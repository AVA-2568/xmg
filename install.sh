#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# install.sh - XMG 安装脚本
#
# 说明：
#   - 优先从当前源码目录安装
#   - 如果未检测到完整本地源码，则从 GitHub Raw 安装
#   - 文件内容应使用 UTF-8 编码保存
#

# 必须在 set -o pipefail 前检查是否为 Bash
if [ -z "${BASH_VERSION:-}" ]; then
    echo "错误: 需要使用 bash 运行 install.sh" >&2
    exit 1
fi

set -Eeuo pipefail

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
XMG_WWW_DIR="${XMG_WWW_DIR:-$XMG_HOME/www}"
XMG_CADDY_DIR="${XMG_CADDY_DIR:-$XMG_HOME/caddy}"
XMG_XRAY_DIR="${XMG_XRAY_DIR:-$XMG_HOME/xray}"

XMG_BIN="${XMG_BIN:-$XMG_BIN_DIR/xmg}"
XMG_LINK="${XMG_LINK:-/usr/local/bin/xmg}"

XMG_CADDYFILE="${XMG_CADDYFILE:-$XMG_CADDY_DIR/Caddyfile}"
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
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "请使用 root 执行安装，例如: sudo ./install.sh"
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

manifest_local_path() {
    printf '%s\n' "$SCRIPT_DIR/xmg.files"
}

install_dirs() {
    mkdir -p \
        "$(dirname "$XMG_BIN")" \
        "$XMG_LIB_DIR" \
        /etc/xmg \
        /run/xmg \
        /var/log/xmg \
        /var/backups/xmg \
        /var/www/xmg
}

manifest_entry_validate() {
    local entry="$1"

    case "$entry" in
        ""|"/"*|*".."*|*"/../"*|*"/.."|"../"*)
            die "不安全的清单条目: $entry"
            ;;
    esac

    case "$entry" in
        xmg|lib/*.sh)
            return 0
            ;;
        *)
            die "不支持的清单条目: $entry"
            ;;
    esac
}

manifest_entry_mode() {
    local entry="$1"

    manifest_entry_validate "$entry"

    case "$entry" in
        xmg)
            printf '0755'
            ;;
        lib/*.sh)
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

    manifest_entry_validate "$entry"

    case "$entry" in
        xmg)
            printf '%s\n' "$XMG_BIN"
            ;;
        lib/*.sh)
            base="${entry##*/}"
            printf '%s/%s\n' "$XMG_LIB_DIR" "$base"
            ;;
        *)
            die "不支持的清单条目: $entry"
            ;;
    esac
}

manifest_entry_local_src() {
    local entry="$1"

    manifest_entry_validate "$entry"
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

        manifest_entry_validate "$line"
        printf '%s\n' "$line"
    done < "$manifest"
}

download_to_temp() {
    local url="$1"
    local tmp=""

    cmd_exists curl || die "curl 不存在，请先安装 curl"

    tmp="$(mktemp)" || die "创建临时文件失败"

    if ! curl -fsSL "$url" -o "$tmp"; then
        rm -f -- "$tmp"
        die "下载失败: $url"
    fi

    if [ ! -s "$tmp" ]; then
        rm -f -- "$tmp"
        die "下载结果为空: $url"
    fi

    printf '%s\n' "$tmp"
}

install_one_file() {
    local src="$1"
    local dst="$2"
    local mode="$3"

    install -m "$mode" -o root -g root "$src" "$dst" || die "安装失败: $dst"
}

install_local() {
    local manifest=""
    local entry=""
    local src=""
    local dst=""
    local mode=""

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
    done < <(read_manifest_file "$manifest")

    return 0
}

install_remote() {
    local manifest_tmp=""
    local entry=""
    local src_tmp=""
    local dst=""
    local mode=""
    local url=""

    install_dirs

    echo "远程源: $XMG_BASE_URL"

    manifest_tmp="$(download_to_temp "$XMG_BASE_URL/xmg.files")"

    while IFS= read -r entry; do
        url="$XMG_BASE_URL/$entry"
        dst="$(manifest_entry_dest "$entry")"
        mode="$(manifest_entry_mode "$entry")"

        src_tmp="$(download_to_temp "$url")"
        install_one_file "$src_tmp" "$dst" "$mode"
        rm -f -- "$src_tmp"
    done < <(read_manifest_file "$manifest_tmp")

    rm -f -- "$manifest_tmp"
}

verify_install() {
    local manifest=""
    local manifest_tmp=""
    local entry=""
    local dst=""
    local missing=0
    local used_local=0

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

    if [ "$missing" -ne 0 ]; then
        die "安装校验失败，缺失 $missing 个文件"
    fi
}

main() {
    need_root

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

    echo
    green "安装完成"
    echo "命令: xmg"
    echo "源码目录测试: XMG_LIB_DIR=./lib ./xmg"
}

main "$@"
