#!/usr/bin/env bash

[ "${XMG_UNINSTALL_SH_LOADED:-0}" = "1" ] && return 0
XMG_UNINSTALL_SH_LOADED=1

XMG_BIN_PATH="${XMG_BIN_PATH:-/usr/local/bin/xmg}"
XMG_LIB_INSTALL_DIR="${XMG_LIB_INSTALL_DIR:-/usr/local/lib/xmg}"

xmg_uninstall_safe_rm_rf() {
    local path="$1"

    case "$path" in
        ""|"/"|"/usr"|"/usr/local"|"/etc"|"/var"|"/var/www"|"/var/log"|"/var/backups")
            xmg_die "拒绝删除危险路径: $path"
            ;;
    esac

    if [ -e "$path" ]; then
        rm -rf --one-file-system "$path"
        xmg_info "已删除: $path"
    else
        xmg_warn "不存在，跳过: $path"
    fi
}

xmg_uninstall_safe_rm_f() {
    local path="$1"

    case "$path" in
        ""|"/"|"/usr"|"/usr/local"|"/etc"|"/var")
            xmg_die "拒绝删除危险路径: $path"
            ;;
    esac

    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -f "$path"
        xmg_info "已删除: $path"
    else
        xmg_warn "不存在，跳过: $path"
    fi
}

xmg_uninstall_program_only() {
    xmg_require_root

    clear
    echo "XMG 卸载：仅删除程序文件"
    echo "========================="
    echo
    echo "将删除:"
    echo "  $XMG_BIN_PATH"
    echo "  $XMG_LIB_INSTALL_DIR"
    echo
    echo "不会删除:"
    echo "  $XMG_ETC_DIR"
    echo "  $XMG_WWW_DIR"
    echo "  $XMG_LOG_DIR"
    echo "  $XMG_BACKUP_DIR"
    echo
    echo "不会卸载 xray/caddy/ufw"
    echo

    if ! xmg_confirm "确认仅删除 XMG 程序文件?"; then
        xmg_info "已取消"
        return 0
    fi

    xmg_uninstall_safe_rm_f "$XMG_BIN_PATH"
    xmg_uninstall_safe_rm_rf "$XMG_LIB_INSTALL_DIR"

    xmg_info "XMG 程序文件已卸载"
}

xmg_uninstall_all() {
    xmg_require_root

    clear
    echo "XMG 卸载：删除程序和 XMG 数据"
    echo "============================="
    echo
    echo "将删除:"
    echo "  $XMG_BIN_PATH"
    echo "  $XMG_LIB_INSTALL_DIR"
    echo "  $XMG_ETC_DIR"
    echo "  $XMG_WWW_DIR"
    echo "  $XMG_LOG_DIR"
    echo "  $XMG_BACKUP_DIR"
    echo
    echo "不会卸载 xray/caddy/ufw"
    echo

    if ! xmg_confirm "确认删除 XMG 程序和 XMG 数据?"; then
        xmg_info "已取消"
        return 0
    fi

    xmg_uninstall_safe_rm_f "$XMG_BIN_PATH"
    xmg_uninstall_safe_rm_rf "$XMG_LIB_INSTALL_DIR"
    xmg_uninstall_safe_rm_rf "$XMG_ETC_DIR"
    xmg_uninstall_safe_rm_rf "$XMG_WWW_DIR"
    xmg_uninstall_safe_rm_rf "$XMG_LOG_DIR"
    xmg_uninstall_safe_rm_rf "$XMG_BACKUP_DIR"

    xmg_info "XMG 程序和数据已卸载"
}

xmg_uninstall_menu() {
    local choice=""

    while true; do
        clear
        echo "========== XMG 卸载 =========="
        echo "1. 仅卸载 XMG 程序文件"
        echo "2. 卸载 XMG 程序文件和 XMG 数据"
        echo "0. 返回"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1) xmg_uninstall_program_only; xmg_pause ;;
            2) xmg_uninstall_all; xmg_pause ;;
            0) return 0 ;;
            *) xmg_warn "无效选择"; xmg_pause ;;
        esac
    done
}
