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

# 归还环境
if [ -z "$_RG_HAS_TEST_MODE" ]; then
    unset XMG_TEST_MODE
else
    export XMG_TEST_MODE="$_RG_SAVED_TEST_MODE"
fi
