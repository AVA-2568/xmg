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
xmg_require_root() { return 0; }

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

# 9. 压缩单行 JSON 真实 API 响应提取测试 (防 endpoint 覆盖 addresses)
MINIFIED_API_RESP='{"id":"minified-uuid-123","token":"mini-tok-abc","account":{"account_type":"free"},"config":{"peers":[{"public_key":"peerKeyMinified1234567890abcdef=","endpoint":{"v4":"162.159.192.1:2408","v6":"[2606:4700:d0::a29f:c005]:0","host":"engage.cloudflareclient.com:2408"}}],"interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:9999:aaaa:bbbb:cccc:dddd"}}}}'

export XMG_MOCK_WARP_API_RESP="$MINIFIED_API_RESP"
export XMG_MOCK_WARP_PRIVKEY="mockPrivKeyMinified99999999999999="
export XMG_MOCK_WARP_PUBKEY="mockPubKeyMinified99999999999999="
export XMG_MOCK_WARP_STACK="dual_stack"

# 强制重新注册，验证提取
_xmg_warp_register 1
_xmg_warp_generate_conf

MINI_CONF="$(cat "$XMG_WARP_CONF")"
t_contains "单行 JSON 下 interface v6 正确提取" "$MINI_CONF" "Address = 172.16.0.2/32, 2606:4700:110:9999:aaaa:bbbb:cccc:dddd/128"
t_not_contains "单行 JSON 下 Address 严禁包含中括号" "$MINI_CONF" "[2606:"
t_not_contains "单行 JSON 下 Address 严禁包含端口号" "$MINI_CONF" ":0/128"
t_contains "单行 JSON 下 Endpoint 自动修正端口为 2408" "$MINI_CONF" "Endpoint = 162.159.192.1:2408"

# 10. 历史损坏凭据 (被误存为 endpoint 格式) 自动自愈测试
cat > "$XMG_WARP_ACCOUNT_FILE" <<EOF
{
  "device_id": "corrupted-device-id",
  "token": "corrupted-token",
  "private_key": "corruptedPrivateKeyBase64==",
  "public_key": "corruptedPublicKeyBase64==",
  "address_v4": "172.16.0.2",
  "address_v6": "[2606:4700:d0::a29f:c005]:0",
  "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
  "endpoint_v6": "[2606:4700:d0::a29f:c005]:2408",
  "endpoint_v4": "162.159.192.1:2408"
}
EOF

# 触发非强制注册 (force=0)，必须能识别出 corrupted 并重新注册
_xmg_warp_register 0
_xmg_warp_generate_conf

HEALED_CONF="$(cat "$XMG_WARP_CONF")"
t_not_contains "自愈后 Address 绝不含被污染的 [2606" "$HEALED_CONF" "[2606:4700:d0::a29f:c005]"
t_contains "自愈后重新获取了纯净凭据" "$HEALED_CONF" "2606:4700:110:9999:aaaa:bbbb:cccc:dddd"

# 11. 清洗函数独立健壮性测试
CLEAN_V6_NORMAL="$(_xmg_warp_clean_ipv6 "2606:4700:110:8586:139e:b183:8c01:77fa")"
CLEAN_V6_BRACKET="$(_xmg_warp_clean_ipv6 "[2606:4700:110:8586:139e:b183:8c01:77fa]")"
CLEAN_V6_PORT="$(_xmg_warp_clean_ipv6 "[2606:4700:d0::a29f:c005]:0")"
CLEAN_V6_PORT2408="$(_xmg_warp_clean_ipv6 "2606:4700:d0::a29f:c005:2408")"
CLEAN_V6_CIDR="$(_xmg_warp_clean_ipv6 "2606:4700:110:8586:139e:b183:8c01:77fa/128")"
CLEAN_V6_INVALID="$(_xmg_warp_clean_ipv6 "not-a-valid-ip")"

t_equals "标准 IPv6 清洗保持原样" "$CLEAN_V6_NORMAL" "2606:4700:110:8586:139e:b183:8c01:77fa"
t_equals "带方括号的 IPv6 自动剥除括号" "$CLEAN_V6_BRACKET" "2606:4700:110:8586:139e:b183:8c01:77fa"
t_equals "带 :0 端口的 endpoint 格式被安全丢弃" "$CLEAN_V6_PORT" ""
t_equals "带 /128 掩码的 IPv6 自动剥除掩码" "$CLEAN_V6_CIDR" "2606:4700:110:8586:139e:b183:8c01:77fa"
t_equals "非法 IPv6 字符串被安全丢弃" "$CLEAN_V6_INVALID" ""

CLEAN_V4_NORMAL="$(_xmg_warp_clean_ipv4 "172.16.0.2")"
CLEAN_V4_CIDR="$(_xmg_warp_clean_ipv4 "172.16.0.2/32")"
CLEAN_V4_PORT="$(_xmg_warp_clean_ipv4 "162.159.192.4:0")"

t_equals "标准 IPv4 清洗保持原样" "$CLEAN_V4_NORMAL" "172.16.0.2"
t_equals "带 CIDR 掩码的 IPv4 自动剥除掩码" "$CLEAN_V4_CIDR" "172.16.0.2"
t_equals "带端口的历史错误 IPv4 自动纠偏为 172.16.0.2" "$CLEAN_V4_PORT" "172.16.0.2"

# 12. 原生地理位置探测与友好国家名称测试
export XMG_MOCK_WARP_NATIVE_LOC="HK"
export XMG_MOCK_WARP_NATIVE_COLO="HKG"
export XMG_MOCK_WARP_NATIVE_IP="203.0.113.88"
xmg_warp_detect_native_geo

t_equals "原生地区代码解析正确" "$XMG_WARP_NATIVE_LOC" "HK"
t_equals "原生机房代码解析正确" "$XMG_WARP_NATIVE_COLO" "HKG"
t_equals "原生 IP 解析正确" "$XMG_WARP_NATIVE_IP" "203.0.113.88"

NAME_HK="$(_xmg_warp_country_name "HK")"
NAME_JP="$(_xmg_warp_country_name "JP")"
NAME_SG="$(_xmg_warp_country_name "SG")"
NAME_US="$(_xmg_warp_country_name "US")"

t_equals "HK 映射为中国香港" "$NAME_HK" "中国香港 (HK)"
t_equals "JP 映射为日本" "$NAME_JP" "日本 (JP)"
t_equals "SG 映射为新加坡" "$NAME_SG" "新加坡 (SG)"
t_equals "US 映射为美国" "$NAME_US" "美国 (US)"

# 13. 端点优选 (Optimize Endpoint) 测试
export XMG_MOCK_WARP_OPTIMIZED_EP="162.159.193.1:2408"
OPT_RES="$(xmg_warp_optimize_endpoint)"
t_contains "优选端点返回所选最佳 IP" "$OPT_RES" "162.159.193.1:2408"

# 14. 状态看板包含地区一致性核验与 Google 识别
export XMG_MOCK_WARP_STACK="ipv6_only"
export XMG_MOCK_WARP_TRACE4="ip=104.28.192.1
loc=HK
colo=HKG
warp=on"
export XMG_MOCK_WARP_TRACE6="ip=2606:4700::1
loc=HK
colo=HKG
warp=off"
export XMG_MOCK_WARP_GOOGLE_LOC="HK"

STATUS_GEO="$(xmg_warp_status)"
t_contains "status 输出包含 VPS 本地原生地区" "$STATUS_GEO" "VPS 本地原生地区"
t_contains "status 输出包含 WARP 出口归属地区" "$STATUS_GEO" "WARP 出口归属地区"
t_contains "status 输出包含 Google 权威地区" "$STATUS_GEO" "Google 权威地区"
t_contains "status 输出包含 100% 保持本地一致" "$STATUS_GEO" "100% 保持本地一致 (PASS)"

# 15. CLI 分发 optimize 子命令测试
CLI_OPT="$("$TESTS_DIR/../xmg" warp optimize)"
t_contains "xmg warp optimize 分发正常" "$CLI_OPT" "优选完成"
