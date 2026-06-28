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

    # 只检查一级入口函数
    xmg_menu_require_func xmg_xray_menu
    xmg_menu_require_func xmg_caddy_menu
    xmg_menu_require_func xmg_firewall_status
    xmg_menu_require_func xmg_firewall_allow_basic
    xmg_menu_require_func xmg_firewall_enable
    xmg_menu_require_func xmg_firewall_disable
    xmg_menu_require_func xmg_update_version
    xmg_menu_require_func xmg_update_check_files
    xmg_menu_require_func xmg_update_from_github
    xmg_menu_require_func xmg_uninstall_menu

    # site.sh 允许两种模式：
    # 1) 提供 xmg_site_menu
    # 2) 只提供最小功能函数
    if declare -F xmg_site_menu >/dev/null 2>&1; then
        :
    else
        xmg_menu_require_func xmg_site_create_default
        xmg_menu_require_func xmg_site_show_path
    fi
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

xmg_menu_site_fallback() {
    local choice=""

    while true; do
        clear
        echo "========== 站点管理 =========="
        echo "1. 创建默认静态站点"
        echo "2. 查看站点目录"
        echo "0. 返回"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_site_create_default
                xmg_pause
                ;;
            2)
                xmg_site_show_path
                xmg_pause
                ;;
            0)
                return 0
                ;;
            *)
                xmg_warn "无效选择"
                xmg_pause
                ;;
        esac
    done
}

xmg_menu_firewall() {
    local choice=""

    while true; do
        clear
        echo "========== 防火墙管理 =========="
        echo "1. 查看 UFW 状态"
        echo "2. 放行 SSH/HTTP/HTTPS"
        echo "3. 启用 UFW"
        echo "4. 禁用 UFW"
        echo "0. 返回"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_firewall_status
                xmg_pause
                ;;
            2)
                xmg_firewall_allow_basic
                xmg_pause
                ;;
            3)
                xmg_firewall_enable
                xmg_pause
                ;;
            4)
                xmg_firewall_disable
                xmg_pause
                ;;
            0)
                return 0
                ;;
            *)
                xmg_warn "无效选择"
                xmg_pause
                ;;
        esac
    done
}

xmg_menu_update() {
    local choice=""

    while true; do
        clear
        echo "========== 更新 / 版本 =========="
        echo "1. 显示版本"
        echo "2. 检查本地文件完整性"
        echo "3. 从 GitHub 更新"
        echo "0. 返回"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_update_version
                xmg_pause
                ;;
            2)
                xmg_update_check_files
                xmg_pause
                ;;
            3)
                xmg_update_from_github
                xmg_pause
                ;;
            0)
                return 0
                ;;
            *)
                xmg_warn "无效选择"
                xmg_pause
                ;;
        esac
    done
}

xmg_menu_logs() {
    clear
