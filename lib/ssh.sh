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

# XMG_MENU_LABEL: SSH 安全加固

# ===== 默认配置 =====
XMG_HOME="${XMG_HOME:-/opt/xmg}"
XMG_BACKUP_DIR="${XMG_BACKUP_DIR:-$XMG_HOME/backups}"
XMG_SSH_CONFIG="${XMG_SSH_CONFIG:-/etc/ssh/sshd_config}"
XMG_SSH_DROPIN_CONF="${XMG_SSH_DROPIN_CONF:-/etc/ssh/sshd_config.d/00-xmg-security.conf}"
XMG_SSH_F2B_JAIL_CONF="${XMG_SSH_F2B_JAIL_CONF:-/etc/fail2ban/jail.d/xmg-sshd.conf}"
XMG_SSH_SOCKET_DROPIN_CONF="${XMG_SSH_SOCKET_DROPIN_CONF:-/etc/systemd/system/ssh.socket.d/listen.conf}"
XMG_SSH_AUTH_KEYS="${XMG_SSH_AUTH_KEYS:-}"

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

# sshd 服务名：Debian/Ubuntu 为 ssh.service，Alpine/RHEL 为 sshd
xmg_ssh_service_name() {
    xmg_svc_name ssh
}

# OpenSSH >= 8.2 支持 Include 指令（sshd_config.d 生效的前提）
xmg_ssh_supports_include() {
    grep -qiE '^[[:space:]]*Include[[:space:]]+' "$XMG_SSH_CONFIG" 2>/dev/null
}

# 备份文件到 $XMG_BACKUP_DIR/ssh/（自动按 XMG_BACKUP_KEEP 轮转清理旧备份）
xmg_ssh_backup_file() {
    local file="$1"
    local dir="${XMG_BACKUP_DIR:-${XMG_HOME:-/opt/xmg}/backups}/ssh"

    [ -e "$file" ] || return 0

    mkdir -p "$dir" 2>/dev/null || return 1
    local bname="${file##*/}"
    local base_bak="$dir/${bname}.$(date '+%Y%m%d-%H%M%S').$$"
    local _seq=0
    local bak_file="${base_bak}_0.bak"
    while [ -e "$bak_file" ]; do
        _seq=$((_seq + 1))
        bak_file="${base_bak}_${_seq}.bak"
    done
    cp -a -- "$file" "$bak_file" || return 1

    local keep="${XMG_BACKUP_KEEP:-5}"
    case "$keep" in ''|*[!0-9]*) keep=5 ;; esac
    if [ "$keep" -gt 0 ]; then
        local -a baks=()
        local _f=""
        for _f in "$dir/${bname}".*.bak; do
            [ -f "$_f" ] && baks+=("$_f")
        done
        local total="${#baks[@]}"
        if [ "$total" -gt "$keep" ]; then
            local del_cnt=$((total - keep)) idx=0
            while [ "$idx" -lt "$del_cnt" ]; do
                rm -f "${baks[$idx]}" 2>/dev/null || true
                idx=$((idx + 1))
            done
        fi
    fi
    return 0
}

# 按 sshd 语义在配置树里查找键值：主配置顺序读，Include 在出现位置就地展开，
# 首个命中即返回。
#   不能用「先查主配置、再查 drop-in」：sshd 是流式读取，主配置里写在 Include
#   之后的 Port 已被 drop-in 覆盖，取它会得到与真实监听不符的端口，
#   防火墙据此只放行旧端口 → 默认 DROP 一开即失联。
_xmg_ssh_conf_lookup() {
    local key="$1"
    local main="${XMG_SSH_CONFIG:-/etc/ssh/sshd_config}"
    [ -r "$main" ] || return 1
    _xmg_ssh_conf_lookup_in "$main" "$key" 0
}

# $3 = 递归深度，防止 Include 成环
_xmg_ssh_conf_lookup_in() {
    local file="$1" key="$2" depth="${3:-0}"
    local line="" pat="" f="" val="" k=""
    local -a inc=()

    [ "$depth" -le 8 ] || return 1
    [ -r "$file" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            ''|'#'*) continue ;;
        esac

        case "$line" in
            [Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]*)
                pat="${line#*[[:space:]]}"
                pat="${pat%%[[:space:]]*}"
                case "$pat" in
                    '') continue ;;
                    /*) ;;
                    [A-Za-z]:[\\/]*) ;;   # 盘符路径（Git Bash 等环境），不拼 /etc/ssh
                    *) pat="/etc/ssh/$pat" ;;
                esac
                # 需要通配符展开，故意不加引号
                # shellcheck disable=SC2086
                for f in $pat; do
                    [ -r "$f" ] || continue
                    val="$(_xmg_ssh_conf_lookup_in "$f" "$key" $((depth + 1)) 2>/dev/null || true)"
                    [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
                done
                continue
                ;;
        esac

        k="${line%%[[:space:]]*}"
        if [ "${k,,}" = "${key,,}" ]; then
            val="${line#*[[:space:]]}"
            val="${val%%[[:space:]]*}"
            [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
        fi
    done < "$file"

    return 1
}

# 读取当前生效配置：优先 sshd -T（实际生效值），失败回退配置文件（含 Include）
xmg_ssh_effective() {
    local key="$1"
    local sshd_bin=""
    local val=""

    if sshd_bin="$(xmg_sshd_bin)"; then
        val="$("$sshd_bin" -T 2>/dev/null | awk -v k="$key" '$1 == k {print $2; exit}')"
        [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
    fi

    val="$(_xmg_ssh_conf_lookup "$key" 2>/dev/null || true)"
    printf '%s\n' "${val:-未设置(默认)}"
}

# 获取当前生效的 SSH 端口（纯数字，无效回退 22）
xmg_ssh_get_port() {
    local val=""
    val="$(xmg_ssh_effective port 2>/dev/null || true)"
    case "$val" in
        ''|*[!0-9]*)
            printf '22\n'
            ;;
        *)
            if [ "$val" -ge 1 ] && [ "$val" -le 65535 ]; then
                printf '%s\n' "$val"
            else
                printf '22\n'
            fi
            ;;
    esac
}

# 检测是否存在 ssh.socket 单元 (Ubuntu 22.10+ / 24.04 特性)
xmg_ssh_has_socket() {
    if [ -n "${XMG_SSH_HAS_SOCKET:-}" ]; then
        [ "$XMG_SSH_HAS_SOCKET" = "1" ] && return 0 || return 1
    fi

    if xmg_cmd_exists systemctl; then
        if systemctl cat ssh.socket >/dev/null 2>&1; then
            return 0
        fi
        if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
            return 0
        fi
    fi

    if [ -f /lib/systemd/system/ssh.socket ] || [ -f /usr/lib/systemd/system/ssh.socket ] || [ -f /etc/systemd/system/ssh.socket ]; then
        return 0
    fi

    return 1
}

# 配置 ssh.socket override 以覆盖默认监听端口
xmg_ssh_configure_socket_port() {
    local port="$1"
    local conf="${XMG_SSH_SOCKET_DROPIN_CONF:-/etc/systemd/system/ssh.socket.d/listen.conf}"

    mkdir -p "$(dirname "$conf")" || return 1
    cat > "$conf" <<EOF
[Socket]
ListenStream=
ListenStream=$port
EOF
    xmg_info "已配置 ssh.socket override: $conf (ListenStream=$port)"
}

# 检查 authorized_keys 是否有效（文件存在、非空、且包含有效公钥）
xmg_ssh_check_authorized_keys() {
    local auth_file="${XMG_SSH_AUTH_KEYS:-}"
    if [ -z "$auth_file" ]; then
        if [ -s "${HOME:-/root}/.ssh/authorized_keys" ]; then
            auth_file="${HOME:-/root}/.ssh/authorized_keys"
        elif [ -s "/root/.ssh/authorized_keys" ]; then
            auth_file="/root/.ssh/authorized_keys"
        elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            local _sudo_home=""
            _sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
            if [ -n "$_sudo_home" ] && [ -s "${_sudo_home}/.ssh/authorized_keys" ]; then
                auth_file="${_sudo_home}/.ssh/authorized_keys"
            else
                auth_file="${HOME:-/root}/.ssh/authorized_keys"
            fi
        else
            auth_file="${HOME:-/root}/.ssh/authorized_keys"
        fi
    fi

    if [ ! -f "$auth_file" ] || [ ! -s "$auth_file" ]; then
        xmg_error "SSH 授权密钥文件不存在或为空 ($auth_file)"
        xmg_warn "禁用密码登录前必须先配置公钥，否则将导致无法远程登录！"
        return 1
    fi

    # 检查是否包含有效公钥（排除空行和以 # 开头的注释）
    local valid_keys
    valid_keys="$(grep -vE '^[[:space:]]*(#|$)' "$auth_file" | grep -E '^(ssh-|ecdsa-|sk-)' || true)"
    if [ -z "$valid_keys" ]; then
        xmg_error "$auth_file 中未检测到有效的 SSH 公钥（仅有注释或格式无效）"
        xmg_warn "禁用密码登录前必须配置至少一个有效公钥，防止被锁死！"
        return 1
    fi

    return 0
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
        # 删除本文件内同 key 旧行（大小写不敏感）
        # 用 grep -v 重写而非 `sed -i .../Id`：I 修饰符是 GNU 扩展，
        # BusyBox sed 不认，Alpine 上会报错并留下重复行，sshd 取第一条 → 改端口不生效
        if [ -s "$XMG_SSH_DROPIN_CONF" ]; then
            local _dropin_tmp="${XMG_SSH_DROPIN_CONF}.tmp.$$"
            grep -viE "^[[:space:]]*${key}[[:space:]]" "$XMG_SSH_DROPIN_CONF" > "$_dropin_tmp" 2>/dev/null || true
            # cat 回写而非 mv：保留原文件的 inode 与权限位
            cat "$_dropin_tmp" > "$XMG_SSH_DROPIN_CONF" 2>/dev/null || true
            rm -f "$_dropin_tmp" 2>/dev/null || true
        fi
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

# 配置校验 + 重启 sshd / ssh.socket
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

    if xmg_ssh_has_socket; then
        local target_port
        target_port="$(xmg_ssh_get_port)"
        xmg_ssh_configure_socket_port "$target_port"
    fi

    if ! xmg_init_use_systemd_units && ! xmg_svc_supported; then
        xmg_warn "非 systemd / OpenRC 环境，请手动重启 sshd 生效"
        return 0
    fi

    if xmg_ssh_has_socket && xmg_init_use_systemd_units; then
        systemctl daemon-reload 2>/dev/null || true
        if systemctl restart ssh.socket 2>/dev/null; then
            xmg_info "ssh.socket 已重启"
            systemctl restart ssh 2>/dev/null || true
            return 0
        fi
    fi

    svc="$(xmg_ssh_service_name)"
    if xmg_systemctl restart "$svc" 2>/dev/null; then
        xmg_info "sshd 已重启 ($svc)"
        return 0
    fi

    xmg_error "sshd 重启失败，请立即检查: $( [ "$XMG_INIT_SYSTEM" = "openrc" ] && echo "rc-service $svc status" || echo "systemctl status $svc" )"
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
    [ -f "$XMG_SSH_SOCKET_DROPIN_CONF" ] && printf 'ssh.socket drop-in    : %s\n' "$XMG_SSH_SOCKET_DROPIN_CONF"
    echo

    echo "===== 密钥状态 ====="
    local auth_file="${XMG_SSH_AUTH_KEYS:-}"
    if [ -z "$auth_file" ]; then
        if [ -s "${HOME:-/root}/.ssh/authorized_keys" ]; then
            auth_file="${HOME:-/root}/.ssh/authorized_keys"
        elif [ -s "/root/.ssh/authorized_keys" ]; then
            auth_file="/root/.ssh/authorized_keys"
        elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            local _sudo_home=""
            _sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
            if [ -n "$_sudo_home" ] && [ -s "${_sudo_home}/.ssh/authorized_keys" ]; then
                auth_file="${_sudo_home}/.ssh/authorized_keys"
            else
                auth_file="${HOME:-/root}/.ssh/authorized_keys"
            fi
        else
            auth_file="${HOME:-/root}/.ssh/authorized_keys"
        fi
    fi

    if [ -s "$auth_file" ] && grep -vE '^[[:space:]]*(#|$)' "$auth_file" | grep -qE '^(ssh-|ecdsa-|sk-)'; then
        printf 'authorized_keys       : 已配置 (%s 个有效密钥)\n' "$(grep -vE '^[[:space:]]*(#|$)' "$auth_file" | grep -c -E '^(ssh-|ecdsa-|sk-)')"
    else
        printf 'authorized_keys       : 未配置或无有效公钥\n'
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

# 等待端口进入监听：0=在听 / 1=超时未在听 / 2=无探测工具（无法判定）
_xmg_ssh_port_listening() {
    local port="$1"
    local i=0
    local cmd=""

    if command -v ss >/dev/null 2>&1; then
        cmd="ss -ltn"
    elif command -v netstat >/dev/null 2>&1; then
        cmd="netstat -ltn"
    elif [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then
        local hex_port=""
        hex_port="$(printf '%04X' "$port" 2>/dev/null || true)"
        if [ -n "$hex_port" ]; then
            for ((i = 0; i < 6; i++)); do
                if awk -v hp=":${hex_port}$" '$2 ~ hp && $4 == "0A" {found=1; exit 0} END {exit(found ? 0 : 1)}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
                    return 0
                fi
                sleep 0.2 2>/dev/null || sleep 1
            done
            return 1
        fi
        return 2
    else
        return 2
    fi

    for ((i = 0; i < 6; i++)); do
        # shellcheck disable=SC2086
        if $cmd 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# 还原 SSH 端口配置并重启（change_port 失败路径专用）
#   drop-in 原本不存在时要删掉，否则残留的 Port 行会继续生效。
#   每个文件单独校验，任一失败都不假装成功 —— 回滚失败时用户只剩当前会话，
#   必须给出可执行的急救指令。
_xmg_ssh_restore_conf() {
    local bak_dropin="$1" bak_main="$2"
    local ok=1

    if [ -n "$bak_dropin" ] && [ -f "$bak_dropin" ]; then
        cp -a "$bak_dropin" "$XMG_SSH_DROPIN_CONF" 2>/dev/null || ok=0
    elif [ -f "$XMG_SSH_DROPIN_CONF" ]; then
        rm -f "$XMG_SSH_DROPIN_CONF" 2>/dev/null || ok=0
    fi

    if [ -n "$bak_main" ] && [ -f "$bak_main" ]; then
        cp -a "$bak_main" "$XMG_SSH_CONFIG" 2>/dev/null || ok=0
    fi

    if [ "$ok" -ne 1 ]; then
        xmg_error "回滚未完全成功：部分配置文件未能还原"
        xmg_error "请勿断开当前会话！立即检查 $XMG_SSH_CONFIG 并手工重启 sshd"
        return 1
    fi

    if ! xmg_ssh_apply >/dev/null 2>&1; then
        xmg_error "配置已还原，但 sshd 未能启动"
        xmg_error "请勿断开当前会话！执行: systemctl start ssh（或 rc-service sshd start）"
        return 1
    fi

    xmg_warn "已还原 SSH 端口配置并重启 sshd"
    return 0
}

xmg_ssh_change_port() {
    xmg_require_root

    local port=""
    local cur_port=""

    cur_port="$(xmg_ssh_get_port)"

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

    # 先放行新端口（防火墙启用时），防锁死
    if xmg_cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port/tcp" comment 'XMG SSH new' \
            && xmg_info "已放行 $port/tcp" \
            || xmg_warn "放行 $port/tcp 失败，请检查云安全组后再继续"
    elif [ -r "${XMG_LIB_DIR:-/opt/xmg/lib}/firewall.sh" ]; then
        # iptables 后端（Alpine）：把新端口写入放行列表并立即生效
        # shellcheck source=/dev/null
        source "${XMG_LIB_DIR:-/opt/xmg/lib}/firewall.sh"
        xmg_firewall_allow_custom_port "$port" tcp >/dev/null 2>&1 \
            && xmg_info "已在新端口 $port/tcp 上放行（iptables 后端）" \
            || true
    fi

    # 改前留底：drop-in 与主配置都要备份。
    # 备份失败必须中止 —— 没有备份就改端口，失败时无从回滚；
    # 而把 bak 置空会让回滚退化成「删掉 drop-in」，等于静默恢复密码登录。
    local bak_dropin="" bak_main=""
    if [ -f "$XMG_SSH_DROPIN_CONF" ]; then
        bak_dropin="$(mktemp)" || bak_dropin=""
        if [ -z "$bak_dropin" ] || ! cp -a "$XMG_SSH_DROPIN_CONF" "$bak_dropin" 2>/dev/null; then
            rm -f "$bak_dropin" 2>/dev/null || true
            xmg_error "备份 $XMG_SSH_DROPIN_CONF 失败，已中止（无备份不可改端口）"
            return 1
        fi
    fi
    if [ -f "$XMG_SSH_CONFIG" ]; then
        bak_main="$(mktemp)" || bak_main=""
        if [ -z "$bak_main" ] || ! cp -a "$XMG_SSH_CONFIG" "$bak_main" 2>/dev/null; then
            rm -f "$bak_main" "$bak_dropin" 2>/dev/null || true
            xmg_error "备份 $XMG_SSH_CONFIG 失败，已中止（无备份不可改端口）"
            return 1
        fi
    fi

    if ! xmg_ssh_set_conf Port "$port"; then
        xmg_error "写入新端口失败，配置未改动"
        rm -f "$bak_dropin" "$bak_main" 2>/dev/null || true
        return 1
    fi

    if ! xmg_ssh_apply; then
        xmg_error "sshd 未能以新端口启动，正在回滚"
        _xmg_ssh_restore_conf "$bak_dropin" "$bak_main" || true
        rm -f "$bak_dropin" "$bak_main" 2>/dev/null || true
        return 1
    fi

    # 无法自动重启的环境（容器/无 init）不做监听验证：sshd 根本没重载，
    # 验证必然失败并把正确配置回滚掉。改为提示人工验证。
    if ! xmg_init_use_systemd_units && ! xmg_svc_supported; then
        rm -f "$bak_dropin" "$bak_main" 2>/dev/null || true
        echo
        xmg_info "SSH 端口配置已写入: $port"
        xmg_warn "本环境无法自动重启 sshd，配置尚未生效"
        xmg_warn "请手动重启后验证: ssh -p $port user@host"
        return 0
    fi

    # 重启成功不等于端口真的在听：端口被占用或绑定失败时 sshd 可能已退出
    local lrc=0
    _xmg_ssh_port_listening "$port" || lrc=$?
    if [ "$lrc" -eq 1 ]; then
        xmg_error "新端口 $port 未进入监听，正在回滚 SSH 端口配置"
        _xmg_ssh_restore_conf "$bak_dropin" "$bak_main" || true
        rm -f "$bak_dropin" "$bak_main" 2>/dev/null || true
        return 1
    fi

    rm -f "$bak_dropin" "$bak_main" 2>/dev/null || true

    # 若已部署 XMG 的 fail2ban sshd 规则，自动同步监控端口并重载，避免改端口后防爆破失效
    if [ -f "${XMG_SSH_F2B_JAIL_CONF:-/etc/fail2ban/jail.d/xmg-sshd.conf}" ]; then
        local _f2b_tmp="${XMG_SSH_F2B_JAIL_CONF}.tmp.$$"
        if sed "s/^port = .*/port = ssh,${port}/" "$XMG_SSH_F2B_JAIL_CONF" > "$_f2b_tmp" 2>/dev/null && [ -s "$_f2b_tmp" ]; then
            cat "$_f2b_tmp" > "$XMG_SSH_F2B_JAIL_CONF" 2>/dev/null || true
            rm -f "$_f2b_tmp" 2>/dev/null || true
            if xmg_cmd_exists fail2ban-client; then
                fail2ban-client reload sshd >/dev/null 2>&1 || fail2ban-client reload >/dev/null 2>&1 || true
            fi
            xmg_info "已同步更新 fail2ban 监控端口: ssh,$port"
        else
            rm -f "$_f2b_tmp" 2>/dev/null || true
        fi
    fi

    echo
    if [ "$lrc" -eq 2 ]; then
        xmg_info "SSH 端口已修改为: $port"
        xmg_warn "未找到 ss/netstat，未能确认监听状态；请立即新开终端验证: ssh -p $port user@host"
    else
        xmg_info "SSH 端口已修改为: $port（已确认监听）"
        xmg_warn "请勿关闭当前会话！新开终端测试: ssh -p $port user@host"
    fi
    xmg_warn "确认新端口可登录后，可删除旧端口放行规则"
}

# ===== 禁用 / 恢复密码登录 =====

xmg_ssh_disable_password() {
    xmg_require_root

    if ! xmg_ssh_check_authorized_keys; then
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

# 生成 fail2ban sshd jail 配置
# backend=auto 时按实际存在的日志文件补 logpath：
#   Debian/Ubuntu -> /var/log/auth.log，Alpine busybox syslog -> /var/log/messages
_xmg_ssh_write_f2b_conf() {
    local backend="$1"
    local port="${2:-22}"

    mkdir -p "$(dirname "$XMG_SSH_F2B_JAIL_CONF")"
    cat > "$XMG_SSH_F2B_JAIL_CONF" <<EOF
# XMG: sshd 防爆破（由 xmg ssh 生成）
[sshd]
enabled = true
port = ssh,$port
backend = $backend
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
EOF
    if [ "$backend" = "auto" ]; then
        local lg=""
        for lg in /var/log/auth.log /var/log/messages; do
            if [ -f "$lg" ]; then
                echo "logpath = $lg" >> "$XMG_SSH_F2B_JAIL_CONF"
                break
            fi
        done
    fi
}

# 重启 fail2ban 并轮询等待就绪
_xmg_ssh_restart_and_wait_f2b() {
    if xmg_svc_supported; then
        xmg_svc_enable fail2ban >/dev/null 2>&1 || true
        xmg_svc_restart fail2ban >/dev/null 2>&1 || true
    elif xmg_cmd_exists service; then
        service fail2ban restart >/dev/null 2>&1 || true
    fi

    # fail2ban 是 Python 守护进程，启动创建 socket 并加载 jail 需耗时 1-3 秒，轮询最多等待 5 秒
    local i=0
    for ((i=1; i<=10; i++)); do
        if fail2ban-client status sshd >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

xmg_ssh_fail2ban_install() {
    xmg_require_root

    if xmg_cmd_exists fail2ban-client; then
        xmg_info "fail2ban 已安装"
    else
        xmg_info "安装 fail2ban: $(xmg_pkg_hint fail2ban)"
        if [ "$(xmg_pkg_mgr)" = "apt" ]; then
            # Debian 12 需 python3-systemd 支持 journal 后端
            xmg_pkg_install fail2ban python3-systemd || {
                xmg_error "fail2ban 安装失败，可先执行 xmg maint 更新源后重试"
                return 1
            }
        else
            xmg_pkg_install fail2ban || {
                xmg_error "fail2ban 安装失败，可先执行 xmg maint 更新源后重试"
                return 1
            }
        fi
    fi

    local current_port="22"
    current_port="$(xmg_ssh_get_port)"

    # 选择初始后端：systemd 环境优先 journal，否则用文件后端（auto）
    local primary_backend="systemd"
    if [ -f /var/log/auth.log ] || [ -f /var/log/messages ]; then
        primary_backend="auto"
    fi
    if ! xmg_init_is_systemd; then
        primary_backend="auto"
    fi

    _xmg_ssh_write_f2b_conf "$primary_backend" "$current_port"

    if ! _xmg_ssh_restart_and_wait_f2b; then
        # 首次启动未就绪，尝试自动 fallback 切换后端
        local fallback_backend="auto"
        if [ "$primary_backend" = "auto" ]; then
            if xmg_init_is_systemd; then
                fallback_backend="systemd"
            else
                fallback_backend="auto"
            fi
        fi
        xmg_warn "sshd jail ($primary_backend 后端) 启动超时，尝试切换为 $fallback_backend 后端自适应修复..."
        _xmg_ssh_write_f2b_conf "$fallback_backend" "$current_port"

        if ! _xmg_ssh_restart_and_wait_f2b; then
            xmg_error "sshd jail 未正常运行，排查诊断信息如下:"
            if xmg_svc_supported; then
                xmg_svc_status fail2ban 2>/dev/null | head -n 15 || true
            fi
            fail2ban-client status 2>/dev/null || true
            if [ -r /var/log/fail2ban.log ]; then
                xmg_error "fail2ban.log 最新日志:"
                tail -n 10 /var/log/fail2ban.log 2>/dev/null || true
            fi
            if ! xmg_init_is_systemd; then
                xmg_warn "当前 init=$XMG_INIT_SYSTEM：fail2ban 依赖 syslog 日志文件"
                xmg_warn "请确认 syslog 服务已启动: rc-service syslog start && rc-update add syslog default"
            fi
            return 1
        fi
    fi

    xmg_info "fail2ban sshd jail 已启用（5 次失败封 1 小时，累犯递增最长 1 周，监控端口: $current_port）"
    fail2ban-client status sshd 2>/dev/null || true
    return 0
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
        echo "========== SSH 安全加固 =========="
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
                xmg_ssh_show || true
                xmg_pause
                ;;
            2)
                xmg_ssh_change_port || true
                xmg_pause
                ;;
            3)
                xmg_ssh_disable_password || true
                xmg_pause
                ;;
            4)
                xmg_ssh_enable_password || true
                xmg_pause
                ;;
            5)
                xmg_ssh_fail2ban_install || true
                xmg_pause
                ;;
            6)
                clear
                xmg_ssh_fail2ban_status || true
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
