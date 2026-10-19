#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# update.sh - XMG 更新模块
#
# XMG_MENU_LABEL: 版本在线升级
#
# 说明：
#   - 从 GitHub 拉取最新版本并更新本地安装
#   - 版本对比：本地主程序 vs GitHub Raw 主程序中的 XMG_VERSION
#   - 原子替换与完整回滚保护 (lib, bin, templates, xmg.files)
#   - 绝不依赖 17 模块硬编码 fallback
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
XMG_BIN="${XMG_BIN:-${XMG_HOME:-/opt/xmg}/bin/xmg}"
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

# ===== 清单刷新 =====
xmg_update_refresh_manifest() {
    local target_root="${1:-$XMG_HOME}"
    local manifest="${target_root}/xmg.files"
    local tmp_manifest="${manifest}.tmp.$$"

    {
        printf 'xmg\n'
        if [ -d "$target_root/lib" ]; then
            for f in "$target_root/lib"/*.sh; do
                [ -f "$f" ] || continue
                printf 'lib/%s\n' "${f##*/}"
            done
        fi
        if [ -d "$target_root/templates" ]; then
            for f in "$target_root/templates"/*; do
                [ -f "$f" ] || continue
                printf 'templates/%s\n' "${f##*/}"
            done
        fi
        printf 'xmg.files\n'
    } > "$tmp_manifest" 2>/dev/null || return 1

    mv "$tmp_manifest" "$manifest" 2>/dev/null || cp "$tmp_manifest" "$manifest"
    rm -f "$tmp_manifest" 2>/dev/null || true
    chmod 0644 "$manifest" 2>/dev/null || true
}

# ===== 原子替换与完整回滚 =====
xmg_update_apply_atomic() {
    local src_dir="$1"
    local src_bin=""
    local src_lib=""
    local src_tpl=""
    local src_manifest=""

    # 1. 查找源文件结构
    if [ -f "$src_dir/xmg" ]; then
        src_bin="$src_dir/xmg"
    elif [ -f "$src_dir/bin/xmg" ]; then
        src_bin="$src_dir/bin/xmg"
    fi

    if [ -d "$src_dir/lib" ]; then
        src_lib="$src_dir/lib"
    fi

    if [ -d "$src_dir/templates" ]; then
        src_tpl="$src_dir/templates"
    fi

    if [ -f "$src_dir/xmg.files" ]; then
        src_manifest="$src_dir/xmg.files"
    fi

    if [ -z "$src_bin" ] || [ -z "$src_lib" ]; then
        xmg_error "更新源不完整: 缺少 xmg 主程序或 lib 模块目录"
        return 1
    fi

    # 2. 语法自检验证，严防损坏包破坏运行时
    if ! bash -n "$src_bin" >/dev/null 2>&1; then
        xmg_error "主程序语法校验失败: $src_bin"
        return 1
    fi

    local f=""
    for f in "$src_lib"/*.sh; do
        [ -f "$f" ] || continue
        if ! bash -n "$f" >/dev/null 2>&1; then
            xmg_error "模块语法校验失败: $f"
            return 1
        fi
    done

    # 3. 准备 staging 暂存目录
    local staging_dir="${XMG_HOME}/.staging_update_$$"
    rm -rf "$staging_dir" 2>/dev/null || true
    mkdir -p "$staging_dir/bin" "$staging_dir/lib"

    cp "$src_bin" "$staging_dir/bin/xmg" || { rm -rf "$staging_dir"; return 1; }
    chmod 0755 "$staging_dir/bin/xmg" 2>/dev/null || true

    for f in "$src_lib"/*.sh; do
        [ -f "$f" ] || continue
        cp "$f" "$staging_dir/lib/" || { rm -rf "$staging_dir"; return 1; }
        chmod 0644 "$staging_dir/lib/${f##*/}" 2>/dev/null || true
    done

    if [ -n "$src_tpl" ] && [ -d "$src_tpl" ]; then
        mkdir -p "$staging_dir/templates"
        cp -r "$src_tpl"/* "$staging_dir/templates/" 2>/dev/null || true
    elif [ -d "$XMG_HOME/templates" ]; then
        mkdir -p "$staging_dir/templates"
        cp -r "$XMG_HOME/templates"/* "$staging_dir/templates/" 2>/dev/null || true
    fi

    if [ -n "$src_manifest" ] && [ -f "$src_manifest" ]; then
        cp "$src_manifest" "$staging_dir/xmg.files" 2>/dev/null || true
    else
        xmg_update_refresh_manifest "$staging_dir"
    fi

    # 4. 校验 staging 完整性
    if [ ! -x "$staging_dir/bin/xmg" ] || [ ! -f "$staging_dir/lib/common.sh" ]; then
        xmg_error "staging 完整性校验失败"
        rm -rf "$staging_dir" 2>/dev/null || true
        return 1
    fi

    # 5. 备份当前完整运行时 (lib, bin, templates, xmg.files)
    local backup_dir="${XMG_BACKUP_DIR}/update_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir" 2>/dev/null || true

    [ -d "$XMG_HOME/lib" ] && cp -r "$XMG_HOME/lib" "$backup_dir/lib" 2>/dev/null || true
    [ -d "$XMG_HOME/bin" ] && cp -r "$XMG_HOME/bin" "$backup_dir/bin" 2>/dev/null || true
    [ -d "$XMG_HOME/templates" ] && cp -r "$XMG_HOME/templates" "$backup_dir/templates" 2>/dev/null || true
    [ -f "$XMG_HOME/xmg.files" ] && cp "$XMG_HOME/xmg.files" "$backup_dir/xmg.files" 2>/dev/null || true

    # 6. 原子目录切换与回滚
    local switch_ok=1

    # 移出当前目录为旧备份临时态
    [ -d "$XMG_HOME/lib" ] && mv "$XMG_HOME/lib" "$XMG_HOME/.lib.old.$$" 2>/dev/null || true
    [ -d "$XMG_HOME/bin" ] && mv "$XMG_HOME/bin" "$XMG_HOME/.bin.old.$$" 2>/dev/null || true
    [ -d "$XMG_HOME/templates" ] && mv "$XMG_HOME/templates" "$XMG_HOME/.templates.old.$$" 2>/dev/null || true
    [ -f "$XMG_HOME/xmg.files" ] && mv "$XMG_HOME/xmg.files" "$XMG_HOME/.xmg.files.old.$$" 2>/dev/null || true

    # 移入 staging
    mv "$staging_dir/lib" "$XMG_HOME/lib" 2>/dev/null || switch_ok=0
    mv "$staging_dir/bin" "$XMG_HOME/bin" 2>/dev/null || switch_ok=0
    if [ -d "$staging_dir/templates" ]; then
        mv "$staging_dir/templates" "$XMG_HOME/templates" 2>/dev/null || switch_ok=0
    fi
    if [ -f "$staging_dir/xmg.files" ]; then
        mv "$staging_dir/xmg.files" "$XMG_HOME/xmg.files" 2>/dev/null || switch_ok=0
    fi

    # 若切换失败，立即触发原子回滚
    if [ "$switch_ok" -ne 1 ]; then
        xmg_error "原子替换失败，正在触发完整自动回滚..."
        rm -rf "$XMG_HOME/lib" "$XMG_HOME/bin" "$XMG_HOME/templates" "$XMG_HOME/xmg.files" 2>/dev/null || true
        [ -d "$XMG_HOME/.lib.old.$$" ] && mv "$XMG_HOME/.lib.old.$$" "$XMG_HOME/lib" 2>/dev/null || true
        [ -d "$XMG_HOME/.bin.old.$$" ] && mv "$XMG_HOME/.bin.old.$$" "$XMG_HOME/bin" 2>/dev/null || true
        [ -d "$XMG_HOME/.templates.old.$$" ] && mv "$XMG_HOME/.templates.old.$$" "$XMG_HOME/templates" 2>/dev/null || true
        [ -f "$XMG_HOME/.xmg.files.old.$$" ] && mv "$XMG_HOME/.xmg.files.old.$$" "$XMG_HOME/xmg.files" 2>/dev/null || true
        rm -rf "$staging_dir" 2>/dev/null || true
        return 1
    fi

    # 清理暂存态与旧临时目录
    rm -rf "$XMG_HOME/.lib.old.$$" "$XMG_HOME/.bin.old.$$" "$XMG_HOME/.templates.old.$$" "$XMG_HOME/.xmg.files.old.$$" "$staging_dir" 2>/dev/null || true

    # 同步配置模板到 etc/xray
    if [ -d "$XMG_HOME/templates" ]; then
        mkdir -p "$XMG_ETC_DIR/xray"
        cp -r "$XMG_HOME/templates"/* "$XMG_ETC_DIR/xray/" 2>/dev/null || true
    fi

    # 重建软链接
    mkdir -p "$(dirname "$XMG_LINK")" 2>/dev/null || true
    ln -sf "$XMG_BIN" "$XMG_LINK" 2>/dev/null || true

    # 刷新 xmg.files 清单
    xmg_update_refresh_manifest "$XMG_HOME"

    xmg_info "原子更新与清单同步成功！"
    return 0
}

# ===== 拉取更新 =====
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
        local archive_url=""
        local extracted_dir=""

        case "$branch" in
            ''|*[!A-Za-z0-9._/-]*)
                xmg_die "分支名包含非法字符: $branch"
                ;;
        esac

        xmg_info "从 GitHub 拉取更新 (分支: $branch)"
        xmg_info "仓库: $repo_url"

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
            xmg_warn "git clone 失败，尝试使用 curl/wget 下载压缩包"
            archive_url="https://github.com/$XMG_UPDATE_REPO/archive/refs/heads/$branch.tar.gz"

            rm -rf "$tmp_dir"
            tmp_dir="$(mktemp -d)" || xmg_die "创建临时目录失败"

            local download_ok=0
            local urls=(
                "$archive_url"
                "https://ghfast.top/$archive_url"
            )

            for u in "${urls[@]}"; do
                xmg_info "尝试下载源: $u"
                if command -v curl &>/dev/null; then
                    if curl -fsSL --connect-timeout 8 "$u" -o "$tmp_dir/repo.tar.gz" 2>/dev/null; then
                        download_ok=1
                        break
                    fi
                elif command -v wget &>/dev/null; then
                    if wget -q -T 8 -O "$tmp_dir/repo.tar.gz" "$u" 2>/dev/null; then
                        download_ok=1
                        break
                    fi
                fi
            done

            if [ "$download_ok" -eq 0 ]; then
                xmg_error "下载失败: 无法连接 GitHub"
                return 1
            fi

            tar -xzf "$tmp_dir/repo.tar.gz" -C "$tmp_dir" || xmg_die "解压失败"
            extracted_dir="$(find "$tmp_dir" -maxdepth 1 -mindepth 1 -type d ! -name '*.tar.gz' | head -1)"
            if [ -n "$extracted_dir" ] && [ "$extracted_dir" != "$tmp_dir" ]; then
                mv "$extracted_dir"/* "$tmp_dir/" 2>/dev/null || true
                rmdir "$extracted_dir" 2>/dev/null || true
            fi
        fi

        # 执行原子替换与完整回滚保护
        xmg_update_apply_atomic "$tmp_dir" || return 1
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

    # 严格根据 xmg.files 清单校验，绝不使用 17 模块硬编码 fallback
    local core_modules=()
    local manifest="${XMG_HOME}/xmg.files"
    local line=""

    if [ ! -f "$manifest" ] || [ ! -r "$manifest" ]; then
        xmg_warn "清单文件不存在或不可读: $manifest"
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
            lib/*.sh) core_modules+=("${line#lib/}") ;;
        esac
    done < "$manifest"

    if [ "${#core_modules[@]}" -eq 0 ]; then
        xmg_warn "清单中未定义任何 lib/*.sh 模块"
        return 1
    fi

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
    local required_dirs=("${XMG_BIN_DIR:-$XMG_HOME/bin}" "${XMG_LIB_DIR:-$XMG_HOME/lib}" "${XMG_ETC_DIR:-$XMG_HOME/etc}" "${XMG_RUN_DIR:-$XMG_HOME/run}" "${XMG_LOG_DIR:-$XMG_HOME/log}" "${XMG_BACKUP_DIR:-$XMG_HOME/backups}" "${XMG_XRAY_DIR:-$XMG_HOME/xray}")
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

    if ! xmg_update_pull "$branch"; then
        return 1
    fi

    if [ "$skip_verify" != "1" ]; then
        xmg_update_verify
    fi

    hash -r 2>/dev/null || true
    xmg_info "更新完成！"
    xmg_info "路径摘要:"
    xmg_info "  XMG_HOME:       $XMG_HOME"
    xmg_info "  命令入口:       $XMG_LINK"
    xmg_info "  主程序:         $XMG_BIN"
    xmg_info "  模块目录:       $XMG_LIB_DIR"
    xmg_info "  配置目录:       $XMG_ETC_DIR"
    xmg_info "  日志目录:       $XMG_LOG_DIR"
    xmg_info "  Xray配置:       $XMG_XRAY_CONFIG"

    if [ -t 0 ] && [ -t 1 ]; then
        echo
        if xmg_confirm "是否立即原地重新载入最新版 XMG 菜单 (免断开重连)?"; then
            exec "$XMG_BIN" menu
        fi
    fi

    return 0
}

# ===== 回滚更新 =====
xmg_update_rollback() {
    local backup_dir="${1:-}"
    local backups=()
    local dir=""
    local i=0
    local choice=""

    if [ -z "$backup_dir" ]; then
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

    # 1. 回滚主程序与 bin 目录
    mkdir -p "$XMG_HOME/bin"
    if [ -d "$backup_dir/bin" ]; then
        cp -r "$backup_dir/bin"/* "$XMG_HOME/bin/" 2>/dev/null || true
    elif [ -f "$backup_dir/xmg" ]; then
        cp "$backup_dir/xmg" "$XMG_HOME/bin/xmg"
    fi
    [ -f "$XMG_BIN" ] && chmod 0755 "$XMG_BIN" 2>/dev/null || true

    # 2. 回滚 lib 模块目录
    if [ -d "$backup_dir/lib" ]; then
        mkdir -p "$XMG_HOME/lib"
        cp -r "$backup_dir/lib"/* "$XMG_HOME/lib/" 2>/dev/null || true
        chmod 0644 "$XMG_HOME/lib"/*.sh 2>/dev/null || true
    fi

    # 3. 回滚 templates 目录
    if [ -d "$backup_dir/templates" ]; then
        mkdir -p "$XMG_HOME/templates"
        cp -r "$backup_dir/templates"/* "$XMG_HOME/templates/" 2>/dev/null || true
    fi

    # 4. 回滚 xmg.files 清单
    if [ -f "$backup_dir/xmg.files" ]; then
        cp "$backup_dir/xmg.files" "$XMG_HOME/xmg.files" 2>/dev/null || true
        chmod 0644 "$XMG_HOME/xmg.files" 2>/dev/null || true
    fi

    # 5. 重建命令入口软链接
    mkdir -p "$(dirname "$XMG_LINK")" 2>/dev/null || true
    ln -sf "$XMG_BIN" "$XMG_LINK" 2>/dev/null || true

    xmg_info "回滚完成"
    return 0
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
