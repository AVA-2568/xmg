#!/usr/bin/env bash
# WARP 模块单元测试
# shellcheck shell=bash

# --- 环境隔离 ---
_TW_HAS_TEST_MODE="${XMG_TEST_MODE+x}"
_TW_SAVED_TEST_MODE="${XMG_TEST_MODE-}"

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT

export XMG_HOME="$XMG_TMP/opt_xmg"
export XMG_LIB_DIR="$TESTS_DIR/../lib"
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_WARP_DIR="$XMG_TMP/warp_etc"
export XMG_WARP_CONF="$XMG_TMP/wireguard/warp.conf"
export XMG_WARP_ACCOUNT_FILE="$XMG_WARP_DIR/account.json"
export XMG_WARP_ENV_FILE="$XMG_WARP_DIR/warp.env"
export XMG_TEST_MODE=1

mkdir -p "$XMG_WARP_DIR" "$(dirname "$XMG_WARP_CONF")"

# 1. 独立加载自包含性验证
_RES_LOAD="$(bash -c '
    export TESTS_DIR="'"$TESTS_DIR"'"
    export XMG_LIB_DIR="$TESTS_DIR/../lib"
    source "$XMG_LIB_DIR/warp.sh"

    declare -F xmg_warp_auto_apply >/dev/null || exit 10
    declare -F xmg_warp_status >/dev/null || exit 11
    declare -F xmg_warp_test_unlock >/dev/null || exit 12
    declare -F xmg_warp_export_xray_outbound >/dev/null || exit 13
    declare -F xmg_warp_menu >/dev/null || exit 14
    declare -F xmg_warp_start >/dev/null || exit 15
    declare -F xmg_warp_stop >/dev/null || exit 16
    declare -F xmg_warp_restart >/dev/null || exit 17
    declare -F xmg_warp_uninstall >/dev/null || exit 18
    echo "LOAD_OK"
')"
_LOAD_RC=$?
t_equals "warp.sh 独立加载自包含性成功" "$_LOAD_RC" "0"
t_contains "warp 导出所有核心接口" "$_RES_LOAD" "LOAD_OK"

# 2. JSON 字段提取测试
source "$XMG_LIB_DIR/common.sh"
source "$XMG_LIB_DIR/detect.sh"
source "$XMG_LIB_DIR/warp.sh"

SAMPLE_JSON='{
  "id": "e44d5c6b-7a8b-4c0d-9e1f-2a3b4c5d6e7f",
  "token": "secret_token_1234567890abcdef",
  "config": {
    "interface": {
      "addresses": {
        "v4": "172.16.0.2",
        "v6": "2606:4700:110:8586:139e:b183:8c01:77fa"
      }
    },
    "peers": [
      {
        "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
      }
    ]
  }
}'

VAL_TOKEN="$(_xmg_warp_json_val "$SAMPLE_JSON" ".token")"
VAL_ID="$(_xmg_warp_json_val "$SAMPLE_JSON" ".id")"
VAL_V4="$(_xmg_warp_json_val "$SAMPLE_JSON" ".config.interface.addresses.v4")"
VAL_V6="$(_xmg_warp_json_val "$SAMPLE_JSON" ".config.interface.addresses.v6")"
VAL_PUB="$(_xmg_warp_json_val "$SAMPLE_JSON" ".config.peers[0].public_key")"

t_equals "JSON 解析提取 token" "$VAL_TOKEN" "secret_token_1234567890abcdef"
t_equals "JSON 解析提取 id" "$VAL_ID" "e44d5c6b-7a8b-4c0d-9e1f-2a3b4c5d6e7f"
t_equals "JSON 解析提取 v4" "$VAL_V4" "172.16.0.2"
t_equals "JSON 解析提取 v6" "$VAL_V6" "2606:4700:110:8586:139e:b183:8c01:77fa"
t_equals "JSON 解析提取 public_key" "$VAL_PUB" "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

# 3. 纯 IPv6 VPS 保护原则严格验证
export XMG_MOCK_WARP_STACK="ipv6_only"
export XMG_MOCK_WARP_PRIVKEY="yAn0MockPrivateKeyBase64ForTestOnly12345678="
export XMG_MOCK_WARP_PUBKEY="zBn0MockPublicKeyBase64ForTestOnly123456789="
export XMG_MOCK_WARP_API_RESP="$SAMPLE_JSON"

# 注册并生成配置
_xmg_warp_register 1
_xmg_warp_generate_conf

CONF_CONTENT="$(cat "$XMG_WARP_CONF")"
t_contains "纯 IPv6 下 AllowedIPs 仅接管 IPv4" "$CONF_CONTENT" "AllowedIPs = 0.0.0.0/0"
t_not_contains "纯 IPv6 下严禁包含 ::/0 路由" "$CONF_CONTENT" "::/0"
t_contains "纯 IPv6 下 Endpoint 必须为 IPv6 端点" "$CONF_CONTENT" "Endpoint = [2606:4700:d0::a29f:c001]:2408"
t_contains "内网 IPv4 写入 Address" "$CONF_CONTENT" "Address = 172.16.0.2/32"
t_contains "私钥正确写入" "$CONF_CONTENT" "PrivateKey = yAn0MockPrivateKeyBase64ForTestOnly12345678="
t_contains "保活配置正确" "$CONF_CONTENT" "PersistentKeepalive = 25"

# 4. 双栈 VPS 场景验证
export XMG_MOCK_WARP_STACK="dual_stack"
_xmg_warp_register 1
_xmg_warp_generate_conf

CONF_CONTENT_DUAL="$(cat "$XMG_WARP_CONF")"
t_contains "双栈下 AllowedIPs 为 0.0.0.0/0" "$CONF_CONTENT_DUAL" "AllowedIPs = 0.0.0.0/0"
t_contains "双栈下 Endpoint 使用 IPv4 端点" "$CONF_CONTENT_DUAL" "Endpoint = 162.159.192.1:2408"

# 5. Xray WireGuard 出站配置片段导出 (JSON) 测试
EXPORT_FILE="$XMG_TMP/xray_warp.json"
xmg_warp_export_xray_outbound "$EXPORT_FILE"
t_assert "Xray 出站导出文件已创建" test -f "$EXPORT_FILE"

XRAY_JSON="$(cat "$EXPORT_FILE")"
t_contains "Xray 导出包含 protocol wireguard" "$XRAY_JSON" '"protocol": "wireguard"'
t_contains "Xray 导出包含 tag warp-out" "$XRAY_JSON" '"tag": "warp-out"'
t_contains "Xray 导出包含 secretKey" "$XRAY_JSON" '"secretKey": "yAn0MockPrivateKeyBase64ForTestOnly12345678="'
t_contains "Xray 导出包含 peer publicKey" "$XRAY_JSON" '"publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="'
t_contains "Xray 导出包含 keepAlive" "$XRAY_JSON" '"keepAlive": 25'
t_contains "Xray 导出包含 mtu 1280" "$XRAY_JSON" '"mtu": 1280'

# 控制台输出测试（不带文件名参数）
STDOUT_EXPORT="$(xmg_warp_export_xray_outbound)"
t_contains "控制台输出包含 tag" "$STDOUT_EXPORT" '"tag": "warp-out"'

# 6. 全自动 auto_apply 与 status
export XMG_MOCK_WARP_STACK="ipv6_only"
export XMG_MOCK_WARP_TRACE4="ip=104.28.192.1
loc=US
warp=on"
export XMG_MOCK_WARP_TRACE6="ip=2606:4700::1
loc=US
warp=off"

STATUS_OUT="$(xmg_warp_status)"
t_contains "status 输出包含服务状态" "$STATUS_OUT" "服务状态"
t_contains "status 输出包含 IPv4 网络出口" "$STATUS_OUT" "104.28.192.1"
t_contains "status 输出包含 WARP: on" "$STATUS_OUT" "WARP: on"
t_contains "status 输出包含防失联保护" "$STATUS_OUT" "防失联保护"

# 连通性测试
UNLOCK_OUT="$(xmg_warp_test_unlock)"
t_contains "连通性测试包含 GitHub" "$UNLOCK_OUT" "GitHub"
t_contains "连通性测试包含 Google" "$UNLOCK_OUT" "Google"
t_contains "连通性测试包含 ChatGPT" "$UNLOCK_OUT" "ChatGPT"

# 7. 服务控制与卸载
t_assert "启动服务执行成功" xmg_warp_start
t_assert "停止服务执行成功" xmg_warp_stop
t_assert "重启服务执行成功" xmg_warp_restart
t_assert "卸载执行成功" xmg_warp_uninstall
t_assert "卸载后配置文件被清理" test ! -f "$XMG_WARP_CONF"
t_assert "卸载后环境目录被清理" test ! -d "$XMG_WARP_DIR"

# 8. xmg CLI 顶层分发测试
CLI_HELP="$("$TESTS_DIR/../xmg" help)"
t_contains "xmg help 输出包含 warp 子命令" "$CLI_HELP" "xmg warp"

CLI_STATUS="$(XMG_TEST_MODE=1 XMG_WARP_DIR="$XMG_TMP/w2" XMG_WARP_CONF="$XMG_TMP/w2.conf" "$TESTS_DIR/../xmg" warp status)"
t_contains "xmg warp status 分发正常" "$CLI_STATUS" "WARP 运行状态与出口诊断"