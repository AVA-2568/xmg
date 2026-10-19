#!/usr/bin/env bash
# shellcheck shell=bash
# 卸载安全保护与危险路径拦截测试

_TUS_SAVED_HOME="${XMG_HOME-}"
_TUS_SAVED_BIN="${XMG_BIN-}"
_TUS_SAVED_LINK="${XMG_LINK-}"
_TUS_SAVED_LIB="${XMG_LIB_DIR-}"
_TUS_SAVED_SYS_DIR="${XMG_SYSTEMD_DIR-}"

_TUS_TMP="$(mktemp -d)"
_TUS_ROOT="$_TUS_TMP/root"
mkdir -p "$_TUS_ROOT"

# 注意相对路径：tests/cases/ -> lib
SRC="$TESTS_DIR/../lib"

# 1. 模块自声明标签检查
_un_content="$(cat "$SRC/uninstall.sh")"
t_contains "uninstall.sh 包含标准自声明标签" "$_un_content" "# XMG_MENU_LABEL: 系统卸载清理"
t_not_contains "uninstall.sh 坚决禁止 rm -f 系统原生 xray.service" "$_un_content" 'rm -f "$xray_unit"'

# 加载 common.sh 与 uninstall.sh
# shellcheck source=/dev/null
source "$SRC/common.sh"
# shellcheck source=/dev/null
source "$SRC/uninstall.sh"

# 2. 危险路径拦截验证
# 验证空路径、根路径、过短路径(<=3)以及系统关键目录必须被拦截报错，绝不执行删除
for bad_path in "" "/" "//" "///" "/a" "/usr" "/etc" "/root" "/home" "/var" "/bin" "/boot" "/lib"; do
    _bad_rc=0
    xmg_uninstall_check_safe_home "$bad_path" >/dev/null 2>&1 || _bad_rc=$?
    t_assert "危险路径 '$bad_path' 应被安全拦截 (返回非0)" "[ $_bad_rc -ne 0 ]"
done

# 3. 卸载安全保护端到端测试：系统原生 unit 绝对不可被删除，仅清理自治资源
MOCK_LIB_SYS="$_TUS_ROOT/lib/systemd/system"
MOCK_USR_LIB_SYS="$_TUS_ROOT/usr/lib/systemd/system"
MOCK_ETC_SYS="$_TUS_ROOT/etc/systemd/system"

mkdir -p "$MOCK_LIB_SYS" "$MOCK_USR_LIB_SYS" "$MOCK_ETC_SYS/xray.service.d" "$MOCK_ETC_SYS/multi-user.target.wants"

# 创建原生 unit 文件（模拟 apt/dnf 系统原生包）
printf '[Unit]\nDescription=Native OS Xray Service in /lib\n' > "$MOCK_LIB_SYS/xray.service"
printf '[Unit]\nDescription=Native OS Xray Service in /usr/lib\n' > "$MOCK_USR_LIB_SYS/xray.service"

# 创建 XMG drop-in 与 warp service 及其自启链接
printf '[Service]\n# XMG dropin\n' > "$MOCK_ETC_SYS/xray.service.d/xmg.conf"
printf '[Unit]\nDescription=XMG Warp Service\n' > "$MOCK_ETC_SYS/xmg-warp.service"
ln -sf "$MOCK_ETC_SYS/xmg-warp.service" "$MOCK_ETC_SYS/multi-user.target.wants/xmg-warp.service"

# 创建 XMG 自治目录与软链接
MOCK_XMG_HOME="$_TUS_ROOT/opt/xmg"
mkdir -p "$MOCK_XMG_HOME/bin" "$MOCK_XMG_HOME/lib"
touch "$MOCK_XMG_HOME/bin/xmg" "$MOCK_XMG_HOME/lib/uninstall.sh"
MOCK_LINK="$_TUS_ROOT/usr/local/bin/xmg"
mkdir -p "$(dirname "$MOCK_LINK")"
ln -sf "$MOCK_XMG_HOME/bin/xmg" "$MOCK_LINK"

# 配置环境变量指向模拟目录
export XMG_HOME="$MOCK_XMG_HOME"
export XMG_BIN="$MOCK_XMG_HOME/bin/xmg"
export XMG_LINK="$MOCK_LINK"
export XMG_SYSTEMD_DIR="$MOCK_ETC_SYS"

# 执行卸载（使用 --yes 非交互参数）
xmg_uninstall_cli --yes >/dev/null 2>&1

# 断言：原生系统 unit 绝不能被删除
t_assert "系统 /lib/systemd/system/xray.service 原生 unit 保持完整未被删除" "[ -f '$MOCK_LIB_SYS/xray.service' ]"
t_assert "系统 /usr/lib/systemd/system/xray.service 原生 unit 保持完整未被删除" "[ -f '$MOCK_USR_LIB_SYS/xray.service' ]"

# 断言：XMG 自治资源被干净清理
t_assert "XMG 自治主目录已删除" "[ ! -d '$MOCK_XMG_HOME' ]"
t_assert "XMG 命令软链接已删除" "[ ! -e '$MOCK_LINK' ]"
t_assert "XMG drop-in 覆盖已清理" "[ ! -f '$MOCK_ETC_SYS/xray.service.d/xmg.conf' ]"
t_assert "xmg-warp.service 自身服务文件已清理" "[ ! -f '$MOCK_ETC_SYS/xmg-warp.service' ]"
t_assert "xmg-warp.service 自启软链接已清理" "[ ! -e '$MOCK_ETC_SYS/multi-user.target.wants/xmg-warp.service' ]"

# 4. 验证交互模式取消不删除任何文件
mkdir -p "$MOCK_XMG_HOME/bin"
touch "$MOCK_XMG_HOME/bin/xmg"
printf 'n\n' | xmg_uninstall_cli >/dev/null 2>&1 || true
t_assert "交互取消时不删除 XMG 目录" "[ -d '$MOCK_XMG_HOME' ]"

# 清理测试现场
rm -rf "$_TUS_TMP"
[ -n "$_TUS_SAVED_HOME" ] && export XMG_HOME="$_TUS_SAVED_HOME" || unset XMG_HOME
[ -n "$_TUS_SAVED_BIN" ] && export XMG_BIN="$_TUS_SAVED_BIN" || unset XMG_BIN
[ -n "$_TUS_SAVED_LINK" ] && export XMG_LINK="$_TUS_SAVED_LINK" || unset XMG_LINK
[ -n "$_TUS_SAVED_LIB" ] && export XMG_LIB_DIR="$_TUS_SAVED_LIB" || unset XMG_LIB_DIR
[ -n "$_TUS_SAVED_SYS_DIR" ] && export XMG_SYSTEMD_DIR="$_TUS_SAVED_SYS_DIR" || unset XMG_SYSTEMD_DIR
unset _TUS_SAVED_HOME _TUS_SAVED_BIN _TUS_SAVED_LINK _TUS_SAVED_LIB _TUS_SAVED_SYS_DIR
unset _TUS_TMP _TUS_ROOT _un_content _bad_rc MOCK_LIB_SYS MOCK_USR_LIB_SYS MOCK_ETC_SYS MOCK_XMG_HOME MOCK_LINK
