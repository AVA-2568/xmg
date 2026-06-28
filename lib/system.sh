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
    date +%s
}

xmg_read_hostname() {
    cat /proc/sys/kernel/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown"
}

xmg_read_kernel() {
    uname -r 2>/dev/null || echo "unknown"
}

xmg_read_time() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown"
}

xmg_read_load() {
    awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || echo "unknown"
}

xmg_read_uptime() {
    awk '
        {
            sec=int($1)
            d=int(sec/86400)
            h=int((sec%86400)/3600)
            m=int((sec%3600)/60)

            if (d > 0) {
                printf "%dd %02dh %02dm", d, h, m
            } else {
                printf "%02dh %02dm", h, m
            }
        }
    ' /proc/uptime 2>/dev/null || echo "unknown"
}

xmg_read_mem_percent() {
    awk '
        /MemTotal:/ {total=$2}
        /MemAvailable:/ {avail=$2}
        END {
            if (total > 0 && avail >= 0) {
                used=total-avail
                printf "%.1f%%", used*100/total
            } else {
                printf "unknown"
            }
        }
    ' /proc/meminfo 2>/dev/null || echo "unknown"
}

xmg_read_mem_detail() {
    awk '
        /MemTotal:/ {total=$2}
        /MemAvailable:/ {avail=$2}
        END {
            if (total > 0 && avail >= 0) {
                used=total-avail
                printf "%.0fMiB/%.0fMiB", used/1024, total/1024
            } else {
                printf "unknown"
            }
        }
    ' /proc/meminfo 2>/dev/null || echo "unknown"
}

xmg_read_disk_root() {
    # df 比读取 /proc 略重，但由 TTL 控制，默认 3 秒一次
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

    # /proc/net/tcp 中状态 0A 表示 LISTEN
    awk -v p="$hex" '
        NR > 1 {
            split($2, a, ":")
            if (toupper(a[2]) == p && $4 == "0A") {
                found=1
                exit
            }
        }
        END {
            exit found ? 0 : 1
        }
    ' /proc/net/tcp 2>/dev/null && return 0

    awk -v p="$hex" '
        NR > 1 {
            split($2, a, ":")
            if (toupper(a[2]) == p && $4 == "0A") {
                found=1
                exit
            }
        }
        END {
            exit found ? 0 : 1
        }
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

    # 端口状态读取 /proc，不调用 ss/netstat/lsof
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

    # systemctl 只在服务缓存过期时调用
    XMG_STATUS_XRAY="$(xmg_service_active_read xray)"
    XMG_STATUS_CADDY="$(xmg_service_active_read caddy)"
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
            printf '%s%s%s' "$(xmg_c 32)" "$value" "$(xmg_reset)"
            ;;
        stopped|closed)
            printf '%s%s%s' "$(xmg_c 31)" "$value" "$(xmg_reset)"
            ;;
        *)
            printf '%s%s%s' "$(xmg_c 33)" "$value" "$(xmg_reset)"
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
