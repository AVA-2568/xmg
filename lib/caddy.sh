#!/usr/bin/env bash
#
# caddy.sh - Caddy 安装和配置管理
#

install_caddy() {
    info "开始安装 Caddy..."

    install_base_deps

    if command -v caddy >/dev/null 2>&1; then
        ok "Caddy 已安装：$(caddy version)"
        return 0
    fi

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null

    apt-get update
    apt-get install -y caddy

    systemctl enable caddy
    systemctl restart caddy || true

    ok "Caddy 安装完成"
    caddy version || true
}

uninstall_caddy() {
    warn "即将卸载 Caddy，但保留 /etc/caddy 目录"

    if confirm "确认卸载 Caddy?"; then
        systemctl stop caddy || true
        apt-get remove -y caddy || true
        ok "Caddy 已卸载"
    else
        warn "已取消"
    fi
}

create_empty_caddyfile() {
    mkdir -p /etc/caddy /var/log/caddy "${WEB_ROOT}"

    if [[ -f "${CADDYFILE}" ]]; then
        backup_file "${CADDYFILE}"
        warn "Caddyfile 已存在，已先备份"
    fi

    if [[ ! -f "${CADDYFILE}" ]]; then
        cat > "${CADDYFILE}" <<EOF
# 请在这里编写你的 Caddy 配置
# 示例：
#
# example.com {
#     root * ${WEB_ROOT}
#     file_server
# }
EOF
        ok "已创建空 Caddyfile：${CADDYFILE}"
    else
        ok "Caddyfile 已存在：${CADDYFILE}"
    fi
}

edit_caddyfile() {
    mkdir -p /etc/caddy

    if [[ ! -f "${CADDYFILE}" ]]; then
        create_empty_caddyfile
    fi

    backup_file "${CADDYFILE}"
    "${EDITOR:-nano}" "${CADDYFILE}"

    if command -v caddy >/dev/null 2>&1; then
        if caddy validate --config "${CADDYFILE}"; then
            systemctl reload caddy || systemctl restart caddy
            ok "Caddy 配置校验通过并已重载"
        else
            err "Caddy 配置校验失败，请修复后再重载"
        fi
    else
        warn "Caddy 未安装，跳过校验"
    fi
}

check_caddyfile() {
    if ! command -v caddy >/dev/null 2>&1; then
        err "Caddy 未安装"
        return 1
    fi

    if [[ ! -f "${CADDYFILE}" ]]; then
        err "Caddyfile 不存在：${CADDYFILE}"
        return 1
    fi

    caddy validate --config "${CADDYFILE}"
}

reload_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        err "Caddy 未安装"
        return 1
    fi

    check_caddyfile
    systemctl reload caddy || systemctl restart caddy
    ok "Caddy 已重载"
}

caddy_menu() {
    while true; do
        clear
        echo "========== Caddy 管理 =========="
        echo "1. 安装 Caddy"
        echo "2. 卸载 Caddy"
        echo "3. 启动 Caddy"
        echo "4. 停止 Caddy"
        echo "5. 重启 Caddy"
        echo "6. 查看 Caddy 状态"
        echo "7. 创建空 Caddyfile"
        echo "8. 编辑 Caddyfile"
        echo "9. 校验 Caddyfile"
        echo "10. 重载 Caddy"
        echo "11. 查看 Caddy 日志"
        echo "0. 返回"
        echo
        read -rp "请选择: " choice

        case "${choice}" in
            1) install_caddy; pause ;;
            2) uninstall_caddy; pause ;;
            3) systemctl start caddy; pause ;;
            4) systemctl stop caddy; pause ;;
            5) systemctl restart caddy; pause ;;
            6) systemctl status caddy --no-pager; pause ;;
            7) create_empty_caddyfile; pause ;;
            8) edit_caddyfile; pause ;;
            9) check_caddyfile; pause ;;
            10) reload_caddy; pause ;;
            11) journalctl -u caddy -n 100 --no-pager; pause ;;
            0) break ;;
            *) warn "无效选择"; pause ;;
        esac
    done
}
