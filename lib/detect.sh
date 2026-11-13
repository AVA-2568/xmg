#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# detect.sh - XMG 环境能力与容器自省层
#
# 说明：
#   - 探测宿主或容器虚拟化类型 (kvm / openvz / lxc / docker / unknown)
#   - 探测系统内存分档 (extreme_low / low / mid / high)
#   - 探测网络栈及 NAT/NAT64 拓扑 (XMG_NET_IPV4 / XMG_NET_IPV6 / XMG_NET_NAT / XMG_NET_NAT64)
#   - 探测受限容器状态 (sysctl 只读 / 缺少 CAP_SYS_ADMIN)
#   - 纯 Bash 内建实现，零 jq / 零 python
#

if [ -z "${BASH_VERSION:-}" ]; then
    echo "detect.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_DETECT_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_DETECT_SH_LOADED=1

# 说明：detect.sh 只提供 CLI 与内部接口（xmg detect ...），刻意不注册菜单：
# 环境信息已由 xmg doctor 与 xmg os 呈现，重复菜单入口只会让排查路径分叉。

# ------------------------------------------------------------------
# 虚拟化与容器类型探测
# 输出: kvm | openvz | lxc | docker | unknown
# ------------------------------------------------------------------
xmg_detect_virt() {
    if [ -n "${MOCK_VIRT:-}" ]; then
        printf '%s\n' "$MOCK_VIRT"
        return 0
    fi

    local proc_dir="${XMG_DETECT_PROC_DIR:-/proc}"
    local dmi_dir="${XMG_DETECT_SYS_DMI_DIR:-/sys/devices/virtual/dmi/id}"
    local dockerenv="${XMG_DETECT_DOCKERENV:-/.dockerenv}"

    # 1. 容器优先识别
    # 1.1 Docker
    if [ -f "$dockerenv" ]; then
        printf 'docker\n'
        return 0
    fi
    if [ -r "$proc_dir/1/cgroup" ] && grep -qa 'docker' "$proc_dir/1/cgroup" 2>/dev/null; then
        printf 'docker\n'
        return 0
    fi
    if [ -r "$proc_dir/1/environ" ] && grep -qa 'container=docker' "$proc_dir/1/environ" 2>/dev/null; then
        printf 'docker\n'
        return 0
    fi

    # 1.2 LXC
    if [ -r "$proc_dir/1/environ" ] && grep -qa 'container=lxc' "$proc_dir/1/environ" 2>/dev/null; then
        printf 'lxc\n'
        return 0
    fi
    if [ -r "$proc_dir/1/cgroup" ] && grep -qa 'lxc' "$proc_dir/1/cgroup" 2>/dev/null; then
        printf 'lxc\n'
        return 0
    fi

    # 1.3 OpenVZ
    if [ -f "$proc_dir/user_beancounters" ] || [ -d "$proc_dir/vz" ]; then
        printf 'openvz\n'
        return 0
    fi

    # 2. systemd-detect-virt 命令辅助（仅在未注入自定义探测目录时调用宿主机工具）
    if [ -z "${XMG_DETECT_PROC_DIR:-}" ] && [ -z "${XMG_DETECT_SYS_DMI_DIR:-}" ] && command -v systemd-detect-virt >/dev/null 2>&1; then
        local sdv=""
        sdv="$(systemd-detect-virt 2>/dev/null || true)"
        case "$sdv" in
            kvm|qemu|bochs)
                printf 'kvm\n'
                return 0
                ;;
            openvz)
                printf 'openvz\n'
                return 0
                ;;
            lxc)
                printf 'lxc\n'
                return 0
                ;;
            docker)
                printf 'docker\n'
                return 0
                ;;
            vmware)
                printf 'vmware\n'
                return 0
                ;;
            xen)
                printf 'xen\n'
                return 0
                ;;
            microsoft|hyperv)
                printf 'hyperv\n'
                return 0
                ;;
            wsl)
                printf 'wsl\n'
                return 0
                ;;
            none)
                printf 'baremetal\n'
                return 0
                ;;
            ?*)
                printf '%s\n' "$sdv"
                return 0
                ;;
        esac
    fi

    # 3. DMI 硬件标识表
    local dmi_f=""
    local dmi_val=""
    for dmi_f in "$dmi_dir/product_name" "$dmi_dir/sys_vendor" "$dmi_dir/bios_vendor"; do
        if [ -r "$dmi_f" ]; then
            dmi_val="$(cat "$dmi_f" 2>/dev/null || true)"
            case "$dmi_val" in
                *QEMU*|*KVM*|*Bochs*)
                    printf 'kvm\n'
                    return 0
                    ;;
                *VMware*|*VMW*)
                    printf 'vmware\n'
                    return 0
                    ;;
                *Microsoft*|*Hyper-V*)
                    printf 'hyperv\n'
                    return 0
                    ;;
                *Xen*)
                    printf 'xen\n'
                    return 0
                    ;;
                *VirtualBox*|*innotek*)
                    printf 'virtualbox\n'
                    return 0
                    ;;
            esac
        fi
    done

    # 4. /proc/cpuinfo 特征
    if [ -r "$proc_dir/cpuinfo" ]; then
        if grep -qaE '(QEMU|KVM|Hypervisor)' "$proc_dir/cpuinfo" 2>/dev/null; then
            printf 'kvm\n'
            return 0
        fi
    fi

    printf 'unknown\n'
    return 0
}

# ------------------------------------------------------------------
# 统一内存真源（kB）
#   - 容器内 /proc/meminfo 是宿主值，必须取 min(MemTotal, cgroup 配额)
#   - cgroup 路径开关与 system.sh 共用 XMG_CGROUP_MEMORY_*
#   - MOCK_MEM_TOTAL_KB / MOCK_MEM_TOTAL_MB 命中时直接采信（测试注入）
#   - 返回 0 表示探测失败
# ------------------------------------------------------------------
xmg_detect_mem_total_kb() {
    local total_kb=0 k="" v="" rest=""

    if [ -n "${MOCK_MEM_TOTAL_KB:-}" ]; then
        total_kb="${MOCK_MEM_TOTAL_KB//[!0-9]/}"
        case "$total_kb" in ''|*[!0-9]*) total_kb=0 ;; esac
        printf '%s\n' "$total_kb"
        return 0
    fi

    if [ -n "${MOCK_MEM_TOTAL_MB:-}" ]; then
        local mock_mb="${MOCK_MEM_TOTAL_MB//[!0-9]/}"
        case "$mock_mb" in ''|*[!0-9]*) mock_mb=0 ;; esac
        printf '%s\n' "$((mock_mb * 1024))"
        return 0
    fi

    local meminfo_file="${XMG_MEMINFO_FILE:-/proc/meminfo}"
    if [ -r "$meminfo_file" ]; then
        while IFS=': ' read -r k v rest; do
            if [ "$k" = "MemTotal" ]; then
                total_kb="${v//[!0-9]/}"
                break
            fi
        done < "$meminfo_file"
    fi
    case "$total_kb" in ''|*[!0-9]*) total_kb=0 ;; esac

    if [ "$total_kb" -eq 0 ] && command -v free >/dev/null 2>&1; then
        local free_out="" fline=""
        free_out="$(free -k 2>/dev/null || true)"
        while IFS= read -r fline || [ -n "$fline" ]; do
            if [[ "$fline" =~ ^Mem:[[:space:]]+([0-9]+) ]]; then
                total_kb="${BASH_REMATCH[1]:-0}"
                break
            fi
        done <<< "$free_out"
    fi
    case "$total_kb" in ''|*[!0-9]*) total_kb=0 ;; esac

    # cgroup v2 memory.max 优先，其次 v1 memory.limit_in_bytes；
    # "max" / 超长哨兵值（v1 常见 9223372036854771712）视为未限额。
    local cg_file="" cg_bytes="" cg_kb=0
    for cg_file in "${XMG_CGROUP_MEMORY_MAX:-/sys/fs/cgroup/memory.max}" \
                   "${XMG_CGROUP_MEMORY_LIMIT:-/sys/fs/cgroup/memory/memory.limit_in_bytes}"; do
        [ -r "$cg_file" ] || continue
        cg_bytes="$(cat "$cg_file" 2>/dev/null || true)"
        case "$cg_bytes" in
            ''|max|*[!0-9]*) continue ;;
        esac
        if [ "${#cg_bytes}" -gt 15 ]; then
            continue
        fi
        cg_kb=$((cg_bytes / 1024))
        if [ "$cg_kb" -gt 0 ] && { [ "$total_kb" -eq 0 ] || [ "$cg_kb" -lt "$total_kb" ]; }; then
            total_kb="$cg_kb"
        fi
        break
    done

    printf '%s\n' "$total_kb"
    return 0
}

xmg_detect_mem_total_mb() {
    local kb=""
    kb="$(xmg_detect_mem_total_kb)"
    printf '%s\n' "$((kb / 1024))"
    return 0
}

# 可用内存（MB）：MemAvailable 优先，回退 MemFree+Buffers+Cached，
# 无 /proc 时用 free，全失败返回 1（调用方自行决定降级）。
# XMG_MEMINFO_FILE 仅用于测试注入，生产恒为 /proc/meminfo。
XMG_MEMINFO_FILE="${XMG_MEMINFO_FILE:-/proc/meminfo}"

xmg_mem_available_mb() {
    local kb="" mb=""

    if [ -r "$XMG_MEMINFO_FILE" ]; then
        kb="$(awk '/^MemAvailable:/ {print $2; exit}' "$XMG_MEMINFO_FILE" 2>/dev/null)"
        if [ -z "$kb" ]; then
            kb="$(awk '/^MemFree:/ {f=$2} /^Buffers:/ {b=$2} /^Cached:/ {c=$2} END {print f+b+c}' \
                "$XMG_MEMINFO_FILE" 2>/dev/null)"
        fi
    fi

    if [ -n "$kb" ]; then
        mb=$((kb / 1024))
        printf '%s' "$mb"
        return 0
    fi

    if command -v free >/dev/null 2>&1; then
        mb="$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}')"
        if [ -n "$mb" ]; then
            printf '%s' "$mb"
            return 0
        fi
    fi

    return 1
}

# 有效内存（MB）：真正能分给新进程的量，不是标称总内存。
#   512MB 机器跑着其他服务、只剩 218MB 可用时，按 512MB 判档会同时放大
#   GOMEMLIMIT 与 geosite 档位，Go 峰值一冲就到 OOM 边缘。
#   可用内存是瞬时值，加 25% 抖动余量后再与总内存取小，避免单次采样把档位打得太低。
xmg_mem_effective_mb() {
    local total=0 avail=0 eff=0
    total="$(xmg_detect_mem_total_mb)"
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    avail="$(xmg_mem_available_mb 2>/dev/null || printf 0)"
    [[ "$avail" =~ ^[0-9]+$ ]] || avail=0
    if [ "$total" -le 0 ]; then
        printf '0'
        return 0
    fi
    if [ "$avail" -le 0 ]; then
        printf '%s' "$total"
        return 0
    fi
    eff=$(( avail + avail / 4 ))
    [ "$eff" -lt "$total" ] || eff="$total"
    printf '%s' "$eff"
}

# ------------------------------------------------------------------
# 有效 CPU 核数：cgroup CPU 配额优先，分数配额（0.5C）收敛为 1
# ------------------------------------------------------------------
xmg_detect_cpu_cores() {
    if [ -n "${MOCK_CPU_CORES:-}" ]; then
        case "$MOCK_CPU_CORES" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$MOCK_CPU_CORES" -ge 1 ]; then
                    printf '%s\n' "$MOCK_CPU_CORES"
                    return 0
                fi
                ;;
        esac
    fi

    local quota="" period="" cores=0 quota_seen=0
    local cpu_max="${XMG_CGROUP_CPU_MAX:-/sys/fs/cgroup/cpu.max}"
    if [ -r "$cpu_max" ]; then
        read -r quota period _ < "$cpu_max" 2>/dev/null || true
        if [[ "$quota" =~ ^[0-9]+$ ]] && [[ "$period" =~ ^[0-9]+$ ]] && [ "$period" -gt 0 ]; then
            cores=$((quota / period))
            quota_seen=1
        fi
    fi

    if [ "$quota_seen" -eq 0 ]; then
        local quota_f="${XMG_CGROUP_CPU_QUOTA:-/sys/fs/cgroup/cpu/cpu.cfs_quota_us}"
        local period_f="${XMG_CGROUP_CPU_PERIOD:-/sys/fs/cgroup/cpu/cpu.cfs_period_us}"
        if [ -r "$quota_f" ] && [ -r "$period_f" ]; then
            quota="$(cat "$quota_f" 2>/dev/null || true)"
            period="$(cat "$period_f" 2>/dev/null || true)"
            if [[ "$quota" =~ ^[0-9]+$ ]] && [ "$quota" -gt 0 ] && [[ "$period" =~ ^[0-9]+$ ]] && [ "$period" -gt 0 ]; then
                cores=$((quota / period))
                quota_seen=1
            fi
        fi
    fi

    if [ "$quota_seen" -eq 0 ]; then
        if command -v nproc >/dev/null 2>&1; then
            cores="$(nproc 2>/dev/null || printf 0)"
        elif command -v getconf >/dev/null 2>&1; then
            cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 0)"
        fi
        case "$cores" in ''|*[!0-9]*) cores=0 ;; esac
    fi

    if [ "$cores" -lt 1 ]; then
        cores=1
    fi
    printf '%s\n' "$cores"
    return 0
}

# ------------------------------------------------------------------
# 内存分档探测（基于统一真源）
# 输出: extreme_low (<=256MB) | low (<=512MB) | mid (<=2048MB) | high (>2048MB)
# ------------------------------------------------------------------
xmg_detect_mem_profile() {
    local total_kb=""
    total_kb="$(xmg_detect_mem_total_kb)"

    # 探测失败与 tune.sh 的 512MB 兜底保持一致，统一落在 low 档
    if [ -z "$total_kb" ] || [ "$total_kb" -le 0 ]; then
        printf 'low\n'
        return 0
    fi

    # 档位判定（单位 kB）：
    # extreme_low: <= 256MB (262144 kB)
    # low:         <= 512MB (524288 kB)
    # mid:         <= 2048MB (2097152 kB)
    # high:        > 2048MB
    if [ "$total_kb" -le 262144 ]; then
        printf 'extreme_low\n'
    elif [ "$total_kb" -le 524288 ]; then
        printf 'low\n'
    elif [ "$total_kb" -le 2097152 ]; then
        printf 'mid\n'
    else
        printf 'high\n'
    fi
    return 0
}

# ------------------------------------------------------------------
# 网络栈及 NAT/NAT64 探测
# 导出环境变量: XMG_NET_IPV4 (0/1), XMG_NET_IPV6 (0/1), XMG_NET_NAT (0/1), XMG_NET_NAT64 (0/1)
# ------------------------------------------------------------------
xmg_detect_network() {
    local net_4="${MOCK_NET_IPV4:-}"
    local net_6="${MOCK_NET_IPV6:-}"
    local net_nat="${MOCK_NET_NAT:-}"
    local net_nat64="${MOCK_NET_NAT64:-}"

    if [ -z "$net_4" ] || [ -z "$net_6" ] || [ -z "$net_nat" ] || [ -z "$net_nat64" ]; then
        local ip_cmd=""
        if declare -F ip >/dev/null 2>&1 || command -v ip >/dev/null 2>&1; then
            ip_cmd="ip"
        fi

        local has_v4=0
        local has_v4_public=0
        if [ -n "$ip_cmd" ]; then
            local v4_out=""
            v4_out="$($ip_cmd -4 addr show 2>/dev/null || true)"
            local line4=""
            local cur_dev=""
            while IFS= read -r line4 || [ -n "$line4" ]; do
                if [[ "$line4" =~ ^[0-9]+:[[:space:]]+([^:@]+) ]]; then
                    cur_dev="${BASH_REMATCH[1]}"
                fi
                case "$cur_dev" in
                    lo|docker*|virbr*|br-*|veth*|dummy*)
                        continue
                        ;;
                esac
                if [[ "$line4" =~ inet[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    local ip_addr="${BASH_REMATCH[1]}"
                    if [[ "$ip_addr" != 127.* ]]; then
                        has_v4=1
                        local is_priv=0
                        if [[ "$ip_addr" =~ ^10\. ]] || [[ "$ip_addr" =~ ^192\.168\. ]] || [[ "$ip_addr" =~ ^169\.254\. ]]; then
                            is_priv=1
                        elif [[ "$ip_addr" =~ ^172\.([0-9]+)\. ]]; then
                            local o2="${BASH_REMATCH[1]}"
                            if [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then
                                is_priv=1
                            fi
                        elif [[ "$ip_addr" =~ ^100\.([0-9]+)\. ]]; then
                            local o2="${BASH_REMATCH[1]}"
                            if [ "$o2" -ge 64 ] && [ "$o2" -le 127 ]; then
                                is_priv=1
                            fi
                        fi
                        if [ "$is_priv" -eq 0 ]; then
                            has_v4_public=1
                        fi
                    fi
                fi
            done <<< "$v4_out"
        fi

        [ -n "$net_4" ] || net_4="$has_v4"

        if [ -z "$net_nat" ]; then
            if [ "$net_4" -eq 1 ] && [ "$has_v4_public" -eq 0 ]; then
                net_nat=1
            else
                net_nat=0
            fi
        fi

        local has_v6=0
        if [ -n "$ip_cmd" ]; then
            local v6_out=""
            v6_out="$($ip_cmd -6 addr show 2>/dev/null || true)"
            local line6=""
            local cur_dev6=""
            while IFS= read -r line6 || [ -n "$line6" ]; do
                if [[ "$line6" =~ ^[0-9]+:[[:space:]]+([^:@]+) ]]; then
                    cur_dev6="${BASH_REMATCH[1]}"
                fi
                case "$cur_dev6" in
                    lo|docker*|virbr*|br-*|veth*|dummy*)
                        continue
                        ;;
                esac
                if [[ "$line6" =~ inet6[[:space:]]+([^/[:space:]]+) ]]; then
                    local ip6="${BASH_REMATCH[1]:-}"
                    if [[ "$line6" =~ scope[[:space:]]+global ]]; then
                        case "$ip6" in
                            ::1|[fF][eE]80:*|[fF][cC]*|[fF][dD]*)
                                continue
                                ;;
                            *)
                                has_v6=1
                                break
                                ;;
                        esac
                    fi
                fi
            done <<< "$v6_out"
        fi
        [ -n "$net_6" ] || net_6="$has_v6"

        local has_nat64=0
        if [ -n "$ip_cmd" ]; then
            local route6=""
            route6="$($ip_cmd -6 route 2>/dev/null || true)"
            if [[ "$route6" == *"64:ff9b::"* ]]; then
                has_nat64=1
            fi
        fi

        local resolv_file="${XMG_RESOLV_CONF_FILE:-/etc/resolv.conf}"
        if [ "$has_nat64" -eq 0 ] && [ -r "$resolv_file" ]; then
            # 扩充主流已知公共与常见 DNS64 地址池特征
            # 包含: Google(2001:4860:4860::64/6464), Cloudflare(2606:4700:4700::64/6400),
            #       Trezor/Kasper(2001:67c:2b0), Hetzner/Nat64.net(2a00:1098:2b/2c, 2a01:4f8:c2c:123f),
            #       以及通用关键词 dns64, nat64
            if grep -qiE '(dns64|nat64|2001:67c:2b0|2a00:1098:2b|2a00:1098:2c|2a01:4f8:c2c:123f|2001:4860:4860::64|2606:4700:4700::64)' "$resolv_file" 2>/dev/null; then
                has_nat64=1
            fi
        fi

        # RFC 7050 标准协议主动探测：当未命中静态特征时，尝试解析保留权威域名 ipv4only.arpa
        if [ "$has_nat64" -eq 0 ] && [ "${XMG_TEST_MODE:-0}" != "1" ]; then
            local nat64_probe=""
            if command -v getent >/dev/null 2>&1; then
                if command -v timeout >/dev/null 2>&1; then
                    nat64_probe="$(timeout 2 getent ahosts ipv4only.arpa 2>/dev/null | grep -E '^64:ff9b::' | head -n 1 || true)"
                else
                    nat64_probe="$(getent ahosts ipv4only.arpa 2>/dev/null | grep -E '^64:ff9b::' | head -n 1 || true)"
                fi
            fi
            if [ -z "$nat64_probe" ] && command -v nslookup >/dev/null 2>&1; then
                if command -v timeout >/dev/null 2>&1; then
                    nat64_probe="$(timeout 2 nslookup -type=AAAA ipv4only.arpa 2>/dev/null | grep -oE '64:ff9b::[0-9a-fA-F:]+' | head -n 1 || true)"
                else
                    nat64_probe="$(nslookup -type=AAAA ipv4only.arpa 2>/dev/null | grep -oE '64:ff9b::[0-9a-fA-F:]+' | head -n 1 || true)"
                fi
            fi
            if [ -n "$nat64_probe" ]; then
                has_nat64=1
            fi
        fi
        [ -n "$net_nat64" ] || net_nat64="$has_nat64"
    fi

    XMG_NET_IPV4="$net_4"
    XMG_NET_IPV6="$net_6"
    XMG_NET_NAT="$net_nat"
    XMG_NET_NAT64="$net_nat64"
    export XMG_NET_IPV4 XMG_NET_IPV6 XMG_NET_NAT XMG_NET_NAT64
}

# ------------------------------------------------------------------
# 受限容器探测
# 返回: 0 (正常主机/特权容器) | 1 (受限容器，只读 sysctl / 无 CAP_SYS_ADMIN)
# ------------------------------------------------------------------
xmg_detect_container_restricted() {
    if [ -n "${MOCK_CONTAINER_RESTRICTED:-}" ]; then
        if [ "$MOCK_CONTAINER_RESTRICTED" = "1" ]; then
            return 1
        else
            return 0
        fi
    fi

    local mounts_file="${XMG_PROC_MOUNTS_FILE:-/proc/mounts}"
    local status_file="${XMG_PROC_STATUS_FILE:-/proc/self/status}"

    # 1. 检查 /proc/mounts 中挂载点 /proc/sys 是否为只读 (ro)
    if [ -r "$mounts_file" ]; then
        local mline=""
        while IFS= read -r mline || [ -n "$mline" ]; do
            if [[ "$mline" =~ [[:space:]]/proc/sys([[:space:]]|$) ]] || [[ "$mline" =~ [[:space:]]/proc([[:space:]]|$) ]]; then
                if [[ "$mline" =~ (^|[[:space:],])ro([[:space:],]|$) ]]; then
                    return 1
                fi
            fi
        done < "$mounts_file"
    fi

    # 2. 检查 /proc/self/status 中有效能力 CapEff
    # CAP_SYS_ADMIN 对应位掩码为 1 << 21 (0x200000)
    # 仅在显式指定 XMG_PROC_STATUS_FILE 或当前为 root (EUID=0) 时检查，避免普通非 root 用户因 CapEff=0 被误判为受限容器
    if { [ -n "${XMG_PROC_STATUS_FILE:-}" ] || [ "${EUID:-$(id -u 2>/dev/null || echo 1)}" -eq 0 ]; } && [ -r "$status_file" ]; then
        local cap_eff=""
        local k="" v="" rest=""
        while IFS=': \t' read -r k v rest; do
            if [ "$k" = "CapEff" ]; then
                cap_eff="${v//[!0-9a-fA-F]/}"
                break
            fi
        done < "$status_file"

        if [ -n "$cap_eff" ]; then
            local padded_cap="000000$cap_eff"
            local low_hex="${padded_cap: -6}"
            local low_dec=$(( 16#0$low_hex ))
            if (( (low_dec & 0x200000) == 0 )); then
                return 1
            fi
        fi
    fi

    # 3. 若为 root 用户且 /proc/sys/net/ipv4/ip_forward 存在但不可写，判定受限
    if [ "${EUID:-$(id -u 2>/dev/null || echo 1)}" -eq 0 ]; then
        if [ -e "/proc/sys/net/ipv4/ip_forward" ] && [ ! -w "/proc/sys/net/ipv4/ip_forward" ]; then
            return 1
        fi
    fi

    return 0
}
