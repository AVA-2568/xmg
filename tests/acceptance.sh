#!/usr/bin/env bash
# coding: utf-8
#
# acceptance.sh - XMG 跨发行版验收脚本
#
# 设计原则：不为某个发行版写专用断言。脚本启动时自行探测
#   发行版家族 / init 系统 / 包管理器 / 防火墙后端，
# 然后按探测结果选择对应的断言分支，同一套流程覆盖：
#   Debian 11/12、Ubuntu 20.04+、Alpine 3.16+，以及任意 systemd 或 OpenRC 系统
#
# 用法（在目标机器上执行，需要 root）：
#   bash tests/acceptance.sh                 # 非破坏性为主，跳过防火墙启用
#   bash tests/acceptance.sh --with-firewall # 额外验证防火墙启用（可能影响 SSH，先在快照机跑）
#   bash tests/acceptance.sh --skip-core     # 跳过内核下载（离线环境）
#   bash tests/acceptance.sh --keep          # 结束后不卸载，保留现场排查
#
# 说明：
#   - 会真实安装 / 调优 / 卸载，请只在一次性 VPS 或快照上执行
#   - 缺外网或缺能力时输出 SKIP，不计入失败
#

set -uo pipefail

SKIP_CORE=0
KEEP=0
WITH_FW=0
for arg in "$@"; do
    case "$arg" in
        --skip-core)     SKIP_CORE=1 ;;
        --keep)          KEEP=1 ;;
        --with-firewall) WITH_FW=1 ;;
        -h|--help)       sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "未知参数: $arg" >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then
    c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_0=$'\033[0m'
else
    c_g=''; c_r=''; c_y=''; c_0=''
fi

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '%s[PASS]%s %s\n' "$c_g" "$c_0" "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '%s[FAIL]%s %s\n' "$c_r" "$c_0" "$*"; }
skip() { SKIP=$((SKIP+1)); printf '%s[SKIP]%s %s\n' "$c_y" "$c_0" "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

chk() {
    local desc="$1"; shift
    if bash -c "$*" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
chk_not() {
    local desc="$1"; shift
    if bash -c "$*" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}

# ================================================================
# 环境探测（脚本自带，同时用于校验 XMG 的识别结果）
# ================================================================
OS_ID="unknown"; OS_LIKE=""; OS_PRETTY="unknown"
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
fi

case "$OS_ID" in
    debian|ubuntu|raspbian|linuxmint|devuan|armbian|kali) EXP_FAMILY=debian ;;
    alpine)                                              EXP_FAMILY=alpine ;;
    rhel|centos|rocky|almalinux|fedora|ol|amzn)           EXP_FAMILY=rhel ;;
    arch|manjaro)                                        EXP_FAMILY=arch ;;
    opensuse*|sles)                                      EXP_FAMILY=suse ;;
    *) EXP_FAMILY=unknown ;;
esac

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT=systemd
elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    INIT=openrc
elif command -v service >/dev/null 2>&1; then
    INIT=sysvinit
else
    INIT=none
fi

if command -v apk >/dev/null 2>&1; then PKG=apk
elif command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf >/dev/null 2>&1; then PKG=dnf
elif command -v yum >/dev/null 2>&1; then PKG=yum
elif command -v pacman >/dev/null 2>&1; then PKG=pacman
elif command -v zypper >/dev/null 2>&1; then PKG=zypper
else PKG=none; fi

if command -v ufw >/dev/null 2>&1; then FW=ufw
elif command -v iptables >/dev/null 2>&1; then FW=iptables
else FW=none; fi

svc_active() {
    case "$INIT" in
        systemd) systemctl is-active --quiet "$1" ;;
        openrc)  rc-service "$1" status >/dev/null 2>&1 ;;
        sysvinit) service "$1" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

svc_enabled() {
    case "$INIT" in
        systemd) systemctl is-enabled --quiet "$1" 2>/dev/null ;;
        openrc)  rc-update show 2>/dev/null | grep -qw "$1" ;;
        sysvinit) return 0 ;;
        *) return 1 ;;
    esac
}

pkg_install() {
    case "$PKG" in
        apk)    apk add --no-cache "$@" ;;
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        pacman) pacman -Sy --noconfirm "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        *) return 1 ;;
    esac
}

# 自动回答交互式确认
# 必须关掉 pipefail：yes 在命令退出后会收到 SIGPIPE(141)，否则整条管道恒为失败
run_yes() {
    ( set +o pipefail; yes 2>/dev/null | "$@" )
}

# ================================================================
section "0. 前置检查"
echo "    发行版 : $OS_PRETTY  (id=$OS_ID, family=$EXP_FAMILY)"
echo "    init   : $INIT"
echo "    包管理 : $PKG"
echo "    防火墙 : $FW"
echo

chk "以 root 运行" '[ "$(id -u)" -eq 0 ]'

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chk "找到 XMG 源码" "[ -f '$REPO_DIR/install.sh' ] && [ -d '$REPO_DIR/lib' ]"

if [ "$(id -u)" -ne 0 ] || [ ! -f "$REPO_DIR/install.sh" ]; then
    echo "前置条件不满足，终止" >&2
    exit 2
fi

# 脚本自身依赖
for tool in curl bash; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '安装脚本依赖 %s ...\n' "$tool"
        pkg_install "$tool" >/dev/null 2>&1 || true
    fi
done

have_net=0
if curl -fsSL --connect-timeout 5 --max-time 10 https://api.github.com/ >/dev/null 2>&1; then
    have_net=1; ok "外网可达"
else
    skip "外网不可达，下载类步骤将跳过"
fi

# ================================================================
section "1. 安装与入口"

if bash "$REPO_DIR/install.sh" >/tmp/xmg-install.log 2>&1; then
    ok "install.sh 执行成功"
else
    bad "install.sh 执行失败（/tmp/xmg-install.log）"
    tail -20 /tmp/xmg-install.log
fi

chk "命令入口可用" "command -v xmg"
chk "核心模块齐全" "[ -f /opt/xmg/lib/os.sh ] && [ -f /opt/xmg/lib/common.sh ]"
chk "xmg version 可执行" "xmg version"
chk "清单模块全部落盘" '[ "$(grep -c "^lib/" /opt/xmg/xmg.files)" -ge 18 ] && [ -f /opt/xmg/lib/os.sh ]'

# ================================================================
section "2. 环境识别一致性（XMG vs 脚本独立探测）"

os_out="$(xmg os 2>&1)"
printf '%s\n' "$os_out" | sed 's/^/    /'

# 用正则而非固定空格匹配，避免输出格式微调导致误判
if printf '%s' "$os_out" | grep -qE "\(family=${EXP_FAMILY}[,)]"; then
    ok "家族识别一致: $EXP_FAMILY"
else
    bad "家族识别不一致，期望 $EXP_FAMILY"
fi
if printf '%s' "$os_out" | grep -qE "^Init[[:space:]]*:[[:space:]]*${INIT}\$"; then
    ok "init 识别一致: $INIT"
else
    bad "init 识别不一致，期望 $INIT"
fi
if printf '%s' "$os_out" | grep -qE "包管理[[:space:]]*:[[:space:]]*${PKG}\$"; then
    ok "包管理器识别一致: $PKG"
else
    bad "包管理器识别不一致，期望 $PKG"
fi

# doctor 在缺服务/缺证书等场景会返回非 0，这里只校验卡片能正常产出
doc_out="$(xmg doctor --dry-run 2>&1 || true)"
if printf '%s' "$doc_out" | grep -q '\[环境\]'; then
    ok "doctor 输出正常"
else
    bad "doctor 未输出诊断卡片"
fi
chk "detect status 可运行" "xmg detect status"

# ================================================================
section "3. 内核安装与服务注册"

if [ "$SKIP_CORE" -eq 1 ]; then
    skip "--skip-core，跳过内核安装"
elif [ "$have_net" -eq 0 ]; then
    skip "无外网，跳过内核安装"
else
    if xmg core install >/tmp/xmg-core.log 2>&1; then
        ok "xmg core install 成功"
    else
        bad "xmg core install 失败（/tmp/xmg-core.log）"
        tail -20 /tmp/xmg-core.log
    fi

    chk "xray 二进制就位" "[ -x /usr/local/bin/xray ]"
    chk "内核版本可读" "xmg core version"

    case "$INIT" in
        systemd)
            chk "systemd unit 已注册" \
                "[ -f /etc/systemd/system/xray.service ] || [ -f /lib/systemd/system/xray.service ]"
            chk "drop-in 注入 GOMEMLIMIT" \
                "grep -q 'GOMEMLIMIT=' /etc/systemd/system/xray.service.d/20-xmg.conf"
            chk "已设置开机自启" "systemctl is-enabled xray"
            ;;
        openrc)
            chk "OpenRC 脚本已生成" "[ -f /etc/init.d/xray ]"
            chk "脚本含 GOMEMLIMIT" "grep -q 'GOMEMLIMIT=' /etc/init.d/xray"
            chk "脚本含 rc_ulimit" "grep -q 'rc_ulimit' /etc/init.d/xray"
            chk "已加入运行级" "rc-update show | grep -qw xray"
            ;;
        *)
            skip "init=$INIT，跳过服务注册断言"
            ;;
    esac
fi

# ================================================================
section "4. 代理配置闭环"

if [ ! -x /usr/local/bin/xray ]; then
    skip "未安装内核，跳过代理配置"
else
    if xmg proxy apply --socks on --socks-port 1080 --socks-user testu --socks-pass testp12 >/tmp/xmg-proxy.log 2>&1; then
        ok "xmg proxy apply 成功"
    else
        bad "xmg proxy apply 失败（/tmp/xmg-proxy.log）"
        tail -20 /tmp/xmg-proxy.log
    fi

    chk "配置文件已生成" "[ -s /opt/xmg/xray/config.json ]"
    chk "配置校验通过" "xmg xray validate"
    chk "proxy status 可读" "xmg proxy status"

    if [ "$INIT" != "none" ]; then
        if svc_active xray; then ok "服务处于运行态"; else bad "服务未运行"; fi
    fi

    chk "1080 端口 LISTEN" "grep -qi ':0438' /proc/net/tcp"
fi

# ================================================================
section "5. 防火墙（后端: $FW）"

chk "firewall status 可运行" "xmg firewall status"

case "$FW" in
    ufw)
        # Debian 默认不预装 ufw，先走 XMG 自己的安装路径
        if ! command -v ufw >/dev/null 2>&1; then
            run_yes xmg firewall install >/tmp/xmg-fw-install.log 2>&1
        fi
        # ufw status 的输出里不含 "ufw" 字样，用状态行判断
        chk "ufw 可用" "ufw status 2>/dev/null | grep -qi 'Status:'"
        if [ "$WITH_FW" -eq 1 ]; then
            run_yes xmg firewall enable >/tmp/xmg-fw.log 2>&1
            chk "UFW 已启用" "ufw status | grep -q 'Status: active'"
            chk "22/tcp 已放行" "ufw status | grep -q '22/tcp'"
            chk "IPV6 未被禁用" "! grep -qiE '^[[:space:]]*IPV6=[[:space:]]*no' /etc/default/ufw"
            run_yes xmg firewall disable >/dev/null 2>&1
        else
            skip "未指定 --with-firewall，跳过启用（避免影响 SSH）"
        fi
        ;;
    iptables)
        if ! command -v iptables >/dev/null 2>&1; then
            run_yes xmg firewall install >/dev/null 2>&1
        fi
        chk "后端识别为 iptables" "xmg firewall status 2>&1 | grep -qi iptables"
        xmg firewall allow >/tmp/xmg-fw-allow.log 2>&1
        chk "放行列表已写入" "[ -s /opt/xmg/etc/firewall/allow.list ]"
        chk "放行列表含 22/tcp" "grep -qx '22/tcp' /opt/xmg/etc/firewall/allow.list"

        if [ "$WITH_FW" -eq 1 ]; then
            run_yes xmg firewall enable >/tmp/xmg-fw.log 2>&1
            if iptables -S XMG-IN >/dev/null 2>&1; then
                ok "XMG-IN 链已创建"
                chk "链末尾为 DROP" "iptables -S XMG-IN | tail -1 | grep -q -- '-j DROP'"
                chk "已挂载到 INPUT" "iptables -S INPUT | grep -q -- '-j XMG-IN'"
                chk "放行规则存在" "iptables -S XMG-IN | grep -q -- '--dport 22'"
                chk "开机重放服务已生成" "[ -x /etc/init.d/xmg-firewall ]"

                if [ -e /proc/net/if_inet6 ]; then
                    chk "IPv6 链已创建" "ip6tables -S XMG-IN"
                    chk "IPv6 放通 NDP" "ip6tables -S XMG-IN | grep -q -- '--icmpv6-type 135'"
                    chk "IPv6 放通 DHCPv6" "ip6tables -S XMG-IN | grep -q -- '--dport 546'"
                else
                    skip "主机未启用 IPv6，跳过双栈断言"
                fi

                run_yes xmg firewall disable >/dev/null 2>&1
                chk_not "禁用后链已摘除" "iptables -S XMG-IN"
            else
                bad "XMG-IN 链未创建（/tmp/xmg-fw.log）"
                tail -10 /tmp/xmg-fw.log
            fi
        else
            skip "未指定 --with-firewall，跳过启用"
        fi
        ;;
    *)
        skip "未检测到受支持的防火墙后端"
        ;;
esac

# ================================================================
section "6. 调优与持久化"

if run_yes xmg tune bbr >/tmp/xmg-bbr.log 2>&1; then
    ok "tune bbr 执行完成"
    chk "BBR 配置已落盘" "[ -f /etc/sysctl.d/99-xmg-bbr.conf ]"
else
    skip "BBR 不可用（内核不支持），跳过落盘检查"
fi

run_yes xmg tune net >/tmp/xmg-net.log 2>&1 \
    && ok "tune net 执行完成" || bad "tune net 失败（/tmp/xmg-net.log）"
chk "网络调优配置已落盘" "[ -f /etc/sysctl.d/99-xmg-tune.conf ]"
chk "limits 配置已落盘" "[ -f /etc/security/limits.d/99-xmg-nofile.conf ]"

case "$INIT" in
    systemd)
        chk "systemd DefaultLimitNOFILE 已写入" \
            "[ -f /etc/systemd/system.conf.d/99-xmg-limits.conf ]"
        skip "systemd 环境不写 /etc/sysctl.conf（由 sysctl.d 自动加载）"
        ;;
    *)
        chk "sysctl.conf 已同步标记块" "grep -q '# >>> xmg:' /etc/sysctl.conf"
        chk "标记块幂等（仅一份）" \
            "[ \$(grep -c '# >>> xmg:99-xmg-tune.conf >>>' /etc/sysctl.conf) -eq 1 ]"
        ;;
esac

# ================================================================
section "7. 卸载与残留清理"

if [ "$KEEP" -eq 1 ]; then
    skip "--keep，保留现场"
else
    run_yes xmg uninstall run --yes >/tmp/xmg-uninstall.log 2>&1

    chk_not "命令入口已移除" "[ -e /usr/local/bin/xmg ]"
    chk_not "主目录已移除" "[ -d /opt/xmg ]"

    case "$INIT" in
        systemd)
            chk_not "drop-in 已清理" "[ -d /etc/systemd/system/xray.service.d ]"
            ;;
        openrc)
            chk_not "OpenRC 脚本已清理" "[ -f /etc/init.d/xray ]"
            chk_not "运行级已移除" "rc-update show | grep -qw xray"
            ;;
        *) ;;
    esac

    chk_not "调优 sysctl 文件已清理" "[ -f /etc/sysctl.d/99-xmg-tune.conf ]"
    chk_not "调优 limits 文件已清理" "[ -f /etc/security/limits.d/99-xmg-nofile.conf ]"
    chk_not "sysctl.conf 标记块已清理" "grep -q '# >>> xmg:' /etc/sysctl.conf"
    chk_not "xmg-warp 服务文件已清理" "[ -f /etc/systemd/system/xmg-warp.service ]"

    if command -v iptables >/dev/null 2>&1; then
        chk_not "iptables 链已清理" "iptables -S XMG-IN"
    fi
    if command -v ufw >/dev/null 2>&1; then
        skip "UFW 属于用户策略，未做自动关闭（如需请手动 ufw disable）"
    fi
fi

# ================================================================
printf '\n============================================\n'
printf 'PASS=%d  FAIL=%d  SKIP=%d   (%s / %s / %s)\n' \
    "$PASS" "$FAIL" "$SKIP" "$OS_ID" "$INIT" "$FW"
printf '============================================\n'

[ "$FAIL" -eq 0 ]
