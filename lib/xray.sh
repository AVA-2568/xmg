#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# xray.sh - XMG Xray 管理模块
#
# 说明：
#   - 本模块只管理 Xray 的安装、更新、卸载和服务生命周期
#   - 本模块不创建、不编辑、不校验 Xray 配置文件
#   - 本模块依赖官方 Xray-install 安装脚本
#   - 文件内容应使用 UTF-8 编码保存
#

# xray.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "xray.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_XRAY_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_XRAY_SH_LOADED=1

XMG_XRAY_SERVICE="${XMG_XRAY_SERVICE:-xray}"
XMG_XRAY_INSTALL_SCRIPT_URL="${XMG_XRAY_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh}"

xmg_xray_binary_exists() {
    xmg_cmd_exists xray
}

xmg_xray_service_exists() {
    xmg_cmd_exists systemctl || return 1
    systemctl cat "$XMG_XRAY_SERVICE" >/dev/null 2>&1
}

xmg_xray_fetch_install_script() {
    local tmp=""

    xmg_require_root

    if ! xmg_cmd_exists curl; then
        xmg_die "curl 不存在，无法下载 Xray 安装脚本"
    fi

    tmp="$(mktemp)" || xmg_die "创建临时文件失败"

    if ! curl -fsSL "$XMG_XRAY_INSTALL_SCRIPT_URL" -o "$tmp"; then
        rm -f -- "$tmp"
        xmg_die "下载 Xray 安装脚本失败"
    fi

    if [ ! -s "$tmp" ]; then
        rm -f -- "$tmp"
        xmg_die "下载到的 Xray 安装脚本为空"
    fi

    chmod +x "$tmp" || {
        rm -f -- "$tmp"
        xmg_die "设置 Xray 安装脚本执行权限失败"
    }

    printf '%s\n' "$tmp"
}

xmg_xray_run_installer() {
    local action="$1"
    shift || true

    local script=""
    local rc=0

    script="$(xmg_xray_fetch_install_script)"

    bash "$script" "$action" "$@" || rc=$?

    rm -f -- "$script"

    return "$rc"
}

xmg_xray_install_update() {
    xmg_require_root

    if xmg_xray_binary_exists; then
        xmg_warn "检测到 Xray 已存在，本操作将执行安装/更新"
        if ! xmg_confirm "是否继续?"; then
            xmg_info "已取消"
            return 0
        fi
    fi

    xmg_info "开始安装/更新 Xray..."

    if ! xmg_xray_run_installer install; then
        xmg_die "Xray 安装/更新失败"
    fi

    xmg_info "Xray 安装/更新完成"
    xmg_warn "XMG 不处理 Xray 配置文件，请用户自行维护配置"
}

# 兼容旧调用名
xmg_xray_install() {
    xmg_xray_install_update
}

xmg_xray_update_geodata() {
    xmg_require_root

    xmg_info "开始更新 Xray geodata..."

    if ! xmg_xray_run_installer install-geodata; then
        xmg_die "Xray geodata 更新失败"
    fi

    xmg_info "Xray geodata 更新完成"
}

xmg_xray_uninstall() {
    xmg_require_root

    if ! xmg_xray_binary_exists && ! xmg_xray_service_exists; then
        xmg_warn "未检测到 Xray 已安装"
        return 0
    fi

    xmg_warn "即将卸载 Xray"
    xmg_warn "XMG 不负责备份或删除用户自定义 Xray 配置文件"

    if ! xmg_confirm "确认卸载 Xray?"; then
        xmg_info "已取消"
        return 0
    fi

    if ! xmg_xray_run_installer remove; then
        xmg_die "Xray 卸载失败"
    fi

    xmg_info "Xray 已卸载"
    xmg_warn "官方卸载脚本默认可能保留 json 配置和日志文件，如需彻底清理请用户自行确认后处理"
}

xmg_xray_start() {
    xmg_systemctl start "$XMG_XRAY_SERVICE"
    xmg_info "Xray 已启动"
}

xmg_xray_stop() {
    xmg_systemctl stop "$XMG_XRAY_SERVICE"
    xmg_info "Xray 已停止"
}

xmg_xray_restart() {
    xmg_systemctl restart "$XMG_XRAY_SERVICE"
    xmg_info "Xray 已重启"
}

xmg_xray_status() {
    if ! xmg_cmd_exists systemctl; then
        xmg_warn "systemctl 不存在，无法查看 Xray 状态"
        return 1
    fi

    systemctl status "$XMG_XRAY_SERVICE" --no-pager || true
}

xmg_xray_menu() {
    local choice=""

    while true; do
        clear
        echo "========== Xray 管理 =========="
        echo "1. 安装/更新 Xray"
        echo "2. 更新 Xray geodata"
        echo "3. 卸载 Xray"
        echo "4. 启动 Xray"
        echo "5. 停止 Xray"
        echo "6. 重启 Xray"
        echo "7. 查看 Xray 状态"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - XMG 只管理 Xray 安装和服务生命周期"
        echo "  - XMG 不创建、不编辑、不校验 Xray 配置文件"
        echo "  - 本模块已移除日志查看功能"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_xray_install_update
                xmg_pause
                ;;
            2)
                xmg_xray_update_geodata
                xmg_pause
                ;;
            3)
                xmg_xray_uninstall
                xmg_pause
                ;;
            4)
                xmg_xray_start
                xmg_pause
                ;;
            5)
                xmg_xray_stop
                xmg_pause
                ;;
            6)
                xmg_xray_restart
                xmg_pause
                ;;
            7)
                xmg_xray_status
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
