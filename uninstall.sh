#!/usr/bin/env bash
#
# uninstall.sh - 卸载 XMG 脚本本体
#

set -o errexit
set -o nounset
set -o pipefail

INSTALL_DIR="/opt/xmg"
BIN_PATH="/usr/local/bin/xmg"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

ok() {
    echo -e "${GREEN}[OK]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

err() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

need_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "请使用 root 用户执行卸载"
        exit 1
    fi
}

main() {
    need_root

    warn "此操作只卸载 XMG 脚本本体"
    warn "不会卸载 Caddy、Xray，也不会删除 /etc/xmg 和 /var/www/mask-site"
    echo

    read -rp "确认卸载 XMG? [y/N]: " ans

    case "${ans}" in
        y|Y|yes|YES)
            rm -f "${BIN_PATH}"
            rm -rf "${INSTALL_DIR}"
            ok "XMG 已卸载"
            ;;
        *)
            warn "已取消"
            ;;
    esac
}

main "$@"
