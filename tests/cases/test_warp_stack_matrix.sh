#!/usr/bin/env bash
# WARP 隧道单栈/双栈矩阵：allowedIPs / remoteDNS / targetStrategy 三者必须同源
# shellcheck shell=bash
#
# 背景（官方 wireguard 出站约束）：
#   1. 隧道内目标必须是 IP，域名靠 remoteDNS 解析，该 DNS 走隧道内部；
#   2. allowedIPs 必须与 address 实际拥有的协议族一致，否则目标找不到 peer；
#   3. targetStrategy 在 OutboundObject 顶层，默认 AsIs 会把解析全压在隧道内 DNS。
#
# 覆盖：纯函数矩阵 7 组 + 两条渲染路径（内建 bash / 模板 jq）+ REALITY 共存。

_MX_HAS_TEST_MODE="${XMG_TEST_MODE+x}"
_MX_SAVED_TEST_MODE="${XMG_TEST_MODE-}"

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT

export XMG_HOME="$XMG_TMP/opt_xmg"
export XMG_LIB_DIR="$TESTS_DIR/../lib"
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_BACKUP_DIR="$XMG_TMP/backups"
export XMG_XRAY_CONFIG="$XMG_TMP/xray/config.json"
export XMG_WARP_DIR="$XMG_TMP/warp_etc"
export XMG_WARP_ACCOUNT_FILE="$XMG_WARP_DIR/account.json"
export XMG_WARP_ENV_FILE="$XMG_WARP_DIR/warp.env"
export XMG_WARP_XRAY_OUTBOUND="$XMG_WARP_DIR/xray_warp.json"

export XMG_TEST_MODE=1
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="true"
export XMG_PROXY_NO_RELOAD=1

mkdir -p "$XMG_WARP_DIR" "$XMG_XRAY_STATE_DIR" "$XMG_BACKUP_DIR" "$(dirname "$XMG_XRAY_CONFIG")"

source "$XMG_LIB_DIR/common.sh"
source "$XMG_LIB_DIR/state.sh"
source "$XMG_LIB_DIR/render.sh"
source "$XMG_LIB_DIR/warp.sh"

# ------------------------------------------------------------------
# 1. 纯函数矩阵：allowedIPs 元素 | remoteDNS 元素 | targetStrategy
#    函数只吐 JSON 元素（不含方括号），由调用方包 []，避免出现 [[...]]
# ------------------------------------------------------------------
_warp_profile_of() {
    _xmg_warp_tunnel_profile "$1" "$2" "$3" 2>/dev/null
}

t_equals "双栈隧道+双栈主机：保留双栈能力" \
    "$(_warp_profile_of 172.16.0.2 2606:4700:110::1 0)" \
    '"0.0.0.0/0", "::/0"|"1.1.1.1", "8.8.8.8"|UseIP'

t_equals "双栈隧道+纯v6主机：强制 v4 才拿得到 WARP 出口" \
    "$(_warp_profile_of 172.16.0.2 2606:4700:110::1 1)" \
    '"0.0.0.0/0", "::/0"|"1.1.1.1", "8.8.8.8"|UseIPv4'

t_equals "仅v4隧道+双栈主机：allowedIPs 收敛且锁死 v4" \
    "$(_warp_profile_of 172.16.0.2 "" 0)" \
    '"0.0.0.0/0"|"1.1.1.1", "8.8.8.8"|UseIPv4'

t_equals "仅v4隧道+纯v6主机：同上" \
    "$(_warp_profile_of 172.16.0.2 "" 1)" \
    '"0.0.0.0/0"|"1.1.1.1", "8.8.8.8"|UseIPv4'

t_equals "仅v6隧道+双栈主机：remoteDNS 切 v6 且不带方括号" \
    "$(_warp_profile_of "" 2606:4700:110::1 0)" \
    '"::/0"|"2606:4700:4700::1111", "2001:4860:4860::8888"|UseIPv6'

t_equals "仅v6隧道+纯v6主机：同上" \
    "$(_warp_profile_of "" 2606:4700:110::1 1)" \
    '"::/0"|"2606:4700:4700::1111", "2001:4860:4860::8888"|UseIPv6'

_mx_rc=0
_xmg_warp_tunnel_profile '' '' 0 >/dev/null 2>&1 || _mx_rc=$?
t_equals "空隧道（无任何地址族）必须拒绝生成出站" "$_mx_rc" "1"

# ------------------------------------------------------------------
# 2. 渲染路径：内建 bash 与模板 jq 必须产出一致结论
# ------------------------------------------------------------------
declare -A XMG_STATE_STAGE=()
XMG_STATE_STAGE[WARP_ENABLED]=1
XMG_STATE_STAGE[WARP_MODE]=global
XMG_STATE_STAGE[WARP_PRIVATE_KEY]="yAn0MockPrivateKeyBase64ForTestOnly12345678="
XMG_STATE_STAGE[WARP_PUBLIC_KEY]="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
XMG_STATE_STAGE[WARP_IPV4]="172.16.0.2"
XMG_STATE_STAGE[WARP_IPV6]="2606:4700:110::1"
XMG_STATE_STAGE[WARP_ENDPOINT]="162.159.192.1:2408"
XMG_STATE_STAGE[WARP_RESERVED]="[0, 0, 0]"
XMG_STATE_STAGE[PROXY_SOCKS_ENABLED]=0
XMG_STATE_STAGE[PROXY_VLESS_ENABLED]=0
XMG_STATE_STAGE[PROXY_REALITY_ENABLED]=1
XMG_STATE_STAGE[PROXY_REALITY_PORT]=8443
XMG_STATE_STAGE[PROXY_REALITY_UUID]="11111111-2222-3333-4444-555555555555"
XMG_STATE_STAGE[PROXY_REALITY_PRIVATE_KEY]="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
XMG_STATE_STAGE[PROXY_REALITY_SNI]="www.microsoft.com"
XMG_STATE_STAGE[PROXY_REALITY_DEST]="www.microsoft.com:443"
XMG_STATE_STAGE[PROXY_REALITY_SHORT_ID]="aa1234"

export XMG_NET_IPV4=1
export XMG_NET_IPV6=1
unset XMG_NET_STACK

for _mx_path in bash jq; do
    if [ "$_mx_path" = "jq" ]; then
        export XMG_CONFIG_TEMPLATE="$TESTS_DIR/../templates/config.template.json"
    else
        unset XMG_CONFIG_TEMPLATE
    fi

    _mx_cfg="$(xmg_render_config 0 0 2>/dev/null)"

    t_assert "[$_mx_path] 渲染结果必须是合法 JSON" \
        "printf '%s' \"\$_mx_cfg\" | jq -e . >/dev/null"

    t_equals "[$_mx_path] 双栈主机+双栈隧道 targetStrategy=UseIP" \
        "$(printf '%s' "$_mx_cfg" | jq -r '.outbounds[]? | select(.tag=="warp-out") | .targetStrategy')" \
        "UseIP"

    t_equals "[$_mx_path] 双栈隧道 allowedIPs 全量且不下套数组" \
        "$(printf '%s' "$_mx_cfg" | jq -c '.outbounds[]? | select(.tag=="warp-out") | .settings.peers[0].allowedIPs')" \
        '["0.0.0.0/0","::/0"]'

    t_equals "[$_mx_path] remoteDNS 必须显式下发（否则域名全压在隧道内 DNS）" \
        "$(printf '%s' "$_mx_cfg" | jq -c '.outbounds[]? | select(.tag=="warp-out") | .settings.remoteDNS')" \
        '["1.1.1.1","8.8.8.8"]'

    t_equals "[$_mx_path] freedom finalRules 必须有兜底 allow" \
        "$(printf '%s' "$_mx_cfg" | jq -c '.outbounds[]? | select(.tag=="direct") | .settings.finalRules[-1]')" \
        '{"action":"allow"}'

    t_assert "[$_mx_path] REALITY 入站在开启 WARP 后必须完好保留" \
        "printf '%s' \"\$_mx_cfg\" | jq -e '.inbounds[]? | select(.streamSettings.security==\"reality\")' >/dev/null"

    t_equals "[$_mx_path] REALITY 回落 target 不受 WARP 影响（服务端字段原样下发）" \
        "$(printf '%s' "$_mx_cfg" | jq -r '.inbounds[]? | select(.streamSettings.security=="reality") | .streamSettings.realitySettings.target')" \
        "www.microsoft.com:443"
done
unset XMG_CONFIG_TEMPLATE

# ------------------------------------------------------------------
# 3. 仅 v4 隧道：allowedIPs 必须收敛，不能声明 ::/0
# ------------------------------------------------------------------
XMG_STATE_STAGE[WARP_IPV6]=""
_mx_cfg="$(xmg_render_config 0 0 2>/dev/null)"
t_equals "仅v4隧道 allowedIPs 不含 ::/0" \
    "$(printf '%s' "$_mx_cfg" | jq -c '.outbounds[]? | select(.tag=="warp-out") | .settings.peers[0].allowedIPs')" \
    '["0.0.0.0/0"]'
t_equals "仅v4隧道 targetStrategy 锁死 UseIPv4" \
    "$(printf '%s' "$_mx_cfg" | jq -r '.outbounds[]? | select(.tag=="warp-out") | .targetStrategy')" \
    "UseIPv4"

# ------------------------------------------------------------------
# 4. 其他方案共存：SOCKS5 / VLESS+TLS / REALITY 共用同一个 warp-out
#    修复位于出站层，与入站协议无关，三类方案必须一视同仁
# ------------------------------------------------------------------
XMG_STATE_STAGE[WARP_IPV6]="2606:4700:110::1"
XMG_STATE_STAGE[PROXY_SOCKS_ENABLED]=1
XMG_STATE_STAGE[PROXY_SOCKS_PORT]=1080
XMG_STATE_STAGE[PROXY_SOCKS_USER]=u
XMG_STATE_STAGE[PROXY_SOCKS_PASS]=p
XMG_STATE_STAGE[PROXY_VLESS_ENABLED]=1
XMG_STATE_STAGE[PROXY_VLESS_PORT]=443
XMG_STATE_STAGE[PROXY_VLESS_DOMAIN]=example.com
XMG_STATE_STAGE[PROXY_VLESS_UUID]="11111111-2222-3333-4444-555555555555"
XMG_STATE_STAGE[PROXY_VLESS_CERT_FILE]="$XMG_TMP/c.crt"
XMG_STATE_STAGE[PROXY_VLESS_KEY_FILE]="$XMG_TMP/k.key"
echo c > "$XMG_TMP/c.crt"
echo k > "$XMG_TMP/k.key"

_mx_cfg="$(xmg_render_config 1 1 2>/dev/null)"

t_equals "三入站共存时 warp-out 仍然只有一份" \
    "$(printf '%s' "$_mx_cfg" | jq '[.outbounds[]? | select(.tag=="warp-out")] | length')" "1"

t_equals "三入站共存时 warp-out 保持默认出站（首位）" \
    "$(printf '%s' "$_mx_cfg" | jq -r '.outbounds[0].tag')" "warp-out"

t_equals "SOCKS5 入站未受出站改动影响" \
    "$(printf '%s' "$_mx_cfg" | jq -r '.inbounds[] | select(.tag=="inbound-socks") | .protocol')" "socks"

t_equals "VLESS+XHTTP+TLS 入站未受出站改动影响" \
    "$(printf '%s' "$_mx_cfg" | jq -r '.inbounds[] | select(.tag=="inbound-vless") | .streamSettings.security')" "tls"

t_equals "REALITY 入站未受出站改动影响" \
    "$(printf '%s' "$_mx_cfg" | jq -r '.inbounds[] | select(.tag=="inbound-reality") | .streamSettings.security')" "reality"

t_equals "routing 未按入站排除任何方案" \
    "$(printf '%s' "$_mx_cfg" | jq '[.routing.rules[]? | select(.inboundTag != null)] | length')" "0"

# 分流模式：direct 才是默认出站，warp-out 仅接指定域名，两边都不能丢字段
XMG_STATE_STAGE[WARP_MODE]=routing
_mx_cfg="$(xmg_render_config 1 1 2>/dev/null)"

t_equals "分流模式默认出站是 direct" \
    "$(printf '%s' "$_mx_cfg" | jq -r '.outbounds[0].tag')" "direct"

t_equals "分流模式 warp-out 仍带 targetStrategy" \
    "$(printf '%s' "$_mx_cfg" | jq -r '.outbounds[]? | select(.tag=="warp-out") | .targetStrategy')" "UseIP"

t_equals "分流模式 warp-out 仍带 remoteDNS" \
    "$(printf '%s' "$_mx_cfg" | jq -c '.outbounds[]? | select(.tag=="warp-out") | .settings.remoteDNS')" \
    '["1.1.1.1","8.8.8.8"]'

t_equals "分流模式 direct 仍带兜底 allow" \
    "$(printf '%s' "$_mx_cfg" | jq -c '.outbounds[]? | select(.tag=="direct") | .settings.finalRules[-1]')" \
    '{"action":"allow"}'

XMG_STATE_STAGE[WARP_MODE]=global

# 归还测试环境
declare -A XMG_STATE_STAGE=()
if [ -z "$_MX_HAS_TEST_MODE" ]; then
    unset XMG_TEST_MODE
else
    export XMG_TEST_MODE="$_MX_SAVED_TEST_MODE"
fi
