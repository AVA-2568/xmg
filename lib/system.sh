#!/usr/bin/env bash
#
# system.sh - 系统信息和小内存 VPS 优化
#

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

get_service_status() {
    local svc="$1"

    if ! service_exists "${svc}"; then
        echo "not installed"
        return
    fi

    local status
    status="$(systemctl is-active "${svc}" 2>/dev/null || true)"

    case "${status}" in
        active)
            echo -e "\033[32mrunning\033[0m"
            ;;
        inactive)
            echo -e "\033[31mstopped\033[0m"
            ;;
        failed)
            echo -e "\033[31mfailed\033[0m"
            ;;
        *)
            echo -e "\033[33munknown\033[0m"
            ;;
    esac
}

show_panel_header() {
    local caddy_status
    local xray_status

    caddy_status="$(get_service_status caddy)"
    xray_status="$(get_service_status xray)"

    echo "===================================="
    echo "  XMG 轻量级 VPS 管理器"
    echo "  Version: ${XMG_VERSION}"
    echo "------------------------------------"
    printf "  Caddy: %-12s | Xray: %-12s\n" "${caddy_status}" "${xray_status}"
    echo "===================================="
}

get_service_status() {
    local svc="$1"

    if ! service_exists "${svc}"; then
        echo "not installed"
        return
    fi

    local status
    status=$(systemctl is-active "${svc}" 2>/dev/null || true)

    case "${status}" in
        active)
            echo -e "\033[32mrunning\033[0m"
            ;;
        inactive)
            echo -e "\033[31mstopped\033[0m"
            ;;
        failed)
            echo -e "\033[31mfailed\033[0m"
            ;;
        *)
            echo -e "\033[33munknown\033[0m"
            ;;
    esac
}

show_services_status() {
    echo
    echo "========== 服务状态 =========="

    if service_exists caddy; then
        if systemctl is-active --quiet caddy; then
            echo "Caddy: running"
        else
            echo "Caddy: stopped"
        fi
    else
        echo "Caddy: not installed"
    fi

    if service_exists xray; then
        if systemctl is-active --quiet xray; then
            echo "Xray: running"
        else
            echo "Xray: stopped"
        fi
    else
        echo "Xray: not installed"
    fi

    echo
    echo "========== 端口监听 =========="
    ss -lntup || true

    echo
    echo "========== 内存占用 =========="
    free -h

    echo
    echo "========== 进程资源占用 TOP 15 =========="
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 15
}

optimize_small_vps() {
    info "开始应用小内存 VPS 基础优化..."

    mkdir -p /etc/systemd/journald.conf.d

    cat > /etc/systemd/journald.conf.d/99-xmg-small-vps.conf <<EOF
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=20M
MaxRetentionSec=7day
EOF

    systemctl restart systemd-journald || true

    if swapon --show | grep -q '^'; then
        warn "检测到系统已有 swap，跳过创建"
    else
        info "创建 512M swap 文件..."

        if ! fallocate -l 512M /swapfile; then
            dd if=/dev/zero of=/swapfile bs=1M count=512
        fi

        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile

        if ! grep -q '^/swapfile ' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
    fi

    cat > /etc/sysctl.d/99-xmg-small-vps.conf <<EOF
vm.swappiness=20
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system || true

    ok "小内存 VPS 优化完成"
}
``
