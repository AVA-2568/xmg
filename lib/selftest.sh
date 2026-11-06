#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# selftest.sh - 安装后一致性自检（随安装包一起落盘，不依赖仓库）
#
# 与 doctor 的分工：
#   doctor   面向运行状态，输出人类可读的体检卡片
#   selftest 面向安装一致性，逐项断言并以退出码表达结果（适合交付验收 / CI）
#
# 默认全部只读：不写配置、不重启服务、不改防火墙，可随时执行
#
# 用法：
#   xmg selftest            # 全部断言，FAIL 时退出码 1
#   xmg selftest -q         # 只显示 FAIL / WARN
#

if [ -z "${BASH_VERSION:-}" ]; then
    echo "selftest.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

if [ "${XMG_SELFTEST_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_SELFTEST_SH_LOADED=1

# 依赖 os.sh（发行版 / init / 包管理器抽象）
if ! declare -F xmg_svc_supported >/dev/null 2>&1; then
    for _xmg_os_f in "${XMG_LIB_DIR:-/opt/xmg/lib}/os.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/os.sh"; do
        if [ -r "$_xmg_os_f" ]; then
            # shellcheck source=/dev/null
            source "$_xmg_os_f"
            break
        fi
    done
    unset _xmg_os_f
fi

# 状态读取（端口、开关）按需引入
if ! declare -F xmg_state_get >/dev/null 2>&1; then
    for _xmg_st_f in "${XMG_LIB_DIR:-/opt/xmg/lib}/state.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/state.sh"; do
        if [ -r "$_xmg_st_f" ]; then
            # shellcheck source=/dev/null
            source "$_xmg_st_f"
            break
        fi
    done
    unset _xmg_st_f
fi

XMG_SELFTEST_PASS=0
XMG_SELFTEST_FAIL=0
XMG_SELFTEST_WARN=0
XMG_SELFTEST_QUIET="${XMG_SELFTEST_QUIET:-0}"

# 独立加载兜底
if ! declare -F xmg_error >/dev/null 2>&1; then
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi

_st_pass() {
    XMG_SELFTEST_PASS=$((XMG_SELFTEST_PASS + 1))
    [ "$XMG_SELFTEST_QUIET" = "1" ] || printf '  [PASS] %s\n' "$*"
}

_st_fail() {
    XMG_SELFTEST_FAIL=$((XMG_SELFTEST_FAIL + 1))
    printf '  [FAIL] %s\n' "$*"
}

_st_warn() {
    XMG_SELFTEST_WARN=$((XMG_SELFTEST_WARN + 1))
    printf '  [WARN] %s\n' "$*"
}

_st_section() {
    printf '\n[%s]\n' "$*"
}

# 端口是否处于 LISTEN（不依赖 ss/netstat）
_st_port_listening() {
    local port="$1"
    local hex=""

    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    hex="$(printf '%04X' "$port" 2>/dev/null)" || return 1

    grep -qi ":${hex} " /proc/net/tcp 2>/dev/null && return 0
    grep -qi ":${hex} " /proc/net/tcp6 2>/dev/null && return 0
    return 1
}

# ===== 1. 环境识别一致性 =====
_st_check_env() {
    _st_section "环境识别"

    xmg_os_detect force

    local id="" like="" family=""
    if [ -r /etc/os-release ]; then
        id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | head -1 | tr -d '"'\''\r')"
        like="$(sed -n 's/^ID_LIKE=//p' /etc/os-release 2>/dev/null | head -1 | tr -d '"'\''\r')"
    fi
    family="$(xmg_os_family_resolve "$id" "$like")"

    if [ "$family" = "$XMG_OS_FAMILY" ]; then
        _st_pass "发行版家族一致: $XMG_OS_FAMILY (${XMG_OS_PRETTY:-unknown})"
    else
        _st_fail "发行版家族不一致: 探测=$XMG_OS_FAMILY 独立解析=$family (id=$id)"
    fi

    case "$XMG_INIT_SYSTEM" in
        systemd|openrc|sysvinit)
            _st_pass "init 系统: $XMG_INIT_SYSTEM"
            ;;
        *)
            _st_warn "未识别到受支持的 init 系统，服务相关项将跳过"
            ;;
    esac

    local pkg=""
    pkg="$(xmg_pkg_mgr)"
    if [ "$pkg" != "none" ]; then
        _st_pass "包管理器: $pkg"
    else
        _st_warn "未识别到包管理器"
    fi
}

# ===== 2. 安装完整性 =====
_st_check_files() {
    _st_section "安装完整性"

    local bin="${XMG_BIN:-${XMG_BIN_DIR:-/opt/xmg/bin}/xmg}"
    if [ -e "$bin" ]; then
        _st_pass "命令入口存在: $bin"
    else
        _st_fail "命令入口缺失: $bin"
    fi

    local lib_dir="${XMG_LIB_DIR:-/opt/xmg/lib}"
    local m=""
    local missing=""
    for m in os.sh common.sh state.sh render.sh proxy.sh core.sh xray.sh; do
        [ -f "$lib_dir/$m" ] || missing="$missing $m"
    done
    if [ -z "$missing" ]; then
        _st_pass "核心模块齐全"
    else
        _st_fail "核心模块缺失:$missing"
    fi

    # 清单与实际落盘比对，能发现升级中断导致的半截安装
    local manifest="${XMG_HOME}/xmg.files"
    if [ -r "$manifest" ]; then
        local entry="" absent=0
        while IFS= read -r entry || [ -n "$entry" ]; do
            case "$entry" in
                ''|'#'*) continue ;;
                lib/*.sh) [ -f "$lib_dir/${entry##*/}" ] || absent=$((absent + 1)) ;;
            esac
        done < "$manifest"
        if [ "$absent" -eq 0 ]; then
            _st_pass "清单内模块全部落盘"
        else
            _st_fail "清单内有 $absent 个模块未落盘（安装可能中断）"
        fi
    else
        _st_warn "未找到安装清单: $manifest"
    fi
}

# ===== 3. 内核与配置 =====
_st_check_core() {
    _st_section "内核与配置"

    local bin=""
    if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
        bin="$(xmg_xray_get_bin 2>/dev/null || true)"
    elif declare -F xmg_xray_binary >/dev/null 2>&1; then
        bin="$(xmg_xray_binary 2>/dev/null || true)"
    fi
    # 允许返回裸命令名（走 PATH），统一解析为绝对路径
    case "$bin" in
        '') bin="/usr/local/bin/xray" ;;
        */*) ;;
        *) bin="$(command -v "$bin" 2>/dev/null || echo "/usr/local/bin/xray")" ;;
    esac

    if [ -x "$bin" ]; then
        _st_pass "内核已安装: $bin ($("$bin" version 2>/dev/null | head -n 1 || echo 版本未知))"
    else
        _st_fail "未找到 Xray 内核: $bin"
        return 0
    fi

    local cfg="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
    if [ -s "$cfg" ]; then
        _st_pass "配置文件存在: $cfg"
    else
        _st_fail "配置文件缺失: $cfg（可执行 xmg proxy apply 生成）"
        return 0
    fi

    if "$bin" run -test -config "$cfg" >/dev/null 2>&1 \
        || "$bin" run -test -c "$cfg" >/dev/null 2>&1 \
        || "$bin" -test -config "$cfg" >/dev/null 2>&1; then
        _st_pass "配置语法校验通过"
    else
        _st_fail "配置语法校验失败: $cfg"
    fi
}

# ===== 4. 服务注册与运行态 =====
_st_check_service() {
    _st_section "服务注册"

    if ! xmg_svc_supported; then
        _st_warn "init=$XMG_INIT_SYSTEM，跳过服务注册检查"
        return 0
    fi

    local svc="${XMG_XRAY_SERVICE:-xray}"

    if xmg_init_use_systemd_units; then
        local unit=""
        for unit in "/etc/systemd/system/${svc}.service" "/lib/systemd/system/${svc}.service" "/usr/lib/systemd/system/${svc}.service"; do
            [ -f "$unit" ] && break || unit=""
        done
        if [ -n "$unit" ]; then
            _st_pass "systemd unit 存在: $unit"
        else
            _st_fail "systemd unit 不存在（可执行 xmg xray 重新注册）"
        fi

        local dropin="${XMG_SYSTEMD_DIR:-/etc/systemd/system}/${svc}.service.d/20-xmg.conf"
        if [ -f "$dropin" ] && grep -q 'GOMEMLIMIT=100MiB' "$dropin" 2>/dev/null; then
            _st_pass "内存抑制已注入: GOMEMLIMIT=100MiB"
        else
            _st_warn "未检测到 XMG drop-in 覆盖（内存抑制未生效）"
        fi

        if xmg_svc_is_enabled "$svc"; then
            _st_pass "已设置开机自启"
        else
            _st_fail "未设置开机自启"
        fi
    elif xmg_init_is_openrc; then
        local initd="${XMG_INITD_DIR:-/etc/init.d}/${svc}"
        if [ -f "$initd" ]; then
            _st_pass "OpenRC 服务脚本存在: $initd"
            if grep -q 'GOMEMLIMIT=100MiB' "$initd" 2>/dev/null; then
                _st_pass "内存抑制已注入: GOMEMLIMIT=100MiB"
            else
                _st_warn "OpenRC 脚本未包含 GOMEMLIMIT"
            fi
            if grep -q 'rc_ulimit' "$initd" 2>/dev/null; then
                _st_pass "nofile 上限已注入: rc_ulimit"
            else
                _st_warn "OpenRC 脚本未包含 rc_ulimit"
            fi
        else
            _st_fail "OpenRC 服务脚本不存在: $initd"
        fi

        if xmg_svc_is_enabled "$svc"; then
            _st_pass "已加入默认运行级"
        else
            _st_fail "未加入默认运行级"
        fi
    fi

    if xmg_svc_is_active "$svc"; then
        _st_pass "服务运行中"
    else
        local cfg="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
        if [ -s "$cfg" ]; then
            _st_fail "服务未运行（配置已存在，可执行 xmg xray restart 查看日志）"
        else
            _st_warn "服务未运行（尚未生成配置，属正常）"
        fi
    fi
}

# ===== 5. 监听端口 =====
_st_check_ports() {
    _st_section "监听端口"

    if ! declare -F xmg_state_get >/dev/null 2>&1; then
        _st_warn "状态模块不可用，跳过端口检查"
        return 0
    fi

    local socks_on="" vless_on="" port="" checked=0
    socks_on="$(xmg_state_get PROXY_SOCKS_ENABLED "0" 2>/dev/null || echo 0)"
    vless_on="$(xmg_state_get PROXY_VLESS_ENABLED "0" 2>/dev/null || echo 0)"

    if [ "$socks_on" = "1" ]; then
        port="$(xmg_state_get PROXY_SOCKS_PORT "1080" 2>/dev/null || echo 1080)"
        checked=$((checked + 1))
        if _st_port_listening "$port"; then
            _st_pass "SOCKS5 端口 $port 处于 LISTEN"
        else
            _st_fail "SOCKS5 端口 $port 未监听"
        fi
    fi

    if [ "$vless_on" = "1" ]; then
        port="$(xmg_state_get PROXY_VLESS_PORT "443" 2>/dev/null || echo 443)"
        checked=$((checked + 1))
        if _st_port_listening "$port"; then
            _st_pass "VLESS 端口 $port 处于 LISTEN"
        else
            _st_fail "VLESS 端口 $port 未监听"
        fi
    fi

    if [ "$checked" -eq 0 ]; then
        _st_warn "未启用任何入站，跳过端口检查"
    fi
}

# ===== 6. 防火墙 =====
_st_check_firewall() {
    _st_section "防火墙"

    local backend="iptables"
    if command -v ufw >/dev/null 2>&1; then
        backend="ufw"
    elif ! command -v iptables >/dev/null 2>&1; then
        _st_warn "未检测到 ufw / iptables，跳过"
        return 0
    fi

    if [ "$backend" = "ufw" ]; then
        if ufw status 2>/dev/null | grep -q 'Status: active'; then
            _st_pass "UFW 已启用"
            if ufw status 2>/dev/null | grep -q '22/tcp'; then
                _st_pass "SSH 端口已放行"
            else
                _st_warn "未见 22/tcp 放行规则（若 SSH 使用其他端口请确认已放行）"
            fi
        else
            _st_warn "UFW 未启用"
        fi
        return 0
    fi

    local enabled_file="${XMG_ETC_DIR:-/opt/xmg/etc}/firewall/enabled"
    if [ -f "$enabled_file" ]; then
        if iptables -S XMG-IN >/dev/null 2>&1; then
            _st_pass "iptables 链 XMG-IN 存在"
            if iptables -S INPUT 2>/dev/null | grep -q -- '-j XMG-IN'; then
                _st_pass "XMG-IN 已挂载到 INPUT"
            else
                _st_fail "XMG-IN 未挂载到 INPUT（规则未生效）"
            fi
            if [ -e /proc/net/if_inet6 ]; then
                if ip6tables -S XMG-IN 2>/dev/null | grep -q -- 'icmpv6-type 135'; then
                    _st_pass "IPv6 侧已放通 NDP"
                else
                    _st_warn "IPv6 侧未放通 NDP，邻居发现可能被拦截"
                fi
            fi
        else
            _st_fail "已标记启用但 XMG-IN 链不存在（可执行 xmg firewall reload）"
        fi
    else
        _st_warn "iptables 防火墙未启用（XMG 侧无 XMG-IN 链）"
    fi
}

# ===== 7. 调优持久化 =====
_st_check_tune() {
    _st_section "调优持久化"

    local cc=""
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"

    if [ -f "${XMG_TUNE_SYSCTL_BBR_CONF:-/etc/sysctl.d/99-xmg-bbr.conf}" ]; then
        if [ "$cc" = "bbr" ]; then
            _st_pass "BBR 配置已落盘且当前生效"
        else
            _st_warn "BBR 配置已落盘但当前拥塞控制为 $cc（重启或内核不支持）"
        fi
    else
        _st_warn "未配置 BBR（可选）"
    fi

    if [ -f "${XMG_TUNE_SYSCTL_NET_CONF:-/etc/sysctl.d/99-xmg-tune.conf}" ]; then
        _st_pass "网络调优配置已落盘"
    fi

    if [ -f "${XMG_TUNE_LIMITS_CONF:-/etc/security/limits.d/99-xmg-nofile.conf}" ]; then
        _st_pass "nofile limits 已落盘"
    fi

    # OpenRC 依赖 /etc/sysctl.conf 才能开机恢复
    if [ "$XMG_INIT_SYSTEM" = "openrc" ] && [ -f "${XMG_TUNE_SYSCTL_NET_CONF:-/etc/sysctl.d/99-xmg-tune.conf}" ]; then
        if grep -q '# >>> xmg:' /etc/sysctl.conf 2>/dev/null; then
            _st_pass "/etc/sysctl.conf 已同步标记块"
        else
            _st_fail "/etc/sysctl.conf 缺少 XMG 标记块，重启后调优会丢失"
        fi
    fi
}

# ===== 8. DNS =====
_st_check_dns() {
    _st_section "DNS"

    local resolv="${XMG_RESOLV_CONF_FILE:-/etc/resolv.conf}"
    if [ -r "$resolv" ]; then
        if grep -qE '^[[:space:]]*nameserver[[:space:]]+' "$resolv" 2>/dev/null; then
            _st_pass "resolv.conf 含有效 nameserver"
        else
            _st_fail "$resolv 没有任何 nameserver，域名解析不可用"
        fi
    else
        _st_fail "缺少 $resolv"
    fi

    local unbound_conf="${XMG_TUNE_UNBOUND_CONF:-/etc/unbound/unbound.conf}"
    if [ -f "$unbound_conf" ] && grep -q 'forward-tls-upstream: yes' "$unbound_conf" 2>/dev/null; then
        if xmg_svc_is_active unbound 2>/dev/null; then
            _st_pass "DoT(unbound) 运行中"
        else
            _st_fail "unbound 配置存在但服务未运行，本机 DNS 可能不可用"
        fi
    fi
}

# ===== 入口 =====
xmg_selftest_run() {
    local only_quiet=0
    local arg=""

    for arg in "$@"; do
        case "$arg" in
            -q|--quiet) only_quiet=1 ;;
            -h|--help)
                cat <<'USAGE'
xmg selftest - 安装一致性自检（只读，不修改任何配置）

用法:
  xmg selftest           全部断言，FAIL 时退出码 1
  xmg selftest -q        只显示 FAIL / WARN
  xmg selftest --help    显示本帮助

检查项:
  环境识别一致性 / 安装完整性（含清单比对）/ 内核与配置语法
  服务注册与运行态 / 入站端口监听 / 防火墙链与 IPv6 NDP
  调优持久化 / DNS 可用性
USAGE
                return 0
                ;;
            *) xmg_error "未知参数: $arg"; return 2 ;;
        esac
    done

    XMG_SELFTEST_QUIET="$only_quiet"
    XMG_SELFTEST_PASS=0
    XMG_SELFTEST_FAIL=0
    XMG_SELFTEST_WARN=0

    printf 'XMG 安装自检（只读，不会修改任何配置）\n'
    printf '主机: %s | 发行版: %s | init: %s\n' \
        "$(hostname 2>/dev/null || echo unknown)" "${XMG_OS_PRETTY:-unknown}" "$XMG_INIT_SYSTEM"

    _st_check_env
    _st_check_files
    _st_check_core
    _st_check_service
    _st_check_ports
    _st_check_firewall
    _st_check_tune
    _st_check_dns

    printf '\n--------------------------------------------\n'
    printf 'PASS=%d  FAIL=%d  WARN=%d\n' \
        "$XMG_SELFTEST_PASS" "$XMG_SELFTEST_FAIL" "$XMG_SELFTEST_WARN"
    printf '%s\n' '--------------------------------------------'

    if [ "$XMG_SELFTEST_FAIL" -gt 0 ]; then
        printf '结论: 存在 %d 项不一致，请按上面的 FAIL 项处理\n' "$XMG_SELFTEST_FAIL"
        return 1
    fi

    printf '结论: 安装一致性检查通过\n'
    return 0
}
