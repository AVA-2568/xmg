#!/usr/bin/env bash
# 环境能力与容器自省层测试 (Task 2)
# shellcheck shell=bash

SRC="$TESTS_DIR/.."
FILES="$SRC/xmg.files"

# --- 1. 清单与加载验证 ---
t_contains "清单含 lib/detect.sh" "$(cat "$FILES")" "lib/detect.sh"

XMG_TMP="$(mktemp -d)"

# 尝试加载 lib/detect.sh
if [ -f "$SRC/lib/detect.sh" ]; then
    # shellcheck source=/dev/null
    source "$SRC/lib/detect.sh"
fi

# 检查哨兵变量与核心函数导出
t_equals "XMG_DETECT_SH_LOADED 哨兵变量应为 1" "${XMG_DETECT_SH_LOADED:-0}" "1"
t_assert "定义 xmg_detect_virt 函数" declare -F xmg_detect_virt
t_assert "定义 xmg_detect_mem_profile 函数" declare -F xmg_detect_mem_profile
t_assert "定义 xmg_detect_network 函数" declare -F xmg_detect_network
t_assert "定义 xmg_detect_container_restricted 函数" declare -F xmg_detect_container_restricted

# --- 2. xmg_detect_virt 测试 ---
# 2.1 MOCK_VIRT 环境变量优先覆盖
t_equals "MOCK_VIRT 覆盖为 docker" "$(MOCK_VIRT=docker xmg_detect_virt)" "docker"
t_equals "MOCK_VIRT 覆盖为 kvm" "$(MOCK_VIRT=kvm xmg_detect_virt)" "kvm"
t_equals "MOCK_VIRT 覆盖为 lxc" "$(MOCK_VIRT=lxc xmg_detect_virt)" "lxc"
t_equals "MOCK_VIRT 覆盖为 openvz" "$(MOCK_VIRT=openvz xmg_detect_virt)" "openvz"
t_equals "MOCK_VIRT 覆盖为 unknown" "$(MOCK_VIRT=unknown xmg_detect_virt)" "unknown"

# 2.2 文件特征检测：docker
mkdir -p "$XMG_TMP/docker_root/proc/1"
touch "$XMG_TMP/docker_root/.dockerenv"
_res="$(XMG_DETECT_PROC_DIR="$XMG_TMP/docker_root/proc" XMG_DETECT_DOCKERENV="$XMG_TMP/docker_root/.dockerenv" xmg_detect_virt)"
t_equals "存在 .dockerenv 时检测为 docker" "$_res" "docker"

# 2.3 文件特征检测：lxc
mkdir -p "$XMG_TMP/lxc_root/proc/1"
printf 'container=lxc\0PATH=/bin' > "$XMG_TMP/lxc_root/proc/1/environ"
_res="$(XMG_DETECT_PROC_DIR="$XMG_TMP/lxc_root/proc" XMG_DETECT_DOCKERENV="$XMG_TMP/nonexistent" xmg_detect_virt)"
t_equals "environ 含 container=lxc 时检测为 lxc" "$_res" "lxc"

# 2.4 文件特征检测：openvz
mkdir -p "$XMG_TMP/openvz_root/proc"
touch "$XMG_TMP/openvz_root/proc/user_beancounters"
_res="$(XMG_DETECT_PROC_DIR="$XMG_TMP/openvz_root/proc" XMG_DETECT_DOCKERENV="$XMG_TMP/nonexistent" xmg_detect_virt)"
t_equals "存在 user_beancounters 时检测为 openvz" "$_res" "openvz"

# 2.5 文件特征检测：kvm (通过 DMI product_name)
mkdir -p "$XMG_TMP/kvm_root/proc"
mkdir -p "$XMG_TMP/kvm_root/sys/devices/virtual/dmi/id"
printf 'QEMU Standard PC (Q35 + ICH9, 2009)' > "$XMG_TMP/kvm_root/sys/devices/virtual/dmi/id/product_name"
_res="$(XMG_DETECT_PROC_DIR="$XMG_TMP/kvm_root/proc" XMG_DETECT_SYS_DMI_DIR="$XMG_TMP/kvm_root/sys/devices/virtual/dmi/id" XMG_DETECT_DOCKERENV="$XMG_TMP/nonexistent" xmg_detect_virt)"
t_equals "DMI product_name 含 QEMU 时检测为 kvm" "$_res" "kvm"

# 2.6 无任何标识时检测为 unknown
mkdir -p "$XMG_TMP/bare_root/proc/1"
mkdir -p "$XMG_TMP/bare_root/sys/devices/virtual/dmi/id"
_res="$(XMG_DETECT_PROC_DIR="$XMG_TMP/bare_root/proc" XMG_DETECT_SYS_DMI_DIR="$XMG_TMP/bare_root/sys/devices/virtual/dmi/id" XMG_DETECT_DOCKERENV="$XMG_TMP/nonexistent" PATH="/nonexistent" xmg_detect_virt)"
t_equals "空白环境检测为 unknown" "$_res" "unknown"

# --- 3. xmg_detect_mem_profile 测试 ---
# 3.1 极低内存档 (<=256MB = 262144 kB)
t_equals "215MB (220160 kB) 判定为 extreme_low" "$(MOCK_MEM_TOTAL_KB=220160 xmg_detect_mem_profile)" "extreme_low"
t_equals "256MB (262144 kB) 判定为 extreme_low" "$(MOCK_MEM_TOTAL_KB=262144 xmg_detect_mem_profile)" "extreme_low"

# 3.2 低内存档 (<=512MB = 524288 kB)
t_equals "257MB (262145 kB) 判定为 low" "$(MOCK_MEM_TOTAL_KB=262145 xmg_detect_mem_profile)" "low"
t_equals "512MB (524288 kB) 判定为 low" "$(MOCK_MEM_TOTAL_KB=524288 xmg_detect_mem_profile)" "low"

# 3.3 中等内存档 (<=2048MB = 2097152 kB)
t_equals "513MB (524289 kB) 判定为 mid" "$(MOCK_MEM_TOTAL_KB=524289 xmg_detect_mem_profile)" "mid"
t_equals "1024MB (1048576 kB) 判定为 mid" "$(MOCK_MEM_TOTAL_KB=1048576 xmg_detect_mem_profile)" "mid"
t_equals "2048MB (2097152 kB) 判定为 mid" "$(MOCK_MEM_TOTAL_KB=2097152 xmg_detect_mem_profile)" "mid"

# 3.4 高内存档 (>2048MB)
t_equals "2049MB (2097153 kB) 判定为 high" "$(MOCK_MEM_TOTAL_KB=2097153 xmg_detect_mem_profile)" "high"
t_equals "4096MB (4194304 kB) 判定为 high" "$(MOCK_MEM_TOTAL_KB=4194304 xmg_detect_mem_profile)" "high"

# 3.5 通过 meminfo 文件读取
printf 'MemTotal:         220160 kB\nMemFree:           32000 kB\n' > "$XMG_TMP/meminfo_215"
t_equals "通过 meminfo 读取 215MB" "$(XMG_MEMINFO_FILE="$XMG_TMP/meminfo_215" xmg_detect_mem_profile)" "extreme_low"

printf 'MemTotal:        4194304 kB\nMemFree:         1048576 kB\n' > "$XMG_TMP/meminfo_4g"
t_equals "通过 meminfo 读取 4GB" "$(XMG_MEMINFO_FILE="$XMG_TMP/meminfo_4g" xmg_detect_mem_profile)" "high"

# --- 4. xmg_detect_network 测试 ---
# 4.1 mock 环境变量直接注入
unset XMG_NET_IPV4 XMG_NET_IPV6 XMG_NET_NAT XMG_NET_NAT64
MOCK_NET_IPV4=1 MOCK_NET_IPV6=1 MOCK_NET_NAT=0 MOCK_NET_NAT64=0 xmg_detect_network
t_equals "双栈公网 IPv4" "$XMG_NET_IPV4" "1"
t_equals "双栈公网 IPv6" "$XMG_NET_IPV6" "1"
t_equals "双栈公网 NAT" "$XMG_NET_NAT" "0"
t_equals "双栈公网 NAT64" "$XMG_NET_NAT64" "0"

# 4.2 模拟 IPv4 NAT 场景
unset XMG_NET_IPV4 XMG_NET_IPV6 XMG_NET_NAT XMG_NET_NAT64
# shellcheck disable=SC2317
ip() {
    case "$*" in
        "-4 addr show"*)
            printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP>\n    inet 10.0.0.15/24 brd 10.0.0.255 scope global eth0\n'
            ;;
        "-6 addr show"*)
            ;;
        "-6 route"*)
            ;;
        *)
            ;;
    esac
}
xmg_detect_network
t_equals "NAT 场景 IPv4 为 1" "$XMG_NET_IPV4" "1"
t_equals "NAT 场景 IPv6 为 0" "$XMG_NET_IPV6" "0"
t_equals "NAT 场景 NAT 为 1" "$XMG_NET_NAT" "1"
t_equals "NAT 场景 NAT64 为 0" "$XMG_NET_NAT64" "0"
unset -f ip

# 4.3 模拟纯 IPv6 带 NAT64 场景
unset XMG_NET_IPV4 XMG_NET_IPV6 XMG_NET_NAT XMG_NET_NAT64
# shellcheck disable=SC2317
ip() {
    case "$*" in
        "-4 addr show"*)
            ;;
        "-6 addr show"*)
            printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP>\n    inet6 2001:db8::1/64 scope global\n'
            ;;
        "-6 route"*)
            printf '64:ff9b::/96 via 2001:db8::2 dev eth0\n'
            ;;
        *)
            ;;
    esac
}
xmg_detect_network
t_equals "纯 IPv6 场景 IPv4 为 0" "$XMG_NET_IPV4" "0"
t_equals "纯 IPv6 场景 IPv6 为 1" "$XMG_NET_IPV6" "1"
t_equals "纯 IPv6 场景 NAT 为 0" "$XMG_NET_NAT" "0"
t_equals "纯 IPv6 场景 NAT64 为 1" "$XMG_NET_NAT64" "1"
unset -f ip

# 4.4 模拟双栈公网场景
unset XMG_NET_IPV4 XMG_NET_IPV6 XMG_NET_NAT XMG_NET_NAT64
# shellcheck disable=SC2317
ip() {
    case "$*" in
        "-4 addr show"*)
            printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP>\n    inet 1.2.3.4/24 brd 1.2.3.255 scope global eth0\n'
            ;;
        "-6 addr show"*)
            printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP>\n    inet6 2400:cb00::1/64 scope global\n'
            ;;
        "-6 route"*)
            ;;
        *)
            ;;
    esac
}
xmg_detect_network
t_equals "双栈公网场景 IPv4 为 1" "$XMG_NET_IPV4" "1"
t_equals "双栈公网场景 IPv6 为 1" "$XMG_NET_IPV6" "1"
t_equals "双栈公网场景 NAT 为 0" "$XMG_NET_NAT" "0"
t_equals "双栈公网场景 NAT64 为 0" "$XMG_NET_NAT64" "0"
unset -f ip

# --- 5. xmg_detect_container_restricted 测试 ---
# 5.1 mock 环境变量
MOCK_CONTAINER_RESTRICTED=1 xmg_detect_container_restricted
t_equals "MOCK_CONTAINER_RESTRICTED=1 返回 1" "$?" "1"

MOCK_CONTAINER_RESTRICTED=0 xmg_detect_container_restricted
t_equals "MOCK_CONTAINER_RESTRICTED=0 返回 0" "$?" "0"

# 5.2 proc/mounts 挂载只读
printf 'proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0\nproc /proc/sys proc ro,relatime 0 0\n' > "$XMG_TMP/mounts_ro"
XMG_PROC_MOUNTS_FILE="$XMG_TMP/mounts_ro" xmg_detect_container_restricted
t_equals "只读 /proc/sys 挂载判定为受限容器 (返回 1)" "$?" "1"

# 5.3 CapEff 缺少 CAP_SYS_ADMIN (bit 21 = 0)
printf 'Name: bash\nCapEff:\t00000000a80425fb\n' > "$XMG_TMP/status_unpriv"
XMG_PROC_STATUS_FILE="$XMG_TMP/status_unpriv" XMG_PROC_MOUNTS_FILE="$XMG_TMP/nonexistent" xmg_detect_container_restricted
t_equals "缺少 CAP_SYS_ADMIN 判定为受限容器 (返回 1)" "$?" "1"

# 5.4 满特权宿主机环境 (rw 挂载且 CapEff 包含 bit 21)
printf 'proc /proc proc rw,relatime 0 0\n' > "$XMG_TMP/mounts_rw"
printf 'Name: bash\nCapEff:\t000001ffffffffff\n' > "$XMG_TMP/status_priv"
XMG_PROC_STATUS_FILE="$XMG_TMP/status_priv" XMG_PROC_MOUNTS_FILE="$XMG_TMP/mounts_rw" xmg_detect_container_restricted
t_equals "满特权环境返回 0" "$?" "0"

# --- 清理临时环境 ---
rm -rf "$XMG_TMP"
unset XMG_TMP _res
