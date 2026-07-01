#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# caddy.sh - Caddy 安装与服务生命周期管理
#
# 说明：
#   - 本模块只管理 Caddy 的安装、卸载、启动、停止、重启和状态查看
#   - 本模块不创建、不编辑、不校验 Caddyfile
#   - 文件内容应使用 UTF-8 编码保存
#

# ===== 安全加载 =====
if [ "${XMG_CADDY_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_CADDY_SH_LOADED=1

XMG_CADDY_SERVICE="${XMG_CADDY_SERVICE:-caddy}"

xmg_caddy_binary_exists() {
    xmg_cmd_exists caddy
}

xmg_caddy_install_update() {
    xmg_require_root
    xmg_info "安装/更新 Caddy"

    if xmg_cmd_exists apt-get; then
        # Debian / Ubuntu / Raspbian 官方推荐依赖
        apt-get update || xmg_die "apt update 失败"

        apt-get install -y \
            debian-keyring \
            debian-archive-keyring \
            apt-transport-https \
            curl \
            gnupg \
            || xmg_die "安装 Caddy 依赖失败"

        mkdir -p /usr/share/keyrings || xmg_die "创建 keyrings 目录失败"

        if ! curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg; then
            xmg_die "导入 Caddy GPG key 失败"
        fi

        if ! curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list; then
            xmg_die "写入 Caddy APT 源失败"
        fi

        chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
        chmod o+r /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true

        apt-get update || xmg_die "apt update 失败"
        apt-get install -y caddy || xmg_die "安装 Caddy 失败"

    elif xmg_cmd_exists dnf; then
        # Fedora / RHEL / CentOS Stream / Rocky / AlmaLinux 8+ 路径
        dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
        dnf copr enable -y @caddy/caddy >/dev/null 2>&1 || true
        dnf install -y caddy || xmg_die "dnf 安装 Caddy 失败"

    elif xmg_cmd_exists yum; then
        # CentOS / RHEL 7 路径
        yum install -y yum-plugin-copr >/dev/null 2>&1 || true
        yum copr enable -y @caddy/caddy >/dev/null 2>&1 || true
        yum install -y caddy || xmg_die "yum 安装 Caddy 失败"

    else
        xmg_die "未支持的系统：未检测到 apt-get / dnf / yum"
    fi

    # 尽量统一安装后的服务行为
    if xmg_cmd_exists systemctl; then
        systemctl enable "$XMG_CADDY_SERVICE" >/dev/null 2>&1 || true
        systemctl start "$XMG_CADDY_SERVICE" >/dev/null 2>&1 || true
    fi

    xmg_info "Caddy 安装/更新完成"
    xmg_warn "XMG 不处理 Caddyfile，请用户自行维护配置"
}

xmg_caddy_uninstall() {
    xmg_require_root

    if ! xmg_caddy_binary_exists; then
        xmg_warn "未检测到 Caddy 命令，可能尚未安装"
    fi

    xmg_warn "即将卸载 Caddy"
    xmg_warn "XMG 不负责备份或删除用户自定义 Caddyfile"

    if ! xmg_confirm "确认卸载 Caddy?"; then
        xmg_info "已取消"
        return 0
    fi

    if xmg_cmd_exists systemctl; then
        systemctl stop "$XMG_CADDY_SERVICE" >/dev/null 2>&1 || true
        systemctl disable "$XMG_CADDY_SERVICE" >/dev/null 2>&1 || true
    fi

    if xmg_cmd_exists apt-get; then
        apt-get remove -y caddy || xmg_die "卸载 Caddy 失败"
        xmg_info "Caddy 已卸载"
        return 0
    fi

    if xmg_cmd_exists dnf; then
        dnf remove -y caddy || xmg_die "卸载 Caddy 失败"
        xmg_info "Caddy 已卸载"
        return 0
    fi

    if xmg_cmd_exists yum; then
        yum remove -y caddy || xmg_die "卸载 Caddy 失败"
        xmg_info "Caddy 已卸载"
        return 0
    fi

    xmg_die "未支持的系统：无法卸载 Caddy"
}

xmg_caddy_start() {
    xmg_systemctl start "$XMG_CADDY_SERVICE"
    xmg_info "Caddy 已启动"
}

xmg_caddy_stop() {
    xmg_systemctl stop "$XMG_CADDY_SERVICE"
    xmg_info "Caddy 已停止"
}

xmg_caddy_restart() {
    xmg_systemctl restart "$XMG_CADDY_SERVICE"
    xmg_info "Caddy 已重启"
}

xmg_caddy_reload() {
    xmg_systemctl reload "$XMG_CADDY_SERVICE"
    xmg_info "Caddy 已重载"
}

xmg_caddy_status() {
    if ! xmg_cmd_exists systemctl; then
        xmg_warn "systemctl 不存在，无法查看 Caddy 状态"
        return 1
    fi

    systemctl status "$XMG_CADDY_SERVICE" --no-pager || true
}

xmg_caddy_validate_config() {
    if ! xmg_caddy_binary_exists; then
        xmg_warn "caddy 命令不存在，无法校验配置"
        return 1
    fi

    if [ -f /etc/caddy/Caddyfile ]; then
        caddy validate --config /etc/caddy/Caddyfile || return 1
    else
        xmg_warn "未找到 /etc/caddy/Caddyfile"
        return 1
    fi
}

xmg_caddy_menu() {
    local choice=""

    while true; do
        clear
        echo "========== Caddy 管理 =========="
        echo "1. 安装/更新 Caddy"
        echo "2. 卸载 Caddy"
        echo "3. 启动 Caddy"
        echo "4. 停止 Caddy"
        echo "5. 重启 Caddy"
        echo "6. 重载 Caddy"
        echo "7. 查看 Caddy 状态"
        echo "8. 校验 Caddyfile"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - XMG 只管理 Caddy 服务生命周期"
        echo "  - XMG 不创建、不编辑、不修改 Caddyfile"
        echo "  - 如需修改站点配置，请自行维护 /etc/caddy/Caddyfile"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_caddy_install_update
                xmg_pause
                ;;
            2)
                xmg_caddy_uninstall
                xmg_pause
                ;;
            3)
                xmg_caddy_start
                xmg_pause
                ;;
            4)
                xmg_caddy_stop
                xmg_pause
                ;;
            5)
                xmg_caddy_restart
                xmg_pause
                ;;
            6)
                xmg_caddy_reload
                xmg_pause
                ;;
            7)
                xmg_caddy_status
                xmg_pause
                ;;
            8)
                xmg_caddy_validate_config
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
