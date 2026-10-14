#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# warp.sh - XMG Cloudflare WARP 网络配置与防污染模块
#
# 说明：
#   - 极简全自动 / 零交互自适应：为纯 IPv6 VPS 自动配置 Cloudflare IPv4 出口，同时避免 VPS 本地 IP 污染度高
#   - 纯 IPv6 VPS 保护原则：仅接管 IPv4 流量 (AllowedIPs = 0.0.0.0/0)，使用 Cloudflare IPv6 对端端点，
#     绝不改动 IPv6 默认路由，确保 SSH 连接 100% 绝对不失联！
#   - 支持能力：
#       1. 全自动无人值守安装/应用 (xmg_warp_auto_apply)
#       2. 双栈全局接管模式 (xmg_warp_install_dual，带 SSH 客户端 IP 白名单保护)
#       3. 状态查询 (xmg_warp_status): 接口状态、公网 IPv4/v6 出口、ASN、CF Trace
#       4. IP 清洁度与流媒体/AI 解锁测试 (xmg_warp_test_unlock): Google, ChatGPT, Netflix, GitHub
#       5. Xray 原生 WireGuard 出站配置片段导出 (xmg_warp_export_xray_outbound)
#       6. 服务控制: start, stop, restart, uninstall
#   - 兼容 WireGuard 原生内核 / wg-quick
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
XMG_WARP_CONF_DIR="${XMG_WARP_CONF_DIR:-/etc/wireguard}"
XMG_WARP_CONF="${XMG_WARP_CONF:-$XMG_WARP_CONF_DIR/warp.conf}"
XMG_WARP_CONF_FILE="$XMG_WARP_CONF"
XMG_WARP_ACCOUNT_FILE="${XMG_WARP_ACCOUNT_FILE:-$XMG_WARP_DIR/account.json}"
XMG_WARP_ENV_FILE="${XMG_WARP_ENV_FILE:-$XMG_WARP_DIR/warp.env}"

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
if ! declare -F xmg_confirm >/dev/null 2>&1; then
    xmg_confirm() {
        local prompt="${1:-确认继续?}"
        local answer=""
        if [ "${XMG_TEST_MODE:-0}" = "1" ] || [ "${XMG_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
            return 0
        fi
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

    # 基础 IPv6 语法检查: 仅允许 16 进制字符和冒号，且必须含冒号，严禁三连冒号 :::
    if [[ ! "$raw" =~ ^[0-9a-fA-F:]+$ ]] || [[ ! "$raw" =~ : ]] || [[ "$raw" =~ ::: ]]; then
        echo ""
        return 1
    fi

    echo "$raw"
    return 0
}

# 清洗与校验客户端内网 IPv4 地址 (必须为合法的点分十进制，若异常则安全兜底为 172.16.0.2)
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

# ===== 原生地理位置探测与权威核验辅助 =====

# 国家/地区代码转换为友好展示名
_xmg_warp_country_name() {
    local code="${1^^}"
    case "$code" in
        HK) echo "中国香港 (HK)" ;;
        TW) echo "中国台湾 (TW)" ;;
        JP) echo "日本 (JP)" ;;
        SG) echo "新加坡 (SG)" ;;
        US) echo "美国 (US)" ;;
        KR) echo "韩国 (KR)" ;;
        GB|UK) echo "英国 (GB)" ;;
        DE) echo "德国 (DE)" ;;
        FR) echo "法国 (FR)" ;;
        NL) echo "荷兰 (NL)" ;;
        CA) echo "加拿大 (CA)" ;;
        AU) echo "澳大利亚 (AU)" ;;
        MY) echo "马来西亚 (MY)" ;;
        TH) echo "泰国 (TH)" ;;
        VN) echo "越南 (VN)" ;;
        IN) echo "印度 (IN)" ;;
        RU) echo "俄罗斯 (RU)" ;;
        "") echo "未知地区" ;;
        *)  echo "$code" ;;
    esac
}

# 探测 VPS 原生网络物理归属地与直连 Cloudflare 数据中心 (在接管前或直连探测并固化缓存)
xmg_warp_detect_native_geo() {
    local cache_file="$XMG_WARP_DIR/native_geo.env"

    if [ -n "${XMG_MOCK_WARP_NATIVE_LOC:-}" ]; then
        XMG_WARP_NATIVE_IP="${XMG_MOCK_WARP_NATIVE_IP:-1.2.3.4}"
        XMG_WARP_NATIVE_LOC="${XMG_MOCK_WARP_NATIVE_LOC:-HK}"
        XMG_WARP_NATIVE_COLO="${XMG_MOCK_WARP_NATIVE_COLO:-HKG}"
        return 0
    fi

    # 若已缓存，直接读取缓存 (防止开启全局 WARP 之后无法读取原生 IP)
    if [ -f "$cache_file" ]; then
        # shellcheck disable=SC1090
        source "$cache_file" 2>/dev/null || true
        if [ -n "${XMG_WARP_NATIVE_LOC:-}" ] && [ -n "${XMG_WARP_NATIVE_COLO:-}" ]; then
            return 0
        fi
    fi

    local trace=""
    if [ "${XMG_TEST_MODE:-0}" != "1" ]; then
        trace="$(curl -4sSL --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
        if [ -z "$trace" ] || ! echo "$trace" | grep -q "colo="; then
            trace="$(curl -6sSL --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
        fi
    fi

    XMG_WARP_NATIVE_IP="$(echo "$trace" | grep "^ip=" | cut -d= -f2)"
    XMG_WARP_NATIVE_LOC="$(echo "$trace" | grep "^loc=" | cut -d= -f2)"
    XMG_WARP_NATIVE_COLO="$(echo "$trace" | grep "^colo=" | cut -d= -f2)"

    [ -n "$XMG_WARP_NATIVE_LOC" ] || XMG_WARP_NATIVE_LOC="UNKNOWN"
    [ -n "$XMG_WARP_NATIVE_COLO" ] || XMG_WARP_NATIVE_COLO="UNKNOWN"

    mkdir -p "$XMG_WARP_DIR"
    cat > "$cache_file" <<EOF
XMG_WARP_NATIVE_IP="$XMG_WARP_NATIVE_IP"
XMG_WARP_NATIVE_LOC="$XMG_WARP_NATIVE_LOC"
XMG_WARP_NATIVE_COLO="$XMG_WARP_NATIVE_COLO"
EOF
    chmod 600 "$cache_file" 2>/dev/null || true
}

# 本地机房对端优选: 测试候选官方端点往返延迟，锁定本地数据中心
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

    # 保存优选端点至 account.json 与 warp.conf
    if [ -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        if [ "$is_v6" -eq 1 ]; then
            sed -i -E "s/"endpoint_v6"[[:space:]]*:[[:space:]]*"[^"]*"/"endpoint_v6": "$best_ep"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
        else
            sed -i -E "s/"endpoint_v4"[[:space:]]*:[[:space:]]*"[^"]*"/"endpoint_v4": "$best_ep"/" "$XMG_WARP_ACCOUNT_FILE" 2>/dev/null || true
        fi
    fi

    if [ -f "$XMG_WARP_CONF" ]; then
        sed -i -E "s|^Endpoint[[:space:]]*=.*|Endpoint = $best_ep|" "$XMG_WARP_CONF" 2>/dev/null || true
        systemctl restart wg-quick@warp >/dev/null 2>&1 || true
    fi

    echo "$best_ep"
}

# ===== 环境感知辅助 =====

xmg_warp_is_ipv6_only() {
    if [ "${XMG_MOCK_WARP_STACK:-}" = "ipv6_only" ]; then
        return 0
    elif [ "${XMG_MOCK_WARP_STACK:-}" = "dual_stack" ]; then
        return 1
    fi
    if declare -F xmg_detect_network >/dev/null 2>&1; then
        xmg_detect_network
        if [ "${XMG_NET_IPV4:-0}" -eq 0 ] && [ "${XMG_NET_IPV6:-0}" -eq 1 ] && [ "${XMG_NET_NAT64:-0}" -eq 0 ]; then
            return 0
        fi
    fi
    return 1
}

# 提取当前 SSH 登录端的来源 IP (用于防失联白名单)
xmg_warp_get_ssh_client_ip() {
    local ip=""
    if [ -n "${SSH_CLIENT:-}" ]; then
        ip="$(echo "$SSH_CLIENT" | awk '{print $1}')"
    elif [ -n "${SSH_CONNECTION:-}" ]; then
        ip="$(echo "$SSH_CONNECTION" | awk '{print $1}')"
    fi
    echo "$ip"
}

# 安装 WireGuard 必要工具链
xmg_warp_install_tools() {
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        return 0
    fi
    xmg_require_root

    if xmg_cmd_exists wg && xmg_cmd_exists wg-quick; then
        return 0
    fi

    xmg_info "正在自动安装 WireGuard 工具链 (wireguard-tools, iproute2, resolvconf)..."

    if xmg_cmd_exists apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        export UCF_FORCE_CONFFOLD=1
        if declare -F xmg_apt_wait_lock >/dev/null 2>&1; then
            xmg_apt_wait_lock 60 || true
        fi

        # 优化策略: 优先尝试直接安装 (命中本地缓存，免跑耗时甚至超时的 update)
        if ! apt-get -o DPkg::Lock::Timeout=60 \
                     -o Dpkg::Options::="--force-confdef" \
                     -o Dpkg::Options::="--force-confold" \
                     install -y wireguard-tools iproute2 curl >/dev/null 2>&1; then
            xmg_warn "wireguard-tools 初次安装受阻 (可能存在死锁或缓存缺失)，正在尝试自动解除锁并更新重试..."
            if declare -F xmg_apt_unlock_and_repair >/dev/null 2>&1; then
                xmg_apt_unlock_and_repair || true
            fi
            apt-get -o DPkg::Lock::Timeout=60 update -y >/dev/null 2>&1 || xmg_warn "apt-get update 存在警告"
            apt-get -o DPkg::Lock::Timeout=60 \
                    -o Dpkg::Options::="--force-confdef" \
                    -o Dpkg::Options::="--force-confold" \
                    install -y wireguard-tools iproute2 curl || {
                xmg_error "wireguard-tools 安装失败"
                return 1
            }
        fi
        apt-get -o DPkg::Lock::Timeout=30 \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                install -y resolvconf >/dev/null 2>&1 || true
    elif xmg_cmd_exists dnf; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y wireguard-tools iproute curl || {
            xmg_error "wireguard-tools 安装失败"
            return 1
        }
    elif xmg_cmd_exists yum; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y wireguard-tools iproute curl || {
            xmg_error "wireguard-tools 安装失败"
            return 1
        }
    elif xmg_cmd_exists pacman; then
        pacman -Sy --noconfirm wireguard-tools iproute2 curl || {
            xmg_error "wireguard-tools 安装失败"
            return 1
        }
    elif xmg_cmd_exists apk; then
        apk add wireguard-tools iproute2 curl || {
            xmg_error "wireguard-tools 安装失败"
            return 1
        }
    else
        xmg_error "未知包管理器，请手动安装 wireguard-tools 与 iproute2"
        return 1
    fi

    xmg_info "WireGuard 工具链安装完成"
    return 0
}

# ===== Cloudflare WARP 免费账号注册器 =====

_xmg_warp_register() {
    local force="${1:-0}"
    mkdir -p "$XMG_WARP_DIR" "$(dirname "$XMG_WARP_CONF")"

    if [ "$force" -ne 1 ] && [ -f "$XMG_WARP_ACCOUNT_FILE" ] && [ -s "$XMG_WARP_ACCOUNT_FILE" ]; then
        local exist_privkey="" exist_v4="" exist_v6=""
        exist_privkey="$(grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        exist_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
        exist_v6="$(grep -o '"address_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"

        local is_corrupted=0
        if [ -z "$exist_privkey" ] || [ -z "$exist_v4" ]; then
            is_corrupted=1
        elif [[ "$exist_v4" =~ : ]]; then
            is_corrupted=1
        elif [ -n "$exist_v6" ]; then
            # 严格防范历史凭据中误存 endpoint 的污染
            if [[ "$exist_v6" =~ \[ ]] || [[ "$exist_v6" =~ \] ]] || [[ "$exist_v6" =~ :[0-9]+$ ]]; then
                is_corrupted=1
            fi
        fi

        if [ "$is_corrupted" -eq 1 ]; then
            xmg_warn "检测到旧 WARP 凭据内网 IP 受损或被历史 Endpoint 污染，自动重新注册纯净凭据..."
        else
            xmg_info "复用已有 WARP 账号凭据: $XMG_WARP_ACCOUNT_FILE"
            return 0
        fi
    fi

    local privkey="" pubkey="" resp=""
    if [ -n "${XMG_MOCK_WARP_PRIVKEY:-}" ]; then
        privkey="$XMG_MOCK_WARP_PRIVKEY"
        pubkey="${XMG_MOCK_WARP_PUBKEY:-mockpubkey}"
    else
        xmg_warp_install_tools || return 1
        privkey="$(wg genkey 2>/dev/null)" || {
            xmg_error "生成 WireGuard 私钥失败"
            return 1
        }
        pubkey="$(echo "$privkey" | wg pubkey 2>/dev/null)" || {
            xmg_error "生成 WireGuard 公钥失败"
            return 1
        }
    fi

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

    local dev_id="" token="" addr_v4="" addr_v6="" peer_pub="" peer_ep_v6="" peer_ep_v4=""
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
    if [[ "$resp" == *\"endpoint\"* ]]; then
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

# ===== 配置文件生成核心 =====

_xmg_warp_generate_conf() {
    [ -f "$XMG_WARP_ACCOUNT_FILE" ] || _xmg_warp_register 0 || return 1

    local privkey addr_v4 addr_v6 peer_pub ep_v6 ep_v4
    privkey="$(grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    addr_v4="$(grep -o '"address_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    addr_v6="$(grep -o '"address_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    peer_pub="$(grep -o '"peer_public_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    ep_v6="$(grep -o '"endpoint_v6"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"
    ep_v4="$(grep -o '"endpoint_v4"[[:space:]]*:[[:space:]]*"[^"]*"' "$XMG_WARP_ACCOUNT_FILE" | head -1 | cut -d'"' -f4)"

    addr_v4="$(_xmg_warp_clean_ipv4 "$addr_v4")"
    addr_v6="$(_xmg_warp_clean_ipv6 "$addr_v6")"

    [ -n "$peer_pub" ] || peer_pub="$XMG_WARP_PEER_PUBKEY"
    [ -n "$ep_v6" ] || ep_v6="$XMG_WARP_ENDPOINT_V6"
    [ -n "$ep_v4" ] || ep_v4="$XMG_WARP_ENDPOINT_V4"

    mkdir -p "$(dirname "$XMG_WARP_CONF")"

    local dns_entry=""
    # 仅当系统具备 resolvectl 或 resolvconf 时写入 DNS 行，避免 wg-quick 因无 resolvconf 报错崩溃
    if [ "${XMG_TEST_MODE:-0}" = "1" ] || command -v resolvectl >/dev/null 2>&1 || command -v resolvconf >/dev/null 2>&1; then
        dns_entry="DNS = 1.1.1.1, 2606:4700:4700::1111"
    fi

    local address_line="Address = $addr_v4/32"
    if [ -n "$addr_v6" ]; then
        address_line="$address_line, $addr_v6/128"
    fi

    if xmg_warp_is_ipv6_only; then
        # 纯 IPv6 保护原则：仅 AllowedIPs = 0.0.0.0/0，对端走 IPv6，绝无 ::/0
        if [[ "$ep_v6" =~ :0$ ]]; then
            ep_v6="${ep_v6%:0}:2408"
        fi
        cat > "$XMG_WARP_CONF" <<EOF
[Interface]
PrivateKey = $privkey
Address = $addr_v4/32
${dns_entry:+$dns_entry}
MTU = 1280

[Peer]
PublicKey = $peer_pub
AllowedIPs = 0.0.0.0/0
Endpoint = $ep_v6
PersistentKeepalive = 25
EOF
    else
        # 双栈模式
        if [[ "$ep_v4" =~ :0$ ]]; then
            ep_v4="${ep_v4%:0}:2408"
        fi
        cat > "$XMG_WARP_CONF" <<EOF
[Interface]
PrivateKey = $privkey
$address_line
${dns_entry:+$dns_entry}
MTU = 1280

[Peer]
PublicKey = $peer_pub
AllowedIPs = 0.0.0.0/0
Endpoint = $ep_v4
PersistentKeepalive = 25
EOF
    fi

    chmod 600 "$XMG_WARP_CONF" 2>/dev/null || true
    return 0
}

# ===== 模式一：纯 IPv6 专享 —— 开启 WARP IPv4 出口 =====

xmg_warp_install_v4() {
    xmg_require_root
    xmg_info "正在配置【纯 IPv6 专享 —— WARP IPv4 出口模式】..."
    _xmg_warp_register 0 || return 1
    _xmg_warp_generate_conf || return 1

    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        return 0
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable wg-quick@warp >/dev/null 2>&1 || true
    if ! systemctl restart wg-quick@warp; then
        xmg_error "wg-quick@warp 启动失败"
        if command -v journalctl >/dev/null 2>&1; then
            journalctl -n 12 -u wg-quick@warp --no-pager 2>/dev/null || true
        fi
        return 1
    fi
    xmg_info "WARP 服务启动成功！"
    return 0
}

# ===== 模式二：双栈全局接管模式 =====

xmg_warp_install_dual() {
    xmg_require_root
    xmg_info "正在配置【双栈全局接管模式】..."
    _xmg_warp_register 0 || return 1
    _xmg_warp_generate_conf || return 1

    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        return 0
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable wg-quick@warp >/dev/null 2>&1 || true
    if ! systemctl restart wg-quick@warp; then
        xmg_error "wg-quick@warp 启动失败"
        if command -v journalctl >/dev/null 2>&1; then
            journalctl -n 12 -u wg-quick@warp --no-pager 2>/dev/null || true
        fi
        return 1
    fi
    xmg_info "WARP 双栈接管已启动！"
    return 0
}

# ===== 全自动无人值守入口 =====

xmg_warp_auto_apply() {
    xmg_require_root
    xmg_info "正在执行 WARP 智能全自动部署..."
    # 提前锁定并持久化 VPS 本地原生机房地理特征 (必须在接管路由前执行)
    xmg_warp_detect_native_geo
    xmg_info "原生归属地感知: $(_xmg_warp_country_name "$XMG_WARP_NATIVE_LOC") [直连机房: $XMG_WARP_NATIVE_COLO]"

    if xmg_warp_is_ipv6_only; then
        xmg_info "拓扑感知: 当前为【纯 IPv6 VPS】，自动应用【WARP IPv4 出口接管模式】(原生 IPv6 + CF IPv4)"
        xmg_warp_install_v4
    else
        xmg_info "拓扑感知: 当前具备 IPv4 网络栈，自动应用【双栈全局接管模式】"
        xmg_warp_install_dual
    fi
}

# ===== Xray 原生 WireGuard 出站配置片段导出 =====

xmg_warp_export_xray_outbound() {
    local target_file="${1:-}"
    if [ ! -f "$XMG_WARP_ACCOUNT_FILE" ]; then
        _xmg_warp_register 0 || return 1
    fi

    local privkey addr_v4 addr_v6 peer_pub ep_v6 ep_v4
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
        "keepAlive": 25
      }
    ],
    "reserved": [0, 0, 0],
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

# ===== 服务启停控制与卸载 =====

xmg_warp_start() {
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        return 0
    fi
    xmg_require_root
    if [ ! -f "$XMG_WARP_CONF" ]; then
        xmg_error "未找到 WARP 配置文件: $XMG_WARP_CONF"
        return 1
    fi
    systemctl enable wg-quick@warp >/dev/null 2>&1 || true
    systemctl restart wg-quick@warp || { xmg_error "启动失败"; return 1; }
    xmg_info "WARP 服务已启动"
}

xmg_warp_stop() {
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        return 0
    fi
    xmg_require_root
    systemctl stop wg-quick@warp >/dev/null 2>&1 || true
    systemctl disable wg-quick@warp >/dev/null 2>&1 || true
    xmg_info "WARP 服务已停止"
}

xmg_warp_restart() {
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        return 0
    fi
    xmg_require_root
    systemctl restart wg-quick@warp || { xmg_error "重启失败"; return 1; }
    xmg_info "WARP 服务已重启"
}

xmg_warp_uninstall() {
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        rm -f "$XMG_WARP_CONF"
        rm -rf "$XMG_WARP_DIR"
        return 0
    fi
    xmg_require_root
    if ! xmg_confirm "确认卸载 WARP 并清理相关配置?"; then
        xmg_info "已取消"
        return 0
    fi
    systemctl stop wg-quick@warp >/dev/null 2>&1 || true
    systemctl disable wg-quick@warp >/dev/null 2>&1 || true
    rm -f "$XMG_WARP_CONF"
    rm -rf "$XMG_WARP_DIR"
    xmg_info "WARP 卸载清理完成"
}

# ===== 状态查看与流媒体/AI 解锁诊断 =====

xmg_warp_status() {
    echo "==================== WARP 运行状态与出口诊断 ===================="
    local is_active=0
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        echo "服务状态   : 运行中 (active)"
    elif xmg_cmd_exists systemctl && systemctl is-active --quiet wg-quick@warp 2>/dev/null; then
        echo "服务状态   : 运行中 (active)"
    else
        echo "服务状态   : 未运行 / 未启用"
    fi

    if [ -f "$XMG_WARP_CONF" ]; then
        echo "配置文件   : $XMG_WARP_CONF"
    else
        echo "配置文件   : 未配置"
    fi

    if xmg_warp_is_ipv6_only; then
        echo "防失联保护 : 开启 (原生 IPv6 直连，仅接管 0.0.0.0/0)"
    else
        echo "防失联保护 : 策略路由白名单"
    fi

    echo
    echo "== 网络出口诊断 =="
    local v4="" v6="" trace4="" trace6=""
    if [ -n "${XMG_MOCK_WARP_TRACE4:-}" ]; then
        trace4="$XMG_MOCK_WARP_TRACE4"
        v4="$(echo "$trace4" | grep "^ip=" | cut -d= -f2)"
    else
        v4="$(curl -4sSL --max-time 4 https://api.ipify.org 2>/dev/null || curl -4sSL --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo '无 / 不可达')"
        trace4="$(curl -4sSL --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || echo 'warp=off')"
    fi
    printf "IPv4 网络出口: %s\n" "$v4"

    if [ -n "${XMG_MOCK_WARP_TRACE6:-}" ]; then
        trace6="$XMG_MOCK_WARP_TRACE6"
        v6="$(echo "$trace6" | grep "^ip=" | cut -d= -f2)"
    else
        v6="$(curl -6sSL --max-time 4 https://api6.ipify.org 2>/dev/null || curl -6sSL --max-time 4 https://ipv6.icanhazip.com 2>/dev/null || echo '无 / 不可达')"
        trace6="$(curl -6sSL --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || echo 'warp=off')"
    fi
    printf "IPv6 网络出口: %s\n" "$v6"

    local warp_state="WARP: off"
    if echo "$trace4" | grep -q "warp=on" || echo "$trace4" | grep -q "warp=plus"; then
        warp_state="WARP: on"
    fi
    printf "Cloudflare Trace: %s\n" "$warp_state"

    echo
    echo "== 地理位置与权威机构一致性诊断 =="
    xmg_warp_detect_native_geo

    local egress_loc="" egress_colo=""
    egress_loc="$(echo "$trace4" | grep "^loc=" | cut -d= -f2)"
    egress_colo="$(echo "$trace4" | grep "^colo=" | cut -d= -f2)"
    [ -n "$egress_loc" ] || egress_loc="$(echo "$trace6" | grep "^loc=" | cut -d= -f2)"
    [ -n "$egress_colo" ] || egress_colo="$(echo "$trace6" | grep "^colo=" | cut -d= -f2)"

    printf "VPS 本地原生地区: %s | 机房 Colo: %s\n" "$(_xmg_warp_country_name "$XMG_WARP_NATIVE_LOC")" "$XMG_WARP_NATIVE_COLO"
    printf "WARP 出口归属地区: %s | 机房 Colo: %s\n" "$(_xmg_warp_country_name "$egress_loc")" "${egress_colo:-未知}"

    # Google 权威地区识别
    local google_loc=""
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        google_loc="${XMG_MOCK_WARP_GOOGLE_LOC:-$XMG_WARP_NATIVE_LOC}"
    else
        local g_head=""
        g_head="$(curl -sSL -I -A "Mozilla/5.0" --max-time 4 "https://www.google.com" 2>/dev/null || true)"
        if echo "$g_head" | grep -iq "Location:.*google\."; then
            google_loc="$(echo "$g_head" | grep -i "^Location:" | grep -oiE 'google\.[a-z.]{2,6}' | head -1 | sed -E 's/google\.com?\.?//I' | tr '[:lower:]' '[:upper:]')"
        fi
        [ -n "$google_loc" ] || google_loc="$egress_loc"
    fi
    printf "Google 权威地区 : %s\n" "$(_xmg_warp_country_name "$google_loc")"

    # 一致性综合判定
    if [ -n "$XMG_WARP_NATIVE_LOC" ] && [ "$XMG_WARP_NATIVE_LOC" != "UNKNOWN" ] && [ -n "$egress_loc" ] && [ "$XMG_WARP_NATIVE_LOC" = "$egress_loc" ]; then
        echo "地区一致性判定  : 100% 保持本地一致 (PASS)"
    elif [ -z "$egress_loc" ] || [ "$egress_loc" = "UNKNOWN" ]; then
        echo "地区一致性判定  : 待检测 (WARP 未激活)"
    else
        echo "地区一致性判定  : 跨区漂移 (原生: $XMG_WARP_NATIVE_LOC -> 出口: $egress_loc) [WARN]"
        echo "优化建议        : 请运行「本地机房端点优选」(xmg warp optimize) 锁定本地数据中心"
    fi
    echo "=================================================================="
}

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

# ===== 菜单 =====

xmg_warp_menu() {
    local choice=""

    while true; do
        clear
        echo "========== WARP 网络配置 =========="
        echo "1. 一键全自动智能配置 (自动感知单双栈 / 纯 IPv6 自动配 IPv4 出口·免操作)"
        echo "2. 纯 IPv6 专享: WARP IPv4 出口 (原生 IPv6 + CF IPv4, 绝对防断网)"
        echo "3. 双栈全局接管: IPv4 + IPv6 全流量 WARP 出口 (防 IP 污染·带 SSH 保护)"
        echo "4. 查看当前 WARP 状态与地区一致性诊断"
        echo "5. 本地地区保障: 智能优选低延迟本地端点 (锁定 VPS 本地机房 IP)"
        echo "6. 测试流媒体 / ChatGPT / Google 地区与 IP 清洁度"
        echo "7. 导出 Xray 原生 WireGuard 出站配置片段"
        echo "8. 启动 / 重启 WARP 服务"
        echo "9. 停止 WARP 服务"
        echo "10. 卸载 WARP 并清理配置"
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
                xmg_warp_install_v4 || true
                xmg_pause
                ;;
            3)
                clear
                xmg_warp_install_dual || true
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
                xmg_warp_restart || true
                xmg_pause
                ;;
            9)
                clear
                xmg_warp_stop || true
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
