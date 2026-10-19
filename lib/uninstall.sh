#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# uninstall.sh - XMG 卸载模块
#
# XMG_MENU_LABEL: 系统卸载清理
#
# 说明：
#   - 严格限定清理范围为 XMG 自治资源
#   - 绝不触碰操作系统包管理器的原生 unit (/lib/systemd/system/xray.service 等)
#   - 绝不触碰系统已安装的 Xray 官方二进制
#   - 具备严格的危险路径阻断机制
#

# ===== 安全加载 =====
if [ "${XMG_UNINSTALL_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_UNINSTALL_SH_LOADED=1

# ===== 默认配置 =====
XMG_UNINSTALL_KEEP_BACKUPS="${XMG_UNINSTALL_KEEP_BACKUPS:-0}"

# ===== 依赖 common.sh 的路径变量 =====
XMG_BIN="${XMG_BIN:-${XMG_HOME:-/opt/xmg}/bin/xmg}"
XMG_LINK="${XMG_LINK:-/usr/local/bin/xmg}"
XMG_XRAY_SERVICE="${XMG_XRAY_SERVICE:-xray}"

# ===== 危险路径检测与拦截 =====
xmg_uninstall_check_safe_home() {
    local target
    if [ "$#" -gt 0 ]; then
        target="$1"
    else
        target="${XMG_HOME:-}"
    fi

    if [ -z "$target" ]; then
        xmg_error "卸载安全拦截: XMG_HOME 为空"
        return 1
    fi

    local norm="$target"
    while [ "${norm: -1}" = "/" ] && [ "$norm" != "/" ]; do
        norm="${norm%/}"
    done

    if [ "$norm" = "/" ]; then
        xmg_error "卸载安全拦截: 禁止对根目录 '/' 执行卸载"
        return 1
    fi

    if [ "${#norm}" -le 3 ]; then
        xmg_error "卸载安全拦截: 路径过短 (${#norm} 字符): '$target'"
        return 1
    fi

    case "$norm" in
        /bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            xmg_error "卸载安全拦截: 严格禁止卸载系统目录: '$norm'"
            return 1
            ;;
    esac

    return 0
}

# ===== 进程与服务清理 =====
xmg_uninstall_kill_residues() {
    xmg_info "正在清理残留后台进程..."
    if command -v pkill &>/dev/null; then
        pkill -f "wireproxy" 2>/dev/null || true
    fi
}

xmg_uninstall_stop_services() {
    xmg_info "停止 XMG 托管的服务..."

    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet xmg-warp 2>/dev/null || systemctl is-active --quiet xmg-warp.service 2>/dev/null; then
            systemctl stop xmg-warp.service 2>/dev/null || true
        fi
        if systemctl is-enabled --quiet xmg-warp 2>/dev/null || systemctl is-enabled --quiet xmg-warp.service 2>/dev/null; then
            systemctl disable xmg-warp.service 2>/dev/null || true
        fi

        if systemctl is-active --quiet "$XMG_XRAY_SERVICE" 2>/dev/null; then
            xmg_info "正在停止 Xray 服务..."
            systemctl stop "$XMG_XRAY_SERVICE" 2>/dev/null || true
        fi
    fi

    xmg_uninstall_kill_residues
    xmg_info "服务已停止"
}

# ===== 文件与目录清理 =====
xmg_uninstall_remove_command_link() {
    local link="${XMG_LINK:-/usr/local/bin/xmg}"
    if [ -L "$link" ] || [ -e "$link" ]; then
        rm -f "$link" && xmg_info "已删除命令入口: $link" || xmg_warn "删除命令入口失败: $link"
    else
        xmg_info "命令入口不存在，跳过: $link"
    fi
}

xmg_uninstall_remove_xmg_home() {
    xmg_uninstall_check_safe_home "${XMG_HOME:-}" || return 1
    if [ -d "$XMG_HOME" ]; then
        xmg_info "正在删除 XMG 统一目录: $XMG_HOME"
        rm -rf "$XMG_HOME" && xmg_info "已删除: $XMG_HOME" || xmg_warn "删除 $XMG_HOME 失败"
    else
        xmg_info "$XMG_HOME 不存在，跳过"
    fi
}

xmg_uninstall_cleanup_systemd_artifacts() {
    local sys_dir="${XMG_SYSTEMD_DIR:-/etc/systemd/system}"
    local dropin_dir="${sys_dir}/xray.service.d"

    # 1. 仅清理 XMG 自身的 drop-in 覆盖文件
    for f in "${dropin_dir}/xmg.conf" "${dropin_dir}/20-xmg.conf"; do
        if [ -f "$f" ]; then
            rm -f "$f" 2>/dev/null && xmg_info "已清理 drop-in 覆盖: $f" || true
        fi
    done

    if [ -d "$dropin_dir" ]; then
        rmdir "$dropin_dir" 2>/dev/null || true
    fi

    # 2. 清理 xmg-warp.service 及其自启链接
    local warp_svc="${sys_dir}/xmg-warp.service"
    local warp_wants="${sys_dir}/multi-user.target.wants/xmg-warp.service"
    if [ -L "$warp_wants" ] || [ -e "$warp_wants" ]; then
        rm -f "$warp_wants" 2>/dev/null && xmg_info "已清理 xmg-warp 自启软链接" || true
    fi
    if [ -f "$warp_svc" ] || [ -L "$warp_svc" ]; then
        rm -f "$warp_svc" 2>/dev/null && xmg_info "已清理 xmg-warp 服务单元" || true
    fi

    # 3. 触发 systemd 重新加载配置
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

# ===== CLI 入口与卸载主流程 =====
xmg_uninstall_cli() {
    local auto_yes=0
    local arg=""

    for arg in "$@"; do
        case "$arg" in
            --yes|-y)
                auto_yes=1
                ;;
        esac
    done

    # 危险路径预检阻断
    if ! xmg_uninstall_check_safe_home "${XMG_HOME:-}"; then
        return 1
    fi

    if [ "$auto_yes" -ne 1 ]; then
        if declare -F xmg_confirm >/dev/null 2>&1; then
            if ! xmg_confirm "确认卸载 XMG？此操作不可撤销"; then
                xmg_info "已取消卸载"
                return 0
            fi
        else
            printf "确认卸载 XMG？(y/N): "
            read -r ans || return 0
            case "$ans" in
                [yY]|[yY][eE][sS]) ;;
                *) xmg_info "已取消卸载"; return 0 ;;
            esac
        fi
    fi

    # 1. 停止服务并清理残留
    xmg_uninstall_stop_services

    # 2. 清理命令入口软链接
    xmg_uninstall_remove_command_link

    # 3. 清理 XMG 自治主目录
    if [ "$XMG_UNINSTALL_KEEP_BACKUPS" = "1" ] && [ -n "${XMG_BACKUP_DIR:-}" ] && [ -d "$XMG_BACKUP_DIR" ]; then
        xmg_info "保留备份目录: $XMG_BACKUP_DIR"
        for dir in "${XMG_BIN_DIR:-}" "${XMG_LIB_DIR:-}" "${XMG_ETC_DIR:-}" "${XMG_RUN_DIR:-}" "${XMG_LOG_DIR:-}" "${XMG_XRAY_DIR:-}"; do
            if [ -n "$dir" ] && [ -d "$dir" ]; then
                rm -rf "$dir" 2>/dev/null || true
            fi
        done
    else
        xmg_uninstall_remove_xmg_home
    fi

    # 4. 清理 drop-in 与 warp 专属服务单元
    xmg_uninstall_cleanup_systemd_artifacts

    xmg_info "XMG 卸载完成"
    return 0
}

xmg_uninstall_run() {
    xmg_uninstall_cli "$@"
}

# ===== 卸载菜单 =====
xmg_uninstall_menu() {
    local choice=""

    while true; do
        clear
        echo "========== XMG 卸载管理 =========="
        echo "1. 执行标准卸载"
        echo "2. 执行卸载（保留备份）"
        echo "0. 返回"
        echo
        echo "当前目录:"
        echo "  XMG_HOME: $XMG_HOME"
        echo "  命令入口: $XMG_LINK"
        echo
        echo "安全说明:"
        echo "  - 仅清理 XMG 自治目录与自身生成的 drop-in / warp unit"
        echo "  - 绝对不删除操作系统原生 unit 与系统已安装的 Xray 二进制"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                XMG_UNINSTALL_KEEP_BACKUPS=0
                xmg_uninstall_run
                xmg_pause
                ;;
            2)
                XMG_UNINSTALL_KEEP_BACKUPS=1
                xmg_uninstall_run
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

# ===== 直接执行支持 =====
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    xmg_uninstall_menu
fi
