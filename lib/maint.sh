#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# maint.sh - XMG 系统维护模块
#
# 说明：
#   - 一键系统更新、磁盘清理（journal 限容 + apt 缓存）、流量统计 (vnstat)
#   - journal 限容对小盘低配 VPS 是刚需（默认可占 10% 磁盘）
#   - 优先 apt 系 (Debian/Ubuntu)，兼容 dnf/yum 基础操作
#

# maint.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "maint.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_MAINT_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 1
fi
XMG_MAINT_SH_LOADED=1

# XMG_MENU_LABEL: 系统维护

# ===== 默认配置 =====
XMG_MAINT_JOURNAL_MAX="${XMG_MAINT_JOURNAL_MAX:-50M}"
XMG_MAINT_JOURNALD_CONF="${XMG_MAINT_JOURNALD_CONF:-/etc/systemd/journald.conf.d/00-xmg.conf}"

# ===== 依赖 common.sh 的兜底 =====

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

# ===== 一键系统更新 =====

xmg_maint_update() {
    xmg_require_root

    xmg_warn "即将执行系统更新（可能耗时较长，内核更新后需重启）"

    if ! xmg_confirm "确认执行系统更新?"; then
        xmg_info "已取消"
        return 0
    fi

    if xmg_cmd_exists apt-get; then
        export DEBIAN_FRONTEND=noninteractive

        xmg_info "apt-get update..."
        apt-get update || xmg_warn "apt-get update 存在错误（个别第三方源失败不影响主体）"

        xmg_info "apt-get upgrade..."
        apt-get upgrade -y || xmg_error "apt-get upgrade 失败"

        xmg_info "apt-get autoremove..."
        apt-get autoremove --purge -y >/dev/null 2>&1 || true

        if [ -f /var/run/reboot-required ]; then
            xmg_warn "系统提示需要重启才能完成更新 (reboot-required)"
        fi
    elif xmg_cmd_exists dnf; then
        dnf upgrade -y || xmg_error "dnf upgrade 失败"
        xmg_warn "如更新了内核，请重启: reboot"
    elif xmg_cmd_exists yum; then
        yum update -y || xmg_error "yum update 失败"
        xmg_warn "如更新了内核，请重启: reboot"
    else
        xmg_die "未检测到 apt-get / dnf / yum"
    fi

    xmg_info "系统更新完成"
}

# ===== 一键磁盘清理 =====

# journal 持久化限容，避免小盘被日志吃满
xmg_maint_journal_limit() {
    if ! xmg_cmd_exists journalctl; then
        return 0
    fi

    mkdir -p "$(dirname "$XMG_MAINT_JOURNALD_CONF")"
    cat > "$XMG_MAINT_JOURNALD_CONF" <<EOF
# XMG: journald 限容（由 xmg maint 生成）
[Journal]
SystemMaxUse=$XMG_MAINT_JOURNAL_MAX
EOF

    systemctl restart systemd-journald >/dev/null 2>&1 || true
    xmg_info "journald 已限容 $XMG_MAINT_JOURNAL_MAX: $XMG_MAINT_JOURNALD_CONF"
}

xmg_maint_clean() {
    xmg_require_root

    local before=""
    local after=""

    before="$(df -h / 2>/dev/null | awk 'NR==2 {print $3"/"$2" ("$5")"}')"

    echo "清理前磁盘 /: $before"
    echo

    if xmg_confirm "确认执行磁盘清理? (journal 限容 + apt 缓存 + 旧包)"; then
        if xmg_cmd_exists journalctl; then
            xmg_info "journal 压缩到 $XMG_MAINT_JOURNAL_MAX..."
            journalctl --vacuum-size="$XMG_MAINT_JOURNAL_MAX" 2>/dev/null | tail -1 || true
            xmg_maint_journal_limit
        fi

        if xmg_cmd_exists apt-get; then
            export DEBIAN_FRONTEND=noninteractive

            xmg_info "清理 apt 缓存..."
            apt-get clean

            xmg_info "清理不再需要的包..."
            apt-get autoremove --purge -y || xmg_warn "autoremove 失败"
        elif xmg_cmd_exists dnf; then
            dnf clean all || true
        elif xmg_cmd_exists yum; then
            yum clean all || true
        fi

        after="$(df -h / 2>/dev/null | awk 'NR==2 {print $3"/"$2" ("$5")"}')"
        echo
        echo "清理后磁盘 /: $after"
        xmg_info "磁盘清理完成"
    else
        xmg_info "已取消"
    fi
}

# ===== 流量统计 (vnstat) =====

xmg_maint_vnstat() {
    xmg_require_root

    if ! xmg_cmd_exists apt-get; then
        xmg_die "本模块仅支持 apt 系 (Debian/Ubuntu)"
    fi

    if ! xmg_cmd_exists vnstat; then
        xmg_info "安装 vnstat..."
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get install -y vnstat; then
            xmg_error "vnstat 安装失败，可先执行 apt-get update 后重试"
            return 1
        fi
    fi

    systemctl enable --now vnstat >/dev/null 2>&1 || true

    if ! systemctl is-active --quiet vnstat 2>/dev/null; then
        xmg_error "vnstat 服务未运行"
        return 1
    fi

    echo
    echo "== 本月流量 =="
    vnstat -m 2>/dev/null || vnstat 2>/dev/null || true
    xmg_info "vnstat 已启用（数据从安装时刻开始累计）"
}

# ===== 磁盘占用概览 =====

xmg_maint_disk_overview() {
    echo "== 磁盘分区 =="
    df -h 2>/dev/null || true
    echo

    echo "== journal 占用 =="
    journalctl --disk-usage 2>/dev/null || echo "journalctl 不可用"
    echo

    echo "== apt 缓存占用 =="
    if [ -d /var/cache/apt ]; then
        du -sh /var/cache/apt 2>/dev/null || true
    else
        echo "无 apt 缓存目录"
    fi
    echo

    echo "== /opt/xmg 占用 =="
    if [ -d "$XMG_HOME" ]; then
        du -sh "$XMG_HOME" 2>/dev/null || true
    else
        echo "$XMG_HOME 不存在"
    fi
}

# ===== 菜单 =====

xmg_maint_menu() {
    local choice=""

    while true; do
        clear
        echo "========== 系统维护 =========="
        echo "1. 一键系统更新"
        echo "2. 一键磁盘清理"
        echo "3. 流量统计 (vnstat)"
        echo "4. 磁盘占用概览"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - 磁盘清理会同时把 journal 持久化限容到 $XMG_MAINT_JOURNAL_MAX"
        echo "  - 系统更新后如提示 reboot-required 建议尽快重启"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                clear
                xmg_maint_update
                xmg_pause
                ;;
            2)
                clear
                xmg_maint_clean
                xmg_pause
                ;;
            3)
                clear
                xmg_maint_vnstat
                xmg_pause
                ;;
            4)
                clear
                xmg_maint_disk_overview
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
    xmg_maint_menu
fi
