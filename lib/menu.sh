#!/usr/bin/env bash

[ "${XMG_MENU_SH_LOADED:-0}" = "1" ] && return 0
XMG_MENU_SH_LOADED=1

xmg_menu_source_module() {
    local file="$1"
    local path="$XMG_LIB_DIR/$file"

    if [ ! -r "$path" ]; then
        xmg_die "模块不存在或不可读: $path"
    fi

    # shellcheck source=/dev/null
    source "$path"
}

xmg_menu_require_func() {
    local fn="$1"

    if ! declare -F "$fn" >/dev/null 2>&1; then
        xmg_die "模块接口缺失: $fn"
    fi
}

xmg_menu_load_modules() {
    [ "${XMG_XRAY_SH_LOADED:-0}" = "1" ] || xmg_menu_source_module "xray.sh"
    [ "${XMG_CADDY_SH_LOADED:-0}" = "1" ] || xmg_menu_source_module "caddy.sh"
    [ "${XMG_SITE_SH_LOADED:-0}" = "1" ] || xmg_menu_source_module "site.sh"
    [ "${XMG_FIREWALL_SH_LOADED:-0}" = "1" ] || xmg_menu_source_module "firewall.sh"
    [ "${XMG_UPDATE_SH_LOADED:-0}" = "1" ] || xmg_menu_source_module "update.sh"
    [ "${XMG_UNINSTALL_SH_LOADED:-0}" = "1" ] || xmg_menu_source_module "uninstall.sh"

    xmg_menu_require_func xmg_xray_menu
    xmg_menu_require_func xmg_caddy_menu
    xmg_menu_require_func xmg_site_menu
    xmg_menu_require_func xmg_firewall_menu
    xmg_menu_require_func xmg_update_menu
    xmg_menu_require_func xmg_uninstall_menu
}

xmg_menu_show() {
    clear
    cat <<EOF
========== XMG 管理菜单 ==========

1. 查看系统摘要
2. Xray 管理
3. Caddy 管理
4. 站点管理
5. 防火墙管理
6. 更新 / 版本
7. 查看最近日志
8. 卸载 XMG
9. 返回实时监控
0. 退出

EOF
}

xmg_menu_logs() {
    clear
    echo "========== 最近日志 =========="
    echo

    if xmg_cmd_exists journalctl; then
        echo "--- xray ---"
        journalctl -u xray -n 30 --no-pager 2>/dev/null || true
        echo
        echo "--- caddy ---"
        journalctl -u caddy -n 30 --no-pager 2>/dev/null || true
    else
        xmg_warn "journalctl 不存在"
    fi

    xmg_pause
}

xmg_menu_loop() {
    local choice=""

    xmg_menu_load_modules

    while true; do
        xmg_menu_show
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                clear
                xmg_system_refresh_all force
                xmg_system_print_summary
                xmg_pause
                ;;
            2)
                xmg_xray_menu
                ;;
            3)
                xmg_caddy_menu
                ;;
            4)
                xmg_site_menu
                ;;
            5)
                xmg_firewall_menu
                ;;
            6)
                xmg_update_menu
                ;;
            7)
                xmg_menu_logs
                ;;
            8)
                xmg_uninstall_menu
                ;;
            9)
                return 0
                ;;
            0)
                clear
                exit 0
                ;;
            *)
                xmg_warn "无效选择"
                xmg_pause
                ;;
        esac
    done
}
