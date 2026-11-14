#!/usr/bin/env bash
# 服务硬重启（stop → 等退出 → start → 等 active）测试
#   覆盖两种真实故障场景：
#     1) 服务已停止时 restart 不会拉起 → 必须 start
#     2) 停得太快导致端口未释放 → 必须等进程真正退出再 start
# shellcheck shell=bash

SRC="$TESTS_DIR/.."

T="$(mktemp -d)"
mkdir -p "$T/bin"
LOG="$T/actions.log"
: > "$LOG"

# rc-service 桩：用标记文件模拟进程存活
cat > "$T/bin/rc-service" <<STUB
#!/bin/sh
flag="$T/alive_\$1"
case "\$2" in
    status) [ -f "\$flag" ] && exit 0 || exit 3 ;;
    stop)   rm -f "\$flag"; echo "stop \$1" >> "$LOG"; exit 0 ;;
    start)  : > "\$flag";   echo "start \$1" >> "$LOG"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/rc-service"

# --- 1. 服务处于停止状态：必须被拉起 ---
_OUT1="$(PATH="$T/bin:$PATH" MOCK_INIT=openrc XMG_LIB_DIR="$SRC/lib" \
    bash -c '
        source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
        source "$XMG_LIB_DIR/os.sh" >/dev/null 2>&1
        xmg_svc_restart_verified xray 3
        echo "rc=$?"
    ' 2>&1)"
t_contains "停止态服务被重新拉起（返回 0）" "$_OUT1" "rc=0"
t_equals "停止态时只执行 start" "$(grep -c '^start xray$' "$LOG")" "1"
t_equals "停止态时未执行 stop" "$(grep -c '^stop xray$' "$LOG")" "0"

# --- 2. 服务运行中：必须先 stop 再 start，且顺序正确 ---
: > "$LOG"
: > "$T/alive_xray"
_OUT2="$(PATH="$T/bin:$PATH" MOCK_INIT=openrc XMG_LIB_DIR="$SRC/lib" \
    bash -c '
        source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
        source "$XMG_LIB_DIR/os.sh" >/dev/null 2>&1
        xmg_svc_restart_verified xray 3
        echo "rc=$?"
    ' 2>&1)"
t_contains "运行态重启返回 0" "$_OUT2" "rc=0"
t_equals "运行态先 stop 后 start" "$(tr '\n' ',' < "$LOG")" "stop xray,start xray,"

# --- 3. 服务始终无法启动：返回 1（交由上层回滚） ---
cat > "$T/bin/rc-service" <<'STUB'
#!/bin/sh
case "$2" in
    status) exit 3 ;;
    stop)   exit 0 ;;
    start)  exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/rc-service"

_OUT3="$(PATH="$T/bin:$PATH" MOCK_INIT=openrc XMG_LIB_DIR="$SRC/lib" \
    bash -c '
        source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
        source "$XMG_LIB_DIR/os.sh" >/dev/null 2>&1
        xmg_svc_restart_verified xray 1
        echo "rc=$?"
    ' 2>&1)"
t_contains "启动后始终非 active 时返回 1" "$_OUT3" "rc=1"

# --- 4. 无服务管理器时返回 2（不误判为成功） ---
_OUT4="$(MOCK_INIT=none XMG_LIB_DIR="$SRC/lib" bash -c '
    source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
    source "$XMG_LIB_DIR/os.sh" >/dev/null 2>&1
    xmg_svc_restart_verified xray 1
    echo "rc=$?"
' 2>&1)"
t_contains "无 init 时返回 2" "$_OUT4" "rc=2"

rm -rf "$T"
