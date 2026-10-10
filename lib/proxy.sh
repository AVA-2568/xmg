#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
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
            --vless-listen)      PARAMS["vless_listen"]="${2:-}";      shift 2 || return 2 ;;
            --vless-domain)      PARAMS["vless_domain"]="${2:-}";      shift 2 || return 2 ;;
            --vless-uuid)        PARAMS["vless_uuid"]="${2:-}";        shift 2 || return 2 ;;
            --vless-path)        PARAMS["vless_path"]="${2:-}";        shift 2 || return 2 ;;
            --vless-mode)        PARAMS["vless_mode"]="${2:-}";        shift 2 || return 2 ;;
            --vless-cert-source) PARAMS["vless_cert_source"]="${2:-}"; shift 2 || return 2 ;;
            --vless-cert-file)   PARAMS["vless_cert_file"]="${2:-}";   shift 2 || return 2 ;;
            --vless-key-file)    PARAMS["vless_key_file"]="${2:-}";    shift 2 || return 2 ;;
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
    _xmg_stage_param PROXY_VLESS_LISTEN "${PARAMS[vless_listen]:-}"
    _xmg_stage_param PROXY_VLESS_DOMAIN "${PARAMS[vless_domain]:-}"
    _xmg_stage_param PROXY_VLESS_UUID   "${PARAMS[vless_uuid]:-}"
    _xmg_stage_param PROXY_VLESS_PATH   "${PARAMS[vless_path]:-}"
    _xmg_stage_param PROXY_VLESS_MODE   "${PARAMS[vless_mode]:-}"
    _xmg_stage_param PROXY_VLESS_CERT_SOURCE "${PARAMS[vless_cert_source]:-}"
    _xmg_stage_param PROXY_VLESS_CERT_FILE   "${PARAMS[vless_cert_file]:-}"
    _xmg_stage_param PROXY_VLESS_KEY_FILE    "${PARAMS[vless_key_file]:-}"

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

    # schema 校验：读内存草稿。失败时丢弃草稿（state 文件从未被写），绝不触碰现网。
    if ! xmg_state_validate; then
        xmg_state_stage_clear
        return 2
    fi

    # 完善 ACME 状态一致性：检查 PROXY_VLESS_CERT_SOURCE=acme 时防御性处理
    local vless_on="${XMG_STATE[PROXY_VLESS_ENABLED]:-0}"
    local cert_src="${XMG_STATE[PROXY_VLESS_CERT_SOURCE]:-user}"
    if [ "$vless_on" = "1" ] && [ "$cert_src" = "acme" ]; then
        local cf="${XMG_STATE[PROXY_VLESS_CERT_FILE]:-}"
        local kf="${XMG_STATE[PROXY_VLESS_KEY_FILE]:-}"
        if [ -z "$cf" ]; then
            cf="$XMG_ACME_CERT_FILE"
            _xmg_stage PROXY_VLESS_CERT_FILE "$cf"
        fi
        if [ -z "$kf" ]; then
            kf="$XMG_ACME_KEY_FILE"
            _xmg_stage PROXY_VLESS_KEY_FILE "$kf"
        fi
        if [ ! -f "$cf" ] || [ ! -f "$kf" ]; then
            xmg_warn "ACME 证书文件尚未就绪: $cf（请执行 xmg proxy acme <域名> 签发证书）"
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

    # 校验通过：一次性原子落盘草稿（消除 N+1 磁盘写放大与半提交风险）
    if ! xmg_state_commit_draft; then
        rm -rf "$tmpdir"
        xmg_state_stage_clear
        xmg_error "状态草稿落盘失败"
        return 4
    fi

    # 原子提交 config.json：含内核校验(3)/备份/原子替换/reload 失败回滚(4)
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
        *)
            xmg_error "用法: xmg_proxy_disable <socks|vless>"
            return 2
            ;;
    esac
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

    # JSON 分支：绝不输出任何密码字段
    if [ "$json" -eq 1 ]; then
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
        echo "  域名: $vless_domain"
        echo "  path: $vless_path"
        echo "  mode: $vless_mode"
        echo "  证书: $(xmg_state_get PROXY_VLESS_CERT_SOURCE)"
    else
        echo "  状态: 未启用"
    fi
    echo
    echo "[内核]"
    echo "  通道: $(xmg_state_get XRAY_CHANNEL)"
    echo "  版本: $(_xmg_proxy_kernel_version)"
    echo
    echo "[DNS]"
    echo "  上游: https+local://1.1.1.1/dns-query, https+local://8.8.8.8/dns-query"
    echo "  策略: UseIP"
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

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://get.acme.sh -o "$XMG_ACME_DIR/acme.sh" || {
            xmg_error "下载 acme.sh 失败"
            return 4
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$XMG_ACME_DIR/acme.sh" https://get.acme.sh || {
            xmg_error "下载 acme.sh 失败"
            return 4
        }
    else
        xmg_error "需要 curl 或 wget 才能安装 acme.sh"
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

    if [ "${XMG_TEST_MODE:-0}" = "1" ] && [ -n "${XMG_ACME_TESTCMD:-}" ]; then
        # 测试桩：仅在测试模式生效，生产环境即使存在同名变量也不会 eval 任意命令
        if ! eval "$XMG_ACME_TESTCMD" >/dev/null 2>&1; then
            xmg_error "证书签发失败"
            return 4
        fi
        mkdir -p "$(dirname "$XMG_ACME_CERT_FILE")" 2>/dev/null || true
        printf 'stub\n' > "$XMG_ACME_CERT_FILE" 2>/dev/null || true
        printf 'stub\n' > "$XMG_ACME_KEY_FILE" 2>/dev/null || true
    else
        xmg_proxy_acme_install || return 4

        "$XMG_ACME_DIR/acme.sh" --issue --server letsencrypt \
            -d "$domain" --keylength ec-256 || {
            xmg_error "证书签发失败"
            return 4
        }
        mkdir -p "$(dirname "$XMG_ACME_CERT_FILE")" || {
            xmg_error "无法创建证书目录: $(dirname "$XMG_ACME_CERT_FILE")"
            return 4
        }
        "$XMG_ACME_DIR/acme.sh" --install-cert -d "$domain" \
            --fullchain-file "$XMG_ACME_CERT_FILE" \
            --key-file "$XMG_ACME_KEY_FILE" || {
            xmg_error "证书安装失败"
            return 4
        }
    fi

    # 到这里签发已成功，才写入 state（失败路径已在上面 return）
    xmg_state_stage PROXY_VLESS_CERT_SOURCE "user" || return 4
    xmg_state_stage PROXY_VLESS_CERT_FILE "$XMG_ACME_CERT_FILE" || return 4
    xmg_state_stage PROXY_VLESS_KEY_FILE "$XMG_ACME_KEY_FILE" || return 4
    xmg_state_commit_draft || return 4
    xmg_info "证书已就绪: $XMG_ACME_CERT_FILE（执行 apply 后生效）"
    return 0
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

# XMG_MENU_LABEL: 代理方案
xmg_proxy_menu() {
    declare -F xmg_state_init >/dev/null 2>&1 && xmg_state_init
    local choice="" d=""
    while true; do
        clear
        xmg_proxy_status
        echo
        echo "1. 配置 SOCKS5 方案"
        echo "2. 配置 VLESS + XHTTP + TLS 方案"
        echo "3. 停用 SOCKS5"
        echo "4. 停用 VLESS"
        echo "5. 导出当前状态到文件"
        echo "6. 申请证书 (acme.sh)"
        echo "0. 返回"
        echo
        printf "请选择: "
        read -r choice || return 0

        case "$choice" in
            1)
                echo
                xmg_warn "SOCKS5 协议不对传输加密，公网使用仅提供访问控制，不提供保密性。"
                xmg_confirm "确认继续?" || { xmg_pause; continue; }
                xmg_proxy_apply \
                    --socks on \
                    --socks-port "$(_xmg_read "监听端口" "$(xmg_state_get PROXY_SOCKS_PORT)")" \
                    --socks-listen "$(_xmg_read "监听地址" "$(xmg_state_get PROXY_SOCKS_LISTEN)")" \
                    --socks-user "$(_xmg_read "用户名" "")" \
                    --socks-pass "$(_xmg_read "密码(至少8位)" "")" || true
                xmg_pause
                ;;
            2)
                local v_port v_listen v_domain v_uuid v_path v_mode v_src v_cert v_key
                v_port="$(_xmg_read "监听端口" "$(xmg_state_get PROXY_VLESS_PORT)")"
                v_listen="$(_xmg_read "监听地址" "$(xmg_state_get PROXY_VLESS_LISTEN)")"
                v_domain="$(_xmg_read "域名(用于SNI/CDN回源)" "$(xmg_state_get PROXY_VLESS_DOMAIN)")"
                v_uuid="$(_xmg_read "UUID" "$(xmg_state_get PROXY_VLESS_UUID)")"
                v_path="$(_xmg_read "path" "$(xmg_state_get PROXY_VLESS_PATH "/xhttpx")")"
                v_mode="$(_xmg_read "mode(auto/packet-up/stream-up/stream-one)" "$(xmg_state_get PROXY_VLESS_MODE "auto")")"
                v_src="$(_xmg_read "证书来源(user/acme)" "$(xmg_state_get PROXY_VLESS_CERT_SOURCE "user")")"
                if [ "$v_src" = "user" ]; then
                    v_cert="$(_xmg_read "证书路径" "$(xmg_state_get PROXY_VLESS_CERT_FILE)")"
                    v_key="$(_xmg_read "私钥路径" "$(xmg_state_get PROXY_VLESS_KEY_FILE)")"
                else
                    v_cert="$XMG_ACME_CERT_FILE"
                    v_key="$XMG_ACME_KEY_FILE"
                    if [ ! -f "$v_cert" ] || [ ! -f "$v_key" ]; then
                        echo
                        xmg_warn "检测到域名 $v_domain 的 ACME 证书尚未签发"
                        if xmg_confirm "是否立即申请证书 (acme.sh)?"; then
                            xmg_proxy_acme_issue "$v_domain" || true
                        fi
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
                    --vless-cert-source "$v_src" \
                    --vless-cert-file "$v_cert" \
                    --vless-key-file "$v_key" || true
                echo
                echo "过 CDN 提示：客户端 path 必须与服务器一致；"
                echo "客户端 alpn 可选 h3 使用 QUIC；连不上 CF 请在 CF 面板启用 gRPC；"
                echo "其他 CDN 不兼容时把 mode 改为 packet-up。"
                xmg_pause
                ;;
            3)
                xmg_proxy_disable socks || true
                xmg_pause
                ;;
            4)
                xmg_proxy_disable vless || true
                xmg_pause
                ;;
            5)
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
            6)
                # 仅手动触发，绝不在 apply 流程中自动执行（低配机型约束）
                printf "请输入域名: " >&2
                read -r d || return 0
                if xmg_proxy_acme_issue "$d"; then
                    xmg_info "证书路径已写入 state，请到方案 2 或直接执行 apply 生效"
                fi
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
