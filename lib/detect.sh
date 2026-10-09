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

    # 2. systemd-detect-virt 命令辅助（若存在）
    if command -v systemd-detect-virt >/dev/null 2>&1; then
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
# 内存分档探测
# 输出: extreme_low (<=256MB) | low (<=512MB) | mid (<=2048MB) | high (>2048MB)
# ------------------------------------------------------------------
xmg_detect_mem_profile() {
    local total_kb=""

    if [ -n "${MOCK_MEM_TOTAL_KB:-}" ]; then
        total_kb="$MOCK_MEM_TOTAL_KB"
    fi

    if [ -z "$total_kb" ]; then
        local meminfo_file="${XMG_MEMINFO_FILE:-/proc/meminfo}"
        if [ -r "$meminfo_file" ]; then
            local k="" v="" rest=""
            while IFS=': ' read -r k v rest; do
                if [ "$k" = "MemTotal" ]; then
                    total_kb="${v//[!0-9]/}"
                    break
                fi
            done < "$meminfo_file"
        fi
    fi

    if [ -z "$total_kb" ] && command -v free >/dev/null 2>&1; then
        local free_out=""
        free_out="$(free -k 2>/dev/null || true)"
        local fline=""
        while IFS= read -r fline || [ -n "$fline" ]; do
            if [[ "$fline" =~ ^Mem:[[:space:]]+([0-9]+) ]]; then
                total_kb="${BASH_REMATCH[1]:-}"
                break
            fi
        done <<< "$free_out"
    fi

    if [ -z "$total_kb" ] || ! [[ "$total_kb" =~ ^[0-9]+$ ]]; then
        printf 'mid\n'
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
            while IFS= read -r line4 || [ -n "$line4" ]; do
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
            while IFS= read -r line6 || [ -n "$line6" ]; do
                if [[ "$line6" =~ inet6[[:space:]]+([^/[:space:]]+) ]]; then
                    local ip6="${BASH_REMATCH[1]:-}"
                    if [[ "$line6" =~ scope[[:space:]]+global ]]; then
                        if [[ "$ip6" != "::1" ]] && [[ "$ip6" != fe80* ]]; then
                            has_v6=1
                            break
                        fi
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
            if grep -qiE '(dns64|nat64|2001:67c:2b0|2a00:1098:2b|2a00:1098:2c|2a01:4f8:c2c:123f)' "$resolv_file" 2>/dev/null; then
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
        done <<< "$(cat "$mounts_file" 2>/dev/null || true)"
    fi

    # 2. 检查 /proc/self/status 中有效能力 CapEff
    # CAP_SYS_ADMIN 对应位掩码为 1 << 21 (0x200000)
    if [ -r "$status_file" ]; then
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
