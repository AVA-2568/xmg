#!/usr/bin/env bash
# DNS 预设境外化（Task 12）
# 服务器多位于海外，默认 DNS 必须指向境外（Cloudflare），避免阿里 DNS 高延迟
# shellcheck shell=bash

TUNE_FILE="$TESTS_DIR/../lib/tune.sh"
TUNE="$(cat "$TUNE_FILE")"

# --- 官方预设项必须齐备（境外为主，境内保留）---
t_contains "含 Cloudflare IPv4 预设" "$TUNE" "1.1.1.1 1.0.0.1"
t_contains "含 Google 预设" "$TUNE" "8.8.8.8 8.8.4.4"
t_contains "含 Quad9 预设" "$TUNE" "9.9.9.9 149.112.112.112"
t_contains "含 Cloudflare IPv6 预设" "$TUNE" "2606:4700:4700::1111"
t_contains "保留阿里境内预设" "$TUNE" "223.5.5.5 223.6.6.6"

# --- 境外默认值常量已声明且为 Cloudflare ---
t_contains "声明 XMG_TUNE_DNS_DEFAULT" "$TUNE" "XMG_TUNE_DNS_DEFAULT"
t_contains "DNS 默认为 Cloudflare(境外)" "$TUNE" 'XMG_TUNE_DNS_DEFAULT:-1.1.1.1 1.0.0.1'
t_contains "声明 XMG_TUNE_DOT_DEFAULT" "$TUNE" "XMG_TUNE_DOT_DEFAULT"
t_contains "DoT 默认为 Cloudflare(境外)" "$TUNE" 'XMG_TUNE_DOT_DEFAULT:-1.1.1.1 1.0.0.1'

# --- 默认路径不得再指向境内 DNS ---
t_not_contains "默认不指向阿里 223.5.5.5" "$TUNE" 'XMG_TUNE_DNS_DEFAULT:-223.5.5.5'

# --- 菜单提示须标注境外推荐·默认 ---
t_contains "菜单标注境外推荐·默认" "$TUNE" "境外推荐·默认"

# --- 行为：空输入归一为默认（境外），显式选择仍可用 ---
# 交互函数 UI 走 stderr、结果走 stdout，故用管道喂选择、只捕获 stdout。
source "$TESTS_DIR/../lib/tune.sh" 2>/dev/null

_out="$(printf '\n' | xmg_tune_dns_pick 2>/dev/null)"
t_equals "空输入默认 Cloudflare(境外)" "$_out" "1.1.1.1 1.0.0.1"

_out="$(printf '4\n' | xmg_tune_dns_pick 2>/dev/null)"
t_equals "显式选择 4 仍为阿里(境内)" "$_out" "223.5.5.5 223.6.6.6"

_out="$(printf '\n' | xmg_tune_dot_pick 2>/dev/null)"
t_equals "DoT 空输入默认 Cloudflare(境外)" "$_out" "1.1.1.1 1.0.0.1"

unset _out TUNE TUNE_FILE
