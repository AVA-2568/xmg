#!/usr/bin/env bash

# ===== 安全加载 =====
if [ "${XMG_CADDY_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_CADDY_SH_LOADED=1

XMG_CADDY_SERVICE="${XMG_CADDY_SERVICE:-caddy}"

xmg_caddy_install_update() {
    xmg_require_root
    xmg_info "安装/更新 Caddy"

    if xmg_cmd_exists apt-get; then
        apt-get update || xmg_die "apt update 失败"

        apt-get install -y \
            debian-keyring \
            debian-archive-keyring \
            apt-transport-https \
            curl \
            gnupg \
            || xmg_die "安装依赖失败"

        mkdir -p /usr/share/keyrings

        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
            || xmg_die "导入 Caddy GPG key 失败"

        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list \
            || xmg_die "写入 Caddy APT 源失败"

        chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
        chmod o+r /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true

        apt-get update || xmg_die "apt update 失败"
        apt-get install -y caddy || xmg_die "安装 Caddy 失败"

    elif xmg_cmd_exists dnf; then
        # Fedora 默认仓库可能已有 caddy；RHEL/CentOS 常需要 COPR
        dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
        dnf copr enable -y @caddy/caddy >/dev/null 2>&1 || true
        dnf install -y caddy || xmg_die "dnf 安装 Caddy 失败"

    elif xmg_cmd_exists yum; then
        yum install -y yum-plugin-copr >/dev/null 2>&1 || true
        yum copr enable -y @caddy/caddy >/dev/null 2>&1 || true
        yum install -y caddy || xmg_die "yum 安装 Caddy 失败"

    else
        xmg_die "未支持的系统：未检测到 apt-get / dnf / yum"
    fi

    # 尽量统一服务行为；失败不阻断安装结果
    if xmg_cmd_exists systemctl; then
        systemctl enable "$XMG_CADDY_SERVICE" >/dev/null 2>&1 || true
        systemctl start "$XMG_CADDY_SERVICE" >/dev/null 2>&1 || true
    fi

    xmg_info "Caddy 安装/更新完成"
    xmg_warn "XMG 不处理 Caddyfile，请用户自行维护配置"
}

xmg_caddy_uninstall() {
    xmg_require_root
    xmg_warn "卸载 Caddy"

    if xmg_cmd_exists apt-get; then
        apt-get remove -y caddy || xmg_die "卸载 Caddy 失败"
        return 0
    fi

    if xmg_cmd_exists dnf; then
        dnf remove -y caddy || xmg_die "卸载 Caddy 失败"
        return 0
    fi

    if xmg_cmd_exists yum; then
        yum remove -y caddy || xmg_die "卸载 Caddy 失败"
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

xmg_caddy_status() {
    if ! xmg_cmd_exists systemctl; then
        xmg_warn "systemctl 不存在，无法查看 Caddy 状态"
        return 1
    fi

    systemctl status "$XMG_CADDY_SERVICE" --no-pager || true
}

xmg_caddy_menu() {
    local choice=""

    while true; do
        clear
        echo "========== Caddy 管理 =========="
        echo "1. 安装/更新"
        echo "2. 卸载"
        echo "3. 启动"
        echo "4. 停止"
        echo "5. 重启"
        echo "6. 状态"
        echo "0. 返回"
        echo
        echo "说明: XMG 只管理 Caddy 服务生命周期，不创建/编辑/校验 Caddyfile。"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1) xmg_caddy_install_update; xmg_pause ;;
            2) xmg_caddy_uninstall; xmg_pause ;;
            3) xmg_caddy_start; xmg_pause ;;
            4) xmg_caddy_stop; xmg_pause ;;
            5) xmg_caddy_restart; xmg_pause ;;
            6) xmg_caddy_status; xmg_pause ;;
            0) return 0 ;;
            *) xmg_warn "无效选择"; xmg_pause ;;
        esac
    done
}
