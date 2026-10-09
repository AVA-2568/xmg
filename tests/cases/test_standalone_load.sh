#!/usr/bin/env bash
# 模块独立加载与自包含依赖测试
# shellcheck shell=bash

SRC="$TESTS_DIR/.."

# --- 1. proxy.sh 独立加载自包含性验证 ---
_RES_PROXY="$(bash -c '
    SRC="'"$SRC"'"
    XMG_HOME="$(mktemp -d)"
    XMG_LIB_DIR="$SRC/lib"
    XMG_ETC_DIR="$XMG_HOME/etc"
    export XMG_HOME XMG_LIB_DIR XMG_ETC_DIR
    source "$XMG_LIB_DIR/common.sh"
    source "$XMG_LIB_DIR/proxy.sh"
    
    # 验证依赖函数自动可用
    declare -F xmg_render_config >/dev/null || exit 10
    declare -F xmg_state_init >/dev/null || exit 11
    declare -F xmg_core_version >/dev/null || exit 12

    # 执行 status 不崩且输出正确
    status_out="$(xmg_proxy_status)" || exit 13
    echo "$status_out"
    rm -rf "$XMG_HOME"
')"
_PROXY_RC=$?
t_equals "proxy.sh 独立加载并执行 status 成功" "$_PROXY_RC" "0"
t_contains "status 输出包含 SOCKS5 块" "$_RES_PROXY" "[SOCKS5]"
t_contains "status 输出包含内核块" "$_RES_PROXY" "[内核]"
t_not_contains "status 未安装时无重复拼接" "$_RES_PROXY" "Xray"

# --- 2. core.sh 独立加载自包含性验证 ---
_RES_CORE="$(bash -c '
    SRC="'"$SRC"'"
    XMG_HOME="$(mktemp -d)"
    XMG_LIB_DIR="$SRC/lib"
    XMG_ETC_DIR="$XMG_HOME/etc"
    export XMG_HOME XMG_LIB_DIR XMG_ETC_DIR
    source "$XMG_LIB_DIR/common.sh"
    source "$XMG_LIB_DIR/core.sh"
    
    # 验证 state 依赖已就绪
    declare -F xmg_state_get >/dev/null || exit 20
    declare -F xmg_state_set >/dev/null || exit 21

    # 执行 status 不崩且读取通道正常
    status_out="$(xmg_core_status)" || exit 22
    echo "$status_out"
    rm -rf "$XMG_HOME"
')"
_CORE_RC=$?
t_equals "core.sh 独立加载并执行 status 成功" "$_CORE_RC" "0"
t_contains "core status 输出包含内核通道" "$_RES_CORE" "内核通道: preview"

# --- 3. pipefail 环境下 xmg_core_version 无 SIGPIPE 退出码异常 ---
_RES_VERSION="$(bash -c '
    SRC="'"$SRC"'"
    set -o pipefail
    source "$SRC/lib/common.sh"
    source "$SRC/lib/core.sh"
    
    # 模拟一个多行输出的 mock xray 二进制
    tmp_bin="$(mktemp)"
    cat > "$tmp_bin" << "EOF"
#!/usr/bin/env bash
echo "Xray 26.9.30 (Xray, Penetrates Everything.) mock"
for i in {1..50}; do
    echo "mock padding line $i"
done
EOF
    chmod +x "$tmp_bin"
    eval "xmg_xray_binary() { printf \"%s\n\" \"$tmp_bin\"; }"
    
    ver="$(xmg_core_version)"
    rc=$?
    rm -f "$tmp_bin"
    echo "VER:$ver"
    exit $rc
')"
_VER_RC=$?
t_equals "pipefail 环境下 xmg_core_version 正常返回 0" "$_VER_RC" "0"
t_contains "正确取得首行版本" "$_RES_VERSION" "VER:Xray 26.9.30"

# --- 4. ssh.sh fail2ban jail 配置生成验证 ---
_RES_F2B="$(bash -c '
    SRC="'"$SRC"'"
    tmp_conf="$(mktemp)"
    export XMG_SSH_F2B_JAIL_CONF="$tmp_conf"
    source "$SRC/lib/ssh.sh"
    
    # 测试自定义端口 2222 和 systemd 后端
    _xmg_ssh_write_f2b_conf "systemd" "2222"
    conf_content="$(cat "$tmp_conf")"
    echo "---CONF1---"
    echo "$conf_content"
    
    # 测试 auto 后端与 auth.log 关联
    tmp_auth="$(mktemp)"
    # 模拟环境存在 /var/log/auth.log
    (
        _xmg_ssh_write_f2b_conf "auto" "22"
    )
    conf_content2="$(cat "$tmp_conf")"
    echo "---CONF2---"
    echo "$conf_content2"
    rm -f "$tmp_conf" "$tmp_auth"
')"
t_contains "fail2ban jail 配置含自定义端口" "$_RES_F2B" "port = ssh,2222"
t_contains "fail2ban jail 配置含 systemd 后端" "$_RES_F2B" "backend = systemd"
t_contains "fail2ban jail 配置含 auto 后端" "$_RES_F2B" "backend = auto"
