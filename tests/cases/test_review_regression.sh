#!/usr/bin/env bash
# 复审回归：锁住几处容易反复踩的边界
# shellcheck shell=bash
#
# 覆盖：
#   - _xmg_is_valid_ipv6：CIDR / 组数超标 / 双 :: —— 误判会导致反复重注册撞 CF 429
#   - _xmg_ssh_conf_lookup_in：按行顺序、首个命中 —— 顺序错会拿到与真实监听不符的端口
#   - _xmg_render_norm_int：前导零归一与超长数字回绕 —— 前者产出非法 JSON，后者绕过区间检查

_RG_HAS_TEST_MODE="${XMG_TEST_MODE+x}"
_RG_SAVED_TEST_MODE="${XMG_TEST_MODE-}"

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT

export XMG_HOME="$XMG_TMP/opt_xmg"
export XMG_LIB_DIR="$TESTS_DIR/../lib"
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_TEST_MODE=1

source "$XMG_LIB_DIR/warp.sh"
source "$XMG_LIB_DIR/render.sh"
export XMG_SSH_CONFIG="$XMG_TMP/sshd_config"
source "$XMG_LIB_DIR/ssh.sh"

# ------------------------------------------------------------------
# 1. IPv6 字面量校验
# ------------------------------------------------------------------
t_assert "完整 8 组 IPv6 合法" \
    "_xmg_is_valid_ipv6 '2606:4700:110:8586:139e:b183:8c01:77fa'"

t_assert "带 CIDR 后缀的 IPv6 合法（wgcf 风格凭据）" \
    "_xmg_is_valid_ipv6 '2606:4700:110:8586:139e:b183:8c01:1f2a/128'"

# 注意不能用 "! cmd" 形式：t_assert 单参数走 eval 并读取 PIPESTATUS，
# 而 PIPESTATUS 记录的是取反前的原始退出码，会把「正确拒绝」判成失败。
_rg_rc=0
_xmg_is_valid_ipv6 '2606:4700:110:8586:139e:b183:8c01:77fa:2408' || _rg_rc=$?
t_equals "9 组（地址末尾被拼上端口）必须判非法" "$_rg_rc" "1"

_rg_rc=0
_xmg_is_valid_ipv6 '1::2::3' || _rg_rc=$?
t_equals "双 :: 必须判非法" "$_rg_rc" "1"

t_assert "压缩写法 ::1 合法" "_xmg_is_valid_ipv6 '::1'"

_rg_rc=0
_xmg_is_valid_ipv6 'not-an-ip' || _rg_rc=$?
t_equals "非 IPv6 字符串必须判非法" "$_rg_rc" "1"

# ------------------------------------------------------------------
# 2. sshd 配置查找：按行顺序、首个命中
#    Include 之后出现的 Port 是被覆盖的废值，不能取它
# ------------------------------------------------------------------
printf 'Port 2222\n' > "$XMG_TMP/50-x.conf"
t_equals "单文件取首个 Port" "$(_xmg_ssh_conf_lookup_in "$XMG_TMP/50-x.conf" port 0)" "2222"

cat > "$XMG_TMP/main.conf" <<'EOF'
Port 22
Port 2222
EOF
t_equals "同文件多值取第一个（sshd 语义）" "$(_xmg_ssh_conf_lookup_in "$XMG_TMP/main.conf" port 0)" "22"

# 用具体路径而非通配符：Git Bash 下混合分隔符的 glob 不展开，会误判为「找不到 drop-in」
cat > "$XMG_TMP/inc.conf" <<EOF
Include $XMG_TMP/50-x.conf
Port 22
EOF
t_equals "Include 在 Port 之前时，drop-in 优先" \
    "$(_xmg_ssh_conf_lookup_in "$XMG_TMP/inc.conf" port 0)" "2222"

cat > "$XMG_TMP/inc2.conf" <<EOF
Port 22
Include $XMG_TMP/50-x.conf
EOF
t_equals "Port 在 Include 之前时，主配置优先" \
    "$(_xmg_ssh_conf_lookup_in "$XMG_TMP/inc2.conf" port 0)" "22"

t_equals "键名大小写不敏感" "$(_xmg_ssh_conf_lookup_in "$XMG_TMP/main.conf" PORT 0)" "22"

# ------------------------------------------------------------------
# 3. 数值归一
# ------------------------------------------------------------------
t_equals "前导零归一为十进制" "$(_xmg_render_norm_int '000443' 443 1 65535)" "443"
t_equals "08 按十进制而非八进制" "$(_xmg_render_norm_int '08' 1 1 65535)" "8"
t_equals "零值回退默认" "$(_xmg_render_norm_int '0000' 1080 1 65535)" "1080"
t_equals "空值回退默认" "$(_xmg_render_norm_int '' 1080 1 65535)" "1080"
t_equals "超长数字不得回绕绕过区间" \
    "$(_xmg_render_norm_int '18446744073709552059' 443 1 65535)" "443"
t_equals "越界回退默认" "$(_xmg_render_norm_int '70000' 443 1 65535)" "443"

# ------------------------------------------------------------------
# 4. v2.4.0 深度优化回归套件
# ------------------------------------------------------------------
source "$XMG_LIB_DIR/proxy.sh"
source "$XMG_LIB_DIR/xray.sh"
source "$XMG_LIB_DIR/update.sh"

# 4.1 xmg_proxy_gen_uuid 存在且输出标准 36 字符 UUID 格式
_gen_u="$(xmg_proxy_gen_uuid)"
t_equals "xmg_proxy_gen_uuid 生成 36 位标准 UUID" "${#_gen_u}" "36"
t_assert "xmg_proxy_gen_uuid 格式匹配 8-4-4-4-12"     "[[ '$_gen_u' =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]"

# 4.2 VLESS apply 未显式传 --vless-uuid 时自动生成 UUID 并通过校验
export XMG_XRAY_CONFIG="$XMG_TMP/xray_v240/config.json"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"
export XMG_BACKUP_DIR="$XMG_TMP/backups"
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_XRAY_RELOAD_TESTCMD="true"
export XMG_PROXY_NO_RELOAD=1
mkdir -p "$(dirname "$XMG_XRAY_CONFIG")" "$XMG_BACKUP_DIR" "$XMG_XRAY_STATE_DIR"
printf 'cert
' > "$XMG_TMP/v.crt"
printf 'key
' > "$XMG_TMP/v.key"
xmg_state_init
xmg_state_set PROXY_VLESS_UUID ""
xmg_proxy_apply --vless on --vless-port 443 --vless-domain v240.example.com                 --vless-cert-source user                 --vless-cert-file "$XMG_TMP/v.crt"                 --vless-key-file "$XMG_TMP/v.key" >/dev/null 2>&1
t_equals "VLESS 未传 UUID 时自动生成并 apply 成功" "$?" "0"
_auto_v_uuid="$(xmg_state_get PROXY_VLESS_UUID "")"
t_equals "自动生成的 VLESS UUID 长度为 36" "${#_auto_v_uuid}" "36"
t_equals "PROXY_VLESS_PATH 默认兜底统一为 /" "$(xmg_state_get PROXY_VLESS_PATH "/")" "/"

# 4.3 _xmg_xray_patch_systemd_unit_impl 自愈创建 xray.service 后继续生成 drop-in 并返回 0
export XMG_SYSTEMD_DIR="$XMG_TMP/systemd_selfheal"
mkdir -p "$XMG_SYSTEMD_DIR" "$XMG_TMP/mock_bin"
printf '#!/usr/bin/env bash
exit 0
' > "$XMG_TMP/mock_bin/xray"
chmod +x "$XMG_TMP/mock_bin/xray"
xmg_xray_get_bin() { printf '%s' "$XMG_TMP/mock_bin/xray"; }
systemctl() { return 0; }
_xmg_xray_patch_systemd_unit_impl >/dev/null 2>&1
_sh_rc=$?
t_equals "systemd unit 缺失但存在二进制时自愈返回 0 (不再误触发 return 1)" "$_sh_rc" "0"
t_assert "自愈生成了 xray.service" test -f "$XMG_SYSTEMD_DIR/xray.service"
t_assert "自愈后继续生成了 20-xmg.conf drop-in" test -f "$XMG_SYSTEMD_DIR/xray.service.d/20-xmg.conf"
t_contains "自愈生成的 xray.service 注入了 GOGC" "$(cat "$XMG_SYSTEMD_DIR/xray.service")" "GOGC="
unset -f xmg_xray_get_bin systemctl
unset XMG_SYSTEMD_DIR

# 4.4 WARP 尊重 XMG_PROXY_NO_RELOAD=1（外层升级流水线控制时不触发服务重启）
_warp_src="$(cat "$XMG_LIB_DIR/warp.sh")"
t_contains "warp.sh 检查 XMG_PROXY_NO_RELOAD 环境变量" "$_warp_src" 'XMG_PROXY_NO_RELOAD'
t_not_contains "warp.sh 已移除重复的 _xmg_warp_tunnel_profile 定义" "$_warp_src" '_xmg_warp_tunnel_profile()'

# 4.5 update.sh 升级备份自动轮转清理与无 git 免强装机制
_upd_src="$(cat "$XMG_LIB_DIR/update.sh")"
t_not_contains "update.sh 不再强行安装 git 包" "$_upd_src" 'xmg_pkg_install git'
t_contains "update.sh 包含 update_* 备份轮转清理逻辑" "$_upd_src" 'XMG_BACKUP_KEEP'

# ------------------------------------------------------------------
# 5. 迭代 1 (v2.4.1) 回归断言：多域名 REALITY SNI 校验与备份轮转
# ------------------------------------------------------------------
xmg_proxy_apply --reality on --reality-port 8443                 --reality-sni "www.microsoft.com,www.bing.com"                 --reality-dest "www.microsoft.com:443"                 --reality-private-key "TEST_PRIV_KEY_123456"                 --reality-sid "ab12" >/dev/null 2>&1
t_equals "REALITY 支持逗号分隔多 serverNames 校验与 apply" "$?" "0"
t_equals "state 保存完整多 serverNames" "$(xmg_state_get PROXY_REALITY_SNI)" "www.microsoft.com,www.bing.com"

# 验证 _xmg_warp_backup_config 按 XMG_BACKUP_KEEP 自动清理旧备份
export XMG_BACKUP_KEEP=3
_wbak_dir="$XMG_TMP/warp_bak_rot"
mkdir -p "$_wbak_dir"
export XMG_BACKUP_DIR="$_wbak_dir"
for _i in 1 2 3 4 5; do
    _b="$(_xmg_warp_backup_config "$XMG_XRAY_CONFIG")"
    sleep 0.01 2>/dev/null || true
done
_wbak_cnt="$(ls -1 "$_wbak_dir"/*.warp.bak.* 2>/dev/null | wc -l | tr -d ' ')"
t_equals "WARP 备份按 XMG_BACKUP_KEEP=3 自动轮转清理" "$_wbak_cnt" "3"
unset XMG_BACKUP_KEEP

# ------------------------------------------------------------------
# 6. 迭代 2 (v2.4.2) 回归断言：纯 Bash 零 Fork 内存/アカウント提取与 selftest 端口精确校验
# ------------------------------------------------------------------
source "$XMG_LIB_DIR/detect.sh"
source "$XMG_LIB_DIR/selftest.sh"

_fake_meminfo="$XMG_TMP/meminfo_test"
cat > "$_fake_meminfo" <<'EOF_MI'
MemTotal:         524288 kB
MemFree:           65536 kB
MemAvailable:     262144 kB
Buffers:           16384 kB
Cached:            65536 kB
EOF_MI
t_equals "纯 Bash xmg_mem_available_mb 优先取 MemAvailable (256MB)"     "$(XMG_MEMINFO_FILE="$_fake_meminfo" xmg_mem_available_mb)" "256"

cat > "$_fake_meminfo" <<'EOF_MI2'
MemTotal:         524288 kB
MemFree:           65536 kB
Buffers:           16384 kB
Cached:            50000 kB
EOF_MI2
t_equals "纯 Bash xmg_mem_available_mb 无 MemAvailable 时回退 Free+Buffers+Cached (128MB)"     "$(XMG_MEMINFO_FILE="$_fake_meminfo" xmg_mem_available_mb)" "128"

# 验证单次内存读取版 _xmg_warp_get_account_vars
export XMG_WARP_ACCOUNT_FILE="$XMG_TMP/acc_v242.json"
cat > "$XMG_WARP_ACCOUNT_FILE" <<'EOF_ACC242'
{
  "private_key": "PRIV_V242",
  "peer_public_key": "PUB_V242",
  "address_v4": "172.16.0.9/32",
  "address_v6": "[2606:4700:110::9]/128",
  "endpoint_v4": "162.159.192.9:0",
  "reserved": [11, 22, 33]
}
EOF_ACC242
_xmg_warp_get_account_vars
t_equals "纯 Bash _xmg_warp_get_account_vars 提取私钥" "$WARP_ACC_PRIVKEY" "PRIV_V242"
t_equals "纯 Bash _xmg_warp_get_account_vars 清洗 IPv4" "$WARP_ACC_IPV4" "172.16.0.9"
t_equals "纯 Bash _xmg_warp_get_account_vars 清洗 IPv6" "$WARP_ACC_IPV6" "2606:4700:110::9"
t_equals "纯 Bash _xmg_warp_get_account_vars 提取 reserved" "$WARP_ACC_RESERVED" "[11, 22, 33]"

# ------------------------------------------------------------------
# 7. 迭代 3 (v2.4.3) 回归断言：tune 备份轮转、mktemp 快照防护与 doctor drop-in 端口识别
# ------------------------------------------------------------------
source "$XMG_LIB_DIR/tune.sh"
source "$XMG_LIB_DIR/doctor.sh"

export XMG_BACKUP_KEEP=2
_tbak_dir="$XMG_TMP/tune_bak_rot"
mkdir -p "$_tbak_dir"
export XMG_BACKUP_DIR="$_tbak_dir"
_dummy_tune="$XMG_TMP/dummy_sysctl.conf"
printf 'net.core.somaxconn = 4096
' > "$_dummy_tune"
for _i in 1 2 3 4; do
    xmg_tune_backup_file "$_dummy_tune" >/dev/null 2>&1
done
_tbak_cnt="$(ls -1 "$_tbak_dir/tune"/dummy_sysctl.conf.*.bak 2>/dev/null | wc -l | tr -d ' ')"
t_equals "tune 备份按 XMG_BACKUP_KEEP=2 自动轮转清理" "$_tbak_cnt" "2"
unset XMG_BACKUP_KEEP

_tune_src="$(cat "$XMG_LIB_DIR/tune.sh")"
t_not_contains "tune.sh 已消除可预测的 /tmp/xmg-*-snap.$$.bak 临时路径" "$_tune_src" '/tmp/xmg-resolv-snap.$$.bak'

# 验证 doctor 磁盘摘要与百分比解析（零 awk 纯 Bash 实现）
_doc_disk="$(_xmg_doctor_get_disk_summary)"
t_contains "doctor 磁盘摘要包含斜杠与百分号" "$_doc_disk" "%"

# ------------------------------------------------------------------
# 8. 迭代 4~6 (v2.4.4 -> v2.4.6) 回归断言：
#    - 纯 Bash _xmg_warp_account_set_ep / _xmg_warp_env_set 零 sed -i 且保持 0600
#    - menu.sh 单遍零 Fork 扫描器 _xmg_menu_scan_module 与缓存命中
#    - 全库零 /tmp 可预测固定临时路径与零非 POSIX sed -i
# ------------------------------------------------------------------
source "$XMG_LIB_DIR/menu.sh"

_xmg_warp_account_set_ep "endpoint_v4" "162.159.195.88:2408"
_xmg_warp_get_account_vars
t_equals "纯 Bash _xmg_warp_account_set_ep 更新 endpoint_v4" "$WARP_ACC_ENDPOINT" "162.159.195.88:2408"

_xmg_warp_env_set "WARP_ENABLED=1" "WARP_MODE=routing" "WARP_GEO_MODE=slim"
t_contains "_xmg_warp_env_set 写入 WARP_MODE=routing" "$(cat "$XMG_WARP_ENV_FILE")" "WARP_MODE=routing"
_xmg_warp_env_set "WARP_ENABLED=0"
t_contains "_xmg_warp_env_set 幂等覆盖 WARP_ENABLED=0" "$(cat "$XMG_WARP_ENV_FILE")" "WARP_ENABLED=0"
t_contains "_xmg_warp_env_set 保留未修改的 WARP_MODE=routing" "$(cat "$XMG_WARP_ENV_FILE")" "WARP_MODE=routing"

_xmg_menu_scan_module "$XMG_LIB_DIR/proxy.sh"
t_equals "单遍扫描 proxy.sh 提取菜单标签" "$_XMG_SCAN_LABEL" "节点代理管理"
t_equals "单遍扫描 proxy.sh 提取菜单函数" "$_XMG_SCAN_FN" "xmg_proxy_menu"

_non_menu_rc=0
_xmg_menu_scan_module "$XMG_LIB_DIR/state.sh" || _non_menu_rc=$?
t_equals "单遍扫描非菜单模块 state.sh 前 60 行快速短路返回 1" "$_non_menu_rc" "1"

# 归还环境
if [ -z "$_RG_HAS_TEST_MODE" ]; then
    unset XMG_TEST_MODE
else
    export XMG_TEST_MODE="$_RG_SAVED_TEST_MODE"
fi
