#!/usr/bin/env bash
#
# system.sh - 系统信息 + 低资源监控面板
#

########################################
# 基础系统信息
########################################

show_system_info() {
    echo
    echo "========== 系统信息 =========="
    echo "主机名: $(hostname)"
    echo "系统: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
    echo "内核: $(uname -r)"
    echo

    echo "========== 内存 =========="
    free -h
    echo

    echo "========== 磁盘 =========="
    df -h /
    echo

    echo "========== 端口监听 =========="
    ss -lntup || true
}

########################################
# 缓存（避免频繁 systemctl / ss）
########################################

CACHE_FILE="/tmp/xmg_cache"
CACHE_TTL=2  # 秒（建议 2~5）

update_cache() {
    local now ts

    now=$(date +%s)

    if [[ ! -f "$CACHE_FILE" ]]; then
        refresh_cache
        return
    fi

    ts=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)

    if (( now - ts >= CACHE_TTL )); then
        refresh_cache
    fi
}

refresh_cache() {
    {
        echo "caddy=$(systemctl is-active caddy 2>/dev/null || echo unknown)"
        echo "xray=$(systemctl is-active xray 2>/dev/null || echo unknown)"
        echo "tcp=$(ss -ant 2>/dev/null | wc -l)"
    } > "$CACHE_FILE"
}

get_cache() {
    grep "^$1=" "$CACHE_FILE" 2>/dev/null | cut -d= -f2
}

########################################
# CPU（低开销实现）
########################################

get_cpu_usage() {
    local user nice system idle iowait irq softirq steal
    local total_before total_after idle_before idle_after
    local total_diff idle_diff cpu

    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    total_before=$((user+nice+system+idle+iowait+irq+softirq+steal))
    idle_before=$((idle+iowait))

    sleep 0.2

    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    total_after=$((user+nice+system+idle+iowait+irq+softirq+steal))
    idle_after=$((idle+iowait))

    total_diff=$((total_after-total_before))
    idle_diff=$((idle_after-idle_before))

    if (( total_diff == 0 )); then
        echo "0%"
        return
    fi

    cpu=$((100*(total_diff-idle_diff)/total_diff))
    echo "${cpu}%"
}

########################################
# 内存（无 ps）
########################################

get_mem_usage() {
    local total avail used

    total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')

    used=$((total - avail))

    echo "$((used/1024))MB / $((total/1024))MB"
}

########################################
# TCP 数量
########################################

get_tcp_count() {
    get_cache tcp
}

########################################
# load average
########################################

get_load() {
    awk '{print $1" "$2" "$3}' /proc/loadavg
}

########################################
# 状态灯
########################################

get_status_light() {
    case "$1" in
        active)
            echo -e "\033[32m●\033[0m"
            ;;
        inactive)
            echo -e "\033[31m●\033[0m"
            ;;
        failed)
            echo -e "\033[31m●\033[0m"
            ;;
        *)
            echo -e "\033[33m●\033[0m"
            ;;
    esac
}

########################################
# top风格面板（核心）
########################################

show_dashboard() {
    update_cache

    local caddy_status xray_status
    local cpu mem tcp load

    caddy_status=$(get_cache caddy)
    xray_status=$(get_cache xray)

    cpu=$(get_cpu_usage)
    mem=$(get_mem_usage)
    tcp=$(get_tcp_count)
    load=$(get_load)

    clear

    echo "=========================================="
    echo " XMG Monitor (Light Mode)"
    echo "------------------------------------------"

    printf " Caddy: %s %-8s   Xray: %s %-8s\n" \
        "$(get_status_light $caddy_status)" "$caddy_status" \
        "$(get_status_light $xray_status)" "$xray_status"

    echo

    printf " CPU: %-10s  MEM: %-18s\n" "$cpu" "$mem"
    printf " TCP: %-10s  Load: %s\n" "$tcp" "$load"

    echo "=========================================="
    echo
}

########################################
# 综合状态（旧功能保留）
########################################

show_services_status() {
    echo "========== 服务状态 =========="
    systemctl is-active caddy 2>/dev/null || echo "caddy: not installed"
    systemctl is-active xray 2>/dev/null || echo "xray: not installed"

    echo
    echo "==========端口=========="
    ss -lntup || true
}

########################################
# 小内存优化（保留）
########################################

optimize_small_vps() {
    echo "[INFO] 优化小内存 VPS..."

    mkdir -p /etc/systemd/journald.conf.d

    cat > /etc/systemd/journald.conf.d/99-xmg.conf <<EOF
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=20M
MaxRetentionSec=7day
EOF

    systemctl restart systemd-journald || true

    if ! swapon --show | grep -q '^'; then
        echo "[INFO] 创建 512M swap..."
        fallocate -l 512M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=512
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile

        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    echo "vm.swappiness=20" >> /etc/sysctl.conf
    sysctl -p || true

    echo "[OK] 优化完成"
}
