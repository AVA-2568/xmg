#!/usr/bin/env bash
# coding: utf-8
#
# alpine-acceptance.sh - Alpine / OpenRC 真机验收脚本（在 Alpine 容器内执行）
#
# 用途：
#   在真实 Alpine 上跑通 XMG 的安装、内核安装、服务注册、代理配置、防火墙、
#   调优与卸载，逐项输出 PASS/FAIL。用于替代「本机无虚拟化环境」的验证缺口。
#
# 用法（宿主机执行，需 Docker）：
#   docker run --rm -it --privileged \
#     -v "$PWD":/xmg \
#     alpine:3.20 \
#     sh -c "apk add --no-cache bash curl && bash /xmg/tests/alpine-acceptance.sh"
#
# 可选参数：
#   --skip-core      跳过内核下载（离线/网络受限时使用）
#   --keep           结束后不执行卸载（便于手工排查）
#
# 说明：
#   - 必须 --privileged，否则 iptables 与 sysctl 无法验证（脚本会标记为 SKIP）
#   - 全部操作发生在容器内，销毁容器即无残留
#

set -uo pipefail

SKIP_CORE=0
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --skip-core) SKIP_CORE=1 ;;
        --keep)      KEEP=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
    esac
done

PASS=0
FAIL=0
SKIP=0

c_green=''
c_red=''
c_yellow=''
if [ -t 1 ]; then
    c_green=$'\033[32m'; c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_reset=$'\033[0m'
else
    c_reset=''
fi

ok()   { PASS=$((PASS + 1)); printf '%s[PASS]%s %s\n' "$c_green" "$c_reset" "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '%s[FAIL]%s %s\n' "$c_red" "$c_reset" "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '%s[SKIP]%s %s\n' "$c_yellow" "$c_reset" "$*"; }

# chk <描述> <命令字符串>
chk() {
    local desc="$1"
    shift
    if bash -c "$*" >/dev/null 2>&1; then
        ok "$desc"
    else
        bad "$desc"
    fi
}

section() {
    printf '\n=== %s ===\n' "$*"
}

# ---------------------------------------------------------------- 0. 前置检查
section "0. 环境前置检查"

if [ ! -r /etc/alpine-release ]; then
    echo "错误: 本脚本必须在 Alpine 上运行（未检测到 /etc/alpine-release）" >&2
    exit 2
fi
ok "运行于 Alpine $(cat /etc/alpine-release)"

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 需要 root 执行" >&2
    exit 2
fi
ok "root 权限"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -f "$REPO_DIR/install.sh" ] || [ ! -d "$REPO_DIR/lib" ]; then
    echo "错误: 未找到 XMG 源码，请用 -v \"\$PWD\":/xmg 挂载仓库后从 /xmg/tests 运行" >&2
    exit 2
fi
ok "源码目录: $REPO_DIR"

have_net=0
if curl -fsSL --connect-timeout 5 --max-time 10 https://api.github.com/ >/dev/null 2>&1; then
    have_net=1
    ok "外网可达（GitHub API）"
else
    skip "外网不可达，将跳过后需要下载的步骤"
fi

# ---------------------------------------------------------------- 1. 安装
section "1. 安装 XMG"

if bash "$REPO_DIR/install.sh" >/tmp/xmg-install.log 2>&1; then
    ok "install.sh 执行成功"
else
    bad "install.sh 执行失败（见 /tmp/xmg-install.log）"
    tail -20 /tmp/xmg-install.log
fi

chk "命令入口存在" "command -v xmg"
chk "os.sh 已落盘" "[ -f /opt/xmg/lib/os.sh ]"
chk "xmg version 可执行" "xmg version"

# ---------------------------------------------------------------- 2. 环境识别
section "2. 发行版 / init / 包管理器识别"

os_out="$(xmg os 2>&1)"
printf '%s\n' "$os_out" | sed 's/^/    /'
case "$os_out" in
    *"family=alpine"*) ok "识别为 alpine 家族" ;;
    *) bad "家族识别错误" ;;
esac
case "$os_out" in
    *"Init   : openrc"*) ok "识别为 openrc" ;;
    *) bad "init 识别错误" ;;
esac
case "$os_out" in
    *"包管理 : apk"*) ok "识别为 apk" ;;
    *) bad "包管理器识别错误" ;;
esac

chk "doctor 可运行" "xmg doctor --dry-run"

# ---------------------------------------------------------------- 3. 内核与服务注册
section "3. 内核安装与 OpenRC 服务注册"

if [ "$SKIP_CORE" -eq 1 ]; then
    skip "--skip-core 已指定，跳过内核安装"
elif [ "$have_net" -eq 0 ]; then
    skip "无外网，跳过内核安装"
else
    if xmg core install >/tmp/xmg-core.log 2>&1; then
        ok "xmg core install 成功"
    else
        bad "xmg core install 失败（见 /tmp/xmg-core.log）"
        tail -20 /tmp/xmg-core.log
    fi
    chk "xray 二进制就位" "[ -x /usr/local/bin/xray ]"
    chk "xray 版本可读" "xmg core version"
    chk "OpenRC 服务脚本已生成" "[ -f /etc/init.d/xray ]"
    chk "服务脚本含 GOMEMLIMIT" "grep -q 'GOMEMLIMIT=100MiB' /etc/init.d/xray"
    chk "服务脚本含 rc_ulimit" "grep -q 'rc_ulimit' /etc/init.d/xray"
    chk "服务脚本含 XMG 标记" "grep -q 'XMG 管理的 Xray OpenRC 服务脚本' /etc/init.d/xray"
    chk "已加入 default 运行级" "rc-update show | grep -qw xray"
fi

# ---------------------------------------------------------------- 4. 代理配置闭环
section "4. 代理配置与配置校验"

if [ ! -x /usr/local/bin/xray ]; then
    skip "未安装内核，跳过代理配置"
else
    if xmg proxy apply --socks on --socks-port 1080 --socks-user testu --socks-pass testp12 >/tmp/xmg-proxy.log 2>&1; then
        ok "xmg proxy apply 成功（含服务重启）"
    else
        bad "xmg proxy apply 失败（见 /tmp/xmg-proxy.log）"
        tail -20 /tmp/xmg-proxy.log
    fi
    chk "配置文件已生成" "[ -s /opt/xmg/xray/config.json ]"
    chk "配置校验通过" "xmg xray validate"
    chk "服务处于运行态" "rc-service xray status"
    chk "proxy status 可读" "xmg proxy status"

    # 端口实际监听（由 /proc/net/tcp 判定，不依赖 ss/netstat）
    chk "1080 端口处于 LISTEN" "grep -qi ':0438' /proc/net/tcp"
fi

# ---------------------------------------------------------------- 5. 防火墙
section "5. 防火墙（iptables 后端）"

if ! command -v iptables >/dev/null 2>&1; then
    printf 'y\n' | xmg firewall install >/tmp/xmg-fw-install.log 2>&1
fi

if ! command -v iptables >/dev/null 2>&1; then
    skip "iptables 不可用（容器缺少 --privileged 或内核模块）"
else
    xmg firewall allow >/tmp/xmg-fw-allow.log 2>&1
    chk "allow.list 已写入" "[ -s /opt/xmg/etc/firewall/allow.list ]"
    chk "放行列表含 22/tcp" "grep -qx '22/tcp' /opt/xmg/etc/firewall/allow.list"

    printf 'y\n' | xmg firewall enable >/tmp/xmg-fw-enable.log 2>&1
    if iptables -S XMG-IN >/dev/null 2>&1; then
        ok "XMG-IN 链已创建"
        chk "链末尾为 DROP" "iptables -S XMG-IN | tail -1 | grep -q -- '-j DROP'"
        chk "已挂载到 INPUT" "iptables -S INPUT | grep -q -- '-j XMG-IN'"
        chk "放行规则存在" "iptables -S XMG-IN | grep -q -- '--dport 22'"
        chk "开机重放脚本已生成" "[ -x /etc/init.d/xmg-firewall ]"
        chk "xmg-firewall 已进 default 运行级" "rc-update show | grep -qw xmg-firewall"

        # IPv6 双栈：容器通常有 ::1
        if [ -e /proc/net/if_inet6 ]; then
            chk "IPv6 链已创建" "ip6tables -S XMG-IN"
            chk "IPv6 放通 NDP 135" "ip6tables -S XMG-IN | grep -q -- '--icmpv6-type 135'"
            chk "IPv6 放通 DHCPv6 546" "ip6tables -S XMG-IN | grep -q -- '--dport 546'"
        else
            skip "容器未启用 IPv6，跳过双栈断言"
        fi

        # 立即关闭，避免影响后续步骤网络
        printf 'y\n' | xmg firewall disable >/dev/null 2>&1
        chk "禁用后链已摘除" "! iptables -S XMG-IN"
    else
        bad "XMG-IN 链未创建（见 /tmp/xmg-fw-enable.log）"
        tail -10 /tmp/xmg-fw-enable.log
    fi
fi

# ---------------------------------------------------------------- 6. 调优
section "6. 系统调优持久化"

if printf 'y\n' | xmg tune bbr >/tmp/xmg-bbr.log 2>&1; then
    ok "xmg tune bbr 执行完成"
else
    skip "BBR 未启用（容器内核可能不支持）"
fi
chk "sysctl.d 配置已落盘" "[ -f /etc/sysctl.d/99-xmg-bbr.conf ]"

if printf 'y\n' | xmg tune net >/tmp/xmg-net.log 2>&1; then
    ok "xmg tune net 执行完成"
else
    bad "xmg tune net 失败（见 /tmp/xmg-net.log）"
fi
chk "网络调优配置已落盘" "[ -f /etc/sysctl.d/99-xmg-tune.conf ]"
chk "已同步到 /etc/sysctl.conf 标记块" "grep -q '>>> xmg:99-xmg-tune.conf >>>' /etc/sysctl.conf"
chk "重复执行不产生重复标记块" "[ \$(grep -c '>>> xmg:99-xmg-tune.conf >>>' /etc/sysctl.conf) -eq 1 ]"

# ---------------------------------------------------------------- 7. 卸载
section "7. 卸载与残留清理"

if [ "$KEEP" -eq 1 ]; then
    skip "--keep 已指定，保留现场"
else
    printf 'y\n' | xmg uninstall run --yes >/tmp/xmg-uninstall.log 2>&1
    chk "命令入口已移除" "[ ! -e /usr/local/bin/xmg ]"
    chk "主目录已移除" "[ ! -d /opt/xmg ]"
    chk "OpenRC 服务脚本已清理" "[ ! -f /etc/init.d/xray ]"
    chk "xmg-firewall 脚本已清理" "[ ! -f /etc/init.d/xmg-firewall ]"
    chk "运行级里已无 xray" "! rc-update show | grep -qw xray"
    chk "iptables 链已清理" "! iptables -S XMG-IN"
fi

# ---------------------------------------------------------------- 汇总
printf '\n============================================\n'
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
printf '============================================\n'

[ "$FAIL" -eq 0 ]
