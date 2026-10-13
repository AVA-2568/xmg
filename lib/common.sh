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
# XMG_HOME 是 XMG 的统一根目录。
# 所有 XMG 管理的文件默认集中放在 /opt/xmg。
XMG_HOME="${XMG_HOME:-/opt/xmg}"
# 主程序与模块目录
XMG_BIN_DIR="${XMG_BIN_DIR:-$XMG_HOME/bin}"
XMG_LIB_DIR="${XMG_LIB_DIR:-$XMG_HOME/lib}"
# XMG 自身目录
XMG_ETC_DIR="${XMG_ETC_DIR:-$XMG_HOME/etc}"
XMG_RUN_DIR="${XMG_RUN_DIR:-$XMG_HOME/run}"
XMG_LOG_DIR="${XMG_LOG_DIR:-$XMG_HOME/log}"
XMG_BACKUP_DIR="${XMG_BACKUP_DIR:-$XMG_HOME/backups}"
# 由 XMG 托管的外部组件配置
XMG_XRAY_DIR="${XMG_XRAY_DIR:-$XMG_HOME/xray}"
# 关键配置文件
XMG_XRAY_CONFIG="${XMG_XRAY_CONFIG:-$XMG_XRAY_DIR/config.json}"
export XMG_HOME
export XMG_BIN_DIR XMG_LIB_DIR
export XMG_ETC_DIR XMG_RUN_DIR XMG_LOG_DIR XMG_BACKUP_DIR
export XMG_XRAY_DIR
export XMG_XRAY_CONFIG

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
    if [ -t 0 ] && [ -t 1 ]; then
        xmg_pause
    fi
    exit 1
}

xmg_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
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
        "$XMG_LOG_DIR/xray" \
        "$XMG_BACKUP_DIR" \
        "$XMG_XRAY_DIR" \
        "$XMG_ETC_DIR/xray"
    chmod 777 "$XMG_LOG_DIR" "$XMG_LOG_DIR/xray" 2>/dev/null || true
    touch "$XMG_LOG_DIR/xray/error.log" 2>/dev/null || true
    chmod 666 "$XMG_LOG_DIR/xray/error.log" 2>/dev/null || true
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

# ===== 包管理器与 apt 锁等待与自动修复机制 =====

# 获取持有 dpkg / apt 锁的进程 PID 列表
xmg_apt_find_lock_pids() {
    local pids=""

    # 方法 1: fuser
    if command -v fuser >/dev/null 2>&1; then
        pids="$(fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null || true)"
        if [ -n "$pids" ]; then
            echo "$pids" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '
            return 0
        fi
    fi

    # 方法 2: lsof
    if command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -t /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null || true)"
        if [ -n "$pids" ]; then
            echo "$pids" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '
            return 0
        fi
    fi

    # 方法 3: 纯内核读取 /proc/[0-9]*/fd 原生精准匹配持锁文件 (零外部依赖，100% 精确)
    if [ -d /proc ]; then
        local pid_dir=""
        for pid_dir in /proc/[0-9]*; do
            [ -d "$pid_dir/fd" ] || continue
            local cur_pid="${pid_dir##*/}"
            [ "$cur_pid" = "$$" ] && continue

            local fd=""
            for fd in "$pid_dir"/fd/*; do
                [ -e "$fd" ] || continue
                local target=""
                target="$(readlink "$fd" 2>/dev/null || true)"
                case "$target" in
                    *dpkg/lock*|*apt/lists/lock*|*cache/apt/archives/lock*)
                        pids="$pids $cur_pid"
                        break
                        ;;
                esac
            done
        done
    fi

    # 方法 4: pgrep 兜底
    if [ -z "$pids" ] && command -v pgrep >/dev/null 2>&1; then
        local p=""
        for p in $(pgrep -f "apt-get|apt|dpkg|unattended-upgrades" 2>/dev/null || true); do
            [ "$p" != "$$" ] && pids="$pids $p"
        done
    fi

    echo "$pids" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '
}

# 安全解除僵死 apt 锁并自动修复 dpkg 数据库状态
xmg_apt_unlock_and_repair() {
    xmg_require_root

    xmg_info "正在排查并解除 apt / dpkg 锁占用..."
    local pids=""
    pids="$(xmg_apt_find_lock_pids)"

    if [ -n "$pids" ]; then
        xmg_warn "检测到占用包管理器锁的残留进程 PID: $pids"
        local p=""
        for p in $pids; do
            [ "$p" = "$$" ] && continue
            local cmd=""
            if [ -r "/proc/$p/cmdline" ]; then
                cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
            fi
            xmg_warn "正在终止残留进程: PID $p (${cmd:-未知})"
            kill -15 "$p" 2>/dev/null || true
        done
        sleep 2
        for p in $pids; do
            [ "$p" = "$$" ] && continue
            if kill -0 "$p" 2>/dev/null; then
                xmg_warn "强制终止顽固进程: PID $p"
                kill -9 "$p" 2>/dev/null || true
            fi
        done
    fi

    # 清理孤儿锁文件
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true

    # 防御云 VPS 镜像常见的 grub-pc 未指定安装设备导致的配置死锁
    if command -v debconf-set-selections >/dev/null 2>&1; then
        local root_dev="" root_disk=""
        root_dev="$(df / 2>/dev/null | awk 'NR==2 {print $1}')"
        if [ -n "$root_dev" ]; then
            case "$root_dev" in
                /dev/nvme*|/dev/mmcblk*) root_disk="${root_dev%p[0-9]*}" ;;
                /dev/*)                 root_disk="${root_dev%[0-9]*}" ;;
            esac
        fi
        if [ -n "$root_disk" ] && [ -b "$root_disk" ]; then
            echo "grub-pc grub-pc/install_devices multiselect $root_disk" | debconf-set-selections 2>/dev/null || true
        fi
        echo "grub-pc grub-pc/install_devices_empty boolean true" | debconf-set-selections 2>/dev/null || true
        echo "grub-pc grub-pc/mixed_legacy_and_grub2 boolean true" | debconf-set-selections 2>/dev/null || true
    fi

    # 关键自愈：修复被中断的 dpkg 数据库状态与依赖
    xmg_info "正在修复 dpkg 数据库状态 (dpkg --configure -a)..."
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export UCF_FORCE_CONFFOLD=1
    dpkg --configure -a >/dev/null 2>&1 || true

    xmg_info "正在修复可能损坏的包依赖 (apt-get install -f)..."
    apt-get -o DPkg::Lock::Timeout=30 -f install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" >/dev/null 2>&1 || true

    xmg_info "dpkg 锁已解除，软件包数据库修复完成！"
    return 0
}

# 等待 dpkg / apt 锁释放，超时自动解除死锁并自愈
xmg_apt_wait_lock() {
    local timeout="${1:-15}"
    local waited=0
    local pids=""

    while [ "$waited" -lt "$timeout" ]; do
        pids="$(xmg_apt_find_lock_pids)"
        if [ -z "$pids" ]; then
            return 0
        fi

        if [ "$waited" -eq 0 ]; then
            xmg_info "检测到系统后台正在运行包管理器 (PID: $pids)，等待释放中 (最多等待 ${timeout}s)..."
        fi

        sleep 2
        waited=$((waited + 2))
    done

    xmg_warn "包管理器锁等待超时 (${timeout}s)，可能存在挂起/死锁进程，自动介入解除死锁并修复..."
    xmg_apt_unlock_and_repair
}

# 包装安全的 apt-get 安装，自动带锁等待、配置合并保护和锁超时
xmg_apt_install() {
    xmg_require_root
    xmg_apt_wait_lock 15 || true

    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=60 \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            install -y "$@"
}

xmg_systemctl() {
    local action="$1"
    local service="$2"

    if ! xmg_cmd_exists systemctl; then
        xmg_die "当前系统未发现 systemctl，可能不是 systemd 系统"
    fi

    case "$action" in
        start|stop|restart|reload|enable|disable)
            xmg_require_root
            if ! systemctl "$action" "$service"; then
                xmg_error "systemctl $action $service 执行失败！"
                if command -v journalctl >/dev/null 2>&1; then
                    xmg_warn "--- $service 最近 15 行系统日志 ---"
                    journalctl -u "$service" -n 15 --no-pager 2>&1 | sed 's/^/  /' >&2 || true
                fi
                return 1
            fi
            ;;
        status|is-active|is-enabled)
            systemctl "$action" "$service"
            ;;
        *)
            xmg_die "不支持的 systemctl 操作: $action"
            ;;
    esac
}

# ===== 安全加载 detect.sh =====
if [ -r "${XMG_LIB_DIR:-$XMG_HOME/lib}/detect.sh" ]; then
    # shellcheck source=/dev/null
    source "${XMG_LIB_DIR:-$XMG_HOME/lib}/detect.sh"
elif [ -r "$(dirname "${BASH_SOURCE[0]}")/detect.sh" ]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/detect.sh"
fi

# ===== 安全加载 doctor.sh =====
if [ -r "${XMG_LIB_DIR:-$XMG_HOME/lib}/doctor.sh" ]; then
    # shellcheck source=/dev/null
    source "${XMG_LIB_DIR:-$XMG_HOME/lib}/doctor.sh"
elif [ -r "$(dirname "${BASH_SOURCE[0]}")/doctor.sh" ]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/doctor.sh"
fi


