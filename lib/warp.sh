#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# warp.sh - XMG Cloudflare WARP 原生出站模块
#
# 架构说明 (方案 A: Xray 原生 WireGuard 进程内出站):
#   - 彻底废除宿主机网卡级接管 (wg-quick) 与第三方后台代理进程 (wireproxy)
#   - 降维解耦为纯正的【Xray 原生 WireGuard 进程内出站】(protocol: "wireguard", noKernelTun: true)
#   - 核心目标: 彻底隐藏高污染本机 IP，节点公网出站默认 100% 走 WARP 清洁出口
#   - 宿主机保护: 100% 零侵入、零网卡、零路由修改、零 DNS 篡改，SSH 物理级绝对不可能失联！
#   - 官方标准: 完整解析 Cloudflare client_id，精准填充 WireGuard 3 字节 reserved 保留字段，解决丢包假死
#   - 地理数据: 分流模式按机型分档启用官方 geosite.dat（XTLS/Xray-rules-dat），
#     极低内存（<=128MB / 0.2C 弱核）自动回退内置硬编码域名，零 dat 加载开销
#

# warp.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "warp.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_WARP_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_WARP_SH_LOADED=1

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

# 注意：xray.sh 必须「按需」加载，不能在模块加载期 source。
#   xray.sh 加载时会定型 XMG_INITD_DIR / XMG_XRAY_OPENRC_SCRIPT，并引入优先级
#   更高的 xmg_xray_get_bin；一旦在加载期引入，selftest 的内核探测就会从
#   xmg_xray_binary（认 XMG_XRAY_BIN_OVERRIDE）改走 get_bin 而失准。
_warp_load_xray_lib() {
    declare -F xmg_xray_restart_hard >/dev/null 2>&1 && return 0
    local _f=""
    for _f in "${XMG_LIB_DIR:-/opt/xmg/lib}/xray.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/xray.sh"; do
        if [ -r "$_f" ]; then
            # shellcheck source=/dev/null
            source "$_f"
            declare -F xmg_xray_restart_hard >/dev/null 2>&1 && return 0
        fi
    done
    return 1
}

# XMG_MENU_LABEL: WARP 网络增强

# ===== 默认配置与路径 =====
XMG_WARP_DIR="${XMG_WARP_DIR:-${XMG_HOME:-/opt/xmg}/warp}"
XMG_WARP_ACCOUNT_FILE="${XMG_WARP_ACCOUNT_FILE:-$XMG_WARP_DIR/account.json}"
XMG_WARP_ENV_FILE="${XMG_WARP_ENV_FILE:-$XMG_WARP_DIR/warp.env}"
XMG_WARP_XRAY_OUTBOUND="${XMG_WARP_XRAY_OUTBOUND:-$XMG_WARP_DIR/xray_warp.json}"

# Cloudflare Anycast 官方端点
XMG_WARP_ENDPOINT_V6="${XMG_WARP_ENDPOINT_V6:-[2606:4700:d0::a29f:c001]:2408}"
XMG_WARP_ENDPOINT_V4="${XMG_WARP_ENDPOINT_V4:-162.159.192.1:2408}"
XMG_WARP_PEER_PUBKEY="${XMG_WARP_PEER_PUBKEY:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}"

# ===== 安全加载必要依赖 (自包含) =====
_XMG_WARP_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. common.sh
if ! declare -F xmg_info >/dev/null 2>&1; then
    if [ -f "$_XMG_WARP_LIBDIR/common.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_WARP_LIBDIR/common.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/common.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/common.sh"
    fi
fi

# 2. detect.sh
if ! declare -F xmg_detect_network >/dev/null 2>&1; then
    if [ -f "$_XMG_WARP_LIBDIR/detect.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_WARP_LIBDIR/detect.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/detect.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/detect.sh"
    fi
fi

# 3. state.sh
if ! declare -F xmg_state_init >/dev/null 2>&1; then
    if [ -f "$_XMG_WARP_LIBDIR/state.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_WARP_LIBDIR/state.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/state.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/state.sh"
    fi
fi

# 4. render.sh
if ! declare -F xmg_render_config >/dev/null 2>&1; then
    if [ -f "$_XMG_WARP_LIBDIR/render.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_WARP_LIBDIR/render.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/render.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/render.sh"
    fi
fi
unset _XMG_WARP_LIBDIR

# ===== 依赖 common.sh 的兜底 =====

if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info()  { printf '[INFO] %s\n' "$*"; }
fi
if ! declare -F xmg_warn >/dev/null 2>&1; then
    xmg_warn()  { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_error >/dev/null 2>&1; then
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_pause >/dev/null 2>&1; then
    xmg_pause() {
        if [ -t 0 ]; then
            printf '\n按 Enter 返回...'
            read -r _ </dev/tty 2>/dev/null || read -r _ || true
        fi
    }
fi
if ! declare -F xmg_require_root >/dev/null 2>&1; then
    xmg_require_root() {
        if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
            xmg_error "此操作需要 root 特权"
            return 1
        fi
        return 0
    }
fi

# ===== JSON 解析安全兜底函数 =====

_xmg_warp_json_val() {
    local json="$1"
    local path="$2"

    if command -v jq >/dev/null 2>&1; then
        local jq_path="$path"
        [[ "$jq_path" =~ ^\. ]] || jq_path=".$jq_path"
        echo "$json" | jq -r "$jq_path // empty" 2>/dev/null || true
        return 0
    fi

    local key="${path##*.}"
    local regex="\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    if [[ "$json" =~ $regex ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "$json" | grep -o '"'"$key"'"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || true
}

# ===== 凭据与 IP 清洗工具 =====

_xmg_warp_clean_ipv6() {
    local raw="$1"
    if [ -z "$raw" ]; then
        echo ""
        return 0
    fi
    local val="$raw"
    val="${val%%/*}"
    if [[ "$val" =~ ^\[(.*)\]:[0-9]+$ ]]; then
        val="${BASH_REMATCH[1]}"
    fi
    val="${val#\[}"
    val="${val%\]}"
    val="${val//[[:space:]]/}"
    if [[ "$val" =~ : ]] && [[ ! "$val" =~ [^0-9a-fA-F:] ]]; then
        echo "$val"
    else
        echo ""
    fi
}

# 严格校验 IPv6 字面量（字符集 + 组数）
#   历史脏数据会把 endpoint 端口拼在地址末尾（...:77fa:2408），这类地址字符集合法、
#   只有组数超标。旧判定用 ":[0-9]+$" 抓它，会把末组恰好全为数字的合法地址
#   （如 ...:9602:1234）一起误杀，导致每次 enable 都重注册、很快撞 CF 429。
_xmg_is_valid_ipv6() {
    local ip="${1:-}"
    [ -n "$ip" ] || return 1

    # 先剥 CIDR 后缀：wgcf 风格凭据写的是 ".../128"，
    # 不剥会被判非法，导致每次 auto 都重注册覆盖账号，很快撞 CF 429
    ip="${ip%%/*}"

    case "$ip" in
        *[!0-9a-fA-F:.]*) return 1 ;;
        *:::*) return 1 ;;
    esac

    # "1::2::3" 这类双 :: 非法，但不会被上面的 ::: 模式命中
    case "$ip" in
        *::*::*) return 1 ;;
    esac

    local has_dc=0
    case "$ip" in
        *::*) has_dc=1 ;;
    esac

    local -a parts=()
    local IFS=':'
    read -r -a parts <<< "$ip"

    local nz=0 p=""
    for p in "${parts[@]}"; do
        [ -n "$p" ] && nz=$((nz + 1))
    done

    if [ "$has_dc" -eq 1 ]; then
        # "::" 至少压缩一组，非空组最多 7 个；尾随冒号（...:1f2a:）会多出空段
        [ "$nz" -le 7 ] && return 0
        return 1
    fi
    [ "$nz" -eq 8 ]
}

_xmg_warp_clean_ipv4() {
    local raw="$1"
    if [ -z "$raw" ]; then
        echo ""
        return 0
    fi
    local val="$raw"
    val="${val%%/*}"
    val="${val%%:0}"
    if [[ "$val" =~ :[0-9]+$ ]]; then
        val="${val%:[0-9]*}"
    fi
    val="${val//[[:space:]]/}"
    echo "$val"
}

# ===== WARP 隧道能力画像（单栈 / 双栈矩阵）=====
# 直接复用已由顶部加载的 lib/render.sh 中的 _xmg_warp_tunnel_profile 唯一真源，
# 消除双份实现与潜在逻辑漂移。

_xmg_warp_country_name() {
    local code="$1"
    case "$code" in
        SG) echo "新加坡 (SG)" ;;
        HK) echo "中国香港 (HK)" ;;
        JP) echo "日本 (JP)" ;;
        US) echo "美国 (US)" ;;
        KR) echo "韩国 (KR)" ;;
        TW) echo "中国台湾 (TW)" ;;
        GB|UK) echo "英国 (GB)" ;;
        DE) echo "德国 (DE)" ;;
        FR) echo "法国 (FR)" ;;
        NL) echo "荷兰 (NL)" ;;
        AU) echo "澳大利亚 (AU)" ;;
        CA) echo "加拿大 (CA)" ;;
        RU) echo "俄罗斯 (RU)" ;;
        IN) echo "印度 (IN)" ;;
        MY) echo "马来西亚 (MY)" ;;
        TH) echo "泰国 (TH)" ;;
        VN) echo "越南 (VN)" ;;
        PH) echo "菲律宾 (PH)" ;;
        ID) echo "印度尼西亚 (ID)" ;;
        *)  echo "${code:-未知}" ;;
    esac
}

# ===== 物理 VPS 原生地理与数据中心感知 =====

XMG_WARP_NATIVE_LOC=""
XMG_WARP_NATIVE_COLO=""

xmg_warp_detect_native_geo() {
    if [ -n "$XMG_WARP_NATIVE_LOC" ] && [ -n "$XMG_WARP_NATIVE_COLO" ]; then
        return 0
    fi

    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        XMG_WARP_NATIVE_LOC="${XMG_MOCK_WARP_NATIVE_LOC:-SG}"
        XMG_WARP_NATIVE_COLO="${XMG_MOCK_WARP_NATIVE_COLO:-SIN}"
        return 0
    fi

    local fam
    fam="$(_xmg_warp_curl_family)"
    local curl_net=()
    [ -n "$fam" ] && curl_net=("$fam")

    local trace=""
    trace="$(curl "${curl_net[@]}" -sSL --connect-timeout 4 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    if [ -z "$trace" ] && [ -z "$fam" ]; then
        trace="$(curl -6 -sSL --connect-timeout 4 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    fi
    if [ -n "$trace" ]; then
        local _tline="" _tk="" _tv=""
        while IFS='=' read -r _tk _tv; do
            case "$_tk" in
                loc) XMG_WARP_NATIVE_LOC="${_tv//[[:space:]]/}" ;;
                colo) XMG_WARP_NATIVE_COLO="${_tv//[[:space:]]/}" ;;
            esac
        done <<< "$trace"
    fi

    if [ -z "$XMG_WARP_NATIVE_LOC" ]; then
        local ip_info=""
        ip_info="$(curl "${curl_net[@]}" -sSL --connect-timeout 4 --max-time 6 https://ipinfo.io/json 2>/dev/null || true)"
        if [ -z "$ip_info" ] && [ -z "$fam" ]; then
            ip_info="$(curl -6 -sSL --connect-timeout 4 --max-time 6 https://ipinfo.io/json 2>/dev/null || true)"
        fi
        if [ -n "$ip_info" ]; then
            XMG_WARP_NATIVE_LOC="$(echo "$ip_info" | grep -o '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
            XMG_WARP_NATIVE_COLO="DEFAULT"
        fi
    fi

    [ -n "$XMG_WARP_NATIVE_LOC" ] || XMG_WARP_NATIVE_LOC="UNKNOWN"
    [ -n "$XMG_WARP_NATIVE_COLO" ] || XMG_WARP_NATIVE_COLO="UNKNOWN"
    return 0
}

# ===== 网络栈与 curl 协议族参数检测 =====

_xmg_warp_curl_family() {
    if xmg_warp_is_ipv6_only; then
        echo "-6"
        return 0
    elif [ "${XMG_NET_IPV4:-0}" = "1" ] && [ "${XMG_NET_IPV6:-0}" = "0" ]; then
        echo "-4"
        return 0
    fi
    echo ""
}

# ===== IPv6 Endpoint 规范化 =====
# 确保 IPv6 对端端点始终为 [addr]:port，且端口 :0 修正为 :2408
_xmg_warp_norm_endpoint_v6() {
    local ep="${1:-}"
    ep="${ep//[[:space:]]/}"
    [ -n "$ep" ] || { echo ""; return 0; }

    # 已有方括号 [addr]:port
    if [[ "$ep" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        local h="${BASH_REMATCH[1]}" p="${BASH_REMATCH[2]}"
        [ "$p" = "0" ] && p="2408"
        printf '[%s]:%s\n' "$h" "$p"
        return 0
    fi
    # 仅有方括号 [addr]
    if [[ "$ep" =~ ^\[([^]]+)\]$ ]]; then
        printf '[%s]:2408\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    # 无方括号但含冒号：可能是 addr:port（例如 2606:4700:d0::a29f:c001:2408 或 :0）或裸 IPv6
    if [[ "$ep" == *:* ]]; then
        local last="${ep##*:}"
        local head="${ep%:*}"
        # 若末尾是 :0 或 4位端口且前面仍含冒号（至少两组），且不是合法裸 :: 结尾
        if [[ "$last" =~ ^[0-9]+$ ]] && [[ "$head" == *:* ]] && { [ "$last" = "0" ] || [ "$last" = "2408" ] || [ "$last" = "500" ] || [ "$last" = "4500" ]; }; then
            [ "$last" = "0" ] && last="2408"
            printf '[%s]:%s\n' "$head" "$last"
            return 0
        fi
        printf '[%s]:2408\n' "$ep"
        return 0
    fi
    printf '%s\n' "$ep"
}

# ===== 确保宿主机网络栈变量 (XMG_NET_IPV4 / XMG_NET_IPV6) 已就绪 =====
_xmg_warp_ensure_net_detected() {
    if [ -n "${XMG_MOCK_WARP_STACK:-}" ]; then
        case "$XMG_MOCK_WARP_STACK" in
            ipv6_only) XMG_NET_IPV4=0; XMG_NET_IPV6=1 ;;
            ipv4_only) XMG_NET_IPV4=1; XMG_NET_IPV6=0 ;;
            dual_stack|dual) XMG_NET_IPV4=1; XMG_NET_IPV6=1 ;;
        esac
        return 0
    fi
    if [ -n "${XMG_NET_STACK:-}" ]; then
        case "$XMG_NET_STACK" in
            ipv6_only) XMG_NET_IPV4=0; XMG_NET_IPV6=1 ;;
            ipv4_only) XMG_NET_IPV4=1; XMG_NET_IPV6=0 ;;
            dual_stack|dual) XMG_NET_IPV4=1; XMG_NET_IPV6=1 ;;
        esac
        return 0
    fi
    if [ -z "${XMG_NET_IPV4:-}" ] || [ -z "${XMG_NET_IPV6:-}" ]; then
        if declare -F xmg_detect_network >/dev/null 2>&1; then
            xmg_detect_network >/dev/null 2>&1 || true
        fi
    fi
}

# ===== 判断 VPS 是否为纯 IPv6 (无公网 IPv4) =====

xmg_warp_is_ipv6_only() {
    if [ -n "${XMG_MOCK_WARP_STACK:-}" ]; then
        [ "$XMG_MOCK_WARP_STACK" = "ipv6_only" ]
        return $?
    fi

    if [ -n "${XMG_NET_STACK:-}" ]; then
        [ "$XMG_NET_STACK" = "ipv6_only" ]
        return $?
    fi

    if [ -n "${XMG_NET_IPV4:-}" ] && [ -n "${XMG_NET_IPV6:-}" ]; then
        [ "$XMG_NET_IPV4" = "0" ] && [ "$XMG_NET_IPV6" = "1" ]
        return $?
    fi

    if declare -F xmg_detect_network >/dev/null 2>&1; then
        local _sv4="${XMG_NET_IPV4:-}" _sv6="${XMG_NET_IPV6:-}"
        xmg_detect_network >/dev/null 2>&1 || true
        if [ "${XMG_NET_IPV4:-}" = "0" ] && [ "${XMG_NET_IPV6:-}" = "1" ]; then
            return 0
        fi
        if [ "${XMG_NET_IPV4:-}" = "1" ]; then
            return 1
        fi
        # 仅在探测完全失败（0/0 或空）时恢复旧值
        [ -n "$_sv4" ] && XMG_NET_IPV4="$_sv4"
        [ -n "$_sv6" ] && XMG_NET_IPV6="$_sv6"
    fi

    if ! curl -4sSL --connect-timeout 2 --max-time 3 https://1.1.1.1 >/dev/null 2>&1; then
        if curl -6sSL --connect-timeout 2 --max-time 3 https://[2606:4700:4700::1111] >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# ===== Cloudflare Anycast 端点池本地低延迟优选 =====

xmg_warp_optimize_endpoint() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "正在探测当前 VPS 原生网络物理归属地与直连数据中心..."
    xmg_warp_detect_native_geo

    xmg_info "VPS 本地原生地区: $(_xmg_warp_country_name "$XMG_WARP_NATIVE_LOC") | 最佳直连机房: $XMG_WARP_NATIVE_COLO"
    xmg_info "正在对 Cloudflare 官方 Anycast 端点池进行本地低延迟优选..."

    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        local mock_res="${XMG_MOCK_WARP_OPTIMIZED_EP:-}"
        if [ -z "$mock_res" ]; then
            if xmg_warp_is_ipv6_only; then
                mock_res="[2606:4700:d0::a29f:c001]:2408"
            else
                mock_res="162.159.193.1:2408"
            fi
        fi
        xmg_info "优选完成！选定最佳本地端点: $mock_res (延迟: 3ms)"

        if [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
            if xmg_warp_is_ipv6_only; then
                _xmg_warp_account_set_ep "endpoint_v6" "$mock_res"
            else
                _xmg_warp_account_set_ep "endpoint_v4" "$mock_res"
            fi
        fi

        echo "$mock_res"
        return 0
    fi

    local is_v6=0
    xmg_warp_is_ipv6_only && is_v6=1

    local candidates=()
    if [ "$is_v6" -eq 1 ]; then
        candidates=(
            "[2606:4700:d0::a29f:c001]:2408"
            "[2606:4700:d0::a29f:c002]:2408"
            "[2606:4700:d0::a29f:c003]:2408"
            "[2606:4700:d1::a29f:c001]:2408"
            "[2606:4700:d1::a29f:c002]:2408"
        )
    else
        candidates=(
            "engage.cloudflareclient.com:2408"
            "162.159.192.1:2408"
            "162.159.193.1:2408"
            "162.159.195.1:2408"
            "188.114.96.1:2408"
            "188.114.97.1:2408"
            "188.114.98.1:2408"
            "188.114.99.1:2408"
            "162.159.192.1:500"
            "162.159.193.1:500"
            "162.159.192.1:4500"
        )
    fi

    local best_ep=""
    local best_rtt=999999
    local ep=""

    for ep in "${candidates[@]}"; do
        local host="${ep%:*}"
        host="${host#[}"
        host="${host%]}"
        local rtt=""

        if command -v ping >/dev/null 2>&1 || { [ "$is_v6" -eq 1 ] && command -v ping6 >/dev/null 2>&1; }; then
            local ping_cmd="ping -c 1 -W 1"
            [ "$is_v6" -eq 1 ] && ping_cmd="ping -6 -c 1 -W 1"
            local ping_out=""
            ping_out="$($ping_cmd "$host" 2>/dev/null || true)"
            if [ -z "$ping_out" ] && [ "$is_v6" -eq 1 ] && command -v ping6 >/dev/null 2>&1; then
                ping_out="$(ping6 -c 1 -W 1 "$host" 2>/dev/null || true)"
            fi
            rtt="$(echo "$ping_out" | grep -o 'min/avg/max[^=]*=[^/]*' | cut -d= -f2 | tr -d ' ' || true)"
            if [ -z "$rtt" ]; then
                rtt="$(echo "$ping_out" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' | cut -d/ -f2 || true)"
            fi
        fi

        if [ -z "$rtt" ]; then
            local test_url="http://$host:80"
            if [ "$is_v6" -eq 1 ]; then
                test_url="http://[$host]:80"
            fi
            rtt="$(curl -s -o /dev/null -w "%{time_connect}\n" --connect-timeout 1 "$test_url" 2>/dev/null || true)"
            if [ -n "$rtt" ] && [ "$rtt" != "0.000" ] && [ "$rtt" != "0.000000" ]; then
                rtt="$(awk -v t="$rtt" 'BEGIN { printf "%.0f", t * 1000 }' 2>/dev/null || echo "999")"
            else
                rtt=""
            fi
        else
            rtt="$(awk -v t="$rtt" 'BEGIN { printf "%.0f", t }' 2>/dev/null || echo "999")"
            [ "$rtt" = "0" ] && rtt="1"
        fi

        if [ -n "$rtt" ] && [ "$rtt" -gt 0 ] && [ "$rtt" -lt "$best_rtt" ]; then
            best_rtt="$rtt"
            best_ep="$ep"
            printf "  - 测试端点 %-36s: 延迟 %4d ms [目前最优]\n" "$ep" "$rtt"
        elif [ -n "$rtt" ] && [ "$rtt" -gt 0 ]; then
            printf "  - 测试端点 %-36s: 延迟 %4d ms\n" "$ep" "$rtt"
        else
            printf "  - 测试端点 %-36s: 超时 / 不可达\n" "$ep"
        fi
    done

    if [ -z "$best_ep" ]; then
        if [ "$is_v6" -eq 1 ]; then
            best_ep="$XMG_WARP_ENDPOINT_V6"
        else
            best_ep="engage.cloudflareclient.com:2408"
        fi
        xmg_warn "端点探测未能获得更低延迟，使用默认端点: $best_ep"
    else
        xmg_info "优选完成！选定最佳本地端点: $best_ep (延迟: ${best_rtt}ms)"
    fi

    # 更新 account.json 中的端点 (若存在)
    if [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        if [ "$is_v6" -eq 1 ]; then
            _xmg_warp_account_set_ep "endpoint_v6" "$best_ep"
        else
            _xmg_warp_account_set_ep "endpoint_v4" "$best_ep"
        fi
    fi

    # 若 WARP 已处于启用状态（且非 auto_apply 内部调用），自动同步新端点到配置并重启 Xray
    if [ "${_XMG_WARP_IN_AUTO_APPLY:-0}" != "1" ] && [ "${XMG_TEST_MODE:-0}" != "1" ]; then
        local _cur_on="" _cur_mode="" _cur_geo=""
        if declare -F xmg_state_get >/dev/null 2>&1; then
            _cur_on="$(xmg_state_get WARP_ENABLED "" 2>/dev/null || true)"
            _cur_mode="$(xmg_state_get WARP_MODE "" 2>/dev/null || true)"
            _cur_geo="$(xmg_state_get WARP_GEO_MODE "" 2>/dev/null || true)"
        fi
        if { [ -z "$_cur_on" ] || [ -z "$_cur_mode" ]; } && [ -f "$XMG_WARP_ENV_FILE" ]; then
            local _ek="" _ev=""
            while IFS='=' read -r _ek _ev || [ -n "$_ek" ]; do
                _ev="${_ev%$'\r'}"; _ev="${_ev//\"/}"; _ev="${_ev//[[:space:]]/}"
                case "$_ek" in
                    WARP_ENABLED) [ -n "$_cur_on" ]   || _cur_on="$_ev" ;;
                    WARP_MODE)    [ -n "$_cur_mode" ] || _cur_mode="$_ev" ;;
                esac
            done < "$XMG_WARP_ENV_FILE"
        fi
        if [ "$_cur_on" = "1" ]; then
            case "$_cur_mode" in
                global|routing) ;;
                *) _cur_mode="global" ;;
            esac
            xmg_info "检测到 WARP 已启用，正在将优选端点自动同步至 Xray 配置并重启生效..."
            if [ "$_cur_mode" = "routing" ] && [ -n "$_cur_geo" ]; then
                xmg_warp_enable routing --geo "$_cur_geo" >/dev/null 2>&1 || xmg_warn "自动同步端点失败，请手动执行 xmg warp enable routing"
            else
                xmg_warp_enable "$_cur_mode" >/dev/null 2>&1 || xmg_warn "自动同步端点失败，请手动执行 xmg warp enable $_cur_mode"
            fi
        fi
    fi

    echo "$best_ep"
    return 0
}

# ===== Base64 client_id 解码为 WireGuard 3 字节保留字段 (reserved: [r0, r1, r2]) =====

_xmg_warp_decode_client_id() {
    local b64="${1:-}"
    if [ -z "$b64" ] || [ "$b64" = "null" ]; then
        echo "0 0 0"
        return 0
    fi

    # 1. 优先使用 Python3 (绝大多数现代 Linux 默认包含)
    if command -v python3 >/dev/null 2>&1; then
        local py_res=""
        py_res="$(python3 -c "
import base64
try:
    b = base64.b64decode('$b64')
    if len(b) >= 3:
        print(f'{b[0]} {b[1]} {b[2]}')
    elif len(b) == 0:
        print('0 0 0')
    else:
        pad = list(b) + [0] * (3 - len(b))
        print(f'{pad[0]} {pad[1]} {pad[2]}')
except Exception:
    print('0 0 0')
" 2>/dev/null || true)"
        if [ -n "$py_res" ]; then
            echo "$py_res"
            return 0
        fi
    fi

    # 2. 次选 base64 + od (POSIX 标准)
    if command -v base64 >/dev/null 2>&1 && command -v od >/dev/null 2>&1; then
        local hex=""
        hex="$(printf '%s' "$b64" | base64 -d 2>/dev/null | od -An -tx1 2>/dev/null | tr -s ' ' || true)"
        if [ -n "$hex" ]; then
            local h0="" h1="" h2=""
            read -r h0 h1 h2 _ <<< "$hex"
            if [ -n "$h0" ] && [ -n "$h1" ] && [ -n "$h2" ]; then
                printf '%d %d %d\n' "$((16#$h0))" "$((16#$h1))" "$((16#$h2))"
                return 0
            fi
        fi
    fi

    # 3. 次选 base64 + hexdump
    if command -v base64 >/dev/null 2>&1 && command -v hexdump >/dev/null 2>&1; then
        local hex=""
        hex="$(printf '%s' "$b64" | base64 -d 2>/dev/null | hexdump -v -e '/1 "%02x "' 2>/dev/null || true)"
        if [ -n "$hex" ]; then
            local h0="" h1="" h2=""
            read -r h0 h1 h2 _ <<< "$hex"
            if [ -n "$h0" ] && [ -n "$h1" ] && [ -n "$h2" ]; then
                printf '%d %d %d\n' "$((16#$h0))" "$((16#$h1))" "$((16#$h2))"
                return 0
            fi
        fi
    fi

    echo "0 0 0"
}

# ===== 标准化 Base64 编码 (解决 Xray RawURLEncoding 导致 CF 接口报 400 Invalid public key) =====

_xmg_warp_std_b64() {
    local val="$1"
    [ -n "$val" ] || return 0
    val="${val//-/+}"
    val="${val//_//}"
    while [ $(( ${#val} % 4 )) -ne 0 ]; do
        val="${val}="
    done
    echo "$val"
}

# ===== 生成合法配对的 Curve25519 密钥对 =====

_xmg_warp_gen_keys() {
    if [ -n "${XMG_MOCK_WARP_PRIVKEY:-}" ]; then
        echo "${XMG_MOCK_WARP_PRIVKEY} ${XMG_MOCK_WARP_PUBKEY:-mockpubkey}"
        return 0
    fi

    local priv="" pub=""

    # 1. 优先通过 Xray 内核生成真实配对的 Curve25519 密钥对 (xray x25519)
    local xray_bin=""
    if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
        xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"
    elif command -v xray >/dev/null 2>&1; then
        xray_bin="$(command -v xray)"
    elif [ -x /usr/local/bin/xray ]; then
        xray_bin="/usr/local/bin/xray"
    fi

    if [ -n "$xray_bin" ] && [ -x "$xray_bin" ]; then
        local k_out=""
        k_out="$("$xray_bin" x25519 2>/dev/null || "$xray_bin" wg 2>/dev/null || true)"
        priv="$(echo "$k_out" | grep -iE 'Private[[:space:]]*Key' | head -1 | cut -d: -f2- | tr -d '[:space:]')"
        pub="$(echo "$k_out" | grep -iE '(Public[[:space:]]*Key|Password)' | head -1 | cut -d: -f2- | tr -d '[:space:]')"
        if [ -n "$priv" ] && [ -n "$pub" ]; then
            priv="$(_xmg_warp_std_b64 "$priv")"
            pub="$(_xmg_warp_std_b64 "$pub")"
            if [ "${#priv}" -eq 44 ] && [ "${#pub}" -eq 44 ]; then
                echo "$priv $pub"
                return 0
            fi
        fi
    fi

    # 2. 次选系统 openssl 原生命令生成 (所有主流 Linux 发行版均标配)
    if command -v openssl >/dev/null 2>&1; then
        local tmp_der=""
        tmp_der="$(mktemp 2>/dev/null || echo "${XMG_WARP_DIR:-/opt/xmg/warp}/.ossl_$$_$RANDOM.der")"
        if openssl genpkey -algorithm x25519 -outform DER -out "$tmp_der" 2>/dev/null; then
            priv="$(tail -c 32 "$tmp_der" 2>/dev/null | base64 2>/dev/null | tr -d '[:space:]' || true)"
            pub="$(openssl pkey -inform DER -in "$tmp_der" -pubout -outform DER 2>/dev/null | tail -c 32 2>/dev/null | base64 2>/dev/null | tr -d '[:space:]' || true)"
            rm -f "$tmp_der" 2>/dev/null || true
            priv="$(_xmg_warp_std_b64 "$priv")"
            pub="$(_xmg_warp_std_b64 "$pub")"
            if [ "${#priv}" -eq 44 ] && [ "${#pub}" -eq 44 ]; then
                echo "$priv $pub"
                return 0
            fi
        fi
        rm -f "$tmp_der" 2>/dev/null || true
    fi

    # 3. 次选系统 wg 工具 (wireguard-tools)
    if command -v wg >/dev/null 2>&1; then
        priv="$(wg genkey 2>/dev/null || true)"
        if [ -n "$priv" ]; then
            pub="$(echo "$priv" | wg pubkey 2>/dev/null || true)"
            priv="$(_xmg_warp_std_b64 "$priv")"
            pub="$(_xmg_warp_std_b64 "$pub")"
            if [ "${#priv}" -eq 44 ] && [ "${#pub}" -eq 44 ]; then
                echo "$priv $pub"
                return 0
            fi
        fi
    fi

    # 4. 次选 python3 cryptography 生成合法的 X25519 密钥对
    if command -v python3 >/dev/null 2>&1; then
        local py_keys=""
        py_keys="$(python3 -c '
import base64
try:
    from cryptography.hazmat.primitives.asymmetric import x25519
    k = x25519.X25519PrivateKey.generate()
    print(base64.b64encode(k.private_bytes_raw()).decode(), base64.b64encode(k.public_key().public_bytes_raw()).decode())
except Exception:
    pass
' 2>/dev/null || true)"
        if [ -n "$py_keys" ]; then
            read -r priv pub _ <<< "$py_keys"
            priv="$(_xmg_warp_std_b64 "$priv")"
            pub="$(_xmg_warp_std_b64 "$pub")"
            if [ "${#priv}" -eq 44 ] && [ "${#pub}" -eq 44 ]; then
                echo "$priv $pub"
                return 0
            fi
        fi
    fi

    xmg_error "生成合法的 WireGuard Curve25519 密钥对失败 (请确保已安装 xray, openssl 或 wg)"
    return 1
}

# ===== 注册 Cloudflare WARP 免费账号并持久化凭据 =====

_xmg_warp_register() {
    local force="${1:-0}"
    mkdir -p "$XMG_WARP_DIR" 2>/dev/null || true

    # 若已存在凭据，且非强制重新注册，则核验凭据纯净度与 client_id
    if [ "$force" != "1" ] && [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        local _reg_raw="" cur_priv="" cur_v4="" cur_v6="" cur_res="" cur_cid=""
        _reg_raw="$(< "$XMG_WARP_ACCOUNT_FILE")" 2>/dev/null || true
        cur_priv="$(_xmg_warp_json_val "$_reg_raw" "private_key")"
        cur_v4="$(_xmg_warp_json_val "$_reg_raw" "address_v4")"
        cur_v6="$(_xmg_warp_json_val "$_reg_raw" "address_v6")"
        cur_cid="$(_xmg_warp_json_val "$_reg_raw" "client_id")"
        [[ "$_reg_raw" == *'"reserved"'* ]] && cur_res="1"

        # 自愈校验 1: 若内网 IPv6 损坏（含中括号、或地址末尾被拼上端口），自动重新注册
        #   注意不能用 ":[0-9]+$" 判定端口污染 —— 合法 IPv6 末组也常是全数字
        if [ -n "$cur_v6" ]; then
            if [[ "$cur_v6" =~ \[ ]] || ! _xmg_is_valid_ipv6 "$cur_v6"; then
                xmg_warn "检测到旧 WARP 凭据内网 IP 受损或被历史 Endpoint 污染，自动重新注册纯净凭据..."
                force=1
            fi
        fi

        # 自愈校验 2: 核心保留字段自愈！若旧凭据缺失 reserved 或为全零且未记录 client_id，重新注册确保 Cloudflare 握手成功
        if [ "$force" != "1" ] && [ -z "$cur_res" ]; then
            xmg_warn "检测到旧 WARP 凭据缺失 WireGuard 3 字节保留标识 (reserved)，自动重新注册纯净凭据..."
            force=1
        fi

        if [ "$force" != "1" ] && [ -n "$cur_priv" ] && [ -n "$cur_v4" ]; then
            xmg_info "复用已有 WARP 账号凭据: $XMG_WARP_ACCOUNT_FILE"
            return 0
        fi
    fi

    local privkey="" pubkey="" keys=""
    keys="$(_xmg_warp_gen_keys)" || return 1
    read -r privkey pubkey _ <<< "$keys"

    local resp=""
    # 临时文件必须在两个分支外声明：mock 分支也会走到失败诊断，
    # 之前声明在 else 内，mock 失败时 set -u 会直接 unbound variable。
    local tmp_body="" tmp_err="" last_http="000" last_err=""
    if [ -n "${XMG_MOCK_WARP_API_RESP:-}" ]; then
        resp="$XMG_MOCK_WARP_API_RESP"
    else
        xmg_info "正在向 Cloudflare 官方 API 注册免费 WARP 设备..."
        local cur_time=""
        cur_time="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
        [ -n "$cur_time" ] || cur_time="2026-01-01T00:00:00Z"
        local req_body="{\"key\":\"$pubkey\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$cur_time\",\"model\":\"Linux\",\"type\":\"Android\",\"locale\":\"zh_CN\"}"

        local endpoints=(
            "https://api.cloudflareclient.com/v0a2158/reg"
            "https://api.cloudflareclient.com/v0a884/reg"
            "https://api.cloudflareclient.com/v0a1922/reg"
        )

        local net_fam
        net_fam="$(_xmg_warp_curl_family)"

        local attempts=("$net_fam")
        if [ -z "$net_fam" ] && [ "${XMG_NET_IPV6:-0}" = "1" ]; then
            attempts=("" "-6")
        fi

        tmp_body="$(mktemp 2>/dev/null || echo "${XMG_WARP_DIR:-/opt/xmg/warp}/.reg_$$_$RANDOM.json")"
        tmp_err="$(mktemp 2>/dev/null || echo "${XMG_WARP_DIR:-/opt/xmg/warp}/.reg_$$_$RANDOM.err")"

        for fam_opt in "${attempts[@]}"; do
            local curl_args=()
            [ -n "$fam_opt" ] && curl_args=("$fam_opt")

            for ep_url in "${endpoints[@]}"; do
                : > "$tmp_body"
                : > "$tmp_err"

                local http_code="000"
                http_code="$(curl "${curl_args[@]}" -sS -o "$tmp_body" -w "%{http_code}" \
                    --connect-timeout 8 --max-time 15 -X POST "$ep_url" \
                    -H "Content-Type: application/json; charset=UTF-8" \
                    -H "User-Agent: okhttp/3.12.1" \
                    -d "$req_body" 2>"$tmp_err" || echo "000")"

                last_http="$http_code"
                if [ -s "$tmp_body" ] && grep -q '"id"' "$tmp_body"; then
                    resp="$(cat "$tmp_body")"
                    break 2
                fi

                if [ -s "$tmp_err" ]; then
                    last_err="$(head -n 1 "$tmp_err" | tr -d '\r\n')"
                fi
            done
        done
    fi

    if [ -z "$resp" ] || ! echo "$resp" | grep -q '"id"'; then
        local cf_err_msg=""
        if [ -s "$tmp_body" ]; then
            cf_err_msg="$(grep -oE '"message"[[:space:]]*:[[:space:]]*"[^"]+"' "$tmp_body" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
            if [ -z "$cf_err_msg" ]; then
                cf_err_msg="$(grep -oE '"errors"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$tmp_body" 2>/dev/null | head -1 || true)"
            fi
        fi

        if [ "$last_http" = "429" ]; then
            xmg_error "向 Cloudflare 注册账号失败: HTTP 429 请求频次超限 (Rate Limited)"
            xmg_warn "说明: 当前 IP 近期申请 Cloudflare WARP 设备数量已达官方上限"
        elif [ "$last_http" = "403" ]; then
            xmg_error "向 Cloudflare 注册账号失败: HTTP 403 访问被拦截 (Forbidden / Cloudflare 边缘安全防护)"
            xmg_warn "说明: 当前 VPS 机房 IP 被 Cloudflare 判定为数据中心风险流量"
        elif [ "$last_http" = "400" ]; then
            xmg_error "向 Cloudflare 注册账号失败: HTTP 400 请求被拒绝 (Bad Request)"
            [ -n "$cf_err_msg" ] && xmg_warn "Cloudflare 错误提示: $cf_err_msg"
        elif [ "$last_http" = "000" ]; then
            xmg_error "向 Cloudflare 注册账号失败: 网络连接超时或不可达 (HTTP 000)"
            [ -n "$last_err" ] && xmg_warn "底层报错: $last_err"
            if xmg_warp_is_ipv6_only; then
                xmg_warn "环境提示: 当前为纯 IPv6 VPS，请确保系统 DNS 能够解析 Cloudflare API 并具备 IPv6 外网连通性"
            fi
        else
            xmg_error "向 Cloudflare 注册账号失败: 响应异常 (HTTP $last_http)"
            [ -n "$cf_err_msg" ] && xmg_warn "提示: $cf_err_msg"
            [ -n "$last_err" ] && xmg_warn "详情: $last_err"
        fi

        xmg_warn "------------------------------------------------------------"
        xmg_warn "自愈指引: 若当前 VPS 机房受限无法在线注册，可选用以下方式一键解决:"
        xmg_warn "  1. 外部导入: 在本地电脑或未受限设备生成凭据，执行: xmg warp import <account.json>"
        xmg_warn "  2. 手动放置: 将有效凭据文件直接保存至 $XMG_WARP_ACCOUNT_FILE"
        xmg_warn "------------------------------------------------------------"
        if [ -n "$tmp_body" ]; then rm -f "$tmp_body" 2>/dev/null || true; fi
        if [ -n "$tmp_err" ]; then rm -f "$tmp_err" 2>/dev/null || true; fi
        return 1
    fi

    # 提取注册凭据前先清理临时文件（成功路径不再需要响应体）
    if [ -n "$tmp_body" ]; then rm -f "$tmp_body" 2>/dev/null || true; fi
    if [ -n "$tmp_err" ]; then rm -f "$tmp_err" 2>/dev/null || true; fi

    # 提取注册凭据
    local dev_id="" token="" addr_v4="" addr_v6="" peer_pub="" peer_ep_v4="" peer_ep_v6="" client_id=""
    dev_id="$(_xmg_warp_json_val "$resp" ".id")"
    token="$(_xmg_warp_json_val "$resp" ".token")"

    # 精准提取 addresses
    local addr_block="${resp#*\"addresses\"}"
    addr_block="${addr_block%%\}*}"

    addr_v4="$(echo "$addr_block" | grep -o '"v4"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
    addr_v6="$(echo "$addr_block" | grep -o '"v6"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"

    addr_v4="$(_xmg_warp_clean_ipv4 "$addr_v4")"
    addr_v6="$(_xmg_warp_clean_ipv6 "$addr_v6")"

    peer_pub="$(echo "$resp" | grep -o '"public_key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"

    if [[ "$resp" == *"endpoint"* ]]; then
        local ep_block="${resp#*\"endpoint\"}"
        ep_block="${ep_block%%\}*}"
        peer_ep_v6="$(echo "$ep_block" | grep -o '"v6"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
        peer_ep_v4="$(echo "$ep_block" | grep -o '"v4"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
    fi

    # 提取 client_id 并解码为 3 字节十进制 reserved
    client_id="$(_xmg_warp_json_val "$resp" ".config.client_id")"
    if [ -z "$client_id" ] || [ "$client_id" = "null" ]; then
        client_id="$(echo "$resp" | grep -o '"client_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    fi

    local r_bytes="" r0="0" r1="0" r2="0"
    r_bytes="$(_xmg_warp_decode_client_id "$client_id")"
    read -r r0 r1 r2 _ <<< "$r_bytes"
    [ -n "$r0" ] || r0="0"
    [ -n "$r1" ] || r1="0"
    [ -n "$r2" ] || r2="0"

    # 校验 Endpoint 合法性
    if [[ ! "$peer_ep_v6" =~ :[0-9]+$ ]]; then
        peer_ep_v6=""
    fi
    if [[ ! "$peer_ep_v4" =~ :[0-9]+$ ]]; then
        peer_ep_v4=""
    fi

    [ -n "$peer_pub" ] || peer_pub="$XMG_WARP_PEER_PUBKEY"
    [ -n "$peer_ep_v6" ] || peer_ep_v6="$XMG_WARP_ENDPOINT_V6"
    [ -n "$peer_ep_v4" ] || peer_ep_v4="$XMG_WARP_ENDPOINT_V4"

    peer_ep_v6="$(_xmg_warp_norm_endpoint_v6 "$peer_ep_v6")"
    if [[ "$peer_ep_v4" =~ :0$ ]]; then
        peer_ep_v4="${peer_ep_v4%:0}:2408"
    fi

    # 保存纯净凭据至 account.json (严格包含 client_id 与 reserved)
    mkdir -p "$(dirname "$XMG_WARP_ACCOUNT_FILE")"
    cat > "$XMG_WARP_ACCOUNT_FILE" <<EOF
{
  "device_id": "$dev_id",
  "token": "$token",
  "private_key": "$privkey",
  "public_key": "$pubkey",
  "address_v4": "$addr_v4",
  "address_v6": "$addr_v6",
  "peer_public_key": "$peer_pub",
  "endpoint_v6": "$peer_ep_v6",
  "endpoint_v4": "$peer_ep_v4",
  "client_id": "$client_id",
  "reserved": [$r0, $r1, $r2]
}
EOF
    chmod 600 "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true

    mkdir -p "$(dirname "$XMG_WARP_ENV_FILE")"
    # 保留原有的启用标记：register 会被 auto_apply 在 enable 之前调用，
    # 整体重写会把 WARP_ENABLED/WARP_MODE 一并抹掉，导致配置里 warp-out 还在
    # 而 status（只读 warp.env）报「未启用」
    local _keep_flag="" _keep_mode=""
    if [ -f "$XMG_WARP_ENV_FILE" ]; then
        _keep_flag="$(grep -E '^WARP_ENABLED=' "$XMG_WARP_ENV_FILE" 2>/dev/null | tail -n 1 || true)"
        _keep_mode="$(grep -E '^WARP_MODE=' "$XMG_WARP_ENV_FILE" 2>/dev/null | tail -n 1 || true)"
    fi
    cat > "$XMG_WARP_ENV_FILE" <<EOF
WARP_DEV_ID="$dev_id"
WARP_ADDR_V4="$addr_v4"
WARP_ADDR_V6="$addr_v6"
EOF
    [ -n "$_keep_flag" ] && printf '%s\n' "$_keep_flag" >> "$XMG_WARP_ENV_FILE"
    [ -n "$_keep_mode" ] && printf '%s\n' "$_keep_mode" >> "$XMG_WARP_ENV_FILE"
    chmod 600 "$XMG_WARP_ENV_FILE" 2>/dev/null || true

    xmg_info "WARP 账号注册成功 (分配虚拟 IPv4: $addr_v4, 鉴权保留字段: [$r0, $r1, $r2])"
    return 0
}

# ===== 导入已有 WARP 凭据 (突破机房 IP 注册受限) =====

xmg_warp_import() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    local src="${1:-}"

    if [ -z "$src" ]; then
        if [ -t 0 ]; then
            printf "请输入 WARP 账号凭据文件路径 (account.json): "
            read -r src || return 1
        else
            xmg_error "请指定待导入的 WARP account.json 路径"
            return 1
        fi
    fi

    if [ ! -f "$src" ]; then
        xmg_error "凭据文件不存在: $src"
        return 1
    fi

    local priv_k cid
    priv_k="$(grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$src" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
    if [ -z "$priv_k" ]; then
        xmg_error "无效的凭据文件: 缺少 private_key 字段"
        return 1
    fi

    mkdir -p "$XMG_WARP_DIR"
    cp -f "$src" "$XMG_WARP_ACCOUNT_FILE"
    chmod 600 "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true

    local cur_res
    cur_res="$(grep -o '"reserved"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true)"
    if [ -z "$cur_res" ]; then
        cid="$(grep -o '"client_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
        if [ -n "$cid" ] && [ "$cid" != "null" ]; then
            local r_bytes r0="0" r1="0" r2="0"
            r_bytes="$(_xmg_warp_decode_client_id "$cid")"
            read -r r0 r1 r2 _ <<< "$r_bytes"
            [ -n "$r0" ] || r0="0"
            [ -n "$r1" ] || r1="0"
            [ -n "$r2" ] || r2="0"
            if command -v jq >/dev/null 2>&1; then
                local tmp_acc="${XMG_WARP_ACCOUNT_FILE}.tmp"
                jq ".reserved = [$r0, $r1, $r2]" "$XMG_WARP_ACCOUNT_FILE" > "$tmp_acc" && mv -f "$tmp_acc" "$XMG_WARP_ACCOUNT_FILE"
            fi
        fi
    fi

    xmg_info "成功导入 WARP 账号凭据至: $XMG_WARP_ACCOUNT_FILE"
    return 0
}

# ===== Xray 原生 WireGuard 出站配置片段导出 =====

xmg_warp_export_xray_outbound() {
    local target_file="${1:-}"
    if [ ! -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        _xmg_warp_register 0 || return 1
    fi

    _xmg_warp_get_account_vars || return 1
    local privkey="$WARP_ACC_PRIVKEY"
    local peer_pub="$WARP_ACC_PUBKEY"
    local addr_v4="$WARP_ACC_IPV4"
    local addr_v6="$WARP_ACC_IPV6"
    local endpoint="$WARP_ACC_ENDPOINT"
    local reserved_json="$WARP_ACC_RESERVED"

    # 隧道实际拥有哪些地址族，直接决定 allowedIPs / remoteDNS / targetStrategy
    local _host_v6_only=0
    xmg_warp_is_ipv6_only && _host_v6_only=1

    local _wprof="" w_allowed="" w_dns="" w_strat=""
    _wprof="$(_xmg_warp_tunnel_profile "$addr_v4" "$addr_v6" "$_host_v6_only")" || _wprof=""
    if [ -z "$_wprof" ]; then
        xmg_error "WARP 账号未提供任何可用地址（IPv4/IPv6 皆空），拒绝生成无承载能力的出站"
        return 1
    fi
    IFS='|' read -r w_allowed w_dns w_strat <<< "$_wprof" || true

    # address 只列真实分配到的地址族，空值拼出的 "/32" 会让内核直接拒绝启动
    local address_json=""
    [ -n "$addr_v4" ] && address_json="\"$addr_v4/32\""
    if [ -n "$addr_v6" ]; then
        if [ -n "$address_json" ]; then
            address_json="$address_json,\n      \"$addr_v6/128\""
        else
            address_json="\"$addr_v6/128\""
        fi
    fi

    local xray_json=""
    xray_json="$(cat <<EOF
{
  "tag": "warp-out",
  "protocol": "wireguard",
  "targetStrategy": "$w_strat",
  "settings": {
    "secretKey": "$privkey",
    "address": [
      $(printf '%b' "$address_json")
    ],
    "peers": [
      {
        "publicKey": "$peer_pub",
        "endpoint": "$endpoint",
        "keepAlive": 25,
        "allowedIPs": [
          $(printf '%b' "$w_allowed")
        ]
      }
    ],
    "reserved": $reserved_json,
    "noKernelTun": true,
    "mtu": 1280,
    "remoteDNS": [
      $(printf '%b' "$w_dns")
    ]
  }
}
EOF
)"

    if [ -n "$target_file" ]; then
        mkdir -p "$(dirname "$target_file")"
        echo "$xray_json" > "$target_file"
        xmg_info "Xray WireGuard 出站配置片段已写入: $target_file"
    else
        echo "$xray_json"
    fi
}

# 智能精准定位系统当前 Xray 实际加载生效的配置文件路径
_xmg_warp_find_xray_config() {
    if [ -n "${XMG_XRAY_CONFIG:-}" ]; then
        echo "$XMG_XRAY_CONFIG"
        return 0
    fi

    if command -v pgrep >/dev/null 2>&1 || command -v ps >/dev/null 2>&1; then
        local proc_cmd=""
        # BusyBox ps 不支持 aux，退回 POSIX 的 -ef
        proc_cmd="$(ps aux 2>/dev/null | grep -E '[x]ray.*run.*-c' | head -1 || true)"
        if [ -z "$proc_cmd" ]; then
            proc_cmd="$(ps -ef 2>/dev/null | grep -E '[x]ray.*run.*-c' | head -1 || true)"
        fi
        if [ -n "$proc_cmd" ]; then
            local parsed_cfg=""
            parsed_cfg="$(echo "$proc_cmd" | grep -oE '(-c|-config)[[:space:]]+[^[:space:]]+' | awk '{print $2}' | head -1)"
            if [ -n "$parsed_cfg" ] && [ -f "$parsed_cfg" ]; then
                echo "$parsed_cfg"
                return 0
            fi
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        local svc_name="${XMG_XRAY_SERVICE:-xray}"
        local unit_exec=""
        unit_exec="$(systemctl cat "$svc_name" 2>/dev/null | grep -E '^ExecStart=' | tail -1 || true)"
        if [ -n "$unit_exec" ]; then
            local parsed_unit_cfg=""
            parsed_unit_cfg="$(echo "$unit_exec" | grep -oE '(-c|-config)[[:space:]]+[^[:space:]]+' | awk '{print $2}' | head -1)"
            if [ -n "$parsed_unit_cfg" ] && [ -f "$parsed_unit_cfg" ]; then
                echo "$parsed_unit_cfg"
                return 0
            fi
        fi
    fi

    for cand in \
        "${XMG_HOME:-/opt/xmg}/xray/config.json" \
        "/opt/xmg/xray/config.json" \
        "/usr/local/etc/xray/config.json" \
        "/etc/xray/config.json"; do
        if [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done

    echo "${XMG_HOME:-/opt/xmg}/xray/config.json"
}

_xmg_warp_backup_config() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    local bak_dir=""
    if [ -n "${XMG_BACKUP_DIR:-}" ]; then
        bak_dir="$XMG_BACKUP_DIR"
    else
        bak_dir="${XMG_HOME:-/opt/xmg}/backups"
    fi
    mkdir -p "$bak_dir" 2>/dev/null || true
    local bname="${cfg##*/}"
    local base_bak="$bak_dir/${bname}.warp.bak.$(date +%Y%m%d%H%M%S).$$"
    local _seq=0
    local bak_file="${base_bak}_0"
    while [ -e "$bak_file" ]; do
        _seq=$((_seq + 1))
        bak_file="${base_bak}_${_seq}"
    done
    cp -f "$cfg" "$bak_file" 2>/dev/null || true

    local keep="${XMG_BACKUP_KEEP:-5}"
    case "$keep" in ''|*[!0-9]*) keep=5 ;; esac
    if [ "$keep" -gt 0 ]; then
        local -a wbaks=()
        local _wf=""
        for _wf in "$bak_dir/${bname}".warp.bak.*; do
            [ -f "$_wf" ] && wbaks+=("$_wf")
        done
        local wtotal="${#wbaks[@]}"
        if [ "$wtotal" -gt "$keep" ]; then
            local wdel=$((wtotal - keep)) widx=0
            while [ "$widx" -lt "$wdel" ]; do
                rm -f "${wbaks[$widx]}" 2>/dev/null || true
                widx=$((widx + 1))
            done
        fi
    fi

    echo "$bak_file"
}

# ===== 辅助: 纯 Bash 安全更新 account.json 端点与 warp.env 键值（零 sed -i，保持 0600 权限）=====
_xmg_warp_account_set_ep() {
    local key="$1" ep="$2"
    [ -f "$XMG_WARP_ACCOUNT_FILE" ] || return 0
    local _line="" _out="" _nl=$'\n'
    while IFS= read -r _line || [ -n "$_line" ]; do
        if [[ "$_line" == *"\"${key}\""* ]]; then
            local _prefix="${_line%%:*}: \""
            local _rest="${_line#*:}"
            local _comma=""
            [[ "$_rest" == *","* ]] && _comma=","
            _line="${_prefix}${ep}\"${_comma}"
        fi
        _out="${_out}${_line}${_nl}"
    done < "$XMG_WARP_ACCOUNT_FILE"
    printf '%s' "$_out" > "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
    chmod 600 "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
}

_xmg_warp_env_set() {
    mkdir -p "$(dirname "$XMG_WARP_ENV_FILE")" 2>/dev/null || true
    local -A _updates=()
    local -a _order=()
    local _kv="" _k="" _v=""
    for _kv in "$@"; do
        _k="${_kv%%=*}"
        _v="${_kv#*=}"
        _updates["$_k"]="$_v"
        _order+=("$_k")
    done
    local _line="" _lk="" _out="" _nl=$'\n'
    if [ -f "$XMG_WARP_ENV_FILE" ]; then
        while IFS= read -r _line || [ -n "$_line" ]; do
            _lk="${_line%%=*}"
            if [ -n "${_updates[$_lk]+set}" ]; then
                continue
            fi
            [ -n "$_line" ] && _out="${_out}${_line}${_nl}"
        done < "$XMG_WARP_ENV_FILE"
    fi
    for _k in "${_order[@]}"; do
        _out="${_out}${_k}=${_updates[$_k]}${_nl}"
    done
    printf '%s' "$_out" > "$XMG_WARP_ENV_FILE" 2>/dev/null || true
    chmod 600 "$XMG_WARP_ENV_FILE" 2>/dev/null || true
}

# ===== 辅助: 从 account.json 提取账号变量（纯 Bash 单次内存读取，零外部子进程）=====
_xmg_warp_get_account_vars() {
    [ -f "$XMG_WARP_ACCOUNT_FILE" ] || return 1
    local acc_raw=""
    acc_raw="$(< "$XMG_WARP_ACCOUNT_FILE")" 2>/dev/null || return 1
    local privkey="" addr_v4="" addr_v6="" peer_pub="" ep_v6="" ep_v4="" reserved_json=""
    privkey="$(_xmg_warp_json_val "$acc_raw" "private_key")"
    addr_v4="$(_xmg_warp_json_val "$acc_raw" "address_v4")"
    addr_v6="$(_xmg_warp_json_val "$acc_raw" "address_v6")"
    peer_pub="$(_xmg_warp_json_val "$acc_raw" "peer_public_key")"
    ep_v6="$(_xmg_warp_json_val "$acc_raw" "endpoint_v6")"
    ep_v4="$(_xmg_warp_json_val "$acc_raw" "endpoint_v4")"
    local raw_res=""
    if [[ "$acc_raw" == *'"reserved"'* ]]; then
        raw_res="${acc_raw#*\"reserved\"}"
        raw_res="${raw_res#*\[}"
        raw_res="${raw_res%%\]*}"
    fi
    if [ -n "$raw_res" ]; then
        local nums="${raw_res//[\[\]]/}"
        nums="${nums//,/ }"
        nums="${nums//[$'\r\n']/ }"
        local r0="0" r1="0" r2="0"
        read -r r0 r1 r2 _ <<< "$nums"
        reserved_json="[${r0:-0}, ${r1:-0}, ${r2:-0}]"
    else
        local c_id=""
        c_id="$(_xmg_warp_json_val "$acc_raw" "client_id")"
        if [ -n "$c_id" ] && [ "$c_id" != "null" ]; then
            local rb="" r0="0" r1="0" r2="0"
            rb="$(_xmg_warp_decode_client_id "$c_id")"
            read -r r0 r1 r2 _ <<< "$rb"
            reserved_json="[$r0, $r1, $r2]"
        else
            reserved_json="[0, 0, 0]"
        fi
    fi

    addr_v4="$(_xmg_warp_clean_ipv4 "$addr_v4")"
    addr_v6="$(_xmg_warp_clean_ipv6 "$addr_v6")"
    [ -n "$peer_pub" ] || peer_pub="$XMG_WARP_PEER_PUBKEY"

    local endpoint=""
    if xmg_warp_is_ipv6_only; then
        endpoint="$(_xmg_warp_norm_endpoint_v6 "${ep_v6:-$XMG_WARP_ENDPOINT_V6}")"
    else
        endpoint="${ep_v4:-$XMG_WARP_ENDPOINT_V4}"
        if [[ "$endpoint" =~ :0$ ]]; then
            endpoint="${endpoint%:0}:2408"
        fi
    fi

    WARP_ACC_PRIVKEY="$privkey"
    WARP_ACC_PUBKEY="$peer_pub"
    WARP_ACC_IPV4="$addr_v4"
    WARP_ACC_IPV6="$addr_v6"
    WARP_ACC_ENDPOINT="$endpoint"
    WARP_ACC_RESERVED="$reserved_json"
    return 0
}

# ===== 地理数据文件管理（WARP 分流用） =====
# 数据源与落盘位置严格跟随 Xray 官方：
#   1. 官方仓库 XTLS/Xray-rules-dat 提供 geosite.dat(.gz) 与 .sha256sum；
#   2. 官方 install-release.sh 的 DAT_PATH 默认就是 /usr/local/share/xray，
#      这也是 Xray 内核查找资源文件的默认目录，无需额外设 XRAY_LOCATION_ASSET。
#   体积取舍：geosite.dat 解压后约 7.7MB，压缩包 2.4MB；geosite-expand.dat 解压 100MB+，
#   低配机一律不用。官方源失败时回退 v2fly dlc.dat（2.4MB，标签集兼容）。

xmg_warp_geo_dir() {
    printf '%s' "${XMG_XRAY_ASSET_DIR:-/usr/local/share/xray}"
}

_xmg_warp_geo_size() {
    local f="${1:-}" sz=''
    [ -f "$f" ] || { printf '0'; return 0; }
    sz="$(wc -c < "$f" 2>/dev/null || true)"
    sz="${sz//[[:space:]]/}"
    [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
    printf '%s' "$sz"
}

# 下载器：curl 优先，wget 兜底；镜像用于 GitHub 直连受限的机房
_xmg_warp_geo_get() {
    local url="$1" out="$2" timeout="${3:-120}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 8 --max-time "$timeout" "$url" -o "$out" 2>/dev/null && return 0
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$out" "$url" 2>/dev/null && return 0
    fi
    return 1
}

_xmg_warp_sha256() {
    local f="$1" h=''
    if command -v sha256sum >/dev/null 2>&1; then
        h="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        h="$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
    elif command -v busybox >/dev/null 2>&1; then
        h="$(busybox sha256sum "$f" 2>/dev/null | awk '{print $1}')"
    fi
    printf '%s' "${h,,}"
}

# 官方源：geosite.dat.gz（2.4MB）→ gzip 解压 → 原子替换
_xmg_warp_geo_fetch_official() {
    local out="$1"
    local base="https://github.com/XTLS/Xray-rules-dat/releases/latest/download"
    local gz="${out}.gz.$$"
    local sumf="${gz}.sum"
    local un="${out}.xmg-new.$$"
    local u='' sum='' calc='' sz=0

    for u in "$base" "https://ghfast.top/$base" "https://mirror.ghproxy.com/$base"; do
        rm -f "$gz" "$sumf" "$un" 2>/dev/null || true
        _xmg_warp_geo_get "$u/geosite.dat.gz" "$gz" 150 || continue
        _xmg_warp_geo_get "$u/geosite.dat.gz.sha256sum" "$sumf" 30 || true

        # 压缩包至少 1MB，挡掉 404 页面与被截断的半包
        [ "$(_xmg_warp_geo_size "$gz")" -ge 1048576 ] || continue

        if [ -s "$sumf" ]; then
            sum="$(awk '{print $1; exit}' "$sumf" 2>/dev/null | tr 'A-F' 'a-f')"
            calc="$(_xmg_warp_sha256 "$gz")"
            if [ -n "$sum" ] && [ -n "$calc" ] && [ "$sum" != "$calc" ]; then
                xmg_warn "地理数据 sha256 校验不匹配，换下一个源重试..."
                continue
            fi
        fi

        if gzip -dc "$gz" > "$un" 2>/dev/null; then
            sz="$(_xmg_warp_geo_size "$un")"
            if [ "$sz" -ge 1048576 ] && [ "$sz" -le 20971520 ]; then
                if mv -f "$un" "$out" 2>/dev/null; then
                    rm -f "$gz" "$sumf" 2>/dev/null || true
                    return 0
                fi
            fi
        fi
    done
    rm -f "$gz" "$sumf" "$un" 2>/dev/null || true
    return 1
}

# 备用源：v2fly dlc.dat（未压缩 2.4MB，标签集与 Xray 官方兼容）
_xmg_warp_geo_fetch_v2fly() {
    local out="$1"
    local base="https://github.com/v2fly/domain-list-community/releases/latest/download"
    local un="${out}.xmg-new.$$"
    local u='' sz=0

    for u in "$base" "https://ghfast.top/$base" "https://mirror.ghproxy.com/$base"; do
        rm -f "$un" 2>/dev/null || true
        _xmg_warp_geo_get "$u/dlc.dat" "$un" 150 || continue
        sz="$(_xmg_warp_geo_size "$un")"
        if [ "$sz" -ge 1048576 ] && [ "$sz" -le 8388608 ]; then
            mv -f "$un" "$out" 2>/dev/null && return 0
        fi
    done
    rm -f "$un" 2>/dev/null || true
    return 1
}

_xmg_warp_geo_download() {
    local out="$1"
    _xmg_warp_geo_fetch_official "$out" && return 0
    xmg_warn "官方地理数据源不可用，回退 v2fly 社区数据源..."
    _xmg_warp_geo_fetch_v2fly "$out" && return 0
    return 1
}

# 确保地理数据就绪；结果写入全局 XMG_WARP_GEO_EFFECTIVE（失败会降为 off）。
# 必须在当前 shell 直接调用，不要放进 $(...) —— 否则变量回传会丢。
_xmg_warp_geo_prepare() {
    local want="${1:-auto}" mode='' dir='' f='' mark='' ts=0 now=0
    XMG_WARP_GEO_EFFECTIVE="off"

    mode="$(xmg_warp_geo_mode_resolve "$want")"
    if [ "$mode" = "off" ]; then
        return 0
    fi

    dir="$(xmg_warp_geo_dir)"
    f="${dir}/geosite.dat"
    XMG_WARP_GEOSITE_FILE="$f"
    export XMG_WARP_GEOSITE_FILE
    mark="${XMG_WARP_GEO_FAIL_MARK:-${XMG_WARP_DIR}/.geodata_failed}"

    if xmg_warp_geo_available; then
        rm -f "$mark" 2>/dev/null || true
        XMG_WARP_GEO_EFFECTIVE="$mode"
        return 0
    fi

    # 测试模式绝不触网：用例要的是确定性的规则结构，不是真实下载
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        return 0
    fi

    # 失败负缓存：三个源依次超时要等 24 秒以上，不能让用户每次 enable 都再等一遍。
    # 24 小时内直接走硬编码，需要重试时用 xmg warp geo update。
    if [ -f "$mark" ]; then
        ts="$(cat "$mark" 2>/dev/null | tr -d '[:space:]')"
        [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
        now="$(date +%s 2>/dev/null || printf 0)"
        if [ "$ts" -gt 0 ] && [ "$now" -gt 0 ] && [ $(( now - ts )) -lt 86400 ]; then
            xmg_info "地理数据 24 小时内获取失败过，本次直接使用硬编码域名 (xmg warp geo update 可强制重试)"
            return 0
        fi
    fi

    xmg_info "正在获取地理数据文件 (geosite.dat, 约 2.4MB)..."
    if ! mkdir -p "$dir" 2>/dev/null; then
        xmg_warn "无法创建地理数据目录: $dir，本次降级为硬编码分流"
        return 0
    fi
    if _xmg_warp_geo_download "$f" && xmg_warp_geo_available; then
        rm -f "$mark" 2>/dev/null || true
        xmg_info "地理数据已就绪: $f ($(_xmg_warp_geo_size "$f") 字节)"
        XMG_WARP_GEO_EFFECTIVE="$mode"
        return 0
    fi

    date +%s > "$mark" 2>/dev/null || true
    xmg_warn "地理数据获取失败，本次分流降级为内置硬编码域名 (核心 AI / 流媒体仍走 WARP)"
    xmg_info "24 小时内不再自动重试；需要时执行: xmg warp geo update"
    return 0
}

# ===== 无 jq 时的配置合并 =====
# XMG 托管配置（XMG_XRAY_CONFIG）由渲染器重建：WARP 出站与分流规则本来就在
# render.sh 里实现（纯 Bash），比 awk 手写 JSON 更可靠。
# 外部自定义配置无法在不解析 JSON 的前提下安全合并，直接报错，绝不写坏配置。
# 返回: 0=已渲染  1=渲染失败  2=非托管配置/渲染器不可用
_xmg_warp_render_managed_config() {
    local cfg="$1" out="$2"
    # 只认 XMG 自己的配置路径：XMG_XRAY_CONFIG 可被用户指向任意文件，
    # 用它做判据会把外部配置误当托管配置，重渲染后用户节点全丢。
    local managed="${XMG_HOME:-/opt/xmg}/xray/config.json"
    if [ "$cfg" != "$managed" ]; then
        return 2
    fi
    declare -F xmg_render_config >/dev/null 2>&1 || return 2

    local s_on="" v_on=""
    if declare -p XMG_STATE_STAGE >/dev/null 2>&1; then
        s_on="${XMG_STATE_STAGE[PROXY_SOCKS_ENABLED]:-}"
        v_on="${XMG_STATE_STAGE[PROXY_VLESS_ENABLED]:-}"
    fi
    [ -n "$s_on" ] || s_on="$(xmg_state_get PROXY_SOCKS_ENABLED 0)"
    [ -n "$v_on" ] || v_on="$(xmg_state_get PROXY_VLESS_ENABLED 0)"

    xmg_render_config "$s_on" "$v_on" > "$out" 2>/dev/null || return 1
    [ -s "$out" ] || return 1
    return 0
}

# ===== 启用 Xray 原生 WireGuard 出站 =====

xmg_warp_enable() {
    local mode="${1:-global}"
    local geo_want=""
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root

    # 第二种写法是 xmg warp enable routing --geo slim|std|full|off|auto
    if [ "${2:-}" = "--geo" ]; then
        geo_want="${3:-auto}"
    elif [ -n "${2:-}" ]; then
        geo_want="$2"
    fi
    case "$geo_want" in
        ''|auto|off|slim|std|full) ;;
        *)
            xmg_warn "未知地理数据档位: '$geo_want'，按 auto 处理"
            geo_want="auto"
            ;;
    esac

    # 模式必须先归一：任意字符串都会被当作 global 注入，但非法值会原样写进
    # state.env，之后每次 xmg proxy apply 都在校验阶段被判非法，只能手改文件恢复。
    case "$mode" in
        global|routing) ;;
        *)
            xmg_error "非法 WARP 模式: '$mode'（仅支持 global / routing）"
            return 2
            ;;
    esac

    if [ "$mode" = "routing" ]; then
        xmg_info "正在启用 Xray 原生 WireGuard (WARP) 出站【流媒体与 AI 智能分流模式】..."
    else
        xmg_info "正在启用 Xray 原生 WireGuard (WARP) 出站【全局清洁出站接管模式】..."
        xmg_info "核心目标: 彻底隐藏高污染本机 IP，节点代理流量全局默认走 WARP 出口"
    fi

    # routing 专属：确保地理数据就绪。
    # 下载或校验失败只降级为硬编码，不阻断启用 —— 分流失效比「完全没网」更可接受。
    local geo_effective=""
    if [ "$mode" = "routing" ]; then
        if [ -z "$geo_want" ]; then
            geo_want="$(_xmg_render_get_val WARP_GEO_MODE auto)"
        fi
        _xmg_warp_geo_prepare "$geo_want"
        geo_effective="$XMG_WARP_GEO_EFFECTIVE"
        if [ "$geo_effective" = "off" ]; then
            xmg_info "地理数据档位: off (使用内置硬编码域名，零 dat 加载开销)"
        else
            xmg_info "地理数据档位: $geo_effective (geosite 标签已合并进分流规则)"
        fi
    fi

    # 1. 确保账号凭据就绪 (含 client_id / reserved)
    if [ ! -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        _xmg_warp_register 0 || return 1
    fi

    # 确保宿主机网络栈变量已探测就绪，避免路由分流与端点选择误判为 IPv4
    _xmg_warp_ensure_net_detected

    # 2. 提取凭据并 stage 到 state 内存中
    local WARP_ACC_PRIVKEY="" WARP_ACC_PUBKEY="" WARP_ACC_IPV4="" WARP_ACC_IPV6="" WARP_ACC_ENDPOINT="" WARP_ACC_RESERVED=""
    _xmg_warp_get_account_vars || return 1

    if declare -F xmg_state_stage >/dev/null 2>&1; then
        xmg_state_stage WARP_ENABLED 1
        xmg_state_stage WARP_MODE "$mode"
        if [ "$mode" = "routing" ] && [ -n "$geo_want" ]; then
            xmg_state_stage WARP_GEO_MODE "$geo_want"
        fi
        xmg_state_stage WARP_ENDPOINT "$WARP_ACC_ENDPOINT"
        xmg_state_stage WARP_PRIVATE_KEY "$WARP_ACC_PRIVKEY"
        xmg_state_stage WARP_PUBLIC_KEY "$WARP_ACC_PUBKEY"
        xmg_state_stage WARP_IPV4 "$WARP_ACC_IPV4"
        xmg_state_stage WARP_IPV6 "$WARP_ACC_IPV6"
        xmg_state_stage WARP_RESERVED "$WARP_ACC_RESERVED"
    fi

    # 3. 导出出站片段供兼容使用
    xmg_warp_export_xray_outbound "$XMG_WARP_XRAY_OUTBOUND" || return 1

    # 4. warp.env 的写入推迟到配置注入成功之后
    #    提前写会让 xmg warp status（只读 warp.env）在注入失败时报「已启用」，
    #    而配置文件里根本没有 warp-out

    # 5. 定位当前生效的 Xray 主配置
    local xray_cfg=""
    xray_cfg="$(_xmg_warp_find_xray_config)"
    xmg_info "定位到生效的 Xray 主配置文件: $xray_cfg"
    # 把实际生效路径交给 xray.sh 的硬重启：否则 unit 自愈会按默认路径回写，
    # 服务被拉起后读的是另一份配置，表现为「改了却没生效，必须手工重启」
    [ -n "$xray_cfg" ] && export XMG_XRAY_CONFIG="$xray_cfg"

    if [ -f "$xray_cfg" ]; then
        # ===== 增量无损合成: 100% 保留现有所有 inbounds/节点/证书/路由，仅注入/置顶 warp-out =====
        local warp_json=""
        warp_json="$(cat "$XMG_WARP_XRAY_OUTBOUND" 2>/dev/null || true)"
        if [ -z "$warp_json" ]; then
            xmg_error "未找到 WARP 出站配置片段: $XMG_WARP_XRAY_OUTBOUND"
            return 1
        fi

        local bak=""
        bak="$(_xmg_warp_backup_config "$xray_cfg")"
        [ -n "$bak" ] && xmg_info "已安全备份当前原始 Xray 配置至: $bak"

        local tmp_cfg="${xray_cfg}.tmp.$$.json"
        local merged_ok=0

        local ssh_p=22
        if declare -F xmg_ssh_get_port >/dev/null 2>&1; then
            ssh_p="$(xmg_ssh_get_port 2>/dev/null || echo 22)"
        fi
        [[ "$ssh_p" =~ ^[0-9]+$ ]] && [ "$ssh_p" -gt 0 ] && [ "$ssh_p" -le 65535 ] || ssh_p=22

        if [ "${XMG_WARP_NO_JQ:-0}" != "1" ] && command -v jq >/dev/null 2>&1; then
            local jq_file="${xray_cfg}.tmp.$$.jq"
            if [ "$mode" = "routing" ]; then
                local _wtun="" _wfb=0 _wcond="[]" v6_fallback_rule=""
                _wtun="$(_xmg_warp_tunnel_family "$WARP_ACC_IPV4" "$WARP_ACC_IPV6")"
                if _xmg_warp_need_ip_match "$_wtun" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}"; then
                    _wfb=1
                fi
                # 只有「隧道单栈 + 宿主有另一族」才给域名规则挂 ip 条件。
                # 双栈隧道没有「承载族」概念，硬拼会得到空串，内核直接报
                # illegal ip rule / unsupported address family，整份配置起不来。
                if _xmg_warp_family_fallback "$_wtun" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}"; then
                    local _wc=""
                    _wc="$(_xmg_warp_carrier_cidr "$_wtun" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}")"
                    if [ -n "$_wc" ]; then
                        _wcond="[\"$_wc\"]"
                    fi
                fi
                # 宿主缺失、隧道能承载的那一族全量走 WARP（纯 v4 宿主 + 双栈隧道 → ::/0）
                local _wonly=""
                _wonly="$(_xmg_warp_tunnel_only_cidr "$_wtun" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}")"
                if [ -n "$_wonly" ]; then
                    # 全量网段前必须先放行私有/保留段，否则回环与内网目标会被吞进隧道
                    v6_fallback_rule="$(printf ', { "type": "field", "outboundTag": "direct", "ip": %s }, { "type": "field", "outboundTag": "warp-out", "ip": [ "%s" ] }' "$(_xmg_warp_private_cidrs_json)" "$_wonly")"
                fi
                cat > "$jq_file" << EOF_ROUTING_JQ
(.outbounds = (
  [ (.outbounds // [])[] | select(.tag != "warp-out") |
    if .protocol == "freedom" then
      (if .settings and .settings.domainStrategy then
         .streamSettings = (.streamSettings // {}) |
         .streamSettings.sockopt = (.streamSettings.sockopt // {}) |
         .streamSettings.sockopt.domainStrategy = (.streamSettings.sockopt.domainStrategy // .settings.domainStrategy) |
         del(.settings.domainStrategy)
       else . end) |
      .settings = (.settings // {}) |
      .settings.finalRules = [
        {
          "action": "allow",
          "network": "tcp",
          "port": "$ssh_p"
        },
        {
          "action": "allow"
        }
      ]
    else . end
  ] + [ $warp_json ]
)) |
(.routing = (.routing // { "domainStrategy": "AsIs", "rules": [] })) |
(.routing.domainStrategy = (if \$warp_fb then "IPIfNonMatch" else (.routing.domainStrategy // "AsIs") end)) |
(.routing.rules = (
  [ (.routing.rules // [])[] |
    select(
      (.outboundTag // "") != "warp-out"
      and ((.port // "") | tostring) != "$ssh_p"
      and ((((.outboundTag // "") == "direct") and (((.ip // []) | index("10.0.0.0/8")) != null) and (((.ip // []) | index("fc00::/7")) != null)) | not)
    )
  ] + [
    ({ "type": "field", "outboundTag": "warp-out", "domain": \$domains }
     + (if (\$warp_ip_cond | length) > 0 then { "ip": \$warp_ip_cond } else {} end))$v6_fallback_rule
  ]
))
EOF_ROUTING_JQ
            else
                cat > "$jq_file" << EOF_GLOBAL_JQ
(.outbounds = (
  [ $warp_json ] + [ (.outbounds // [])[] | select(.tag != "warp-out") |
    if .protocol == "freedom" then
      (if .settings and .settings.domainStrategy then
         .streamSettings = (.streamSettings // {}) |
         .streamSettings.sockopt = (.streamSettings.sockopt // {}) |
         .streamSettings.sockopt.domainStrategy = (.streamSettings.sockopt.domainStrategy // .settings.domainStrategy) |
         del(.settings.domainStrategy)
       else . end) |
      .settings = (.settings // {}) |
      .settings.finalRules = [
        {
          "action": "allow",
          "network": "tcp",
          "port": "$ssh_p"
        },
        {
          "action": "allow"
        }
      ]
    else . end
  ]
)) |
(.routing = (.routing // {})) |
(if (.routing.rules // null) != null then
   .routing.rules = (
     [ (.routing.rules // [])[] |
       select(
         (.outboundTag // "") != "warp-out"
         and ((.port // "") | tostring) != "$ssh_p"
         and ((((.outboundTag // "") == "direct") and (((.ip // []) | index("10.0.0.0/8")) != null) and (((.ip // []) | index("fc00::/7")) != null)) | not)
       ) ]
   )
 else . end) |
(if ((.routing.rules // []) | length) == 0 then del(.routing) else . end)
EOF_GLOBAL_JQ
            fi
            # 分流域名清单由 render.sh 统一生成（硬编码 + geosite 标签），
            # jq 只负责把数组塞进配置，不再自己持有域名列表。
            local domains_json="[]"
            local _wfb_json="false"
            if [ "$mode" = "routing" ]; then
                domains_json="$(xmg_warp_routing_domains_json "${geo_effective:-off}")"
            fi
            if [ "${_wfb:-0}" -eq 1 ]; then
                _wfb_json="true"
            fi
            if jq --argjson domains "$domains_json" \
                  --argjson warp_fb "$_wfb_json" \
                  --argjson warp_ip_cond "${_wcond:-[]}" \
                  -f "$jq_file" < "$xray_cfg" > "$tmp_cfg" 2>/dev/null; then
                merged_ok=1
            else
                rm -f "$jq_file" "$tmp_cfg" 2>/dev/null || true
            fi
        else
            # 无 jq：XMG 托管配置交给纯 Bash 渲染器重建，外部配置直接报错
            local _rrc=0
            _xmg_warp_render_managed_config "$xray_cfg" "$tmp_cfg" || _rrc=$?
            if [ "$_rrc" -eq 0 ]; then
                merged_ok=1
            else
                rm -f "$tmp_cfg" 2>/dev/null || true
                if [ "$_rrc" -eq 2 ]; then
                    xmg_error "当前配置不是 XMG 托管配置，WARP 无损注入需要 jq；请安装 jq 后重试"
                else
                    xmg_error "渲染 XMG 托管配置失败，取消应用"
                fi
                return 1
            fi
        fi

        if [ "$merged_ok" -eq 1 ]; then
            local xray_bin=""
            if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
                xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"
            elif command -v xray >/dev/null 2>&1; then
                xray_bin="$(command -v xray)"
            elif [ -x /usr/local/bin/xray ]; then
                xray_bin="/usr/local/bin/xray"
            fi

            # 单栈主机 + WARP 全局接管：把 DNS/出站策略从 UseIPv6 放开为 UseIP
            _xmg_warp_relax_stack_strategy "$tmp_cfg" "$mode" "$WARP_ACC_IPV4"

            if [ -n "$xray_bin" ] && [ -x "$xray_bin" ] && [ "${XMG_TEST_MODE:-0}" != "1" ]; then
                local test_out=""
                if ! test_out="$("$xray_bin" run -test -format json -c "$tmp_cfg" 2>&1)"; then
                    # geosite 标签名在不同 dat 版本间有差异，且内核在配置解析期就会失败。
                    # 整块回滚会让用户误判「WARP 不可用」，所以先自动回退硬编码再校验一次。
                    if [ "$mode" = "routing" ] && [ "${geo_effective:-off}" != "off" ]; then
                        xmg_warn "含 geosite 规则的配置未通过内核校验，自动回退硬编码域名重试..."
                        geo_effective="off"
                        local fallback_ok=0
                        if [ -f "${jq_file:-/nonexistent}" ]; then
                            domains_json="$(xmg_warp_routing_domains_json off)"
                            jq --argjson domains "$domains_json" \
                               --argjson warp_fb "$_wfb_json" \
                               --argjson warp_ip_cond "${_wcond:-[]}" \
                                            -f "$jq_file" < "$xray_cfg" > "$tmp_cfg" 2>/dev/null && fallback_ok=1
                        else
                            # 纯 Bash 渲染路径：用环境开关强制关掉 geosite 重渲染托管配置
                            XMG_WARP_GEO_DISABLE=1 _xmg_warp_render_managed_config "$xray_cfg" "$tmp_cfg" && fallback_ok=1
                        fi
                        if [ "$fallback_ok" -eq 1 ]; then
                            _xmg_warp_relax_stack_strategy "$tmp_cfg" "$mode" "$WARP_ACC_IPV4"
                            if ! test_out="$("$xray_bin" run -test -format json -c "$tmp_cfg" 2>&1)"; then
                                xmg_error "回退后仍校验失败，取消应用，详细错误信息如下:"
                                printf '%s\n' "$test_out" >&2
                                rm -f "$tmp_cfg" 2>/dev/null || true
                                [ -n "${jq_file:-}" ] && rm -f "$jq_file" 2>/dev/null
                                return 1
                            fi
                            xmg_info "已回退为硬编码分流规则，并通过内核校验"
                            # 状态必须同步降级：否则下一次 proxy apply 走 render.sh 重渲染时，
                            # 会按 state 里的原档位把 geosite 加回来，再撞一次同样的校验失败，
                            # 而用户看到的是「改个端口就失败」，根本联想不到是地理数据。
                            geo_want="off"
                            geo_effective="off"
                            if declare -F xmg_state_stage >/dev/null 2>&1; then
                                xmg_state_stage WARP_GEO_MODE off
                            fi
                        else
                            xmg_error "回退硬编码规则失败，取消应用"
                            rm -f "$tmp_cfg" 2>/dev/null || true
                            [ -n "${jq_file:-}" ] && rm -f "$jq_file" 2>/dev/null
                            return 1
                        fi
                    else
                        xmg_error "Xray 内核校验新配置失败，取消应用，详细错误信息如下:"
                        printf '%s\n' "$test_out" >&2
                        rm -f "$tmp_cfg" 2>/dev/null || true
                        [ -n "${jq_file:-}" ] && rm -f "$jq_file" 2>/dev/null
                        return 1
                    fi
                fi
                [ -n "${jq_file:-}" ] && rm -f "$jq_file" 2>/dev/null
            fi
            [ -n "${jq_file:-}" ] && rm -f "$jq_file" 2>/dev/null || true

            mv -f "$tmp_cfg" "$xray_cfg"
            local alt_cfg="${XMG_HOME:-/opt/xmg}/xray/config.json"
            if [ "$alt_cfg" != "$xray_cfg" ] && [ -d "$(dirname "$alt_cfg")" ]; then
                cp -f "$xray_cfg" "$alt_cfg" 2>/dev/null || true
            fi

            # 机型参数可能随版本升级变化（例如 GOMEMLIMIT 分档口径调整），
            # 借这次重启顺手刷新 drop-in / init 脚本，否则用户升级后参数仍停在旧值。
            # xray.sh 是懒加载的，这里必须先显式拉起来，否则函数不存在会静默跳过。
            _warp_load_xray_lib 2>/dev/null || true
            if declare -F xmg_xray_patch_systemd_unit >/dev/null 2>&1; then
                xmg_xray_patch_systemd_unit "$xray_cfg" >/dev/null 2>&1 || true
            elif declare -F xmg_core_patch_systemd_unit >/dev/null 2>&1; then
                xmg_core_patch_systemd_unit "$xray_cfg" >/dev/null 2>&1 || true
            fi

            if [ "$mode" = "routing" ]; then
                xmg_info "Xray 配置增量注入完成: 原有所有入站节点/证书/端口 100% 毫发无损，已追加 warp-out 流媒体/AI 智能分流"
            else
                xmg_info "Xray 配置增量注入完成: 原有所有入站节点/证书/端口 100% 毫发无损，warp-out 已设为默认清洁出站接管"
            fi
        else
            rm -f "$tmp_cfg" 2>/dev/null || true
            xmg_error "增量注入 WARP 出站失败，取消应用"
            return 1
        fi

        # 仅同步状态草稿记录，绝对不调用全量重新渲染覆写的 xmg_state_commit
        # 不再用 "-f $XMG_STATE_FILE" 做守卫：首装即启 WARP 时 state.env 还不存在，
        # 跳过落盘会让下一次 xmg proxy apply 按默认值把 warp-out 静默撤掉。
        # commit_draft 自身会创建目录与文件。
        if declare -F xmg_state_commit_draft >/dev/null 2>&1; then
            xmg_state_commit_draft >/dev/null 2>&1 || true
        fi
    else
        # 仅当宿主机完全不存在任何 Xray 配置文件时，才通过模板生成初始骨架配置
        if declare -F xmg_state_commit >/dev/null 2>&1; then
            local _tc_set=0
            if [ "${XMG_TEST_MODE:-0}" = "1" ] && [ -z "${XMG_XRAY_CONFIG_TESTCMD:-}" ]; then
                export XMG_XRAY_CONFIG_TESTCMD="true"
                export XMG_XRAY_RELOAD_TESTCMD="true"
                _tc_set=1
            fi
            if ! xmg_state_commit; then
                [ "$_tc_set" -eq 1 ] && unset XMG_XRAY_CONFIG_TESTCMD XMG_XRAY_RELOAD_TESTCMD
                xmg_error "WARP 出站初始配置渲染失败"
                return 1
            fi
            [ "$_tc_set" -eq 1 ] && unset XMG_XRAY_CONFIG_TESTCMD XMG_XRAY_RELOAD_TESTCMD
        fi
    fi

    # 4.5 配置已成功落盘，此刻才把启用状态写进 warp.env（兼容副本，纯 Bash 零 sed）
    if [ "$mode" = "routing" ]; then
        _xmg_warp_env_set "WARP_ENABLED=1" "WARP_MODE=$mode" "WARP_GEO_MODE=${geo_want:-auto}"
    else
        _xmg_warp_env_set "WARP_ENABLED=1" "WARP_MODE=$mode"
    fi

    # 6. 清理任何可能存在的第三方 wireproxy 残留服务
    if [ "${XMG_TEST_MODE:-0}" != "1" ] && _warp_can_manage_service; then
        xmg_svc_stop xmg-warp >/dev/null 2>&1 || true
        xmg_svc_disable xmg-warp >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/xmg-warp.service 2>/dev/null || true
        rm -f /etc/init.d/xmg-warp 2>/dev/null || true
        rm -f "$XMG_WARP_DIR/wireproxy.conf" "$XMG_WARP_DIR/bin/wireproxy" 2>/dev/null || true
        xmg_svc_reload_manager
    fi

    # 7. 无论服务当前是否在运行，都要走一次硬重启（停→启→验证 active）
    #    WARP 出站只在进程启动时建立，配置变了必须换进程；服务已停时也要拉起
    #    若外层升级/批量流水线显式设置 XMG_PROXY_NO_RELOAD=1，则跳过重启交由外层统一单次重启
    if [ "${XMG_TEST_MODE:-0}" != "1" ] && [ "${XMG_PROXY_NO_RELOAD:-0}" != "1" ]; then
        local s_name="${XMG_XRAY_SERVICE:-xray}"
        if ! _warp_can_manage_service; then
            # 无服务管理器不能回滚：配置本身是好的，只是本环境无法托管进程
            _warp_warn_manual_restart "生效"
        elif ! _warp_restart_xray 2>/dev/null; then
            xmg_error "重启 $s_name 服务失败，正在自动回滚 WARP 配置..."
            if [ -n "${bak:-}" ] && [ -f "$bak" ]; then
                cp -f "$bak" "$xray_cfg" 2>/dev/null || true
                if [ -n "${alt_cfg:-}" ] && [ "$alt_cfg" != "$xray_cfg" ]; then
                    cp -f "$bak" "$alt_cfg" 2>/dev/null || true
                fi
                _warp_restart_xray 2>/dev/null || true
            fi
            # 状态/env 必须与配置一起回退：否则 state 声称已启用，下一次 proxy apply
            # 会按 state 把 warp-out 重新渲染回来，形成"回滚了但又生效"的鬼状态。
            _xmg_warp_env_set "WARP_ENABLED=0"
            if declare -F xmg_state_stage >/dev/null 2>&1; then
                xmg_state_stage WARP_ENABLED 0
                if declare -F xmg_state_commit_draft >/dev/null 2>&1; then
                    xmg_state_commit_draft >/dev/null 2>&1 || true
                fi
            fi
            return 1
        else
            xmg_info "已成功重启 $s_name 服务并确认运行健康 (active)"
        fi
    fi

    xmg_info "Xray WARP 出站已成功启用 (出站标签: warp-out, 模式: $mode)"
    xmg_info "配置片段位置: $XMG_WARP_XRAY_OUTBOUND"
    xmg_info "宿主机 100% 零侵入、零网卡接管、零系统路由改动，SSH 物理级绝对防断网！"
    return 0
}

# WARP 变更后重启 Xray
# 优先用 xray.sh 的硬重启（含注册文件自愈）；拿不到时退回服务抽象层
_warp_restart_xray() {
    if _warp_load_xray_lib; then
        xmg_xray_restart_hard && return 0
        return 1
    fi
    xmg_svc_restart_verified "${XMG_XRAY_SERVICE:-xray}" 8
}

# 当前环境能否托管服务生命周期（容器 / 无 init 的手工部署会返回假）
_warp_can_manage_service() {
    xmg_svc_supported 2>/dev/null || xmg_init_use_systemd_units 2>/dev/null
}

# 配置已落盘但无法自动重启时必须明确告知
#   WireGuard 出站只在进程启动时建立，不换进程 = 配置不生效。
#   静默跳过会让用户以为「启用成功」却始终没网，只能自己猜到手要重启核心。
_warp_warn_manual_restart() {
    local action="${1:-生效}"
    local svc="${XMG_XRAY_SERVICE:-xray}"
    xmg_warn "配置已写入，但当前环境未检测到可用的服务管理器，无法自动重启 ${svc} 使配置${action}。"
    xmg_warn "请手动执行以下任一命令完成${action}："
    xmg_warn "  xmg xray restart"
    xmg_warn "  systemctl restart ${svc}      # systemd"
    xmg_warn "  rc-service ${svc} restart     # OpenRC"
    return 0
}

# WARP 让单栈机获得双栈出口后，DNS / 出站策略要跟着放开
# 纯 IPv6 主机渲染时被固定成 UseIPv6（因为宿主机没有 IPv4），
# 隧道带来 172.16.x.x 之后仍只查 AAAA，所有 IPv4-only 站点依旧不可达
_xmg_warp_relax_stack_strategy() {
    local cfg="$1"
    local mode="${2:-global}"
    local v4="${3:-}"

    [ -f "$cfg" ] || return 0
    # 只对纯 IPv6 主机处理；IPv4 主机本来就是 UseIP
    xmg_warp_is_ipv6_only || return 0
    [ -n "$v4" ] || return 0

    if command -v jq >/dev/null 2>&1; then
        local tmp="${cfg}.stack.$$"
        # 分流模式下 direct 出站仍走宿主机原生 IPv6（保持 UseIPv6），
        # 但 DNS queryStrategy 必须放开为 UseIP，否则 IPIfNonMatch 查不到 A 记录导致 IPv4 规则永不命中。
        # 同时确保纯 IPv6 机的直连 DoH 服务器为 IPv6（https+local 不走路由，纯 IPv6 连不上 1.1.1.1）。
        if jq --arg mode "$mode" '
            (if ($mode == "global" or ((.routing // {}).domainStrategy // "") == "IPIfNonMatch")
                and ((.dns // {}).queryStrategy == "UseIPv6")
             then .dns.queryStrategy = "UseIP"
             else . end)
            | (if (.dns // {}).servers then
                 if ([.dns.servers[] | select(tostring | test("2606:4700|2001:4860"))] | length) == 0
                    and ([.dns.servers[] | select(tostring | test("^https[+]local://(1[.]1[.]1[.]1|8[.]8[.]8[.]8)"))] | length) > 0
                 then .dns.servers = ["https+local://[2606:4700:4700::1111]/dns-query", "https+local://[2001:4860:4860::8888]/dns-query", "localhost"]
                 else . end
               else . end)
            | (if $mode == "global" then
                 (.outbounds // []) |= map(
                   if (((.streamSettings // {}).sockopt // {}).domainStrategy // "") == "UseIPv6"
                   then .streamSettings.sockopt.domainStrategy = "UseIP"
                   else . end)
               else . end)
        ' "$cfg" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
            chmod --reference="$cfg" "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$cfg"
            if [ "$mode" = "global" ]; then
                xmg_info "已把 DNS/出站策略放开为 UseIP：WARP 隧道为纯 IPv6 主机提供了 IPv4 出口"
            else
                xmg_info "已把 DNS 查询策略放开为 UseIP（分流模式需解析 A 记录以匹配 WARP IPv4 规则）"
            fi
            return 0
        fi
        rm -f "$tmp" 2>/dev/null || true
    fi

    # 无 jq 纯 Bash 原子兜底（兼容紧凑/宽松 JSON 空白，零 sed -i）
    if [ "$mode" = "global" ]; then
        _xmg_warp_json_swap_strategy "$cfg" "UseIPv6" "UseIP" 1
        xmg_info "已把 DNS/出站策略放开为 UseIP（WARP 隧道提供 IPv4 出口）"
    else
        _xmg_warp_json_swap_strategy "$cfg" "UseIPv6" "UseIP" 0
        xmg_info "已把 DNS 查询策略放开为 UseIP（分流模式）"
    fi
    return 0
}

# 纯 Bash 零 sed -i 原子替换 queryStrategy / domainStrategy（兼容任意空白符并保留权限）
_xmg_warp_json_swap_strategy() {
    local cfg="$1"
    local from_val="$2"
    local to_val="$3"
    local swap_domain="${4:-1}"

    [ -f "$cfg" ] || return 0
    local content=""
    content="$(< "$cfg")" 2>/dev/null || return 0

    local changed=0 re_q="" re_d=""
    re_q='^(.*)"queryStrategy"[[:space:]]*:[[:space:]]*"'"$from_val"'"(.*)$'
    while [[ "$content" =~ $re_q ]]; do
        content="${BASH_REMATCH[1]}\"queryStrategy\": \"${to_val}\"${BASH_REMATCH[2]}"
        changed=1
    done

    if [ "$swap_domain" = "1" ]; then
        re_d='^(.*)"domainStrategy"[[:space:]]*:[[:space:]]*"'"$from_val"'"(.*)$'
        while [[ "$content" =~ $re_d ]]; do
            content="${BASH_REMATCH[1]}\"domainStrategy\": \"${to_val}\"${BASH_REMATCH[2]}"
            changed=1
        done
    fi

    [ "$changed" = "1" ] || return 0
    local tmp="${cfg}.stack.$$"
    if printf '%s
' "$content" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        chmod --reference="$cfg" "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$cfg"
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
}

# 停用 WARP 后反向收紧：纯 IPv6 主机没有 IPv4 直连，必须回到 UseIPv6
_xmg_warp_restore_stack_strategy() {
    local cfg="$1"

    [ -f "$cfg" ] || return 0
    xmg_warp_is_ipv6_only || return 0

    if command -v jq >/dev/null 2>&1; then
        local tmp="${cfg}.stack.$$"
        if jq '
            (if (.dns // {}).queryStrategy == "UseIP" then .dns.queryStrategy = "UseIPv6" else . end)
            | (.outbounds // []) |= map(
                if (((.streamSettings // {}).sockopt // {}).domainStrategy // "") == "UseIP"
                then .streamSettings.sockopt.domainStrategy = "UseIPv6"
                else . end)
        ' "$cfg" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
            chmod --reference="$cfg" "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$cfg"
            xmg_info "已恢复 DNS/出站策略为 UseIPv6（宿主机无 IPv4 直连）"
            return 0
        fi
        rm -f "$tmp" 2>/dev/null || true
    fi

    _xmg_warp_json_swap_strategy "$cfg" "UseIP" "UseIPv6" 1
    xmg_info "已恢复 DNS/出站策略为 UseIPv6（宿主机无 IPv4 直连）"
    return 0
}

# ===== 停用 Xray 原生 WireGuard 出站 =====

xmg_warp_disable() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "正在停用 Xray 原生 WireGuard (WARP) 出站..."

    # warp.env 的写入放到配置真正移除成功之后：
    # 提前写 0 会让下面的失败分支（jq 解析失败、渲染失败、内核校验失败）
    # 留下「warp.env=0 而配置里 warp-out 还在」的反向漂移 —— status 只读
    # warp.env，会报「已停用」，而流量实际仍全部走 WARP。

    if declare -F xmg_state_stage >/dev/null 2>&1; then
        xmg_state_stage WARP_ENABLED 0
    fi

    local xray_cfg=""
    xray_cfg="$(_xmg_warp_find_xray_config)"
    xmg_info "定位到生效的 Xray 主配置文件: $xray_cfg"
    # 把实际生效路径交给 xray.sh 的硬重启：否则 unit 自愈会按默认路径回写，
    # 服务被拉起后读的是另一份配置，表现为「改了却没生效，必须手工重启」
    [ -n "$xray_cfg" ] && export XMG_XRAY_CONFIG="$xray_cfg"

    if [ -f "$xray_cfg" ]; then
        local bak=""
        bak="$(_xmg_warp_backup_config "$xray_cfg")"
        [ -n "$bak" ] && xmg_info "已安全备份当前原始 Xray 配置至: $bak"

        local tmp_cfg="${xray_cfg}.tmp.$$.json"
        local removed_ok=0

        if [ "${XMG_WARP_NO_JQ:-0}" != "1" ] && command -v jq >/dev/null 2>&1; then
            local jq_file="${xray_cfg}.tmp.$$.jq"
            cat > "$jq_file" << 'EOF_DISABLE_JQ'
(.outbounds = [ (.outbounds // [])[] | select(.tag != "warp-out") ]) |
(if (.routing and .routing.rules) then
   .routing.rules = [ .routing.rules[] | select(
     (.outboundTag // "") != "warp-out"
     and ((((.outboundTag // "") == "direct") and (((.ip // []) | index("10.0.0.0/8")) != null) and (((.ip // []) | index("fc00::/7")) != null)) | not)
   ) ]
   | (if ((.routing.rules // []) | length) == 0 then del(.routing) else . end)
 else . end)
EOF_DISABLE_JQ
            if jq -f "$jq_file" < "$xray_cfg" > "$tmp_cfg" 2>/dev/null; then
                rm -f "$jq_file" 2>/dev/null || true
                removed_ok=1
            else
                # 不能静默继续：往下走会写 state=0 并打印「已关闭」，
                # 而配置里的 warp-out 还在，用户以为已直连、实际仍全部走 WARP
                rm -f "$jq_file" "$tmp_cfg" 2>/dev/null || true
                xmg_error "解析 Xray 配置失败（文件可能已损坏或为空），已取消停用 WARP"
                xmg_warn "请先执行 xray run -test -c $xray_cfg 检查配置，再重试"
                return 1
            fi
        else
            # 无 jq：托管配置按状态重渲染（WARP_ENABLED=0 已 stage）；外部配置报错
            local _rrc=0
            _xmg_warp_render_managed_config "$xray_cfg" "$tmp_cfg" || _rrc=$?
            if [ "$_rrc" -eq 0 ]; then
                removed_ok=1
            else
                rm -f "$tmp_cfg" 2>/dev/null || true
                if [ "$_rrc" -eq 2 ]; then
                    xmg_error "当前配置不是 XMG 托管配置，移除 WARP 出站需要 jq；请安装 jq 后重试"
                else
                    xmg_error "渲染 XMG 托管配置失败，取消停用"
                fi
                return 1
            fi
        fi

        if [ "$removed_ok" -eq 1 ]; then
            local xray_bin=""
            if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
                xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"
            elif command -v xray >/dev/null 2>&1; then
                xray_bin="$(command -v xray)"
            elif [ -x /usr/local/bin/xray ]; then
                xray_bin="/usr/local/bin/xray"
            fi

            # 停用后纯 IPv6 主机失去隧道 IPv4，策略要收回 UseIPv6
            _xmg_warp_restore_stack_strategy "$tmp_cfg"

            if [ -n "$xray_bin" ] && [ -x "$xray_bin" ] && [ "${XMG_TEST_MODE:-0}" != "1" ]; then
                local test_out=""
                if ! test_out="$("$xray_bin" run -test -format json -c "$tmp_cfg" 2>&1)"; then
                    xmg_error "Xray 内核校验新配置失败，取消停用 WARP:"
                    printf '%s\n' "$test_out" >&2
                    rm -f "$tmp_cfg" 2>/dev/null || true
                    return 1
                fi
            fi

            mv -f "$tmp_cfg" "$xray_cfg"
            local alt_cfg="${XMG_HOME:-/opt/xmg}/xray/config.json"
            if [ "$alt_cfg" != "$xray_cfg" ] && [ -d "$(dirname "$alt_cfg")" ]; then
                cp -f "$xray_cfg" "$alt_cfg" 2>/dev/null || true
            fi
            xmg_info "已从 Xray 配置中无损移除 warp-out 出站与相关分流规则 (原有所有节点与配置毫发无损)"
        else
            rm -f "$tmp_cfg" 2>/dev/null || true
            xmg_error "移除 warp-out 未成功，已保留原有状态（不写 state，避免状态谎报）"
            return 1
        fi

        # 首装时 state.env 可能尚不存在；commit_draft 自身会建目录与文件，
        # 跳过落盘会让下一次 proxy apply 按默认值把 WARP 重新渲染回来
        if declare -F xmg_state_commit_draft >/dev/null 2>&1; then
            xmg_state_commit_draft >/dev/null 2>&1 || true
        fi

        if [ "${XMG_TEST_MODE:-0}" != "1" ] && [ "${XMG_PROXY_NO_RELOAD:-0}" != "1" ]; then
            local s_name="${XMG_XRAY_SERVICE:-xray}"
            if ! _warp_can_manage_service; then
                _warp_warn_manual_restart "关停"
            elif _warp_restart_xray >/dev/null 2>&1; then
                xmg_info "已成功重启 $s_name 服务应用变更"
            else
                xmg_warn "$s_name 重启失败，请执行 xmg xray restart 确认状态"
            fi
        fi
    fi
    # 走到这里说明配置已确实移除（或本来就没有），此刻才写停用标记
    _xmg_warp_env_set "WARP_ENABLED=0"

    xmg_info "Xray WARP 出站已关闭 (warp-out 已停用，已恢复直连出站)"
    return 0
}

# ===== 全自动配置 (方案 A) =====

xmg_warp_auto_apply() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "=================================================================="
    xmg_info "正在执行 Xray 原生 WireGuard (WARP) 出站全自动极速配置..."
    xmg_info "核心目标: 彻底隐藏高污染本机 IP，节点代理流量全局走 WARP 清洁出口"
    xmg_info "架构设计: 宿主机 100% 零侵入、零网卡、零路由修改、零 DNS 篡改"
    xmg_info "防失联保证: SSH 物理级绝对不可能失联！"
    xmg_info "=================================================================="

    # 1. 物理机房与原生地理嗅探
    xmg_warp_detect_native_geo
    xmg_info "原生归属地感知: $(_xmg_warp_country_name "$XMG_WARP_NATIVE_LOC") [直连机房: $XMG_WARP_NATIVE_COLO]"

    # 2. 注册纯净凭据 (若已有且纯净则复用)
    _xmg_warp_register 0 || return 1

    # 3. 本地机房低延迟 Anycast 端点优选并写入 account.json
    _XMG_WARP_IN_AUTO_APPLY=1 xmg_warp_optimize_endpoint || return 1

    # 4. 导出出站并启用 (默认 global 全局清洁模式)
    xmg_warp_enable "global" || return 1

    xmg_info "=================================================================="
    xmg_info "WARP 原生 Xray 出站配置就绪！"
    xmg_info "提示: 流量已在 Xray 进程内由 WireGuard 出站接管，宿主机网络 0 变动！"
    xmg_info "=================================================================="
    return 0
}

# ===== 卸载与配置清理 =====

xmg_warp_uninstall() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "正在清理 WARP 配置与凭据..."

    # 1. 关闭 Xray 出站
    xmg_warp_disable >/dev/null 2>&1 || true

    # 2. 清理 WARP 目录
    if [ -d "$XMG_WARP_DIR" ]; then
        rm -rf "$XMG_WARP_DIR"
        xmg_info "已删除 WARP 数据目录: $XMG_WARP_DIR"
    fi

    # 3. 清理历史遗留 wireproxy 与 wg-quick 服务
    if _warp_can_manage_service; then
        xmg_svc_stop xmg-warp >/dev/null 2>&1 || true
        xmg_svc_disable xmg-warp >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/xmg-warp.service 2>/dev/null || true
        rm -f /etc/init.d/xmg-warp 2>/dev/null || true
        if xmg_init_is_systemd; then
            systemctl stop wg-quick@warp >/dev/null 2>&1 || true
            systemctl disable wg-quick@warp >/dev/null 2>&1 || true
        else
            xmg_svc_stop wg-quick@warp >/dev/null 2>&1 || true
            xmg_svc_disable wg-quick@warp >/dev/null 2>&1 || true
        fi
        rm -f /etc/wireguard/warp.conf 2>/dev/null || true
        xmg_svc_reload_manager
    fi

    if [ -n "${XMG_WARP_CONF:-}" ] && [ -f "$XMG_WARP_CONF" ]; then
        rm -f "$XMG_WARP_CONF"
    fi

    xmg_info "WARP 配置与凭据已彻底清理完毕！宿主机网络纯净如初。"
    return 0
}

# ===== 运行状态与出口诊断 =====

xmg_warp_status() {
    _xmg_warp_ensure_net_detected
    echo "==================== WARP 运行状态与出口诊断 ===================="
    printf "架构模式        : Xray 原生 WireGuard 进程内出站 (方案 A)\n"
    printf "防失联保护      : 宿主机 100%% 零网卡/零路由接管，SSH 物理级绝对不失联\n"

    local is_enabled=0
    local cur_mode="global"
    if [ -f "$XMG_WARP_ENV_FILE" ]; then
        grep -q '^WARP_ENABLED=1' "$XMG_WARP_ENV_FILE" 2>/dev/null && is_enabled=1
        cur_mode="$(grep -E '^WARP_MODE=' "$XMG_WARP_ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "global")"
    elif [ -f "$XMG_WARP_XRAY_OUTBOUND" ]; then
        is_enabled=1
    fi

    printf "服务状态        : "
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        echo "已启用 (Xray 原生 WireGuard 出站就绪)"
    elif [ "$is_enabled" -eq 1 ]; then
        echo "已启用 (Xray 原生 WireGuard 出站就绪, 模式: ${cur_mode:-global})"
    else
        echo "未启用"
    fi

    local _st_acc_raw=""
    if [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        _st_acc_raw="$(< "$XMG_WARP_ACCOUNT_FILE")" 2>/dev/null || true
        local cur_v4="" cur_ep_v4="" cur_ep_v6="" cur_res="未记录"
        cur_v4="$(_xmg_warp_json_val "$_st_acc_raw" "address_v4")"
        cur_ep_v4="$(_xmg_warp_json_val "$_st_acc_raw" "endpoint_v4")"
        cur_ep_v6="$(_xmg_warp_json_val "$_st_acc_raw" "endpoint_v6")"
        if [[ "$_st_acc_raw" == *'"reserved"'* ]]; then
            local _tmp_r="${_st_acc_raw#*\"reserved\"}"
            _tmp_r="${_tmp_r#*\[}"
            _tmp_r="${_tmp_r%%\]*}"
            _tmp_r="${_tmp_r//[$'\r\n']/}"; cur_res="[${_tmp_r// /}]"
        fi
        printf "虚拟内网 IPv4   : %s\n" "${cur_v4:-未分配}"
        printf "握手保留字节    : %s\n" "$cur_res"
        if xmg_warp_is_ipv6_only; then
            printf "当前对端端点    : %s\n" "${cur_ep_v6:-$XMG_WARP_ENDPOINT_V6}"
        else
            printf "当前对端端点    : %s\n" "${cur_ep_v4:-$XMG_WARP_ENDPOINT_V4}"
        fi
    fi

    local trace4="" trace6=""
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        trace4="${XMG_MOCK_WARP_TRACE4:-ip=104.28.192.1\nloc=US\ncolo=SFO\nwarp=on}"
        trace6="${XMG_MOCK_WARP_TRACE6:-ip=2606:4700::1\nloc=US\ncolo=SFO\nwarp=off}"
    else
        trace4="$(curl -4sSL --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || echo 'warp=off')"
        trace6="$(curl -6sSL --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || echo 'warp=off')"
    fi

    local ip4="" loc4="" colo4="" _tl="" _t4_norm="${trace4//\\n/$'\n'}"
    while IFS= read -r _tl || [ -n "$_tl" ]; do
        _tl="${_tl%$'\r'}"
        case "$_tl" in
            ip=*)   [ -n "$ip4" ]   || ip4="${_tl#ip=}" ;;
            loc=*)  [ -n "$loc4" ]  || loc4="${_tl#loc=}" ;;
            colo=*) [ -n "$colo4" ] || colo4="${_tl#colo=}" ;;
        esac
    done <<< "$_t4_norm"

    local ip6="" loc6="" colo6="" _t6_norm="${trace6//\\n/$'\n'}"
    while IFS= read -r _tl || [ -n "$_tl" ]; do
        _tl="${_tl%$'\r'}"
        case "$_tl" in
            ip=*)   [ -n "$ip6" ]   || ip6="${_tl#ip=}" ;;
            loc=*)  [ -n "$loc6" ]  || loc6="${_tl#loc=}" ;;
            colo=*) [ -n "$colo6" ] || colo6="${_tl#colo=}" ;;
        esac
    done <<< "$_t6_norm"

    echo "-------------------- 宿主机直连出口 (SSH 与直连) --------------------"
    printf "说明            : 宿主机 0 网卡改动，此处的 IP 为宿主机物理真实 IP (保证 SSH 稳定)\n"
    printf "IPv4 物理出口   : %s (%s, 机房: %s)\n" "${ip4:-无 IPv4}" "${loc4:-未知}" "${colo4:-未知}"
    printf "IPv6 物理出口   : %s (%s, 机房: %s)\n" "${ip6:-无 IPv6}" "${loc6:-未知}" "${colo6:-未知}"

    xmg_warp_detect_native_geo

    local egress_loc="$loc4"
    local egress_colo="$colo4"
    [ -z "$egress_loc" ] && egress_loc="$loc6"
    [ -z "$egress_colo" ] && egress_colo="$colo6"

    echo "-------------------- Xray 节点代理清洁出口诊断 --------------------"
    printf "接管模式        : %s\n" "$([ "$cur_mode" = "routing" ] && echo "流媒体/AI 智能分流" || echo "全局清洁接管 (默认出站走 WARP，隐藏高污染本机 IP)")"
    if [ "$cur_mode" = "routing" ]; then
        local geo_set="" geo_eff="" geo_note=""
        geo_set="$(grep -E '^WARP_GEO_MODE=' "$XMG_WARP_ENV_FILE" 2>/dev/null | cut -d= -f2 || true)"
        [ -n "$geo_set" ] || geo_set="auto"
        geo_eff="$(xmg_warp_geo_mode_resolve "$geo_set")"
        if xmg_warp_geo_available; then
            geo_note="$(xmg_warp_geo_dir)/geosite.dat $(( $(_xmg_warp_geo_size "$XMG_WARP_GEOSITE_FILE") / 1024 ))KB"
        else
            geo_note="未就绪 (已回退硬编码)"
        fi
        printf "地理数据档位  : %s (设置: %s, 内存约 %sMB)\n" \
            "$geo_eff" "$geo_set" "$(( $(xmg_detect_mem_total_kb 2>/dev/null || echo 0) / 1024 ))"
        printf "地理数据文件  : %s\n" "$geo_note"

        # 协议族覆盖：隧道承载不了的那一族是否已回退直连
        local _tv4="" _tv6="" _tfam="" _sfb=""
        _tv4="$(_xmg_warp_json_val "$_st_acc_raw" "address_v4")"
        _tv6="$(_xmg_warp_json_val "$_st_acc_raw" "address_v6")"
        _tfam="$(_xmg_warp_tunnel_family "$_tv4" "$_tv6")"
        local _sonly=""
        _sonly="$(_xmg_warp_tunnel_only_cidr "$_tfam" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}")"
        if [ -n "$_sonly" ]; then
            _sfb="已开启 (宿主机缺失的 $_sonly 全量走 WARP)"
        elif _xmg_warp_family_fallback "$_tfam" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}"; then
            _sfb="已开启 (隧道承载不了的一族回退宿主机直连)"
        elif [ "$_tfam" = "dual" ]; then
            _sfb="不需要 (隧道双栈，两族都走 WARP)"
        else
            _sfb="不可用 (宿主机与隧道都没有那一族，回退也无处可走)"
        fi
        printf "协议族覆盖    : %s\n" "$_sfb"
    fi
    if [ "${XMG_TEST_MODE:-0}" != "1" ] && [ "$is_enabled" -eq 1 ]; then
        local _px_url=""
        _px_url="$(_xmg_warp_local_socks_proxy_url 2>/dev/null || true)"
        if [ -n "$_px_url" ]; then
            local _px_trace=""
            _px_trace="$(curl -x "$_px_url" -sSL --connect-timeout 4 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
            if [ -n "$_px_trace" ]; then
                local _px_ip="" _px_loc="" _px_colo="" _px_warp="" _ptl=""
                while IFS= read -r _ptl || [ -n "$_ptl" ]; do
                    _ptl="${_ptl%$'\r'}"
                    case "$_ptl" in
                        ip=*)   [ -n "$_px_ip" ]   || _px_ip="${_ptl#ip=}" ;;
                        loc=*)  [ -n "$_px_loc" ]  || _px_loc="${_ptl#loc=}" ;;
                        colo=*) [ -n "$_px_colo" ] || _px_colo="${_ptl#colo=}" ;;
                        warp=*) [ -n "$_px_warp" ] || _px_warp="${_ptl#warp=}" ;;
                    esac
                done <<< "$_px_trace"
                printf "代理实测出口    : %s (%s, 机房: %s, warp=%s)\n" "${_px_ip:-未知}" "${_px_loc:-未知}" "${_px_colo:-未知}" "${_px_warp:-off}"
            else
                printf "代理实测出口    : 探测超时（请确认 Xray 运行状态与 WARP 握手）\n"
            fi
        fi
    fi

    printf "VPS 本地原生地区: %s | 机房 Colo: %s\n" "$(_xmg_warp_country_name "$XMG_WARP_NATIVE_LOC")" "$XMG_WARP_NATIVE_COLO"
    echo "=================================================================="
}

# ===== 地理数据管理 =====
# xmg warp geo [status|update|clean]
xmg_warp_geo_cmd() {
    local action="${1:-status}"
    local dir="" f="" want="" eff="" sz=0

    dir="$(xmg_warp_geo_dir)"
    f="${dir}/geosite.dat"
    XMG_WARP_GEOSITE_FILE="$f"
    export XMG_WARP_GEOSITE_FILE

    want="$(xmg_state_get WARP_GEO_MODE auto 2>/dev/null || true)"
    [ -n "$want" ] || want="auto"
    eff="$(xmg_warp_geo_mode_resolve "$want")"

    case "$action" in
        status)
            local mem_mb=0 cpu_pct=100
            mem_mb="$(( $(xmg_detect_mem_total_kb 2>/dev/null || echo 0) / 1024 ))"
            cpu_pct="$(_xmg_warp_cpu_pct 2>/dev/null || echo 100)"
            echo "==================== WARP 地理数据分流状态 ===================="
            printf "设置档位        : %s\n" "$want"
            printf "当前生效档位    : %s (内存分档 + CPU 降档后的结果)\n" "$eff"
            printf "内存 / 有效CPU  : %sMB / %s%%\n" "$mem_mb" "$cpu_pct"
            printf "数据文件        : %s\n" "$f"
            if xmg_warp_geo_available; then
                sz="$(_xmg_warp_geo_size "$f")"
                printf "文件状态        : 可用 (%s KB)\n" "$(( sz / 1024 ))"
            else
                printf "文件状态        : 缺失或不可用 (分流只使用硬编码域名)\n"
            fi
            printf "geosite 标签    : %s\n" "$(_xmg_warp_geo_tags "$eff")"
            printf "分流条目数      : %s (硬编码 + geosite)\n" "$(xmg_warp_routing_domains "$eff" | wc -l | tr -d ' ')"
            echo "=============================================================="
            ;;
        update)
            xmg_require_root
            if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
                xmg_info "[测试模式] 跳过地理数据下载"
                return 0
            fi
            eff="$(xmg_warp_geo_mode_resolve "$want")"
            if [ "$eff" = "off" ]; then
                # off 档不阻止用户预先准备好数据：下载本身不改变当前规则，
                # 只是切到 slim/std/full 时才真正加载。
                xmg_warn "当前档位为 off，数据下载后不会自动生效"
                xmg_info "启用方式: xmg warp enable routing --geo slim"
            fi
            xmg_info "刷新地理数据: $f"
            mkdir -p "$dir" 2>/dev/null || { xmg_error "无法创建目录: $dir"; return 1; }
            if _xmg_warp_geo_download "$f" && xmg_warp_geo_available; then
                rm -f "${XMG_WARP_GEO_FAIL_MARK:-${XMG_WARP_DIR}/.geodata_failed}" 2>/dev/null || true
                xmg_info "地理数据已更新 ($(( $(_xmg_warp_geo_size "$f") / 1024 )) KB)"
                if [ "${XMG_PROXY_NO_RELOAD:-0}" != "1" ] && _warp_can_manage_service; then
                    if _warp_restart_xray >/dev/null 2>&1; then
                        xmg_info "已自动重启 Xray 服务使新地理数据立即生效"
                    else
                        xmg_warn "自动重启 Xray 失败，请执行: xmg xray restart"
                    fi
                else
                    xmg_warn "规则未变，重启 Xray 后新数据才会被加载: xmg xray restart"
                fi
                return 0
            fi
            xmg_error "地理数据更新失败（网络不可达或产物异常）"
            return 1
            ;;
        clean)
            xmg_require_root
            rm -f "${XMG_WARP_GEO_FAIL_MARK:-${XMG_WARP_DIR}/.geodata_failed}" 2>/dev/null || true
            if [ -f "$f" ]; then
                rm -f "$f" 2>/dev/null || true
                xmg_info "已删除地理数据文件: $f"
                if [ "${XMG_TEST_MODE:-0}" != "1" ] && [ "${XMG_PROXY_NO_RELOAD:-0}" != "1" ] && _warp_can_manage_service; then
                    if _warp_restart_xray >/dev/null 2>&1; then
                        xmg_info "已自动重启 Xray 服务，分流已切换为纯硬编码域名"
                    else
                        xmg_warn "分流将回退为硬编码域名，请执行 xmg xray restart 生效"
                    fi
                else
                    xmg_warn "分流将回退为硬编码域名，重启 Xray 后生效"
                fi
            else
                xmg_info "地理数据文件不存在，无需清理"
            fi
            ;;
        *)
            xmg_error "未知的 geo 子命令: '$action'（支持 status / update / clean）"
            return 2
            ;;
    esac
    return 0
}

_XMG_WARP_EPHEMERAL_PID=""
_XMG_WARP_EPHEMERAL_DIR=""

_xmg_warp_stop_ephemeral_socks() {
    if [ -n "${_XMG_WARP_EPHEMERAL_PID:-}" ]; then
        kill "$_XMG_WARP_EPHEMERAL_PID" 2>/dev/null || true
        wait "$_XMG_WARP_EPHEMERAL_PID" 2>/dev/null || true
        _XMG_WARP_EPHEMERAL_PID=""
    fi
    if [ -n "${_XMG_WARP_EPHEMERAL_DIR:-}" ] && [ -d "$_XMG_WARP_EPHEMERAL_DIR" ]; then
        rm -rf "$_XMG_WARP_EPHEMERAL_DIR" 2>/dev/null || true
        _XMG_WARP_EPHEMERAL_DIR=""
    fi
}

_xmg_warp_start_ephemeral_socks() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] && return 1
    [ -f "$XMG_WARP_ACCOUNT_FILE" ] || return 1

    _warp_load_xray_lib 2>/dev/null || true
    local xray_bin=""
    if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
        xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"
    elif command -v xray >/dev/null 2>&1; then
        xray_bin="$(command -v xray)"
    elif [ -x /usr/local/bin/xray ]; then
        xray_bin="/usr/local/bin/xray"
    fi
    [ -n "$xray_bin" ] && [ -x "$xray_bin" ] || return 1

    local tdir="" tport=""
    tdir="$(mktemp -d 2>/dev/null || echo "${XMG_WARP_DIR:-/opt/xmg/warp}/.eph_$$_$RANDOM")"
    mkdir -p "$tdir" 2>/dev/null || return 1

    if command -v python3 >/dev/null 2>&1; then
        tport="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || true)"
    fi
    [[ "$tport" =~ ^[0-9]+$ ]] && [ "$tport" -gt 1024 ] || tport="$(( 30000 + (RANDOM % 20000) ))"

    local out_frag=""
    out_frag="$(xmg_warp_export_xray_outbound 2>/dev/null || true)"
    if [ -z "$out_frag" ]; then
        rm -rf "$tdir" 2>/dev/null || true
        return 1
    fi

    cat > "$tdir/config.json" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "tag": "eph-socks",
      "listen": "127.0.0.1",
      "port": $tport,
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": false }
    }
  ],
  "outbounds": [
    $out_frag
  ]
}
EOF
    if ! "$xray_bin" run -test -format json -c "$tdir/config.json" >/dev/null 2>&1; then
        rm -rf "$tdir" 2>/dev/null || true
        return 1
    fi

    "$xray_bin" run -c "$tdir/config.json" >/dev/null 2>&1 &
    _XMG_WARP_EPHEMERAL_PID="$!"
    _XMG_WARP_EPHEMERAL_DIR="$tdir"

    local i=0
    while [ "$i" -lt 20 ]; do
        if curl -x "socks5h://127.0.0.1:${tport}" -s --connect-timeout 1 --max-time 1 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
            printf 'socks5h://127.0.0.1:%s
' "$tport"
            return 0
        fi
        kill -0 "$_XMG_WARP_EPHEMERAL_PID" 2>/dev/null || break
        i=$((i + 1))
        sleep 0.1
    done

    _xmg_warp_stop_ephemeral_socks
    return 1
}

# ===== 获取本机 Xray SOCKS5 代理地址（供实测 WARP 出站） =====
_xmg_warp_local_socks_proxy_url() {
    local cfg="" listen="" port="" user="" pass=""
    cfg="$(_xmg_warp_find_xray_config 2>/dev/null || true)"

    if [ -n "$cfg" ] && [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
        local line=""
        line="$(jq -r '
            [.inbounds[]? | select(.protocol=="socks")][0] // empty |
            [(.listen // "127.0.0.1"), ((.port // 0) | tostring), (.settings.users[0].user // ""), (.settings.users[0].pass // "")] |
            @tsv
        ' "$cfg" 2>/dev/null || true)"
        if [ -n "$line" ]; then
            IFS=$'\t' read -r listen port user pass <<< "$line"
        fi
    fi

    if [ -z "$port" ] || [ "$port" = "0" ]; then
        if declare -F xmg_state_get >/dev/null 2>&1; then
            [ "$(xmg_state_get PROXY_SOCKS_ENABLED 0 2>/dev/null)" = "1" ] || return 1
            listen="$(xmg_state_get PROXY_SOCKS_LISTEN "127.0.0.1" 2>/dev/null)"
            port="$(xmg_state_get PROXY_SOCKS_PORT "1080" 2>/dev/null)"
            user="$(xmg_state_get PROXY_SOCKS_USER "" 2>/dev/null)"
            pass="$(xmg_state_get PROXY_SOCKS_PASS "" 2>/dev/null)"
        else
            return 1
        fi
    fi

    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || return 1
    case "$listen" in
        ""|"0.0.0.0") listen="127.0.0.1" ;;
        "::"|"[::]")  listen="[::1]" ;;
        *:*)
            [[ "$listen" == \[*\] ]] || listen="[$listen]"
            ;;
    esac

    if [ -n "$user" ] && [ -n "$pass" ]; then
        printf 'socks5h://%s:%s@%s:%s\n' "$user" "$pass" "$listen" "$port"
    else
        printf 'socks5h://%s:%s\n' "$listen" "$port"
    fi
    return 0
}

# ===== 流媒体与 IP 清洁度测试 =====

xmg_warp_test_unlock() {
    echo "==================== WARP 流媒体与 IP 清洁度测试 ===================="
    echo "正在测试常见平台连通性与解锁状态，请稍候..."
    echo

    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        echo "[测试] YouTube Premium : 支持 (US 地区解锁)"
        echo "[测试] Netflix         : 支持 (原生内容解锁)"
        echo "[测试] Disney+         : 支持 (已解锁)"
        echo "[测试] OpenAI / ChatGPT: 支持 (官方 API/Web 访问通畅)"
        echo "[测试] Claude (Anthropic): 支持 (正常访问)"
        echo "[测试] Google Search   : 支持 (无异常验证码拦截)"
        echo "=================================================================="
        return 0
    fi

    local proxy_url=""
    local curl_proxy_args=()
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    local used_ephemeral=0
    proxy_url="$(_xmg_warp_local_socks_proxy_url 2>/dev/null || true)"
    if [ -n "$proxy_url" ]; then
        local px_trace=""
        px_trace="$(curl -x "$proxy_url" -sSL --connect-timeout 4 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
        if [ -n "$px_trace" ]; then
            curl_proxy_args=(-x "$proxy_url")
            local px_ip="" px_loc="" px_colo="" px_warp=""
            px_ip="$(printf '%s\n' "$px_trace" | grep -E '^ip=' | head -1 | cut -d= -f2)"
            px_loc="$(printf '%s\n' "$px_trace" | grep -E '^loc=' | head -1 | cut -d= -f2)"
            px_colo="$(printf '%s\n' "$px_trace" | grep -E '^colo=' | head -1 | cut -d= -f2)"
            px_warp="$(printf '%s\n' "$px_trace" | grep -E '^warp=' | head -1 | cut -d= -f2)"
            xmg_info "测试路径: 通过 Xray 本机 SOCKS5 代理 (实测 WARP 出站)"
            printf "当前代理出口 IP             : %s (%s, 机房: %s, warp=%s)\n" "${px_ip:-未知}" "${px_loc:-未知}" "${px_colo:-未知}" "${px_warp:-off}"
        else
            proxy_url=""
        fi
    fi

    if [ -z "$proxy_url" ] && [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        proxy_url="$(_xmg_warp_start_ephemeral_socks 2>/dev/null || true)"
        if [ -n "$proxy_url" ]; then
            used_ephemeral=1
            curl_proxy_args=(-x "$proxy_url")
            local eph_trace="" eph_ip="" eph_loc="" eph_colo="" eph_warp=""
            eph_trace="$(curl -x "$proxy_url" -sSL --connect-timeout 4 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
            eph_ip="$(printf '%s\n' "$eph_trace" | grep -E '^ip=' | head -1 | cut -d= -f2)"
            eph_loc="$(printf '%s\n' "$eph_trace" | grep -E '^loc=' | head -1 | cut -d= -f2)"
            eph_colo="$(printf '%s\n' "$eph_trace" | grep -E '^colo=' | head -1 | cut -d= -f2)"
            eph_warp="$(printf '%s\n' "$eph_trace" | grep -E '^warp=' | head -1 | cut -d= -f2)"
            xmg_info "测试路径: 通过临时本地 WARP 探测实例 (不暴露公网端口，测完自动销毁)"
            printf "当前 WARP 实测出口 IP       : %s (%s, 机房: %s, warp=%s)\n" "${eph_ip:-未知}" "${eph_loc:-未知}" "${eph_colo:-未知}" "${eph_warp:-off}"
        fi
    fi

    if [ ${#curl_proxy_args[@]} -eq 0 ]; then
        xmg_warn "未检测到可用的本机 WARP 代理实例，以下为宿主机直连测试（非 WARP 出口）"
    fi

    # 1. OpenAI / ChatGPT
    printf "测试 OpenAI / ChatGPT       : "
    local oai_api_code="" oai_web_code=""
    oai_api_code="$(curl "${curl_proxy_args[@]}" -sSL --connect-timeout 5 --max-time 8 -o /dev/null -w "%{http_code}" https://api.openai.com/v1/models 2>/dev/null || echo "000")"
    oai_web_code="$(curl "${curl_proxy_args[@]}" -sSL -A "$ua" --connect-timeout 5 --max-time 8 -o /dev/null -w "%{http_code}" https://chatgpt.com 2>/dev/null || echo "000")"
    if [ "$oai_api_code" = "401" ] || [ "$oai_api_code" = "200" ]; then
        if [ "$oai_web_code" = "200" ] || [ "$oai_web_code" = "301" ] || [ "$oai_web_code" = "302" ]; then
            echo "完全支持 (API HTTP $oai_api_code / Web HTTP $oai_web_code)"
        else
            echo "API 可用 (HTTP $oai_api_code)，Web 受风控 (HTTP $oai_web_code)"
        fi
    elif [ "$oai_api_code" = "403" ] || [ "$oai_api_code" = "451" ] || [ "$oai_web_code" = "403" ]; then
        echo "被拦截或地区受限 (API HTTP $oai_api_code / Web HTTP $oai_web_code)"
    else
        echo "受限或超时 (API HTTP $oai_api_code / Web HTTP $oai_web_code)"
    fi

    # 2. Netflix
    printf "测试 Netflix 原生解锁       : "
    local nflx_nonorig_code="" nflx_orig_code=""
    nflx_nonorig_code="$(curl "${curl_proxy_args[@]}" -sSL -A "$ua" --connect-timeout 5 --max-time 8 -o /dev/null -w "%{http_code}" "https://www.netflix.com/title/80018499" 2>/dev/null || echo "000")"
    if [ "$nflx_nonorig_code" = "200" ]; then
        echo "已解锁 (支持完整自制剧与版权内容)"
    else
        nflx_orig_code="$(curl "${curl_proxy_args[@]}" -sSL -A "$ua" --connect-timeout 5 --max-time 8 -o /dev/null -w "%{http_code}" "https://www.netflix.com/title/81280792" 2>/dev/null || echo "000")"
        if [ "$nflx_orig_code" = "200" ]; then
            echo "仅解锁自制剧 (HTTP $nflx_nonorig_code / $nflx_orig_code)"
        else
            echo "未解锁或连接受阻 (HTTP $nflx_nonorig_code)"
        fi
    fi

    # 3. YouTube 地区与 Premium
    printf "测试 YouTube 地区标识       : "
    local yt_loc=""
    yt_loc="$(curl "${curl_proxy_args[@]}" -sSL -A "$ua" --connect-timeout 5 --max-time 8 https://www.youtube.com 2>/dev/null | grep -o '"countryCode":"[A-Z]*"' | head -1 | cut -d'"' -f4 || true)"
    if [ -n "$yt_loc" ]; then
        echo "已定位 ($( _xmg_warp_country_name "$yt_loc" ))"
    else
        echo "未获取到地区标识"
    fi

    # 4. Google 搜索验证码防风控
    printf "测试 Google 搜索风控状态    : "
    local g_tmp="" g_code="" g_res=""
    g_tmp="$(mktemp 2>/dev/null || echo "${XMG_WARP_DIR:-/opt/xmg/warp}/.g_$$_$RANDOM.html")"
    g_code="$(curl "${curl_proxy_args[@]}" -sSL -A "$ua" --connect-timeout 5 --max-time 8 -o "$g_tmp" -w "%{http_code}" "https://www.google.com/search?q=test" 2>/dev/null || echo "000")"
    g_res="$(cat "$g_tmp" 2>/dev/null || true)"
    rm -f "$g_tmp" 2>/dev/null || true
    if [ "$g_code" = "429" ] || echo "$g_res" | grep -qiE "recaptcha|unusual traffic|/sorry/"; then
        echo "检测到异常流量验证码 (HTTP $g_code, WARN)"
    elif [ "$g_code" = "200" ] || [ "$g_code" = "301" ] || [ "$g_code" = "302" ]; then
        echo "清洁通过 (HTTP $g_code，无验证码拦截)"
    else
        echo "无法连接 (HTTP $g_code)"
    fi

    [ "$used_ephemeral" -eq 1 ] && _xmg_warp_stop_ephemeral_socks
    echo "=================================================================="
}

# ===== 交互菜单 =====

xmg_warp_menu() {
    local choice=""

    while true; do
        clear
        echo "========== WARP 原生出站管理 (Xray WireGuard) =========="
        echo "核心设计: 彻底隐藏高污染本机 IP，节点代理公网流量走 WARP 清洁出口"
        echo "宿主机保障: 100% 零侵入、零网卡、零路由修改，SSH 物理级绝对不可能失联！"
        echo "------------------------------------------------------------"
        echo "1. 一键全自动极速配置 (原生嗅探 + 注册纯净凭据 + 优选端点 + 全局清洁出站)"
        echo "2. 启用 WARP 全局清洁出站 (节点公网出站默认 100% 走 WARP，隐藏高污染本机 IP)"
        echo "3. 启用 WARP 流媒体与 AI 分流出站 (按需分流常见 AI 与流媒体域名)"
        echo "4. 关闭 WARP 出站 (恢复纯直连出口)"
        echo "5. 查看当前 WARP 状态与网络出口诊断"
        echo "6. 智能优选低延迟本地端点 (锁定 VPS 本地机房，2ms 极速延迟)"
        echo "7. 测试流媒体 / ChatGPT / Google 地区与 IP 清洁度"
        echo "8. 导出 / 查看 Xray 原生 WireGuard 出站配置片段"
        echo "9. 重新注册 Cloudflare WARP 纯净账号凭据 (含 3 字节保留标识)"
        echo "10. 导入已有 WARP 凭据 (突破机房 IP 注册受限)"
        echo "11. 清理 / 卸载 WARP 配置与凭据"
        echo "0. 返回"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                clear
                xmg_warp_auto_apply || true
                xmg_pause
                ;;
            2)
                clear
                xmg_warp_enable "global" || true
                xmg_pause
                ;;
            3)
                clear
                xmg_warp_enable "routing" || true
                xmg_pause
                ;;
            4)
                clear
                xmg_warp_disable || true
                xmg_pause
                ;;
            5)
                clear
                xmg_warp_status
                xmg_pause
                ;;
            6)
                clear
                xmg_warp_optimize_endpoint || true
                xmg_pause
                ;;
            7)
                clear
                xmg_warp_test_unlock
                xmg_pause
                ;;
            8)
                clear
                xmg_warp_export_xray_outbound || true
                xmg_pause
                ;;
            9)
                clear
                _xmg_warp_register 1 || true
                xmg_pause
                ;;
            10)
                clear
                xmg_warp_import || true
                xmg_pause
                ;;
            11)
                clear
                xmg_warp_uninstall || true
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
