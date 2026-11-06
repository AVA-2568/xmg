#!/usr/bin/env bash
# 卸载残留清理测试（跨发行版通用）
#   - 调优产物：sysctl.d / limits.d / system.conf.d / modules-load.d / resolved / journald
#   - OpenRC 的 /etc/modules 行与 /etc/sysctl.conf 标记块
#   - XMG 生成的 unbound 配置，以及被 unbound 接管后的 resolv.conf 回填
# 全部通过变量覆盖指向临时目录，不触碰真实 /etc。
# shellcheck shell=bash

SRC="$TESTS_DIR/.."

_RUN="$(bash -c '
    T="$(TMPDIR=/tmp mktemp -d)"
    mkdir -p "$T/sysctl.d" "$T/limits.d" "$T/system.conf.d" "$T/modules-load.d" "$T/unbound"

    for f in tune bbr swap; do echo "# XMG" > "$T/sysctl.d/99-xmg-$f.conf"; done
    echo "# XMG" > "$T/limits.d/99-xmg-nofile.conf"
    echo "# XMG" > "$T/system.conf.d/99-xmg-limits.conf"
    echo "tcp_bbr" > "$T/modules-load.d/xmg-bbr.conf"
    echo "# XMG: 加密 DNS DoT（由 xmg tune 生成，unbound 后端）" > "$T/unbound/unbound.conf"

    printf "tcp_bbr\nloop\n" > "$T/modules"
    printf "vm.swappiness = 10\n# >>> xmg:99-xmg-tune.conf >>>\nnet.core.somaxconn = 2048\n# <<< xmg:99-xmg-tune.conf <<<\nvm.dirty_ratio = 15\n" > "$T/sysctl.conf"
    printf "nameserver 127.0.0.1\nnameserver ::1\n" > "$T/resolv.conf"

    export XMG_LIB_DIR="'"$SRC"'/lib"
    export XMG_TUNE_SYSCTL_NET_CONF="$T/sysctl.d/99-xmg-tune.conf"
    export XMG_TUNE_SYSCTL_BBR_CONF="$T/sysctl.d/99-xmg-bbr.conf"
    export XMG_TUNE_SYSCTL_SWAP_CONF="$T/sysctl.d/99-xmg-swap.conf"
    export XMG_TUNE_LIMITS_CONF="$T/limits.d/99-xmg-nofile.conf"
    export XMG_TUNE_SYSTEMD_LIMITS_CONF="$T/system.conf.d/99-xmg-limits.conf"
    export XMG_TUNE_MODULES_LOAD_CONF="$T/modules-load.d/xmg-bbr.conf"
    export XMG_TUNE_RESOLVED_CONF="$T/resolved.conf.d/xmg-dns.conf"
    export XMG_MAINT_JOURNALD_CONF="$T/journald.conf.d/00-xmg.conf"
    export XMG_TUNE_UNBOUND_CONF="$T/unbound/unbound.conf"
    export XMG_TUNE_SWAPFILE="$T/no-such-swapfile"
    export XMG_MODULES_FILE="$T/modules"
    export XMG_TUNE_SYSCTL_MAIN_CONF="$T/sysctl.conf"
    export XMG_RESOLV_CONF_FILE="$T/resolv.conf"

    source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
    source "$XMG_LIB_DIR/uninstall.sh" >/dev/null 2>&1
    xmg_uninstall_cleanup_tune_artifacts >/dev/null 2>&1

    left=0
    for f in "$T/sysctl.d/99-xmg-tune.conf" "$T/sysctl.d/99-xmg-bbr.conf" \
             "$T/sysctl.d/99-xmg-swap.conf" "$T/limits.d/99-xmg-nofile.conf" \
             "$T/system.conf.d/99-xmg-limits.conf" "$T/modules-load.d/xmg-bbr.conf" \
             "$T/unbound/unbound.conf"; do
        [ -e "$f" ] && left=$((left + 1))
    done

    echo "LEFT=$left"
    echo "MODULES=$(tr "\n" "," < "$T/modules" 2>/dev/null)"
    echo "SYSCTL=$(tr "\n" "," < "$T/sysctl.conf" 2>/dev/null)"
    echo "RESOLV=$(tr "\n" "," < "$T/resolv.conf" 2>/dev/null)"
    rm -rf "$T"
' 2>/dev/null)"

_LEFT="$(printf '%s' "$_RUN" | sed -n 's/^LEFT=//p')"
_MODS="$(printf '%s' "$_RUN" | sed -n 's/^MODULES=//p')"
_SYSCTL="$(printf '%s' "$_RUN" | sed -n 's/^SYSCTL=//p')"
_RESOLV="$(printf '%s' "$_RUN" | sed -n 's/^RESOLV=//p')"

t_equals "卸载后 7 个调优产物全部清除" "${_LEFT:-unknown}" "0"
t_not_contains "已从 /etc/modules 移除 tcp_bbr" "$_MODS" "tcp_bbr"
t_contains "保留 /etc/modules 其他内容" "$_MODS" "loop"
t_not_contains "sysctl.conf 标记块已移除" "$_SYSCTL" ">>> xmg:"
t_contains "保留 sysctl.conf 用户原有配置" "$_SYSCTL" "vm.swappiness = 10"
t_contains "保留标记块之外的配置" "$_SYSCTL" "vm.dirty_ratio = 15"
t_not_contains "resolv.conf 不再指向已删除的 unbound" "$_RESOLV" "nameserver 127.0.0.1"
t_contains "resolv.conf 回填公共 DNS" "$_RESOLV" "nameserver 1.1.1.1"
