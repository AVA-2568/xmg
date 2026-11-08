#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# firewall.sh - XMG 防火墙管理模块
#
# 说明：
#   - 双后端：ufw（Debian/Ubuntu 系）与 iptables（Alpine / 极简系统）
#   - 默认放行 22/tcp、80/tcp、443/tcp，并自适应当前 SSH 端口
#   - 启用前会提示用户确认，避免 SSH 断连
#   - iptables 后端放行列表持久化在 /opt/xmg/etc/firewall/allow.list，
#     由 OpenRC 服务 xmg-firewall 开机重放
#   - 文件内容应使用 UTF-8 编码保存
#

# ===== 安全加载 =====
if [ "${XMG_FIREWALL_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_FIREWALL_SH_LOADED=1

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

# XMG_MENU_LABEL: 防火墙管理

# ===== 依赖加载 =====
_XMG_FW_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_XMG_FW_SELF_DIR="$_XMG_FW_LIBDIR"
if ! declare -F xmg_info >/dev/null 2>&1; then
    if [ -f "$_XMG_FW_LIBDIR/common.sh" ]; then
        # shellcheck source=lib/common.sh
        source "$_XMG_FW_LIBDIR/common.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/common.sh" ]; then
        # shellcheck source=lib/common.sh
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/common.sh"
    fi
fi

if ! declare -F xmg_ssh_effective >/dev/null 2>&1; then
    if [ -f "$_XMG_FW_LIBDIR/ssh.sh" ]; then
        # shellcheck source=lib/ssh.sh
        source "$_XMG_FW_LIBDIR/ssh.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/ssh.sh" ]; then
        # shellcheck source=lib/ssh.sh
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/ssh.sh"
    fi
fi
unset _XMG_FW_LIBDIR

# ===== 依赖兜底 =====
if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info()  { printf '[INFO] %s\n' "$*"; }
fi
if ! declare -F xmg_warn >/dev/null 2>&1; then
    xmg_warn()  { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_error >/dev/null 2>&1; then
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_die >/dev/null 2>&1; then
    xmg_die()   { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fi
if ! declare -F xmg_cmd_exists >/dev/null 2>&1; then
    xmg_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
fi
if ! declare -F xmg_require_root >/dev/null 2>&1; then
    xmg_require_root() {
        if [ "$(id -u)" -ne 0 ]; then
            xmg_die "请使用 root 用户运行，或使用 sudo 执行"
        fi
    }
fi
if ! declare -F xmg_confirm >/dev/null 2>&1; then
    xmg_confirm() {
        local prompt="${1:-确认继续?}"
        local answer=""
        printf '%s [y/N]: ' "$prompt"
        read -r answer || return 1
        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            *) return 1 ;;
        esac
    }
fi
if ! declare -F xmg_pause >/dev/null 2>&1; then
    xmg_pause() {
        printf '\n按 Enter 返回...'
        read -r _ || true
    }
fi

XMG_UFW_DEFAULT_CONF="${XMG_UFW_DEFAULT_CONF:-/etc/default/ufw}"

# ===== iptables 后端配置 =====
XMG_FW_BACKEND="${XMG_FW_BACKEND:-auto}"
XMG_FW_CHAIN="${XMG_FW_CHAIN:-XMG-IN}"
XMG_FW_RULES_DIR="${XMG_FW_RULES_DIR:-${XMG_ETC_DIR:-/opt/xmg/etc}/firewall}"
XMG_FW_ALLOW_FILE="${XMG_FW_ALLOW_FILE:-$XMG_FW_RULES_DIR/allow.list}"
XMG_FW_ENABLED_FILE="${XMG_FW_ENABLED_FILE:-$XMG_FW_RULES_DIR/enabled}"
XMG_FW_INITD="${XMG_FW_INITD:-/etc/init.d/xmg-firewall}"

# 后端选择：auto 优先 ufw，缺失则用 iptables
xmg_firewall_backend() {
    case "$XMG_FW_BACKEND" in
        ufw|iptables)
            printf '%s\n' "$XMG_FW_BACKEND"
            return 0
            ;;
    esac

    xmg_os_detect

    if xmg_cmd_exists ufw; then
        printf 'ufw\n'
    elif [ "$XMG_OS_FAMILY" = "debian" ] || [ "$XMG_OS_FAMILY" = "unknown" ]; then
        # Debian/Ubuntu 默认不预装 ufw，保持原有「安装 UFW」语义
        printf 'ufw\n'
    elif xmg_os_is_alpine; then
        printf 'iptables\n'
    elif xmg_cmd_exists iptables; then
        printf 'iptables\n'
    else
        printf 'ufw\n'
    fi
}

xmg_firewall_is_ufw() {
    [ "$(xmg_firewall_backend)" = "ufw" ]
}

# ==================================================================
# ufw 后端
# ==================================================================

xmg_firewall_need_ufw() {
    if ! xmg_cmd_exists ufw; then
        xmg_die "ufw 未安装，请先在菜单中执行「安装防火墙」。安装方式: $(xmg_pkg_hint ufw)"
    fi
}

# 检查并纠偏 /etc/default/ufw 中的 IPV6=yes
xmg_firewall_fix_ipv6() {
    local ufw_conf="${XMG_UFW_DEFAULT_CONF:-/etc/default/ufw}"
    [ -f "$ufw_conf" ] || return 0

    # 用 grep 做大小写兼容判断，避免依赖 GNU sed 的 I 修饰符（BusyBox sed 不支持）
    if grep -qiE '^[[:space:]]*IPV6=[[:space:]]*no' "$ufw_conf"; then
        xmg_warn "检测到 $ufw_conf 中配置为 IPV6=no，正在自动修正为 IPV6=yes 防止 IPv6 流量阻断..."
        awk '
            tolower($0) ~ /^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*no/ { print "IPV6=yes"; next }
            { print }
        ' "$ufw_conf" > "${ufw_conf}.xmg-tmp" 2>/dev/null && \
            cat "${ufw_conf}.xmg-tmp" > "$ufw_conf" && \
            rm -f "${ufw_conf}.xmg-tmp" && \
            xmg_info "已修正 $ufw_conf: IPV6=yes" || \
            xmg_warn "修正 $ufw_conf 失败，请手动确认 IPV6 配置"
    fi
}

# ==================================================================
# iptables 后端（Alpine / 无 ufw 环境）
# ==================================================================

# 当前主机可用的协议族列表
#   - 4 始终尝试（127.0.0.1 在任何栈上都可用）
#   - 6 仅在系统确实启用 IPv6 且存在 ip6tables 时纳入，避免纯 IPv4 机器上刷屏告警
# XMG_FW_IPV6=0|1 可强制开关（排查与测试用）
xmg_fw_families() {
    local fams="4"

    case "${XMG_FW_IPV6:-}" in
        0)
            printf '%s\n' "$fams"
            return 0
            ;;
        1)
            printf '%s 6\n' "$fams"
            return 0
            ;;
    esac

    # /proc/net/if_inet6 不存在说明内核未启用 IPv6
    if [ -e /proc/net/if_inet6 ] && xmg_cmd_exists ip6tables; then
        fams="4 6"
    fi

    printf '%s\n' "$fams"
}

# 取指定协议族的 iptables 命令
# XMG_FW_IPT_DRY_RUN=1 时仅回显命令不执行，便于排查规则构建问题
xmg_fw_ipt_bin() {
    local dry="${XMG_FW_IPT_DRY_RUN:-0}"
    case "$1" in
        6)
            if xmg_cmd_exists ip6tables; then
                printf 'ip6tables\n'
            elif [ "$dry" = "1" ]; then
                printf 'ip6tables\n'
            fi
            ;;
        *)
            if xmg_cmd_exists iptables; then
                printf 'iptables\n'
            elif [ "$dry" = "1" ]; then
                printf 'iptables\n'
            fi
            ;;
    esac
    return 0
}

# 执行（或 dry-run 回显）单条规则命令
# dry-run 下 -C（存在性检查）一律返回「不存在」，使回显结果等同于全新系统要建立的完整规则
_xmg_fw_ipt_exec() {
    local bin="$1"
    shift
    if [ "${XMG_FW_IPT_DRY_RUN:-0}" = "1" ]; then
        printf '%s %s\n' "$bin" "$*"
        case "${1:-}" in
            -C) return 1 ;;
        esac
        return 0
    fi
    "$bin" "$@"
}

xmg_fw_ipt_ensure_tools() {
    if [ "${XMG_FW_IPT_DRY_RUN:-0}" = "1" ]; then
        return 0
    fi
    if ! xmg_cmd_exists iptables; then
        xmg_require_root
        xmg_info "未检测到 iptables，尝试安装: $(xmg_pkg_hint iptables)"
        if ! xmg_pkg_install iptables >/dev/null 2>&1; then
            xmg_error "iptables 安装失败，请手动安装后重试"
            return 1
        fi
    fi
    return 0
}

# 允许列表读写：每行 "<port>/<proto>"
xmg_fw_allow_list() {
    [ -r "$XMG_FW_ALLOW_FILE" ] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$XMG_FW_ALLOW_FILE" 2>/dev/null || true
}

xmg_fw_allow_add() {
    local port="$1"
    local proto="${2:-tcp}"
    local entry="${port}/${proto}"

    mkdir -p "$XMG_FW_RULES_DIR" || return 1
    touch "$XMG_FW_ALLOW_FILE" 2>/dev/null || return 1

    if xmg_fw_allow_list | grep -qx "$entry"; then
        return 0
    fi
    printf '%s\n' "$entry" >> "$XMG_FW_ALLOW_FILE"
}

xmg_fw_ipt_apply() {
    local enabled=0
    [ -f "$XMG_FW_ENABLED_FILE" ] && enabled=1

    if ! xmg_fw_ipt_ensure_tools; then
        return 1
    fi

    local fam=""
    local bin=""
    local ok=0
    local port="" proto=""

    for fam in $(xmg_fw_families); do
        bin="$(xmg_fw_ipt_bin "$fam")"
        [ -n "$bin" ] || continue

        # 链不存在则创建，存在则清空后重建（幂等）
        _xmg_fw_ipt_exec "$bin" -N "$XMG_FW_CHAIN" 2>/dev/null || true
        if ! _xmg_fw_ipt_exec "$bin" -F "$XMG_FW_CHAIN" 2>/dev/null; then
            xmg_warn "$bin 无法操作链 $XMG_FW_CHAIN（内核模块缺失或无 CAP_NET_ADMIN）"
            continue
        fi

        _xmg_fw_ipt_exec "$bin" -A "$XMG_FW_CHAIN" -i lo -j RETURN 2>/dev/null || true
        if ! _xmg_fw_ipt_exec "$bin" -A "$XMG_FW_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null; then
            _xmg_fw_ipt_exec "$bin" -A "$XMG_FW_CHAIN" -m state --state ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
        fi

        # IPv6 必需的最小控制面放通：
        #   133-136 NDP（路由通告/请求、邻居请求/通告）——DROP 掉会直接断 IPv6
        #   128/129 ICMPv6 echo —— 便于连通性排查
        #   546     DHCPv6 客户端 —— 否则地址续租失败
        if [ "$fam" = "6" ]; then
            local icmp_type=""
            for icmp_type in 133 134 135 136 128 129; do
                _xmg_fw_ipt_exec "$bin" -A "$XMG_FW_CHAIN" -p ipv6-icmp --icmpv6-type "$icmp_type" -j RETURN 2>/dev/null || true
            done
            _xmg_fw_ipt_exec "$bin" -A "$XMG_FW_CHAIN" -p udp --dport 546 -j RETURN 2>/dev/null || true
        fi

        # IPv4 DHCP 客户端（68/udp）：避免租约续期时被默认 DROP 拦掉
        if [ "$fam" = "4" ]; then
            _xmg_fw_ipt_exec "$bin" -A "$XMG_FW_CHAIN" -p udp --dport 68 -j RETURN 2>/dev/null || true
        fi

        local allowed_ok=0
        while IFS='/' read -r port proto; do
            [ -n "$port" ] || continue
            proto="${proto:-tcp}"
            if _xmg_fw_ipt_exec "$bin" -A "$XMG_FW_CHAIN" -p "$proto" --dport "$port" -j RETURN 2>/dev/null; then
                allowed_ok=$((allowed_ok + 1))
            else
                xmg_warn "$bin 放行 ${port}/${proto} 失败"
            fi
        done <<EOF
$(xmg_fw_allow_list)
EOF

        if [ "$enabled" -eq 1 ]; then
            # 防锁死：一条放行规则都没成功时绝不挂 DROP，否则整机失联
            if [ "$allowed_ok" -eq 0 ]; then
                xmg_error "$bin 未能成功下发任何放行规则，已跳过默认 DROP 以避免锁死"
                "$bin" -D INPUT -j "$XMG_FW_CHAIN" 2>/dev/null || true
                continue
            fi

            _xmg_fw_ipt_exec "$bin" -A "$XMG_FW_CHAIN" -j DROP 2>/dev/null || true
            if ! _xmg_fw_ipt_exec "$bin" -C INPUT -j "$XMG_FW_CHAIN" 2>/dev/null; then
                _xmg_fw_ipt_exec "$bin" -I INPUT 1 -j "$XMG_FW_CHAIN" 2>/dev/null || \
                    xmg_warn "$bin 挂载 $XMG_FW_CHAIN 到 INPUT 失败"
            fi
        else
            # 未启用：摘掉跳转，保持流量原样放通
            _xmg_fw_ipt_exec "$bin" -D INPUT -j "$XMG_FW_CHAIN" 2>/dev/null || true
        fi

        ok=1
    done

    [ "$ok" -eq 1 ] || return 1
    return 0
}

xmg_fw_ipt_flush() {
    local fam="" bin=""
    for fam in $(xmg_fw_families); do
        bin="$(xmg_fw_ipt_bin "$fam")"
        [ -n "$bin" ] || continue
        _xmg_fw_ipt_exec "$bin" -D INPUT -j "$XMG_FW_CHAIN" 2>/dev/null || true
        _xmg_fw_ipt_exec "$bin" -F "$XMG_FW_CHAIN" 2>/dev/null || true
        _xmg_fw_ipt_exec "$bin" -X "$XMG_FW_CHAIN" 2>/dev/null || true
    done
    return 0
}

# 生成 OpenRC 开机重放服务
xmg_fw_ipt_write_openrc() {
    [ -d "$(dirname "$XMG_FW_INITD")" ] || return 0

    local xmg_bin="${XMG_LINK:-${XMG_BIN_DIR:-/opt/xmg/bin}/xmg}"
    [ -x "$xmg_bin" ] || xmg_bin="/usr/local/bin/xmg"

    cat > "$XMG_FW_INITD" <<EOF
#!/sbin/openrc-run
# XMG 管理的防火墙规则重放服务（由 xmg 自动生成，请勿手工编辑）
description="XMG firewall rules (iptables)"

depend() {
    need net
    after iptables
}

start() {
    ebegin "Loading XMG firewall rules"
    $xmg_bin firewall reload >/dev/null 2>&1
    eend \$?
}

stop() {
    ebegin "Flushing XMG firewall rules"
    $xmg_bin firewall flush >/dev/null 2>&1
    eend \$?
}
EOF
    chmod 0755 "$XMG_FW_INITD" 2>/dev/null || true
    return 0
}

xmg_fw_ipt_status() {
    local enabled="disabled"
    [ -f "$XMG_FW_ENABLED_FILE" ] && enabled="enabled"

    printf '后端       : iptables (链 %s)\n' "$XMG_FW_CHAIN"
    printf '策略       : %s\n' "$enabled"
    printf '允许列表   : %s\n' "$XMG_FW_ALLOW_FILE"
    echo
    printf '放行规则   :\n'
    if [ -n "$(xmg_fw_allow_list)" ]; then
        xmg_fw_allow_list | sed 's/^/  - /'
    else
        echo "  (空)"
    fi

    echo
    local fam="" bin=""
    for fam in $(xmg_fw_families); do
        bin="$(xmg_fw_ipt_bin "$fam")"
        [ -n "$bin" ] || continue
        printf '== %s ==\n' "$bin"
        "$bin" -S "$XMG_FW_CHAIN" 2>/dev/null || echo "  链未创建（防火墙未启用或规则未应用）"
    done
}

# ===== 统一入口 =====

xmg_firewall_install() {
    xmg_require_root

    if xmg_firewall_is_ufw; then
        if xmg_cmd_exists ufw; then
            xmg_info "ufw 已安装: $(command -v ufw)"
            return 0
        fi

        xmg_info "安装 ufw: $(xmg_pkg_hint ufw)"
        if ! xmg_pkg_install ufw; then
            xmg_warn "ufw 安装失败，包索引可能过期（可执行 xmg maint 更新源后重试）"
            return 1
        fi
        xmg_info "ufw 安装完成"
        return 0
    fi

    xmg_fw_ipt_ensure_tools || return 1
    xmg_info "iptables 已就绪: $(command -v iptables)"
}

xmg_firewall_status() {
    if xmg_firewall_is_ufw; then
        xmg_firewall_need_ufw
        ufw status verbose || true
        return 0
    fi
    xmg_fw_ipt_status
}

# 只读加载状态模块：不建目录、不写默认值，firewall allow 不应产生副作用
_xmg_fw_load_state() {
    declare -F xmg_state_get >/dev/null 2>&1 && return 0
    local dir="" f=""
    for dir in "${XMG_LIB_DIR:-}" "${_XMG_FW_SELF_DIR:-}" "${XMG_HOME:-/opt/xmg}/lib"; do
        [ -n "$dir" ] || continue
        f="$dir/state.sh"
        if [ -r "$f" ]; then
            # shellcheck source=/dev/null
            source "$f" && return 0
        fi
    done
    return 1
}

_xmg_fw_enabled_proxy_ports() {
    _xmg_fw_load_state || return 0
    if declare -F xmg_state_load >/dev/null 2>&1; then
        xmg_state_load >/dev/null 2>&1 || true
    fi

    local name="" on="" port="" seen=" "
    for name in SOCKS VLESS REALITY; do
        on="$(xmg_state_get "PROXY_${name}_ENABLED" 0 2>/dev/null || printf 0)"
        [ "$on" = "1" ] || continue
        port="$(xmg_state_get "PROXY_${name}_PORT" "" 2>/dev/null || true)"
        case "$port" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || continue
        case "$seen" in
            *" $port "*) continue ;;
        esac
        seen="$seen$port "
        printf '%s\n' "$port"
    done
    return 0
}

xmg_firewall_allow_basic() {
    xmg_require_root

    # 自适应当前生效的 SSH 端口，防锁死
    local cur_ssh_port=""
    if declare -F xmg_ssh_effective >/dev/null 2>&1; then
        cur_ssh_port="$(xmg_ssh_effective port 2>/dev/null || true)"
    fi
    case "$cur_ssh_port" in
        ''|*[!0-9]*) cur_ssh_port="" ;;
        *)
            if [ "$cur_ssh_port" -lt 1 ] || [ "$cur_ssh_port" -gt 65535 ]; then
                cur_ssh_port=""
            fi
            ;;
    esac

    # 代理入站端口（按 state 中已启用的方案补齐，避免开了防火墙就连不上）
    local proxy_ports="" proxy_added="" socks_udp_on="0"
    _xmg_fw_load_state >/dev/null 2>&1 || true
    # 必须在父 shell 里加载一次：上面的端口枚举跑在 $( ) 子 shell，状态不会回传
    if declare -F xmg_state_load >/dev/null 2>&1; then
        xmg_state_load >/dev/null 2>&1 || true
    fi
    proxy_ports="$(_xmg_fw_enabled_proxy_ports 2>/dev/null || true)"
    if declare -F xmg_state_get >/dev/null 2>&1; then
        socks_udp_on="$(xmg_state_get PROXY_SOCKS_UDP 0 2>/dev/null || printf 0)"
    fi

    if xmg_firewall_is_ufw; then
        xmg_firewall_need_ufw
        xmg_firewall_fix_ipv6

        ufw allow 22/tcp comment 'XMG SSH' || xmg_die "放行 22/tcp 失败"
        ufw allow 80/tcp comment 'XMG HTTP' || xmg_die "放行 80/tcp 失败"
        ufw allow 443/tcp comment 'XMG HTTPS' || xmg_die "放行 443/tcp 失败"

        if [ -n "$cur_ssh_port" ] && [ "$cur_ssh_port" -ne 22 ]; then
            ufw allow "${cur_ssh_port}/tcp" comment "XMG SSH ${cur_ssh_port}" \
                || xmg_die "自适应放行自定义 SSH 端口 ${cur_ssh_port}/tcp 失败"
            xmg_info "检测到当前生效 SSH 端口为 ${cur_ssh_port}，已自适应放行 ${cur_ssh_port}/tcp 防锁死"
        fi

        local p=""
        for p in $proxy_ports; do
            case "$p" in
                22|80|443) continue ;;
            esac
            if [ -n "$cur_ssh_port" ] && [ "$p" = "$cur_ssh_port" ]; then
                continue
            fi
            ufw allow "${p}/tcp" comment 'XMG proxy' \
                || xmg_warn "放行代理端口 ${p}/tcp 失败"
            proxy_added="$proxy_added ${p}/tcp"
        done
        if [ "$socks_udp_on" = "1" ]; then
            local sp=""
            sp="$(xmg_state_get PROXY_SOCKS_PORT "" 2>/dev/null || true)"
            case "$sp" in
                ''|*[!0-9]*) ;;
                *)
                    ufw allow "${sp}/udp" comment 'XMG proxy UDP' \
                        || xmg_warn "放行 SOCKS5 UDP 端口 ${sp}/udp 失败"
                    proxy_added="$proxy_added ${sp}/udp"
                    ;;
            esac
        fi

        xmg_info "已放行 22/tcp、80/tcp、443/tcp"
        if [ -n "$cur_ssh_port" ] && [ "$cur_ssh_port" != "22" ]; then
            xmg_info "已同步放行自定义 SSH 端口: ${cur_ssh_port}/tcp"
        else
            xmg_warn "如果 SSH 不是 22 端口，请自行放行真实 SSH 端口"
        fi
        if [ -n "$proxy_added" ]; then
            xmg_info "已按当前代理配置放行:${proxy_added}"
        fi
        return 0
    fi

    xmg_fw_ipt_ensure_tools || return 1
    xmg_fw_allow_add 22 tcp
    xmg_fw_allow_add 80 tcp
    xmg_fw_allow_add 443 tcp
    if [ -n "$cur_ssh_port" ] && [ "$cur_ssh_port" -ne 22 ]; then
        xmg_fw_allow_add "$cur_ssh_port" tcp
        xmg_info "检测到当前生效 SSH 端口为 ${cur_ssh_port}，已加入放行列表防锁死"
    fi

    local p2=""
    for p2 in $proxy_ports; do
        case "$p2" in
            22|80|443) continue ;;
        esac
        if [ -n "$cur_ssh_port" ] && [ "$p2" = "$cur_ssh_port" ]; then
            continue
        fi
        xmg_fw_allow_add "$p2" tcp
        proxy_added="$proxy_added ${p2}/tcp"
    done
    if [ "$socks_udp_on" = "1" ]; then
        local sp2=""
        sp2="$(xmg_state_get PROXY_SOCKS_PORT "" 2>/dev/null || true)"
        case "$sp2" in
            ''|*[!0-9]*) ;;
            *)
                xmg_fw_allow_add "$sp2" udp
                proxy_added="$proxy_added ${sp2}/udp"
                ;;
        esac
    fi

    xmg_fw_ipt_apply || xmg_error "iptables 规则应用失败，请检查内核模块"
    xmg_info "已放行 22/tcp、80/tcp、443/tcp（写入 $XMG_FW_ALLOW_FILE）"
    if [ -n "$proxy_added" ]; then
        xmg_info "已按当前代理配置放行:${proxy_added}"
    fi
}

xmg_firewall_allow_custom_port() {
    local port="${1:-}"
    local proto="${2:-}"

    xmg_require_root

    if [ -z "$port" ]; then
        printf "请输入要放行的端口号: "
        read -r port || return 1
    fi

    case "$port" in
        ''|*[!0-9]*)
            xmg_warn "端口号无效: '$port'"
            return 1
            ;;
    esac

    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        xmg_warn "端口号范围应为 1-65535: '$port'"
        return 1
    fi

    if [ -z "$proto" ]; then
        if [ "$#" -ge 2 ]; then
            proto="tcp"
        elif [ "$#" -eq 1 ]; then
            proto="tcp"
        else
            printf "请输入协议 tcp/udp，默认 tcp: "
            read -r proto || proto="tcp"
        fi
    fi
    proto="${proto:-tcp}"

    case "$proto" in
        tcp|udp)
            ;;
        *)
            xmg_warn "协议无效，只支持 tcp 或 udp: '$proto'"
            return 1
            ;;
    esac

    if xmg_firewall_is_ufw; then
        xmg_firewall_need_ufw
        ufw allow "${port}/${proto}" comment "XMG custom ${port}/${proto}" \
            || xmg_die "放行 ${port}/${proto} 失败"
    else
        xmg_fw_ipt_ensure_tools || return 1
        xmg_fw_allow_add "$port" "$proto"
        xmg_fw_ipt_apply || xmg_warn "规则已记录，但应用失败（防火墙可能未启用）"
    fi

    xmg_info "已放行 ${port}/${proto}"
}

# 启用防火墙前确保当前 SSH 端口已放行 —— 两种后端共用
#   这是最后一道防呆：默认 deny/DROP 一旦生效而 SSH 端口没放行，当前会话断开即失联。
#   UFW 后端此前完全没有这一步，只有 iptables 分支做了。
_xmg_fw_ensure_ssh_allowed() {
    local ssh_port=""
    if declare -F xmg_ssh_get_port >/dev/null 2>&1; then
        ssh_port="$(xmg_ssh_get_port 2>/dev/null || true)"
    elif declare -F xmg_ssh_effective >/dev/null 2>&1; then
        ssh_port="$(xmg_ssh_effective port 2>/dev/null || true)"
    fi
    case "$ssh_port" in
        ''|*[!0-9]*) ssh_port="22" ;;
    esac
    [ "$ssh_port" -ge 1 ] 2>/dev/null && [ "$ssh_port" -le 65535 ] 2>/dev/null || ssh_port=22

    if xmg_firewall_is_ufw; then
        if ufw status 2>/dev/null | grep -qE "^${ssh_port}/tcp[[:space:]]+ALLOW"; then
            return 0
        fi
        # 同端口存在 DENY 时，allow 不一定能覆盖（最终顺序由 ufw 决定），先删再放行
        ufw delete deny "${ssh_port}/tcp" >/dev/null 2>&1 || true
        if ufw allow "${ssh_port}/tcp" comment 'XMG SSH guard' >/dev/null 2>&1; then
            # 复核：命令返回 0 不等于最终规则真的放行
            if ufw status 2>/dev/null | grep -qE "^${ssh_port}/tcp[[:space:]]+ALLOW"; then
                xmg_info "已自动放行当前 SSH 端口 ${ssh_port}/tcp，避免启用后锁死"
                return 0
            fi
        fi
        xmg_error "自动放行 SSH 端口 ${ssh_port}/tcp 失败，已中止启用（防止失联）"
        return 1
    fi

    if ! xmg_fw_allow_list | grep -qE "^${ssh_port}/(tcp|udp)$"; then
        xmg_fw_allow_add "$ssh_port" tcp || return 1
        xmg_info "已自动放行当前 SSH 端口 ${ssh_port}/tcp，避免启用后锁死"
    fi
    return 0
}

xmg_firewall_enable() {
    xmg_require_root

    xmg_warn "启用防火墙可能导致当前 SSH 连接断开，请确认 SSH 端口已经放行"
    xmg_warn "建议先执行“放行 SSH/HTTP/HTTPS”，再启用防火墙"

    if xmg_firewall_is_ufw; then
        # 守卫必须在 ufw 本体就绪之后：未装 ufw 时所有 ufw 调用都是 127，
        # 会把「本机还没装防火墙」误报成「放行 SSH 失败」并挡住安装引导
        xmg_firewall_need_ufw
        _xmg_fw_ensure_ssh_allowed || return 1
        xmg_firewall_fix_ipv6

        if xmg_confirm "确认启用 UFW 并设置默认策略为 deny incoming / allow outgoing?"; then
            ufw default deny incoming || xmg_die "设置默认入站策略失败"
            ufw default allow outgoing || xmg_die "设置默认出站策略失败"
            ufw --force enable || xmg_die "启用 UFW 失败"
            ufw status verbose || true
        else
            xmg_info "已取消"
        fi
        return 0
    fi

    xmg_fw_ipt_ensure_tools || return 1
    _xmg_fw_ensure_ssh_allowed || return 1

    if xmg_confirm "确认启用 iptables 防火墙 (默认拒绝入站 / 放通已配置端口)?"; then
        mkdir -p "$XMG_FW_RULES_DIR" || return 1
        : > "$XMG_FW_ENABLED_FILE"
        if ! xmg_fw_ipt_apply; then
            rm -f "$XMG_FW_ENABLED_FILE" 2>/dev/null || true
            xmg_error "iptables 规则应用失败，已回退为不启用状态"
            return 1
        fi
        xmg_fw_ipt_write_openrc
        if xmg_init_is_openrc; then
            xmg_svc_enable xmg-firewall >/dev/null 2>&1 \
                && xmg_info "xmg-firewall 已加入 default 运行级（开机自动重放规则）" \
                || xmg_warn "注册开机自启失败: rc-update add xmg-firewall default"
        fi
        xmg_info "防火墙已启用"
        xmg_fw_ipt_status
    else
        xmg_info "已取消"
    fi
}

xmg_firewall_disable() {
    xmg_require_root

    if xmg_firewall_is_ufw; then
        xmg_firewall_need_ufw
        if xmg_confirm "确认禁用 UFW?"; then
            ufw disable || xmg_die "禁用 UFW 失败"
            xmg_info "UFW 已禁用"
        else
            xmg_info "已取消"
        fi
        return 0
    fi

    if xmg_confirm "确认禁用 iptables 防火墙 (摘除 XMG 链，恢复全放通)?"; then
        rm -f "$XMG_FW_ENABLED_FILE" 2>/dev/null || true
        xmg_fw_ipt_flush
        xmg_svc_disable xmg-firewall >/dev/null 2>&1 || true
        xmg_info "防火墙已禁用（$XMG_FW_CHAIN 链已摘除）"
    else
        xmg_info "已取消"
    fi
}

# 开机重放入口（由 xmg-firewall 服务调用）：按当前允许列表重新应用
xmg_firewall_reload() {
    xmg_require_root
    xmg_fw_ipt_apply
}

xmg_firewall_flush() {
    xmg_require_root
    xmg_fw_ipt_flush
}

xmg_firewall_menu() {
    local choice=""

    while true; do
        clear
        echo "========== 防火墙管理 =========="
        echo "1. 查看防火墙状态"
        echo "2. 放行 SSH/HTTP/HTTPS"
        echo "3. 放行自定义端口"
        echo "4. 启用防火墙"
        echo "5. 禁用防火墙"
        echo "6. 安装防火墙组件"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - 当前后端: $(xmg_firewall_backend)（auto 模式: 有 ufw 用 ufw，否则用 iptables）"
        echo "  - Debian/Ubuntu 推荐 UFW；Alpine 使用 iptables + xmg-firewall 服务"
        echo "  - 启用前请确认 SSH 端口已经放行，避免远程断连"
        echo "  - 如果服务器还使用云安全组，请同时检查云平台入站规则"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_firewall_status || true
                xmg_pause
                ;;
            2)
                xmg_firewall_allow_basic || true
                xmg_pause
                ;;
            3)
                xmg_firewall_allow_custom_port || true
                xmg_pause
                ;;
            4)
                xmg_firewall_enable || true
                xmg_pause
                ;;
            5)
                xmg_firewall_disable || true
                xmg_pause
                ;;
            6)
                xmg_firewall_install || true
                xmg_pause
                ;;
            0)
                return 0
                ;;
            *)
                xmg_warn "无效选择"
                xmg_pause
                ;;
        esac
    done
}
