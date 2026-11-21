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

# ===== 发行版 / init / 包管理器抽象层 =====
# os.sh 是 common.sh 的强依赖：所有包与服务操作都应经由它转发，
# 以保证 Debian 系 (systemd+apt) 与 Alpine (OpenRC+apk) 行为一致。
if [ "${XMG_OS_SH_LOADED:-0}" != "1" ]; then
    for _xmg_os_cand in \
        "$XMG_LIB_DIR/os.sh" \
        "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/os.sh"
    do
        if [ -r "$_xmg_os_cand" ]; then
            # shellcheck source=/dev/null
            source "$_xmg_os_cand"
            break
        fi
    done
    unset _xmg_os_cand
fi

if [ "${XMG_OS_SH_LOADED:-0}" != "1" ]; then
    echo "[ERROR] 缺少核心模块 os.sh（$XMG_LIB_DIR/os.sh），请重新执行 install.sh 完成升级" >&2
    return 1 2>/dev/null || exit 1
fi

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
    chmod 0750 "$XMG_LOG_DIR" "$XMG_LOG_DIR/xray" 2>/dev/null || true
    touch "$XMG_LOG_DIR/xray/error.log" 2>/dev/null || true
    chmod 0640 "$XMG_LOG_DIR/xray/error.log" 2>/dev/null || true
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

# 纯 Bash 去重辅助，替代 echo | tr | sort -u 外部子进程
# 仅保留纯数字 PID；空输入返回空串，非空输出无尾随空格
_xmg_uniq_pids() {
    local -A _seen=()
    local _w="" _uniq=()
    for _w in $1; do
        if [[ "$_w" =~ ^[0-9]+$ ]] && [ -z "${_seen[$_w]:-}" ]; then
            _seen["$_w"]=1
            _uniq+=("$_w")
        fi
    done
    [ "${#_uniq[@]}" -eq 0 ] && return 0
    local IFS=' '
    printf '%s' "${_uniq[*]}"
}

# 防御云 VPS 镜像常见的 grub-pc 未指定安装设备导致的配置死锁（共用辅助）
_xmg_apt_preset_grub_debconf() {
    command -v debconf-set-selections >/dev/null 2>&1 || return 0
    local root_dev="" root_disk="" _fs="" _rest=""
    while read -r _fs _rest; do
        [ "$_fs" = "Filesystem" ] && continue
        [ -n "$_fs" ] && root_dev="$_fs"
    done < <(LC_ALL=C df -P / 2>/dev/null)
    if [ -n "$root_dev" ]; then
        case "$root_dev" in
            /dev/nvme*|/dev/mmcblk*) root_disk="${root_dev%p[0-9]*}" ;;
            /dev/*)                 root_disk="${root_dev%[0-9]*}" ;;
        esac
    fi
    if [ -n "$root_disk" ] && [ -b "$root_disk" ]; then
        printf 'grub-pc grub-pc/install_devices multiselect %s\n' "$root_disk" | debconf-set-selections 2>/dev/null || true
    fi
    printf 'grub-pc grub-pc/install_devices_empty boolean true\n' | debconf-set-selections 2>/dev/null || true
    printf 'grub-pc grub-pc/mixed_legacy_and_grub2 boolean true\n' | debconf-set-selections 2>/dev/null || true
}

# 获取持有 dpkg / apt 锁的进程 PID 列表（仅基于真实锁文件句柄，杜绝模糊匹配误杀）
xmg_apt_find_lock_pids() {
    local pids=""

    # 非 apt 系（Alpine 等）不存在 dpkg 锁，直接返回空，避免无意义的 /proc 全表扫描
    if ! command -v dpkg >/dev/null 2>&1 && ! command -v apt-get >/dev/null 2>&1; then
        return 0
    fi

    local -a _all_locks=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )
    if [ -n "${XMG_APT_LOCK_FILES_OVERRIDE:-}" ]; then
        read -r -a _all_locks <<< "$XMG_APT_LOCK_FILES_OVERRIDE"
    fi

    local -a _locks=()
    local _lf=""
    for _lf in "${_all_locks[@]}"; do
        [ -e "$_lf" ] && _locks+=("$_lf")
    done
    [ "${#_locks[@]}" -eq 0 ] && return 0

    local _self_pid="$$"
    local _sub_pid="${BASHPID:-$$}"

    # 方法 1: fuser（可用时直接以内核查询结果为准，避免无锁时回退扫描 /proc）
    if command -v fuser >/dev/null 2>&1; then
        pids="$(fuser "${_locks[@]}" 2>/dev/null || true)"
    # 方法 2: lsof
    elif command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -t "${_locks[@]}" 2>/dev/null || true)"
    # 方法 3: 纯内核读取 /proc/[0-9]*/fd 精准匹配锁文件路径
    elif [ -d /proc ]; then
        local pid_dir=""
        for pid_dir in /proc/[0-9]*; do
            [ -d "$pid_dir/fd" ] || continue
            local cur_pid="${pid_dir##*/}"
            [ "$cur_pid" = "$_self_pid" ] || [ "$cur_pid" = "$_sub_pid" ] && continue

            local fd=""
            for fd in "$pid_dir"/fd/*; do
                [ -e "$fd" ] || continue
                local target=""
                target="$(readlink "$fd" 2>/dev/null || true)"
                [ -z "$target" ] && continue
                for _lf in "${_locks[@]}"; do
                    if [ "$target" = "$_lf" ]; then
                        pids="$pids $cur_pid"
                        break 2
                    fi
                done
            done
        done
    fi

    # 排除当前主/子 shell PID，防止极端场景下误伤自身
    local _filtered="" _p=""
    for _p in $pids; do
        [ "$_p" = "$_self_pid" ] || [ "$_p" = "$_sub_pid" ] && continue
        _filtered="$_filtered $_p"
    done

    _xmg_uniq_pids "$_filtered"
}

# 安全解除僵死 apt 锁并自动修复 dpkg 数据库状态
xmg_apt_unlock_and_repair() {
    xmg_require_root

    if ! command -v dpkg >/dev/null 2>&1; then
        xmg_warn "当前系统未使用 dpkg/apt（$(xmg_os_summary 2>/dev/null || echo unknown)），无需解除 apt 锁"
        return 0
    fi

    local -a _all_locks=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )
    if [ -n "${XMG_APT_LOCK_FILES_OVERRIDE:-}" ]; then
        read -r -a _all_locks <<< "$XMG_APT_LOCK_FILES_OVERRIDE"
    fi

    xmg_info "正在排查并解除 apt / dpkg 锁占用..."
    local pids=""
    pids="$(xmg_apt_find_lock_pids)"

    local _self_pid="$$"
    local _sub_pid="${BASHPID:-$$}"

    if [ -n "$pids" ]; then
        xmg_warn "检测到占用包管理器锁的残留进程 PID: $pids"
        local p=""
        for p in $pids; do
            [ "$p" = "1" ] || [ "$p" = "$_self_pid" ] || [ "$p" = "$_sub_pid" ] && continue
            local cmd=""
            if [ -r "/proc/$p/cmdline" ]; then
                cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
            fi
            xmg_warn "正在终止残留进程: PID $p (${cmd:-未知})"
            kill -15 "$p" 2>/dev/null || true
        done
        sleep 2
        local _still_alive=""
        for p in $pids; do
            [ "$p" = "1" ] || [ "$p" = "$_self_pid" ] || [ "$p" = "$_sub_pid" ] && continue
            if kill -0 "$p" 2>/dev/null; then
                xmg_warn "强制终止顽固进程: PID $p"
                kill -9 "$p" 2>/dev/null || true
                _still_alive="$_still_alive $p"
            fi
        done
        if [ -n "$_still_alive" ]; then
            sleep 1
            for p in $_still_alive; do
                if kill -0 "$p" 2>/dev/null; then
                    xmg_error "持锁进程 PID $p 无法终止（可能处于不可中断 D 状态），为避免损坏 dpkg 数据库已中止删锁"
                    return 1
                fi
            done
        fi
    fi

    # 仅在确认无持锁进程存活后清理孤儿锁文件
    rm -f "${_all_locks[@]}" 2>/dev/null || true

    _xmg_apt_preset_grub_debconf

    # 关键自愈：修复被中断的 dpkg 数据库状态与依赖（保留错误输出，不掩盖失败）
    xmg_info "正在修复 dpkg 数据库状态 (dpkg --configure -a)..."
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export UCF_FORCE_CONFFOLD=1
    local _repair_rc=0
    if ! dpkg --configure -a; then
        xmg_warn "dpkg --configure -a 执行存在异常，继续尝试修复依赖..."
        _repair_rc=1
    fi

    xmg_info "正在修复可能损坏的包依赖 (apt-get install -f)..."
    if ! apt-get -o DPkg::Lock::Timeout=30 -f install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"; then
        xmg_error "apt-get install -f 修复失败，请检查上方输出或磁盘/网络状态"
        return 1
    fi

    if [ "$_repair_rc" -ne 0 ]; then
        if ! dpkg --configure -a; then
            xmg_error "dpkg 数据库仍存在未完成配置的软件包，请手动排查"
            return 1
        fi
    fi

    xmg_info "dpkg 锁已解除，软件包数据库修复完成！"
    return 0
}

# 等待 dpkg / apt 锁释放（仅友好观测等待，绝不自动强杀正在运行的包管理器）
xmg_apt_wait_lock() {
    local timeout="${1:-30}"
    local waited=0
    local pids=""

    while [ "$waited" -lt "$timeout" ]; do
        pids="$(xmg_apt_find_lock_pids)"
        if [ -z "$pids" ]; then
            return 0
        fi

        if [ "$waited" -eq 0 ]; then
            local _first_pid="${pids%% *}"
            local _cmd=""
            if [ -r "/proc/$_first_pid/cmdline" ]; then
                _cmd="$(tr '\0' ' ' < "/proc/$_first_pid/cmdline" 2>/dev/null || true)"
                _cmd="${_cmd%"${_cmd##*[![:space:]]}"}"
                if [ "${#_cmd}" -gt 60 ]; then
                    _cmd="${_cmd:0:57}..."
                fi
            fi
            xmg_info "检测到系统后台正在运行包管理器 (PID: $pids${_cmd:+, $_cmd})，等待释放中 (最多等待 ${timeout}s)..."
        fi

        local _step=2
        if [ $((timeout - waited)) -lt "$_step" ]; then
            _step=$((timeout - waited))
        fi
        sleep "$_step"
        waited=$((waited + _step))
    done

    pids="$(xmg_apt_find_lock_pids)"
    if [ -z "$pids" ]; then
        return 0
    fi

    xmg_warn "包管理器锁等待超时 (${timeout}s，持锁 PID: $pids)，交由 apt 原生锁等待继续处理；若确认为僵死死锁，请在「系统维护 → 7」手动解除"
    return 1
}

# ==================================================================
# 服务控制兼容层
# ==================================================================
# 历史代码大量调用 xmg_systemctl，此处保留函数名不变，
# 内部按实际 init 系统（systemd / OpenRC / SysV）转发：
#   - systemd 环境行为与改造前完全一致
#   - OpenRC 环境映射到 rc-service / rc-update
xmg_systemctl() {
    local action="${1:-}"
    local service="${2:-}"

    if [ -z "$action" ]; then
        xmg_error "xmg_systemctl 缺少操作参数"
        return 2
    fi

    # daemon-reload 不针对具体服务
    if [ "$action" = "daemon-reload" ]; then
        xmg_svc_reload_manager
        return 0
    fi

    if [ -z "$service" ]; then
        xmg_error "xmg_systemctl 缺少服务名"
        return 2
    fi

    xmg_os_detect

    # 非 systemd：交给服务抽象层
    if ! xmg_init_use_systemd_units; then
        case "$action" in
            start|stop|restart|reload)
                xmg_require_root
                if ! xmg_svc_do "$action" "$service"; then
                    xmg_error "服务操作失败: $action $service (init=$XMG_INIT_SYSTEM)"
                    xmg_svc_logs "$service" 15 2>/dev/null | sed 's/^/  /' >&2 || true
                    return 1
                fi
                return 0
                ;;
            enable|disable)
                xmg_require_root
                xmg_svc_do "$action" "$service" || return 1
                return 0
                ;;
            status)
                xmg_svc_status "$service" || return $?
                return 0
                ;;
            is-active)
                xmg_svc_is_active "$service"
                return $?
                ;;
            is-enabled)
                xmg_svc_is_enabled "$service"
                return $?
                ;;
            *)
                xmg_error "当前 init 系统 ($XMG_INIT_SYSTEM) 不支持 systemctl 操作: $action"
                return 2
                ;;
        esac
    fi

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
            systemctl "$action" "$service" || return $?
            ;;
        daemon-reload)
            systemctl daemon-reload >/dev/null 2>&1 || true
            ;;
        *)
            xmg_die "不支持的 systemctl 操作: $action"
            ;;
    esac
}




