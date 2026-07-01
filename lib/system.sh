#!/usr/bin/env bash

# system*** 是 Bash 库文件，明确拒绝非 Bash 宿主
[ -n "***ASH_VERSION:-}" ] || {
    echo ***stem.sh: requires bash" >&2
    ***urn 1 2>/dev/null || exit 1
}

#***=== 安全加载 =====
if [ "${XMG_SYSTE***H_LOADED:-0}" = "1" ]; then
    ***urn 0 2>/dev/null || exit 0
fi
X***SYSTEM_SH_LOADED=1

XMG_CACHE_TT***${XMG_CACHE_TTL:-3}"
XMG_SERVICE***L="${XMG_SERVICE_TTL:-5}"

XMG_X***_SERVICE="${XMG_XRAY_SERVICE:-xr***"
XMG_CADDY_SERVICE="${XMG_CADDY***RVICE:-caddy}"

XMG_CACHE_TS=0
X***SERVICE_CACHE_TS=0

XMG_STATUS_T***="unknown"
XMG_STATUS_HOSTNAME="***nown"
XMG_STATUS_KERNEL="unknown***MG_STATUS_UPTIME="unknown"
XMG_S***US_LOAD="unknown"
XMG_STATUS_MEM***RCENT="unknown"
XMG_STATUS_MEM_D***IL="unknown"
XMG_STATUS_DISK_ROO***unknown"
XMG_STATUS_XRAY="unknow***XMG_STATUS_CADDY="unknown"
XMG_S***US_PORT_22="unknown"
XMG_STATUS_***T_80="unknown"
XMG_STATUS_PORT_4***"unknown"

# common.sh 正常会先定义 xm***md_exists；这里仅提供兜底，不覆盖已有实现
if ! d***are -F xmg_cmd_exists >/dev/null***&1; then
    xmg_cmd_exists() {
***     command -v "$1" >/dev/null ***1
    }
fi

xmg_now_s() {
    # ***h 4.2+ 支持 printf %(%s)T；失败时回退 da***    printf '%(%s)T' -1 2>/dev/nu***|| date '+%s'
}

xmg_read_time()***    # Bash 4.2+ 支持内建时间格式化；失败时回退 ***e
    printf '%(%Y-%m-%d %H:%M:%***' -1 2>/dev/null || date '+%Y-%m*** %H:%M:%S'
}

xmg_read_hostname(***
    local h=""

    if read -r *** /proc/sys/kernel/hostname 2>/de***ull; then
        printf '%s' "$***        return 0
    fi

    hos***me 2>/dev/null || echo "unknown"***
xmg_read_kernel() {
    uname -***>/dev/null || echo "unknown"
}

***_read_load() {
    local l1=""
 ***local l2=""
    local l3=""
    ***al rest=""

    if read -r l1 l2*** rest < /proc/loadavg 2>/dev/nul***then
        printf '%s %s %s' "***" "$l2" "$l3"
        return 0
 ***fi

    echo "unknown"
}

xmg_re***uptime() {
    local raw=""
    ***al sec=0
    local d=0
    local***0
    local m=0

    if ! read -***aw _ < /proc/uptime 2>/dev/null;***en
        echo "unknown"
      ***eturn 0
    fi

    sec="${raw%%***"

    case "$sec" in
        ''***!0-9]*)
            echo "unknow***            return 0
           ***
    esac

    d=$((sec / 86400)***   h=$(((sec % 86400) / 3600))
 ***m=$(((sec % 3600) / 60))

    if***"$d" -gt 0 ]; then
        print***%dd %02dh %02dm' "$d" "$h" "$m"
*** else
        printf '%02dh %02d***"$h" "$m"
    fi
}

# 一次读取内存信息，返***：
#   percent|usedMi/totalMi
#
#***使用 MemAvailable；如果系统过旧没有 MemAvai***le，则回退到
# MemFree + Buffers + Ca***d 的近似可用内存。
xmg_read_mem() {
    ***al key=""
    local value=""
   ***cal unit=""

    local total_kb=***   local available_kb=0
    loca***emfree_kb=0
    local buffers_kb***    local cached_kb=0

    local***ed_kb=0
    local percent=0

   ***ile read -r key value unit; do
 ***    case "$key" in
            M***otal:)
                total_kb=***alue"
                ;;
       ***  MemAvailable:)
               ***ailable_kb="$value"
            *** ;;
            MemFree:)
      ***       memfree_kb="$value"
     ***        ;;
            Buffers:)***              buffers_kb="$value***               ;;
            Ca***d:)
                cached_kb="$***ue"
                ;;
        e***

        # MemAvailable 已拿到时可以提***
        if [ "$total_kb" -gt 0 ***& [ "$available_kb" -gt 0 ]; the***           break
        fi
    ***e < /proc/meminfo 2>/dev/null

 ***if [ "$total_kb" -le 0 ]; then
 ***    echo "unknown|unknown"
     ***return 0
    fi

    if [ "$avai***le_kb" -le 0 ]; then
        ava***ble_kb=$((memfree_kb + buffers_k*** cached_kb))
    fi

    if [ "$***ilable_kb" -lt 0 ]; then
       ***ailable_kb=0
    fi

    used_kb***(total_kb - available_kb))

    ***[ "$used_kb" -lt 0 ]; then
     ***used_kb=0
    fi

    percent=$(***ed_kb * 100 / total_kb))

    pr***f '%s|%sMi/%sMi' \
        "${pe***nt}%" \
        "$((used_kb / 10***)" \
        "$((total_kb / 1024***
}

# 兼容旧调用
xmg_read_mem_percent***{
    local r=""
    r="$(xmg_re***mem)"
    printf '%s' "${r%%|*}"***
xmg_read_mem_detail() {
    loc***r=""
    r="$(xmg_read_mem)"
   ***intf '%s' "${r##*|}"
}

xmg_read***sk_root() {
    local line=""
  ***ocal fs=""
    local size=""
   ***cal used=""
    local avail=""
 ***local usep=""
    local mount=""***   # df 本身需要外部命令；这里不用 awk，减少一次 f***
    while read -r fs size used ***il usep mount; do
        [ "$fs*** "Filesystem" ] && continue

   ***  if [ -n "$usep" ] && [ -n "$us*** ] && [ -n "$size" ]; then
     ***    printf '%s %s/%s' "$usep" "$***d" "$size"
            return 0
***     fi
    done < <(df -hP / 2>***v/null)

    echo "unknown"
}

x***service_active_read() {
    loca***ervice="$1"

    if ! xmg_cmd_ex***s systemctl; then
        echo "***systemd"
        return 0
    fi***   if systemctl is-active --quie***$service" 2>/dev/null; then
    *** echo "running"
    else
       ***ho "stopped"
    fi
}

xmg_hex_p***() {
    local port="$1"

    ca***"$port" in
        ''|*[!0-9]*)
***         printf '0000'
         ***return 1
            ;;
    esac***   printf '%04X' "$port"
}

xmg_***c_port_listening() {
    local p***="$1"
    local hex=""
    local***le=""
    local sl=""
    local ***r=""
    local rem=""
    local ***te=""
    local rest=""

    hex***(xmg_hex_port "$port")" || retur***

    # /proc/net/tcp 和 /proc/ne***cp6 的 st 字段中，0A 表示 LISTEN。
    #***只看本地端口和 LISTEN 状态，不关心具体绑定地址。
   ***r file in /proc/net/tcp /proc/ne***cp6; do
        [ -r "$file" ] |***ontinue

        while read -r s***ddr rem state rest; do
         ***[ "$sl" = "sl" ] && continue

  ***       if [ "${addr##*:}" = "$he***] && [ "$state" = "0A" ]; then
 ***            return 0
           ***
        done < "$file"
    done***   return 1
}

xmg_port_status()***    local port="$1"

    if xmg_***c_port_listening "$port"; then
 ***    echo "listen"
    else
     ***echo "closed"
    fi
}

xmg_syst***refresh_basic() {
    local forc***${1:-}"
    local now=0
    loca***em_result=""

    now="$(xmg_now***"

    if [ "$force" != "force" ***& [ $((now - XMG_CACHE_TS)) -lt ***MG_CACHE_TTL" ]; then
        re***n 0
    fi

    XMG_CACHE_TS="$n***

    XMG_STATUS_TIME="$(xmg_rea***ime)"
    XMG_STATUS_HOSTNAME="$***g_read_hostname)"
    XMG_STATUS***RNEL="$(xmg_read_kernel)"
    XM***TATUS_UPTIME="$(xmg_read_uptime)***   XMG_STATUS_LOAD="$(xmg_read_l***)"

    mem_result="$(xmg_read_m***"
    XMG_STATUS_MEM_PERCENT="${***_result%%|*}"
    XMG_STATUS_MEM***TAIL="${mem_result##*|}"

    XM***TATUS_DISK_ROOT="$(xmg_read_disk***ot)"

    XMG_STATUS_PORT_22="$(***_port_status 22)"
    XMG_STATUS***RT_80="$(xmg_port_status 80)"
  ***MG_STATUS_PORT_443="$(xmg_port_s***us 443)"
}

xmg_system_refresh_s***ices() {
    local force="${1:-}***   local now=0

    now="$(xmg_n***s)"

    if [ "$force" != "force*** && [ $((now - XMG_SERVICE_CACHE***)) -lt "$XMG_SERVICE_TTL" ]; the***       return 0
    fi

    XMG_***VICE_CACHE_TS="$now"

    XMG_ST***S_XRAY="$(xmg_service_active_rea***$XMG_XRAY_SERVICE")"
    XMG_STA***_CADDY="$(xmg_service_active_rea***$XMG_CADDY_SERVICE")"
}

xmg_sys***_refresh_all() {
    local force***{1:-}"

    xmg_system_refresh_b***c "$force"
    xmg_system_refres***ervices "$force"
}

xmg_status_c***r() {
    local value="$1"

    ***e "$value" in
        running|li***n)
            printf '%s%s%s' "***MG_C_GREEN:-}" "$value" "${XMG_C***SET:-}"
            ;;
        s***ped|closed)
            printf '***s%s' "${XMG_C_RED:-}" "$value" "${XMG_C_RESET:-}"
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
    xmg_system_print_status_line "Caddy" "$XMG_STATUS_CADDY"

    cat <<EOF

Ports:
EOF

    xmg_system_print_status_line "22/SSH" "$XMG_STATUS_PORT_22"
    xmg_system_print_status_line "80/HTTP" "$XMG_STATUS_PORT_80"
    xmg_system_print_status_line "443/HTTPS" "$XMG_STATUS_PORT_443"
}
