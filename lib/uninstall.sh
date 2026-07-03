#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# uninstall.sh - XMG 卸载模块
#
# 说明：
#   - 卸载 XMG 及其管理的组件
#   - 删除 XMG 统一目录 /opt/xmg
#   - 删除命令入口软链接 /usr/local/bin/xmg
#   - 可选择是否清理 Caddy 和 Xray 的配置
#

# ===== 安全加载 =====
if [ "${XMG_UNINSTALL_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_UNINSTALL_SH_LOADED=1

# ===== 默认配置 =====
XMG_UNINSTALL_KEEP_CADDY="${XMG_UNINSTALL_KEEP_CADDY:-0}"
XMG_UNINSTALL_KEEP_XRAY="${XMG_UNINSTALL_KEEP_XRAY:-0}"
XMG_UNINSTALL_KEEP_BACKUPS="${XMG_UNINSTALL_KEEP_BACKUPS:-0}"

# ===== 服务停止 =====

xmg_uninstall_stop_services() {
    xmg_info "停止 XMG 托管的服务..."

    # 停止 Caddy 服务（如果存在）
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet caddy 2>/dev/null; then
            xmg_info "正在停止 Caddy 服务..."
            systemctl stop caddy || xmg_warn "停止 Caddy 服务失败"
        fi

        # 停止 Xray 服务（如果存在）
        if systemctl is-active --quiet xray 2>/dev/null; then
            xmg_info "正在停止 Xray 服务..."
            systemctl stop xray || xmg_warn "停止 Xray 服务失败"
        fi

        # 禁用自启
        if systemctl is-enabled --quiet caddy 2>/dev/null; then
            systemctl disable caddy || xmg_warn "禁用 Caddy 自启失败"
        fi
        if systemctl is-enabled --quiet xray 2>/dev/null; then
            systemctl disable xray || xmg_warn "禁用 Xray 自启失败"
        fi
    fi

    xmg_info "服务已停止"
}

# ===== 文件清理 =====

xmg_uninstall_remove_command_link() {
    # 删除命令入口软链接 /usr/local/bin/xmg
    if [ -L "$XMG_LINK" ] || [ -e "$XMG_LINK" ]; then
        rm -f "$XMG_LINK" && xmg_info "已删除命令入口: $XMG_LINK" || xmg_warn "删除命令入口失败: $XMG_LINK"
    else
        xmg_info "命令入口不存在，跳过: $XMG_LINK"
    fi
}

xmg_uninstall_remove_xmg_home() {
    # 删除 XMG 统一根目录 /opt/xmg
    if [ -d "$XMG_HOME" ]; then
        xmg_info "正在删除 XMG 统一目录: $XMG_HOME"
        rm -rf "$XMG_HOME" && xmg_info "已删除: $XMG_HOME" || xmg_warn "删除 $XMG_HOME 失败，请手动检查"
    else
        xmg_info "$XMG_HOME 不存在，跳过"
    fi
}

xmg_uninstall_cleanup_caddy() {
    # 清理 Caddy 系统级配置（仅当用户确认时）
    if [ "$XMG_UNINSTALL_KEEP_CADDY" = "1" ]; then
        xmg_info "保留 Caddy 配置，跳过清理"
        return 0
    fi

    local caddy_etc="/etc/caddy"
    local caddy_unit=""
    local caddy_keyring="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    local caddy_apt_source="/etc/apt/sources.list.d/caddy-stable.list"

    # 查找 systemd unit
    for path in "/etc/systemd/system/caddy.service" "/lib/systemd/system/caddy.service" "/usr/lib/systemd/system/caddy.service"; do
        if [ -f "$path" ]; then
            caddy_unit="$path"
            break
        fi
    done

    if [ -z "$caddy_unit" ] && [ ! -d "$caddy_etc" ] && [ ! -f "$caddy_keyring" ] && [ ! -f "$caddy_apt_source" ]; then
        xmg_info "未检测到 Caddy 系统级配置，跳过"
        return 0
    fi

    xmg_warn "检测到 Caddy 系统级配置："
    [ -f "$caddy_unit" ] && xmg_warn "  systemd unit: $caddy_unit"
    [ -d "$caddy_etc" ] && xmg_warn "  /etc/caddy 目录"
    [ -f "$caddy_keyring" ] && xmg_warn "  APT keyring: $caddy_keyring"
    [ -f "$caddy_apt_source" ] && xmg_warn "  APT 源: $caddy_apt_source"

    if xmg_confirm "是否清理 Caddy 系统级配置？这不会影响系统中已安装的 Caddy 二进制"; then
        if [ -n "$caddy_unit" ]; then
            rm -f "$caddy_unit" && xmg_info "已删除: $caddy_unit"
        fi
        if [ -d "$caddy_etc" ]; then
            rm -rf "$caddy_etc" && xmg_info "已删除: $caddy_etc"
        fi
        if [ -f "$caddy_keyring" ]; then
            rm -f "$caddy_keyring" && xmg_info "已删除: $caddy_keyring"
        fi
        if [ -f "$caddy_apt_source" ]; then
            rm -f "$caddy_apt_source" && xmg_info "已删除: $caddy_apt_source"
        fi

        if command -v systemctl &>/dev/null; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi

        xmg_info "Caddy 系统级配置已清理"
    else
        xmg_info "保留 Caddy 系统级配置"
    fi
}

xmg_uninstall_cleanup_xray() {
    # 清理 Xray 系统级配置（仅当用户确认时）
    if [ "$XMG_UNINSTALL_KEEP_XRAY" = "1" ]; then
        xmg_info "保留 Xray 配置，跳过清理"
        return 0
    fi

    local xray_etc="/usr/local/etc/xray"
    local xray_unit=""

    # 查找 systemd unit
    for path in "/etc/systemd/system/xray.service" "/lib/systemd/system/xray.service" "/usr/lib/systemd/system/xray.service"; do
        if [ -f "$path" ]; then
            xray_unit="$path"
            break
        fi
    done

    if [ -z "$xray_unit" ] && [ ! -d "$xray_etc" ]; then
        xmg_info "未检测到 Xray 系统级配置，跳过"
        return 0
    fi

    xmg_warn "检测到 Xray 系统级配置："
    [ -f "$xray_unit" ] && xmg_warn "  systemd unit: $xray_unit"
    [ -d "$xray_etc" ] && xmg_warn "  /usr/local/etc/xray 目录"

    if xmg_confirm "是否清理 Xray 系统级配置？这不会影响系统中已安装的 Xray 二进制"; then
        if [ -n "$xray_unit" ]; then
            rm -f "$xray_unit" && xmg_info "已删除: $xray_unit"
        fi
        if [ -d "$xray_etc" ]; then
            rm -rf "$xray_etc" && xmg_info "已删除: $xray_etc"
        fi

        if command -v systemctl &>/dev/null; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi

        xmg_info "Xray 系统级配置已清理"
    else
        xmg_info "保留 Xray 系统级配置"
    fi
}

# ===== 卸载主流程 =====

xmg_uninstall_run() {
    xmg_require_root

    echo
    echo "========== XMG 卸载 =========="
    echo "将执行以下操作："
    echo "  1. 停止 XMG 托管的服务（Caddy、Xray）"
    echo "  2. 删除命令入口: $XMG_LINK"
    echo "  3. 删除 XMG 统一目录: $XMG_HOME"
    echo "  4. 可选清理 Caddy 系统级配置"
    echo "  5. 可选清理 Xray 系统级配置"
    echo
    echo "以下内容将被删除："
    echo "  - 主程序: $XMG_BIN"
    echo "  - 模块: $XMG_LIB_DIR"
    echo "  - 配置: $XMG_ETC_DIR"
    echo "  - 日志: $XMG_LOG_DIR"
    echo "  - 站点: $XMG_WWW_DIR"
    echo "  - 运行时: $XMG_RUN_DIR"
    echo "  - 备份: $XMG_BACKUP_DIR"
    echo "  - Caddy 配置: $XMG_CADDY_DIR"
    echo "  - Xray 配置: $XMG_XRAY_DIR"
    echo

    if ! xmg_confirm "确认卸载 XMG？此操作不可撤销"; then
        xmg_info "已取消卸载"
        return 0
    fi

    echo

    # 第一步：停止服务
    xmg_uninstall_stop_services

    # 第二步：删除命令入口
    xmg_uninstall_remove_command_link

    # 第三步：删除 XMG 统一目录
    if [ "$XMG_UNINSTALL_KEEP_BACKUPS" = "1" ]; then
        xmg_info "保留备份目录: $XMG_BACKUP_DIR"
        # 先删除除备份外的所有子目录
        for dir in "$XMG_BIN_DIR" "$XMG_LIB_DIR" "$XMG_ETC_DIR" "$XMG_RUN_DIR" "$XMG_LOG_DIR" "$XMG_WWW_DIR" "$XMG_CADDY_DIR" "$XMG_XRAY_DIR"; do
            if [ -d "$dir" ]; then
                rm -rf "$dir" && xmg_info "已删除: $dir" || xmg_warn "删除失败: $dir"
            fi
        done
        xmg_warn "备份目录已保留: $XMG_BACKUP_DIR"
        xmg_warn "如需手动清理，请执行: sudo rm -rf $XMG_BACKUP_DIR"
    else
        xmg_uninstall_remove_xmg_home
    fi

    # 第四步：可选清理 Caddy 系统级配置
    echo
    xmg_uninstall_cleanup_caddy

    # 第五步：可选清理 Xray 系统级配置
    echo
    xmg_uninstall_cleanup_xray

    # 完成
    echo
    xmg_info "========== XMG 卸载完成 =========="
    echo
    xmg_info "已删除的 XMG 自身文件："
    xmg_info "  $XMG_LINK"
    xmg_info "  $XMG_HOME"
    echo
    xmg_warn "如果系统中仍安装有 Caddy 或 Xray 二进制，它们不会受影响"
    xmg_warn "如需完全移除 Caddy/Xray，请使用系统的包管理器卸载"
    echo
    xmg_warn "如果之前通过包管理器安装了 Caddy:"
    xmg_warn "  apt-get remove caddy"
    xmg_warn "  dnf remove caddy"
    xmg_warn "  yum remove caddy"
    echo
    xmg_warn "如果之前通过 Xray 官方脚本安装了 Xray:"
    xmg_warn "  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove"
}

# ===== 卸载菜单 =====

xmg_uninstall_menu() {
    local choice=""

    while true; do
        clear
        echo "========== XMG 卸载管理 =========="
        echo "1. 执行标准卸载"
        echo "2. 执行卸载（保留备份）"
        echo "3. 执行卸载（保留备份、保留 Caddy/Xray 配置）"
        echo "0. 返回"
        echo
        echo "当前目录:"
        echo "  XMG_HOME: $XMG_HOME"
        echo "  命令入口: $XMG_LINK"
        echo
        echo "说明:"
        echo "  - 卸载会删除 $XMG_HOME 下的所有文件"
        echo "  - 不会删除系统已安装的 Caddy/Xray 二进制"
        echo "  - 可选项保留备份目录以备未来恢复参考"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                XMG_UNINSTALL_KEEP_BACKUPS=0
                XMG_UNINSTALL_KEEP_CADDY=0
                XMG_UNINSTALL_KEEP_XRAY=0
                xmg_uninstall_run
                xmg_pause
                ;;
            2)
                XMG_UNINSTALL_KEEP_BACKUPS=1
                XMG_UNINSTALL_KEEP_CADDY=0
                XMG_UNINSTALL_KEEP_XRAY=0
                xmg_uninstall_run
                xmg_pause
                ;;
            3)
                XMG_UNINSTALL_KEEP_BACKUPS=1
                XMG_UNINSTALL_KEEP_CADDY=1
                XMG_UNINSTALL_KEEP_XRAY=1
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
