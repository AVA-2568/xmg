#!/usr/bin/env bash
# 远程 VPS 一键健康诊断工具测试 (Task 7)
# shellcheck shell=bash

SRC="$TESTS_DIR/.."
FILES="$SRC/xmg.files"
MAIN="$SRC/xmg"

# source common.sh 会把 XMG_HOME/XMG_LIB_DIR 补成 /opt/xmg 并 export，
# 必须在加载任何 lib 之前记下真实初始值，供用例结束时还原。
_TE_PRE_HOME="${XMG_HOME-}"
_TE_PRE_LIB="${XMG_LIB_DIR-}"

# --- 1. 清单与模块定义检查 ---
t_contains "xmg.files 清单包含 lib/doctor.sh" "$(cat "$FILES")" "lib/doctor.sh"
t_assert "lib/doctor.sh 文件存在" test -f "$SRC/lib/doctor.sh"

# 加载依赖库
if [ -f "$SRC/lib/common.sh" ]; then
    # shellcheck source=/dev/null
    source "$SRC/lib/common.sh"
fi
if [ -f "$SRC/lib/detect.sh" ]; then
    # shellcheck source=/dev/null
    source "$SRC/lib/detect.sh"
fi
if [ -f "$SRC/lib/system.sh" ]; then
    # shellcheck source=/dev/null
    source "$SRC/lib/system.sh"
fi
if [ -f "$SRC/lib/doctor.sh" ]; then
    # shellcheck source=/dev/null
    source "$SRC/lib/doctor.sh"
fi

t_equals "XMG_DOCTOR_SH_LOADED 哨兵变量应为 1" "${XMG_DOCTOR_SH_LOADED:-0}" "1"
t_assert "定义 xmg_doctor_run 函数" declare -F xmg_doctor_run
t_assert "定义 xmg_doctor_cli 函数" declare -F xmg_doctor_cli
t_assert "定义 xmg_doctor_menu 函数" declare -F xmg_doctor_menu

# --- 2. 菜单与入口挂载扫描 ---
t_assert "doctor.sh 声明菜单标签" grep -q "XMG_MENU_LABEL:" "$SRC/lib/doctor.sh"
t_contains "xmg usage 包含 doctor" "$(XMG_HOME="$SRC" XMG_LIB_DIR="$SRC/lib" bash "$MAIN" help 2>&1 || true)" "xmg doctor"

# 验证 menu.sh 模块发现
_TE_SAVED_HOME="${XMG_HOME-}"
_TE_SAVED_LIB_DIR="${XMG_LIB_DIR-}"
export XMG_HOME="$SRC"
export XMG_LIB_DIR="$SRC/lib"
# shellcheck source=/dev/null
source "$SRC/lib/menu.sh"
xmg_menu_discover_modules
_MENU_FUNCS="$(printf '%s\n' "${XMG_MENU_FUNCS[@]}")"
t_contains "menu 静态扫描发现 doctor 菜单" "$_MENU_FUNCS" "xmg_doctor_menu"
export XMG_HOME="$_TE_SAVED_HOME"
export XMG_LIB_DIR="$_TE_SAVED_LIB_DIR"

# --- 3. 诊断报告卡片输出格式覆盖 ---
# 在 mock 环境下运行 xmg_doctor_run
_OUT="$(MOCK_VIRT="kvm" \
        MOCK_MEM_TOTAL_KB="1048576" \
        MOCK_CONTAINER_RESTRICTED="0" \
        MOCK_NET_IPV4="1" \
        MOCK_NET_IPV6="1" \
        MOCK_NET_NAT="0" \
        MOCK_NET_NAT64="0" \
        MOCK_XRAY_VERSION="Xray 1.8.24 (Xray, Penetrates Everything.)" \
        MOCK_XRAY_STATUS="running" \
        MOCK_XRAY_CONFIG_VALID="1" \
        MOCK_GOMEMLIMIT="100MiB" \
        MOCK_BBR_STATUS="bbr" \
        MOCK_QDISC_STATUS="fq" \
        xmg_doctor_run --dry-run 2>&1 || true)"

# 3.1 [环境]
t_contains "诊断输出包含 [环境] 标识" "$_OUT" "[环境]"
t_contains "诊断输出包含虚拟化架构 kvm" "$_OUT" "kvm"
t_contains "诊断输出包含内存阶梯分档 mid" "$_OUT" "mid"
t_contains "诊断输出包含容器特权状态 (正常/特权)" "$_OUT" "特权"

# 3.2 [网络]
t_contains "诊断输出包含 [网络] 标识" "$_OUT" "[网络]"
t_contains "诊断输出包含 IPv4 状态" "$_OUT" "IPv4"
t_contains "诊断输出包含 IPv6 状态" "$_OUT" "IPv6"
t_contains "诊断输出包含 NAT 状态" "$_OUT" "NAT"
t_contains "诊断输出包含 NAT64 状态" "$_OUT" "NAT64"

# 3.3 [资源]
t_contains "诊断输出包含 [资源] 标识" "$_OUT" "[资源]"
t_contains "诊断输出包含内存信息" "$_OUT" "内存"
t_contains "诊断输出包含 Swap 信息" "$_OUT" "Swap"

# 3.4 [内核]
t_contains "诊断输出包含 [内核] 标识" "$_OUT" "[内核]"
t_contains "诊断输出包含 BBR 拥塞控制" "$_OUT" "bbr"
t_contains "诊断输出包含队列算法 fq" "$_OUT" "fq"
t_contains "诊断输出包含 TCP 缓冲" "$_OUT" "TCP 缓冲"
t_contains "诊断输出包含连接跟踪" "$_OUT" "连接跟踪"

# 3.5 [Xray]
t_contains "诊断输出包含 [Xray] 标识" "$_OUT" "[Xray]"
t_contains "诊断输出包含版本信息" "$_OUT" "Xray 1.8.24"
t_contains "诊断输出包含运行状态" "$_OUT" "running"
t_contains "诊断输出包含配置校验 OK" "$_OUT" "配置校验: OK"
t_contains "诊断输出包含 GOMEMLIMIT 内存抑制" "$_OUT" "100MiB"
t_contains "诊断输出包含监听端口" "$_OUT" "监听端口"

# 3.5.1 机型变更后落盘 Go 参数过期必须告警
_DRIFT_OUT="$(MOCK_VIRT="kvm" \
        MOCK_MEM_TOTAL_KB="4194304" \
        MOCK_CPU_CORES="8" \
        MOCK_CONTAINER_RESTRICTED="0" \
        MOCK_NET_IPV4="1" \
        MOCK_NET_IPV6="1" \
        MOCK_NET_NAT="0" \
        MOCK_NET_NAT64="0" \
        MOCK_GOMEMLIMIT="32MiB" \
        MOCK_GOMAXPROCS="1" \
        xmg_doctor_run --dry-run 2>&1 || true)"
t_contains "Go 参数与当前机型不匹配时给出过期提示" "$_DRIFT_OUT" "Go 参数已过期"
t_contains "过期提示包含期望参数值" "$_DRIFT_OUT" "150MiB"
t_contains "诊断输出包含证书状态" "$_OUT" "证书:"

# 3.6 [DNS]
t_contains "诊断输出包含 [DNS] 标识" "$_OUT" "[DNS]"
t_contains "诊断输出包含内置 DoH" "$_OUT" "DoH"
t_contains "诊断输出包含出站解析模式" "$_OUT" "UseIP"
t_contains "诊断输出包含 DoH 延迟评级" "$_OUT" "延迟:"

# --- 4. 纯 IPv6 环境自适应测试 ---
_OUT_V6="$(MOCK_VIRT="lxc" \
           MOCK_MEM_TOTAL_KB="220160" \
           MOCK_CONTAINER_RESTRICTED="1" \
           MOCK_NET_IPV4="0" \
           MOCK_NET_IPV6="1" \
           MOCK_NET_NAT="0" \
           MOCK_NET_NAT64="1" \
           MOCK_XRAY_STATUS="stopped" \
           MOCK_XRAY_CONFIG_VALID="1" \
           xmg_doctor_run --dry-run 2>&1 || true)"
t_contains "v6 单栈下内存档为 extreme_low" "$_OUT_V6" "extreme_low"
t_contains "受限容器显示受限提示" "$_OUT_V6" "受限"
t_contains "v6 出站解析模式为 UseIPv6" "$_OUT_V6" "UseIPv6"

# --- 5. 退出码契约测试 (0 正常，1 严重故障) ---
# 5.1 正常环境退出码为 0
MOCK_VIRT="kvm" \
MOCK_MEM_TOTAL_KB="1048576" \
MOCK_CONTAINER_RESTRICTED="0" \
MOCK_NET_IPV4="1" \
MOCK_NET_IPV6="1" \
MOCK_XRAY_CONFIG_VALID="1" \
t_assert "正常诊断返回码为 0" xmg_doctor_run --dry-run

# 5.2 严重故障（配置校验失败或显式 MOCK 故障）退出码为 1
t_assert "配置校验失败时返回码为 1" bash -c '
    source "'"$SRC"'/lib/common.sh" 2>/dev/null || true
    source "'"$SRC"'/lib/detect.sh" 2>/dev/null || true
    source "'"$SRC"'/lib/doctor.sh" 2>/dev/null || true
    MOCK_XRAY_CONFIG_VALID=0 xmg_doctor_run --dry-run >/dev/null 2>&1
    [ "$?" -eq 1 ]
'

t_assert "严重故障显式模拟时返回码为 1" bash -c '
    source "'"$SRC"'/lib/common.sh" 2>/dev/null || true
    source "'"$SRC"'/lib/detect.sh" 2>/dev/null || true
    source "'"$SRC"'/lib/doctor.sh" 2>/dev/null || true
    MOCK_DOCTOR_FAIL=1 xmg_doctor_run --dry-run >/dev/null 2>&1
    [ "$?" -eq 1 ]
'

# --- 6. CLI 端到端调用验证 ---
t_assert "xmg doctor --dry-run CLI 返回 0" env XMG_HOME="$SRC" XMG_LIB_DIR="$SRC/lib" MOCK_XRAY_CONFIG_VALID=1 bash "$MAIN" doctor --dry-run

# --- 7. Task 4 回归：证书检测与 DoH 延迟接口单元测试 ---
t_assert "定义 _xmg_doctor_get_cert_status 函数" declare -F _xmg_doctor_get_cert_status
t_assert "定义 _xmg_doctor_get_doh_latency 函数" declare -F _xmg_doctor_get_doh_latency

t_equals "MOCK_CERT_STATUS 正常生效" "$(MOCK_CERT_STATUS="有效 (剩余 85 天)" _xmg_doctor_get_cert_status)" "有效 (剩余 85 天)"
t_equals "MOCK_DOH_LATENCY 正常生效" "$(MOCK_DOH_LATENCY="42ms (优秀)" _xmg_doctor_get_doh_latency)" "42ms (优秀)"
t_equals "测试模式下 DoH 延迟默认短路返回" "$(XMG_TEST_MODE=1 _xmg_doctor_get_doh_latency)" "35ms (优秀)"

# --- 8. Alpine 回归：证书有效期不得依赖 GNU date ---
# BusyBox date -d 解析不了 openssl 的 "Nov  7 13:49:17 2026 GMT"，
# 旧实现会把有效证书算成 "已过期"。改为 openssl -checkend 后与平台无关。
T_CERT="$(TMPDIR=/tmp mktemp -d)"
mkdir -p "$T_CERT/etc/xray/certs"
if command -v openssl >/dev/null 2>&1; then
    # 用配置文件写主题，避免 -subj "/CN=..." 在 Git Bash 下被当成路径改写
    cat > "$T_CERT/req.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = xmg.test
[v3]
basicConstraints = CA:TRUE
CNF
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$T_CERT/key.pem" \
        -out "$T_CERT/etc/xray/certs/fullchain.crt" \
        -days 365 -config "$T_CERT/req.cnf" >/dev/null 2>&1 || true
    t_assert "生成 365 天有效期的测试证书" test -s "$T_CERT/etc/xray/certs/fullchain.crt"
    _CERT_ST="$(XMG_HOME="$T_CERT" _xmg_doctor_get_cert_status 2>/dev/null || true)"
    t_contains "有效证书判定为有效" "$_CERT_ST" "有效"
    t_not_contains "有效证书不被误判为已过期" "$_CERT_ST" "已过期"
    t_equals "剩余天数四舍五入到 364 天左右" "$(XMG_HOME="$T_CERT" _xmg_doctor_cert_days_left "$T_CERT/etc/xray/certs/fullchain.crt" 2>/dev/null | awk '{print ($1 >= 360 && $1 <= 366) ? "ok" : "bad"}')" "ok"
fi
rm -rf "$T_CERT"

# --- 9. 无配置时「配置校验」显示未配置，而不是 OK ---
T_NOCFG="$(TMPDIR=/tmp mktemp -d)"
_NOCFG_RC=0
XMG_XRAY_CONFIG="$T_NOCFG/none.json" _xmg_doctor_validate_xray_config || _NOCFG_RC=$?
t_equals "无配置文件时校验接口返回 2（未配置）" "$_NOCFG_RC" "2"

_NOCFG_OUT="$(XMG_XRAY_CONFIG="$T_NOCFG/none.json" \
    MOCK_XRAY_VERSION="未安装" MOCK_XRAY_STATUS="stopped" \
    MOCK_DOH_LATENCY="1ms (优秀)" MOCK_CERT_STATUS="未配置" \
    xmg_doctor_run --dry-run 2>&1 || true)"
t_contains "诊断卡片显示配置校验: 未配置" "$_NOCFG_OUT" "配置校验: 未配置"
t_not_contains "无配置时不显示配置校验 OK" "$_NOCFG_OUT" "配置校验: OK"
rm -rf "$T_NOCFG"

# --- 9.5 NAT 机型未声明外部端口时必须显式提示（README 承诺的体检行为） ---
T_NAT="$(TMPDIR=/tmp mktemp -d)"
mkdir -p "$T_NAT/etc/xray"
printf 'PROXY_VLESS_ENABLED=1\nPROXY_VLESS_PORT=20000\n' > "$T_NAT/etc/xray/state.env"
_HINT_NAT="$(XMG_HOME="$T_NAT" XMG_ETC_DIR="$T_NAT/etc" \
    XMG_XRAY_STATE_DIR="$T_NAT/etc/xray" XMG_STATE_FILE="$T_NAT/etc/xray/state.env" \
    XMG_NET_NAT=1 _xmg_doctor_external_port_hint 2>/dev/null || true)"
t_contains "NAT 未声明外部端口时提示 --external-port" "$_HINT_NAT" "--external-port"

printf 'PROXY_EXTERNAL_PORT=20000\n' >> "$T_NAT/etc/xray/state.env"
_HINT_OK="$(XMG_HOME="$T_NAT" XMG_ETC_DIR="$T_NAT/etc" \
    XMG_XRAY_STATE_DIR="$T_NAT/etc/xray" XMG_STATE_FILE="$T_NAT/etc/xray/state.env" \
    XMG_NET_NAT=1 _xmg_doctor_external_port_hint 2>/dev/null || true)"
t_equals "已声明外部端口时不再提示" "$_HINT_OK" ""

_HINT_NONAT="$(XMG_HOME="$T_NAT" XMG_ETC_DIR="$T_NAT/etc" \
    XMG_XRAY_STATE_DIR="$T_NAT/etc/xray" XMG_STATE_FILE="$T_NAT/etc/xray/state.env" \
    XMG_NET_NAT=0 _xmg_doctor_external_port_hint 2>/dev/null || true)"
t_equals "非 NAT 机型不提示外部端口" "$_HINT_NONAT" ""
rm -rf "$T_NAT"

# --- 10. 用例收尾：还原加载 lib 之前的路径变量 ---
# common.sh 会 export XMG_HOME=/opt/xmg、XMG_LIB_DIR=/opt/xmg/lib；留在环境里，
# 后续用例的 `bash xmg selftest` 会拿到不存在的 /opt/xmg/lib 而直接 exit 1。
if [ -n "$_TE_PRE_HOME" ]; then
    export XMG_HOME="$_TE_PRE_HOME"
else
    unset XMG_HOME
fi
if [ -n "$_TE_PRE_LIB" ]; then
    export XMG_LIB_DIR="$_TE_PRE_LIB"
else
    unset XMG_LIB_DIR
fi
