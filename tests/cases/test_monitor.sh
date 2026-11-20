#!/usr/bin/env bash
# lib/monitor.sh 单元测试 — 验证界面绘制、q 键退出与 EOF 防死循环保护
# shellcheck shell=bash

_MON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset XMG_MONITOR_SH_LOADED XMG_COMMON_SH_LOADED XMG_SYSTEM_SH_LOADED
# shellcheck source=/dev/null
source "$_MON_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$_MON_ROOT/lib/system.sh"
# shellcheck source=/dev/null
source "$_MON_ROOT/lib/monitor.sh"

t_assert "xmg_monitor_draw 函数已加载" declare -F xmg_monitor_draw
t_assert "xmg_monitor_loop 函数已加载" declare -F xmg_monitor_loop

# 1. 测试 xmg_monitor_draw 输出包含关键字段
_draw_out="$(
    XMG_STATUS_TIME="2026-11-20 12:00:00"
    XMG_STATUS_HOSTNAME="vps-test"
    XMG_STATUS_KERNEL="6.1.0"
    XMG_STATUS_UPTIME="up 1 day"
    XMG_STATUS_LOAD="0.05"
    XMG_STATUS_MEM_PERCENT="32%"
    XMG_STATUS_MEM_DETAIL="68MB/215MB"
    XMG_STATUS_DISK_ROOT="25%"
    XMG_STATUS_XRAY="ACTIVE"
    XMG_STATUS_PORT_22="LISTEN"
    XMG_STATUS_PORT_80="CLOSED"
    XMG_STATUS_PORT_443="LISTEN"
    XMG_CACHE_TTL=5
    XMG_SERVICE_TTL=10
    xmg_monitor_draw
)"
t_contains "监控绘制包含标题" "$_draw_out" "XMG Monitor (Real-Time)"
t_contains "监控绘制包含主机名" "$_draw_out" "vps-test"
t_contains "监控绘制包含内存信息" "$_draw_out" "68MB/215MB"
t_contains "监控绘制包含退出快捷键提示" "$_draw_out" "[q]"

# 2. 测试按 q 正常退出且恢复光标（输出含 \033[?25h）
_q_out="$(
    xmg_system_refresh_all() { :; }
    xmg_monitor_draw() { printf 'DRAWN\n'; }
    XMG_MONITOR_INTERVAL=1
    printf 'q' | xmg_monitor_loop
)"
_q_rc=$?
t_equals "按 q 退出返回码为 0" "$_q_rc" "0"
t_contains "按 q 退出恢复光标显示" "$_q_out" $'\033[?25h'

# 3. 测试 stdin EOF（</dev/null）立即退出，防 0.5C 机型无间隔重绘死循环
_eof_rc=0
(
    xmg_system_refresh_all() { :; }
    xmg_monitor_draw() { :; }
    XMG_MONITOR_INTERVAL=1
    xmg_monitor_loop </dev/null >/dev/null 2>&1
) || _eof_rc=$?
t_equals "stdin EOF 立即退出且返回 0" "$_eof_rc" "0"

# 4. 测试自定义 SSH 端口动态识别与展示（不写死 22/SSH）
_custom_sshd_dir="$(mktemp -d)"
printf 'Port 2222\n' > "$_custom_sshd_dir/sshd_config"
_det_port="$(XMG_SSHD_CONFIG="$_custom_sshd_dir/sshd_config" _xmg_system_detect_ssh_port)"
rm -rf "$_custom_sshd_dir"
t_equals "自定义 sshd_config 端口应解析为 2222" "$_det_port" "2222"

_draw_custom="$(
    XMG_STATUS_TIME="2026-11-20 12:00:00"
    XMG_STATUS_HOSTNAME="vps-test"
    XMG_STATUS_KERNEL="6.1.0"
    XMG_STATUS_UPTIME="up 1 day"
    XMG_STATUS_LOAD="0.05"
    XMG_STATUS_MEM_PERCENT="32%"
    XMG_STATUS_MEM_DETAIL="68MB/215MB"
    XMG_STATUS_DISK_ROOT="25%"
    XMG_STATUS_XRAY="ACTIVE"
    XMG_STATUS_SSH_PORT="2222"
    XMG_STATUS_PORT_22="listen"
    XMG_STATUS_PORT_80="closed"
    XMG_STATUS_PORT_443="listen"
    XMG_CACHE_TTL=5
    XMG_SERVICE_TTL=10
    xmg_monitor_draw
)"
t_contains "监控面板动态展示自定义 SSH 端口 2222/SSH" "$_draw_custom" "2222/SSH"
