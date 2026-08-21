#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# update.sh - XMG 更新模块
#
# 说明：
#   - 从 GitHub 拉取最新版本并更新本地安装
#   - 版本对比：本地主程序 vs GitHub Raw 主程序中的 XMG_VERSION
#   - 更新流程在子 shell 中执行，避免污染调用方的 trap
#   - 所有 XMG 管理文件集中放在 /opt/xmg
#

# ===== 安全加载 =====
if [ "${XMG_UPDATE_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_UPDATE_SH_LOADED=1

# ===== 默认配置 =====
XMG_UPDATE_BRANCH="${XMG_UPDATE_BRANCH:-main}"
XMG_UPDATE_REPO="${XMG_UPDATE_REPO:-AVA-2568/xmg}"
XMG_UPDATE_FORCE="${XMG_UPDATE_FORCE:-0}"
XMG_UPDATE_SKIP_VERIFY="${XMG_UPDATE_SKIP_VERIFY:-0}"

# ===== 依赖 common.sh 的路径变量 =====
XMG_BIN="${XMG_BIN:-$XMG_HOME/bin/xmg}"
XMG_LINK="${XMG_LINK:-/usr/local/bin/xmg}"

# ===== 版本检测 =====

# 从文件内容提取 XMG_VERSION（主程序中的定义形如 XMG_VERSION="${XMG_VERSION:-x.y.z}"）
xmg_update_extract_version() {
    local file="$1"
    local v=""

    [ -r "$file" ] || return 1

    v="$(sed -n 's/.*XMG_VERSION:-\([0-9][0-9.]*\).*/\1/p' "$file" | head -1)"
    [ -n "$v" ] || return 1

    printf '%s\n' "$v"
}

xmg_update_current_version() {
    local v=""

    if [ -x "$XMG_BIN" ]; then
        v="$("$XMG_BIN" version 2>/dev/null | awk '{print $2}')"
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    fi

    xmg_update_extract_version "$XMG_BIN" || printf 'unknown\n'
}

xmg_update_latest_version() {
    local url="https://raw.githubusercontent.com/$XMG_UPDATE_REPO/$XMG_UPDATE_BRANCH/xmg"
    local tmp=""

    tmp="$(mktemp)" || { printf 'unknown\n'; return 0; }

    if xmg_cmd_exists curl; then
        curl -fsSL "$url" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; printf 'unknown\n'; return 0; }
    elif xmg_cmd_exists wget; then
        wget -qO "$tmp" "$url" 2>/dev/null || { rm -f "$tmp"; printf 'unknown\n'; return 0; }
    else
        rm -f "$tmp"
        printf 'unknown\n'
        return 0
    fi

    xmg_update_extract_version "$tmp" || printf 'unknown\n'
    rm -f "$tmp"
}

# 返回值约定：0 = 有可用更新；1 = 无更新或无法确定
xmg_update_check_updates() {
    local current_version=""
    local latest_version=""

    current_version="$(xmg_update_current_version)"
    latest_version="$(xmg_update_latest_version)"

    echo "当前版本: $current_version"
    echo "最新版本: $latest_version ($XMG_UPDATE_REPO@$XMG_UPDATE_BRANCH)"

    if [ "$current_version" != "unknown" ] \
        && [ "$latest_version" != "unknown" ] \
        && [ "$current_version" != "$latest_version" ]; then
        return 0
    fi

    return 1
}

# ===== 拉取更新 =====

# 实际拉取与安装在子 shell 中执行：
#   - 子 shell 内的 EXIT trap 只影响子 shell，不覆盖调用方（monitor）的清理 trap
#   - 子 shell 内 xmg_die 只退出子 shell，失败通过退出码传递
xmg_update_pull() {
    local branch="${1:-$XMG_UPDATE_BRANCH}"

    xmg_update_pull_impl "$branch" || {
        xmg_error "更新失败"
        return 1
    }
}

xmg_update_pull_impl() {
    (
        local branch="${1:-$XMG_UPDATE_BRANCH}"
        local tmp_dir=""
        local repo_url="https://github.com/$XMG_UPDATE_REPO.git"
        local backup_dir=""
        local archive_url=""
        local extracted_dir=""
        local file=""

        # 分支名白名单校验：防止拼入 git 参数与下载 URL 时被注入
        case "$branch" in
            ''|*[!A-Za-z0-9._/-]*)
                xmg_die "分支名包含非法字符: $branch"
                ;;
        esac

        xmg_info "从 GitHub 拉取更新 (分支: $branch)"
        xmg_info "仓库: $repo_url"

        # 检查 git
        if ! command -v git &>/dev/null; then
            xmg_warn "git 不存在，尝试安装"
            if command -v apt-get &>/dev/null; then
                apt-get install -y git || xmg_die "安装 git 失败"
            elif command -v dnf &>/dev/null; then
                dnf install -y git || xmg_die "安装 git 失败"
            elif command -v yum &>/dev/null; then
                yum install -y git || xmg_die "安装 git 失败"
            else
                xmg_die "无法安装 git，请手动安装"
            fi
        fi

        tmp_dir="$(mktemp -d)" || xmg_die "创建临时目录失败"
        trap 'rm -rf "$tmp_dir"' EXIT

        # 克隆仓库
        if ! git clone --depth 1 -b "$branch" "$repo_url" "$tmp_dir" 2>/dev/null; then
            xmg_warn "git clone 失败，尝试使用 curl 下载压缩包"
            archive_url="https://github.com/$XMG_UPDATE_REPO/archive/refs/heads/$branch.tar.gz"

            rm -rf "$tmp_dir"
            tmp_dir="$(mktemp -d)" || xmg_die "创建临时目录失败"

            if command -v curl &>/dev/null; then
                curl -fsSL "$archive_url" -o "$tmp_dir/repo.tar.gz" || xmg_die "下载失败"
            elif command -v wget &>/dev/null; then
                wget -qO "$tmp_dir/repo.tar.gz" "$archive_url" || xmg_die "下载失败"
            else
                xmg_die "没有可用的下载工具 (curl/wget)"
            fi

            tar -xzf "$tmp_dir/repo.tar.gz" -C "$tmp_dir" || xmg_die "解压失败"
            # 压缩包会多一层目录，调整路径
            extracted_dir="$(find "$tmp_dir" -maxdepth 1 -mindepth 1 -type d ! -name '*.tar.gz' | head -1)"
            if [ -n "$extracted_dir" ] && [ "$extracted_dir" != "$tmp_dir" ]; then
                mv "$extracted_dir"/* "$tmp_dir/" 2>/dev/null || true
                rmdir "$extracted_dir" 2>/dev/null || true
            fi
        fi

        # 确认代码已拉取
        if [ ! -f "$tmp_dir/xmg" ] || [ ! -d "$tmp_dir/lib" ]; then
            xmg_die "拉取的代码不完整，缺少 xmg 或 lib/ 目录"
        fi

        # 将新代码安装到 XMG 统一目录
        xmg_info "正在安装更新到 $XMG_HOME"

        # 备份当前配置
        backup_dir="${XMG_BACKUP_DIR}/update_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir" 2>/dev/null || true

        if [ -d "$XMG_LIB_DIR" ]; then
            cp -r "$XMG_LIB_DIR" "$backup_dir/" 2>/dev/null || xmg_warn "备份当前模块失败"
        fi
        if [ -f "$XMG_BIN" ]; then
            cp "$XMG_BIN" "$backup_dir/" 2>/dev/null || xmg_warn "备份当前主程序失败"
        fi

        xmg_info "已备份当前版本到: $backup_dir"

        # 安装主程序
        install -m 0755 -o root -g root "$tmp_dir/xmg" "$XMG_BIN" || xmg_die "安装主程序失败"

        # 安装模块
        mkdir -p "$XMG_LIB_DIR"
        for file in "$tmp_dir/lib"/*.sh; do
            [ -f "$file" ] || continue
            install -m 0644 -o root -g root "$file" "$XMG_LIB_DIR/" || xmg_warn "安装模块失败: $file"
        done

        # 同步模块清单（menu 模块发现依赖 $XMG_HOME/xmg.files）
        if [ -f "$tmp_dir/xmg.files" ]; then
            install -m 0644 -o root -g root "$tmp_dir/xmg.files" "$XMG_HOME/xmg.files" \
                || xmg_warn "同步 xmg.files 失败"
        fi

        # 重建命令入口软链接
        mkdir -p "$(dirname "$XMG_LINK")"
        ln -sf "$XMG_BIN" "$XMG_LINK" || xmg_warn "重建命令入口软链接失败"

        xmg_info "更新安装完成"
        xmg_info "命令入口: $XMG_LINK"
        xmg_info "主程序: $XMG_BIN"
        xmg_info "模块目录: $XMG_LIB_DIR"
    ) || return 1

    return 0
}

# ===== 验证更新 =====
xmg_update_verify() {
    xmg_info "验证更新..."

    local errors=0

    # 检查主程序
    if [ ! -f "$XMG_BIN" ]; then
        xmg_warn "主程序不存在: $XMG_BIN"
        errors=$((errors + 1))
    elif [ ! -x "$XMG_BIN" ]; then
        xmg_warn "主程序不可执行: $XMG_BIN"
        errors=$((errors + 1))
    else
        xmg_info "主程序: OK ($XMG_BIN)"
    fi

    # 检查命令入口
    if [ ! -L "$XMG_LINK" ]; then
        xmg_warn "命令入口不是软链接: $XMG_LINK"
        errors=$((errors + 1))
    elif [ "$(readlink "$XMG_LINK")" != "$XMG_BIN" ]; then
        xmg_warn "命令入口指向错误: $XMG_LINK -> $(readlink "$XMG_LINK")"
        errors=$((errors + 1))
    else
        xmg_info "命令入口: OK ($XMG_LINK -> $XMG_BIN)"
    fi

    # 检查核心模块
    local core_modules=("common.sh" "system.sh" "menu.sh" "monitor.sh")
    local module=""
    for module in "${core_modules[@]}"; do
        if [ ! -f "$XMG_LIB_DIR/$module" ]; then
            xmg_warn "模块缺失: $XMG_LIB_DIR/$module"
            errors=$((errors + 1))
        else
            xmg_info "模块: OK ($XMG_LIB_DIR/$module)"
        fi
    done

    # 检查统一目录结构
    local required_dirs=("$XMG_BIN_DIR" "$XMG_LIB_DIR" "$XMG_ETC_DIR" "$XMG_RUN_DIR" "$XMG_LOG_DIR" "$XMG_BACKUP_DIR" "$XMG_WWW_DIR" "$XMG_CADDY_DIR" "$XMG_XRAY_DIR")
    local dir=""
    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            xmg_warn "目录缺失: $dir"
            errors=$((errors + 1))
        fi
    done

    if [ "$errors" -eq 0 ]; then
        xmg_info "验证通过"
        return 0
    else
        xmg_warn "验证发现 $errors 个问题"
        return 1
    fi
}

# ===== 执行更新 =====
xmg_update_run() {
    local branch="${1:-$XMG_UPDATE_BRANCH}"
    local force="${2:-$XMG_UPDATE_FORCE}"
    local skip_verify="${3:-$XMG_UPDATE_SKIP_VERIFY}"

    xmg_require_root

    xmg_info "开始更新 XMG"
    xmg_info "分支: $branch"
    xmg_info "目标目录: $XMG_HOME"

    # 检查更新（返回 0 表示有可用更新）
    if [ "$force" != "1" ]; then
        if xmg_update_check_updates; then
            if ! xmg_confirm "发现新版本，是否更新?"; then
                xmg_info "已取消"
                return 0
            fi
        else
            xmg_info "当前已是最新版本（或无法确定远端版本）"
            if ! xmg_confirm "是否强制重新安装?"; then
                xmg_info "已取消"
                return 0
            fi
        fi
    fi

    # 拉取更新
    if ! xmg_update_pull "$branch"; then
        return 1
    fi

    # 验证
    if [ "$skip_verify" != "1" ]; then
        xmg_update_verify
    fi

    xmg_info "更新完成"
    xmg_info "路径摘要:"
    xmg_info "  XMG_HOME:       $XMG_HOME"
    xmg_info "  命令入口:       $XMG_LINK"
    xmg_info "  主程序:         $XMG_BIN"
    xmg_info "  模块目录:       $XMG_LIB_DIR"
    xmg_info "  配置目录:       $XMG_ETC_DIR"
    xmg_info "  日志目录:       $XMG_LOG_DIR"
    xmg_info "  站点目录:       $XMG_WWW_DIR"
    xmg_info "  Caddy配置:      $XMG_CADDYFILE"
    xmg_info "  Xray配置:       $XMG_XRAY_CONFIG"

    return 0
}

# ===== 回滚更新 =====
xmg_update_rollback() {
    local backup_dir="${1:-}"
    local backups=()
    local dir=""
    local i=0
    local choice=""
    local file=""

    if [ -z "$backup_dir" ]; then
        # 列出可用备份
        if [ -d "$XMG_BACKUP_DIR" ]; then
            for dir in "$XMG_BACKUP_DIR"/update_*; do
                [ -d "$dir" ] || continue
                backups+=("$dir")
            done
        fi

        if [ ${#backups[@]} -eq 0 ]; then
            xmg_warn "没有可用的备份"
            return 1
        fi

        echo "可用的备份:"
        for i in "${!backups[@]}"; do
            echo "$((i + 1)). ${backups[$i]}"
        done

        printf "请选择要回滚的备份: "
        read -r choice || return 1

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
            xmg_warn "无效选择"
            return 1
        fi

        backup_dir="${backups[$((choice - 1))]}"
    fi

    if [ ! -d "$backup_dir" ]; then
        xmg_warn "备份目录不存在: $backup_dir"
        return 1
    fi

    xmg_info "从备份回滚: $backup_dir"

    # 回滚主程序
    if [ -f "$backup_dir/xmg" ]; then
        install -m 0755 -o root -g root "$backup_dir/xmg" "$XMG_BIN" || xmg_warn "回滚主程序失败"
        xmg_info "主程序已回滚"
    fi

    # 回滚模块
    if [ -d "$backup_dir/lib" ]; then
        for file in "$backup_dir/lib"/*.sh; do
            [ -f "$file" ] || continue
            install -m 0644 -o root -g root "$file" "$XMG_LIB_DIR/" || xmg_warn "回滚模块失败: $file"
        done
        xmg_info "模块已回滚"
    fi

    # 重建命令入口
    mkdir -p "$(dirname "$XMG_LINK")"
    ln -sf "$XMG_BIN" "$XMG_LINK" || xmg_warn "重建命令入口失败"

    xmg_info "回滚完成"
}

# ===== 更新菜单 =====
xmg_update_menu() {
    local choice=""
    local branch=""

    while true; do
        clear
        echo "========== XMG 更新管理 =========="
        echo "1. 检查更新"
        echo "2. 执行更新"
        echo "3. 强制更新 (跳过版本检查)"
        echo "4. 验证安装"
        echo "5. 回滚更新"
        echo "6. 指定分支更新 (当前: $XMG_UPDATE_BRANCH)"
        echo "0. 返回"
        echo
        echo "当前配置:"
        echo "  仓库: $XMG_UPDATE_REPO"
        echo "  分支: $XMG_UPDATE_BRANCH"
        echo "  安装目录: $XMG_HOME"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_update_check_updates
                xmg_pause
                ;;
            2)
                xmg_update_run
                xmg_pause
                ;;
            3)
                xmg_update_run "$XMG_UPDATE_BRANCH" 1
                xmg_pause
                ;;
            4)
                xmg_update_verify
                xmg_pause
                ;;
            5)
                xmg_update_rollback
                xmg_pause
                ;;
            6)
                printf "请输入分支名 (当前: $XMG_UPDATE_BRANCH): "
                read -r branch || continue
                [ -z "$branch" ] && continue
                xmg_update_run "$branch"
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
    xmg_update_menu
fi
