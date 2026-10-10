#!/usr/bin/env bash
# 主入口子命令与模块清单
# shellcheck shell=bash

# 注意实际相对层级：本文件在 tests/cases/，仓库根（含 xmg/xmg.files）在 xmg/，
# 故 SRC 是 $TESTS_DIR/..（简报写的 ../.. 多退了一级）。
SRC="$TESTS_DIR/.."
MAIN="$SRC/xmg"
FILES="$SRC/xmg.files"

# --- xmg.files 必须登记新模块 ---
t_contains "清单含 detect.sh" "$(cat "$FILES")" "lib/detect.sh"
t_contains "清单含 state.sh" "$(cat "$FILES")" "lib/state.sh"
t_contains "清单含 render.sh" "$(cat "$FILES")" "lib/render.sh"
t_contains "清单含 proxy.sh" "$(cat "$FILES")" "lib/proxy.sh"
t_contains "清单含 core.sh" "$(cat "$FILES")" "lib/core.sh"

# --- 废弃与臃肿模块不得出现在清单中 ---
t_not_contains "caddy.sh 不应出现在 xmg.files" "$(cat "$FILES")" "caddy.sh"
t_not_contains "site.sh 不应出现在 xmg.files" "$(cat "$FILES")" "site.sh"
t_not_contains "third-party.sh 不应出现在 xmg.files" "$(cat "$FILES")" "third-party.sh"

# 清单顺序决定菜单顺序：新模块必须在清单中
ORDER="$(grep -n 'lib/proxy.sh' "$FILES" | cut -d: -f1)"
t_assert "proxy.sh 在清单中存在且有行号" test -n "$ORDER"
ORDER_CORE="$(grep -n 'lib/core.sh' "$FILES" | cut -d: -f1)"
t_assert "core.sh 在清单中存在且有行号" test -n "$ORDER_CORE"

# 清单条目类别必须全部落在 install.sh 允许的集合内（xmg / lib/*.sh / xmg.files / templates/*.json）
_BAD=""
while IFS= read -r _e || [ -n "$_e" ]; do
    [ -z "$_e" ] && continue
    case "$_e" in
        xmg|lib/*.sh|xmg.files|templates/*.json) ;;
        *) _BAD="$_e" ;;
    esac
done < "$FILES"
t_equals "清单条目均符合 install.sh 允许类别" "${_BAD}" ""

# --- 主入口必须支持 proxy / core 子命令 ---
MAIN_SRC="$(cat "$MAIN")"
t_contains "入口含 proxy 分支" "$MAIN_SRC" "proxy"
t_contains "入口含 core 分支" "$MAIN_SRC" "core"

# --- 用法文本 ---
t_contains "用法含 proxy" "$MAIN_SRC" "xmg proxy"
t_contains "用法含 core" "$MAIN_SRC" "xmg core"

# --- 模块可被 menu.sh 的静态扫描识别 ---
for f in state.sh render.sh proxy.sh core.sh; do
    t_assert "$f 存在" test -f "$SRC/lib/$f"
done
t_assert "proxy.sh 声明菜单标签" grep -q "XMG_MENU_LABEL:" "$SRC/lib/proxy.sh"
t_assert "core.sh 声明菜单标签" grep -q "XMG_MENU_LABEL:" "$SRC/lib/core.sh"
t_assert "proxy.sh 定义菜单函数" grep -qE '^xmg_proxy_menu\(\)' "$SRC/lib/proxy.sh"
t_assert "core.sh 定义菜单函数" grep -qE '^xmg_core_menu\(\)' "$SRC/lib/core.sh"

# --- 轻量集成：真跑一次 menu.sh 的发现逻辑，确认新模块进入菜单 ---
_TE_HAS_HOME="${XMG_HOME+x}"
_TE_HAS_LIB_DIR="${XMG_LIB_DIR+x}"
_TE_SAVED_HOME="${XMG_HOME-}"
_TE_SAVED_LIB_DIR="${XMG_LIB_DIR-}"
export XMG_HOME="$SRC"
export XMG_LIB_DIR="$SRC/lib"
# shellcheck source=/dev/null
source "$SRC/lib/menu.sh"
xmg_menu_discover_modules
_MENU_FUNCS="$(printf '%s\n' "${XMG_MENU_FUNCS[@]}")"
t_contains "静态扫描发现 proxy 菜单" "$_MENU_FUNCS" "xmg_proxy_menu"
t_contains "静态扫描发现 core 菜单" "$_MENU_FUNCS" "xmg_core_menu"
t_not_contains "静态扫描不应包含 caddy 菜单" "$_MENU_FUNCS" "xmg_caddy_menu"
t_not_contains "静态扫描不应包含 site 菜单" "$_MENU_FUNCS" "xmg_site_menu"
t_not_contains "静态扫描不应包含 third_party 菜单" "$_MENU_FUNCS" "xmg_third_party_menu"

# --- Caddy 彻底剥离与零残留断言 ---
t_not_contains "common.sh 不再引用 XMG_CADDY_DIR" "$(cat "$SRC/lib/common.sh")" "XMG_CADDY_DIR"
t_not_contains "common.sh 不再引用 XMG_CADDYFILE" "$(cat "$SRC/lib/common.sh")" "XMG_CADDYFILE"
t_not_contains "update.sh 不再引用 XMG_CADDY_DIR" "$(cat "$SRC/lib/update.sh")" "XMG_CADDY_DIR"
t_not_contains "update.sh 不再引用 XMG_CADDYFILE" "$(cat "$SRC/lib/update.sh")" "XMG_CADDYFILE"
t_not_contains "system.sh 不再包含 XMG_STATUS_CADDY" "$(cat "$SRC/lib/system.sh")" "XMG_STATUS_CADDY"
t_not_contains "system.sh 不再包含 XMG_CADDY_SERVICE" "$(cat "$SRC/lib/system.sh")" "XMG_CADDY_SERVICE"
t_not_contains "monitor.sh 不再打印 Caddy 状态" "$(cat "$SRC/lib/monitor.sh")" "Caddy"
t_not_contains "xmg 入口帮助不含 XMG_CADDY_SERVICE" "$(cat "$SRC/xmg")" "XMG_CADDY_SERVICE"

# --- 废弃站点与死代码彻底剥离断言 ---
t_not_contains "common.sh 不再引用 XMG_WWW_DIR" "$(cat "$SRC/lib/common.sh")" "XMG_WWW_DIR"
t_not_contains "update.sh 不再引用 XMG_WWW_DIR" "$(cat "$SRC/lib/update.sh")" "XMG_WWW_DIR"
t_not_contains "install.sh 不再引用 XMG_WWW_DIR" "$(cat "$SRC/install.sh")" "XMG_WWW_DIR"
t_not_contains "uninstall.sh 不再引用 XMG_WWW_DIR" "$(cat "$SRC/lib/uninstall.sh")" "XMG_WWW_DIR"
t_not_contains "common.sh 不再包含 xmg_color 兼容死代码" "$(cat "$SRC/lib/common.sh")" "xmg_color()"
t_not_contains "common.sh 不再包含 xmg_backup_file 死代码" "$(cat "$SRC/lib/common.sh")" "xmg_backup_file()"
t_not_contains "system.sh 不再包含 xmg_read_mem_percent 兼容死代码" "$(cat "$SRC/lib/system.sh")" "xmg_read_mem_percent()"
t_not_contains "menu.sh 不再包含 xmg_menu_load_modules 兼容死代码" "$(cat "$SRC/lib/menu.sh")" "xmg_menu_load_modules()"
t_not_contains "render.sh 不再包含 xmg_render_dns 兼容死代码" "$(cat "$SRC/lib/render.sh")" "xmg_render_dns()"

# --- 环境恢复 ---
XMG_HOME="$_TE_SAVED_HOME"
XMG_LIB_DIR="$_TE_SAVED_LIB_DIR"
[ -n "$_TE_HAS_HOME" ] || unset XMG_HOME
[ -n "$_TE_HAS_LIB_DIR" ] || unset XMG_LIB_DIR
unset _TE_HAS_HOME _TE_HAS_LIB_DIR _TE_SAVED_HOME _TE_SAVED_LIB_DIR
unset _BAD _e _MENU_FUNCS ORDER ORDER_CORE
