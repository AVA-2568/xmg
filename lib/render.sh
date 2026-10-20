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
          }
        ]
      },
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIP"
        }
      }
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
    [[ "$bufsz" =~ ^[0-9]+$ ]] && [ "$bufsz" -gt 0 ] || bufsz=4
    [[ "$socks_port" =~ ^[0-9]+$ ]] && [ "$socks_port" -gt 0 ] && [ "$socks_port" -le 65535 ] || socks_port=1080
    [[ "$vless_port" =~ ^[0-9]+$ ]] && [ "$vless_port" -gt 0 ] && [ "$vless_port" -le 65535 ] || vless_port=443

    [ -n "$error_log" ] || error_log="/opt/xmg/log/xray/error.log"
    local default_listen="0.0.0.0"
    [ "$is_ipv6_only" = "true" ] && default_listen="::"
    [ -n "$socks_listen" ] || socks_listen="$default_listen"
    [ -n "$vless_listen" ] || vless_listen="$default_listen"
    [ -n "$vless_path" ] || vless_path="/"
    [ -n "$vless_mode" ] || vless_mode="auto"
    [ -n "$socks_udp_bool" ] || socks_udp_bool=false

    # WARP 参数清洗与兜底
    [ -n "$warp_mode" ] || warp_mode="global"
    if [ "$is_ipv6_only" = "true" ]; then
        [ -n "$warp_endpoint" ] || warp_endpoint="[2606:4700:d0::a29f:c001]:2408"
    else
        [ -n "$warp_endpoint" ] || warp_endpoint="162.159.192.1:2408"
    fi
    if [[ "$warp_endpoint" =~ :0$ ]]; then
        warp_endpoint="${warp_endpoint%:0}:2408"
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
    if [ "$is_ipv6_only" = "true" ]; then
        dns_servers='[
      "https+local://[2606:4700:4700::1111]/dns-query",
      "https+local://[2001:4860:4860::8888]/dns-query",
      "localhost"
    ]'
        dns_query_strat="UseIPv6"
        out_strat="UseIPv6"
    else
        dns_servers='[
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
      "localhost"
    ]'
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

    if [ "$socks_on" != "1" ] && [ "$vless_on" != "1" ]; then
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
            printf '      }\n'
            printf '    }'
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
        local warp_addr_json="\"$warp_v4\""
        if [ -n "$warp_v6" ]; then
            warp_addr_json="\"$warp_v4\",
          \"$warp_v6\""
        fi
        warp_outbound='    {
      "tag": "warp-out",
      "protocol": "wireguard",
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
              "0.0.0.0/0",
              "::/0"
            ]
          }
        ],
        "reserved": '"$warp_reserved"',
        "noKernelTun": true,
        "mtu": 1280
      }
    }'
    fi

    printf '  "outbounds": [\n'
    if [ "$warp_on" = "1" ]; then
        if [ "$warp_mode" = "routing" ]; then
            printf '%s,\n%s\n' "$direct_outbound" "$warp_outbound"
        else
            printf '%s,\n%s\n' "$warp_outbound" "$direct_outbound"
        fi
    else
        printf '%s\n' "$direct_outbound"
    fi
    printf '  ]'

    if [ "$warp_on" = "1" ] && [ "$warp_mode" = "global" ]; then
        printf ',\n'
        printf '  "routing": {\n'
        printf '    "domainStrategy": "IPIfNonMatch",\n'
        printf '    "rules": [\n'
        printf '      {\n'
        printf '        "outboundTag": "direct",\n'
        printf '        "network": "tcp",\n'
        printf '        "port": "22"\n'
        printf '      }\n'
        printf '    ]\n'
        printf '  }\n'
    elif [ "$warp_on" = "1" ] && [ "$warp_mode" = "routing" ]; then
        printf ',\n'
        printf '  "routing": {\n'
        printf '    "domainStrategy": "IPIfNonMatch",\n'
        printf '    "rules": [\n'
        printf '      {\n'
        printf '        "type": "field",\n'
        printf '        "outboundTag": "warp-out",\n'
        printf '        "domain": [\n'
        printf '          "domain:openai.com",\n'
        printf '          "domain:chatgpt.com",\n'
        printf '          "domain:oaistatic.com",\n'
        printf '          "domain:oaiusercontent.com",\n'
        printf '          "domain:sora.com",\n'
        printf '          "domain:anthropic.com",\n'
        printf '          "domain:claude.ai",\n'
        printf '          "domain:gemini.google.com",\n'
        printf '          "domain:bard.google.com",\n'
        printf '          "domain:generativeai.googleapis.com",\n'
        printf '          "domain:makersuite.google.com",\n'
        printf '          "domain:deepmind.com",\n'
        printf '          "domain:deepmind.google",\n'
        printf '          "domain:copilot.microsoft.com",\n'
        printf '          "domain:sydney.bing.com",\n'
        printf '          "domain:perplexity.ai",\n'
        printf '          "domain:pplx.ai",\n'
        printf '          "domain:midjourney.com",\n'
        printf '          "domain:huggingface.co",\n'
        printf '          "domain:groq.com",\n'
        printf '          "domain:poe.com",\n'
        printf '          "domain:cursor.com",\n'
        printf '          "domain:cursor.sh",\n'
        printf '          "domain:netflix.com",\n'
        printf '          "domain:byteoversea.com",\n'
        printf '          "domain:ibytedtos.com",\n'
        printf '          "domain:musical.ly",\n'
        printf '          "domain:tiktokcdn.com",\n'
        printf '          "domain:tiktokv.com",\n'
        printf '          "domain:gamer.com.tw",\n'
        printf '          "domain:bilibili.tv",\n'
        printf '          "domain:viu.com",\n'
        printf '          "domain:viu.tv"\n'
        printf '        ]\n'
        if [ "$is_ipv6_only" = "true" ]; then
            printf '      },\n'
            printf '      {\n'
            printf '        "type": "field",\n'
            printf '        "outboundTag": "warp-out",\n'
            printf '        "ip": [\n'
            printf '          "0.0.0.0/0"\n'
            printf '        ]\n'
            printf '      }\n'
        else
            printf '      }\n'
        fi
        printf '    ]\n'
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
    vless_path="$(_xmg_render_get_val PROXY_VLESS_PATH "/xhttpx")"
    vless_mode="$(_xmg_render_get_val PROXY_VLESS_MODE "auto")"
    vless_cert_file="$(_xmg_render_get_val PROXY_VLESS_CERT_FILE "")"
    vless_key_file="$(_xmg_render_get_val PROXY_VLESS_KEY_FILE "")"

    # 提取全局 policy bufferSize 与端口保底
    local bufsz
    bufsz="$(_xmg_render_get_val XMG_BUFFER_SIZE "4")"
    [[ "$bufsz" =~ ^[0-9]+$ ]] && [ "$bufsz" -gt 0 ] || bufsz=4
    [[ "$socks_port" =~ ^[0-9]+$ ]] && [ "$socks_port" -gt 0 ] && [ "$socks_port" -le 65535 ] || socks_port=1080
    [[ "$vless_port" =~ ^[0-9]+$ ]] && [ "$vless_port" -gt 0 ] && [ "$vless_port" -le 65535 ] || vless_port=443

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
        [ -n "$warp_endpoint" ] || warp_endpoint="[2606:4700:d0::a29f:c001]:2408"
    else
        [ -n "$warp_endpoint" ] || warp_endpoint="162.159.192.1:2408"
    fi
    if [[ "$warp_endpoint" =~ :0$ ]]; then
        warp_endpoint="${warp_endpoint%:0}:2408"
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
.dns.servers = (
  if $is_ipv6_only then
    ["https+local://[2606:4700:4700::1111]/dns-query", "https+local://[2001:4860:4860::8888]/dns-query", "localhost"]
  else
    ["https+local://1.1.1.1/dns-query", "https+local://8.8.8.8/dns-query", "localhost"]
  end
) |
.dns.queryStrategy = (if $is_ipv6_only then "UseIPv6" else "UseIP" end) |
(
  if $warp_on then
    {
      "tag": "warp-out",
      "protocol": "wireguard",
      "settings": {
        "secretKey": $warp_privkey,
        "address": $warp_address,
        "peers": [
          {
            "publicKey": $warp_pubkey,
            "endpoint": $warp_endpoint,
            "keepAlive": 25,
            "allowedIPs": [
              "0.0.0.0/0",
              "::/0"
            ]
          }
        ],
        "reserved": $warp_reserved,
        "noKernelTun": true,
        "mtu": 1280
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
              }
            ]
          },
          "streamSettings": {
            "sockopt": {
              "domainStrategy": (if $is_ipv6_only then "UseIPv6" else "UseIP" end)
            }
          }
        },
        $warp_out
      ] |
      .routing = {
        "domainStrategy": "IPIfNonMatch",
        "rules": (
          [
            {
              "outboundTag": "direct",
              "network": "tcp",
              "port": "22"
            },
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
            }
          ] + (if $is_ipv6_only then [{ "type": "field", "outboundTag": "warp-out", "ip": [ "0.0.0.0/0" ] }] else [] end)
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
              }
            ]
          },
          "streamSettings": {
            "sockopt": {
              "domainStrategy": (if $is_ipv6_only then "UseIPv6" else "UseIP" end)
            }
          }
        }
      ] |
      .routing = {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
          {
            "outboundTag": "direct",
            "network": "tcp",
            "port": "22"
          }
        ]
      }
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
            }
          ]
        },
        "streamSettings": {
          "sockopt": {
            "domainStrategy": (if $is_ipv6_only then "UseIPv6" else "UseIP" end)
          }
        }
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
      }
    }
  ] else [] end)
) as $active_inbounds |
.inbounds = $active_inbounds'

        local jq_args=(
            --arg error_log "$error_log"
            --argjson buffer_size "$bufsz"
            --argjson is_ipv6_only "$is_ipv6_only"
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
            --argjson warp_on "$warp_bool"
            --arg warp_mode "$warp_mode"
            --arg warp_endpoint "$warp_endpoint"
            --arg warp_privkey "$warp_privkey"
            --arg warp_pubkey "$warp_pubkey"
            --argjson warp_address "$warp_addr_json"
            --argjson warp_reserved "$warp_reserved"
        )

        if [ -n "$tpl_file" ] && [ -f "$tpl_file" ]; then
            if MSYS_NO_PATHCONV=1 jq "${jq_args[@]}" "$jq_filter" < "$tpl_file"; then
                rendered=1
            fi
        elif [ -n "${XMG_CONFIG_TEMPLATE:-}" ]; then
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
