#!/usr/bin/env bash
# shellcheck shell=bash
#
# test_state_atomic_dual.sh - 状态引擎与双文件两阶段联合事务测试
#
# 测试重点：
#   1. WARP 相关状态键（WARP_ENABLED, WARP_MODE, WARP_ENDPOINT, WARP_PRIVATE_KEY,
#      WARP_PUBLIC_KEY, WARP_IPV4, WARP_IPV6, WARP_RESERVED）的合法存储、校验与重置。
#   2. state.sh 双文件（state.env 与 config.json）两阶段联合事务：
#      - Phase 1 校验失败场景（如 xray run -test 失败），断言当前 state.env 与 config.json 均保持未动；
#      - Phase 2 重载/重启服务失败场景，断言触发双回滚（同时还原 config.json 与 state.env），退出码返回 4；
#      - 正常提交成功场景，断言 config.json 与 state.env 均更新，旧版本备份保留在 backups 目录。

_TSA_HAS_ETC="${XMG_ETC_DIR+x}"
_TSA_HAS_STATE_DIR="${XMG_XRAY_STATE_DIR+x}"
_TSA_HAS_STATE_FILE="${XMG_STATE_FILE+x}"
_TSA_HAS_LOG_DIR="${XMG_LOG_DIR+x}"
_TSA_HAS_BACKUP_DIR="${XMG_BACKUP_DIR+x}"
_TSA_HAS_XRAY_CONFIG="${XMG_XRAY_CONFIG+x}"
_TSA_HAS_CFG_CMD="${XMG_XRAY_CONFIG_TESTCMD+x}"
_TSA_HAS_RELOAD_CMD="${XMG_XRAY_RELOAD_TESTCMD+x}"
_TSA_HAS_TEST_MODE="${XMG_TEST_MODE+x}"

_TSA_SAVED_ETC="${XMG_ETC_DIR-}"
_TSA_SAVED_STATE_DIR="${XMG_XRAY_STATE_DIR-}"
_TSA_SAVED_STATE_FILE="${XMG_STATE_FILE-}"
_TSA_SAVED_LOG_DIR="${XMG_LOG_DIR-}"
_TSA_SAVED_BACKUP_DIR="${XMG_BACKUP_DIR-}"
_TSA_SAVED_XRAY_CONFIG="${XMG_XRAY_CONFIG-}"
_TSA_SAVED_CFG_CMD="${XMG_XRAY_CONFIG_TESTCMD-}"
_TSA_SAVED_RELOAD_CMD="${XMG_XRAY_RELOAD_TESTCMD-}"
_TSA_SAVED_TEST_MODE="${XMG_TEST_MODE-}"

XMG_TMP="$(TMPDIR=/tmp mktemp -d)"
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_BACKUP_DIR="$XMG_TMP/backups"
export XMG_XRAY_CONFIG="$XMG_TMP/xray/config.json"
export XMG_TEST_MODE=1
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="true"

# shellcheck source=../../lib/state.sh
source "$TESTS_DIR/../lib/state.sh"

mkdir -p "$XMG_LOG_DIR" "$XMG_BACKUP_DIR" "$XMG_XRAY_STATE_DIR" "$(dirname "$XMG_XRAY_CONFIG")"
xmg_state_init

# ============================================================================
# 1. WARP 相关状态键支持：默认值、写入、读取与校验
# ============================================================================
t_equals "WARP_ENABLED 默认值为 0" "$(xmg_state_get WARP_ENABLED)" "0"
t_equals "WARP_MODE 默认值为 global" "$(xmg_state_get WARP_MODE)" "global"
t_equals "WARP_ENDPOINT 默认为空" "$(xmg_state_get WARP_ENDPOINT)" ""
t_equals "WARP_PRIVATE_KEY 默认为空" "$(xmg_state_get WARP_PRIVATE_KEY)" ""
t_equals "WARP_PUBLIC_KEY 默认为空" "$(xmg_state_get WARP_PUBLIC_KEY)" ""
t_equals "WARP_IPV4 默认为空" "$(xmg_state_get WARP_IPV4)" ""
t_equals "WARP_IPV6 默认为空" "$(xmg_state_get WARP_IPV6)" ""
t_equals "WARP_RESERVED 默认为空" "$(xmg_state_get WARP_RESERVED)" ""

# 写入合法 WARP 字段
xmg_state_set WARP_ENABLED 1
xmg_state_set WARP_MODE routing
xmg_state_set WARP_ENDPOINT "162.159.192.1:2408"
xmg_state_set WARP_PRIVATE_KEY "priv_test_key_sample"
xmg_state_set WARP_PUBLIC_KEY "pub_test_key_sample"
xmg_state_set WARP_IPV4 "172.16.0.2"
xmg_state_set WARP_IPV6 "2606:4700:110:8f6a::"
xmg_state_set WARP_RESERVED "[230, 19, 10]"

t_equals "WARP_ENABLED 写入成功" "$(xmg_state_get WARP_ENABLED)" "1"
t_equals "WARP_MODE 写入成功" "$(xmg_state_get WARP_MODE)" "routing"
t_equals "WARP_ENDPOINT 写入成功" "$(xmg_state_get WARP_ENDPOINT)" "162.159.192.1:2408"
t_equals "WARP_PRIVATE_KEY 写入成功" "$(xmg_state_get WARP_PRIVATE_KEY)" "priv_test_key_sample"
t_equals "WARP_PUBLIC_KEY 写入成功" "$(xmg_state_get WARP_PUBLIC_KEY)" "pub_test_key_sample"
t_equals "WARP_IPV4 写入成功" "$(xmg_state_get WARP_IPV4)" "172.16.0.2"
t_equals "WARP_IPV6 写入成功" "$(xmg_state_get WARP_IPV6)" "2606:4700:110:8f6a::"
t_equals "WARP_RESERVED 写入成功" "$(xmg_state_get WARP_RESERVED)" "[230, 19, 10]"

t_assert "合法 WARP 字段校验通过" xmg_state_validate

# 校验拦截：非法 WARP_MODE
xmg_state_stage WARP_MODE "unsupported_mode"
xmg_state_validate 2>/dev/null
t_equals "非法 WARP_MODE 校验拦截 (返回 2)" "$?" "2"
xmg_state_stage_clear

# 校验拦截：非法 WARP_ENDPOINT (无端口)
xmg_state_stage WARP_ENDPOINT "192.168.1.1"
xmg_state_validate 2>/dev/null
t_equals "无端口 WARP_ENDPOINT 校验拦截 (返回 2)" "$?" "2"
xmg_state_stage_clear

# 重置 WARP 状态
xmg_state_set WARP_ENABLED 0
xmg_state_set WARP_MODE global
xmg_state_set WARP_ENDPOINT ""
xmg_state_set WARP_PRIVATE_KEY ""
xmg_state_set WARP_PUBLIC_KEY ""
xmg_state_set WARP_IPV4 ""
xmg_state_set WARP_IPV6 ""
xmg_state_set WARP_RESERVED ""

# ============================================================================
# 2. 双文件两阶段联合事务：准备初始环境
# ============================================================================
xmg_state_set PROXY_VLESS_PORT 443
printf '{"marker":"orig_config","port":443}\n' > "$XMG_XRAY_CONFIG"

_tsa_orig_cfg_sum="$(cksum < "$XMG_XRAY_CONFIG")"
_tsa_orig_state_sum="$(cksum < "$XMG_STATE_FILE")"

# ----------------------------------------------------------------------------
# 2.1 Phase 1 校验失败场景（如 xray run -test 失败）：
#     断言当前 state.env 与 config.json 均保持未动，绝不提前覆盖；返回 3
# ----------------------------------------------------------------------------
printf '{"marker":"bad_config","port":8443}\n' > "$XMG_TMP/candidate_fail.json"
xmg_state_stage PROXY_VLESS_PORT 8443
export XMG_XRAY_CONFIG_TESTCMD="false"   # 模拟 xray run -test 校验失败
export XMG_XRAY_RELOAD_TESTCMD="true"

xmg_state_commit "$XMG_TMP/candidate_fail.json"
_tsa_p1_rc=$?

t_equals "Phase 1 校验失败应返回 3" "$_tsa_p1_rc" "3"
t_equals "Phase 1 失败后 config.json 内容完全未动" "$(cksum < "$XMG_XRAY_CONFIG")" "$_tsa_orig_cfg_sum"
t_equals "Phase 1 失败后 state.env 内容完全未动" "$(cksum < "$XMG_STATE_FILE")" "$_tsa_orig_state_sum"
t_equals "Phase 1 失败后内存状态恢复（无 Ghost State）" "$(xmg_state_get PROXY_VLESS_PORT)" "443"

# ----------------------------------------------------------------------------
# 2.2 Phase 2 重载/重启服务失败场景：
#     断言触发双回滚（同时自动还原 config.json 与 state.env 到提交前状态），退出码返回 4
# ----------------------------------------------------------------------------
printf '{"marker":"candidate_reload_fail","port":8443}\n' > "$XMG_TMP/candidate_reload_fail.json"
xmg_state_stage PROXY_VLESS_PORT 8443
export XMG_XRAY_CONFIG_TESTCMD="true"    # 校验通过
export XMG_XRAY_RELOAD_TESTCMD="false"  # 重启服务失败

xmg_state_commit "$XMG_TMP/candidate_reload_fail.json" >/dev/null 2>&1
_tsa_p2_rc=$?

t_equals "Phase 2 重载失败应返回 4" "$_tsa_p2_rc" "4"
t_equals "Phase 2 失败后 config.json 成功双回滚为旧配置" "$(cksum < "$XMG_XRAY_CONFIG")" "$_tsa_orig_cfg_sum"
t_equals "Phase 2 失败后 state.env 成功双回滚为旧状态" "$(cksum < "$XMG_STATE_FILE")" "$_tsa_orig_state_sum"
t_contains "Phase 2 回滚后 config.json 含原有 marker" "$(cat "$XMG_XRAY_CONFIG")" "orig_config"
t_not_contains "Phase 2 回滚后 config.json 不含未生效内容" "$(cat "$XMG_XRAY_CONFIG")" "candidate_reload_fail"
t_equals "Phase 2 回滚后内存状态恢复为旧端口 (443)" "$(xmg_state_get PROXY_VLESS_PORT)" "443"

# ----------------------------------------------------------------------------
# 2.3 正常提交成功场景：
#     断言 config.json 与 state.env 均更新，旧版本备份保留在 backups 目录
# ----------------------------------------------------------------------------
printf '{"marker":"success_config","port":9443}\n' > "$XMG_TMP/candidate_ok.json"
xmg_state_stage PROXY_VLESS_PORT 9443
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="true"

xmg_state_commit "$XMG_TMP/candidate_ok.json"
_tsa_ok_rc=$?

t_equals "正常提交成功应返回 0" "$_tsa_ok_rc" "0"
t_contains "正常提交后 config.json 已成功落盘" "$(cat "$XMG_XRAY_CONFIG")" "success_config"
t_contains "正常提交后 state.env 已成功更新" "$(cat "$XMG_STATE_FILE")" "PROXY_VLESS_PORT=9443"
t_equals "正常提交后内存状态为 9443" "$(xmg_state_get PROXY_VLESS_PORT)" "9443"

t_assert "config.json 旧版本备份保留在 backups 目录" "ls $XMG_BACKUP_DIR/config.json.*.bak >/dev/null 2>&1"
t_assert "state.env 旧版本备份保留在 backups 目录" "ls $XMG_BACKUP_DIR/state.env.*.bak >/dev/null 2>&1"
t_assert "config.json 备份包含提交前的旧内容" "grep -q orig_config $XMG_BACKUP_DIR/config.json.*.bak"
t_assert "state.env 备份包含提交前的旧状态" "grep -q 'PROXY_VLESS_PORT=443' $XMG_BACKUP_DIR/state.env.*.bak"

# ============================================================================
# 环境清理与恢复
# ============================================================================
rm -rf "$XMG_TMP" 2>/dev/null || true
XMG_ETC_DIR="$_TSA_SAVED_ETC"
XMG_XRAY_STATE_DIR="$_TSA_SAVED_STATE_DIR"
XMG_STATE_FILE="$_TSA_SAVED_STATE_FILE"
XMG_LOG_DIR="$_TSA_SAVED_LOG_DIR"
XMG_BACKUP_DIR="$_TSA_SAVED_BACKUP_DIR"
XMG_XRAY_CONFIG="$_TSA_SAVED_XRAY_CONFIG"
[ -n "$_TSA_HAS_ETC" ] || unset XMG_ETC_DIR
[ -n "$_TSA_HAS_STATE_DIR" ] || unset XMG_XRAY_STATE_DIR
[ -n "$_TSA_HAS_STATE_FILE" ] || unset XMG_STATE_FILE
[ -n "$_TSA_HAS_LOG_DIR" ] || unset XMG_LOG_DIR
[ -n "$_TSA_HAS_BACKUP_DIR" ] || unset XMG_BACKUP_DIR
[ -n "$_TSA_HAS_XRAY_CONFIG" ] || unset XMG_XRAY_CONFIG
if [ -n "$_TSA_HAS_CFG_CMD" ]; then
    XMG_XRAY_CONFIG_TESTCMD="$_TSA_SAVED_CFG_CMD"
else
    unset XMG_XRAY_CONFIG_TESTCMD
fi
if [ -n "$_TSA_HAS_RELOAD_CMD" ]; then
    XMG_XRAY_RELOAD_TESTCMD="$_TSA_SAVED_RELOAD_CMD"
else
    unset XMG_XRAY_RELOAD_TESTCMD
fi
if [ -n "$_TSA_HAS_TEST_MODE" ]; then
    XMG_TEST_MODE="$_TSA_SAVED_TEST_MODE"
else
    unset XMG_TEST_MODE
fi
