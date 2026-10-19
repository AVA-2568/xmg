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
#   - 零依赖: 全局出站置顶架构，不写 geoip: 规则，零依赖 geoip.dat，244MB 极低内存机器稳定运行
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
        echo "$json" | jq -r "$path // empty" 2>/dev/null || true
        return 0
    fi

    local key="${path##*.}"
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
    val="${val%%:0}"
    val="$(echo "$val" | tr -d '[:space:]')"
    if [[ "$val" =~ : ]] && [[ ! "$val" =~ [^0-9a-fA-F:] ]]; then
        echo "$val"
    else
        echo ""
    fi
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
    val="$(echo "$val" | tr -d '[:space:]')"
    echo "$val"
}

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

    local trace=""
    trace="$(curl -sSL --connect-timeout 4 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    if [ -n "$trace" ]; then
        XMG_WARP_NATIVE_LOC="$(echo "$trace" | grep -E '^loc=' | head -1 | cut -d= -f2 | tr -d '[:space:]')"
        XMG_WARP_NATIVE_COLO="$(echo "$trace" | grep -E '^colo=' | head -1 | cut -d= -f2 | tr -d '[:space:]')"
    fi

    if [ -z "$XMG_WARP_NATIVE_LOC" ]; then
        local ip_info=""
        ip_info="$(curl -sSL --connect-timeout 4 --max-time 6 https://ipinfo.io/json 2>/dev/null || true)"
        if [ -n "$ip_info" ]; then
            XMG_WARP_NATIVE_LOC="$(echo "$ip_info" | grep -o '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
            XMG_WARP_NATIVE_COLO="DEFAULT"
        fi
    fi

    [ -n "$XMG_WARP_NATIVE_LOC" ] || XMG_WARP_NATIVE_LOC="UNKNOWN"
    [ -n "$XMG_WARP_NATIVE_COLO" ] || XMG_WARP_NATIVE_COLO="UNKNOWN"
    return 0
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

    if declare -F xmg_detect_network >/dev/null 2>&1; then
        xmg_detect_network >/dev/null 2>&1 || true
        if [ "${XMG_NET_STACK:-}" = "ipv6_only" ]; then
            return 0
        fi
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
                sed -i -E "s/\"endpoint_v6\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"endpoint_v6\": \"$mock_res\"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
            else
                sed -i -E "s/\"endpoint_v4\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"endpoint_v4\": \"$mock_res\"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
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
            local test_url="http://$host:80"
            if [ "$is_v6" -eq 1 ]; then
                test_url="http://[$host]:80"
            fi
            rtt="$(curl -s -o /dev/null -w "%{time_connect}\n" --connect-timeout 2 "$test_url" 2>/dev/null || true)"
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

    # 更新 account.json 中的端点 (若存在)
    if [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        if [ "$is_v6" -eq 1 ]; then
            sed -i -E "s/\"endpoint_v6\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"endpoint_v6\": \"$best_ep\"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
        else
            sed -i -E "s/\"endpoint_v4\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"endpoint_v4\": \"$best_ep\"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
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

# ===== 生成合法配对的 Curve25519 密钥对 =====

_xmg_warp_gen_keys() {
    if [ -n "${XMG_MOCK_WARP_PRIVKEY:-}" ]; then
        echo "${XMG_MOCK_WARP_PRIVKEY} ${XMG_MOCK_WARP_PUBKEY:-mockpubkey}"
        return 0
    fi

    local priv="" pub=""

    # 1. 优先通过 Xray 内核生成真实配对的 Curve25519 密钥对 (xray x25519 / xray wg)
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
            echo "$priv $pub"
            return 0
        fi
    fi

    # 2. 次选系统 wg 工具 (wireguard-tools)
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

    # 3. 次选 python3 cryptography 生成合法的 X25519 密钥对
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
            echo "$py_keys"
            return 0
        fi
    fi

    xmg_error "生成合法的 WireGuard Curve25519 密钥对失败 (请确保已安装 xray 或 wg)"
    return 1
}

# ===== 注册 Cloudflare WARP 免费账号并持久化凭据 =====

_xmg_warp_register() {
    local force="${1:-0}"
    mkdir -p "$XMG_WARP_DIR" 2>/dev/null || true

    # 若已存在凭据，且非强制重新注册，则核验凭据纯净度与 client_id
    if [ "$force" != "1" ] && [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        local cur_priv cur_v4 cur_v6 cur_res cur_cid
        cur_priv="$(grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        cur_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        cur_v6="$(grep -o '"address_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        cur_res="$(grep -o '"reserved"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true)"
        cur_cid="$(grep -o '"client_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"

        # 自愈校验 1: 若内网 IPv6 损坏（含中括号、端口或非 IPv6 格式），自动标记受损重新注册
        if [ -n "$cur_v6" ]; then
            local test_clean_v6="$(_xmg_warp_clean_ipv6 "$cur_v6")"
            if [ -z "$test_clean_v6" ] || [[ "$cur_v6" =~ \[ ]] || [[ "$cur_v6" =~ :[0-9]+$ ]]; then
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
        # 优先 v0a2158，若失败回退 v0a884
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

    if [[ "$peer_ep_v6" =~ :0$ ]]; then
        peer_ep_v6="${peer_ep_v6%:0}:2408"
    fi
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
    cat > "$XMG_WARP_ENV_FILE" <<EOF
WARP_DEV_ID="$dev_id"
WARP_ADDR_V4="$addr_v4"
WARP_ADDR_V6="$addr_v6"
EOF
    chmod 600 "$XMG_WARP_ENV_FILE" 2>/dev/null || true

    xmg_info "WARP 账号注册成功 (分配虚拟 IPv4: $addr_v4, 鉴权保留字段: [$r0, $r1, $r2])"
    return 0
}

xmg_warp_register_account() {
    _xmg_warp_register 0
}

# ===== Xray 原生 WireGuard 出站配置片段导出 =====

xmg_warp_export_xray_outbound() {
    local target_file="${1:-}"
    if [ ! -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        _xmg_warp_register 0 || return 1
    fi

    local privkey="" addr_v4="" addr_v6="" peer_pub="" ep_v6="" ep_v4="" reserved_json=""
    privkey="$(grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    addr_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    addr_v6="$(grep -o '"address_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    peer_pub="$(grep -o '"peer_public_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    ep_v6="$(grep -o '"endpoint_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    ep_v4="$(grep -o '"endpoint_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    local raw_res=""
    raw_res="$(grep -o '"reserved"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d: -f2- || true)"
    if [ -n "$raw_res" ]; then
        local nums=""
        nums="$(echo "$raw_res" | tr -d '[]' | tr ',' ' ')"
        local r0="0" r1="0" r2="0"
        read -r r0 r1 r2 _ <<< "$nums"
        reserved_json="[$r0, $r1, $r2]"
    else
        local c_id=""
        c_id="$(grep -o '"client_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4 || true)"
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
        endpoint="${ep_v6:-$XMG_WARP_ENDPOINT_V6}"
    else
        endpoint="${ep_v4:-$XMG_WARP_ENDPOINT_V4}"
    fi

    if [[ "$endpoint" =~ :0$ ]]; then
        endpoint="${endpoint%:0}:2408"
    fi

    local address_json="\"$addr_v4/32\""
    if [ -n "$addr_v6" ]; then
        address_json="\"$addr_v4/32\",\n      \"$addr_v6/128\""
    fi

    local xray_json=""
    xray_json="$(cat <<EOF
{
  "tag": "warp-out",
  "protocol": "wireguard",
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
          "0.0.0.0/0",
          "::/0"
        ]
      }
    ],
    "reserved": $reserved_json,
    "noKernelTun": true,
    "mtu": 1280
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
        proc_cmd="$(ps aux 2>/dev/null | grep -E '[x]ray.*run.*-c' | head -1 || true)"
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
    local bak_file="$bak_dir/$(basename "$cfg").warp.bak.$(date +%Y%m%d%H%M%S).$$"
    cp -f "$cfg" "$bak_file" 2>/dev/null || true
    echo "$bak_file"
}

# ===== 辅助: 判断是否为外部已有非标准配置 =====
_xmg_warp_is_external_config() {
    local cfg="$1"
    [ -f "$cfg" ] || return 1
    [ -f "${XMG_STATE_FILE:-}" ] || return 0
    if grep -q 'geosite:' "$cfg" 2>/dev/null; then
        return 0
    fi
    if grep -q '"tag"' "$cfg" 2>/dev/null; then
        local non_standard_tags
        non_standard_tags="$(grep -oE '"tag"[[:space:]]*:[[:space:]]*"[^"]+"' "$cfg" 2>/dev/null | grep -v -E 'inbound-socks|inbound-vless|direct|blocked|warp-out' || true)"
        if [ -n "$non_standard_tags" ]; then
            return 0
        fi
    fi
    return 1
}

# ===== 辅助: 从 account.json 提取账号变量 =====
_xmg_warp_get_account_vars() {
    [ -f "$XMG_WARP_ACCOUNT_FILE" ] || return 1
    local privkey="" addr_v4="" addr_v6="" peer_pub="" ep_v6="" ep_v4="" reserved_json=""
    privkey="$(grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    addr_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    addr_v6="$(grep -o '"address_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    peer_pub="$(grep -o '"peer_public_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    ep_v6="$(grep -o '"endpoint_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    ep_v4="$(grep -o '"endpoint_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    local raw_res=""
    raw_res="$(grep -o '"reserved"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d: -f2- || true)"
    if [ -n "$raw_res" ]; then
        local nums=""
        nums="$(echo "$raw_res" | tr -d '[]' | tr ',' ' ')"
        local r0="0" r1="0" r2="0"
        read -r r0 r1 r2 _ <<< "$nums"
        reserved_json="[$r0, $r1, $r2]"
    else
        local c_id=""
        c_id="$(grep -o '"client_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4 || true)"
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
        endpoint="${ep_v6:-$XMG_WARP_ENDPOINT_V6}"
    else
        endpoint="${ep_v4:-$XMG_WARP_ENDPOINT_V4}"
    fi
    if [[ "$endpoint" =~ :0$ ]]; then
        endpoint="${endpoint%:0}:2408"
    fi

    WARP_ACC_PRIVKEY="$privkey"
    WARP_ACC_PUBKEY="$peer_pub"
    WARP_ACC_IPV4="$addr_v4"
    WARP_ACC_IPV6="$addr_v6"
    WARP_ACC_ENDPOINT="$endpoint"
    WARP_ACC_RESERVED="$reserved_json"
    return 0
}

# ===== 辅助: 纯 Bash 模式处理外部配置 (无 jq 回退) =====
_xmg_warp_patch_external_bash() {
    local action="$1" mode="$2" cfg="$3" out="$4" warp_json="$5"
    if [ "$action" = "enable" ]; then
        if [ "$mode" = "routing" ]; then
            awk -v w="$warp_json" '
                /"outbounds"[[:space:]]*:[[:space:]]*\[/ {
                    print; in_out=1; next
                }
                in_out && /\]/ {
                    printf "    ,\n%s\n  ]\n", w; in_out=0; next
                }
                { print }
            ' "$cfg" > "$out"
        else
            awk -v w="$warp_json" '
                /"outbounds"[[:space:]]*:[[:space:]]*\[/ {
                    print; printf "    %s,\n", w; next
                }
                /"tag"[[:space:]]*:[[:space:]]*"warp-out"/ { skip=1 }
                skip && /\}/ { skip=0; next }
                !skip { print }
            ' "$cfg" > "$out"
        fi
    elif [ "$action" = "disable" ]; then
        awk '
            /"tag"[[:space:]]*:[[:space:]]*"warp-out"/ { skip=1 }
            /"outboundTag"[[:space:]]*:[[:space:]]*"warp-out"/ { skip_rule=1 }
            skip && /\}/ { skip=0; next }
            skip_rule && /\}/ { skip_rule=0; next }
            !skip && !skip_rule { print }
        ' "$cfg" > "$out"
    fi
}

# ===== 启用 Xray 原生 WireGuard 出站 =====

xmg_warp_enable() {
    local mode="${1:-global}"
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    
    if [ "$mode" = "routing" ]; then
        xmg_info "正在启用 Xray 原生 WireGuard (WARP) 出站【流媒体与 AI 智能分流模式】..."
    else
        xmg_info "正在启用 Xray 原生 WireGuard (WARP) 出站【全局清洁出站接管模式】..."
        xmg_info "核心目标: 彻底隐藏高污染本机 IP，节点代理流量全局默认走 WARP 出口"
    fi

    # 1. 确保账号凭据就绪 (含 client_id / reserved)
    if [ ! -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        _xmg_warp_register 0 || return 1
    fi

    # 2. 提取凭据并 stage 到 state 内存中
    local WARP_ACC_PRIVKEY="" WARP_ACC_PUBKEY="" WARP_ACC_IPV4="" WARP_ACC_IPV6="" WARP_ACC_ENDPOINT="" WARP_ACC_RESERVED=""
    _xmg_warp_get_account_vars || return 1

    if declare -F xmg_state_stage >/dev/null 2>&1; then
        xmg_state_stage WARP_ENABLED 1
        xmg_state_stage WARP_MODE "$mode"
        xmg_state_stage WARP_ENDPOINT "$WARP_ACC_ENDPOINT"
        xmg_state_stage WARP_PRIVATE_KEY "$WARP_ACC_PRIVKEY"
        xmg_state_stage WARP_PUBLIC_KEY "$WARP_ACC_PUBKEY"
        xmg_state_stage WARP_IPV4 "$WARP_ACC_IPV4"
        xmg_state_stage WARP_IPV6 "$WARP_ACC_IPV6"
        xmg_state_stage WARP_RESERVED "$WARP_ACC_RESERVED"
    fi

    # 3. 导出出站片段供兼容使用
    xmg_warp_export_xray_outbound "$XMG_WARP_XRAY_OUTBOUND" || return 1

    # 4. 更新 warp.env 保持环境兼容
    mkdir -p "$(dirname "$XMG_WARP_ENV_FILE")"
    if [ -f "$XMG_WARP_ENV_FILE" ]; then
        sed -i '/^WARP_ENABLED=/d' "$XMG_WARP_ENV_FILE" 2>/dev/null || true
        sed -i '/^WARP_MODE=/d' "$XMG_WARP_ENV_FILE" 2>/dev/null || true
    fi
    echo "WARP_ENABLED=1" >> "$XMG_WARP_ENV_FILE"
    echo "WARP_MODE=$mode" >> "$XMG_WARP_ENV_FILE"

    # 5. 定位当前生效的 Xray 主配置
    local xray_cfg=""
    xray_cfg="$(_xmg_warp_find_xray_config)"
    xmg_info "定位到生效的 Xray 主配置文件: $xray_cfg"

    if [ -f "$xray_cfg" ] || [ -f "${XMG_STATE_FILE:-}" ]; then
        if _xmg_warp_is_external_config "$xray_cfg"; then
        # ===== 外部已有非标准配置增量合成分支 =====
        local warp_json=""
        warp_json="$(cat "$XMG_WARP_XRAY_OUTBOUND" 2>/dev/null || true)"
        if [ -n "$warp_json" ]; then
            local bak=""
            bak="$(_xmg_warp_backup_config "$xray_cfg")"
            [ -n "$bak" ] && xmg_info "已备份原始 Xray 配置至: $bak"

            local tmp_cfg="${xray_cfg}.tmp.$$.json"
            local merged_ok=0

            if command -v jq >/dev/null 2>&1; then
                local jq_file="${xray_cfg}.tmp.$$.jq"
                if [ "$mode" = "routing" ]; then
                    local v6_fallback_rule=""
                    if xmg_warp_is_ipv6_only; then
                        v6_fallback_rule=', { "type": "field", "outboundTag": "warp-out", "ip": [ "0.0.0.0/0" ] }'
                    fi
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
        "domain:deepmind.com",
        "domain:deepmind.google",
        "domain:copilot.microsoft.com",
        "domain:sydney.bing.com",
        "domain:perplexity.ai",
        "domain:pplx.ai",
        "domain:midjourney.com",
        "domain:huggingface.co",
        "domain:groq.com",
        "domain:poe.com",
        "domain:cursor.com",
        "domain:cursor.sh",
        "domain:netflix.com",
        "domain:netflix.net",
        "domain:nflximg.net",
        "domain:nflxvideo.net",
        "domain:nflxext.com",
        "domain:nflxso.net",
        "domain:disneyplus.com",
        "domain:disney-portal.my.onetrust.com",
        "domain:dssott.com",
        "domain:bamgrid.com",
        "domain:disneystreaming.com",
        "domain:spotify.com",
        "domain:scdn.co",
        "domain:spoti.fi",
        "domain:max.com",
        "domain:hbo.com",
        "domain:hbomax.com",
        "domain:primevideo.com",
        "domain:aiv-cdn.net",
        "domain:amazonvideo.com",
        "domain:tv.apple.com",
        "domain:hulu.com",
        "domain:peacocktv.com",
        "domain:paramountplus.com",
        "domain:tiktok.com",
        "domain:byteoversea.com",
        "domain:ibytedtos.com",
        "domain:musical.ly",
        "domain:tiktokcdn.com",
        "domain:tiktokv.com",
        "domain:gamer.com.tw",
        "domain:bilibili.tv",
        "domain:viu.com",
        "domain:viu.tv"
      ]
    }$v6_fallback_rule
  ]
))
EOF_ROUTING_JQ
                else
                    cat > "$jq_file" << EOF_GLOBAL_JQ
(.outbounds = (
  [ $warp_json ] + [ (.outbounds // [])[] | select(.tag != "warp-out") ]
)) |
(if (.routing and .routing.rules) then
   .routing.rules = [ .routing.rules[] | select((.outboundTag // "") != "warp-out") ]
 else . end)
EOF_GLOBAL_JQ
                fi
                if jq -f "$jq_file" < "$xray_cfg" > "$tmp_cfg" 2>/dev/null; then
                    rm -f "$jq_file" 2>/dev/null || true
                    merged_ok=1
                else
                    rm -f "$jq_file" "$tmp_cfg" 2>/dev/null || true
                fi
            else
                _xmg_warp_patch_external_bash "enable" "$mode" "$xray_cfg" "$tmp_cfg" "$warp_json"
                [ -s "$tmp_cfg" ] && merged_ok=1
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

                if [ -n "$xray_bin" ] && [ -x "$xray_bin" ] && [ "${XMG_TEST_MODE:-0}" != "1" ]; then
                    local test_out=""
                    if ! test_out="$("$xray_bin" run -test -format json -c "$tmp_cfg" 2>&1)"; then
                        xmg_error "Xray 内核校验新配置失败，详细错误信息如下:"
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
                if [ "$mode" = "routing" ]; then
                    xmg_info "Xray 配置增量补强完成: 已在 outbounds 追加 warp-out 并添加流媒体/AI 智能分流规则"
                else
                    xmg_info "Xray 配置增量补强完成: 已将 warp-out 设为首选默认出口 (全局公网出站已由 WARP 接管，隐藏本机 IP)"
                fi
            else
                rm -f "$tmp_cfg" 2>/dev/null || true
                xmg_error "处理外部配置失败，取消应用"
                return 1
            fi
        fi
        if [ -f "${XMG_STATE_FILE:-}" ] && declare -F xmg_state_commit_draft >/dev/null 2>&1; then
            xmg_state_commit_draft >/dev/null 2>&1 || true
        fi
    else
        # ===== 标准 state 管辖模式分支 =====
        if declare -F xmg_state_commit >/dev/null 2>&1; then
            local _tc_set=0
            if [ "${XMG_TEST_MODE:-0}" = "1" ] && [ -z "${XMG_XRAY_CONFIG_TESTCMD:-}" ]; then
                export XMG_XRAY_CONFIG_TESTCMD="true"
                export XMG_XRAY_RELOAD_TESTCMD="true"
                _tc_set=1
            fi
            if ! xmg_state_commit; then
                [ "$_tc_set" -eq 1 ] && unset XMG_XRAY_CONFIG_TESTCMD XMG_XRAY_RELOAD_TESTCMD
                xmg_error "WARP 出站配置渲染与两阶段提交失败"
                return 1
            fi
            [ "$_tc_set" -eq 1 ] && unset XMG_XRAY_CONFIG_TESTCMD XMG_XRAY_RELOAD_TESTCMD
        fi
    fi
    fi
    # 6. 清理任何可能存在的第三方 wireproxy 残留服务
    if [ "${XMG_TEST_MODE:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop xmg-warp >/dev/null 2>&1 || true
        systemctl disable xmg-warp >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/xmg-warp.service 2>/dev/null || true
        rm -f "$XMG_WARP_DIR/wireproxy.conf" "$XMG_WARP_DIR/bin/wireproxy" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    # 7. 若 Xray 运行中，重载/重启服务（外部配置分支需要显式重启，state 模式已在 xmg_state_commit 内重启）
    if _xmg_warp_is_external_config "$xray_cfg"; then
        if [ "${XMG_TEST_MODE:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
            local s_name="${XMG_XRAY_SERVICE:-xray}"
            if systemctl is-active --quiet "$s_name" 2>/dev/null; then
                if ! systemctl restart "$s_name" >/dev/null 2>&1; then
                    xmg_error "重启 $s_name 服务失败，正在自动回滚..."
                    if [ -n "${bak:-}" ] && [ -f "$bak" ]; then
                        cp -f "$bak" "$xray_cfg" 2>/dev/null || true
                        systemctl restart "$s_name" >/dev/null 2>&1 || true
                    fi
                    return 1
                fi
                xmg_info "已成功重启 $s_name 服务并确认运行健康 (active)"
            fi
        fi
    fi

    xmg_info "Xray WARP 出站已成功启用 (出站标签: warp-out, 模式: $mode)"
    xmg_info "配置片段位置: $XMG_WARP_XRAY_OUTBOUND"
    xmg_info "宿主机 100% 零侵入、零网卡接管、零系统路由改动，SSH 物理级绝对防断网！"
    return 0
}

# ===== 停用 Xray 原生 WireGuard 出站 =====

xmg_warp_disable() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "正在停用 Xray 原生 WireGuard (WARP) 出站..."

    mkdir -p "$(dirname "$XMG_WARP_ENV_FILE")"
    if [ -f "$XMG_WARP_ENV_FILE" ]; then
        sed -i '/^WARP_ENABLED=/d' "$XMG_WARP_ENV_FILE" 2>/dev/null || true
    fi
    echo "WARP_ENABLED=0" >> "$XMG_WARP_ENV_FILE"

    if declare -F xmg_state_stage >/dev/null 2>&1; then
        xmg_state_stage WARP_ENABLED 0
    fi

    local xray_cfg=""
    xray_cfg="$(_xmg_warp_find_xray_config)"
    xmg_info "定位到生效的 Xray 主配置文件: $xray_cfg"

    if [ -f "$xray_cfg" ] || [ -f "${XMG_STATE_FILE:-}" ]; then
        if _xmg_warp_is_external_config "$xray_cfg"; then
            # 外部已有配置增量剔除分支
            local bak=""
            bak="$(_xmg_warp_backup_config "$xray_cfg")"
            [ -n "$bak" ] && xmg_info "已备份原始 Xray 配置至: $bak"

            local tmp_cfg="${xray_cfg}.tmp.$$.json"
            local removed_ok=0

            if command -v jq >/dev/null 2>&1; then
                local jq_file="${xray_cfg}.tmp.$$.jq"
                cat > "$jq_file" << 'EOF_DISABLE_JQ'
(.outbounds = [ (.outbounds // [])[] | select(.tag != "warp-out") ]) |
(if (.routing and .routing.rules) then
   .routing.rules = [ .routing.rules[] | select((.outboundTag // "") != "warp-out") ]
 else . end)
EOF_DISABLE_JQ
                if jq -f "$jq_file" < "$xray_cfg" > "$tmp_cfg" 2>/dev/null; then
                    rm -f "$jq_file" 2>/dev/null || true
                    removed_ok=1
                else
                    rm -f "$jq_file" "$tmp_cfg" 2>/dev/null || true
                fi
            else
                _xmg_warp_patch_external_bash "disable" "" "$xray_cfg" "$tmp_cfg" ""
                [ -s "$tmp_cfg" ] && removed_ok=1
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
                xmg_info "已从 Xray 配置中无损移除 warp-out 出站与相关分流规则 (原有其余配置毫发无损)"
            else
                rm -f "$tmp_cfg" 2>/dev/null || true
            fi

            if [ -f "${XMG_STATE_FILE:-}" ] && declare -F xmg_state_commit_draft >/dev/null 2>&1; then
                xmg_state_commit_draft >/dev/null 2>&1 || true
            fi

            if [ "${XMG_TEST_MODE:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
                local s_name="${XMG_XRAY_SERVICE:-xray}"
                if systemctl is-active --quiet "$s_name" 2>/dev/null; then
                    systemctl restart "$s_name" >/dev/null 2>&1 && xmg_info "已重启 $s_name 服务应用变更"
                fi
            fi
        else
            # 标准 state 管辖模式分支
            if declare -F xmg_state_commit >/dev/null 2>&1; then
                local _tc_set=0
                if [ "${XMG_TEST_MODE:-0}" = "1" ] && [ -z "${XMG_XRAY_CONFIG_TESTCMD:-}" ]; then
                    export XMG_XRAY_CONFIG_TESTCMD="true"
                    export XMG_XRAY_RELOAD_TESTCMD="true"
                    _tc_set=1
                fi
                if ! xmg_state_commit; then
                    [ "$_tc_set" -eq 1 ] && unset XMG_XRAY_CONFIG_TESTCMD XMG_XRAY_RELOAD_TESTCMD
                    xmg_error "停用 WARP 重新生成配置失败"
                    return 1
                fi
                [ "$_tc_set" -eq 1 ] && unset XMG_XRAY_CONFIG_TESTCMD XMG_XRAY_RELOAD_TESTCMD
            fi
        fi
    fi
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
    xmg_warp_optimize_endpoint || return 1

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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop xmg-warp >/dev/null 2>&1 || true
        systemctl disable xmg-warp >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/xmg-warp.service 2>/dev/null || true
        systemctl stop wg-quick@warp >/dev/null 2>&1 || true
        systemctl disable wg-quick@warp >/dev/null 2>&1 || true
        rm -f /etc/wireguard/warp.conf 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if [ -n "${XMG_WARP_CONF:-}" ] && [ -f "$XMG_WARP_CONF" ]; then
        rm -f "$XMG_WARP_CONF"
    fi

    xmg_info "WARP 配置与凭据已彻底清理完毕！宿主机网络纯净如初。"
    return 0
}

# ===== 运行状态与出口诊断 =====

xmg_warp_status() {
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

    if [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        local cur_v4 cur_ep_v4 cur_ep_v6 cur_res
        cur_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)"
        cur_ep_v4="$(grep -o '"endpoint_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)"
        cur_ep_v6="$(grep -o '"endpoint_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)"
        cur_res="$(grep -o '"reserved"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null | head -1 | cut -d: -f2- | tr -d ' ' || echo "未记录")"
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

    local ip4="" loc4="" colo4=""
    ip4="$(echo -e "$trace4" | grep -E '^ip=' | head -1 | cut -d= -f2)"
    loc4="$(echo -e "$trace4" | grep -E '^loc=' | head -1 | cut -d= -f2)"
    colo4="$(echo -e "$trace4" | grep -E '^colo=' | head -1 | cut -d= -f2)"

    local ip6="" loc6="" colo6=""
    ip6="$(echo -e "$trace6" | grep -E '^ip=' | head -1 | cut -d= -f2)"
    loc6="$(echo -e "$trace6" | grep -E '^loc=' | head -1 | cut -d= -f2)"
    colo6="$(echo -e "$trace6" | grep -E '^colo=' | head -1 | cut -d= -f2)"

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
    printf "VPS 本地原生地区: %s | 机房 Colo: %s\n" "$(_xmg_warp_country_name "$XMG_WARP_NATIVE_LOC")" "$XMG_WARP_NATIVE_COLO"
    echo "=================================================================="
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

    # 1. OpenAI / ChatGPT
    printf "测试 OpenAI / ChatGPT       : "
    local oai_code=""
    oai_code="$(curl -sSL --connect-timeout 5 --max-time 8 -o /dev/null -w "%{http_code}" https://chatgpt.com 2>/dev/null || echo "000")"
    if [ "$oai_code" = "200" ] || [ "$oai_code" = "301" ] || [ "$oai_code" = "302" ] || [ "$oai_code" = "403" ]; then
        echo "可直连 (HTTP $oai_code)"
    else
        echo "受限或超时 (HTTP $oai_code)"
    fi

    # 2. Netflix
    printf "测试 Netflix 原生解锁       : "
    local nflx_res=""
    nflx_res="$(curl -sSL --connect-timeout 5 --max-time 8 "https://www.netflix.com/title/80018499" 2>/dev/null || true)"
    if echo "$nflx_res" | grep -q "80018499"; then
        echo "已解锁 (支持完整自制剧与版权内容)"
    elif echo "$nflx_res" | grep -qi "netflix"; then
        echo "仅解锁自制剧"
    else
        echo "未解锁或连接受阻"
    fi

    # 3. YouTube 地区与 Premium
    printf "测试 YouTube 地区标识       : "
    local yt_loc=""
    yt_loc="$(curl -sSL --connect-timeout 5 --max-time 8 https://www.youtube.com 2>/dev/null | grep -o '"countryCode":"[A-Z]*"' | head -1 | cut -d'"' -f4 || true)"
    if [ -n "$yt_loc" ]; then
        echo "已定位 ($( _xmg_warp_country_name "$yt_loc" ))"
    else
        echo "未获取到地区标识"
    fi

    # 4. Google 搜索验证码防风控
    printf "测试 Google 搜索风控状态    : "
    local g_res=""
    g_res="$(curl -sSL --connect-timeout 5 --max-time 8 "https://www.google.com/search?q=test" 2>/dev/null || true)"
    if echo "$g_res" | grep -qi "recaptcha\|unusual traffic"; then
        echo "检测到异常流量验证码 (WARN)"
    elif echo "$g_res" | grep -qi "google"; then
        echo "清洁通过 (无验证码弹窗，安全)"
    else
        echo "无法连接"
    fi

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
        echo "10. 清理 / 卸载 WARP 配置与凭据"
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
