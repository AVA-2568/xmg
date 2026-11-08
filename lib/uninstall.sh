#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# uninstall.sh - XMG 卸载模块
#
# XMG_MENU_LABEL: 系统卸载清理
#
# 说明：
#   - 严格限定清理范围为 XMG 自治资源
#   - 绝不触碰操作系统包管理器的原生 unit (/lib/systemd/system/xray.service 等)
#   - 绝不触碰系统已安装的 Xray 官方二进制
#   - 具备严格的危险路径阻断机制
#

# ===== 安全加载 =====
if [ "${XMG_UNINSTALL_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_UNINSTALL_SH_LOADED=1

# 依赖 os.sh（发行版 / init / 包管理器抽象）
if ! declare -F xmg_svc_supported >/dev/null 2>&1; then
    for _xmg_os_f in "${XMG_LIB_DIR:-/opt/xmg/lib}/os.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/os.sh"; do
        if [ -r "$_xmg_os_f" ]; then
            # shellcheck source=/dev/null
            source "$_xmg_os_f"
            break
        fi
    done
    unset _xmg_os_f
fi

# ===== 默认配置 =====
XMG_UNINSTALL_KEEP_BACKUPS="${XMG_UNINSTALL_KEEP_BACKUPS:-0}"

# ===== 依赖 common.sh 的路径变量 =====
XMG_BIN="${XMG_BIN:-${XMG_HOME:-/opt/xmg}/bin/xmg}"
XMG_LINK="${XMG_LINK:-/usr/local/bin/xmg}"
XMG_XRAY_SERVICE="${XMG_XRAY_SERVICE:-xray}"

# ===== 危险路径检测与拦截 =====
# 仅做字符串比较挡不住 /opt/..、/tmp/../ 这类写法：
# 尾斜杠能去掉，但 ".." 原样留在路径里，rm -rf 会按内核语义作用到上级目录。
# 所以必须先规范化，再比对；解析不出真实目录时宁可拒绝。
xmg_uninstall_check_safe_home() {
    local target
    if [ "$#" -gt 0 ]; then
        target="$1"
    else
        target="${XMG_HOME:-}"
    fi

    if [ -z "$target" ]; then
        xmg_error "卸载安全拦截: XMG_HOME 为空"
        return 1
    fi

    local norm="$target"
    local real=""

    # readlink -f 会消掉 ".." 与软链接；只有解析出真实存在的目录才采信
    if real="$(readlink -f -- "$norm" 2>/dev/null)" && [ -n "$real" ] && [ -d "$real" ]; then
        norm="$real"
    else
        # 无法规范化时，含 ".." 的路径一律拒绝（宁可误杀，不可误删）
        case "/$norm/" in
            */../*)
                xmg_error "卸载安全拦截: 路径含 '..' 且无法规范化: '$target'"
                return 1
                ;;
        esac
    fi

    while [ "${norm: -1}" = "/" ] && [ "$norm" != "/" ]; do
        norm="${norm%/}"
    done

    if [ "$norm" = "/" ]; then
        xmg_error "卸载安全拦截: 禁止对根目录 '/' 执行卸载"
        return 1
    fi

    if [ "${#norm}" -le 3 ]; then
        xmg_error "卸载安全拦截: 路径过短 (${#norm} 字符): '$target'"
        return 1
    fi

    case "$norm" in
        /bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            xmg_error "卸载安全拦截: 严格禁止卸载系统目录: '$norm'"
            return 1
            ;;
    esac

    # 注意：目录特征校验不能放在这里 —— 卸载过程中 bin/lib 会被逐步清理，
    # 中途再次调用本函数时会误判为「非 XMG 目录」。特征校验下沉到
    # xmg_uninstall_remove_xmg_home（真正 rm -rf 之前那一刻）。
    return 0
}

# ===== 进程与服务清理 =====
xmg_uninstall_kill_residues() {
    xmg_info "正在清理残留后台进程..."
    if command -v pkill &>/dev/null; then
        pkill -f "wireproxy" 2>/dev/null || true
    fi
}

xmg_uninstall_stop_services() {
    xmg_info "停止 XMG 托管的服务..."

    if xmg_svc_supported; then
        if xmg_svc_is_active xmg-warp; then
            xmg_svc_stop xmg-warp >/dev/null 2>&1 || true
        fi
        xmg_svc_disable xmg-warp >/dev/null 2>&1 || true

        if xmg_svc_is_active "$XMG_XRAY_SERVICE"; then
            xmg_info "正在停止 Xray 服务..."
            xmg_svc_stop "$XMG_XRAY_SERVICE" 2>/dev/null || true
        fi

        if xmg_svc_is_active xmg-firewall; then
            xmg_svc_stop xmg-firewall >/dev/null 2>&1 || true
            xmg_svc_disable xmg-firewall >/dev/null 2>&1 || true
        fi
    fi

    xmg_uninstall_kill_residues
    xmg_info "服务已停止"
}

# ===== 文件与目录清理 =====
xmg_uninstall_remove_command_link() {
    local link="${XMG_LINK:-/usr/local/bin/xmg}"
    if [ -L "$link" ] || [ -e "$link" ]; then
        rm -f "$link" && xmg_info "已删除命令入口: $link" || xmg_warn "删除命令入口失败: $link"
    else
        xmg_info "命令入口不存在，跳过: $link"
    fi
}

xmg_uninstall_remove_xmg_home() {
    xmg_uninstall_check_safe_home "${XMG_HOME:-}" || return 1
    if [ -d "$XMG_HOME" ]; then
        # 最后一道保险：目录必须带 XMG 特征，避免 XMG_HOME 被误设/注入后删掉别人的数据
        if [ ! -d "$XMG_HOME/lib" ] && [ ! -x "$XMG_HOME/bin/xmg" ] && [ ! -f "$XMG_HOME/xmg.files" ]; then
            xmg_error "拒绝删除: $XMG_HOME 不像 XMG 安装目录（缺少 lib/ 与 bin/xmg）"
            return 1
        fi
        xmg_info "正在删除 XMG 统一目录: $XMG_HOME"
        rm -rf "$XMG_HOME" && xmg_info "已删除: $XMG_HOME" || xmg_warn "删除 $XMG_HOME 失败"
    else
        xmg_info "$XMG_HOME 不存在，跳过"
    fi
}

xmg_uninstall_cleanup_systemd_artifacts() {
    local sys_dir="${XMG_SYSTEMD_DIR:-/etc/systemd/system}"
    local dropin_dir="${sys_dir}/xray.service.d"

    # 1. 仅清理 XMG 自身的 drop-in 覆盖文件
    for f in "${dropin_dir}/xmg.conf" "${dropin_dir}/20-xmg.conf"; do
        if [ -f "$f" ]; then
            rm -f "$f" 2>/dev/null && xmg_info "已清理 drop-in 覆盖: $f" || true
        fi
    done

    if [ -d "$dropin_dir" ]; then
        rmdir "$dropin_dir" 2>/dev/null || true
    fi

    # 2. 清理 xmg-warp.service 及其自启链接
    local warp_svc="${sys_dir}/xmg-warp.service"
    local warp_wants="${sys_dir}/multi-user.target.wants/xmg-warp.service"
    if [ -L "$warp_wants" ] || [ -e "$warp_wants" ]; then
        rm -f "$warp_wants" 2>/dev/null && xmg_info "已清理 xmg-warp 自启软链接" || true
    fi
    if [ -f "$warp_svc" ] || [ -L "$warp_svc" ]; then
        rm -f "$warp_svc" 2>/dev/null && xmg_info "已清理 xmg-warp 服务单元" || true
    fi

    # 3. 触发 systemd 重新加载配置
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

# OpenRC（Alpine）服务脚本清理：仅删除 XMG 生成的那几个
# 清理 XMG 落在系统目录里的调优产物
# 这些文件不在 /opt/xmg 下，如果不主动清理，卸载后会留下：
#   - 残留的内核参数与 limits（静默改变系统行为）
#   - unbound 接管 127.0.0.1 但解析器已被删（DNS 直接不可用）
xmg_uninstall_cleanup_tune_artifacts() {
    local f=""
    local files=(
        "${XMG_TUNE_SYSCTL_NET_CONF:-/etc/sysctl.d/99-xmg-tune.conf}"
        "${XMG_TUNE_SYSCTL_BBR_CONF:-/etc/sysctl.d/99-xmg-bbr.conf}"
        "${XMG_TUNE_SYSCTL_SWAP_CONF:-/etc/sysctl.d/99-xmg-swap.conf}"
        "${XMG_TUNE_LIMITS_CONF:-/etc/security/limits.d/99-xmg-nofile.conf}"
        "${XMG_TUNE_SYSTEMD_LIMITS_CONF:-/etc/systemd/system.conf.d/99-xmg-limits.conf}"
        "${XMG_TUNE_MODULES_LOAD_CONF:-/etc/modules-load.d/xmg-bbr.conf}"
        "${XMG_TUNE_RESOLVED_CONF:-/etc/systemd/resolved.conf.d/xmg-dns.conf}"
        "${XMG_MAINT_JOURNALD_CONF:-/etc/systemd/journald.conf.d/00-xmg.conf}"
    )

    for f in "${files[@]}"; do
        if [ -f "$f" ]; then
            rm -f "$f" 2>/dev/null && xmg_info "已清理调优文件: $f" || true
        fi
    done

    # /etc/modules 里我们追加的 tcp_bbr（OpenRC 路径）
    local modules_file="${XMG_MODULES_FILE:-/etc/modules}"
    if [ -r "$modules_file" ] && grep -qx 'tcp_bbr' "$modules_file" 2>/dev/null; then
        local tmp_mod=""
        tmp_mod="$(mktemp)" || tmp_mod=""
        if [ -n "$tmp_mod" ]; then
            grep -vx 'tcp_bbr' "$modules_file" > "$tmp_mod" 2>/dev/null && cat "$tmp_mod" > "$modules_file"
            rm -f "$tmp_mod" 2>/dev/null || true
            xmg_info "已从 $modules_file 移除 tcp_bbr"
        fi
    fi

    # /etc/sysctl.conf 里的 XMG 标记块（OpenRC 持久化用）
    local main_conf="${XMG_TUNE_SYSCTL_MAIN_CONF:-/etc/sysctl.conf}"
    if [ -r "$main_conf" ] && grep -q '# >>> xmg:' "$main_conf" 2>/dev/null; then
        local tmp_main=""
        tmp_main="$(mktemp)" || tmp_main=""
        if [ -n "$tmp_main" ]; then
            awk '
                /^# >>> xmg:/ { skip = 1; next }
                /^# <<< xmg:/ { skip = 0; next }
                !skip { print }
            ' "$main_conf" > "$tmp_main" 2>/dev/null && cat "$tmp_main" > "$main_conf"
            rm -f "$tmp_main" 2>/dev/null || true
            xmg_info "已从 $main_conf 移除 XMG 标记块"
        fi
    fi

    # unbound：仅移除 XMG 生成的配置；若解析已指向 127.0.0.1，必须换回公共 DNS，
    # 否则卸载后系统没有任何可用解析器
    local unbound_conf="${XMG_TUNE_UNBOUND_CONF:-/etc/unbound/unbound.conf}"
    local resolv_file="${XMG_RESOLV_CONF_FILE:-/etc/resolv.conf}"
    if [ -f "$unbound_conf" ] && grep -q "由 xmg tune 生成" "$unbound_conf" 2>/dev/null; then
        rm -f "$unbound_conf" 2>/dev/null || true
        xmg_info "已移除 XMG 生成的 unbound 配置"
        if [ -f "$resolv_file" ] && grep -q '^nameserver 127.0.0.1' "$resolv_file" 2>/dev/null; then
            cat > "$resolv_file" <<EOF
# XMG 卸载后恢复默认 DNS（unbound 已移除）
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2
EOF
            chmod 644 "$resolv_file" 2>/dev/null || true
            xmg_warn "unbound 已移除，$resolv_file 已恢复为 1.1.1.1 / 8.8.8.8，请按需调整"
        fi
    fi

    # swap 属于用户数据，不自动删除，只提示
    if [ -f "${XMG_TUNE_SWAPFILE:-/swapfile}" ]; then
        xmg_warn "检测到 swap 文件 ${XMG_TUNE_SWAPFILE:-/swapfile}，已保留未删除（如需回收请手动 swapoff + 删除并清理 /etc/fstab）"
    fi
    return 0
}

# 清理 XMG iptables 残留链
# 卸载后若仍把带 DROP 的 XMG-IN 链挂在 INPUT 上，会留下看不见的防火墙规则，
# 所以这里不依赖 xmg-firewall 服务是否在运行，直接摘链并销毁。
xmg_uninstall_cleanup_iptables() {
    local fam="" bin=""
    local cleaned=0

    for fam in 4 6; do
        if [ "$fam" = "6" ]; then
            bin="ip6tables"
        else
            bin="iptables"
        fi
        command -v "$bin" >/dev/null 2>&1 || continue

        # 链存在才清理，避免无谓的报错与误导性提示
        if "$bin" -S XMG-IN >/dev/null 2>&1; then
            cleaned=1
        fi

        "$bin" -D INPUT -j XMG-IN 2>/dev/null || true
        "$bin" -F XMG-IN 2>/dev/null || true
        "$bin" -X XMG-IN 2>/dev/null || true
    done

    [ "$cleaned" -eq 1 ] && xmg_info "已清理 iptables 残留链 XMG-IN"
    return 0
}

xmg_uninstall_cleanup_openrc_artifacts() {
    local initd="${XMG_INITD_DIR:-/etc/init.d}"
    local f=""

    for f in "$initd/xmg-firewall" "$initd/xmg-warp"; do
        if [ -e "$f" ]; then
            rm -f "$f" 2>/dev/null && xmg_info "已清理 OpenRC 服务脚本: $f" || true
        fi
    done

    # xray 的 init 脚本仅在确认为 XMG 生成时才删除（含 XMG 标记）
    if [ -f "$initd/xray" ] && grep -q "XMG 管理的 Xray OpenRC 服务脚本" "$initd/xray" 2>/dev/null; then
        xmg_svc_disable xray >/dev/null 2>&1 || true
        rm -f "$initd/xray" 2>/dev/null && xmg_info "已清理 OpenRC 服务脚本: $initd/xray" || true
    fi

    rm -f /run/xray.pid 2>/dev/null || true
}

# ===== CLI 入口与卸载主流程 =====
xmg_uninstall_cli() {
    local auto_yes=0
    local arg=""

    for arg in "$@"; do
        case "$arg" in
            --yes|-y)
                auto_yes=1
                ;;
        esac
    done

    # 危险路径预检阻断
    if ! xmg_uninstall_check_safe_home "${XMG_HOME:-}"; then
        return 1
    fi

    if [ "$auto_yes" -ne 1 ]; then
        if declare -F xmg_confirm >/dev/null 2>&1; then
            if ! xmg_confirm "确认卸载 XMG？此操作不可撤销"; then
                xmg_info "已取消卸载"
                return 0
            fi
        else
            printf "确认卸载 XMG？(y/N): "
            read -r ans || return 0
            case "$ans" in
                [yY]|[yY][eE][sS]) ;;
                *) xmg_info "已取消卸载"; return 0 ;;
            esac
        fi
    fi

    # 1. 停止服务并清理残留
    xmg_uninstall_stop_services

    # 2. 清理命令入口软链接
    xmg_uninstall_remove_command_link

    # 3. 清理 XMG 自治主目录
    if [ "$XMG_UNINSTALL_KEEP_BACKUPS" = "1" ] && [ -n "${XMG_BACKUP_DIR:-}" ] && [ -d "$XMG_BACKUP_DIR" ]; then
        xmg_info "保留备份目录: $XMG_BACKUP_DIR"
        for dir in "${XMG_BIN_DIR:-}" "${XMG_LIB_DIR:-}" "${XMG_ETC_DIR:-}" "${XMG_RUN_DIR:-}" "${XMG_LOG_DIR:-}" "${XMG_XRAY_DIR:-}"; do
            if [ -n "$dir" ] && [ -d "$dir" ]; then
                rm -rf "$dir" 2>/dev/null || true
            fi
        done
    else
        xmg_uninstall_remove_xmg_home
    fi

    # 4. 清理 drop-in 与 warp 专属服务单元
    xmg_uninstall_cleanup_systemd_artifacts

    # 5. 清理 OpenRC（Alpine）侧由 XMG 生成的服务脚本与 iptables 残留链
    xmg_uninstall_cleanup_openrc_artifacts
    xmg_uninstall_cleanup_iptables

    # 6. 清理落在系统目录的调优产物（sysctl / limits / resolved / journald / unbound）
    xmg_uninstall_cleanup_tune_artifacts

    xmg_info "XMG 卸载完成"
    return 0
}

xmg_uninstall_run() {
    xmg_uninstall_cli "$@"
}

# ===== 卸载菜单 =====
xmg_uninstall_menu() {
    local choice=""

    while true; do
        clear
        echo "========== XMG 卸载管理 =========="
        echo "1. 执行标准卸载"
        echo "2. 执行卸载（保留备份）"
        echo "0. 返回"
        echo
        echo "当前目录:"
        echo "  XMG_HOME: $XMG_HOME"
        echo "  命令入口: $XMG_LINK"
        echo
        echo "安全说明:"
        echo "  - 仅清理 XMG 自治目录与自身生成的 drop-in / warp unit"
        echo "  - 绝对不删除操作系统原生 unit 与系统已安装的 Xray 二进制"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                XMG_UNINSTALL_KEEP_BACKUPS=0
                xmg_uninstall_run
                xmg_pause
                ;;
            2)
                XMG_UNINSTALL_KEEP_BACKUPS=1
                xmg_uninstall_run
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
    xmg_uninstall_menu
fi
