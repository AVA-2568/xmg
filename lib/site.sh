#!/usr/bin/env bash
#
# site.sh - 站点目录管理
#

# 添加 include guard（与其他模块一致）
[ "${XMG_SITE_SH_LOADED:-0}" = "1" ] && return 0
XMG_SITE_SH_LOADED=1

# 路径安全检查函数（参考 uninstall.sh）
xmg_site_safe_path() {
    local path="$1"
    case "$path" in
        ""|"/"|"/usr"|"/usr/local"|"/etc"|"/var"|"/var/log"|"/var/backups"|"/home"*)
            xmg_die "拒绝操作危险路径: $path"
            ;;
    esac
    # 确保路径在 XMG_WWW_DIR 下
    case "$path" in
        "${XMG_WWW_DIR}"|"${XMG_WWW_DIR}/"*)
            return 0
            ;;
        *)
            xmg_die "路径不在站点目录下: $path"
            ;;
    esac
}

# 备份站点（函数名添加 xmg_ 前缀）
xmg_site_backup() {
    if [[ -d "${XMG_WWW_DIR}" ]] && [[ -n "$(ls -A "${XMG_WWW_DIR}" 2>/dev/null || true)" ]]; then
        local ts
        local backup
        ts="$(date +%Y%m%d-%H%M%S)"
        backup="${XMG_BACKUP_DIR}/mask-site.${ts}.tar.gz"
        xmg_mkdirs
        tar -czf "${backup}" -C "${XMG_WWW_DIR}" .
        xmg_info "当前站点已备份到 ${backup}"
    else
        xmg_warn "站点目录为空，无需备份"
    fi
}

# 从 GitHub 拉取站点
xmg_site_pull_from_github() {
    local repo
    read -rp "请输入 GitHub 仓库地址，例如 https://github.com/user/repo.git: " repo

    if [[ -z "${repo}" ]]; then
        xmg_error "仓库地址不能为空"
        return 1
    fi

    xmg_site_backup

    # 清理临时目录（防止 git clone 失败）
    rm -rf /tmp/xmg-site

    # 安全清空站点目录
    xmg_site_safe_path "${XMG_WWW_DIR}"
    rm -rf "${XMG_WWW_DIR:?}/"*

    xmg_info "正在拉取仓库：${repo}"
    if git clone --depth=1 "${repo}" /tmp/xmg-site; then
        shopt -s dotglob
        cp -a /tmp/xmg-site/* "${XMG_WWW_DIR}/" || true
        shopt -u dotglob
        rm -rf /tmp/xmg-site
        chown -R caddy:caddy "${XMG_WWW_DIR}" 2>/dev/null || true
        find "${XMG_WWW_DIR}" -type d -exec chmod 755 {} \;
        find "${XMG_WWW_DIR}" -type f -exec chmod 644 {} \;
        xmg_info "站点已部署到 ${XMG_WWW_DIR}"
    else
        xmg_error "GitHub 仓库拉取失败，请检查地址或网络"
        return 1
    fi
}

# 清空站点
xmg_site_clear() {
    xmg_warn "即将清空 ${XMG_WWW_DIR}"
    if xmg_confirm "确认清空?"; then
        xmg_site_backup
        xmg_site_safe_path "${XMG_WWW_DIR}"
        rm -rf "${XMG_WWW_DIR:?}/"*
        xmg_info "站点目录已清空"
    else
        xmg_warn "已取消"
    fi
}

# 查看站点目录
xmg_site_show() {
    xmg_mkdirs
    ls -lah "${XMG_WWW_DIR}"
}

# 站点菜单（函数名添加 xmg_ 前缀）
xmg_site_menu() {
    local choice=""
    while true; do
        clear
        echo "========== 站点目录管理 =========="
        echo "1. 从 GitHub 拉取站点"
        echo "2. 备份当前站点"
        echo "3. 清空当前站点"
        echo "4. 查看站点目录"
        echo "0. 返回"
        echo
        printf "请选择: "
        read -r choice || return 0

        case "${choice}" in
            1) xmg_site_pull_from_github; xmg_pause ;;
            2) xmg_site_backup; xmg_pause ;;
            3) xmg_site_clear; xmg_pause ;;
            4) xmg_site_show; xmg_pause ;;
            0) return 0 ;;
            *) xmg_warn "无效选择"; xmg_pause ;;
        esac
    done
}
