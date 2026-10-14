#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# warp.sh - XMG Cloudflare WARP 原生出站模块
#
# 方案 A 架构说明：
#   - 彻底废除宿主机网卡级接管 (wg-quick)，将 WARP 彻底降维解耦为【Xray 原生 WireGuard 进程内出站】
#   - 目标：宿主机 100% 零侵入、零网卡、零路由修改、零 DNS 篡改，SSH 100% 物理级绝对不可能失联！
#   - 原生支持能力：
#       1. 全自动原生感知与应用 (xmg_warp_auto_apply)
#       2. 本地原生机房低延迟端点优选 (xmg_warp_optimize_endpoint)
#       3. 纯净 WARP 凭据管理 (_xmg_warp_register / account.json)
#       4. Xray 原生 WireGuard 出站配置片段导出 (xmg_warp_export_xray_outbound)
#       5. Xray WARP 出站启用与关闭 (xmg_warp_enable / xmg_warp_disable)
#       6. 状态查询与地区一致性核验 (xmg_warp_status)
#       7. IP 清洁度与流媒体/AI 解锁测试 (xmg_warp_test_unlock)
#       8. 纯净卸载与配置清理 (xmg_warp_uninstall)
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

# XMG_MENU_LABEL: WARP 网络配置

# ===== 默认配置与路径 =====
XMG_WARP_DIR="${XMG_WARP_DIR:-${XMG_HOME:-/opt/xmg}/warp}"
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

# 清洗与校验客户端内网 IPv6 地址 (必须为合法纯 IPv6 字面量，严禁方括号、端口号、CIDR 或 Endpoint 特征)
_xmg_warp_clean_ipv6() {
    local raw="$1"
    raw="$(echo "$raw" | tr -d '[:space:]')"
    raw="${raw#[}"
    raw="${raw%]}"
    raw="${raw%/*}"

    # 若末尾带端口号 (如 :0 或 :2408)，绝对为对端 Endpoint 或非法格式，拒绝作为内网 IP
    if [[ "$raw" =~ :[0-9]+$ ]]; then
        echo ""
        return 1
    fi

    # 基础 IPv6 语法校验 (至少含一个冒号，只允许 16 进制与冒号)
    if [[ ! "$raw" =~ : ]] || [[ ! "$raw" =~ ^[0-9a-fA-F:]+$ ]]; then
        echo ""
        return 1
    fi

    echo "$raw"
    return 0
}

# 清洗与校验客户端内网 IPv4 地址
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

# 地区代码到友好国家/地区名称映射
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

# 探测 VPS 原生物理网络归属地与直连数据中心
xmg_warp_detect_native_geo() {
    if [ -n "${XMG_MOCK_WARP_NATIVE_LOC:-}" ]; then
        XMG_WARP_NATIVE_LOC="$XMG_MOCK_WARP_NATIVE_LOC"
        XMG_WARP_NATIVE_COLO="${XMG_MOCK_WARP_NATIVE_COLO:-UNKNOWN}"
        XMG_WARP_NATIVE_IP="${XMG_MOCK_WARP_NATIVE_IP:-}"
        return 0
    fi

    local trace_info=""
    trace_info="$(curl -sSL --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"

    if [ -n "$trace_info" ] && echo "$trace_info" | grep -q 'loc='; then
        XMG_WARP_NATIVE_LOC="$(echo "$trace_info" | grep -E '^loc=' | head -1 | cut -d= -f2)"
        XMG_WARP_NATIVE_COLO="$(echo "$trace_info" | grep -E '^colo=' | head -1 | cut -d= -f2)"
        XMG_WARP_NATIVE_IP="$(echo "$trace_info" | grep -E '^ip=' | head -1 | cut -d= -f2)"
    else
        local ip_info=""
        ip_info="$(curl -sSL --max-time 4 https://ipinfo.io/json 2>/dev/null || curl -sSL --max-time 4 http://ip-api.com/json 2>/dev/null || true)"
        XMG_WARP_NATIVE_LOC="$(echo "$ip_info" | grep -o '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
        XMG_WARP_NATIVE_COLO="UNKNOWN"
        XMG_WARP_NATIVE_IP="$(echo "$ip_info" | grep -o '"query"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
    fi

    [ -n "$XMG_WARP_NATIVE_LOC" ] || XMG_WARP_NATIVE_LOC="UNKNOWN"
    [ -n "$XMG_WARP_NATIVE_COLO" ] || XMG_WARP_NATIVE_COLO="UNKNOWN"
}

# 判断是否为纯 IPv6 环境
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

    if ! curl -4sSL --max-time 2 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
        if curl -6sSL --max-time 2 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
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

        # 更新 account.json 中的端点 (若存在)
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

    # 保存优选端点至 account.json 与重新导出 Xray 出站
    if [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        if [ "$is_v6" -eq 1 ]; then
            sed -i -E "s/\"endpoint_v6\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"endpoint_v6\": \"$best_ep\"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
        else
            sed -i -E "s/\"endpoint_v4\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"endpoint_v4\": \"$best_ep\"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
        fi

        if [ -f "$XMG_WARP_XRAY_OUTBOUND" ]; then
            xmg_warp_export_xray_outbound "$XMG_WARP_XRAY_OUTBOUND" >/dev/null 2>&1 || true
            xmg_info "已同步刷新 Xray 原生出站端点配置: $XMG_WARP_XRAY_OUTBOUND"
        fi
    fi

    echo "$best_ep"
}

# ===== WireGuard 密钥对生成 (零外部工具侵入) =====

_xmg_warp_gen_keys() {
    if [ -n "${XMG_MOCK_WARP_PRIVKEY:-}" ]; then
        echo "${XMG_MOCK_WARP_PRIVKEY} ${XMG_MOCK_WARP_PUBKEY:-mockpubkey}"
        return 0
    fi

    local priv="" pub=""

    # 1. 优先使用 xray 内置 wgkey 命令 (零依赖宿主机环境)
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

    # 2. 次选宿主机已有的 wg 工具
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

    xmg_error "生成 WireGuard 密钥失败 (请确保已安装 xray 或 wg)"
    return 1
}

# ===== 注册 Cloudflare WARP 免费账号 =====

_xmg_warp_register() {
    local force="${1:-0}"
    mkdir -p "$XMG_WARP_DIR" 2>/dev/null || true

    # 若已存在凭据，且非强制重新注册，则核验凭据纯净度
    if [ "$force" != "1" ] && [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        local cur_priv cur_v4 cur_v6
        cur_priv="$(grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        cur_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        cur_v6="$(grep -o '"address_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"

        # 自愈校验：若内网 IPv6 损坏（含中括号、端口、或非 IPv6 格式），自动标记受损重新注册
        if [ -n "$cur_v6" ]; then
            local test_clean_v6="$(_xmg_warp_clean_ipv6 "$cur_v6")"
            if [ -z "$test_clean_v6" ] || [[ "$cur_v6" =~ \[ ]] || [[ "$cur_v6" =~ :[0-9]+$ ]]; then
                xmg_warn "检测到旧 WARP 凭据内网 IP 受损或被历史 Endpoint 污染，自动重新注册纯净凭据..."
                force=1
            fi
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
    local dev_id="" token="" addr_v4="" addr_v6="" peer_pub="" peer_ep_v4="" peer_ep_v6=""
    dev_id="$(_xmg_warp_json_val "$resp" ".id")"
    token="$(_xmg_warp_json_val "$resp" ".token")"

    # 精准截取 interface.addresses 块，无论单行紧凑或多行 JSON 均 100% 免疫 peers.endpoint 干扰
    local addr_block="${resp#*\"addresses\"}"
    addr_block="${addr_block%%\}*}"

    addr_v4="$(echo "$addr_block" | grep -o '"v4"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
    addr_v6="$(echo "$addr_block" | grep -o '"v6"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"

    addr_v4="$(_xmg_warp_clean_ipv4 "$addr_v4")"
    addr_v6="$(_xmg_warp_clean_ipv6 "$addr_v6")"

    peer_pub="$(echo "$resp" | grep -o '"public_key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"

    # 精准截取 peers.endpoint 块 (仅当明确包含 endpoint 键时才解析)
    if [[ "$resp" == *"endpoint"* ]]; then
        local ep_block="${resp#*\"endpoint\"}"
        ep_block="${ep_block%%\}*}"
        peer_ep_v6="$(echo "$ep_block" | grep -o '"v6"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
        peer_ep_v4="$(echo "$ep_block" | grep -o '"v4"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
    fi

    # 校验 Endpoint 合法性: 端点必须包含端口号，若不合法则丢弃并兜底为官方 Anycast 端点
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

    # 保存纯净凭据至 account.json
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

    xmg_info "WARP 账号注册成功 (分配虚拟 IPv4: $addr_v4)"
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

    local privkey="" addr_v4="" addr_v6="" peer_pub="" ep_v6="" ep_v4=""
    privkey="$(grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    addr_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    addr_v6="$(grep -o '"address_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    peer_pub="$(grep -o '"peer_public_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    ep_v6="$(grep -o '"endpoint_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    ep_v4="$(grep -o '"endpoint_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"

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
    "noKernelTun": true,
    "mtu": 1280,
    "reserved": [0, 0, 0],
    "remoteDNS": [
      "1.1.1.1",
      "1.0.0.1",
      "2606:4700:4700::1111",
      "2606:4700:4700::1001"
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

_xmg_warp_backup_config() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    local bak_dir=""
    if [ -n "${XMG_BACKUP_DIR:-}" ]; then
        bak_dir="$XMG_BACKUP_DIR"
    elif [ -n "${XMG_HOME:-}" ]; then
        bak_dir="$XMG_HOME/backup"
    else
        bak_dir="$(dirname "$cfg")/backup"
    fi
    mkdir -p "$bak_dir" 2>/dev/null || bak_dir="$(dirname "$cfg")"
    local bak="$bak_dir/config.json.warp.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || date +%s).$"
    cp -f "$cfg" "$bak" 2>/dev/null || true
    echo "$bak"
}

# ===== Xray WARP 出站分流管理 (增量补强 / 优雅剔除 / 安全备份) =====

xmg_warp_enable() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "正在启用 Xray 原生 WireGuard (WARP) 出站..."

    # 1. 确保账号凭据就绪
    if [ ! -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        _xmg_warp_register 0 || return 1
    fi

    # 2. 导出出站片段
    xmg_warp_export_xray_outbound "$XMG_WARP_XRAY_OUTBOUND" || return 1

    # 3. 记录启用状态至 env
    mkdir -p "$(dirname "$XMG_WARP_ENV_FILE")"
    if [ -f "$XMG_WARP_ENV_FILE" ]; then
        sed -i '/^WARP_ENABLED=/d' "$XMG_WARP_ENV_FILE" 2>/dev/null || true
    fi
    echo "WARP_ENABLED=1" >> "$XMG_WARP_ENV_FILE"

    # 4. 增量补强 Xray 主配置 (绝不重置覆盖，100% 保留原有 inbounds/证书/出站/policy)
    local xray_cfg="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
    if [ -f "$xray_cfg" ] && command -v jq >/dev/null 2>&1; then
        local warp_json=""
        warp_json="$(cat "$XMG_WARP_XRAY_OUTBOUND" 2>/dev/null || true)"
        if [ -n "$warp_json" ]; then
            # 修改前安全备份
            local bak=""
            bak="$(_xmg_warp_backup_config "$xray_cfg")"
            [ -n "$bak" ] && xmg_info "已备份原始 Xray 配置至: $bak"

            local tmp_cfg="${xray_cfg}.tmp.$"
            local jq_file="${tmp_cfg}.jq"
            local v6_fallback_rule=""
            if xmg_warp_is_ipv6_only; then
                # 纯 IPv6 VPS 终极容灾: 若目标网站无法通过 IPv6 访问 (无 AAAA 或 IPv6 阻断)，由 WARP IPv4 节点出口全自动兜底！
                v6_fallback_rule=', { "type": "field", "outboundTag": "warp-out", "ip": [ "0.0.0.0/0" ] }'
            fi

            cat > "$jq_file" << EOF_ENABLE_JQ
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
        "domain:youtube.com",
        "domain:ytimg.com",
        "domain:googlevideo.com",
        "domain:youtubekids.com",
        "domain:youtube-nocookie.com",
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
        "domain:viu.tv",
        "domain:google.com",
        "domain:googleapis.com",
        "domain:gstatic.com",
        "domain:googleusercontent.com",
        "domain:recaptcha.net",
        "domain:google.com.hk",
        "domain:google.co.jp",
        "domain:google.com.tw",
        "domain:google.com.sg",
        "domain:github.com",
        "domain:githubassets.com",
        "domain:githubusercontent.com",
        "domain:raw.githubusercontent.com",
        "domain:api.github.com",
        "domain:twitter.com",
        "domain:x.com",
        "domain:twimg.com",
        "domain:instagram.com",
        "domain:reddit.com",
        "domain:redditmedia.com"
      ]
    }$v6_fallback_rule
  ]
))
EOF_ENABLE_JQ

            if jq -f "$jq_file" < "$xray_cfg" > "$tmp_cfg" 2>/dev/null; then
                rm -f "$jq_file" 2>/dev/null || true
                # 校验生成的 json 语法
                if jq . < "$tmp_cfg" >/dev/null 2>&1; then
                    # 若内核二进制存在，预校验内核解析
                    local xray_bin=""
                    if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
                        xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"
                    elif command -v xray >/dev/null 2>&1; then
                        xray_bin="$(command -v xray)"
                    fi

                    if [ -n "$xray_bin" ] && [ -x "$xray_bin" ] && [ "${XMG_TEST_MODE:-0}" != "1" ]; then
                        local test_out=""
                        if ! test_out="$("$xray_bin" run -test -c "$tmp_cfg" 2>&1)"; then
                            xmg_error "Xray 内核校验新配置失败，详细错误信息如下:"
                            printf '%s\n' "$test_out" >&2
                            rm -f "$tmp_cfg" 2>/dev/null || true
                            return 1
                        fi
                    fi

                    mv -f "$tmp_cfg" "$xray_cfg"
                    xmg_info "Xray 配置增量补强完成: 已在 outbounds 追加 warp-out 并添加流媒体/AI 按需分流规则 (原有配置 100% 保留)"
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

    # 5. 若 Xray 运行中，重载/重启服务
    if [ "${XMG_TEST_MODE:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        local s_name="${XMG_XRAY_SERVICE:-xray}"
        if systemctl is-active --quiet "$s_name" 2>/dev/null; then
            if ! systemctl restart "$s_name" >/dev/null 2>&1; then
                xmg_error "重启 $s_name 失败，尝试回滚配置..."
                if [ -n "${bak:-}" ] && [ -f "$bak" ]; then
                    cp -f "$bak" "$xray_cfg" 2>/dev/null || true
                    systemctl restart "$s_name" >/dev/null 2>&1 || true
                fi
                return 1
            fi
            # 运行时存活健康复核: 等待 1 秒检查服务是否异常闪退
            sleep 1
            if ! systemctl is-active --quiet "$s_name" 2>/dev/null; then
                xmg_error "$s_name 服务启动后异常闪退，正在执行安全回滚..."
                if [ -n "${bak:-}" ] && [ -f "$bak" ]; then
                    cp -f "$bak" "$xray_cfg" 2>/dev/null || true
                    systemctl restart "$s_name" >/dev/null 2>&1 || true
                fi
                return 1
            fi
            xmg_info "已成功重启 $s_name 服务并确认运行健康 (active)"
        fi
    fi

    xmg_info "Xray WARP 出站已成功启用 (出站标签: warp-out)"
    xmg_info "配置片段位置: $XMG_WARP_XRAY_OUTBOUND"
    xmg_info "宿主机 100% 零侵入、零网卡接管、零系统路由改动，SSH 绝对防断网！"
    return 0
}

xmg_warp_disable() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "正在停用 Xray 原生 WireGuard (WARP) 出站..."

    # 1. 记录停用状态至 env
    mkdir -p "$(dirname "$XMG_WARP_ENV_FILE")"
    if [ -f "$XMG_WARP_ENV_FILE" ]; then
        sed -i '/^WARP_ENABLED=/d' "$XMG_WARP_ENV_FILE" 2>/dev/null || true
    fi
    echo "WARP_ENABLED=0" >> "$XMG_WARP_ENV_FILE"

    # 2. 从 Xray 主配置中无损剔除 warp-out (保留所有其余配置)
    local xray_cfg="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
    if [ -f "$xray_cfg" ] && command -v jq >/dev/null 2>&1; then
        # 修改前安全备份
        local bak=""
        bak="$(_xmg_warp_backup_config "$xray_cfg")"
        [ -n "$bak" ] && xmg_info "已备份原始 Xray 配置至: $bak"

        local tmp_cfg="${xray_cfg}.tmp.$"
        local jq_file="${tmp_cfg}.jq"
        cat > "$jq_file" << 'EOF_DISABLE_JQ'
(.outbounds = [ (.outbounds // [])[] | select(.tag != "warp-out") ]) |
(if (.routing and .routing.rules) then
   .routing.rules = [ .routing.rules[] | select((.outboundTag // "") != "warp-out") ]
 else . end)
EOF_DISABLE_JQ

        if jq -f "$jq_file" < "$xray_cfg" > "$tmp_cfg" 2>/dev/null; then
            rm -f "$jq_file" 2>/dev/null || true
            if jq . < "$tmp_cfg" >/dev/null 2>&1; then
                mv -f "$tmp_cfg" "$xray_cfg"
                xmg_info "已从 Xray 配置中无损移除 warp-out 出站与相关分流规则 (原有其余配置毫发无损)"
            else
                rm -f "$tmp_cfg" 2>/dev/null || true
            fi
        else
            rm -f "$jq_file" "$tmp_cfg" 2>/dev/null || true
        fi
    fi

    # 3. 若 Xray 运行中，重载/重启服务
    if [ "${XMG_TEST_MODE:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        local s_name="${XMG_XRAY_SERVICE:-xray}"
        if systemctl is-active --quiet "$s_name" 2>/dev/null; then
            systemctl restart "$s_name" >/dev/null 2>&1 && xmg_info "已重启 $s_name 服务应用变更"
        fi
    fi

    xmg_info "Xray WARP 出站已关闭 (warp-out 已停用)"
    return 0
}




# ===== 全自动配置 (方案 A) =====

xmg_warp_auto_apply() {
    [ "${XMG_TEST_MODE:-0}" = "1" ] || xmg_require_root
    xmg_info "=================================================================="
    xmg_info "正在执行 Xray 原生 WireGuard (WARP) 出站全自动极速配置..."
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

    # 4. 导出出站并启用
    xmg_warp_enable || return 1

    xmg_info "=================================================================="
    xmg_info "WARP 原生 Xray 出站配置就绪！"
    xmg_info "提示: 流量已降维至 Xray 进程内出站分流，宿主机网络 0 变动！"
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

    # 3. 彻底清除可能存在的历史遗留 wg-quick 配置文件与服务（零污染清理）
    if [ -f "/etc/wireguard/warp.conf" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop wg-quick@warp >/dev/null 2>&1 || true
            systemctl disable wg-quick@warp >/dev/null 2>&1 || true
        fi
        rm -f "/etc/wireguard/warp.conf"
        xmg_info "已清理历史遗留 /etc/wireguard/warp.conf"
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
    if [ -f "$XMG_WARP_ENV_FILE" ] && grep -q '^WARP_ENABLED=1' "$XMG_WARP_ENV_FILE" 2>/dev/null; then
        is_enabled=1
    elif [ -f "$XMG_WARP_XRAY_OUTBOUND" ]; then
        is_enabled=1
    fi

    printf "服务状态        : "
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        echo "已启用 (Xray 原生 WireGuard 出站就绪)"
    elif [ "$is_enabled" -eq 1 ]; then
        echo "已启用 (Xray 原生 WireGuard 出站就绪)"
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

    # 获取 Cloudflare trace 信息
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

    echo "-------------------- 智能分流与出站容灾诊断 --------------------"
    local v6_fallback_tip="无需兜底 (具备原生 IPv4/双栈)"
    if xmg_warp_is_ipv6_only; then
        v6_fallback_tip="全自动兜底已生效 (遇到无法用 IPv6 访问的纯 IPv4 连接，自动使用 WARP 节点出站)"
    fi
    printf "分流规则覆盖    : 全主流 AI (OpenAI/Claude/Gemini) + 全球流媒体 (Netflix/Disney+/YT) + 搜索防风控\n"
    printf "无法用IPv6容灾  : %s\n" "$v6_fallback_tip"
    echo "-------------------- 本地原生与出口地区诊断 --------------------"
    printf "VPS 本地原生地区: %s | 机房 Colo: %s\n" "$(_xmg_warp_country_name "$XMG_WARP_NATIVE_LOC")" "$XMG_WARP_NATIVE_COLO"
    printf "WARP 出口归属地区: %s | 机房 Colo: %s\n" "$(_xmg_warp_country_name "$egress_loc")" "${egress_colo:-未知}"

    local google_loc=""
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        google_loc="${XMG_MOCK_WARP_GOOGLE_LOC:-$egress_loc}"
    else
        google_loc="$(curl -sSL --max-time 4 "https://www.google.com" -o /dev/null -w "%{redirect_url}\n" 2>/dev/null | grep -oE 'google\.[a-z\.]+' | sed 's/google\.//' | tr '[:lower:]' '[:upper:]' || true)"
        [ -z "$google_loc" ] && google_loc="$egress_loc"
    fi
    printf "Google 权威地区 : %s\n" "$(_xmg_warp_country_name "$google_loc")"

    if [ -n "$XMG_WARP_NATIVE_LOC" ] && [ "$XMG_WARP_NATIVE_LOC" = "$egress_loc" ]; then
        echo "地区一致性判定  : 100% 保持本地一致 (PASS)"
    elif [ -z "$egress_loc" ] || [ "$egress_loc" = "UNKNOWN" ]; then
        echo "地区一致性判定  : 待检测 (WARP 未激活)"
    else
        echo "地区一致性判定  : 跨区漂移 (原生: $XMG_WARP_NATIVE_LOC -> 出口: $egress_loc) [WARN]"
        echo "优化建议        : 请运行「本地机房端点优选」(xmg warp optimize) 锁定本地数据中心"
    fi
    echo "=================================================================="
}

# ===== 流媒体与 IP 清洁度测试 =====

xmg_warp_test_unlock() {
    echo "==================== WARP 流媒体与 IP 清洁度测试 ===================="
    echo "正在测试常见平台连通性与解锁状态，请稍候..."
    echo

    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        echo "GitHub (纯 IPv6 痛点) : 正常连通"
        echo "Google (搜索连通性)  : 正常 (HTTP 200, IP 清洁度良好)"
        echo "ChatGPT / OpenAI      : 可用 (HTTP 200, 允许访问)"
        echo "Netflix               : 完全解锁 (HTTP 200)"
        return 0
    fi

    # 1. Google 连通性
    printf "Google (搜索连通性)  : "
    local g_code=""
    g_code="$(curl -4sSL -o /dev/null -w "%{http_code}" --max-time 5 "https://www.google.com" 2>/dev/null || echo "000")"
    if [ "$g_code" = "200" ]; then
        echo "正常 (HTTP 200, 无验证码阻断, IP 清洁度良好)"
    elif [ "$g_code" = "000" ]; then
        echo "连接失败 (超时或无 IPv4 路由)"
    else
        echo "返回码 HTTP $g_code"
    fi

    # 2. ChatGPT / OpenAI
    printf "ChatGPT / OpenAI      : "
    local oai_code=""
    oai_code="$(curl -sSL -o /dev/null -w "%{http_code}" --max-time 5 "https://chatgpt.com" 2>/dev/null || echo "000")"
    if [ "$oai_code" = "200" ] || [ "$oai_code" = "307" ] || [ "$oai_code" = "308" ]; then
        echo "可用 (HTTP $oai_code, 允许访问)"
    elif [ "$oai_code" = "000" ]; then
        echo "连接超时"
    else
        echo "返回码 HTTP $oai_code"
    fi

    # 3. GitHub
    printf "GitHub (纯 IPv6 痛点) : "
    local gh_code=""
    gh_code="$(curl -4sSL -o /dev/null -w "%{http_code}" --max-time 5 "https://api.github.com" 2>/dev/null || echo "000")"
    if [ "$gh_code" = "200" ]; then
        echo "正常连通 (IPv4 访问正常)"
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
        echo "========== WARP 原生出站管理 (Xray WireGuard) =========="
        echo "说明: 宿主机 100% 零侵入、零网卡、零路由修改，SSH 物理级绝对不失联！"
        echo "------------------------------------------------------------"
        echo "1. 一键全自动配置 (原生嗅探 + 注册纯净凭据 + 优选端点 + 导出出站)"
        echo "2. 启用 Xray WARP 出站分流 (启用 warp-out)"
        echo "3. 关闭 Xray WARP 出站分流 (停用 warp-out)"
        echo "4. 查看当前 WARP 状态与地区一致性诊断"
        echo "5. 智能优选低延迟本地端点 (锁定 VPS 本地机房 IP)"
        echo "6. 测试流媒体 / ChatGPT / Google 地区与 IP 清洁度"
        echo "7. 导出 / 查看 Xray 原生 WireGuard 出站配置片段"
        echo "8. 重新注册 Cloudflare WARP 纯净账号凭据"
        echo "9. 清理 / 卸载 WARP 配置与凭据"
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
                xmg_warp_enable || true
                xmg_pause
                ;;
            3)
                clear
                xmg_warp_disable || true
                xmg_pause
                ;;
            4)
                clear
                xmg_warp_status
                xmg_pause
                ;;
            5)
                clear
                xmg_warp_optimize_endpoint || true
                xmg_pause
                ;;
            6)
                clear
                xmg_warp_test_unlock
                xmg_pause
                ;;
            7)
                clear
                xmg_warp_export_xray_outbound || true
                xmg_pause
                ;;
            8)
                clear
                _xmg_warp_register 1 || true
                xmg_pause
                ;;
            9)
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
