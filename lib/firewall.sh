#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# firewall.sh - XMG 防火墙管理模块
#
# 说明：
#   - 本模块只做基础 UFW 管理
#   - 默认放行 22/tcp、80/tcp、443/tcp
#   - 启用 UFW 前会提示用户确认，避免 SSH 断连
#   - 文件内容应使用 UTF-8 编码保存
#

# ===== 安全加载 =====
if [ "${XMG_FIREWALL_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_FIREWALL_SH_LOADED=1

xmg_firewall_need_ufw() {
    if ! xmg_cmd_exists ufw; then
        xmg_die "ufw 不存在，请先安装 ufw，或使用云安全组 / iptables / nftables 手动管理防火墙"
    fi
}

xmg_firewall_status() {
    xmg_firewall_need_ufw
    ufw status verbose || true
}

xmg_firewall_allow_basic() {
    xmg_require_root
    xmg_firewall_need_ufw

    ufw allow 22/tcp comment 'XMG SSH' || xmg_die "放行 22/tcp 失败"
    ufw allow 80/tcp comment 'XMG HTTP' || xmg_die "放行 80/tcp 失败"
    ufw allow 443/tcp comment 'XMG HTTPS' || xmg_die "放行 443/tcp 失败"

    xmg_info "已放行 22/tcp、80/tcp、443/tcp"
    xmg_warn "如果 SSH 不是 22 端口，请自行放行真实 SSH 端口"
}

xmg_firewall_allow_custom_port() {
    local port=""
    local proto="tcp"

    xmg_require_root
    xmg_firewall_need_ufw

    printf "请输入要放行的端口号: "
    read -r port || return 1

    case "$port" in
        ''|*[!0-9]*)
            xmg_warn "端口号无效"
            return 1
            ;;
    esac

    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        xmg_warn "端口号范围应为 1-65535"
        return 1
    fi

    printf "请输入协议 tcp/udp，默认 tcp: "
    read -r proto || proto="tcp"

    case "${proto:-tcp}" in
        tcp|udp)
            ;;
        *)
            xmg_warn "协议无效，只支持 tcp 或 udp"
            return 1
            ;;
    esac

    ufw allow "${port}/${proto}" comment "XMG custom ${port}/${proto}" \
        || xmg_die "放行 ${port}/${proto} 失败"

    xmg_info "已放行 ${port}/${proto}"
}

xmg_firewall_enable() {
    xmg_require_root
    xmg_firewall_need_ufw

    xmg_warn "启用 UFW 可能导致当前 SSH 连接断开，请确认 SSH 端口已经放行"
    xmg_warn "建议先执行“放行 SSH/HTTP/HTTPS”，再启用 UFW"

    if xmg_confirm "确认启用 UFW 并设置默认策略为 deny incoming / allow outgoing?"; then
        ufw default deny incoming || xmg_die "设置默认入站策略失败"
        ufw default allow outgoing || xmg_die "设置默认出站策略失败"
        ufw --force enable || xmg_die "启用 UFW 失败"
        ufw status verbose || true
    else
        xmg_info "已取消"
    fi
}

xmg_firewall_disable() {
    xmg_require_root
    xmg_firewall_need_ufw

    if xmg_confirm "确认禁用 UFW?"; then
        ufw disable || xmg_die "禁用 UFW 失败"
        xmg_info "UFW 已禁用"
    else
        xmg_info "已取消"
    fi
}

xmg_firewall_menu() {
    local choice=""

    while true; do
        clear
        echo "========== 防火墙管理 =========="
        echo "1. 查看 UFW 状态"
        echo "2. 放行 SSH/HTTP/HTTPS"
        echo "3. 放行自定义端口"
        echo "4. 启用 UFW"
        echo "5. 禁用 UFW"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - 当前模块只做最基础的 UFW 管理"
        echo "  - 启用前请确认 SSH 端口已经放行，避免远程断连"
        echo "  - 如果服务器还使用云安全组，请同时检查云平台入站规则"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_firewall_status
                xmg_pause
                ;;
            2)
                xmg_firewall_allow_basic
                xmg_pause
                ;;
            3)
                xmg_firewall_allow_custom_port
                xmg_pause
                ;;
            4)
                xmg_firewall_enable
                xmg_pause
                ;;
            5)
                xmg_firewall_disable
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
