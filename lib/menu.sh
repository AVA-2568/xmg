#!/usr/bin/env bash
#
# menu.sh - 主菜单
#

main_menu() {
    while true; do
        clear
        show_panel_header
        echo "1. 系统信息"
        echo "2. Caddy 管理"
        echo "3. Xray 管理"
        echo "4. 站点目录管理"
        echo "5. 防火墙管理"
        echo "6. 综合状态"
        echo "7. 小内存 VPS 优化"
        echo "0. 退出"
        echo
        read -rp "请选择: " choice

        case "${choice}" in
            1) show_system_info; pause ;;
            2) caddy_menu ;;
            3) xray_menu ;;
            4) site_menu ;;
            5) firewall_menu ;;
            6) show_services_status; pause ;;
            7) optimize_small_vps; pause ;;
            0) exit 0 ;;
            *) warn "无效选择"; pause ;;
        esac
    done
}
