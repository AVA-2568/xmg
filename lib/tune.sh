#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# tune.sh - XMG 系统调优模块
#
# 说明：
#   - 提供 VPS 通用一键调优：BBR+FQ、内核网络参数、DNS、时间同步、Swap
#   - sysctl 配置写入 /etc/sysctl.d/，limits 写入 /etc/security/limits.d/
#   - DNS 优先使用 systemd-resolved drop-in，避免直接改被管理的 resolv.conf
#   - 所有被覆盖的配置先备份到 $XMG_BACKUP_DIR/tune/
#

# tune.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "tune.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_TUNE_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_TUNE_SH_LOADED=1

# XMG_MENU_LABEL: 系统与网络调优

# ===== 默认配置 =====
XMG_TUNE_SYSCTL_NET_CONF="${XMG_TUNE_SYSCTL_NET_CONF:-/etc/sysctl.d/99-xmg-tune.conf}"
XMG_TUNE_SYSCTL_BBR_CONF="${XMG_TUNE_SYSCTL_BBR_CONF:-/etc/sysctl.d/99-xmg-bbr.conf}"
XMG_TUNE_SYSCTL_SWAP_CONF="${XMG_TUNE_SYSCTL_SWAP_CONF:-/etc/sysctl.d/99-xmg-swap.conf}"
XMG_TUNE_LIMITS_CONF="${XMG_TUNE_LIMITS_CONF:-/etc/security/limits.d/99-xmg-nofile.conf}"
XMG_TUNE_SYSTEMD_LIMITS_CONF="${XMG_TUNE_SYSTEMD_LIMITS_CONF:-/etc/systemd/system.conf.d/99-xmg-limits.conf}"
XMG_TUNE_RESOLVED_CONF="${XMG_TUNE_RESOLVED_CONF:-/etc/systemd/resolved.conf.d/xmg-dns.conf}"
XMG_TUNE_MODULES_LOAD_CONF="${XMG_TUNE_MODULES_LOAD_CONF:-/etc/modules-load.d/xmg-bbr.conf}"
XMG_TUNE_NOFILE="${XMG_TUNE_NOFILE:-1048576}"
XMG_TUNE_SWAPFILE="${XMG_TUNE_SWAPFILE:-/swapfile}"
XMG_BACKUP_DIR="${XMG_BACKUP_DIR:-${XMG_HOME:-/var/lib/xmg}/backups}"

# DNS 默认预设（境外优先：本面板多部署于海外服务器，阿里 DNS 直连延迟高）
XMG_TUNE_DNS_DEFAULT="${XMG_TUNE_DNS_DEFAULT:-1.1.1.1 1.0.0.1}"
XMG_TUNE_DOT_DEFAULT="${XMG_TUNE_DOT_DEFAULT:-1.1.1.1 1.0.0.1}"
export XMG_TUNE_DNS_DEFAULT XMG_TUNE_DOT_DEFAULT

# ===== 自包含加载依赖 (common.sh + detect.sh) =====
_XMG_TUNE_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F xmg_info >/dev/null 2>&1; then
    if [ -f "$_XMG_TUNE_LIBDIR/common.sh" ]; then
        # shellcheck source=lib/common.sh
        source "$_XMG_TUNE_LIBDIR/common.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/common.sh" ]; then
        # shellcheck source=lib/common.sh
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/common.sh"
    fi
fi

if ! declare -F xmg_detect_mem_profile >/dev/null 2>&1; then
    if [ -f "$_XMG_TUNE_LIBDIR/detect.sh" ]; then
        # shellcheck source=lib/detect.sh
        source "$_XMG_TUNE_LIBDIR/detect.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/detect.sh" ]; then
        # shellcheck source=lib/detect.sh
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/detect.sh"
    fi
fi

# ===== 依赖 common.sh 的兜底 =====

if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info()  { printf '[INFO] %s\n' "$*"; }
fi
if ! declare -F xmg_warn >/dev/null 2>&1; then
    xmg_warn()  { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_error >/dev/null 2>&1; then
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_die >/dev/null 2>&1; then
    xmg_die()   { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fi
if ! declare -F xmg_cmd_exists >/dev/null 2>&1; then
    xmg_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
fi
if ! declare -F xmg_require_root >/dev/null 2>&1; then
    xmg_require_root() {
        if [ "$(id -u)" -ne 0 ]; then
            xmg_die "请使用 root 用户运行，或使用 sudo 执行"
        fi
    }
fi
if ! declare -F xmg_confirm >/dev/null 2>&1; then
    xmg_confirm() {
        local prompt="${1:-确认继续?}"
        local answer=""
        printf '%s [y/N]: ' "$prompt"
        read -r answer || return 1
        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            *) return 1 ;;
        esac
    }
fi
if ! declare -F xmg_pause >/dev/null 2>&1; then
    xmg_pause() {
        printf '\n按 Enter 返回...'
        read -r _ || true
    }
fi
if ! declare -F xmg_timestamp >/dev/null 2>&1; then
    xmg_timestamp() { date '+%Y%m%d-%H%M%S'; }
fi

# ===== 通用辅助 =====

# 读取总内存（MB）。探测失败时按 512MB 处理（保守档位）
xmg_tune_mem_total_mb() {
    if [ -n "${MOCK_MEM_TOTAL_MB:-}" ]; then
        echo "$MOCK_MEM_TOTAL_MB"
        return 0
    fi

    local key=""
    local value=""

    while read -r key value _; do
        case "$key" in
            MemTotal:)
                case "$value" in
                    ''|*[!0-9]*) break ;;
                esac
                echo $((value / 1024))
                return 0
                ;;
        esac
    done < "${XMG_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null

    echo 512
}

# 读取总 Swap（MB）
xmg_tune_swap_total_mb() {
    if [ -n "${MOCK_SWAP_TOTAL_MB:-}" ]; then
        echo "$MOCK_SWAP_TOTAL_MB"
        return 0
    fi

    local key=""
    local value=""

    while read -r key value _; do
        case "$key" in
            SwapTotal:)
                case "$value" in
                    ''|*[!0-9]*) break ;;
                esac
                echo $((value / 1024))
                return 0
                ;;
        esac
    done < "${XMG_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null

    echo 0
}

# 计算 vm.swappiness：极小内存且有 Swap 时设为 60（防止 Direct Reclaim 突发 OOM 崩溃），高配机设为 10
xmg_tune_calc_swappiness() {
    local mem_mb="${1:-}"
    local swap_mb="${2:-}"

    if [ -z "$mem_mb" ]; then
        mem_mb="$(xmg_tune_mem_total_mb)"
    fi
    if [ -z "$swap_mb" ]; then
        swap_mb="$(xmg_tune_swap_total_mb)"
    fi

    if [ "$mem_mb" -le 256 ] && [ "$swap_mb" -gt 0 ]; then
        echo 60
    else
        echo 10
    fi
}

# 按内存返回调优档位：extreme_low (<=256MB) / low (<=512MB) / mid (<=2048MB) / high
xmg_tune_mem_profile() {
    local mem_mb="${1:-}"

    if [ -z "$mem_mb" ]; then
        if declare -F xmg_detect_mem_profile >/dev/null 2>&1; then
            xmg_detect_mem_profile
            return 0
        fi
        mem_mb="$(xmg_tune_mem_total_mb)"
    fi

    if [ "$mem_mb" -le 256 ]; then
        printf 'extreme_low'
    elif [ "$mem_mb" -le 512 ]; then
        printf 'low'
    elif [ "$mem_mb" -le 2048 ]; then
        printf 'mid'
    else
        printf 'high'
    fi
}

# 备份将被覆盖的配置文件到 $XMG_BACKUP_DIR/tune/
xmg_tune_backup_file() {
    local file="$1"
    local dir="$XMG_BACKUP_DIR/tune"

    [ -e "$file" ] || return 0

    mkdir -p "$dir" || return 1
    cp -a -- "$file" "$dir/$(basename "$file").$(xmg_timestamp).bak" || {
        xmg_warn "备份失败: $file"
        return 1
    }
    xmg_info "已备份 $file -> $dir/"
}

# 逐行应用 sysctl 配置文件，失败的 key 警告但不中断
# 在受限容器环境下（如 OpenVZ/LXC/Docker 只读 sysctl），对不可写参数静默跳过并友情提示，平滑熔断返回 0
xmg_tune_sysctl_apply() {
    local file="$1"
    local line=""
    local failed=0
    local is_restricted=0

    if [ ! -r "$file" ]; then
        xmg_error "sysctl 配置不可读: $file"
        return 1
    fi

    if declare -F xmg_detect_container_restricted >/dev/null 2>&1; then
        if ! xmg_detect_container_restricted; then
            is_restricted=1
        fi
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*)
                continue
                ;;
        esac

        if ! sysctl -q -w "$line" >/dev/null 2>&1; then
            failed=$((failed + 1))
            if [ "$is_restricted" -eq 0 ]; then
                xmg_warn "sysctl 应用失败: $line"
            fi
        fi
    done < "$file"

    if [ "$is_restricted" -eq 1 ]; then
        if [ "$failed" -gt 0 ]; then
            xmg_info "当前处于受限容器环境，已自动跳过不可写内核参数 ($failed 项)"
        fi
        return 0
    fi

    if [ "$failed" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ===== BBR + FQ =====

# 检测内核是否支持 BBR（需要 4.9+ 且启用 tcp_bbr）
xmg_tune_bbr_supported() {
    # 已加载或内建时静默通过；模块不存在时失败也无妨，再看可用算法列表
    modprobe tcp_bbr 2>/dev/null || true

    local avail=""
    avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo '')"

    case " $avail " in
        *" bbr "*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

xmg_tune_bbr_enable() {
    xmg_require_root

    if ! xmg_tune_bbr_supported; then
        xmg_error "当前内核不支持 BBR（需要内核 4.9+ 且启用 tcp_bbr）"
        xmg_warn "当前内核: $(uname -r 2>/dev/null || echo unknown)"
        xmg_warn "可尝试升级系统内核后重试"
        return 1
    fi

    xmg_warn "将写入 $XMG_TUNE_SYSCTL_BBR_CONF 并立即应用"

    if ! xmg_confirm "确认开启 BBR + FQ?"; then
        xmg_info "已取消"
        return 0
    fi

    # 模块开机自动加载（内建时此文件无害）
    if [ -d /etc/modules-load.d ]; then
        printf 'tcp_bbr\n' > "$XMG_TUNE_MODULES_LOAD_CONF"
    fi

    cat > "$XMG_TUNE_SYSCTL_BBR_CONF" <<'EOF'
# XMG: BBR + FQ（由 xmg tune 生成）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    xmg_tune_sysctl_apply "$XMG_TUNE_SYSCTL_BBR_CONF" || \
        xmg_warn "部分内核参数写入失败（容器/精简内核常见），以验证结果为准"

    local cc=""
    local qdisc=""
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"

    if [ "$cc" = "bbr" ]; then
        xmg_info "BBR 已启用: 拥塞控制=$cc, 队列=$qdisc"
    else
        xmg_error "BBR 启用失败，当前拥塞控制: $cc"
        return 1
    fi
}

# ===== 内核网络参数优化 =====

# 写入 nofile limits：PAM limits + systemd DefaultLimitNOFILE
xmg_tune_write_limits() {
    cat > "$XMG_TUNE_LIMITS_CONF" <<EOF
# XMG: nofile limits（由 xmg tune 生成）
* soft nofile $XMG_TUNE_NOFILE
* hard nofile $XMG_TUNE_NOFILE
root soft nofile $XMG_TUNE_NOFILE
root hard nofile $XMG_TUNE_NOFILE
EOF
    xmg_info "nofile limits 已写入: $XMG_TUNE_LIMITS_CONF（新登录会话生效）"

    # systemd 服务不受 limits.d 影响，需单独设置 DefaultLimitNOFILE
    if xmg_cmd_exists systemctl; then
        mkdir -p "$(dirname "$XMG_TUNE_SYSTEMD_LIMITS_CONF")" 2>/dev/null || true
        cat > "$XMG_TUNE_SYSTEMD_LIMITS_CONF" 2>/dev/null <<EOF || true
# XMG: systemd DefaultLimitNOFILE（由 xmg tune 生成）
[Manager]
DefaultLimitNOFILE=$XMG_TUNE_NOFILE
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
        xmg_info "systemd DefaultLimitNOFILE=$XMG_TUNE_NOFILE（服务重启后生效）"
    fi
}

xmg_tune_net_optimize() {
    xmg_require_root

    local mem_mb=""
    local profile=""
    local conntrack_max=""
    local buf_max=""
    local backlog=""
    local syn_backlog=""
    local tw_buckets=""

    mem_mb="$(xmg_tune_mem_total_mb)"
    profile="$(xmg_tune_mem_profile "$mem_mb")"

    # 按内存分档，避免小内存机被 conntrack 表 / 突发缓冲挤爆：
    #   conntrack 每条约 300B，262144 条约 76MB，215MB 内存机不可承受
    #   缓冲区为按需分配上限，低内存机仍收敛突发峰值
    case "$profile" in
        extreme_low)
            conntrack_max=8192
            buf_max=1048576
            backlog=2048
            syn_backlog=1024
            tw_buckets=4096
            ;;
        low)
            conntrack_max=32768
            buf_max=16777216
            backlog=8192
            syn_backlog=4096
            tw_buckets=16384
            ;;
        mid)
            conntrack_max=131072
            buf_max=33554432
            backlog=16384
            syn_backlog=8192
            tw_buckets=32768
            ;;
        high|*)
            conntrack_max=262144
            buf_max=33554432
            backlog=16384
            syn_backlog=8192
            tw_buckets=32768
            ;;
    esac

    xmg_info "检测到内存: ${mem_mb}MB，调优档位: $profile"
    xmg_warn "将写入 $XMG_TUNE_SYSCTL_NET_CONF 并立即应用"
    xmg_warn "同时写入 nofile limits（PAM + systemd）"

    if ! xmg_confirm "确认执行内核网络参数优化?"; then
        xmg_info "已取消"
        return 0
    fi

    xmg_tune_backup_file "$XMG_TUNE_SYSCTL_NET_CONF" || true

    {
        echo "# XMG: 内核网络参数调优（由 xmg tune 生成）"
        echo "# 内存档位: $profile (${mem_mb}MB)"
        echo
        echo "# --- 文件描述符 ---"
        echo "fs.file-max = $XMG_TUNE_NOFILE"
        echo
        echo "# --- 连接队列与缓冲区 ---"
        echo "net.core.somaxconn = $backlog"
        echo "net.core.netdev_max_backlog = $backlog"
        echo "net.core.rmem_max = $buf_max"
        echo "net.core.wmem_max = $buf_max"
        echo "net.ipv4.tcp_rmem = 4096 87380 $buf_max"
        echo "net.ipv4.tcp_wmem = 4096 16384 $buf_max"
        if [ "$profile" = "extreme_low" ]; then
            echo "# 历史基线对照: net.core.rmem_max = 4194304 / net.core.wmem_max = 4194304"
            echo "# 历史基线对照: net.ipv4.tcp_rmem = 4096 87380 4194304 / net.ipv4.tcp_wmem = 4096 16384 4194304"
            echo "net.ipv4.tcp_mem = 3072 4096 6144"
        fi
        echo
        echo "# --- TCP 行为 ---"
        echo "net.ipv4.tcp_fastopen = 3"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        echo "net.ipv4.tcp_mtu_probing = 1"
        echo "net.ipv4.tcp_syncookies = 1"
        echo "net.ipv4.tcp_max_syn_backlog = $syn_backlog"
        echo "net.ipv4.tcp_fin_timeout = 15"
        echo "net.ipv4.tcp_tw_reuse = 1"
        echo "net.ipv4.tcp_max_tw_buckets = $tw_buckets"
        echo "net.ipv4.tcp_keepalive_time = 600"
        echo "net.ipv4.tcp_keepalive_intvl = 30"
        echo "net.ipv4.tcp_keepalive_probes = 5"
        echo
        # conntrack 参数仅在模块可用时写入，避免 sysctl 报错
        local conntrack_file="${XMG_TUNE_CONNTRACK_FILE:-/proc/sys/net/netfilter/nf_conntrack_max}"
        if [ -r "$conntrack_file" ]; then
            echo "# --- 连接跟踪 ---"
            echo "net.netfilter.nf_conntrack_max = $conntrack_max"
            echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"
            echo
        fi
        if [ -d /proc/sys/net/ipv6 ]; then
            echo "# --- IPv6 路由与网络栈保护 ---"
            echo "net.ipv6.conf.all.accept_ra = 2"
            echo "net.ipv6.conf.default.accept_ra = 2"
            echo
        fi
        local swappiness_val
        swappiness_val="$(xmg_tune_calc_swappiness "$mem_mb")"
        echo "# --- 虚拟内存 ---"
        echo "vm.swappiness = $swappiness_val"
    } > "$XMG_TUNE_SYSCTL_NET_CONF"

    # 个别 key 在容器/精简内核上不可写属正常现象：警告后继续，保证 limits 仍然落盘
    if ! xmg_tune_sysctl_apply "$XMG_TUNE_SYSCTL_NET_CONF"; then
        xmg_warn "部分内核参数写入失败（容器/精简内核常见），已跳过失败项"
    fi

    xmg_tune_write_limits

    xmg_info "内核网络参数优化完成（档位: $profile）"
    xmg_info "配置文件: $XMG_TUNE_SYSCTL_NET_CONF"
    xmg_warn "BBR + FQ 不包含在本项中，请单独执行「一键开启 BBR + FQ」"
}

# ===== DNS 优化 =====

# 单双栈拓扑感知
xmg_tune_is_ipv6_only() {
    if declare -F xmg_detect_network >/dev/null 2>&1; then
        xmg_detect_network
        if [ "${XMG_NET_IPV4:-0}" -eq 0 ] && [ "${XMG_NET_IPV6:-0}" -eq 1 ] && [ "${XMG_NET_NAT64:-0}" -eq 0 ]; then
            return 0
        fi
    fi
    return 1
}

xmg_tune_is_ipv4_only() {
    if declare -F xmg_detect_network >/dev/null 2>&1; then
        xmg_detect_network
        if [ "${XMG_NET_IPV4:-0}" -eq 1 ] && [ "${XMG_NET_IPV6:-0}" -eq 0 ]; then
            return 0
        fi
    fi
    return 1
}

xmg_tune_is_ipv6_addr() {
    case "$1" in
        *:*) return 0 ;;
        *) return 1 ;;
    esac
}

# 探测目标 IP 的特定 TCP 端口连通性（如 DoT 853）
xmg_tune_check_tcp_port() {
    local host="$1"
    local port="${2:-853}"
    local timeout_sec="${3:-2}"

    if [ -n "${MOCK_CHECK_TCP_PORT:-}" ]; then
        return "$MOCK_CHECK_TCP_PORT"
    fi

    local clean_host="${host#[}"
    clean_host="${clean_host%]}"

    if command -v timeout >/dev/null 2>&1 && [ -n "${BASH_VERSION:-}" ]; then
        if timeout "$timeout_sec" bash -c "exec 3<>/dev/tcp/$clean_host/$port" 2>/dev/null; then
            return 0
        fi
    fi
    if command -v nc >/dev/null 2>&1; then
        if [[ "$clean_host" =~ : ]]; then
            nc -6 -z -w "$timeout_sec" "$clean_host" "$port" 2>/dev/null && return 0
        fi
        nc -z -w "$timeout_sec" "$clean_host" "$port" 2>/dev/null && return 0
    fi
    return 1
}

# 校验 IP：IPv4 严格（点分四段 0-255），IPv6 宽松（hex/冒号/点，含 v4 映射尾段）
# 注意：IPv6 分支必须在前——v4 映射地址（::ffff:1.2.3.4）同时含点与冒号
xmg_tune_valid_ip() {
    local ip="$1"
    local o1="" o2="" o3="" o4=""
    local seg=""

    case "$ip" in
        *:*)
            # IPv6（宽松）：仅含 hex/冒号/点，且至少一个冒号
            case "$ip" in
                ''|*[!0-9A-Fa-f:.]*)
                    return 1
                    ;;
            esac
            return 0
            ;;
        *.*)
            # IPv4
            case "$ip" in
                *[!0-9.]*) return 1 ;;
            esac
            IFS='.' read -r o1 o2 o3 o4 <<EOF
$ip
EOF
            for seg in "$o1" "$o2" "$o3" "$o4"; do
                case "$seg" in
                    ''|*[!0-9]*)
                        return 1
                        ;;
                esac
                if [ "$seg" -gt 255 ]; then
                    return 1
                fi
            done
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 输出 "主DNS 备DNS"，取消或无效时返回非零
# 交互 UI 必须走 stderr：调用方以命令替换捕获 stdout，UI 混入 stdout 会污染返回值
xmg_tune_dns_pick() {
    local choice=""
    local p1=""
    local p2=""
    local is_v6_only=0

    if xmg_tune_is_ipv6_only; then
        is_v6_only=1
    fi

    {
        echo
        echo "请选择 DNS 预设:"
        echo "  1. Cloudflare   (1.1.1.1 / 1.0.0.1)            [境外推荐·默认]"
        echo "  2. Google       (8.8.8.8 / 8.8.4.4)"
        echo "  3. Quad9        (9.9.9.9 / 149.112.112.112)"
        echo "  4. 阿里 DNS     (223.5.5.5 / 223.6.6.6)        [境内推荐·海外服务器延迟较高]"
        echo "  5. Cloudflare IPv6 (2606:4700:4700::1111 / ::1001)  [纯 IPv6 机·推荐]"
        echo "  6. Google IPv6  (2001:4860:4860::8888 / ::8844)     [纯 IPv6 机]"
        echo "  7. 公共 DNS64   (2a01:4f8:c2c:123f::1 / 2a00:1098:2b::1) [纯 IPv6 无 WARP 推荐·支持解析 GitHub 等纯 v4 站]"
        echo "  8. 自定义 (支持 IPv4 / IPv6 / 混合双栈)"
        if [ "$is_v6_only" -eq 1 ]; then
            echo "  [提示: 纯 IPv6 VPS 访问 GitHub 等无 IPv6 网站，未开启 WARP 时建议选择 7 (DNS64)；开启 WARP 后可任选 5/6]"
        fi
        printf "请选择 [1]: "
    } >&2
    read -r choice || return 1
    # 空输入归一为默认
    if [ -z "$choice" ]; then
        if [ "$is_v6_only" -eq 1 ]; then
            printf '2606:4700:4700::1111 2606:4700:4700::1001\n'
            return 0
        fi
        choice="1"
    fi

    case "$choice" in
        1) printf '%s\n' "$XMG_TUNE_DNS_DEFAULT" ;;
        2) printf '8.8.8.8 8.8.4.4\n' ;;
        3) printf '9.9.9.9 149.112.112.112\n' ;;
        4) printf '223.5.5.5 223.6.6.6\n' ;;
        5) printf '2606:4700:4700::1111 2606:4700:4700::1001\n' ;;
        6) printf '2001:4860:4860::8888 2001:4860:4860::8844\n' ;;
        7) printf '2a01:4f8:c2c:123f::1 2a00:1098:2b::1\n' ;;
        8)
            printf "主 DNS: " >&2
            read -r p1 || return 1
            printf "备 DNS: " >&2
            read -r p2 || return 1

            if ! xmg_tune_valid_ip "$p1"; then
                xmg_warn "IP 格式无效: $p1"
                return 1
            fi
            if ! xmg_tune_valid_ip "$p2"; then
                xmg_warn "IP 格式无效: $p2"
                return 1
            fi

            printf '%s %s\n' "$p1" "$p2"
            ;;
        *)
            xmg_warn "无效选择"
            return 1
            ;;
    esac
}

# /etc/resolv.conf 是否由 systemd-resolved 管理（软链接指向其文件）
xmg_tune_is_resolved_managed() {
    [ -L /etc/resolv.conf ] || return 1

    case "$(readlink /etc/resolv.conf)" in
        *systemd*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

xmg_tune_dns_apply_resolved() {
    local dns1="$1"
    local dns2="$2"
    local fallback=""

    if xmg_tune_is_ipv6_only; then
        fallback="2606:4700:4700::1111 2001:4860:4860::8888"
    else
        fallback="1.1.1.1 2606:4700:4700::1111 8.8.8.8 2001:4860:4860::8888"
    fi

    mkdir -p "$(dirname "$XMG_TUNE_RESOLVED_CONF")"
    xmg_tune_backup_file "$XMG_TUNE_RESOLVED_CONF" || true

    cat > "$XMG_TUNE_RESOLVED_CONF" <<EOF
# XMG: DNS 优化（由 xmg tune 生成）
[Resolve]
DNS=$dns1 $dns2
FallbackDNS=$fallback
EOF

    systemctl restart systemd-resolved 2>/dev/null || xmg_warn "systemd-resolved 重启失败"

    xmg_info "DNS 已写入 resolved drop-in: $XMG_TUNE_RESOLVED_CONF"

    if xmg_cmd_exists resolvectl; then
        sleep 1
        resolvectl status 2>/dev/null | sed -n '1,12p' || true
    fi
}

xmg_tune_dns_apply_resolvconf() {
    local dns1="$1"
    local dns2="$2"

    xmg_tune_backup_file /etc/resolv.conf || true

    # resolv.conf 若为软链接则替换为真实文件，避免写入链接目标
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi

    cat > /etc/resolv.conf <<EOF
# XMG: DNS 优化（由 xmg tune 生成）
nameserver $dns1
nameserver $dns2
options timeout:2 attempts:2
EOF
    chmod 644 /etc/resolv.conf

    xmg_info "DNS 已写入 /etc/resolv.conf"
}

xmg_tune_dns_optimize() {
    xmg_require_root

    local dns_pair=""
    local dns1=""
    local dns2=""

    dns_pair="$(xmg_tune_dns_pick)" || {
        xmg_info "已取消"
        return 0
    }

    # shellcheck disable=SC2086
    set -- $dns_pair
    dns1="$1"
    dns2="$2"

    if ! xmg_tune_valid_ip "$dns1" || ! xmg_tune_valid_ip "$dns2"; then
        xmg_error "DNS 结果无效: '$dns1' / '$dns2'，未做任何变更"
        return 0
    fi

    # 关键防呆拦截：纯单栈环境下防止配置反向单栈 DNS 导致断网
    if xmg_tune_is_ipv6_only; then
        if ! xmg_tune_is_ipv6_addr "$dns1" && ! xmg_tune_is_ipv6_addr "$dns2"; then
            xmg_error "安全拦截: 检测到当前主机为纯 IPv6 环境（无 IPv4 路由且不支持 NAT64）"
            xmg_warn "所选 DNS ($dns1 / $dns2) 均为 IPv4 地址，写入后将导致系统立即失去所有域名解析能力而断网！"
            xmg_info "请选择 IPv6 DNS (如 2606:4700:4700::1111) 或通过 xmg warp 开启 WARP IPv4 出口"
            return 1
        fi
    elif xmg_tune_is_ipv4_only; then
        if xmg_tune_is_ipv6_addr "$dns1" && xmg_tune_is_ipv6_addr "$dns2"; then
            xmg_error "安全拦截: 检测到当前主机为纯 IPv4 环境（无 IPv6 路由）"
            xmg_warn "所选 DNS 均为 IPv6 地址，无法通信！"
            return 1
        fi
    fi

    echo
    echo "将使用 DNS: $dns1 / $dns2"

    if ! xmg_confirm "确认应用?"; then
        xmg_info "已取消"
        return 0
    fi

    # 保存安全回滚快照
    local snapshot_resolv="/tmp/xmg-resolv-snap.$$.bak"
    local snapshot_resolved="/tmp/xmg-resolved-snap.$$.bak"
    local had_resolved_conf=0
    [ -e /etc/resolv.conf ] && cp -a /etc/resolv.conf "$snapshot_resolv" 2>/dev/null || true
    if [ -f "$XMG_TUNE_RESOLVED_CONF" ]; then
        cp -a "$XMG_TUNE_RESOLVED_CONF" "$snapshot_resolved" 2>/dev/null || true
        had_resolved_conf=1
    fi

    local is_resolved=0
    if xmg_tune_is_resolved_managed; then
        is_resolved=1
        xmg_tune_dns_apply_resolved "$dns1" "$dns2"
    else
        xmg_tune_dns_apply_resolvconf "$dns1" "$dns2"
    fi

    # 连通性验证与自动回滚
    xmg_info "正在验证 DNS 解析连通性..."
    if ! xmg_tune_dns_verify; then
        xmg_error "DNS 解析验证失败！新配置在此网络环境下不可达"
        xmg_warn "正在自动执行安全回滚以恢复原有配置，防止断网..."
        if [ "$is_resolved" -eq 1 ]; then
            if [ "$had_resolved_conf" -eq 1 ]; then
                cp -a "$snapshot_resolved" "$XMG_TUNE_RESOLVED_CONF" 2>/dev/null || true
            else
                rm -f "$XMG_TUNE_RESOLVED_CONF"
            fi
            systemctl restart systemd-resolved 2>/dev/null || true
        fi
        if [ -e "$snapshot_resolv" ]; then
            rm -f /etc/resolv.conf
            cp -a "$snapshot_resolv" /etc/resolv.conf 2>/dev/null || true
        fi
        rm -f "$snapshot_resolv" "$snapshot_resolved"
        xmg_info "已完成安全回滚，已恢复原网络配置"
        return 1
    fi

    rm -f "$snapshot_resolv" "$snapshot_resolved"
    xmg_info "DNS 优化应用成功，解析验证通过"
}

# ===== 加密 DNS (DoT) =====

# systemd >= 243 才支持 DNSOverTLS
xmg_tune_dot_supported() {
    local v=""
    v="$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')"

    case "$v" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$v" -ge 243 ]
}

# 输出 DoT 上游 "主 备"，取消时返回非零
# opportunistic 模式不校验证书，纯 IP 即可（IP#证书名 语法需 systemd 246+）
# 交互 UI 必须走 stderr，理由同 xmg_tune_dns_pick
xmg_tune_dot_pick() {
    local choice=""
    local p1=""
    local p2=""
    local is_v6_only=0

    if xmg_tune_is_ipv6_only; then
        is_v6_only=1
    fi

    {
        echo
        echo "请选择 DoT 上游 (DNSOverTLS=opportunistic，失败自动回退明文):"
        echo "  1. Cloudflare   (1.1.1.1 / 1.0.0.1)            [境外推荐·默认]"
        echo "  2. Google       (8.8.8.8 / 8.8.4.4)"
        echo "  3. Quad9        (9.9.9.9 / 149.112.112.112)"
        echo "  4. 阿里 DNS     (223.5.5.5 / 223.6.6.6)        [境内推荐·海外服务器延迟较高]"
        echo "  5. Cloudflare IPv6 (2606:4700:4700::1111 / ::1001)  [纯 IPv6 机·推荐]"
        echo "  6. 自定义 (支持 IPv4 / IPv6)"
        if [ "$is_v6_only" -eq 1 ]; then
            echo "  [提示: 检测到当前主机为纯 IPv6 环境，默认/推荐选择 5]"
        fi
        printf "请选择 [1]: "
    } >&2
    read -r choice || return 1
    # 空输入归一为默认
    if [ -z "$choice" ]; then
        if [ "$is_v6_only" -eq 1 ]; then
            printf '2606:4700:4700::1111 2606:4700:4700::1001\n'
            return 0
        fi
        choice="1"
    fi

    case "$choice" in
        1) printf '%s\n' "$XMG_TUNE_DOT_DEFAULT" ;;
        2) printf '8.8.8.8 8.8.4.4\n' ;;
        3) printf '9.9.9.9 149.112.112.112\n' ;;
        4) printf '223.5.5.5 223.6.6.6\n' ;;
        5) printf '2606:4700:4700::1111 2606:4700:4700::1001\n' ;;
        6)
            printf "主 DoT 上游 IP: " >&2
            read -r p1 || return 1
            printf "备 DoT 上游 IP: " >&2
            read -r p2 || return 1

            if ! xmg_tune_valid_ip "$p1"; then
                xmg_warn "IP 格式无效: $p1"
                return 1
            fi
            if ! xmg_tune_valid_ip "$p2"; then
                xmg_warn "IP 格式无效: $p2"
                return 1
            fi

            printf '%s %s\n' "$p1" "$p2"
            ;;
        *)
            xmg_warn "无效选择"
            return 1
            ;;
    esac
}

# 解析链路验证：失败返回非零
xmg_tune_dns_verify() {
    if command -v timeout >/dev/null 2>&1; then
        if timeout 3 getent hosts deb.debian.org >/dev/null 2>&1; then
            return 0
        fi
        if timeout 3 getent hosts cloudflare.com >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi

    if getent hosts deb.debian.org >/dev/null 2>&1; then
        return 0
    fi
    if getent hosts cloudflare.com >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# systemd-resolved 服务单元是否存在（Debian 12 精简模板常缺此包）
xmg_tune_resolved_unit_exists() {
    systemctl list-unit-files --type=service 2>/dev/null \
        | grep -q '^systemd-resolved\.service'
}

# resolved 未运行时的启用迁移（带回退）：
# 备份 resolv.conf -> 启用 resolved -> 切 stub 软链 -> 验证解析，失败整体回滚
xmg_tune_dns_enable_resolved() {
    local dns1="${1:-}"
    local dns2="${2:-}"
    local resolv_backup="/tmp/xmg-resolv-backup.$(xmg_timestamp)"

    xmg_warn "systemd-resolved 未运行，将启用它并接管 /etc/resolv.conf"
    if ! xmg_confirm "确认继续? (失败会自动回滚)"; then
        return 1
    fi

    # 前置诊断 1：unit 缺失（Debian 12 精简模板未装该包）-> 尝试安装
    if ! xmg_tune_resolved_unit_exists; then
        xmg_warn "systemd-resolved 服务单元不存在（系统未安装该组件）"
        if xmg_cmd_exists apt-get; then
            if xmg_confirm "是否安装 systemd-resolved?"; then
                export DEBIAN_FRONTEND=noninteractive
                if ! apt-get -o DPkg::Lock::Timeout=60 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y systemd-resolved; then
                    xmg_error "安装失败，可先执行 apt-get update 后重试"
                    xmg_info "或改用「一键 DNS 优化 (UDP)」，无需 resolved"
                    return 1
                fi
            else
                xmg_info "已取消。可改用「一键 DNS 优化 (UDP)」，无需 resolved"
                return 1
            fi
        else
            xmg_error "非 apt 系统，请手动安装 systemd-resolved 后重试"
            return 1
        fi
    fi

    # 前置诊断 2：被 mask（部分"优化脚本"会禁用它）
    if [ "$(systemctl is-enabled systemd-resolved 2>/dev/null)" = "masked" ]; then
        xmg_warn "systemd-resolved 处于 masked 状态，尝试解除"
        systemctl unmask systemd-resolved >/dev/null 2>&1 || true
    fi

    cp -a /etc/resolv.conf "$resolv_backup" 2>/dev/null || true

    # 关键防空载: 启动 systemd-resolved 之前预置目标 DNS 上游，避免空载误判回滚
    if [ -n "$dns1" ]; then
        mkdir -p "$(dirname "$XMG_TUNE_RESOLVED_CONF")"
        local fallback=""
        if xmg_tune_is_ipv6_only; then
            fallback="2606:4700:4700::1111 2001:4860:4860::8888"
        else
            fallback="1.1.1.1 2606:4700:4700::1111 8.8.8.8 2001:4860:4860::8888"
        fi
        cat > "$XMG_TUNE_RESOLVED_CONF" <<EOF
# XMG: DNS 预载配置（由 xmg tune 生成）
[Resolve]
DNS=$dns1 ${dns2:-}
FallbackDNS=$fallback
DNSOverTLS=opportunistic
EOF
    fi

    if ! systemctl enable systemd-resolved >/dev/null 2>&1; then
        xmg_error "systemd-resolved enable 失败"
        rm -f "$resolv_backup"
        return 1
    fi

    if ! systemctl start systemd-resolved >/dev/null 2>&1; then
        xmg_error "systemd-resolved 启动失败，最近日志:"
        journalctl -u systemd-resolved -n 10 --no-pager 2>/dev/null || true
        systemctl disable systemd-resolved >/dev/null 2>&1 || true
        rm -f "$resolv_backup"
        return 1
    fi

    # 切换 resolv.conf 到 resolved stub
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    if ! xmg_tune_dns_verify; then
        xmg_error "切换后解析失败，回滚"
        rm -f /etc/resolv.conf
        cp -a "$resolv_backup" /etc/resolv.conf 2>/dev/null || true
        systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
        xmg_info "已恢复原 /etc/resolv.conf 并停用 systemd-resolved"
        return 1
    fi

    rm -f "$resolv_backup"
    xmg_info "systemd-resolved 已启用，解析验证通过"
    return 0
}

xmg_tune_dns_dot_apply() {
    local dns1="$1"
    local dns2="$2"
    local fallback=""

    if xmg_tune_is_ipv6_only; then
        fallback="2606:4700:4700::1111 2001:4860:4860::8888"
    else
        fallback="1.1.1.1 2606:4700:4700::1111 8.8.8.8 2001:4860:4860::8888"
    fi

    local snapshot_dropin="/tmp/xmg-dot-dropin.$$.bak"
    local had_prior=0
    if [ -f "$XMG_TUNE_RESOLVED_CONF" ]; then
        cp -a "$XMG_TUNE_RESOLVED_CONF" "$snapshot_dropin" 2>/dev/null || true
        had_prior=1
    fi

    mkdir -p "$(dirname "$XMG_TUNE_RESOLVED_CONF")"
    xmg_tune_backup_file "$XMG_TUNE_RESOLVED_CONF" || true

    cat > "$XMG_TUNE_RESOLVED_CONF" <<EOF
# XMG: 加密 DNS DoT（由 xmg tune 生成）
[Resolve]
DNS=$dns1 $dns2
FallbackDNS=$fallback
# opportunistic: DoT(853) 不通时自动回退明文 53，不会断网
DNSOverTLS=opportunistic
EOF

    systemctl restart systemd-resolved 2>/dev/null || {
        xmg_error "systemd-resolved 重启失败"
        return 1
    }

    if ! xmg_tune_dns_verify; then
        xmg_error "DoT 配置后解析验证失败（853 端口受阻或解析无响应）！"
        xmg_warn "正在自动回滚 DoT 配置以恢复网络..."
        if [ "$had_prior" -eq 1 ]; then
            cp -a "$snapshot_dropin" "$XMG_TUNE_RESOLVED_CONF" 2>/dev/null || true
        else
            rm -f "$XMG_TUNE_RESOLVED_CONF"
        fi
        systemctl restart systemd-resolved 2>/dev/null || true
        rm -f "$snapshot_dropin"
        xmg_info "已自动撤销 DoT 配置，网络已恢复"
        return 1
    fi

    rm -f "$snapshot_dropin"
    xmg_info "DoT 已启用: DNSOverTLS=opportunistic（带回退）"
    xmg_info "配置文件: $XMG_TUNE_RESOLVED_CONF"
    resolvectl status 2>/dev/null | sed -n '1,12p' || true
}

xmg_tune_dns_dot() {
    xmg_require_root

    if ! xmg_cmd_exists systemctl; then
        xmg_die "需要 systemd 环境"
    fi

    if ! xmg_tune_dot_supported; then
        xmg_error "systemd 版本过低（$(systemctl --version 2>/dev/null | head -1)），DoT 需要 >= 243"
        return 1
    fi

    local dns_pair=""
    local dns1=""
    local dns2=""

    dns_pair="$(xmg_tune_dot_pick)" || {
        xmg_info "已取消"
        return 0
    }

    # shellcheck disable=SC2086
    set -- $dns_pair
    dns1="$1"
    dns2="$2"

    if ! xmg_tune_valid_ip "$dns1" || ! xmg_tune_valid_ip "$dns2"; then
        xmg_error "DoT 上游无效: '$dns1' / '$dns2'，未做任何变更"
        return 0
    fi

    # 关键防呆拦截：纯单栈环境防止配置反向单栈 DoT
    if xmg_tune_is_ipv6_only; then
        if ! xmg_tune_is_ipv6_addr "$dns1" && ! xmg_tune_is_ipv6_addr "$dns2"; then
            xmg_error "安全拦截: 检测到当前主机为纯 IPv6 环境（无 IPv4 路由且不支持 NAT64）"
            xmg_warn "所选 DoT 上游 ($dns1 / $dns2) 均为 IPv4 地址，无法建立 TLS 握手！"
            xmg_info "建议选择 IPv6 节点 (如 2606:4700:4700::1111)"
            return 1
        fi
    elif xmg_tune_is_ipv4_only; then
        if xmg_tune_is_ipv6_addr "$dns1" && xmg_tune_is_ipv6_addr "$dns2"; then
            xmg_error "安全拦截: 检测到当前主机为纯 IPv4 环境（无 IPv6 路由）"
            xmg_warn "所选 DoT 上游均为 IPv6 地址，无法建立连接！"
            return 1
        fi
    fi

    # 853 端口握手连通性预检
    if ! xmg_tune_check_tcp_port "$dns1" 853 2; then
        xmg_warn "预检提示: 目标 DoT 上游 ($dns1) 端口 853 无法连通"
        xmg_warn "可能原因: VPS 所在云厂商安全组或运营商阻断了 TCP 853 端口"
        xmg_warn "若强制开启，DNSOverTLS 可能会经历握手超时，导致网络查询卡顿"
        if ! xmg_confirm "是否仍要继续尝试开启 DoT? (建议改用普通 UDP 模式)"; then
            xmg_info "已取消。可使用「一键 DNS 优化 (UDP)」模式"
            return 0
        fi
    fi

    echo
    echo "将启用 DoT (opportunistic): $dns1 / $dns2"

    if ! xmg_confirm "确认应用?"; then
        xmg_info "已取消"
        return 0
    fi

    # resolved 未运行时先迁移启用（内置回滚）
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if ! xmg_tune_dns_enable_resolved "$dns1" "$dns2"; then
            return 1
        fi
    fi

    xmg_tune_dns_dot_apply "$dns1" "$dns2" || true
}

# ===== 时间同步 =====

# 自动探测 VPS 当前出口 IP 的当地自然时区
xmg_tune_detect_ip_timezone() {
    local tz=""
    tz="$(curl -sSL --connect-timeout 3 --max-time 5 "http://ip-api.com/line?fields=timezone" 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$tz" ] && [[ "$tz" =~ ^[A-Za-z_]+/[A-Za-z_]+ ]]; then
        echo "$tz"
        return 0
    fi
    tz="$(curl -sSL --connect-timeout 3 --max-time 5 "https://ipapi.co/timezone" 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$tz" ] && [[ "$tz" =~ ^[A-Za-z_]+/[A-Za-z_]+ ]]; then
        echo "$tz"
        return 0
    fi
    echo ""
}

xmg_tune_time_sync() {
    xmg_require_root

    if ! xmg_cmd_exists timedatectl; then
        xmg_die "未检测到 timedatectl，需要 systemd 环境"
    fi

    local current_tz=""
    current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
    echo "当前系统时区: $current_tz"

    xmg_info "正在探测 VPS 所在公网 IP 的地理时区..."
    local detected_tz=""
    detected_tz="$(xmg_tune_detect_ip_timezone)"

    if [ -n "$detected_tz" ]; then
        xmg_info "探测到 VPS 出口 IP 所在地时区: $detected_tz"
    fi

    echo
    echo "请选择时区配置方式:"
    if [ -n "$detected_tz" ]; then
        echo "  1. 设置为 VPS 所在地时区 ($detected_tz) [推荐]"
    else
        echo "  1. 设置为 UTC 协调世界时 (国际标准)"
    fi
    echo "  2. 设置为 UTC 协调世界时 (国际标准)"
    echo "  3. 设置为北京时间 (Asia/Shanghai, UTC+8)"
    echo "  4. 自定义时区 (如 America/New_York, Asia/Tokyo 等)"
    echo "  0. 保持当前时区不变"
    printf "请选择 [1]: "

    local choice=""
    read -r choice || return 0
    [ -z "$choice" ] && choice="1"

    local new_tz=""
    case "$choice" in
        1)
            if [ -n "$detected_tz" ]; then
                new_tz="$detected_tz"
            else
                new_tz="UTC"
            fi
            ;;
        2)
            new_tz="UTC"
            ;;
        3)
            new_tz="Asia/Shanghai"
            ;;
        4)
            printf "请输入目标时区名称: "
            read -r new_tz || return 0
            ;;
        0)
            xmg_info "保持时区不变"
            ;;
        *)
            xmg_warn "无效选择"
            return 1
            ;;
    esac

    if [ -n "$new_tz" ]; then
        if timedatectl set-timezone "$new_tz" 2>/dev/null; then
            xmg_info "VPS 时区已成功更新为: $new_tz"
        else
            xmg_error "设置时区失败: $new_tz"
        fi
    fi

    # 同步服务：chrony 优先，其次 systemd-timesyncd
    local svc=""
    if xmg_cmd_exists chronyc; then
        if systemctl list-unit-files 2>/dev/null | grep -q '^chronyd\.service'; then
            svc="chronyd"
        else
            svc="chrony"
        fi
    elif systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then
        svc="systemd-timesyncd"
    else
        xmg_warn "未检测到 chrony / systemd-timesyncd"
        xmg_warn "可手动安装: apt install chrony 或 dnf install chrony"
        return 1
    fi

    xmg_info "启用时间同步服务: $svc"
    systemctl enable --now "$svc" >/dev/null 2>&1 || xmg_warn "启用 $svc 失败"
    timedatectl set-ntp true >/dev/null 2>&1 || true

    echo
    timedatectl status || true
}

# ===== Swap 管理 =====

xmg_tune_swap_to_mb() {
    local size="$1"
    local num="${size%[GgMm]}"
    local unit="${size: -1}"

    case "$num" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    case "$unit" in
        G|g) echo $((num * 1024)) ;;
        M|m) echo "$num" ;;
        *) return 1 ;;
    esac
}

xmg_tune_swap_show() {
    echo "== swap 设备 =="
    swapon --show 2>/dev/null || echo "(无)"
    echo
    echo "== 内存 =="
    free -h 2>/dev/null || true
    echo
    echo "vm.swappiness = $(cat /proc/sys/vm/swappiness 2>/dev/null || echo unknown)"
}

# 获取目标路径所在挂载点的可用空间（MB）
xmg_tune_disk_avail_mb() {
    local target="${1:-/}"

    if [ -n "${XMG_MOCK_DISK_AVAIL_MB:-}" ]; then
        echo "$XMG_MOCK_DISK_AVAIL_MB"
        return 0
    fi

    local dir="$target"
    while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
        dir="$(dirname "$dir")"
    done
    [ -d "$dir" ] || dir="/"

    local avail=""
    avail="$(df -m -P "$dir" 2>/dev/null | awk 'NR==2 {print $4}')"
    case "$avail" in
        ''|*[!0-9]*)
            echo 999999
            return 0
            ;;
    esac
    echo "$avail"
}

# 预检并计算安全 Swap 尺寸（MB）
# 若可用空间不足 1200MB，自动将 Swap 尺寸收缩（如 256MB）或提示跳过，杜绝磁盘打满
# 探测路径所在文件系统类型
xmg_tune_fs_type() {
    local target="${1:-$XMG_TUNE_SWAPFILE}"
    local target_dir
    target_dir="$(dirname "$target")"
    local fstype=""
    if command -v stat >/dev/null 2>&1; then
        fstype="$(stat -f -c %T "$target_dir" 2>/dev/null || true)"
    fi
    if [ -z "$fstype" ] && command -v df >/dev/null 2>&1; then
        fstype="$(df -T "$target_dir" 2>/dev/null | awk 'NR>1 {print $2; exit}' || true)"
    fi
    printf '%s' "$fstype"
}

xmg_tune_swap_calc_size() {
    local req_mb="$1"
    local target_file="${2:-$XMG_TUNE_SWAPFILE}"
    local avail_mb=""

    avail_mb="$(xmg_tune_disk_avail_mb "$target_file")"

    # 可用空间不足 1200MB
    if [ "$avail_mb" -lt 1200 ]; then
        if [ "$avail_mb" -le 300 ]; then
            xmg_warn "磁盘可用空间不足 300MB (剩余 ${avail_mb}MB)，跳过创建 Swap 以免打满磁盘"
            return 1
        fi
        if [ "$req_mb" -gt 256 ]; then
            xmg_warn "磁盘可用空间不足 1200MB (剩余 ${avail_mb}MB)，自动将 Swap 尺寸收缩为 256MB"
            echo 256
            return 0
        fi
    fi

    # 可用空间充足但请求值接近/超过剩余空间（至少预留 512MB 缓冲）
    if [ "$req_mb" -ge "$((avail_mb - 512))" ]; then
        local safe_mb=$((avail_mb - 512))
        if [ "$safe_mb" -le 0 ]; then
            xmg_warn "磁盘剩余空间不足 (${avail_mb}MB)，跳过创建 Swap"
            return 1
        fi
        xmg_warn "磁盘空间紧张，自动将 Swap 尺寸收缩为 ${safe_mb}MB"
        echo "$safe_mb"
        return 0
    fi

    echo "$req_mb"
    return 0
}

xmg_tune_swap_create() {
    xmg_require_root

    local size=""
    local mb=0
    local mem_mb=""

    if [ -e "$XMG_TUNE_SWAPFILE" ]; then
        xmg_warn "$XMG_TUNE_SWAPFILE 已存在，如需重建请先删除"
        return 1
    fi

    mem_mb="$(xmg_tune_mem_total_mb)"
    if [ "$mem_mb" -le 512 ]; then
        xmg_info "当前内存 ${mem_mb}MB，建议 Swap 1G 左右"
    fi

    printf "请输入 Swap 大小，例如 1G / 2G / 512M: "
    read -r size || return 1

    mb="$(xmg_tune_swap_to_mb "$size")" || {
        xmg_warn "大小格式无效，示例: 1G、2G、512M"
        return 1
    }

    if [ "$mb" -gt 8192 ]; then
        xmg_warn "Swap 过大（>8G），低配 VPS 不建议"
        return 1
    fi

    # 磁盘空间预检与自动收缩
    local final_mb=""
    final_mb="$(xmg_tune_swap_calc_size "$mb" "$XMG_TUNE_SWAPFILE")" || {
        xmg_info "已跳过 Swap 创建"
        return 0
    }
    mb="$final_mb"

    xmg_tune_backup_file /etc/fstab || true

    xmg_info "创建 ${mb}MB Swap: $XMG_TUNE_SWAPFILE"

    # 在 Btrfs 文件系统创建 Swap 前先执行 chattr +C 禁用 COW
    local fs_type
    fs_type="$(xmg_tune_fs_type "$XMG_TUNE_SWAPFILE")"
    if [ "$fs_type" = "btrfs" ]; then
        touch "$XMG_TUNE_SWAPFILE"
        if command -v chattr >/dev/null 2>&1; then
            chattr +C "$XMG_TUNE_SWAPFILE" 2>/dev/null || true
        fi
    fi

    # dd 而非 fallocate：fallocate 产生的文件可能含 hole，swapon 会拒绝
    dd if=/dev/zero of="$XMG_TUNE_SWAPFILE" bs=1M count="$mb" status=none \
        || {
            rm -f "$XMG_TUNE_SWAPFILE"
            xmg_warn "写入 swapfile 失败（磁盘空间不足）"
            return 1
        }

    chmod 600 "$XMG_TUNE_SWAPFILE"
    mkswap "$XMG_TUNE_SWAPFILE" >/dev/null || {
        rm -f "$XMG_TUNE_SWAPFILE"
        xmg_warn "mkswap 失败"
        return 1
    }

    if ! swapon "$XMG_TUNE_SWAPFILE" 2>/dev/null; then
        rm -f "$XMG_TUNE_SWAPFILE"
        xmg_warn "当前容器环境受宿主机限制无法启用独立 Swap"
        return 0
    fi

    if ! grep -q "^$XMG_TUNE_SWAPFILE " /etc/fstab; then
        printf '%s none swap sw 0 0\n' "$XMG_TUNE_SWAPFILE" >> /etc/fstab
    fi

    local swap_swappiness
    swap_swappiness="$(xmg_tune_calc_swappiness "$mem_mb" "$mb")"
    cat > "$XMG_TUNE_SYSCTL_SWAP_CONF" <<EOF
# XMG: Swap 参数（由 xmg tune 生成）
vm.swappiness = $swap_swappiness
EOF
    xmg_tune_sysctl_apply "$XMG_TUNE_SYSCTL_SWAP_CONF"

    xmg_info "Swap 创建完成（已持久化到 /etc/fstab）"
    swapon --show
}

xmg_tune_swap_remove() {
    xmg_require_root

    if [ ! -e "$XMG_TUNE_SWAPFILE" ]; then
        xmg_warn "$XMG_TUNE_SWAPFILE 不存在"
        return 1
    fi

    if ! xmg_confirm "确认删除 Swap ($XMG_TUNE_SWAPFILE)?"; then
        xmg_info "已取消"
        return 0
    fi

    swapoff "$XMG_TUNE_SWAPFILE" 2>/dev/null || true
    sed -i '\|^'"$XMG_TUNE_SWAPFILE"' |d' /etc/fstab
    rm -f "$XMG_TUNE_SWAPFILE" && xmg_info "Swap 已删除"
    rm -f "$XMG_TUNE_SYSCTL_SWAP_CONF"
}

xmg_tune_swap_panel() {
    local choice=""

    while true; do
        clear
        echo "========== Swap 管理 =========="
        echo "1. 查看当前 Swap"
        echo "2. 创建 Swap"
        echo "3. 删除 Swap"
        echo "0. 返回"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                clear
                xmg_tune_swap_show
                xmg_pause
                ;;
            2)
                clear
                xmg_tune_swap_create || true
                xmg_pause
                ;;
            3)
                xmg_tune_swap_remove || true
                xmg_pause
                ;;
            0)
                return 0
                ;;
            *)
                xmg_warn "无效选择"
                xmg_pause
                ;;
        esac
    done
}

# ===== 状态查看 =====

xmg_tune_status() {
    local mem_mb=""
    local profile=""

    mem_mb="$(xmg_tune_mem_total_mb)"
    profile="$(xmg_tune_mem_profile "$mem_mb")"

    echo "===== 主机档位 ====="
    printf '内存       : %sMB（调优档位: %s）\n' "$mem_mb" "$profile"
    echo

    echo "===== 拥塞控制 / 队列 ====="
    printf '拥塞控制 : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    printf '默认队列 : %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    printf '可用算法 : %s\n' "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo unknown)"
    echo

    echo "===== 关键内核参数 ====="
    printf 'fs.file-max                : %s\n' "$(sysctl -n fs.file-max 2>/dev/null || echo unknown)"
    printf 'net.core.somaxconn         : %s\n' "$(sysctl -n net.core.somaxconn 2>/dev/null || echo unknown)"
    printf 'net.ipv4.tcp_fastopen      : %s\n' "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo unknown)"
    printf 'net.ipv4.tcp_congestion_control : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    printf 'vm.swappiness              : %s\n' "$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
    echo

    echo "===== 文件描述符 ====="
    printf '当前 shell nofile : %s\n' "$(ulimit -n 2>/dev/null || echo unknown)"
    if [ -f "$XMG_TUNE_LIMITS_CONF" ]; then
        printf 'limits 配置       : %s\n' "$XMG_TUNE_LIMITS_CONF"
    else
        printf 'limits 配置       : 未配置\n'
    fi
    echo

    echo "===== DNS ====="
    if xmg_tune_is_resolved_managed; then
        echo "管理模式: systemd-resolved"
        if [ -f "$XMG_TUNE_RESOLVED_CONF" ]; then
            echo "XMG drop-in: $XMG_TUNE_RESOLVED_CONF"
            grep -E 'DNSOverTLS|^DNS=' "$XMG_TUNE_RESOLVED_CONF" || true
        fi
    else
        echo "管理模式: /etc/resolv.conf"
    fi
    grep -v '^#' /etc/resolv.conf 2>/dev/null | grep -v '^$' || true
    echo

    echo "===== 时间同步 ====="
    if xmg_cmd_exists timedatectl; then
        timedatectl 2>/dev/null | sed -n '1,6p' || true
    else
        echo "timedatectl 不可用"
    fi
    echo

    echo "===== Swap ====="
    swapon --show 2>/dev/null || echo "(无 swap)"
}

# ===== 菜单 =====

xmg_tune_menu() {
    local choice=""

    while true; do
        clear
        echo "========== 系统调优 =========="
        echo "1. 一键开启 BBR + FQ"
        echo "2. 一键内核网络参数优化"
        echo "3. 一键 DNS 优化 (UDP)"
        echo "4. 一键加密 DNS (DoT, 带回退)"
        echo "5. 时间同步配置"
        echo "6. Swap 管理"
        echo "7. 查看当前调优状态"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - BBR+FQ 需要内核 4.9+，脚本会自动检测"
        echo "  - 网络参数优化按内存自动分档，含 nofile limits"
        echo "  - DoT 需要 systemd >= 243，opportunistic 模式失败自动回退明文"
        echo "  - 所有被覆盖的配置会备份到: $XMG_BACKUP_DIR/tune/"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                clear
                # 动作失败不退出菜单：set -e 下裸调用非零返回会终止整个 xmg
                xmg_tune_bbr_enable || true
                xmg_pause
                ;;
            2)
                clear
                xmg_tune_net_optimize || true
                xmg_pause
                ;;
            3)
                clear
                xmg_tune_dns_optimize || true
                xmg_pause
                ;;
            4)
                clear
                xmg_tune_dns_dot || true
                xmg_pause
                ;;
            5)
                clear
                xmg_tune_time_sync || true
                xmg_pause
                ;;
            6)
                xmg_tune_swap_panel
                ;;
            7)
                clear
                xmg_tune_status
                xmg_pause
                ;;
            0)
                return 0
                ;;
            *)
                xmg_warn "无效选择"
                xmg_pause
                ;;
        esac
    done
}

# ===== 直接执行支持 =====
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    xmg_tune_menu
fi
