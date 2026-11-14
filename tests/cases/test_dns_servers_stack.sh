#!/usr/bin/env bash
# DNS 服务器按宿主机协议族下发测试
#   双栈 / 未知 -> IPv4 主 + IPv6 备
#   纯 IPv6     -> 仅 IPv6
#   纯 IPv4     -> 仅 IPv4
# 两套渲染引擎（jq 与纯 Bash）都必须产出合法 JSON。
# shellcheck shell=bash

SRC="$TESTS_DIR/.."
_DNS_TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$_DNS_TMP_ROOT"' RETURN 2>/dev/null || true

render() {
    local v4="$1" v6="$2"
    XMG_HOME="$(mktemp -d "$_DNS_TMP_ROOT/case.XXXXXX")" XMG_NET_IPV4="$v4" XMG_NET_IPV6="$v6" \
        XMG_LIB_DIR="$SRC/lib" \
        bash -c '
            source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
            source "$XMG_LIB_DIR/state.sh" >/dev/null 2>&1
            source "$XMG_LIB_DIR/render.sh" >/dev/null 2>&1
            xmg_render_config 0 0
        ' 2>/dev/null
}

render_bash_engine() {
    local v4="$1" v6="$2"
    XMG_HOME="$(mktemp -d "$_DNS_TMP_ROOT/case.XXXXXX")" XMG_NET_IPV4="$v4" XMG_NET_IPV6="$v6" \
        XMG_LIB_DIR="$SRC/lib" \
        bash -c '
            source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
            source "$XMG_LIB_DIR/state.sh" >/dev/null 2>&1
            source "$XMG_LIB_DIR/render.sh" >/dev/null 2>&1
            _xmg_render_config_bash
        ' 2>/dev/null
}

C_DUAL="$(render 1 1)"
C_V6="$(render 0 1)"
C_V4="$(render 1 0)"
C_UNKNOWN="$(render "" "")"

t_equals "双栈渲染输出合法 JSON" "$(printf '%s' "$C_DUAL" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"
t_equals "双栈 DNS 同时含 IPv4 与 IPv6" \
    "$(printf '%s' "$C_DUAL" | jq -r '(([.dns.servers[] | select(test("1\\.1\\.1\\.1"))] | length) > 0) and (([.dns.servers[] | select(test("2606:4700"))] | length) > 0)' 2>/dev/null)" \
    "true"

t_equals "纯 IPv6 DNS 仅 IPv6" \
    "$(printf '%s' "$C_V6" | jq -r '[.dns.servers[] | select(test("^https\\+local://1\\.1\\.1\\.1"))] | length' 2>/dev/null)" \
    "0"
t_equals "纯 IPv6 保留 IPv6 DoH" \
    "$(printf '%s' "$C_V6" | jq -r '[.dns.servers[] | select(test("2606:4700"))] | length' 2>/dev/null)" \
    "1"

t_equals "纯 IPv4 DNS 仅 IPv4" \
    "$(printf '%s' "$C_V4" | jq -r '[.dns.servers[] | select(test("2606:4700"))] | length' 2>/dev/null)" \
    "0"
t_equals "纯 IPv4 保留 IPv4 DoH" \
    "$(printf '%s' "$C_V4" | jq -r '[.dns.servers[] | select(test("1\\.1\\.1\\.1"))] | length' 2>/dev/null)" \
    "1"

t_equals "栈未知时两族都给（避免探测失败押错）" \
    "$(printf '%s' "$C_UNKNOWN" | jq -r '[.dns.servers[] | select(test("2606:4700"))] | length' 2>/dev/null)" \
    "1"

t_equals "所有场景都以 localhost 兜底" \
    "$(printf '%s' "$C_DUAL" | jq -r '.dns.servers[-1]' 2>/dev/null)" \
    "localhost"

# 纯 Bash 引擎与 jq 引擎结果一致
C_BASH="$(render_bash_engine 1 1)"
t_equals "纯 Bash 引擎输出合法 JSON" "$(printf '%s' "$C_BASH" | jq -e . >/dev/null 2>&1 && echo ok)" "ok"
t_equals "两套引擎 DNS 列表一致" \
    "$(printf '%s' "$C_BASH" | jq -c '.dns.servers' 2>/dev/null)" \
    "$(printf '%s' "$C_DUAL" | jq -c '.dns.servers' 2>/dev/null)"

rm -rf "$_DNS_TMP_ROOT"
