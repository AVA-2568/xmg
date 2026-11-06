#!/usr/bin/env bash
# Alpine / OpenRC 支持测试
#   - 发行版与 init 识别
#   - 服务名映射（ssh -> sshd）
#   - OpenRC 版 Xray 服务脚本生成
#   - 防火墙 iptables 后端规则构建
#   - sysctl 在 OpenRC 下的持久化区块
# 本用例不依赖真实 Alpine，全部通过环境变量与 PATH 桩注入验证纯逻辑。
# shellcheck shell=bash

SRC="$TESTS_DIR/.."

# --- 1. 发行版识别 ---
t_equals "Alpine 家族识别" \
    "$(MOCK_OS_ID=alpine MOCK_OS_VER=3.20 bash -c 'source "'"$SRC"'/lib/os.sh"; xmg_os_detect force; printf "%s" "$XMG_OS_FAMILY"')" \
    "alpine"

t_equals "Debian 家族识别" \
    "$(MOCK_OS_ID=debian MOCK_OS_LIKE= bash -c 'source "'"$SRC"'/lib/os.sh"; xmg_os_detect force; printf "%s" "$XMG_OS_FAMILY"')" \
    "debian"

t_equals "ID_LIKE 派生识别 (linuxmint)" \
    "$(MOCK_OS_ID=linuxmint MOCK_OS_LIKE="ubuntu debian" bash -c 'source "'"$SRC"'/lib/os.sh"; xmg_os_detect force; printf "%s" "$XMG_OS_FAMILY"')" \
    "debian"

t_equals "未知发行版回退 unknown" \
    "$(MOCK_OS_ID=gentoo bash -c 'source "'"$SRC"'/lib/os.sh"; xmg_os_detect force; printf "%s" "$XMG_OS_FAMILY"')" \
    "unknown"

# --- 2. init 识别 ---
t_equals "MOCK_INIT=openrc 生效" \
    "$(MOCK_INIT=openrc bash -c 'source "'"$SRC"'/lib/os.sh"; xmg_os_detect force; printf "%s" "$XMG_INIT_SYSTEM"')" \
    "openrc"

t_equals "MOCK_INIT=systemd 生效" \
    "$(MOCK_INIT=systemd bash -c 'source "'"$SRC"'/lib/os.sh"; xmg_os_detect force; printf "%s" "$XMG_INIT_SYSTEM"')" \
    "systemd"

# --- 3. 服务名映射 ---
t_equals "OpenRC 下 ssh 映射为 sshd" \
    "$(MOCK_INIT=openrc bash -c 'source "'"$SRC"'/lib/os.sh"; xmg_os_detect force; xmg_svc_name ssh')" \
    "sshd"

# --- 4. OpenRC 版 Xray 服务脚本 ---
_OPENRC_SCRIPT="$(MOCK_INIT=openrc bash -c '
    XMG_LIB_DIR="'"$SRC"'/lib"
    XMG_HOME="$(mktemp -d)"
    export XMG_LIB_DIR XMG_HOME
    source "$XMG_LIB_DIR/os.sh"
    source "$XMG_LIB_DIR/common.sh"
    source "$XMG_LIB_DIR/xray.sh"
    xmg_xray_generate_openrc_content "/opt/xmg/xray/config.json" "/usr/local/bin/xray"
    rm -rf "$XMG_HOME"
' 2>/dev/null)"

t_contains "OpenRC 脚本声明 openrc-run 解释器" "$_OPENRC_SCRIPT" "#!/sbin/openrc-run"
t_contains "OpenRC 脚本注入 GOMEMLIMIT" "$_OPENRC_SCRIPT" "export GOMEMLIMIT=100MiB"
t_contains "OpenRC 脚本注入 GOMAXPROCS" "$_OPENRC_SCRIPT" "export GOMAXPROCS=1"
t_contains "OpenRC 脚本使用 XMG 配置路径" "$_OPENRC_SCRIPT" "run -config /opt/xmg/xray/config.json"
t_contains "OpenRC 脚本设置 nofile 上限" "$_OPENRC_SCRIPT" "rc_ulimit="
t_contains "OpenRC 脚本声明 net 依赖" "$_OPENRC_SCRIPT" "need net"

# 语法自检：生成的脚本必须能被 bash -n 解析
_OPENRC_SYNTAX_RC=0
printf '%s\n' "$_OPENRC_SCRIPT" > /tmp/xmg-openrc-test.$$.sh
bash -n /tmp/xmg-openrc-test.$$.sh || _OPENRC_SYNTAX_RC=1
rm -f /tmp/xmg-openrc-test.$$.sh
t_equals "生成的 OpenRC 脚本语法合法" "$_OPENRC_SYNTAX_RC" "0"

# --- 5. 架构 slug 映射 ---
t_equals "x86_64 架构映射为 64" \
    "$(bash -c '
        mkdir -p /tmp/xmg-arch-$$/bin
        printf "#!/bin/sh\necho x86_64\n" > /tmp/xmg-arch-$$/bin/uname
        chmod +x /tmp/xmg-arch-$$/bin/uname
        PATH="/tmp/xmg-arch-$$/bin:$PATH"
        XMG_LIB_DIR="'"$SRC"'/lib"
        export PATH
        source "'"$SRC"'/lib/core.sh"
        xmg_core_arch_slug
        rm -rf /tmp/xmg-arch-$$
    ' 2>/dev/null)" \
    "64"

t_equals "aarch64 架构映射为 arm64-v8a" \
    "$(bash -c '
        mkdir -p /tmp/xmg-arch2-$$/bin
        printf "#!/bin/sh\necho aarch64\n" > /tmp/xmg-arch2-$$/bin/uname
        chmod +x /tmp/xmg-arch2-$$/bin/uname
        PATH="/tmp/xmg-arch2-$$/bin:$PATH"
        XMG_LIB_DIR="'"$SRC"'/lib"
        export PATH
        source "'"$SRC"'/lib/core.sh"
        xmg_core_arch_slug
        rm -rf /tmp/xmg-arch2-$$
    ' 2>/dev/null)" \
    "arm64-v8a"

# --- 6. 防火墙 iptables 后端（dry-run 回显规则序列，跨平台可验证） ---
TMP_FW2="$(mktemp -d)"

_FW_DRY_OUT="$(bash -c '
    XMG_FW_IPT_DRY_RUN=1
    XMG_FW_BACKEND=iptables
    XMG_FW_IPV6=1
    XMG_FW_RULES_DIR="'"$TMP_FW2"'/fw"
    XMG_FW_ALLOW_FILE="'"$TMP_FW2"'/fw/allow.list"
    XMG_FW_ENABLED_FILE="'"$TMP_FW2"'/fw/enabled"
    XMG_LIB_DIR="'"$SRC"'/lib"
    export XMG_FW_IPT_DRY_RUN XMG_FW_BACKEND XMG_FW_IPV6 XMG_FW_RULES_DIR XMG_FW_ALLOW_FILE XMG_FW_ENABLED_FILE XMG_LIB_DIR
    source "$XMG_LIB_DIR/firewall.sh"
    xmg_require_root() { return 0; }
    mkdir -p "$XMG_FW_RULES_DIR"
    : > "$XMG_FW_ENABLED_FILE"
    xmg_fw_allow_add 22 tcp
    xmg_fw_allow_add 443 tcp
    xmg_fw_ipt_apply
' 2>/dev/null)"
_FW_APPLY_RC=$?
t_equals "iptables 后端应用成功" "$_FW_APPLY_RC" "0"

t_contains "创建 XMG 链" "$_FW_DRY_OUT" "iptables -N XMG-IN"
t_contains "放行 SSH 22" "$_FW_DRY_OUT" "--dport 22 -j RETURN"
t_contains "放行 443" "$_FW_DRY_OUT" "--dport 443 -j RETURN"
t_contains "默认拒绝" "$_FW_DRY_OUT" "-A XMG-IN -j DROP"
t_contains "挂载到 INPUT" "$_FW_DRY_OUT" "-I INPUT 1 -j XMG-IN"
t_contains "双栈时 IPv6 侧同样生效" "$_FW_DRY_OUT" "ip6tables -N XMG-IN"
t_contains "IPv6 放通 NDP (135/136)" "$_FW_DRY_OUT" "-p ipv6-icmp --icmpv6-type 135 -j RETURN"
t_contains "IPv6 放通 DHCPv6 客户端" "$_FW_DRY_OUT" "-p udp --dport 546 -j RETURN"
t_contains "IPv4 放通 DHCP 客户端" "$_FW_DRY_OUT" "-p udp --dport 68 -j RETURN"

# 纯 IPv4 单栈：不应触碰 ip6tables
_FW_DRY_V4="$(bash -c '
    XMG_FW_IPT_DRY_RUN=1
    XMG_FW_BACKEND=iptables
    XMG_FW_IPV6=0
    XMG_FW_RULES_DIR="'"$TMP_FW2"'/fw4"
    XMG_FW_ALLOW_FILE="'"$TMP_FW2"'/fw4/allow.list"
    XMG_FW_ENABLED_FILE="'"$TMP_FW2"'/fw4/enabled"
    XMG_LIB_DIR="'"$SRC"'/lib"
    export XMG_FW_IPT_DRY_RUN XMG_FW_BACKEND XMG_FW_IPV6 XMG_FW_RULES_DIR XMG_FW_ALLOW_FILE XMG_FW_ENABLED_FILE XMG_LIB_DIR
    source "$XMG_LIB_DIR/firewall.sh"
    xmg_require_root() { return 0; }
    mkdir -p "$XMG_FW_RULES_DIR"
    : > "$XMG_FW_ENABLED_FILE"
    xmg_fw_allow_add 22 tcp
    xmg_fw_ipt_apply
' 2>/dev/null)"
t_not_contains "纯 IPv4 单栈不操作 ip6tables" "$_FW_DRY_V4" "ip6tables"
t_contains "纯 IPv4 单栈仍正常重建链" "$_FW_DRY_V4" "iptables -N XMG-IN"

# 未启用时只维护链，不挂载 DROP
_FW_DRY_OUT2="$(bash -c '
    XMG_FW_IPT_DRY_RUN=1
    XMG_FW_BACKEND=iptables
    XMG_FW_RULES_DIR="'"$TMP_FW2"'/fw2"
    XMG_FW_ALLOW_FILE="'"$TMP_FW2"'/fw2/allow.list"
    XMG_FW_ENABLED_FILE="'"$TMP_FW2"'/fw2/enabled"
    XMG_LIB_DIR="'"$SRC"'/lib"
    export XMG_FW_IPT_DRY_RUN XMG_FW_BACKEND XMG_FW_RULES_DIR XMG_FW_ALLOW_FILE XMG_FW_ENABLED_FILE XMG_LIB_DIR
    source "$XMG_LIB_DIR/firewall.sh"
    xmg_require_root() { return 0; }
    xmg_fw_allow_add 22 tcp
    xmg_fw_ipt_apply
' 2>/dev/null)"
t_not_contains "未启用时不挂 DROP 规则" "$_FW_DRY_OUT2" "-A XMG-IN -j DROP"
t_contains "未启用时摘除 INPUT 跳转" "$_FW_DRY_OUT2" "-D INPUT -j XMG-IN"

# 后端自动选择：Alpine 无 ufw 时用 iptables
t_equals "Alpine 无 ufw 时后端为 iptables" \
    "$(MOCK_OS_ID=alpine MOCK_INIT=openrc XMG_FW_BACKEND=auto bash -c '
        export XMG_LIB_DIR="'"$SRC"'/lib"
        source "$XMG_LIB_DIR/os.sh"
        source "$XMG_LIB_DIR/firewall.sh"
        xmg_firewall_backend
    ' 2>/dev/null)" \
    "iptables"

rm -rf "$TMP_FW2"

# --- 7. sysctl 在 OpenRC 下的持久化 ---
TMP_SYSCTL="$(mktemp -d)"
printf '# existing\nvm.swappiness = 10\n' > "$TMP_SYSCTL/sysctl.conf"
printf 'net.core.somaxconn = 2048\nvm.swappiness = 20\n' > "$TMP_SYSCTL/99-xmg-tune.conf"

bash -c '
    export MOCK_INIT=openrc
    export XMG_TUNE_SYSCTL_MAIN_CONF="'"$TMP_SYSCTL"'/sysctl.conf"
    export XMG_LIB_DIR="'"$SRC"'/lib"
    source "$XMG_LIB_DIR/os.sh"
    source "$XMG_LIB_DIR/common.sh"
    source "$XMG_LIB_DIR/tune.sh"
    xmg_tune_sysctl_persist "'"$TMP_SYSCTL"'/99-xmg-tune.conf" >/dev/null 2>&1
    xmg_tune_sysctl_persist "'"$TMP_SYSCTL"'/99-xmg-tune.conf" >/dev/null 2>&1
' >/dev/null 2>&1

_SYSCTL_MAIN="$(cat "$TMP_SYSCTL/sysctl.conf" 2>/dev/null || true)"
t_contains "sysctl.conf 保留原有内容" "$_SYSCTL_MAIN" "vm.swappiness = 10"
t_contains "sysctl.conf 写入 XMG 标记块" "$_SYSCTL_MAIN" ">>> xmg:99-xmg-tune.conf >>>"
t_contains "sysctl.conf 带入调优参数" "$_SYSCTL_MAIN" "net.core.somaxconn = 2048"
_MARK_COUNT="$(grep -c '>>> xmg:99-xmg-tune.conf >>>' "$TMP_SYSCTL/sysctl.conf" 2>/dev/null || true)"
t_equals "重复执行不产生重复标记块（幂等）" "$_MARK_COUNT" "1"

# systemd 环境不应污染 /etc/sysctl.conf
TMP_SYSCTL2="$(mktemp -d)"
printf '# untouched\n' > "$TMP_SYSCTL2/sysctl.conf"
bash -c '
    export MOCK_INIT=systemd
    export XMG_TUNE_SYSCTL_MAIN_CONF="'"$TMP_SYSCTL2"'/sysctl.conf"
    export XMG_LIB_DIR="'"$SRC"'/lib"
    source "$XMG_LIB_DIR/os.sh"
    source "$XMG_LIB_DIR/common.sh"
    source "$XMG_LIB_DIR/tune.sh"
    xmg_tune_sysctl_persist "'"$TMP_SYSCTL"'/99-xmg-tune.conf" >/dev/null 2>&1
' >/dev/null 2>&1
t_not_contains "systemd 环境不写 /etc/sysctl.conf" "$(cat "$TMP_SYSCTL2/sysctl.conf")" "xmg:99-xmg-tune.conf"

rm -rf "$TMP_SYSCTL" "$TMP_SYSCTL2"

# --- 8. 包管理器抽象 ---
TMP_PKG="$(TMPDIR=/tmp mktemp -d)"
mkdir -p "$TMP_PKG/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP_PKG/bin/apk"
chmod +x "$TMP_PKG/bin/apk"
t_equals "检测到 apk 包管理器" \
    "$(PATH="$TMP_PKG/bin:$PATH" bash -c 'export XMG_LIB_DIR="'"$SRC"'/lib"; source "$XMG_LIB_DIR/os.sh"; xmg_pkg_mgr')" \
    "apk"
t_contains "apk 安装命令提示正确" \
    "$(PATH="$TMP_PKG/bin:$PATH" bash -c 'export XMG_LIB_DIR="'"$SRC"'/lib"; source "$XMG_LIB_DIR/os.sh"; xmg_pkg_hint unbound')" \
    "apk add --no-cache unbound"
rm -rf "$TMP_PKG"

# --- 9. 单栈 / 双栈自适应 ---
TMP_UNBOUND="$(mktemp -d)"

_CONF_V4="$(bash -c '
    XMG_HAS_IPV6=0
    XMG_LIB_DIR="'"$SRC"'/lib"
    export XMG_HAS_IPV6 XMG_LIB_DIR
    source "$XMG_LIB_DIR/os.sh"
    source "$XMG_LIB_DIR/common.sh"
    source "$XMG_LIB_DIR/tune.sh"
    xmg_tune_unbound_write_conf "'"$TMP_UNBOUND"'/v4.conf" 1.1.1.1 1.0.0.1 cloudflare-dns.com cloudflare-dns.com
    cat "'"$TMP_UNBOUND"'/v4.conf"
' 2>/dev/null)"
t_contains "纯 IPv4 单栈绑定 127.0.0.1" "$_CONF_V4" "interface: 127.0.0.1"
t_not_contains "纯 IPv4 单栈不绑定 ::1" "$_CONF_V4" "interface: ::1"
t_contains "DoT 转发仍启用" "$_CONF_V4" "forward-tls-upstream: yes"
t_contains "DoT 上游带证书域名" "$_CONF_V4" "forward-addr: 1.1.1.1@853#cloudflare-dns.com"

_CONF_V6="$(bash -c '
    XMG_HAS_IPV6=1
    XMG_LIB_DIR="'"$SRC"'/lib"
    export XMG_HAS_IPV6 XMG_LIB_DIR
    source "$XMG_LIB_DIR/os.sh"
    source "$XMG_LIB_DIR/common.sh"
    source "$XMG_LIB_DIR/tune.sh"
    xmg_tune_unbound_write_conf "'"$TMP_UNBOUND"'/v6.conf" 2606:4700:4700::1111 2606:4700:4700::1001 cloudflare-dns.com cloudflare-dns.com
    cat "'"$TMP_UNBOUND"'/v6.conf"
' 2>/dev/null)"
t_contains "双栈时同时绑定 ::1" "$_CONF_V6" "interface: ::1"
t_contains "双栈时放通 ::1 访问" "$_CONF_V6" "access-control: ::1 allow"
t_contains "IPv6 上游可用" "$_CONF_V6" "forward-addr: 2606:4700:4700::1111@853"

rm -rf "$TMP_UNBOUND"
