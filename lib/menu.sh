#!/usr/bin/env bash

[ "${XMG_MENU_SH_LOADED:-0}" = "1" ] && return 0
XMG_MENU_SH_LOADED=1

xmg_menu_load_modules() {
    # 菜单业务模块懒加载，避免默认 monitor 启动路径过重
    [ "${XMG_CADDY_SH_LOADED:-0}" = "1" ] || source "$XMG_LIB_DIR/caddy.sh"
    [ "${XMG_XRAY_SH_LOADED:-0}" = "1" ] || source "$XMG_LIB_DIR/xray.sh"
    [ "${XMG_SITE_SH_LOADED:-0}" = "1" ] || source "$XMG_LIB_DIR/site.sh"
    [ "${XMG_FIREWALL_SH_LOADED:-0}" = "1" ] || source "$XMG_LIB_DIR/firewall.sh"
    [ "${XMG_UPDATE_SH_LOADED:-0}" = "1" ] || source "$XMG_LIB_DIR/update.sh"
    [ "${XMG_UNINSTALL_SH_LOADED:-0}" = "1" ] || source "$XMG_LIB_DIR/uninstall.sh"
}

xmg_menu_show() {
    clear
    cat <<EOF
XMG 管理菜单
============

1) 查看系统摘要
2) Xray 管理
3) Caddy 管理
4) 站点管理
5) 防火墙管理
6) 更新 / 版本
7) 查看最近日志
8) 卸载 XMG
9) 返回实时监控
10) 退出

EOF
}

xmg_menu_xray() {
    local choice=""

    while true; do
        clear
        cat <<EOF
Xray 管理
=========

1) 查看状态
2) 启动 Xray
3) 停止 Xray
4) 重启 Xray
5) 启用开机自启
6) 禁用开机自启
7) 写入本地示例配置
8) 返回

EOF
        printf '请选择: '
        read -r choice || return 0

        case "$choice" in
            1) xmg_xray_status; xmg_pause ;;
            2) xmg_xray_start; xmg_pause ;;
            3) xmg_xray_stop; xmg_pause ;;
            4) xmg_xray_restart; xmg_pause ;;
            5) xmg_xray_enable; xmg_pause ;;
            6) xmg_xray_disable; xmg_pause ;;
            7) xmg_xray_write_sample_config; xmg_pause ;;
            8) return 0 ;;
            *) xmg_warn "无效选择"; xmg_pause ;;
        esac
    done
}

xmg_menu_caddy() {
    local choice=""

    while true; do
        clear
        cat <<EOF
Caddy 管理
==========

1) 查看状态
2) 启动 Caddy
3) 停止 Caddy
4) 重启 Caddy
5) 重新加载 Caddy
6) 启用开机自启
7) 禁用开机自启
8) 写入示例 Caddyfile
9) 返回

EOF
        printf '请选择: '
        read -r choice || return 0

        case "$choice" in
            1) xmg_caddy_status; xmg_pause ;;
            2) xmg_caddy_start; xmg_pause ;;
            3) xmg_caddy_stop; xmg_pause ;;
            4) xmg_caddy_restart; xmg_pause ;;
            5) xmg_caddy_reload; xmg_pause ;;
            6) xmg_caddy_enable; xmg_pause ;;
            7) xmg_caddy_disable; xmg_pause ;;
            8) xmg_caddy_write_sample_config; xmg_pause ;;
            9) return 0 ;;
            *) xmg_warn "无效选择"; xmg_pause ;;
        esac
    done
}

xmg_menu_site() {
    local choice=""

    while true; do
        clear
        cat <<EOF
站点管理
========

1) 创建默认静态站点
2) 查看站点目录
3) 返回

EOF
        printf '请选择: '
        read -r choice || return 0

        case "$choice" in
            1) xmg_site_create_default; xmg_pause ;;
            2) xmg_site_show_path; xmg_pause ;;
            3) return 0 ;;
            *) xmg_warn "无效选择"; xmg_pause ;;
        esac
    done
}

xmg_menu_firewall() {
    local choice=""

    while true; do
        clear
        cat <<EOF
防火墙管理
==========

1) 查看 UFW 状态
2) 放行 SSH/HTTP/HTTPS
3) 启用 UFW
4) 禁用 UFW
5) 返回

EOF
        printf '请选择: '
        read -r choice || return 0

        case "$choice" in
            1) xmg_firewall_status; xmg_pause ;;
            2) xmg_firewall_allow_basic; xmg_pause ;;
            3) xmg_firewall_enable; xmg_pause ;;
            4) xmg_firewall_disable; xmg_pause ;;
            5) return 0 ;;
            *) xmg_warn "无效选择"; xmg_pause ;;
        esac
    done
}

xmg_menu_update() {
    local choice=""

    while true; do
        clear
        cat <<EOF
更新 / 版本
===========

1) 显示版本
2) 检查本地文件完整性
3) 从 GitHub 更新
4) 返回

EOF
        printf '请选择: '
        read -r choice || return 0

        case "$choice" in
            1) xmg_update_version; xmg_pause ;;
            2) xmg_update_check_files; xmg_pause ;;
            3) xmg_update_from_github; xmg_pause ;;
            4) return 0 ;;
            *) xmg_warn "无效选择"; xmg_pause ;;
        esac
    done
}

xmg_menu_logs() {
    clear
    echo "最近日志"
    echo "========"
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
        printf '请选择: '
        read -r choice || return 0

        case "$choice" in
            1)
                clear
                xmg_system_refresh_all force
                xmg_system_print_summary
                xmg_pause
                ;;
            2) xmg_menu_xray ;;
            3) xmg_menu_caddy ;;
            4) xmg_menu_site ;;
            5) xmg_menu_firewall ;;
            6) xmg_menu_update ;;
            7) xmg_menu_logs ;;
            8) xmg_uninstall_menu ;;
            9) return 0 ;;
            10) clear; exit 0 ;;
            *) xmg_warn "无效选择"; xmg_pause ;;
        esac
    done
}
