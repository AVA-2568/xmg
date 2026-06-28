#!/usr/bin/env bash

CACHE_CPU="/dev/shm/xmg_cpu"
CACHE_TTL=2

########################################
# 服务检测（极轻）
########################################

check_service() {
    pidof "$1" >/dev/null 2>&1 && echo active || echo inactive
}

########################################
# CPU（缓存）
########################################

calc_cpu() {
    local u n s i io irq si st t1 t2
    read -r _ u n s i io irq si st _ < /proc/stat
    t1=$((u+n+s+i+io+irq+si+st))
    sleep 0.2
    read -r _ u n s i io irq si st _ < /proc/stat
    t2=$((u+n+s+i+io+irq+si+st))

    local idle_diff total_diff
    idle_diff=$((i+io))
    total_diff=$((t2 - t1))

    (( total_diff == 0 )) && echo "0%" || echo "$((100*(total_diff-idle_diff)/total_diff))%"
}

get_cpu() {
    local now ts
    now=$(date +%s)

    if [[ ! -f "$CACHE_CPU" ]]; then
        calc_cpu > "$CACHE_CPU"
    else
        ts=$(stat -c %Y "$CACHE_CPU" 2>/dev/null || echo 0)
        (( now - ts >= CACHE_TTL )) && calc_cpu > "$CACHE_CPU"
    fi

    cat "$CACHE_CPU"
}

########################################
# 内存
########################################

get_mem() {
    local total avail k v

    while read -r k v _; do
        case "$k" in
            MemTotal:) total=$v ;;
            MemAvailable:) avail=$v ;;
        esac
    done < /proc/meminfo

    echo "$(((total-avail)/1024))MB / $((total/1024))MB"
}

########################################
# TCP
########################################

get_tcp() {
    wc -l < /proc/net/tcp
}

########################################
# load
########################################

get_load() {
    awk '{print $1" "$2" "$3}' /proc/loadavg
}

########################################
# uptime
########################################

get_uptime() {
    awk '{print int($1/3600)"h "int(($1%3600)/60)"m"}' /proc/uptime
}

########################################
# 状态灯
########################################

light() {
    case "$1" in
        active) printf "\033[32m●\033[0m" ;;
        inactive) printf "\033[31m●\033[0m" ;;
        *) printf "\033[33m●\033[0m" ;;
    esac
}

########################################
# 绘制UI（无clear）
########################################

draw_dashboard() {
    printf "\033[H"

    local caddy xray cpu mem tcp load uptime

    caddy=$(check_service caddy)
    xray=$(check_service xray)
    cpu=$(get_cpu)
    mem=$(get_mem)
    tcp=$(get_tcp)
    load=$(get_load)
    uptime=$(get_uptime)

    echo "=========================================="
    echo " XMG Monitor (Real-Time)"
    echo "------------------------------------------"

    printf " Caddy: %s %-8s   Xray: %s %-8s\n" \
        "$(light "$caddy")" "$caddy" \
        "$(light "$xray")" "$xray"

    echo

    printf " CPU: %-10s  MEM: %-18s\n" "$cpu" "$mem"
    printf " TCP: %-10s  Load: %-15s\n" "$tcp" "$load"
    printf " Uptime: %-15s\n" "$uptime"

    echo "=========================================="
    echo "[m] 菜单   [q] 退出"
}

########################################
# 主循环
########################################

monitor_loop() {
    tput civis 2>/dev/null

    while true; do
        draw_dashboard

        read -rsn1 -t 1 key

        case "$key" in
            q) break ;;
            m)
                tput cnorm
                run_main_menu
                tput civis
                ;;
        esac
    done

    tput cnorm
    clear
}
