#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# caddy.sh - Caddy 安装与服务生命周期管理
#
# 说明：
#   - 本模块只管理 Caddy 的安装、卸载、启动、停止、重启、重载和状态查看
#   - 本模块不创建、不编辑、不修改 Caddyfile
#   - 默认不执行 apt-get update，避免被第三方 APT 源阻塞
#   - APT 安装失败后，自动回退到 Caddy 官方二进制安装
#   - 所有 XMG 管理的 Caddy 文件集中放在 /opt/xmg/caddy 下
#

# ===== 安全加载 =====
if [ "${XMG_CADDY_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_CADDY_SH_LOADED=1

# ===== 默认配置 =====
# 这些变量名属于模块接口，不要改名。
XMG_CADDY_SERVICE="${XMG_CADDY_SERVICE:-caddy}"
XMG_CADDY_APT_KEY_URL="${XMG_CADDY_APT_KEY_URL:-https://dl.cloudsmith.io/public/caddy/stable/gpg.key}"
XMG_CADDY_APT_SOURCE_URL="${XMG_CADDY_APT_SOURCE_URL:-https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt}"
XMG_CADDY_KEYRING_PATH="${XMG_CADDY_KEYRING_PATH:-/usr/share/keyrings/caddy-stable-archive-keyring.gpg}"
XMG_CADDY_APT_SOURCE_PATH="${XMG_CADDY_APT_SOURCE_PATH:-/etc/apt/sources.list.d/caddy-stable.list}"

# 新增参数：不破坏旧接口。
# auto   : 先尝试包管理器，不执行 apt update，失败后走二进制
# binary : 完全绕过包管理器，直接二进制安装
XMG_CADDY_INSTALL_MODE="${XMG_CADDY_INSTALL_MODE:-auto}"

# 是否允许二进制兜底安装。
XMG_CADDY_ENABLE_BINARY_FALLBACK="${XMG_CADDY_ENABLE_BINARY_FALLBACK:-1}"

# 二进制安装路径。
XMG_CADDY_BINARY_INSTALL_PATH="${XMG_CADDY_BINARY_INSTALL_PATH:-/usr/local/bin/caddy}"

# Caddy 官方下载 API。
XMG_CADDY_DOWNLOAD_BASE_URL="${XMG_CADDY_DOWNLOAD_BASE_URL:-https://caddyserver.com/api/download}"

# ===== 依赖 common.sh 的路径变量 =====
# 如果 common.sh 尚未加载，则设置默认值
if [ -z "${XMG_HOME:-}" ]; then
    XMG_HOME="${XMG_HOME:-/opt/xmg}"
fi
if [ -z "${XMG_CADDY_DIR:-}" ]; then
    XMG_CADDY_DIR="${XMG_CADDY_DIR:-$XMG_HOME/caddy}"
fi
if [ -z "${XMG_CADDYFILE:-}" ]; then
    XMG_CADDYFILE="${XMG_CADDYFILE:-$XMG_CADDY_DIR/Caddyfile}"
fi
if [ -z "${XMG_LOG_DIR:-}" ]; then
    XMG_LOG_DIR="${XMG_LOG_DIR:-$XMG_HOME/log}"
fi
if [ -z "${XMG_RUN_DIR:-}" ]; then
    XMG_RUN_DIR="${XMG_RUN_DIR:-$XMG_HOME/run}"
fi

# Caddy 在 XMG 统一目录下的数据目录和日志目录
XMG_CADDY_DATA_DIR="${XMG_CADDY_DATA_DIR:-$XMG_CADDY_DIR/data}"
XMG_CADDY_LOG_DIR="${XMG_CADDY_LOG_DIR:-$XMG_LOG_DIR/caddy}"

# ===== 兼容函数 =====

if ! declare -F xmg_cmd_exists >/dev/null 2>&1; then
    xmg_cmd_exists() {
        command -v "$1" >/dev/null 2>&1
    }
fi

if ! declare -F xmg_info >/dev/null 2>&1; then
    xmg_info() {
        printf '[INFO] %s\n' "$*"
    }
fi

if ! declare -F xmg_warn >/dev/null 2>&1; then
    xmg_warn() {
        printf '[WARN] %s\n' "$*" >&2
    }
fi

if ! declare -F xmg_die >/dev/null 2>&1; then
    xmg_die() {
        printf '[ERROR] %s\n' "$*" >&2
        exit 1
    }
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
            y|Y|yes|YES|Yes)
                return 0
                ;;
            *)
                return 1
                ;;
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

# ===== 基础检测 =====

xmg_caddy_binary_exists() {
    xmg_cmd_exists caddy || [ -x "$XMG_CADDY_BINARY_INSTALL_PATH" ]
}

xmg_caddy_is_systemd_available() {
    xmg_cmd_exists systemctl
}

xmg_caddy_get_bin() {
    if xmg_cmd_exists caddy; then
        command -v caddy
        return 0
    fi

    if [ -x "$XMG_CADDY_BINARY_INSTALL_PATH" ]; then
        printf '%s\n' "$XMG_CADDY_BINARY_INSTALL_PATH"
        return 0
    fi

    return 1
}

xmg_caddy_print_version() {
    local caddy_bin=""

    caddy_bin="$(xmg_caddy_get_bin)" || return 1
    "$caddy_bin" version 2>/dev/null
}

# ===== 下载辅助 =====

xmg_caddy_download() {
    local url="${1:-}"
    local output="${2:-}"

    if [ -z "$url" ] || [ -z "$output" ]; then
        return 1
    fi

    if xmg_cmd_exists curl; then
        curl -fsSL "$url" -o "$output"
        return $?
    fi

    if xmg_cmd_exists wget; then
        wget -qO "$output" "$url"
        return $?
    fi

    return 1
}

# ===== 架构识别 =====

xmg_caddy_get_linux_arch() {
    local machine=""

    machine="$(uname -m 2>/dev/null || true)"

    case "$machine" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armv7)
            echo "armv7"
            ;;
        armv6l|armv6)
            echo "armv6"
            ;;
        i386|i686)
            echo "386"
            ;;
        *)
            return 1
            ;;
    esac
}

# ===== APT 安装：不执行 apt-get update =====

xmg_caddy_install_by_apt_no_update() {
    xmg_info "检测到 apt-get，尝试不执行 apt-get update 直接安装 Caddy"

    if ! xmg_cmd_exists apt-get; then
        return 1
    fi

    export DEBIAN_FRONTEND=noninteractive

    xmg_warn "本次不会执行 apt-get update"
    xmg_warn "如果 APT 缓存中没有 Caddy 包，此步骤可能失败，随后会尝试二进制安装"

    if apt-get install -y caddy; then
        xmg_info "APT 直接安装 Caddy 成功"
        return 0
    fi

    xmg_warn "APT 直接安装 Caddy 失败"
    return 1
}

# ===== DNF/YUM 安装 =====
# 注意：dnf/yum 自身可能刷新元数据，但不会执行 apt-get update。

xmg_caddy_install_by_dnf() {
    if ! xmg_cmd_exists dnf; then
        return 1
    fi

    xmg_info "检测到 dnf，尝试安装 Caddy"

    if dnf install -y caddy; then
        xmg_info "DNF 安装 Caddy 成功"
        return 0
    fi

    xmg_warn "DNF 直接安装 Caddy 失败"
    return 1
}

xmg_caddy_install_by_yum() {
    if ! xmg_cmd_exists yum; then
        return 1
    fi

    xmg_info "检测到 yum，尝试安装 Caddy"

    if yum install -y caddy; then
        xmg_info "YUM 安装 Caddy 成功"
        return 0
    fi

    xmg_warn "YUM 直接安装 Caddy 失败"
    return 1
}

# ===== 二进制安装准备 =====

xmg_caddy_create_user_and_dirs() {
    # 创建 caddy 系统用户，home 目录指向 XMG 统一数据目录
    if ! id caddy >/dev/null 2>&1; then
        if xmg_cmd_exists useradd; then
            useradd \
                --system \
                --home "$XMG_CADDY_DATA_DIR" \
                --shell /usr/sbin/nologin \
                caddy 2>/dev/null \
                || useradd -r -d "$XMG_CADDY_DATA_DIR" -s /sbin/nologin caddy 2>/dev/null \
                || true
        fi
    fi

    # 创建 XMG 统一目录下的 Caddy 数据目录和日志目录
    # 注意：Caddyfile 配置目录 $XMG_CADDY_DIR 由 xmg_mkdirs() 统一创建
    install -d -m 0755 "$XMG_CADDY_DATA_DIR" \
        || return 1

    install -d -m 0755 "$XMG_CADDY_LOG_DIR" \
        || return 1

    # 设置数据目录和日志目录的归属给 caddy 用户
    if id caddy >/dev/null 2>&1; then
        chown -R caddy:caddy "$XMG_CADDY_DATA_DIR" "$XMG_CADDY_LOG_DIR" 2>/dev/null || true
    fi

    return 0
}

xmg_caddy_install_systemd_unit_for_binary() {
    local unit_path="/etc/systemd/system/${XMG_CADDY_SERVICE}.service"

    if ! xmg_caddy_is_systemd_available; then
        xmg_warn "未检测到 systemctl，跳过 systemd service 创建"
        return 0
    fi

    if [ -f "/etc/systemd/system/${XMG_CADDY_SERVICE}.service" ] \
        || [ -f "/lib/systemd/system/${XMG_CADDY_SERVICE}.service" ] \
        || [ -f "/usr/lib/systemd/system/${XMG_CADDY_SERVICE}.service" ]; then
        xmg_info "检测到已有 ${XMG_CADDY_SERVICE}.service，跳过创建"
        return 0
    fi

    # 创建 systemd unit，配置文件和日志路径都指向 XMG 统一目录
    cat > "$unit_path" <<EOF
[Unit]
Description=Caddy web server
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=${XMG_CADDY_BINARY_INSTALL_PATH} run --environ --config ${XMG_CADDYFILE}
ExecReload=${XMG_CADDY_BINARY_INSTALL_PATH} reload --config ${XMG_CADDYFILE} --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
WorkingDirectory=${XMG_CADDY_DATA_DIR}
ReadWritePaths=${XMG_CADDY_DATA_DIR} ${XMG_CADDY_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    xmg_info "已创建 systemd service：$unit_path"
    xmg_info "配置路径：$XMG_CADDYFILE"
    xmg_info "数据目录：$XMG_CADDY_DATA_DIR"
    xmg_info "日志目录：$XMG_CADDY_LOG_DIR"

    return 0
}

# ===== 官方二进制安装：完全不依赖 apt update =====

xmg_caddy_install_by_binary() {
    local arch=""
    local url=""
    local tmp_dir=""
    local tmp_bin=""

    if [ "$XMG_CADDY_ENABLE_BINARY_FALLBACK" != "1" ]; then
        xmg_warn "二进制安装已关闭"
        return 1
    fi

    xmg_info "尝试使用 Caddy 官方二进制安装"
    xmg_warn "此方式不会执行 apt-get update，也不会修改第三方 APT 源"

    if ! xmg_cmd_exists curl && ! xmg_cmd_exists wget; then
        xmg_warn "缺少 curl/wget，无法下载 Caddy 二进制文件"
        return 1
    fi

    arch="$(xmg_caddy_get_linux_arch)" || {
        xmg_warn "不支持的 CPU 架构：$(uname -m 2>/dev/null || echo unknown)"
        return 1
    }

    tmp_dir="$(mktemp -d)" || return 1
    tmp_bin="${tmp_dir}/caddy"

    url="${XMG_CADDY_DOWNLOAD_BASE_URL}?os=linux&arch=${arch}"

    xmg_info "下载 Caddy 官方二进制：linux/${arch}"

    if ! xmg_caddy_download "$url" "$tmp_bin"; then
        rm -rf "$tmp_dir"
        xmg_warn "下载 Caddy 二进制失败"
        return 1
    fi

    chmod 0755 "$tmp_bin" || {
        rm -rf "$tmp_dir"
        xmg_warn "设置 Caddy 二进制权限失败"
        return 1
    }

    if ! "$tmp_bin" version >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        xmg_warn "下载的文件不能正常执行，可能不是有效的 Caddy 二进制"
        return 1
    fi

    install -d -m 0755 "$(dirname "$XMG_CADDY_BINARY_INSTALL_PATH")" || {
        rm -rf "$tmp_dir"
        xmg_warn "创建二进制安装目录失败"
        return 1
    }

    install -m 0755 "$tmp_bin" "$XMG_CADDY_BINARY_INSTALL_PATH" || {
        rm -rf "$tmp_dir"
        xmg_warn "安装 Caddy 二进制失败"
        return 1
    }

    rm -rf "$tmp_dir"

    xmg_caddy_create_user_and_dirs || {
        xmg_warn "创建 Caddy 用户或目录失败"
        return 1
    }

    xmg_caddy_install_systemd_unit_for_binary || {
        xmg_warn "创建 systemd service 失败"
        return 1
    }

    xmg_info "Caddy 官方二进制安装成功"
    "$XMG_CADDY_BINARY_INSTALL_PATH" version 2>/dev/null || true

    return 0
}

# ===== 安装 / 更新 =====

xmg_caddy_install_update() {
    xmg_require_root
    xmg_info "安装/更新 Caddy"

    local installed=0

    case "$XMG_CADDY_INSTALL_MODE" in
        binary)
            xmg_info "安装模式：binary，直接使用官方二进制安装"
            if xmg_caddy_install_by_binary; then
                installed=1
            fi
            ;;
        auto|"")
            xmg_info "安装模式：auto"
            xmg_warn "默认不会执行 apt-get update"

            if xmg_cmd_exists apt-get; then
                if xmg_caddy_install_by_apt_no_update; then
                    installed=1
                fi
            elif xmg_cmd_exists dnf; then
                if xmg_caddy_install_by_dnf; then
                    installed=1
                fi
            elif xmg_cmd_exists yum; then
                if xmg_caddy_install_by_yum; then
                    installed=1
                fi
            else
                xmg_warn "未检测到 apt-get / dnf / yum"
            fi

            if [ "$installed" -ne 1 ]; then
                xmg_warn "包管理器安装失败，开始尝试官方二进制安装"
                if xmg_caddy_install_by_binary; then
                    installed=1
                fi
            fi
            ;;
        *)
            xmg_die "未知安装模式：$XMG_CADDY_INSTALL_MODE"
            ;;
    esac

    if [ "$installed" -ne 1 ]; then
        xmg_die "Caddy 安装失败"
    fi

    if ! xmg_caddy_binary_exists; then
        xmg_die "安装流程结束，但未检测到 caddy 命令"
    fi

    xmg_info "Caddy 命令检测成功"

    if xmg_caddy_print_version >/dev/null 2>&1; then
        xmg_info "Caddy 版本：$(xmg_caddy_print_version)"
    else
        xmg_warn "无法获取 Caddy 版本，但 caddy 命令已存在"
    fi

    if xmg_caddy_is_systemd_available; then
        systemctl daemon-reload >/dev/null 2>&1 || true

        if systemctl enable "$XMG_CADDY_SERVICE" >/dev/null 2>&1; then
            xmg_info "Caddy 已设置为开机自启"
        else
            xmg_warn "Caddy 已安装，但设置开机自启失败"
        fi

        # 检查 Caddyfile 是否存在，提示用户自行创建
        if [ ! -f "$XMG_CADDYFILE" ]; then
            xmg_warn "未找到 $XMG_CADDYFILE"
            xmg_warn "本模块不创建 Caddyfile，因此服务启动可能失败"
            xmg_warn "请手动创建 Caddyfile，例如:"
            xmg_warn "  sudo mkdir -p $(dirname "$XMG_CADDYFILE")"
            xmg_warn "  sudo nano $XMG_CADDYFILE"
        fi

        if systemctl start "$XMG_CADDY_SERVICE" >/dev/null 2>&1; then
            xmg_info "Caddy 服务已启动"
        else
            xmg_warn "Caddy 已安装，但服务启动失败"
            xmg_warn "常见原因：Caddyfile 不存在、配置错误、端口占用或权限问题"
            xmg_warn "请执行以下命令查看原因："
            xmg_warn "systemctl status ${XMG_CADDY_SERVICE} --no-pager"
            xmg_warn "journalctl -u ${XMG_CADDY_SERVICE} -n 100 --no-pager"
        fi
    else
        xmg_warn "未检测到 systemctl，仅完成 Caddy 安装"
    fi

    xmg_info "Caddy 安装/更新完成"
    xmg_warn "XMG 不处理 Caddyfile，请用户自行维护配置"
    xmg_warn "Caddyfile 路径: $XMG_CADDYFILE"
    xmg_warn "Caddy 数据目录: $XMG_CADDY_DATA_DIR"
    xmg_warn "Caddy 日志目录: $XMG_CADDY_LOG_DIR"
}

# ===== 卸载 =====

xmg_caddy_uninstall() {
    xmg_require_root

    if ! xmg_caddy_binary_exists; then
        xmg_warn "未检测到 Caddy 命令，可能尚未安装"
    fi

    xmg_warn "即将卸载 Caddy"
    xmg_warn "XMG 不负责备份或删除用户自定义 Caddyfile"

    if ! xmg_confirm "确认卸载 Caddy?"; then
        xmg_info "已取消"
        return 0
    fi

    if xmg_caddy_is_systemd_available; then
        systemctl stop "$XMG_CADDY_SERVICE" >/dev/null 2>&1 || true
        systemctl disable "$XMG_CADDY_SERVICE" >/dev/null 2>&1 || true
    fi

    if xmg_cmd_exists apt-get && dpkg -s caddy >/dev/null 2>&1; then
        apt-get remove -y caddy || xmg_warn "通过 apt 卸载 Caddy 失败"
    elif xmg_cmd_exists dnf && rpm -q caddy >/dev/null 2>&1; then
        dnf remove -y caddy || xmg_warn "通过 dnf 卸载 Caddy 失败"
    elif xmg_cmd_exists yum && rpm -q caddy >/dev/null 2>&1; then
        yum remove -y caddy || xmg_warn "通过 yum 卸载 Caddy 失败"
    fi

    if [ -x "$XMG_CADDY_BINARY_INSTALL_PATH" ]; then
        rm -f "$XMG_CADDY_BINARY_INSTALL_PATH" \
            && xmg_info "已删除二进制文件：$XMG_CADDY_BINARY_INSTALL_PATH" \
            || xmg_warn "删除二进制文件失败：$XMG_CADDY_BINARY_INSTALL_PATH"
    fi

    if [ -f "/etc/systemd/system/${XMG_CADDY_SERVICE}.service" ]; then
        rm -f "/etc/systemd/system/${XMG_CADDY_SERVICE}.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
        xmg_info "已删除 systemd service：/etc/systemd/system/${XMG_CADDY_SERVICE}.service"
    fi

    xmg_info "Caddy 卸载流程完成"
    xmg_warn "未删除 Caddyfile 和 Caddy 数据目录："
    xmg_warn "  Caddyfile: $XMG_CADDYFILE"
    xmg_warn "  数据目录: $XMG_CADDY_DATA_DIR"
    xmg_warn "  日志目录: $XMG_CADDY_LOG_DIR"
    xmg_warn "如需手动清理，请执行:"
    xmg_warn "  sudo rm -rf $XMG_CADDY_DIR"
    xmg_warn "  sudo rm -rf $XMG_CADDY_LOG_DIR"
}

# ===== 服务生命周期 =====

xmg_caddy_start() {
    xmg_require_root
    xmg_systemctl start "$XMG_CADDY_SERVICE"
    xmg_info "Caddy 已启动"
}

xmg_caddy_stop() {
    xmg_require_root
    xmg_systemctl stop "$XMG_CADDY_SERVICE"
    xmg_info "Caddy 已停止"
}

xmg_caddy_restart() {
    xmg_require_root
    xmg_systemctl restart "$XMG_CADDY_SERVICE"
    xmg_info "Caddy 已重启"
}

xmg_caddy_reload() {
    xmg_require_root
    xmg_systemctl reload "$XMG_CADDY_SERVICE"
    xmg_info "Caddy 已重载"
}

xmg_caddy_status() {
    if ! xmg_caddy_is_systemd_available; then
        xmg_warn "systemctl 不存在，无法查看 Caddy 状态"
        return 1
    fi

    systemctl status "$XMG_CADDY_SERVICE" --no-pager || true
}

# ===== 配置校验 =====

xmg_caddy_validate_config() {
    local caddy_bin=""

    caddy_bin="$(xmg_caddy_get_bin)" || {
        xmg_warn "caddy 命令不存在，无法校验配置"
        return 1
    }

    if [ -f "$XMG_CADDYFILE" ]; then
        "$caddy_bin" validate --config "$XMG_CADDYFILE" || return 1
    else
        xmg_warn "未找到 $XMG_CADDYFILE"
        return 1
    fi
}

# ===== 诊断 =====

xmg_caddy_diag() {
    echo "========== Caddy 安装诊断 =========="

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
    echo "[安装模式]"
    echo "XMG_CADDY_INSTALL_MODE=$XMG_CADDY_INSTALL_MODE"
    echo "XMG_CADDY_ENABLE_BINARY_FALLBACK=$XMG_CADDY_ENABLE_BINARY_FALLBACK"
    echo "XMG_CADDY_BINARY_INSTALL_PATH=$XMG_CADDY_BINARY_INSTALL_PATH"

    echo
    echo "[XMG 统一目录]"
    echo "XMG_HOME=$XMG_HOME"
    echo "XMG_CADDY_DIR=$XMG_CADDY_DIR"
    echo "XMG_CADDYFILE=$XMG_CADDYFILE"
    echo "XMG_CADDY_DATA_DIR=$XMG_CADDY_DATA_DIR"
    echo "XMG_CADDY_LOG_DIR=$XMG_CADDY_LOG_DIR"

    echo
    echo "[命令检测]"
    for cmd in apt-get dnf yum curl wget systemctl caddy; do
        if xmg_cmd_exists "$cmd"; then
            echo "$cmd: $(command -v "$cmd")"
        else
            echo "$cmd: 未检测到"
        fi
    done

    echo
    echo "[Cloudflare WARP APT 源检测]"
    grep -R "pkg.cloudflareclient.com" \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d \
        2>/dev/null || echo "未检测到 Cloudflare WARP APT 源"

    echo
    echo "[Caddy 版本]"
    if xmg_caddy_binary_exists; then
        xmg_caddy_print_version || echo "无法获取 caddy version"
    else
        echo "caddy 未安装"
    fi

    echo
    echo "[Caddy 二进制路径]"
    if [ -x "$XMG_CADDY_BINARY_INSTALL_PATH" ]; then
        ls -l "$XMG_CADDY_BINARY_INSTALL_PATH"
    else
        echo "不存在：$XMG_CADDY_BINARY_INSTALL_PATH"
    fi

    echo
    echo "[APT 源文件]"
    if [ -f "$XMG_CADDY_APT_SOURCE_PATH" ]; then
        echo "存在：$XMG_CADDY_APT_SOURCE_PATH"
        sed -n '1,20p' "$XMG_CADDY_APT_SOURCE_PATH"
    else
        echo "不存在：$XMG_CADDY_APT_SOURCE_PATH"
    fi

    echo
    echo "[Caddyfile 状态]"
    if [ -f "$XMG_CADDYFILE" ]; then
        echo "存在：$XMG_CADDYFILE"
        wc -l "$XMG_CADDYFILE"
    else
        echo "不存在：$XMG_CADDYFILE"
    fi

    echo
    echo "[Caddy 数据目录]"
    if [ -d "$XMG_CADDY_DATA_DIR" ]; then
        ls -la "$XMG_CADDY_DATA_DIR"
    else
        echo "不存在：$XMG_CADDY_DATA_DIR"
    fi

    echo
    echo "[Caddy 日志目录]"
    if [ -d "$XMG_CADDY_LOG_DIR" ]; then
        ls -la "$XMG_CADDY_LOG_DIR"
    else
        echo "不存在：$XMG_CADDY_LOG_DIR"
    fi

    echo
    echo "[systemd 服务状态]"
    if xmg_caddy_is_systemd_available; then
        systemctl status "$XMG_CADDY_SERVICE" --no-pager || true
    else
        echo "systemctl 不存在"
    fi

    echo
    echo "[最近日志]"
    if xmg_caddy_is_systemd_available; then
        journalctl -u "$XMG_CADDY_SERVICE" -n 50 --no-pager 2>/dev/null || true
    else
        echo "systemctl 不存在，跳过 journalctl"
    fi
}

# ===== 菜单 =====

xmg_caddy_menu() {
    local choice=""

    while true; do
        clear
        echo "========== Caddy 管理 =========="
        echo "1. 安装/更新 Caddy"
        echo "2. 卸载 Caddy"
        echo "3. 启动 Caddy"
        echo "4. 停止 Caddy"
        echo "5. 重启 Caddy"
        echo "6. 重载 Caddy"
        echo "7. 查看 Caddy 状态"
        echo "8. 校验 Caddyfile"
        echo "9. 安装诊断"
        echo "10. 强制使用官方二进制安装"
        echo "0. 返回"
        echo
        echo "说明:"
        echo "  - XMG 只管理 Caddy 服务生命周期"
        echo "  - XMG 不创建、不编辑、不修改 Caddyfile"
        echo "  - 默认不会执行 apt-get update"
        echo "  - 默认先尝试 apt-get install caddy"
        echo "  - APT 失败后会回退到官方二进制安装"
        echo "  - 如需完全绕过 APT，可选择 10"
        echo "  - Caddyfile: $XMG_CADDYFILE"
        echo "  - 数据目录: $XMG_CADDY_DATA_DIR"
        echo "  - 日志目录: $XMG_CADDY_LOG_DIR"
        echo
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            1)
                xmg_caddy_install_update
                xmg_pause
                ;;
            2)
                xmg_caddy_uninstall
                xmg_pause
                ;;
            3)
                xmg_caddy_start
                xmg_pause
                ;;
            4)
                xmg_caddy_stop
                xmg_pause
                ;;
            5)
                xmg_caddy_restart
                xmg_pause
                ;;
            6)
                xmg_caddy_reload
                xmg_pause
                ;;
            7)
                xmg_caddy_status
                xmg_pause
                ;;
            8)
                xmg_caddy_validate_config
                xmg_pause
                ;;
            9)
                xmg_caddy_diag
                xmg_pause
                ;;
            10)
                XMG_CADDY_INSTALL_MODE="binary"
                xmg_caddy_install_update
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
    xmg_caddy_menu
fi
