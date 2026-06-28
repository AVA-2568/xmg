#!/usr/bin/env bash

[ "${XMG_MONITOR_SH_LOADED:-0}" = "1" ] && return 0
XMG_MONITOR_SH_LOADED=1

XMG_MONITOR_INTERVAL="${XMG_MONITOR_INTERVAL:-1}"

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

xmg_monitor_draw() {
    xmg_monitor_clear

    printf '%sXMG Monitor (Real-Time)%s\n' "$(xmg_c 36)" "$(xmg_reset)"
    printf '=======================\n\n'

    printf '%s系统%s\n' "$(xmg_c 1)" "$(xmg_reset)"
    printf '  Time       : %s\n' "$XMG_STATUS_TIME"
    printf '  Hostname   : %s\n' "$XMG_STATUS_HOSTNAME"
    printf '  Kernel     : %s\n' "$XMG_STATUS_KERNEL"
    printf '  Uptime     : %s\n' "$XMG_STATUS_UPTIME"
    printf '  Load       : %s\n' "$XMG_STATUS_LOAD"
    printf '  Memory     : %s (%s)\n' "$XMG_STATUS_MEM_PERCENT" "$XMG_STATUS_MEM_DETAIL"
    printf '  Disk /     : %s\n' "$XMG_STATUS_DISK_ROOT"
    printf '\n'

    printf '%s服务%s\n' "$(xmg_c 1)" "$(xmg_reset)"
    printf '  Xray       : %s\n' "$(xmg_status_color "$XMG_STATUS_XRAY")"
    printf '  Caddy      : %s\n' "$(xmg_status_color "$XMG_STATUS_CADDY")"
    printf '\n'

    printf '%s监听端口%s\n' "$(xmg_c 1)" "$(xmg_reset)"
    printf '  22/SSH     : %s\n' "$(xmg_status_color "$XMG_STATUS_PORT_22")"
    printf '  80/HTTP    : %s\n' "$(xmg_status_color "$XMG_STATUS_PORT_80")"
    printf '  443/HTTPS  : %s\n' "$(xmg_status_color "$XMG_STATUS_PORT_443")"
    printf '\n'

    printf '操作: '
    printf '%s[m]%s 管理菜单  ' "$(xmg_c 32)" "$(xmg_reset)"
    printf '%s[q]%s 退出\n' "$(xmg_c 31)" "$(xmg_reset)"
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
