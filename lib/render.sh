#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# render.sh - Xray 配置渲染器（纯函数）
#
# 说明：
#   - 每个 render_* 均为纯函数：state 进、JSON 片段出、无副作用、不写文件。
#     这样可脱离 VPS 单测，直接与官方文档比对字段名。
#   - 依赖：state.sh 必须先加载（xmg_render_policy 读 state 的bufferSize）。
#   - 输出风格：各块自带两空格缩进，且**除最后一块外都以逗号结尾**，
#     xmg_render_config 只需顺序拼接即可得到合法 JSON。
#
# 开销约束（目标机 0.5C/215MB，且可能是 BusyBox 用户态）：
#   - 零外部依赖，不使用 jq / python
#   - 全部用 printf 内建而非 `cat <<EOF`（后者每次调用 fork 一个 cat）
#   - 热路径不写 $(...)：转义与读 state 都有零 fork 的内部变体
#
# 字段依据：docs-research/ 下官方文档 https://lcuwx2016.github.io/xtls/config
#
# 本文件刻意不出现的字段（逐条有依据，不要"顺手补上"）：
#   network      -> 传输方式字段名是 streamSettings.method
#   tcpSettings  -> 原TCP 传输的字段名是 rawSettings
#   mux          -> 文档警告 XHTTP 下不可启用 mux.cool
#   flow         -> 文档说明 XTLS 仅在 TCP+TLS/REALITY 可用
#   stats / api  -> 本方案不启用
#   routing      -> 本方案不启用；因此 dns 也不写 tag（写了无人匹配）

#===== 安全加载 =====
if [ "${XMG_RENDER_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_RENDER_SH_LOADED=1

if [ -z "${BASH_VERSION:-}" ]; then
    echo "render.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== JSON 转义 =====
# 把转义结果写进调用方已声明的局部变量 <变量名>，全程零 fork。
# 与 state.sh 的 _state_val 同一套约定。内部专用。
_xmg_json_esc=""
_xmg_json_escape_into() {
    local __vname="$1" s="$2"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf -v "$__vname" '%s' "$s"
}

# 转义顺序不可调换：反斜杠必须先于双引号处理，否则 \" 会被二次转义成 \\"。
#
# 只处理 C0 里会被实际敲出来的 5 个控制字符（\b \f \n \r \t）；其余 C0
# （0x00-0x07、0x0B、0x0E-0x1F）不在此处理，理由是上游已挡住：
# xmg_state_set 拒绝含换行的值，日志路径也由面板自己拼出。
# 需要更强保证时，在边界处校验而不是在这里加逐字符循环——那会让
# 每次渲染都退化成 O(n) 的 bash 字符循环，在 0.5C 上不值。
xmg_json_escape() {
    local out=""
    _xmg_json_escape_into out "${1-}"
    printf '%s' "$out"
}

# ===== dns 块 =====
# 依据 config_dns.md:
#   - "https+local://host/dns-query" 即 DOHL，文档称"一般适合在服务端使用"，
#     且 DOH 请求不经路由组件、直接由 freedom 出站，对本方案最省一跳
#   - IP 形式合法：文档原文"有些服务商拥有 IP 别名的证书，可以直接写 IP 形式"
#   - 动态双栈适配：纯 IPv6 机器（XMG_NET_IPV4=0 && XMG_NET_IPV6=1）下渲染为
#     IPv6 DoH 地址（Cloudflare/Google IPv6）且 queryStrategy 设为 UseIPv6；
#     双栈或 IPv4 场景使用 IPv4 DoH (1.1.1.1/8.8.8.8) 且 queryStrategy 为 UseIP
#   - 全局 queryStrategy 优先：文档原文"全局值优先，当子项中的值与全局值冲突时，
#     子项的查询将空响应" -> 子项一律不写 queryStrategy
#   - 不用 localhost：文档原文"本机的 DNS 请求不受 Xray 控制"
#   - 不开 enableParallelQuery：并发查询在215MB 机器上是净内存损失
#   - 不写 hosts/tag：本方案不启用 routing，写了也无人匹配
xmg_render_dns() {
    if [ "${XMG_NET_IPV4:-}" = "0" ] && [ "${XMG_NET_IPV6:-}" = "1" ]; then
        printf '%s\n' \
            '  "dns": {' \
            '    "servers": [' \
            '      "https+local://[2606:4700:4700::1111]/dns-query",' \
            '      "https+local://[2001:4860:4860::8888]/dns-query"' \
            '    ],' \
            '    "queryStrategy": "UseIPv6"' \
            '  },'
    else
        printf '%s\n' \
            '  "dns": {' \
            '    "servers": [' \
            '      "https+local://1.1.1.1/dns-query",' \
            '      "https+local://8.8.8.8/dns-query"' \
            '    ],' \
            '    "queryStrategy": "UseIP"' \
            '  },'
    fi
}

# ===== policy 块 =====
# 依据 config_policy.md:
#   - bufferSize 单位 KB，平台默认 ARM=0 / ARM64=4 / 其它=512
#   - 统一走 XMG_BUFFER_SIZE（默认 4）：x86 低配机上 512KB/连接 的池子太奢侈
#   - connIdle: 60（默认 300 秒收缩至 60 秒）：迅速回收失效或半开套接字，防止 215M 小内存耗尽
#   - 键是字符串形式的数字（JSON 的要求），"0" 的双引号不可省略
xmg_render_policy() {
    local bufsz
    _state_val bufsz XMG_BUFFER_SIZE
    # state.env 是root 600 但可被手工编辑。bufferSize 只接受正整数，
    # 脏值直接渲染会让整份 config 变成非法 JSON 且报错点远离真正的原因，
    # 故就地退回默认而不是把垃圾写进配置。校验本身由 xmg_state_validate 负责。
    case "$bufsz" in
        ''|*[!0-9]*) bufsz=4 ;;
    esac
    [ "$bufsz" -ge 1 ] 2>/dev/null || bufsz=4

    printf '  "policy": {\n'
    printf '    "levels": {\n'
    printf '      "0": {\n'
    printf '        "bufferSize": %s,\n' "$bufsz"
    printf '        "connIdle": 60\n'
    printf '      }\n'
    printf '    }\n'
    printf '  },\n'
}

# ===== outbounds =====
# 依据 config_outbound.md: 列表中的第一个元素作为主 outbound
# 依据 config_transport.md: 出站的 streamSettings 只对"有传输层"的协议有意义，
#   freedom 直接出站只有 sockopt 可配，故不写 streamSettings。
# 依据 config_outbounds_freedom.md: settings 声明 domainStrategy 为 "UseIP"
#   （纯 IPv6 机器下动态适配为 "UseIPv6"），打通出站代理对内置 DoH 的依赖，
#   终结系统 /etc/resolv.conf 旁路问题。
#   本方案不开 routing，因此也不需要 block 出站。
xmg_render_outbounds() {
    local ds="UseIP"
    if [ "${XMG_NET_IPV4:-}" = "0" ] && [ "${XMG_NET_IPV6:-}" = "1" ]; then
        ds="UseIPv6"
    fi

    printf '%s\n' \
        '  "outbounds": [' \
        '    {' \
        '      "protocol": "freedom",' \
        '      "tag": "direct",' \
        '      "settings": {' \
        "        \"domainStrategy\": \"$ds\"" \
        '      }' \
        '    }' \
        '  ]'
}

# ===== log 块 =====
# 依据 config_log.md: access 的特殊值 "none" 表示关闭访问日志。
# 本方案不启用访问日志有两个原因：面板是自用场景，访问日志没有消费方；
# 且它是纯增长文件，在215MB 的盘上是长期负担。
xmg_render_log() {
    #优先用 xmg.sh 已规范化的 XMG_XRAY_LOG_DIR，未加载时退回拼接
    local dir="${XMG_XRAY_LOG_DIR:-${XMG_LOG_DIR:-/opt/xmg/log}/xray}"
    mkdir -p "$dir" 2>/dev/null || true
    local errpath="" esc=""
    errpath="$dir/error.log"
    _xmg_json_escape_into esc "$errpath"

    printf '  "log": {\n'
    printf '    "access": "none",\n'
    printf '    "error": "%s",\n' "$esc"
    printf '    "loglevel": "warning"\n'
    printf '  },\n'
}

# ===== 组装完整配置 =====
# $1= socks 开关 0/1, $2 = vless 开关 0/1
#
# 依赖 xmg_render_socks / xmg_render_vless（Task 5/6 实现），
# 本任务不提供占位实现。
xmg_render_config() {
    local socks_on="${1:-0}" vless_on="${2:-0}"
    local first=1

    printf '{\n'
    xmg_render_log
    xmg_render_dns
    xmg_render_policy

    printf '  "inbounds": [\n'
    if [ "$socks_on" = "1" ]; then
        xmg_render_socks "inbound-socks"
        first=0
    fi
    if [ "$vless_on" = "1" ]; then
        [ "$first" -eq 0 ] && printf ',\n'
        xmg_render_vless "inbound-vless"
        first=0
    fi
    # 两方案都未启用时的占位入站，保证 inbounds 非空、Xray 有入口可跑
    [ "$first" -eq 1 ] && printf '    {\n      "protocol": "tunnel",\n      "port": 0,\n      "tag": "empty"\n    }'

    printf '\n  ],\n'
    xmg_render_outbounds
    printf '\n}\n'
}

# ===== SOCKS5 入站 =====
# 字段依据 config/inbounds/socks.md:
#   - auth: "noauth" | "password"，默认 "noauth"
#   - users: [{ user, pass }]，仅当 auth 为 password 时有效
#   - udp: 默认 false
#   - userLevel: 对应 policy 中的用户等级
# 本方案为公网入口，必须 auth=password（用户确认），
# 因此绝不输出 noauth。
# 文档明确 SOCKS 不对传输加密、且 socks+tls 为"受限"，
# 用户确认本方案不加TLS，故不输出 streamSettings。
#
# 输出**不带尾逗号**：xmg_render_config 在元素之间自行补 ",\n"，并以
# "\n  ],\n" 收尾。元素若自带尾逗号，A+B 会拼出 ",,"、单方案会拼出尾逗号
# （"] ,"），两种都是非法 JSON——这正是本函数不写尾逗号的原因。
xmg_render_socks() {
    local tag="${1:-inbound-socks}"
    local listen port user pass udp

    listen="$(xmg_state_get PROXY_SOCKS_LISTEN)"
    port="$(xmg_state_get PROXY_SOCKS_PORT)"
    user="$(xmg_state_get PROXY_SOCKS_USER)"
    pass="$(xmg_state_get PROXY_SOCKS_PASS)"
    udp="$(xmg_state_get PROXY_SOCKS_UDP)"
    [ "$udp" = "1" ] && udp="true" || udp="false"

    printf '    {\n'
    printf '      "tag": "%s",\n' "$(xmg_json_escape "$tag")"
    printf '      "listen": "%s",\n' "$(xmg_json_escape "$listen")"
    printf '      "port": %s,\n' "$port"
    printf '      "protocol": "socks",\n'
    printf '      "settings": {\n'
    printf '        "auth": "password",\n'
    printf '        "users": [\n'
    printf '          {\n'
    printf '            "user": "%s",\n' "$(xmg_json_escape "$user")"
    printf '            "pass": "%s"\n' "$(xmg_json_escape "$pass")"
    printf '          }\n'
    printf '        ],\n'
    printf '        "udp": %s\n' "$udp"
    printf '      }\n'
    printf '    }\n'
}

# ===== VLESS + XHTTP + TLS 入站 =====
# 字段依据:
#   config/inbounds/vless.md      -> users[{id,level}], decryption
#   config/transport.md            -> method（不是 network！）, security
#   config/transports/xhttp.md     -> xhttpSettings{path,mode}
#   config/transports/tls.md       -> tlsSettings
#
# 刻意不写的字段（依据见 spec §5.5）:
#   - extra: 用户确认只暴露核心项；文档称 extra 应由服务发布者下发
#   - flow:  文档说明 XTLS 仅在 TCP+TLS/REALITY 可用，XHTTP 属HTTP 类传输
#   - mux:   文档警告使用 XHTTP 时不要启用 mux.cool
#   - email: 用户确认不暴露（且不开 stats，无副作用）
#
# 与 xmg_render_socks 同理：输出不带尾逗号，逗号由 xmg_render_config 补。
xmg_render_vless() {
    local tag="${1:-inbound-vless}"
    local listen port domain uuid path mode cert_file key_file

    listen="$(xmg_state_get PROXY_VLESS_LISTEN)"
    port="$(xmg_state_get PROXY_VLESS_PORT)"
    domain="$(xmg_state_get PROXY_VLESS_DOMAIN)"
    uuid="$(xmg_state_get PROXY_VLESS_UUID)"
    path="$(xmg_state_get PROXY_VLESS_PATH)"
    mode="$(xmg_state_get PROXY_VLESS_MODE)"
    cert_file="$(xmg_state_get PROXY_VLESS_CERT_FILE)"
    key_file="$(xmg_state_get PROXY_VLESS_KEY_FILE)"

    printf '    {\n'
    printf '      "tag": "%s",\n' "$(xmg_json_escape "$tag")"
    printf '      "listen": "%s",\n' "$(xmg_json_escape "$listen")"
    printf '      "port": %s,\n' "$port"
    printf '      "protocol": "vless",\n'
    printf '      "settings": {\n'
    printf '        "users": [\n'
    printf '          {\n'
    printf '            "id": "%s",\n' "$(xmg_json_escape "$uuid")"
    printf '            "level": 0\n'
    printf '          }\n'
    printf '        ],\n'
    printf '        "decryption": "none"\n'
    printf '      },\n'
    printf '      "streamSettings": {\n'
    printf '        "method": "xhttp",\n'
    printf '        "xhttpSettings": {\n'
    printf '          "path": "%s",\n' "$(xmg_json_escape "$path")"
    printf '          "mode": "%s"\n' "$(xmg_json_escape "$mode")"
    printf '        },\n'
    printf '        "security": "tls",\n'
    printf '        "tlsSettings": {\n'
    printf '          "serverName": "%s",\n' "$(xmg_json_escape "$domain")"
    printf '          "rejectUnknownSni": true,\n'
    printf '          "alpn": ["h2", "http/1.1"],\n'
    printf '          "minVersion": "1.2",\n'
    printf '          "maxVersion": "1.3",\n'
    printf '          "certificates": [\n'
    printf '            {\n'
    printf '              "usage": "encipherment",\n'
    printf '              "certificateFile": "%s",\n' "$(xmg_json_escape "$cert_file")"
    printf '              "keyFile": "%s"\n' "$(xmg_json_escape "$key_file")"
    printf '            }\n'
    printf '          ]\n'
    printf '        }\n'
    printf '      }\n'
    printf '    }\n'
}
