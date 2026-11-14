#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# render.sh - Xray 配置渲染器（纯 Bash 内建引擎 + jq 模板注入双模）
#
# 说明：
#   - xmg_render_config 支持纯 Bash 零依赖内建渲染引擎与基于 jq 的模板注入引擎。
#   - 在缺少 jq 的环境（目标机 0.5C/215MB、Alpine/BusyBox、极简系统）下，
#     自动使用纯 Bash 引擎直接生成 100% 合法、符合 Xray 官方规范的 config.json。
#   - 查找模板路径优先级：
#     1. $XMG_CONFIG_TEMPLATE
#     2. $XMG_ETC_DIR/xray/config.template.json
#     3. $XMG_HOME/etc/xray/config.template.json
#     4. $SCRIPT_DIR/../templates/config.template.json 或 $SCRIPT_DIR/templates/config.template.json
#     5. 回退至内置骨架模板 / 纯 Bash 引擎
#   - 外部依赖：零强制依赖（有 jq 时支持外部模板自定义注入，无 jq 时纯 Bash 自包含）。

#===== 安全加载 =====
if [ "${XMG_RENDER_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_RENDER_SH_LOADED=1

if [ -z "${BASH_VERSION:-}" ]; then
    echo "render.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== JSON 转义接口 =====
_xmg_json_escape_into() {
    local __vname="$1" s="$2"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\x01'/\\u0001}"
    s="${s//$'\x02'/\\u0002}"
    s="${s//$'\x03'/\\u0003}"
    s="${s//$'\x04'/\\u0004}"
    s="${s//$'\x05'/\\u0005}"
    s="${s//$'\x06'/\\u0006}"
    s="${s//$'\x07'/\\u0007}"
    s="${s//$'\x0b'/\\u000b}"
    s="${s//$'\x0e'/\\u000e}"
    s="${s//$'\x0f'/\\u000f}"
    s="${s//$'\x10'/\\u0010}"
    s="${s//$'\x11'/\\u0011}"
    s="${s//$'\x12'/\\u0012}"
    s="${s//$'\x13'/\\u0013}"
    s="${s//$'\x14'/\\u0014}"
    s="${s//$'\x15'/\\u0015}"
    s="${s//$'\x16'/\\u0016}"
    s="${s//$'\x17'/\\u0017}"
    s="${s//$'\x18'/\\u0018}"
    s="${s//$'\x19'/\\u0019}"
    s="${s//$'\x1a'/\\u001a}"
    s="${s//$'\x1b'/\\u001b}"
    s="${s//$'\x1c'/\\u001c}"
    s="${s//$'\x1d'/\\u001d}"
    s="${s//$'\x1e'/\\u001e}"
    s="${s//$'\x1f'/\\u001f}"
    printf -v "$__vname" '%s' "$s"
}
xmg_json_escape() {
    local out=""
    _xmg_json_escape_into out "${1-}"
    printf '%s' "$out"
}

# ===== 内置骨架模板 =====
_XMG_DEFAULT_CONFIG_TEMPLATE='{
  "log": {
    "access": "none",
    "error": "/opt/xmg/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIP"
  },
  "policy": {
    "levels": {
      "0": {
        "bufferSize": 4,
        "connIdle": 60
      }
    }
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "finalRules": [
          {
            "action": "allow",
            "network": "tcp",
            "port": "22"
          },
          {
            "action": "allow"
          }
        ]
      },
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIP"
        }
      }
    },
    {
      "protocol": "blackhole",
      "tag": "blocked",
      "settings": {}
    }
  ]
}'

# ===== 模板查找 =====
_xmg_find_config_template() {
    if [ -n "${XMG_CONFIG_TEMPLATE:-}" ] && [ -f "$XMG_CONFIG_TEMPLATE" ]; then
        printf '%s\n' "$XMG_CONFIG_TEMPLATE"
        return 0
    fi
    if [ -n "${XMG_ETC_DIR:-}" ] && [ -f "$XMG_ETC_DIR/xray/config.template.json" ]; then
        printf '%s\n' "$XMG_ETC_DIR/xray/config.template.json"
        return 0
    fi
    if [ -n "${XMG_HOME:-}" ] && [ -f "$XMG_HOME/etc/xray/config.template.json" ]; then
        printf '%s\n' "$XMG_HOME/etc/xray/config.template.json"
        return 0
    fi
    local sdir
    sdir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$sdir/../templates/config.template.json" ]; then
        printf '%s\n' "$sdir/../templates/config.template.json"
        return 0
    fi
    if [ -f "$sdir/templates/config.template.json" ]; then
        printf '%s\n' "$sdir/templates/config.template.json"
        return 0
    fi
    return 1
}

# ===== 内部辅助读取 state 值 =====
_xmg_render_get_val() {
    local key="$1" def="${2:-}" val=""
    if declare -F xmg_state_get >/dev/null 2>&1; then
        val="$(xmg_state_get "$key")"
    elif [ -n "${XMG_STATE[$key]+x}" ]; then
        val="${XMG_STATE[$key]}"
    else
        val="${!key:-}"
    fi
    if [ -n "$val" ]; then
        printf '%s' "$val"
    else
        printf '%s' "$def"
    fi
}

# 数值归一：前导零在 JSON 里非法（RFC 8259 禁止 00443），且 bash 会按八进制解析。
# state 侧允许带填充写法，渲染侧必须先归一，否则纯 Bash 路径产出的配置无法被内核解析。
_xmg_render_norm_int() {
    local val="${1:-}" def="${2:-0}" min="${3:-1}" max="${4:-65535}"

    case "$val" in
        ''|*[!0-9]*) printf '%s' "$def"; return 0 ;;
    esac

    # 先剥前导零再判长度：$((10#...)) 在超长数字上会回绕，
    # 18446744073709552059 会变成 443 从而绕过区间检查
    while [ "${#val}" -gt 1 ] && [ "${val#0}" != "$val" ]; do
        val="${val#0}"
    done
    if [ "${#val}" -gt 10 ]; then
        printf '%s' "$def"
        return 0
    fi

    val="$((10#$val))"
    if [ "$val" -lt "$min" ] || [ "$val" -gt "$max" ]; then
        printf '%s' "$def"
        return 0
    fi
    printf '%s' "$val"
}

# ===== DNS 服务器列表（按宿主机可用协议族下发）=====
#   双栈 / 探测失败（未知） -> IPv4 主 + IPv6 备，v4 被阻断时仍有退路
#   纯 IPv6                -> 仅 IPv6
#   纯 IPv4                -> 仅 IPv4
# 注意：https+local:// 属于 DOHL 本地模式，按 Xray 官方文档不进入路由系统，
#       即 DNS 查询永远走直连，不会经过 WARP 隧道。
_xmg_render_dns_servers_json() {
    local v4_ok=0 v6_ok=0
    local out=""
    local sep=""

    [ "${XMG_NET_IPV4:-}" = "1" ] && v4_ok=1
    [ "${XMG_NET_IPV6:-}" = "1" ] && v6_ok=1
    if [ "$v4_ok" -eq 0 ] && [ "$v6_ok" -eq 0 ]; then
        v4_ok=1
        v6_ok=1
    fi

    if [ "$v4_ok" -eq 1 ]; then
        out='"https+local://1.1.1.1/dns-query", "https+local://8.8.8.8/dns-query"'
        sep=', '
    fi
    if [ "$v6_ok" -eq 1 ]; then
        out="${out}${sep}\"https+local://[2606:4700:4700::1111]/dns-query\", \"https+local://[2001:4860:4860::8888]/dns-query\""
        sep=', '
    fi
    out="${out}${sep}\"localhost\""

    printf '[%s]' "$out"
}

# ===== WARP 隧道能力画像（单栈 / 双栈矩阵）=====
# 官方 WireGuard 出站约束（xtls.github.io/config/outbounds/wireguard.html）：
#   1. 隧道内目标地址必须是 IP，域名要靠 remoteDNS 解析，且该 DNS 走隧道内部；
#   2. allowedIPs 决定哪些目标交给该 peer，必须与 address 实际拥有的协议族一致 ——
#      隧道没有 IPv6 地址却声明 ::/0，AAA A 目标会被塞进无源地址的隧道，直接超时；
#   3. targetStrategy 在 OutboundObject 顶层，默认 AsIs（不本地解析），
#      等于把域名解析全压在隧道内 DNS 上，隧道一抖全站皆挂。
# 参数：$1=隧道 IPv4（可空）$2=隧道 IPv6（可空）$3=主机是否纯 IPv6(1/0)
# 输出：<allowedIPs 元素>|<remoteDNS 元素>|<targetStrategy>，元素不含外层方括号，
#       由调用方包 [] —— 这里再包一层会生成 [[...]]，内核直接拒绝启动。
#       隧道无任何地址时返回 1
_xmg_warp_tunnel_profile() {
    local tun_v4="${1:-}" tun_v6="${2:-}" host_v6_only="${3:-0}"
    local allowed="" dns="" strat=""

    [ -n "$tun_v4" ] && allowed='"0.0.0.0/0"'
    [ -n "$tun_v4" ] && dns='"1.1.1.1", "8.8.8.8"'

    if [ -n "$tun_v6" ]; then
        if [ -n "$allowed" ]; then
            allowed="$allowed, \"::/0\""
        else
            allowed='"::/0"'
        fi
    fi

    # 没有任何地址的隧道不具备承载能力，调用方应直接不渲染 warp-out
    [ -n "$allowed" ] || return 1

    # 隧道无 IPv4 时 remoteDNS 只能用 IPv6（裸地址，官方示例不带方括号）
    [ -n "$dns" ] || dns='"2606:4700:4700::1111", "2001:4860:4860::8888"'

    if [ -z "$tun_v4" ]; then
        # 隧道只有 IPv6，目标只能解到 IPv6
        strat="UseIPv6"
    elif [ -z "$tun_v6" ]; then
        # 隧道只有 IPv4：必须锁死 v4，否则解出 AAAA 后 allowedIPs 里没有 ::/0，找不到 peer
        strat="UseIPv4"
    elif [ "$host_v6_only" = "1" ]; then
        # 纯 IPv6 主机靠隧道补 IPv4 出口，强制 v4 才能拿到 WARP 的收益
        strat="UseIPv4"
    else
        # 双栈主机 + 双栈隧道：保留原生双栈能力
        strat="UseIP"
    fi

    printf '%s|%s|%s' "$allowed" "$dns" "$strat"
}

# ===== WARP 分流：地理数据文件与规则集 =====
# 为什么分档而不是一律开 geosite：
#   Xray 引用 geosite: 标签时，启动阶段要按标签逐个扫描整个 dat 文件；常驻内存
#   只保留被引用标签的 matcher（增量约 1~3MB），但 11MB 级全量包在 80~215MB 机型
#   上会挤压 Xray 原本 20~35MB 的 RSS，进而触发 GOMEMLIMIT 抖动。
#   因此默认只取 v2fly 的 dlc.dat（约 2.4MB），低内存机型直接回落到硬编码域名。
XMG_WARP_GEOSITE_FILE="${XMG_WARP_GEOSITE_FILE:-${XMG_XRAY_ASSET_DIR:-/usr/local/share/xray}/geosite.dat}"

# 档位 -> geosite 标签集合。标签越少，启动扫描次数与 matcher 内存越小。
_xmg_warp_geo_tags() {
    case "${1:-off}" in
        slim) printf '%s' 'openai anthropic google-gemini netflix' ;;
        std)  printf '%s' 'openai anthropic google-gemini netflix disney hbo primevideo spotify youtube' ;;
        full) printf '%s' 'openai anthropic google-gemini netflix disney hbo primevideo spotify youtube tiktok telegram twitter github' ;;
        *)    printf '' ;;
    esac
}

# 有效 CPU 百分比（100 = 1 核）。cgroup v2 的 0.2C 会写成 cpu.max "20000 100000"，
# 整数除法会抹成 0 再被兜底成 1 核，所以这里单独按百分比算，不复用核数探测。
_xmg_warp_cpu_pct() {
    local quota='' period='' pct=''
    local cpu_max="${XMG_CGROUP_CPU_MAX:-/sys/fs/cgroup/cpu.max}"
    if [ -r "$cpu_max" ]; then
        read -r quota period _ < "$cpu_max" 2>/dev/null || true
        if [[ "$quota" =~ ^[0-9]+$ ]] && [[ "$period" =~ ^[0-9]+$ ]] && [ "$period" -gt 0 ]; then
            pct=$(( quota * 100 / period ))
            printf '%s' "$pct"
            return 0
        fi
    fi

    local quota_f="${XMG_CGROUP_CPU_QUOTA:-/sys/fs/cgroup/cpu/cpu.cfs_quota_us}"
    local period_f="${XMG_CGROUP_CPU_PERIOD:-/sys/fs/cgroup/cpu/cpu.cfs_period_us}"
    if [ -r "$quota_f" ] && [ -r "$period_f" ]; then
        read -r quota < "$quota_f" 2>/dev/null || true
        read -r period < "$period_f" 2>/dev/null || true
        if [[ "$quota" =~ ^[0-9]+$ ]] && [[ "$period" =~ ^[0-9]+$ ]] && [ "$period" -gt 0 ]; then
            pct=$(( quota * 100 / period ))
            printf '%s' "$pct"
            return 0
        fi
    fi

    local cores=''
    if declare -F xmg_detect_cpu_cores >/dev/null 2>&1; then
        cores="$(xmg_detect_cpu_cores 2>/dev/null || true)"
    fi
    [[ "$cores" =~ ^[0-9]+$ ]] && [ "$cores" -gt 0 ] || cores=1
    printf '%s' $(( cores * 100 ))
}

# 内存 -> 默认档位。auto 的语义是「按机型自己选」，用户可显式覆盖。
# 判据用「有效内存」而不是标称总内存：512MB 机器只剩 218MB 可用时，
# 按 512MB 判 std 会多加载 5 个标签，而 geosite 加载峰值正好落在这段余量里。
# 只做分流档位判断，不参与 tune.sh 的内核调优分档，两者互不影响。
xmg_warp_geo_auto_mode() {
    local mb=0 cpu_pct=100 base=''
    if declare -F xmg_mem_effective_mb >/dev/null 2>&1; then
        mb="$(xmg_mem_effective_mb 2>/dev/null || printf 0)"
    elif declare -F xmg_detect_mem_total_mb >/dev/null 2>&1; then
        mb="$(xmg_detect_mem_total_mb 2>/dev/null || printf 0)"
    fi
    [[ "$mb" =~ ^[0-9]+$ ]] || mb=0

    if [ "$mb" -le 0 ]; then
        printf 'off'       # 探测失败：按最保守处理，不拿稳定性赌
        return 0
    elif [ "$mb" -le 128 ]; then
        base='off'         # 80MB 级：零地理数据开销，纯硬编码
    elif [ "$mb" -le 256 ]; then
        base='slim'        # 129~256MB：4 个核心标签
    elif [ "$mb" -le 512 ]; then
        base='std'
    else
        base='full'
    fi

    # 0.2C 这类弱 CPU：dat 扫描是启动期的 CPU 密集操作，档位再收一档。
    # 只收档不下探到 off —— 弱 CPU 机型往往内存也不大，slim 已是可用的最低档。
    cpu_pct="$(_xmg_warp_cpu_pct 2>/dev/null || printf 100)"
    [[ "$cpu_pct" =~ ^[0-9]+$ ]] || cpu_pct=100
    if [ "$cpu_pct" -le 20 ]; then
        case "$base" in
            full) base='slim' ;;
            std)  base='slim' ;;
        esac
    elif [ "$cpu_pct" -le 50 ]; then
        case "$base" in
            full) base='std' ;;
            std)  base='slim' ;;
        esac
    fi

    printf '%s' "$base"
    return 0
}

xmg_warp_geo_mode_resolve() {
    case "${1:-auto}" in
        auto|'') xmg_warp_geo_auto_mode ;;
        off|slim|std|full) printf '%s' "$1" ;;
        *) printf 'off' ;;
    esac
}

# dat 是否可用：1MB 下限能挡掉 404 HTML 与被截断的半包。
# XMG_WARP_GEO_DISABLE=1 是渲染期的强制降级开关：内核 -test 判定 geosite
# 不可用时（tag 不存在/文件损坏），调用方靠它重渲染一版纯硬编码配置。
xmg_warp_geo_available() {
    local f="${XMG_WARP_GEOSITE_FILE:-/usr/local/share/xray/geosite.dat}" sz=0
    [ "${XMG_WARP_GEO_DISABLE:-0}" = "1" ] && return 1
    [ -s "$f" ] || return 1
    sz="$(wc -c < "$f" 2>/dev/null || true)"
    sz="${sz//[[:space:]]/}"
    [[ "$sz" =~ ^[0-9]+$ ]] || return 1
    [ "$sz" -ge 1048576 ] || return 1
    return 0
}

# 分流条目唯一真源。
#   硬编码核心永远排在最前：geosite 缺失、档位为 off、或 dat 被删时，
#   这批域名仍能保证 AI / 主流流媒体走 WARP，功能不会整块失效。
#   geosite 只做「扩展覆盖」，不替代硬编码。
xmg_warp_routing_domains() {
    local mode='' m='' t=''
    mode="${1:-auto}"
    m="$(xmg_warp_geo_mode_resolve "$mode")"

    printf '%s\n' \
        'domain:openai.com' \
        'domain:chatgpt.com' \
        'domain:oaistatic.com' \
        'domain:oaiusercontent.com' \
        'domain:sora.com' \
        'domain:anthropic.com' \
        'domain:claude.ai' \
        'domain:gemini.google.com' \
        'domain:bard.google.com' \
        'domain:generativeai.googleapis.com' \
        'domain:makersuite.google.com' \
        'domain:deepmind.com' \
        'domain:deepmind.google' \
        'domain:copilot.microsoft.com' \
        'domain:sydney.bing.com' \
        'domain:perplexity.ai' \
        'domain:pplx.ai' \
        'domain:midjourney.com' \
        'domain:huggingface.co' \
        'domain:groq.com' \
        'domain:poe.com' \
        'domain:cursor.com' \
        'domain:cursor.sh' \
        'domain:netflix.com' \
        'domain:netflix.net' \
        'domain:nflximg.net' \
        'domain:nflxvideo.net' \
        'domain:nflxext.com' \
        'domain:nflxso.net' \
        'domain:disneyplus.com' \
        'domain:disney-portal.my.onetrust.com' \
        'domain:dssott.com' \
        'domain:bamgrid.com' \
        'domain:disneystreaming.com' \
        'domain:spotify.com' \
        'domain:scdn.co' \
        'domain:spoti.fi' \
        'domain:max.com' \
        'domain:hbo.com' \
        'domain:hbomax.com' \
        'domain:primevideo.com' \
        'domain:aiv-cdn.net' \
        'domain:amazonvideo.com' \
        'domain:tv.apple.com' \
        'domain:hulu.com' \
        'domain:peacocktv.com' \
        'domain:paramountplus.com' \
        'domain:tiktok.com' \
        'domain:byteoversea.com' \
        'domain:ibytedtos.com' \
        'domain:musical.ly' \
        'domain:tiktokcdn.com' \
        'domain:tiktokv.com' \
        'domain:gamer.com.tw' \
        'domain:bilibili.tv' \
        'domain:viu.com' \
        'domain:viu.tv'

    if [ "$m" != 'off' ] && xmg_warp_geo_available; then
        for t in $(_xmg_warp_geo_tags "$m"); do
            printf 'geosite:%s\n' "$t"
        done
    fi
}

# 同一份条目的 JSON 数组形态，供 jq 引擎与 warp.sh 增量合并复用。
# 两条渲染路径都从这里取，避免又出现「bash 版 33 条 / jq 版 55 条」的漂移。
xmg_warp_routing_domains_json() {
    local first=1 d=''
    printf '['
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$first" -eq 1 ]; then
            first=0
        else
            printf ','
        fi
        printf '"%s"' "$d"
    done < <(xmg_warp_routing_domains "${1:-auto}")
    printf ']'
}

# ===== WARP 协议族兜底 =====
# 隧道承载不了的那一族目标，不能塞进 warp-out：
#   UseIPv4 的隧道拿不到 A 记录就判死，而路由一旦选中出站就没有回退机制
#   （Xray 的 outbound 没有 fallback 字段）。所以把「隧道可承载的协议族」
#   作为 ip 条件挂在同一条规则上，目标解析出另一族时规则不命中，自然落到 direct。
# 代价是 domainStrategy 必须 IPIfNonMatch（未命中第一轮的连接多一次解析），
# 因此只在「宿主有另一族」时启用：单栈宿主回退也访问不了，不必付这个代价。

# 输出隧道可承载的协议族：v4 / v6 / dual / none
_xmg_warp_tunnel_family() {
    local v4="${1:-}" v6="${2:-}"
    if [ -n "$v4" ] && [ -n "$v6" ]; then
        printf 'dual'
    elif [ -n "$v4" ]; then
        printf 'v4'
    elif [ -n "$v6" ]; then
        printf 'v6'
    else
        printf 'none'
    fi
}

# 是否需要协议族兜底：$1=隧道族 $2=宿主 IPv4(1/0) $3=宿主 IPv6(1/0)
_xmg_warp_family_fallback() {
    local tun="${1:-none}" hv4="${2:-0}" hv6="${3:-0}"
    case "$tun" in
        v4) [ "$hv6" = "1" ] && return 0 ;;
        v6) [ "$hv4" = "1" ] && return 0 ;;
        dual)
            # 双栈隧道本身两族都能走，但纯 IPv6 宿主的 warp-out 会被
            # _xmg_warp_tunnel_profile 锁成 UseIPv4（宿主没有 v4 原生出口，
            # 必须强制走隧道 v4）。此时 IPv6 目标只能回宿主机直连，
            # 所以域名规则要挂 v4 条件，把 AAAA-only 目标挡在隧道外。
            [ "$hv4" = "0" ] && [ "$hv6" = "1" ] && return 0
            ;;
    esac
    return 1
}

# warp-out 实际能承载的那一族（由 targetStrategy 决定，不等于隧道地址族）：
#   纯 IPv6 宿主即便隧道双栈，targetStrategy 也会被锁成 UseIPv4，
#   此时域名规则只能挂 v4 条件，否则 AAAA-only 目标会进隧道后失败。
_xmg_warp_carrier_cidr() {
    local tun="${1:-none}" hv4="${2:-0}" hv6="${3:-0}"
    case "$tun" in
        v4) printf '0.0.0.0/0' ;;
        v6) printf '::/0' ;;
        dual)
            if [ "$hv4" = "0" ] && [ "$hv6" = "1" ]; then
                printf '0.0.0.0/0'
            fi
            ;;
    esac
}

# 隧道族 -> 该族的目标 CIDR（用于给 warp 规则挂 ip 条件）
_xmg_warp_tunnel_cidr() {
    case "${1:-none}" in
        v4) printf '0.0.0.0/0' ;;
        v6) printf '::/0' ;;
        *) printf '' ;;
    esac
}

# 宿主缺失、但隧道能承载的协议族 CIDR。
#   WARP 是用户态 gVisor 栈，隧道内地址族与宿主机无关：
#   纯 IPv4 宿主只要隧道拿到 v6 地址，IPv6 目标就全部可以走 WARP，
#   没必要让它去撞宿主那条根本不存在的 v6 路由。
#   反向同理（纯 IPv6 宿主 + 隧道有 v4），原来只对 v4 做了，v6 侧是缺的。
_xmg_warp_tunnel_only_cidr() {
    local tun="${1:-none}" hv4="${2:-0}" hv6="${3:-0}"
    # 两族都探不到是探测失败，不是「宿主真的两族都没有」：
    # 按最保守处理，不生成全量转发规则，避免把本可直连的流量误塞进隧道。
    if [ "$hv4" = "0" ] && [ "$hv6" = "0" ]; then
        return 1
    fi
    if [ "$hv4" = "0" ] && { [ "$tun" = "v4" ] || [ "$tun" = "dual" ]; }; then
        printf '0.0.0.0/0'
        return 0
    fi
    if [ "$hv6" = "0" ] && { [ "$tun" = "v6" ] || [ "$tun" = "dual" ]; }; then
        printf '::/0'
        return 0
    fi
    return 1
}

# 私有/保留网段：全量转发规则必须把它们排除在外。
#   ::/0 与 0.0.0.0/0 字面上包含回环、ULA、链路本地、CGNAT，
#   这些目标塞进 WARP 隧道只会失败（隧道不承载内网路由），必须先直连。
_xmg_warp_private_cidrs_json() {
    printf '["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"]'
}

# 是否需要 domainStrategy=IPIfNonMatch（先解析目标再按 ip 规则匹配）。
# 只要有一条 ip 规则参与分流就必须开：
#   - 回退直连规则（宿主有、隧道没有的那一族）
#   - 全量走隧道规则（宿主没有、隧道能承载的那一族，典型是纯 v4 宿主 + 双栈隧道）
_xmg_warp_need_ip_match() {
    local tun="${1:-none}" hv4="${2:-0}" hv6="${3:-0}"
    _xmg_warp_family_fallback "$tun" "$hv4" "$hv6" && return 0
    _xmg_warp_tunnel_only_cidr "$tun" "$hv4" "$hv6" >/dev/null 2>&1 && return 0
    return 1
}

# ===== REALITY 入站（VLESS + XHTTP + REALITY）=====
# REALITY 不需要证书：对 target 站点做真实 TLS 握手，靠 privateKey/shortId 区分客户端。
# serverNames 支持逗号分隔多值 —— 这就是「同一端口服务多个域名」的真实端口复用。
_xmg_render_json_str_array() {
    local raw="$1"
    local item="" esc="" out="" first=1
    local oldifs="$IFS"

    IFS=','
    for item in $raw; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [ -n "$item" ] || continue
        _xmg_json_escape_into esc "$item"
        if [ "$first" -eq 1 ]; then
            out="\"$esc\""
            first=0
        else
            out="$out, \"$esc\""
        fi
    done
    IFS="$oldifs"
    printf '[%s]' "$out"
}

# 生成 REALITY 入站的 JSON 片段（已缩进到 inbounds 数组元素层级）
_xmg_render_reality_inbound_json() {
    local listen="$1" port="$2" uuid="$3" path="$4" mode="$5"
    local dest="$6" sni="$7" privkey="$8" shortid="$9"
    local esc_listen esc_uuid esc_path esc_mode esc_dest esc_privkey esc_sid

    _xmg_json_escape_into esc_listen "$listen"
    _xmg_json_escape_into esc_uuid "$uuid"
    _xmg_json_escape_into esc_path "$path"
    _xmg_json_escape_into esc_mode "$mode"
    _xmg_json_escape_into esc_dest "$dest"
    _xmg_json_escape_into esc_privkey "$privkey"
    _xmg_json_escape_into esc_sid "$shortid"

    local names_json ids_json
    names_json="$(_xmg_render_json_str_array "$sni")"
    if [ -n "$shortid" ]; then
        ids_json="$(_xmg_render_json_str_array "$shortid")"
    else
        # 空 shortId 也要显式给一个空串，否则部分客户端与服务端对不上
        ids_json='[""]'
    fi

    printf '    {\n'
    printf '      "tag": "inbound-reality",\n'
    printf '      "listen": "%s",\n' "$esc_listen"
    printf '      "port": %s,\n' "$port"
    printf '      "protocol": "vless",\n'
    printf '      "settings": {\n'
    printf '        "users": [\n'
    printf '          {\n'
    printf '            "id": "%s",\n' "$esc_uuid"
    printf '            "flow": "",\n'
    printf '            "level": 0\n'
    printf '          }\n'
    printf '        ],\n'
    printf '        "decryption": "none"\n'
    printf '      },\n'
    printf '      "streamSettings": {\n'
    printf '        "network": "xhttp",\n'
    printf '        "xhttpSettings": {\n'
    printf '          "path": "%s",\n' "$esc_path"
    printf '          "mode": "%s"\n' "$esc_mode"
    printf '        },\n'
    printf '        "security": "reality",\n'
        printf '        "realitySettings": {\n'
        printf '          "show": false,\n'
        # 官方当前字段名是 target（旧名 dest，两者互为别名）；同时下发两份，
        # 兼顾仍只认 dest 的旧内核：新内核 target 优先覆盖 dest，旧内核忽略未知 target。
        printf '          "target": "%s",\n' "$esc_dest"
        printf '          "dest": "%s",\n' "$esc_dest"
        printf '          "xver": 0,\n'
    printf '          "serverNames": %s,\n' "$names_json"
    printf '          "privateKey": "%s",\n' "$esc_privkey"
    printf '          "shortIds": %s\n' "$ids_json"
    printf '        }\n'
    printf '      },\n'
    printf '      "sniffing": {\n'
    printf '        "enabled": true,\n'
    printf '        "destOverride": ["http", "tls", "quic"],\n'
    printf '        "routeOnly": true\n'
    printf '      }\n'
    printf '    }'
}

# ===== 纯 Bash 零依赖内建渲染引擎 =====
_xmg_render_config_bash() {
    local socks_on="$1" vless_on="$2"
    local error_log="$3" bufsz="$4" is_ipv6_only="$5"
    local socks_listen="$6" socks_port="$7" socks_user="$8" socks_pass="$9" socks_udp_bool="${10}"
    local vless_listen="${11}" vless_port="${12}" vless_domain="${13}" vless_uuid="${14}"
    local vless_path="${15}" vless_mode="${16}" vless_cert_file="${17}" vless_key_file="${18}"
    local warp_on="${19:-$(_xmg_render_get_val WARP_ENABLED 0)}"
    local warp_mode="${20:-$(_xmg_render_get_val WARP_MODE global)}"
    local warp_endpoint="${21:-$(_xmg_render_get_val WARP_ENDPOINT "")}"
    local warp_privkey="${22:-$(_xmg_render_get_val WARP_PRIVATE_KEY "")}"
    local warp_pubkey="${23:-$(_xmg_render_get_val WARP_PUBLIC_KEY "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=")}"
    local warp_v4="${24:-$(_xmg_render_get_val WARP_IPV4 "172.16.0.2")}"
    local warp_v6="${25:-$(_xmg_render_get_val WARP_IPV6 "")}"
    local warp_reserved="${26:-$(_xmg_render_get_val WARP_RESERVED "[0,0,0]")}"

    # 数字保底
    bufsz="$(_xmg_render_norm_int "$bufsz" 4 1 4096)"
    socks_port="$(_xmg_render_norm_int "$socks_port" 1080 1 65535)"
    vless_port="$(_xmg_render_norm_int "$vless_port" 443 1 65535)"

    [ -n "$error_log" ] || error_log="/opt/xmg/log/xray/error.log"
    local default_listen="0.0.0.0"
    [ "$is_ipv6_only" = "true" ] && default_listen="::"
    [ -n "$socks_listen" ] || socks_listen="$default_listen"
    [ -n "$vless_listen" ] || vless_listen="$default_listen"
    [ -n "$vless_path" ] || vless_path="/"
    [ -n "$vless_mode" ] || vless_mode="auto"
    [ -n "$socks_udp_bool" ] || socks_udp_bool=false

    # REALITY 参数（VLESS + XHTTP + REALITY，无需证书）
    local reality_on reality_listen reality_port reality_uuid reality_path reality_mode
    local reality_dest reality_sni reality_pk reality_sid
    reality_on="$(_xmg_render_get_val PROXY_REALITY_ENABLED 0)"
    reality_listen="$(_xmg_render_get_val PROXY_REALITY_LISTEN "$default_listen")"
    reality_port="$(_xmg_render_get_val PROXY_REALITY_PORT "8443")"
    reality_uuid="$(_xmg_render_get_val PROXY_REALITY_UUID "")"
    reality_path="$(_xmg_render_get_val PROXY_REALITY_PATH "/xhttp")"
    reality_mode="$(_xmg_render_get_val PROXY_REALITY_MODE "auto")"
    reality_dest="$(_xmg_render_get_val PROXY_REALITY_DEST "www.microsoft.com:443")"
    reality_sni="$(_xmg_render_get_val PROXY_REALITY_SNI "www.microsoft.com")"
    reality_pk="$(_xmg_render_get_val PROXY_REALITY_PRIVATE_KEY "")"
    reality_sid="$(_xmg_render_get_val PROXY_REALITY_SHORT_ID "")"

    [ -n "$reality_listen" ] || reality_listen="$default_listen"
    if [ "$is_ipv6_only" = "true" ] && [ "$reality_listen" = "0.0.0.0" ]; then
        reality_listen="::"
    fi
    reality_port="$(_xmg_render_norm_int "$reality_port" 8443 1 65535)"
    [ -n "$reality_path" ] || reality_path="/xhttp"
    [ -n "$reality_mode" ] || reality_mode="auto"
    [ -n "$reality_dest" ] || reality_dest="www.microsoft.com:443"
    [ -n "$reality_sni" ] || reality_sni="www.microsoft.com"
    # 缺私钥或 UUID 的 REALITY 入站会被 Xray 拒绝，直接不渲染，避免整份配置起不来
    if [ -z "$reality_pk" ] || [ -z "$reality_uuid" ]; then
        reality_on=0
    fi

    # WARP 参数清洗与兜底
    [ -n "$warp_mode" ] || warp_mode="global"
    if [ "$is_ipv6_only" = "true" ]; then
        if [ -z "$warp_endpoint" ] || [[ "$warp_endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
            warp_endpoint="[2606:4700:d0::a29f:c001]:2408"
        fi
    else
        [ -n "$warp_endpoint" ] || warp_endpoint="162.159.192.1:2408"
    fi
    if [[ "$warp_endpoint" =~ :0$ ]]; then
        warp_endpoint="${warp_endpoint%:0}:2408"
    fi
    if [ "$is_ipv6_only" = "true" ] && [[ "$warp_endpoint" != \[* ]] && [[ "$warp_endpoint" == *:* ]]; then
        local _ep_last="${warp_endpoint##*:}" _ep_head="${warp_endpoint%:*}"
        if [[ "$_ep_last" =~ ^[0-9]+$ ]] && [[ "$_ep_head" == *:* ]]; then
            warp_endpoint="[${_ep_head}]:${_ep_last}"
        fi
    fi
    [ -n "$warp_pubkey" ] || warp_pubkey="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    [ -n "$warp_v4" ] || warp_v4="172.16.0.2"
    [[ "$warp_v4" == */* ]] || warp_v4="${warp_v4}/32"
    if [ -n "$warp_v6" ] && [[ "$warp_v6" != */* ]]; then
        warp_v6="${warp_v6}/128"
    fi
    if [ -z "$warp_reserved" ] || [ "$warp_reserved" = "null" ]; then
        warp_reserved="[0, 0, 0]"
    elif [[ ! "$warp_reserved" =~ ^\[.*\]$ ]]; then
        local _clean_res="${warp_reserved//[[:space:]]/,}"
        while [[ "$_clean_res" =~ ,, ]]; do _clean_res="${_clean_res//,,/,}"; done
        _clean_res="${_clean_res#,}"
        _clean_res="${_clean_res%,}"
        warp_reserved="[$_clean_res]"
    fi

    local esc_error_log esc_socks_listen esc_socks_user esc_socks_pass
    local esc_vless_listen esc_vless_domain esc_vless_uuid esc_vless_path esc_vless_mode esc_vless_cert_file esc_vless_key_file
    local esc_warp_privkey esc_warp_pubkey esc_warp_endpoint

    _xmg_json_escape_into esc_error_log "$error_log"
    _xmg_json_escape_into esc_socks_listen "$socks_listen"
    _xmg_json_escape_into esc_socks_user "$socks_user"
    _xmg_json_escape_into esc_socks_pass "$socks_pass"
    _xmg_json_escape_into esc_vless_listen "$vless_listen"
    _xmg_json_escape_into esc_vless_domain "$vless_domain"
    _xmg_json_escape_into esc_vless_uuid "$vless_uuid"
    _xmg_json_escape_into esc_vless_path "$vless_path"
    _xmg_json_escape_into esc_vless_mode "$vless_mode"
    _xmg_json_escape_into esc_vless_cert_file "$vless_cert_file"
    _xmg_json_escape_into esc_vless_key_file "$vless_key_file"
    _xmg_json_escape_into esc_warp_privkey "$warp_privkey"
    _xmg_json_escape_into esc_warp_pubkey "$warp_pubkey"
    _xmg_json_escape_into esc_warp_endpoint "$warp_endpoint"

    local dns_servers dns_query_strat out_strat
    dns_servers="$(_xmg_render_dns_servers_json)"
    # 纯 IPv6 宿主默认锁 UseIPv6，避免解析出根本没有出口的 A 记录。
    # 但 WARP 隧道补上 IPv4 出口后必须放开为 UseIP：
    # UseIPv6 只查 AAAA，IPv4-only 的域名永远解析不出 A，隧道再能承载也没用。
    if [ "$is_ipv6_only" = "true" ] && { [ "$warp_on" != "1" ] || [ -z "$warp_v4" ]; }; then
        dns_query_strat="UseIPv6"
        out_strat="UseIPv6"
    elif [ "$is_ipv6_only" = "true" ] && [ "$warp_mode" = "routing" ]; then
        dns_query_strat="UseIP"
        out_strat="UseIPv6"
    else
        dns_query_strat="UseIP"
        out_strat="UseIP"
    fi

    printf '{\n'
    printf '  "log": {\n'
    printf '    "access": "none",\n'
    printf '    "error": "%s",\n' "$esc_error_log"
    printf '    "loglevel": "warning"\n'
    printf '  },\n'
    printf '  "dns": {\n'
    printf '    "servers": %s,\n' "$dns_servers"
    printf '    "queryStrategy": "%s"\n' "$dns_query_strat"
    printf '  },\n'
    printf '  "policy": {\n'
    printf '    "levels": {\n'
    printf '      "0": {\n'
    printf '        "bufferSize": %s,\n' "$bufsz"
    printf '        "connIdle": 60\n'
    printf '      }\n'
    printf '    }\n'
    printf '  },\n'

    if [ "$socks_on" != "1" ] && [ "$vless_on" != "1" ] && [ "$reality_on" != "1" ]; then
        printf '  "inbounds": [],\n'
    else
        printf '  "inbounds": [\n'
        local need_comma=0
        if [ "$socks_on" = "1" ]; then
            printf '    {\n'
            printf '      "tag": "inbound-socks",\n'
            printf '      "listen": "%s",\n' "$esc_socks_listen"
            printf '      "port": %s,\n' "$socks_port"
            printf '      "protocol": "socks",\n'
            printf '      "settings": {\n'
            printf '        "auth": "password",\n'
            printf '        "users": [\n'
            printf '          {\n'
            printf '            "user": "%s",\n' "$esc_socks_user"
            printf '            "pass": "%s"\n' "$esc_socks_pass"
            printf '          }\n'
            printf '        ],\n'
            printf '        "udp": %s\n' "$socks_udp_bool"
            printf '      },\n'
            printf '      "sniffing": {\n'
            printf '        "enabled": true,\n'
            printf '        "destOverride": ["http", "tls", "quic"],\n'
            printf '        "routeOnly": true\n'
            printf '      }\n'
            printf '    }'
            need_comma=1
        fi
        if [ "$vless_on" = "1" ]; then
            [ "$need_comma" -eq 1 ] && printf ',\n'
            printf '    {\n'
            printf '      "tag": "inbound-vless",\n'
            printf '      "listen": "%s",\n' "$esc_vless_listen"
            printf '      "port": %s,\n' "$vless_port"
            printf '      "protocol": "vless",\n'
            printf '      "settings": {\n'
            printf '        "users": [\n'
            printf '          {\n'
            printf '            "id": "%s",\n' "$esc_vless_uuid"
            printf '            "level": 0\n'
            printf '          }\n'
            printf '        ],\n'
            printf '        "decryption": "none"\n'
            printf '      },\n'
            printf '      "streamSettings": {\n'
            printf '        "network": "xhttp",\n'
            printf '        "xhttpSettings": {\n'
            printf '          "path": "%s",\n' "$esc_vless_path"
            printf '          "mode": "%s"\n' "$esc_vless_mode"
            printf '        },\n'
            printf '        "security": "tls",\n'
            printf '        "tlsSettings": {\n'
            printf '          "serverName": "%s",\n' "$esc_vless_domain"
            printf '          "rejectUnknownSni": true,\n'
            printf '          "alpn": [\n'
            printf '            "h2",\n'
            printf '            "http/1.1"\n'
            printf '          ],\n'
            printf '          "minVersion": "1.2",\n'
            printf '          "maxVersion": "1.3",\n'
            printf '          "certificates": [\n'
            printf '            {\n'
            printf '              "usage": "encipherment",\n'
            printf '              "certificateFile": "%s",\n' "$esc_vless_cert_file"
            printf '              "keyFile": "%s"\n' "$esc_vless_key_file"
            printf '            }\n'
            printf '          ]\n'
            printf '        }\n'
            printf '      },\n'
            printf '      "sniffing": {\n'
            printf '        "enabled": true,\n'
            printf '        "destOverride": ["http", "tls", "quic"],\n'
            printf '        "routeOnly": true\n'
            printf '      }\n'
            printf '    }'
            need_comma=1
        fi

        if [ "$reality_on" = "1" ]; then
            [ "$need_comma" -eq 1 ] && printf ',\n'
            _xmg_render_reality_inbound_json \
                "$reality_listen" "$reality_port" "$reality_uuid" \
                "$reality_path" "$reality_mode" "$reality_dest" "$reality_sni" \
                "$reality_pk" "$reality_sid"
        fi
        printf '\n  ],\n'
    fi

    local direct_outbound
    direct_outbound='    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "finalRules": [
          {
            "action": "allow",
            "network": "tcp",
            "port": "22"
          },
          {
            "action": "allow"
          }
        ]
      },
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "'"$out_strat"'"
        }
      }
    }'

    local warp_outbound=""
    if [ "$warp_on" = "1" ]; then
        local _host_v6_only=0
        [ "$is_ipv6_only" = "true" ] && _host_v6_only=1

        local _wprof="" warp_allowed="" warp_dns="" warp_strat=""
        _wprof="$(_xmg_warp_tunnel_profile "$warp_v4" "$warp_v6" "$_host_v6_only")" || _wprof=""

        if [ -z "$_wprof" ]; then
            # 隧道没有任何地址族可用于承载目标，写进配置只会让内核起不来
            warp_on=0
            warp_outbound=""
        else
            IFS='|' read -r warp_allowed warp_dns warp_strat <<< "$_wprof" || true

            local warp_addr_json="\"$warp_v4\""
            if [ -n "$warp_v6" ]; then
                warp_addr_json="\"$warp_v4\",
          \"$warp_v6\""
            fi

            warp_outbound='    {
      "tag": "warp-out",
      "protocol": "wireguard",
      "targetStrategy": "'"$warp_strat"'",
      "settings": {
        "secretKey": "'"$esc_warp_privkey"'",
        "address": [
          '"$warp_addr_json"'
        ],
        "peers": [
          {
            "publicKey": "'"$esc_warp_pubkey"'",
            "endpoint": "'"$esc_warp_endpoint"'",
            "keepAlive": 25,
            "allowedIPs": [
              '"$warp_allowed"'
            ]
          }
        ],
        "reserved": '"$warp_reserved"',
        "noKernelTun": true,
        "mtu": 1280,
        "remoteDNS": [
          '"$warp_dns"'
        ]
      }
    }'
        fi
    fi

    local blocked_outbound='    {
      "protocol": "blackhole",
      "tag": "blocked",
      "settings": {}
    }'

    printf '  "outbounds": [\n'
    if [ "$warp_on" = "1" ]; then
        if [ "$warp_mode" = "routing" ]; then
            printf '%s,\n%s,\n%s\n' "$direct_outbound" "$warp_outbound" "$blocked_outbound"
        else
            printf '%s,\n%s,\n%s\n' "$warp_outbound" "$direct_outbound" "$blocked_outbound"
        fi
    else
        printf '%s,\n%s\n' "$direct_outbound" "$blocked_outbound"
    fi
    printf '  ]'

    # global 模式不生成 routing：
    #   默认出站就是 warp-out（outbounds 第一位），无需任何规则；
    #   旧版在这里插了一条 {"tcp/22" -> direct}，它没有 inboundTag 约束，
    #   会把所有经代理访问 22 端口的流量强制用宿主机真实 IP 直连（流量泄漏），
    #   而且宿主 SSH 压根不经过 Xray，这条规则保护不了任何东西。
    if [ "$warp_on" = "1" ] && [ "$warp_mode" = "routing" ]; then
        local _wgm='' _wd='' _wfirst=1
        local _wtun='' _wfb=0 _wcond=''
        _wgm="$(_xmg_render_get_val WARP_GEO_MODE auto)"
        _wtun="$(_xmg_warp_tunnel_family "$warp_v4" "$warp_v6")"
        _wcond="$(_xmg_warp_carrier_cidr "$_wtun" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}")"
        if _xmg_warp_need_ip_match "$_wtun" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}"; then
            _wfb=1
        fi

        printf ',\n'
        printf '  "routing": {\n'
        # 挂协议族条件时必须 IPIfNonMatch：第一轮域名匹配因 ip 为空而不命中，
        # 解析出目标地址族后第二轮才能判断这条规则是否适用。
        # 没有协议族条件时用 AsIs，避免每条未命中域名的连接白做一次 DNS。
        if [ "$_wfb" -eq 1 ]; then
            printf '    "domainStrategy": "IPIfNonMatch",\n'
        else
            printf '    "domainStrategy": "AsIs",\n'
        fi
        printf '    "rules": [\n'
        printf '      {\n'
        printf '        "type": "field",\n'
        printf '        "outboundTag": "warp-out",\n'
        printf '        "domain": [\n'
        while IFS= read -r _wd; do
            [ -n "$_wd" ] || continue
            if [ "$_wfirst" -eq 1 ]; then
                _wfirst=0
                printf '          "%s"' "$_wd"
            else
                printf ',\n          "%s"' "$_wd"
            fi
        done < <(xmg_warp_routing_domains "$_wgm")
        printf '\n        ]'
        # 协议族兜底：给 WARP 规则挂上「隧道能承载的地址族」条件。
        # 目标解析出另一族时规则不命中，自然落回默认出站 direct —— 不需要显式写回退规则。
        # 仅当宿主确实有那一族（回退真能通）时才启用，单栈宿主不为此付 DNS 解析开销。
        if [ "$_wfb" -eq 1 ] && [ -n "$_wcond" ]; then
            printf ',\n        "ip": [\n          "%s"\n        ]' "$_wcond"
        fi
        printf '\n      }'
        # 宿主缺失的那一族，只要隧道能承载就全量交给 WARP：
        # 纯 IPv4 宿主 + 双栈隧道时，IPv6 目标只有隧道这一条路能走。
        local _wonly=""
        _wonly="$(_xmg_warp_tunnel_only_cidr "$_wtun" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}")"
        if [ -n "$_wonly" ]; then
            # 先放行私有/保留段：全量网段字面上包含回环与内网，塞进隧道只会失败
            printf ',\n'
            printf '      {\n'
            printf '        "type": "field",\n'
            printf '        "outboundTag": "direct",\n'
            printf '        "ip": %s\n' "$(_xmg_warp_private_cidrs_json)"
            printf '      }'
            printf ',\n'
            printf '      {\n'
            printf '        "type": "field",\n'
            printf '        "outboundTag": "warp-out",\n'
            printf '        "ip": [\n'
            printf '          "%s"\n' "$_wonly"
            printf '        ]\n'
            printf '      }'
        fi
        printf '\n    ]\n'
        printf '  }\n'
    else
        printf '\n'
    fi
    printf '}\n'
}

# ===== 组装完整配置 =====
# $1 = socks 开关 0/1, $2 = vless 开关 0/1
xmg_render_config() {
    local socks_on="${1:-0}" vless_on="${2:-0}"
    local socks_bool=false vless_bool=false
    [ "$socks_on" = "1" ] && socks_bool=true
    [ "$vless_on" = "1" ] && vless_bool=true

    if [ -z "${XMG_NET_IPV4:-}" ] || [ -z "${XMG_NET_IPV6:-}" ]; then
        if declare -F xmg_detect_network >/dev/null 2>&1; then
            xmg_detect_network >/dev/null 2>&1 || true
        fi
    fi

    local is_ipv6_only=false
    if [ "${XMG_NET_IPV4:-}" = "0" ] && [ "${XMG_NET_IPV6:-}" = "1" ]; then
        is_ipv6_only=true
    fi

    local default_listen="0.0.0.0"
    [ "$is_ipv6_only" = "true" ] && default_listen="::"

    # 提取 SOCKS 参数
    local socks_listen socks_port socks_user socks_pass socks_udp socks_udp_bool
    socks_listen="$(_xmg_render_get_val PROXY_SOCKS_LISTEN "$default_listen")"
    socks_port="$(_xmg_render_get_val PROXY_SOCKS_PORT "1080")"
    socks_user="$(_xmg_render_get_val PROXY_SOCKS_USER "")"
    socks_pass="$(_xmg_render_get_val PROXY_SOCKS_PASS "")"
    socks_udp="$(_xmg_render_get_val PROXY_SOCKS_UDP "0")"
    socks_udp_bool=false
    [ "$socks_udp" = "1" ] && socks_udp_bool=true

    # 提取 VLESS 参数
    local vless_listen vless_port vless_domain vless_uuid vless_path vless_mode vless_cert_file vless_key_file
    vless_listen="$(_xmg_render_get_val PROXY_VLESS_LISTEN "$default_listen")"
    if [ "$is_ipv6_only" = "true" ]; then
        [ "$socks_listen" = "0.0.0.0" ] && socks_listen="::"
        [ "$vless_listen" = "0.0.0.0" ] && vless_listen="::"
    fi
    vless_port="$(_xmg_render_get_val PROXY_VLESS_PORT "443")"
    vless_domain="$(_xmg_render_get_val PROXY_VLESS_DOMAIN "")"
    vless_uuid="$(_xmg_render_get_val PROXY_VLESS_UUID "")"
    vless_path="$(_xmg_render_get_val PROXY_VLESS_PATH "/")"
    [ -n "$vless_path" ] || vless_path="/"
    vless_mode="$(_xmg_render_get_val PROXY_VLESS_MODE "auto")"
    vless_cert_file="$(_xmg_render_get_val PROXY_VLESS_CERT_FILE "")"
    vless_key_file="$(_xmg_render_get_val PROXY_VLESS_KEY_FILE "")"

    # 提取 REALITY 参数（与纯 Bash 引擎同一套兜底，保证两条渲染路径输出一致）
    local reality_on reality_listen reality_port reality_uuid reality_path reality_mode
    local reality_dest reality_sni reality_pk reality_sid reality_json="null"
    reality_on="$(_xmg_render_get_val PROXY_REALITY_ENABLED 0)"
    reality_listen="$(_xmg_render_get_val PROXY_REALITY_LISTEN "$default_listen")"
    reality_port="$(_xmg_render_get_val PROXY_REALITY_PORT "8443")"
    reality_uuid="$(_xmg_render_get_val PROXY_REALITY_UUID "")"
    reality_path="$(_xmg_render_get_val PROXY_REALITY_PATH "/xhttp")"
    reality_mode="$(_xmg_render_get_val PROXY_REALITY_MODE "auto")"
    reality_dest="$(_xmg_render_get_val PROXY_REALITY_DEST "www.microsoft.com:443")"
    reality_sni="$(_xmg_render_get_val PROXY_REALITY_SNI "www.microsoft.com")"
    reality_pk="$(_xmg_render_get_val PROXY_REALITY_PRIVATE_KEY "")"
    reality_sid="$(_xmg_render_get_val PROXY_REALITY_SHORT_ID "")"

    [ -n "$reality_listen" ] || reality_listen="$default_listen"
    if [ "$is_ipv6_only" = "true" ] && [ "$reality_listen" = "0.0.0.0" ]; then
        reality_listen="::"
    fi
    reality_port="$(_xmg_render_norm_int "$reality_port" 8443 1 65535)"
    [ -n "$reality_path" ] || reality_path="/xhttp"
    [ -n "$reality_mode" ] || reality_mode="auto"
    [ -n "$reality_dest" ] || reality_dest="www.microsoft.com:443"
    [ -n "$reality_sni" ] || reality_sni="www.microsoft.com"
    if [ -z "$reality_pk" ] || [ -z "$reality_uuid" ]; then
        reality_on=0
    fi
    if [ "$reality_on" = "1" ]; then
        reality_json="$(_xmg_render_reality_inbound_json \
            "$reality_listen" "$reality_port" "$reality_uuid" \
            "$reality_path" "$reality_mode" "$reality_dest" "$reality_sni" \
            "$reality_pk" "$reality_sid")"
    fi

    # 提取全局 policy bufferSize 与端口保底
    local bufsz
    bufsz="$(_xmg_render_get_val XMG_BUFFER_SIZE "4")"
    bufsz="$(_xmg_render_norm_int "$bufsz" 4 1 4096)"
    socks_port="$(_xmg_render_norm_int "$socks_port" 1080 1 65535)"
    vless_port="$(_xmg_render_norm_int "$vless_port" 443 1 65535)"

    # 提取日志参数
    local logdir error_log
    logdir="${XMG_XRAY_LOG_DIR:-${XMG_LOG_DIR:-/opt/xmg/log}/xray}"
    mkdir -p "$logdir" 2>/dev/null || true
    chmod 750 "$logdir" 2>/dev/null || true
    error_log="$logdir/error.log"
    touch "$error_log" 2>/dev/null || true
    chmod 640 "$error_log" 2>/dev/null || true

    # IPv6 模式判断已在顶部处理

    # 提取 WARP 参数
    local warp_on warp_mode warp_endpoint warp_privkey warp_pubkey warp_v4 warp_v6 warp_reserved
    warp_on="$(_xmg_render_get_val WARP_ENABLED 0)"
    warp_mode="$(_xmg_render_get_val WARP_MODE global)"
    warp_endpoint="$(_xmg_render_get_val WARP_ENDPOINT "")"
    warp_privkey="$(_xmg_render_get_val WARP_PRIVATE_KEY "")"
    warp_pubkey="$(_xmg_render_get_val WARP_PUBLIC_KEY "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=")"
    warp_v4="$(_xmg_render_get_val WARP_IPV4 "172.16.0.2")"
    warp_v6="$(_xmg_render_get_val WARP_IPV6 "")"
    warp_reserved="$(_xmg_render_get_val WARP_RESERVED "[0,0,0]")"

    local warp_bool=false
    [ "$warp_on" = "1" ] && warp_bool=true
    [ -n "$warp_mode" ] || warp_mode="global"

    if [ "$is_ipv6_only" = "true" ]; then
        if [ -z "$warp_endpoint" ] || [[ "$warp_endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
            warp_endpoint="[2606:4700:d0::a29f:c001]:2408"
        fi
    else
        [ -n "$warp_endpoint" ] || warp_endpoint="162.159.192.1:2408"
    fi
    if [[ "$warp_endpoint" =~ :0$ ]]; then
        warp_endpoint="${warp_endpoint%:0}:2408"
    fi
    if [ "$is_ipv6_only" = "true" ] && [[ "$warp_endpoint" != \[* ]] && [[ "$warp_endpoint" == *:* ]]; then
        local _ep_last="${warp_endpoint##*:}" _ep_head="${warp_endpoint%:*}"
        if [[ "$_ep_last" =~ ^[0-9]+$ ]] && [[ "$_ep_head" == *:* ]]; then
            warp_endpoint="[${_ep_head}]:${_ep_last}"
        fi
    fi
    [ -n "$warp_pubkey" ] || warp_pubkey="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    [ -n "$warp_v4" ] || warp_v4="172.16.0.2"
    [[ "$warp_v4" == */* ]] || warp_v4="${warp_v4}/32"
    if [ -n "$warp_v6" ] && [[ "$warp_v6" != */* ]]; then
        warp_v6="${warp_v6}/128"
    fi
    if [ -z "$warp_reserved" ] || [ "$warp_reserved" = "null" ]; then
        warp_reserved="[0, 0, 0]"
    elif [[ ! "$warp_reserved" =~ ^\[.*\]$ ]]; then
        local _clean_res="${warp_reserved//[[:space:]]/,}"
        while [[ "$_clean_res" =~ ,, ]]; do _clean_res="${_clean_res//,,/,}"; done
        _clean_res="${_clean_res#,}"
        _clean_res="${_clean_res%,}"
        warp_reserved="[$_clean_res]"
    fi

    local warp_addr_json
    if [ -n "$warp_v6" ]; then
        warp_addr_json="[\"$warp_v4\", \"$warp_v6\"]"
    else
        warp_addr_json="[\"$warp_v4\"]"
    fi

    # 单栈/双栈矩阵：allowedIPs / remoteDNS / targetStrategy 三者必须同源
    local _host_v6_only=0
    [ "$is_ipv6_only" = "true" ] && _host_v6_only=1
    local warp_allowed_ips='["0.0.0.0/0"]' warp_remote_dns='["1.1.1.1"]' warp_target_strategy="UseIPv4"
    local _wprof=""
    _wprof="$(_xmg_warp_tunnel_profile "$warp_v4" "$warp_v6" "$_host_v6_only")" || _wprof=""
    if [ -n "$_wprof" ]; then
        local _wa="" _wd="" _ws=""
        IFS='|' read -r _wa _wd _ws <<< "$_wprof" || true
        warp_allowed_ips="[$_wa]"
        warp_remote_dns="[$_wd]"
        warp_target_strategy="$_ws"
    else
        # 隧道无可用地址族，等同未启用，避免渲染出内核拒绝的配置
        warp_bool=false
    fi

    local has_jq=0
    if command -v jq >/dev/null 2>&1; then
        has_jq=1
    fi

    # 模板查找
    local tpl_file=""
    tpl_file="$(_xmg_find_config_template || true)"

    local rendered=0
    if [ "$has_jq" -eq 1 ]; then
        local jq_filter='
.log.error = $error_log |
.log.access = "none" |
.log.loglevel = "warning" |
.policy.levels["0"].bufferSize = ($buffer_size | tonumber) |
.policy.levels["0"].connIdle = 60 |
.dns.servers = $dns_servers |
.dns.queryStrategy = $stack_strategy |
(
  if $warp_on then
    {
      "tag": "warp-out",
      "protocol": "wireguard",
      "targetStrategy": $warp_target_strategy,
      "settings": {
        "secretKey": $warp_privkey,
        "address": $warp_address,
        "peers": [
          {
            "publicKey": $warp_pubkey,
            "endpoint": $warp_endpoint,
            "keepAlive": 25,
            "allowedIPs": $warp_allowed_ips
          }
        ],
        "reserved": $warp_reserved,
        "noKernelTun": true,
        "mtu": 1280,
        "remoteDNS": $warp_remote_dns
      }
    }
  else null end
) as $warp_out |
(
  if $warp_on then
    if $warp_mode == "routing" then
      .outbounds = [
        {
          "protocol": "freedom",
          "tag": "direct",
          "settings": {
            "finalRules": [
              {
                "action": "allow",
                "network": "tcp",
                "port": "22"
              },
              {
                "action": "allow"
              }
            ]
          },
          "streamSettings": {
            "sockopt": {
              "domainStrategy": $out_strategy
            }
          }
        },
        $warp_out,
        {
          "protocol": "blackhole",
          "tag": "blocked",
          "settings": {}
        }
      ] |
      .routing = {
        "domainStrategy": $warp_strategy,
        "rules": (
          [
            {
              "type": "field",
              "outboundTag": "warp-out",
              "domain": $routing_domains
            } + (if ($warp_ip_cond | length) > 0 then { "ip": $warp_ip_cond } else {} end)
          ]
          + (if ($warp_only_cidr | length) > 0 then [
               { "type": "field", "outboundTag": "direct", "ip": $warp_private_cidrs },
               { "type": "field", "outboundTag": "warp-out", "ip": $warp_only_cidr }
             ] else [] end)
        )
      }
    else
      .outbounds = [
        $warp_out,
        {
          "protocol": "freedom",
          "tag": "direct",
          "settings": {
            "finalRules": [
              {
                "action": "allow",
                "network": "tcp",
                "port": "22"
              },
              {
                "action": "allow"
              }
            ]
          },
          "streamSettings": {
            "sockopt": {
              "domainStrategy": $out_strategy
            }
          }
        },
        {
          "protocol": "blackhole",
          "tag": "blocked",
          "settings": {}
        }
      ]
    end
  else
    .outbounds = [
      {
        "protocol": "freedom",
        "tag": "direct",
        "settings": {
          "finalRules": [
            {
              "action": "allow",
              "network": "tcp",
              "port": "22"
            },
            {
              "action": "allow"
            }
          ]
        },
        "streamSettings": {
          "sockopt": {
            "domainStrategy": $out_strategy
          }
        }
      },
      {
        "protocol": "blackhole",
        "tag": "blocked",
        "settings": {}
      }
    ] |
    (if .routing and .routing.rules then
      .routing.rules = [.routing.rules[] | select((.outboundTag // "") != "warp-out")]
     else . end)
  end
) |
(
  (if $socks_on then [
    {
      "tag": "inbound-socks",
      "listen": $socks_listen,
      "port": ($socks_port | tonumber),
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "users": [
          {
            "user": $socks_user,
            "pass": $socks_pass
          }
        ],
        "udp": $socks_udp
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ] else [] end) +
  (if $vless_on then [
    {
      "tag": "inbound-vless",
      "listen": $vless_listen,
      "port": ($vless_port | tonumber),
      "protocol": "vless",
      "settings": {
        "users": [
          {
            "id": $vless_uuid,
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": $vless_path,
          "mode": $vless_mode
        },
        "security": "tls",
        "tlsSettings": {
          "serverName": $vless_domain,
          "rejectUnknownSni": true,
          "alpn": [
            "h2",
            "http/1.1"
          ],
          "minVersion": "1.2",
          "maxVersion": "1.3",
          "certificates": [
            {
              "usage": "encipherment",
              "certificateFile": $vless_cert_file,
              "keyFile": $vless_key_file
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ] else [] end) +
  (if $reality_on then [$reality_inbound] else [] end)
) as $active_inbounds |
.inbounds = $active_inbounds'

        # 协议族兜底：jq 路径与纯 Bash 路径共用同一套判定函数
        local _stack_strategy="UseIP" _out_strategy="UseIP"
        if [ "$is_ipv6_only" = "true" ] && { [ "$warp_bool" != "true" ] || [ -z "$warp_v4" ]; }; then
            _stack_strategy="UseIPv6"
            _out_strategy="UseIPv6"
        elif [ "$is_ipv6_only" = "true" ] && [ "$warp_mode" = "routing" ]; then
            _stack_strategy="UseIP"
            _out_strategy="UseIPv6"
        fi
        local _warp_tun="" _warp_strategy="AsIs" _warp_ip_cond="[]" _warp_only="[]"
        _warp_tun="$(_xmg_warp_tunnel_family "$warp_v4" "$warp_v6")"
        local _wo=""
        _wo="$(_xmg_warp_tunnel_only_cidr "$_warp_tun" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}")"
        if [ -n "$_wo" ]; then _warp_only="[\"$_wo\"]"; fi
        if _xmg_warp_need_ip_match "$_warp_tun" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}"; then
            _warp_strategy="IPIfNonMatch"
            local _wc=""
            _wc="$(_xmg_warp_carrier_cidr "$_warp_tun" "${XMG_NET_IPV4:-1}" "${XMG_NET_IPV6:-0}")"
            if [ -n "$_wc" ]; then _warp_ip_cond="[\"$_wc\"]"; fi
        fi

        local jq_args=(
            --arg error_log "$error_log"
            --argjson buffer_size "$bufsz"
            --argjson dns_servers "$(_xmg_render_dns_servers_json)"
            --argjson is_ipv6_only "$is_ipv6_only"
            --arg stack_strategy "$_stack_strategy"
            --arg out_strategy "$_out_strategy"
            --arg warp_strategy "$_warp_strategy"
            --argjson warp_ip_cond "$_warp_ip_cond"
            --argjson warp_only_cidr "$_warp_only"
            --argjson warp_private_cidrs "$(_xmg_warp_private_cidrs_json)"
            --argjson routing_domains "$(xmg_warp_routing_domains_json "$(_xmg_render_get_val WARP_GEO_MODE auto)")"
            --argjson socks_on "$socks_bool"
            --arg socks_listen "$socks_listen"
            --argjson socks_port "$socks_port"
            --arg socks_user "$socks_user"
            --arg socks_pass "$socks_pass"
            --argjson socks_udp "$socks_udp_bool"
            --argjson vless_on "$vless_bool"
            --arg vless_listen "$vless_listen"
            --argjson vless_port "$vless_port"
            --arg vless_domain "$vless_domain"
            --arg vless_uuid "$vless_uuid"
            --arg vless_path "$vless_path"
            --arg vless_mode "$vless_mode"
            --arg vless_cert_file "$vless_cert_file"
            --arg vless_key_file "$vless_key_file"
            --argjson reality_on "$([ "$reality_on" = "1" ] && printf 'true' || printf 'false')"
            --argjson reality_inbound "$reality_json"
            --argjson warp_on "$warp_bool"
            --arg warp_mode "$warp_mode"
            --arg warp_endpoint "$warp_endpoint"
            --arg warp_privkey "$warp_privkey"
            --arg warp_pubkey "$warp_pubkey"
            --argjson warp_address "$warp_addr_json"
            --argjson warp_reserved "$warp_reserved"
            --argjson warp_allowed_ips "$warp_allowed_ips"
            --argjson warp_remote_dns "$warp_remote_dns"
            --arg warp_target_strategy "$warp_target_strategy"
        )

        if [ -n "$tpl_file" ] && [ -f "$tpl_file" ]; then
            if MSYS_NO_PATHCONV=1 jq "${jq_args[@]}" "$jq_filter" < "$tpl_file"; then
                rendered=1
            fi
        else
            if printf '%s\n' "$_XMG_DEFAULT_CONFIG_TEMPLATE" | MSYS_NO_PATHCONV=1 jq "${jq_args[@]}" "$jq_filter"; then
                rendered=1
            fi
        fi
    fi

    # 纯 Bash 零依赖内建引擎（目标机 0.5C/215MB、BusyBox 或未安装 jq 时安全兜底与保底渲染）
    if [ "$rendered" -ne 1 ]; then
        _xmg_render_config_bash \
            "$socks_on" "$vless_on" \
            "$error_log" "$bufsz" "$is_ipv6_only" \
            "$socks_listen" "$socks_port" "$socks_user" "$socks_pass" "$socks_udp_bool" \
            "$vless_listen" "$vless_port" "$vless_domain" "$vless_uuid" \
            "$vless_path" "$vless_mode" "$vless_cert_file" "$vless_key_file" \
            "$warp_on" "$warp_mode" "$warp_endpoint" "$warp_privkey" "$warp_pubkey" \
            "$warp_v4" "$warp_v6" "$warp_reserved"
    fi
}
