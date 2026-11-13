#!/usr/bin/env bash
# 纯 IPv6 环境下 WARP 模块与配置渲染回归测试
# shellcheck shell=bash

_TV6_TMP="$(mktemp -d)"
trap 'rm -rf "$_TV6_TMP"' EXIT

export XMG_HOME="$_TV6_TMP/opt_xmg"
export XMG_LIB_DIR="$TESTS_DIR/../lib"
export XMG_ETC_DIR="$_TV6_TMP/etc"
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$_TV6_TMP/log"
export XMG_BACKUP_DIR="$_TV6_TMP/backups"
export XMG_XRAY_CONFIG="$_TV6_TMP/xray/config.json"
export XMG_WARP_DIR="$_TV6_TMP/warp_etc"
export XMG_WARP_ACCOUNT_FILE="$XMG_WARP_DIR/account.json"
export XMG_WARP_ENV_FILE="$XMG_WARP_DIR/warp.env"
export XMG_WARP_XRAY_OUTBOUND="$XMG_WARP_DIR/xray_warp.json"

export XMG_TEST_MODE=1
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="true"
export XMG_PROXY_NO_RELOAD=1

mkdir -p "$XMG_WARP_DIR" "$XMG_XRAY_STATE_DIR" "$XMG_BACKUP_DIR" "$(dirname "$XMG_XRAY_CONFIG")"

source "$XMG_LIB_DIR/common.sh"
source "$XMG_LIB_DIR/detect.sh"
source "$XMG_LIB_DIR/state.sh"
source "$XMG_LIB_DIR/render.sh"
source "$XMG_LIB_DIR/warp.sh"

xmg_require_root() { return 0; }

# 1. _xmg_warp_clean_ipv6 不得误删末组 :0
t_equals "_xmg_warp_clean_ipv6 保留末组 :0" \
    "$(_xmg_warp_clean_ipv6 "2606:4700:110:8586:139e:b183:8c01:0/128")" \
    "2606:4700:110:8586:139e:b183:8c01:0"

# 2. _xmg_warp_norm_endpoint_v6 规范化各种写法
t_equals "规范化 [ipv6]:0 为 :2408" \
    "$(_xmg_warp_norm_endpoint_v6 "[2606:4700:d0::a29f:c001]:0")" \
    "[2606:4700:d0::a29f:c001]:2408"
t_equals "规范化无括号 ipv6:0 为 [ipv6]:2408" \
    "$(_xmg_warp_norm_endpoint_v6 "2606:4700:d0::a29f:c001:0")" \
    "[2606:4700:d0::a29f:c001]:2408"
t_equals "规范化无括号 ipv6:2408 为 [ipv6]:2408" \
    "$(_xmg_warp_norm_endpoint_v6 "2606:4700:d0::a29f:c001:2408")" \
    "[2606:4700:d0::a29f:c001]:2408"

# 3. xmg_warp_is_ipv6_only 必须识别 XMG_NET_IPV4=0 / XMG_NET_IPV6=1（以及 xmg_detect_network 结果）
unset XMG_MOCK_WARP_STACK XMG_NET_STACK
export XMG_NET_IPV4=0
export XMG_NET_IPV6=1
t_assert "预设 XMG_NET_IPV4=0/IPV6=1 时判定为纯 IPv6" xmg_warp_is_ipv6_only

unset XMG_NET_IPV4 XMG_NET_IPV6
xmg_detect_network() {
    XMG_NET_IPV4=0
    XMG_NET_IPV6=1
    XMG_NET_NAT=0
    XMG_NET_NAT64=0
    export XMG_NET_IPV4 XMG_NET_IPV6 XMG_NET_NAT XMG_NET_NAT64
}
t_assert "未预设变量时通过 xmg_detect_network 判定为纯 IPv6" xmg_warp_is_ipv6_only
t_equals "判定后保留探测出的 XMG_NET_IPV4=0" "${XMG_NET_IPV4:-}" "0"
t_equals "判定后保留探测出的 XMG_NET_IPV6=1" "${XMG_NET_IPV6:-}" "1"

# 4. 纯 IPv6 机启用 routing 模式（事先未设置 XMG_NET_IPV4/6，且旧配置为 UseIPv6 + IPv4 DoH）
unset XMG_NET_IPV4 XMG_NET_IPV6
export XMG_MOCK_WARP_PRIVKEY="yAn0MockPrivateKeyBase64ForTestOnly12345678="
export XMG_MOCK_WARP_PUBKEY="zBn0MockPublicKeyBase64ForTestOnly123456789="
export XMG_MOCK_WARP_API_RESP='{
  "id": "e44d5c6b-7a8b-4c0d-9e1f-2a3b4c5d6e7f",
  "token": "secret_token",
  "config": {
    "client_id": "5hMK",
    "interface": {
      "addresses": {
        "v4": "172.16.0.2",
        "v6": "2606:4700:110:8586:139e:b183:8c01:0"
      }
    },
    "peers": [
      {
        "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
        "endpoint": {
          "v4": "162.159.192.1:0",
          "v6": "2606:4700:d0::a29f:c001:0"
        }
      }
    ]
  }
}'

cat > "$XMG_XRAY_CONFIG" <<'JSON'
{
  "dns": {
    "servers": ["https+local://1.1.1.1/dns-query", "localhost"],
    "queryStrategy": "UseIPv6"
  },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "streamSettings": { "sockopt": { "domainStrategy": "UseIPv6" } }
    },
    { "tag": "blocked", "protocol": "blackhole", "settings": {} }
  ]
}
JSON

xmg_state_init
t_assert "纯 IPv6 启用 routing 模式成功" xmg_warp_enable routing off

t_equals "纯 IPv6 routing 模式 warp-out 使用 IPv6 endpoint" \
    "$(jq -r '.outbounds[] | select(.tag=="warp-out") | .settings.peers[0].endpoint' "$XMG_XRAY_CONFIG")" \
    "[2606:4700:d0::a29f:c001]:2408"

t_equals "纯 IPv6 routing 模式 warp-out targetStrategy=UseIPv4" \
    "$(jq -r '.outbounds[] | select(.tag=="warp-out") | .targetStrategy' "$XMG_XRAY_CONFIG")" \
    "UseIPv4"

t_equals "纯 IPv6 routing 模式 dns.queryStrategy 放开为 UseIP" \
    "$(jq -r '.dns.queryStrategy' "$XMG_XRAY_CONFIG")" \
    "UseIP"

t_equals "纯 IPv6 routing 模式直连 DoH 自动切为 IPv6" \
    "$(jq -r '[.dns.servers[] | select(test("2606:4700:4700::1111"))] | length' "$XMG_XRAY_CONFIG")" \
    "1"

t_equals "纯 IPv6 routing 模式 direct 出站保持 UseIPv6" \
    "$(jq -r '.outbounds[] | select(.tag=="direct") | .streamSettings.sockopt.domainStrategy' "$XMG_XRAY_CONFIG")" \
    "UseIPv6"

t_equals "纯 IPv6 routing 模式域名规则挂 0.0.0.0/0 条件" \
    "$(jq -c '[.routing.rules[] | select(.outboundTag=="warp-out" and (.domain != null)) | .ip][0]' "$XMG_XRAY_CONFIG")" \
    '["0.0.0.0/0"]'

t_equals "纯 IPv6 routing 模式全量 IPv4 兜底走 WARP" \
    "$(jq -c '[.routing.rules[] | select(.outboundTag=="warp-out" and (.domain == null)) | .ip][0]' "$XMG_XRAY_CONFIG")" \
    '["0.0.0.0/0"]'

# 5. render.sh（bash 与 jq 双路径）在纯 IPv6 机下若残留 IPv4 endpoint 应自动纠正为 IPv6 endpoint
export XMG_NET_IPV4=0
export XMG_NET_IPV6=1
xmg_state_stage WARP_ENABLED 1
xmg_state_stage WARP_MODE routing
xmg_state_stage WARP_ENDPOINT "162.159.192.1:2408"
xmg_state_stage WARP_IPV4 "172.16.0.2"
xmg_state_stage WARP_IPV6 "2606:4700:110::1"

for _p in bash jq; do
    if [ "$_p" = "jq" ]; then
        export XMG_CONFIG_TEMPLATE="$TESTS_DIR/../templates/config.template.json"
    else
        unset XMG_CONFIG_TEMPLATE
    fi
    _rcfg="$(xmg_render_config 0 0 2>/dev/null)"
    t_equals "[$_p] 纯 IPv6 渲染自动纠正 IPv4 endpoint 为 IPv6" \
        "$(printf '%s' "$_rcfg" | jq -r '.outbounds[] | select(.tag=="warp-out") | .settings.peers[0].endpoint')" \
        "[2606:4700:d0::a29f:c001]:2408"
    t_equals "[$_p] 纯 IPv6 routing 渲染 dns.queryStrategy=UseIP" \
        "$(printf '%s' "$_rcfg" | jq -r '.dns.queryStrategy')" \
        "UseIP"
    t_equals "[$_p] 纯 IPv6 routing 渲染 direct.domainStrategy=UseIPv6" \
        "$(printf '%s' "$_rcfg" | jq -r '.outbounds[] | select(.tag=="direct") | .streamSettings.sockopt.domainStrategy')" \
        "UseIPv6"
done
unset XMG_CONFIG_TEMPLATE

# 6. 重复启用 routing 模式保持规则幂等，不重复追加私有网段直连规则；停用后彻底清理
t_assert "纯 IPv6 重复启用 routing 模式成功" xmg_warp_enable routing off
t_equals "重复启用 routing 后规则数保持 3 条（无重复）" \
    "$(jq '.routing.rules | length' "$XMG_XRAY_CONFIG")" \
    "3"

t_assert "纯 IPv6 停用 WARP 成功" xmg_warp_disable
t_equals "停用后私有网段直连兜底规则已一并清理" \
    "$(jq '.routing.rules | length' "$XMG_XRAY_CONFIG")" \
    "0"
t_equals "停用后 dns.queryStrategy 收回 UseIPv6" \
    "$(jq -r '.dns.queryStrategy' "$XMG_XRAY_CONFIG")" \
    "UseIPv6"

# 7. 所有入站（SOCKS / VLESS / REALITY）在 bash 与 jq 两条路径下均启用 sniffing (routeOnly=true)
xmg_state_stage PROXY_SOCKS_ENABLED 1
xmg_state_stage PROXY_SOCKS_PORT 1080
xmg_state_stage PROXY_SOCKS_USER u
xmg_state_stage PROXY_SOCKS_PASS p
xmg_state_stage PROXY_VLESS_ENABLED 1
xmg_state_stage PROXY_VLESS_PORT 443
xmg_state_stage PROXY_VLESS_DOMAIN example.com
xmg_state_stage PROXY_VLESS_UUID "11111111-2222-3333-4444-555555555555"
xmg_state_stage PROXY_VLESS_CERT_FILE "$_TV6_TMP/c.crt"
xmg_state_stage PROXY_VLESS_KEY_FILE "$_TV6_TMP/k.key"
echo c > "$_TV6_TMP/c.crt"
echo k > "$_TV6_TMP/k.key"
xmg_state_stage PROXY_REALITY_ENABLED 1
xmg_state_stage PROXY_REALITY_PORT 8443
xmg_state_stage PROXY_REALITY_UUID "11111111-2222-3333-4444-555555555555"
xmg_state_stage PROXY_REALITY_PRIVATE_KEY "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

for _p in bash jq; do
    if [ "$_p" = "jq" ]; then
        export XMG_CONFIG_TEMPLATE="$TESTS_DIR/../templates/config.template.json"
    else
        unset XMG_CONFIG_TEMPLATE
    fi
    _scfg="$(xmg_render_config 1 1 2>/dev/null)"
    t_equals "[$_p] 3 个入站均启用 sniffing 且 routeOnly=true" \
        "$(printf '%s' "$_scfg" | jq '[.inbounds[] | select(.sniffing.enabled==true and .sniffing.routeOnly==true and (.sniffing.destOverride == ["http","tls","quic"]))] | length')" \
        "3"
done
unset XMG_CONFIG_TEMPLATE

# 8. _xmg_warp_local_socks_proxy_url 正确将 :: 与 0.0.0.0 转为本地回环 socks5h:// 代理 URL
cat > "$_TV6_TMP/socks_v6.json" <<'JSON'
{
  "inbounds": [
    {
      "tag": "inbound-socks",
      "listen": "::",
      "port": 1080,
      "protocol": "socks",
      "settings": { "auth": "password", "users": [{ "user": "u1", "pass": "p1" }] }
    }
  ]
}
JSON
XMG_XRAY_CONFIG="$_TV6_TMP/socks_v6.json"
t_equals "纯 IPv6 :: 监听生成 socks5h://[::1] 代理 URL" \
    "$(_xmg_warp_local_socks_proxy_url)" \
    "socks5h://u1:p1@[::1]:1080"

cat > "$_TV6_TMP/socks_v4.json" <<'JSON'
{
  "inbounds": [
    {
      "tag": "inbound-socks",
      "listen": "0.0.0.0",
      "port": 2080,
      "protocol": "socks",
      "settings": { "auth": "noauth" }
    }
  ]
}
JSON
XMG_XRAY_CONFIG="$_TV6_TMP/socks_v4.json"
t_equals "0.0.0.0 监听生成 socks5h://127.0.0.1 代理 URL" \
    "$(_xmg_warp_local_socks_proxy_url)" \
    "socks5h://127.0.0.1:2080"
XMG_XRAY_CONFIG="$_TV6_TMP/xray/config.json"
