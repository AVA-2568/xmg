#!/usr/bin/env bash
# WARP 模块单元测试 (方案 A: Xray 原生 WireGuard 出站)
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
export XMG_WARP_XRAY_OUTBOUND="$XMG_WARP_DIR/xray_warp.json"
export XMG_TEST_MODE=1

mkdir -p "$XMG_WARP_DIR"

# 1. 独立加载自包含性验证
_RES_LOAD="$(bash -c '
    export TESTS_DIR="'"$TESTS_DIR"'"
    export XMG_LIB_DIR="$TESTS_DIR/../lib"
    source "$XMG_LIB_DIR/warp.sh"

    declare -F xmg_warp_auto_apply >/dev/null || exit 10
    declare -F xmg_warp_status >/dev/null || exit 11
    declare -F xmg_warp_test_unlock >/dev/null || exit 12
    declare -F xmg_warp_export_xray_outbound >/dev/null || exit 13
    declare -F xmg_warp_enable >/dev/null || exit 14
    declare -F xmg_warp_disable >/dev/null || exit 15
    declare -F xmg_warp_optimize_endpoint >/dev/null || exit 16
    declare -F xmg_warp_uninstall >/dev/null || exit 17
    declare -F xmg_warp_menu >/dev/null || exit 18
    echo "LOAD_OK"
')"
_LOAD_RC=$?
t_equals "warp.sh 独立加载自包含性成功" "$_LOAD_RC" "0"
t_contains "warp 导出所有核心接口" "$_RES_LOAD" "LOAD_OK"

# 2. JSON 字段与 client_id 解码测试
source "$XMG_LIB_DIR/common.sh"
source "$XMG_LIB_DIR/detect.sh"
source "$XMG_LIB_DIR/warp.sh"
xmg_require_root() { return 0; }

SAMPLE_JSON='{
  "id": "e44d5c6b-7a8b-4c0d-9e1f-2a3b4c5d6e7f",
  "token": "secret_token_1234567890abcdef",
  "config": {
    "client_id": "5hMK",
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
VAL_CID="$(_xmg_warp_json_val "$SAMPLE_JSON" ".config.client_id")"

t_equals "JSON 解析提取 token" "$VAL_TOKEN" "secret_token_1234567890abcdef"
t_equals "JSON 解析提取 id" "$VAL_ID" "e44d5c6b-7a8b-4c0d-9e1f-2a3b4c5d6e7f"
t_equals "JSON 解析提取 v4" "$VAL_V4" "172.16.0.2"
t_equals "JSON 解析提取 v6" "$VAL_V6" "2606:4700:110:8586:139e:b183:8c01:77fa"
t_equals "JSON 解析提取 public_key" "$VAL_PUB" "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
t_equals "JSON 解析提取 client_id" "$VAL_CID" "5hMK"

DECODED_RES="$(_xmg_warp_decode_client_id "5hMK")"
t_equals "Base64 client_id 解码为 3 字节保留数值" "$DECODED_RES" "230 19 10"

# 3. 方案 A: 纯 IPv6 VPS 场景下 Xray 原生 WireGuard 出站导出与零宿主机侵入验证
export XMG_MOCK_WARP_STACK="ipv6_only"
export XMG_MOCK_WARP_PRIVKEY="yAn0MockPrivateKeyBase64ForTestOnly12345678="
export XMG_MOCK_WARP_PUBKEY="zBn0MockPublicKeyBase64ForTestOnly123456789="
export XMG_MOCK_WARP_API_RESP="$SAMPLE_JSON"

# 注册并生成凭据
_xmg_warp_register 1

t_assert "account.json 已生成" test -f "$XMG_WARP_ACCOUNT_FILE"
ACC_CONTENT="$(cat "$XMG_WARP_ACCOUNT_FILE")"
t_contains "account.json 包含 device_id" "$ACC_CONTENT" '"device_id"'
t_contains "account.json 包含 private_key" "$ACC_CONTENT" "yAn0MockPrivateKeyBase64ForTestOnly12345678="
t_contains "account.json 包含 address_v4" "$ACC_CONTENT" "172.16.0.2"
t_contains "account.json 包含 reserved [230, 19, 10]" "$ACC_CONTENT" '"reserved": [230, 19, 10]'

# 导出 Xray WireGuard 出站 JSON
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
t_contains "Xray 导出包含 noKernelTun true (保障 LXC 容器零虚拟网卡安全运行)" "$XRAY_JSON" '"noKernelTun": true'
t_contains "Xray 导出包含 reserved" "$XRAY_JSON" '"reserved": [230, 19, 10]'
t_contains "Xray 导出包含 allowedIPs" "$XRAY_JSON" '"allowedIPs"'
t_contains "纯 IPv6 下 Endpoint 使用 IPv6 端点" "$XRAY_JSON" '"endpoint": "[2606:4700:d0::a29f:c001]:2408"'
t_contains "纯 IPv6 下包含虚拟 IPv4 地址" "$XRAY_JSON" '"172.16.0.2/32"'

# 方案 A 严格不变量: 宿主机 100% 零侵入，绝不产生 /etc/wireguard/warp.conf
t_assert "方案 A: 绝不生成宿主机 warp.conf" test ! -f "$XMG_WARP_CONF"

# 4. 双栈 VPS 场景验证
export XMG_MOCK_WARP_STACK="dual_stack"
_xmg_warp_register 1

EXPORT_DUAL="$XMG_TMP/xray_dual.json"
xmg_warp_export_xray_outbound "$EXPORT_DUAL"
XRAY_DUAL_JSON="$(cat "$EXPORT_DUAL")"
t_contains "双栈下 Endpoint 使用 IPv4 端点" "$XRAY_DUAL_JSON" '"endpoint": "162.159.192.1:2408"'
t_assert "双栈下亦绝不生成宿主机 warp.conf" test ! -f "$XMG_WARP_CONF"

# 5. 控制台输出导出测试（不带文件名参数）
STDOUT_EXPORT="$(xmg_warp_export_xray_outbound)"
t_contains "控制台输出包含 tag" "$STDOUT_EXPORT" '"tag": "warp-out"'
t_contains "控制台输出包含 protocol wireguard" "$STDOUT_EXPORT" '"protocol": "wireguard"'
t_contains "控制台输出包含 reserved [230, 19, 10]" "$STDOUT_EXPORT" '"reserved": [230, 19, 10]'

# 6. 全自动 auto_apply 与 status
export XMG_MOCK_WARP_STACK="ipv6_only"
export XMG_MOCK_WARP_TRACE4="ip=104.28.192.1
loc=US
warp=on"
export XMG_MOCK_WARP_TRACE6="ip=2606:4700::1
loc=US
warp=off"

t_assert "xmg_warp_auto_apply 执行成功" xmg_warp_auto_apply

STATUS_OUT="$(xmg_warp_status)"
t_contains "status 输出包含服务状态" "$STATUS_OUT" "服务状态"
t_contains "status 输出包含 IPv4 物理出口" "$STATUS_OUT" "104.28.192.1"
t_contains "status 输出包含 宿主机 0 网卡改动说明" "$STATUS_OUT" "宿主机 0 网卡改动"

# 7. 单行紧凑 JSON 与 Endpoint 智能识别防御
MINIFIED_API_RESP='{"id":"minified-uuid-123","token":"mini-tok-abc","account":{"account_type":"free"},"config":{"client_id":"5hMK","peers":[{"public_key":"peerKeyMinified1234567890abcdef=","endpoint":{"v4":"162.159.192.1:2408","v6":"[2606:4700:d0::a29f:c005]:0","host":"engage.cloudflareclient.com:2408"}}],"interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:9999:aaaa:bbbb:cccc:dddd"}}}}'
export XMG_MOCK_WARP_API_RESP="$MINIFIED_API_RESP"
export XMG_MOCK_WARP_STACK="dual_stack"
_xmg_warp_register 1

MINI_OUT="$XMG_TMP/mini_outbound.json"
xmg_warp_export_xray_outbound "$MINI_OUT"
MINI_JSON="$(cat "$MINI_OUT")"
t_contains "单行 JSON 下 Endpoint 自动修正端口为 2408" "$MINI_JSON" '"endpoint": "162.159.192.1:2408"'
t_contains "单行 JSON 下 IPv6 纯净无端口" "$MINI_JSON" '"2606:4700:110:9999:aaaa:bbbb:cccc:dddd/128"'
t_contains "单行 JSON 下 reserved 正确注入" "$MINI_JSON" '"reserved": [230, 19, 10]'

# 8. 自愈校验: 模拟旧凭据损坏场景
cat > "$XMG_WARP_ACCOUNT_FILE" << 'EOF_CORRUPT'
{
  "device_id": "corrupted-uuid",
  "token": "tok123",
  "private_key": "somepriv",
  "public_key": "somepub",
  "address_v4": "172.16.0.2",
  "address_v6": "[2606:4700:d0::a29f:c005]:0",
  "peer_public_key": "peerpub",
  "endpoint_v6": "[2606:4700:d0::a29f:c005]:2408",
  "endpoint_v4": "162.159.192.1:2408"
}
EOF_CORRUPT

export XMG_MOCK_WARP_API_RESP="$SAMPLE_JSON"
_xmg_warp_register 0
RECOVERED_CONTENT="$(cat "$XMG_WARP_ACCOUNT_FILE")"
t_contains "自愈逻辑自动剔除被污染的内网 IPv6 并重新注册" "$RECOVERED_CONTENT" "2606:4700:110:8586:139e:b183:8c01:77fa"
t_contains "自愈逻辑自动补充 reserved 字段" "$RECOVERED_CONTENT" '"reserved": [230, 19, 10]'

# 9. IPv6 清洗工具专项测试
CLEAN_V6_NORMAL="$(_xmg_warp_clean_ipv6 "2606:4700:110:8586:139e:b183:8c01:77fa")"
CLEAN_V6_BRACKET="$(_xmg_warp_clean_ipv6 "[2606:4700:110:8586:139e:b183:8c01:77fa]")"
CLEAN_V6_CIDR="$(_xmg_warp_clean_ipv6 "2606:4700:110:8586:139e:b183:8c01:77fa/128")"
CLEAN_V6_PORT="$(_xmg_warp_clean_ipv6 "[2606:4700:d0::a29f:c005]:0")"
t_equals "标准 IPv6 清洗保持原样" "$CLEAN_V6_NORMAL" "2606:4700:110:8586:139e:b183:8c01:77fa"
t_equals "带方括号的 IPv6 自动剥除括号" "$CLEAN_V6_BRACKET" "2606:4700:110:8586:139e:b183:8c01:77fa"
t_equals "带 /128 掩码的 IPv6 自动剥除掩码" "$CLEAN_V6_CIDR" "2606:4700:110:8586:139e:b183:8c01:77fa"
t_equals "带端口的 IPv6 剥除端口与方括号" "$CLEAN_V6_PORT" "2606:4700:d0::a29f:c005"

# 10. IPv4 清洗工具专项测试
CLEAN_V4_PORT="$(_xmg_warp_clean_ipv4 "162.159.192.4:0")"
CLEAN_V4_CIDR="$(_xmg_warp_clean_ipv4 "172.16.0.2/32")"
t_equals "带端口的 IPv4 剥除端口" "$CLEAN_V4_PORT" "162.159.192.4"
t_equals "带掩码的 IPv4 剥除掩码" "$CLEAN_V4_CIDR" "172.16.0.2"

# 11. 端点优选 mock 测试
export XMG_MOCK_WARP_OPTIMIZED_EP="162.159.193.1:2408"
OPT_RES="$(xmg_warp_optimize_endpoint)"
t_contains "优选端点返回所选最佳 IP" "$OPT_RES" "162.159.193.1:2408"

# 12. 卸载纯净清理测试
t_assert "xmg_warp_uninstall 成功执行" xmg_warp_uninstall
t_assert "WARP 目录已清空" test ! -d "$XMG_WARP_DIR"
t_assert "绝不遗留宿主机配置文件" test ! -f "$XMG_WARP_CONF"

# 13. 流媒体解锁测试用例 (mock 模式)
UNLOCK_RES="$(xmg_warp_test_unlock)"
t_contains "流媒体解锁测试包含 YouTube" "$UNLOCK_RES" "YouTube"
t_contains "流媒体解锁测试包含 Netflix" "$UNLOCK_RES" "Netflix"
t_contains "流媒体解锁测试包含 ChatGPT" "$UNLOCK_RES" "ChatGPT"

# 14. 增量修改真实 Xray 配置专项测试 (保障原有 inbounds 与证书 100% 毫发无损)
EXIST_CFG="$XMG_TMP/existing_xray_config.json"
cat > "$EXIST_CFG" << 'EOF_CFG'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "inbound-vless",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "users": [
          {
            "id": "e7b0d877-4567-4abc-9def-123456789abc",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "my.vless.domain.com",
          "certificates": [
            {
              "certificateFile": "/opt/xmg/certs/fullchain.crt",
              "keyFile": "/opt/xmg/certs/privkey.key"
            }
          ]
        }
      }
    },
    {
      "tag": "inbound-socks",
      "port": 1080,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "users": [
          {
            "user": "alice",
            "pass": "secret123"
          }
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "blocked",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "blocked",
        "domain": [
          "geosite:category-ads-all"
        ]
      }
    ]
  }
}
EOF_CFG

export XMG_XRAY_CONFIG="$EXIST_CFG"
export XMG_BACKUP_DIR="$XMG_TMP/xray_bak"
mkdir -p "$XMG_BACKUP_DIR"

# 15. 启用 WARP 全局清洁出站模式 (global，默认): 验证 warp-out 为首位默认出站
t_assert "启用 WARP 全局模式执行成功" xmg_warp_enable "global"

GLOBAL_CFG="$(cat "$EXIST_CFG")"
# 验证原有 inbounds 100% 完整保留
t_contains "原有 VLESS inbound 完整保留" "$GLOBAL_CFG" '"tag": "inbound-vless"'
t_contains "原有 VLESS UUID 保持一致" "$GLOBAL_CFG" "e7b0d877-4567-4abc-9def-123456789abc"
t_contains "原有证书路径完整保留" "$GLOBAL_CFG" "/opt/xmg/certs/fullchain.crt"
t_contains "原有 SOCKS inbound 完整保留" "$GLOBAL_CFG" '"tag": "inbound-socks"'
t_contains "原有 SOCKS 用户密码保留" "$GLOBAL_CFG" "secret123"

# 验证全局模式下 warp-out 出站为首位默认出口
t_contains "全局模式注入 warp-out 出站" "$GLOBAL_CFG" '"tag": "warp-out"'
t_contains "warp-out 协议为 wireguard" "$GLOBAL_CFG" '"protocol": "wireguard"'
FIRST_TAG="$(echo "$GLOBAL_CFG" | grep -A 2 '"outbounds":' | grep '"tag"' | head -1 | cut -d'"' -f4)"
t_equals "全局模式下 warp-out 为首位出站 (默认公网出站)" "$FIRST_TAG" "warp-out"
t_contains "原有 direct 出站依旧保留在后" "$GLOBAL_CFG" '"tag": "direct"'

# 16. 分流模式 (routing) 专项测试
t_assert "启用 WARP 分流模式执行成功" xmg_warp_enable "routing"
ROUTING_CFG="$(cat "$EXIST_CFG")"
t_contains "分流模式下包含 OpenAI 分流" "$ROUTING_CFG" "domain:openai.com"
t_contains "分流模式下包含 Netflix 分流" "$ROUTING_CFG" "domain:netflix.com"
t_contains "原有广告拦截路由规则完整保留" "$ROUTING_CFG" "geosite:category-ads-all"

# 17. 验证备份机制: 修改前生成了备份
BAK_COUNT="$(ls -1 "$XMG_BACKUP_DIR"/*.bak.* 2>/dev/null | wc -l)"
t_assert "修改前成功生成了 Xray 备份文件" test "$BAK_COUNT" -gt 0

# 18. 幂等性验证: 再次执行 enable 不会产生重复出站
xmg_warp_enable "global"
IDEMPOTENT_CFG="$(cat "$EXIST_CFG")"
WARP_OUT_COUNT="$(echo "$IDEMPOTENT_CFG" | grep -o '"tag": "warp-out"' | wc -l)"
t_equals "幂等性: warp-out 出站唯一存在" "$WARP_OUT_COUNT" "1"

# 19. 关闭 WARP: 优雅剔除 warp-out 出站和相关规则，其余配置毫发无损
t_assert "优雅停用 WARP 执行成功" xmg_warp_disable

REVERTED_CFG="$(cat "$EXIST_CFG")"
t_not_contains "停用后 warp-out 出站已被剔除" "$REVERTED_CFG" '"tag": "warp-out"'
t_not_contains "停用后 openai 分流规则已被剔除" "$REVERTED_CFG" "domain:openai.com"

# 原有各项配置依然完好如初
t_contains "停用后原有 VLESS 依然完好" "$REVERTED_CFG" '"tag": "inbound-vless"'
t_contains "停用后原有 SOCKS 依然完好" "$REVERTED_CFG" '"tag": "inbound-socks"'
t_contains "停用后原有 direct 出站依然完好" "$REVERTED_CFG" '"tag": "direct"'
t_contains "停用后原有广告拦截规则依然完好" "$REVERTED_CFG" "geosite:category-ads-all"


# 20. 网络栈感知与 curl 协议族参数检测测试
export XMG_MOCK_WARP_STACK="ipv6_only"
FAM_V6="$(_xmg_warp_curl_family)"
t_equals "纯 IPv6 下 curl 参数输出 -6" "$FAM_V6" "-6"

export XMG_MOCK_WARP_STACK="dual_stack"
export XMG_NET_IPV4=1
export XMG_NET_IPV6=0
FAM_V4="$(_xmg_warp_curl_family)"
t_equals "纯 IPv4 下 curl 参数输出 -4" "$FAM_V4" "-4"

export XMG_NET_IPV4=1
export XMG_NET_IPV6=1
FAM_DUAL="$(_xmg_warp_curl_family)"
t_equals "双栈下 curl 参数不强制族限制 (留空)" "$FAM_DUAL" ""

# 21. WARP 凭据导入测试 (xmg_warp_import)
IMPORT_SRC="$XMG_TMP/valid_external_account.json"
cat > "$IMPORT_SRC" << 'EOF_IMP'
{
  "device_id": "imp-device-999",
  "token": "imp-tok-888",
  "private_key": "importedPrivateKeyForTesting1234567890=",
  "public_key": "importedPublicKeyForTesting12345678901=",
  "address_v4": "172.16.0.5",
  "address_v6": "2606:4700:110:9999::5",
  "client_id": "5hMK"
}
EOF_IMP

t_assert "导入有效凭据成功" xmg_warp_import "$IMPORT_SRC"
t_assert "目标 account.json 已写入" test -f "$XMG_WARP_ACCOUNT_FILE"
IMP_CONTENT="$(cat "$XMG_WARP_ACCOUNT_FILE")"
t_contains "导入凭据包含 private_key" "$IMP_CONTENT" "importedPrivateKeyForTesting1234567890="
t_contains "导入凭据自动根据 client_id 补全 reserved 标识" "$IMP_CONTENT" '"reserved"'
t_contains "导入凭据 reserved 包含字节 230" "$IMP_CONTENT" '230'
t_contains "导入凭据 reserved 包含字节 19" "$IMP_CONTENT" '19'
t_contains "导入凭据 reserved 包含字节 10" "$IMP_CONTENT" '10'

# 22. 凭据导入防呆: 拒绝缺失 private_key 的非法文件
INVALID_SRC="$XMG_TMP/invalid_account.json"
cat > "$INVALID_SRC" << 'EOF_INV'
{
  "device_id": "some-id",
  "token": "tok"
}
EOF_INV

INV_RC=0
xmg_warp_import "$INVALID_SRC" >/dev/null 2>&1 || INV_RC=$?
t_equals "拒绝缺失 private_key 的非法文件" "$INV_RC" "1"

# 23. 凭据导入防呆: 拒绝不存在的文件
NOT_FOUND_RC=0
xmg_warp_import "$XMG_TMP/non_existent_file.json" >/dev/null 2>&1 || NOT_FOUND_RC=$?
t_equals "拒绝不存在的文件" "$NOT_FOUND_RC" "1"

# 24. Base64 规范化专项测试 (_xmg_warp_std_b64 防 400 错误)
B64_TEST_URL="fuIwSl4SEgvtabGo4gNS-YGQ0zxZOgAGpPrpxtgvhC4"
B64_RES="$(_xmg_warp_std_b64 "$B64_TEST_URL")"
t_equals "43 字符 RawURL Base64 正确补齐为 44 字符标准 Base64" "$B64_RES" "fuIwSl4SEgvtabGo4gNS+YGQ0zxZOgAGpPrpxtgvhC4="
t_equals "标准化 Base64 长度严格为 44" "${#B64_RES}" "44"

B64_TEST_US="OJHH0HN5r2dpqDx7dSimK2_iNQVGVlfCyyO1NeY68mQ"
B64_RES2="$(_xmg_warp_std_b64 "$B64_TEST_US")"
t_equals "带下划线 URL Base64 转换为标准斜杠" "$B64_RES2" "OJHH0HN5r2dpqDx7dSimK2/iNQVGVlfCyyO1NeY68mQ="

# 25. 关键回归测试: 存在 state.env 且为标准 inbound-vless 节点时，WARP 绝不覆盖原节点配置
STAGED_CFG="$XMG_TMP/staged_vless_node.json"
cat > "$STAGED_CFG" << 'EOF_VLESS_CUSTOM'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "inbound-vless",
      "port": 54321,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "user-custom-uuid-1111-2222-333344445555",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF_VLESS_CUSTOM

# 模拟存在 state.env
mkdir -p "$(dirname "$XMG_STATE_FILE")" 2>/dev/null || true
touch "$XMG_STATE_FILE" 
export XMG_XRAY_CONFIG="$STAGED_CFG"

xmg_warp_enable "global"
PRESERVED_CONTENT="$(cat "$STAGED_CFG")"
t_contains "增量注入后用户自定义端口 54321 毫发无损" "$PRESERVED_CONTENT" "54321"
t_contains "增量注入后用户自定义 UUID 毫发无损" "$PRESERVED_CONTENT" "user-custom-uuid-1111-2222-333344445555"
t_contains "增量注入后用户 Reality 流控设置毫发无损" "$PRESERVED_CONTENT" "xtls-rprx-vision"
t_contains "增量注入后包含首选 warp-out 出站" "$PRESERVED_CONTENT" '"tag": "warp-out"'
# --- Task 1 回归：纯 Bash 字符串规整与保留字段解析能力 ---
CLEAN_V4_SPACE="$(_xmg_warp_clean_ipv4 "  172.16.0.2   ")"
CLEAN_V6_SPACE="$(_xmg_warp_clean_ipv6 "  2606:4700:110::1   ")"
t_equals "纯 Bash clean_ipv4 正确去除两端及内部空白" "$CLEAN_V4_SPACE" "172.16.0.2"
t_equals "纯 Bash clean_ipv6 正确去除两端及内部空白" "$CLEAN_V6_SPACE" "2606:4700:110::1"

# 测试 JSON 纯 Bash 提取接口与 account.json 异常保留字段提取
T_JSON_STR='{"private_key": "MOCK_KEY", "reserved": [ 12 ,  34 , 56 ]}'
t_equals "纯 Bash _xmg_warp_json_val 提取私钥" "$(_xmg_warp_json_val "$T_JSON_STR" "private_key")" "MOCK_KEY"
