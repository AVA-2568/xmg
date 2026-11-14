#!/usr/bin/env bash
# 单栈主机 + WARP 双栈后，DNS/出站策略自适应测试
#   - 纯 IPv6 主机 + WARP 全局接管 → UseIPv6 放开为 UseIP（否则 IPv4-only 站点不可达）
#   - 纯 IPv4 主机不受影响（本来就是 UseIP）
#   - WARP 分流模式不改全局策略
#   - 停用 WARP 后反向收回 UseIPv6
# shellcheck shell=bash

SRC="$TESTS_DIR/.."

T="$(mktemp -d)"

# 模拟 render.sh 在纯 IPv6 主机上的输出
mk_cfg() {
    cat > "$1" <<'JSON'
{
  "dns": { "queryStrategy": "UseIPv6" },
  "outbounds": [
    { "tag": "direct", "protocol": "freedom",
      "streamSettings": { "sockopt": { "domainStrategy": "UseIPv6" } } },
    { "tag": "warp-out", "protocol": "wireguard" }
  ]
}
JSON
}

run_relax() {
    local cfg="$1" mode="$2" stack="$3"
    XMG_LIB_DIR="$SRC/lib" XMG_HOME="$T" XMG_NET_STACK="$stack" \
        bash -c '
            source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
            source "$XMG_LIB_DIR/warp.sh" >/dev/null 2>&1
            _xmg_warp_relax_stack_strategy "$1" "$2" "172.16.0.2"
        ' _ "$cfg" "$mode" 2>&1
}

q_strategy() { grep -o '"queryStrategy": *"[^"]*"' "$1" 2>/dev/null | tr -d ' ' | head -1; }
d_strategy() { grep -o '"domainStrategy": *"[^"]*"' "$1" 2>/dev/null | tr -d ' ' | head -1; }

# --- 1. 纯 IPv6 主机 + 全局 WARP：放开为 UseIP ---
C1="$T/c1.json"; mk_cfg "$C1"
run_relax "$C1" global ipv6_only >/dev/null 2>&1
t_equals "纯 IPv6 + WARP 全局：DNS 策略放开为 UseIP" "$(q_strategy "$C1")" '"queryStrategy":"UseIP"'
t_equals "纯 IPv6 + WARP 全局：出站策略放开为 UseIP" "$(d_strategy "$C1")" '"domainStrategy":"UseIP"'

# --- 2. 纯 IPv4 主机：保持 UseIP（本来即正确，不得改成 UseIPv6） ---
C2="$T/c2.json"
printf '{"dns":{"queryStrategy":"UseIP"},"outbounds":[{"tag":"direct","protocol":"freedom","streamSettings":{"sockopt":{"domainStrategy":"UseIP"}}}]}\n' > "$C2"
run_relax "$C2" global ipv4_only >/dev/null 2>&1
t_equals "纯 IPv4 主机策略保持不变" "$(q_strategy "$C2")" '"queryStrategy":"UseIP"'

# --- 3. 双栈主机：不动 ---
C3="$T/c3.json"; mk_cfg "$C3"
run_relax "$C3" global dual >/dev/null 2>&1
t_equals "双栈主机策略不动" "$(q_strategy "$C3")" '"queryStrategy":"UseIPv6"'

# --- 4. 分流模式：不动全局策略（未命中 WARP 的流量仍需宿主机栈） ---
C4="$T/c4.json"; mk_cfg "$C4"
run_relax "$C4" routing ipv6_only >/dev/null 2>&1
t_equals "WARP 分流模式不改全局策略" "$(q_strategy "$C4")" '"queryStrategy":"UseIPv6"'

# --- 5. 停用 WARP：纯 IPv6 主机收回 UseIPv6 ---
C5="$T/c5.json"; mk_cfg "$C5"
run_relax "$C5" global ipv6_only >/dev/null 2>&1
t_equals "启用后为 UseIP" "$(q_strategy "$C5")" '"queryStrategy":"UseIP"'
XMG_LIB_DIR="$SRC/lib" XMG_HOME="$T" XMG_NET_STACK=ipv6_only \
    bash -c '
        source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
        source "$XMG_LIB_DIR/warp.sh" >/dev/null 2>&1
        _xmg_warp_restore_stack_strategy "$1"
    ' _ "$C5" >/dev/null 2>&1
t_equals "停用后 DNS 策略收回 UseIPv6" "$(q_strategy "$C5")" '"queryStrategy":"UseIPv6"'
t_equals "停用后出站策略收回 UseIPv6" "$(d_strategy "$C5")" '"domainStrategy":"UseIPv6"'


# --- 6. 无 jq 纯 Bash 兜底 + 紧凑 JSON（无空格）双向验证与权限保持 ---
NOJQ_BIN="$T/nojq_bin"
mkdir -p "$NOJQ_BIN"
# 仅放基础命令并屏蔽 jq
for _cmd in bash sh rm mv chmod cat printf dirname; do
    _p="$(command -v "$_cmd" 2>/dev/null || true)"
    [ -n "$_p" ] && ln -sf "$_p" "$NOJQ_BIN/$_cmd"
done

C6="$T/c6.json"
printf '{"dns":{"queryStrategy":"UseIPv6"},"outbounds":[{"tag":"direct","protocol":"freedom","streamSettings":{"sockopt":{"domainStrategy":"UseIPv6"}}}]}\n' > "$C6"
chmod 600 "$C6"
PATH="$NOJQ_BIN" XMG_LIB_DIR="$SRC/lib" XMG_HOME="$T" XMG_NET_STACK=ipv6_only \
    bash -c '
        source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
        source "$XMG_LIB_DIR/warp.sh" >/dev/null 2>&1
        _xmg_warp_relax_stack_strategy "$1" "global" "172.16.0.2"
    ' _ "$C6" >/dev/null 2>&1
t_equals "无 jq 紧凑 JSON 放开 queryStrategy 为 UseIP" "$(q_strategy "$C6")" '"queryStrategy":"UseIP"'
t_equals "无 jq 紧凑 JSON 放开 domainStrategy 为 UseIP" "$(d_strategy "$C6")" '"domainStrategy":"UseIP"'
t_equals "无 jq 替换后保持 600 权限" "$(stat -c '%a' "$C6" 2>/dev/null || echo 600)" "600"

PATH="$NOJQ_BIN" XMG_LIB_DIR="$SRC/lib" XMG_HOME="$T" XMG_NET_STACK=ipv6_only \
    bash -c '
        source "$XMG_LIB_DIR/common.sh" >/dev/null 2>&1
        source "$XMG_LIB_DIR/warp.sh" >/dev/null 2>&1
        _xmg_warp_restore_stack_strategy "$1"
    ' _ "$C6" >/dev/null 2>&1
t_equals "无 jq 紧凑 JSON 收回 queryStrategy 为 UseIPv6" "$(q_strategy "$C6")" '"queryStrategy":"UseIPv6"'
t_equals "无 jq 紧凑 JSON 收回 domainStrategy 为 UseIPv6" "$(d_strategy "$C6")" '"domainStrategy":"UseIPv6"'

rm -rf "$T"
