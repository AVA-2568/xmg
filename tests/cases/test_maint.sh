#!/usr/bin/env bash
# lib/maint.sh 单元测试 — 验证 vnstat 零 fork 分支判断、磁盘概览、进程排查与菜单退出
# shellcheck shell=bash

_MAINT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset XMG_MAINT_SH_LOADED XMG_COMMON_SH_LOADED XMG_OS_SH_LOADED
# shellcheck source=/dev/null
source "$_MAINT_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$_MAINT_ROOT/lib/maint.sh"

t_assert "xmg_maint_vnstat 函数已加载" declare -F xmg_maint_vnstat
t_assert "xmg_maint_disk_overview 函数已加载" declare -F xmg_maint_disk_overview
t_assert "xmg_maint_process_inspect 函数已加载" declare -F xmg_maint_process_inspect
t_assert "xmg_maint_drop_caches 函数已加载" declare -F xmg_maint_drop_caches

# 1. 测试 xmg_maint_vnstat：初始化中（不区分大小写，零 fork 匹配 Not Enough / No Interface / Created）
_maint_out="$(
    xmg_require_root() { return 0; }
    xmg_cmd_exists() { [ "$1" = "vnstat" ]; }
    xmg_svc_supported() { return 1; }
    vnstat() { printf 'Not enough data available yet.\n'; }
    xmg_maint_vnstat 2>&1
)"
t_contains "vnstat 采样初始化文案命中" "$_maint_out" "采样库初始化中"

_maint_out2="$(
    xmg_require_root() { return 0; }
    xmg_cmd_exists() { [ "$1" = "vnstat" ]; }
    xmg_svc_supported() { return 1; }
    vnstat() { printf 'Database created for eth0\n'; }
    xmg_maint_vnstat 2>&1
)"
t_contains "vnstat created 分支命中初始化提示" "$_maint_out2" "采样库初始化中"

_maint_out3="$(
    xmg_require_root() { return 0; }
    xmg_cmd_exists() { [ "$1" = "vnstat" ]; }
    xmg_svc_supported() { return 1; }
    vnstat() { printf '2026-11   1.20 GiB | 2.30 GiB | 3.50 GiB\n'; }
    xmg_maint_vnstat 2>&1
)"
t_contains "vnstat 正常数据命中运行正常提示" "$_maint_out3" "vnstat 运行正常"

# 2. 测试 _xmg_maint_disk_line（正常返回非空字符串）
_disk_line="$(_xmg_maint_disk_line 2>/dev/null || true)"
t_assert "_xmg_maint_disk_line 正常执行不报错" test -n "$_disk_line"

# 3. 测试 xmg_maint_menu 输入 0 优雅退出
_menu_rc=0
(
    clear() { :; }
    xmg_maint_menu <<< "0" >/dev/null 2>&1
) || _menu_rc=$?
t_equals "xmg_maint_menu 输入 0 正常返回 0" "$_menu_rc" "0"

# 4. 回归测试：_xmg_uniq_pids 空输入返回空串、非空去重且无尾随空格、过滤非数字
_uniq_empty="$(_xmg_uniq_pids "")"
t_equals "_xmg_uniq_pids 空输入长度为 0" "${#_uniq_empty}" "0"
_uniq_ws="$(_xmg_uniq_pids "   ")"
t_equals "_xmg_uniq_pids 纯空白输入长度为 0" "${#_uniq_ws}" "0"
_uniq_dedup="$(_xmg_uniq_pids "271 abc 271 300")"
t_equals "_xmg_uniq_pids 去重且无尾随空格" "$_uniq_dedup" "271 300"

# 5. 回归测试：xmg_apt_find_lock_pids / xmg_apt_wait_lock 不误检无关进程，不自动强杀超时持锁进程
_lock_tmp="$(mktemp -d)"
touch "$_lock_tmp/lock-frontend" "$_lock_tmp/lock"
_pids_idle="$(XMG_APT_LOCK_FILES_OVERRIDE="$_lock_tmp/lock-frontend $_lock_tmp/lock" xmg_apt_find_lock_pids)"
t_equals "无锁状态下 xmg_apt_find_lock_pids 返回空串" "$_pids_idle" ""

( exec 9>"$_lock_tmp/lock-frontend"; sleep 10 ) &
_holder_pid=$!
sleep 0.2
_pids_busy="$(XMG_APT_LOCK_FILES_OVERRIDE="$_lock_tmp/lock-frontend $_lock_tmp/lock" xmg_apt_find_lock_pids)"
t_equals "真实持锁进程被精准检出" "$_pids_busy" "$_holder_pid"

_wait_rc=0
_wait_out="$(XMG_APT_LOCK_FILES_OVERRIDE="$_lock_tmp/lock-frontend $_lock_tmp/lock" xmg_apt_wait_lock 1 2>&1)" || _wait_rc=$?
t_equals "持锁超时返回非 0" "$_wait_rc" "1"
t_contains "持锁超时仅警告不强杀" "$_wait_out" "交由 apt 原生锁等待继续处理"
t_assert "持锁超时后真实持锁进程未被强杀" kill -0 "$_holder_pid"
kill "$_holder_pid" 2>/dev/null || true
wait "$_holder_pid" 2>/dev/null || true
rm -rf "$_lock_tmp"

# 6. 回归测试：xmg_maint_update 纯 IPv4 启用 ForceIPv4 且纯网络失败不触发删锁修复
_maint_upd_bin="$(mktemp -d)"
_maint_upd_lock="$(mktemp -d)"
touch "$_maint_upd_lock/lock-frontend"
cat > "$_maint_upd_bin/apt-get" <<'MOCK'
#!/usr/bin/env bash
echo "[MOCK apt-get] $*"
exit 0
MOCK
cat > "$_maint_upd_bin/dpkg" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = "--audit" ] && exit 0
exit 0
MOCK
chmod +x "$_maint_upd_bin/apt-get" "$_maint_upd_bin/dpkg"

_upd_v4_out="$(
    export PATH="$_maint_upd_bin:$PATH"
    export XMG_APT_LOCK_FILES_OVERRIDE="$_maint_upd_lock/lock-frontend"
    xmg_require_root() { return 0; }
    xmg_confirm() { return 0; }
    xmg_detect_network() { XMG_NET_IPV4=1; XMG_NET_IPV6=0; }
    xmg_svc_supported() { return 1; }
    xmg_maint_update 2>&1
)"
t_contains "纯 IPv4 系统更新启用 Acquire::ForceIPv4=true" "$_upd_v4_out" "Acquire::ForceIPv4=true"
t_not_contains "无锁系统更新不触发锁等待超时" "$_upd_v4_out" "包管理器锁等待超时"
rm -rf "$_maint_upd_bin" "$_maint_upd_lock"

# 7. 回归测试：根分区可用空间 <300MB 预警
_low_df_out="$(
    xmg_require_root() { return 0; }
    xmg_confirm() { return 1; }
    df() {
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
        printf '/dev/vda1 10485760 10300000 185760 99%% /\n'
    }
    xmg_maint_update 2>&1
)"
t_contains "根分区空间不足触发更新前预警" "$_low_df_out" "可用空间仅 181MB (<300MB)"

# 8. 回归测试：dpkg 中断 (stderr + 非 0 退出码) 触发自愈重试 + SSH 宕机强告警
_maint_edge_dir="$(mktemp -d)"
mkdir -p "$_maint_edge_dir/bin" "$_maint_edge_dir/lock"
touch "$_maint_edge_dir/lock/lock-frontend"
cat > "$_maint_edge_dir/bin/apt-get" <<MOCK
#!/usr/bin/env bash
if [[ "\$*" == *" upgrade "* ]] && [ ! -f "$_maint_edge_dir/repaired" ]; then
    echo "E: dpkg was interrupted" >&2
    exit 100
fi
exit 0
MOCK
cat > "$_maint_edge_dir/bin/dpkg" <<MOCK
#!/usr/bin/env bash
if [ "\${1:-}" = "--audit" ] && [ ! -f "$_maint_edge_dir/repaired" ]; then
    echo "dpkg: error: dpkg was interrupted" >&2
    exit 2
fi
[ "\${1:-}" = "--configure" ] && touch "$_maint_edge_dir/repaired"
exit 0
MOCK
chmod +x "$_maint_edge_dir/bin/apt-get" "$_maint_edge_dir/bin/dpkg"

_edge_out="$(
    export PATH="$_maint_edge_dir/bin:$PATH"
    export XMG_APT_LOCK_FILES_OVERRIDE="$_maint_edge_dir/lock/lock-frontend"
    export XMG_XRAY_CONFIG="/nonexistent"
    xmg_require_root() { return 0; }
    xmg_confirm() { return 0; }
    xmg_detect_network() { XMG_NET_IPV4=1; XMG_NET_IPV6=1; }
    xmg_svc_supported() { return 0; }
    xmg_svc_is_active() { return 1; }
    xmg_svc_start() { return 1; }
    xmg_maint_update 2>&1
)"
t_contains "dpkg stderr 中断被精准识别并触发修复" "$_edge_out" "检测到 dpkg 数据库存在中断"
t_contains "更新后 SSH 全挂触发防失联强告警" "$_edge_out" "切勿断开当前 SSH 会话"
rm -rf "$_maint_edge_dir"
