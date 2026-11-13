#!/usr/bin/env bash
# xmg selftest（安装一致性自检）测试
#   - 模块可独立加载、命令分派可用
#   - 未安装环境下返回非零并列出 FAIL
#   - 完整模拟安装环境下全部 PASS（含 OpenRC 分支）
# shellcheck shell=bash

SRC="$TESTS_DIR/.."

# --- 1. 独立加载 ---
_LOAD_RC=0
bash -c 'set -e; XMG_LIB_DIR="'"$SRC"'/lib"; source "'"$SRC"'/lib/selftest.sh"; declare -F xmg_selftest_run >/dev/null' \
    >/dev/null 2>&1 || _LOAD_RC=1
t_equals "selftest.sh 独立加载成功" "$_LOAD_RC" "0"

# --- 2. 命令分派与帮助 ---
# 显式指定 XMG_LIB_DIR：用例共享同一 shell，上文其他用例可能导出过
# XMG_LIB_DIR=/opt/xmg/lib（本机不存在），不指定会让入口直接 exit 1
_HELP_RC=0
XMG_LIB_DIR="$SRC/lib" bash "$SRC/xmg" selftest --help >/dev/null 2>&1 || _HELP_RC=1
t_equals "xmg selftest --help 退出码为 0" "$_HELP_RC" "0"

_BAD_RC=0
XMG_LIB_DIR="$SRC/lib" bash "$SRC/xmg" selftest --nonsense >/dev/null 2>&1 || _BAD_RC=$?
t_equals "xmg selftest 非法参数退出码为 2" "$_BAD_RC" "2"

# --- 3. 空环境：应报 FAIL 并返回 1 ---
T_EMPTY="$(mktemp -d)"
_EMPTY_OUT="$(XMG_HOME="$T_EMPTY" XMG_LIB_DIR="$SRC/lib" XMG_BIN="$T_EMPTY/bin/xmg" \
    XMG_RESOLV_CONF_FILE="$T_EMPTY/resolv.conf" \
    bash "$SRC/xmg" selftest 2>&1)"
_EMPTY_RC=$?
t_equals "空环境下自检返回 1" "$_EMPTY_RC" "1"
t_contains "空环境报告 FAIL 项" "$_EMPTY_OUT" "[FAIL]"
t_contains "输出包含汇总行" "$_EMPTY_OUT" "PASS="
rm -rf "$T_EMPTY"

# --- 4. 模拟完整安装：应全部 PASS ---
T_OK="$(mktemp -d)"
mkdir -p "$T_OK/bin" "$T_OK/etc/firewall" "$T_OK/initd" "$T_OK/binpath"

# 入口与清单
: > "$T_OK/bin/xmg"
cp "$SRC/xmg.files" "$T_OK/xmg.files"

# 内核与配置（stub 二进制：version 与 run -test 都返回 0）
cat > "$T_OK/xray-stub" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    version) echo "Xray 26.10.31 (stub)" ;;
esac
exit 0
STUB
chmod +x "$T_OK/xray-stub"
printf '{"inbounds":[]}\n' > "$T_OK/config.json"

# OpenRC 服务脚本（含 XMG 标记）
cat > "$T_OK/initd/xray" <<'INITD'
#!/sbin/openrc-run
# XMG 管理的 Xray OpenRC 服务脚本
export GOMEMLIMIT=64MiB
rc_ulimit="-n 1048576"
INITD

# rc-service / rc-update 桩
cat > "$T_OK/binpath/rc-service" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$T_OK/binpath/rc-update" <<'STUB'
#!/usr/bin/env bash
echo "              xray | default"
exit 0
STUB
chmod +x "$T_OK/binpath/rc-service" "$T_OK/binpath/rc-update"

printf 'nameserver 1.1.1.1\n' > "$T_OK/resolv.conf"

_OK_OUT="$(PATH="$T_OK/binpath:$PATH" MOCK_INIT=openrc \
    XMG_HOME="$T_OK" XMG_LIB_DIR="$SRC/lib" XMG_BIN="$T_OK/bin/xmg" \
    XMG_XRAY_BIN_OVERRIDE="$T_OK/xray-stub" XMG_XRAY_CONFIG="$T_OK/config.json" \
    XMG_INITD_DIR="$T_OK/initd" XMG_RESOLV_CONF_FILE="$T_OK/resolv.conf" \
    XMG_TUNE_SYSCTL_BBR_CONF="$T_OK/no-bbr.conf" \
    XMG_TUNE_SYSCTL_NET_CONF="$T_OK/no-net.conf" \
    XMG_TUNE_LIMITS_CONF="$T_OK/no-limits.conf" \
    bash "$SRC/xmg" selftest 2>&1)"
_OK_RC=$?
t_equals "模拟安装环境自检返回 0" "$_OK_RC" "0"
t_contains "识别到 OpenRC 服务脚本" "$_OK_OUT" "OpenRC 服务脚本存在"
t_contains "校验到内存抑制注入" "$_OK_OUT" "GOMEMLIMIT=64MiB"
t_contains "校验到 rc_ulimit 注入" "$_OK_OUT" "rc_ulimit"
t_contains "校验到运行级注册" "$_OK_OUT" "已加入默认运行级"
t_contains "校验到服务运行中" "$_OK_OUT" "服务运行中"
t_not_contains "无 FAIL 项" "$_OK_OUT" "[FAIL]"

rm -rf "$T_OK"

# --- 5. Alpine 仅装框架、内核未装：必须无 FAIL（回归） ---
# 历史问题：抬头在探测前打印，永远显示 unknown；
# 且内核缺失会让「内核/服务脚本/运行级」连刷 3 条 FAIL，掩盖真正的适配问题。
T_BARE="$(mktemp -d)"
mkdir -p "$T_BARE/bin"
: > "$T_BARE/bin/xmg"
cp "$SRC/xmg.files" "$T_BARE/xmg.files"
printf 'nameserver 1.1.1.1\n' > "$T_BARE/resolv.conf"

_BARE_OUT="$(MOCK_OS_ID=alpine MOCK_OS_PRETTY="Alpine Linux v3.21" MOCK_OS_VER=3.21 MOCK_INIT=openrc \
    XMG_HOME="$T_BARE" XMG_LIB_DIR="$SRC/lib" XMG_BIN="$T_BARE/bin/xmg" \
    XMG_RESOLV_CONF_FILE="$T_BARE/resolv.conf" \
    XMG_TUNE_SYSCTL_BBR_CONF="$T_BARE/no-bbr.conf" \
    XMG_TUNE_SYSCTL_NET_CONF="$T_BARE/no-net.conf" \
    XMG_TUNE_LIMITS_CONF="$T_BARE/no-limits.conf" \
    XMG_TUNE_UNBOUND_CONF="$T_BARE/no-unbound.conf" \
    bash "$SRC/xmg" selftest 2>&1)"
_BARE_RC=$?
t_equals "仅装框架（Alpine）自检返回 0" "$_BARE_RC" "0"
t_not_contains "仅装框架不产生 FAIL" "$_BARE_OUT" "[FAIL]"
t_contains "抬头显示发行版而非 unknown" "$_BARE_OUT" "发行版: Alpine Linux v3.21"
t_contains "抬头显示 init 而非 unknown" "$_BARE_OUT" "init: openrc"
t_contains "内核缺失给出安装指引" "$_BARE_OUT" "xmg core install"
t_contains "结论点明内核尚未安装" "$_BARE_OUT" "Xray 内核尚未安装"
t_contains "服务注册项降级为 WARN 而非 FAIL" "$_BARE_OUT" "跳过服务注册检查"

rm -rf "$T_BARE"
