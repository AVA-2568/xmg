#!/usr/bin/env bash
# 安装前内存体检（Task 13）
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"

source "$TESTS_DIR/../lib/state.sh"
source "$TESTS_DIR/../lib/core.sh"
xmg_state_init

# ------------------------------------------------------------------
# 真实环境读取：成功则给出非负整数，失败则优雅返回非 0（不崩）
# ------------------------------------------------------------------
MB="$(xmg_mem_available_mb 2>/dev/null)"
_rc=$?
if [ "$_rc" -eq 0 ]; then
    t_assert "真实内存值为非负整数" bash -c "[[ '$MB' =~ ^[0-9]+$ ]]"
else
    t_equals "无内存信息时优雅返回非 0" "$_rc" "1"
fi

# ------------------------------------------------------------------
# MemAvailable 优先（用测试文件作为 seam，不依赖真机 /proc）
# ------------------------------------------------------------------
printf 'MemTotal: 2048 kB\nMemAvailable: 1048576 kB\n' > "$XMG_TMP/mi_avail"
_mb="$(XMG_MEMINFO_FILE="$XMG_TMP/mi_avail" xmg_mem_available_mb)"
t_equals "MemAvailable 优先并换算为 MB" "$_mb" "1024"

# ------------------------------------------------------------------
# 无 MemAvailable 时回退 MemFree+Buffers+Cached
# ------------------------------------------------------------------
printf 'MemTotal: 4096 kB\nMemFree: 1024 kB\nBuffers: 512 kB\nCached: 512 kB\n' > "$XMG_TMP/mi_free"
_mb="$(XMG_MEMINFO_FILE="$XMG_TMP/mi_free" xmg_mem_available_mb)"
t_equals "回退 MemFree+Buffers+Cached" "$_mb" "2"

# ------------------------------------------------------------------
# 无 /proc 且无 free：返回 1，绝不报错崩掉
# ------------------------------------------------------------------
XMG_MEMINFO_FILE="$XMG_TMP/no-such-meminfo" PATH=/nonexistent xmg_mem_available_mb >/dev/null 2>&1
t_equals "无 /proc 且无 free 时返回 1" "$?" "1"

# ------------------------------------------------------------------
# 无 /proc 但 free 可用：回退到 free -m（用桩函数模拟 free 输出）
# ------------------------------------------------------------------
# shellcheck disable=SC2317
free() {
    printf '%s\n' \
        '               total        used        free      shared  buff/cache   available' \
        'Mem:           1024         100         800           0         124         900'
}
_mb="$(XMG_MEMINFO_FILE="$XMG_TMP/no-such-meminfo" xmg_mem_available_mb 2>/dev/null)"
t_equals "无 /proc 时回退到 free" "$_mb" "900"
unset -f free

# ------------------------------------------------------------------
# 阈值判定：不足告警返回 1，充足返回 0（仅告警，不阻断安装）
# ------------------------------------------------------------------
printf 'MemTotal: 2048 kB\nMemAvailable: 102400 kB\n' > "$XMG_TMP/mi_low"
XMG_MEMINFO_FILE="$XMG_TMP/mi_low" XMG_MEM_CHECK_MB=999999 xmg_core_memcheck >/dev/null 2>&1
t_equals "内存低于阈值时返回 1" "$?" "1"

XMG_MEMINFO_FILE="$XMG_TMP/mi_low" XMG_MEM_CHECK_MB=1 xmg_core_memcheck >/dev/null 2>&1
t_equals "内存充足时返回 0" "$?" "0"

XMG_MEMINFO_FILE="$XMG_TMP/mi_low" xmg_core_memcheck 999999 >/dev/null 2>&1
t_equals "阈值可由参数覆盖" "$?" "1"

XMG_MEMINFO_FILE="$XMG_TMP/no-such-meminfo" PATH=/nonexistent xmg_core_memcheck >/dev/null 2>&1
t_equals "无法读取内存时不阻断（返回 0）" "$?" "0"

# ------------------------------------------------------------------
# 安装流程确实调用了体检，且不阻断（|| true）
# ------------------------------------------------------------------
CORE="$(cat "$TESTS_DIR/../lib/core.sh")"
t_contains "安装前调用内存体检且不阻断" "$CORE" 'xmg_core_memcheck || true'

# ==================================================================
# Task 6: 系统调优 Extreme-Low 215M 专属适配与容器安全
# ==================================================================
source "$TESTS_DIR/../lib/tune.sh"

# ------------------------------------------------------------------
# 1. 内存分档：extreme_low (<=256MB)
# ------------------------------------------------------------------
_prof_215="$(xmg_tune_mem_profile 215)"
t_equals "215MB 判定为 extreme_low 档位" "$_prof_215" "extreme_low"

_prof_256="$(xmg_tune_mem_profile 256)"
t_equals "256MB 边界判定为 extreme_low 档位" "$_prof_256" "extreme_low"

_prof_300="$(xmg_tune_mem_profile 300)"
t_equals "300MB 判定为 low 档位" "$_prof_300" "low"

# ------------------------------------------------------------------
# 2. extreme_low 专属网络参数生成
#    conntrack_max=8192, buf_max=4194304, tw_buckets=4096,
#    backlog=2048, syn_backlog=1024
# ------------------------------------------------------------------
CONF_TUNE="$XMG_TMP/test_tune_net.conf"
CONF_LIMITS="$XMG_TMP/test_tune_limits.conf"
CONF_SYSTEMD_LIMITS="$XMG_TMP/test_systemd_limits.conf"
MOCK_CONNTRACK="$XMG_TMP/mock_nf_conntrack_max"
printf '65536\n' > "$MOCK_CONNTRACK"

# 模拟环境以供 xmg_tune_net_optimize 生成配置
# shellcheck disable=SC2317
_orig_root="$(declare -f xmg_require_root || true)"
# shellcheck disable=SC2317
_orig_confirm="$(declare -f xmg_confirm || true)"
# shellcheck disable=SC2317
_orig_sysctl="$(declare -f sysctl || true)"

xmg_require_root() { return 0; }
xmg_confirm() { return 0; }
sysctl() { return 0; }

XMG_BACKUP_DIR="$XMG_TMP/backup" \
XMG_TUNE_SYSCTL_NET_CONF="$CONF_TUNE" \
XMG_TUNE_LIMITS_CONF="$CONF_LIMITS" \
XMG_TUNE_SYSTEMD_LIMITS_CONF="$CONF_SYSTEMD_LIMITS" \
XMG_TUNE_CONNTRACK_FILE="$MOCK_CONNTRACK" \
MOCK_MEM_TOTAL_MB=215 \
xmg_tune_net_optimize >/dev/null 2>&1

TUNE_NET_CONTENT="$(cat "$CONF_TUNE" 2>/dev/null || true)"
t_contains "extreme_low 档位标记" "$TUNE_NET_CONTENT" "内存档位: extreme_low"
t_contains "extreme_low conntrack_max=8192" "$TUNE_NET_CONTENT" "net.netfilter.nf_conntrack_max = 8192"
t_contains "extreme_low rmem_max=4194304" "$TUNE_NET_CONTENT" "net.core.rmem_max = 4194304"
t_contains "extreme_low wmem_max=4194304" "$TUNE_NET_CONTENT" "net.core.wmem_max = 4194304"
t_contains "extreme_low tcp_rmem 上限 4MB" "$TUNE_NET_CONTENT" "net.ipv4.tcp_rmem = 4096 87380 4194304"
t_contains "extreme_low tcp_wmem 上限 4MB" "$TUNE_NET_CONTENT" "net.ipv4.tcp_wmem = 4096 16384 4194304"
t_contains "extreme_low tw_buckets=4096" "$TUNE_NET_CONTENT" "net.ipv4.tcp_max_tw_buckets = 4096"
t_contains "extreme_low somaxconn=2048" "$TUNE_NET_CONTENT" "net.core.somaxconn = 2048"
t_contains "extreme_low netdev_max_backlog=2048" "$TUNE_NET_CONTENT" "net.core.netdev_max_backlog = 2048"
t_contains "extreme_low syn_backlog=1024" "$TUNE_NET_CONTENT" "net.ipv4.tcp_max_syn_backlog = 1024"

# ------------------------------------------------------------------
# 3. 容器环境 sysctl 熔断与容错机制
#    受限容器不可写参数静默跳过并友情提示，不报致命错误
# ------------------------------------------------------------------
SYSCTL_TEST_FILE="$XMG_TMP/test_sysctl.conf"
printf 'net.core.somaxconn = 2048\nnet.ipv4.tcp_rmem = 4096 87380 4194304\n' > "$SYSCTL_TEST_FILE"

# 模拟受限容器 (xmg_detect_container_restricted 返回 1)
xmg_detect_container_restricted() { return 1; }
# 模拟只读失败
sysctl() { return 1; }

_sc_rc=0
xmg_tune_sysctl_apply "$SYSCTL_TEST_FILE" >/dev/null 2>&1 || _sc_rc=$?
t_equals "受限容器下 sysctl 失败熔断保护平滑返回 0" "$_sc_rc" "0"

# 模拟非受限容器 (返回 0)，失败应正常返回失败计数 (非 0)
xmg_detect_container_restricted() { return 0; }
_sc_rc_normal=0
xmg_tune_sysctl_apply "$SYSCTL_TEST_FILE" >/dev/null 2>&1 || _sc_rc_normal=$?
t_assert "正常主机下 sysctl 失败应返回非 0 计数" [ "$_sc_rc_normal" -ne 0 ]

# ------------------------------------------------------------------
# 4. Swap 磁盘预检机制 (防打满)
# ------------------------------------------------------------------
# 可用空间不足 1200MB (例如 1000MB)，自动收缩至 256MB
_calc_size="$(XMG_MOCK_DISK_AVAIL_MB=1000 xmg_tune_swap_calc_size 1024 "$XMG_TMP/swapfile")"
t_equals "磁盘不足 1200MB 时 Swap 尺寸收缩为 256MB" "$_calc_size" "256"

# 可用空间极低 (例如 200MB < 300MB)，跳过创建返回非零
_calc_rc=0
XMG_MOCK_DISK_AVAIL_MB=200 xmg_tune_swap_calc_size 1024 "$XMG_TMP/swapfile" >/dev/null 2>&1 || _calc_rc=$?
t_assert "磁盘不足 300MB 时跳过创建 Swap" [ "$_calc_rc" -ne 0 ]

# 可用空间充裕 (5000MB)，保持 1024MB
_calc_ok="$(XMG_MOCK_DISK_AVAIL_MB=5000 xmg_tune_swap_calc_size 1024 "$XMG_TMP/swapfile")"
t_equals "磁盘充裕时保持请求的 Swap 尺寸" "$_calc_ok" "1024"

# ------------------------------------------------------------------
# 5. 受限容器中 swapon 失败平滑降级
# ------------------------------------------------------------------
SWAP_TEST_FILE="$XMG_TMP/test_swapfile"
XMG_TUNE_SWAPFILE="$SWAP_TEST_FILE"
XMG_MOCK_DISK_AVAIL_MB=5000

# 模拟容器内 swapon 被宿主机拒绝
# shellcheck disable=SC2317
swapon() { return 1; }
# shellcheck disable=SC2317
mkswap() { return 0; }
# shellcheck disable=SC2317
dd() { touch "$SWAP_TEST_FILE"; return 0; }

_swap_rc=0
printf '512M\n' | xmg_tune_swap_create >/dev/null 2>&1 || _swap_rc=$?
t_equals "受限容器 swapon 失败平滑返回 0 不中断" "$_swap_rc" "0"
t_assert "swapon 失败后已清理临时 swapfile" [ ! -f "$SWAP_TEST_FILE" ]

# 恢复桩函数与清理
eval "$_orig_root" 2>/dev/null || unset -f xmg_require_root
eval "$_orig_confirm" 2>/dev/null || unset -f xmg_confirm
eval "$_orig_sysctl" 2>/dev/null || unset -f sysctl
unset -f swapon mkswap dd xmg_detect_container_restricted

unset MB _rc _mb CORE _prof_215 _prof_256 _prof_300 CONF_TUNE CONF_LIMITS MOCK_CONNTRACK
unset TUNE_NET_CONTENT SYSCTL_TEST_FILE _sc_rc _sc_rc_normal _calc_size _calc_rc _calc_ok SWAP_TEST_FILE _swap_rc
rm -rf "$XMG_TMP"
unset XMG_TMP
