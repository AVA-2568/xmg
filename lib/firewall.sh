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

# XMG_MENU_LABEL: 防火墙管理

# ===== 依赖加载 =====
_XMG_FW_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F xmg_info >/dev/null 2>&1; then
    if [ -f "$_XMG_FW_LIBDIR/common.sh" ]; then
        # shellcheck source=lib/common.sh
        source "$_XMG_FW_LIBDIR/common.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/common.sh" ]; then
        # shellcheck source=lib/common.sh
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/common.sh"
    fi
fi

if ! declare -F xmg_ssh_effective >/dev/null 2>&1; then
    if [ -f "$_XMG_FW_LIBDIR/ssh.sh" ]; then
        # shellcheck source=lib/ssh.sh
        source "$_XMG_FW_LIBDIR/ssh.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/ssh.sh" ]; then
        # shellcheck source=lib/ssh.sh
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/ssh.sh"
    fi
fi

# ===== 依赖兜底 =====
if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info()  { printf '[INFO] %s\n' "$*"; }
fi
if ! declare -F xmg_warn >/dev/null 2>&1; then
    xmg_warn()  { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_error >/dev/null 2>&1; then
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_die >/dev/null 2>&1; then
    xmg_die()   { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fi
if ! declare -F xmg_cmd_exists >/dev/null 2>&1; then
    xmg_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
fi
if ! declare -F xmg_require_root >/dev/null 2>&1; then
    xmg_require_root() {
        if [ "$(id -u)" -ne 0 ]; then
            xmg_die "请使用 root 用户运行，或使用 sudo 执行"
        fi
    }
fi
if ! declare -F xmg_confirm >/dev/null 2>&1; then
    xmg_confirm() {
        local prompt="${1:-确认继续?}"
        local answer=""
        printf '%s [y/N]: ' "$prompt"
        read -r answer || return 1
        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            *) return 1 ;;
        esac
    }
fi
if ! declare -F xmg_pause >/dev/null 2>&1; then
    xmg_pause() {
        printf '\n按 Enter 返回...'
        read -r _ || true
    }
fi

XMG_UFW_DEFAULT_CONF="${XMG_UFW_DEFAULT_CONF:-/etc/default/ufw}"

xmg_firewall_need_ufw() {
    if ! xmg_cmd_exists ufw; then
        xmg_die "ufw 未安装，请先在菜单中执行「安装 UFW」，或手动: apt-get install -y ufw"
    fi
}

# 检查并纠偏 /etc/default/ufw 中的 IPV6=yes
xmg_firewall_fix_ipv6() {
    local ufw_conf="${XMG_UFW_DEFAULT_CONF:-/etc/default/ufw}"
    [ -f "$ufw_conf" ] || return 0

    if grep -qiE '^[[:space:]]*IPV6=[[:space:]]*no' "$ufw_conf"; then
        xmg_warn "检测到 $ufw_conf 中配置为 IPV6=no，正在自动修正为 IPV6=yes 防止 IPv6 流量阻断..."
        sed -i -E 's/^[[:space:]]*IPV6=[[:space:]]*no/IPV6=yes/I' "$ufw_conf" \
            && xmg_info "已修正 $ufw_conf: IPV6=yes" \
            || xmg_warn "修正 $ufw_conf 失败，请手动确认 IPV6 配置"
    fi
}

# Debian 默认不带 ufw（Ubuntu 预装），提供一键安装
xmg_firewall_install() {
    xmg_require_root

    if xmg_cmd_exists ufw; then
        xmg_info "ufw 已安装: $(command -v ufw)"
        return 0
    fi

    if ! xmg_cmd_exists apt-get; then
        xmg_die "未检测到 apt-get，请手动安装 ufw"
    fi

    xmg_info "使用 apt 安装 ufw（不执行 apt-get update）"

    if apt-get install -y ufw; then
        xmg_info "ufw 安装完成"
    else
        xmg_warn "apt 安装 ufw 失败，APT 缓存可能过期"
        xmg_warn "可手动执行: apt-get update && apt-get install -y ufw"
        return 1
    fi
}

xmg_firewall_status() {
    xmg_firewall_need_ufw
    ufw status verbose || true
}

xmg_firewall_allow_basic() {
    xmg_require_root
    xmg_firewall_need_ufw

    xmg_firewall_fix_ipv6

    ufw allow 22/tcp comment 'XMG SSH' || xmg_die "放行 22/tcp 失败"
    ufw allow 80/tcp comment 'XMG HTTP' || xmg_die "放行 80/tcp 失败"
    ufw allow 443/tcp comment 'XMG HTTPS' || xmg_die "放行 443/tcp 失败"

    local cur_ssh_port=""
    if declare -F xmg_ssh_effective >/dev/null 2>&1; then
        cur_ssh_port="$(xmg_ssh_effective port 2>/dev/null || true)"
    fi

    case "$cur_ssh_port" in
        ''|*[!0-9]*)
            ;;
        *)
            if [ "$cur_ssh_port" -ge 1 ] && [ "$cur_ssh_port" -le 65535 ]; then
                if [ "$cur_ssh_port" -ne 22 ]; then
                    ufw allow "${cur_ssh_port}/tcp" comment "XMG SSH ${cur_ssh_port}" \
                        || xmg_die "自适应放行自定义 SSH 端口 ${cur_ssh_port}/tcp 失败"
                    xmg_info "检测到当前生效 SSH 端口为 ${cur_ssh_port}，已自适应放行 ${cur_ssh_port}/tcp 防锁死"
                fi
            fi
            ;;
    esac

    xmg_info "已放行 22/tcp、80/tcp、443/tcp"
    if [ -n "$cur_ssh_port" ] && [ "$cur_ssh_port" != "22" ]; then
        xmg_info "已同步放行自定义 SSH 端口: ${cur_ssh_port}/tcp"
    else
        xmg_warn "如果 SSH 不是 22 端口，请自行放行真实 SSH 端口"
    fi
}

xmg_firewall_allow_custom_port() {
    local port="${1:-}"
    local proto="${2:-}"

    xmg_require_root
    xmg_firewall_need_ufw

    if [ -z "$port" ]; then
        printf "请输入要放行的端口号: "
        read -r port || return 1
    fi

    case "$port" in
        ''|*[!0-9]*)
            xmg_warn "端口号无效: '$port'"
            return 1
            ;;
    esac

    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        xmg_warn "端口号范围应为 1-65535: '$port'"
        return 1
    fi

    if [ -z "$proto" ]; then
        if [ "$#" -ge 2 ]; then
            proto="tcp"
        elif [ "$#" -eq 1 ]; then
            proto="tcp"
        else
            printf "请输入协议 tcp/udp，默认 tcp: "
            read -r proto || proto="tcp"
        fi
    fi
    proto="${proto:-tcp}"

    case "$proto" in
        tcp|udp)
            ;;
        *)
            xmg_warn "协议无效，只支持 tcp 或 udp: '$proto'"
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

    xmg_firewall_fix_ipv6

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
        echo "6. 安装 UFW"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - 当前模块只做最基础的 UFW 管理"
        echo "  - Ubuntu 预装 UFW，Debian 可通过选项 6 安装"
        echo "  - 启用前请确认 SSH 端口已经放行，避免远程断连"
        echo "  - 如果服务器还使用云安全组，请同时检查云平台入站规则"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_firewall_status || true
                xmg_pause
                ;;
            2)
                xmg_firewall_allow_basic || true
                xmg_pause
                ;;
            3)
                xmg_firewall_allow_custom_port || true
                xmg_pause
                ;;
            4)
                xmg_firewall_enable || true
                xmg_pause
                ;;
            5)
                xmg_firewall_disable || true
                xmg_pause
                ;;
            6)
                xmg_firewall_install || true
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
