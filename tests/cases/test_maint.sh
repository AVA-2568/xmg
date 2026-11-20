#!/usr/bin/env bash
# lib/maint.sh 单元测试 — 验证 vnstat 零 fork 分支判断、磁盘概览、进程排查与菜单退出
# shellcheck shell=bash

_MAINT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset XMG_MAINT_SH_LOADED XMG_COMMON_SH_LOADED XMG_OS_SH_LOADED
# shellcheck source=/dev/null
source "$_MAINT_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$_MAINT_ROOT/lib/maint.sh"

t_assert "xmg_maint_vnstat 函数已加载" declare -F xmg_maint_vnstat
t_assert "xmg_maint_disk_overview 函数已加载" declare -F xmg_maint_disk_overview
t_assert "xmg_maint_process_inspect 函数已加载" declare -F xmg_maint_process_inspect
t_assert "xmg_maint_drop_caches 函数已加载" declare -F xmg_maint_drop_caches

# 1. 测试 xmg_maint_vnstat：初始化中（不区分大小写，零 fork 匹配 Not Enough / No Interface / Created）
_maint_out="$(
    xmg_require_root() { return 0; }
    xmg_cmd_exists() { [ "$1" = "vnstat" ]; }
    xmg_svc_supported() { return 1; }
    vnstat() { printf 'Not enough data available yet.\n'; }
    xmg_maint_vnstat 2>&1
)"
t_contains "vnstat 采样初始化文案命中" "$_maint_out" "采样库初始化中"

_maint_out2="$(
    xmg_require_root() { return 0; }
    xmg_cmd_exists() { [ "$1" = "vnstat" ]; }
    xmg_svc_supported() { return 1; }
    vnstat() { printf 'Database created for eth0\n'; }
    xmg_maint_vnstat 2>&1
)"
t_contains "vnstat created 分支命中初始化提示" "$_maint_out2" "采样库初始化中"

_maint_out3="$(
    xmg_require_root() { return 0; }
    xmg_cmd_exists() { [ "$1" = "vnstat" ]; }
    xmg_svc_supported() { return 1; }
    vnstat() { printf '2026-11   1.20 GiB | 2.30 GiB | 3.50 GiB\n'; }
    xmg_maint_vnstat 2>&1
)"
t_contains "vnstat 正常数据命中运行正常提示" "$_maint_out3" "vnstat 运行正常"

# 2. 测试 _xmg_maint_disk_line（正常返回非空字符串）
_disk_line="$(_xmg_maint_disk_line 2>/dev/null || true)"
t_assert "_xmg_maint_disk_line 正常执行不报错" test -n "$_disk_line"

# 3. 测试 xmg_maint_menu 输入 0 优雅退出
_menu_rc=0
(
    clear() { :; }
    xmg_maint_menu <<< "0" >/dev/null 2>&1
) || _menu_rc=$?
t_equals "xmg_maint_menu 输入 0 正常返回 0" "$_menu_rc" "0"
