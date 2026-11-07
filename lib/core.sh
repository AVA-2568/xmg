#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# core.sh - Xray 内核管理
#
# XMG_MENU_LABEL: 核心架构引擎
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
    elif [ -f "${XMG_LIB_DIR:-/opt/xmg/lib}/detect.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-/opt/xmg/lib}/detect.sh"
    fi
fi

if ! declare -F xmg_state_init >/dev/null 2>&1; then
    if [ -f "$_XMG_CORE_LIBDIR/state.sh" ]; then
        # shellcheck source=/dev/null
        source "$_XMG_CORE_LIBDIR/state.sh"
    elif [ -f "${XMG_LIB_DIR:-/opt/xmg/lib}/state.sh" ]; then
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-/opt/xmg/lib}/state.sh"
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
    xmg_require_root

    # 内存体检：不足时仅告警，不阻断（用户可自行配置 swap 后重试）
    xmg_core_memcheck || true

    if xmg_init_is_systemd; then
        args="$(xmg_core_install_args)" || return $?

        local -a extra=()
        [ "$XMG_CORE_GEODATA" = "1" ] || extra+=("--without-geodata")

        xmg_info "安装 Xray 内核 ${args:-(stable)}..."
        if ! xmg_core_install_official "$args" "${extra[@]}"; then
            xmg_error "官方安装脚本执行失败"
            return 4
        fi
    else
        # 官方 install-release.sh 硬校验 systemd（非 systemd 直接 exit），
        # 且包管理器识别不含 apk，因此 Alpine / OpenRC 走内置原生安装流程。
        local channel=""
        channel="$(xmg_state_get XRAY_CHANNEL 2>/dev/null || true)"
        [ -n "$channel" ] || channel="stable"

        if ! xmg_core_install_native "$channel"; then
            xmg_error "内置安装流程失败"
            return 4
        fi
    fi

    # 关键收尾：无论装的是新内核还是同版本跳过，立即确保服务注册存在并生效
    xmg_core_patch_systemd_unit "${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}" >/dev/null 2>&1 || true

    # 二进制刚被替换：旧进程仍持有旧 inode，必须换进程新版本才生效
    local cfg_path="${XMG_XRAY_CONFIG:-/opt/xmg/xray/config.json}"
    if [ -s "$cfg_path" ] && xmg_svc_supported; then
        if declare -F xmg_xray_restart_hard >/dev/null 2>&1; then
            if xmg_xray_restart_hard; then
                xmg_info "Xray 已重启并确认加载新内核"
            else
                xmg_warn "Xray 重启失败，请执行 xmg xray restart 或查看 xmg xray diag"
            fi
        elif xmg_svc_restart_verified "${XMG_XRAY_SERVICE:-xray}" 8; then
            xmg_info "Xray 已重启并确认加载新内核"
        else
            xmg_warn "Xray 重启失败，请执行 xmg xray restart 或查看 xmg xray diag"
        fi
    fi

    xmg_info "内核安装完成"
    xmg_core_version
    return 0
}

# ===== 内置原生安装（非 systemd / Alpine 专用）=====

# CPU 架构 -> Xray 官方发布包命名后缀
xmg_core_arch_slug() {
    case "$(uname -m 2>/dev/null || echo unknown)" in
        x86_64|amd64)  printf '64' ;;
        aarch64|arm64) printf 'arm64-v8a' ;;
        armv7l|armv7)  printf 'arm32-v7a' ;;
        armv6l)        printf 'arm32-v6' ;;
        i386|i486|i586|i686) printf '32' ;;
        s390x)         printf 's390x' ;;
        *) return 1 ;;
    esac
}

# 统一下载器（带 GitHub 加速镜像回退）
_xmg_core_download() {
    local url="$1"
    local out="$2"
    local u=""

    for u in "$url" "https://ghfast.top/$url" "https://mirror.ghproxy.com/$url"; do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL --connect-timeout 8 --max-time 180 "$u" -o "$out" 2>/dev/null && [ -s "$out" ]; then
                return 0
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -q -T 30 -O "$out" "$u" 2>/dev/null && [ -s "$out" ]; then
                return 0
            fi
        else
            return 1
        fi
    done
    return 1
}

# 解析目标版本 tag：pinned 直取记录值；stable/preview 走 GitHub API
xmg_core_resolve_tag() {
    local channel="$1"

    if [ "$channel" = "pinned" ]; then
        local pinned=""
        pinned="$(xmg_state_get XRAY_PINNED_VERSION 2>/dev/null || true)"
        if [ -z "$pinned" ]; then
            xmg_error "通道为 pinned 但未记录版本号"
            return 3
        fi
        printf '%s' "$pinned"
        return 0
    fi

    local api=""
    if [ "$channel" = "preview" ]; then
        api="https://api.github.com/repos/XTLS/Xray-core/releases?per_page=5"
    else
        api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    fi

    local tmp=""
    tmp="$(mktemp)" || return 1
    if _xmg_core_download "$api" "$tmp"; then
        local tag=""
        tag="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp" | head -n 1)"
        rm -f "$tmp" 2>/dev/null || true
        if [ -n "$tag" ]; then
            printf '%s' "$tag"
            return 0
        fi
    else
        rm -f "$tmp" 2>/dev/null || true
    fi

    # API 被限流/阻断时，跟随 releases/latest 的重定向地址反推 tag
    if command -v curl >/dev/null 2>&1; then
        local eff=""
        eff="$(curl -fsSIL --connect-timeout 8 --max-time 25 -o /dev/null \
            -w '%{url_effective}' "https://github.com/XTLS/Xray-core/releases/latest" 2>/dev/null || true)"
        case "$eff" in
            */tag/*)
                printf '%s' "${eff##*/tag/}"
                return 0
                ;;
        esac
    fi

    xmg_error "无法解析 Xray 最新版本号（GitHub API 不可达）"
    xmg_warn "可改用固定版本: xmg core menu 选择「安装指定版本」"
    return 1
}

# 解压 zip（Alpine 最小化系统可能只有 busybox unzip）
_xmg_core_unzip() {
    local zip="$1"
    local dest="$2"

    if command -v unzip >/dev/null 2>&1; then
        unzip -o -q "$zip" -d "$dest" && return 0
    fi
    if busybox unzip -o -q "$zip" -d "$dest" >/dev/null 2>&1; then
        return 0
    fi
    if [ "$(xmg_pkg_mgr)" = "apk" ]; then
        xmg_info "安装 unzip 以解压内核压缩包..."
        if xmg_pkg_install unzip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
            unzip -o -q "$zip" -d "$dest" && return 0
        fi
    fi
    return 1
}

# 原生安装主流程：下载官方 zip -> 落盘 /usr/local/bin/xray -> 服务注册交给上层
xmg_core_install_native() {
    local channel="${1:-stable}"

    local slug=""
    if ! slug="$(xmg_core_arch_slug)"; then
        xmg_error "当前架构不受支持: $(uname -m 2>/dev/null || echo unknown)"
        return 1
    fi

    local tag=""
    if ! tag="$(xmg_core_resolve_tag "$channel")"; then
        return 1
    fi

    xmg_info "目标版本: $tag ($channel) / 架构: linux-$slug"

    local workdir=""
    workdir="$(xmg_core_resolve_tmpdir)"
    local run_tmp="${workdir%/}/xmg-core-$-$RANDOM"
    mkdir -p "$run_tmp" 2>/dev/null || run_tmp="$workdir"
    if [ "$workdir" != "/tmp" ]; then
        xmg_info "使用物理临时目录防 tmpfs OOM: $run_tmp"
    fi

    local zip="${run_tmp}/xray.zip"
    local url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${slug}.zip"

    xmg_info "下载内核: $url"
    if ! _xmg_core_download "$url" "$zip"; then
        rm -rf "$run_tmp" 2>/dev/null || true
        xmg_error "内核下载失败（若为纯 IPv6 主机请检查 DNS64 或开启 WARP IPv4 出口）"
        return 1
    fi

    local unpack="${run_tmp}/unpack"
    mkdir -p "$unpack"
    if ! _xmg_core_unzip "$zip" "$unpack" || [ ! -f "$unpack/xray" ]; then
        rm -rf "$run_tmp" 2>/dev/null || true
        xmg_error "内核压缩包解压失败或内容异常"
        return 1
    fi

    # 落盘：先放同目录临时名再原子 mv，避免升级中途二进制被截断
    local target="/usr/local/bin/xray"
    mkdir -p "$(dirname "$target")"
    if ! cp -f "$unpack/xray" "${target}.xmg-new" 2>/dev/null; then
        rm -rf "$run_tmp" 2>/dev/null || true
        xmg_error "写入 $target 失败（磁盘空间不足或权限不足）"
        return 1
    fi
    chmod 0755 "${target}.xmg-new" || true
    mv -f "${target}.xmg-new" "$target" || {
        rm -f "${target}.xmg-new" 2>/dev/null || true
        rm -rf "$run_tmp" 2>/dev/null || true
        xmg_error "替换 $target 失败"
        return 1
    }

    # 地理数据默认不装（低配机型省磁盘），需要时再开
    if [ "$XMG_CORE_GEODATA" = "1" ]; then
        local dat_dir="/usr/local/share/xray"
        mkdir -p "$dat_dir"
        local f=""
        for f in geoip.dat geosite.dat; do
            if [ -f "$unpack/$f" ]; then
                cp -f "$unpack/$f" "$dat_dir/$f" 2>/dev/null || true
            fi
        done
        xmg_info "地理数据已安装到 $dat_dir"
    fi

    rm -rf "$run_tmp" 2>/dev/null || true

    if [ ! -x "$target" ]; then
        xmg_error "安装后未找到可执行文件: $target"
        return 1
    fi

    xmg_info "内核已安装: $target ($("$target" version 2>/dev/null | head -n 1 || echo "$tag"))"
    return 0
}

# ===== systemd drop-in 生成与写入 =====
_xmg_core_ensure_xray_module() {
    if ! declare -F xmg_xray_patch_systemd_unit >/dev/null 2>&1; then
        local xray_file="${XMG_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/xray.sh"
        if [ -r "$xray_file" ]; then
            # shellcheck source=/dev/null
            source "$xray_file"
        fi
    fi
}

xmg_core_generate_dropin_content() {
    _xmg_core_ensure_xray_module
    xmg_xray_generate_dropin_content "$@"
}

xmg_core_patch_systemd_unit() {
    _xmg_core_ensure_xray_module
    xmg_xray_patch_systemd_unit "$@"
}

xmg_core_restore_systemd_unit() {
    _xmg_core_ensure_xray_module
    xmg_xray_restore_systemd_unit "$@"
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
    # 规范化临时解压目录路径，防止 /tmp 冲突与多实例竞争
    local run_tmpdir="${target_tmp%/}/xmg-inst-$-$RANDOM"
    mkdir -p "$run_tmpdir" 2>/dev/null || run_tmpdir="$target_tmp"
    if [ "$target_tmp" != "/tmp" ]; then
        xmg_info "使用物理临时目录解压以防 tmpfs OOM: $run_tmpdir"
    fi

    local script_tmp="${run_tmpdir}/xray-install.sh"

    local install_urls=(
        "$XMG_XRAY_INSTALL_URL"
        "https://ghfast.top/$XMG_XRAY_INSTALL_URL"
        "https://mirror.ghproxy.com/$XMG_XRAY_INSTALL_URL"
    )

    local dl_ok=0
    for u in "${install_urls[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL --connect-timeout 8 --max-time 25 "$u" -o "$script_tmp" 2>/dev/null && [ -s "$script_tmp" ]; then
                dl_ok=1
                break
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -q -T 8 -O "$script_tmp" "$u" 2>/dev/null && [ -s "$script_tmp" ]; then
                dl_ok=1
                break
            fi
        fi
    done

    if [ "$dl_ok" -ne 1 ]; then
        rm -f "$script_tmp" 2>/dev/null || true
        xmg_error "下载 Xray 官方安装脚本失败 (纯 IPv6 主机直连 GitHub 受限，请检查 DNS64 或开启 WARP IPv4 出口)"
        return 4
    fi

    local ret=0
    # args 故意不加引号：需要按空格拆成多个参数交给官方脚本
    # shellcheck disable=SC2086
    TMPDIR="$run_tmpdir" bash "$script_tmp" install -f $args "${extra[@]}" || ret=$?
    rm -rf "$run_tmpdir" 2>/dev/null || rm -f "$script_tmp" 2>/dev/null || true

    return "$ret"
}

# ===== 版本查询 =====
xmg_core_version() {
    local bin=""
    bin="$(xmg_xray_binary)" || {
        xmg_warn "未检测到 xray 内核，请先安装"
        return 1
    }
    local out=""
    out="$("$bin" version 2>/dev/null || true)"
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | head -n 1
        return 0
    fi
    return 1
}

xmg_core_status() {
    declare -F xmg_state_init >/dev/null 2>&1 && xmg_state_init
    local channel
    channel="$(xmg_state_get XRAY_CHANNEL)"
    printf '内核通道: %s\n' "$channel"
    if [ "$channel" = "pinned" ]; then
        printf '锁定版本: %s\n' "$(xmg_state_get XRAY_PINNED_VERSION)"
    fi
    local v=""
    v="$(xmg_core_version 2>/dev/null || true)"
    if [ -n "$v" ]; then
        printf '当前版本: %s\n' "$v"
    else
        printf '当前版本: (未安装)\n'
    fi
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
        xmg_info "已自动应用内存抑制 (GOMEMLIMIT=$(xmg_xray_gomemlimit 2>/dev/null || echo 32MiB)) 与单核限制 (GOMAXPROCS=1)，允许继续安装"
        return 0
    fi

    # 小内存机器（low 档 <= 512MB，如 331MB）：可用内存已达 128MB 以上且未显式指定超大阈值时放行
    if [ "$profile" = "low" ] && [ "$threshold" -le 256 ] && [ "$mb" -ge 128 ]; then
        xmg_info "检测到低配内存模式 (low，可用: ${mb}MB)"
        xmg_info "已自动应用内存抑制 (GOMEMLIMIT=$(xmg_xray_gomemlimit 2>/dev/null || echo 32MiB)) 与单核限制 (GOMAXPROCS=1)，允许继续安装"
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
xmg_core_menu() {
    declare -F xmg_state_init >/dev/null 2>&1 && xmg_state_init
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
                { xmg_core_channel_set preview && xmg_core_install; } || true
                xmg_pause
                ;;
            2)
                { xmg_core_channel_set stable && xmg_core_install; } || true
                xmg_pause
                ;;
            3)
                printf "请输入版本号 (如 v25.8.3): " >&2
                read -r ver || return 0
                { xmg_core_channel_set pinned "$ver" && xmg_core_install; } || true
                xmg_pause
                ;;
            4)
                xmg_core_version || true
                xmg_pause
                ;;
            5)
                xmg_core_status || true
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
