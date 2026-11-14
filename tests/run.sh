#!/usr/bin/env bash
# 测试入口 — 用法: bash xmg/tests/run.sh [case_file...]
# shellcheck shell=bash
unset BASH_ENV ENV 2>/dev/null || true
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TESTS_DIR/.." || exit 1
# shellcheck source=lib.sh
source "$TESTS_DIR/lib.sh"

_RUN_ORIG_PATH="$PATH"
_RUN_ORIG_IFS="$IFS"
_RUN_ORIG_TMPDIR="$TMPDIR"

if [ "$#" -gt 0 ]; then
    CASES=("$@")
else
    CASES=("$TESTS_DIR"/cases/test_*.sh)
fi

if [ ! -d "$TESTS_DIR/cases" ]; then
    mkdir -p "$TESTS_DIR/cases"
fi

if [ ! -f "${CASES[0]}" ]; then
    printf '无用例可运行: %s\n' "$TESTS_DIR/cases" >&2
    exit 1
fi

for case_file in "${CASES[@]}"; do
    [ -f "$case_file" ] || continue
    printf '== %s ==\n' "$(basename "$case_file")" >&2

    # 恢复基础环境并清理前序用例导出的 XMG_* / MOCK_* 变量与模块加载守卫
    export PATH="$_RUN_ORIG_PATH"
    export TMPDIR="$_RUN_ORIG_TMPDIR"
    IFS="$_RUN_ORIG_IFS"
    unset LC_ALL 2>/dev/null || true

    for _xmg_g in "${!XMG_@}"; do
        unset "$_xmg_g" 2>/dev/null || true
    done
    for _mock_g in "${!MOCK_@}"; do
        unset "$_mock_g" 2>/dev/null || true
    done

    # 清理模块加载哨兵函数及前序用例可能覆写的全局桩函数，确保每个用例完整重加载所需模块
    unset -f xmg_svc_supported xmg_info xmg_warn xmg_error xmg_die xmg_color_init \
             xmg_state_init xmg_state_get xmg_render_config xmg_core_version xmg_core_install \
             xmg_detect_virt xmg_detect_mem_profile xmg_detect_mem_total_kb xmg_detect_mem_total_mb \
             xmg_detect_network xmg_detect_container_restricted \
             xmg_xray_gomemlimit xmg_xray_patch_systemd_unit xmg_service_active_read xmg_ssh_effective \
             sysctl dd mkswap swapon swapoff chattr ip curl systemctl rc-service rc-update \
             ufw iptables ip6tables fail2ban-client unbound chronyd ntpd vnstat \
             die xmg_require_root xmg_confirm _xmg_read xmg_pause 2>/dev/null || true

    # shellcheck source=/dev/null
    source "$case_file"

    # 若当前用例注册了 EXIT trap，立即执行清理并重置 trap，防止跨用例覆盖或遗留临时目录
    _case_exit_trap="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")"
    if [ -n "$_case_exit_trap" ]; then
        eval "$_case_exit_trap" 2>/dev/null || true
        trap - EXIT
    fi
done

rm -rf "$TESTS_DIR/.tmp" 2>/dev/null || true
t_summary
