#!/usr/bin/env bash
# install.sh 与基础安全单元测试
# shellcheck shell=bash

SRC="$TESTS_DIR/.."
# shellcheck source=/dev/null
source "$SRC/install.sh"

# 在测试环境中拦截 die，避免在异常测试路径下直接退出测试进程
die() {
    return 1
}

# --- 1. manifest_entry_validate 测试 ---
is_manifest_entry_valid() {
    manifest_entry_validate "$1" >/dev/null 2>&1
}
is_manifest_entry_invalid() {
    ! manifest_entry_validate "$1" >/dev/null 2>&1
}

t_assert "合法清单项通过: xmg" is_manifest_entry_valid "xmg"
t_assert "合法清单项通过: lib/common.sh" is_manifest_entry_valid "lib/common.sh"
t_assert "合法清单项通过: xmg.files" is_manifest_entry_valid "xmg.files"
t_assert "合法清单项通过: templates/config.template.json" is_manifest_entry_valid "templates/config.template.json"

t_assert "拦截路径穿越 ../etc/passwd" is_manifest_entry_invalid "../etc/passwd"
t_assert "拦截路径穿越 lib/../xmg" is_manifest_entry_invalid "lib/../xmg"
t_assert "拦截路径穿越 dir/.." is_manifest_entry_invalid "dir/.."
t_assert "拦截根路径 /bin/sh" is_manifest_entry_invalid "/bin/sh"
t_assert "拦截根路径 /opt/xmg" is_manifest_entry_invalid "/opt/xmg"
t_assert "拦截空条目" is_manifest_entry_invalid ""
t_assert "拦截未知文件" is_manifest_entry_invalid "lib/foo.py"

# --- 2. manifest_entry_mode 测试 ---
# xmg 为 0755，其余为 0644
t_equals "manifest_entry_mode: xmg 为 0755" "$(manifest_entry_mode "xmg")" "0755"
t_equals "manifest_entry_mode: lib/common.sh 为 0644" "$(manifest_entry_mode "lib/common.sh")" "0644"
t_equals "manifest_entry_mode: xmg.files 为 0644" "$(manifest_entry_mode "xmg.files")" "0644"
t_equals "manifest_entry_mode: templates/config.template.json 为 0644" "$(manifest_entry_mode "templates/config.template.json")" "0644"

# --- 3. install_dirs 权限测试 ---
# 测试 install_dirs 在临时测试目录下创建的 etc 目录权限为 0700
TEST_TMP="$(mktemp -d)"
XMG_HOME="$TEST_TMP/opt/xmg"
XMG_BIN_DIR="$XMG_HOME/bin"
XMG_LIB_DIR="$XMG_HOME/lib"
XMG_ETC_DIR="$XMG_HOME/etc"
XMG_RUN_DIR="$XMG_HOME/run"
XMG_LOG_DIR="$XMG_HOME/log"
XMG_BACKUP_DIR="$XMG_HOME/backups"
XMG_XRAY_DIR="$XMG_HOME/xray"
XMG_LINK="$TEST_TMP/usr/local/bin/xmg"

CHMOD_CALLS=()
chmod() {
    CHMOD_CALLS+=("$*")
    command chmod "$@" 2>/dev/null || true
}

install_dirs

# 验证 install_dirs 调用 chmod 时对敏感目录赋予 700
_has_700_etc=0
_has_755_etc=0
for call in "${CHMOD_CALLS[@]}"; do
    if [[ "$call" == *"700"*"$XMG_ETC_DIR"* ]] || [[ "$call" == *"700"*"$XMG_ETC_DIR" ]]; then
        _has_700_etc=1
    fi
    if [[ "$call" == *"755"*"$XMG_ETC_DIR"* ]] || [[ "$call" == *"755"*"$XMG_ETC_DIR" ]]; then
        _has_755_etc=1
    fi
done

t_assert "install_dirs 对 etc 目录调用 chmod 700" [ "$_has_700_etc" -eq 1 ]
t_assert "install_dirs 未对 etc 目录调用 chmod 755" [ "$_has_755_etc" -eq 0 ]

# 如果当前文件系统支持 POSIX 权限位（如 Linux ext4），直接断言 stat 结果
: > "$TEST_TMP/perm.probe"
command chmod 600 "$TEST_TMP/perm.probe" 2>/dev/null || true
if [ "$(stat -c '%a' "$TEST_TMP/perm.probe" 2>/dev/null)" = "600" ]; then
    t_equals "文件系统 stat: etc 目录权限为 700" "$(stat -c '%a' "$XMG_ETC_DIR")" "700"
    t_equals "文件系统 stat: backups 目录权限为 700" "$(stat -c '%a' "$XMG_BACKUP_DIR")" "700"
    t_equals "文件系统 stat: xray 目录权限为 700" "$(stat -c '%a' "$XMG_XRAY_DIR")" "700"
fi

unset -f chmod
rm -rf "$TEST_TMP"

# --- 4. common.sh xmg_mkdirs 与 xmg_systemctl 及解耦测试 ---
# shellcheck source=/dev/null
source "$SRC/lib/common.sh"

TEST_TMP_COMMON="$(mktemp -d)"
XMG_ETC_DIR="$TEST_TMP_COMMON/etc"
XMG_RUN_DIR="$TEST_TMP_COMMON/run"
XMG_LOG_DIR="$TEST_TMP_COMMON/log"
XMG_BACKUP_DIR="$TEST_TMP_COMMON/backups"
XMG_XRAY_DIR="$TEST_TMP_COMMON/xray"

CHMOD_CALLS_MKDIRS=()
chmod() {
    CHMOD_CALLS_MKDIRS+=("$*")
    command chmod "$@" 2>/dev/null || true
}

xmg_mkdirs

t_not_contains "xmg_mkdirs 绝不使用 777" "${CHMOD_CALLS_MKDIRS[*]}" "777"
t_not_contains "xmg_mkdirs 绝不使用 666" "${CHMOD_CALLS_MKDIRS[*]}" "666"
t_contains "xmg_mkdirs 使用 0750 保护日志目录" "${CHMOD_CALLS_MKDIRS[*]}" "0750"
t_contains "xmg_mkdirs 使用 0640 保护日志文件" "${CHMOD_CALLS_MKDIRS[*]}" "0640"

unset -f chmod
rm -rf "$TEST_TMP_COMMON"

# 测试 xmg_systemctl 状态返回码在 set -e 下安全返回
systemctl() {
    return 3
}
_sub_rc=0
xmg_systemctl is-active fake-service >/dev/null 2>&1 || _sub_rc=$?
t_equals "xmg_systemctl is-active 正常返回退出码 3" "$_sub_rc" "3"
unset -f systemctl

# 验证 common.sh 解耦：不自动加载 doctor.sh 与 detect.sh
_leak_doc="$(bash -c "source '$SRC/lib/common.sh'; declare -F xmg_doctor || true")"
t_equals "common.sh 解耦：不反向加载 doctor.sh" "$_leak_doc" ""

_leak_det="$(bash -c "source '$SRC/lib/common.sh'; declare -F xmg_detect_os || true")"
t_equals "common.sh 解耦：不反向加载 detect.sh" "$_leak_det" ""

# 恢复 shell 状态，避免对后续用例造成影响
set +e
IFS=$' \t\n'
