#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# monitor.sh - XMG 实时监控界面
#
# 说明：
#   - 本模块负责绘制实时监控终端界面
#   - 依赖 common.sh 中的颜色变量和通用函数
#   - 依赖 system.sh 中的系统状态刷新函数和状态变量
#   - 依赖 menu.sh 中的 xmg_menu_loop
#   - 文件内容应使用 UTF-8 编码保存
#

# monitor.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "monitor.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_MONITOR_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_MONITOR_SH_LOADED=1

XMG_MONITOR_INTERVAL="${XMG_MONITOR_INTERVAL:-3}"

xmg_monitor_clear() {
    printf '\033[H\033[2J'
}

xmg_monitor_hide_cursor() {
    printf '\033[?25l'
}

xmg_monitor_show_cursor() {
    printf '\033[?25h'
}

xmg_monitor_cleanup() {
    xmg_monitor_show_cursor
}

# 打印带颜色状态，避免在热路径中使用 $(xmg_status_color ...)
xmg_monitor_print_status_line() {
    local label="$1"
    local value="$2"

    printf '  %-11s : ' "$label"
    xmg_status_color "$value"
    printf '\n'
}

xmg_monitor_draw() {
    xmg_monitor_clear

    printf '%sXMG Monitor (Real-Time)%s\n' "$XMG_C_CYAN" "$XMG_C_RESET"
    printf '=======================\n\n'

    printf '%s系统%s\n' "$XMG_C_BOLD" "$XMG_C_RESET"
    printf '  Time       : %s\n' "$XMG_STATUS_TIME"
    printf '  Hostname   : %s\n' "$XMG_STATUS_HOSTNAME"
    printf '  Kernel     : %s\n' "$XMG_STATUS_KERNEL"
    printf '  Uptime     : %s\n' "$XMG_STATUS_UPTIME"
    printf '  Load       : %s\n' "$XMG_STATUS_LOAD"
    printf '  Memory     : %s (%s)\n' "$XMG_STATUS_MEM_PERCENT" "$XMG_STATUS_MEM_DETAIL"
    printf '  Disk /     : %s\n' "$XMG_STATUS_DISK_ROOT"
    printf '\n'

    printf '%s服务%s\n' "$XMG_C_BOLD" "$XMG_C_RESET"
    xmg_monitor_print_status_line "Xray" "$XMG_STATUS_XRAY"
    xmg_monitor_print_status_line "Caddy" "$XMG_STATUS_CADDY"
    printf '\n'

    printf '%s监听端口%s\n' "$XMG_C_BOLD" "$XMG_C_RESET"
    xmg_monitor_print_status_line "22/SSH" "$XMG_STATUS_PORT_22"
    xmg_monitor_print_status_line "80/HTTP" "$XMG_STATUS_PORT_80"
    xmg_monitor_print_status_line "443/HTTPS" "$XMG_STATUS_PORT_443"
    printf '\n'

    printf '操作: '
    printf '%s[m]%s 管理菜单  ' "$XMG_C_GREEN" "$XMG_C_RESET"
    printf '%s[q]%s 退出\n' "$XMG_C_RED" "$XMG_C_RESET"
    printf '\n'

    printf '低资源模式: UI刷新=%ss, 系统缓存=%ss, 服务缓存=%ss\n' \
        "$XMG_MONITOR_INTERVAL" "$XMG_CACHE_TTL" "$XMG_SERVICE_TTL"
}

xmg_monitor_loop() {
    local key=""

    trap 'xmg_monitor_cleanup; exit 130' INT TERM
    trap 'xmg_monitor_cleanup' EXIT

    xmg_monitor_hide_cursor
    xmg_system_refresh_all force

    while true; do
        xmg_system_refresh_all
        xmg_monitor_draw

        key=""
        if read -rsn1 -t "$XMG_MONITOR_INTERVAL" key; then
            case "$key" in
                m|M)
                    xmg_monitor_show_cursor
                    xmg_menu_loop
                    xmg_monitor_hide_cursor
                    xmg_system_refresh_all force
                    ;;
                q|Q)
                    xmg_monitor_show_cursor
                    xmg_monitor_clear
                    trap - EXIT
                    return 0
                    ;;
                *)
                    ;;
            esac
        fi
    done
}
