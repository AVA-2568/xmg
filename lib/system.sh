#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# system.sh - XMG 系统状态采集模块
#
# 说明：
#   - 本模块为 monitor、menu、doctor 提供系统状态数据
#   - 优先使用 /proc 读取系统信息，减少外部命令调用
#   - 文件内容应使用 UTF-8 编码保存
#

# system.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "system.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_SYSTEM_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_SYSTEM_SH_LOADED=1

XMG_CACHE_TTL="${XMG_CACHE_TTL:-3}"
XMG_SERVICE_TTL="${XMG_SERVICE_TTL:-5}"

XMG_XRAY_SERVICE="${XMG_XRAY_SERVICE:-xray}"

XMG_CACHE_TS=0
XMG_SERVICE_CACHE_TS=0

XMG_STATUS_TIME="unknown"
XMG_STATUS_HOSTNAME="unknown"
XMG_STATUS_KERNEL="unknown"
XMG_STATUS_UPTIME="unknown"
XMG_STATUS_LOAD="unknown"
XMG_STATUS_MEM_PERCENT="unknown"
XMG_STATUS_MEM_DETAIL="unknown"
XMG_STATUS_DISK_ROOT="unknown"
XMG_STATUS_XRAY="unknown"
XMG_STATUS_PORT_22="unknown"
XMG_STATUS_PORT_80="unknown"
XMG_STATUS_PORT_443="unknown"

# common.sh 正常会先定义 xmg_cmd_exists；
# 这里仅提供兜底，不覆盖已有实现。
if ! declare -F xmg_cmd_exists >/dev/null 2>&1; then
    xmg_cmd_exists() {
        command -v "$1" >/dev/null 2>&1
    }
fi

xmg_now_s() {
    # Bash 4.2+ 支持 printf %(%s)T；失败时回退 date。
    printf '%(%s)T' -1 2>/dev/null || date '+%s'
}

xmg_read_time() {
    # Bash 4.2+ 支持内建时间格式化；失败时回退 date。
    printf '%(%Y-%m-%d %H:%M:%S)T' -1 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
}

xmg_read_hostname() {
    local h=""

    if read -r h < /proc/sys/kernel/hostname 2>/dev/null; then
        printf '%s' "$h"
        return 0
    fi

    hostname 2>/dev/null || echo "unknown"
}

xmg_read_kernel() {
    uname -r 2>/dev/null || echo "unknown"
}

xmg_read_load() {
    local l1=""
    local l2=""
    local l3=""
    local rest=""

    if read -r l1 l2 l3 rest < /proc/loadavg 2>/dev/null; then
        printf '%s %s %s' "$l1" "$l2" "$l3"
        return 0
    fi

    echo "unknown"
}

xmg_read_uptime() {
    local raw=""
    local sec=0
    local d=0
    local h=0
    local m=0

    if ! read -r raw _ < /proc/uptime 2>/dev/null; then
        echo "unknown"
        return 0
    fi

    sec="${raw%%.*}"

    case "$sec" in
        ''|*[!0-9]*)
            echo "unknown"
            return 0
            ;;
    esac

    d=$((sec / 86400))
    h=$(((sec % 86400) / 3600))
    m=$(((sec % 3600) / 60))

    if [ "$d" -gt 0 ]; then
        printf '%dd %02dh %02dm' "$d" "$h" "$m"
    else
        printf '%02dh %02dm' "$h" "$m"
    fi
}

# 一次读取内存信息，返回：
#   percent|usedMi/totalMi
#
# 优先使用 MemAvailable；
# 如果系统过旧没有 MemAvailable，则回退到 MemFree + Buffers + Cached。
xmg_read_mem() {
    local key=""
    local value=""
    local unit=""

    local total_kb=0
    local available_kb=0
    local memfree_kb=0
    local buffers_kb=0
    local cached_kb=0

    local used_kb=0
    local percent=0

    while read -r key value unit; do
        case "$key" in
            MemTotal:)
                total_kb="$value"
                ;;
            MemAvailable:)
                available_kb="$value"
                ;;
            MemFree:)
                memfree_kb="$value"
                ;;
            Buffers:)
                buffers_kb="$value"
                ;;
            Cached:)
                cached_kb="$value"
                ;;
        esac

        # MemAvailable 已拿到时可以提前结束。
        if [ "$total_kb" -gt 0 ] && [ "$available_kb" -gt 0 ]; then
            break
        fi
    done < /proc/meminfo 2>/dev/null

    if [ "$total_kb" -le 0 ]; then
        echo "unknown|unknown"
        return 0
    fi

    if [ "$available_kb" -le 0 ]; then
        available_kb=$((memfree_kb + buffers_kb + cached_kb))
    fi

    if [ "$available_kb" -lt 0 ]; then
        available_kb=0
    fi

    used_kb=$((total_kb - available_kb))

    if [ "$used_kb" -lt 0 ]; then
        used_kb=0
    fi

    percent=$((used_kb * 100 / total_kb))

    printf '%s|%sMi/%sMi' \
        "${percent}%" \
        "$((used_kb / 1024))" \
        "$((total_kb / 1024))"
}

xmg_read_disk_root() {
    local fs=""
    local size=""
    local used=""
    local avail=""
    local usep=""
    local mount=""

    # df 本身需要外部命令；这里不用 awk，减少一次 fork。
    while read -r fs size used avail usep mount; do
        [ "$fs" = "Filesystem" ] && continue

        if [ -n "$usep" ] && [ -n "$used" ] && [ -n "$size" ]; then
            printf '%s %s/%s' "$usep" "$used" "$size"
            return 0
        fi
    done < <(df -hP / 2>/dev/null)

    echo "unknown"
}

xmg_service_active_read() {
    local service="$1"

    if ! xmg_cmd_exists systemctl; then
        echo "no-systemd"
        return 0
    fi

    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

xmg_hex_port() {
    local port="$1"

    case "$port" in
        ''|*[!0-9]*)
            printf '0000'
            return 1
            ;;
    esac

    if [ "$port" -lt 0 ] || [ "$port" -gt 65535 ]; then
        printf '0000'
        return 1
    fi

    printf '%04X' "$port"
}

xmg_proc_port_listening() {
    local port="$1"
    local hex=""
    local file=""
    local sl=""
    local addr=""
    local rem=""
    local state=""
    local rest=""

    hex="$(xmg_hex_port "$port")" || return 1

    # /proc/net/tcp 和 /proc/net/tcp6 的 st 字段中，0A 表示 LISTEN。
    # 这里只看本地端口和 LISTEN 状态，不关心具体绑定地址。
    for file in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$file" ] || continue

        while read -r sl addr rem state rest; do
            [ "$sl" = "sl" ] && continue

            if [ "${addr##*:}" = "$hex" ] && [ "$state" = "0A" ]; then
                return 0
            fi
        done < "$file"
    done

    return 1
}

xmg_port_status() {
    local port="$1"

    if xmg_proc_port_listening "$port"; then
        echo "listen"
    else
        echo "closed"
    fi
}

xmg_system_refresh_basic() {
    local force="${1:-}"
    local now=0
    local mem_result=""

    now="$(xmg_now_s)"

    if [ "$force" != "force" ] && [ $((now - XMG_CACHE_TS)) -lt "$XMG_CACHE_TTL" ]; then
        return 0
    fi

    XMG_CACHE_TS="$now"

    XMG_STATUS_TIME="$(xmg_read_time)"
    XMG_STATUS_HOSTNAME="$(xmg_read_hostname)"
    XMG_STATUS_KERNEL="$(xmg_read_kernel)"
    XMG_STATUS_UPTIME="$(xmg_read_uptime)"
    XMG_STATUS_LOAD="$(xmg_read_load)"

    mem_result="$(xmg_read_mem)"
    XMG_STATUS_MEM_PERCENT="${mem_result%%|*}"
    XMG_STATUS_MEM_DETAIL="${mem_result##*|}"

    XMG_STATUS_DISK_ROOT="$(xmg_read_disk_root)"

    XMG_STATUS_PORT_22="$(xmg_port_status 22)"
    XMG_STATUS_PORT_80="$(xmg_port_status 80)"
    XMG_STATUS_PORT_443="$(xmg_port_status 443)"
}

xmg_system_refresh_services() {
    local force="${1:-}"
    local now=0

    now="$(xmg_now_s)"

    if [ "$force" != "force" ] && [ $((now - XMG_SERVICE_CACHE_TS)) -lt "$XMG_SERVICE_TTL" ]; then
        return 0
    fi

    XMG_SERVICE_CACHE_TS="$now"

    XMG_STATUS_XRAY="$(xmg_service_active_read "$XMG_XRAY_SERVICE")"
}

xmg_system_refresh_all() {
    local force="${1:-}"

    xmg_system_refresh_basic "$force"
    xmg_system_refresh_services "$force"
}

xmg_status_color() {
    local value="$1"

    case "$value" in
        running|listen)
            printf '%s%s%s' "${XMG_C_GREEN:-}" "$value" "${XMG_C_RESET:-}"
            ;;
        stopped|closed)
            printf '%s%s%s' "${XMG_C_RED:-}" "$value" "${XMG_C_RESET:-}"
            ;;
        *)
            printf '%s%s%s' "${XMG_C_YELLOW:-}" "$value" "${XMG_C_RESET:-}"
            ;;
    esac
}

xmg_system_print_status_line() {
    local label="$1"
    local value="$2"

    printf '  %-9s : ' "$label"
    xmg_status_color "$value"
    printf '\n'
}

xmg_system_print_summary() {
    cat <<EOF
XMG System Summary
==================

Time       : $XMG_STATUS_TIME
Hostname   : $XMG_STATUS_HOSTNAME
Kernel     : $XMG_STATUS_KERNEL
Uptime     : $XMG_STATUS_UPTIME
Load       : $XMG_STATUS_LOAD
Memory     : $XMG_STATUS_MEM_PERCENT ($XMG_STATUS_MEM_DETAIL)
Disk /     : $XMG_STATUS_DISK_ROOT

Services:
EOF

    xmg_system_print_status_line "Xray" "$XMG_STATUS_XRAY"

    cat <<EOF

Ports:
EOF

    xmg_system_print_status_line "22/SSH" "$XMG_STATUS_PORT_22"
    xmg_system_print_status_line "80/HTTP" "$XMG_STATUS_PORT_80"
    xmg_system_print_status_line "443/HTTPS" "$XMG_STATUS_PORT_443"
}
