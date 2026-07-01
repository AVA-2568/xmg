#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# common.sh - XMG 公共函数库
#
# 说明：
#   - 本文件应由 xmg 主程序或其他 lib/*.sh 模块 source 加载
#   - 文件内容按 UTF-8 保存
#   - 不应将 Bash 特殊字符转义为 HTML 实体
#

# common.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "common.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
# 既兼容 source，也兼容被直接执行
if [ "${XMG_COMMON_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_COMMON_SH_LOADED=1

# ===== 全局目录配置 =====
XMG_ETC_DIR="${XMG_ETC_DIR:-/etc/xmg}"
XMG_RUN_DIR="${XMG_RUN_DIR:-/run/xmg}"
XMG_LOG_DIR="${XMG_LOG_DIR:-/var/log/xmg}"
XMG_BACKUP_DIR="${XMG_BACKUP_DIR:-/var/backups/xmg}"
XMG_WWW_DIR="${XMG_WWW_DIR:-/var/www/xmg}"

# 颜色策略：
#   auto   - 仅在 TTY 中启用颜色
#   always - 强制启用颜色
#   never  - 禁用颜色
XMG_COLOR="${XMG_COLOR:-auto}"

# 颜色转义序列缓存变量
# 初始化后直接引用，避免热路径中反复执行命令替换
XMG_C_RESET=""
XMG_C_BOLD=""
XMG_C_RED=""
XMG_C_GREEN=""
XMG_C_YELLOW=""
XMG_C_CYAN=""

xmg_has_tty() {
    [ -t 1 ]
}

xmg_color_enabled() {
    case "$XMG_COLOR" in
        always)
            return 0
            ;;
        never)
            return 1
            ;;
        auto)
            xmg_has_tty
            ;;
        *)
            xmg_has_tty
            ;;
    esac
}

xmg_color_init() {
    # 启动时初始化一次颜色变量，避免 UI 循环里频繁调用 $(...)
    if xmg_color_enabled; then
        XMG_C_RESET=$'\033[0m'
        XMG_C_BOLD=$'\033[1m'
        XMG_C_RED=$'\033[31m'
        XMG_C_GREEN=$'\033[32m'
        XMG_C_YELLOW=$'\033[33m'
        XMG_C_CYAN=$'\033[36m'
    else
        XMG_C_RESET=""
        XMG_C_BOLD=""
        XMG_C_RED=""
        XMG_C_GREEN=""
        XMG_C_YELLOW=""
        XMG_C_CYAN=""
    fi
}

# 保留兼容函数，供少量一次性脚本使用
xmg_color() {
    local code="$1"

    if xmg_color_enabled; then
        printf '\033[%sm' "$code"
    fi
}

xmg_reset() {
    if xmg_color_enabled; then
        printf '\033[0m'
    fi
}

# ===== 控制台提示接口 =====
# 这是公共 API，其他模块依赖这些函数名，尽量保持稳定。

xmg_info() {
    printf '%s[INFO]%s %s\n' "$XMG_C_GREEN" "$XMG_C_RESET" "$*"
}

xmg_warn() {
    printf '%s[WARN]%s %s\n' "$XMG_C_YELLOW" "$XMG_C_RESET" "$*" >&2
}

xmg_error() {
    printf '%s[ERROR]%s %s\n' "$XMG_C_RED" "$XMG_C_RESET" "$*" >&2
}

xmg_die() {
    xmg_error "$*"
    exit 1
}

xmg_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

xmg_require_bash() {
    if [ -z "${BASH_VERSION:-}" ]; then
        echo "错误: 需要 bash 运行" >&2
        exit 1
    fi
}

xmg_is_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ]
}

xmg_require_root() {
    xmg_is_root || xmg_die "操作需要 root 权限，请使用 sudo 或 root 用户执行"
}

xmg_mkdirs() {
    mkdir -p \
        "$XMG_ETC_DIR" \
        "$XMG_RUN_DIR" \
        "$XMG_LOG_DIR" \
        "$XMG_BACKUP_DIR" \
        "$XMG_WWW_DIR"
}

xmg_pause() {
    local dummy=""

    printf '\n按 Enter 返回...'
    read -r dummy || true
}

xmg_confirm() {
    local prompt="${1:-确认?}"
    local ans=""

    printf '%s [y/N]: ' "$prompt"
    read -r ans || return 1

    case "$ans" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

xmg_timestamp() {
    date '+%Y%m%d-%H%M%S'
}

xmg_backup_file() {
    local file="$1"
    local base=""
    local dst=""
    local ts=""

    [ -e "$file" ] || [ -L "$file" ] || return 0

    xmg_mkdirs

    base="$(basename "$file")"
    ts="$(xmg_timestamp)"
    dst="$XMG_BACKUP_DIR/${base}.${ts}.bak"

    cp -a -- "$file" "$dst" || return 1
    xmg_info "已备份 $file -> $dst"
}

xmg_systemctl() {
    local action="$1"
    local service="$2"

    xmg_require_root

    if ! xmg_cmd_exists systemctl; then
        xmg_die "当前系统未发现 systemctl，可能不是 systemd 系统"
    fi

    case "$action" in
        start|stop|restart|reload|enable|disable|status|is-active|is-enabled)
            systemctl "$action" "$service"
            ;;
        *)
            xmg_die "不支持的 systemctl 操作: $action"
            ;;
    esac
}
