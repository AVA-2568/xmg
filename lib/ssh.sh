#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# ssh.sh - XMG SSH 安全加固模块
#
# 说明：
#   - 提供 SSH 端口修改、禁用密码登录、fail2ban 防爆破
#   - OpenSSH >= 8.2（支持 Include）时写入 /etc/ssh/sshd_config.d/00-xmg.conf
#     使用 00- 前缀：sshd 取第一个出现的值，需排在 cloud-init 的 50-*.conf 之前
#   - 旧版 OpenSSH 直接备份并 sed 修改主配置
#   - 所有变更先 sshd -t 校验，失败自动回滚，不 restart
#

# ssh.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ssh.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_SSH_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_SSH_SH_LOADED=1

# XMG_MENU_LABEL: SSH 安全

# ===== 默认配置 =====
XMG_SSH_CONFIG="${XMG_SSH_CONFIG:-/etc/ssh/sshd_config}"
XMG_SSH_DROPIN_CONF="${XMG_SSH_DROPIN_CONF:-/etc/ssh/sshd_config.d/00-xmg-security.conf}"
XMG_SSH_F2B_JAIL_CONF="${XMG_SSH_F2B_JAIL_CONF:-/etc/fail2ban/jail.d/xmg-sshd.conf}"

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

# ===== 基础辅助 =====

xmg_sshd_bin() {
    if xmg_cmd_exists sshd; then
        command -v sshd
        return 0
    fi
    if [ -x /usr/sbin/sshd ]; then
        printf '/usr/sbin/sshd\n'
        return 0
    fi
    return 1
}

# sshd 服务名：Debian 为 ssh.service（sshd 别名），Ubuntu 为 ssh.service
xmg_ssh_service_name() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
        printf 'sshd'
    else
        printf 'ssh'
    fi
}

# OpenSSH >= 8.2 支持 Include 指令（sshd_config.d 生效的前提）
xmg_ssh_supports_include() {
    grep -qiE '^[[:space:]]*Include[[:space:]]+' "$XMG_SSH_CONFIG" 2>/dev/null
}

# 备份文件到 $XMG_BACKUP_DIR/ssh/
xmg_ssh_backup_file() {
    local file="$1"
    local dir="$XMG_BACKUP_DIR/ssh"

    [ -e "$file" ] || return 0

    mkdir -p "$dir" || return 1
    cp -a -- "$file" "$dir/$(basename "$file").$(date '+%Y%m%d-%H%M%S').bak"
}

# 读取当前生效配置：优先 sshd -T（实际生效值），失败回退配置文件 grep
xmg_ssh_effective() {
    local key="$1"
    local sshd_bin=""
    local val=""

    if sshd_bin="$(xmg_sshd_bin)"; then
        val="$("$sshd_bin" -T 2>/dev/null | awk -v k="$key" '$1 == k {print $2; exit}')"
        [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
    fi

    # 回退：配置文件中第一个出现的值（sshd 语义：第一个生效）
    val="$(awk -v k="$key" 'tolower($1) == tolower(k) {print $2; exit}' "$XMG_SSH_CONFIG" 2>/dev/null)"
    printf '%s\n' "${val:-未设置(默认)}"
}

# 写入配置项（key value...），自动选择 drop-in 或主文件
# drop-in 模式：主配置不动，校验失败整体删除 drop-in 即可恢复
# 旧版模式：先写临时副本并 sshd -t -f 校验，通过才替换主配置，任何情况下不落坏配置
xmg_ssh_set_conf() {
    local key="$1"
    shift
    local value="$*"

    if xmg_ssh_supports_include; then
        mkdir -p "$(dirname "$XMG_SSH_DROPIN_CONF")"
        touch "$XMG_SSH_DROPIN_CONF"
        # 删除本文件内同 key 旧行
        sed -i "/^[[:space:]]*${key}[[:space:]]/Id" "$XMG_SSH_DROPIN_CONF"
        printf '%s %s\n' "$key" "$value" >> "$XMG_SSH_DROPIN_CONF"
        xmg_info "已写入 $XMG_SSH_DROPIN_CONF: $key $value"
        return 0
    fi

    # 旧版 OpenSSH：临时副本上改，校验通过才替换主配置
    local sshd_bin=""
    local tmp_conf=""

    if ! sshd_bin="$(xmg_sshd_bin)"; then
        xmg_error "未找到 sshd 二进制，无法校验新配置"
        return 1
    fi

    tmp_conf="$(mktemp)" || return 1

    grep -viE "^[[:space:]]*${key}[[:space:]]+" "$XMG_SSH_CONFIG" > "$tmp_conf" || true
    printf '%s %s\n' "$key" "$value" >> "$tmp_conf"

    if "$sshd_bin" -t -f "$tmp_conf" 2>/dev/null; then
        xmg_ssh_backup_file "$XMG_SSH_CONFIG"
        cat "$tmp_conf" > "$XMG_SSH_CONFIG"
        rm -f "$tmp_conf"
        xmg_info "已写入 $XMG_SSH_CONFIG: $key $value"
        return 0
    fi

    rm -f "$tmp_conf"
    xmg_error "新配置校验失败 (sshd -t)，主配置未改动"
    return 1
}

# 配置校验 + 重启 sshd
# drop-in 模式下校验失败自动删除 drop-in 恢复原状；
# 旧版模式在写入阶段已保证主配置有效，此处仅防御 drop-in 场景
xmg_ssh_apply() {
    local sshd_bin=""
    local svc=""

    if ! sshd_bin="$(xmg_sshd_bin)"; then
        xmg_error "未找到 sshd 二进制"
        return 1
    fi

    if ! "$sshd_bin" -t 2>/dev/null; then
        xmg_error "sshd 配置校验失败 (sshd -t)，正在回滚"
        if [ -f "${XMG_SSH_DROPIN_CONF}" ]; then
            rm -f "$XMG_SSH_DROPIN_CONF"
        fi
        return 1
    fi

    if ! xmg_cmd_exists systemctl; then
        xmg_warn "非 systemd 环境，请手动重启 sshd 生效"
        return 0
    fi

    svc="$(xmg_ssh_service_name)"
    if systemctl restart "$svc" 2>/dev/null; then
        xmg_info "sshd 已重启 ($svc)"
        return 0
    fi

    xmg_error "sshd 重启失败，请立即检查: systemctl status $svc"
    return 1
}

# ===== 查看配置 =====

xmg_ssh_show() {
    echo "===== SSH 当前配置 ====="
    printf '端口                  : %s\n' "$(xmg_ssh_effective port)"
    printf '密码登录              : %s\n' "$(xmg_ssh_effective passwordauthentication)"
    printf 'root 登录策略         : %s\n' "$(xmg_ssh_effective permitrootlogin)"
    printf '配置文件              : %s\n' "$XMG_SSH_CONFIG"
    [ -f "$XMG_SSH_DROPIN_CONF" ] && printf 'XMG drop-in           : %s\n' "$XMG_SSH_DROPIN_CONF"
    echo

    echo "===== 密钥状态 ====="
    if [ -s /root/.ssh/authorized_keys ]; then
        printf 'root authorized_keys  : 已配置 (%s 个密钥)\n' "$(grep -c -E '^(ssh|ecdsa)' /root/.ssh/authorized_keys)"
    else
        printf 'root authorized_keys  : 未配置或为空\n'
    fi
    echo

    echo "===== fail2ban ====="
    if xmg_cmd_exists fail2ban-client; then
        fail2ban-client status sshd 2>/dev/null || echo "sshd jail 未启用"
    else
        echo "未安装"
    fi
}

# ===== 修改端口 =====

xmg_ssh_change_port() {
    xmg_require_root

    local port=""
    local cur_port=""

    cur_port="$(xmg_ssh_effective port)"

    printf "当前 SSH 端口: %s\n" "$cur_port"
    printf "请输入新端口 (1-65535，建议 1024 以上): "
    read -r port || return 1

    case "$port" in
        ''|*[!0-9]*)
            xmg_warn "端口无效"
            return 1
            ;;
    esac

    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        xmg_warn "端口范围应为 1-65535"
        return 1
    fi

    if [ "$port" = "$cur_port" ]; then
        xmg_warn "新端口与当前端口相同"
        return 1
    fi

    xmg_warn "修改端口前请确认:"
    xmg_warn "  1. 新端口未被占用"
    xmg_warn "  2. 云平台安全组已放行新端口"
    xmg_warn "  3. 修改后保持当前会话，新开终端验证后再断开"

    if ! xmg_confirm "确认修改 SSH 端口为 $port?"; then
        xmg_info "已取消"
        return 0
    fi

    # 先放行新端口（UFW 启用时），防锁死
    if xmg_cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port/tcp" comment 'XMG SSH new' \
            && xmg_info "已放行 $port/tcp" \
            || xmg_warn "放行 $port/tcp 失败，请检查云安全组后再继续"
    fi

    xmg_ssh_set_conf Port "$port"

    if ! xmg_ssh_apply; then
        return 1
    fi

    echo
    xmg_info "SSH 端口已修改为: $port"
    xmg_warn "请勿关闭当前会话！新开终端测试: ssh -p $port user@host"
    xmg_warn "确认新端口可登录后，可删除旧端口放行规则"
}

# ===== 禁用 / 恢复密码登录 =====

xmg_ssh_disable_password() {
    xmg_require_root

    if [ ! -s /root/.ssh/authorized_keys ]; then
        xmg_error "root 尚未配置 SSH 密钥 (authorized_keys 为空)"
        xmg_warn "禁用密码登录前必须先配置密钥，否则会锁死"
        return 1
    fi

    xmg_warn "将禁用密码登录（仅允许密钥登录）"
    xmg_warn "请确认你已经用密钥成功登录过本机"

    if ! xmg_confirm "确认禁用密码登录?"; then
        xmg_info "已取消"
        return 0
    fi

    xmg_ssh_set_conf PasswordAuthentication no
    xmg_ssh_set_conf PermitRootLogin prohibit-password

    if ! xmg_ssh_apply; then
        return 1
    fi

    xmg_info "密码登录已禁用（仅密钥登录）"
    xmg_warn "请保持当前会话，新开终端验证密钥登录正常"
}

xmg_ssh_enable_password() {
    xmg_require_root

    xmg_warn "将恢复密码登录（降低安全性）"

    if ! xmg_confirm "确认恢复密码登录?"; then
        xmg_info "已取消"
        return 0
    fi

    xmg_ssh_set_conf PasswordAuthentication yes
    xmg_ssh_set_conf PermitRootLogin yes

    if ! xmg_ssh_apply; then
        return 1
    fi

    xmg_info "密码登录已恢复"
}

# ===== fail2ban =====

xmg_ssh_fail2ban_install() {
    xmg_require_root

    if ! xmg_cmd_exists apt-get; then
        xmg_die "本模块仅支持 apt 系 (Debian/Ubuntu)"
    fi

    if xmg_cmd_exists fail2ban-client; then
        xmg_info "fail2ban 已安装"
    else
        xmg_info "安装 fail2ban（Debian 12 需 python3-systemd 支持 journal 后端）"
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get install -y fail2ban python3-systemd; then
            xmg_error "fail2ban 安装失败，可先执行 apt-get update 后重试"
            return 1
        fi
    fi

    # sshd jail：backend=systemd 避免 Debian 12 无 /var/log/auth.log 时起不来
    mkdir -p "$(dirname "$XMG_SSH_F2B_JAIL_CONF")"
    cat > "$XMG_SSH_F2B_JAIL_CONF" <<'EOF'
# XMG: sshd 防爆破（由 xmg ssh 生成）
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
EOF

    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    if fail2ban-client status sshd >/dev/null 2>&1; then
        xmg_info "fail2ban sshd jail 已启用（5 次失败封 1 小时，累犯递增最长 1 周）"
        fail2ban-client status sshd
    else
        xmg_error "sshd jail 未正常运行，请检查: systemctl status fail2ban"
        return 1
    fi
}

xmg_ssh_fail2ban_status() {
    if ! xmg_cmd_exists fail2ban-client; then
        xmg_warn "fail2ban 未安装，请先执行菜单 5"
        return 1
    fi

    echo "== fail2ban 总览 =="
    fail2ban-client status 2>/dev/null || true
    echo
    echo "== sshd jail =="
    fail2ban-client status sshd 2>/dev/null || true
}

# ===== 菜单 =====

xmg_ssh_menu() {
    local choice=""

    while true; do
        clear
        echo "========== SSH 安全 =========="
        echo "1. 查看 SSH 当前配置"
        echo "2. 修改 SSH 端口"
        echo "3. 禁用密码登录（仅密钥）"
        echo "4. 恢复密码登录"
        echo "5. fail2ban 防爆破一键部署"
        echo "6. 查看 fail2ban 封禁状态"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - 修改端口/禁密码后请保持当前会话，新开终端验证成功再断开"
        echo "  - 禁用密码登录前必须已配置 SSH 密钥"
        echo "  - 配置变更先经 sshd -t 校验，失败自动回滚"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                clear
                xmg_ssh_show
                xmg_pause
                ;;
            2)
                xmg_ssh_change_port
                xmg_pause
                ;;
            3)
                xmg_ssh_disable_password
                xmg_pause
                ;;
            4)
                xmg_ssh_enable_password
                xmg_pause
                ;;
            5)
                xmg_ssh_fail2ban_install
                xmg_pause
                ;;
            6)
                clear
                xmg_ssh_fail2ban_status
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
    xmg_ssh_menu
fi
