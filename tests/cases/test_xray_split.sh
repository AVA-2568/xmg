#!/usr/bin/env bash
# xray.sh 职责收窄：不再声称不碰配置，且保留服务生命周期能力
# shellcheck shell=bash

# --- 环境隔离 ---
# run.sh 在同一 shell 顺序 source 多个用例；本用例会 source common.sh/xray.sh，
# 后者会连带加载 state.sh/core.sh。退出时恢复路径变量，避免污染后续用例。
_TX_HAS_ETC="${XMG_ETC_DIR+x}"
_TX_HAS_STATE_DIR="${XMG_XRAY_STATE_DIR+x}"
_TX_HAS_STATE_FILE="${XMG_STATE_FILE+x}"
_TX_HAS_LIB_DIR="${XMG_LIB_DIR+x}"
_TX_SAVED_ETC="${XMG_ETC_DIR-}"
_TX_SAVED_STATE_DIR="${XMG_XRAY_STATE_DIR-}"
_TX_SAVED_STATE_FILE="${XMG_STATE_FILE-}"
_TX_SAVED_LIB_DIR="${XMG_LIB_DIR-}"

XMG_TMP="$(TMPDIR=/tmp mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_HOME="$XMG_TMP/home"
export XMG_LIB_DIR="$XMG_TMP/home/lib"
export XMG_LOG_DIR="$XMG_TMP/home/log"
export XMG_RUN_DIR="$XMG_TMP/home/run"
export XMG_ETC_DIR="$XMG_TMP/home/etc"
# 三个路径变量必须显式齐备，否则会被上一个 source 过 state.sh 的用例污染。
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_BACKUP_DIR="$XMG_TMP/home/backups"
export XMG_BIN_DIR="$XMG_TMP/home/bin"
export XMG_XRAY_DIR="$XMG_TMP/home/xray"
export XMG_XRAY_CONFIG="$XMG_XRAY_DIR/config.json"

# 注意实际相对层级：本文件在 tests/cases/，lib 在 xmg/lib，故是 ../lib
SRC="$TESTS_DIR/../lib"

# shellcheck source=/dev/null
source "$SRC/common.sh"
# shellcheck source=/dev/null
source "$SRC/xray.sh"

# 保留能力
# 注意：函数定义不跨进程，不能用 `bash -c "declare -F ..."`（永远失败）。
# 必须在当前 shell 直接断言（t_assert 单命令字符串形式，走内建 declare）。
for fn in xmg_xray_start xmg_xray_stop xmg_xray_restart \
           xmg_xray_reload xmg_xray_status xmg_xray_validate_config \
           xmg_xray_patch_systemd_unit xmg_xray_install_update \
           xmg_xray_uninstall xmg_xray_diag; do
    t_assert "保留函数 $fn" "declare -F $fn >/dev/null"
done

# 移除的旧声明
XR="$(cat "$SRC/xray.sh")"
t_not_contains "不再声明不修改配置" "$XR" "不创建、不编辑、不修改"
t_contains "说明配置已迁移" "$XR" "配置能力已迁移至 state.sh / render.sh / proxy.sh"
t_not_contains "不再重复定义 xmg_info" "$XR" "if ! declare -F xmg_info"
t_not_contains "不再重复定义 xmg_die" "$XR" "if ! declare -F xmg_die"

# 委托内核安装：install_update 内应调用 core.sh 的 xmg_core_install
t_contains "install_update 委托内核安装" "$XR" "xmg_core_install"

# 服务生命周期函数应能解析到 core.sh 的内核安装能力
t_assert "core 安装能力已可用" "declare -F xmg_core_install >/dev/null"

# --- 环境恢复 ---
XMG_ETC_DIR="$_TX_SAVED_ETC"
XMG_XRAY_STATE_DIR="$_TX_SAVED_STATE_DIR"
XMG_STATE_FILE="$_TX_SAVED_STATE_FILE"
XMG_LIB_DIR="$_TX_SAVED_LIB_DIR"
[ -n "$_TX_HAS_ETC" ] || unset XMG_ETC_DIR
[ -n "$_TX_HAS_STATE_DIR" ] || unset XMG_XRAY_STATE_DIR
[ -n "$_TX_HAS_STATE_FILE" ] || unset XMG_STATE_FILE
[ -n "$_TX_HAS_LIB_DIR" ] || unset XMG_LIB_DIR
unset _TX_HAS_ETC _TX_HAS_STATE_DIR _TX_HAS_STATE_FILE _TX_HAS_LIB_DIR
unset _TX_SAVED_ETC _TX_SAVED_STATE_DIR _TX_SAVED_STATE_FILE _TX_SAVED_LIB_DIR
