#!/usr/bin/env bash
# proxy apply / status / disable / export
# shellcheck shell=bash

# --- 环境隔离 ---
# run.sh 在同一 shell 里顺序 source 多个用例；本用例会改一批环境变量，
# 退出时逐项恢复，避免污染后续用例（尤其是 XMG_TEST_MODE / 测试桩）。
_TP_HAS_ETC="${XMG_ETC_DIR+x}"
_TP_HAS_STATE_DIR="${XMG_XRAY_STATE_DIR+x}"
_TP_HAS_STATE_FILE="${XMG_STATE_FILE+x}"
_TP_HAS_LOG_DIR="${XMG_LOG_DIR+x}"
_TP_HAS_BACKUP_DIR="${XMG_BACKUP_DIR+x}"
_TP_HAS_XRAY_CONFIG="${XMG_XRAY_CONFIG+x}"
_TP_HAS_CFG_CMD="${XMG_XRAY_CONFIG_TESTCMD+x}"
_TP_HAS_RELOAD_CMD="${XMG_XRAY_RELOAD_TESTCMD+x}"
_TP_HAS_TEST_MODE="${XMG_TEST_MODE+x}"
_TP_HAS_NO_RELOAD="${XMG_PROXY_NO_RELOAD+x}"
_TP_SAVED_ETC="${XMG_ETC_DIR-}"
_TP_SAVED_STATE_DIR="${XMG_XRAY_STATE_DIR-}"
_TP_SAVED_STATE_FILE="${XMG_STATE_FILE-}"
_TP_SAVED_LOG_DIR="${XMG_LOG_DIR-}"
_TP_SAVED_BACKUP_DIR="${XMG_BACKUP_DIR-}"
_TP_SAVED_XRAY_CONFIG="${XMG_XRAY_CONFIG-}"
_TP_SAVED_CFG_CMD="${XMG_XRAY_CONFIG_TESTCMD-}"
_TP_SAVED_RELOAD_CMD="${XMG_XRAY_RELOAD_TESTCMD-}"
_TP_SAVED_TEST_MODE="${XMG_TEST_MODE-}"
_TP_SAVED_NO_RELOAD="${XMG_PROXY_NO_RELOAD-}"

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
# 三个路径变量必须显式齐备，否则会被上一个 source 过 state.sh 的用例污染。
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_BACKUP_DIR="$XMG_TMP/backups"
export XMG_XRAY_CONFIG="$XMG_TMP/xray/config.json"
# 测试桩：把内核校验与 reload 分别替换为 true。
# 两个桩都只在 XMG_TEST_MODE=1 时生效（生产环境即使同名也不 eval 任意命令）。
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="true"
export XMG_TEST_MODE=1
export XMG_PROXY_NO_RELOAD=1

CERT="$XMG_TMP/c.crt"; KEY="$XMG_TMP/k.key"
echo c > "$CERT"; echo k > "$KEY"
mkdir -p "$(dirname "$XMG_XRAY_CONFIG")" "$XMG_BACKUP_DIR"

# 注意实际相对层级：本文件在 tests/cases/，lib 在 xmg/lib，故是 ../lib
source "$TESTS_DIR/../lib/state.sh"
source "$TESTS_DIR/../lib/render.sh"
source "$TESTS_DIR/../lib/proxy.sh"
xmg_state_init

# ------------------------------------------------------------------
# apply：仅 SOCKS
# ------------------------------------------------------------------
xmg_proxy_apply --socks on --socks-port 1080 --socks-user alice \
                --socks-pass supersecret 2>/dev/null
t_equals "apply socks 应返回 0" "$?" "0"
t_assert "config.json 已生成" test -f "$XMG_XRAY_CONFIG"
t_contains "config 含 socks 入站" "$(cat "$XMG_XRAY_CONFIG")" '"tag": "inbound-socks"'
t_equals "state 已记录端口" "$(xmg_state_get PROXY_SOCKS_PORT)" "1080"

# ------------------------------------------------------------------
# 幂等：同一输入重复执行，config.json 内容不变
# ------------------------------------------------------------------
BEFORE="$(cat "$XMG_XRAY_CONFIG")"
SBEFORE="$(cat "$XMG_STATE_FILE")"
xmg_proxy_apply --socks on --socks-port 1080 --socks-user alice \
                --socks-pass supersecret 2>/dev/null
t_equals "重复 apply 应返回 0" "$?" "0"
t_equals "config 幂等不变" "$(cat "$XMG_XRAY_CONFIG")" "$BEFORE"
t_equals "state 幂等不变" "$(cat "$XMG_STATE_FILE")" "$SBEFORE"

# ------------------------------------------------------------------
# apply：追加 VLESS 实现共存
# ------------------------------------------------------------------
xmg_proxy_apply --vless on --vless-port 443 --vless-domain example.com \
                --vless-uuid uuid-abc --vless-mode auto \
                --vless-cert-source user \
                --vless-cert-file "$CERT" --vless-key-file "$KEY" 2>/dev/null
t_equals "apply vless 应返回 0" "$?" "0"
CFG="$(cat "$XMG_XRAY_CONFIG")"
t_contains "共存含 socks" "$CFG" '"tag": "inbound-socks"'
t_contains "共存含 vless" "$CFG" '"tag": "inbound-vless"'

# ------------------------------------------------------------------
# 校验失败：返回 2 且绝不触碰现网（config 与 state 都不变）
# ------------------------------------------------------------------
GOOD="$(cat "$XMG_XRAY_CONFIG")"
SGOOD="$(cat "$XMG_STATE_FILE")"
xmg_proxy_apply --socks-pass short 2>/dev/null
t_equals "密码过短应返回 2" "$?" "2"
t_equals "校验失败后 config 不变" "$(cat "$XMG_XRAY_CONFIG")" "$GOOD"
t_equals "校验失败后 state 不变" "$(cat "$XMG_STATE_FILE")" "$SGOOD"

# ------------------------------------------------------------------
# 端口冲突：返回 2
# ------------------------------------------------------------------
xmg_proxy_apply --vless-port 1080 2>/dev/null
t_equals "端口冲突应返回 2" "$?" "2"

# ------------------------------------------------------------------
# disable：只影响目标方案
# ------------------------------------------------------------------
xmg_proxy_disable vless 2>/dev/null
t_equals "disable vless 应返回 0" "$?" "0"
CFG2="$(cat "$XMG_XRAY_CONFIG")"
t_not_contains "vless 已移除" "$CFG2" '"tag": "inbound-vless"'
t_contains "socks 仍在" "$CFG2" '"tag": "inbound-socks"'

# ------------------------------------------------------------------
# status：文本输出
# ------------------------------------------------------------------
OUT="$(xmg_proxy_status 2>&1)"
t_contains "status 显示 socks" "$OUT" "SOCKS5"
t_contains "status 显示 vless" "$OUT" "VLESS"
t_contains "status 显示端口" "$OUT" "1080"
t_not_contains "status 不泄露密码" "$OUT" "supersecret"

# ------------------------------------------------------------------
# status --json
# ------------------------------------------------------------------
JOUT="$(xmg_proxy_status --json 2>/dev/null)"
t_contains "JSON 含 socks_enabled" "$JOUT" '"socks_enabled"'
t_contains "JSON 含 vless_enabled" "$JOUT" '"vless_enabled"'
t_contains "JSON 含 buffer_size" "$JOUT" '"buffer_size"'
t_not_contains "JSON 不含密码" "$JOUT" "supersecret"
t_contains "JSON 首字符为 {" "${JOUT:0:1}" "{"

# ------------------------------------------------------------------
# export
# ------------------------------------------------------------------
EOUT="$(xmg_proxy_export 2>/dev/null)"
t_contains "export 含 SOCKS 端口" "$EOUT" "PROXY_SOCKS_PORT=1080"

# ------------------------------------------------------------------
# 非法方案名
# ------------------------------------------------------------------
xmg_proxy_disable bogus 2>/dev/null
t_equals "非法方案名应返回 2" "$?" "2"

# ------------------------------------------------------------------
# acme 来源防损坏与证书文件不存在时的防御性处理
# ------------------------------------------------------------------
xmg_proxy_apply --vless on --vless-port 8443 --vless-domain acme.test \
                --vless-uuid acme-uuid-123 --vless-cert-source acme 2>/dev/null
t_equals "acme apply 应返回 0" "$?" "0"
CFG_ACME="$(cat "$XMG_XRAY_CONFIG")"
t_contains "acme 配置含 inbound-vless" "$CFG_ACME" '"tag": "inbound-vless"'
t_contains "acme 配置含 serverName" "$CFG_ACME" '"serverName": "acme.test"'
t_contains "acme 配置以 { 开头" "${CFG_ACME:0:1}" "{"
t_equals "state 记录来源为 acme" "$(xmg_state_get PROXY_VLESS_CERT_SOURCE)" "acme"
OUT_ACME="$(xmg_proxy_status 2>&1)"
t_contains "status 正确展示 acme 证书来源" "$OUT_ACME" "证书: acme"

# ------------------------------------------------------------------
# 恢复环境
# ------------------------------------------------------------------
XMG_ETC_DIR="$_TP_SAVED_ETC"
XMG_XRAY_STATE_DIR="$_TP_SAVED_STATE_DIR"
XMG_STATE_FILE="$_TP_SAVED_STATE_FILE"
XMG_LOG_DIR="$_TP_SAVED_LOG_DIR"
XMG_BACKUP_DIR="$_TP_SAVED_BACKUP_DIR"
XMG_XRAY_CONFIG="$_TP_SAVED_XRAY_CONFIG"
[ -n "$_TP_HAS_ETC" ] || unset XMG_ETC_DIR
[ -n "$_TP_HAS_STATE_DIR" ] || unset XMG_XRAY_STATE_DIR
[ -n "$_TP_HAS_STATE_FILE" ] || unset XMG_STATE_FILE
[ -n "$_TP_HAS_LOG_DIR" ] || unset XMG_LOG_DIR
[ -n "$_TP_HAS_BACKUP_DIR" ] || unset XMG_BACKUP_DIR
[ -n "$_TP_HAS_XRAY_CONFIG" ] || unset XMG_XRAY_CONFIG
if [ -n "$_TP_HAS_CFG_CMD" ]; then XMG_XRAY_CONFIG_TESTCMD="$_TP_SAVED_CFG_CMD"; else unset XMG_XRAY_CONFIG_TESTCMD; fi
if [ -n "$_TP_HAS_RELOAD_CMD" ]; then XMG_XRAY_RELOAD_TESTCMD="$_TP_SAVED_RELOAD_CMD"; else unset XMG_XRAY_RELOAD_TESTCMD; fi
if [ -n "$_TP_HAS_TEST_MODE" ]; then XMG_TEST_MODE="$_TP_SAVED_TEST_MODE"; else unset XMG_TEST_MODE; fi
if [ -n "$_TP_HAS_NO_RELOAD" ]; then XMG_PROXY_NO_RELOAD="$_TP_SAVED_NO_RELOAD"; else unset XMG_PROXY_NO_RELOAD; fi
unset _TP_HAS_ETC _TP_HAS_STATE_DIR _TP_HAS_STATE_FILE _TP_HAS_LOG_DIR
unset _TP_HAS_BACKUP_DIR _TP_HAS_XRAY_CONFIG _TP_HAS_CFG_CMD _TP_HAS_RELOAD_CMD
unset _TP_HAS_TEST_MODE _TP_HAS_NO_RELOAD
unset _TP_SAVED_ETC _TP_SAVED_STATE_DIR _TP_SAVED_STATE_FILE _TP_SAVED_LOG_DIR
unset _TP_SAVED_BACKUP_DIR _TP_SAVED_XRAY_CONFIG _TP_SAVED_CFG_CMD _TP_SAVED_RELOAD_CMD
unset _TP_SAVED_TEST_MODE _TP_SAVED_NO_RELOAD
# XMG_STATE 是 state.sh 的全局关联数组，本用例改过它；清空让下一个用例重新填充。
XMG_STATE=()
# 不 unset XMG_TMP：文件头 EXIT trap 会在退出时引用它（set -u 下会报错）。
unset BEFORE SBEFORE CFG GOOD SGOOD CFG2 OUT JOUT EOUT CERT KEY
