#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# xray.sh - Xray 安装与服务生命周期管理
#
# 说明：
#   - 使用 Xray 官方安装脚本安装 Xray 核心
#   - 所有 XMG 管理的 Xray 配置集中放在 /opt/xmg/xray 下
#   - 安装后自动修改 systemd unit，使 ExecStart 指向 /opt/xmg/xray/config.json
#   - 支持安装、卸载、启动、停止、重启、重载和状态查看
#   - XMG 不创建、不编辑、不修改 Xray 配置模板
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

# ===== 兼容函数 =====

if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info()  { printf '[INFO] %s\n' "$*"; }
fi
if ! declare -F xmg_warn >/dev/null 2>&1; then
    xmg_warn()  { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_die >/dev/null 2>&1; then
    xmg_die()   { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fi
if ! declare -F xmg_error >/dev/null 2>&1; then
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_cmd_exists >/dev/null 2>&1; then
    xmg_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
fi
if ! declare -F xmg_require_root >/dev/null 2>&1; then
    xmg_require_root() {
        if [ "$(id -u)" -ne 0 ]; then
            xmg_die "请使用 root 用户运行，或使用 sudo 执行"
        fi
    }
fi
if ! declare -F xmg_confirm >/dev/null 2>&1; then
    xmg_confirm() {
        local prompt="${1:-确认继续?}"
        local answer=""
        printf '%s [y/N]: ' "$prompt"
        read -r answer || return 1
        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            *) return 1 ;;
        esac
    }
fi
if ! declare -F xmg_pause >/dev/null 2>&1; then
    xmg_pause() {
        printf '\n按回车键继续...'
        read -r _ || true
    }
fi
if ! declare -F xmg_systemctl >/dev/null 2>&1; then
    xmg_systemctl() {
        local action="${1:-}"
        local service="${2:-}"
        if [ -z "$action" ] || [ -z "$service" ]; then
            xmg_die "xmg_systemctl 参数错误"
        fi
        if ! xmg_cmd_exists systemctl; then
            xmg_die "systemctl 不存在，当前系统可能不是 systemd 环境"
        fi
        systemctl "$action" "$service" || xmg_die "执行 systemctl ${action} ${service} 失败"
    }
fi
if ! declare -F xmg_mkdirs >/dev/null 2>&1; then
    xmg_mkdirs() {
        mkdir -p \
            "$XMG_BIN_DIR" \
            "$XMG_LIB_DIR" \
            "$XMG_ETC_DIR" \
            "$XMG_RUN_DIR" \
            "$XMG_LOG_DIR" \
            "$XMG_BACKUP_DIR" \
            "$XMG_WWW_DIR" \
            "$XMG_CADDY_DIR" \
            "$XMG_XRAY_DIR"
    }
fi

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

# ===== 使用官方脚本安装 Xray =====

xmg_xray_install_by_official_script() {
    xmg_require_root

    xmg_info "使用 Xray 官方安装脚本安装 Xray..."
    xmg_warn "Xray 官方脚本会将 xray 二进制安装到 /usr/local/bin/xray"
    xmg_warn "XMG 会将 Xray 配置目录统一管理到: $XMG_XRAY_DIR"

    # 确保 XMG 统一目录结构存在
    xmg_mkdirs

    # 检查是否有 curl 或 wget
    if ! xmg_cmd_exists curl && ! xmg_cmd_exists wget; then
        xmg_die "缺少 curl 或 wget，无法下载 Xray 安装脚本"
    fi

    # 下载并执行 Xray 官方安装脚本，同时记录日志
    local install_log
    install_log="$(mktemp)" || xmg_die "创建临时文件失败"

    xmg_info "下载 Xray 官方安装脚本..."

    if xmg_cmd_exists curl; then
        bash <(curl -fsSL "$XMG_XRAY_INSTALL_URL") 2>&1 | tee "$install_log" || {
            xmg_warn "Xray 官方安装脚本执行失败，请检查网络或手动安装"
            rm -f "$install_log"
            return 1
        }
    elif xmg_cmd_exists wget; then
        bash <(wget -qO- "$XMG_XRAY_INSTALL_URL") 2>&1 | tee "$install_log" || {
            xmg_warn "Xray 官方安装脚本执行失败，请检查网络或手动安装"
            rm -f "$install_log"
            return 1
        }
    fi

    # 安装完成后，将 Xray 配置复制到 XMG 统一配置目录
    if [ -f /usr/local/etc/xray/config.json ]; then
        xmg_info "将 Xray 配置复制到 XMG 统一配置目录..."
        mkdir -p "$XMG_XRAY_DIR"
        cp /usr/local/etc/xray/config.json "$XMG_XRAY_CONFIG" 2>/dev/null || xmg_warn "复制 config.json 失败"
        xmg_info "配置已复制到: $XMG_XRAY_CONFIG"
    else
        xmg_warn "未找到 /usr/local/etc/xray/config.json"
        xmg_warn "XMG 不会自动生成配置，请手动创建: $XMG_XRAY_CONFIG"
    fi

    rm -f "$install_log"

    # 确认安装成功
    if xmg_xray_binary_exists; then
        xmg_info "Xray 安装成功"
        xmg_xray_print_version || true
        return 0
    else
        xmg_error "Xray 安装失败，未检测到 xray 命令"
        return 1
    fi
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
        cp "$dropin_file" "$backup_unit" 2>/dev/null && \
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

# ===== 恢复 systemd unit 备份 =====
xmg_xray_restore_systemd_unit() {
    local xray_unit=""

    for path in "/etc/systemd/system/xray.service" "/lib/systemd/system/xray.service" "/usr/lib/systemd/system/xray.service"; do
        if [ -f "$path" ]; then
            xray_unit="$path"
            break
        fi
    done

    if [ -z "$xray_unit" ]; then
        xmg_warn "未找到 Xray systemd unit"
        return 1
    fi

    local backup_file=""
    # 查找最近的备份
    backup_file=$(ls -t "${xray_unit}.xmg-backup."* 2>/dev/null | head -1)

    if [ -z "$backup_file" ]; then
        xmg_warn "未找到 systemd unit 的备份文件"
        return 1
    fi

    cp "$backup_file" "$xray_unit" && xmg_info "已恢复 systemd unit 备份: $backup_file"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

# ===== 安装 / 更新 =====

xmg_xray_install_update() {
    xmg_require_root
    xmg_info "安装/更新 Xray"

    # 确保 XMG 统一目录结构存在
    xmg_mkdirs

    # 使用官方脚本安装
    if xmg_xray_install_by_official_script; then
        xmg_info "Xray 安装/更新完成"
    else
        xmg_die "Xray 安装失败"
    fi

    # 创建 Xray 日志目录
    mkdir -p "$XMG_XRAY_LOG_DIR"

    # 如果存在 xray 用户，设置目录归属
    if id xray >/dev/null 2>&1; then
        chown -R xray:xray "$XMG_XRAY_LOG_DIR" 2>/dev/null || true
        chown -R xray:xray "$XMG_XRAY_DIR" 2>/dev/null || true
    fi

    # 自动修改 systemd unit 的 ExecStart，指向 XMG 统一配置路径
    xmg_xray_patch_systemd_unit

    # 启动服务
    if xmg_xray_is_systemd_available; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable "$XMG_XRAY_SERVICE" >/dev/null 2>&1 && xmg_info "Xray 已设置为开机自启" || xmg_warn "设置 Xray 开机自启失败"
        systemctl start "$XMG_XRAY_SERVICE" >/dev/null 2>&1 && xmg_info "Xray 已启动" || xmg_warn "Xray 启动失败，请检查配置"
    fi

    xmg_info "Xray 安装/更新完成"
    xmg_info "配置路径: $XMG_XRAY_CONFIG"
    xmg_info "日志目录: $XMG_XRAY_LOG_DIR"
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
        echo "11. 恢复 systemd unit 备份"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - XMG 管理 Xray 的安装与服务生命周期"
        echo "  - XMG 不创建、不编辑、不修改 Xray 配置模板"
        echo "  - Xray 配置由用户自行维护"
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

# ===== 直接执行支持 =====
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    xmg_xray_menu
fi
