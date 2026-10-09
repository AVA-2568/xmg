#!/usr/bin/env bash
# state 读写与 schema 校验
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT

export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"
# state.sh 是「加载一次」的（XMG_STATE_SH_LOADED 守卫），三个路径变量只在
# 首次 source 时按当时的 XMG_ETC_DIR 推导一次。若本用例是第一个 source
# state.sh 的用例（用例按文件名排序，test_render_common.sh 会抢先），
# 不显式设 XMG_XRAY_STATE_DIR 就会沿用上一个用例的目录：xmg_state_init
# 在那里建目录并写文件，而断言读的是本用例的 XMG_STATE_FILE，
# 表现为「写成功、读为空」的假象。故三个变量必须显式齐备。
#
# 注意：框架层已在 run.sh 的用例循环里、source 每个用例之前清掉所有
# *_SH_LOADED 守卫，因此即便不写下面这行，本用例也能按自己的 XMG_ETC_DIR
# 重新加载 state.sh 并重新推导路径。这里显式导出 XMG_XRAY_STATE_DIR 是
# 为了自陈本用例依赖的路径变量、不依赖框架副作用，并非防止污染的唯一防线。
export XMG_XRAY_STATE_DIR="$XMG_ETC_DIR/xray"

# shellcheck source=../../lib/state.sh
# 注意：lib 与 tests 同级，所以是 ../lib（简报里写的 ../../lib 多退了一级）
source "$TESTS_DIR/../lib/state.sh"

# --- 默认值 ---
xmg_state_init
t_equals "默认值 SOCKS 关闭" "$(xmg_state_get PROXY_SOCKS_ENABLED)" "0"
t_equals "默认值 SOCKS 端口" "$(xmg_state_get PROXY_SOCKS_PORT)" "1080"
t_equals "默认值 SOCKS listen" "$(xmg_state_get PROXY_SOCKS_LISTEN)" "0.0.0.0"
t_equals "默认值 VLESS 关闭" "$(xmg_state_get PROXY_VLESS_ENABLED)" "0"
t_equals "默认值 mode" "$(xmg_state_get PROXY_VLESS_MODE)" "auto"
t_equals "默认值 path" "$(xmg_state_get PROXY_VLESS_PATH)" "/"
t_equals "默认值 bufferSize" "$(xmg_state_get XMG_BUFFER_SIZE)" "4"
t_equals "默认值内核通道" "$(xmg_state_get XRAY_CHANNEL)" "preview"
t_equals "默认值备份保留份数" "$(xmg_state_get XMG_BACKUP_KEEP)" "5"
t_equals "默认值 VLESS 端口" "$(xmg_state_get PROXY_VLESS_PORT)" "443"
t_equals "默认值证书来源" "$(xmg_state_get PROXY_VLESS_CERT_SOURCE)" "user"

# 权限断言只在文件系统真正支持 chmod 位时生效。
# Cygwin/挂载在 NTFS 上的目录会忽略 chmod（stat 恒为 644），那是宿主限制而非代码缺陷；
# 真实目标是 Debian/UPDATE 的 ext4，权限必须为 600。用探针决定是否断言。
#
# 探针必须先真正创建文件、再 chmod 600、然后 stat。两处都少一步都会让探针恒为 0：
#  1) 早先这里 stat 的是一个从未创建过的路径，stat 必然失败、输出空串；
#  2) 后来只补了创建、没补 chmod，但新建文件的权限由 umask 决定、从未被 chmod 过，
#     Debian/Ubuntu 默认 umask 022 → 新建文件就是 644 → 在真实 ext4 上同样恒为 0。
# 也就是说前两次修完后，权限断言在目标机上依然一次都没跑过。
# 创建后主动 chmod 600 再 stat，探针问的才是「文件系统支不支持 chmod 位」这件事：
#   Cygwin/NTFS：chmod 被忽略 → stat 644 → 跳过（宿主限制，合理）
#   真实 ext4  ：chmod 生效 → stat 600 → 断言执行
: > "$XMG_TMP/perm.probe"
chmod 600 "$XMG_TMP/perm.probe" 2>/dev/null || true
_xmg_perm_ok=0
if [ "$(stat -c '%a' "$XMG_TMP/perm.probe" 2>/dev/null)" = "600" ]; then
    _xmg_perm_ok=1
fi
if [ "$_xmg_perm_ok" = "1" ]; then
    t_equals "state 文件权限应为 600" "$(stat -c '%a' "$XMG_STATE_FILE")" "600"
    t_equals "状态目录权限应为 700" "$(stat -c '%a' "$XMG_XRAY_STATE_DIR")" "700"
    # 已存在的 755 目录必须被 init 收紧到 700：
    # 目录里放着 SOCKS5 密码文件，755 会让同机其他用户可读。
    chmod 755 "$XMG_XRAY_STATE_DIR"
    t_equals "收紧前目录为 755" "$(stat -c '%a' "$XMG_XRAY_STATE_DIR")" "755"
    xmg_state_init
    t_equals "init 应把已存在的 755 目录收紧为 700" "$(stat -c '%a' "$XMG_XRAY_STATE_DIR")" "700"
    # 同一毛病在 state 文件上：已存在的 644 文件里是密码明文，同样必须被收紧。
    chmod 644 "$XMG_STATE_FILE"
    t_equals "收紧前state 文件为 644" "$(stat -c '%a' "$XMG_STATE_FILE")" "644"
    xmg_state_init
    t_equals "init 应把已存在的 644 文件收紧为 600" "$(stat -c '%a' "$XMG_STATE_FILE")" "600"
fi

# --- 默认值关联数组（供渲染器/CLI 查表） ---
t_equals "XMG_STATE_DEFAULTS 端口" "${XMG_STATE_DEFAULTS[PROXY_VLESS_PORT]}" "443"
t_equals "XMG_STATE_DEFAULTS path" "${XMG_STATE_DEFAULTS[PROXY_VLESS_PATH]}" "/"
t_equals "XMG_STATE_DEFAULTS UUID 为空" "${XMG_STATE_DEFAULTS[PROXY_VLESS_UUID]}" ""

# --- 读写往返 ---
xmg_state_set PROXY_SOCKS_USER "alice"
t_equals "写入后读回" "$(xmg_state_get PROXY_SOCKS_USER)" "alice"
xmg_state_load
t_equals "载入后读回" "${XMG_STATE[PROXY_SOCKS_USER]}" "alice"
t_contains "state 文件已落盘" "$(cat "$XMG_STATE_FILE")" "PROXY_SOCKS_USER=alice"

# 覆盖写不得产生重复键
xmg_state_set PROXY_SOCKS_USER "bob"
xmg_state_set PROXY_SOCKS_USER "alice"
t_equals "重复写入后仍为新值" "$(xmg_state_get PROXY_SOCKS_USER)" "alice"
t_equals "重复写入不得留下重复键" "$(grep -c '^PROXY_SOCKS_USER=' "$XMG_STATE_FILE")" "1"

# --- state_all 输出全部键 ---
_all="$(xmg_state_all)"
t_contains "state_all 含 SOCKS 端口" "$_all" "PROXY_SOCKS_PORT=1080"
t_contains "state_all 含内核通道" "$_all" "XRAY_CHANNEL=preview"
t_assert "state_all 行数应与默认键数一致" test "$(printf '%s\n' "$_all" | wc -l)" -eq "$(xmg_state_defaults | wc -l)"

# --- 端口校验 ---
# 注意：不要写成 t_assert "..." test "$?" -ne 0 —— 那样 $? 在函数执行前
# 就被展开，拿到的是上一条命令的状态，断言必然失效。统一用分号 + t_equals。
xmg_state_validate_port 0; t_equals "端口 0 应拒绝" "$?" "2"
xmg_state_validate_port 443; t_equals "端口 443 应接受" "$?" "0"
xmg_state_validate_port 1080; t_equals "端口 1080 应接受" "$?" "0"
xmg_state_validate_port 1; t_equals "端口 1 应接受(下界为 1,非 0)" "$?" "0"
xmg_state_validate_port 65535; t_equals "端口 65535 应接受" "$?" "0"
xmg_state_validate_port 65536; t_equals "端口 65536 应拒绝" "$?" "2"
xmg_state_validate_port abc; t_equals "非数字端口应拒绝" "$?" "2"
xmg_state_validate_port ""; t_equals "空端口应拒绝" "$?" "2"
xmg_state_validate_port " 80"; t_equals "带空白的端口应拒绝" "$?" "2"

# ---端口超长数字串：算术回绕绕过 ---
# bash 算术是 64 位的，$((10#超长串)) 会静默回绕：
# 18446744073709551617 (=2^64+1) 归一后变成 1，落在合法区间里被当作 1 号端口接受。
# 校验必须先把前导零剥掉、按长度上限拦下，再做数值比较。
xmg_state_validate_port 18446744073709551617; t_equals "2^64+1 回绕成 1 的超长串应拒绝" "$?" "2"
xmg_state_validate_port 99999999999999999999999; t_equals "23 位全 9 应拒绝" "$?" "2"
xmg_state_validate_port 100000; t_equals "6 位数 100000 应拒绝" "$?" "2"
# 前导零是合法写法，不能因去零逻辑被误杀
xmg_state_validate_port 000443; t_equals "前导零端口 000443 应接受" "$?" "0"
xmg_state_validate_port 0000000443; t_equals "8 位前导零 0000000443 应接受" "$?" "0"
xmg_state_validate_port 0000000000000000000000443; t_equals "超长前导零但值合法应接受" "$?" "0"
# 全零等价于 0，必须被范围检查拒掉
xmg_state_validate_port 00000; t_equals "全零端口应拒绝" "$?" "2"

# --- 地址校验 ---
xmg_state_validate_ipv4or6 "0.0.0.0"; t_equals "0.0.0.0 合法" "$?" "0"
xmg_state_validate_ipv4or6 "::"; t_equals ":: 合法" "$?" "0"
xmg_state_validate_ipv4or6 "1.2.3.4"; t_equals "IPv4 合法" "$?" "0"
xmg_state_validate_ipv4or6 "not-an-ip"; t_equals "非法地址应拒绝" "$?" "2"
xmg_state_validate_ipv4or6 ""; t_equals "空地址应拒绝" "$?" "2"
xmg_state_validate_ipv4or6 "fe80::1"; t_equals "IPv6 链路本地地址合法" "$?" "0"
xmg_state_validate_ipv4or6 "2001:db8::8a2e:370:7334"; t_equals "IPv6 完整地址合法" "$?" "0"
xmg_state_validate_ipv4or6 "256.1.1.1"; t_equals "IPv4 段超 255 应拒绝" "$?" "2"
xmg_state_validate_ipv4or6 "1.2.3"; t_equals "三段 IPv4 应拒绝" "$?" "2"
xmg_state_validate_ipv4or6 "1.2.3.4.5"; t_equals "五段 IPv4 应拒绝" "$?" "2"
xmg_state_validate_ipv4or6 ":::"; t_equals "非法 IPv6 应拒绝" "$?" "2"
xmg_state_validate_ipv4or6 "1.2.3.4:x"; t_equals "混合非法地址应拒绝" "$?" "2"

# --- 枚举校验 ---
xmg_state_validate_mode "auto"; t_equals "auto 合法" "$?" "0"
xmg_state_validate_mode "packet-up"; t_equals "packet-up 合法" "$?" "0"
xmg_state_validate_mode "stream-up"; t_equals "stream-up 合法" "$?" "0"
xmg_state_validate_mode "stream-one"; t_equals "stream-one 合法" "$?" "0"
xmg_state_validate_mode "tcp"; t_equals "tcp 非法(非文档取值)" "$?" "2"
xmg_state_validate_mode ""; t_equals "空 mode 应拒绝" "$?" "2"

# ============================================================
# schema 校验：先搭一份合法基线，再逐条引入单一违规
# （每条负例都必须只被它自己的规则拦下，否则规则失效时测不出来）
# ============================================================

# 证书来源默认为 user，validate 会检查证书与私钥存在且可读，故先造两个占位文件
printf 'CERT\n' > "$XMG_TMP/cert.pem"
printf 'KEY\n' > "$XMG_TMP/key.pem"

xmg_state_set PROXY_SOCKS_ENABLED 1
xmg_state_set PROXY_SOCKS_PORT 1080
xmg_state_set PROXY_SOCKS_LISTEN "0.0.0.0"
xmg_state_set PROXY_SOCKS_USER "alice"
xmg_state_set PROXY_SOCKS_PASS "supersecret"
xmg_state_set PROXY_VLESS_ENABLED 1
xmg_state_set PROXY_VLESS_PORT 443
xmg_state_set PROXY_VLESS_LISTEN "0.0.0.0"
xmg_state_set PROXY_VLESS_DOMAIN "example.com"
xmg_state_set PROXY_VLESS_UUID "5783a3e7-e373-51cd-8642-c83782b807c5"
xmg_state_set PROXY_VLESS_PATH "/"
xmg_state_set PROXY_VLESS_MODE "auto"
xmg_state_set PROXY_VLESS_CERT_SOURCE "user"
xmg_state_set PROXY_VLESS_CERT_FILE "$XMG_TMP/cert.pem"
xmg_state_set PROXY_VLESS_KEY_FILE "$XMG_TMP/key.pem"

xmg_state_validate 2>/dev/null; t_equals "合法基线应通过" "$?" "0"

# --- schema 校验：端口冲突 ---
xmg_state_set PROXY_SOCKS_PORT 443
xmg_state_validate 2>/dev/null; t_equals "端口冲突应返回 2" "$?" "2"
xmg_state_set PROXY_SOCKS_PORT 1080
xmg_state_validate 2>/dev/null; t_equals "端口改回后应通过" "$?" "0"

# --- schema 校验：密码过短 ---
xmg_state_set PROXY_SOCKS_PASS "short"
xmg_state_validate 2>/dev/null; t_equals "密码过短应返回 2" "$?" "2"

# --- schema 校验：密码等于用户名 ---
# 负例必须只违反「相等」这一条规则。
# 早先这里用 5 字符的 "alice"（用户名也是 alice），它同时违反了密码长度规则（≥8），
# 而长度规则排在相等规则之前会先命中并 return 2 —— 于是这条断言在相等规则被删掉后
# 依然通过，规则彻底失效也测不出来（已实测复现：删掉相等规则仍 PASS=93 FAIL=0）。
# 改用 10 字符、长度合法的输入，保证命中的只能是相等规则。
xmg_state_set PROXY_SOCKS_USER "alicealice"
xmg_state_set PROXY_SOCKS_PASS "alicealice"
xmg_state_validate 2>/dev/null; t_equals "密码等于用户名应返回 2" "$?" "2"
# 复位：本用例改动了 PROXY_SOCKS_USER，后续用例仍以 alice 为基线
xmg_state_set PROXY_SOCKS_USER "alice"
xmg_state_set PROXY_SOCKS_PASS "supersecret"
xmg_state_validate 2>/dev/null; t_equals "相等规则复位后应通过" "$?" "0"

# --- schema 校验：用户名/密码为空 ---
xmg_state_set PROXY_SOCKS_PASS "supersecret"
xmg_state_set PROXY_SOCKS_USER ""
xmg_state_validate 2>/dev/null; t_equals "用户名为空应返回 2" "$?" "2"
xmg_state_set PROXY_SOCKS_USER "alice"

# --- schema 校验：VLESS UUID 为空 ---
xmg_state_set PROXY_VLESS_UUID ""
xmg_state_validate 2>/dev/null; t_equals "UUID 为空应返回 2" "$?" "2"

# --- schema 校验：非法 mode ---
xmg_state_set PROXY_VLESS_UUID "5783a3e7-e373-51cd-8642-c83782b807c5"
xmg_state_set PROXY_VLESS_MODE "tcp"
xmg_state_validate 2>/dev/null; t_equals "mode=tcp 应返回 2" "$?" "2"
xmg_state_set PROXY_VLESS_MODE "auto"

# --- schema 校验：path 未以 / 开头 ---
xmg_state_set PROXY_VLESS_PATH "xhttp"
xmg_state_validate 2>/dev/null; t_equals "path 非法应返回 2" "$?" "2"
xmg_state_set PROXY_VLESS_PATH "/"

# --- schema 校验：域名缺失 ---
xmg_state_set PROXY_VLESS_DOMAIN ""
xmg_state_validate 2>/dev/null; t_equals "域名为空应返回 2" "$?" "2"
xmg_state_set PROXY_VLESS_DOMAIN "example.com"

# --- schema 校验：端口越界（启用方案内） ---
xmg_state_set PROXY_SOCKS_PORT 70000
xmg_state_validate 2>/dev/null; t_equals "启用方案端口越界应返回 2" "$?" "2"
xmg_state_set PROXY_SOCKS_PORT 1080

# --- schema 校验：全局数值项非法 ---
xmg_state_set XMG_BUFFER_SIZE 0
xmg_state_validate 2>/dev/null; t_equals "bufferSize 非正整数应返回 2" "$?" "2"
xmg_state_set XMG_BUFFER_SIZE 4
xmg_state_set XMG_BACKUP_KEEP abc
xmg_state_validate 2>/dev/null; t_equals "备份份数非数字应返回 2" "$?" "2"
xmg_state_set XMG_BACKUP_KEEP 5

# --- schema 校验：证书来源非法 / 证书文件不可读 ---
xmg_state_set PROXY_VLESS_CERT_SOURCE "self-signed"
xmg_state_validate 2>/dev/null; t_equals "非法证书来源应返回 2" "$?" "2"
xmg_state_set PROXY_VLESS_CERT_SOURCE "user"
xmg_state_set PROXY_VLESS_CERT_FILE "$XMG_TMP/nope.pem"
xmg_state_validate 2>/dev/null; t_equals "证书文件不存在应返回 2" "$?" "2"
xmg_state_set PROXY_VLESS_CERT_FILE "$XMG_TMP/cert.pem"

# --- schema 校验：acme 来源不依赖证书文件 ---
xmg_state_set PROXY_VLESS_CERT_SOURCE "acme"
xmg_state_set PROXY_VLESS_CERT_FILE ""
xmg_state_set PROXY_VLESS_KEY_FILE ""
xmg_state_validate 2>/dev/null; t_equals "acme 来源应通过" "$?" "0"
xmg_state_set PROXY_VLESS_CERT_SOURCE "user"
xmg_state_set PROXY_VLESS_CERT_FILE "$XMG_TMP/cert.pem"
xmg_state_set PROXY_VLESS_KEY_FILE "$XMG_TMP/key.pem"

# --- schema 校验：全部合法 ---
xmg_state_validate 2>/dev/null; t_equals "合法配置应通过" "$?" "0"

# --- schema 校验：短UUID（<30 字节的自定义串）合法 ---
xmg_state_set PROXY_VLESS_UUID "my-custom-id"
xmg_state_validate 2>/dev/null; t_equals "短自定义 id 应通过" "$?" "0"
xmg_state_set PROXY_VLESS_UUID "5783a3e7-e373-51cd-8642-c83782b807c5"

# --- 未启用方案的弱校验 ---
xmg_state_set PROXY_SOCKS_ENABLED 0
xmg_state_set PROXY_VLESS_ENABLED 0
xmg_state_set PROXY_SOCKS_PASS ""
xmg_state_set PROXY_VLESS_UUID ""
xmg_state_validate 2>/dev/null; t_equals "方案全关时应通过" "$?" "0"

# --- 启用标志必须是 0/1 ---
xmg_state_set PROXY_SOCKS_ENABLED "yes"
xmg_state_validate 2>/dev/null; t_equals "ENABLED 非 0/1 应返回 2" "$?" "2"
xmg_state_set PROXY_SOCKS_ENABLED 0

# --- 校验失败信息不得回显密码 ---
# 两个前提缺一不可，否则这条断言恒真：
#  1) 必须先启用 SOCKS。早先这里在 PROXY_SOCKS_ENABLED=0 下断言，SOCKS 分支被整体
#     跳过、validate 根本不碰密码，_err 是空串，t_not_contains 在空串上必然通过。
#  2) 密码必须真的触发校验失败。早先用的 "shortpass" 有 9 个字符，≥8 的长度规则
#     放行它，validate 返回 0，_err 依旧是空串。
# 现在用 7 字符的 hunter2 走「密码长度不足」这条真实路径：实现只报长度 ${#pass}，
# 不回显密码本身（若改成回显，下面这条断言会立刻抓到）。
xmg_state_set PROXY_SOCKS_ENABLED 1
xmg_state_set PROXY_SOCKS_USER "alice"
_err="$(xmg_state_set PROXY_SOCKS_PASS "hunter2" >/dev/null 2>&1; xmg_state_validate 2>&1 >/dev/null)"
# 先证明 _err 非空，否则「不含密码」仍是空串上的假通过
t_assert "密码错误路径必须真的产生错误输出" test -n "$_err"
t_contains "错误信息应指出密码长度不足" "$_err" "至少 8"
t_not_contains "错误信息不得含密码明文" "$_err" "hunter2"
# 复位：恢复 SOCKS 关闭与空密码，供后续用例沿用
xmg_state_set PROXY_SOCKS_ENABLED 0
xmg_state_set PROXY_SOCKS_PASS ""

# --- 非法键名/多行值必须被拒绝（防止写坏文件格式） ---
xmg_state_set "BAD KEY" "v" 2>/dev/null; t_equals "非法键名应返回 1" "$?" "1"
xmg_state_set "PROXY_SOCKS_USER" "a
b" 2>/dev/null; t_equals "多行值应返回 1" "$?" "1"
#两次非法写入都应被拒，用户名仍是先前合法写入的 alice（未被覆盖也未被清空）
t_equals "非法写入未污染状态" "$(xmg_state_get PROXY_SOCKS_USER)" "alice"

# ============================================================
# --- 暂存批处理与草稿原子提交 (xmg_state_stage / commit / clear) ---
# ============================================================

# 1. stage 内存暂存与延迟落盘
xmg_state_stage "TEST_STAGE_A" "val_a"
t_equals "stage 后内存可立即读取" "$(xmg_state_get TEST_STAGE_A)" "val_a"
t_not_contains "stage 尚未提交时磁盘文件不得包含新键" "$(cat "$XMG_STATE_FILE")" "TEST_STAGE_A="

# 2. stage 参数合法性校验
xmg_state_stage "INVALID KEY" "v" 2>/dev/null; t_equals "stage 非法键名应拒绝" "$?" "1"
xmg_state_stage "TEST_KEY_BAD" "val"$'\n'"broken" 2>/dev/null; t_equals "stage 换行值应拒绝" "$?" "1"
t_equals "非法 stage 未污染内存" "$(xmg_state_get TEST_KEY_BAD)" ""

# 3. stage_clear 清空暂存并还原内存
xmg_state_stage "PROXY_SOCKS_PORT" "9999"
t_equals "stage 暂存修改端口" "$(xmg_state_get PROXY_SOCKS_PORT)" "9999"
xmg_state_stage_clear
t_equals "stage_clear 后恢复磁盘原值" "$(xmg_state_get PROXY_SOCKS_PORT)" "1080"
t_equals "未提交的新键在 stage_clear 后恢复为空" "$(xmg_state_get TEST_STAGE_A)" ""

# 4. 批量 stage 与 commit_draft 原子事务落盘
xmg_state_stage "PROXY_SOCKS_USER" "batch_alice"
xmg_state_stage "PROXY_SOCKS_PORT" "2080"
xmg_state_stage "BATCH_NEW_KEY" "batch_value"
# 提交前文件未变
t_contains "提交前文件仍为原用户名" "$(cat "$XMG_STATE_FILE")" "PROXY_SOCKS_USER=alice"
t_not_contains "提交前文件不含新键" "$(cat "$XMG_STATE_FILE")" "BATCH_NEW_KEY="

xmg_state_commit_draft
t_equals "commit_draft 应返回 0" "$?" "0"

# 提交后磁盘文件包含全部更新，且无重复键
_sf_content="$(cat "$XMG_STATE_FILE")"
t_contains "commit_draft 后磁盘包含更新后的用户名" "$_sf_content" "PROXY_SOCKS_USER=batch_alice"
t_contains "commit_draft 后磁盘包含更新后的端口" "$_sf_content" "PROXY_SOCKS_PORT=2080"
t_contains "commit_draft 后磁盘包含追加的新键" "$_sf_content" "BATCH_NEW_KEY=batch_value"
t_equals "覆盖写不产生重复 PROXY_SOCKS_USER" "$(grep -c '^PROXY_SOCKS_USER=' "$XMG_STATE_FILE")" "1"
t_equals "覆盖写不产生重复 PROXY_SOCKS_PORT" "$(grep -c '^PROXY_SOCKS_PORT=' "$XMG_STATE_FILE")" "1"

# 提交后暂存区已清空，再次 commit_draft 返回 0
xmg_state_commit_draft
t_equals "空暂存区 commit_draft 恒返回 0" "$?" "0"

# 权限保证
if [ "$_xmg_perm_ok" = "1" ]; then
    t_equals "commit_draft 后状态文件权限保持 600" "$(stat -c '%a' "$XMG_STATE_FILE")" "600"
fi
