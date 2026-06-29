#!/usr/bin/env bash

[ "${XMG_SYSTEM_SH_LOADED:-0}" = "1" ] && return 0
XMG_SYSTEM_SH_LOADED=1

XMG_CACHE_TTL="${XMG_CACHE_TTL:-3}"
XMG_SERVICE_TTL="${XMG_SERVICE_TTL:-5}"

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
XMG_STATUS_CADDY="unknown"
XMG_STATUS_PORT_22="unknown"
XMG_STATUS_PORT_80="unknown"
XMG_STATUS_PORT_443="unknown"

xmg_now_s() {
    # bash 4.2+ 支持 printf %(%s)T，无需 fork date 子进程
    printf '%(%s)T' -1
}

xmg_read_hostname() {
    # 使用 read 内建替代 cat，避免 fork
    local h=""
    read -r h < /proc/sys/kernel/hostname 2>/dev/null && printf '%s' "$h" && return 0
    hostname 2>/dev/null || echo "unknown"
}

xmg_read_kernel() {
    uname -r 2>/dev/null || echo "unknown"
}

xmg_read_time() {
    # bash 4.2+ 内建时间格式化，避免 fork date
    printf '%(%Y-%m-%d %H:%M:%S)T' -1
}

xmg_read_load() {
    # 使用 read 内建替代 awk，避免 fork
    local l1 l2 l3 rest
    read -r l1 l2 l3 rest < /proc/loadavg 2>/dev/null && printf '%s %s %s' "$l1" "$l2" "$l3" && return 0
    echo "unknown"
}

xmg_read_uptime() {
    # 使用 bash 内建算术替代 awk，避免 fork
    local raw sec d h m
    read -r raw _ < /proc/uptime 2>/dev/null || { echo "unknown"; return 0; }
    # raw 格式为 "12345.67 ..."，取整数部分
    sec="${raw%%.*}"
    d=$((sec / 86400))
    h=$(( (sec % 86400) / 3600 ))
    m=$(( (sec % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then
        printf '%dd %02dh %02dm' "$d" "$h" "$m"
    else
        printf '%02dh %02dm' "$h" "$m"
    fi
}

# ===== 修改 xmg_system_refresh_basic =====
# 位置：lib/system.sh 中的 xmg_system_refresh_basic 函数
# 将原来的两行：
#   XMG_STATUS_MEM_PERCENT="$(xmg_read_mem_percent)"
#   XMG_STATUS_MEM_DETAIL="$(xmg_read_mem_detail)"
# 替换为：

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

    # 合并读取：一次 awk 获取两个值，减少一次 /proc/meminfo 读取和一次 fork
    mem_result="$(xmg_read_mem)"
    XMG_STATUS_MEM_PERCENT="${mem_result%%|*}"
    XMG_STATUS_MEM_DETAIL="${mem_result##*|}"

    XMG_STATUS_DISK_ROOT="$(xmg_read_disk_root)"

    XMG_STATUS_PORT_22="$(xmg_port_status 22)"
    XMG_STATUS_PORT_80="$(xmg_port_status 80)"
    XMG_STATUS_PORT_443="$(xmg_port_status 443)"
}

xmg_read_disk_root() {
    df -hP / 2>/dev/null | awk 'NR==2 {print $5" "$3"/"$2}' || echo "unknown"
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
    printf '%04X' "$port"
}

xmg_proc_port_listening() {
    local port="$1"
    local hex=""
    hex="$(xmg_hex_port "$port")"

    awk -v p="$hex" '
        BEGIN { found=0 }          # <-- 显式初始化
        NR > 1 {
            split($2, a, ":")
            if (toupper(a[2]) == p && $4 == "0A") {
                found=1
                exit
            }
        }
        END { exit found ? 0 : 1 }
    ' /proc/net/tcp 2>/dev/null && return 0

    awk -v p="$hex" '
        BEGIN { found=0 }          # <-- 显式初始化
        NR > 1 {
            split($2, a, ":")
            if (toupper(a[2]) == p && $4 == "0A") {
                found=1
                exit
            }
        }
        END { exit found ? 0 : 1 }
    ' /proc/net/tcp6 2>/dev/null
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
    XMG_STATUS_MEM_PERCENT="$(xmg_read_mem_percent)"
    XMG_STATUS_MEM_DETAIL="$(xmg_read_mem_detail)"
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

    XMG_STATUS_XRAY="$(xmg_service_active_read xray)"
    XMG_STATUS_CADDY="$(xmg_service_active_read caddy)"
}

xmg_system_refresh_all() {
    local force="${1:-}"

    xmg_system_refresh_basic "$force"
    xmg_system_refresh_services "$force"
}

# ===== 替换 xmg_status_color =====
# 位置：lib/system.sh 中 xmg_system_print_summary 函数之前
xmg_status_color() {
    local value="$1"

    case "$value" in
        running|listen)
            printf '%s%s%s' "$XMG_C_GREEN" "$value" "$XMG_C_RESET"
            ;;
        stopped|closed)
            printf '%s%s%s' "$XMG_C_RED" "$value" "$XMG_C_RESET"
            ;;
        *)
            printf '%s%s%s' "$XMG_C_YELLOW" "$value" "$XMG_C_RESET"
            ;;
    esac
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
  Xray      : $XMG_STATUS_XRAY
  Caddy     : $XMG_STATUS_CADDY

Ports:
  22/SSH    : $XMG_STATUS_PORT_22
  80/HTTP   : $XMG_STATUS_PORT_80
  443/HTTPS : $XMG_STATUS_PORT_443
EOF
}
