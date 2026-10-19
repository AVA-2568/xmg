#!/usr/bin/env bash
# 系统采集加固测试（Locale 国际化表头防御与 Cgroup 容器内存）
# shellcheck shell=bash

SRC="$TESTS_DIR/.."

# 隔离环境变量
_TS_SAVED_PATH="$PATH"
_TS_SAVED_LC="${LC_ALL-}"
_TS_TMP="$(mktemp -d)"

# shellcheck source=/dev/null
source "$SRC/lib/system.sh"

# ============================================================
# 1. Locale 防御：验证 xmg_read_disk_root 强制使用 LC_ALL=C
# ============================================================
# 创建 mock df，检验是否收到 LC_ALL=C
mkdir -p "$_TS_TMP/bin"
cat > "$_TS_TMP/bin/df" <<'EOF'
#!/usr/bin/env bash
if [ "${LC_ALL:-}" = "C" ]; then
    printf 'Filesystem      Size  Used Avail Use%% Mounted on\n'
    printf '/dev/sda1        40G   10G   30G  25%% /\n'
else
    # 模拟中文 locale 表头
    printf '文件系统        容量  已用  可用 已用%% 挂载点\n'
    printf '/dev/sda1        40G   10G   30G   25%% /\n'
fi
EOF
chmod +x "$_TS_TMP/bin/df"

# 临时将 mock df 置于 PATH 顶层
PATH="$_TS_TMP/bin:$PATH"

# 1.1 中文 Locale 测试
res_zh="$(LC_ALL=zh_CN.UTF-8 xmg_read_disk_root)"
pct_zh="${res_zh%% *}"
t_assert "中文 Locale 下返回有效结果" test -n "$res_zh"
t_equals "中文 Locale 下解析出纯数字百分比 25%" "$pct_zh" "25%"
t_contains "中文 Locale 下格式包含 10G/40G" "$res_zh" "10G/40G"

# 1.2 德语 Locale 测试
res_de="$(LC_ALL=de_DE.UTF-8 xmg_read_disk_root)"
pct_de="${res_de%% *}"
t_equals "德语 Locale 下解析出纯数字百分比 25%" "$pct_de" "25%"

# 恢复 PATH
PATH="$_TS_SAVED_PATH"

# ============================================================
# 2. Cgroup 容器内存感知与利用率计算测试
# ============================================================
# 2.1 Cgroup v2 内存限额计算
mkdir -p "$_TS_TMP/cgroup2"
# 限额 512MiB (536870912 字节)，当前已用 128MiB (134217728 字节) -> 利用率 25%
echo "536870912" > "$_TS_TMP/cgroup2/memory.max"
echo "134217728" > "$_TS_TMP/cgroup2/memory.current"

res_cg2="$(XMG_CGROUP_MEMORY_MAX="$_TS_TMP/cgroup2/memory.max" \
          XMG_CGROUP_MEMORY_CURRENT="$_TS_TMP/cgroup2/memory.current" \
          xmg_read_mem)"

t_equals "Cgroup v2 内存计算结果" "$res_cg2" "25%|128Mi/512Mi"

# 2.2 Cgroup v1 内存限额计算
mkdir -p "$_TS_TMP/cgroup1"
# 限额 1024MiB (1073741824 字节)，当前已用 768MiB (805306368 字节) -> 利用率 75%
echo "1073741824" > "$_TS_TMP/cgroup1/memory.limit_in_bytes"
echo "805306368" > "$_TS_TMP/cgroup1/memory.usage_in_bytes"

res_cg1="$(XMG_CGROUP_MEMORY_MAX="$_TS_TMP/nonexistent" \
          XMG_CGROUP_MEMORY_LIMIT="$_TS_TMP/cgroup1/memory.limit_in_bytes" \
          XMG_CGROUP_MEMORY_USAGE="$_TS_TMP/cgroup1/memory.usage_in_bytes" \
          xmg_read_mem)"

t_equals "Cgroup v1 内存计算结果" "$res_cg1" "75%|768Mi/1024Mi"

# 2.3 Cgroup v2 max (无限额时回退到 meminfo，不崩溃)
echo "max" > "$_TS_TMP/cgroup2/memory.max"
res_cg_max="$(XMG_CGROUP_MEMORY_MAX="$_TS_TMP/cgroup2/memory.max" \
             XMG_CGROUP_MEMORY_LIMIT="$_TS_TMP/nonexistent" \
             xmg_read_mem)"
t_assert "Cgroup max 时回退且输出不为空" test -n "$res_cg_max"
t_contains "Cgroup max 输出格式正确" "$res_cg_max" "|"

# 清理临时文件与恢复环境
rm -rf "$_TS_TMP"
if [ -n "$_TS_SAVED_LC" ]; then
    LC_ALL="$_TS_SAVED_LC"
else
    unset LC_ALL
fi
unset _TS_SAVED_PATH _TS_SAVED_LC _TS_TMP
