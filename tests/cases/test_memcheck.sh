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

unset MB _rc _mb CORE
rm -rf "$XMG_TMP"
unset XMG_TMP
