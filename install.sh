#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# install.sh - XMG 安装脚本
#
# 说明：
#   - 优先从当前源码目录安装
#   - 如果未检测到完整本地源码，则从 GitHub Raw 安装
#   - 所有 XMG 管理的文件集中安装到 /opt/xmg
#   - /usr/local/bin/xmg 仅作为命令入口软链接
#
# 使用方法：
#   sudo bash install.sh
#
# 可选环境变量：
#   XMG_HOME=/opt/xmg
#   XMG_BASE_URL=https://raw.githubusercontent.com/AVA-2568/xmg/main
#
# 注意事项：
#   - 需要 root 权限
#   - 依赖 curl 进行远程安装
#

# 必须在 set -o pipefail 前检查是否为 Bash
if [ -z "${BASH_VERSION:-}" ]; then
    echo "错误: 需要使用 bash 运行 install.sh" >&2
    if command -v apk >/dev/null 2>&1; then
        echo "Alpine 环境请先安装 bash 与 curl:" >&2
        echo "  apk add --no-cache bash curl" >&2
        echo "  bash install.sh" >&2
    else
        echo "示例: sudo bash install.sh" >&2
    fi
    exit 1
fi

unset BASH_ENV ENV 2>/dev/null || true
set -Eeuo pipefail
IFS=$'\n\t'

# 这里请按你的实际 GitHub 仓库 Raw 地址设置
# 如果你的仓库名实际是大写 XMG，请改为：
#   https://raw.githubusercontent.com/AVA-2568/XMG/main
XMG_BASE_URL="${XMG_BASE_URL:-https://raw.githubusercontent.com/AVA-2568/xmg/main}"

# ============================================================
# XMG 统一安装目录
# ============================================================
# 真实安装目录：/opt/xmg
# 命令入口：/usr/local/bin/xmg -> /opt/xmg/bin/xmg
XMG_HOME="${XMG_HOME:-/opt/xmg}"

XMG_BIN_DIR="${XMG_BIN_DIR:-$XMG_HOME/bin}"
XMG_LIB_DIR="${XMG_LIB_DIR:-$XMG_HOME/lib}"
XMG_ETC_DIR="${XMG_ETC_DIR:-$XMG_HOME/etc}"
XMG_RUN_DIR="${XMG_RUN_DIR:-$XMG_HOME/run}"
XMG_LOG_DIR="${XMG_LOG_DIR:-$XMG_HOME/log}"
XMG_BACKUP_DIR="${XMG_BACKUP_DIR:-$XMG_HOME/backups}"
XMG_XRAY_DIR="${XMG_XRAY_DIR:-$XMG_HOME/xray}"

XMG_BIN="${XMG_BIN:-$XMG_BIN_DIR/xmg}"
XMG_LINK="${XMG_LINK:-/usr/local/bin/xmg}"

XMG_XRAY_CONFIG="${XMG_XRAY_CONFIG:-$XMG_XRAY_DIR/config.json}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red() {
    printf '\033[31m%s\033[0m\n' "$*" >&2
}

green() {
    printf '\033[32m%s\033[0m\n' "$*"
}

yellow() {
    printf '\033[33m%s\033[0m\n' "$*" >&2
}

die() {
    red "错误: $*"
    exit 1
}

need_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "请使用 root 执行安装，例如: sudo bash install.sh"
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

ensure_dependencies() {
    local missing=()
    local dep=""
    for dep in bash curl jq openssl ca-certificates; do
        if [ "$dep" = "ca-certificates" ]; then
            [ -d /etc/ssl/certs ] || missing+=("$dep")
        elif ! cmd_exists "$dep"; then
            missing+=("$dep")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        green "✓ 系统运行环境已就绪 (bash, curl, jq, openssl, ca-certificates)"
        return 0
    fi

    yellow "检测到未安装的基础依赖: ${missing[*]}，正在配置系统运行环境..."
    if cmd_exists apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        export UCF_FORCE_CONFFOLD=1
        (apt-get update -y -q && apt-get install -y -q "${missing[@]}") >/dev/null 2>&1 || true
    elif cmd_exists apk; then
        # Alpine：ca-certificates 由 ca-certificates-bundle 提供，jq 非必需
        (apk update -q && apk add --no-cache "${missing[@]}") >/dev/null 2>&1 || \
            apk add --no-cache "${missing[@]}" >/dev/null 2>&1 || true
    elif cmd_exists dnf; then
        dnf install -y -q "${missing[@]}" >/dev/null 2>&1 || true
    elif cmd_exists yum; then
        yum install -y -q "${missing[@]}" >/dev/null 2>&1 || true
    elif cmd_exists pacman; then
        pacman -Sy --noconfirm "${missing[@]}" >/dev/null 2>&1 || true
    elif cmd_exists zypper; then
        zypper --non-interactive install "${missing[@]}" >/dev/null 2>&1 || true
    fi

    local still_missing=()
    for dep in "${missing[@]}"; do
        if [ "$dep" = "ca-certificates" ]; then
            [ -d /etc/ssl/certs ] || still_missing+=("$dep")
        elif ! cmd_exists "$dep"; then
            still_missing+=("$dep")
        fi
    done

    if [ "${#still_missing[@]}" -eq 0 ]; then
        green "✓ 系统运行环境配置完成 (已安装: ${missing[*]})"
    else
        yellow "提示: 部分依赖未能自动安装: ${still_missing[*]}"
        if ! cmd_exists jq; then
            yellow "      XMG 纯 Bash 内建引擎已生效，无需 jq 亦可稳定生成配置"
        fi
    fi
    return 0
}

ensure_jq() {
    ensure_dependencies
}

manifest_local_path() {
    printf '%s\n' "$SCRIPT_DIR/xmg.files"
}

install_dirs() {
    # 创建统一目录结构，mkdir -p 可以重复执行，保证安装脚本幂等
    mkdir -p \
        "$XMG_BIN_DIR" \
        "$XMG_LIB_DIR" \
        "$XMG_ETC_DIR" \
        "$XMG_ETC_DIR/xray" \
        "$XMG_RUN_DIR" \
        "$XMG_LOG_DIR" \
        "$XMG_BACKUP_DIR" \
        "$XMG_XRAY_DIR" \
        "$XMG_HOME/templates" \
        "$(dirname "$XMG_LINK")"

    # 设置基础权限，避免普通用户误写核心目录
    chmod 755 \
        "$XMG_HOME" \
        "$XMG_BIN_DIR" \
        "$XMG_LIB_DIR" \
        "$XMG_RUN_DIR" \
        "$XMG_LOG_DIR"

    # 敏感配置及备份目录强化为 700 权限
    chmod 700 \
        "$XMG_ETC_DIR" \
        "$XMG_ETC_DIR/xray" \
        "$XMG_BACKUP_DIR" \
        "$XMG_XRAY_DIR"
}

manifest_entry_validate() {
    local entry="$1"

    case "$entry" in
        ""|"/"*|*".."*|*"/../"*|*"/.."|"../"*)
            return 1
            ;;
    esac

    case "$entry" in
        xmg|lib/*.sh|xmg.files|templates/*.json)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

manifest_entry_mode() {
    local entry="$1"

    manifest_entry_validate "$entry" || die "不支持的清单条目: $entry"

    case "$entry" in
        xmg)
            printf '0755'
            ;;
        lib/*.sh|xmg.files|templates/*.json)
            printf '0644'
            ;;
        *)
            die "不支持的清单条目: $entry"
            ;;
    esac
}

manifest_entry_dest() {
    local entry="$1"
    local base=""

    manifest_entry_validate "$entry" || die "不支持的清单条目: $entry"

    case "$entry" in
        xmg)
            printf '%s\n' "$XMG_BIN"
            ;;
        lib/*.sh)
            base="${entry##*/}"
            printf '%s/%s\n' "$XMG_LIB_DIR" "$base"
            ;;
        xmg.files)
            printf '%s/xmg.files\n' "$XMG_HOME"
            ;;
        templates/*.json)
            base="${entry##*/}"
            printf '%s/xray/%s\n' "$XMG_ETC_DIR" "$base"
            ;;
        *)
            die "不支持的清单条目: $entry"
            ;;
    esac
}

manifest_entry_local_src() {
    local entry="$1"

    manifest_entry_validate "$entry" || die "不支持的清单条目: $entry"
    printf '%s/%s\n' "$SCRIPT_DIR" "$entry"
}

read_manifest_file() {
    local manifest="$1"
    local line=""

    [ -r "$manifest" ] || die "模块清单不存在或不可读: $manifest"

    while IFS= read -r line || [ -n "$line" ]; do
        # 去掉首尾空白
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # 跳过空行和注释
        [ -z "$line" ] && continue

        case "$line" in
            \#*)
                continue
                ;;
        esac

        manifest_entry_validate "$line" || die "不安全的清单条目: $line"
        printf '%s\n' "$line"
    done < "$manifest"
}

download_to_temp() {
    local url="$1"
    local tmp=""

    cmd_exists curl || die "curl 不存在，请先安装 curl"

    tmp="$(mktemp)" || die "创建临时文件失败"

    local urls=(
        "$url"
        "https://ghfast.top/$url"
        "https://mirror.ghproxy.com/$url"
    )

    local success=0
    for u in "${urls[@]}"; do
        if curl -fsSL --connect-timeout 8 --max-time 20 "$u" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
            success=1
            break
        fi
    done

    if [ "$success" -ne 1 ]; then
        rm -f -- "$tmp"
        die "下载失败: $url (若为纯 IPv6 VPS 请检查 DNS64 或配置 WARP IPv4 出口)"
    fi

    printf '%s\n' "$tmp"
}

install_one_file() {
    local src="$1"
    local dst="$2"
    local mode="$3"

    # BusyBox 环境的 install 参数支持不完整，优先用 coreutils 语义，
    # 失败则退化为 cp + chmod（Alpine 最小系统常见）
    if command -v install >/dev/null 2>&1; then
        if install -m "$mode" -o root -g root "$src" "$dst" 2>/dev/null; then
            return 0
        fi
        if install -m "$mode" "$src" "$dst" 2>/dev/null; then
            return 0
        fi
    fi

    cp -f "$src" "$dst" || die "安装失败: $dst"
    chmod "$mode" "$dst" 2>/dev/null || die "设置权限失败: $dst"
    chown root:root "$dst" 2>/dev/null || true
    return 0
}

install_command_link() {
    # 如果旧命令入口存在，先删除入口文件或软链接
    # 注意：这里只删除 /usr/local/bin/xmg，不删除 /opt/xmg 真实文件
    if [ -e "$XMG_LINK" ] || [ -L "$XMG_LINK" ]; then
        rm -f -- "$XMG_LINK" || die "删除旧命令入口失败: $XMG_LINK"
    fi

    # 创建新的命令入口软链接
    ln -s "$XMG_BIN" "$XMG_LINK" || die "创建命令入口失败: $XMG_LINK -> $XMG_BIN"

    # 确保主程序可执行
    chmod 755 "$XMG_BIN" || die "设置主程序执行权限失败: $XMG_BIN"
}

install_local() {
    local manifest=""
    local entry=""
    local src=""
    local dst=""
    local mode=""

    ensure_jq

    manifest="$(manifest_local_path)"

    [ -f "$SCRIPT_DIR/xmg" ] || return 1
    [ -d "$SCRIPT_DIR/lib" ] || return 1
    [ -f "$manifest" ] || return 1

    install_dirs

    while IFS= read -r entry; do
        src="$(manifest_entry_local_src "$entry")"
        [ -f "$src" ] || die "缺少本地文件: $entry"

        dst="$(manifest_entry_dest "$entry")"
        mode="$(manifest_entry_mode "$entry")"

        install_one_file "$src" "$dst" "$mode"
        if [[ "$entry" == templates/*.json ]]; then
            install_one_file "$src" "$XMG_HOME/templates/${entry##*/}" "$mode"
        fi
    done < <(read_manifest_file "$manifest")

    install_command_link

    return 0
}

install_remote() {
    local manifest_tmp=""
    local entry=""
    local src_tmp=""
    local dst=""
    local mode=""
    local url=""

    ensure_jq

    install_dirs

    echo "远程源: $XMG_BASE_URL"

    manifest_tmp="$(download_to_temp "$XMG_BASE_URL/xmg.files")"

    while IFS= read -r entry; do
        url="$XMG_BASE_URL/$entry"
        dst="$(manifest_entry_dest "$entry")"
        mode="$(manifest_entry_mode "$entry")"

        src_tmp="$(download_to_temp "$url")"
        install_one_file "$src_tmp" "$dst" "$mode"
        if [[ "$entry" == templates/*.json ]]; then
            install_one_file "$src_tmp" "$XMG_HOME/templates/${entry##*/}" "$mode"
        fi
        rm -f -- "$src_tmp"
    done < <(read_manifest_file "$manifest_tmp")

    rm -f -- "$manifest_tmp"

    install_command_link
}

verify_install() {
    local manifest=""
    local manifest_tmp=""
    local entry=""
    local dst=""
    local missing=0
    local used_local=0
    local link_target=""

    if [ -f "$(manifest_local_path)" ] && [ -f "$SCRIPT_DIR/xmg" ] && [ -d "$SCRIPT_DIR/lib" ]; then
        manifest="$(manifest_local_path)"
        used_local=1
    else
        manifest_tmp="$(download_to_temp "$XMG_BASE_URL/xmg.files")"
        manifest="$manifest_tmp"
        used_local=0
    fi

    while IFS= read -r entry; do
        dst="$(manifest_entry_dest "$entry")"

        if [ ! -r "$dst" ]; then
            red "[MISS] $dst"
            missing=$((missing + 1))
        else
            green "[OK]   $dst"
        fi
    done < <(read_manifest_file "$manifest")

    if [ "$used_local" -eq 0 ]; then
        rm -f -- "$manifest_tmp"
    fi

    if [ ! -L "$XMG_LINK" ]; then
        red "[MISS] $XMG_LINK 不是软链接"
        missing=$((missing + 1))
    else
        link_target="$(readlink "$XMG_LINK")"
        if [ "$link_target" != "$XMG_BIN" ]; then
            red "[MISS] $XMG_LINK 指向错误: $link_target"
            missing=$((missing + 1))
        else
            green "[OK]   $XMG_LINK -> $XMG_BIN"
        fi
    fi

    if [ "$missing" -ne 0 ]; then
        die "安装校验失败，缺失或异常 $missing 项"
    fi
}

auto_refresh_on_upgrade() {
    local state_f="$XMG_ETC_DIR/xray/state.env"
    local warp_env="$XMG_HOME/warp/warp.env"
    [ "${XMG_TEST_MODE:-0}" = "1" ] && return 0
    [ -x "$XMG_BIN" ] || return 0
    [ -f "$state_f" ] || [ -f "$warp_env" ] || return 0

    local w_on="" w_mode="" w_geo="" _k="" _v=""
    if [ -f "$state_f" ]; then
        while IFS='=' read -r _k _v || [ -n "$_k" ]; do
            _v="${_v%$'\r'}"
            _v="${_v//\"/}"
            _v="${_v//[[:space:]]/}"
            case "$_k" in
                WARP_ENABLED)  w_on="$_v" ;;
                WARP_MODE)     w_mode="$_v" ;;
                WARP_GEO_MODE) w_geo="$_v" ;;
            esac
        done < "$state_f"
    fi
    if [ -f "$warp_env" ]; then
        while IFS='=' read -r _k _v || [ -n "$_k" ]; do
            _v="${_v%$'\r'}"
            _v="${_v//\"/}"
            _v="${_v//[[:space:]]/}"
            case "$_k" in
                WARP_ENABLED)  [ -n "$w_on" ]   || w_on="$_v" ;;
                WARP_MODE)     [ -n "$w_mode" ] || w_mode="$_v" ;;
                WARP_GEO_MODE) [ -n "$w_geo" ]  || w_geo="$_v" ;;
            esac
        done < "$warp_env"
    fi
    case "$w_mode" in
        global|routing) ;;
        *) w_mode="global" ;;
    esac

    echo
    green "检测到已有配置，正在按新版本同步状态、全量重渲染并单次重启 Xray 核心..."
    # 管线顺序：1. 同步 WARP 状态(不重启) -> 2. 全量重渲染 Proxy+WARP 配置(不重启) -> 3. 单次硬重启核心
    if [ "$w_on" = "1" ]; then
        if [ "$w_mode" = "routing" ] && [ -n "$w_geo" ]; then
            XMG_PROXY_NO_RELOAD=1 "$XMG_BIN" warp enable routing --geo "$w_geo" || yellow "WARP 状态同步失败，请手动执行: xmg warp enable routing"
        else
            XMG_PROXY_NO_RELOAD=1 "$XMG_BIN" warp enable "$w_mode" || yellow "WARP 状态同步失败，请手动执行: xmg warp enable $w_mode"
        fi
    fi
    if [ -f "$state_f" ]; then
        XMG_PROXY_NO_RELOAD=1 "$XMG_BIN" proxy apply || yellow "Proxy 配置重渲染失败，请手动执行: xmg proxy apply"
    fi
    "$XMG_BIN" xray restart || yellow "Xray 自动重启失败，请手动执行: xmg xray restart"
}

print_summary() {
    hash -r 2>/dev/null || true
    echo
    green "安装/更新完成"
    echo "命令入口: $XMG_LINK"
    echo "真实主程序: $XMG_BIN"
    echo "模块目录: $XMG_LIB_DIR"
    echo "配置目录: $XMG_ETC_DIR"
    echo "运行目录: $XMG_RUN_DIR"
    echo "日志目录: $XMG_LOG_DIR"
    echo "备份目录: $XMG_BACKUP_DIR"
    echo "Xray 配置目录: $XMG_XRAY_DIR"
    echo
    echo "执行命令 (当前终端已刷新，无需断开重连):"
    echo "  xmg"
    echo
    echo "源码目录测试:"
    echo "  XMG_LIB_DIR=./lib ./xmg"
}

main() {
    need_root

    echo "============================================================"
    echo "                 XMG 环境检查与系统安装"
    echo "============================================================"
    ensure_dependencies
    echo

    if install_local; then
        green "已从本地源码安装 XMG"
    else
        yellow "未检测到完整本地源码，尝试从 GitHub Raw 安装"
        install_remote
        green "已从 GitHub Raw 安装 XMG"
    fi

    echo
    echo "安装文件校验："
    verify_install
    auto_refresh_on_upgrade

    print_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
