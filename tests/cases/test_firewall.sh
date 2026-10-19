#!/usr/bin/env bash
# 防火墙自适应放行与 CLI 非交互放行测试
# shellcheck shell=bash

FW_SRC="$TESTS_DIR/../lib/firewall.sh"
FW_CONTENT="$(cat "$FW_SRC")"

# --- 1. 自声明标签验证 ---
t_contains "firewall.sh 包含标准自声明标签" "$FW_CONTENT" "# XMG_MENU_LABEL: 防火墙管理"

# --- 2. 独立加载自包含性验证 ---
_RES_FW_LOAD="$(bash -c '
    SRC="'"$TESTS_DIR/.."'"
    XMG_HOME="$(mktemp -d)"
    XMG_LIB_DIR="$SRC/lib"
    export XMG_HOME XMG_LIB_DIR
    source "$XMG_LIB_DIR/firewall.sh" || exit 10
    
    # 依赖与自身关键函数应已定义
    declare -F xmg_firewall_allow_basic >/dev/null || exit 11
    declare -F xmg_firewall_allow_custom_port >/dev/null || exit 12
    declare -F xmg_firewall_fix_ipv6 >/dev/null || exit 13
    declare -F xmg_info >/dev/null || exit 14
    rm -rf "$XMG_HOME"
')"
_LOAD_RC=$?
t_equals "firewall.sh 独立加载自包含测试成功" "$_LOAD_RC" "0"

# --- 3. 自适应放行 SSH 端口防锁死测试 ---
TMP_FW_DIR="$(TMPDIR=/tmp mktemp -d)"
MOCK_LOG="$TMP_FW_DIR/ufw.log"
MOCK_BIN="$TMP_FW_DIR/bin"
MOCK_UFW_CONF="$TMP_FW_DIR/ufw_default"
mkdir -p "$MOCK_BIN"

# 创建 mock ufw
cat << 'MOCK_UFW' > "$MOCK_BIN/ufw"
#!/usr/bin/env bash
echo "$*" >> "$MOCK_UFW_LOG"
if [ "$1" = "status" ]; then
    echo "Status: active"
fi
exit 0
MOCK_UFW
chmod +x "$MOCK_BIN/ufw"

# 创建测试 ufw default 配置，初始化为 IPV6=no
cat << 'CONF' > "$MOCK_UFW_CONF"
# /etc/default/ufw
IPV6=no
DEFAULT_INPUT_POLICY="DROP"
DEFAULT_OUTPUT_POLICY="ACCEPT"
CONF

_SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"
export MOCK_UFW_LOG="$MOCK_LOG"
export XMG_UFW_DEFAULT_CONF="$MOCK_UFW_CONF"

# 运行测试：配置当前 SSH 端口为 2222
_SSH_ADAPT_OUT="$(bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export MOCK_UFW_LOG="'"$MOCK_LOG"'"
    export XMG_UFW_DEFAULT_CONF="'"$MOCK_UFW_CONF"'"
    source "'"$TESTS_DIR/../lib/firewall.sh"'"

    # mock root 权限和有效 ssh 端口为 2222
    xmg_require_root() { return 0; }
    xmg_ssh_effective() {
        if [ "$1" = "port" ]; then
            echo "2222"
            return 0
        fi
        echo "22"
    }

    xmg_firewall_allow_basic
')"
_ADAPT_RC=$?
t_equals "xmg_firewall_allow_basic 执行成功" "$_ADAPT_RC" "0"

_UFW_CALLS="$(cat "$MOCK_LOG" 2>/dev/null || true)"
t_contains "放行基础 22/tcp" "$_UFW_CALLS" "allow 22/tcp"
t_contains "放行基础 80/tcp" "$_UFW_CALLS" "allow 80/tcp"
t_contains "放行基础 443/tcp" "$_UFW_CALLS" "allow 443/tcp"
t_contains "自适应放行自定义 SSH 端口 2222/tcp" "$_UFW_CALLS" "allow 2222/tcp"
t_contains "输出包含自适应放行提示" "$_SSH_ADAPT_OUT" "2222"

# 验证标准 22 端口时不会多余放行 22/tcp 两次
: > "$MOCK_LOG"
bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export MOCK_UFW_LOG="'"$MOCK_LOG"'"
    export XMG_UFW_DEFAULT_CONF="'"$MOCK_UFW_CONF"'"
    source "'"$TESTS_DIR/../lib/firewall.sh"'"
    xmg_require_root() { return 0; }
    xmg_ssh_effective() { echo "22"; }
    xmg_firewall_allow_basic
' >/dev/null 2>&1
_UFW_CALLS_22="$(cat "$MOCK_LOG" 2>/dev/null || true)"
_COUNT_22="$(grep -c "allow 22/tcp" <<< "$_UFW_CALLS_22" || true)"
t_equals "标准 22 端口仅放行一次 22/tcp" "$_COUNT_22" "1"

# --- 4. 非交互式 CLI 传参放行测试 ---
: > "$MOCK_LOG"
bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export MOCK_UFW_LOG="'"$MOCK_LOG"'"
    source "'"$TESTS_DIR/../lib/firewall.sh"'"
    xmg_require_root() { return 0; }
    xmg_firewall_allow_custom_port 8443 udp
' >/dev/null 2>&1
_UFW_CALLS_CLI="$(cat "$MOCK_LOG" 2>/dev/null || true)"
t_contains "非交互放行 8443 udp" "$_UFW_CALLS_CLI" "allow 8443/udp"

: > "$MOCK_LOG"
bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export MOCK_UFW_LOG="'"$MOCK_LOG"'"
    source "'"$TESTS_DIR/../lib/firewall.sh"'"
    xmg_require_root() { return 0; }
    xmg_firewall_allow_custom_port 9000
' >/dev/null 2>&1
_UFW_CALLS_DEF_PROTO="$(cat "$MOCK_LOG" 2>/dev/null || true)"
t_contains "非交互放行 9000 默认 tcp" "$_UFW_CALLS_DEF_PROTO" "allow 9000/tcp"

# 非法端口拒绝
bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export MOCK_UFW_LOG="'"$MOCK_LOG"'"
    source "'"$TESTS_DIR/../lib/firewall.sh"'"
    xmg_require_root() { return 0; }
    xmg_firewall_allow_custom_port 70000
' >/dev/null 2>&1
_INVALID_PORT_RC=$?
t_assert "超出范围的端口应返回非零" [ "$_INVALID_PORT_RC" -ne 0 ]

# 非法协议拒绝
bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export MOCK_UFW_LOG="'"$MOCK_LOG"'"
    source "'"$TESTS_DIR/../lib/firewall.sh"'"
    xmg_require_root() { return 0; }
    xmg_firewall_allow_custom_port 8080 http
' >/dev/null 2>&1
_INVALID_PROTO_RC=$?
t_assert "不支持的协议应返回非零" [ "$_INVALID_PROTO_RC" -ne 0 ]

# --- 5. IPV6=yes 检查/纠偏测试 ---
_UFW_CONF_AFTER="$(cat "$MOCK_UFW_CONF" 2>/dev/null || true)"
t_contains "IPV6=no 被自动纠偏为 IPV6=yes" "$_UFW_CONF_AFTER" "IPV6=yes"
t_not_contains "不再残留 IPV6=no" "$_UFW_CONF_AFTER" "IPV6=no"
t_contains "保留原有其他配置项" "$_UFW_CONF_AFTER" 'DEFAULT_INPUT_POLICY="DROP"'

# 清理环境
export PATH="$_SAVED_PATH"
unset MOCK_UFW_LOG XMG_UFW_DEFAULT_CONF
rm -rf "$TMP_FW_DIR"