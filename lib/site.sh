#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# site.sh - XMG 站点目录管理
#
# 说明：
#   - 本模块只管理站点文件目录
#   - 本模块不创建、不编辑、不校验 Caddyfile
#   - 默认站点目录由 XMG_WWW_DIR 控制，通常为 /opt/xmg/www
#   - 文件内容应使用 UTF-8 编码保存
#   - 所有 XMG 管理的文件集中放在 /opt/xmg 下
#

# site.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "site.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_SITE_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_SITE_SH_LOADED=1

# ===== 路径安全检查 =====
# 只允许操作 XMG_WWW_DIR 本身或其子路径，并拒绝常见危险路径。
xmg_site_safe_path() {
    local path="$1"

    # 拒绝系统级危险路径和 XMG 根目录
    case "$path" in
        ""|"/"|"/usr"|"/usr/local"|"/etc"|"/var"|"/var/www"|"/var/log"|"/var/backups"|"/home"|"/home/"*)
            xmg_die "拒绝操作危险路径: $path"
            ;;
        "/opt"|"/opt/xmg")
            xmg_die "拒绝操作 XMG 根目录: $path"
            ;;
    esac

    # 拒绝路径穿越
    case "$path" in
        *"/../"*|*"/.."|".."|"../"*)
            xmg_die "拒绝包含路径穿越的路径: $path"
            ;;
    esac

    # 确认路径在站点目录下
    case "$path" in
        "$XMG_WWW_DIR"|"$XMG_WWW_DIR"/*)
            return 0
            ;;
        *)
            xmg_die "路径不在站点目录下: $path"
            ;;
    esac
}

xmg_site_need_git() {
    if ! xmg_cmd_exists git; then
        xmg_die "git 不存在，请先安装 git 后再拉取站点"
    fi
}

# 准备站点目录，由 xmg_mkdirs 统一创建 /opt/xmg 目录结构
xmg_site_prepare_www() {
    xmg_require_root
    xmg_mkdirs
    xmg_site_safe_path "$XMG_WWW_DIR"

    mkdir -p "$XMG_WWW_DIR" || xmg_die "创建站点目录失败: $XMG_WWW_DIR"
}

# 判断站点目录是否有内容，包括隐藏文件。
xmg_site_dir_has_content() {
    local item=""

    [ -d "$XMG_WWW_DIR" ] || return 1

    shopt -s nullglob dotglob
    for item in "$XMG_WWW_DIR"/*; do
        shopt -u nullglob dotglob
        return 0
    done
    shopt -u nullglob dotglob

    return 1
}

# 安全清空站点目录，包括隐藏文件。
xmg_site_empty_dir() {
    local item=""

    xmg_require_root
    xmg_site_safe_path "$XMG_WWW_DIR"

    [ -d "$XMG_WWW_DIR" ] || mkdir -p "$XMG_WWW_DIR"

    shopt -s nullglob dotglob
    for item in "$XMG_WWW_DIR"/*; do
        xmg_site_safe_path "$item"
        rm -rf --one-file-system -- "$item" || xmg_die "删除失败: $item"
    done
    shopt -u nullglob dotglob
}

# 备份当前站点。
xmg_site_backup() {
    local ts=""
    local backup=""

    xmg_require_root
    xmg_mkdirs
    xmg_site_safe_path "$XMG_WWW_DIR"

    if ! xmg_site_dir_has_content; then
        xmg_warn "站点目录为空，无需备份"
        return 0
    fi

    ts="$(xmg_timestamp)"
    backup="$XMG_BACKUP_DIR/xmg-site.${ts}.tar.gz"

    mkdir -p "$XMG_BACKUP_DIR" || xmg_die "创建备份目录失败: $XMG_BACKUP_DIR"

    tar -czf "$backup" -C "$XMG_WWW_DIR" . || xmg_die "站点备份失败"
    xmg_info "当前站点已备份到 $backup"
}

xmg_site_validate_git_url() {
    local repo="$1"

    if [ -z "$repo" ]; then
        xmg_error "仓库地址不能为空"
        return 1
    fi

    case "$repo" in
        https://github.com/*|http://github.com/*|git@github.com:*|ssh://git@github.com/*)
            return 0
            ;;
        https://*.git|http://*.git|ssh://*|git@*:*)
            # 允许非 GitHub Git 地址，但给出提醒。
            xmg_warn "当前不是标准 GitHub 地址，将按普通 Git 仓库处理"
            return 0
            ;;
        *)
            xmg_error "仓库地址格式不支持: $repo"
            return 1
            ;;
    esac
}

# 从 Git 仓库拉取站点。
xmg_site_pull_from_github() {
    local repo=""
    local tmpdir=""

    xmg_require_root
    xmg_site_need_git
    xmg_site_prepare_www

    printf "请输入 Git 仓库地址，例如 https://github.com/user/repo.git: "
    read -r repo || return 1

    if ! xmg_site_validate_git_url "$repo"; then
        return 1
    fi

    tmpdir="$(mktemp -d)" || xmg_die "创建临时目录失败"

    # 函数退出时清理临时目录。
    xmg_site_cleanup_tmp() {
        if [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ]; then
            rm -rf -- "$tmpdir"
        fi
    }
    trap xmg_site_cleanup_tmp RETURN

    xmg_site_backup

    xmg_info "正在拉取仓库: $repo"

    if ! git clone --depth=1 "$repo" "$tmpdir/repo"; then
        xmg_error "Git 仓库拉取失败，请检查地址或网络"
        return 1
    fi

    xmg_site_empty_dir

    shopt -s dotglob nullglob
    if ! cp -a "$tmpdir/repo"/* "$XMG_WWW_DIR"/ 2>/dev/null; then
        shopt -u dotglob nullglob
        xmg_die "复制站点文件失败"
    fi
    shopt -u dotglob nullglob

    # 设置站点文件权限
    # 如果系统中存在 caddy 用户，将站点目录归属给 caddy
    if id caddy >/dev/null 2>&1; then
        chown -R caddy:caddy "$XMG_WWW_DIR" 2>/dev/null || true
    fi

    find "$XMG_WWW_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$XMG_WWW_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true

    xmg_info "站点已部署到 $XMG_WWW_DIR"
    xmg_warn "XMG 不修改 Caddyfile，如需生效请用户自行配置或重载 Caddy"
}

# 清空站点。
xmg_site_clear() {
    xmg_require_root
    xmg_site_prepare_www

    xmg_warn "即将清空 $XMG_WWW_DIR"

    if xmg_confirm "确认清空当前站点目录?"; then
        xmg_site_backup
        xmg_site_empty_dir
        xmg_info "站点目录已清空"
    else
        xmg_info "已取消"
    fi
}

# 查看站点目录。
xmg_site_show() {
    xmg_mkdirs

    echo "站点目录: $XMG_WWW_DIR"
    echo

    if [ ! -d "$XMG_WWW_DIR" ]; then
        xmg_warn "站点目录不存在: $XMG_WWW_DIR"
        return 0
    fi

    ls -lah "$XMG_WWW_DIR"
}

# 站点菜单。
xmg_site_menu() {
    local choice=""

    while true; do
        clear
        echo "========== 站点目录管理 =========="
        echo "1. 从 Git 仓库拉取站点"
        echo "2. 备份当前站点"
        echo "3. 清空当前站点"
        echo "4. 查看站点目录"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - XMG 只管理站点文件目录"
        echo "  - XMG 不创建、不编辑、不校验 Caddyfile"
        echo "  - 拉取站点需要系统已安装 git"
        echo "  - 站点目录: $XMG_WWW_DIR"
        echo "  - 备份目录: $XMG_BACKUP_DIR"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_site_pull_from_github
                xmg_pause
                ;;
            2)
                xmg_site_backup
                xmg_pause
                ;;
            3)
                xmg_site_clear
                xmg_pause
                ;;
            4)
                xmg_site_show
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

# ===== 直接执行支持 =====
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    xmg_site_menu
fi
