#!/usr/bin/env bash

# ===== 安全加载 =====
if [ "${XMG_CADDY_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_CADDY_SH_LOADED=1

XMG_CADDY_SERVICE="${XMG_CADDY_SERVICE:-caddy}"

# ===== 核心函数 =====
xmg_caddy_install_update() {
    xmg_require_root

    xmg_info "安装/更新 Caddy"

    if xmg_cmd_exists apt-get; then
        apt-get update || xmg_die "apt update 失败"
        apt-get install -y curl gnupg || xmg_die "依赖失败"

        curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
            | gpg --dearmor -o /usr/share/keyrings/caddy.gpg \
            || xmg_die "key 导入失败"

        cat > /etc/apt/sources.list.d/caddy.list <<EOF
deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/debian any-version main
EOF

        apt-get update || xmg_die "apt update 失败"
        apt-get install -y caddy || xmg_die "安装失败"

        return 0
    fi

    if xmg_cmd_exists dnf; then
        dnf install -y caddy && return 0
    fi

    xmg_die "未支持的系统"
}

xmg_caddy_uninstall() {
    xmg_require_root

    xmg_warn "卸载 Caddy"

    if xmg_cmd_exists apt-get; then
        apt-get remove -y caddy
        return
    fi

    if xmg_cmd_exists dnf; then
        dnf remove -y caddy
        return
    fi
}

xmg_caddy_start() {
    xmg_systemctl start "$XMG_CADDY_SERVICE"
    xmg_info "已启动"
}

xmg_caddy_stop() {
    xmg_systemctl stop "$XMG_CADDY_SERVICE"
    xmg_info "已停止"
}

xmg_caddy_restart() {
    xmg_systemctl restart "$XMG_CADDY_SERVICE"
    xmg_info "已重启"
}

xmg_caddy_status() {
    systemctl status "$XMG_CADDY_SERVICE" --no-pager || true
}

xmg_caddy_logs() {
    journalctl -u "$XMG_CADDY_SERVICE" -n 80 --no-pager || true
}

# ===== 菜单 =====
xmg_caddy_menu() {
    local choice

    while true; do
        clear
        echo "========== Caddy 管理 =========="
        echo "1. 安装/更新"
        echo "2. 卸载"
        echo "3. 启动"
        echo "4. 停止"
        echo "5. 重启"
        echo "6. 状态"
        echo "7. 日志"
        echo "0. 返回"
        printf "请选择: "

        read -r choice

        case "$choice" in
            1) xmg_caddy_install_update ;;
            2) xmg_caddy_uninstall ;;
            3) xmg_caddy_start ;;
            4) xmg_caddy_stop ;;
            5) xmg_caddy_restart ;;
            6) xmg_caddy_status ;;
            7) xmg_caddy_logs ;;
            0) return ;;
            *) xmg_warn "错误输入" ;;
        esac

        xmg_pause
    done
}
``
