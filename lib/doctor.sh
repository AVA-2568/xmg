#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# doctor.sh - XMG 远程 VPS 一键健康诊断工具
#
# 说明：
#   - 输出紧凑、信息密集的终端自检报告卡片
#   - 检查 [环境]、[网络]、[资源]、[内核]、[Xray]、[DNS] 六大核心维度的运行状态
#   - 纯 Bash 内建实现，零 jq / 零 python 外部依赖
#   - 支持 xmg doctor [--dry-run] 非交互 CLI 调用，返回码 0(正常) 或 1(严重故障)
#   - 在主菜单提供交互自检入口
#

if [ -z "${BASH_VERSION:-}" ]; then
    echo "doctor.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_DOCTOR_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_DOCTOR_SH_LOADED=1

# XMG_MENU_LABEL: 系统健康体检

# ===== 依赖安全引入 =====
_XMG_DOCTOR_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F xmg_detect_virt >/dev/null 2>&1; then
    if [ -f "$_XMG_DOCTOR_LIBDIR/detect.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_DOCTOR_LIBDIR/detect.sh"
    elif [ -f "${XMG_LIB_DIR:-/opt/xmg/lib}/detect.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-/opt/xmg/lib}/detect.sh"
    fi
fi

if ! declare -F xmg_service_active_read >/dev/null 2>&1; then
    if [ -f "$_XMG_DOCTOR_LIBDIR/system.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_DOCTOR_LIBDIR/system.sh"
    elif [ -f "${XMG_LIB_DIR:-/opt/xmg/lib}/system.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-/opt/xmg/lib}/system.sh"
    fi
fi

if ! declare -F xmg_color_init >/dev/null 2>&1; then
    if [ -f "$_XMG_DOCTOR_LIBDIR/common.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_DOCTOR_LIBDIR/common.sh"
    elif [ -f "${XMG_LIB_DIR:-/opt/xmg/lib}/common.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-/opt/xmg/lib}/common.sh"
    fi
fi
unset _XMG_DOCTOR_LIBDIR

# 基础日志兜底
if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info()  { printf '[INFO] %s\n' "$*"; }
    xmg_warn()  { printf '[WARN] %s\n' "$*" >&2; }
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
    xmg_pause() { printf '\n按 Enter 返回...'; read -r _ || true; }
fi

# ==================================================================
# 核心采集函数
# ==================================================================

# 1. 采集内核 BBR 与队列算法
_xmg_doctor_get_congestion() {
    if [ -n "${MOCK_BBR_STATUS:-}" ]; then
        printf '%s' "$MOCK_BBR_STATUS"
        return 0
    fi
    local cc=""
    if [ -r /proc/sys/net/ipv4/tcp_congestion_control ]; then
        read -r cc < /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
    fi
    if [ -z "$cc" ] && command -v sysctl >/dev/null 2>&1; then
        cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    fi
    printf '%s' "${cc:-unknown}"
}

_xmg_doctor_get_qdisc() {
    if [ -n "${MOCK_QDISC_STATUS:-}" ]; then
        printf '%s' "$MOCK_QDISC_STATUS"
        return 0
    fi
    local qd=""
    if [ -r /proc/sys/net/core/default_qdisc ]; then
        read -r qd < /proc/sys/net/core/default_qdisc 2>/dev/null || true
    fi
    if [ -z "$qd" ] && command -v sysctl >/dev/null 2>&1; then
        qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    fi
    printf '%s' "${qd:-unknown}"
}

# 2. 采集 TCP 缓冲与连接跟踪上限
_xmg_doctor_get_tcp_buf() {
    local rmem=""
    if [ -r /proc/sys/net/ipv4/tcp_rmem ]; then
        read -r rmem < /proc/sys/net/ipv4/tcp_rmem 2>/dev/null || true
    fi
    if [ -z "$rmem" ] && [ -r /proc/sys/net/core/rmem_max ]; then
        read -r rmem < /proc/sys/net/core/rmem_max 2>/dev/null || true
    fi
    if [ -n "$rmem" ]; then
        printf '%s' "$rmem"
    else
        printf '系统默认'
    fi
}

_xmg_doctor_get_conntrack_max() {
    local ct=""
    local ct_file="${XMG_TUNE_CONNTRACK_FILE:-/proc/sys/net/netfilter/nf_conntrack_max}"
    if [ -r "$ct_file" ]; then
        read -r ct < "$ct_file" 2>/dev/null || true
    elif [ -r /proc/sys/net/nf_conntrack_max ]; then
        read -r ct < /proc/sys/net/nf_conntrack_max 2>/dev/null || true
    fi
    if [ -n "$ct" ]; then
        printf '%s' "$ct"
    else
        printf '未加载/无限制'
    fi
}

# 3. 采集内存与 Swap 概况
_xmg_doctor_get_memory_summary() {
    local total_kb=0
    local avail_kb=0
    local free_kb=0
    local buffers_kb=0
    local cached_kb=0
    local k="" v="" rest=""

    if [ -n "${MOCK_MEM_TOTAL_KB:-}" ]; then
        total_kb="$MOCK_MEM_TOTAL_KB"
        avail_kb=$((total_kb * 7 / 10))
    elif [ -r /proc/meminfo ]; then
        while IFS=': ' read -r k v rest; do
            case "$k" in
                MemTotal) total_kb="${v//[!0-9]/}" ;;
                MemAvailable) avail_kb="${v//[!0-9]/}" ;;
                MemFree) free_kb="${v//[!0-9]/}" ;;
                Buffers) buffers_kb="${v//[!0-9]/}" ;;
                Cached) cached_kb="${v//[!0-9]/}" ;;
            esac
            if [ "$total_kb" -gt 0 ] && [ "$avail_kb" -gt 0 ]; then
                break
            fi
        done < /proc/meminfo
        if [ "$avail_kb" -le 0 ]; then
            avail_kb=$((free_kb + buffers_kb + cached_kb))
        fi
    fi

    if [ "$total_kb" -gt 0 ]; then
        local total_mb=$((total_kb / 1024))
        local avail_mb=$((avail_kb / 1024))
        local used_mb=$((total_mb - avail_mb))
        [ "$used_mb" -lt 0 ] && used_mb=0
        local pct=$((used_mb * 100 / total_mb))
        printf '%dMB (可用: %dMB, 已用: %d%%)' "$total_mb" "$avail_mb" "$pct"
    else
        printf '未知'
    fi
}

_xmg_doctor_get_swap_summary() {
    local swap_total_kb=0
    local swap_free_kb=0
    local k="" v="" rest=""

    if [ -r /proc/meminfo ]; then
        while IFS=': ' read -r k v rest; do
            case "$k" in
                SwapTotal) swap_total_kb="${v//[!0-9]/}" ;;
                SwapFree) swap_free_kb="${v//[!0-9]/}" ;;
            esac
        done < /proc/meminfo
    fi

    if [ "$swap_total_kb" -gt 0 ]; then
        local total_mb=$((swap_total_kb / 1024))
        local free_mb=$((swap_free_kb / 1024))
        local used_mb=$((total_mb - free_mb))
        [ "$used_mb" -lt 0 ] && used_mb=0
        printf '%dMB (已用 %dMB)' "$total_mb" "$used_mb"
    else
        printf '未挂载'
    fi
}

# 4. 采集 Xray 状态与配置校验
_xmg_doctor_get_xray_version() {
    if [ -n "${MOCK_XRAY_VERSION:-}" ]; then
        printf '%s' "$MOCK_XRAY_VERSION"
        return 0
    fi
    local bin=""
    if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
        bin="$(xmg_xray_get_bin 2>/dev/null || true)"
    elif command -v xray >/dev/null 2>&1; then
        bin="$(command -v xray)"
    elif [ -x /usr/local/bin/xray ]; then
        bin="/usr/local/bin/xray"
    elif [ -x /usr/bin/xray ]; then
        bin="/usr/bin/xray"
    fi

    if [ -n "$bin" ] && [ -x "$bin" ]; then
        local v=""
        v="$("$bin" version 2>/dev/null | head -n 1 || true)"
        printf '%s' "${v:-未知版本}"
    else
        printf '未安装'
    fi
}

_xmg_doctor_get_xray_status() {
    if [ -n "${MOCK_XRAY_STATUS:-}" ]; then
        printf '%s' "$MOCK_XRAY_STATUS"
        return 0
    fi
    if declare -F xmg_service_active_read >/dev/null 2>&1; then
        xmg_service_active_read "${XMG_XRAY_SERVICE:-xray}"
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "${XMG_XRAY_SERVICE:-xray}" 2>/dev/null; then
            printf 'running'
        else
            printf 'stopped'
        fi
        return 0
    fi
    printf 'unknown'
}

_xmg_doctor_validate_xray_config() {
    if [ -n "${MOCK_XRAY_CONFIG_VALID:-}" ]; then
        if [ "$MOCK_XRAY_CONFIG_VALID" = "1" ]; then
            return 0
        else
            return 1
        fi
    fi

    local cfg="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
    if [ ! -f "$cfg" ]; then
        # 配置文件尚未创建时，若无其他配置则视为待配置（不判严重语法故障）
        return 0
    fi

    local bin=""
    if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
        bin="$(xmg_xray_get_bin 2>/dev/null || true)"
    elif command -v xray >/dev/null 2>&1; then
        bin="$(command -v xray)"
    fi

    if [ -n "$bin" ] && [ -x "$bin" ]; then
        if "$bin" run -test -format json -c "$cfg" >/dev/null 2>&1 || "$bin" run -test -c "$cfg" >/dev/null 2>&1 || "$bin" -test -config "$cfg" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    fi

    # 兜底：纯 Bash 基础 JSON 结构完整性校验（首字符 { 尾字符 }）
    local content=""
    content="$(tr -d '[:space:]' < "$cfg" 2>/dev/null || true)"
    if [[ "$content" == "{"*"}" ]]; then
        return 0
    fi
    return 1
}

_xmg_doctor_get_gomemlimit() {
    if [ -n "${MOCK_GOMEMLIMIT:-}" ]; then
        printf '%s' "$MOCK_GOMEMLIMIT"
        return 0
    fi
    local dropin="${XMG_SYSTEMD_DIR:-/etc/systemd/system}/${XMG_XRAY_SERVICE:-xray}.service.d/20-xmg.conf"
    if [ -r "$dropin" ]; then
        local line=""
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ GOMEMLIMIT=([^[:space:]\"]+) ]]; then
                printf '%s' "${BASH_REMATCH[1]}"
                return 0
            fi
        done < "$dropin"
    fi
    printf '未配置'
}

_xmg_doctor_get_listening_ports() {
    if [ -n "${MOCK_LISTENING_PORTS:-}" ]; then
        printf '%s' "$MOCK_LISTENING_PORTS"
        return 0
    fi

    # 仅检测 Xray 自身的业务入站端口，避免将宿主机 SSH (22) 等端口误报为 Xray 端口
    local candidate_ports=()
    local socks_on="0" vless_on="0"
    if declare -F xmg_state_get >/dev/null 2>&1; then
        socks_on="$(xmg_state_get PROXY_SOCKS_ENABLED "0")"
        vless_on="$(xmg_state_get PROXY_VLESS_ENABLED "0")"
        if [ "$vless_on" = "1" ]; then
            local vp
            vp="$(xmg_state_get PROXY_VLESS_PORT "443")"
            [ -n "$vp" ] && candidate_ports+=("$vp")
        fi
        if [ "$socks_on" = "1" ]; then
            local sp
            sp="$(xmg_state_get PROXY_SOCKS_PORT "1080")"
            [ -n "$sp" ] && candidate_ports+=("$sp")
        fi
    fi

    # 若未启用任何代理入站方案
    if [ "$socks_on" != "1" ] && [ "$vless_on" != "1" ]; then
        # 兼容兜底：若 Xray 运行中且 443 处于监听（默认预设），展示 443
        local xray_st=""
        xray_st="$(_xmg_doctor_get_xray_status 2>/dev/null || true)"
        if [ "$xray_st" = "running" ] && declare -F xmg_port_status >/dev/null 2>&1; then
            if [ "$(xmg_port_status 443 2>/dev/null)" = "listen" ]; then
                printf '443'
                return 0
            fi
        fi
        printf '未配置入站'
        return 0
    fi

    local active_ports=()
    local p=""
    for p in "${candidate_ports[@]}"; do
        if declare -F xmg_port_status >/dev/null 2>&1; then
            local st=""
            st="$(xmg_port_status "$p" 2>/dev/null || echo "closed")"
            if [ "$st" = "listen" ]; then
                active_ports+=("$p")
            fi
        fi
    done

    if [ "${#active_ports[@]}" -gt 0 ]; then
        local IFS=','
        printf '%s' "${active_ports[*]}"
    else
        printf '未就绪 (端口未监听)'
    fi
}

# 5. 提取 Xray 生效或预期的 DoH 配置
_xmg_doctor_xray_dns() {
    if [ -n "${MOCK_DOH_ADDR:-}" ]; then
        printf '%s' "$MOCK_DOH_ADDR"
        return 0
    fi
    local cfg="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
    local doh=""
    if [ -r "$cfg" ]; then
        doh="$(grep -oE 'https\+local://[^"]+' "$cfg" 2>/dev/null | head -n 1 || true)"
    fi
    if [ -z "$doh" ]; then
        if [ "${XMG_NET_IPV4:-0}" = "0" ] && [ "${XMG_NET_IPV6:-0}" = "1" ]; then
            doh="https+local://[2606:4700:4700::1111]/dns-query"
        else
            doh="https+local://1.1.1.1/dns-query"
        fi
    fi
    printf '%s' "$doh"
}

_xmg_doctor_get_dns_info() {
    local doh="" out_strat=""
    doh="$(_xmg_doctor_xray_dns)"

    local cfg="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
    if [ -n "${MOCK_DOMAIN_STRATEGY:-}" ]; then
        out_strat="$MOCK_DOMAIN_STRATEGY"
    elif [ -r "$cfg" ]; then
        out_strat="$(grep -oE '"domainStrategy"[[:space:]]*:[[:space:]]*"[^"]+"' "$cfg" 2>/dev/null | head -n 1 | cut -d'"' -f4 || true)"
    fi
    if [ -z "$out_strat" ]; then
        if [ "${XMG_NET_IPV4:-0}" = "0" ] && [ "${XMG_NET_IPV6:-0}" = "1" ]; then
            out_strat="UseIPv6"
        else
            out_strat="UseIP"
        fi
    fi

    printf '%s|%s\n' "$doh" "$out_strat"
}

# 5.1 检查 TLS 证书剩余有效天数
_xmg_doctor_get_cert_status() {
    if [ -n "${MOCK_CERT_STATUS:-}" ]; then
        printf '%s' "$MOCK_CERT_STATUS"
        return 0
    fi
    local cert_file=""
    if declare -F xmg_state_get >/dev/null 2>&1; then
        cert_file="$(xmg_state_get PROXY_VLESS_CERT_FILE "" 2>/dev/null || true)"
    fi
    if [ -z "$cert_file" ] || [ ! -f "$cert_file" ]; then
        local def_cert="${XMG_HOME:-/opt/xmg}/etc/xray/certs/fullchain.crt"
        if [ -f "$def_cert" ]; then
            cert_file="$def_cert"
        fi
    fi

    if [ -z "$cert_file" ] || [ ! -f "$cert_file" ]; then
        printf '未配置'
        return 0
    fi

    if command -v openssl >/dev/null 2>&1; then
        local end_date=""
        end_date="$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2 || true)"
        if [ -n "$end_date" ]; then
            local end_ts now_ts diff_s days
            end_ts="$(date -d "$end_date" +%s 2>/dev/null || echo 0)"
            now_ts="$(date +%s)"
            diff_s=$((end_ts - now_ts))
            days=$((diff_s / 86400))
            if [ "$diff_s" -le 0 ]; then
                printf '已过期'
            elif [ "$days" -le 15 ]; then
                printf '即将过期 (剩余 %d 天)' "$days"
            else
                printf '有效 (剩余 %d 天)' "$days"
            fi
            return 0
        fi
    fi
    printf '已就绪'
}

# 5.2 探测当前 DoH 解析连通性与网络延迟
_xmg_doctor_get_doh_latency() {
    if [ -n "${MOCK_DOH_LATENCY:-}" ]; then
        printf '%s' "$MOCK_DOH_LATENCY"
        return 0
    fi
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        printf '35ms (优秀)'
        return 0
    fi

    local doh_addr="${1:-}"
    if [ -z "$doh_addr" ]; then
        doh_addr="$(_xmg_doctor_xray_dns)"
    fi
    local doh_url=""
    case "$doh_addr" in
        https+local://*) doh_url="https://${doh_addr#https+local://}" ;;
        https://*)        doh_url="$doh_addr" ;;
        *)               doh_url="https://1.1.1.1/dns-query" ;;
    esac

    if command -v curl >/dev/null 2>&1; then
        local rtt=""
        rtt="$(curl -s -o /dev/null -w "%{time_connect}\n" --connect-timeout 2 "$doh_url" 2>/dev/null || true)"
        if [ -n "$rtt" ] && [ "$rtt" != "0.000" ] && [ "$rtt" != "0.000000" ]; then
            local ms
            ms="$(awk -v t="$rtt" 'BEGIN { printf "%.0f", t * 1000 }' 2>/dev/null || echo 0)"
            if [ "$ms" -lt 80 ]; then
                printf '%dms (优秀)' "$ms"
            elif [ "$ms" -lt 200 ]; then
                printf '%dms (良好)' "$ms"
            else
                printf '%dms (较高)' "$ms"
            fi
            return 0
        fi
    fi
    printf '超时/不可达'
}

# 6. 采集防火墙状态
_xmg_doctor_get_firewall_status() {
    if [ -n "${MOCK_FIREWALL_STATUS:-}" ]; then
        printf '%s' "$MOCK_FIREWALL_STATUS"
        return 0
    fi
    if command -v ufw >/dev/null 2>&1; then
        local ufw_out
        ufw_out="$(ufw status 2>/dev/null || true)"
        if [[ "$ufw_out" == *"Status: active"* ]]; then
            printf 'ufw (active)'
            return 0
        fi
    fi
    if command -v nft >/dev/null 2>&1; then
        local nft_rules
        nft_rules="$(nft list ruleset 2>/dev/null || true)"
        if [ -n "$nft_rules" ]; then
            printf 'nftables (active)'
            return 0
        fi
    fi
    if command -v iptables >/dev/null 2>&1; then
        local ipt_lines
        ipt_lines="$(iptables -L -n 2>/dev/null | wc -l 2>/dev/null || echo 0)"
        if [ "$ipt_lines" -gt 8 ]; then
            printf 'iptables (active)'
            return 0
        fi
    fi
    printf '未启用/未配置'
}

# 7. 采集真实 SSH 端口
_xmg_doctor_get_ssh_port() {
    if [ -n "${MOCK_SSH_PORT:-}" ]; then
        printf '%s' "$MOCK_SSH_PORT"
        return 0
    fi
    if declare -F xmg_ssh_get_port >/dev/null 2>&1; then
        local p
        p="$(xmg_ssh_get_port 2>/dev/null || true)"
        if [ -n "$p" ]; then
            printf '%s' "$p"
            return 0
        fi
    fi
    local sshd_bin=""
    if command -v sshd >/dev/null 2>&1; then
        sshd_bin="$(command -v sshd)"
    elif [ -x /usr/sbin/sshd ]; then
        sshd_bin="/usr/sbin/sshd"
    fi
    if [ -n "$sshd_bin" ]; then
        local val
        val="$("$sshd_bin" -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)"
        if [ -n "$val" ]; then
            printf '%s' "$val"
            return 0
        fi
    fi
    if [ -r /etc/ssh/sshd_config ]; then
        local cfg_port
        cfg_port="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | head -n 1 | awk '{print $2}' || true)"
        if [ -n "$cfg_port" ]; then
            printf '%s' "$cfg_port"
            return 0
        fi
    fi
    printf '22'
}

# 8. 采集 NTP 时钟同步状态与偏差
_xmg_doctor_get_ntp_status() {
    if [ -n "${MOCK_NTP_STATUS:-}" ]; then
        printf '%s' "$MOCK_NTP_STATUS"
        return 0
    fi
    local offset=""
    local synced=""
    if command -v timedatectl >/dev/null 2>&1; then
        synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
        if [ "$synced" = "yes" ]; then
            offset="$(timedatectl timesync-status 2>/dev/null | awk -F': ' '/Offset:/ {print $2; exit}' || true)"
            if [ -n "$offset" ]; then
                printf '已同步 (偏差: %s)' "$offset"
            else
                printf '已同步'
            fi
            return 0
        fi
        local status_out
        status_out="$(timedatectl status 2>/dev/null || true)"
        if [[ "$status_out" == *"synchronized: yes"* ]]; then
            printf '已同步'
            return 0
        fi
    fi
    if command -v chronyc >/dev/null 2>&1; then
        local sys_time
        sys_time="$(chronyc tracking 2>/dev/null | awk -F': ' '/System time/ {print $2; exit}' || true)"
        if [ -n "$sys_time" ]; then
            printf '已同步 (偏差: %s)' "$sys_time"
            return 0
        fi
    fi
    printf '未同步/未配置'
}

# ==================================================================
# 自检主运行器
# ==================================================================
xmg_doctor_run() {
    local dry_run=0
    local arg=""
    for arg in "$@"; do
        if [ "$arg" = "--dry-run" ]; then
            dry_run=1
        fi
    done

    # 初始化颜色
    if declare -F xmg_color_init >/dev/null 2>&1; then
        xmg_color_init
    fi

    local c_reset="${XMG_C_RESET:-}"
    local c_bold="${XMG_C_BOLD:-}"
    local c_green="${XMG_C_GREEN:-}"
    local c_red="${XMG_C_RED:-}"
    local c_yellow="${XMG_C_YELLOW:-}"
    local c_cyan="${XMG_C_CYAN:-}"

    local has_critical=0

    # 1. 环境采集
    local virt="unknown"
    if declare -F xmg_detect_virt >/dev/null 2>&1; then
        virt="$(xmg_detect_virt)"
    fi

    local mem_prof="mid"
    if declare -F xmg_detect_mem_profile >/dev/null 2>&1; then
        mem_prof="$(xmg_detect_mem_profile)"
    fi

    local container_status="特权 (正常)"
    if declare -F xmg_detect_container_restricted >/dev/null 2>&1; then
        if ! xmg_detect_container_restricted; then
            container_status="受限容器"
        fi
    fi

    # 2. 网络采集
    if declare -F xmg_detect_network >/dev/null 2>&1; then
        xmg_detect_network
    fi
    local net_v4="${XMG_NET_IPV4:-0}"
    local net_v6="${XMG_NET_IPV6:-0}"
    local net_nat="${XMG_NET_NAT:-0}"
    local net_nat64="${XMG_NET_NAT64:-0}"

    local v4_str="禁用/无"
    [ "$net_v4" = "1" ] && v4_str="正常"
    local v6_str="禁用/无"
    [ "$net_v6" = "1" ] && v6_str="正常"
    local nat_str="否"
    [ "$net_nat" = "1" ] && nat_str="是 (NAT)"
    local nat64_str="不支持"
    [ "$net_nat64" = "1" ] && nat64_str="支持"

    # 3. 资源采集
    local mem_summary=""
    mem_summary="$(_xmg_doctor_get_memory_summary)"
    local swap_summary=""
    swap_summary="$(_xmg_doctor_get_swap_summary)"

    # 4. 内核与网络调优采集
    local bbr_cc=""
    bbr_cc="$(_xmg_doctor_get_congestion)"
    local qdisc=""
    qdisc="$(_xmg_doctor_get_qdisc)"
    local tcp_buf=""
    tcp_buf="$(_xmg_doctor_get_tcp_buf)"
    local conntrack_max=""
    conntrack_max="$(_xmg_doctor_get_conntrack_max)"

    # 5. Xray 核心运行状态
    local xray_ver=""
    xray_ver="$(_xmg_doctor_get_xray_version)"
    local xray_st=""
    xray_st="$(_xmg_doctor_get_xray_status)"
    local cfg_valid_str="OK"
    if ! _xmg_doctor_validate_xray_config; then
        cfg_valid_str="FAIL"
        has_critical=1
    fi
    local gomemlimit=""
    gomemlimit="$(_xmg_doctor_get_gomemlimit)"
    local listen_ports=""
    listen_ports="$(_xmg_doctor_get_listening_ports)"

    # 6. DNS 与出站解析（真实读取，绝不无条件覆写）
    local dns_info=""
    dns_info="$(_xmg_doctor_get_dns_info)"
    local doh_addr="${dns_info%%|*}"
    local out_resolve="${dns_info##*|}"

    # 7. 安全与系统体检项（防火墙、SSH 端口、NTP 时钟）
    local fw_status=""
    fw_status="$(_xmg_doctor_get_firewall_status)"
    local ssh_port=""
    ssh_port="$(_xmg_doctor_get_ssh_port)"
    local ntp_status=""
    ntp_status="$(_xmg_doctor_get_ntp_status)"

    # 8. Critical 联合判定规则
    if [ "${MOCK_NTP_CRITICAL:-0}" = "1" ]; then
        has_critical=1
    fi
    # 显式故障模拟覆盖
    if [ "${MOCK_DOCTOR_FAIL:-0}" = "1" ]; then
        has_critical=1
    fi

    # ================= 终端卡片输出 =================
    printf '%s================================================================================%s\n' "$c_cyan" "$c_reset"
    printf '%s                         XMG VPS 健康诊断报告 (Doctor)%s\n' "$c_bold" "$c_reset"
    printf '%s================================================================================%s\n' "$c_cyan" "$c_reset"

    local render_mode="纯Bash (零依赖)"
    if command -v jq >/dev/null 2>&1; then
        render_mode="jq + 纯Bash"
    fi

    # [环境]
    printf '%s[环境]%s 架构: %s%s%s | 内存分档: %s%s%s | 容器特权: %s%s%s | 渲染引擎: %s%s%s\n' \
        "$c_bold" "$c_reset" \
        "$c_cyan" "$virt" "$c_reset" \
        "$c_cyan" "$mem_prof" "$c_reset" \
        "$c_cyan" "$container_status" "$c_reset" \
        "$c_cyan" "$render_mode" "$c_reset"

    # [网络]
    printf '%s[网络]%s IPv4: %s%s%s | IPv6: %s%s%s | NAT: %s%s%s | NAT64: %s%s%s\n' \
        "$c_bold" "$c_reset" \
        "$c_cyan" "$v4_str" "$c_reset" \
        "$c_cyan" "$v6_str" "$c_reset" \
        "$c_cyan" "$nat_str" "$c_reset" \
        "$c_cyan" "$nat64_str" "$c_reset"

    # [资源]
    printf '%s[资源]%s 物理内存: %s%s%s | Swap: %s%s%s\n' \
        "$c_bold" "$c_reset" \
        "$c_cyan" "$mem_summary" "$c_reset" \
        "$c_cyan" "$swap_summary" "$c_reset"

    # [内核]
    printf '%s[内核]%s 拥塞控制: %s%s%s | 队列算法: %s%s%s | TCP 缓冲: %s | 连接跟踪上限: %s%s%s\n' \
        "$c_bold" "$c_reset" \
        "$c_cyan" "$bbr_cc" "$c_reset" \
        "$c_cyan" "$qdisc" "$c_reset" \
        "$tcp_buf" \
        "$c_cyan" "$conntrack_max" "$c_reset"

    # [Xray]
    local cfg_color="$c_green"
    [ "$cfg_valid_str" = "FAIL" ] && cfg_color="$c_red"
    local cert_st=""
    cert_st="$(_xmg_doctor_get_cert_status)"
    printf '%s[Xray]%s 版本: %s%s%s | 状态: %s%s%s | 配置校验: %s%s%s | 证书: %s%s%s | 内存抑制: %s%s%s | 监听端口: %s%s%s\n' \
        "$c_bold" "$c_reset" \
        "$c_cyan" "$xray_ver" "$c_reset" \
        "$c_cyan" "$xray_st" "$c_reset" \
        "$cfg_color" "$cfg_valid_str" "$c_reset" \
        "$c_cyan" "$cert_st" "$c_reset" \
        "$c_cyan" "$gomemlimit" "$c_reset" \
        "$c_cyan" "$listen_ports" "$c_reset"

    # [DNS]
    local doh_lat=""
    doh_lat="$(_xmg_doctor_get_doh_latency "$doh_addr")"
    printf '%s[DNS]%s  内置 DoH: %s%s%s | 延迟: %s%s%s | 出站解析模式: %s%s%s\n' \
        "$c_bold" "$c_reset" \
        "$c_cyan" "$doh_addr" "$c_reset" \
        "$c_cyan" "$doh_lat" "$c_reset" \
        "$c_cyan" "$out_resolve" "$c_reset"

    # [安全]
    printf '%s[安全]%s 防火墙: %s%s%s | SSH 端口: %s%s%s | NTP 时钟: %s%s%s\n' \
        "$c_bold" "$c_reset" \
        "$c_cyan" "$fw_status" "$c_reset" \
        "$c_cyan" "$ssh_port" "$c_reset" \
        "$c_cyan" "$ntp_status" "$c_reset"

    printf '%s--------------------------------------------------------------------------------%s\n' "$c_cyan" "$c_reset"

    if [ "$has_critical" -eq 0 ]; then
        printf '%s结论: 系统运行正常，无关键故障 (PASS)%s\n' "$c_green" "$c_reset"
    else
        printf '%s结论: 存在严重故障或配置异常，请核对上述标记为 FAIL 或异常的项目 (CRITICAL)%s\n' "$c_red" "$c_reset"
    fi
    printf '%s================================================================================%s\n' "$c_cyan" "$c_reset"

    return "$has_critical"
}

# ==================================================================
# CLI 入口与菜单接口
# ==================================================================
xmg_doctor_cli() {
    local dry_run=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            -h|--help)
                cat <<EOF
用法:
  xmg doctor [--dry-run]

说明:
  运行 VPS 一键健康诊断，输出环境、网络、资源、内核、Xray、DNS 等自检卡片。
  返回码: 0 正常，1 存在严重故障。
EOF
                return 0
                ;;
            *)
                shift
                ;;
        esac
    done

    if [ "$dry_run" -eq 1 ]; then
        xmg_doctor_run --dry-run
    else
        xmg_doctor_run
    fi
}

xmg_doctor_menu() {
    clear
    xmg_doctor_run || true
    xmg_pause
}
