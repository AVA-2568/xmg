#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# XMG_MENU_LABEL: 节点代理管理
# proxy.sh - 代理方案管理与命令入口
#
# 说明：
#   - apply / status / disable / export 均以 state 为唯一真相，幂等
#   - apply 采用「内存草稿 + 校验通过后才落盘」的事务式流程：
#       * schema 校验失败 -> 返回 2，state.env 与 config.json 都不被触碰
#       * 内核校验失败   -> 返回 3（现网已按 state.sh 的规则回滚/保留）
#       * 运行失败       -> 返回 4
#   - 交互向导与 CLI 共用同一套函数，不重复实现逻辑
#
# 退出码约定：0 成功 / 2 校验失败 / 3 内核校验失败 / 4 运行失败

#===== 安全加载 =====
if [ "${XMG_PROXY_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_PROXY_SH_LOADED=1

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

if [ -z "${BASH_VERSION:-}" ]; then
    echo "proxy.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

XMG_HOME="${XMG_HOME:-/opt/xmg}"

# 基本日志函数回退
if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info()  { printf '[INFO] %s\n' "$*"; }
    xmg_warn()  { printf '[WARN] %s\n' "$*" >&2; }
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi

# ===== 依赖加载 =====
# proxy.sh 依赖 state.sh (状态管理与事务)、render.sh (配置渲染) 与 core.sh (内核版本/控制)
_XMG_PROXY_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F xmg_state_init >/dev/null 2>&1; then
    if [ -f "$_XMG_PROXY_LIBDIR/state.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_PROXY_LIBDIR/state.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/state.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/state.sh"
    fi
fi

if ! declare -F xmg_render_config >/dev/null 2>&1; then
    if [ -f "$_XMG_PROXY_LIBDIR/render.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_PROXY_LIBDIR/render.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/render.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/render.sh"
    fi
fi

if ! declare -F xmg_core_version >/dev/null 2>&1; then
    if [ -f "$_XMG_PROXY_LIBDIR/core.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_PROXY_LIBDIR/core.sh"
    elif [ -f "${XMG_LIB_DIR:-$XMG_HOME/lib}/core.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-$XMG_HOME/lib}/core.sh"
    fi
fi
unset _XMG_PROXY_LIBDIR

# acme.sh 证书申请路径。
# 安装目录自包含约束：acme.sh 与证书产物都必须落在 XMG_HOME 单一目录树内，
# 不得散落到 $HOME（默认 ~/.acme.sh）或 /etc/letsencrypt。
XMG_ACME_DIR="${XMG_ACME_DIR:-$XMG_HOME/acme.sh}"
XMG_ACME_CERT_FILE="${XMG_ACME_CERT_FILE:-$XMG_HOME/etc/xray/certs/fullchain.crt}"
XMG_ACME_KEY_FILE="${XMG_ACME_KEY_FILE:-$XMG_HOME/etc/xray/certs/priv.key}"
export XMG_HOME XMG_ACME_DIR XMG_ACME_CERT_FILE XMG_ACME_KEY_FILE

# ===== 参数解析 =====
# 把 --key value 形式的参数存入关联数组 PARAMS。
# 键名用下划线（socks_port）而非连字符，便于后续当变量名拼接。
declare -gA PARAMS=()

xmg_proxy_parse_args() {
    PARAMS=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --file)              PARAMS["file"]="${2:-}";              shift 2 || return 2 ;;
            --socks)             PARAMS["socks"]="${2:-}";             shift 2 || return 2 ;;
            --socks-port)        PARAMS["socks_port"]="${2:-}";        shift 2 || return 2 ;;
            --socks-listen)      PARAMS["socks_listen"]="${2:-}";      shift 2 || return 2 ;;
            --socks-user)        PARAMS["socks_user"]="${2:-}";        shift 2 || return 2 ;;
            --socks-pass)        PARAMS["socks_pass"]="${2:-}";        shift 2 || return 2 ;;
            --socks-udp)         PARAMS["socks_udp"]="${2:-}";         shift 2 || return 2 ;;
            --vless)             PARAMS["vless"]="${2:-}";             shift 2 || return 2 ;;
            --vless-port)        PARAMS["vless_port"]="${2:-}";        shift 2 || return 2 ;;
            --public-host)       PARAMS["public_host"]="${2:-}";       shift 2 || return 2 ;;
            --external-port)     PARAMS["external_port"]="${2:-}";     shift 2 || return 2 ;;
            --vless-external-port)   PARAMS["vless_external_port"]="${2:-}";   shift 2 || return 2 ;;
            --reality-external-port) PARAMS["reality_external_port"]="${2:-}"; shift 2 || return 2 ;;
            --vless-listen)      PARAMS["vless_listen"]="${2:-}";      shift 2 || return 2 ;;
            --vless-domain)      PARAMS["vless_domain"]="${2:-}";      shift 2 || return 2 ;;
            --vless-uuid)        PARAMS["vless_uuid"]="${2:-}";        shift 2 || return 2 ;;
            --vless-path)        PARAMS["vless_path"]="${2:-}";        shift 2 || return 2 ;;
            --vless-mode)        PARAMS["vless_mode"]="${2:-}";        shift 2 || return 2 ;;
            --vless-cert-source) PARAMS["vless_cert_source"]="${2:-}"; shift 2 || return 2 ;;
            --vless-cert-file)   PARAMS["vless_cert_file"]="${2:-}";   shift 2 || return 2 ;;
            --vless-key-file)    PARAMS["vless_key_file"]="${2:-}";    shift 2 || return 2 ;;
            --reality)           PARAMS["reality"]="${2:-}";           shift 2 || return 2 ;;
            --reality-port)      PARAMS["reality_port"]="${2:-}";      shift 2 || return 2 ;;
            --reality-listen)    PARAMS["reality_listen"]="${2:-}";    shift 2 || return 2 ;;
            --reality-uuid)      PARAMS["reality_uuid"]="${2:-}";      shift 2 || return 2 ;;
            --reality-path)      PARAMS["reality_path"]="${2:-}";      shift 2 || return 2 ;;
            --reality-mode)      PARAMS["reality_mode"]="${2:-}";      shift 2 || return 2 ;;
            --reality-dest)      PARAMS["reality_dest"]="${2:-}";      shift 2 || return 2 ;;
            --reality-sni)       PARAMS["reality_sni"]="${2:-}";       shift 2 || return 2 ;;
            --reality-private-key) PARAMS["reality_private_key"]="${2:-}"; shift 2 || return 2 ;;
            --reality-public-key|--reality-pbk) PARAMS["reality_public_key"]="${2:-}"; shift 2 || return 2 ;;
            --reality-sid)       PARAMS["reality_sid"]="${2:-}";       shift 2 || return 2 ;;
            *)
                xmg_error "未知参数: $1"
                return 2
                ;;
        esac
    done
    return 0
}

# on/off -> 1/0。合法时把结果打印到 stdout 并返回 0，非法返回 1。
# 注意：返回值是"是否合法"，取值靠 stdout，调用方必须用 $(...) 取。
_xmg_onoff() {
    case "${1:-}" in
        on|1|true|yes)   printf '1' ;;
        off|0|false|no)  printf '0' ;;
        *) return 1 ;;
    esac
    return 0
}

# ===== 事务式草稿 =====
# apply 先在内存里改 state，schema 校验通过才落盘。
# 采用 lib/state.sh 提供的暂存与单一事务落盘机制，消除 N+1 写放大。
_xmg_stage_reset() {
    xmg_state_stage_clear
}

_xmg_stage() {
    local __k="$1" __v="$2"
    xmg_state_stage "$__k" "$__v"
}

# 暂存一个"可空"参数：空值视为未提供，不暂存。
_xmg_stage_param() {
    [ -n "${2:-}" ] || return 0
    _xmg_stage "$1" "$2"
}

# 暂存一个开关参数：非法取值返回 2。
_xmg_stage_onoff() {
    local __key="$1" __raw="$2" __v=""
    __v="$(_xmg_onoff "$__raw")" || {
        xmg_error "$__key 的取值非法: '$__raw'（只能是 on/off、1/0、true/false）"
        return 2
    }
    _xmg_stage "$__key" "$__v"
}

# ===== apply =====
xmg_proxy_apply() {
    declare -F xmg_state_init >/dev/null 2>&1 && xmg_state_init
    xmg_proxy_parse_args "$@" || return 2
    _xmg_stage_reset

    # --file：覆盖式导入一份 state 文件到草稿（也参与落盘，保证幂等）
    if [ -n "${PARAMS[file]:-}" ]; then
        [ -r "${PARAMS[file]}" ] || {
            xmg_error "状态文件不可读: ${PARAMS[file]}"
            return 2
        }
        local line key val
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            case "$line" in *=*) ;; *) continue ;; esac
            key="${line%%=*}"; val="${line#*=}"
            _xmg_stage "$key" "${val%$'\r'}"
        done < "${PARAMS[file]}"
    fi

    # 显式参数覆盖草稿
    _xmg_stage_param PROXY_SOCKS_PORT   "${PARAMS[socks_port]:-}"
    _xmg_stage_param PROXY_SOCKS_LISTEN "${PARAMS[socks_listen]:-}"
    _xmg_stage_param PROXY_SOCKS_USER   "${PARAMS[socks_user]:-}"
    _xmg_stage_param PROXY_SOCKS_PASS   "${PARAMS[socks_pass]:-}"
    _xmg_stage_param PROXY_VLESS_PORT   "${PARAMS[vless_port]:-}"
    _xmg_stage_param PROXY_PUBLIC_HOST "${PARAMS[public_host]:-}"
    _xmg_stage_param PROXY_EXTERNAL_PORT "${PARAMS[external_port]:-}"
    _xmg_stage_param PROXY_VLESS_EXTERNAL_PORT "${PARAMS[vless_external_port]:-}"
    _xmg_stage_param PROXY_REALITY_EXTERNAL_PORT "${PARAMS[reality_external_port]:-}"
    _xmg_stage_param PROXY_VLESS_LISTEN "${PARAMS[vless_listen]:-}"
    _xmg_stage_param PROXY_VLESS_DOMAIN "${PARAMS[vless_domain]:-}"
    _xmg_stage_param PROXY_VLESS_UUID   "${PARAMS[vless_uuid]:-}"
    _xmg_stage_param PROXY_VLESS_PATH   "${PARAMS[vless_path]:-}"
    _xmg_stage_param PROXY_VLESS_MODE   "${PARAMS[vless_mode]:-}"
    _xmg_stage_param PROXY_VLESS_CERT_SOURCE "${PARAMS[vless_cert_source]:-}"
    _xmg_stage_param PROXY_VLESS_CERT_FILE   "${PARAMS[vless_cert_file]:-}"
    _xmg_stage_param PROXY_VLESS_KEY_FILE    "${PARAMS[vless_key_file]:-}"
    _xmg_stage_param PROXY_REALITY_PORT      "${PARAMS[reality_port]:-}"
    _xmg_stage_param PROXY_REALITY_LISTEN    "${PARAMS[reality_listen]:-}"
    _xmg_stage_param PROXY_REALITY_UUID      "${PARAMS[reality_uuid]:-}"
    _xmg_stage_param PROXY_REALITY_PATH      "${PARAMS[reality_path]:-}"
    _xmg_stage_param PROXY_REALITY_MODE      "${PARAMS[reality_mode]:-}"
    _xmg_stage_param PROXY_REALITY_DEST      "${PARAMS[reality_dest]:-}"
    _xmg_stage_param PROXY_REALITY_SNI       "${PARAMS[reality_sni]:-}"
    _xmg_stage_param PROXY_REALITY_PRIVATE_KEY "${PARAMS[reality_private_key]:-}"
    _xmg_stage_param PROXY_REALITY_PUBLIC_KEY  "${PARAMS[reality_public_key]:-}"
    _xmg_stage_param PROXY_REALITY_SHORT_ID  "${PARAMS[reality_sid]:-}"

    if [ -n "${PARAMS[socks]:-}" ]; then
        _xmg_stage_onoff PROXY_SOCKS_ENABLED "${PARAMS[socks]}" || {
            xmg_state_stage_clear; return 2
        }
    fi
    if [ -n "${PARAMS[socks_udp]:-}" ]; then
        _xmg_stage_onoff PROXY_SOCKS_UDP "${PARAMS[socks_udp]}" || {
            xmg_state_stage_clear; return 2
        }
    fi
    if [ -n "${PARAMS[vless]:-}" ]; then
        _xmg_stage_onoff PROXY_VLESS_ENABLED "${PARAMS[vless]}" || {
            xmg_state_stage_clear; return 2
        }
    fi
    if [ -n "${PARAMS[reality]:-}" ]; then
        _xmg_stage_onoff PROXY_REALITY_ENABLED "${PARAMS[reality]}" || {
            xmg_state_stage_clear; return 2
        }
    fi

    # REALITY 自举：UUID / privateKey / shortId 缺失时自动补齐。
    # 必须在 schema 校验之前完成，否则校验会直接以「不能为空」失败。
    if [ "$(xmg_state_get PROXY_REALITY_ENABLED 0)" = "1" ]; then
        local r_uuid="" r_pk="" r_pub="" r_sid="" _kp=""
        r_uuid="$(xmg_state_get PROXY_REALITY_UUID "")"
        [ -n "$r_uuid" ] || r_uuid="$(xmg_state_get PROXY_VLESS_UUID "")"
        if [ -z "$r_uuid" ]; then
            if [ -r /proc/sys/kernel/random/uuid ]; then
                r_uuid="$(tr -d '\r\n' < /proc/sys/kernel/random/uuid 2>/dev/null || true)"
            fi
            if [ -z "$r_uuid" ] && command -v openssl >/dev/null 2>&1; then
                r_uuid="$(openssl rand -hex 16 2>/dev/null | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
            fi
        fi
        [ -n "$r_uuid" ] && _xmg_stage PROXY_REALITY_UUID "$r_uuid"

        r_pk="$(xmg_state_get PROXY_REALITY_PRIVATE_KEY "")"
        if [ -z "$r_pk" ]; then
            _kp="$(xmg_proxy_reality_keygen_raw 2>/dev/null || true)"
            if [ -n "$_kp" ]; then
                read -r r_pk r_pub <<< "$_kp"
                _xmg_stage PROXY_REALITY_PRIVATE_KEY "$r_pk"
                if [ -n "$r_pub" ]; then
                    _xmg_stage PROXY_REALITY_PUBLIC_KEY "$r_pub"
                fi
                xmg_info "已自动生成 REALITY 密钥对（公钥: ${r_pub:-推导失败}）"
            fi
        fi

        # 私钥已在、公钥缺失（旧版本升级或手工导入）：能推导就补，link 不再依赖运行时反推
        if [ -n "$r_pk" ] && [ -z "$(xmg_state_get PROXY_REALITY_PUBLIC_KEY "")" ]; then
            local _derived_pub=""
            _derived_pub="$(_xmg_proxy_reality_pubkey "$r_pk" 2>/dev/null || true)"
            if [ -n "$_derived_pub" ]; then
                _xmg_stage PROXY_REALITY_PUBLIC_KEY "$_derived_pub"
            fi
        fi

        r_sid="$(xmg_state_get PROXY_REALITY_SHORT_ID "")"
        if [ -z "$r_sid" ] && command -v openssl >/dev/null 2>&1; then
            r_sid="$(openssl rand -hex 8 2>/dev/null || true)"
            [ -n "$r_sid" ] && _xmg_stage PROXY_REALITY_SHORT_ID "$r_sid"
        fi
    fi

    # schema 校验：读内存草稿。失败时丢弃草稿（state 文件从未被写），绝不触碰现网。
    if ! xmg_state_validate; then
        xmg_state_stage_clear
        return 2
    fi

    # 完善证书一致性与自动回退兜底
    local vless_on="${XMG_STATE[PROXY_VLESS_ENABLED]:-0}"
    local cert_src="${XMG_STATE[PROXY_VLESS_CERT_SOURCE]:-user}"
    if [ "$vless_on" = "1" ]; then
        local cf="${XMG_STATE[PROXY_VLESS_CERT_FILE]:-}"
        local kf="${XMG_STATE[PROXY_VLESS_KEY_FILE]:-}"
        if [ "$cert_src" = "acme" ]; then
            if [ -z "$cf" ]; then
                cf="$XMG_ACME_CERT_FILE"
                _xmg_stage PROXY_VLESS_CERT_FILE "$cf"
            fi
            if [ -z "$kf" ]; then
                kf="$XMG_ACME_KEY_FILE"
                _xmg_stage PROXY_VLESS_KEY_FILE "$kf"
            fi
        fi
        # 生产环境若证书文件不存在，自动通过 acme 申请或自签名保底
        if [ "${XMG_TEST_MODE:-0}" != "1" ] && { [ ! -f "$cf" ] || [ ! -f "$kf" ]; }; then
            local v_domain="${XMG_STATE[PROXY_VLESS_DOMAIN]:-example.com}"
            if [ "$cert_src" = "acme" ]; then
                xmg_info "检测到 ACME 证书未就绪，正在尝试申请证书..."
                if ! xmg_proxy_acme_issue "$v_domain"; then
                    xmg_warn "acme.sh 签发未通过（NAT机通常无80端口），自动回退为生成自签名证书..."
                    xmg_proxy_self_sign_cert "$v_domain" "$cf" "$kf" || true
                fi
            else
                xmg_warn "证书文件不存在: $cf，自动生成自签名证书保底..."
                xmg_proxy_self_sign_cert "$v_domain" "$cf" "$kf" || true
            fi
        fi
    fi

    # 渲染到临时文件（从已通过校验的草稿读出）
    # 注意：Xray 依赖 .json 后缀识别配置格式（无后缀时 xray run -test 会报 Failed to get format）
    local socks_on vless_on tmpdir tmp rc
    socks_on="${XMG_STATE[PROXY_SOCKS_ENABLED]:-0}"
    vless_on="${XMG_STATE[PROXY_VLESS_ENABLED]:-0}"
    tmpdir="$(mktemp -d)" || { xmg_error "无法创建临时目录"; xmg_state_stage_clear; return 4; }
    tmp="$tmpdir/config.json"
    if ! xmg_render_config "$socks_on" "$vless_on" > "$tmp"; then
        rm -rf "$tmpdir"
        xmg_state_stage_clear
        xmg_error "渲染配置失败"
        return 4
    fi

    # 双文件联合两阶段原子提交：由 xmg_state_commit 执行（Phase 1 预检失败绝不污染 state.env）
    xmg_state_commit "$tmp"
    rc=$?
    rm -rf "$tmpdir"
    return "$rc"
}

# ===== disable =====
# 只关掉目标方案；另一个方案与其余配置保持不变。
# 走 apply 的 --socks/--vless off，复用同一套校验与提交逻辑。
xmg_proxy_disable() {
    declare -F xmg_state_init >/dev/null 2>&1 && xmg_state_init
    case "${1:-}" in
        socks) xmg_proxy_apply --socks off ;;
        vless) xmg_proxy_apply --vless off ;;
        reality) xmg_proxy_apply --reality off ;;
        *)
            xmg_error "用法: xmg_proxy_disable <socks|vless|reality>"
            return 2
            ;;
    esac
}

# ===== REALITY 密钥 =====
# 输出 "privateKey publicKey"（一行两列），失败返回 1。
# 兼容 xray 新旧两种输出：PrivateKey/Public key 与 Private key/Password。
xmg_proxy_reality_keygen_raw() {
    local bin=""
    if declare -F xmg_xray_binary >/dev/null 2>&1; then
        bin="$(xmg_xray_binary 2>/dev/null || true)"
    fi
    [ -n "$bin" ] || bin="$(command -v xray 2>/dev/null || true)"
    [ -n "$bin" ] && [ -x "$bin" ] || return 1

    local out="" priv="" pub=""
    out="$("$bin" x25519 2>/dev/null || true)"
    [ -n "$out" ] || return 1
    priv="$(printf '%s\n' "$out" | sed -n 's/^[Pp]rivate[[:space:]]*[Kk]ey:[[:space:]]*//p' | head -n 1)"
    pub="$(printf '%s\n' "$out" | sed -n 's/^[Pp]ublic[[:space:]]*[Kk]ey:[[:space:]]*//p' | head -n 1)"
    [ -n "$pub" ] || pub="$(printf '%s\n' "$out" | sed -n 's/^Password:[[:space:]]*//p' | head -n 1)"
    [ -n "$priv" ] || return 1
    pub="$(_xmg_proxy_normalize_pbk "$pub")"
    printf '%s %s\n' "$priv" "$pub"
}

# 由私钥反推公钥（客户端链接里的 pbk）。失败时输出空串。
_xmg_proxy_reality_pubkey() {
    local pk="$1" bin=""
    [ -n "$pk" ] || return 1
    if declare -F xmg_xray_binary >/dev/null 2>&1; then
        bin="$(xmg_xray_binary 2>/dev/null || true)"
    fi
    [ -n "$bin" ] || bin="$(command -v xray 2>/dev/null || true)"
    [ -n "$bin" ] && [ -x "$bin" ] || return 1

    local out="" pub=""
    out="$("$bin" x25519 -i "$pk" 2>/dev/null || true)"
    [ -n "$out" ] || return 1
    pub="$(printf '%s\n' "$out" | sed -n 's/^[Pp]ublic[[:space:]]*[Kk]ey:[[:space:]]*//p' | head -n 1)"
    [ -n "$pub" ] || pub="$(printf '%s\n' "$out" | sed -n 's/^Password:[[:space:]]*//p' | head -n 1)"
    # 兼容不带标签的输出：取最后一个 43/44 位 base64 token（若同时打印私钥与公钥，公钥在后）
    if [ -z "$pub" ]; then
        pub="$(printf '%s\n' "$out" | grep -oE '[A-Za-z0-9_+/-]{43}=?' | tail -n 1)"
    fi
    [ -n "$pub" ] || return 1
    pub="$(_xmg_proxy_normalize_pbk "$pub")"
    printf '%s' "$pub"
}

xmg_proxy_reality_keygen() {
    local kp="" priv="" pub="" sid=""
    kp="$(xmg_proxy_reality_keygen_raw 2>/dev/null || true)"
    if [ -z "$kp" ]; then
        xmg_error "未找到 xray 内核，无法生成 REALITY 密钥（先执行 xmg core install）"
        return 1
    fi
    read -r priv pub <<< "$kp"
    command -v openssl >/dev/null 2>&1 && sid="$(openssl rand -hex 8 2>/dev/null || true)"

    echo "REALITY 密钥对（privateKey 填服务端，pbk 填客户端）:"
    echo "  privateKey: $priv"
    echo "  publicKey : ${pub:-（当前内核未输出，可用 xray x25519 -i <privateKey> 反推）}"
    [ -n "$sid" ] && echo "  shortId   : $sid（1-16 位十六进制，可留空）"
    return 0
}

# ===== REALITY 分享链接 =====
# REALITY 不需要域名：节点地址是 VPS 公网 IP，伪装目标是 sni/dest。
# 私网 / 不可全局路由地址判定（域名返回 1，按"非私网"处理）
_xmg_proxy_ip_is_private() {
    local ip="${1:-}"
    case "$ip" in
        ''|*[!0-9A-Fa-f:.]*) return 1 ;;
    esac
    if [[ "$ip" == *:* ]]; then
        case "$ip" in
            ::1|::|fe80:*|fc*|fd*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local a="" b=""
    IFS=. read -r a b _ <<< "$ip"
    case "$a" in
        10|127|0) return 0 ;;
        169) [ "$b" = "254" ] && return 0 ;;
        172) [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0 ;;
        192) [ "$b" = "168" ] && return 0 ;;
        100) [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0 ;;
    esac
    return 1
}

# 返回用于客户端链接的主机地址。
# 优先级：XMG_PUBLIC_HOST 环境变量 → state 中的 PROXY_PUBLIC_HOST → 本机全局地址 →
# Cloudflare trace 探测出口公网 IP。NAT / 容器里本机只能看到私网地址，必须探测或显式声明，
# 否则链接里会出现 10.x / 172.17.x，客户端根本连不上。
_xmg_proxy_server_host() {
    local h=""
    if [ -n "${XMG_PUBLIC_HOST:-}" ]; then
        h="$XMG_PUBLIC_HOST"
    fi
    if [ -z "$h" ] && declare -F xmg_state_get >/dev/null 2>&1; then
        h="$(xmg_state_get PROXY_PUBLIC_HOST "")"
    fi
    h="${h#[}"
    h="${h%]}"
    if [ -n "$h" ]; then
        printf '%s' "$h"
        return 0
    fi

    local cand="" c=""
    if command -v ip >/dev/null 2>&1; then
        cand="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
    fi
    if [ -z "$cand" ]; then
        # BusyBox hostname 没有 -I
        cand="$(hostname -I 2>/dev/null || true)"
    fi
    if [ -z "$cand" ] && command -v ip >/dev/null 2>&1; then
        cand="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
    fi

    for c in $cand; do
        c="${c%%/*}"
        if ! _xmg_proxy_ip_is_private "$c"; then
            h="$c"
            break
        fi
    done
    if [ -n "$h" ]; then
        printf '%s' "$h"
        return 0
    fi

    # 本机只有私网地址：探测出口公网 IP（NAT/OVZ 场景）
    if command -v curl >/dev/null 2>&1; then
        local trace="" fam=""
        trace="$(curl -4 -sS --connect-timeout 3 --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
        h="$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -n 1)"
        if _xmg_proxy_ip_is_private "$h"; then
            h=""
        fi
        if [ -z "$h" ] && [ "${XMG_NET_IPV6:-0}" = "1" ]; then
            trace="$(curl -6 -sS --connect-timeout 3 --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
            h="$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -n 1)"
            if _xmg_proxy_ip_is_private "$h"; then
                h=""
            fi
        fi
    fi

    printf '%s' "${h:-<SERVER_IP>}"
}

# NAT 端口映射机型：外部公网端口无法从本机可靠探测，只接受显式声明。
# 已声明则客户端链接用外部端口；未声明且识别为 NAT 机型时给出明确提示。
_xmg_proxy_client_port() {
    local listen_port="$1" specific_key="${2:-}" ext="" specific=""
    # 方案级映射优先（VLESS 443 与 REALITY 8443 在 NAT 上通常映射到不同公网端口），
    # 未声明时回落到全局 PROXY_EXTERNAL_PORT，兼容单入站旧配置。
    if [ -n "$specific_key" ]; then
        specific="$specific_key"
        ext="$(xmg_state_get "$specific_key" "" 2>/dev/null || true)"
        case "$ext" in
            ''|*[!0-9]*) ext="" ;;
            *)
                if [ "$ext" -lt 1 ] || [ "$ext" -gt 65535 ]; then
                    ext=""
                fi
                ;;
        esac
    fi
    if [ -z "$ext" ]; then
        ext="$(xmg_state_get PROXY_EXTERNAL_PORT "" 2>/dev/null || true)"
        case "$ext" in
            ''|*[!0-9]*) ext="" ;;
            *)
                if [ "$ext" -lt 1 ] || [ "$ext" -gt 65535 ]; then
                    ext=""
                fi
                ;;
        esac
    fi
    if [ -n "$ext" ]; then
        printf '%s' "$ext"
        return 0
    fi
    if [ -z "${XMG_NET_NAT:-}" ] && declare -F xmg_detect_network >/dev/null 2>&1; then
        xmg_detect_network >/dev/null 2>&1 || true
    fi
    if [ "${XMG_NET_NAT:-0}" = "1" ]; then
        xmg_warn "NAT 端口映射机型未声明外部端口，客户端链接暂用内部监听端口 ${listen_port}"
        case "$specific" in
            PROXY_VLESS_EXTERNAL_PORT)   xmg_warn "请执行: xmg proxy apply --vless-external-port <公网端口>" ;;
            PROXY_REALITY_EXTERNAL_PORT) xmg_warn "请执行: xmg proxy apply --reality-external-port <公网端口>" ;;
            *)                           xmg_warn "请执行: xmg proxy apply --external-port <映射后的公网端口>" ;;
        esac
    fi
    printf '%s' "$listen_port"
}

# ===== 分享链接取值编码 =====
# VLESS URI 的 query 值必须按 RFC 3986 百分号编码。
# 过去只把 "/" 替换成 %2F：path 里出现 ? & # 空格 或非 ASCII 时链接会被截断/串参数，
# 客户端解析出的 path 与 SNI 对不上，表现为「节点导入成功但连不上」。
_xmg_urlencode() {
    local s="${1-}" out="" c=""
    local i=0
    # 必须是字节语义：UTF-8 多字节字符逐字符替换会得到错误编码
    local LC_ALL=C

    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            # ":" / "@" 属于 RFC 3986 query 的 pchar，保留原样：
            # IPv6 字面量 SNI 若被编码成 %3A，部分客户端会解析失败。
            [A-Za-z0-9.~_:@-]) out="$out$c" ;;
            *)
                printf -v c '%%%02X' "'$c"
                out="$out$c"
                ;;
        esac
    done
    printf '%s' "$out"
}

# X25519 公钥统一成 URL-safe 形式（43 字符、无 padding），避免 + / 在 query 里被误解析
_xmg_proxy_normalize_pbk() {
    local k="${1-}"
    k="${k//+/-}"
    k="${k//\//_}"
    k="${k%%=*}"
    printf '%s' "$k"
}

# 自签证书判定：0=自签，1=CA 签发，2=无法判定。
# 只有自签才在直连链接里附带 allowInsecure=1，ACME/CA 证书带这个参数
# 等于让客户端放弃校验，属于无谓的安全降级；无法判定时按自签处理（保连通）。
_xmg_proxy_cert_self_signed() {
    local f="${1:-}" subj="" iss=""
    if [ -z "$f" ] || [ ! -r "$f" ]; then
        return 2
    fi
    command -v openssl >/dev/null 2>&1 || return 2
    subj="$(openssl x509 -in "$f" -noout -subject 2>/dev/null || true)"
    iss="$(openssl x509 -in "$f" -noout -issuer 2>/dev/null || true)"
    if [ -z "$subj" ] || [ -z "$iss" ]; then
        return 2
    fi
    if [ "$subj" = "$iss" ]; then
        return 0
    fi
    return 1
}

xmg_proxy_reality_link() {
    declare -F xmg_state_init >/dev/null 2>&1 && xmg_state_init

    local uuid="" port="" path="" mode="" sni="" pk="" sid="" pub="" host=""
    uuid="$(xmg_state_get PROXY_REALITY_UUID "")"
    [ -n "$uuid" ] || uuid="$(xmg_state_get PROXY_VLESS_UUID "")"
    port="$(_xmg_proxy_client_port "$(xmg_state_get PROXY_REALITY_PORT 8443)" PROXY_REALITY_EXTERNAL_PORT)"
    path="$(xmg_state_get PROXY_REALITY_PATH "/xhttp")"
    mode="$(xmg_state_get PROXY_REALITY_MODE "auto")"
    sni="$(xmg_state_get PROXY_REALITY_SNI "www.microsoft.com")"
    pk="$(xmg_state_get PROXY_REALITY_PRIVATE_KEY "")"
    sid="$(xmg_state_get PROXY_REALITY_SHORT_ID "")"
    [ -n "$uuid" ] || return 1

    # 公钥优先取 state（apply 时已随密钥对落盘），旧数据再从私钥反推一次
    pub="$(xmg_state_get PROXY_REALITY_PUBLIC_KEY "")"
    if [ -z "$pub" ]; then
        pub="$(_xmg_proxy_reality_pubkey "$pk" 2>/dev/null || true)"
    fi
    if [ -z "$pub" ]; then
        xmg_error "缺少 REALITY 公钥 (pbk)，无法生成可用链接"
        xmg_warn "执行 xmg proxy apply --reality on 让 XMG 自动补全，或用 xmg proxy keygen 生成后导入"
        return 1
    fi
    pub="$(_xmg_proxy_normalize_pbk "$pub")"
    host="$(_xmg_proxy_server_host)"
    if [ -z "$host" ] || [ "$host" = "<SERVER_IP>" ]; then
        xmg_error "无法确定本机公网地址，REALITY 链接不可用"
        xmg_warn "请设置环境变量 XMG_PUBLIC_HOST=<公网 IP> 后重试（NAT 机型填映射后的公网地址）"
        return 1
    fi
    if [[ "$host" =~ : ]] && [[ ! "$host" =~ ^\[.*\]$ ]]; then
        host="[${host}]"
    fi

    # 结构遵循 vless://<uuid>@<host>:<port>?<query>#<remark>
    # spx 是 REALITY 的 spiderX，官方示例显式给出；缺省时部分客户端会留空导致回落异常。
    local q_uuid="" q_sni="" q_pbk="" q_sid="" q_path=""
    q_uuid="$(_xmg_urlencode "$uuid")"
    q_sni="$(_xmg_urlencode "$sni")"
    q_pbk="$(_xmg_urlencode "$pub")"
    q_sid="$(_xmg_urlencode "$sid")"
    q_path="$(_xmg_urlencode "$path")"

    # shortId 未启用时不发空 sid 参数，避免部分客户端把它当成非法值
    local sid_q=""
    if [ -n "$q_sid" ]; then
        sid_q="&sid=${q_sid}"
    fi

    local link="vless://${q_uuid}@${host}:${port}?encryption=none&security=reality&sni=${q_sni}&fp=chrome&pbk=${q_pbk}${sid_q}&spx=%2F&type=xhttp&path=${q_path}&mode=${mode}#XMG-VLESS-REALITY"

    echo "==================== REALITY 节点链接 ===================="
    echo "服务端 privateKey: 不写入链接（REALITY 的安全要求，客户端只需要公钥）"
    echo "客户端 pbk(公钥): $pub"
    if [ -n "$sid" ]; then
        echo "客户端 sid(shortId): $sid"
    else
        echo "客户端 sid(shortId): 未启用（服务端 shortIds 含空串）"
    fi
    printf '%s\n' "$link"
    echo "=========================================================="
    return 0
}

# ===== 客户端节点分享链接生成器 =====
xmg_proxy_vless_link() {
    declare -F xmg_state_init >/dev/null 2>&1 && xmg_state_init
    local uuid domain path mode port
    uuid="$(xmg_state_get PROXY_VLESS_UUID)"
    domain="$(xmg_state_get PROXY_VLESS_DOMAIN)"
    path="$(xmg_state_get PROXY_VLESS_PATH "/xhttpx")"
    mode="$(xmg_state_get PROXY_VLESS_MODE "auto")"
    port="$(_xmg_proxy_client_port "$(xmg_state_get PROXY_VLESS_PORT "443")" PROXY_VLESS_EXTERNAL_PORT)"

    if [ -z "$uuid" ] || [ -z "$domain" ]; then
        return 1
    fi

    local q_uuid="" q_domain="" q_path=""
    q_uuid="$(_xmg_urlencode "$uuid")"
    q_domain="$(_xmg_urlencode "$domain")"
    q_path="$(_xmg_urlencode "$path")"

    # 1. CDN 代理模式（客户端连接 443，走 Cloudflare CDN 隐藏真实 IP）
    # 注意：XHTTP 是 TCP/TLS 传输，没有 QUIC/HTTP3 分支，ALPN 只能是 h2 / http1.1。
    # 早期写的 alpn=h3 属于无效声明，严格客户端会握手失败。
    local cdn_link="vless://${q_uuid}@${q_domain}:443?encryption=none&security=tls&sni=${q_domain}&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&host=${q_domain}&path=${q_path}&mode=${mode}#XMG-VLESS-CDN"

    # 2. 直连模式（直连当前主机端口；仅自签证书才附带 allowInsecure=1）
    local direct_host="$domain"
    if [[ "$direct_host" =~ : ]] && [[ ! "$direct_host" =~ ^\[.*\]$ ]]; then
        direct_host="[${direct_host}]"
    fi
    local insecure=""
    if [ "$(xmg_state_get PROXY_VLESS_CERT_SOURCE "user")" = "user" ]; then
        local cert_rc=2
        if _xmg_proxy_cert_self_signed "$(xmg_state_get PROXY_VLESS_CERT_FILE "")"; then
            cert_rc=0
        else
            cert_rc=$?
        fi
        # 0=自签 / 2=无法判定（没有 openssl 或路径不可读）→ 保守附带
        if [ "$cert_rc" -eq 0 ] || [ "$cert_rc" -eq 2 ]; then
            insecure="&allowInsecure=1"
        fi
    fi
    local direct_link="vless://${q_uuid}@${direct_host}:${port}?encryption=none&security=tls&sni=${q_domain}&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&host=${q_domain}&path=${q_path}&mode=${mode}${insecure}#XMG-VLESS-Direct"

    echo "==================== 客户端节点分享链接 ===================="
    echo "[方案 A：Cloudflare CDN 代理模式] (推荐，走 443 端口):"
    printf '%s\n' "$cdn_link"
    echo
    printf '[方案 B：源站直连模式] (直连端口 %s；证书校验策略随证书来源自动适配):\n' "$port"
    printf '%s\n' "$direct_link"
    echo "============================================================"
    return 0
}

# ===== status =====
# 内核版本回显兜底：CLI 子命令按需加载，core.sh 可能未加载。
_xmg_proxy_kernel_version() {
    local v=""
    if declare -F xmg_core_version >/dev/null 2>&1; then
        v="$(xmg_core_version 2>/dev/null)" || true
    fi
    if [ -n "$v" ]; then
        printf '%s' "$v"
    else
        printf '(未安装)'
    fi
}

xmg_proxy_status() {
    declare -F xmg_state_init >/dev/null 2>&1 && xmg_state_init
    local json=0
    [ "${1:-}" = "--json" ] && json=1

    local socks_on vless_on socks_port vless_port vless_domain vless_path vless_mode
    socks_on="$(xmg_state_get PROXY_SOCKS_ENABLED)"
    vless_on="$(xmg_state_get PROXY_VLESS_ENABLED)"
    socks_port="$(xmg_state_get PROXY_SOCKS_PORT)"
    vless_port="$(xmg_state_get PROXY_VLESS_PORT)"
    vless_domain="$(xmg_state_get PROXY_VLESS_DOMAIN)"
    vless_path="$(xmg_state_get PROXY_VLESS_PATH)"
    vless_mode="$(xmg_state_get PROXY_VLESS_MODE)"

    # JSON 分支：绝不输出任何密码/私钥字段
    if [ "$json" -eq 1 ]; then
        local reality_on reality_port reality_sni ext_port ext_json="null"
        local vless_ext_json="null" reality_ext_json="null" tmp_ext=""
        reality_on="$(xmg_state_get PROXY_REALITY_ENABLED 0)"
        reality_port="$(xmg_state_get PROXY_REALITY_PORT 8443)"
        reality_sni="$(xmg_state_get PROXY_REALITY_SNI "www.microsoft.com")"
        # state.env 可能被手工改坏：非 0/1 或非数字一律归一，避免输出非法 JSON
        [ "$reality_on" = "1" ] || reality_on=0
        case "$reality_port" in
            ''|*[!0-9]*) reality_port=8443 ;;
        esac
        ext_port="$(xmg_state_get PROXY_EXTERNAL_PORT "")"
        tmp_ext="$(xmg_state_get PROXY_VLESS_EXTERNAL_PORT "")"
        case "$tmp_ext" in ''|*[!0-9]*) ;; *) vless_ext_json="$tmp_ext" ;; esac
        tmp_ext="$(xmg_state_get PROXY_REALITY_EXTERNAL_PORT "")"
        case "$tmp_ext" in ''|*[!0-9]*) ;; *) reality_ext_json="$tmp_ext" ;; esac
        case "$ext_port" in
            ''|*[!0-9]*) ;;
            *) ext_json="$ext_port" ;;
        esac

        printf '{\n'
        printf '  "socks_enabled": %s,\n' "$socks_on"
        printf '  "socks_listen": "%s",\n' "$(xmg_json_escape "$(xmg_state_get PROXY_SOCKS_LISTEN)")"
        printf '  "socks_port": %s,\n' "$socks_port"
        printf '  "socks_user": "%s",\n' "$(xmg_json_escape "$(xmg_state_get PROXY_SOCKS_USER)")"
        printf '  "vless_enabled": %s,\n' "$vless_on"
        printf '  "vless_listen": "%s",\n' "$(xmg_json_escape "$(xmg_state_get PROXY_VLESS_LISTEN)")"
        printf '  "vless_port": %s,\n' "$vless_port"
        printf '  "vless_domain": "%s",\n' "$(xmg_json_escape "$vless_domain")"
        printf '  "vless_path": "%s",\n' "$(xmg_json_escape "$vless_path")"
        printf '  "vless_mode": "%s",\n' "$(xmg_json_escape "$vless_mode")"
        printf '  "reality_enabled": %s,\n' "$reality_on"
        printf '  "reality_port": %s,\n' "$reality_port"
        printf '  "reality_sni": "%s",\n' "$(xmg_json_escape "$reality_sni")"
        printf '  "external_port": %s,\n' "$ext_json"
        printf '  "vless_external_port": %s,\n' "$vless_ext_json"
        printf '  "reality_external_port": %s,\n' "$reality_ext_json"
        printf '  "public_host": "%s",\n' "$(xmg_json_escape "$(xmg_state_get PROXY_PUBLIC_HOST "")")"
        printf '  "buffer_size": %s,\n' "$(xmg_state_get XMG_BUFFER_SIZE)"
        printf '  "kernel_channel": "%s"\n' "$(xmg_json_escape "$(xmg_state_get XRAY_CHANNEL)")"
        printf '}\n'
        return 0
    fi

    echo "========== 代理方案状态 =========="
    echo
    echo "[SOCKS5]"
    if [ "$socks_on" = "1" ]; then
        echo "  状态: 启用"
        echo "  监听: $(xmg_state_get PROXY_SOCKS_LISTEN):$socks_port"
        echo "  用户: $(xmg_state_get PROXY_SOCKS_USER)"
        echo "  UDP : $(xmg_state_get PROXY_SOCKS_UDP)"
    else
        echo "  状态: 未启用"
    fi
    echo
    echo "[VLESS + XHTTP + TLS]"
    if [ "$vless_on" = "1" ]; then
        echo "  状态: 启用"
        echo "  监听: $(xmg_state_get PROXY_VLESS_LISTEN):$vless_port"
        local vless_ext=""
        vless_ext="$(xmg_state_get PROXY_VLESS_EXTERNAL_PORT "")"
        if [ -n "$vless_ext" ]; then
            echo "  外部: $vless_ext (NAT 映射)"
        fi
        echo "  域名: $vless_domain"
        echo "  path: $vless_path"
        echo "  mode: $vless_mode"
        echo "  证书: $(xmg_state_get PROXY_VLESS_CERT_SOURCE)"
        echo
        xmg_proxy_vless_link 2>/dev/null || true
    else
        echo "  状态: 未启用"
    fi
    echo
    echo "[VLESS + XHTTP + REALITY]"
    local reality_on="0"
    reality_on="$(xmg_state_get PROXY_REALITY_ENABLED 0)"
    if [ "$reality_on" = "1" ]; then
        echo "  状态: 启用（无证书，伪装目标 $(xmg_state_get PROXY_REALITY_DEST "www.microsoft.com:443")）"
        echo "  监听: $(xmg_state_get PROXY_REALITY_LISTEN):$(xmg_state_get PROXY_REALITY_PORT 8443)"
        local reality_ext=""
        reality_ext="$(xmg_state_get PROXY_REALITY_EXTERNAL_PORT "")"
        if [ -n "$reality_ext" ]; then
            echo "  外部: $reality_ext (NAT 映射)"
        fi
        echo "  SNI : $(xmg_state_get PROXY_REALITY_SNI "www.microsoft.com")"
        echo "  path: $(xmg_state_get PROXY_REALITY_PATH "/xhttp")"
        echo "  mode: $(xmg_state_get PROXY_REALITY_MODE "auto")"
        echo
        if ! xmg_proxy_reality_link 2>/dev/null; then
            xmg_warn "REALITY 链接不可用：缺少公钥 (pbk)，执行 xmg proxy apply --reality on 自动补全"
        fi
    else
        echo "  状态: 未启用"
    fi
    echo
    echo "[内核]"
    echo "  通道: $(xmg_state_get XRAY_CHANNEL)"
    echo "  版本: $(_xmg_proxy_kernel_version)"
    echo
    echo "[DNS]"
    if [ "${XMG_NET_IPV4:-}" = "0" ] && [ "${XMG_NET_IPV6:-}" = "1" ]; then
        echo "  上游: https+local://[2606:4700:4700::1111]/dns-query, https+local://[2001:4860:4860::8888]/dns-query"
        echo "  策略: UseIPv6"
    else
        echo "  上游: https+local://1.1.1.1/dns-query, https+local://8.8.8.8/dns-query"
        echo "  策略: UseIP"
    fi
    echo
    echo "配置路径: ${XMG_XRAY_CONFIG:-}"
    return 0
}

# ===== export =====
# 输出全部 KEY=VALUE（含密码明文）。仅供重定向到文件使用；
# 调用方绝不可把它直接打到终端或写进日志。
xmg_proxy_export() {
    declare -F xmg_state_init >/dev/null 2>&1 && xmg_state_init
    xmg_state_all
}

# ===== acme.sh 证书申请（低配约束：仅手动触发，绝不在 apply 流程中自动执行）=====
# 文档依据 config/transports/tls.md:
#   "如果已经拥有一个域名, 可以使用工具便捷的获取免费第三方证书,如 acme.sh"
#
# 安装目录自包含：acme.sh 装到 $XMG_HOME/acme.sh，证书产物落到
# $XMG_HOME/etc/xray/certs/，全部在 XMG_HOME 单一目录树内。
xmg_proxy_acme_install() {
    # 已装好（脚本存在且可执行）则直接复用
    [ -x "$XMG_ACME_DIR/acme.sh" ] && return 0
    mkdir -p "$XMG_ACME_DIR" || {
        xmg_error "无法创建 acme.sh 目录: $XMG_ACME_DIR"
        return 4
    }

    local urls=(
        "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"
        "https://ghfast.top/https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"
        "https://mirror.ghproxy.com/https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"
    )
    local dl_ok=0
    for u in "${urls[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL --connect-timeout 8 --max-time 25 "$u" -o "$XMG_ACME_DIR/acme.sh" 2>/dev/null && [ -s "$XMG_ACME_DIR/acme.sh" ]; then
                dl_ok=1
                break
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -q -T 8 -O "$XMG_ACME_DIR/acme.sh" "$u" 2>/dev/null && [ -s "$XMG_ACME_DIR/acme.sh" ]; then
                dl_ok=1
                break
            fi
        fi
    done

    if [ "$dl_ok" -ne 1 ]; then
        rm -f "$XMG_ACME_DIR/acme.sh" 2>/dev/null || true
        xmg_error "下载 acme.sh 失败 (纯 IPv6 主机直连 GitHub 受限，请检查 DNS64 或开启 WARP IPv4 出口)"
        return 4
    fi
    chmod +x "$XMG_ACME_DIR/acme.sh" 2>/dev/null || true
    return 0
}

# 签发证书并写入 state。
# 返回：0 成功 / 2 参数非法（空域名）/ 4 签发或安装失败。
# 关键不变量：失败路径在任何 state 写入之前就 return，绝不覆盖既有证书路径。
xmg_proxy_acme_issue() {
    local domain="${1:-}"
    if [ -z "$domain" ]; then
        xmg_error "域名不能为空"
        return 2
    fi

    local acme_success=0
    if [ "${XMG_TEST_MODE:-0}" = "1" ] && [ -n "${XMG_ACME_TESTCMD:-}" ]; then
        # 测试桩：仅在测试模式生效，生产环境即使存在同名变量也不会执行任意命令
        local -a acme_test=($XMG_ACME_TESTCMD)
        if ! "${acme_test[@]}" >/dev/null 2>&1; then
            xmg_error "证书签发失败"
            return 4
        fi
        mkdir -p "$(dirname "$XMG_ACME_CERT_FILE")" 2>/dev/null || true
        printf 'stub\n' > "$XMG_ACME_CERT_FILE" 2>/dev/null || true
        printf 'stub\n' > "$XMG_ACME_KEY_FILE" 2>/dev/null || true
        acme_success=1
    else
        xmg_proxy_acme_install || true

        if [ -x "$XMG_ACME_DIR/acme.sh" ]; then
            local acme_cmd=("$XMG_ACME_DIR/acme.sh" --issue --server letsencrypt --standalone -d "$domain" --keylength ec-256)
            if [ "${XMG_NET_IPV4:-}" = "0" ] && [ "${XMG_NET_IPV6:-}" = "1" ]; then
                acme_cmd+=(--listen-v6)
            fi
            "${acme_cmd[@]}" >/dev/null 2>&1 || true
            mkdir -p "$(dirname "$XMG_ACME_CERT_FILE")" 2>/dev/null || true
            "$XMG_ACME_DIR/acme.sh" --install-cert -d "$domain" \
                --fullchain-file "$XMG_ACME_CERT_FILE" \
                --key-file "$XMG_ACME_KEY_FILE" >/dev/null 2>&1 || true
        fi

        if [ -s "$XMG_ACME_CERT_FILE" ] && [ -s "$XMG_ACME_KEY_FILE" ]; then
            acme_success=1
        fi
    fi

    # 签发成功路径
    if [ "$acme_success" -eq 1 ]; then
        xmg_state_stage PROXY_VLESS_CERT_SOURCE "user" || return 4
        xmg_state_stage PROXY_VLESS_CERT_FILE "$XMG_ACME_CERT_FILE" || return 4
        xmg_state_stage PROXY_VLESS_KEY_FILE "$XMG_ACME_KEY_FILE" || return 4
        xmg_state_commit_draft || return 4
        xmg_info "ACME 正规证书已就绪: $XMG_ACME_CERT_FILE（执行 apply 后生效）"
        return 0
    fi

    # 测试模式失败断言保持
    if [ "${XMG_TEST_MODE:-0}" = "1" ]; then
        xmg_error "证书签发失败"
        return 4
    fi

    # 生产环境真实失败（NAT机无80端口或域名为内网名称）：自动回退生成自签名证书
    echo
    xmg_warn "ACME 证书签发未通过（NAT机无80端口或域名无法解析），自动回退为生成自签名证书..."
    if xmg_proxy_self_sign_cert "$domain" "$XMG_ACME_CERT_FILE" "$XMG_ACME_KEY_FILE"; then
        xmg_info "已自动回退生成自签名证书并写入配置！"
        return 0
    else
        xmg_error "回退生成自签名证书失败"
        return 4
    fi
}

# ===== 一键生成自签名证书（配合 Cloudflare Full 模式穿透 NAT）=====
xmg_proxy_self_sign_cert() {
    local domain="${1:-}"
    if [ -z "$domain" ]; then
        domain="$(xmg_state_get PROXY_VLESS_DOMAIN "example.com")"
    fi
    local cert="${2:-$XMG_ACME_CERT_FILE}"
    local key="${3:-$XMG_ACME_KEY_FILE}"

    mkdir -p "$(dirname "$cert")" "$(dirname "$key")" 2>/dev/null || true
    if command -v openssl >/dev/null 2>&1; then
        if openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$key" -out "$cert" \
            -subj "/CN=$domain" -days 3650 >/dev/null 2>&1; then
            :
        else
            openssl req -x509 -nodes -newkey rsa:2048 \
                -keyout "$key" -out "$cert" \
                -subj "/CN=$domain" -days 3650 >/dev/null 2>&1 || true
        fi
        if [ -f "$cert" ] && [ -f "$key" ]; then
            chmod 644 "$cert" 2>/dev/null || true
            chmod 600 "$key" 2>/dev/null || true
            xmg_state_stage PROXY_VLESS_CERT_SOURCE "user" || true
            xmg_state_stage PROXY_VLESS_CERT_FILE "$cert" || true
            xmg_state_stage PROXY_VLESS_KEY_FILE "$key" || true
            xmg_state_commit_draft || true
            xmg_info "自签名证书已生成就绪: $cert"
            xmg_info "提示：请在 Cloudflare 后台 SSL/TLS 模式选择 Full（完全）"
            return 0
        fi
    fi
    xmg_error "未检测到 openssl 或生成证书失败"
    return 1
}

# ===== CDN 回源与非标端口提示 =====
_xmg_proxy_cf_port_hint() {
    local port="$1"
    local is_cf_standard=0
    case "$port" in
        443|8443|2053|2083|2087|2096)
            is_cf_standard=1
            ;;
    esac

    echo
    echo "==================== CDN 与证书配置说明 ===================="
    echo "1. 证书与验证："
    echo "   - 走 CDN 代理时：客户端【无需】开启跳过证书验证（Cloudflare 官方证书完全受信任）；"
    echo "     同时请在 Cloudflare 仪表盘 [SSL/TLS] 设为 [Full (完全)] 模式。"
    echo "   - 若直接连接 VPS IP：客户端必须开启【跳过证书验证 (AllowInsecure)】。"
    if [ "$is_cf_standard" -eq 1 ]; then
        echo "2. 回源端口：当前端口 $port 为 Cloudflare 官方支持的标准 HTTPS 端口，小黄云开启直接连通。"
    else
        printf '%s2. 回源端口：%s当前端口 %s 为非标准 CDN 端口（NAT 机映射端口）！\n' "$XMG_C_YELLOW" "$XMG_C_RESET" "$port"
        echo "   由于使用了非标端口，配合 Cloudflare CDN 必须配置端口回源："
        echo "   -> 打开 Cloudflare 域名控制台 -> 规则 (Rules) -> 源服务器规则 (Origin Rules)"
        echo "   -> 新建规则：匹配主机名 (Hostname)，在 [目标端口 (Destination Port)] 勾选重写为: $port"
        echo "   -> 客户端外部即可通过标准 443 端口连接域名！"
    fi
    echo "3. 路径匹配：客户端 path 必须与服务端一致，alpn 建议填 h2,http/1.1。"
    echo "============================================================"
}

# ===== 交互向导 =====
_xmg_read() {
    local prompt="$1" def="${2:-}" ans=""
    if [ -n "$def" ]; then
        printf '%s [%s]: ' "$prompt" "$def" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    read -r ans || return 1
    [ -z "$ans" ] && ans="$def"
    printf '%s' "$ans"
}

# ===== REALITY 配置向导 =====
# REALITY 不需要证书，只需伪装的 serverName + 回落目标 dest；密钥在 apply 时自动生成。
xmg_proxy_reality_wizard() {
    local r_port r_listen r_sni r_dest r_path r_mode r_ext r_public cur_listen def_sni def_dest

    def_sni="$(xmg_state_get PROXY_REALITY_SNI "www.microsoft.com")"
    def_dest="$(xmg_state_get PROXY_REALITY_DEST "${def_sni}:443")"

    cur_listen="$(xmg_state_get PROXY_REALITY_LISTEN)"
    if [ "${XMG_NET_IPV4:-}" = "0" ] && [ "${XMG_NET_IPV6:-}" = "1" ]; then
        if [ -z "$cur_listen" ] || [ "$cur_listen" = "0.0.0.0" ]; then
            cur_listen="::"
        fi
    fi
    [ -n "$cur_listen" ] || cur_listen="0.0.0.0"

    xmg_info "REALITY 不用证书：对伪装站点做真实 TLS 握手，靠密钥区分客户端。"
    xmg_info "建议 dest 与 serverName 保持同一站点，且该站点支持 TLS1.3。"

    r_port="$(_xmg_read "监听端口" "$(xmg_state_get PROXY_REALITY_PORT "8443")")"
    r_listen="$(_xmg_read "监听地址" "$cur_listen")"
    r_sni="$(_xmg_read "serverName(伪装域名)" "$def_sni")"
    r_dest="$(_xmg_read "target(回落目标 host:port，旧名 dest)" "$def_dest")"
    r_path="$(_xmg_read "path" "$(xmg_state_get PROXY_REALITY_PATH "/xhttp")")"
    r_mode="$(_xmg_read "mode(auto/packet-up/stream-up/stream-one)" "$(xmg_state_get PROXY_REALITY_MODE "auto")")"
    r_ext="$(_xmg_read "外部映射端口(NAT 机型填公网端口，直连留空)" "$(xmg_state_get PROXY_REALITY_EXTERNAL_PORT "")")"
    r_public="$(_xmg_read "公网地址(域名或公网 IP，NAT 机型建议显式填写)" "$(xmg_state_get PROXY_PUBLIC_HOST "")")"

    if ! xmg_proxy_apply \
        --reality on \
        --reality-port "$r_port" \
        --reality-listen "$r_listen" \
        --reality-sni "$r_sni" \
        --reality-dest "$r_dest" \
        --reality-path "$r_path" \
        --reality-mode "$r_mode" \
        --reality-external-port "$r_ext" \
        --public-host "$r_public"; then
        return 1
    fi

    echo
    xmg_proxy_reality_link 2>/dev/null || true
    return 0
}

xmg_proxy_menu() {
    declare -F xmg_state_init >/dev/null 2>&1 && xmg_state_init
    local choice="" d=""
    while true; do
        clear
        xmg_proxy_status
        echo
        echo "1. 配置 SOCKS5 方案"
        echo "2. 配置 VLESS + XHTTP + TLS 方案"
        echo "3. 配置 VLESS + XHTTP + REALITY 方案 (免证书)"
        echo "4. 停用 SOCKS5"
        echo "5. 停用 VLESS"
        echo "6. 停用 REALITY"
        echo "7. 导出当前状态到文件"
        echo "8. 申请证书 (acme.sh)"
        echo "9. 一键生成自签名证书 (供 CDN Full 模式)"
        echo "10. 查看客户端节点分享链接 (VLESS)"
        echo "11. 查看客户端节点分享链接 (REALITY)"
        echo "12. 生成 REALITY 密钥对"
        echo "0. 返回"
        echo
        printf "请选择: "
        read -r choice || return 0

        case "$choice" in
            1)
                echo
                xmg_warn "SOCKS5 协议不对传输加密，公网使用仅提供访问控制，不提供保密性。"
                xmg_confirm "确认继续?" || { xmg_pause; continue; }
                local cur_s_listen
                cur_s_listen="$(xmg_state_get PROXY_SOCKS_LISTEN)"
                if [ "${XMG_NET_IPV4:-}" = "0" ] && [ "${XMG_NET_IPV6:-}" = "1" ]; then
                    if [ -z "$cur_s_listen" ] || [ "$cur_s_listen" = "0.0.0.0" ]; then
                        cur_s_listen="::"
                    fi
                fi
                xmg_proxy_apply \
                    --socks on \
                    --socks-port "$(_xmg_read "监听端口" "$(xmg_state_get PROXY_SOCKS_PORT)")" \
                    --socks-listen "$(_xmg_read "监听地址" "$cur_s_listen")" \
                    --socks-user "$(_xmg_read "用户名" "")" \
                    --socks-pass "$(_xmg_read "密码(至少8位)" "")" || true
                xmg_pause
                ;;
            2)
                local v_port v_listen v_domain v_uuid v_path v_mode v_ext v_src v_cert v_key
                local def_cf="${XMG_ACME_CERT_FILE:-$XMG_HOME/etc/xray/certs/fullchain.crt}"
                local def_kf="${XMG_ACME_KEY_FILE:-$XMG_HOME/etc/xray/certs/priv.key}"
                local cur_v_listen
                cur_v_listen="$(xmg_state_get PROXY_VLESS_LISTEN)"
                if [ "${XMG_NET_IPV4:-}" = "0" ] && [ "${XMG_NET_IPV6:-}" = "1" ]; then
                    if [ -z "$cur_v_listen" ] || [ "$cur_v_listen" = "0.0.0.0" ]; then
                        cur_v_listen="::"
                    fi
                fi
                v_port="$(_xmg_read "监听端口" "$(xmg_state_get PROXY_VLESS_PORT)")"
                v_listen="$(_xmg_read "监听地址" "$cur_v_listen")"
                v_domain="$(_xmg_read "域名(用于SNI/CDN回源)" "$(xmg_state_get PROXY_VLESS_DOMAIN)")"
                v_uuid="$(_xmg_read "UUID" "$(xmg_state_get PROXY_VLESS_UUID)")"
                v_path="$(_xmg_read "path" "$(xmg_state_get PROXY_VLESS_PATH "/xhttpx")")"
                v_mode="$(_xmg_read "mode(auto/packet-up/stream-up/stream-one)" "$(xmg_state_get PROXY_VLESS_MODE "auto")")"
                v_ext="$(_xmg_read "外部映射端口(NAT 机型填公网端口，直连留空)" "$(xmg_state_get PROXY_VLESS_EXTERNAL_PORT "")")"
                v_src="$(_xmg_read "证书来源(user/acme)" "$(xmg_state_get PROXY_VLESS_CERT_SOURCE "user")")"
                if [ "$v_src" = "user" ]; then
                    v_cert="$(_xmg_read "证书路径" "$(xmg_state_get PROXY_VLESS_CERT_FILE "$def_cf")")"
                    v_key="$(_xmg_read "私钥路径" "$(xmg_state_get PROXY_VLESS_KEY_FILE "$def_kf")")"
                    if [ ! -f "$v_cert" ] || [ ! -f "$v_key" ]; then
                        echo
                        xmg_warn "检测到证书或私钥文件不存在: $v_cert"
                        if xmg_confirm "是否立即一键生成自签名证书（配合 Cloudflare Full 模式）?"; then
                            xmg_proxy_self_sign_cert "$v_domain" "$v_cert" "$v_key" || true
                        fi
                    fi
                else
                    v_cert="$XMG_ACME_CERT_FILE"
                    v_key="$XMG_ACME_KEY_FILE"
                    local need_issue=0
                    if [ ! -f "$v_cert" ] || [ ! -f "$v_key" ]; then
                        echo
                        xmg_warn "检测到域名 $v_domain 的 ACME 证书尚未签发"
                        need_issue=1
                    else
                        echo
                        xmg_info "检测到已有证书文件: $v_cert"
                        if xmg_confirm "是否重新申请域名 $v_domain 的正式 ACME 证书 (acme.sh)?"; then
                            need_issue=1
                        fi
                    fi
                    if [ "$need_issue" -eq 1 ]; then
                        xmg_proxy_acme_issue "$v_domain" || true
                    fi
                fi
                xmg_proxy_apply \
                    --vless on \
                    --vless-port "$v_port" \
                    --vless-listen "$v_listen" \
                    --vless-domain "$v_domain" \
                    --vless-uuid "$v_uuid" \
                    --vless-path "$v_path" \
                    --vless-mode "$v_mode" \
                    --vless-external-port "$v_ext" \
                    --vless-cert-source "$v_src" \
                    --vless-cert-file "$v_cert" \
                    --vless-key-file "$v_key" || true
                _xmg_proxy_cf_port_hint "$v_port"
                xmg_pause
                ;;
            3)
                echo
                xmg_proxy_reality_wizard || true
                xmg_pause
                ;;
            4)
                xmg_proxy_disable socks || true
                xmg_pause
                ;;
            5)
                xmg_proxy_disable vless || true
                ;;
            6)
                xmg_proxy_disable reality || true
                xmg_pause
                ;;
            7)
                # 导出文件里含密码明文：写 600 文件，只回显路径，绝不打到终端。
                local dst="$XMG_ETC_DIR/xray/state.export.env"
                mkdir -p "$(dirname "$dst")" 2>/dev/null || true
                if xmg_proxy_export > "$dst" 2>/dev/null; then
                    chmod 600 "$dst" 2>/dev/null || true
                    xmg_info "已导出到 $dst（含密码明文，请妥善保管）"
                else
                    xmg_error "导出失败: $dst"
                fi
                xmg_pause
                ;;
            8)
                # 仅手动触发，绝不在 apply 流程中自动执行（低配机型约束）
                printf "请输入域名: " >&2
                read -r d || return 0
                if xmg_proxy_acme_issue "$d"; then
                    xmg_info "证书路径已写入 state，请到方案 2 或直接执行 apply 生效"
                fi
                xmg_pause
                ;;
            9)
                printf "请输入域名 (默认 %s): " "$(xmg_state_get PROXY_VLESS_DOMAIN "example.com")" >&2
                read -r d || return 0
                [ -z "$d" ] && d="$(xmg_state_get PROXY_VLESS_DOMAIN "example.com")"
                xmg_proxy_self_sign_cert "$d" || true
                xmg_pause
                ;;
            10)
                clear
                if ! xmg_proxy_vless_link; then
                    xmg_warn "VLESS 尚未配置或未提供有效域名/UUID"
                fi
                xmg_pause
                ;;
            11)
                clear
                if ! xmg_proxy_reality_link; then
                    xmg_warn "REALITY 尚未配置或缺少 UUID/私钥"
                fi
                xmg_pause
                ;;
            12)
                clear
                xmg_proxy_reality_keygen || true
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
