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

# XMG_MENU_LABEL: 系统调优

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

# DNS 默认预设（境外优先：本面板多部署于海外服务器，阿里 DNS 直连延迟高）
XMG_TUNE_DNS_DEFAULT="${XMG_TUNE_DNS_DEFAULT:-1.1.1.1 1.0.0.1}"
XMG_TUNE_DOT_DEFAULT="${XMG_TUNE_DOT_DEFAULT:-1.1.1.1 1.0.0.1}"
export XMG_TUNE_DNS_DEFAULT XMG_TUNE_DOT_DEFAULT

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
    done < /proc/meminfo 2>/dev/null

    echo 512
}

# 按内存返回调优档位：low (<=512MB) / mid (<=2048MB) / high
xmg_tune_mem_profile() {
    local mem_mb="$1"

    if [ "$mem_mb" -le 512 ]; then
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
# 个别内核参数（如 conntrack）在模块未加载时不存在，属正常现象
xmg_tune_sysctl_apply() {
    local file="$1"
    local line=""
    local failed=0

    if [ ! -r "$file" ]; then
        xmg_error "sysctl 配置不可读: $file"
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*)
                continue
                ;;
        esac

        if ! sysctl -q -w "$line" >/dev/null 2>&1; then
            xmg_warn "sysctl 应用失败: $line"
            failed=$((failed + 1))
        fi
    done < "$file"

    return "$failed"
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
        mkdir -p "$(dirname "$XMG_TUNE_SYSTEMD_LIMITS_CONF")"
        cat > "$XMG_TUNE_SYSTEMD_LIMITS_CONF" <<EOF
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
        high)
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
        if [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
            echo "# --- 连接跟踪 ---"
            echo "net.netfilter.nf_conntrack_max = $conntrack_max"
            echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"
            echo
        fi
        echo "# --- 虚拟内存 ---"
        echo "vm.swappiness = 10"
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

    {
        echo
        echo "请选择 DNS 预设:"
        echo "  1. Cloudflare   (1.1.1.1 / 1.0.0.1)            [境外推荐·默认]"
        echo "  2. Google       (8.8.8.8 / 8.8.4.4)"
        echo "  3. Quad9        (9.9.9.9 / 149.112.112.112)"
        echo "  4. 阿里 DNS     (223.5.5.5 / 223.6.6.6)        [境内推荐·海外服务器延迟较高]"
        echo "  5. Cloudflare IPv6 (2606:4700:4700::1111 / ::1001)  [纯 IPv6 机]"
        echo "  6. Google IPv6  (2001:4860:4860::8888 / ::8844)     [纯 IPv6 机]"
        echo "  7. 自定义 (支持 IPv4 / IPv6 / 混合双栈)"
        printf "请选择 [1]: "
    } >&2
    read -r choice || return 1
    # 空输入归一为默认（Cloudflare，境外）
    [ -z "$choice" ] && choice="1"

    case "$choice" in
        1) printf '%s\n' "$XMG_TUNE_DNS_DEFAULT" ;;
        2) printf '8.8.8.8 8.8.4.4\n' ;;
        3) printf '9.9.9.9 149.112.112.112\n' ;;
        4) printf '223.5.5.5 223.6.6.6\n' ;;
        5) printf '2606:4700:4700::1111 2606:4700:4700::1001\n' ;;
        6) printf '2001:4860:4860::8888 2001:4860:4860::8844\n' ;;
        7)
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

    mkdir -p "$(dirname "$XMG_TUNE_RESOLVED_CONF")"
    xmg_tune_backup_file "$XMG_TUNE_RESOLVED_CONF" || true

    cat > "$XMG_TUNE_RESOLVED_CONF" <<EOF
# XMG: DNS 优化（由 xmg tune 生成）
[Resolve]
DNS=$dns1 $dns2
FallbackDNS=9.9.9.9 149.112.112.112
Domains=~.
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
options timeout:2 attempts:2 rotate
EOF
    chmod 644 /etc/resolv.conf

    xmg_info "DNS 已写入 /etc/resolv.conf"

    # 防止 DHCP / cloud-init 覆盖
    if xmg_confirm "是否锁定 /etc/resolv.conf 防止被覆盖? (chattr +i)"; then
        if chattr +i /etc/resolv.conf 2>/dev/null; then
            xmg_info "已锁定。解锁命令: chattr -i /etc/resolv.conf"
        else
            xmg_warn "chattr +i 失败（文件系统可能不支持）"
        fi
    fi
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

    echo
    echo "将使用 DNS: $dns1 / $dns2"

    if ! xmg_confirm "确认应用?"; then
        xmg_info "已取消"
        return 0
    fi

    if xmg_tune_is_resolved_managed; then
        xmg_tune_dns_apply_resolved "$dns1" "$dns2"
    else
        xmg_tune_dns_apply_resolvconf "$dns1" "$dns2"
    fi
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

    {
        echo
        echo "请选择 DoT 上游 (DNSOverTLS=opportunistic，失败自动回退明文):"
        echo "  1. Cloudflare   (1.1.1.1 / 1.0.0.1)            [境外推荐·默认]"
        echo "  2. Google       (8.8.8.8 / 8.8.4.4)"
        echo "  3. Quad9        (9.9.9.9 / 149.112.112.112)"
        echo "  4. 阿里 DNS     (223.5.5.5 / 223.6.6.6)        [境内推荐·海外服务器延迟较高]"
        echo "  5. Cloudflare IPv6 (2606:4700:4700::1111 / ::1001)  [纯 IPv6 机]"
        echo "  6. 自定义 (支持 IPv4 / IPv6)"
        printf "请选择 [1]: "
    } >&2
    read -r choice || return 1
    # 空输入归一为默认（Cloudflare，境外）
    [ -z "$choice" ] && choice="1"

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
    getent hosts deb.debian.org >/dev/null 2>&1
}

# systemd-resolved 服务单元是否存在（Debian 12 精简模板常缺此包）
xmg_tune_resolved_unit_exists() {
    systemctl list-unit-files --type=service 2>/dev/null \
        | grep -q '^systemd-resolved\.service'
}

# resolved 未运行时的启用迁移（带回退）：
# 备份 resolv.conf -> 启用 resolved -> 切 stub 软链 -> 验证解析，失败整体回滚
xmg_tune_dns_enable_resolved() {
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
                if ! apt-get install -y systemd-resolved; then
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

    mkdir -p "$(dirname "$XMG_TUNE_RESOLVED_CONF")"
    xmg_tune_backup_file "$XMG_TUNE_RESOLVED_CONF" || true

    cat > "$XMG_TUNE_RESOLVED_CONF" <<EOF
# XMG: 加密 DNS DoT（由 xmg tune 生成）
[Resolve]
DNS=$dns1 $dns2
FallbackDNS=9.9.9.9 149.112.112.112
Domains=~.
# opportunistic: DoT(853) 不通时自动回退明文 53，不会断网
DNSOverTLS=opportunistic
EOF

    systemctl restart systemd-resolved 2>/dev/null || {
        xmg_error "systemd-resolved 重启失败"
        return 1
    }

    if ! xmg_tune_dns_verify; then
        xmg_error "DoT 配置后解析失败，请检查上游 853 端口连通性"
        xmg_warn "可重新执行「一键 DNS 优化」切回普通 UDP 模式"
        return 1
    fi

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

    echo
    echo "将启用 DoT (opportunistic): $dns1 / $dns2"

    if ! xmg_confirm "确认应用?"; then
        xmg_info "已取消"
        return 0
    fi

    # resolved 未运行时先迁移启用（内置回滚）
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if ! xmg_tune_dns_enable_resolved; then
            return 1
        fi
    fi

    xmg_tune_dns_dot_apply "$dns1" "$dns2" || true
}

# ===== 时间同步 =====

xmg_tune_time_sync() {
    xmg_require_root

    if ! xmg_cmd_exists timedatectl; then
        xmg_die "未检测到 timedatectl，需要 systemd 环境"
    fi

    # 时区
    echo "当前时区: $(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
    if xmg_confirm "是否将时区设置为 Asia/Shanghai?"; then
        timedatectl set-timezone Asia/Shanghai && xmg_info "时区已设置为 Asia/Shanghai"
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
    xmg_tune_backup_file /etc/fstab || true

    xmg_info "创建 ${mb}MB Swap: $XMG_TUNE_SWAPFILE"

    # dd 而非 fallocate：fallocate 产生的文件可能含 hole，swapon 会拒绝
    dd if=/dev/zero of="$XMG_TUNE_SWAPFILE" bs=1M count="$mb" status=none \
        || xmg_die "写入 swapfile 失败"

    chmod 600 "$XMG_TUNE_SWAPFILE"
    mkswap "$XMG_TUNE_SWAPFILE" >/dev/null || {
        rm -f "$XMG_TUNE_SWAPFILE"
        xmg_die "mkswap 失败"
    }
    swapon "$XMG_TUNE_SWAPFILE" || {
        rm -f "$XMG_TUNE_SWAPFILE"
        xmg_die "swapon 失败"
    }

    if ! grep -q "^$XMG_TUNE_SWAPFILE " /etc/fstab; then
        printf '%s none swap sw 0 0\n' "$XMG_TUNE_SWAPFILE" >> /etc/fstab
    fi

    cat > "$XMG_TUNE_SYSCTL_SWAP_CONF" <<'EOF'
# XMG: Swap 参数（由 xmg tune 生成）
vm.swappiness = 10
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
