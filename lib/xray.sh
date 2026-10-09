#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# xray.sh - Xray 服务生命周期管理
#
# 说明：
#   - 安装与更新内核：见 lib/core.sh（支持 stable/preview/pinned 通道）
#   - 配置能力已迁移至 state.sh / render.sh / proxy.sh
#   - 本文件只负责 systemd drop-in 与服务生命周期
#   - 所有 XMG 管理的 Xray 配置集中放在 /opt/xmg/xray 下
#

# ===== 安全加载 =====
if [ "${XMG_XRAY_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_XRAY_SH_LOADED=1

# ===== 默认配置 =====
XMG_XRAY_SERVICE="${XMG_XRAY_SERVICE:-xray}"
XMG_XRAY_INSTALL_URL="${XMG_XRAY_INSTALL_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"

# ===== 依赖 common.sh 的路径变量 =====
if [ -z "${XMG_HOME:-}" ]; then
    XMG_HOME="${XMG_HOME:-/opt/xmg}"
fi
if [ -z "${XMG_XRAY_DIR:-}" ]; then
    XMG_XRAY_DIR="${XMG_XRAY_DIR:-$XMG_HOME/xray}"
fi
if [ -z "${XMG_XRAY_CONFIG:-}" ]; then
    XMG_XRAY_CONFIG="${XMG_XRAY_CONFIG:-$XMG_XRAY_DIR/config.json}"
fi
if [ -z "${XMG_LOG_DIR:-}" ]; then
    XMG_LOG_DIR="${XMG_LOG_DIR:-$XMG_HOME/log}"
fi
if [ -z "${XMG_RUN_DIR:-}" ]; then
    XMG_RUN_DIR="${XMG_RUN_DIR:-$XMG_HOME/run}"
fi

# Xray 在 XMG 统一目录下的日志目录
XMG_XRAY_LOG_DIR="${XMG_XRAY_LOG_DIR:-$XMG_LOG_DIR/xray}"

# ===== 基础检测 =====

xmg_xray_binary_exists() {
    xmg_cmd_exists xray || [ -x /usr/local/bin/xray ] || [ -x /usr/bin/xray ]
}

xmg_xray_get_bin() {
    if xmg_cmd_exists xray; then
        command -v xray
        return 0
    fi
    if [ -x /usr/local/bin/xray ]; then
        printf '%s\n' "/usr/local/bin/xray"
        return 0
    fi
    if [ -x /usr/bin/xray ]; then
        printf '%s\n' "/usr/bin/xray"
        return 0
    fi
    return 1
}

xmg_xray_is_systemd_available() {
    xmg_cmd_exists systemctl
}

xmg_xray_print_version() {
    local xray_bin=""
    xray_bin="$(xmg_xray_get_bin)" || return 1
    "$xray_bin" version 2>/dev/null | head -1 || true
}

# ===== 自动修改 systemd unit 的 ExecStart =====
# 确保 Xray 服务启动时读取的是 XMG 统一配置路径
# ============================================================
# 修复后的 xmg_xray_patch_systemd_unit 函数
# ============================================================
xmg_xray_patch_systemd_unit() {
    local xray_unit=""
    local unit_found=0

    # 查找 Xray 的 systemd unit 文件
    for path in "/etc/systemd/system/xray.service" "/lib/systemd/system/xray.service" "/usr/lib/systemd/system/xray.service"; do
        if [ -f "$path" ]; then
            xray_unit="$path"
            unit_found=1
            break
        fi
    done

    if [ "$unit_found" -ne 1 ]; then
        xmg_warn "未找到 Xray systemd unit，跳过自动配置"
        return 1
    fi

    xmg_info "检测到 Xray systemd unit: $xray_unit"

    # ---- 方案：使用 drop-in 覆盖文件（systemd 推荐方式）----
    # 创建优先级更高的 drop-in（20-xmg.conf > 10-donot_touch_single_conf.conf）
    # 这样即使官方脚本重新生成主 unit 和 10-*.conf，XMG 的覆盖仍然生效
    local dropin_dir="/etc/systemd/system/xray.service.d"
    local dropin_file="${dropin_dir}/20-xmg.conf"

    mkdir -p "$dropin_dir"

    # 检查 drop-in 是否已经指向 XMG 路径
    if [ -f "$dropin_file" ] && grep -q "$XMG_XRAY_CONFIG" "$dropin_file" 2>/dev/null; then
        xmg_info "drop-in 覆盖已存在且指向 XMG 统一配置路径，无需修改"
        return 0
    fi

    # 备份现有 drop-in（如果存在）
    if [ -f "$dropin_file" ]; then
        local backup_dropin="${dropin_file}.xmg-backup.$(date +%Y%m%d_%H%M%S)"
        cp "$dropin_file" "$backup_dropin" 2>/dev/null && \
            xmg_info "已备份现有 drop-in 到: $backup_dropin" || true
    fi

    # 写入 drop-in 覆盖文件
    # ExecStart=  （空值）先清空所有之前的 ExecStart
    # ExecStart=...  然后设置 XMG 的路径
    cat > "$dropin_file" <<XMGEOF
# XMG 管理的 drop-in 覆盖文件
# 此文件优先级高于官方的 10-donot_touch_single_conf.conf
# 请勿手动编辑，由 XMG 自动管理
[Service]
ExecStart=
ExecStart=/usr/local/bin/xray run -config ${XMG_XRAY_CONFIG}
XMGEOF

    # 验证 drop-in 是否写入成功
    if grep -q "$XMG_XRAY_CONFIG" "$dropin_file" 2>/dev/null; then
        xmg_info "drop-in 覆盖已创建，ExecStart 指向: $XMG_XRAY_CONFIG"
    else
        xmg_warn "drop-in 覆盖文件写入失败"
        return 1
    fi

    # 重载 systemd 配置
    systemctl daemon-reload >/dev/null 2>&1 || true

    return 0
}

# ===== 移除 XMG drop-in 覆盖（恢复官方 unit 行为）=====
xmg_xray_restore_systemd_unit() {
    local dropin_dir="/etc/systemd/system/xray.service.d"
    local dropin_file="${dropin_dir}/20-xmg.conf"

    if [ ! -f "$dropin_file" ]; then
        xmg_warn "未找到 XMG drop-in 覆盖: $dropin_file"
        return 1
    fi

    rm -f "$dropin_file" && xmg_info "已移除 XMG drop-in 覆盖: $dropin_file"
    rmdir "$dropin_dir" 2>/dev/null || true

    systemctl daemon-reload >/dev/null 2>&1 || true
    xmg_info "Xray 已恢复官方 systemd unit 配置（重启服务后生效）"
}

# ===== 安装 / 更新 =====
# 内核安装/更新委托给 core.sh（按 state 记录的通道装 stable/preview/pinned），
# 本函数只负责 drop-in 覆盖与开机自启等 systemd 侧收尾。
xmg_xray_install_update() {
    xmg_require_root
    xmg_mkdirs
    mkdir -p "$XMG_XRAY_LOG_DIR"

    if ! xmg_core_install; then
        xmg_error "Xray 内核安装失败"
        return 1
    fi

    xmg_xray_patch_systemd_unit

    if xmg_xray_is_systemd_available; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable "$XMG_XRAY_SERVICE" >/dev/null 2>&1 && \
            xmg_info "Xray 已设置为开机自启" || xmg_warn "设置开机自启失败"
    fi
    return 0
}

# ===== 卸载 =====

xmg_xray_uninstall() {
    xmg_require_root

    if ! xmg_xray_binary_exists; then
        xmg_warn "未检测到 Xray 命令，可能尚未安装"
    fi

    xmg_warn "即将卸载 Xray"
    xmg_warn "XMG 管理的 Xray 配置目录: $XMG_XRAY_DIR"

    if ! xmg_confirm "确认卸载 Xray?"; then
        xmg_info "已取消"
        return 0
    fi

    # 停止服务
    if xmg_xray_is_systemd_available; then
        systemctl stop "$XMG_XRAY_SERVICE" >/dev/null 2>&1 || true
        systemctl disable "$XMG_XRAY_SERVICE" >/dev/null 2>&1 || true
    fi

    # 使用官方卸载脚本
    xmg_info "使用 Xray 官方卸载脚本..."
    if xmg_cmd_exists curl; then
        bash <(curl -fsSL "$XMG_XRAY_INSTALL_URL") remove 2>/dev/null || xmg_warn "官方卸载脚本执行失败"
    elif xmg_cmd_exists wget; then
        bash <(wget -qO- "$XMG_XRAY_INSTALL_URL") remove 2>/dev/null || xmg_warn "官方卸载脚本执行失败"
    else
        xmg_warn "没有可用的下载工具，跳过官方卸载脚本"
    fi

    # 删除 XMG 管理的 Xray 配置目录
    if [ -d "$XMG_XRAY_DIR" ]; then
        xmg_info "删除 XMG 管理的 Xray 配置目录: $XMG_XRAY_DIR"
        rm -rf "$XMG_XRAY_DIR" && xmg_info "已删除: $XMG_XRAY_DIR" || xmg_warn "删除 $XMG_XRAY_DIR 失败"
    fi

    # 删除 XMG 管理的 Xray 日志目录
    if [ -d "$XMG_XRAY_LOG_DIR" ]; then
        xmg_info "删除 XMG 管理的 Xray 日志目录: $XMG_XRAY_LOG_DIR"
        rm -rf "$XMG_XRAY_LOG_DIR" && xmg_info "已删除: $XMG_XRAY_LOG_DIR" || xmg_warn "删除 $XMG_XRAY_LOG_DIR 失败"
    fi

    # 清理 systemd unit 残留
    if xmg_xray_is_systemd_available; then
        for path in "/etc/systemd/system/xray.service" "/lib/systemd/system/xray.service" "/usr/lib/systemd/system/xray.service"; do
            if [ -f "$path" ]; then
                rm -f "$path" && xmg_info "已删除 systemd unit: $path"
            fi
        done

        # 清理 XMG drop-in 覆盖目录
        if [ -d "/etc/systemd/system/xray.service.d" ]; then
            rm -rf "/etc/systemd/system/xray.service.d" \
                && xmg_info "已删除 drop-in 覆盖目录: /etc/systemd/system/xray.service.d"
        fi

        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    xmg_info "Xray 卸载流程完成"
}

# ===== 配置管理 =====

xmg_xray_validate_config() {
    local xray_bin=""

    xray_bin="$(xmg_xray_get_bin)" || {
        xmg_error "xray 命令不存在，无法校验配置"
        return 1
    }

    if [ -f "$XMG_XRAY_CONFIG" ]; then
        "$xray_bin" run -test -c "$XMG_XRAY_CONFIG" || return 1
    else
        xmg_error "未找到 Xray 配置: $XMG_XRAY_CONFIG"
        return 1
    fi
}

xmg_xray_show_config() {
    if [ -f "$XMG_XRAY_CONFIG" ]; then
        echo "Xray 配置路径: $XMG_XRAY_CONFIG"
        echo
        cat "$XMG_XRAY_CONFIG"
    else
        xmg_warn "未找到 Xray 配置: $XMG_XRAY_CONFIG"
    fi
}

# ===== 服务生命周期 =====

xmg_xray_start() {
    xmg_require_root
    xmg_systemctl start "$XMG_XRAY_SERVICE"
    xmg_info "Xray 已启动"
}

xmg_xray_stop() {
    xmg_require_root
    xmg_systemctl stop "$XMG_XRAY_SERVICE"
    xmg_info "Xray 已停止"
}

xmg_xray_restart() {
    xmg_require_root
    xmg_systemctl restart "$XMG_XRAY_SERVICE"
    xmg_info "Xray 已重启"
}

xmg_xray_reload() {
    xmg_require_root
    xmg_systemctl reload "$XMG_XRAY_SERVICE"
    xmg_info "Xray 已重载"
}

xmg_xray_status() {
    if ! xmg_xray_is_systemd_available; then
        xmg_warn "systemctl 不存在，无法查看 Xray 状态"
        return 1
    fi
    systemctl status "$XMG_XRAY_SERVICE" --no-pager || true
}

# ===== 诊断 =====

xmg_xray_diag() {
    echo "========== Xray 安装诊断 =========="

    echo
    echo "[系统信息]"
    if [ -f /etc/os-release ]; then
        cat /etc/os-release
    else
        uname -a
    fi

    echo
    echo "[当前用户]"
    echo "uid=$(id -u), user=$(id -un 2>/dev/null || echo unknown)"

    echo
    echo "[XMG 统一目录]"
    echo "XMG_HOME=$XMG_HOME"
    echo "XMG_XRAY_DIR=$XMG_XRAY_DIR"
    echo "XMG_XRAY_CONFIG=$XMG_XRAY_CONFIG"
    echo "XMG_XRAY_LOG_DIR=$XMG_XRAY_LOG_DIR"

    echo
    echo "[命令检测]"
    for cmd in xray curl wget systemctl; do
        if xmg_cmd_exists "$cmd"; then
            echo "$cmd: $(command -v "$cmd")"
        else
            echo "$cmd: 未检测到"
        fi
    done

    echo
    echo "[Xray 版本]"
    if xmg_xray_binary_exists; then
        xmg_xray_print_version || echo "无法获取 xray version"
    else
        echo "xray 未安装"
    fi

    echo
    echo "[XMG 管理的 Xray 配置]"
    if [ -f "$XMG_XRAY_CONFIG" ]; then
        echo "存在: $XMG_XRAY_CONFIG"
        wc -l "$XMG_XRAY_CONFIG" 2>/dev/null || true
    else
        echo "不存在: $XMG_XRAY_CONFIG"
    fi

    echo
    echo "[系统 Xray 配置]"
    if [ -f /usr/local/etc/xray/config.json ]; then
        echo "存在: /usr/local/etc/xray/config.json"
        wc -l /usr/local/etc/xray/config.json 2>/dev/null || true
    else
        echo "不存在: /usr/local/etc/xray/config.json"
    fi

    echo
    echo "[XMG 统一日志目录]"
    if [ -d "$XMG_XRAY_LOG_DIR" ]; then
        ls -la "$XMG_XRAY_LOG_DIR"
    else
        echo "不存在: $XMG_XRAY_LOG_DIR"
    fi

    echo
    echo "[systemd unit 路径检测]"
    local unit_found=0
    for path in "/etc/systemd/system/xray.service" "/lib/systemd/system/xray.service" "/usr/lib/systemd/system/xray.service"; do
        if [ -f "$path" ]; then
            echo "存在: $path"
            echo "  ExecStart: $(grep 'ExecStart=' "$path" | head -1)"
            unit_found=1
        fi
    done
    [ "$unit_found" -eq 0 ] && echo "未找到 systemd unit"

    echo
    echo "[systemd 服务状态]"
    if xmg_xray_is_systemd_available; then
        systemctl status "$XMG_XRAY_SERVICE" --no-pager || true
    else
        echo "systemctl 不存在"
    fi

    echo
    echo "[最近日志]"
    if xmg_xray_is_systemd_available; then
        journalctl -u "$XMG_XRAY_SERVICE" -n 50 --no-pager 2>/dev/null || true
    fi
}

# ===== 菜单 =====

xmg_xray_menu() {
    local choice=""

    while true; do
        clear
        echo "========== Xray 管理 =========="
        echo "1. 安装/更新 Xray"
        echo "2. 卸载 Xray"
        echo "3. 启动 Xray"
        echo "4. 停止 Xray"
        echo "5. 重启 Xray"
        echo "6. 重载 Xray"
        echo "7. 查看 Xray 状态"
        echo "8. 校验 Xray 配置"
        echo "9. 查看 Xray 配置"
        echo "10. 安装诊断"
        echo "11. 移除 XMG 覆盖（恢复官方配置）"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - XMG 管理 Xray 的安装与服务生命周期"
        echo "  - 代理方案配置由 proxy.sh 生成（state.sh + render.sh）"
        echo "  - 配置路径: $XMG_XRAY_CONFIG"
        echo "  - 日志目录: $XMG_XRAY_LOG_DIR"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_xray_install_update
                xmg_pause
                ;;
            2)
                xmg_xray_uninstall
                xmg_pause
                ;;
            3)
                xmg_xray_start
                xmg_pause
                ;;
            4)
                xmg_xray_stop
                xmg_pause
                ;;
            5)
                xmg_xray_restart
                xmg_pause
                ;;
            6)
                xmg_xray_reload
                xmg_pause
                ;;
            7)
                xmg_xray_status
                xmg_pause
                ;;
            8)
                xmg_xray_validate_config
                xmg_pause
                ;;
            9)
                xmg_xray_show_config
                xmg_pause
                ;;
            10)
                xmg_xray_diag
                xmg_pause
                ;;
            11)
                xmg_xray_restore_systemd_unit
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

# ===== 依赖：内核安装能力委托给 core.sh =====
# core.sh 的 xmg_core_install 会读取 state.sh 记录的通道/锁定版本，故一并按需加载。
# 用模块自身所在目录解析同级模块，避免依赖可能被外部改写的 XMG_LIB_DIR。
_XMG_XRAY_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F xmg_state_get >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_XMG_XRAY_LIBDIR/state.sh"
fi
if ! declare -F xmg_core_install >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_XMG_XRAY_LIBDIR/core.sh"
fi
unset _XMG_XRAY_LIBDIR

# ===== 直接执行支持 =====
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    xmg_xray_menu
fi
