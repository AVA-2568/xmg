#!/usr/bin/env bash
# 内核调优极低内存抗 OOM 与健康体检纠偏测试 (Task 6)
# shellcheck shell=bash

SRC="$TESTS_DIR/.."
XMG_TMP="$(mktemp -d)"

# 基础依赖加载
source "$SRC/lib/common.sh" 2>/dev/null || true
source "$SRC/lib/detect.sh" 2>/dev/null || true
source "$SRC/lib/tune.sh" 2>/dev/null || true
source "$SRC/lib/doctor.sh" 2>/dev/null || true

# ==================================================================
# 1. 验证标签规范
# ==================================================================
TUNE_CONTENT="$(cat "$SRC/lib/tune.sh")"
DETECT_CONTENT="$(cat "$SRC/lib/detect.sh")"
DOCTOR_CONTENT="$(cat "$SRC/lib/doctor.sh")"

t_contains "tune.sh 头部声明规范标签" "$TUNE_CONTENT" "# XMG_MENU_LABEL: 系统与网络调优"
t_contains "detect.sh 头部声明规范标签" "$DETECT_CONTENT" "# XMG_MENU_LABEL: 系统环境感知"
t_contains "doctor.sh 头部声明规范标签" "$DOCTOR_CONTENT" "# XMG_MENU_LABEL: 系统健康体检"

# ==================================================================
# 2. 验证 extreme_low (<=256MB) 档位抗 OOM 缓冲区与 tcp_mem
# ==================================================================
export XMG_TUNE_SYSCTL_NET_CONF="$XMG_TMP/99-xmg-tune.conf"
export XMG_TUNE_SYSCTL_SWAP_CONF="$XMG_TMP/99-xmg-swap.conf"
export XMG_TUNE_LIMITS_CONF="$XMG_TMP/99-xmg-nofile.conf"
export XMG_TUNE_SYSTEMD_LIMITS_CONF="$XMG_TMP/99-xmg-limits.conf"
export XMG_BACKUP_DIR="$XMG_TMP/backups"

# 覆盖交互与特权约束
xmg_require_root() { return 0; }
xmg_confirm() { return 0; }
sysctl() { return 0; }

# 2.1 extreme_low 档位下的网络缓冲收敛与 tcp_mem
export MOCK_MEM_TOTAL_MB=256
export MOCK_SWAP_TOTAL_MB=512
t_equals "256MB 识别为 extreme_low 档位" "$(xmg_tune_mem_profile 256)" "extreme_low"

xmg_tune_net_optimize >/dev/null 2>&1
NET_CONF="$(cat "$XMG_TUNE_SYSCTL_NET_CONF" 2>/dev/null || true)"

t_contains "extreme_low 下 rmem_max 收敛为 1MB" "$NET_CONF" "net.core.rmem_max = 1048576"
t_contains "extreme_low 下 wmem_max 收敛为 1MB" "$NET_CONF" "net.core.wmem_max = 1048576"
t_contains "extreme_low 下 tcp_rmem 尾部上限为 1MB" "$NET_CONF" "net.ipv4.tcp_rmem = 4096 87380 1048576"
t_contains "extreme_low 下 tcp_wmem 尾部上限为 1MB" "$NET_CONF" "net.ipv4.tcp_wmem = 4096 16384 1048576"
t_contains "extreme_low 下显式配置 net.ipv4.tcp_mem" "$NET_CONF" "net.ipv4.tcp_mem = 3072 4096 6144"
t_contains "extreme_low 挂载 Swap 时 swappiness 为 60" "$NET_CONF" "vm.swappiness = 60"

# 2.2 小内存无 Swap 时 swappiness 为 10
export MOCK_MEM_TOTAL_MB=256
export MOCK_SWAP_TOTAL_MB=0
xmg_tune_net_optimize >/dev/null 2>&1
NET_CONF_NOSWAP="$(cat "$XMG_TUNE_SYSCTL_NET_CONF" 2>/dev/null || true)"
t_contains "extreme_low 无 Swap 时 swappiness 保持 10" "$NET_CONF_NOSWAP" "vm.swappiness = 10"

# 2.3 高配机（带 Swap）swappiness 保持 10
export MOCK_MEM_TOTAL_MB=4096
export MOCK_SWAP_TOTAL_MB=2048
xmg_tune_net_optimize >/dev/null 2>&1
NET_CONF_HIGH="$(cat "$XMG_TUNE_SYSCTL_NET_CONF" 2>/dev/null || true)"
t_contains "高配机 swappiness 保持 10" "$NET_CONF_HIGH" "vm.swappiness = 10"
t_not_contains "高配机不写入 extreme_low 专用的低 tcp_mem" "$NET_CONF_HIGH" "net.ipv4.tcp_mem = 3072 4096 6144"

# ==================================================================
# 3. 验证 xmg_tune_sysctl_apply 退出码截断防溢出
# ==================================================================
# 构造包含 256 条配置的测试文件
SYSCTL_BIG="$XMG_TMP/big_sysctl.conf"
: > "$SYSCTL_BIG"
for i in $(seq 1 256); do
    echo "net.custom.param_$i = 1" >> "$SYSCTL_BIG"
done

# 模拟 sysctl 全量失败
sysctl() { return 1; }
xmg_tune_sysctl_apply "$SYSCTL_BIG" >/dev/null 2>&1
_rc=$?
t_equals "sysctl 失败 256 项退出码归一化为 1 而非截断溢出为 0" "$_rc" "1"

# ==================================================================
# 4. 验证 Btrfs Swap 创建前执行 chattr +C
# ==================================================================
export XMG_TUNE_SWAPFILE="$XMG_TMP/test_swapfile"
CHATTR_LOG="$XMG_TMP/chattr.log"
chattr() {
    echo "$*" > "$CHATTR_LOG"
    return 0
}
dd() { return 0; }
mkswap() { return 0; }
swapon() { return 0; }
xmg_tune_disk_avail_mb() { echo 5000; }
xmg_tune_fs_type() { echo "btrfs"; }

# 模拟输入 512M（避免管道子 shell 丢状态）
xmg_tune_swap_create <<< "512M" >/dev/null 2>&1
CHATTR_CALLED="$(cat "$CHATTR_LOG" 2>/dev/null || true)"
t_contains "Btrfs 创建 Swap 执行了 chattr +C 禁用 COW" "$CHATTR_CALLED" "+C"

# ==================================================================
# 5. 验证 detect.sh 排除 ULA IPv6 与 NAT64 超时兜底
# ==================================================================
unset MOCK_NET_IPV4 MOCK_NET_IPV6 MOCK_NET_NAT MOCK_NET_NAT64

# 5.1 排除虚拟网卡上的 IPv6
ip() {
    if [ "$1" = "-4" ]; then
        echo "1: lo: <LOOPBACK>"
        echo "    inet 127.0.0.1/8 scope host lo"
        echo "2: eth0: <BROADCAST,MULTICAST>"
        echo "    inet 192.168.1.100/24 scope global eth0"
    elif [ "$1" = "-6" ]; then
        echo "1: lo: <LOOPBACK>"
        echo "    inet6 ::1/128 scope host"
        echo "3: docker0: <BROADCAST,MULTICAST>"
        echo "    inet6 2001:db8:1::1/64 scope global"
    fi
}
xmg_detect_network
t_equals "仅 docker0 有 global IPv6 时应排除" "$XMG_NET_IPV6" "0"

# 5.2 排除 ULA 本地单播地址 (fc00::/7, fd00::/8)
ip() {
    if [ "$1" = "-4" ]; then
        echo "1: lo: <LOOPBACK>"
        echo "    inet 127.0.0.1/8 scope host lo"
        echo "2: eth0: <BROADCAST,MULTICAST>"
        echo "    inet 192.168.1.100/24 scope global eth0"
    elif [ "$1" = "-6" ]; then
        echo "1: lo: <LOOPBACK>"
        echo "    inet6 ::1/128 scope host"
        echo "2: eth0: <BROADCAST,MULTICAST>"
        echo "    inet6 fd12:3456:789a:1::1/64 scope global"
        echo "    inet6 fc00:abcd::1/64 scope global"
    fi
}
unset XMG_NET_IPV4 XMG_NET_IPV6 XMG_NET_NAT XMG_NET_NAT64
xmg_detect_network
t_equals "仅有 ULA (fd00::/8 或 fc00::/7) 时不能判定为公网 IPv6" "$XMG_NET_IPV6" "0"

# 5.3 真实公网 IPv6 地址正常识别
ip() {
    if [ "$1" = "-4" ]; then
        echo "2: eth0: <BROADCAST,MULTICAST>"
        echo "    inet 192.168.1.100/24 scope global eth0"
    elif [ "$1" = "-6" ]; then
        echo "2: eth0: <BROADCAST,MULTICAST>"
        echo "    inet6 2400:cb00:2048:1::c629:d7a2/64 scope global"
    fi
}
unset XMG_NET_IPV4 XMG_NET_IPV6 XMG_NET_NAT XMG_NET_NAT64
xmg_detect_network
t_equals "存在公网 IPv6 地址时正确识别" "$XMG_NET_IPV6" "1"

# 5.4 RFC 7050 具备 2 秒超时兜底
t_contains "detect.sh RFC 7050 主动探测具备 2 秒超时" "$DETECT_CONTENT" "timeout 2"

# ==================================================================
# 6. 验证 doctor.sh 真实展示 DNS 与新增体检项
# ==================================================================
# 6.1 验证 DoH 地址真实展示（不被无条件覆写为 1.1.1.1）
mkdir -p "$XMG_TMP/xray"
CUSTOM_CFG="$XMG_TMP/xray/config.json"
cat << 'CFG_EOF' > "$CUSTOM_CFG"
{
  "dns": {
    "servers": [
      "https+local://9.9.9.9/dns-query"
    ]
  },
  "routing": {
    "domainStrategy": "AsIs"
  }
}
CFG_EOF

DOCTOR_OUT="$(MOCK_VIRT="kvm" \
            MOCK_MEM_TOTAL_KB="1048576" \
            MOCK_NET_IPV4="1" \
            MOCK_NET_IPV6="1" \
            XMG_XRAY_CONFIG="$CUSTOM_CFG" \
            MOCK_XRAY_STATUS="running" \
            MOCK_XRAY_CONFIG_VALID="1" \
            MOCK_FIREWALL_STATUS="ufw (active)" \
            MOCK_SSH_PORT="2222" \
            MOCK_NTP_STATUS="已同步 (偏差: +1.2ms)" \
            xmg_doctor_run --dry-run 2>&1 || true)"

t_contains "doctor 真实展示配置中的 9.9.9.9 DoH 地址" "$DOCTOR_OUT" "https+local://9.9.9.9/dns-query"
t_not_contains "doctor 未被硬编码强行覆写为 1.1.1.1" "$DOCTOR_OUT" "https+local://1.1.1.1/dns-query"
t_contains "doctor 真实展示配置中的 domainStrategy" "$DOCTOR_OUT" "AsIs"

# 6.2 验证新增体检项：防火墙状态、真实 SSH 端口、NTP 时钟
t_contains "doctor 体检包含防火墙状态" "$DOCTOR_OUT" "防火墙"
t_contains "doctor 报告展示防火墙活跃信息" "$DOCTOR_OUT" "ufw (active)"
t_contains "doctor 体检包含 SSH 端口" "$DOCTOR_OUT" "SSH 端口"
t_contains "doctor 报告展示真实 SSH 端口 2222" "$DOCTOR_OUT" "2222"
t_contains "doctor 体检包含 NTP 时钟信息" "$DOCTOR_OUT" "NTP"
t_contains "doctor 报告展示时钟偏差" "$DOCTOR_OUT" "已同步 (偏差: +1.2ms)"

# 6.3 验证 Critical 联合判定规则
# 严重故障（时钟严重失步或显式严重故障）输出 CRITICAL 并返回 1
t_assert "严重故障时 doctor 判定为 1" bash -c '
    source "'"$SRC"'/lib/common.sh" 2>/dev/null || true
    source "'"$SRC"'/lib/detect.sh" 2>/dev/null || true
    source "'"$SRC"'/lib/doctor.sh" 2>/dev/null || true
    MOCK_DOCTOR_FAIL=1 xmg_doctor_run --dry-run >/dev/null 2>&1
    [ "$?" -eq 1 ]
'

# 清理临时文件
rm -rf "$XMG_TMP"
unset MOCK_MEM_TOTAL_MB MOCK_SWAP_TOTAL_MB MOCK_NET_IPV4 MOCK_NET_IPV6
