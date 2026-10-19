#!/usr/bin/env bash
# shellcheck shell=bash
#
# test_render_extreme.sh - 极端边界与 WARP 出站原生渲染测试
#
# 测试重点：
#   1. streamSettings 内部统一规范为 "network": "xhttp"（官方标准）；
#   2. 纯 Bash 渲染器在特殊/控制字符输入下的安全转义与合法 JSON 输出；
#   3. 数字型字段为空/非法时的合理兜底，绝不产生裸逗号或语法损毁；
#   4. WARP_ENABLED=1 时在 outbounds 中原生注入 WireGuard warp-out，且 global 模式置首。

_TRE_HAS_ETC="${XMG_ETC_DIR+x}"
_TRE_HAS_STATE_DIR="${XMG_XRAY_STATE_DIR+x}"
_TRE_HAS_STATE_FILE="${XMG_STATE_FILE+x}"
_TRE_HAS_LOG_DIR="${XMG_LOG_DIR+x}"

_TRE_SAVED_ETC="${XMG_ETC_DIR-}"
_TRE_SAVED_STATE_DIR="${XMG_XRAY_STATE_DIR-}"
_TRE_SAVED_STATE_FILE="${XMG_STATE_FILE-}"
_TRE_SAVED_LOG_DIR="${XMG_LOG_DIR-}"

XMG_TMP="$(TMPDIR=/tmp mktemp -d)"
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"

# shellcheck source=../../lib/state.sh
source "$TESTS_DIR/../lib/state.sh"
# shellcheck source=../../lib/render.sh
source "$TESTS_DIR/../lib/render.sh"

mkdir -p "$XMG_LOG_DIR" "$XMG_XRAY_STATE_DIR"
xmg_state_init

_is_valid_json() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$1" | jq . >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$1" | python3 -c 'import sys, json; json.load(sys.stdin)' >/dev/null 2>&1
    else
        return 0
    fi
}

# ============================================================================
# 1. 协议规范：streamSettings 必须为 "network": "xhttp"，不为 "method": "xhttp"
# ============================================================================
out_bash="$(_xmg_render_config_bash 0 1 "/opt/xmg/log/error.log" 4 false "0.0.0.0" 1080 "" "" false "0.0.0.0" 443 "example.com" "11111111-1111-1111-1111-111111111111" "/xhttp" "auto" "/cert.crt" "/priv.key")"

t_contains "Bash 渲染器输出 streamSettings 包含 network: xhttp" "$out_bash" '"network": "xhttp"'
t_not_contains "Bash 渲染器输出 streamSettings 绝不包含 method: xhttp" "$out_bash" '"method": "xhttp"'

if command -v jq >/dev/null 2>&1; then
    out_jq="$(xmg_render_config 0 1)"
    t_contains "jq 渲染器输出 streamSettings 包含 network: xhttp" "$out_jq" '"network": "xhttp"'
    t_not_contains "jq 渲染器输出 streamSettings 绝不包含 method: xhttp" "$out_jq" '"method": "xhttp"'
fi

# ============================================================================
# 2. 极端特殊与控制字符转义测试 (纯 Bash 渲染)
# ============================================================================
extreme_user=$(printf "user\"with\\quotes and \\\\slashes and \b\f")
extreme_pass=$(printf "pass\twith\nnewlines\rand\x01\x07\x1b\x1fctrl")
extreme_domain=$(printf "domain\\\"test\\\\foo")
extreme_path=$(printf "/path\x02\x1etest")

out_extreme="$(_xmg_render_config_bash 1 1 "/opt/xmg/log/error.log" 4 false "0.0.0.0" 1080 "$extreme_user" "$extreme_pass" false "0.0.0.0" 443 "$extreme_domain" "11111111-1111-1111-1111-111111111111" "$extreme_path" "auto" "/cert.crt" "/priv.key")"

t_assert "极端控制字符输入经纯 Bash 渲染后为合法 JSON" _is_valid_json "$out_extreme"

# ============================================================================
# 3. 数字型字段为空/非法时的合理兜底与防裸逗号测试
# ============================================================================
out_num="$(_xmg_render_config_bash 1 1 "/opt/xmg/log/error.log" "" false "0.0.0.0" "" "user" "pass" false "0.0.0.0" "" "example.com" "11111111-1111-1111-1111-111111111111" "/" "auto" "/c" "/k")"

t_not_contains "绝不输出裸逗号 port: ," "$out_num" '"port": ,'
t_not_contains "绝不输出裸逗号 bufferSize: ," "$out_num" '"bufferSize": ,'
t_contains "bufferSize 为空安全兜底为 4" "$out_num" '"bufferSize": 4'
t_contains "SOCKS 端口为空安全兜底为 1080" "$out_num" '"port": 1080'
t_contains "VLESS 端口为空安全兜底为 443" "$out_num" '"port": 443'
t_assert "数字保底兜底后 JSON 语法完全合法" _is_valid_json "$out_num"

# ============================================================================
# 4. WARP 原生出站注入 (WARP_ENABLED=1)
# ============================================================================
xmg_state_set WARP_ENABLED 1
xmg_state_set WARP_MODE global
xmg_state_set WARP_ENDPOINT "162.159.192.1:2408"
xmg_state_set WARP_PRIVATE_KEY "test_private_key_abc="
xmg_state_set WARP_PUBLIC_KEY "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
xmg_state_set WARP_IPV4 "172.16.0.2"
xmg_state_set WARP_IPV6 "2606:4700:110:8f6a::"
xmg_state_set WARP_RESERVED "[230, 19, 10]"

# 4.1 global 模式：warp-out 必须置于 outbounds 首位 (在 direct 之前)
out_warp_global="$(xmg_render_config 0 1)"

t_contains "全局模式注入 tag: warp-out" "$out_warp_global" '"tag": "warp-out"'
t_contains "全局模式注入 protocol: wireguard" "$out_warp_global" '"protocol": "wireguard"'
t_contains "包含指定 secretKey" "$out_warp_global" '"secretKey": "test_private_key_abc="'
t_contains "包含握手保留字节 key reserved" "$out_warp_global" '"reserved"'
t_contains "包含握手保留字节数值 230" "$out_warp_global" '230'
t_contains "包含握手保留字节数值 19" "$out_warp_global" '19'
t_contains "包含握手保留字节数值 10" "$out_warp_global" '10'
t_contains "包含对端 endpoint" "$out_warp_global" '"endpoint": "162.159.192.1:2408"'

warp_pos="$(printf '%s' "$out_warp_global" | grep -n '"tag": "warp-out"' | head -1 | cut -d: -f1)"
direct_pos="$(printf '%s' "$out_warp_global" | grep -n '"tag": "direct"' | head -1 | cut -d: -f1)"
t_assert "global 模式下 warp-out 置于首位 (在 direct 之前)" test "$warp_pos" -lt "$direct_pos"
t_assert "WARP global 产物为合法 JSON" _is_valid_json "$out_warp_global"

# 测试纯 Bash 渲染器生成 warp-out 且 reserved 数组紧凑格式
out_warp_bash="$(_xmg_render_config_bash 0 1 "/opt/xmg/log/error.log" 4 false "0.0.0.0" 1080 "" "" false "0.0.0.0" 443 "example.com" "11111111-1111-1111-1111-111111111111" "/xhttp" "auto" "/cert.crt" "/priv.key" 1 global "162.159.192.1:2408" "test_private_key_abc=" "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=" "172.16.0.2" "2606:4700:110:8f6a::" "[230, 19, 10]")"
t_contains "纯 Bash 渲染器输出包含 reserved" "$out_warp_bash" '"reserved": [230, 19, 10]'
t_assert "纯 Bash 渲染器输出合法 JSON" _is_valid_json "$out_warp_bash"

# 4.2 routing 模式：warp-out 置于 direct 之后，并注入 routing 规则
xmg_state_set WARP_MODE routing
out_warp_routing="$(xmg_render_config 0 1)"

warp_r_pos="$(printf '%s' "$out_warp_routing" | grep -n '"tag": "warp-out"' | head -1 | cut -d: -f1)"
direct_r_pos="$(printf '%s' "$out_warp_routing" | grep -n '"tag": "direct"' | head -1 | cut -d: -f1)"
t_assert "routing 模式下 warp-out 置于 direct 之后" test "$direct_r_pos" -lt "$warp_r_pos"
t_contains "routing 模式下生成 routing 分流规则" "$out_warp_routing" '"routing"'
t_contains "routing 规则命中 warp-out" "$out_warp_routing" '"outboundTag": "warp-out"'
t_assert "WARP routing 产物为合法 JSON" _is_valid_json "$out_warp_routing"

# 4.3 禁用 WARP 状态
xmg_state_set WARP_ENABLED 0
out_no_warp="$(xmg_render_config 0 1)"
t_not_contains "WARP_ENABLED=0 时不注入 warp-out" "$out_no_warp" 'warp-out'
t_assert "WARP 停用产物为合法 JSON" _is_valid_json "$out_no_warp"

# ============================================================================
# 环境清理与恢复
# ============================================================================
rm -rf "$XMG_TMP" 2>/dev/null || true
XMG_ETC_DIR="$_TRE_SAVED_ETC"
XMG_XRAY_STATE_DIR="$_TRE_SAVED_STATE_DIR"
XMG_STATE_FILE="$_TRE_SAVED_STATE_FILE"
XMG_LOG_DIR="$_TRE_SAVED_LOG_DIR"
[ -n "$_TRE_HAS_ETC" ] || unset XMG_ETC_DIR
[ -n "$_TRE_HAS_STATE_DIR" ] || unset XMG_XRAY_STATE_DIR
[ -n "$_TRE_HAS_STATE_FILE" ] || unset XMG_STATE_FILE
[ -n "$_TRE_HAS_LOG_DIR" ] || unset XMG_LOG_DIR
