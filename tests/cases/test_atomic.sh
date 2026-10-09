#!/usr/bin/env bash
# 原子写入与备份清理
# 核心不变量：任何配置变更失败时，运行中的 config.json 必须保持可用
# shellcheck shell=bash

# --- 环境隔离 ---
# run.sh 在同一个 shell 里顺序 source 多个用例，本用例设置的全局变量会漏给
# 后面的用例；state.sh 又有 *_SH_LOADED 守卫，只按首个用例的环境推导一次路径。
# 故：进入时快照、退出时恢复，并用「存在性标志 + 值」两个变量记录
# （不能写成 ${VAR-哨兵}：哨兵只是猜测，路径本身理论上就可能等于它）。
_TA_HAS_ETC="${XMG_ETC_DIR+x}"
_TA_HAS_STATE_DIR="${XMG_XRAY_STATE_DIR+x}"
_TA_HAS_STATE_FILE="${XMG_STATE_FILE+x}"
_TA_HAS_LOG_DIR="${XMG_LOG_DIR+x}"
_TA_HAS_BACKUP_DIR="${XMG_BACKUP_DIR+x}"
_TA_HAS_XRAY_CONFIG="${XMG_XRAY_CONFIG+x}"
_TA_HAS_XRAY_BIN="${XMG_XRAY_BIN+x}"
_TA_HAS_CFG_CMD="${XMG_XRAY_CONFIG_TESTCMD+x}"
_TA_HAS_RELOAD_CMD="${XMG_XRAY_RELOAD_TESTCMD+x}"
_TA_HAS_TEST_MODE="${XMG_TEST_MODE+x}"
# ${VAR-} 而非 ${VAR}：run.sh 带 set -u，未定义变量直接展开会中断测试入口
_TA_SAVED_ETC="${XMG_ETC_DIR-}"
_TA_SAVED_STATE_DIR="${XMG_XRAY_STATE_DIR-}"
_TA_SAVED_STATE_FILE="${XMG_STATE_FILE-}"
_TA_SAVED_LOG_DIR="${XMG_LOG_DIR-}"
_TA_SAVED_BACKUP_DIR="${XMG_BACKUP_DIR-}"
_TA_SAVED_XRAY_CONFIG="${XMG_XRAY_CONFIG-}"
_TA_SAVED_XRAY_BIN="${XMG_XRAY_BIN-}"
_TA_SAVED_CFG_CMD="${XMG_XRAY_CONFIG_TESTCMD-}"
_TA_SAVED_RELOAD_CMD="${XMG_XRAY_RELOAD_TESTCMD-}"
_TA_SAVED_TEST_MODE="${XMG_TEST_MODE-}"

# TMPDIR=/tmp 强制 mktemp 产出 POSIX 路径。原因有二：
#  1) 生产环境 XMG_BACKUP_DIR 是 /opt/xmg/backups（POSIX），用 POSIX 临时路径才贴合；
#  2) 本机（Cygwin）默认 mktemp 会返回 Windows 风格 "C:\...\Temp/tmp.xxx"，
#     而被导出的安全删除钩子（rm 被包装成函数）拒绝一切含 "C:" 的路径，
#     会让 prune 内部的 rm -f 静默失败、用例假失败。
XMG_TMP="$(TMPDIR=/tmp mktemp -d)"
# 不用 trap 清理：EXIT trap 会被同一进程里后续用例（如 test_state.sh）的 trap 覆盖，
# 本用例的临时目录就漏了。改为在用例末尾显式删除。
export XMG_ETC_DIR="$XMG_TMP/etc"
# 三个路径变量必须显式齐备，否则会被上一个 source state.sh 的用例污染。
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_BACKUP_DIR="$XMG_TMP/backups"
export XMG_XRAY_CONFIG="$XMG_TMP/xray/config.json"
export XMG_XRAY_CONFIG_TESTCMD="true"   # 测试桩：把内核校验命令替换为 true
export XMG_XRAY_RELOAD_TESTCMD="true"   # 测试桩：把服务重载替换为 true
# 测试桩现在只在 XMG_TEST_MODE=1 时生效：xmg 以 root 运行，环境变量即命令执行面，
# 这道开关保证生产环境即使存在同名变量也不会 eval 任意命令。
export XMG_TEST_MODE=1

# shellcheck source=../../lib/state.sh
# 注意：lib 与 tests 同级，所以是 ../lib（简报里写的 ../../lib 多退了一级）
source "$TESTS_DIR/../lib/state.sh"

# 简报里写成 mkdir -p "$XMG_LOG_DIR" "$XMG_XRAY_CONFIG"，会把 config.json 建成目录，
# 后续写入必失败。这里只建目录，config.json 由后面的用例按需写成文件。
mkdir -p "$XMG_LOG_DIR" "$XMG_BACKUP_DIR" "$(dirname "$XMG_XRAY_CONFIG")"
xmg_state_init

# ============================================================================
# --- 备份清理：保留上限 ---
# ============================================================================
_i=1
while [ "$_i" -le 8 ]; do
    touch "$XMG_BACKUP_DIR/config.json.2026010${_i}-000000.bak"
    _i=$((_i + 1))
done
xmg_state_set XMG_BACKUP_KEEP 5
xmg_backup_prune "$XMG_BACKUP_DIR" 5 "config.json."
t_equals "备份清理后保留 5 份" \
    "$(find "$XMG_BACKUP_DIR" -maxdepth 1 -name 'config.json.*.bak' | wc -l | tr -d ' ')" "5"
# 保留的必须是"最新"的若干份，而不是任意 5 份
t_assert "最新一份被保留" test -f "$XMG_BACKUP_DIR/config.json.20260108-000000.bak"
t_assert "最旧一份被删除" test ! -f "$XMG_BACKUP_DIR/config.json.20260101-000000.bak"

# ============================================================================
# --- 备份清理：不影响其它前缀 ---
# ============================================================================
touch "$XMG_BACKUP_DIR/state.env.20260101-000000.bak"
xmg_backup_prune "$XMG_BACKUP_DIR" 5 "config.json."
t_assert "其它前缀备份未被删除" \
    test -f "$XMG_BACKUP_DIR/state.env.20260101-000000.bak"

# ============================================================================
# --- 备份清理：保留数大于实际份数时不报错 ---
# ============================================================================
xmg_backup_prune "$XMG_BACKUP_DIR" 99 "config.json."
t_equals "保留数大于实际份数应返回 0" "$?" "0"

# ============================================================================
# --- 备份清理：目录不存在时不阻断 ---
# ============================================================================
xmg_backup_prune "$XMG_TMP/nonexistent" 5 "config.json."
t_equals "目录不存在应返回 0" "$?" "0"

# ============================================================================
# --- 备份清理：缺省前缀不得误删其它备份 ---
# 历史隐患：prefix 默认空串会匹配目录内全部 *.bak。默认值改为 config.json. 后，
# 即使调用方漏传前缀，也只影响配置备份，不会误删 state.env.*.bak。
# ============================================================================
_j=1
while [ "$_j" -le 3 ]; do
    touch "$XMG_BACKUP_DIR/state.env.2026020${_j}-000000.bak"
    _j=$((_j + 1))
done
_se_before="$(find "$XMG_BACKUP_DIR" -maxdepth 1 -name 'state.env.*.bak' | wc -l | tr -d ' ')"
xmg_backup_prune "$XMG_BACKUP_DIR" 1   # 只传目录与保留数，前缀走默认值
t_equals "缺省前缀清理仅保留 1 份 config 备份" \
    "$(find "$XMG_BACKUP_DIR" -maxdepth 1 -name 'config.json.*.bak' | wc -l | tr -d ' ')" "1"
t_equals "缺省前缀不误删 state.env 备份" \
    "$(find "$XMG_BACKUP_DIR" -maxdepth 1 -name 'state.env.*.bak' | wc -l | tr -d ' ')" "$_se_before"

# ============================================================================
# --- xray 定位：未安装时返回 1 ---
# 清掉可能的 override，避免用例之间互相污染（本用例最后一个 source state.sh 的
# 用例会沿用守卫值，但 override 是普通变量，仍显式清一下更稳）。
unset XMG_XRAY_BIN_OVERRIDE
XMG_XRAY_BIN="$XMG_TMP/no-such-xray"
xmg_xray_binary
t_equals "xray 不存在应返回 1" "$?" "1"

# ============================================================================
# --- 配置校验：桩分支与生产路径语义一致（文件不存在都返回 3）---
# 旧桩分支跳过 [ -f "$cfg" ] 检查：配置不存在时桩返回 4、生产返回 3，两条路径分叉。
# ============================================================================
export XMG_XRAY_CONFIG_TESTCMD="true"
xmg_state_validate_config "$XMG_TMP/no-such-config.json" 2>/dev/null
t_equals "桩分支：新配置不存在应返回 3（与生产路径对齐）" "$?" "3"

# ============================================================================
# --- 配置校验：真实分支（不走桩，用假 xray 二进制驱动）---
# 此前只覆盖过桩分支，生产校验路径从未被测过；这里补上这一缺口。
# ============================================================================
printf '#!/bin/sh\nexit 1\n' > "$XMG_TMP/fake-xray-fail"
printf '#!/bin/sh\nexit 0\n' > "$XMG_TMP/fake-xray-ok"
chmod +x "$XMG_TMP/fake-xray-fail" "$XMG_TMP/fake-xray-ok"
printf '{"marker":"probe"}\n' > "$XMG_TMP/probe.json"
unset XMG_XRAY_CONFIG_TESTCMD          # 撤掉桩，强制走真实分支
export XMG_XRAY_BIN_OVERRIDE="$XMG_TMP/fake-xray-fail"
xmg_state_validate_config "$XMG_TMP/probe.json" 2>/dev/null
t_equals "真实分支：xray 拒绝配置应返回 3" "$?" "3"
export XMG_XRAY_BIN_OVERRIDE="$XMG_TMP/fake-xray-ok"
xmg_state_validate_config "$XMG_TMP/probe.json" 2>/dev/null
t_equals "真实分支：xray 接受配置应返回 0" "$?" "0"
xmg_state_validate_config "$XMG_TMP/no-such-config.json" 2>/dev/null
t_equals "真实分支：新配置不存在应返回 3" "$?" "3"
unset XMG_XRAY_BIN_OVERRIDE
export XMG_XRAY_CONFIG_TESTCMD="true"   # 复位，后续用例继续用桩

# ============================================================================
# --- 原子提交：校验失败时现网配置字节不变（核心不变量）---
# ============================================================================
printf '{"marker":"original"}\n' > "$XMG_XRAY_CONFIG"
printf '{"marker":"broken"\n' > "$XMG_TMP/broken.json"
_before_sum="$(cksum < "$XMG_XRAY_CONFIG")"
export XMG_XRAY_CONFIG_TESTCMD="false"   # 测试桩：校验必定失败
xmg_state_commit "$XMG_TMP/broken.json" 2>/dev/null
t_equals "校验失败应返回 3" "$?" "3"
t_contains "校验失败后现网配置内容不变" "$(cat "$XMG_XRAY_CONFIG")" 'original'
t_equals "校验失败后现网配置字节不变" "$(cksum < "$XMG_XRAY_CONFIG")" "$_before_sum"
t_not_contains "校验失败后现网配置未被写入坏内容" "$(cat "$XMG_XRAY_CONFIG")" 'broken'

# ============================================================================
# --- 原子提交：成功时替换并备份旧配置 ---
# ============================================================================
printf '{"marker":"new"}\n' > "$XMG_TMP/new.json"
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="true"
xmg_state_commit "$XMG_TMP/new.json"
t_equals "提交成功应返回 0" "$?" "0"
t_contains "配置已替换为新内容" "$(cat "$XMG_XRAY_CONFIG")" 'new'
t_assert "旧配置已备份（存在 config.json.*.bak）" \
    "ls $XMG_BACKUP_DIR/config.json.*.bak >/dev/null 2>&1"
t_assert "备份内容是提交前的旧配置" \
    "grep -q original $XMG_BACKUP_DIR/config.json.*.bak"

# ============================================================================
# --- 原子提交：reload 失败必须回滚到原配置（md5 + cmp 双重验证）---
# ============================================================================
printf '{"marker":"keep-me"}\n' > "$XMG_XRAY_CONFIG"
cp -a "$XMG_XRAY_CONFIG" "$XMG_TMP/keep-me.snapshot"
_ta_rollback_md5="$(md5sum < "$XMG_XRAY_CONFIG")"
printf '{"marker":"should-not-stick"}\n' > "$XMG_TMP/new2.json"
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="false"   # 测试桩：重载必定失败
_ta_rb_err="$(xmg_state_commit "$XMG_TMP/new2.json" 2>&1 >/dev/null)"
_ta_rb_rc=$?
t_equals "reload 失败应返回 4" "$_ta_rb_rc" "4"
t_equals "reload 失败后现网 md5 恢复为旧配置" "$(md5sum < "$XMG_XRAY_CONFIG")" "$_ta_rollback_md5"
t_assert "回滚后现网与旧配置逐字节相同（cmp）" cmp "$XMG_XRAY_CONFIG" "$XMG_TMP/keep-me.snapshot"
t_contains "reload 失败已回滚到原配置" "$(cat "$XMG_XRAY_CONFIG")" 'keep-me'
t_not_contains "回滚后不含未生效的新配置" "$(cat "$XMG_XRAY_CONFIG")" 'should-not-stick'
t_contains "确有回滚时文案如实报告已回滚" "$_ta_rb_err" "已回滚"

# ============================================================================
# --- 原子提交：首次安装（原本无现网配置）+ reload 失败 → 如实报告，不谎称回滚 ---
# ============================================================================
rm -f "$XMG_XRAY_CONFIG"
printf '{"marker":"fresh"}\n' > "$XMG_TMP/fresh.json"
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="false"
_ta_fresh_err="$(xmg_state_commit "$XMG_TMP/fresh.json" 2>&1 >/dev/null)"
_ta_fresh_rc=$?
t_equals "首次安装 reload 失败应返回 4" "$_ta_fresh_rc" "4"
t_not_contains "首次安装 reload 失败不得谎称已回滚" "$_ta_fresh_err" "已回滚"
t_contains "首次安装 reload 失败应如实说明新配置未生效" "$_ta_fresh_err" "未生效"
t_assert "首次安装 reload 失败默认保留新配置（便于排查）" test -f "$XMG_XRAY_CONFIG"
t_contains "保留的新配置是刚写入的内容" "$(cat "$XMG_XRAY_CONFIG")" 'fresh'

# ============================================================================
# --- 原子提交：备份失败必须中止且现网字节不变（核心不变量）---
# 备份目录不可写/磁盘满时，不能带着「无退路」的状态替换现网配置。
# 用「父路径是普通文件」制造 mkdir/cp 必失败。
# ============================================================================
printf '{"marker":"must-survive"}\n' > "$XMG_XRAY_CONFIG"
cp -a "$XMG_XRAY_CONFIG" "$XMG_TMP/original.snapshot"
_ta_bak_before_md5="$(md5sum < "$XMG_XRAY_CONFIG")"
printf '{"marker":"must-not-land"}\n' > "$XMG_TMP/new3.json"
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="false"   # reload 本会失败——但根本不该走到那一步
: > "$XMG_TMP/notadir"
export XMG_BACKUP_DIR="$XMG_TMP/notadir/backups"
_ta_bak_err="$(xmg_state_commit "$XMG_TMP/new3.json" 2>&1 >/dev/null)"
_ta_bak_rc=$?
t_equals "备份失败应返回 4" "$_ta_bak_rc" "4"
t_equals "备份失败后现网配置 md5 不变" "$(md5sum < "$XMG_XRAY_CONFIG")" "$_ta_bak_before_md5"
t_assert "备份失败后现网与快照逐字节相同（cmp）" cmp "$XMG_XRAY_CONFIG" "$XMG_TMP/original.snapshot"
t_not_contains "备份失败后现网仍是旧内容" "$(cat "$XMG_XRAY_CONFIG")" 'must-not-land'
t_not_contains "备份失败不得出现已回滚字样" "$_ta_bak_err" "已回滚"
export XMG_BACKUP_DIR="$XMG_TMP/backups"   # 恢复备份目录供后续使用

# ============================================================================
# --- 恢复环境 + 清理（见文件开头「环境隔离」的解释）---
# ============================================================================
# 恢复要在断言之后：中途恢复会让本用例后续断言读到别人的路径。
XMG_ETC_DIR="$_TA_SAVED_ETC"
XMG_XRAY_STATE_DIR="$_TA_SAVED_STATE_DIR"
XMG_STATE_FILE="$_TA_SAVED_STATE_FILE"
XMG_LOG_DIR="$_TA_SAVED_LOG_DIR"
XMG_BACKUP_DIR="$_TA_SAVED_BACKUP_DIR"
XMG_XRAY_CONFIG="$_TA_SAVED_XRAY_CONFIG"
XMG_XRAY_BIN="$_TA_SAVED_XRAY_BIN"
# 原先不存在的变量要真正 unset，否则会凭空多出指向空串的变量给后续用例
[ -n "$_TA_HAS_ETC" ] || unset XMG_ETC_DIR
[ -n "$_TA_HAS_STATE_DIR" ] || unset XMG_XRAY_STATE_DIR
[ -n "$_TA_HAS_STATE_FILE" ] || unset XMG_STATE_FILE
[ -n "$_TA_HAS_LOG_DIR" ] || unset XMG_LOG_DIR
[ -n "$_TA_HAS_BACKUP_DIR" ] || unset XMG_BACKUP_DIR
[ -n "$_TA_HAS_XRAY_CONFIG" ] || unset XMG_XRAY_CONFIG
[ -n "$_TA_HAS_XRAY_BIN" ] || unset XMG_XRAY_BIN
if [ -n "$_TA_HAS_CFG_CMD" ]; then
    XMG_XRAY_CONFIG_TESTCMD="$_TA_SAVED_CFG_CMD"
else
    unset XMG_XRAY_CONFIG_TESTCMD
fi
if [ -n "$_TA_HAS_RELOAD_CMD" ]; then
    XMG_XRAY_RELOAD_TESTCMD="$_TA_SAVED_RELOAD_CMD"
else
    unset XMG_XRAY_RELOAD_TESTCMD
fi
if [ -n "$_TA_HAS_TEST_MODE" ]; then
    XMG_TEST_MODE="$_TA_SAVED_TEST_MODE"
else
    unset XMG_TEST_MODE
fi
unset _TA_HAS_ETC _TA_HAS_STATE_DIR _TA_HAS_STATE_FILE _TA_HAS_LOG_DIR
unset _TA_HAS_BACKUP_DIR _TA_HAS_XRAY_CONFIG _TA_HAS_XRAY_BIN
unset _TA_HAS_CFG_CMD _TA_HAS_RELOAD_CMD _TA_HAS_TEST_MODE
unset _TA_SAVED_ETC _TA_SAVED_STATE_DIR _TA_SAVED_STATE_FILE _TA_SAVED_LOG_DIR
unset _TA_SAVED_BACKUP_DIR _TA_SAVED_XRAY_CONFIG _TA_SAVED_XRAY_BIN
unset _TA_SAVED_CFG_CMD _TA_SAVED_RELOAD_CMD _TA_SAVED_TEST_MODE
# XMG_STATE 是 state.sh 的全局关联数组，本用例改过它（XMG_BACKUP_KEEP 试验），
# 清空让下一个用例的 init/load 重新填。
XMG_STATE=()
rm -rf "$XMG_TMP"
unset XMG_TMP _i _before_sum _j _se_before
unset _ta_rollback_md5 _ta_rb_err _ta_rb_rc _ta_fresh_err _ta_fresh_rc
unset _ta_bak_before_md5 _ta_bak_err _ta_bak_rc
