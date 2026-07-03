#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# third-party.sh - XMG 外部工具管理模块
#
# 说明：
#   - 提供第三方脚本在线运行功能
#   - 预置 IP 质量体检脚本 (xykt/IPQuality)
#   - 支持用户自定义添加/删除第三方脚本
#   - 所有脚本通过 bash <(curl -Ls URL) 在线运行，不下载到本地
#   - 文件内容应使用 UTF-8 编码保存
#

# third-party.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "third-party.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_THIRD_PARTY_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_THIRD_PARTY_SH_LOADED=1

# ===== 默认配置 =====

# 用户自定义脚本配置文件路径
XMG_THIRD_PARTY_CONF="${XMG_THIRD_PARTY_CONF:-$XMG_ETC_DIR/third-party.conf}"

# ===== 依赖 common.sh 的路径变量 =====
if [ -z "${XMG_HOME:-}" ]; then
    XMG_HOME="${XMG_HOME:-/opt/xmg}"
fi
if [ -z "${XMG_ETC_DIR:-}" ]; then
    XMG_ETC_DIR="${XMG_ETC_DIR:-$XMG_HOME/etc}"
fi

# ===== 预置脚本注册表 =====
# 这些脚本由 XMG 预置，用户不可删除
# 使用并行数组存储：名称、URL、描述
XMG_THIRD_PARTY_PREDEF_NAMES=("IP质量体检")
XMG_THIRD_PARTY_PREDEF_URLS=("https://IP.Check.Place")
XMG_THIRD_PARTY_PREDEF_DESCS=("IP 质量检测脚本 (xykt/IPQuality)")

# ===== 兼容函数 =====

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
if ! declare -F xmg_mkdirs >/dev/null 2>&1; then
    xmg_mkdirs() {
        mkdir -p "$XMG_ETC_DIR"
    }
fi

# ===== 配置文件管理 =====

# 确保配置文件目录和文件存在
xmg_third_party_ensure_conf() {
    xmg_mkdirs
    if [ ! -f "$XMG_THIRD_PARTY_CONF" ]; then
        cat > "$XMG_THIRD_PARTY_CONF" <<'EOF'
# XMG 第三方脚本配置文件
# 格式：名称|URL|描述
# 注意：请勿手动编辑，通过 XMG 菜单管理
EOF
    fi
}

# 加载用户自定义脚本到并行数组
# 设置三个全局数组：_TP_CUSTOM_NAMES / _TP_CUSTOM_URLS / _TP_CUSTOM_DESCS
xmg_third_party_load_custom() {
    _TP_CUSTOM_NAMES=()
    _TP_CUSTOM_URLS=()
    _TP_CUSTOM_DESCS=()

    local line=""
    local name=""
    local url=""
    local desc=""

    [ -r "$XMG_THIRD_PARTY_CONF" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        # 跳过空行和注释行
        case "$line" in
            ''|'#'*)
                continue
                ;;
        esac

        # 解析 pipe 分隔的字段：名称|URL|描述
        IFS='|' read -r name url desc <<< "$line"

        # 跳过无效条目
        [ -z "$name" ] && continue
        [ -z "$url" ] && continue

        _TP_CUSTOM_NAMES+=("$name")
        _TP_CUSTOM_URLS+=("$url")
        _TP_CUSTOM_DESCS+=("${desc:-无描述}")
    done < "$XMG_THIRD_PARTY_CONF"
}

# 保存用户自定义脚本到配置文件
# 依赖全局数组：_TP_CUSTOM_NAMES / _TP_CUSTOM_URLS / _TP_CUSTOM_DESCS
xmg_third_party_save_custom() {
    local i=0
    local count="${#_TP_CUSTOM_NAMES[@]}"

    xmg_third_party_ensure_conf

    # 写入文件头
    cat > "$XMG_THIRD_PARTY_CONF" <<'EOF'
# XMG 第三方脚本配置文件
# 格式：名称|URL|描述
# 注意：请勿手动编辑，通过 XMG 菜单管理
EOF

    # 写入每条记录
    for ((i = 0; i < count; i++)); do
        printf '%s|%s|%s\n' \
            "${_TP_CUSTOM_NAMES[$i]}" \
            "${_TP_CUSTOM_URLS[$i]}" \
            "${_TP_CUSTOM_DESCS[$i]}" >> "$XMG_THIRD_PARTY_CONF"
    done
}

# ===== 脚本运行 =====

# 运行指定 URL 的第三方脚本
# 参数：$1 = 脚本 URL
xmg_third_party_run() {
    local url="$1"

    # 检查 curl 是否可用
    if ! xmg_cmd_exists curl; then
        xmg_error "curl 未安装，无法在线运行第三方脚本"
        xmg_info "请先安装 curl：apt install curl / yum install curl / dnf install curl"
        return 1
    fi

    xmg_info "正在在线运行第三方脚本..."
    xmg_warn "脚本来源：$url"
    echo ""

    # 在线运行第三方脚本
    # 使用 bash <(curl -Ls URL) 模式，参数由第三方脚本自行处理
    bash <(curl -Ls "$url") || {
        xmg_warn "第三方脚本执行结束（退出码非零，这可能是正常行为）"
    }

    echo ""
    xmg_info "第三方脚本执行完毕"
}

# ===== 用户自定义管理 =====

# 添加自定义脚本
xmg_third_party_add() {
    local name=""
    local url=""
    local desc=""

    echo ""
    echo "--- 添加自定义脚本 ---"
    echo ""

    # 输入脚本名称
    printf "请输入脚本名称: "
    read -r name || return 1

    case "$name" in
        ''|'|'*)
            xmg_warn "脚本名称不能为空，且不能包含 | 字符"
            return 1
            ;;
    esac

    # 输入脚本 URL
    printf "请输入脚本 URL: "
    read -r url || return 1

    # 验证 URL 格式
    case "$url" in
        http://*|https://*)
            ;;
        *)
            xmg_warn "URL 必须以 http:// 或 https:// 开头"
            return 1
            ;;
    esac

    # 输入脚本描述（可选）
    printf "请输入脚本描述（可选，直接回车跳过）: "
    read -r desc || desc=""
    [ -z "$desc" ] && desc="无描述"

    # 确认添加
    echo ""
    echo "名称: $name"
    echo "URL:  $url"
    echo "描述: $desc"
    echo ""

    if ! xmg_confirm "确认添加此脚本?"; then
        xmg_info "已取消"
        return 0
    fi

    # 加载现有自定义脚本，追加新条目，保存
    xmg_third_party_load_custom
    _TP_CUSTOM_NAMES+=("$name")
    _TP_CUSTOM_URLS+=("$url")
    _TP_CUSTOM_DESCS+=("$desc")
    xmg_third_party_save_custom

    xmg_info "已添加自定义脚本: $name"
}

# 删除自定义脚本
xmg_third_party_remove() {
    local i=0
    local count=0
    local choice=""
    local idx=0

    # 加载自定义脚本
    xmg_third_party_load_custom
    count="${#_TP_CUSTOM_NAMES[@]}"

    if [ "$count" -eq 0 ]; then
        xmg_warn "当前没有自定义脚本可删除"
        return 0
    fi

    echo ""
    echo "--- 删除自定义脚本 ---"
    echo ""

    for ((i = 0; i < count; i++)); do
        printf '  %d. %s  -  %s\n' \
            "$((i + 1))" \
            "${_TP_CUSTOM_NAMES[$i]}" \
            "${_TP_CUSTOM_DESCS[$i]}"
    done

    echo "  0. 取消"
    echo ""
    printf "请选择要删除的脚本: "
    read -r choice || return 0

    case "$choice" in
        ''|*[!0-9]*)
            xmg_warn "无效选择"
            return 1
            ;;
    esac

    choice=$((10#$choice))

    if [ "$choice" -eq 0 ]; then
        xmg_info "已取消"
        return 0
    fi

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        xmg_warn "无效选择"
        return 1
    fi

    idx=$((choice - 1))

    # 确认删除
    if ! xmg_confirm "确认删除 \"${_TP_CUSTOM_NAMES[$idx]}\"?"; then
        xmg_info "已取消"
        return 0
    fi

    # 从数组中移除指定索引的元素
    unset '_TP_CUSTOM_NAMES[idx]'
    unset '_TP_CUSTOM_URLS[idx]'
    unset '_TP_CUSTOM_DESCS[idx]'

    # 重建数组索引（unset 后数组会有间隙）
    _TP_CUSTOM_NAMES=("${_TP_CUSTOM_NAMES[@]}")
    _TP_CUSTOM_URLS=("${_TP_CUSTOM_URLS[@]}")
    _TP_CUSTOM_DESCS=("${_TP_CUSTOM_DESCS[@]}")

    # 保存到配置文件
    xmg_third_party_save_custom

    xmg_info "已删除自定义脚本"
}

# ===== 菜单 =====

xmg_third_party_menu() {
    local choice=""
    local i=0
    local predef_count=0
    local custom_count=0
    local total_scripts=0
    local manage_add=0
    local manage_del=0

    while true; do
        clear

        # 加载最新的自定义脚本列表
        xmg_third_party_load_custom

        predef_count="${#XMG_THIRD_PARTY_PREDEF_NAMES[@]}"
        custom_count="${#_TP_CUSTOM_NAMES[@]}"
        total_scripts=$((predef_count + custom_count))

        # 管理选项的编号
        manage_add=$((total_scripts + 1))
        manage_del=$((total_scripts + 2))

        echo "========== 外部工具 =========="
        echo ""
        echo "⚠️  安全提醒：第三方脚本由外部作者维护"
        echo "   运行前请确认来源可信，XMG 不对其行为负责"
        echo ""

        # 列出预置脚本
        if [ "$predef_count" -gt 0 ]; then
            echo "--- 预置脚本 ---"
            for ((i = 0; i < predef_count; i++)); do
                printf '  %d. %s  -  %s\n' \
                    "$((i + 1))" \
                    "${XMG_THIRD_PARTY_PREDEF_NAMES[$i]}" \
                    "${XMG_THIRD_PARTY_PREDEF_DESCS[$i]}"
            done
            echo ""
        fi

        # 列出自定义脚本
        if [ "$custom_count" -gt 0 ]; then
            echo "--- 自定义脚本 ---"
            for ((i = 0; i < custom_count; i++)); do
                printf '  %d. %s  -  %s\n' \
                    "$((predef_count + i + 1))" \
                    "${_TP_CUSTOM_NAMES[$i]}" \
                    "${_TP_CUSTOM_DESCS[$i]}"
            done
            echo ""
        fi

        # 管理选项
        echo "--- 管理选项 ---"
        printf '  %d. 添加自定义脚本\n' "$manage_add"
        printf '  %d. 删除自定义脚本\n' "$manage_del"
        echo "  0. 返回"
        echo ""
        printf "请选择: "

        read -r choice || return 0

        case "$choice" in
            0)
                return 0
                ;;
            "$manage_add")
                xmg_third_party_add
                xmg_pause
                ;;
            "$manage_del")
                xmg_third_party_remove
                xmg_pause
                ;;
            *)
                # 检查是否为有效数字
                if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
                    xmg_warn "无效选择"
                    xmg_pause
                    continue
                fi

                choice=$((10#$choice))

                if [ "$choice" -ge 1 ] && [ "$choice" -le "$total_scripts" ]; then
                    # 运行选中的脚本
                    if [ "$choice" -le "$predef_count" ]; then
                        # 预置脚本
                        xmg_third_party_run "${XMG_THIRD_PARTY_PREDEF_URLS[$((choice - 1))]}"
                    else
                        # 自定义脚本
                        local custom_idx=$((choice - predef_count - 1))
                        xmg_third_party_run "${_TP_CUSTOM_URLS[$custom_idx]}"
                    fi
                    xmg_pause
                else
                    xmg_warn "无效选择"
                    xmg_pause
                fi
                ;;
        esac
    done
}

# ===== 直接执行支持 =====
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    xmg_third_party_menu
fi
