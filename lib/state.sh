#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# state.sh - Xray 配置状态层
#
# 说明：
#   - state.env 为配置唯一真相来源，config.json 是派生产物
#   - 扁平 KEY=value 格式，零依赖读写（目标机型无 python/jq，可能是 BusyBox）
#   - 本模块不做渲染，渲染见 render.sh
#
# 可移植性与开销约束（目标环境可能是 BusyBox 用户态，且是 0.5C/215M 低配机）：
#   - 只用 bash 内建 + POSIX 基础工具，不依赖 jq / python / GNU 专有选项
#   - 正则一律用 [[ =~ ]]，不依赖 grep -P / sed -E
#   - 写一次 state 的外部命令固定为 2 个（chmod + mv），其余全部走内建。
#     这既是为了低配机上的响应，也为了让本模块的测试能在受限环境里跑完。

#===== 安全加载 =====
if [ "${XMG_STATE_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_STATE_SH_LOADED=1

if [ -z "${BASH_VERSION:-}" ]; then
    echo "state.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 依赖 common.sh 的路径变量 =====
# 用 :- 赋值而非裸赋值，这样调用方（如测试）预设的路径不会被覆盖。
XMG_ETC_DIR="${XMG_ETC_DIR:-/opt/xmg/etc}"
XMG_XRAY_STATE_DIR="${XMG_XRAY_STATE_DIR:-$XMG_ETC_DIR/xray}"
XMG_STATE_FILE="${XMG_STATE_FILE:-$XMG_XRAY_STATE_DIR/state.env}"
export XMG_ETC_DIR XMG_XRAY_STATE_DIR XMG_STATE_FILE

# 提示函数的兜底定义。
# state.sh 理论上由 common.sh 先加载，但渲染器/CLI 的测试会单独 source 本文件，
# 此时 xmg_error 不存在会退化成 command not found（127），在 set -e 环境下还会
# 直接中断调用方。只在未定义时补，不覆盖 common.sh 的版本。
if ! declare -F xmg_error >/dev/null 2>&1; then
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_warn >/dev/null 2>&1; then
    xmg_warn() { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info() { printf '[INFO] %s\n' "$*"; }
fi

# 已载入的键值
declare -gA XMG_STATE=()
# 内存暂存区（草稿），用于状态批处理与原子提交
declare -gA XMG_STATE_STAGE=()

# ===== 默认值 =====
# 文档依据见 docs/superpowers/specs/2026-10-08-xray-config-layer-design.md
#
# 关联数组 XMG_STATE_DEFAULTS 由本函数输出构建，不在此处重复抄写，避免两处漂移。
# 用 printf 而非 cat <<EOF：heredoc 版的 cat 是一次 fork，这里是纯内建。
xmg_state_defaults() {
    printf '%s\n' \
        'PROXY_SOCKS_ENABLED=0' \
        'PROXY_SOCKS_LISTEN=0.0.0.0' \
        'PROXY_SOCKS_PORT=1080' \
        'PROXY_SOCKS_USER=' \
        'PROXY_SOCKS_PASS=' \
        'PROXY_SOCKS_UDP=0' \
        'PROXY_VLESS_ENABLED=0' \
        'PROXY_VLESS_LISTEN=0.0.0.0' \
        'PROXY_VLESS_PORT=443' \
        'PROXY_VLESS_DOMAIN=' \
        'PROXY_VLESS_UUID=' \
        'PROXY_VLESS_PATH=/' \
        'PROXY_VLESS_MODE=auto' \
        'PROXY_VLESS_CERT_SOURCE=user' \
        'PROXY_VLESS_CERT_FILE=' \
        'PROXY_VLESS_KEY_FILE=' \
        'XMG_BUFFER_SIZE=4' \
        'XMG_BACKUP_KEEP=5' \
        'XRAY_CHANNEL=preview' \
        'XRAY_PINNED_VERSION='
}

declare -gA XMG_STATE_DEFAULTS=()
while IFS= read -r _xmg_def_line; do
    XMG_STATE_DEFAULTS["${_xmg_def_line%%=*}"]="${_xmg_def_line#*=}"
done < <(xmg_state_defaults)
unset _xmg_def_line

# ===== 内部工具 =====
# 合法键名：字母或下划线开头，其余为字母数字下划线。
# 不校验就允许注入换行或 =，把 state.env 写坏，故在写入边界拦住。
_xmg_state_key_ok() {
    [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# 合法值：单行。= 允许出现（读侧按首个 = 切分），换行不允许。
_xmg_state_value_ok() {
    case "${1:-}" in
        *$'\n'*|*$'\r'*) return 1 ;;
    esac
    return 0
}

# IPv4 字面量：四段十进制0-255。拒绝前导零（"010" 会被 test 当八进制，且语义有歧义）。
_xmg_is_ipv4() {
    local a="${1:-}" p
    local -a o
    [[ "$a" == *.* ]] || return 1
    IFS='.' read -r -a o <<< "$a"
    [ "${#o[@]}" -eq 4 ] || return 1
    for p in "${o[@]}"; do
        [[ "$p" =~ ^[0-9]{1,3}$ ]] || return 1
        if [ "${#p}" -gt 1 ] && [ "${p:0:1}" = "0" ]; then
            return 1
        fi
        [ "$p" -le 255 ] || return 1
    done
    return 0
}

# 校验 IPv6 一侧（:: 左边或右边）的分组序列，并把分组数写入 _XMG_V6_GROUPS。
# 允许结尾是内嵌 IPv4（::ffff:1.2.3.4），按 2 个分组计。
# 调用方负责检查 :: 的出现次数与总分组数。
_xmg_ipv6_side() {
    local s="${1:-}" last="" p
    local -a parts
    _XMG_V6_GROUPS=0
    [ -n "$s" ] || return 0

    case "$s" in
        *:*)
            last="${s##*:}"
            if [ -n "$last" ] && [[ "$last" == *.* ]]; then
                _xmg_is_ipv4 "$last" || return 1
                _XMG_V6_GROUPS=2
                s="${s%:*}"
                [ -n "$s" ] || return 0
            fi
            ;;
    esac

    IFS=':' read -r -a parts <<< "$s"
    for p in "${parts[@]}"; do
        [ -n "$p" ] || return 1
        [ "${#p}" -le 4 ] || return 1
        [[ "$p" =~ ^[0-9A-Fa-f]+$ ]] || return 1
        _XMG_V6_GROUPS=$((_XMG_V6_GROUPS + 1))
    done
    return 0
}

# IPv6 字面量：无 :: 时恰好 8 个分组；有 :: 时至多一处，且显式分组不超过 7
#（:: 代表被压缩掉的至少一个分组）。
#
# 「至多一处 ::」不能用 glob `*:::*` 判断：那个模式里的 * 会跨越冒号匹配，
# 于是 2001:db8::8a2e 这类只含一处:: 的地址也会被判成含两处而误拒。
# 正确做法是掐掉第一处 :: 之后再查剩下的部分还含不含 ::。
_xmg_is_ipv6() {
    local a="${1:-}" head tail rest
    local g_head=0 g_tail=0

    case "$a" in
        *::*)
            rest="${a#*::}"
            case "$rest" in
                *::*) return 1 ;;
            esac
            head="${a%%::*}"
            tail="$rest"
            _xmg_ipv6_side "$head" || return 1
            g_head="$_XMG_V6_GROUPS"
            _xmg_ipv6_side "$tail" || return 1
            g_tail="$_XMG_V6_GROUPS"
            [ $((g_head + g_tail)) -le 7 ] || return 1
            ;;
        *)
            _xmg_ipv6_side "$a" || return 1
            [ "$_XMG_V6_GROUPS" -eq 8 ] || return 1
            ;;
    esac
    return 0
}

#===== 基础读写 =====

xmg_state_init() {
    if [ ! -d "$XMG_XRAY_STATE_DIR" ]; then
        mkdir -p "$XMG_XRAY_STATE_DIR" || {
            xmg_error "无法创建状态目录: $XMG_XRAY_STATE_DIR"
            return 1
        }
    fi
    # 无条件收紧，不只在目录刚创建时。
    # 目录里放着 SOCKS5 密码文件：若目录已存在且是 755（历史遗留、手工建过、
    # 或被别的工具改过），跳过后密码文件就落在 755 目录里，同机其他用户可读。
    # chmod 幂等，多一次 fork 换掉这个窗口。
    chmod 700 "$XMG_XRAY_STATE_DIR" 2>/dev/null || true

    if [ ! -f "$XMG_STATE_FILE" ]; then
        xmg_state_defaults > "$XMG_STATE_FILE" || {
            xmg_error "无法写入初始状态: $XMG_STATE_FILE"
            return 1
        }
    fi
    # 与目录同理，无条件收紧：state.env 里是密码明文。
    # 评审只点了目录，但这是同一行代码的同一个毛病——已存在的 644 文件同样该收紧。
    chmod 600 "$XMG_STATE_FILE" 2>/dev/null || true
    xmg_state_load
}

xmg_state_load() {
    local line="" key="" val="" rc=0

    XMG_STATE=()

    if [ -f "$XMG_STATE_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ''|'#'*) continue ;;
                *=*) ;;
                *) continue ;;
            esac
            key="${line%%=*}"
            val="${line#*=}"
            # 去除 CRLF 残留（Windows 编辑过的 state.env 会带\r）
            XMG_STATE["$key"]="${val%$'\r'}"
        done < "$XMG_STATE_FILE"
    else
        # 文件不存在：读接口仍需给出可用值，否则调用方会拿到空串并误判
        while IFS= read -r line; do
            XMG_STATE["${line%%=*}"]="${line#*=}"
        done < <(xmg_state_defaults)
        rc=1
    fi

    # 补齐文件中缺失的键：老版本 state.env 或被手工删行时仍能取到默认值，
    # 也保证 xmg_state_all 的输出始终包含全部已知键。
    local k
    for k in "${!XMG_STATE_DEFAULTS[@]}"; do
        [ -n "${XMG_STATE[$k]+set}" ] || XMG_STATE["$k"]="${XMG_STATE_DEFAULTS[$k]}"
    done

    return "$rc"
}

# 读单个值。第二个参数为调用方指定的回退值。
# 已显式写空的值（键存在但值为空）返回空，不触发回退——否则无法把某个键清空。
xmg_state_get() {
    local key="${1:-}" def="${2:-}"
    if [ -n "$key" ] && [ -n "${XMG_STATE[$key]+set}" ]; then
        printf '%s\n' "${XMG_STATE[$key]}"
        return 0
    fi
    if [ "$#" -ge 2 ]; then
        printf '%s\n' "$def"
        return 0
    fi
    # 键完全不存在时退回内置默认值，让只读状态（如 status 回显）不必先init
    if [ -n "$key" ] && [ -n "${XMG_STATE_DEFAULTS[$key]+set}" ]; then
        printf '%s\n' "${XMG_STATE_DEFAULTS[$key]}"
        return 0
    fi
    printf '%s\n' ""
}

# 与 xmg_state_get 同语义，但把结果写进全局 _xmg_v 而不是 stdout。
# xmg_state_validate 要读二十多个键，走 $(...) 每次都fork 一个子 shell；
# 在受限环境里单次校验就会拖到秒级，在 0.5C 机型上同样是白付的进程开销。
# 内部专用：赋值给调用方的局部变量请用_state_val <变量名> <键>。
_xmg_state_v=""
_xmg_state_peek() {
    local key="${1:-}"
    if [ -n "$key" ] && [ -n "${XMG_STATE[$key]+set}" ]; then
        _xmg_state_v="${XMG_STATE[$key]}"
    elif [ -n "$key" ] && [ -n "${XMG_STATE_DEFAULTS[$key]+set}" ]; then
        _xmg_state_v="${XMG_STATE_DEFAULTS[$key]}"
    else
        _xmg_state_v=""
    fi
}

# 把 <键> 的值直接赋给调用方已声明的局部变量 <变量名>，全程零 fork。
_state_val() {
    local __vname="${1:-}" __key="${2:-}"
    _xmg_state_peek "$__key"
    printf -v "$__vname" '%s' "$_xmg_state_v"
}

# ===== 状态批处理与暂存机制 =====

# 在内存/暂存区批处理暂存键值对，消除循环落盘。
# 校验合法性，更新内存状态与暂存区，延迟落盘。
xmg_state_stage() {
    local key="${1:-}" val="${2:-}"

    if ! _xmg_state_key_ok "$key"; then
        xmg_error "非法状态键名: '$key'（只允许字母、数字、下划线，且不以数字开头）"
        return 1
    fi
    if ! _xmg_state_value_ok "$val"; then
        xmg_error "状态值不能包含换行（键: $key）"
        return 1
    fi

    XMG_STATE_STAGE["$key"]="$val"
    XMG_STATE["$key"]="$val"
    return 0
}

# 清空未提交的暂存内容，并将内存状态重新恢复为磁盘真相。
xmg_state_stage_clear() {
    XMG_STATE_STAGE=()
    xmg_state_load >/dev/null 2>&1 || true
}

# 将当前暂存区中的所有键一次性合并并原子写入 state.env（单一事务落盘）。
# 外部命令只有 chmod 与 mv 两个，其余全部走 bash 内建。
xmg_state_commit_draft() {
    [ "${#XMG_STATE_STAGE[@]}" -gt 0 ] || return 0

    if [ ! -d "$XMG_XRAY_STATE_DIR" ]; then
        mkdir -p "$XMG_XRAY_STATE_DIR" || {
            xmg_error "无法创建状态目录: $XMG_XRAY_STATE_DIR"
            return 1
        }
    fi
    chmod 700 "$XMG_XRAY_STATE_DIR" 2>/dev/null || true
    [ -f "$XMG_STATE_FILE" ] || xmg_state_defaults > "$XMG_STATE_FILE" || return 1

    local tmp="" line="" k=""
    tmp="$XMG_XRAY_STATE_DIR/.state.$$"
    if ( set -o noclobber; : > "$tmp" ) 2>/dev/null; then
        :
    else
        tmp="$XMG_XRAY_STATE_DIR/.state.$$.$RANDOM"
        ( set -o noclobber; : > "$tmp" ) 2>/dev/null || {
            xmg_error "无法在 $XMG_XRAY_STATE_DIR 创建临时文件"
            return 1
        }
    fi

    local -A written=()
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*)
                printf '%s\n' "$line" >> "$tmp"
                ;;
            *=*)
                k="${line%%=*}"
                if [ -n "${XMG_STATE_STAGE[$k]+set}" ]; then
                    printf '%s=%s\n' "$k" "${XMG_STATE_STAGE[$k]}" >> "$tmp"
                    written["$k"]=1
                else
                    printf '%s\n' "$line" >> "$tmp"
                fi
                ;;
            *)
                printf '%s\n' "$line" >> "$tmp"
                ;;
        esac
    done < "$XMG_STATE_FILE"

    for k in "${!XMG_STATE_STAGE[@]}"; do
        if [ -z "${written[$k]+set}" ]; then
            printf '%s=%s\n' "$k" "${XMG_STATE_STAGE[$k]}" >> "$tmp"
        fi
    done

    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$XMG_STATE_FILE" || {
        rm -f "$tmp"
        xmg_error "无法替换状态文件: $XMG_STATE_FILE"
        return 1
    }

    XMG_STATE_STAGE=()
    return 0
}

# 写入单个键并立即落盘（复用 stage + commit_draft 单一事务落盘）。
xmg_state_set() {
    local key="${1:-}" val="${2:-}"
    xmg_state_stage "$key" "$val" || return 1
    xmg_state_commit_draft || return 1
}

# 输出全部 KEY=VALUE 行，按键名排序（排序保证输出确定，便于 diff 与幂等比较）。
# 注意：输出含密码明文，仅供写文件/导出用，不要直接打到终端或日志。
xmg_state_all() {
    local key=""
    xmg_state_load >/dev/null 2>&1
    [ "${#XMG_STATE[@]}" -gt 0 ] || return 0
    for key in "${!XMG_STATE[@]}"; do
        printf '%s=%s\n' "$key" "${XMG_STATE[$key]}"
    done | sort
}

# ===== 校验 =====
# 所有校验失败统一返回 2

xmg_state_validate_port() {
    local port="${1:-}"
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        xmg_error "端口必须为数字: '$port'"
        return 2
    fi
    # 前导零会让 [ -gt ] 走八进制解释，先按十进制归一。
    #
    # 但绝不能直接把原串丢进 $((10#...))：bash 算术是 64 位的，超长数字串会静默回绕。
    # 实测 18446744073709551617 (=2^64+1) 经 10# 归一后变成 1，落在合法区间里被当作
    # 合法端口接受，校验被完全绕过。所以顺序必须是：先剥前导零，再按长度上限拦，
    # 最后才做数值比较。
    #
    # 剥前导零而不是直接判长度，是为了不误杀 0000000443（=443）这类带填充的合法写法。
    # 剥到只剩一位 "0" 时停下，交给后面的范围检查判掉（0 不是合法端口）。
    while [ "${#port}" -gt 1 ] && [ "${port:0:1}" = "0" ]; do
        port="${port:1}"
    done
    # 剥完前导零仍超过 5 位，必然大于 65535，无需（也不能）再转算术。
    if [ "${#port}" -gt 5 ]; then
        xmg_error "端口超出范围 1-65535: '${1:-}'"
        return 2
    fi
    port="$((10#$port))"
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        xmg_error "端口超出范围 1-65535: '$port'"
        return 2
    fi
    return 0
}

xmg_state_validate_ipv4or6() {
    local addr="${1:-}"
    if [ -z "$addr" ]; then
        xmg_error "监听地址不能为空"
        return 2
    fi
    if _xmg_is_ipv4 "$addr" || _xmg_is_ipv6 "$addr"; then
        return 0
    fi
    xmg_error "非法监听地址: '$addr'（需为 IPv4 或 IPv6 字面量）"
    return 2
}

xmg_state_validate_mode() {
    local mode="${1:-}"
    case "$mode" in
        auto|packet-up|stream-up|stream-one) return 0 ;;
        *)
            xmg_error "非法 xhttp mode: '$mode'（文档取值: auto/packet-up/stream-up/stream-one）"
            return 2
            ;;
    esac
}

# 开关量只接受 0/1。
# 写成 yes/true 时若被静默当作「关闭」，用户会以为方案已启用而实际没有入站，
# 所以这里显式拒绝而非容错。
_xmg_state_validate_onoff() {
    local key="${1:-}" val="${2:-}"
    case "$val" in
        0|1) return 0 ;;
        *)
            xmg_error "$key 只能是 0 或 1: '$val'"
            return 2
            ;;
    esac
}

_xmg_state_validate_positive_int() {
    local key="${1:-}" val="${2:-}"
    if [[ ! "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ]; then
        xmg_error "$key 必须为正整数: '$val'"
        return 2
    fi
    return 0
}

xmg_state_validate() {
    local socks_on vless_on _bufsz _keep

    _state_val socks_on PROXY_SOCKS_ENABLED
    _state_val vless_on PROXY_VLESS_ENABLED

    _xmg_state_validate_onoff PROXY_SOCKS_ENABLED "$socks_on" || return 2
    _xmg_state_validate_onoff PROXY_VLESS_ENABLED "$vless_on" || return 2

    # bufferSize 恒为小值，仅校验为正整数
    _state_val _bufsz XMG_BUFFER_SIZE
    _xmg_state_validate_positive_int XMG_BUFFER_SIZE "$_bufsz" || return 2
    # 备份保留份数
    _state_val _keep XMG_BACKUP_KEEP
    _xmg_state_validate_positive_int XMG_BACKUP_KEEP "$_keep" || return 2

    if [ "$socks_on" = "1" ]; then
        local port listen user pass udp
        _state_val port PROXY_SOCKS_PORT
        xmg_state_validate_port "$port" || return 2

        _state_val listen PROXY_SOCKS_LISTEN
        xmg_state_validate_ipv4or6 "$listen" || return 2

        _state_val udp PROXY_SOCKS_UDP
        _xmg_state_validate_onoff PROXY_SOCKS_UDP "$udp" || return 2

        _state_val user PROXY_SOCKS_USER
        _state_val pass PROXY_SOCKS_PASS

        if [ -z "$user" ]; then
            xmg_error "SOCKS5 启用时用户名不能为空（公网入口必须认证）"
            return 2
        fi
        # 错误信息只报长度，绝不回显密码本身
        if [ -z "$pass" ]; then
            xmg_error "SOCKS5 启用时密码不能为空（公网入口必须认证）"
            return 2
        fi
        if [ "${#pass}" -lt 8 ]; then
            xmg_error "SOCKS5 密码至少 8 个字符（当前 ${#pass}）"
            return 2
        fi
        if [ "$user" = "$pass" ]; then
            xmg_error "SOCKS5 密码不能与用户名相同"
            return 2
        fi
    fi

    if [ "$vless_on" = "1" ]; then
        local port listen uuid domain path mode src
        _state_val port PROXY_VLESS_PORT
        xmg_state_validate_port "$port" || return 2

        _state_val listen PROXY_VLESS_LISTEN
        xmg_state_validate_ipv4or6 "$listen" || return 2

        _state_val uuid PROXY_VLESS_UUID
        if [ -z "$uuid" ]; then
            xmg_error "VLESS 启用时 UUID 不能为空"
            return 2
        fi
        # 文档：可小于 30 字节的字符串，或合法 UUID。
        # 只按长度卡会误杀标准 36 字符 UUID，故两种形态分别判定。
        if [[ ! "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
            && [ "${#uuid}" -ge 30 ]; then
            xmg_error "UUID 格式非法：既不是合法 UUID，长度也未小于 30 字节（当前 ${#uuid}）"
            return 2
        fi

        _state_val domain PROXY_VLESS_DOMAIN
        if [ -z "$domain" ]; then
            xmg_error "VLESS 启用时域名不能为空（用于 SNI 与 CDN 回源）"
            return 2
        fi
        if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
            xmg_error "域名格式非法: '$domain'"
            return 2
        fi

        _state_val path PROXY_VLESS_PATH
        if [ -z "$path" ]; then
            xmg_error "VLESS path 不能为空（文档默认值 /）"
            return 2
        fi
        if [ "${path:0:1}" != "/" ]; then
            xmg_error "path 必须以 / 开头: '$path'"
            return 2
        fi

        _state_val mode PROXY_VLESS_MODE
        xmg_state_validate_mode "$mode" || return 2

        _state_val src PROXY_VLESS_CERT_SOURCE
        case "$src" in
            user)
                local cf kf
                _state_val cf PROXY_VLESS_CERT_FILE
                _state_val kf PROXY_VLESS_KEY_FILE
                if [ -z "$cf" ] || [ -z "$kf" ]; then
                    xmg_error "证书来源为 user 时必须提供证书与私钥路径"
                    return 2
                fi
                if [ ! -r "$cf" ]; then
                    xmg_error "证书文件不可读: $cf"
                    return 2
                fi
                if [ ! -r "$kf" ]; then
                    xmg_error "私钥文件不可读: $kf"
                    return 2
                fi
                ;;
            acme)
                if [ -z "$domain" ]; then
                    xmg_error "证书来源为 acme 时必须提供域名"
                    return 2
                fi
                ;;
            *)
                xmg_error "非法证书来源: '$src'（取值 user 或 acme）"
                return 2
                ;;
        esac
    fi

    # 端口冲突：仅两方案同时启用时检查
    if [ "$socks_on" = "1" ] && [ "$vless_on" = "1" ]; then
        local sp vp
        _state_val sp PROXY_SOCKS_PORT
        _state_val vp PROXY_VLESS_PORT
        if [ "$sp" = "$vp" ]; then
            xmg_error "端口冲突：SOCKS5 与 VLESS 均使用端口 $sp，请为其中一个更换端口"
            return 2
        fi
    fi

    return 0
}

# ============================================================================
# 原子写入与备份清理（Task 4）
#
# 核心不变量：任何配置变更失败时，运行中的 config.json 必须保持可用。
# 写入顺序恒为：校验新配置 → 备份旧配置 → 清理旧备份 → 原子替换 → reload → 失败回滚。
# 校验失败绝不触碰现网配置。
#
# 退出码约定（给 CLI 层）：
#   xmg_state_commit          0 成功 / 3 校验失败（现网未被触碰）/ 4 运行失败
#                             （有旧配置时已尽力原子回滚；首次安装场景无旧配置可回滚，
#                              新配置保留待排查。文案与实际行为严格一致，绝不谎称已回滚）
#   xmg_state_validate_config 0 合法 / 3 非法或无法校验
#   xmg_xray_binary           0 找到并打印路径 / 1 未找到
#   xmg_backup_prune          恒 0（清理失败仅告警，不阻断）
#
# 测试桩开关（XMG_XRAY_CONFIG_TESTCMD / XMG_XRAY_RELOAD_TESTCMD）只在
# XMG_TEST_MODE=1 时生效：xmg 以 root 运行，环境变量即命令执行面，
# 加显式开关后生产环境即使存在同名变量也不会 eval 任意命令。
# ============================================================================

# xmg_timestamp 由 common.sh 提供；单独 source 本文件（测试）时补一个兜底，
# 保证 xmg_state_commit 的备份命名可用。与文件顶部 xmg_error 兜底同理。
if ! declare -F xmg_timestamp >/dev/null 2>&1; then
    xmg_timestamp() { date '+%Y%m%d-%H%M%S'; }
fi

# ===== Xray 二进制定位 =====
# xray 二进制路径（可被调用方预设覆盖）。用 :- 赋值，避免覆盖调用方/测试的预设。
XMG_XRAY_BIN="${XMG_XRAY_BIN:-/usr/local/bin/xray}"

# 定位 xray 可执行文件：成功打印路径并返回 0；未找到返回 1。
# 查找顺序：显式 override → PATH → $XMG_XRAY_BIN → /usr/bin/xray。
xmg_xray_binary() {
    if [ -n "${XMG_XRAY_BIN_OVERRIDE:-}" ] && [ -x "$XMG_XRAY_BIN_OVERRIDE" ]; then
        printf '%s\n' "$XMG_XRAY_BIN_OVERRIDE"
        return 0
    fi
    if command -v xray >/dev/null 2>&1; then
        command -v xray
        return 0
    fi
    if [ -x "$XMG_XRAY_BIN" ]; then
        printf '%s\n' "$XMG_XRAY_BIN"
        return 0
    fi
    if [ -x /usr/bin/xray ]; then
        printf '%s\n' "/usr/bin/xray"
        return 0
    fi
    return 1
}

# ===== 配置校验 =====
# 调用 `xray run -test -c <配置>` 校验生成的配置；失败返回 3。
# 允许通过环境变量 XMG_XRAY_CONFIG_TESTCMD 注入测试桩（仅 XMG_TEST_MODE=1 时生效）；
# 桩模式下失败同样归一为 3，保证对外契约「校验失败 = 3」恒定，
# 否则调用方会拿到桩命令的原始退出码（1/127 等）而无所适从。
xmg_state_validate_config() {
    local cfg="${1:-}"
    local bin=""

    # 文件存在性检查放在桩分支之前：桩路径与生产路径必须同一语义
    # （新配置不存在时都返回 3），否则两条路径行为分叉，测试无法代表生产。
    [ -f "$cfg" ] || {
        xmg_error "配置文件不存在: $cfg"
        return 3
    }

    # 测试桩只在显式开启测试模式时生效：xmg 以 root 运行，环境变量就是命令
    # 执行面，加这道开关后生产环境即使存在同名变量也不会 eval 任意命令。
    if [ "${XMG_TEST_MODE:-0}" = "1" ] && [ -n "${XMG_XRAY_CONFIG_TESTCMD:-}" ]; then
        if eval "$XMG_XRAY_CONFIG_TESTCMD" >/dev/null 2>&1; then
            return 0
        fi
        return 3
    fi

    bin="$(xmg_xray_binary)" || {
        xmg_error "未找到 xray 可执行文件，无法校验配置"
        return 3
    }

    local logdir="${XMG_XRAY_LOG_DIR:-${XMG_LOG_DIR:-/opt/xmg/log}/xray}"
    mkdir -p "$logdir" 2>/dev/null || true

    local err_out=""
    if ! err_out="$("$bin" run -test -c "$cfg" 2>&1)"; then
        xmg_error "Xray 拒绝了生成的配置（xray run -test 失败）:"
        [ -n "$err_out" ] && printf '%s\n' "$err_out" >&2
        return 3
    fi
    return 0
}

# ===== 备份清理 =====
# 用法：xmg_backup_prune [目录] [保留数] [匹配前缀]
# 默认目录 $XMG_BACKUP_DIR、保留数取 state XMG_BACKUP_KEEP。
# 前缀默认 config.json.：绝不能空串。空串会匹配目录内全部 *.bak，
# 调用方一旦漏传前缀就会误删其它备份（如 state.env.*.bak）；把默认值
# 收敛到本函数的主用途，即使漏传也只影响配置备份这一类。
# 严格限定在指定目录「单层」内匹配 <前缀>*.bak，绝不用跨目录通配
# （低配机 BusyBox/GNU find 行为差异会误删）。
# 清理失败仅告警，不阻断主流程，恒返回 0。
xmg_backup_prune() {
    local dir="${1:-$XMG_BACKUP_DIR}"
    local keep="${2:-$(xmg_state_get XMG_BACKUP_KEEP)}"
    local prefix="${3:-config.json.}"

    [ -d "$dir" ] || return 0
    # keep 归一：非正整数一律回退 5，且至少保留 1 份
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
    [ "$keep" -ge 1 ] || keep=1

    local -a files=()
    local f
    # -maxdepth 1 限定单层；sort -r 按名倒序（备份名含时间戳，字典序即时间序），
    # 于是 files[0..keep-1] 恰是最新的 keep 份。
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -name "${prefix}*.bak" 2>/dev/null | sort -r)

    local total="${#files[@]}"
    [ "$total" -gt "$keep" ] || return 0

    local i
    for (( i=keep; i<total; i++ )); do
        rm -f "${files[$i]}" 2>/dev/null || \
            xmg_warn "备份清理失败（已忽略）: ${files[$i]}"
    done
    return 0
}

# ===== 服务重载 =====
# 测试可注入 XMG_XRAY_RELOAD_TESTCMD 桩替换真实 systemctl（仅 XMG_TEST_MODE=1 时生效，
# 与校验桩同理：生产环境即使存在同名变量也不 eval 任意命令）；
# 生产无 systemctl 时视为无需重载（返回 0）。
_xmg_xray_reload() {
    if [ "${XMG_TEST_MODE:-0}" = "1" ] && [ -n "${XMG_XRAY_RELOAD_TESTCMD:-}" ]; then
        eval "$XMG_XRAY_RELOAD_TESTCMD" >/dev/null 2>&1
        return $?
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload xray >/dev/null 2>&1
        return $?
    fi
    return 0
}

# ===== 原子提交 =====
# 顺序：校验新配置 → 备份旧配置 → 清理旧备份 → 原子替换 → reload → 失败回滚。
#
# 核心不变量：进入「替换」阶段前，只要现网存在旧配置，旧配置必已备份成功；
# 备份失败立即中止、绝不替换——无法保证可回滚，就不动现网。
# 首次安装（原本无现网配置）是唯一没有旧备份的合法情形，reload 失败时
# 如实报告「新配置已写入但未生效」，不再谎称已回滚。
#
# 返回：0 成功 / 3 校验失败（现网未被触碰）/ 4 运行失败
#       （有旧配置时已尽力原子回滚；首次安装时返回 4 且新配置保留待排查）。
xmg_state_commit() {
    local new_cfg="${1:-}"
    local old_backup=""
    local had_old=0
    local dir_tmp=""

    local logdir="${XMG_XRAY_LOG_DIR:-${XMG_LOG_DIR:-/opt/xmg/log}/xray}"
    mkdir -p "$logdir" 2>/dev/null || true

    # 1. 校验新配置（失败绝不触碰现网配置）
    xmg_state_validate_config "$new_cfg"
    local vrc=$?
    [ "$vrc" -eq 0 ] || return 3

    dir_tmp="$(dirname "$XMG_XRAY_CONFIG")"
    mkdir -p "$dir_tmp" || {
        xmg_error "无法创建配置目录"
        return 4
    }

    # 2. 备份旧配置。备份失败立即中止、不进入替换阶段：没有可用备份就没有
    #    可靠退路，若照常替换，reload 失败就会把现网换成未生效的新配置。
    #    备份名含时间戳 + PID + 自增序号，避免同秒提交互相覆盖。
    if [ -f "$XMG_XRAY_CONFIG" ]; then
        mkdir -p "$XMG_BACKUP_DIR" 2>/dev/null || true
        _XMG_BAK_SEQ=$(( ${_XMG_BAK_SEQ:-0} + 1 ))
        old_backup="$XMG_BACKUP_DIR/config.json.$(xmg_timestamp).$$.$_XMG_BAK_SEQ.bak"
        if ! cp -a "$XMG_XRAY_CONFIG" "$old_backup" 2>/dev/null || [ ! -f "$old_backup" ]; then
            rm -f "$old_backup" 2>/dev/null || true
            xmg_error "无法备份现有配置，为安全起见中止本次变更（现网配置未改动）"
            return 4
        fi
        had_old=1

        # 3. 清理旧备份（保留 XMG_BACKUP_KEEP 份）
        xmg_backup_prune "$XMG_BACKUP_DIR" "$(xmg_state_get XMG_BACKUP_KEEP)" "config.json."
    fi

    # 4. 原子替换：先写同目录暂存文件，再 mv 覆盖，中断不会留下半个 config.json
    local staged=""
    staged="$(mktemp "$dir_tmp/.config.XXXXXX")" || {
        xmg_error "无法创建临时文件"
        return 4
    }
    cat "$new_cfg" > "$staged" || { rm -f "$staged"; return 4; }
    chmod 644 "$staged" 2>/dev/null || true
    mv -f "$staged" "$XMG_XRAY_CONFIG" || {
        rm -f "$staged"
        xmg_error "替换配置失败"
        return 4
    }

    # 5. reload
    _xmg_xray_reload && return 0

    # reload 失败。文案必须与实际行为一致，任何分支都不谎称已回滚。
    if [ "$had_old" -ne 1 ]; then
        # 首次安装：原本没有配置，没有旧配置可回滚。如实报告，默认保留新配置。
        xmg_error "服务重载失败；本次为首次安装，原状态为无配置，新配置已写入但未生效：$XMG_XRAY_CONFIG（未自动删除，便于排查）"
        return 4
    fi

    # 有旧配置：用「同目录暂存 + mv -f」原子回滚（回滚也要原子，且失败必须可见）。
    local rb_staged=""
    if rb_staged="$(mktemp "$dir_tmp/.config.rb.XXXXXX")" \
        && cp -a "$old_backup" "$rb_staged" 2>/dev/null \
        && mv -f "$rb_staged" "$XMG_XRAY_CONFIG" 2>/dev/null; then
        _xmg_xray_reload >/dev/null 2>&1 || \
            xmg_warn "已回滚到原配置，但重载仍然失败，请检查 xray 服务状态"
        xmg_error "服务重载失败，已回滚到原配置"
    else
        if [ -n "$rb_staged" ]; then
            rm -f "$rb_staged" 2>/dev/null || true
        fi
        xmg_error "服务重载失败，且回滚未能完成；现网配置可能未生效，请立即检查 $XMG_XRAY_CONFIG"
    fi
    return 4
}