#!/usr/bin/env bash
# WARP 原生出站收编与 Proxy 协同测试 (消除 State Drift)
# shellcheck shell=bash

_TPS_HAS_TEST_MODE="${XMG_TEST_MODE+x}"
_TPS_SAVED_TEST_MODE="${XMG_TEST_MODE-}"

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT

export XMG_HOME="$XMG_TMP/opt_xmg"
export XMG_LIB_DIR="$TESTS_DIR/../lib"
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_STATE_FILE="$XMG_XRAY_STATE_DIR/state.env"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_BACKUP_DIR="$XMG_TMP/backups"
export XMG_XRAY_CONFIG="$XMG_TMP/xray/config.json"
export XMG_WARP_DIR="$XMG_TMP/warp_etc"
export XMG_WARP_ACCOUNT_FILE="$XMG_WARP_DIR/account.json"
export XMG_WARP_ENV_FILE="$XMG_WARP_DIR/warp.env"
export XMG_WARP_XRAY_OUTBOUND="$XMG_WARP_DIR/xray_warp.json"

export XMG_TEST_MODE=1
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="true"
export XMG_PROXY_NO_RELOAD=1

mkdir -p "$XMG_WARP_DIR" "$XMG_XRAY_STATE_DIR" "$XMG_BACKUP_DIR" "$(dirname "$XMG_XRAY_CONFIG")"

# Mock WARP API 数据
SAMPLE_WARP_JSON='{
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

export XMG_MOCK_WARP_STACK="dual_stack"
export XMG_MOCK_WARP_PRIVKEY="yAn0MockPrivateKeyBase64ForTestOnly12345678="
export XMG_MOCK_WARP_PUBKEY="zBn0MockPublicKeyBase64ForTestOnly123456789="
export XMG_MOCK_WARP_API_RESP="$SAMPLE_WARP_JSON"

source "$XMG_LIB_DIR/common.sh"
source "$XMG_LIB_DIR/detect.sh"
source "$XMG_LIB_DIR/state.sh"
source "$XMG_LIB_DIR/render.sh"
source "$XMG_LIB_DIR/proxy.sh"
source "$XMG_LIB_DIR/warp.sh"

xmg_require_root() { return 0; }

# 1. 初始化 state 环境
xmg_state_init
t_assert "state.env 初始文件已生成" test -f "$XMG_STATE_FILE"
STATE_INIT="$(cat "$XMG_STATE_FILE")"
t_contains "初始状态 WARP_ENABLED=0" "$STATE_INIT" "WARP_ENABLED=0"

# 2. 启用 WARP 全局出站
t_assert "xmg_warp_enable global 执行成功" xmg_warp_enable "global"

STATE_AFTER_ENABLE="$(cat "$XMG_STATE_FILE")"
t_contains "启用后 state.env 包含 WARP_ENABLED=1" "$STATE_AFTER_ENABLE" "WARP_ENABLED=1"
t_contains "启用后 state.env 包含 WARP_MODE=global" "$STATE_AFTER_ENABLE" "WARP_MODE=global"

t_assert "已生成 Xray 主配置文件" test -f "$XMG_XRAY_CONFIG"
CFG_AFTER_ENABLE="$(cat "$XMG_XRAY_CONFIG")"
t_contains "配置包含 warp-out 出站" "$CFG_AFTER_ENABLE" '"tag": "warp-out"'
t_contains "warp-out 协议为 wireguard" "$CFG_AFTER_ENABLE" '"protocol": "wireguard"'

# 3. 执行 proxy apply（修改 socks 端口与开关）验证协同与消除 State Drift
xmg_proxy_apply --socks on --socks-port 1080 --socks-user synergy_user --socks-pass synergy_pass
t_equals "执行 proxy apply 成功" "$?" "0"

CFG_AFTER_PROXY="$(cat "$XMG_XRAY_CONFIG")"
t_contains "proxy apply 后包含 SOCKS inbound" "$CFG_AFTER_PROXY" '"tag": "inbound-socks"'
t_contains "proxy apply 后包含 socks-user" "$CFG_AFTER_PROXY" '"user": "synergy_user"'
# 关键断言：proxy apply 重新生成配置后，warp-out 依然完好无损！
t_contains "proxy apply 后依然完整保留 warp-out 出站 (消除 State Drift)" "$CFG_AFTER_PROXY" '"tag": "warp-out"'
t_contains "proxy apply 后 warp-out 协议依然为 wireguard" "$CFG_AFTER_PROXY" '"protocol": "wireguard"'

STATE_AFTER_PROXY="$(cat "$XMG_STATE_FILE")"
t_contains "proxy apply 后 state.env 依然保持 WARP_ENABLED=1" "$STATE_AFTER_PROXY" "WARP_ENABLED=1"

# 4. 停用 WARP (xmg_warp_disable) 并验证 state 与 config 联动
t_assert "xmg_warp_disable 执行成功" xmg_warp_disable

STATE_AFTER_DISABLE="$(cat "$XMG_STATE_FILE")"
t_contains "停用后 state.env 变为 WARP_ENABLED=0" "$STATE_AFTER_DISABLE" "WARP_ENABLED=0"

CFG_AFTER_DISABLE="$(cat "$XMG_XRAY_CONFIG")"
t_not_contains "停用后 config.json 不再包含 warp-out" "$CFG_AFTER_DISABLE" '"tag": "warp-out"'
t_contains "停用后 SOCKS inbound 依然完好" "$CFG_AFTER_DISABLE" '"tag": "inbound-socks"'

# 5. 停用 WARP 后再次执行 proxy apply，验证状态持续保持 WARP_ENABLED=0
xmg_proxy_apply --socks on --socks-port 2080
t_equals "再次执行 proxy apply 成功" "$?" "0"

CFG_AFTER_SECOND_PROXY="$(cat "$XMG_XRAY_CONFIG")"
t_contains "二次 apply 端口已更新为 2080" "$CFG_AFTER_SECOND_PROXY" '"port": 2080'
t_not_contains "二次 apply 后依然不含 warp-out" "$CFG_AFTER_SECOND_PROXY" '"tag": "warp-out"'

STATE_AFTER_SECOND_PROXY="$(cat "$XMG_STATE_FILE")"
t_contains "二次 apply 后 state.env 依然为 WARP_ENABLED=0" "$STATE_AFTER_SECOND_PROXY" "WARP_ENABLED=0"
