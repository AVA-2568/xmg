#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# os.sh - 发行版 / init / 包管理器 / 服务抽象层
#
# 说明：
#   - 统一 Debian 系（systemd + apt）与 Alpine（OpenRC + apk）的差异
#   - 所有模块优先使用本层的 xmg_pkg_* / xmg_svc_* 接口，不再直连包管理器与 init
#   - 纯 Bash 内建实现，零 jq / 零 python
#
# 可注入环境变量（测试用）：
#   MOCK_OS_ID / MOCK_OS_VER / MOCK_OS_LIKE / MOCK_OS_PRETTY
#   MOCK_INIT (systemd|openrc|sysvinit|none)
#   XMG_INIT_OVERRIDE  强制指定 init（需在进程启动前设置，检测结果会缓存）
#   XMG_OS_RELEASE_FILE / XMG_ALPINE_RELEASE_FILE / XMG_INIT_DIR
#

if [ -z "${BASH_VERSION:-}" ]; then
    echo "os.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

if [ "${XMG_OS_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_OS_SH_LOADED=1

# ===== 默认输出变量 =====
XMG_OS_ID="${XMG_OS_ID:-unknown}"
XMG_OS_LIKE="${XMG_OS_LIKE:-}"
XMG_OS_VER="${XMG_OS_VER:-}"
XMG_OS_PRETTY="${XMG_OS_PRETTY:-unknown}"
XMG_OS_FAMILY="${XMG_OS_FAMILY:-unknown}"
XMG_INIT_SYSTEM="${XMG_INIT_SYSTEM:-unknown}"
XMG_OS_DETECTED="${XMG_OS_DETECTED:-0}"

# 发行版 ID -> 家族归类
xmg_os_family_resolve() {
    local id="${1:-}"
    local like="${2:-}"

    case "$id" in
        debian|ubuntu|raspbian|linuxmint|devuan|armbian|kali|pop|elementary|neon|deepin|uos|deepin)
            printf 'debian\n'
            return 0
            ;;
        alpine)
            printf 'alpine\n'
            return 0
            ;;
        rhel|centos|rocky|almalinux|fedora|ol|amzn|virtuozzo|opencloudos|anolis|alibaba)
            printf 'rhel\n'
            return 0
            ;;
        arch|manjaro|endeavouros|garuda)
            printf 'arch\n'
            return 0
            ;;
        opensuse*|sles|suse)
            printf 'suse\n'
            return 0
            ;;
    esac

    # 回退：按 ID_LIKE 归类（Debian 衍生版通常 ID_LIKE="debian ubuntu"）
    case " $like " in
        *" debian "*|*" ubuntu "*)
            printf 'debian\n'
            return 0
            ;;
        *" alpine "*)
            printf 'alpine\n'
            return 0
            ;;
        *" rhel "*|*" fedora "*|*" centos "*)
            printf 'rhel\n'
            return 0
            ;;
        *" arch "*)
            printf 'arch\n'
            return 0
            ;;
        *" suse "*|*" opensuse "*)
            printf 'suse\n'
            return 0
            ;;
    esac

    printf 'unknown\n'
    return 0
}

# 发行版识别：优先 /etc/os-release，Alpine 老镜像回退 /etc/alpine-release
xmg_os_detect() {
    local force="${1:-}"

    if [ "${XMG_OS_DETECTED}" = "1" ] && [ "$force" != "force" ]; then
        return 0
    fi

    local id="" ver="" pretty="" like=""
    local rel="${XMG_OS_RELEASE_FILE:-/etc/os-release}"
    local alpine_rel="${XMG_ALPINE_RELEASE_FILE:-/etc/alpine-release}"

    if [ -n "${MOCK_OS_ID:-}" ]; then
        id="$MOCK_OS_ID"
        ver="${MOCK_OS_VER:-}"
        like="${MOCK_OS_LIKE:-}"
        pretty="${MOCK_OS_PRETTY:-$MOCK_OS_ID}"
    else
        if [ -r "$rel" ]; then
            local line=""
            while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in
                    ID=*)          id="${line#ID=}" ;;
                    ID_LIKE=*)     like="${line#ID_LIKE=}" ;;
                    VERSION_ID=*)  ver="${line#VERSION_ID=}" ;;
                    PRETTY_NAME=*) pretty="${line#PRETTY_NAME=}" ;;
                esac
            done < "$rel"
        fi

        # Alpine 老版本（3.x 早期）可能没有完整 os-release
        if [ -z "$id" ] && [ -r "$alpine_rel" ]; then
            id="alpine"
            ver="$(tr -d '\r\n' < "$alpine_rel" 2>/dev/null || true)"
        fi
    fi

    # 去掉引号与回车
    id="${id//\"/}"; id="${id//\'/}"; id="${id//$'\r'/}"
    like="${like//\"/}"; like="${like//\'/}"; like="${like//$'\r'/}"
    ver="${ver//\"/}"; ver="${ver//\'/}"; ver="${ver//$'\r'/}"
    pretty="${pretty//\"/}"; pretty="${pretty//\'/}"; pretty="${pretty//$'\r'/}"

    [ -n "$id" ] || id="unknown"
    [ -n "$pretty" ] || pretty="$id"

    XMG_OS_ID="$id"
    XMG_OS_LIKE="$like"
    XMG_OS_VER="$ver"
    XMG_OS_PRETTY="$pretty"
    XMG_OS_FAMILY="$(xmg_os_family_resolve "$id" "$like")"

    xmg_init_detect "$force"
    XMG_OS_DETECTED=1
    export XMG_OS_ID XMG_OS_LIKE XMG_OS_VER XMG_OS_PRETTY XMG_OS_FAMILY XMG_INIT_SYSTEM
    return 0
}

# init 系统识别：systemd / openrc / sysvinit / none
xmg_init_detect() {
    local force="${1:-}"

    if [ "$force" != "force" ] && [ -n "${XMG_INIT_OVERRIDE:-}" ]; then
        XMG_INIT_SYSTEM="$XMG_INIT_OVERRIDE"
        return 0
    fi
    if [ -n "${MOCK_INIT:-}" ]; then
        XMG_INIT_SYSTEM="$MOCK_INIT"
        return 0
    fi

    # systemd 必须同时具备 systemctl 与运行中的 systemd（chroot/容器根目录下会缺失）
    if command -v systemctl >/dev/null 2>&1; then
        if [ -d /run/systemd/system ] || [ "${XMG_ASSUME_SYSTEMD:-0}" = "1" ]; then
            XMG_INIT_SYSTEM="systemd"
            return 0
        fi
    fi

    if command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        XMG_INIT_SYSTEM="openrc"
        return 0
    fi
    if [ -d /run/openrc ] || [ -x /sbin/openrc ]; then
        XMG_INIT_SYSTEM="openrc"
        return 0
    fi

    if [ -d "${XMG_INIT_DIR:-/etc/init.d}" ] && command -v service >/dev/null 2>&1; then
        XMG_INIT_SYSTEM="sysvinit"
        return 0
    fi

    XMG_INIT_SYSTEM="none"
    return 0
}

xmg_os_is_alpine() {
    xmg_os_detect
    [ "$XMG_OS_FAMILY" = "alpine" ]
}

xmg_init_is_systemd() {
    xmg_os_detect
    [ "$XMG_INIT_SYSTEM" = "systemd" ]
}

xmg_init_is_openrc() {
    xmg_os_detect
    [ "$XMG_INIT_SYSTEM" = "openrc" ]
}

xmg_init_is_sysvinit() {
    xmg_os_detect
    [ "$XMG_INIT_SYSTEM" = "sysvinit" ]
}

# 是否以 systemd 单元形式落盘服务
# 判据是「systemctl 可用」而非「systemd 正在运行」：
# chroot、容器、离线镜像里 systemd 未启动但依然应该写 unit 文件；
# 而 Alpine 默认根本没有 systemctl，自然落到 OpenRC 分支。
xmg_init_use_systemd_units() {
    if xmg_init_is_systemd; then
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    if [ -n "${XMG_SYSTEMD_DIR:-}" ] && [ -d "${XMG_SYSTEMD_DIR}" ]; then
        return 0
    fi
    return 1
}

# ==================================================================
# 包管理器抽象
# ==================================================================

xmg_pkg_mgr() {
    if command -v apk >/dev/null 2>&1; then
        printf 'apk\n'
    elif command -v apt-get >/dev/null 2>&1; then
        printf 'apt\n'
    elif command -v dnf >/dev/null 2>&1; then
        printf 'dnf\n'
    elif command -v yum >/dev/null 2>&1; then
        printf 'yum\n'
    elif command -v pacman >/dev/null 2>&1; then
        printf 'pacman\n'
    elif command -v zypper >/dev/null 2>&1; then
        printf 'zypper\n'
    else
        printf 'none\n'
    fi
}

# 包管理器安装命令提示（用于错误信息）
xmg_pkg_hint() {
    case "$(xmg_pkg_mgr)" in
        apk)    printf 'apk add --no-cache %s\n' "${1:-<pkg>}" ;;
        apt)    printf 'apt-get install -y %s\n' "${1:-<pkg>}" ;;
        dnf)    printf 'dnf install -y %s\n' "${1:-<pkg>}" ;;
        yum)    printf 'yum install -y %s\n' "${1:-<pkg>}" ;;
        pacman) printf 'pacman -S --noconfirm %s\n' "${1:-<pkg>}" ;;
        zypper) printf 'zypper install -y %s\n' "${1:-<pkg>}" ;;
        *)      printf '请手动安装 %s\n' "${1:-<pkg>}" ;;
    esac
}

# 刷新软件源索引
xmg_pkg_update() {
    case "$(xmg_pkg_mgr)" in
        apk)
            apk update
            ;;
        apt)
            export DEBIAN_FRONTEND=noninteractive
            export NEEDRESTART_MODE=a
            export UCF_FORCE_CONFFOLD=1
            apt-get -o DPkg::Lock::Timeout=60 update
            ;;
        dnf)
            dnf makecache -y >/dev/null 2>&1 || dnf -y makecache
            ;;
        yum)
            yum makecache -y >/dev/null 2>&1 || true
            ;;
        pacman)
            pacman -Sy --noconfirm
            ;;
        zypper)
            zypper --non-interactive refresh
            ;;
        *)
            return 1
            ;;
    esac
}

# 安装软件包：xmg_pkg_install pkg1 pkg2 ...
# 已安装的包在 apk/apt 下会被自动跳过，可安全重复调用
xmg_pkg_install() {
    if [ "$#" -eq 0 ]; then
        return 0
    fi

    case "$(xmg_pkg_mgr)" in
        apk)
            apk add --no-cache "$@"
            ;;
        apt)
            if declare -F xmg_apt_wait_lock >/dev/null 2>&1; then
                xmg_apt_wait_lock 15 || true
            fi
            export DEBIAN_FRONTEND=noninteractive
            apt-get -o DPkg::Lock::Timeout=60 \
                    -o Dpkg::Options::="--force-confdef" \
                    -o Dpkg::Options::="--force-confold" \
                    install -y "$@"
            ;;
        dnf)
            dnf install -y "$@"
            ;;
        yum)
            yum install -y "$@"
            ;;
        pacman)
            pacman -Sy --noconfirm "$@"
            ;;
        zypper)
            zypper --non-interactive install "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

# 清理包缓存
xmg_pkg_clean() {
    case "$(xmg_pkg_mgr)" in
        apk)
            rm -rf /var/cache/apk/* 2>/dev/null || true
            apk cache clean >/dev/null 2>&1 || true
            ;;
        apt)
            apt-get clean >/dev/null 2>&1 || true
            apt-get autoclean -y >/dev/null 2>&1 || true
            ;;
        dnf) dnf clean all >/dev/null 2>&1 || true ;;
        yum) yum clean all >/dev/null 2>&1 || true ;;
        pacman) pacman -Scc --noconfirm >/dev/null 2>&1 || true ;;
        zypper) zypper clean --all >/dev/null 2>&1 || true ;;
        *) return 1 ;;
    esac
}

# 包是否已安装（仅支持 apk/apt 精确探测，其余返回 1）
xmg_pkg_installed() {
    local pkg="$1"
    [ -n "$pkg" ] || return 1

    case "$(xmg_pkg_mgr)" in
        apk)
            apk info -e "$pkg" >/dev/null 2>&1
            ;;
        apt)
            dpkg -s "$pkg" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# ==================================================================
# 服务管理抽象
# ==================================================================

# 服务名映射：Debian 用 ssh，Alpine 用 sshd
xmg_svc_name() {
    local name="$1"
    xmg_os_detect

    case "$name" in
        ssh|sshd)
            if [ "$XMG_INIT_SYSTEM" = "systemd" ]; then
                # Debian/Ubuntu 为 ssh.service，RHEL 系为 sshd.service
                if command -v systemctl >/dev/null 2>&1; then
                    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
                        printf 'ssh\n'
                        return 0
                    fi
                    if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
                        printf 'sshd\n'
                        return 0
                    fi
                fi
                printf 'ssh\n'
            else
                printf 'sshd\n'
            fi
            ;;
        *)
            printf '%s\n' "$name"
            ;;
    esac
}

xmg_svc_supported() {
    xmg_os_detect
    case "$XMG_INIT_SYSTEM" in
        systemd|openrc|sysvinit) return 0 ;;
        *) return 1 ;;
    esac
}

xmg_svc_do() {
    local action="$1"
    local svc="$2"

    xmg_os_detect
    case "$XMG_INIT_SYSTEM" in
        systemd)
            systemctl "$action" "$svc"
            ;;
        openrc)
            case "$action" in
                start|stop|restart|reload)
                    rc-service "$svc" "$action"
                    ;;
                enable)
                    # rc-update add 对已存在的服务会返回非零，先查一次保证幂等
                    if xmg_svc_is_enabled "$svc"; then
                        return 0
                    fi
                    rc-update add "$svc" default 2>/dev/null || rc-update add "$svc"
                    ;;
                disable)
                    rc-update del "$svc" default >/dev/null 2>&1 || true
                    rc-update del "$svc" >/dev/null 2>&1 || true
                    return 0
                    ;;
                *)
                    return 2
                    ;;
            esac
            ;;
        sysvinit)
            case "$action" in
                start|stop|restart|reload)
                    service "$svc" "$action"
                    ;;
                enable|disable)
                    return 0
                    ;;
                *)
                    return 2
                    ;;
            esac
            ;;
        *)
            return 2
            ;;
    esac
}

xmg_svc_start()   { xmg_svc_do start "$1"; }
xmg_svc_stop()    { xmg_svc_do stop "$1"; }
xmg_svc_restart() { xmg_svc_do restart "$1"; }
xmg_svc_enable()  { xmg_svc_do enable "$1"; }
xmg_svc_disable() { xmg_svc_do disable "$1"; }

xmg_svc_reload() {
    local svc="$1"
    xmg_os_detect
    if [ "$XMG_INIT_SYSTEM" = "systemd" ]; then
        systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc"
        return $?
    fi
    # OpenRC 的 reload 依赖服务自身实现，失败时退化为 restart
    if xmg_svc_do reload "$svc" >/dev/null 2>&1; then
        return 0
    fi
    xmg_svc_do restart "$svc"
}

xmg_svc_is_active() {
    local svc="$1"
    xmg_os_detect
    case "$XMG_INIT_SYSTEM" in
        systemd)
            systemctl is-active --quiet "$svc" 2>/dev/null
            ;;
        openrc)
            rc-service "$svc" status >/dev/null 2>&1
            ;;
        sysvinit)
            service "$svc" status >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

xmg_svc_is_enabled() {
    local svc="$1"
    xmg_os_detect
    case "$XMG_INIT_SYSTEM" in
        systemd)
            systemctl is-enabled --quiet "$svc" 2>/dev/null
            ;;
        openrc)
            rc-update show 2>/dev/null | awk '{print $1}' | grep -qx "$svc"
            ;;
        sysvinit)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

xmg_svc_status() {
    local svc="$1"
    xmg_os_detect
    case "$XMG_INIT_SYSTEM" in
        systemd)
            systemctl status "$svc" --no-pager
            ;;
        openrc)
            rc-service "$svc" status
            ;;
        sysvinit)
            service "$svc" status
            ;;
        *)
            printf '未检测到可用的服务管理器\n'
            return 1
            ;;
    esac
}

# 服务日志：systemd 走 journalctl，OpenRC 走 syslog 文件过滤
xmg_svc_logs() {
    local svc="$1"
    local lines="${2:-20}"
    xmg_os_detect

    if [ "$XMG_INIT_SYSTEM" = "systemd" ] && command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$svc" -n "$lines" --no-pager 2>/dev/null
        return $?
    fi

    local f=""
    local found=0
    for f in /var/log/messages /var/log/syslog /var/log/daemon.log; do
        [ -r "$f" ] || continue
        grep -F "$svc" "$f" 2>/dev/null | tail -n "$lines" && found=1
    done

    if [ "$found" -eq 0 ]; then
        printf '未找到 %s 的系统日志（可能未配置 syslog 服务）\n' "$svc"
        return 1
    fi
    return 0
}

# 强制结束服务进程（仅在优雅停止超时后使用）
# systemd: 直接对 unit cgroup 发 SIGKILL；OpenRC: 读 pidfile
xmg_svc_kill_force() {
    local svc="$1"
    xmg_os_detect

    case "$XMG_INIT_SYSTEM" in
        systemd)
            systemctl kill -s SIGKILL "$svc" >/dev/null 2>&1 || true
            ;;
        *)
            local pidfile="${XMG_PID_DIR:-/run}/${svc}.pid"
            if [ -r "$pidfile" ]; then
                local pid=""
                pid="$(tr -dc '0-9' < "$pidfile" 2>/dev/null || true)"
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null || true
                fi
            fi
            ;;
    esac
    return 0
}

# 停 → 等进程真正退出 → 启 → 等进入 active
#
# 为什么不用 restart：
#   1) 服务已处于 stopped/failed 时，部分 init 的 restart 不会把它拉起
#   2) 进程尚未完全退出就启动，端口/句柄仍被占用，Xray 会因 bind 失败而退出
#
# 返回：0 已进入 active / 1 启动后仍非 active / 2 无可用服务管理器
xmg_svc_restart_verified() {
    local svc="$1"
    local timeout="${2:-8}"
    local i=0

    xmg_os_detect

    if ! xmg_svc_supported; then
        return 2
    fi

    if xmg_svc_is_active "$svc"; then
        xmg_svc_stop "$svc" >/dev/null 2>&1 || true

        # 等待进程真正退出（逐秒轮询，兼容没有 sleep 小数支持的 BusyBox）
        for ((i = 0; i < timeout; i++)); do
            xmg_svc_is_active "$svc" || break
            sleep 1
        done

        if xmg_svc_is_active "$svc"; then
            xmg_warn "$svc 未在 ${timeout}s 内停止，强制结束进程"
            xmg_svc_kill_force "$svc"
            for ((i = 0; i < 3; i++)); do
                xmg_svc_is_active "$svc" || break
                sleep 1
            done
        fi
    fi

    xmg_svc_start "$svc" >/dev/null 2>&1 || true

    for ((i = 0; i < timeout; i++)); do
        xmg_svc_is_active "$svc" && return 0
        sleep 1
    done

    return 1
}

# 配置文件落盘后的 init 侧生效动作（systemd 需 daemon-reload，OpenRC 无需）
xmg_svc_reload_manager() {
    xmg_os_detect
    if [ "$XMG_INIT_SYSTEM" = "systemd" ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    return 0
}

# 一行式环境摘要，供 doctor / 菜单 / 诊断使用
xmg_os_summary() {
    xmg_os_detect
    printf '%s (%s) init=%s pkg=%s\n' \
        "${XMG_OS_PRETTY:-unknown}" \
        "${XMG_OS_FAMILY:-unknown}" \
        "${XMG_INIT_SYSTEM:-unknown}" \
        "$(xmg_pkg_mgr)"
}

# ==================================================================
# 兼容层兜底
# ==================================================================
# state.sh / xray.sh / ssh.sh 会直接调用 xmg_systemctl。
# 正式入口会先加载 common.sh（那里有带日志与 root 校验的完整实现），
# 只有单独 source 这些模块时才需要这里的极简版本，避免 command not found。
# 注意：common.sh 在 os.sh 之后定义同名函数，会覆盖本实现。
if ! declare -F xmg_systemctl >/dev/null 2>&1; then
    xmg_systemctl() {
        local action="${1:-}"
        local service="${2:-}"

        [ -n "$action" ] || return 2

        if [ "$action" = "daemon-reload" ]; then
            xmg_svc_reload_manager
            return 0
        fi
        [ -n "$service" ] || return 2

        case "$action" in
            start|stop|restart|reload|enable|disable)
                xmg_svc_do "$action" "$service"
                ;;
            status)
                xmg_svc_status "$service"
                ;;
            is-active)
                xmg_svc_is_active "$service"
                ;;
            is-enabled)
                xmg_svc_is_enabled "$service"
                ;;
            *)
                return 2
                ;;
        esac
    }
fi
