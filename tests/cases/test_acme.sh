#!/usr/bin/env bash
# acme.sh 证书申请 — 仅手动触发
# shellcheck shell=bash

# --- 环境隔离 ---
_TX_HAS_ETC="${XMG_ETC_DIR+x}"
_TX_HAS_STATE_DIR="${XMG_XRAY_STATE_DIR+x}"
_TX_HAS_STATE_FILE="${XMG_STATE_FILE+x}"
_TX_HAS_LOG_DIR="${XMG_LOG_DIR+x}"
_TX_HAS_BACKUP_DIR="${XMG_BACKUP_DIR+x}"
_TX_HAS_XRAY_CONFIG="${XMG_XRAY_CONFIG+x}"
_TX_HAS_ACME_DIR="${XMG_ACME_DIR+x}"
_TX_HAS_ACME_CERT="${XMG_ACME_CERT_FILE+x}"
_TX_HAS_ACME_KEY="${XMG_ACME_KEY_FILE+x}"
_TX_HAS_TEST_MODE="${XMG_TEST_MODE+x}"
_TX_HAS_ACME_TESTCMD="${XMG_ACME_TESTCMD+x}"
_TX_SAVED_ETC="${XMG_ETC_DIR-}"
_TX_SAVED_STATE_DIR="${XMG_XRAY_STATE_DIR-}"
_TX_SAVED_STATE_FILE="${XMG_STATE_FILE-}"
_TX_SAVED_LOG_DIR="${XMG_LOG_DIR-}"
_TX_SAVED_BACKUP_DIR="${XMG_BACKUP_DIR-}"
_TX_SAVED_XRAY_CONFIG="${XMG_XRAY_CONFIG-}"
_TX_SAVED_ACME_DIR="${XMG_ACME_DIR-}"
_TX_SAVED_ACME_CERT="${XMG_ACME_CERT_FILE-}"
_TX_SAVED_ACME_KEY="${XMG_ACME_KEY_FILE-}"
_TX_SAVED_TEST_MODE="${XMG_TEST_MODE-}"
_TX_SAVED_ACME_TESTCMD="${XMG_ACME_TESTCMD-}"

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
# 三个路径变量必须显式齐备，否则会被上一个 source 过 state.sh 的用例污染。
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_BACKUP_DIR="$XMG_TMP/backups"
export XMG_XRAY_CONFIG="$XMG_TMP/xray/config.json"
# 证书产物落到临时目录，避免真去写 $XMG_HOME
export XMG_ACME_DIR="$XMG_TMP/acme.sh"
export XMG_ACME_CERT_FILE="$XMG_TMP/certs/fullchain.crt"
export XMG_ACME_KEY_FILE="$XMG_TMP/certs/priv.key"
# 测试桩：跳过真实签发（下载/联网）。
# 桩只在 XMG_TEST_MODE=1 时生效，生产环境即使同名也不会 eval 任意命令。
export XMG_TEST_MODE=1
export XMG_ACME_TESTCMD="true"

# 注意实际相对层级：本文件在 tests/cases/，lib 在 xmg/lib，故是 ../lib
source "$TESTS_DIR/../lib/state.sh"
source "$TESTS_DIR/../lib/render.sh"
source "$TESTS_DIR/../lib/proxy.sh"
xmg_state_init

# ------------------------------------------------------------------
# 路径导出
# ------------------------------------------------------------------
t_assert "XMG_ACME_DIR 已导出" test -n "$XMG_ACME_DIR"
t_assert "证书产物路径已导出" test -n "$XMG_ACME_CERT_FILE"
t_assert "私钥产物路径已导出" test -n "$XMG_ACME_KEY_FILE"

# ------------------------------------------------------------------
# 签发成功后应把路径写入 state
# ------------------------------------------------------------------
xmg_proxy_acme_issue example.com 2>/dev/null
t_equals "签发应返回 0" "$?" "0"
t_equals "证书来源应切为 user" "$(xmg_state_get PROXY_VLESS_CERT_SOURCE)" "user"
t_equals "证书路径已写入" "$(xmg_state_get PROXY_VLESS_CERT_FILE)" "$XMG_ACME_CERT_FILE"
t_equals "私钥路径已写入" "$(xmg_state_get PROXY_VLESS_KEY_FILE)" "$XMG_ACME_KEY_FILE"

# ------------------------------------------------------------------
# 签发失败时不得覆盖既有证书路径
# ------------------------------------------------------------------
xmg_state_set PROXY_VLESS_CERT_FILE "/old/path.crt"
xmg_state_set PROXY_VLESS_KEY_FILE "/old/path.key"
XMG_ACME_TESTCMD="false"
xmg_proxy_acme_issue example.com 2>/dev/null
t_equals "签发失败应返回 4" "$?" "4"
t_equals "失败时不覆盖已有证书路径" "$(xmg_state_get PROXY_VLESS_CERT_FILE)" "/old/path.crt"
t_equals "失败时不覆盖已有私钥路径" "$(xmg_state_get PROXY_VLESS_KEY_FILE)" "/old/path.key"

# ------------------------------------------------------------------
# 空域名应拒绝
# ------------------------------------------------------------------
XMG_ACME_TESTCMD="true"
xmg_proxy_acme_issue "" 2>/dev/null
t_equals "空域名应返回 2" "$?" "2"

# ------------------------------------------------------------------
# 恢复环境
# ------------------------------------------------------------------
XMG_ETC_DIR="$_TX_SAVED_ETC"
XMG_XRAY_STATE_DIR="$_TX_SAVED_STATE_DIR"
XMG_STATE_FILE="$_TX_SAVED_STATE_FILE"
XMG_LOG_DIR="$_TX_SAVED_LOG_DIR"
XMG_BACKUP_DIR="$_TX_SAVED_BACKUP_DIR"
XMG_XRAY_CONFIG="$_TX_SAVED_XRAY_CONFIG"
XMG_ACME_DIR="$_TX_SAVED_ACME_DIR"
XMG_ACME_CERT_FILE="$_TX_SAVED_ACME_CERT"
XMG_ACME_KEY_FILE="$_TX_SAVED_ACME_KEY"
[ -n "$_TX_HAS_ETC" ] || unset XMG_ETC_DIR
[ -n "$_TX_HAS_STATE_DIR" ] || unset XMG_XRAY_STATE_DIR
[ -n "$_TX_HAS_STATE_FILE" ] || unset XMG_STATE_FILE
[ -n "$_TX_HAS_LOG_DIR" ] || unset XMG_LOG_DIR
[ -n "$_TX_HAS_BACKUP_DIR" ] || unset XMG_BACKUP_DIR
[ -n "$_TX_HAS_XRAY_CONFIG" ] || unset XMG_XRAY_CONFIG
[ -n "$_TX_HAS_ACME_DIR" ] || unset XMG_ACME_DIR
[ -n "$_TX_HAS_ACME_CERT" ] || unset XMG_ACME_CERT_FILE
[ -n "$_TX_HAS_ACME_KEY" ] || unset XMG_ACME_KEY_FILE
if [ -n "$_TX_HAS_TEST_MODE" ]; then XMG_TEST_MODE="$_TX_SAVED_TEST_MODE"; else unset XMG_TEST_MODE; fi
if [ -n "$_TX_HAS_ACME_TESTCMD" ]; then XMG_ACME_TESTCMD="$_TX_SAVED_ACME_TESTCMD"; else unset XMG_ACME_TESTCMD; fi
unset _TX_HAS_ETC _TX_HAS_STATE_DIR _TX_HAS_STATE_FILE _TX_HAS_LOG_DIR
unset _TX_HAS_BACKUP_DIR _TX_HAS_XRAY_CONFIG
unset _TX_HAS_ACME_DIR _TX_HAS_ACME_CERT _TX_HAS_ACME_KEY
unset _TX_HAS_TEST_MODE _TX_HAS_ACME_TESTCMD
unset _TX_SAVED_ETC _TX_SAVED_STATE_DIR _TX_SAVED_STATE_FILE _TX_SAVED_LOG_DIR
unset _TX_SAVED_BACKUP_DIR _TX_SAVED_XRAY_CONFIG
unset _TX_SAVED_ACME_DIR _TX_SAVED_ACME_CERT _TX_SAVED_ACME_KEY
unset _TX_SAVED_TEST_MODE _TX_SAVED_ACME_TESTCMD
# XMG_STATE 是 state.sh 的全局关联数组，本用例改过它；清空让下一个用例重新填充。
XMG_STATE=()
# 不 unset XMG_TMP：文件头 EXIT trap 会在退出时引用它（set -u 下会报错）。
