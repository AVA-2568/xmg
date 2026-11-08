#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# xray.sh - Xray 服务生命周期管理
#
# XMG_MENU_LABEL: Xray 服务管理
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

# OpenRC（Alpine）服务脚本路径
XMG_INITD_DIR="${XMG_INITD_DIR:-/etc/init.d}"
XMG_XRAY_OPENRC_SCRIPT="${XMG_XRAY_OPENRC_SCRIPT:-$XMG_INITD_DIR/xray}"

# 依赖 os.sh（发行版 / init 抽象）。独立加载本模块时自动补齐。
if [ "${XMG_OS_SH_LOADED:-0}" != "1" ]; then
    _XMG_XRAY_OSDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for _xmg_xray_os in "$_XMG_XRAY_OSDIR/os.sh" "${XMG_LIB_DIR:-/opt/xmg/lib}/os.sh"; do
        if [ -r "$_xmg_xray_os" ]; then
            # shellcheck source=/dev/null
            source "$_xmg_xray_os"
            break
        fi
    done
    unset _XMG_XRAY_OSDIR _xmg_xray_os
fi

# 依赖 detect.sh（机型真源：内存/CPU 配额）。独立加载本模块时自动补齐。
if [ "${XMG_DETECT_SH_LOADED:-0}" != "1" ]; then
    _XMG_XRAY_DETDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for _xmg_xray_det in "$_XMG_XRAY_DETDIR/detect.sh" "${XMG_LIB_DIR:-/opt/xmg/lib}/detect.sh"; do
        if [ -r "$_xmg_xray_det" ]; then
            # shellcheck source=/dev/null
            source "$_xmg_xray_det"
            break
        fi
    done
    unset _XMG_XRAY_DETDIR _xmg_xray_det
fi

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
    # override / 显式路径优先：doctor、selftest 等只读模块都走这里，
    # 若排在 PATH 之后，自定义安装路径与测试桩都会被判定为「内核未安装」
    if [ -n "${XMG_XRAY_BIN_OVERRIDE:-}" ] && [ -x "$XMG_XRAY_BIN_OVERRIDE" ]; then
        printf '%s\n' "$XMG_XRAY_BIN_OVERRIDE"
        return 0
    fi
    if [ -n "${XMG_XRAY_BIN:-}" ] && [ -x "$XMG_XRAY_BIN" ]; then
        printf '%s\n' "$XMG_XRAY_BIN"
        return 0
    fi
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

# 当前 init 后端：systemd | openrc | sysvinit | none
xmg_xray_init_backend() {
    xmg_os_detect
    printf '%s\n' "$XMG_INIT_SYSTEM"
}

xmg_xray_print_version() {
    local xray_bin=""
    xray_bin="$(xmg_xray_get_bin)" || return 1
    "$xray_bin" version 2>/dev/null | head -1 || true
}

# ===== Go 运行时机型参数 =====
# 内存与 CPU 一律取 detect.sh 统一真源：容器内 /proc/meminfo 是宿主值，
# 必须以 cgroup 限额收敛，否则 512MB 容器会被判成宿主机大内存档位。
_xmg_xray_mem_total_mb() {
    local mb=0
    if declare -F xmg_detect_mem_total_mb >/dev/null 2>&1; then
        mb="$(xmg_detect_mem_total_mb 2>/dev/null || printf 0)"
    fi
    case "$mb" in ''|*[!0-9]*) mb=0 ;; esac
    printf '%s\n' "$mb"
}

# 并发度：<=512MB 机型收敛为 1（协程栈膨胀风险），其余按有效核数，上限 4
xmg_xray_gomaxprocs() {
    local mb="" cores=1
    mb="$(_xmg_xray_mem_total_mb)"
    if declare -F xmg_detect_cpu_cores >/dev/null 2>&1; then
        cores="$(xmg_detect_cpu_cores 2>/dev/null || printf 1)"
    fi
    case "$cores" in ''|*[!0-9]*) cores=1 ;; esac
    if [ "$cores" -lt 1 ]; then
        cores=1
    fi
    if [ "$mb" -eq 0 ] || [ "$mb" -le 512 ] || [ "$cores" -eq 1 ]; then
        printf '1'
        return 0
    fi
    if [ "$cores" -gt 4 ]; then
        cores=4
    fi
    printf '%s' "$cores"
}

xmg_xray_gomemlimit() {
    local mb=""
    mb="$(_xmg_xray_mem_total_mb)"
    if [ "$mb" -le 0 ]; then
        printf '100MiB'
    elif [ "$mb" -le 96 ]; then
        printf '32MiB'
    elif [ "$mb" -le 192 ]; then
        printf '48MiB'
    elif [ "$mb" -le 384 ]; then
        printf '64MiB'
    elif [ "$mb" -le 1024 ]; then
        printf '100MiB'
    else
        printf '150MiB'
    fi
}

# 服务级 fd 上限：与 tune 模块共用 os.sh 的分档规则
xmg_xray_nofile() {
    local mb=""
    mb="$(_xmg_xray_mem_total_mb)"
    if [ "$mb" -le 0 ]; then
        mb=512
    fi
    if declare -F xmg_nofile_for_mem_mb >/dev/null 2>&1; then
        xmg_nofile_for_mem_mb "$mb"
    else
        printf '1048576'
    fi
}

# 返回空串表示不注入（Go 默认 GOGC=100）：低内存档才需要更激进的回收
xmg_xray_gogc() {
    local mb=""
    mb="$(_xmg_xray_mem_total_mb)"
    if [ "$mb" -gt 0 ] && [ "$mb" -le 192 ]; then
        printf '40'
    elif [ "$mb" -gt 0 ] && [ "$mb" -le 384 ]; then
        printf '60'
    fi
}

# ===== 生成 drop-in 覆盖内容 =====
xmg_xray_generate_dropin_content() {
    local cfg="${1:-${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}}"
    local xray_bin=""
    if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
        xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"
    elif command -v xray >/dev/null 2>&1; then
        xray_bin="$(command -v xray)"
    elif [ -x /usr/local/bin/xray ]; then
        xray_bin="/usr/local/bin/xray"
    elif [ -x /usr/bin/xray ]; then
        xray_bin="/usr/bin/xray"
    fi
    [ -n "$xray_bin" ] && [ -x "$xray_bin" ] || xray_bin="/usr/local/bin/xray"

    local memlimit="" gogc="" procs=""
    memlimit="$(xmg_xray_gomemlimit)"
    gogc="$(xmg_xray_gogc)"
    procs="$(xmg_xray_gomaxprocs)"

    cat <<EOF
# XMG 管理的 drop-in 覆盖文件
# 此文件优先级高于官方的 10-donot_touch_single_conf.conf
# 请勿手动编辑，由 XMG 自动管理
[Service]
User=root
Environment="GOMEMLIMIT=$memlimit"
Environment="GODEBUG=madvdontneed=1"
Environment="GOMAXPROCS=$procs"
EOF
    [ -n "$gogc" ] && printf 'Environment="GOGC=%s"\n' "$gogc"
    cat <<EOF
ExecStart=
ExecStart=$xray_bin run -config $cfg
EOF
}

# ===== OpenRC (Alpine) 服务脚本 =====
# 与 systemd drop-in 等价：同样的 GOMEMLIMIT/GODEBUG/GOMAXPROCS 内存抑制，
# 同样的 nofile 上限，同样的崩溃自动拉起。
xmg_xray_generate_openrc_content() {
    local cfg="${1:-${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}}"
    local xray_bin="${2:-}"

    [ -n "$xray_bin" ] || xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"
    [ -n "$xray_bin" ] || xray_bin="/usr/local/bin/xray"

    # 新版 OpenRC 才有 supervise-daemon；缺失时退回 start-stop-daemon 后台模式
    local supervisor_block=""
    if [ -x /sbin/supervise-daemon ] || command -v supervise-daemon >/dev/null 2>&1; then
        supervisor_block='supervisor=supervise-daemon
respawn_delay=5
respawn_max=0'
    else
        supervisor_block='command_background=true'
    fi

    cat <<'OPENRC_EOF'
#!/sbin/openrc-run
# XMG 管理的 Xray OpenRC 服务脚本
# 由 xmg 自动生成，请勿手工编辑；重新执行 xmg xray 相关操作会覆盖本文件
description="Xray Service"
OPENRC_EOF

    # Go 运行时内存抑制：与 systemd 环境下的 drop-in 保持同一套取值
    local memlimit="" gogc="" procs=""
    memlimit="$(xmg_xray_gomemlimit)"
    gogc="$(xmg_xray_gogc)"
    procs="$(xmg_xray_gomaxprocs)"
    printf 'export GOMEMLIMIT=%s\n' "$memlimit"
    printf 'export GODEBUG=madvdontneed=1\n'
    printf 'export GOMAXPROCS=%s\n' "$procs"
    [ -n "$gogc" ] && printf 'export GOGC=%s\n' "$gogc"
    printf '\n'

    printf 'command="%s"\n' "$xray_bin"
    printf 'command_args="run -config %s"\n' "$cfg"
    printf '%s\n' 'command_user="root"'
    printf '%s\n' 'pidfile="/run/xray.pid"'
    printf 'rc_ulimit="-n %s"\n' "$(xmg_xray_nofile)"
    printf '%s\n\n' "$supervisor_block"

    # 依赖写软依赖 use net：LXC/容器里 networking 服务常常没运行，
    # 硬依赖会让 OpenRC 直接拒绝启动（宿主机已配好网卡，进程本身不需要该服务）
    cat <<'OPENRC_EOF'
depend() {
    use net
    after net firewall
}
OPENRC_EOF

    # 日志目录权限（Xray 自身写 /opt/xmg/log/xray，目录必须存在且可写）
    local log_dir="${XMG_XRAY_LOG_DIR:-/opt/xmg/log/xray}"
    printf '\nstart_pre() {\n    if [ -d "%s" ]; then\n        chmod 0750 "%s" 2>/dev/null || true\n    fi\n}\n' \
        "$log_dir" "$log_dir"
}

# 安装（或覆盖）OpenRC 服务脚本并设为开机自启
xmg_xray_install_openrc_service() {
    local cfg="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
    local xray_bin=""
    xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"

    if [ -z "$xray_bin" ] && [ ! -x /usr/local/bin/xray ]; then
        xmg_warn "未找到 Xray 可执行程序，跳过 OpenRC 服务安装"
        return 1
    fi

    mkdir -p "$XMG_INITD_DIR" || return 1

    # 非 XMG 生成的同名脚本先备份，避免覆盖发行版/用户自己的服务定义
    if [ -f "$XMG_XRAY_OPENRC_SCRIPT" ] && \
       ! grep -q "XMG 管理的 Xray OpenRC 服务脚本" "$XMG_XRAY_OPENRC_SCRIPT" 2>/dev/null; then
        local bak="${XMG_XRAY_OPENRC_SCRIPT}.xmg-backup.$(date +%Y%m%d_%H%M%S)"
        cp -a "$XMG_XRAY_OPENRC_SCRIPT" "$bak" 2>/dev/null && \
            xmg_info "已备份现有 OpenRC 脚本: $bak" || true
    fi

    xmg_xray_generate_openrc_content "$cfg" "$xray_bin" > "$XMG_XRAY_OPENRC_SCRIPT" || return 1
    chmod 0755 "$XMG_XRAY_OPENRC_SCRIPT" || return 1

    xmg_info "已生成 OpenRC 服务脚本: $XMG_XRAY_OPENRC_SCRIPT"
    xmg_svc_enable "$XMG_XRAY_SERVICE" >/dev/null 2>&1 \
        && xmg_info "Xray 已加入 default 运行级（开机自启）" \
        || xmg_warn "rc-update add $XMG_XRAY_SERVICE 失败，请手动检查"
    return 0
}

# 移除 XMG 管理的 OpenRC 服务脚本
xmg_xray_remove_openrc_service() {
    if [ -f "$XMG_XRAY_OPENRC_SCRIPT" ]; then
        xmg_svc_disable "$XMG_XRAY_SERVICE" >/dev/null 2>&1 || true
        xmg_svc_stop "$XMG_XRAY_SERVICE" >/dev/null 2>&1 || true
        rm -f "$XMG_XRAY_OPENRC_SCRIPT" 2>/dev/null || true
        xmg_info "已移除 OpenRC 服务脚本: $XMG_XRAY_OPENRC_SCRIPT"
    fi
}

# ===== 服务注册统一入口 =====
# systemd -> drop-in 覆盖；OpenRC -> /etc/init.d/xray
xmg_xray_patch_systemd_unit() {
    if ! xmg_init_use_systemd_units; then
        if xmg_init_is_openrc; then
            xmg_xray_install_openrc_service
            return $?
        fi
        if xmg_init_is_sysvinit; then
            xmg_warn "检测到 SysV init 环境，XMG 仅自动生成 systemd 与 OpenRC 服务"
            xmg_warn "请手动将启动命令写入 /etc/init.d: $(xmg_xray_get_bin 2>/dev/null || echo xray) run -config ${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
            return 1
        fi
        xmg_warn "未检测到可用的服务管理器，已跳过开机自启配置"
        return 1
    fi

    _xmg_xray_patch_systemd_unit_impl
}

# ===== 自动修改 systemd unit 的 ExecStart =====
# 确保 Xray 服务启动时读取的是 XMG 统一配置路径，并注入 Go 内存压制与并发限制
_xmg_xray_patch_systemd_unit_impl() {
    local xray_unit=""
    local unit_found=0
    local sys_dir="${XMG_SYSTEMD_DIR:-/etc/systemd/system}"

    # 查找 Xray 的 systemd unit 文件
    for path in "${sys_dir}/xray.service" "/etc/systemd/system/xray.service" "/lib/systemd/system/xray.service" "/usr/lib/systemd/system/xray.service"; do
        if [ -f "$path" ]; then
            xray_unit="$path"
            unit_found=1
            break
        fi
    done

    # 关键自愈：未找到 unit 时，若系统中存在 xray 二进制，直接自动生成自包含服务单元
    if [ "$unit_found" -ne 1 ]; then
        local xray_bin=""
        if declare -F xmg_xray_get_bin >/dev/null 2>&1; then
            xray_bin="$(xmg_xray_get_bin 2>/dev/null || true)"
        elif command -v xray >/dev/null 2>&1; then
            xray_bin="$(command -v xray)"
        elif [ -x /usr/local/bin/xray ]; then
            xray_bin="/usr/local/bin/xray"
        elif [ -x /usr/bin/xray ]; then
            xray_bin="/usr/bin/xray"
        fi

        if [ -n "$xray_bin" ] && [ -x "$xray_bin" ]; then
            xmg_info "未检测到现有 xray.service，正在自动生成自包含 systemd unit..."
            mkdir -p "${sys_dir}"
            cat > "${sys_dir}/xray.service" << EOF_UNIT
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment="GOMEMLIMIT=$(xmg_xray_gomemlimit)"
Environment="GODEBUG=madvdontneed=1"
Environment="GOMAXPROCS=$(xmg_xray_gomaxprocs)"
ExecStart=$xray_bin run -config ${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=$(xmg_xray_nofile)

[Install]
WantedBy=multi-user.target
EOF_UNIT
            chmod 644 "${sys_dir}/xray.service"
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable xray >/dev/null 2>&1 || true
            xray_unit="${sys_dir}/xray.service"
            unit_found=1
            xmg_info "已成功自愈生成 Xray systemd unit: $xray_unit"
            return 0
        fi

        xmg_warn "未找到 Xray 可执行程序与 systemd unit，跳过自动配置"
        return 1
    fi

    xmg_info "检测到 Xray systemd unit: $xray_unit"

    local dropin_dir="${sys_dir}/xray.service.d"
    local dropin_file="${dropin_dir}/20-xmg.conf"

    mkdir -p "$dropin_dir"

    local target_cfg="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
    local expected=""
    expected="$(xmg_xray_generate_dropin_content "$target_cfg")"
    # 与当前机型期望内容比对：机型（内存/CPU 配额）变化后自动刷新，不再「存在即跳过」
    if [ -f "$dropin_file" ] && [ "$(cat "$dropin_file" 2>/dev/null || true)" = "$expected" ]; then
        xmg_info "drop-in 覆盖已与当前机型参数一致 (GOMEMLIMIT=$(xmg_xray_gomemlimit) / GOMAXPROCS=$(xmg_xray_gomaxprocs))，无需修改"
        return 0
    fi

    # 备份现有 drop-in（如果存在）
    if [ -f "$dropin_file" ]; then
        local backup_dropin="${dropin_file}.xmg-backup.$(date +%Y%m%d_%H%M%S)"
        cp "$dropin_file" "$backup_dropin" 2>/dev/null && \
            xmg_info "已备份现有 drop-in 到: $backup_dropin" || true
    fi

    xmg_xray_generate_dropin_content "$target_cfg" > "$dropin_file"

    if grep -q "$target_cfg" "$dropin_file" 2>/dev/null && grep -q "GOMEMLIMIT=" "$dropin_file" 2>/dev/null; then
        xmg_info "drop-in 覆盖已按当前机型刷新 (GOMEMLIMIT=$(xmg_xray_gomemlimit) / GOMAXPROCS=$(xmg_xray_gomaxprocs))"
    else
        xmg_warn "drop-in 覆盖文件写入失败"
        return 1
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
}

# ===== 移除 XMG 覆盖（恢复官方行为）=====
xmg_xray_restore_systemd_unit() {
    if ! xmg_init_use_systemd_units; then
        if [ -f "$XMG_XRAY_OPENRC_SCRIPT" ]; then
            xmg_xray_remove_openrc_service
            return 0
        fi
        xmg_warn "未找到 XMG 管理的服务脚本: $XMG_XRAY_OPENRC_SCRIPT"
        return 1
    fi

    local sys_dir="${XMG_SYSTEMD_DIR:-/etc/systemd/system}"
    local dropin_dir="${sys_dir}/xray.service.d"
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

    if xmg_svc_supported; then
        xmg_svc_reload_manager
        xmg_svc_enable "$XMG_XRAY_SERVICE" >/dev/null 2>&1 && \
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

    # 停止并禁用服务
    if xmg_svc_supported; then
        xmg_svc_stop "$XMG_XRAY_SERVICE" >/dev/null 2>&1 || true
        xmg_svc_disable "$XMG_XRAY_SERVICE" >/dev/null 2>&1 || true
    fi

    # 尝试使用官方卸载脚本（带镜像加速 fallback）
    xmg_info "正在清理 Xray 系统文件与内核..."
    local uninst_urls=(
        "$XMG_XRAY_INSTALL_URL"
        "https://ghfast.top/$XMG_XRAY_INSTALL_URL"
        "https://mirror.ghproxy.com/$XMG_XRAY_INSTALL_URL"
    )
    local u=""
    for u in "${uninst_urls[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL --connect-timeout 8 --max-time 20 "$u" 2>/dev/null | bash -s -- remove >/dev/null 2>&1; then
                break
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -q -T 8 -O- "$u" 2>/dev/null | bash -s -- remove >/dev/null 2>&1; then
                break
            fi
        fi
    done

    # 自包含彻底兜底清理：即便官方远程脚本因网络问题不可达，亦能 100% 干净卸载
    rm -f /usr/local/bin/xray /usr/bin/xray /opt/xmg/bin/xray 2>/dev/null || true
    rm -rf /usr/local/share/xray /usr/share/xray /etc/xray /usr/local/etc/xray 2>/dev/null || true

    # 删除 XMG 管理的 Xray 配置目录
    if [ -d "$XMG_XRAY_DIR" ]; then
        rm -rf "$XMG_XRAY_DIR" 2>/dev/null || true
        xmg_info "已删除配置目录: $XMG_XRAY_DIR"
    fi

    # 删除 XMG 管理的 Xray 日志目录
    if [ -d "$XMG_XRAY_LOG_DIR" ]; then
        rm -rf "$XMG_XRAY_LOG_DIR" 2>/dev/null || true
        xmg_info "已删除日志目录: $XMG_XRAY_LOG_DIR"
    fi

    # 清理 systemd unit 残留
    # 用 use_systemd_units 而非 is_systemd：容器/chroot 里 systemd 未运行，
    # 但 unit 文件仍然存在，必须一并清掉
    if xmg_init_use_systemd_units; then
        for path in "/etc/systemd/system/xray.service" "/etc/systemd/system/xray@.service" "/lib/systemd/system/xray.service" "/usr/lib/systemd/system/xray.service"; do
            rm -f "$path" 2>/dev/null || true
        done
        rm -rf /etc/systemd/system/xray.service.d 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        # OpenRC 残留清理
        xmg_xray_remove_openrc_service >/dev/null 2>&1 || true
        rm -f /run/xray.pid 2>/dev/null || true
    fi

    xmg_info "Xray 卸载流程完成 (已彻底清理二进制、服务与配置)"
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

    if xmg_xray_restart_hard; then
        xmg_info "Xray 已重启（stop → start 已验证 active）"
    else
        xmg_error "Xray 重启失败，请检查: $( [ "$XMG_INIT_SYSTEM" = "openrc" ] && echo "rc-service $XMG_XRAY_SERVICE status" || echo "systemctl status $XMG_XRAY_SERVICE" )"
        return 1
    fi
}

# 硬重启：停 → 等进程退出 → 启 → 等 active
# 配置变更、WARP 出站切换、内核二进制更新后都必须走这里，
# 直接 restart 在进程未完全退出时会让新进程 bind 失败
xmg_xray_restart_hard() {
    local svc="${XMG_XRAY_SERVICE:-xray}"
    local timeout="${1:-8}"

    if ! xmg_svc_supported; then
        xmg_warn "未检测到可用的服务管理器（init=$XMG_INIT_SYSTEM），无法重启 $svc"
        return 1
    fi

    # 注册文件缺失时先补齐（升级/手工删除后常见）
    if declare -F xmg_core_patch_systemd_unit >/dev/null 2>&1; then
        xmg_core_patch_systemd_unit "${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}" >/dev/null 2>&1 || true
    elif declare -F xmg_xray_patch_systemd_unit >/dev/null 2>&1; then
        xmg_xray_patch_systemd_unit "${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}" >/dev/null 2>&1 || true
    fi
    xmg_svc_reload_manager

    xmg_svc_restart_verified "$svc" "$timeout"
    local rc=$?

    if [ "$rc" -eq 1 ]; then
        xmg_error "$svc 启动后未进入 active，最近日志:"
        xmg_svc_logs "$svc" 15 2>/dev/null | sed 's/^/  /' >&2 || true
        return 1
    fi
    return $rc
}

xmg_xray_reload() {
    xmg_require_root
    xmg_info "Xray 不支持平滑重载配置，正在重启服务以生效新配置..."
    xmg_xray_restart
}

xmg_xray_status() {
    if ! xmg_svc_supported; then
        xmg_warn "未检测到可用的服务管理器（systemd / OpenRC），无法查看 Xray 状态"
        return 1
    fi
    xmg_svc_status "$XMG_XRAY_SERVICE" || true
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
    echo "xmg 视角: $(xmg_os_summary 2>/dev/null || echo unknown)"

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
    for cmd in xray curl wget systemctl rc-service rc-update unzip; do
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
    echo "[服务注册检测]"
    if xmg_init_use_systemd_units; then
        local unit_found=0
        for path in "/etc/systemd/system/xray.service" "/lib/systemd/system/xray.service" "/usr/lib/systemd/system/xray.service"; do
            if [ -f "$path" ]; then
                echo "存在: $path"
                echo "  ExecStart: $(grep 'ExecStart=' "$path" | head -1)"
                unit_found=1
            fi
        done
        [ "$unit_found" -eq 0 ] && echo "未找到 systemd unit"
        if [ -f "${XMG_SYSTEMD_DIR:-/etc/systemd/system}/xray.service.d/20-xmg.conf" ]; then
            echo "存在 XMG drop-in: ${XMG_SYSTEMD_DIR:-/etc/systemd/system}/xray.service.d/20-xmg.conf"
        fi
    elif xmg_init_is_openrc; then
        if [ -f "$XMG_XRAY_OPENRC_SCRIPT" ]; then
            echo "存在: $XMG_XRAY_OPENRC_SCRIPT"
            grep -E '^(command|command_args|supervisor|rc_ulimit)=' "$XMG_XRAY_OPENRC_SCRIPT" | sed 's/^/  /'
        else
            echo "未找到 OpenRC 服务脚本: $XMG_XRAY_OPENRC_SCRIPT"
        fi
        echo "运行级: $(rc-update show 2>/dev/null | grep -w "$XMG_XRAY_SERVICE" | head -1 || echo 未注册)"
    else
        echo "init 后端: $(xmg_xray_init_backend)"
    fi

    echo
    echo "[服务状态]"
    if xmg_svc_supported; then
        xmg_svc_status "$XMG_XRAY_SERVICE" || true
    else
        echo "无可用的服务管理器"
    fi

    echo
    echo "[最近日志]"
    xmg_svc_logs "$XMG_XRAY_SERVICE" 50 || true
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
                xmg_xray_install_update || true
                xmg_pause
                ;;
            2)
                xmg_xray_uninstall || true
                xmg_pause
                ;;
            3)
                xmg_xray_start || true
                xmg_pause
                ;;
            4)
                xmg_xray_stop || true
                xmg_pause
                ;;
            5)
                xmg_xray_restart || true
                xmg_pause
                ;;
            6)
                xmg_xray_reload || true
                xmg_pause
                ;;
            7)
                xmg_xray_status || true
                xmg_pause
                ;;
            8)
                xmg_xray_validate_config || true
                xmg_pause
                ;;
            9)
                xmg_xray_show_config || true
                xmg_pause
                ;;
            10)
                xmg_xray_diag || true
                xmg_pause
                ;;
            11)
                xmg_xray_restore_systemd_unit || true
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
