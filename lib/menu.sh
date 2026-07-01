#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# menu.sh - XMG 管理菜单与模块发现
#
# 说明：
#   - 本文件是 Bash 库文件，应由 xmg 主程序 source 加载
#   - 使用 Bash 数组和正则匹配，因此不支持 sh/dash
#   - 文件内容应使用 UTF-8 编码保存
#

# menu.sh 是 Bash 库文件，明确拒绝非 Bash 宿主
if [ -z "${BASH_VERSION:-}" ]; then
    echo "menu.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 安全加载 =====
if [ "${XMG_MENU_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_MENU_SH_LOADED=1

# 自动发现到的模块列表
XMG_MENU_FILES=()
XMG_MENU_FUNCS=()
XMG_MENU_LABELS=()

xmg_menu_source_module() {
    local file="$1"
    local path="$XMG_LIB_DIR/$file"

    if [ ! -r "$path" ]; then
        xmg_die "模块不存在或不可读: $path"
    fi

    # shellcheck source=/dev/null
    source "$path"
}

xmg_menu_require_func() {
    local fn="$1"

    if ! declare -F "$fn" >/dev/null 2>&1; then
        xmg_die "模块接口缺失: $fn"
    fi
}

xmg_menu_is_core_file() {
    local file="$1"

    case "$file" in
        common.sh|system.sh|monitor.sh|menu.sh)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 从模块文件中提取第一个 xmg_xxx_menu 函数名
#
# 支持以下写法：
#   xmg_demo_menu() {
#   function xmg_demo_menu {
#   function xmg_demo_menu() {
#
# 注意：
#   - 这里只做轻量静态扫描，不执行模块内容
#   - 真正执行模块时由 xmg_menu_load_module_func 按需 source
xmg_menu_find_menu_func() {
    local path="$1"
    local line=""

    [ -r "$path" ] || return 1

    while IFS= read -r line; do
        # 跳过空行和注释行
        case "$line" in
            ''|[[:space:]]'#'*|'#'*)
                continue
                ;;
        esac

        if [[ "$line" =~ ^[[:space:]]*(xmg_[A-Za-z0-9_]+_menu)[[:space:]]*\(\)[[:space:]]*\{ ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi

        if [[ "$line" =~ ^[[:space:]]*function[[:space:]]+(xmg_[A-Za-z0-9_]+_menu)[[:space:]]*(\(\))?[[:space:]]*(\{|$) ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$path"

    return 1
}

xmg_menu_label_for_file() {
    local file="$1"
    local base="${file%.sh}"

    case "$file" in
        xray.sh)
            printf 'Xray 管理'
            ;;
        caddy.sh)
            printf 'Caddy 管理'
            ;;
        site.sh)
            printf '站点管理'
            ;;
        firewall.sh)
            printf '防火墙管理'
            ;;
        update.sh)
            printf '更新 / 版本'
            ;;
        uninstall.sh)
            printf '卸载 XMG'
            ;;
        *)
            printf '%s' "$base"
            ;;
    esac
}

xmg_menu_module_seen() {
    local file="$1"
    local existing=""

    for existing in "${XMG_MENU_FILES[@]}"; do
        if [ "$existing" = "$file" ]; then
            return 0
        fi
    done

    return 1
}

xmg_menu_add_module_if_valid() {
    local file="$1"
    local path="$XMG_LIB_DIR/$file"
    local fn=""
    local label=""

    # 核心模块不作为菜单项出现
    xmg_menu_is_core_file "$file" && return 0

    # 避免重复添加
    xmg_menu_module_seen "$file" && return 0

    # 不可读文件直接跳过
    [ -r "$path" ] || return 0

    # 没有 xmg_xxx_menu 函数定义的模块直接跳过
    if ! fn="$(xmg_menu_find_menu_func "$path")"; then
        return 0
    fi

    label="$(xmg_menu_label_for_file "$file")"

    XMG_MENU_FILES+=("$file")
    XMG_MENU_FUNCS+=("$fn")
    XMG_MENU_LABELS+=("$label")
}

xmg_menu_discover_modules() {
    local path=""
    local file=""

    XMG_MENU_FILES=()
    XMG_MENU_FUNCS=()
    XMG_MENU_LABELS=()

    # 已知模块保持稳定顺序
    xmg_menu_add_module_if_valid "xray.sh"
    xmg_menu_add_module_if_valid "caddy.sh"
    xmg_menu_add_module_if_valid "site.sh"
    xmg_menu_add_module_if_valid "firewall.sh"
    xmg_menu_add_module_if_valid "update.sh"
    xmg_menu_add_module_if_valid "uninstall.sh"

    # 自动追加未知模块
    for path in "$XMG_LIB_DIR"/*.sh; do
        [ -e "$path" ] || continue

        file="${path##*/}"
        xmg_menu_add_module_if_valid "$file"
    done
}

# 按需加载某个模块并校验入口函数
xmg_menu_load_module_func() {
    local file="$1"
    local fn="$2"

    if ! declare -F "$fn" >/dev/null 2>&1; then
        xmg_menu_source_module "$file"
    fi

    xmg_menu_require_func "$fn"
}

# 兼容旧调用：预加载全部已发现模块
xmg_menu_load_modules() {
    local i=0

    xmg_menu_discover_modules

    for i in "${!XMG_MENU_FILES[@]}"; do
        xmg_menu_load_module_func "${XMG_MENU_FILES[$i]}" "${XMG_MENU_FUNCS[$i]}"
    done
}

xmg_menu_open_module_by_index() {
    local idx="$1"
    local file=""
    local fn=""

    if [[ ! "$idx" =~ ^[0-9]+$ ]]; then
        xmg_warn "无效模块索引"
        xmg_pause
        return 1
    fi

    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#XMG_MENU_FILES[@]}" ]; then
        xmg_warn "无效模块索引"
        xmg_pause
        return 1
    fi

    file="${XMG_MENU_FILES[$idx]}"
    fn="${XMG_MENU_FUNCS[$idx]}"

    xmg_menu_load_module_func "$file" "$fn"
    "$fn"
}

# 兼容旧接口：按文件和函数打开模块
xmg_menu_open_module() {
    local file="$1"
    local fn="$2"

    xmg_menu_load_module_func "$file" "$fn"
    "$fn"
}

xmg_menu_show() {
    local i=0
    local num=0
    local return_num=0

    clear

    xmg_menu_discover_modules

    cat <<EOF
========== XMG 管理菜单 ==========

1. 查看系统摘要
EOF

    num=2
    for i in "${!XMG_MENU_FILES[@]}"; do
        printf '%d. %s\n' "$num" "${XMG_MENU_LABELS[$i]}"
        num=$((num + 1))
    done

    return_num="$num"

    cat <<EOF
$return_num. 返回实时监控
0. 退出

EOF
}

xmg_menu_loop() {
    local choice=""
    local n=0
    local module_count=0
    local return_num=0
    local idx=0

    while true; do
        xmg_menu_show

        module_count="${#XMG_MENU_FILES[@]}"
        return_num=$((module_count + 2))

        printf "请选择: "
        read -r choice || return 0

        case "$choice" in
            0)
                clear
                exit 0
                ;;
            '')
                xmg_warn "无效选择"
                xmg_pause
                ;;
            *)
                if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
                    xmg_warn "无效选择"
                    xmg_pause
                    continue
                fi

                n=$((10#$choice))

                if [ "$n" -eq 1 ]; then
                    clear
                    xmg_system_refresh_all force
                    xmg_system_print_summary
                    xmg_pause
                    continue
                fi

                if [ "$n" -eq "$return_num" ]; then
                    return 0
                fi

                if [ "$n" -ge 2 ] && [ "$n" -lt "$return_num" ]; then
                    idx=$((n - 2))
                    xmg_menu_open_module_by_index "$idx"
                    continue
                fi

                xmg_warn "无效选择"
                xmg_pause
                ;;
        esac
    done
}
``
