#!/usr/bin/env bash
#
# update.sh - XMG 更新模块
#

########################################
# 获取当前版本（可选）
########################################

get_local_version() {
    if command -v git >/dev/null 2>&1; then
        git -C /opt/xmg rev-parse --short HEAD 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

########################################
# 更新 XMG
########################################

xmg_update() {
    echo
    echo "========== XMG 更新 =========="

    local dir="/opt/xmg"

    # 1. 检查目录
    if [[ ! -d "$dir" ]]; then
        echo "[ERROR] 未检测到安装目录：$dir"
        return 1
    fi

    # 2. 检查 git
    if ! command -v git >/dev/null 2>&1; then
        echo "[INFO] 安装 git..."
        apt-get update
        apt-get install -y git
    fi

    # 3. 检查 git 仓库
    if [[ ! -d "$dir/.git" ]]; then
        echo "[ERROR] 当前不是 Git 安装版本，无法自动更新"
        echo "请重新通过 install.sh 安装"
        return 1
    fi

    echo "[INFO] 当前版本: $(get_local_version)"

    echo "[INFO] 拉取最新代码..."

    if git -C "$dir" pull --ff-only; then
        echo "[OK] 已更新到最新版本 ✅"
    else
        echo "[ERROR] 更新失败，请检查网络或冲突"
        return 1
    fi

    ########################################
    # 修复权限
    ########################################

    chmod +x "$dir/xmg.sh" 2>/dev/null || true
    chmod +x "$dir/install.sh" 2>/dev/null || true
    chmod +x "$dir/uninstall.sh" 2>/dev/null || true

    find "$dir/lib" -type f -name "*.sh" -exec chmod 644 {} \;

    echo "[OK] 权限修复完成"

    ########################################
    # 完成
    ########################################

    echo
    echo "更新完成 ✅"
    echo "请重新运行：xmg"
}
