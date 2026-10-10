#!/usr/bin/env bash
# 渲染产物精简校验（Task 12 前的测试瘦身）
#
# 背景：原 test_render_common/vless/config/socks.sh 共 154 条断言，逐字段比对
# 官方文档。用户明确「配置不用测，依据官方文档即可，我会自己测试」，
# 且全量套件在本机（每次断言 fork）耗时逼近运行器上限。
# 故只保留「能挡住静默失效」的最小集合：产物合法性、共存结构、
# 铁律禁止字段、必备字段、streamSettings 归属。字段级明细交给官方文档。
#
# shellcheck shell=bash

# --- 环境隔离 ---
# run.sh 在同一个 shell 里依次 source 多个用例，本用例对全局变量的修改会漏给
# 后面的用例；state.sh/render.sh 又是「加载一次」的。故进出各快照/恢复一次。
_TC_HAS_ETC="${XMG_ETC_DIR+x}"
_TC_HAS_STATE_DIR="${XMG_XRAY_STATE_DIR+x}"
_TC_HAS_STATE_FILE="${XMG_STATE_FILE+x}"
_TC_HAS_LOG_DIR="${XMG_LOG_DIR+x}"
_TC_HAS_XRAY_LOG_DIR="${XMG_XRAY_LOG_DIR+x}"
_TC_HAS_NET_IPV4="${XMG_NET_IPV4+x}"
_TC_HAS_NET_IPV6="${XMG_NET_IPV6+x}"
_TC_SAVED_ETC="${XMG_ETC_DIR-}"
_TC_SAVED_STATE_DIR="${XMG_XRAY_STATE_DIR-}"
_TC_SAVED_STATE_FILE="${XMG_STATE_FILE-}"
_TC_SAVED_LOG_DIR="${XMG_LOG_DIR-}"
_TC_SAVED_XRAY_LOG_DIR="${XMG_XRAY_LOG_DIR-}"
_TC_SAVED_NET_IPV4="${XMG_NET_IPV4-}"
_TC_SAVED_NET_IPV6="${XMG_NET_IPV6-}"

XMG_TMP="$(mktemp -d)"
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"
unset XMG_XRAY_LOG_DIR

# shellcheck source=../../lib/state.sh
source "$TESTS_DIR/../lib/state.sh"
source "$TESTS_DIR/../lib/render.sh"
xmg_state_init

# ============================================================================
# 纯 bash JSON 合法性检查器（零依赖：目标机 0.5C/215MB 无 jq/python）
# 「长得像 JSON」不等于「是合法 JSON」：heredoc 少逗号、字符串落裸控制字符、
# 括号跨块不配对，都只有真机启动失败才暴露。本检查器正是为抓这些而留。
# ============================================================================
_json_err=""
_json_check() {
    local s="$1"
    local n=${#s} i=0
    local ch nx
    local -a stack=()
    _json_err=""

    while [ "$i" -lt "$n" ]; do
        ch="${s:i:1}"
        case "$ch" in
            '"')
                local closed=0
                i=$((i + 1))
                while [ "$i" -lt "$n" ]; do
                    ch="${s:i:1}"
                    if [ "$ch" = "\\" ]; then
                        nx="${s:i+1:1}"
                        case "$nx" in
                            '"'|'\'|'/'|'b'|'f'|'n'|'r'|'t'|'u') ;;
                            *)
                                _json_err="位置 $i：非法转义 \\$nx"
                                return 1
                                ;;
                        esac
                        if [ "$nx" = "u" ]; then
                            local hex="${s:i+2:4}"
                            if [[ ! "$hex" =~ ^[0-9a-fA-F]{4}$ ]]; then
                                _json_err="位置 $i：\\u 后缺 4 位十六进制"
                                return 1
                            fi
                            i=$((i + 4))
                        fi
                        i=$((i + 2))
                        continue
                    fi
                    if [[ "$ch" == [$'\x01'-$'\x1f'] ]]; then
                        _json_err="位置 $i：字符串内有未转义控制字符"
                        return 1
                    fi
                    if [ "$ch" = '"' ]; then
                        closed=1
                        break
                    fi
                    i=$((i + 1))
                done
                if [ "$closed" -ne 1 ]; then
                    _json_err="位置 $i：字符串未闭合"
                    return 1
                fi
                i=$((i + 1))
                continue
                ;;
            '{'|'[')
                stack+=("$ch")
                ;;
            '}'|']')
                local want
                if [ "${#stack[@]}" -eq 0 ]; then
                    _json_err="位置 $i：多余的 $ch"
                    return 1
                fi
                want="${stack[$((${#stack[@]} - 1))]}"
                stack=("${stack[@]:0:$((${#stack[@]} - 1))}")
                if { [ "$ch" = "}" ] && [ "$want" != "{" ]; } \
                    || { [ "$ch" = "]" ] && [ "$want" != "[" ]; }; then
                    _json_err="位置 $i：$ch 与 $want 不配对"
                    return 1
                fi
                local j=$((i - 1))
                while [ "$j" -ge 0 ]; do
                    case "${s:j:1}" in
                        ' '|$'\t'|$'\n'|$'\r') j=$((j - 1)) ;;
                        *) break ;;
                    esac
                done
                if [ "$j" -ge 0 ] && [ "${s:j:1}" = "," ]; then
                    _json_err="位置 $i：$ch 前有尾逗号"
                    return 1
                fi
                ;;
            '/')
                _json_err="位置 $i：JSON 不允许注释"
                return 1
                ;;
        esac
        i=$((i + 1))
    done

    if [ "${#stack[@]}" -ne 0 ]; then
        _json_err="有 ${#stack[@]} 个括号未闭合"
        return 1
    fi
    return 0
}

t_json_valid() {
    local desc="$1" doc="$2"
    if _json_check "$doc"; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        printf '  [FAIL] %s\n' "$desc" >&2
        printf '         JSON 非法: %s\n' "$_json_err" >&2
    fi
    return 0
}

# 子串判定助手（多参数直接调用，不走 eval / 不 fork）
# _t_has_all doc tok...   全部出现才返回 0
# _t_absent_tokens doc tok...  全部不出现才返回 0
_t_has_all() {
    local doc="$1"; shift
    local tok
    for tok in "$@"; do
        case "$doc" in
            *"$tok"*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}
_t_absent_tokens() {
    local doc="$1"; shift
    local tok
    for tok in "$@"; do
        case "$doc" in
            *"$tok"*) return 1 ;;
        esac
    done
    return 0
}

# ============================================================================
# 造数据
# ============================================================================
CERT="$XMG_TMP/fullchain.crt"
KEY="$XMG_TMP/priv.key"
printf 'cert\n' > "$CERT"
printf 'key\n' > "$KEY"

xmg_state_set PROXY_SOCKS_ENABLED 1
xmg_state_set PROXY_SOCKS_PORT 1080
xmg_state_set PROXY_SOCKS_LISTEN "0.0.0.0"
xmg_state_set PROXY_SOCKS_USER "alice"
xmg_state_set PROXY_SOCKS_PASS "supersecret"
xmg_state_set PROXY_SOCKS_UDP 0
xmg_state_set PROXY_VLESS_ENABLED 1
xmg_state_set PROXY_VLESS_PORT 443
xmg_state_set PROXY_VLESS_LISTEN "0.0.0.0"
xmg_state_set PROXY_VLESS_DOMAIN "example.com"
xmg_state_set PROXY_VLESS_UUID "5783a3e7-e373-51cd-8642-c83782b807c5"
xmg_state_set PROXY_VLESS_PATH "/xhttpx"
xmg_state_set PROXY_VLESS_MODE "auto"
xmg_state_set PROXY_VLESS_CERT_FILE "$CERT"
xmg_state_set PROXY_VLESS_KEY_FILE "$KEY"

C1="$(xmg_render_config 1 0)"   # 仅 SOCKS
C2="$(xmg_render_config 0 1)"   # 仅 VLESS
C3="$(xmg_render_config 1 1)"   # 共存

# ============================================================================
# 1. 三种组合的产物都是合法 JSON
# ============================================================================
t_json_valid "仅 SOCKS 配置是合法 JSON" "$C1"
t_json_valid "仅 VLESS 配置是合法 JSON" "$C2"
t_json_valid "共存配置是合法 JSON" "$C3"

# ============================================================================
# 2. 共存时 inbounds 恰 2 个，tag 分别为 inbound-socks / inbound-vless，端口不同
# ============================================================================
_t_c3_inbound_tags="$(printf '%s' "$C3" | grep -c '"tag": "inbound-')"
t_equals "共存时 inbounds 恰为 2 个" "$_t_c3_inbound_tags" "2"

t_assert "共存时 tag 为 inbound-socks 与 inbound-vless" \
    _t_has_all "$C3" '"tag": "inbound-socks"' '"tag": "inbound-vless"'

_t_c3_ports="$(printf '%s' "$C3" | grep -oE '"port": [0-9]+' | awk '{print $2}' | sort -u | wc -l | tr -d ' ')"
t_equals "共存时两入站端口不同" "$_t_c3_ports" "2"

# ============================================================================
# 3. 铁律禁止字段（对产物，不对源码）：依据 https://lcuwx2016.github.io/xtls/config 规范
#    network（传输字段应为 method）/ mux（XHTTP 下不可用）/ flow（仅 TCP+TLS 可用）
#    extra、email（用户确认不暴露）/ accounts（入站用户列表应为 users）/ noauth（SOCKS 必须强口令）
#    tcpSettings（传输字段名为 rawSettings）
# ============================================================================
t_assert "共存产物不含铁律禁止字段" \
    _t_absent_tokens "$C3" \
    '"network"' '"mux"' '"flow"' '"extra"' '"email"' '"accounts"' 'noauth' 'tcpSettings'

# ============================================================================
# 4. 必备字段必须出现（依据 https://lcuwx2016.github.io/xtls/config 规范）
# ============================================================================
t_assert "共存产物含必备字段 method/users/decryption/auth" \
    _t_has_all "$C3" '"method": "xhttp"' '"users"' '"decryption": "none"' '"auth": "password"'

# ============================================================================
# 5. SOCKS 入站不得带 streamSettings：全产物中 streamSettings 只应出现 1 次（VLESS）
# ============================================================================
_t_c3_ss="$(printf '%s' "$C3" | grep -c 'streamSettings')"
t_equals "共存产物 streamSettings 恰出现在 VLESS 一处" "$_t_c3_ss" "1"
t_not_contains "仅 SOCKS 产物无 streamSettings" "$C1" 'streamSettings'

# ============================================================================
# 6. Task 4 加固字段断言 (rejectUnknownSni, domainStrategy, connIdle, IPv6 DoH)
# ============================================================================
# 6.1 VLESS TLS rejectUnknownSni 阻断空 SNI 探测
t_contains "VLESS 产物 tlsSettings 包含 rejectUnknownSni: true" "$C2" '"rejectUnknownSni": true'
t_contains "共存产物 tlsSettings 包含 rejectUnknownSni: true" "$C3" '"rejectUnknownSni": true'

# 6.2 Freedom 出站闭环 domainStrategy
t_contains "默认/双栈下 freedom 出站包含 domainStrategy: UseIP" "$C3" '"domainStrategy": "UseIP"'

# 6.3 Policy 连接空闲超时收缩至 60 秒
t_contains "Policy 配置包含 connIdle: 60" "$C3" '"connIdle": 60'

# 6.4 默认/双栈下 DNS DoH 与 queryStrategy
t_contains "默认/双栈下 DNS servers 包含 1.1.1.1" "$C3" '"https+local://1.1.1.1/dns-query"'
t_contains "默认/双栈下 DNS servers 包含 8.8.8.8" "$C3" '"https+local://8.8.8.8/dns-query"'
t_contains "默认/双栈下 DNS queryStrategy 为 UseIP" "$C3" '"queryStrategy": "UseIP"'

# 6.5 纯 IPv6 场景动态适配 (XMG_NET_IPV4=0 && XMG_NET_IPV6=1)
XMG_NET_IPV4=0
XMG_NET_IPV6=1
C_IPV6="$(xmg_render_config 1 1)"
t_json_valid "纯 IPv6 场景配置是合法 JSON" "$C_IPV6"
t_contains "纯 IPv6 下 freedom 出站 domainStrategy 为 UseIPv6" "$C_IPV6" '"domainStrategy": "UseIPv6"'
t_contains "纯 IPv6 下 DNS servers 包含 Cloudflare IPv6 DoH" "$C_IPV6" '"https+local://[2606:4700:4700::1111]/dns-query"'
t_contains "纯 IPv6 下 DNS servers 包含 Google IPv6 DoH" "$C_IPV6" '"https+local://[2001:4860:4860::8888]/dns-query"'
t_contains "纯 IPv6 下 DNS queryStrategy 为 UseIPv6" "$C_IPV6" '"queryStrategy": "UseIPv6"'
t_not_contains "纯 IPv6 下 DNS servers 不包含 IPv4 1.1.1.1" "$C_IPV6" '"https+local://1.1.1.1/dns-query"'
unset XMG_NET_IPV4 XMG_NET_IPV6

# 6.6 无方案启用 (0 0) 时生成空 inbounds 列表（合法且不含非法 tunnel 协议）
C0="$(xmg_render_config 0 0)"
t_json_valid "两方案均未启用配置是合法 JSON" "$C0"
t_contains "两方案均未启用时 inbounds 为空列表" "$C0" '"inbounds": []'
t_not_contains "两方案均未启用时不包含 tunnel 协议" "$C0" '"tunnel"'

# 6.7 环境变量指定自定义模板生效
C_CUSTOM_TPL="$XMG_TMP/custom_template.json"
printf '{"log":{},"dns":{},"policy":{"levels":{"0":{}}},"inbounds":[],"outbounds":[],"customMarker":"customValue"}\n' > "$C_CUSTOM_TPL"
XMG_CONFIG_TEMPLATE="$C_CUSTOM_TPL"
C_CUSTOM="$(xmg_render_config 1 0)"
t_json_valid "自定义模板配置是合法 JSON" "$C_CUSTOM"
t_contains "自定义模板字段正确透传" "$C_CUSTOM" '"customMarker": "customValue"'
unset XMG_CONFIG_TEMPLATE

# 6.8 模板文件不存在时回退到内置骨架
XMG_CONFIG_TEMPLATE="$XMG_TMP/nonexistent_template.json"
C_FALLBACK="$(xmg_render_config 1 0)"
t_json_valid "回退内置骨架模板配置是合法 JSON" "$C_FALLBACK"
t_contains "回退内置骨架时包含 socks 入站" "$C_FALLBACK" '"inbound-socks"'
unset XMG_CONFIG_TEMPLATE

# ============================================================================
# 负例：证明 JSON 检查器真的会响（否则「合法 JSON」断言在检查器恒 0 时也会全绿）
# ============================================================================
_json_rc=0
_json_check '{"a":1,}' || _json_rc=$?
t_equals "负例：尾逗号应被判非法" "$_json_rc" "1"

# ============================================================================
# 恢复环境 + 清理
# ============================================================================
eval "XMG_ETC_DIR=\"\$_TC_SAVED_ETC\""
eval "XMG_XRAY_STATE_DIR=\"\$_TC_SAVED_STATE_DIR\""
eval "XMG_STATE_FILE=\"\$_TC_SAVED_STATE_FILE\""
eval "XMG_LOG_DIR=\"\$_TC_SAVED_LOG_DIR\""
eval "XMG_XRAY_LOG_DIR=\"\$_TC_SAVED_XRAY_LOG_DIR\""
eval "XMG_NET_IPV4=\"\$_TC_SAVED_NET_IPV4\""
eval "XMG_NET_IPV6=\"\$_TC_SAVED_NET_IPV6\""
[ -n "$_TC_HAS_ETC" ] || unset XMG_ETC_DIR
[ -n "$_TC_HAS_STATE_DIR" ] || unset XMG_XRAY_STATE_DIR
[ -n "$_TC_HAS_STATE_FILE" ] || unset XMG_STATE_FILE
[ -n "$_TC_HAS_LOG_DIR" ] || unset XMG_LOG_DIR
[ -n "$_TC_HAS_XRAY_LOG_DIR" ] || unset XMG_XRAY_LOG_DIR
[ -n "$_TC_HAS_NET_IPV4" ] || unset XMG_NET_IPV4
[ -n "$_TC_HAS_NET_IPV6" ] || unset XMG_NET_IPV6
unset _TC_SAVED_ETC _TC_SAVED_STATE_DIR _TC_SAVED_STATE_FILE
unset _TC_SAVED_LOG_DIR _TC_SAVED_XRAY_LOG_DIR
unset _TC_SAVED_NET_IPV4 _TC_SAVED_NET_IPV6
unset _TC_HAS_ETC _TC_HAS_STATE_DIR _TC_HAS_STATE_FILE
unset _TC_HAS_LOG_DIR _TC_HAS_XRAY_LOG_DIR
unset _TC_HAS_NET_IPV4 _TC_HAS_NET_IPV6
unset _t_c3_inbound_tags _t_c3_ports _t_c3_ss _json_rc _json_err
XMG_STATE=()
rm -rf "$XMG_TMP"
unset XMG_TMP CERT KEY C1 C2 C3 C_IPV6
