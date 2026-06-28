#!/usr/bin/env bash
set -Eeuo pipefail

XMG_BASE_URL="${XMG_BASE_URL:-https://raw.githubusercontent.com/AVA-2568/xmg/main}"
XMG_BIN="${XMG_BIN:-/usr/local/bin/xmg}"
XMG_LIB_DIR="${XMG_LIB_DIR:-/usr/local/lib/xmg}"

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

required_libs() {
    cat <<EOF
common.sh
system.sh
monitor.sh
menu.sh
caddy.sh
xray.sh
site.sh
firewall.sh
update.sh
uninstall.sh
EOF
}

install_dirs() {
    mkdir -p \
        "$(dirname "$XMG_BIN")" \
        "$XMG_LIB_DIR" \
        /etc/xmg \
        /run/xmg \
        /var/log/xmg \
        /var/backups/xmg \
        /var/www/xmg/site
}

install_local() {
    local f=""

    [ -f "$SCRIPT_DIR/xmg" ] || return 1
    [ -d "$SCRIPT_DIR/lib" ] || return 1

    install_dirs

    install -m 0755 -o root -g root "$SCRIPT_DIR/xmg" "$XMG_BIN"

    while IFS= read -r f; do
        [ -f "$SCRIPT_DIR/lib/$f" ] || die "缺少本地文件: lib/$f"
        install -m 0644 -o root -g root "$SCRIPT_DIR/lib/$f" "$XMG_LIB_DIR/$f"
    done < <(required_libs)

    return 0
}

download_file() {
    local url="$1"
    local dst="$2"
    local mode="$3"
    local tmp=""

    cmd_exists curl || die "curl 不存在，请先安装 curl"

    tmp="$(mktemp)"
    [ -n "$tmp" ] || die "创建临时文件失败"

    if ! curl -fsSL "$url" -o "$tmp"; then
        rm -f "$tmp"
        die "下载失败: $url"
    fi

    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        die "下载结果为空: $url"
    fi

    install -m "$mode" -o root -g root "$tmp" "$dst"
    rm -f "$tmp"
}

install_remote() {
    local f=""

    install_dirs

    echo "远程源: $XMG_BASE_URL"

    download_file "$XMG_BASE_URL/xmg" "$XMG_BIN" 0755

    while IFS= read -r f; do
        download_file "$XMG_BASE_URL/lib/$f" "$XMG_LIB_DIR/$f" 0644
    done < <(required_libs)
}

verify_install() {
    local missing=0
    local f=""

    if [ ! -x "$XMG_BIN" ]; then
        red "[MISS] $XMG_BIN"
        missing=$((missing + 1))
    else
        green "[OK]   $XMG_BIN"
    fi

    while IFS= read -r f; do
        if [ ! -r "$XMG_LIB_DIR/$f" ]; then
            red "[MISS] $XMG_LIB_DIR/$f"
            missing=$((missing + 1))
        else
            green "[OK]   $XMG_LIB_DIR/$f"
        fi
    done < <(required_libs)

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
