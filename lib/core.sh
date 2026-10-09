#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# core.sh - Xray 内核管理
#
# 说明：
#   - 复用官方 Xray-install 脚本，不自行拼接下载地址
#   - 官方脚本已内置 --beta（预览版，对应 PRE_RELEASE_LATEST）与 --version <tag>
#   - 本模块只负责「版本通道的选择与记录」，安装动作交由官方脚本
#
# 三通道：
#   stable  -> 官方脚本不带版本参数，装最新稳定版
#   preview -> --beta，装预发布版（本面板默认）
#   pinned  -> --version <tag>，锁定到指定 tag

#===== 安全加载 =====
if [ "${XMG_CORE_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_CORE_SH_LOADED=1

if [ -z "${BASH_VERSION:-}" ]; then
    echo "core.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# 基本日志函数回退
if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info()  { printf '[INFO] %s\n' "$*"; }
    xmg_warn()  { printf '[WARN] %s\n' "$*" >&2; }
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi

if ! declare -F xmg_require_root >/dev/null 2>&1; then
    xmg_require_root() {
        if [ "${EUID:-$(id -u 2>/dev/null || echo 1)}" -ne 0 ]; then
            xmg_error "此操作需要 root 权限"
            return 1
        fi
        return 0
    }
fi

_XMG_CORE_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F xmg_detect_mem_profile >/dev/null 2>&1; then
    if [ -f "$_XMG_CORE_LIBDIR/detect.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_CORE_LIBDIR/detect.sh"
    fi
fi
unset _XMG_CORE_LIBDIR

XMG_XRAY_INSTALL_URL="${XMG_XRAY_INSTALL_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"
XMG_XRAY_SERVICE="${XMG_XRAY_SERVICE:-xray}"

# 路径变量默认值
if [ -z "${XMG_HOME:-}" ]; then
    XMG_HOME="/opt/xmg"
fi
if [ -z "${XMG_XRAY_DIR:-}" ]; then
    XMG_XRAY_DIR="$XMG_HOME/xray"
fi
if [ -z "${XMG_XRAY_CONFIG:-}" ]; then
    XMG_XRAY_CONFIG="$XMG_XRAY_DIR/config.json"
fi

# 低配机型默认不下载地理数据（geoip.dat / geosite.dat），省磁盘与流量。
# 设为 1 时才让官方脚本下载 geodata。
XMG_CORE_GEODATA="${XMG_CORE_GEODATA:-0}"

export XMG_XRAY_INSTALL_URL XMG_XRAY_SERVICE XMG_HOME XMG_XRAY_DIR XMG_XRAY_CONFIG

# ===== 通道参数推导 =====
# 输出传给官方脚本的参数（可能是两个词，如 "--version v25.8.3"）。
# 失败：3 = pinned 但缺版本号；2 = 通道非法。
xmg_core_install_args() {
    local channel pinned
    channel="$(xmg_state_get XRAY_CHANNEL)"
    pinned="$(xmg_state_get XRAY_PINNED_VERSION)"

    case "$channel" in
        stable)
            # 不传版本参数，官方脚本装最新稳定版
            printf '%s' ""
            ;;
        preview)
            # 官方脚本 BETA=1 -> INSTALL_VERSION="$PRE_RELEASE_LATEST"
            printf '%s' "--beta"
            ;;
        pinned)
            if [ -z "$pinned" ]; then
                xmg_error "通道为 pinned 但未指定版本号，请先设置 XRAY_PINNED_VERSION"
                return 3
            fi
            printf '%s' "--version $pinned"
            ;;
        *)
            xmg_error "未知内核通道: '$channel'（取值 stable/preview/pinned）"
            return 2
            ;;
    esac
    return 0
}

# ===== 通道写入 =====
# xmg_core_channel_set <通道> [版本]
xmg_core_channel_set() {
    local channel="${1:-}" version="${2:-}"

    case "$channel" in
        stable|preview) ;;
        pinned)
            if [ -z "$version" ]; then
                xmg_error "pinned 通道需要指定版本号"
                return 2
            fi
            ;;
        *)
            xmg_error "非法通道: '$channel'（取值 stable/preview/pinned）"
            return 2
            ;;
    esac

    xmg_state_set XRAY_CHANNEL "$channel" || return 4
    if [ "$channel" = "pinned" ]; then
        xmg_state_set XRAY_PINNED_VERSION "$version" || return 4
    else
        # 切回 stable/preview 时清掉遗留的锁定版本，避免下次误用
        xmg_state_set XRAY_PINNED_VERSION "" || return 4
    fi
    return 0
}

# ===== 安装 =====
xmg_core_install() {
    local args=""
    args="$(xmg_core_install_args)" || return $?
    xmg_require_root

    # 内存体检：不足时仅告警，不阻断（用户可自行配置 swap 后重试）
    xmg_core_memcheck || true

    local -a extra=()
    [ "$XMG_CORE_GEODATA" = "1" ] || extra+=("--without-geodata")

    xmg_info "安装 Xray 内核 ${args:-(stable)}..."
    if ! xmg_core_install_official "$args" "${extra[@]}"; then
        xmg_error "官方安装脚本执行失败"
        return 4
    fi

    xmg_info "内核安装完成"
    xmg_core_version
    return 0
}

# ===== systemd drop-in 生成与写入 =====
xmg_core_generate_dropin_content() {
    local cfg="${1:-${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}}"
    cat <<EOF
# XMG 管理的 drop-in 覆盖文件
# 此文件优先级高于官方的 10-donot_touch_single_conf.conf
# 请勿手动编辑，由 XMG 自动管理
[Service]
Environment="GOMEMLIMIT=100MiB"
Environment="GODEBUG=madvdontneed=1"
Environment="GOMAXPROCS=1"
ExecStart=
ExecStart=/usr/local/bin/xray run -config $cfg
EOF
}

xmg_core_patch_systemd_unit() {
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

    if [ "$unit_found" -ne 1 ]; then
        xmg_warn "未找到 Xray systemd unit，跳过自动配置"
        return 1
    fi

    xmg_info "检测到 Xray systemd unit: $xray_unit"

    local dropin_dir="${sys_dir}/xray.service.d"
    local dropin_file="${dropin_dir}/20-xmg.conf"

    mkdir -p "$dropin_dir"

    local target_cfg="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
    # 检查 drop-in 是否已经指向 XMG 路径且已包含 GOMEMLIMIT
    if [ -f "$dropin_file" ] && grep -q "$target_cfg" "$dropin_file" 2>/dev/null && grep -q "GOMEMLIMIT=100MiB" "$dropin_file" 2>/dev/null; then
        xmg_info "drop-in 覆盖已存在且已应用 100MiB 内存抑制，无需修改"
        return 0
    fi

    # 备份现有 drop-in（如果存在）
    if [ -f "$dropin_file" ]; then
        local backup_dropin="${dropin_file}.xmg-backup.$(date +%Y%m%d_%H%M%S)"
        cp "$dropin_file" "$backup_dropin" 2>/dev/null && \
            xmg_info "已备份现有 drop-in 到: $backup_dropin" || true
    fi

    xmg_core_generate_dropin_content "$target_cfg" > "$dropin_file"

    if grep -q "$target_cfg" "$dropin_file" 2>/dev/null && grep -q "GOMEMLIMIT=100MiB" "$dropin_file" 2>/dev/null; then
        xmg_info "drop-in 覆盖已创建，已应用 GOMEMLIMIT=100MiB / GOMAXPROCS=1"
    else
        xmg_warn "drop-in 覆盖文件写入失败"
        return 1
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
}

xmg_core_restore_systemd_unit() {
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

# ===== 临时解压目录解析 =====
xmg_core_resolve_tmpdir() {
    local use_physical=0
    local mem_prof=""
    if declare -F xmg_detect_mem_profile >/dev/null 2>&1; then
        mem_prof="$(xmg_detect_mem_profile 2>/dev/null || true)"
    fi

    if [ "$mem_prof" = "extreme_low" ]; then
        use_physical=1
    else
        local tmp_fs="${MOCK_TMP_FS:-}"
        local tmp_avail_kb="${MOCK_TMP_AVAIL_KB:-}"

        if [ -z "$tmp_fs" ] || [ -z "$tmp_avail_kb" ]; then
            if command -v df >/dev/null 2>&1; then
                local df_out=""
                df_out="$(df -k /tmp 2>/dev/null | tail -n 1)"
                if [ -n "$df_out" ]; then
                    local -a fields=($df_out)
                    local num_fields="${#fields[@]}"
                    if [ "$num_fields" -ge 4 ]; then
                        [ -n "$tmp_avail_kb" ] || tmp_avail_kb="${fields[num_fields-3]}"
                    fi
                fi
                local df_t=""
                df_t="$(df -T /tmp 2>/dev/null | tail -n 1)"
                if [[ "$df_t" =~ [[:space:]]tmpfs[[:space:]] ]]; then
                    [ -n "$tmp_fs" ] || tmp_fs="tmpfs"
                fi
            fi
        fi

        if [ "$tmp_fs" = "tmpfs" ] && [ -n "$tmp_avail_kb" ] && [ "$tmp_avail_kb" -lt 102400 ] 2>/dev/null; then
            use_physical=1
        elif [ -n "$tmp_avail_kb" ] && [ "$tmp_avail_kb" -lt 81920 ] 2>/dev/null; then
            use_physical=1
        fi
    fi

    if [ "$use_physical" -eq 1 ]; then
        local target_dir="${XMG_TMP_DIR:-${XMG_HOME:-/opt/xmg}/tmp}"
        printf '%s\n' "$target_dir"
        return 0
    fi

    printf '%s\n' "/tmp"
    return 0
}

# ===== 官方脚本安装执行 =====
xmg_core_install_official() {
    local args="${1:-}"
    shift || true
    local -a extra=("$@")

    local downloader=""
    if command -v curl >/dev/null 2>&1; then
        downloader="curl -fsSL"
    elif command -v wget >/dev/null 2>&1; then
        downloader="wget -qO-"
    else
        xmg_error "需要 curl 或 wget 才能安装内核"
        return 4
    fi

    local target_tmp=""
    target_tmp="$(xmg_core_resolve_tmpdir)"
    local custom_tmp_created=0
    local run_tmpdir=""

    if [ "$target_tmp" != "/tmp" ]; then
        run_tmpdir="$target_tmp/xray-inst.$$"
        mkdir -p "$run_tmpdir" 2>/dev/null || run_tmpdir="$target_tmp"
        mkdir -p "$run_tmpdir" 2>/dev/null || true
        custom_tmp_created=1
        xmg_info "使用物理临时目录解压以防 tmpfs OOM: $run_tmpdir"
    fi

    local ret=0
    # args 故意不加引号：需要按空格拆成多个参数交给官方脚本
    # shellcheck disable=SC2086
    if [ "$custom_tmp_created" -eq 1 ] && [ -d "$run_tmpdir" ]; then
        TMPDIR="$run_tmpdir" bash <($downloader "$XMG_XRAY_INSTALL_URL") install $args "${extra[@]}" || ret=$?
        rm -rf "$run_tmpdir" 2>/dev/null || true
    else
        bash <($downloader "$XMG_XRAY_INSTALL_URL") install $args "${extra[@]}" || ret=$?
    fi

    return "$ret"
}

# ===== 版本查询 =====
xmg_core_version() {
    local bin=""
    bin="$(xmg_xray_binary)" || {
        xmg_warn "未检测到 xray 内核，请先安装"
        return 1
    }
    "$bin" version 2>/dev/null | head -1
}

xmg_core_status() {
    local channel
    channel="$(xmg_state_get XRAY_CHANNEL)"
    printf '内核通道: %s\n' "$channel"
    if [ "$channel" = "pinned" ]; then
        printf '锁定版本: %s\n' "$(xmg_state_get XRAY_PINNED_VERSION)"
    fi
    printf '当前版本: %s\n' "$(xmg_core_version 2>/dev/null || printf '(未安装)')"
}

# ===== 内存体检 =====
# 低配机型（0.5C/215MB）下载与解压内核时内存峰值可能超限，
# 安装前体检并在不足时告警（不阻断，见 spec §7.4）。
# XMG_MEMINFO_FILE 仅用于测试注入：默认真机 /proc/meminfo。
XMG_MEM_CHECK_MB="${XMG_MEM_CHECK_MB:-256}"
XMG_MEMINFO_FILE="${XMG_MEMINFO_FILE:-/proc/meminfo}"

# 输出可用内存（MB）。优先 MemAvailable，回退 MemFree+Buffers+Cached；
# 无 /proc（部分开发环境）时回退 free；都不可用则返回 1（不报错崩掉）。
xmg_mem_available_mb() {
    local kb="" mb=""

    if [ -r "$XMG_MEMINFO_FILE" ]; then
        kb="$(awk '/^MemAvailable:/ {print $2; exit}' "$XMG_MEMINFO_FILE" 2>/dev/null)"
        if [ -z "$kb" ]; then
            kb="$(awk '/^MemFree:/ {f=$2} /^Buffers:/ {b=$2} /^Cached:/ {c=$2} END {print f+b+c}' \
                "$XMG_MEMINFO_FILE" 2>/dev/null)"
        fi
    fi

    if [ -n "$kb" ]; then
        mb=$((kb / 1024))
        printf '%s' "$mb"
        return 0
    fi

    # 无 /proc 时回退到系统命令
    if command -v free >/dev/null 2>&1; then
        mb="$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}')"
        if [ -n "$mb" ]; then
            printf '%s' "$mb"
            return 0
        fi
    fi

    return 1
}

# 内存体检：低于阈值时告警并返回 1；无法读取时告警并返回 0（不阻断）；
# 对 <= 256MB (extreme_low) 机器放行并提示 100MiB 内存抑制。
xmg_core_memcheck() {
    local threshold="${1:-$XMG_MEM_CHECK_MB}"
    local mb=""

    if ! mb="$(xmg_mem_available_mb)"; then
        xmg_warn "无法读取内存信息，跳过内存体检"
        return 0
    fi

    local profile=""
    if declare -F xmg_detect_mem_profile >/dev/null 2>&1; then
        profile="$(xmg_detect_mem_profile 2>/dev/null || true)"
    fi

    # 极低内存机器（<= 256MB，如 215MB）：
    # 当 profile 为 extreme_low 且未显式指定高于 256MB 的检查阈值时：
    # 不再报致命警告或强推 swap（容器环境往往无法创建 swap），
    # 而是展示 extreme_low 极低内存模式，提示已自动应用 100MiB 内存抑制，允许继续安装。
    if [ "$profile" = "extreme_low" ] && [ "$threshold" -le 256 ]; then
        xmg_info "检测到极低内存模式 (extreme_low，可用: ${mb}MB)"
        xmg_info "已自动应用 100MiB 内存抑制 (GOMEMLIMIT=100MiB) 与单核限制 (GOMAXPROCS=1)，允许继续安装"
        return 0
    fi

    if [ "$mb" -lt "$threshold" ]; then
        xmg_warn "可用内存仅 ${mb}MB，低于建议阈值 ${threshold}MB"
        xmg_warn "下载与解压 Xray 内核时内存峰值可能超出，建议先配置 swap"
        xmg_warn "可执行: xmg tune   (创建 swap 后再重试)"
        return 1
    fi

    xmg_info "内存体检通过: ${mb}MB"
    return 0
}

# ===== 菜单 =====
# XMG_MENU_LABEL: Xray 内核
xmg_core_menu() {
    local choice="" ver=""
    while true; do
        clear
        echo "========== Xray 内核管理 =========="
        xmg_core_status
        echo
        echo "1. 安装/更新到预览版"
        echo "2. 安装/更新到稳定版"
        echo "3. 安装指定版本"
        echo "4. 查看当前版本"
        echo "5. 查看内核状态"
        echo "0. 返回"
        echo
        printf "请选择: "
        read -r choice || return 0

        case "$choice" in
            1)
                xmg_core_channel_set preview && xmg_core_install
                xmg_pause
                ;;
            2)
                xmg_core_channel_set stable && xmg_core_install
                xmg_pause
                ;;
            3)
                printf "请输入版本号 (如 v25.8.3): " >&2
                read -r ver || return 0
                xmg_core_channel_set pinned "$ver" && xmg_core_install
                xmg_pause
                ;;
            4)
                xmg_core_version
                xmg_pause
                ;;
            5)
                xmg_core_status
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
