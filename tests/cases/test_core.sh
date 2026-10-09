#!/usr/bin/env bash
# 内核管理 — 版本通道与安装参数推导
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
# 三个路径变量必须显式齐备，否则会被上一个 source 过 state.sh 的用例污染。
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"

# 注意实际相对层级：本文件在 tests/cases/，lib 在 xmg/lib，故是 ../lib
source "$TESTS_DIR/../lib/state.sh"
source "$TESTS_DIR/../lib/core.sh"
xmg_state_init

# ------------------------------------------------------------------
# 通道参数推导
# ------------------------------------------------------------------
xmg_state_set XRAY_CHANNEL preview
t_equals "preview 应产出 --beta" "$(xmg_core_install_args)" "--beta"

xmg_state_set XRAY_CHANNEL stable
t_equals "stable 应产出空参数" "$(xmg_core_install_args)" ""

xmg_state_set XRAY_CHANNEL pinned
xmg_state_set XRAY_PINNED_VERSION "v25.8.3"
t_equals "pinned 应产出 --version <tag>" "$(xmg_core_install_args)" "--version v25.8.3"

# pinned 但缺版本号 -> 返回 3（且不吐出半个参数）
xmg_state_set XRAY_PINNED_VERSION ""
_out="$(xmg_core_install_args 2>/dev/null)"; _rc=$?
t_equals "pinned 无版本号应返回 3" "$_rc" "3"
t_equals "pinned 无版本号不应输出参数" "$_out" ""

# 未知通道 -> 返回 2
xmg_state_set XRAY_CHANNEL bogus
xmg_core_install_args >/dev/null 2>&1
t_equals "未知通道应返回 2" "$?" "2"

# ------------------------------------------------------------------
# 通道写入 state
# ------------------------------------------------------------------
xmg_state_set XRAY_CHANNEL stable
xmg_core_channel_set preview 2>/dev/null
t_equals "通道已写为 preview" "$(xmg_state_get XRAY_CHANNEL)" "preview"
t_equals "切到 preview 后清空锁定版本" "$(xmg_state_get XRAY_PINNED_VERSION)" ""

xmg_core_channel_set pinned v25.8.3 2>/dev/null
t_equals "通道已写为 pinned" "$(xmg_state_get XRAY_CHANNEL)" "pinned"
t_equals "锁定版本已记录" "$(xmg_state_get XRAY_PINNED_VERSION)" "v25.8.3"

# pinned 缺版本号应被拒且不写 state
xmg_core_channel_set pinned "" 2>/dev/null
t_equals "pinned 无版本号应返回 2" "$?" "2"
t_equals "pinned 无版本号不污染 state" "$(xmg_state_get XRAY_CHANNEL)" "pinned"

# 非法通道应被拒且不污染 state
xmg_core_channel_set bogus 2>/dev/null
t_equals "非法通道应返回 2" "$?" "2"
t_equals "非法通道不污染 state" "$(xmg_state_get XRAY_CHANNEL)" "pinned"

# ------------------------------------------------------------------
# 未安装内核时 version 应返回非 0（并给出提示）
# ------------------------------------------------------------------
XMG_XRAY_BIN_OVERRIDE=""
XMG_XRAY_BIN="$XMG_TMP/no-such-xray"
xmg_core_version >/dev/null 2>&1
_rc=$?
t_equals "未安装内核时 version 返回非 0" \
    "$([ "$_rc" -ne 0 ] && printf nonzero || printf zero)" "nonzero"

# ------------------------------------------------------------------
# Drop-in Go 运行时内存与并发控制
# ------------------------------------------------------------------
_dropin="$(xmg_core_generate_dropin_content "/custom/xray/config.json" 2>/dev/null || true)"
t_contains "drop-in 注入 GOMEMLIMIT=100MiB" "$_dropin" 'Environment="GOMEMLIMIT=100MiB"'
t_contains "drop-in 注入 GODEBUG=madvdontneed=1" "$_dropin" 'Environment="GODEBUG=madvdontneed=1"'
t_contains "drop-in 注入 GOMAXPROCS=1" "$_dropin" 'Environment="GOMAXPROCS=1"'
t_contains "drop-in 指向指定配置文件" "$_dropin" "ExecStart=/usr/local/bin/xray run -config /custom/xray/config.json"

# ------------------------------------------------------------------
# 215MB 极低内存机器 (extreme_low) 内存体检放行策略
# ------------------------------------------------------------------
printf 'MemTotal: 220160 kB\nMemAvailable: 81920 kB\n' > "$XMG_TMP/mi_215m"
_out="$(XMG_MEMINFO_FILE="$XMG_TMP/mi_215m" xmg_core_memcheck 2>&1)"
_rc=$?
t_equals "215MB 机器内存体检应放行 (返回 0)" "$_rc" "0"
t_contains "215MB 机器提示 extreme_low 模式" "$_out" "extreme_low"
t_contains "215MB 机器提示已应用 100MiB 内存抑制" "$_out" "100MiB"
t_not_contains "215MB 机器不强推 swap" "$_out" "建议先配置 swap"

# 对比：大内存机器但可用内存不足时仍应告警返回 1 并建议 swap
printf 'MemTotal: 1048576 kB\nMemAvailable: 81920 kB\n' > "$XMG_TMP/mi_high_low_avail"
_out="$(XMG_MEMINFO_FILE="$XMG_TMP/mi_high_low_avail" xmg_core_memcheck 2>&1)"
_rc=$?
t_equals "大内存机器可用内存不足时仍返回 1" "$_rc" "1"
t_contains "大内存机器提示建议配置 swap" "$_out" "建议先配置 swap"

# ------------------------------------------------------------------
# 极低内存与 tmpfs 容量不足时解压临时目录推导为物理目录
# ------------------------------------------------------------------
export XMG_HOME="$XMG_TMP/home"
_td="$(MOCK_MEM_TOTAL_KB=220160 xmg_core_resolve_tmpdir 2>/dev/null || true)"
t_equals "215MB 极小内存应推导物理临时目录" "$_td" "$XMG_HOME/tmp"

_td="$(MOCK_TMP_FS=tmpfs MOCK_TMP_AVAIL_KB=51200 MOCK_MEM_TOTAL_KB=1048576 xmg_core_resolve_tmpdir 2>/dev/null || true)"
t_equals "tmpfs 空间紧张时应推导物理临时目录" "$_td" "$XMG_HOME/tmp"

_td="$(MOCK_TMP_FS=tmpfs MOCK_TMP_AVAIL_KB=524288 MOCK_MEM_TOTAL_KB=2097152 xmg_core_resolve_tmpdir 2>/dev/null || true)"
t_equals "正常大内存且 tmpfs 充裕应使用默认 /tmp" "$_td" "/tmp"

# ------------------------------------------------------------------
# drop-in 文件写入与移除端到端验证
# ------------------------------------------------------------------
export XMG_SYSTEMD_DIR="$XMG_TMP/systemd"
mkdir -p "$XMG_SYSTEMD_DIR"
touch "$XMG_SYSTEMD_DIR/xray.service"
export XMG_XRAY_CONFIG="$XMG_TMP/home/xray/config.json"

xmg_core_patch_systemd_unit >/dev/null 2>&1
_conf_file="$XMG_SYSTEMD_DIR/xray.service.d/20-xmg.conf"
t_assert "drop-in 覆盖文件已创建" "[ -f '$_conf_file' ]"
_conf_content="$(cat "$_conf_file" 2>/dev/null || true)"
t_contains "落地文件含 GOMEMLIMIT=100MiB" "$_conf_content" 'Environment="GOMEMLIMIT=100MiB"'
t_contains "落地文件含 GODEBUG=madvdontneed=1" "$_conf_content" 'Environment="GODEBUG=madvdontneed=1"'
t_contains "落地文件含 GOMAXPROCS=1" "$_conf_content" 'Environment="GOMAXPROCS=1"'
t_contains "落地文件含 ExecStart" "$_conf_content" "ExecStart=/usr/local/bin/xray run -config $XMG_XRAY_CONFIG"

# 移除覆盖
xmg_core_restore_systemd_unit >/dev/null 2>&1
t_assert "drop-in 覆盖文件已移除" "[ ! -f '$_conf_file' ]"

# 注意：不 unset XMG_TMP —— 文件头的 EXIT trap 会在退出时引用它，
# 在 run.sh 的 set -u 下 unset 会让 trap 报 unbound variable。
unset _rc _out _dropin _td _conf_file _conf_content XMG_SYSTEMD_DIR
