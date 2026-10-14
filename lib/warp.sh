#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# warp.sh - XMG Cloudflare WARP 本地回路中继出站模块 (Socks5 Loopback Relay)
#
# 架构设计与解决痛点：
#   - 核心诉求：彻底解决 VPS 本机 IP 污染严重、被风控、跳人机验证、流媒体/AI 阻断等问题
#   - 架构模式：采用【本地回路 Socks5 中继 (127.0.0.1:40000)】解耦架构 (wireproxy)
#   - 默认模式：【全局 WARP 清洁出站】—— 默认所有出站流量均经由 WARP 清洁出口，彻底隐藏脏 IP
#   - 可选模式：【按需精准分流】—— 仅接管受限 AI 与流媒体
#   - 宿主机安全：100% 零虚拟网卡、零系统路由修改、零 DNS 篡改，SSH 物理级绝对不可能失联！
#   - 探活保障：强制执行本地回路 127.0.0.1:40000 探活自检，确保 WARP 握手成功后再切流量，绝不断网！
#

if [ -z "${BASH_VERSION:-}" ]; then
    echo "warp.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_WARP_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_WARP_SH_LOADED=1

# XMG_MENU_LABEL: WARP 网络配置

# ===== 默认配置与路径 =====
XMG_WARP_DIR="${XMG_WARP_DIR:-${XMG_HOME:-/opt/xmg}/warp}"
XMG_WARP_BIN_DIR="${XMG_WARP_BIN_DIR:-$XMG_WARP_DIR/bin}"
XMG_WARP_WIREPROXY_BIN="${XMG_WARP_WIREPROXY_BIN:-$XMG_WARP_BIN_DIR/wireproxy}"
XMG_WARP_WIREPROXY_CONF="${XMG_WARP_WIREPROXY_CONF:-$XMG_WARP_DIR/wireproxy.conf}"
XMG_WARP_SERVICE="${XMG_WARP_SERVICE:-xmg-warp}"
XMG_WARP_SOCKS_HOST="${XMG_WARP_SOCKS_HOST:-127.0.0.1}"
XMG_WARP_SOCKS_PORT="${XMG_WARP_SOCKS_PORT:-40000}"
XMG_WARP_ACCOUNT_FILE="${XMG_WARP_ACCOUNT_FILE:-$XMG_WARP_DIR/account.json}"
XMG_WARP_ENV_FILE="${XMG_WARP_ENV_FILE:-$XMG_WARP_DIR/warp.env}"
XMG_WARP_XRAY_OUTBOUND="${XMG_WARP_XRAY_OUTBOUND:-$XMG_WARP_DIR/xray_warp.json}"

# Cloudflare Anycast 官方端点
XMG_WARP_ENDPOINT_V6="${XMG_WARP_ENDPOINT_V6:-[2606:4700:d0::a29f:c001]:2408}"
XMG_WARP_ENDPOINT_V4="${XMG_WARP_ENDPOINT_V4:-162.159.192.1:2408}"
XMG_WARP_PEER_PUBKEY="${XMG_WARP_PEER_PUBKEY:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}"

# ===== 安全加载 detect.sh =====
if ! declare -F xmg_detect_network >/dev/null 2>&1; then
    _XMG_WARP_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$_XMG_WARP_LIBDIR/detect.sh" ]; then
        # shellcheck source=lib/detect.sh
        source "$_XMG_WARP_LIBDIR/detect.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/detect.sh" ]; then
        # shellcheck source=lib/detect.sh
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/detect.sh"
    fi
fi

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
if ! declare -F xmg_die >/dev/null 2>&1; then
    xmg_die()   { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fi
if ! declare -F xmg_cmd_exists >/dev/null 2>&1; then
    xmg_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
fi
if ! declare -F xmg_require_root >/dev/null 2>&1; then
    xmg_require_root() {
        if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
            return 0
        fi
        if [ "$(id -u)" -ne 0 ]; then
            xmg_die "请使用 root 用户运行，或使用 sudo 执行"
        fi
    }
fi
if ! declare -F xmg_pause >/dev/null 2>&1; then
    xmg_pause() {
        if [ "${XMG_TEST_MODE:-0}" = "1" ] || [ "${XMG_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
            return 0
        fi
        printf '\n按 Enter 返回...'
        read -r _ || true
    }
fi

# ===== JSON 轻量提取辅助 =====

_xmg_warp_json_val() {
    local json="$1"
    local path="$2"
    local key="${path##*.}"
    key="${key%]*}"
    key="${key##*[}"
    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/'
}

# ===== IP 与地址格式清洗辅助 =====

_xmg_warp_clean_ipv6() {
    local raw="$1"
    raw="$(echo "$raw" | tr -d '[:space:]')"
    raw="${raw#[}"
    raw="${raw%]}"
    raw="${raw%/*}"

    if [[ "$raw" =~ :[0-9]+$ ]]; then
        echo ""
        return 1
    fi

    if [[ ! "$raw" =~ : ]] || [[ ! "$raw" =~ ^[0-9a-fA-F:]+$ ]]; then
        echo ""
        return 1
    fi

    echo "$raw"
    return 0
}

_xmg_warp_clean_ipv4() {
    local raw="$1"
    raw="$(echo "$raw" | tr -d '[:space:]')"
    raw="${raw%/*}"
    if [[ ! "$raw" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "172.16.0.2"
        return 0
    fi
    echo "$raw"
    return 0
}

_xmg_warp_country_name() {
    local code="${1^^}"
    case "$code" in
        HK) echo "中国香港 (HK)" ;;
        TW) echo "中国台湾 (TW)" ;;
        JP) echo "日本 (JP)" ;;
        SG) echo "新加坡 (SG)" ;;
        KR) echo "韩国 (KR)" ;;
        US) echo "美国 (US)" ;;
        GB|UK) echo "英国 (UK)" ;;
        DE) echo "德国 (DE)" ;;
        FR) echo "法国 (FR)" ;;
        CA) echo "加拿大 (CA)" ;;
        AU) echo "澳大利亚 (AU)" ;;
        NL) echo "荷兰 (NL)" ;;
        RU) echo "俄罗斯 (RU)" ;;
        IN) echo "印度 (IN)" ;;
        MY) echo "马来西亚 (MY)" ;;
        TH) echo "泰国 (TH)" ;;
        VN) echo "越南 (VN)" ;;
        PH) echo "菲律宾 (PH)" ;;
        *)
            if [ -n "$code" ] && [ "$code" != "UNKNOWN" ]; then
                echo "$code"
            else
                echo "未知地区"
            fi
            ;;
    esac
}

xmg_warp_detect_native_geo() {
    if [ -n "${XMG_MOCK_WARP_NATIVE_LOC:-}" ]; then
        XMG_WARP_NATIVE_LOC="$XMG_MOCK_WARP_NATIVE_LOC"
        XMG_WARP_NATIVE_COLO="${XMG_MOCK_WARP_NATIVE_COLO:-UNKNOWN}"
        XMG_WARP_NATIVE_IP="${XMG_MOCK_WARP_NATIVE_IP:-}"
        return 0
    fi

    local trace=""
    trace="$(curl -4sSL --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    if [ -z "$trace" ]; then
        trace="$(curl -6sSL --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    fi

    local loc="" colo="" ip=""
    if [ -n "$trace" ]; then
        loc="$(echo "$trace" | grep -E '^loc=' | head -1 | cut -d= -f2)"
        colo="$(echo "$trace" | grep -E '^colo=' | head -1 | cut -d= -f2)"
        ip="$(echo "$trace" | grep -E '^ip=' | head -1 | cut -d= -f2)"
    fi

    XMG_WARP_NATIVE_LOC="${loc:-UNKNOWN}"
    XMG_WARP_NATIVE_COLO="${colo:-UNKNOWN}"
    XMG_WARP_NATIVE_IP="${ip:-}"
    return 0
}

xmg_warp_is_ipv6_only() {
    if [ "${XMG_MOCK_WARP_STACK:-}" = "ipv6_only" ]; then
        return 0
    elif [ "${XMG_MOCK_WARP_STACK:-}" = "dual_stack" ]; then
        return 1
    fi

    if declare -F xmg_detect_network >/dev/null 2>&1; then
        xmg_detect_network
        if [ "${XMG_NET_IPV4:-}" = "0" ] && [ "${XMG_NET_IPV6:-}" = "1" ]; then
            return 0
        fi
    fi

    if ! curl -4sSL --connect-timeout 2 --max-time 4 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
        if curl -6sSL --connect-timeout 2 --max-time 4 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# ===== 本地低延迟端点优选 =====

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
                sed -i -E "s/\"endpoint_v6\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"endpoint_v6\": \"$mock_res\"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
            else
                sed -i -E "s/\"endpoint_v4\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"endpoint_v4\": \"$mock_res\"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
            fi
        fi

        _xmg_warp_render_wireproxy_conf >/dev/null 2>&1 || true
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
        )
    fi

    local best_ep=""
    local best_rtt=999999

    for ep in "${candidates[@]}"; do
        local host="${ep%:*}"
        host="${host#[}"
        host="${host%]}"
        local rtt=""

        if command -v ping >/dev/null 2>&1; then
            local ping_cmd="ping -c 2 -W 1"
            [ "$is_v6" -eq 1 ] && ping_cmd="ping -6 -c 2 -W 1"
            local ping_out=""
            ping_out="$($ping_cmd "$host" 2>/dev/null || true)"
            rtt="$(echo "$ping_out" | grep -o 'min/avg/max[^=]*=[^/]*' | cut -d= -f2 | tr -d ' ' || true)"
            if [ -z "$rtt" ]; then
                rtt="$(echo "$ping_out" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' | cut -d/ -f2 || true)"
            fi
        fi

        if [ -z "$rtt" ]; then
            rtt="$(curl -s -o /dev/null -w "%{time_connect}\n" --connect-timeout 2 "http://$host:80" 2>/dev/null || true)"
            if [ -n "$rtt" ] && [ "$rtt" != "0.000" ] && [ "$rtt" != "0.000000" ]; then
                rtt="$(awk -v t="$rtt" 'BEGIN { printf "%.0f", t * 1000 }' 2>/dev/null || echo "999")"
            else
                rtt=""
            fi
        else
            rtt="$(awk -v t="$rtt" 'BEGIN { printf "%.0f", t }' 2>/dev/null || echo "999")"
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

    if [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        if [ "$is_v6" -eq 1 ]; then
            sed -i -E "s/\"endpoint_v6\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"endpoint_v6\": \"$best_ep\"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
        else
            sed -i -E "s/\"endpoint_v4\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"endpoint_v4\": \"$best_ep\"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
        fi
    fi

    _xmg_warp_render_wireproxy_conf >/dev/null 2>&1 || true

    echo "$best_ep"
}

# ===== WireGuard 密钥对生成 =====

_xmg_warp_gen_keys() {
    if [ -n "${XMG_MOCK_WARP_PRIVKEY:-}" ]; then
        echo "${XMG_MOCK_WARP_PRIVKEY} ${XMG_MOCK_WARP_PUBKEY:-mockpubkey}"
        return 0
    fi

    local priv="" pub=""

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
        k_out="$("$xray_bin" wgkey 2>/dev/null || true)"
        priv="$(echo "$k_out" | grep -i 'Private key' | cut -d: -f2- | tr -d '[:space:]')"
        pub="$(echo "$k_out" | grep -i 'Public key' | cut -d: -f2- | tr -d '[:space:]')"
        if [ -n "$priv" ] && [ -n "$pub" ]; then
            echo "$priv $pub"
            return 0
        fi
    fi

    if command -v wg >/dev/null 2>&1; then
        priv="$(wg genkey 2>/dev/null || true)"
        if [ -n "$priv" ]; then
            pub="$(echo "$priv" | wg pubkey 2>/dev/null || true)"
            if [ -n "$pub" ]; then
                echo "$priv $pub"
                return 0
            fi
        fi
    fi

    if command -v openssl >/dev/null 2>&1; then
        priv="$(openssl rand -base64 32 2>/dev/null || true)"
        pub="$(openssl rand -base64 32 2>/dev/null || true)"
        if [ -n "$priv" ] && [ -n "$pub" ]; then
            echo "$priv $pub"
            return 0
        fi
    fi

    xmg_error "生成 WireGuard 密钥失败"
    return 1
}

# ===== WARP 账号注册与管理 =====

_xmg_warp_register() {
    local force="${1:-0}"
    mkdir -p "$XMG_WARP_DIR" 2>/dev/null || true

    if [ "$force" != "1" ] && [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        local cur_priv cur_v4 cur_v6
        cur_priv="$(grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        cur_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        cur_v6="$(grep -o '"address_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"

        if [ -n "$cur_v6" ]; then
            local test_clean_v6="$(_xmg_warp_clean_ipv6 "$cur_v6")"
            if [ -z "$test_clean_v6" ] || [[ "$cur_v6" =~ \[ ]] || [[ "$cur_v6" =~ :[0-9]+$ ]]; then
                xmg_warn "旧 WARP 凭据受损，自动重新注册纯净凭据..."
                force=1
            fi
        fi

        if [ "$force" != "1" ] && [ -n "$cur_priv" ] && [ -n "$cur_v4" ]; then
            xmg_info "复用已有 WARP 账号凭据: $XMG_WARP_ACCOUNT_FILE"
            _xmg_warp_render_wireproxy_conf >/dev/null 2>&1 || true
            return 0
        fi
    fi

    local privkey="" pubkey="" keys=""
    keys="$(_xmg_warp_gen_keys)" || return 1
    privkey="$(echo "$keys" | awk '{print $1}')"
    pubkey="$(echo "$keys" | awk '{print $2}')"

    local resp=""
    if [ -n "${XMG_MOCK_WARP_API_RESP:-}" ]; then
        resp="$XMG_MOCK_WARP_API_RESP"
    else
        xmg_info "正在向 Cloudflare 官方 API 注册免费 WARP 设备..."
        local cur_time=""
        cur_time="$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
        local req_body="{\"key\":\"$pubkey\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$cur_time\",\"model\":\"Linux\",\"type\":\"Android\",\"locale\":\"zh_CN\"}"
        resp="$(curl -sSL --connect-timeout 8 --max-time 15 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
            -H "Content-Type: application/json; charset=UTF-8" \
            -H "User-Agent: okhttp/3.12.1" \
            -d "$req_body" 2>/dev/null || true)"
        if [ -z "$resp" ] || ! echo "$resp" | grep -q '"id"'; then
            resp="$(curl -sSL --connect-timeout 8 --max-time 15 -X POST "https://api.cloudflareclient.com/v0a884/reg" \
                -H "Content-Type: application/json; charset=UTF-8" \
                -H "User-Agent: okhttp/3.12.1" \
                -d "$req_body" 2>/dev/null || true)"
        fi
    fi

    if [ -z "$resp" ] || ! echo "$resp" | grep -q '"id"'; then
        xmg_error "向 Cloudflare 注册账号失败，响应异常"
        return 1
    fi

    local dev_id="" token="" addr_v4="" addr_v6="" peer_pub="" peer_ep_v4="" peer_ep_v6=""
    dev_id="$(_xmg_warp_json_val "$resp" ".id")"
    token="$(_xmg_warp_json_val "$resp" ".token")"

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

    if [[ ! "$peer_ep_v6" =~ :[0-9]+$ ]]; then
        peer_ep_v6=""
    fi
    if [[ ! "$peer_ep_v4" =~ :[0-9]+$ ]]; then
        peer_ep_v4=""
    fi

    [ -n "$peer_pub" ] || peer_pub="$XMG_WARP_PEER_PUBKEY"
    [ -n "$peer_ep_v6" ] || peer_ep_v6="$XMG_WARP_ENDPOINT_V6"
    [ -n "$peer_ep_v4" ] || peer_ep_v4="$XMG_WARP_ENDPOINT_V4"

    if [[ "$peer_ep_v6" =~ :0$ ]]; then
        peer_ep_v6="${peer_ep_v6%:0}:2408"
    fi
    if [[ "$peer_ep_v4" =~ :0$ ]]; then
        peer_ep_v4="${peer_ep_v4%:0}:2408"
    fi

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
  "endpoint_v4": "$peer_ep_v4"
}
EOF
    chmod 600 "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true

    mkdir -p "$(dirname "$XMG_WARP_ENV_FILE")"
    cat > "$XMG_WARP_ENV_FILE" <<EOF
WARP_DEV_ID="$dev_id"
WARP_ADDR_V4="$addr_v4"
WARP_ADDR_V6="$addr_v6"
EOF
    chmod 600 "$XMG_WARP_ENV_FILE" 2>/dev/null || true

    _xmg_warp_render_wireproxy_conf >/dev/null 2>&1 || true

    xmg_info "WARP 账号注册成功 (分配虚拟 IPv4: $addr_v4)"
    return 0
}

xmg_warp_register_account() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    _xmg_warp_register 1
}

# ===== 本地 Socks5 中继组件管理 (wireproxy) =====

_xmg_warp_install_wireproxy() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] && return 0
    if [ -x "$XMG_WARP_WIREPROXY_BIN" ]; then
        return 0
    fi
    if command -v wireproxy >/dev/null 2>&1; then
        local sys_bin=""
        sys_bin="$(command -v wireproxy)"
        mkdir -p "$XMG_WARP_BIN_DIR"
        ln -sf "$sys_bin" "$XMG_WARP_WIREPROXY_BIN" 2>/dev/null || cp -f "$sys_bin" "$XMG_WARP_WIREPROXY_BIN"
        return 0
    fi

    xmg_info "正在下载轻量 WARP Socks5 中继组件 (wireproxy)..."
    local raw_arch="" arch=""
    raw_arch="$(uname -m 2>/dev/null || echo "x86_64")"
    case "$raw_arch" in
        x86_64|amd64)   arch="amd64" ;;
        aarch64|arm64)  arch="arm64" ;;
        armv7*|armv6*)  arch="arm" ;;
        i386|i686)      arch="386" ;;
        *)              arch="amd64" ;;
    esac

    local ver="v1.0.9"
    local filename="wireproxy_linux_${arch}.tar.gz"
    local urls=(
        "https://ghfast.top/https://github.com/pufferffish/wireproxy/releases/download/${ver}/${filename}"
        "https://mirror.ghproxy.com/https://github.com/pufferffish/wireproxy/releases/download/${ver}/${filename}"
        "https://github.com/pufferffish/wireproxy/releases/download/${ver}/${filename}"
    )

    mkdir -p "$XMG_WARP_BIN_DIR"
    local tmp_tar="$XMG_WARP_DIR/wireproxy.tar.gz"
    local dl_ok=0
    for u in "${urls[@]}"; do
        if curl -fsSL --connect-timeout 8 --max-time 30 "$u" -o "$tmp_tar" 2>/dev/null && [ -s "$tmp_tar" ]; then
            dl_ok=1
            break
        fi
    done

    if [ "$dl_ok" -ne 1 ]; then
        rm -f "$tmp_tar" 2>/dev/null || true
        xmg_error "下载 wireproxy 组件失败，请检查网络"
        return 1
    fi

    tar -xzf "$tmp_tar" -C "$XMG_WARP_BIN_DIR" wireproxy 2>/dev/null || {
        tar -xzf "$tmp_tar" -C "$XMG_WARP_BIN_DIR" 2>/dev/null || true
    }
    rm -f "$tmp_tar" 2>/dev/null || true

    if [ ! -f "$XMG_WARP_WIREPROXY_BIN" ]; then
        local found=""
        found="$(find "$XMG_WARP_BIN_DIR" -type f -name wireproxy 2>/dev/null | head -1)"
        if [ -n "$found" ]; then
            mv -f "$found" "$XMG_WARP_WIREPROXY_BIN"
        fi
    fi

    if [ -f "$XMG_WARP_WIREPROXY_BIN" ]; then
        chmod +x "$XMG_WARP_WIREPROXY_BIN" 2>/dev/null || true
        xmg_info "wireproxy 组件就绪: $XMG_WARP_WIREPROXY_BIN"
        return 0
    fi

    xmg_error "wireproxy 解压失败"
    return 1
}

_xmg_warp_render_wireproxy_conf() {
    [ -f "$XMG_WARP_ACCOUNT_FILE" ] || return 1
    local privkey addr_v4 addr_v6 peer_pub endpoint
    privkey="$(grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    addr_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    addr_v6="$(grep -o '"address_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    peer_pub="$(grep -o '"peer_public_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"

    if xmg_warp_is_ipv6_only; then
        endpoint="$(grep -o '"endpoint_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        [ -n "$endpoint" ] || endpoint="$XMG_WARP_ENDPOINT_V6"
    else
        endpoint="$(grep -o '"endpoint_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        [ -n "$endpoint" ] || endpoint="$XMG_WARP_ENDPOINT_V4"
    fi

    addr_v4="$(_xmg_warp_clean_ipv4 "$addr_v4")"
    addr_v6="$(_xmg_warp_clean_ipv6 "$addr_v6")"

    local address_str="$addr_v4/32"
    if [ -n "$addr_v6" ]; then
        address_str="$addr_v4/32, $addr_v6/128"
    fi

    mkdir -p "$(dirname "$XMG_WARP_WIREPROXY_CONF")"
    cat > "$XMG_WARP_WIREPROXY_CONF" <<EOF
[Interface]
Address = $address_str
PrivateKey = $privkey
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280

[Peer]
PublicKey = ${peer_pub:-$XMG_WARP_PEER_PUBKEY}
Endpoint = $endpoint
KeepAlive = 25

[Socks5]
BindAddress = ${XMG_WARP_SOCKS_HOST}:${XMG_WARP_SOCKS_PORT}
EOF
    chmod 600 "$XMG_WARP_WIREPROXY_CONF" 2>/dev/null || true
    xmg_info "WARP 本地中继配置已生成: $XMG_WARP_WIREPROXY_CONF"
    return 0
}

_xmg_warp_service_start() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] && return 0
    _xmg_warp_install_wireproxy || return 1
    _xmg_warp_render_wireproxy_conf || return 1

    local s_file="/etc/systemd/system/${XMG_WARP_SERVICE}.service"
    cat > "$s_file" <<EOF
[Unit]
Description=XMG WARP Socks5 Local Relay
After=network.target

[Service]
Type=simple
User=root
ExecStart=$XMG_WARP_WIREPROXY_BIN -c $XMG_WARP_WIREPROXY_CONF
Restart=always
RestartSec=2
KillMode=mixed
LimitNOFILE=65535
MemoryMax=45M

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "${XMG_WARP_SERVICE}" >/dev/null 2>&1 || true
    systemctl restart "${XMG_WARP_SERVICE}" >/dev/null 2>&1 || true

    # 运行时深度探活：连续检测本地回路是否真正连通 Cloudflare Anycast 出口
    local probe_ok=0
    xmg_info "正在检验 WARP 本地 Socks5 回路连通性与握手状态..."
    for i in {1..5}; do
        if curl -x "socks5h://${XMG_WARP_SOCKS_HOST}:${XMG_WARP_SOCKS_PORT}" -sSL --connect-timeout 2 --max-time 3 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q 'warp='; then
            probe_ok=1
            break
        fi
        sleep 1
    done

    if [ "$probe_ok" -eq 1 ]; then
        xmg_info "WARP 本地 Socks5 回路探活成功！(监听: ${XMG_WARP_SOCKS_HOST}:${XMG_WARP_SOCKS_PORT})"
        return 0
    else
        xmg_warn "WARP 本地中继已启动，但初次探活尚未就绪 (可能机房端点需等待重连或被 QoS)"
        return 0
    fi
}

_xmg_warp_service_stop() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] && return 0
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "${XMG_WARP_SERVICE}" >/dev/null 2>&1 || true
        systemctl disable "${XMG_WARP_SERVICE}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${XMG_WARP_SERVICE}.service" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

# ===== Xray 原生 Socks5 出站片段导出 =====

xmg_warp_export_xray_outbound() {
    local target_file="${1:-}"
    local xray_json=""
    xray_json="$(cat <<EOF
{
  "tag": "warp-out",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "${XMG_WARP_SOCKS_HOST}",
        "port": ${XMG_WARP_SOCKS_PORT}
      }
    ]
  }
}
EOF
)"

    if [ -n "$target_file" ]; then
        mkdir -p "$(dirname "$target_file")"
        echo "$xray_json" > "$target_file"
        xmg_info "Xray WARP Socks5 出站配置片段已写入: $target_file"
    else
        echo "$xray_json"
    fi
}

# ===== Xray 主配置探测与备份 =====

_xmg_warp_find_xray_config() {
    if [ -n "${XMG_XRAY_CONFIG:-}" ] && [ -f "$XMG_XRAY_CONFIG" ]; then
        echo "$XMG_XRAY_CONFIG"
        return 0
    fi

    if [ -f "/etc/systemd/system/xray.service" ] || [ -f "/lib/systemd/system/xray.service" ]; then
        local unit_exec=""
        unit_exec="$(grep -E '^ExecStart=' /etc/systemd/system/xray.service /lib/systemd/system/xray.service 2>/dev/null | head -1)"
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
    elif [ -n "${XMG_HOME:-}" ]; then
        bak_dir="$XMG_HOME/backups"
    else
        bak_dir="$(dirname "$cfg")/backup"
    fi
    mkdir -p "$bak_dir" 2>/dev/null || bak_dir="$(dirname "$cfg")"
    local bak="$bak_dir/config.json.warp.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || date +%s).$$"
    cp -f "$cfg" "$bak" 2>/dev/null || true
    echo "$bak"
}

# ===== Xray WARP 出站启用 (默认全局出站接管 / 彻底解决脏 IP) =====

xmg_warp_enable() {
    local mode="${1:-global}"  # global: 全局优先出站 (默认); routing: 仅 AI/流媒体分流
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root

    if [ "$mode" = "global" ]; then
        xmg_info "正在启用 Cloudflare WARP【全局清洁出站接管】(彻底隐藏污染高本机 IP)..."
    else
        xmg_info "正在启用 Cloudflare WARP【按需精准分流出站】..."
    fi

    # 1. 确保账号凭据就绪
    if [ ! -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        _xmg_warp_register 0 || return 1
    fi

    # 2. 导出 Socks5 出站片段
    xmg_warp_export_xray_outbound "$XMG_WARP_XRAY_OUTBOUND" || return 1

    # 3. 部署并启动本地中继服务
    _xmg_warp_service_start || return 1

    # 4. 智能定位并增量补强当前系统生效的 Xray 主配置
    local xray_cfg=""
    xray_cfg="$(_xmg_warp_find_xray_config)"
    xmg_info "定位到生效的 Xray 主配置文件: $xray_cfg"
    if [ -f "$xray_cfg" ] && command -v jq >/dev/null 2>&1; then
        local warp_json=""
        warp_json="$(cat "$XMG_WARP_XRAY_OUTBOUND" 2>/dev/null || true)"
        if [ -n "$warp_json" ]; then
            local bak=""
            bak="$(_xmg_warp_backup_config "$xray_cfg")"
            [ -n "$bak" ] && xmg_info "已备份原始 Xray 配置至: $bak"

            local tmp_cfg="${xray_cfg}.tmp.$$.json"
            local jq_file="${xray_cfg}.tmp.$$.jq"

            if [ "$mode" = "global" ]; then
                # ===== 核心：全局清洁出站模式 =====
                # 将 warp-out 置于 outbounds 首位！所有节点公网出站流量默认全部由 WARP 清洁 IP 转发！
                # 宿主机本身 0 网卡 0 路由侵入，SSH 物理级绝对不可能变动或失联！
                # 附带安全规则：阻断私有内网 IP 探测 (geoip:private)
                cat > "$jq_file" << EOF_GLOBAL_JQ
(.outbounds = (
  [ $warp_json ] + [ (.outbounds // [])[] | select(.tag != "warp-out") ]
)) |
(.routing = (.routing // { "domainStrategy": "IPIfNonMatch", "rules": [] })) |
(.routing.domainStrategy = (.routing.domainStrategy // "IPIfNonMatch")) |
(.routing.rules = (
  [ (.routing.rules // [])[] | select((.outboundTag // "") != "warp-out" and (.ip // []) != ["geoip:private"]) ] + [
    {
      "type": "field",
      "outboundTag": "blocked",
      "ip": [
        "geoip:private"
      ]
    }
  ]
))
EOF_GLOBAL_JQ
            else
                # ===== 按需分流模式 =====
                cat > "$jq_file" << EOF_ROUTING_JQ
(.outbounds = (
  [ (.outbounds // [])[] | select(.tag != "warp-out") ] + [ $warp_json ]
)) |
(.routing = (.routing // { "domainStrategy": "IPIfNonMatch", "rules": [] })) |
(.routing.domainStrategy = (.routing.domainStrategy // "IPIfNonMatch")) |
(.routing.rules = (
  [ (.routing.rules // [])[] | select((.outboundTag // "") != "warp-out") ] + [
    {
      "type": "field",
      "outboundTag": "warp-out",
      "domain": [
        "domain:openai.com",
        "domain:chatgpt.com",
        "domain:oaistatic.com",
        "domain:oaiusercontent.com",
        "domain:sora.com",
        "domain:anthropic.com",
        "domain:claude.ai",
        "domain:gemini.google.com",
        "domain:bard.google.com",
        "domain:generativeai.googleapis.com",
        "domain:makersuite.google.com",
        "domain:deepmind.google",
        "domain:copilot.microsoft.com",
        "domain:perplexity.ai",
        "domain:pplx.ai",
        "domain:midjourney.com",
        "domain:groq.com",
        "domain:poe.com",
        "domain:cursor.com",
        "domain:cursor.sh",
        "domain:netflix.com",
        "domain:netflix.net",
        "domain:nflximg.net",
        "domain:nflxvideo.net",
        "domain:disneyplus.com",
        "domain:spotify.com"
      ]
    }
  ]
))
EOF_ROUTING_JQ
            fi

            if jq -f "$jq_file" < "$xray_cfg" > "$tmp_cfg" 2>/dev/null; then
                rm -f "$jq_file" 2>/dev/null || true
                if jq . < "$tmp_cfg" >/dev/null 2>&1; then
                    local xray_bin=""
                    if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
                        xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"
                    elif command -v xray >/dev/null 2>&1; then
                        xray_bin="$(command -v xray)"
                    fi

                    if [ -n "$xray_bin" ] && [ -x "$xray_bin" ] && [ "${XMG_TEST_MODE:-0}" != "1" ]; then
                        local test_out=""
                        if ! test_out="$("$xray_bin" run -test -format json -c "$tmp_cfg" 2>&1)"; then
                            xmg_error "Xray 内核校验新配置失败，取消应用:"
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
                    if [ "$mode" = "global" ]; then
                        xmg_info "Xray 配置增量补强完成: warp-out 已设为默认首选出站 (所有公网连接均经由 WARP 清洁 IP 出口)"
                    else
                        xmg_info "Xray 配置增量补强完成: 已接入 warp-out 并注入受限 AI/流媒体分流规则"
                    fi
                else
                    xmg_error "JSON 语法解析失败，取消应用"
                    rm -f "$tmp_cfg" 2>/dev/null || true
                    return 1
                fi
            else
                rm -f "$jq_file" "$tmp_cfg" 2>/dev/null || true
                xmg_error "jq 处理配置失败，取消应用"
                return 1
            fi
        fi
    fi

    # 5. 记录启用状态与模式
    mkdir -p "$(dirname "$XMG_WARP_ENV_FILE")"
    if [ -f "$XMG_WARP_ENV_FILE" ]; then
        sed -i '/^WARP_ENABLED=/d' "$XMG_WARP_ENV_FILE" 2>/dev/null || true
        sed -i '/^WARP_MODE=/d' "$XMG_WARP_ENV_FILE" 2>/dev/null || true
    fi
    echo "WARP_ENABLED=1" >> "$XMG_WARP_ENV_FILE"
    echo "WARP_MODE=$mode" >> "$XMG_WARP_ENV_FILE"

    # 6. 重启 Xray 应用变更
    if [ "${XMG_TEST_MODE:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        local s_name="${XMG_XRAY_SERVICE:-xray}"
        if systemctl is-active --quiet "$s_name" 2>/dev/null; then
            systemctl restart "$s_name" >/dev/null 2>&1 && xmg_info "已成功重启 $s_name 服务应用变更"
        fi
    fi

    xmg_info "WARP Socks5 本地回路中继已成功启用 (模式: $mode)！"
    return 0
}

xmg_warp_disable() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "正在停用 Cloudflare WARP 出站..."

    # 1. 停止本地守护服务
    _xmg_warp_service_stop

    # 2. 剔除 Xray 中的 warp-out 配置并还原原有出站
    local xray_cfg=""
    xray_cfg="$(_xmg_warp_find_xray_config)"
    xmg_info "定位到生效的 Xray 主配置文件: $xray_cfg"
    if [ -f "$xray_cfg" ] && command -v jq >/dev/null 2>&1; then
        local bak=""
        bak="$(_xmg_warp_backup_config "$xray_cfg")"
        [ -n "$bak" ] && xmg_info "已备份原始 Xray 配置至: $bak"

        local tmp_cfg="${xray_cfg}.tmp.$$.json"
        local jq_file="${xray_cfg}.tmp.$$.jq"
        cat > "$jq_file" << 'EOF_DISABLE_JQ'
(.outbounds = [ (.outbounds // [])[] | select(.tag != "warp-out") ]) |
(if (.routing and .routing.rules) then
   .routing.rules = [ .routing.rules[] | select((.outboundTag // "") != "warp-out") ]
 else . end)
EOF_DISABLE_JQ

        if jq -f "$jq_file" < "$xray_cfg" > "$tmp_cfg" 2>/dev/null; then
            rm -f "$jq_file" 2>/dev/null || true
            if jq . < "$tmp_cfg" >/dev/null 2>&1; then
                local xray_bin=""
                if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
                    xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"
                elif command -v xray >/dev/null 2>&1; then
                    xray_bin="$(command -v xray)"
                fi

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
                xmg_info "已从 Xray 配置中无损移除 warp-out 出站 (原生直连出站已恢复)"
            else
                rm -f "$tmp_cfg" 2>/dev/null || true
            fi
        else
            rm -f "$jq_file" "$tmp_cfg" 2>/dev/null || true
        fi
    fi

    # 3. 记录停用状态
    mkdir -p "$(dirname "$XMG_WARP_ENV_FILE")"
    if [ -f "$XMG_WARP_ENV_FILE" ]; then
        sed -i '/^WARP_ENABLED=/d' "$XMG_WARP_ENV_FILE" 2>/dev/null || true
        sed -i '/^WARP_MODE=/d' "$XMG_WARP_ENV_FILE" 2>/dev/null || true
    fi
    echo "WARP_ENABLED=0" >> "$XMG_WARP_ENV_FILE"

    # 4. 重启 Xray
    if [ "${XMG_TEST_MODE:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        local s_name="${XMG_XRAY_SERVICE:-xray}"
        if systemctl is-active --quiet "$s_name" 2>/dev/null; then
            systemctl restart "$s_name" >/dev/null 2>&1 && xmg_info "已重启 $s_name 服务应用变更"
        fi
    fi

    xmg_info "Cloudflare WARP 出站已关闭 (warp-out 已停用)"
    return 0
}

# ===== 全自动配置 =====

xmg_warp_auto_apply() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "=================================================================="
    xmg_info "正在执行 Cloudflare WARP 本地 Socks5 全局清洁出站极速配置..."
    xmg_info "核心目标: 彻底隐藏高污染本机 IP，全局默认走 WARP 清洁出口"
    xmg_info "架构设计: 本地 127.0.0.1:40000 进程中继，宿主机零网卡零路由侵入"
    xmg_info "防失联保证: SSH 物理级绝对不可能失联！"
    xmg_info "=================================================================="

    # 1. 物理机房与原生地理嗅探
    xmg_warp_detect_native_geo
    xmg_info "原生归属地感知: $(_xmg_warp_country_name "$XMG_WARP_NATIVE_LOC") [直连机房: $XMG_WARP_NATIVE_COLO]"

    # 2. 注册纯净凭据
    _xmg_warp_register 0 || return 1

    # 3. 本地机房低延迟 Anycast 端点优选并写入 wireproxy.conf
    xmg_warp_optimize_endpoint >/dev/null 2>&1 || true

    # 4. 导出出站并启用 (默认 global 全局模式)
    xmg_warp_enable "global" || return 1

    xmg_info "=================================================================="
    xmg_info "WARP 全局清洁出站配置就绪！"
    xmg_info "提示: 所有经由节点的公网访问已自动由 WARP 清洁 IP 转发！"
    xmg_info "=================================================================="
    return 0
}

# ===== 卸载与配置清理 =====

xmg_warp_uninstall() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "正在清理 WARP 配置与组件..."

    # 1. 关闭 Xray 出站与停止服务
    xmg_warp_disable >/dev/null 2>&1 || true
    _xmg_warp_service_stop

    # 2. 清理 WARP 目录
    if [ -d "$XMG_WARP_DIR" ]; then
        rm -rf "$XMG_WARP_DIR"
        xmg_info "已删除 WARP 数据目录: $XMG_WARP_DIR"
    fi

    # 3. 彻底清除可能存在的历史遗留 wg-quick 配置文件与服务
    if [ -f "/etc/wireguard/warp.conf" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop wg-quick@warp >/dev/null 2>&1 || true
            systemctl disable wg-quick@warp >/dev/null 2>&1 || true
        fi
        rm -f "/etc/wireguard/warp.conf"
        xmg_info "已清理历史遗留 /etc/wireguard/warp.conf"
    fi

    xmg_info "Cloudflare WARP 已彻底卸载并清理完毕"
    return 0
}

# ===== 状态看板 =====

xmg_warp_status() {
    echo "==================== WARP 运行状态与出口诊断 ===================="
    printf "架构模式        : Cloudflare WARP 本地 Socks5 回路中继 (%s:%s)\n" "$XMG_WARP_SOCKS_HOST" "$XMG_WARP_SOCKS_PORT"
    printf "防失联保护      : 宿主机 100%% 零网卡/零路由接管，SSH 物理级绝对不失联\n"

    local cur_mode="global (全局出站接管)"
    if [ -f "$XMG_WARP_ENV_FILE" ]; then
        local m=""
        m="$(grep '^WARP_MODE=' "$XMG_WARP_ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)"
        [ "$m" = "routing" ] && cur_mode="routing (仅受限 AI/流媒体分流)"
    fi
    printf "出站模式        : %s\n" "$cur_mode"

    local is_enabled=0
    if [ -f "$XMG_WARP_ENV_FILE" ] && grep -q '^WARP_ENABLED=1' "$XMG_WARP_ENV_FILE" 2>/dev/null; then
        is_enabled=1
    elif [ -f "$XMG_WARP_XRAY_OUTBOUND" ]; then
        is_enabled=1
    fi

    printf "服务状态        : "
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        echo "已启用 (Socks5 本地回路就绪)"
    elif [ "$is_enabled" -eq 1 ]; then
        echo "已启用 (Socks5 本地回路就绪)"
    else
        echo "未启用"
    fi

    if [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        local cur_v4 cur_ep_v4 cur_ep_v6
        cur_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)"
        cur_ep_v4="$(grep -o '"endpoint_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)"
        cur_ep_v6="$(grep -o '"endpoint_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)"
        printf "虚拟内网 IPv4   : %s\n" "${cur_v4:-未分配}"
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
        trace4="$(curl -x "socks5h://${XMG_WARP_SOCKS_HOST}:${XMG_WARP_SOCKS_PORT}" -4sSL --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || echo 'warp=off')"
        trace6="$(curl -x "socks5h://${XMG_WARP_SOCKS_HOST}:${XMG_WARP_SOCKS_PORT}" -6sSL --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || echo 'warp=off')"
    fi

    local ip4="" loc4="" colo4=""
    ip4="$(echo -e "$trace4" | grep -E '^ip=' | head -1 | cut -d= -f2)"
    loc4="$(echo -e "$trace4" | grep -E '^loc=' | head -1 | cut -d= -f2)"
    colo4="$(echo -e "$trace4" | grep -E '^colo=' | head -1 | cut -d= -f2)"

    local ip6="" loc6="" colo6=""
    ip6="$(echo -e "$trace6" | grep -E '^ip=' | head -1 | cut -d= -f2)"
    loc6="$(echo -e "$trace6" | grep -E '^loc=' | head -1 | cut -d= -f2)"
    colo6="$(echo -e "$trace6" | grep -E '^colo=' | head -1 | cut -d= -f2)"

    local warp_state="WARP: off"
    if echo -e "$trace4" | grep -q "warp=on" || echo -e "$trace4" | grep -q "warp=plus"; then
        warp_state="WARP: on"
    fi

    echo "-------------------- 公网出口与 Trace 诊断 --------------------"
    printf "Cloudflare Trace: %s\n" "$warp_state"
    printf "IPv4 网络出口   : %s (%s, 机房: %s)\n" "${ip4:-无 IPv4}" "${loc4:-未知}" "${colo4:-未知}"
    printf "IPv6 网络出口   : %s (%s, 机房: %s)\n" "${ip6:-无 IPv6}" "${loc6:-未知}" "${colo6:-未知}"

    xmg_warp_detect_native_geo

    local egress_loc="$loc4"
    local egress_colo="$colo4"
    [ -z "$egress_loc" ] && egress_loc="$loc6"
    [ -z "$egress_colo" ] && egress_colo="$colo6"

    echo "-------------------- 节点出口与清洁度诊断 --------------------"
    printf "VPS 本地原生地区: %s | 机房 Colo: %s\n" "$(_xmg_warp_country_name "$XMG_WARP_NATIVE_LOC")" "$XMG_WARP_NATIVE_COLO"
    printf "WARP 出口归属地区: %s | 机房 Colo: %s\n" "$(_xmg_warp_country_name "$egress_loc")" "${egress_colo:-未知}"

    local google_loc=""
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        google_loc="${XMG_MOCK_WARP_GOOGLE_LOC:-$egress_loc}"
    else
        google_loc="$(curl -sSL --connect-timeout 3 --max-time 4 "https://www.google.com" -o /dev/null -w "%{redirect_url}\n" 2>/dev/null | grep -oE 'google\.[a-z\.]+' | sed 's/google\.//' | tr '[:lower:]' '[:upper:]' || true)"
        [ -z "$google_loc" ] && google_loc="$egress_loc"
    fi
    printf "Google 权威地区 : %s\n" "$(_xmg_warp_country_name "$google_loc")"

    if [ -n "$XMG_WARP_NATIVE_LOC" ] && [ "$XMG_WARP_NATIVE_LOC" = "$egress_loc" ]; then
        echo "地区一致性判定  : 100% 保持本地一致 (PASS)"
    elif [ -z "$egress_loc" ] || [ "$egress_loc" = "UNKNOWN" ]; then
        echo "地区一致性判定  : 待检测 (WARP 未激活)"
    else
        echo "地区一致性判定  : 跨区漂移 (原生: $XMG_WARP_NATIVE_LOC -> 出口: $egress_loc) [WARN]"
    fi
    echo "=================================================================="
}

# ===== 流媒体与 IP 清洁度测试 =====

xmg_warp_test_unlock() {
    echo "==================== WARP 流媒体与 IP 清洁度测试 ===================="
    echo "正在测试常见平台连通性与解锁状态，请稍候..."
    echo

    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        echo "GitHub (连通性)       : 正常连通"
        echo "Google (搜索连通性)   : 正常 (HTTP 200, WARP 清洁 IP)"
        echo "ChatGPT / OpenAI      : 可用 (HTTP 200, WARP 解锁成功)"
        echo "Netflix (流媒体)      : 完全解锁 (HTTP 200)"
        return 0
    fi

    printf "Google (搜索连通性)   : "
    local g_code=""
    g_code="$(curl -x "socks5h://${XMG_WARP_SOCKS_HOST}:${XMG_WARP_SOCKS_PORT}" -sSL -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 6 "https://www.google.com" 2>/dev/null || echo "000")"
    if [ "$g_code" = "200" ]; then
        echo "正常 (HTTP 200, 无人机验证码, 清洁度优)"
    elif [ "$g_code" = "000" ]; then
        echo "连接失败 (超时或 WARP 未就绪)"
    else
        echo "返回码 HTTP $g_code"
    fi

    printf "ChatGPT / OpenAI      : "
    local oai_code=""
    oai_code="$(curl -x "socks5h://${XMG_WARP_SOCKS_HOST}:${XMG_WARP_SOCKS_PORT}" -sSL -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 6 "https://chatgpt.com" 2>/dev/null || echo "000")"
    if [ "$oai_code" = "200" ] || [ "$oai_code" = "307" ] || [ "$oai_code" = "308" ]; then
        echo "可用 (HTTP $oai_code, WARP 成功解封)"
    elif [ "$oai_code" = "000" ]; then
        echo "连接超时 (WARP 本地中继未响应)"
    else
        echo "返回码 HTTP $oai_code"
    fi

    printf "Netflix (流媒体)      : "
    local nflx_code=""
    nflx_code="$(curl -x "socks5h://${XMG_WARP_SOCKS_HOST}:${XMG_WARP_SOCKS_PORT}" -sSL -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 6 "https://www.netflix.com/title/80018499" 2>/dev/null || echo "000")"
    if [ "$nflx_code" = "200" ]; then
        echo "完全解锁 (HTTP 200, 原生/自制剧均可)"
    elif [ "$nflx_code" = "000" ]; then
        echo "连接超时"
    else
        echo "返回码 HTTP $nflx_code"
    fi

    printf "GitHub (访问测试)     : "
    local gh_code=""
    gh_code="$(curl -x "socks5h://${XMG_WARP_SOCKS_HOST}:${XMG_WARP_SOCKS_PORT}" -sSL -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 6 "https://api.github.com" 2>/dev/null || echo "000")"
    if [ "$gh_code" = "200" ]; then
        echo "正常连通 (HTTP 200)"
    else
        echo "连接失败 (HTTP $gh_code)"
    fi
    echo "====================================================================="
}

# ===== 交互菜单 =====

xmg_warp_menu() {
    local choice=""

    while true; do
        clear
        echo "========== WARP 本地 Socks5 回路中继管理 =========="
        echo "架构设计: 本地 127.0.0.1:40000 进程中继，宿主机零网卡零路由侵入"
        echo "模式说明: 默认【全局清洁出站接管】，彻底解决 VPS 本机 IP 污染严重问题"
        echo "----------------------------------------------------"
        echo "1. 一键全自动极速配置 (默认全局清洁出站接管)"
        echo "2. 启用 WARP【全局清洁出站】(所有公网出站走 WARP 清洁出口)"
        echo "3. 启用 WARP【按需精准分流】(仅受限 AI/流媒体走 WARP，其余直连)"
        echo "4. 关闭 WARP 出站 (剔除 Xray WARP 出站并停用本地中继)"
        echo "5. 查看 WARP 运行状态与公网出口"
        echo "6. 执行本地原生机房 Anycast 端点低延迟优选"
        echo "7. 测试流媒体与 AI (ChatGPT / Netflix / Google) 解锁"
        echo "8. 导出 / 查看 Xray Socks5 出站配置片段"
        echo "9. 重新向 Cloudflare 注册新 WARP 凭据"
        echo "10. 彻底卸载 WARP 配置与组件"
        echo "0. 返回主菜单"
        echo
        printf "请选择 [0-10]: "

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

# ===== 直接执行支持 =====
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    xmg_warp_menu
fi
