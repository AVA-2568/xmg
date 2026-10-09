#!/usr/bin/env bash
# 内核管理 — 版本通道与安装参数推导
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
# 三个路径变量必须显式齐备，否则会被上一个 source 过 state.sh 的用例污染。
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"

# 注意实际相对层级：本文件在 tests/cases/，lib 在 xmg/lib，故是 ../lib
source "$TESTS_DIR/../lib/state.sh"
source "$TESTS_DIR/../lib/core.sh"
xmg_state_init

# ------------------------------------------------------------------
# 通道参数推导
# ------------------------------------------------------------------
xmg_state_set XRAY_CHANNEL preview
t_equals "preview 应产出 --beta" "$(xmg_core_install_args)" "--beta"

xmg_state_set XRAY_CHANNEL stable
t_equals "stable 应产出空参数" "$(xmg_core_install_args)" ""

xmg_state_set XRAY_CHANNEL pinned
xmg_state_set XRAY_PINNED_VERSION "v25.8.3"
t_equals "pinned 应产出 --version <tag>" "$(xmg_core_install_args)" "--version v25.8.3"

# pinned 但缺版本号 -> 返回 3（且不吐出半个参数）
xmg_state_set XRAY_PINNED_VERSION ""
_out="$(xmg_core_install_args 2>/dev/null)"; _rc=$?
t_equals "pinned 无版本号应返回 3" "$_rc" "3"
t_equals "pinned 无版本号不应输出参数" "$_out" ""

# 未知通道 -> 返回 2
xmg_state_set XRAY_CHANNEL bogus
xmg_core_install_args >/dev/null 2>&1
t_equals "未知通道应返回 2" "$?" "2"

# ------------------------------------------------------------------
# 通道写入 state
# ------------------------------------------------------------------
xmg_state_set XRAY_CHANNEL stable
xmg_core_channel_set preview 2>/dev/null
t_equals "通道已写为 preview" "$(xmg_state_get XRAY_CHANNEL)" "preview"
t_equals "切到 preview 后清空锁定版本" "$(xmg_state_get XRAY_PINNED_VERSION)" ""

xmg_core_channel_set pinned v25.8.3 2>/dev/null
t_equals "通道已写为 pinned" "$(xmg_state_get XRAY_CHANNEL)" "pinned"
t_equals "锁定版本已记录" "$(xmg_state_get XRAY_PINNED_VERSION)" "v25.8.3"

# pinned 缺版本号应被拒且不写 state
xmg_core_channel_set pinned "" 2>/dev/null
t_equals "pinned 无版本号应返回 2" "$?" "2"
t_equals "pinned 无版本号不污染 state" "$(xmg_state_get XRAY_CHANNEL)" "pinned"

# 非法通道应被拒且不污染 state
xmg_core_channel_set bogus 2>/dev/null
t_equals "非法通道应返回 2" "$?" "2"
t_equals "非法通道不污染 state" "$(xmg_state_get XRAY_CHANNEL)" "pinned"

# ------------------------------------------------------------------
# 未安装内核时 version 应返回非 0（并给出提示）
# ------------------------------------------------------------------
XMG_XRAY_BIN_OVERRIDE=""
XMG_XRAY_BIN="$XMG_TMP/no-such-xray"
xmg_core_version >/dev/null 2>&1
_rc=$?
t_equals "未安装内核时 version 返回非 0" \
    "$([ "$_rc" -ne 0 ] && printf nonzero || printf zero)" "nonzero"

# 注意：不 unset XMG_TMP —— 文件头的 EXIT trap 会在退出时引用它，
# 在 run.sh 的 set -u 下 unset 会让 trap 报 unbound variable。
unset _rc _out
