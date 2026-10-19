#!/usr/bin/env bash
# SSH 安全加固、fail2ban 端口修复与 ssh.socket 适配测试
# shellcheck shell=bash

SSH_SRC="$TESTS_DIR/../lib/ssh.sh"
SSH_CONTENT="$(cat "$SSH_SRC")"

# --- 1. 自声明标签验证 ---
t_contains "ssh.sh 包含标准自声明标签" "$SSH_CONTENT" "# XMG_MENU_LABEL: SSH 安全加固"

TMP_SSH_DIR="$(TMPDIR=/tmp mktemp -d)"
MOCK_BIN="$TMP_SSH_DIR/bin"
MOCK_SYS_LOG="$TMP_SSH_DIR/systemctl.log"
MOCK_F2B_CONF="$TMP_SSH_DIR/jail.d/xmg-sshd.conf"
MOCK_SOCKET_CONF="$TMP_SSH_DIR/systemd/system/ssh.socket.d/listen.conf"
MOCK_SSHD_CONF="$TMP_SSH_DIR/sshd_config"
MOCK_DROPIN_CONF="$TMP_SSH_DIR/sshd_config.d/00-xmg-security.conf"
MOCK_KEYS="$TMP_SSH_DIR/authorized_keys"

mkdir -p "$MOCK_BIN" "$(dirname "$MOCK_F2B_CONF")" "$(dirname "$MOCK_SOCKET_CONF")" "$(dirname "$MOCK_DROPIN_CONF")"
touch "$MOCK_SSHD_CONF"

# mock apt-get, fail2ban-client, systemctl, sshd
cat << 'MOCK_APT' > "$MOCK_BIN/apt-get"
#!/usr/bin/env bash
exit 0
MOCK_APT
chmod +x "$MOCK_BIN/apt-get"

cat << 'MOCK_SYS' > "$MOCK_BIN/systemctl"
#!/usr/bin/env bash
echo "systemctl $*" >> "$MOCK_SYS_LOG"
if [ "$1" = "cat" ] && [ "$2" = "ssh.socket" ]; then
    [ "${MOCK_HAS_SOCKET:-0}" = "1" ] && exit 0 || exit 1
fi
exit 0
MOCK_SYS
chmod +x "$MOCK_BIN/systemctl"

cat << 'MOCK_F2B' > "$MOCK_BIN/fail2ban-client"
#!/usr/bin/env bash
exit 0
MOCK_F2B
chmod +x "$MOCK_BIN/fail2ban-client"

cat << 'MOCK_SSHD' > "$MOCK_BIN/sshd"
#!/usr/bin/env bash
if [ "$1" = "-t" ]; then
    exit 0
fi
if [ "$1" = "-T" ]; then
    cat << 'SSHD_T'
port 2222
passwordauthentication yes
permitrootlogin yes
SSHD_T
    exit 0
fi
exit 0
MOCK_SSHD
chmod +x "$MOCK_BIN/sshd"

_SAVED_PATH="$PATH"
export PATH="$MOCK_BIN:$PATH"
export MOCK_SYS_LOG="$MOCK_SYS_LOG"
export XMG_SSH_F2B_JAIL_CONF="$MOCK_F2B_CONF"
export XMG_SSH_SOCKET_DROPIN_CONF="$MOCK_SOCKET_CONF"
export XMG_SSH_CONFIG="$MOCK_SSHD_CONF"
export XMG_SSH_DROPIN_CONF="$MOCK_DROPIN_CONF"
export XMG_SSH_AUTH_KEYS="$MOCK_KEYS"

# --- 2. fail2ban 安装端口识别与 xmg_ssh_get_port 测试 ---
_F2B_OUT="$(bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export MOCK_SYS_LOG="'"$MOCK_SYS_LOG"'"
    export XMG_SSH_F2B_JAIL_CONF="'"$MOCK_F2B_CONF"'"
    source "'"$TESTS_DIR/../lib/ssh.sh"'"

    xmg_require_root() { return 0; }
    xmg_ssh_effective() {
        if [ "$1" = "port" ]; then
            echo "2222"
            return 0
        fi
        echo "22"
    }

    # 验证 xmg_ssh_get_port 函数存在并能获取当前端口 2222
    declare -F xmg_ssh_get_port >/dev/null || exit 20
    p="$(xmg_ssh_get_port)"
    [ "$p" = "2222" ] || exit 21

    xmg_ssh_fail2ban_install || exit 22
')"
_F2B_RC=$?
t_equals "fail2ban 安装且获取自定义端口 2222 成功" "$_F2B_RC" "0"

_F2B_CONF_CONTENT="$(cat "$MOCK_F2B_CONF" 2>/dev/null || true)"
t_contains "fail2ban 配置文件写入了自定义端口 2222" "$_F2B_CONF_CONTENT" "2222"
t_not_contains "fail2ban 未回退到默认 22" "$_F2B_CONF_CONTENT" "port = ssh,22"$'\n'

# --- 3. Ubuntu 22.10+ / 24.04 ssh.socket 适配测试 ---
: > "$MOCK_SYS_LOG"
_SOCKET_OUT="$(bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export MOCK_SYS_LOG="'"$MOCK_SYS_LOG"'"
    export MOCK_HAS_SOCKET=1
    export XMG_SSH_HAS_SOCKET=1
    export XMG_SSH_SOCKET_DROPIN_CONF="'"$MOCK_SOCKET_CONF"'"
    export XMG_SSH_CONFIG="'"$MOCK_SSHD_CONF"'"
    export XMG_SSH_DROPIN_CONF="'"$MOCK_DROPIN_CONF"'"
    source "'"$TESTS_DIR/../lib/ssh.sh"'"

    xmg_require_root() { return 0; }
    xmg_ssh_effective() {
        if [ "$1" = "port" ]; then
            echo "2222"
            return 0
        fi
        echo "22"
    }

    xmg_ssh_apply || exit 30
')"
_SOCKET_RC=$?
t_equals "ssh.socket 模式下 xmg_ssh_apply 成功" "$_SOCKET_RC" "0"

_SOCKET_CONF_CONTENT="$(cat "$MOCK_SOCKET_CONF" 2>/dev/null || true)"
t_contains "socket dropin 包含 [Socket]" "$_SOCKET_CONF_CONTENT" "[Socket]"
t_contains "socket dropin 包含 ListenStream= 重置" "$_SOCKET_CONF_CONTENT" "ListenStream="
t_contains "socket dropin 包含 ListenStream=2222" "$_SOCKET_CONF_CONTENT" "ListenStream=2222"

_SYS_LOG_CONTENT="$(cat "$MOCK_SYS_LOG" 2>/dev/null || true)"
t_contains "调用了 systemctl daemon-reload" "$_SYS_LOG_CONTENT" "systemctl daemon-reload"
t_contains "重启了 ssh.socket" "$_SYS_LOG_CONTENT" "systemctl restart ssh.socket"

# --- 4. 禁用密码登录安全检查测试 ---
# Case A: authorized_keys 不存在
rm -f "$MOCK_KEYS"
_NO_KEY_RC="$(bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export XMG_SSH_AUTH_KEYS="'"$MOCK_KEYS"'"
    source "'"$TESTS_DIR/../lib/ssh.sh"'"
    xmg_require_root() { return 0; }
    xmg_ssh_disable_password
' >/dev/null 2>&1 || echo $?)"
t_assert "authorized_keys 不存在时阻断禁用密码" [ "${_NO_KEY_RC:-0}" -ne 0 ]

# Case B: authorized_keys 为空文件
: > "$MOCK_KEYS"
_EMPTY_KEY_RC="$(bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export XMG_SSH_AUTH_KEYS="'"$MOCK_KEYS"'"
    source "'"$TESTS_DIR/../lib/ssh.sh"'"
    xmg_require_root() { return 0; }
    xmg_ssh_disable_password
' >/dev/null 2>&1 || echo $?)"
t_assert "authorized_keys 为空文件时阻断禁用密码" [ "${_EMPTY_KEY_RC:-0}" -ne 0 ]

# Case C: authorized_keys 仅包含注释和空行，无有效公钥
cat << 'KEYS_COMMENT' > "$MOCK_KEYS"
# This is a comment line
# ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC... user@disabled

KEYS_COMMENT
_COMMENT_KEY_RC="$(bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export XMG_SSH_AUTH_KEYS="'"$MOCK_KEYS"'"
    source "'"$TESTS_DIR/../lib/ssh.sh"'"
    xmg_require_root() { return 0; }
    xmg_ssh_disable_password
' >/dev/null 2>&1 || echo $?)"
t_assert "authorized_keys 仅有注释无有效公钥时阻断禁用密码" [ "${_COMMENT_KEY_RC:-0}" -ne 0 ]

# Case D: authorized_keys 包含有效公钥时允许加固
cat << 'KEYS_VALID' > "$MOCK_KEYS"
# Managed by admin
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGo4k9qQyI+b929837498729384729384729384 admin@workstation
KEYS_VALID

_VALID_KEY_RC="$(bash -c '
    export PATH="'"$MOCK_BIN"':$PATH"
    export XMG_SSH_AUTH_KEYS="'"$MOCK_KEYS"'"
    export XMG_SSH_CONFIG="'"$MOCK_SSHD_CONF"'"
    export XMG_SSH_DROPIN_CONF="'"$MOCK_DROPIN_CONF"'"
    source "'"$TESTS_DIR/../lib/ssh.sh"'"
    xmg_require_root() { return 0; }
    xmg_confirm() { return 0; }
    xmg_ssh_apply() { return 0; }
    xmg_ssh_disable_password
')"
_VALID_RC=$?
t_equals "存在有效公钥时允许禁用密码登录" "$_VALID_RC" "0"

# 清理环境
export PATH="$_SAVED_PATH"
unset MOCK_SYS_LOG XMG_SSH_F2B_JAIL_CONF XMG_SSH_SOCKET_DROPIN_CONF XMG_SSH_CONFIG XMG_SSH_DROPIN_CONF XMG_SSH_AUTH_KEYS
rm -rf "$TMP_SSH_DIR"