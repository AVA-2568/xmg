#!/usr/bin/env bash
# 客户端分享链接结构测试（VLESS URI / REALITY / 百分号编码 / NAT 外部端口）
# shellcheck shell=bash

SRC="$TESTS_DIR/.."

_SL_SAVED_HOME="${XMG_HOME-}"
_SL_SAVED_ETC="${XMG_ETC_DIR-}"
_SL_SAVED_STATE="${XMG_STATE_FILE-}"
_SL_SAVED_LIB="${XMG_LIB_DIR-}"

_SL_TMP="$(mktemp -d)"
mkdir -p "$_SL_TMP/etc/xray"

export XMG_HOME="$_SL_TMP"
export XMG_ETC_DIR="$_SL_TMP/etc"
export XMG_XRAY_STATE_DIR="$_SL_TMP/etc/xray"
export XMG_STATE_FILE="$_SL_TMP/etc/xray/state.env"
export XMG_LIB_DIR="$SRC/lib"

# shellcheck source=/dev/null
source "$SRC/lib/common.sh"
# shellcheck source=/dev/null
source "$SRC/lib/state.sh"
# shellcheck source=/dev/null
source "$SRC/lib/render.sh"
# shellcheck source=/dev/null
source "$SRC/lib/proxy.sh"

# --- 1. 百分号编码（RFC 3986）---
t_equals "路径编码" "$(_xmg_urlencode '/xhttp')" "%2Fxhttp"
t_equals "保留字符编码" "$(_xmg_urlencode '/a b?c&d#e')" "%2Fa%20b%3Fc%26d%23e"
t_equals "UTF-8 字节编码" "$(_xmg_urlencode '中文')" "%E4%B8%AD%E6%96%87"
t_equals "非保留字符保持原样" "$(_xmg_urlencode 'aZ0-_.~')" "aZ0-_.~"
t_equals "IPv6 冒号不编码" "$(_xmg_urlencode '2001:db8::1')" "2001:db8::1"

# --- 1.1 私网地址判定与公网地址优先级 ---
t_assert "10.x 判为私网" _xmg_proxy_ip_is_private 10.0.0.1
t_assert "172.16.x 判为私网" _xmg_proxy_ip_is_private 172.16.0.1
t_assert "172.31.x 判为私网" _xmg_proxy_ip_is_private 172.31.255.254
t_assert "192.168.x 判为私网" _xmg_proxy_ip_is_private 192.168.1.1
t_assert "100.64.x (CGNAT) 判为私网" _xmg_proxy_ip_is_private 100.64.0.1
t_assert "fe80:: 判为私网" _xmg_proxy_ip_is_private fe80::1
t_assert "fd00::/8 ULA 判为私网" _xmg_proxy_ip_is_private fd12:3456::1
_pub_state="public"
if _xmg_proxy_ip_is_private 203.0.113.9; then _pub_state="private"; fi
t_equals "公网 IPv4 不判私网" "$_pub_state" "public"
_dom_state="public"
if _xmg_proxy_ip_is_private node.example.com; then _dom_state="private"; fi
t_equals "域名不判私网" "$_dom_state" "public"

cat > "$XMG_STATE_FILE" <<'EOF'
PROXY_PUBLIC_HOST=203.0.113.7
EOF
xmg_state_load
t_equals "公网地址优先取 state 声明" "$(_xmg_proxy_server_host)" "203.0.113.7"

cat > "$XMG_STATE_FILE" <<'EOF'
PROXY_PUBLIC_HOST=[2001:db8::7]
EOF
xmg_state_load
t_equals "state 公网地址去掉 IPv6 方括号" "$(_xmg_proxy_server_host)" "2001:db8::7"

# --- 2. VLESS + XHTTP + TLS 链接 ---
cat > "$XMG_STATE_FILE" <<'EOF'
PROXY_VLESS_ENABLED=1
PROXY_VLESS_PORT=443
PROXY_VLESS_DOMAIN=example.com
PROXY_VLESS_UUID=11111111-2222-3333-4444-555555555555
PROXY_VLESS_PATH=/x y?z&k#
PROXY_VLESS_MODE=auto
PROXY_VLESS_CERT_SOURCE=acme
PROXY_VLESS_EXTERNAL_PORT=20001
EOF
xmg_state_load

_VLINK="$(xmg_proxy_vless_link 2>/dev/null)"
_CDN="$(printf '%s\n' "$_VLINK" | grep '^vless://.*#XMG-VLESS-CDN$' || true)"
_DIRECT="$(printf '%s\n' "$_VLINK" | grep '^vless://.*#XMG-VLESS-Direct$' || true)"

t_contains "CDN 链接以 vless:// 开头" "$_CDN" "vless://11111111-2222-3333-4444-555555555555@example.com:443?"
t_contains "CDN 链接走 TLS" "$_CDN" "security=tls"
t_contains "CDN 链接声明 XHTTP" "$_CDN" "type=xhttp"
t_contains "CDN 链接携带 Host" "$_CDN" "host=example.com"
t_contains "CDN 链接 ALPN 为 h2/http1.1（XHTTP 无 QUIC）" "$_CDN" "alpn=h2%2Chttp%2F1.1"
t_not_contains "CDN 链接不再声明 HTTP/3" "$_CDN" "alpn=h3"

t_contains "直连链接使用外部映射端口" "$_DIRECT" "@example.com:20001?"
t_contains "路径完整百分号编码" "$_DIRECT" "path=%2Fx%20y%3Fz%26k%23"
t_not_contains "链接中不出现原始空格" "$_DIRECT" " "
t_not_contains "ACME 证书不降级校验" "$_DIRECT" "allowInsecure=1"

# 用户自签证书（无法判定时按自签处理，保守附带跳过校验）
cat > "$XMG_STATE_FILE" <<'EOF'
PROXY_VLESS_ENABLED=1
PROXY_VLESS_PORT=443
PROXY_VLESS_DOMAIN=example.com
PROXY_VLESS_UUID=11111111-2222-3333-4444-555555555555
PROXY_VLESS_PATH=/xhttp
PROXY_VLESS_CERT_SOURCE=user
PROXY_VLESS_CERT_FILE=/nonexistent/cert.pem
PROXY_VLESS_KEY_FILE=/nonexistent/key.pem
EOF
xmg_state_load
_ULINK="$(xmg_proxy_vless_link 2>/dev/null | grep '^vless://.*#XMG-VLESS-Direct$' || true)"
t_contains "无法判定证书时保守附带 allowInsecure" "$_ULINK" "allowInsecure=1"

# --- 3. VLESS + XHTTP + REALITY 链接 ---
cat > "$XMG_STATE_FILE" <<'EOF'
PROXY_REALITY_ENABLED=1
PROXY_REALITY_PORT=8443
PROXY_REALITY_UUID=11111111-2222-3333-4444-555555555555
PROXY_REALITY_PATH=/r p
PROXY_REALITY_MODE=packet-up
PROXY_REALITY_SNI=www.microsoft.com
PROXY_REALITY_SHORT_ID=ab12
PROXY_REALITY_PRIVATE_KEY=TESTKEY
PROXY_REALITY_PUBLIC_KEY=HZhx5Hg7Zgv2lLe8Ivr3nC8v1FqPHvdKCmUIYcMli8I
PROXY_REALITY_EXTERNAL_PORT=20002
EOF
xmg_state_load

# 固定公网地址，避免用例受真实网卡影响
_xmg_proxy_server_host() { printf '203.0.113.9'; }

_RLINK="$(xmg_proxy_reality_link 2>/dev/null | grep '^vless://' || true)"
t_contains "REALITY 链接使用外部映射端口" "$_RLINK" "@203.0.113.9:20002?"
t_contains "REALITY 安全类型" "$_RLINK" "security=reality"
t_contains "REALITY 携带公钥参数" "$_RLINK" "pbk=HZhx5Hg7Zgv2lLe8Ivr3nC8v1FqPHvdKCmUIYcMli8I"
t_contains "REALITY 携带 shortId" "$_RLINK" "sid=ab12"
t_contains "REALITY 携带 spiderX" "$_RLINK" "spx=%2F"
t_contains "REALITY 声明 XHTTP" "$_RLINK" "type=xhttp"
t_contains "REALITY 路径编码" "$_RLINK" "path=%2Fr%20p"
t_contains "REALITY 模式透传" "$_RLINK" "mode=packet-up"

# IPv6 地址必须加方括号，否则 host:port 解析歧义
_xmg_proxy_server_host() { printf '2001:db8::1'; }
_R6="$(xmg_proxy_reality_link 2>/dev/null | grep '^vless://' || true)"
t_contains "IPv6 主机加方括号" "$_R6" "@[2001:db8::1]:20002?"

# 公钥与私钥都缺失时，不得输出带 <PUBLIC_KEY> 占位符的假链接
cat > "$XMG_STATE_FILE" <<'EOF'
PROXY_REALITY_ENABLED=1
PROXY_REALITY_PORT=8443
PROXY_REALITY_UUID=11111111-2222-3333-4444-555555555555
PROXY_REALITY_PATH=/xhttp
PROXY_REALITY_MODE=auto
PROXY_REALITY_SNI=www.microsoft.com
EOF
xmg_state_load
_MISS_RC=0
_MISS_OUT="$(xmg_proxy_reality_link 2>/dev/null)" || _MISS_RC=$?
t_equals "缺少公钥时链接生成失败" "$_MISS_RC" "1"
t_not_contains "缺公钥时不输出占位符链接" "$_MISS_OUT" "vless://"

# --- 4. 恢复环境 ---
if [ -n "$_SL_SAVED_HOME" ]; then export XMG_HOME="$_SL_SAVED_HOME"; else unset XMG_HOME; fi
if [ -n "$_SL_SAVED_ETC" ]; then export XMG_ETC_DIR="$_SL_SAVED_ETC"; else unset XMG_ETC_DIR; fi
if [ -n "$_SL_SAVED_STATE" ]; then export XMG_STATE_FILE="$_SL_SAVED_STATE"; else unset XMG_STATE_FILE; fi
if [ -n "$_SL_SAVED_LIB" ]; then export XMG_LIB_DIR="$_SL_SAVED_LIB"; else unset XMG_LIB_DIR; fi
rm -rf "$_SL_TMP"
