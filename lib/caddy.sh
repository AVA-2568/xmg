#!/usr/bin/env bash

[ "${XMG_CADDY_SH_LOADED:-0}" = "1" ] && return 0
XMG_CADDY_SH_LOADED=1

XMG_CADDY_SERVICE="${XMG_CADDY_SERVICE:-caddy}"

xmg_caddy_binary_exists() {
    xmg_cmd_exists caddy
}

xmg_caddy_install_update_apt() {
    xmg_info "使用 apt-get 安装/更新 Caddy"

    apt-get update
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg

    if [ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]; then
        curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    fi

    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list

    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true

    apt-get update
    apt-get install -y caddy
}

xmg_caddy_install_update_dnf() {
    xmg_info "使用 dnf 安装/更新 Caddy"

    dnf install -y dnf-plugins-core || true
    dnf copr enable -y @caddy/caddy || true
    dnf install -y caddy
}

xmg_caddy_install_update() {
    xmg_require_root

    if xmg_caddy_binary_exists; then
        xmg_warn "检测到 Caddy 已存在，本操作将执行安装/更新"
        if ! xmg_confirm "是否继续?"; then
            xmg_info "已取消"
            return 0
        fi
    fi

    if xmg_cmd_exists apt-get; then
        xmg_caddy_install_update_apt
        xmg_info "Caddy 安装/更新完成"
        xmg_warn "XMG 不处理 Caddyfile，请用户自行维护配置"
        return 0
    fi

    if xmg_cmd_exists dnf; then
        xmg_caddy_install_update_dnf
        xmg_info "Caddy 安装/更新完成"
        xmg_warn "XMG 不处理 Caddyfile，请用户自行维护配置"
        return 0
    fi

    xmg_die "未识别可用包管理器，请用户自行安装/更新 Caddy"
}

# 兼容旧调用名
xmg_caddy_install() {
    xmg_caddy_install_update
}

xmg_caddy_uninstall() {
    xmg_require_root

    xmg_warn "即将卸载 Caddy"
    xmg_warn "XMG 不负责备份或删除用户自定义 Caddyfile"

    if ! xmg_confirm "确认卸载 Caddy?"; then
        xmg_info "已取消"
        return 0
    fi

    if xmg_cmd_exists apt-get; then
        apt-get remove -y caddy || true
        xmg_info "Caddy 已卸载"
        return 0
    fi

    if xmg_cmd_exists dnf; then
        dnf remove -y caddy || true
        xmg_info "Caddy 已卸载"
        return 0
    fi

    if xmg_cmd_exists yum; then
        yum remove -y caddy || true
        xmg_info "Caddy 已卸载"
        return 0
    fi

    xmg_die "未识别可用包管理器，请用户自行卸载 Caddy"
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

xmg_caddy_logs() {
    clear
    echo "========== Caddy 日志 =========="
    echo

    if xmg_cmd_exists journalctl; then
        journalctl -u "$XMG_CADDY_SERVICE" -n 80 --no-pager 2>/dev/null || true
        return 0
    fi

    xmg_warn "journalctl 不存在，无法查看 Caddy 日志"
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
        echo "6. 查看 Caddy 状态"
        echo "7. 查看 Caddy 日志"
        echo "0. 返回"
        echo
        echo "说明: XMG 只管理 Caddy 服务生命周期，不创建/编辑/校验 Caddyfile。"
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
                xmg_caddy_status
                xmg_pause
                ;;
            7)
                xmg_caddy_logs
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
``
