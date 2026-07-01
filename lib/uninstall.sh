#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# uninstall.sh - XMG 卸载模块
#
# 说明：
#   - 本卸载器只删除 XMG 自身文件
#   - 不卸载 xray、caddy、ufw
#   - 默认不使用 XMG_LIB_DIR，避免源码目录测试时误删 ./lib
#   - 文件内容应使用 UTF-8 编码保存
#

# uninstall.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "uninstall.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_UNINSTALL_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_UNINSTALL_SH_LOADED=1

# 注意：
# 不默认使用 XMG_LIB_DIR，避免源码目录测试时：
#   XMG_LIB_DIR=./lib ./xmg menu
# 误删当前源码 lib。
XMG_BIN_PATH="${XMG_BIN_PATH:-/usr/local/bin/xmg}"
XMG_LIB_INSTALL_DIR="${XMG_LIB_INSTALL_DIR:-/usr/local/lib/xmg}"

XMG_UNINSTALL_DONE=0

xmg_uninstall_require_absolute() {
    local path="$1"

    case "$path" in
        /*)
            return 0
            ;;
        *)
            xmg_die "拒绝操作非绝对路径: $path"
            ;;
    esac
}

xmg_uninstall_reject_path_traversal() {
    local path="$1"

    case "$path" in
        *"/../"*|*"/.."|".."|"../"*)
            xmg_die "拒绝包含路径穿越的路径: $path"
            ;;
    esac
}

xmg_uninstall_reject_dangerous_path() {
    local path="$1"

    case "$path" in
        ""|"/"|"/bin"|"/sbin"|"/lib"|"/lib64"|"/usr"|"/usr/bin"|"/usr/sbin"|"/usr/local"|"/etc"|"/var"|"/var/www"|"/var/log"|"/var/backups"|"/run"|"/tmp"|"/home"|"/home/"*)
            xmg_die "拒绝删除危险路径: $path"
            ;;
    esac
}

xmg_uninstall_validate_path() {
    local path="$1"

    xmg_uninstall_require_absolute "$path"
    xmg_uninstall_reject_path_traversal "$path"
    xmg_uninstall_reject_dangerous_path "$path"
}

xmg_uninstall_safe_rm_rf() {
    local path="$1"

    xmg_uninstall_validate_path "$path"

    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -rf --one-file-system -- "$path" || xmg_die "删除失败: $path"
        xmg_info "已删除: $path"
    else
        xmg_warn "不存在，跳过: $path"
    fi
}

xmg_uninstall_safe_rm_f() {
    local path="$1"

    xmg_uninstall_validate_path "$path"

    if [ -d "$path" ] && [ ! -L "$path" ]; then
        xmg_die "目标是目录，拒绝按文件删除: $path"
    fi

    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -f -- "$path" || xmg_die "删除失败: $path"
        xmg_info "已删除: $path"
    else
        xmg_warn "不存在，跳过: $path"
    fi
}

xmg_uninstall_print_program_only_plan() {
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
    echo "  $XMG_RUN_DIR"
    echo "  $XMG_WWW_DIR"
    echo "  $XMG_LOG_DIR"
    echo "  $XMG_BACKUP_DIR"
    echo
    echo "不会卸载:"
    echo "  xray"
    echo "  caddy"
    echo "  ufw"
    echo
}

xmg_uninstall_print_all_plan() {
    clear
    echo "XMG 卸载：删除程序和 XMG 数据"
    echo "============================"
    echo
    echo "将删除:"
    echo "  $XMG_BIN_PATH"
    echo "  $XMG_LIB_INSTALL_DIR"
    echo "  $XMG_ETC_DIR"
    echo "  $XMG_RUN_DIR"
    echo "  $XMG_WWW_DIR"
    echo "  $XMG_LOG_DIR"
    echo "  $XMG_BACKUP_DIR"
    echo
    echo "不会卸载:"
    echo "  xray"
    echo "  caddy"
    echo "  ufw"
    echo
}

xmg_uninstall_program_only() {
    xmg_require_root
    XMG_UNINSTALL_DONE=0

    xmg_uninstall_print_program_only_plan

    if ! xmg_confirm "确认仅删除 XMG 程序文件?"; then
        xmg_info "已取消"
        return 0
    fi

    xmg_uninstall_safe_rm_f "$XMG_BIN_PATH"
    xmg_uninstall_safe_rm_rf "$XMG_LIB_INSTALL_DIR"

    XMG_UNINSTALL_DONE=1
    xmg_info "XMG 程序文件已卸载"
}

xmg_uninstall_all() {
    xmg_require_root
    XMG_UNINSTALL_DONE=0

    xmg_uninstall_print_all_plan

    if ! xmg_confirm "确认删除 XMG 程序和 XMG 数据?"; then
        xmg_info "已取消"
        return 0
    fi

    xmg_uninstall_safe_rm_f "$XMG_BIN_PATH"
    xmg_uninstall_safe_rm_rf "$XMG_LIB_INSTALL_DIR"
    xmg_uninstall_safe_rm_rf "$XMG_ETC_DIR"
    xmg_uninstall_safe_rm_rf "$XMG_RUN_DIR"
    xmg_uninstall_safe_rm_rf "$XMG_WWW_DIR"
    xmg_uninstall_safe_rm_rf "$XMG_LOG_DIR"
    xmg_uninstall_safe_rm_rf "$XMG_BACKUP_DIR"

    XMG_UNINSTALL_DONE=1
    xmg_info "XMG 程序和数据已卸载"
}

xmg_uninstall_after_done() {
    if [ "${XMG_UNINSTALL_DONE:-0}" = "1" ]; then
        echo
        xmg_warn "XMG 文件已被删除，建议退出当前 XMG 会话"
        xmg_pause
        clear
        exit 0
    fi
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
        echo "说明:"
        echo "  - 本卸载器只删除 XMG 自身文件"
        echo "  - 不会卸载 xray/caddy/ufw"
        echo "  - 如果站点或备份仍需保留，请选择 1"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_uninstall_program_only
                xmg_uninstall_after_done
                xmg_pause
                ;;
            2)
                xmg_uninstall_all
                xmg_uninstall_after_done
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
