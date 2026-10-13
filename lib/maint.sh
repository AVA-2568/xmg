#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# maint.sh - XMG 系统维护模块
#
# 说明：
#   - 一键系统更新、深度磁盘清理（journal 限容 + apt/dnf 缓存 + 残留配置 + 旧日志）、流量统计 (vnstat)
#   - 进程与资源异常排查 (TOP 5 / 僵尸进程)、一键释放内存缓存 (drop_caches)
#   - 兼容 apt 系 (Debian/Ubuntu)、dnf/yum (RHEL/CentOS/Rocky/AlmaLinux)、pacman (Arch)、apk (Alpine)
#

# maint.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "maint.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_MAINT_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 1
fi
XMG_MAINT_SH_LOADED=1

# XMG_MENU_LABEL: 系统维护

# ===== 默认配置 =====
XMG_MAINT_JOURNAL_MAX="${XMG_MAINT_JOURNAL_MAX:-50M}"
XMG_MAINT_JOURNALD_CONF="${XMG_MAINT_JOURNALD_CONF:-/etc/systemd/journald.conf.d/00-xmg.conf}"

# ===== 依赖 common.sh 的兜底 =====

if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info()  { printf '[INFO] %s\n' "$*"; }
fi
if ! declare -F xmg_warn >/dev/null 2>&1; then
    xmg_warn()  { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_error >/dev/null 2>&1; then
    xmg_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! declare -F xmg_die >/dev/null 2>&1; then
    xmg_die()   { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
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
        printf '\n按 Enter 返回...'
        read -r _ || true
    }
fi

# ===== 一键系统更新 =====

xmg_maint_update() {
    xmg_require_root

    xmg_warn "即将执行系统更新（可能耗时较长，内核更新后建议重启）"

    if ! xmg_confirm "确认执行系统更新?"; then
        xmg_info "已取消"
        return 0
    fi

    if xmg_cmd_exists apt-get; then
        export DEBIAN_FRONTEND=noninteractive

        if declare -F xmg_apt_wait_lock >/dev/null 2>&1; then
            xmg_apt_wait_lock 15 || true
        fi
        xmg_info "apt-get update..."
        apt-get -o DPkg::Lock::Timeout=60 update || xmg_warn "apt-get update 存在错误（个别第三方源失败不影响主体）"

        if declare -F xmg_apt_wait_lock >/dev/null 2>&1; then
            xmg_apt_wait_lock 15 || true
        fi
        xmg_info "apt-get upgrade..."
        apt-get -o DPkg::Lock::Timeout=60 upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || {
            xmg_warn "upgrade 初次受阻，尝试自动解除死锁后重试一次..."
            if declare -F xmg_apt_unlock_and_repair >/dev/null 2>&1; then
                xmg_apt_unlock_and_repair || true
            fi
            apt-get -o DPkg::Lock::Timeout=60 upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || xmg_error "apt-get upgrade 失败"
        }

        xmg_info "apt-get autoremove..."
        apt-get autoremove --purge -y >/dev/null 2>&1 || true

        if [ -f /var/run/reboot-required ]; then
            xmg_warn "系统提示需要重启才能完成更新 (reboot-required)"
        fi
    elif xmg_cmd_exists dnf; then
        xmg_info "dnf upgrade..."
        dnf upgrade -y || xmg_error "dnf upgrade 失败"
        xmg_warn "如更新了内核，请重启: reboot"
    elif xmg_cmd_exists yum; then
        xmg_info "yum update..."
        yum update -y || xmg_error "yum update 失败"
        xmg_warn "如更新了内核，请重启: reboot"
    elif xmg_cmd_exists pacman; then
        xmg_info "pacman -Syu..."
        pacman -Syu --noconfirm || xmg_error "pacman 升级失败"
    elif xmg_cmd_exists apk; then
        xmg_info "apk update && apk upgrade..."
        apk update && apk upgrade || xmg_error "apk upgrade 失败"
    else
        xmg_error "未检测到受支持的包管理器 (apt-get / dnf / yum / pacman / apk)"
        return 1
    fi

    xmg_info "系统更新完成"
}

# ===== 一键深度磁盘清理 =====

# journal 持久化限容，避免小盘被日志吃满
xmg_maint_journal_limit() {
    if ! xmg_cmd_exists journalctl; then
        return 0
    fi

    mkdir -p "$(dirname "$XMG_MAINT_JOURNALD_CONF")"
    cat > "$XMG_MAINT_JOURNALD_CONF" <<EOF
# XMG: journald 限容（由 xmg maint 生成）
[Journal]
SystemMaxUse=$XMG_MAINT_JOURNAL_MAX
EOF

    systemctl restart systemd-journald >/dev/null 2>&1 || true
    xmg_info "journald 已限容 $XMG_MAINT_JOURNAL_MAX: $XMG_MAINT_JOURNALD_CONF"
}

xmg_maint_clean() {
    xmg_require_root

    local before=""
    local after=""

    before="$(df -h / 2>/dev/null | awk 'NR==2 {print $3"/"$2" ("$5")"}')"

    echo "清理前磁盘 /: $before"
    echo

    if xmg_confirm "确认执行深度磁盘清理? (journal 限容 + 包缓存 + 残留配置 + 旧日志)"; then
        # 1. journal 限容与压缩
        if xmg_cmd_exists journalctl; then
            xmg_info "journal 压缩到 $XMG_MAINT_JOURNAL_MAX..."
            journalctl --vacuum-size="$XMG_MAINT_JOURNAL_MAX" 2>/dev/null | tail -1 || true
            xmg_maint_journal_limit
        fi

        # 2. 包管理器缓存与旧包清理
        if xmg_cmd_exists apt-get; then
            export DEBIAN_FRONTEND=noninteractive

            xmg_info "清理 apt 缓存..."
            apt-get clean
            apt-get autoclean -y >/dev/null 2>&1 || true

            xmg_info "清理孤立包 (autoremove)..."
            apt-get autoremove --purge -y || xmg_warn "autoremove 失败"

            # 清理已卸载包的残余配置文件 (状态为 rc 的包)
            if xmg_cmd_exists dpkg; then
                local rc_pkgs=""
                rc_pkgs="$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' || true)"
                if [ -n "$rc_pkgs" ]; then
                    xmg_info "清理残留配置包 (rc 状态)..."
                    # shellcheck disable=SC2086
                    dpkg --purge $rc_pkgs 2>/dev/null || true
                fi
            fi
        elif xmg_cmd_exists dnf; then
            xmg_info "清理 dnf 缓存..."
            dnf clean all || true
            dnf autoremove -y >/dev/null 2>&1 || true
        elif xmg_cmd_exists yum; then
            xmg_info "清理 yum 缓存..."
            yum clean all || true
            yum autoremove -y >/dev/null 2>&1 || true
        elif xmg_cmd_exists pacman; then
            xmg_info "清理 pacman 缓存..."
            pacman -Scc --noconfirm 2>/dev/null || true
        elif xmg_cmd_exists apk; then
            xmg_info "清理 apk 缓存..."
            apk cache clean 2>/dev/null || true
        fi

        # 3. /var/log 历史压缩日志清理 (*.gz, *.1, *.old)
        xmg_info "清理 /var/log 历史轮转归档文件..."
        find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" \) -delete 2>/dev/null || true

        # 4. /tmp 和 /var/tmp 临时文件清理 (超过 7 天未访问的文件)
        xmg_info "清理过期临时文件 (/tmp, /var/tmp)..."
        find /tmp /var/tmp -mindepth 1 -atime +7 -delete 2>/dev/null || true

        after="$(df -h / 2>/dev/null | awk 'NR==2 {print $3"/"$2" ("$5")"}')"
        echo
        echo "清理后磁盘 /: $after"
        xmg_info "深度磁盘清理完成"
    else
        xmg_info "已取消"
    fi
}

# ===== 流量统计 (vnstat) =====

xmg_maint_vnstat() {
    xmg_require_root

    if ! xmg_cmd_exists vnstat; then
        xmg_info "尝试安装 vnstat 流量统计工具..."
        if xmg_cmd_exists apt-get; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get -o DPkg::Lock::Timeout=60 install -y vnstat || { xmg_error "vnstat 安装失败，可先执行 apt-get update 后重试"; return 1; }
        elif xmg_cmd_exists dnf; then
            dnf install -y epel-release 2>/dev/null || true
            dnf install -y vnstat || { xmg_error "vnstat 安装失败"; return 1; }
        elif xmg_cmd_exists yum; then
            yum install -y epel-release 2>/dev/null || true
            yum install -y vnstat || { xmg_error "vnstat 安装失败"; return 1; }
        elif xmg_cmd_exists pacman; then
            pacman -Sy --noconfirm vnstat || { xmg_error "vnstat 安装失败"; return 1; }
        elif xmg_cmd_exists apk; then
            apk add vnstat || { xmg_error "vnstat 安装失败"; return 1; }
        else
            xmg_warn "未能识别当前包管理器，请手动安装 vnstat"
            return 1
        fi
        xmg_info "vnstat 安装成功，守护进程已初始化"
    fi

    if xmg_cmd_exists systemctl; then
        systemctl enable --now vnstat >/dev/null 2>&1 || true
        if ! systemctl is-active --quiet vnstat 2>/dev/null; then
            xmg_warn "vnstat 服务未运行，尝试启动..."
            systemctl start vnstat 2>/dev/null || true
        fi
    fi

    echo
    echo "== 本月流量统计 =="
    local v_out=""
    v_out="$(vnstat -m 2>&1 || vnstat 2>&1 || true)"
    if echo "$v_out" | grep -qiE "(not enough|no interface|created)"; then
        echo "$v_out"
        echo
        xmg_info "vnstat 刚刚部署或采样库初始化中，系统将在后台持续采样（通常 5~10 分钟后生成首批统计）"
    else
        echo "$v_out"
        xmg_info "vnstat 运行正常（数据从守护进程启动时刻开始累计）"
    fi
}

# ===== 进程与资源异常排查 =====

xmg_maint_process_inspect() {
    echo "==================== 进程与系统资源排查 ===================="
    echo
    echo "== 系统负载 (Load Average) =="
    uptime 2>/dev/null || true
    echo

    echo "== 内存状态 (Free) =="
    free -h 2>/dev/null || true
    echo

    echo "== CPU 占用最高 TOP 5 进程 =="
    ps -eo pid,ppid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -n 6 || true
    echo

    echo "== 内存占用最高 TOP 5 进程 =="
    ps -eo pid,ppid,user,%mem,%cpu,comm --sort=-%mem 2>/dev/null | head -n 6 || true
    echo

    echo "== 僵尸进程 (Zombie) 排查 =="
    local zombies=""
    zombies="$(ps -eo stat,pid,ppid,comm 2>/dev/null | grep -E '^[Zz]' || true)"
    if [ -n "$zombies" ]; then
        xmg_warn "检测到系统存在僵尸进程:"
        echo "$zombies"
    else
        xmg_info "系统无残留僵尸进程 (0 zombies)"
    fi
    echo
}

# ===== 一键释放内存缓存 =====

xmg_maint_drop_caches() {
    xmg_require_root

    echo "== 清理前内存状态 =="
    free -h 2>/dev/null || true
    echo

    if xmg_confirm "确认同步磁盘并释放系统缓存? (sync && drop_caches)"; then
        xmg_info "正在同步文件系统缓存并触发回收 (drop_caches)..."
        sync
        if [ -w /proc/sys/vm/drop_caches ]; then
            echo 3 > /proc/sys/vm/drop_caches
            xmg_info "缓存已释放"
        else
            xmg_warn "/proc/sys/vm/drop_caches 不可写（容器环境常见），已跳过"
        fi
        echo
        echo "== 清理后内存状态 =="
        free -h 2>/dev/null || true
    else
        xmg_info "已取消"
    fi
}

# ===== 磁盘占用概览 =====

xmg_maint_disk_overview() {
    echo "== 磁盘分区 =="
    df -h 2>/dev/null || true
    echo

    echo "== journal 占用 =="
    journalctl --disk-usage 2>/dev/null || echo "journalctl 不可用"
    echo

    echo "== apt/包缓存目录占用 =="
    if [ -d /var/cache/apt ]; then
        du -sh /var/cache/apt 2>/dev/null || true
    elif [ -d /var/cache/dnf ]; then
        du -sh /var/cache/dnf 2>/dev/null || true
    elif [ -d /var/cache/yum ]; then
        du -sh /var/cache/yum 2>/dev/null || true
    else
        echo "无包管理器缓存目录"
    fi
    echo

    echo "== /opt/xmg 占用 =="
    if [ -d "$XMG_HOME" ]; then
        du -sh "$XMG_HOME" 2>/dev/null || true
    else
        echo "$XMG_HOME 不存在"
    fi
}

# ===== 菜单 =====

xmg_maint_menu() {
    local choice=""

    while true; do
        clear
        echo "========== 系统维护 =========="
        echo "1. 一键系统更新"
        echo "2. 一键深度磁盘清理 (journal 限容 + 包缓存 + 残留配置 + 旧日志)"
        echo "3. 流量统计 (vnstat)"
        echo "4. 磁盘占用概览"
        echo "5. 进程与资源异常排查 (TOP 5 负载 / 僵尸进程)"
        echo "6. 一键释放内存缓存 (drop_caches)"
        echo "7. 一键解除 apt/dpkg 锁并修复状态 (处理 lock-frontend 死锁卡死)"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - 深度磁盘清理会同时把 journal 持久化限容到 $XMG_MAINT_JOURNAL_MAX 并彻底清理包残留"
        echo "  - 系统更新后如提示 reboot-required 建议尽快重启"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                clear
                xmg_maint_update
                xmg_pause
                ;;
            2)
                clear
                xmg_maint_clean
                xmg_pause
                ;;
            3)
                clear
                xmg_maint_vnstat
                xmg_pause
                ;;
            4)
                clear
                xmg_maint_disk_overview
                xmg_pause
                ;;
            5)
                clear
                xmg_maint_process_inspect
                xmg_pause
                ;;
            6)
                clear
                xmg_maint_drop_caches
                xmg_pause
                ;;
            7)
                clear
                if declare -F xmg_apt_unlock_and_repair >/dev/null 2>&1; then
                    xmg_apt_unlock_and_repair
                else
                    xmg_warn "当前函数不可用"
                fi
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
    xmg_maint_menu
fi
