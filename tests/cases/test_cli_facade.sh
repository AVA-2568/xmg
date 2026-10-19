#!/usr/bin/env bash
# CLI 门面路由全闭环测试
# shellcheck shell=bash

SRC="$TESTS_DIR/.."
MAIN="$SRC/xmg"

# ============================================================
# 1. version 极速输出与零依赖（即便无 lib 目录也立即可用）
# ============================================================
out_ver="$(XMG_LIB_DIR="/nonexistent" bash "$MAIN" version)"
rc_ver=$?
t_equals "xmg version 零依赖退出码为 0" "$rc_ver" "0"
t_contains "xmg version 输出包含 XMG" "$out_ver" "XMG"

out_v="$(XMG_LIB_DIR="/nonexistent" bash "$MAIN" -v)"
rc_v=$?
t_equals "xmg -v 退出码为 0" "$rc_v" "0"
t_contains "xmg -v 输出包含 XMG" "$out_v" "XMG"

out_ver2="$(XMG_LIB_DIR="/nonexistent" bash "$MAIN" --version)"
rc_ver2=$?
t_equals "xmg --version 退出码为 0" "$rc_ver2" "0"
t_contains "xmg --version 输出包含 XMG" "$out_ver2" "XMG"

# ============================================================
# 2. help 极速输出与各子命令完整性
# ============================================================
out_help="$(XMG_LIB_DIR="/nonexistent" bash "$MAIN" help)"
rc_help=$?
t_equals "xmg help 零依赖退出码为 0" "$rc_help" "0"
t_contains "帮助含 tune" "$out_help" "tune"
t_contains "帮助含 firewall" "$out_help" "firewall"
t_contains "帮助含 ssh" "$out_help" "ssh"
t_contains "帮助含 xray" "$out_help" "xray"
t_contains "帮助含 detect" "$out_help" "detect"
t_contains "帮助含 update" "$out_help" "update"
t_contains "帮助含 uninstall" "$out_help" "uninstall"
t_contains "帮助含 system" "$out_help" "system"

out_h="$(XMG_LIB_DIR="/nonexistent" bash "$MAIN" -h)"
t_equals "xmg -h 退出码为 0" "$?" "0"
t_contains "xmg -h 含用法说明" "$out_h" "用法:"

out_help2="$(XMG_LIB_DIR="/nonexistent" bash "$MAIN" --help)"
t_equals "xmg --help 退出码为 0" "$?" "0"
t_contains "xmg --help 含用法说明" "$out_help2" "用法:"

# ============================================================
# 3. 非法子命令与未知动作退出码为 2
# ============================================================
rc_invalid=0
bash "$MAIN" not_exist_sub >/dev/null 2>&1 || rc_invalid=$?
t_equals "非法顶层子命令退出码为 2" "$rc_invalid" "2"

# ============================================================
# 4. 各子命令 CLI 路由解析与正确分发
# ============================================================
MOCK_LIB="$(mktemp -d)"

cat > "$MOCK_LIB/common.sh" <<'EOF'
xmg_color_init() { :; }
xmg_info() { echo "[INFO] $*"; }
xmg_warn() { echo "[WARN] $*"; }
xmg_error() { echo "[ERROR] $*"; }
xmg_die() { echo "[DIE] $*"; exit 1; }
xmg_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
EOF

cat > "$MOCK_LIB/system.sh" <<'EOF'
xmg_system_refresh_all() { echo "MOCK_SYS_REFRESH:$*"; }
xmg_system_print_summary() { echo "MOCK_SYS_SUMMARY"; }
EOF

cat > "$MOCK_LIB/menu.sh" <<'EOF'
xmg_menu_loop() { echo "MOCK_MENU_LOOP"; }
EOF

cat > "$MOCK_LIB/monitor.sh" <<'EOF'
xmg_monitor_loop() { echo "MOCK_MONITOR_LOOP"; }
EOF

cat > "$MOCK_LIB/tune.sh" <<'EOF'
xmg_tune_bbr_enable() { echo "MOCK_TUNE_BBR:$*"; }
xmg_tune_net_optimize() { echo "MOCK_TUNE_NET:$*"; }
xmg_tune_dns_optimize() { echo "MOCK_TUNE_DNS:$*"; }
xmg_tune_dns_dot() { echo "MOCK_TUNE_DOT:$*"; }
xmg_tune_swap_panel() { echo "MOCK_TUNE_SWAP:$*"; }
xmg_tune_status() { echo "MOCK_TUNE_STATUS:$*"; }
xmg_tune_menu() { echo "MOCK_TUNE_MENU:$*"; }
EOF

cat > "$MOCK_LIB/firewall.sh" <<'EOF'
xmg_firewall_status() { echo "MOCK_FW_STATUS:$*"; }
xmg_firewall_allow() { echo "MOCK_FW_ALLOW:$*"; }
xmg_firewall_allow_basic() { echo "MOCK_FW_ALLOW_BASIC:$*"; }
xmg_firewall_enable() { echo "MOCK_FW_ENABLE:$*"; }
xmg_firewall_disable() { echo "MOCK_FW_DISABLE:$*"; }
xmg_firewall_menu() { echo "MOCK_FW_MENU:$*"; }
EOF

cat > "$MOCK_LIB/ssh.sh" <<'EOF'
xmg_ssh_show() { echo "MOCK_SSH_STATUS:$*"; }
xmg_ssh_change_port() { echo "MOCK_SSH_PORT:$*"; }
xmg_ssh_disable_password() { echo "MOCK_SSH_DISPWD:$*"; }
xmg_ssh_enable_password() { echo "MOCK_SSH_ENPWD:$*"; }
xmg_ssh_fail2ban_install() { echo "MOCK_SSH_F2B:$*"; }
xmg_ssh_menu() { echo "MOCK_SSH_MENU:$*"; }
EOF

cat > "$MOCK_LIB/xray.sh" <<'EOF'
xmg_xray_start() { echo "MOCK_XRAY_START:$*"; }
xmg_xray_stop() { echo "MOCK_XRAY_STOP:$*"; }
xmg_xray_restart() { echo "MOCK_XRAY_RESTART:$*"; }
xmg_xray_reload() { echo "MOCK_XRAY_RELOAD:$*"; }
xmg_xray_status() { echo "MOCK_XRAY_STATUS:$*"; }
xmg_xray_validate_config() { echo "MOCK_XRAY_VALIDATE:$*"; }
xmg_xray_menu() { echo "MOCK_XRAY_MENU:$*"; }
EOF

cat > "$MOCK_LIB/detect.sh" <<'EOF'
xmg_detect_virt() { echo "MOCK_DETECT_VIRT:$*"; }
xmg_detect_mem_profile() { echo "MOCK_DETECT_MEM:$*"; }
xmg_detect_network() { echo "MOCK_DETECT_NET:$*"; }
xmg_detect_status() { echo "MOCK_DETECT_STATUS:$*"; }
EOF

cat > "$MOCK_LIB/update.sh" <<'EOF'
xmg_update_check_updates() { echo "MOCK_UPDATE_CHECK:$*"; }
xmg_update_run() { echo "MOCK_UPDATE_RUN:$*"; }
xmg_update_rollback() { echo "MOCK_UPDATE_ROLLBACK:$*"; }
xmg_update_menu() { echo "MOCK_UPDATE_MENU:$*"; }
EOF

cat > "$MOCK_LIB/uninstall.sh" <<'EOF'
xmg_uninstall_run() { echo "MOCK_UNINSTALL_RUN:$*"; }
xmg_uninstall_menu() { echo "MOCK_UNINSTALL_MENU:$*"; }
EOF

# 4.1 tune 子命令分发
out_tune_bbr="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" tune bbr)"
t_equals "tune bbr 路由" "$out_tune_bbr" "MOCK_TUNE_BBR:"
out_tune_net="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" tune net)"
t_equals "tune net 路由" "$out_tune_net" "MOCK_TUNE_NET:"
out_tune_dns="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" tune dns)"
t_equals "tune dns 路由" "$out_tune_dns" "MOCK_TUNE_DNS:"
out_tune_dot="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" tune dot)"
t_equals "tune dot 路由" "$out_tune_dot" "MOCK_TUNE_DOT:"
out_tune_swap="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" tune swap)"
t_equals "tune swap 路由" "$out_tune_swap" "MOCK_TUNE_SWAP:"
out_tune_status="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" tune status)"
t_equals "tune status 路由" "$out_tune_status" "MOCK_TUNE_STATUS:"
rc_tune_invalid=0
bash "$MAIN" tune not_exist_action >/dev/null 2>&1 || rc_tune_invalid=$?
t_equals "tune 非法子命令返回 2" "$rc_tune_invalid" "2"

# 4.2 firewall 子命令分发
out_fw_status="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" firewall status)"
t_equals "firewall status 路由" "$out_fw_status" "MOCK_FW_STATUS:"
out_fw_allow="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" firewall allow 8080/tcp)"
t_equals "firewall allow 路由" "$out_fw_allow" "MOCK_FW_ALLOW:8080/tcp"
out_fw_enable="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" firewall enable)"
t_equals "firewall enable 路由" "$out_fw_enable" "MOCK_FW_ENABLE:"
out_fw_disable="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" firewall disable)"
t_equals "firewall disable 路由" "$out_fw_disable" "MOCK_FW_DISABLE:"
rc_fw_invalid=0
bash "$MAIN" firewall not_exist_action >/dev/null 2>&1 || rc_fw_invalid=$?
t_equals "firewall 非法子命令返回 2" "$rc_fw_invalid" "2"

# 4.3 ssh 子命令分发
out_ssh_status="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" ssh status)"
t_equals "ssh status 路由" "$out_ssh_status" "MOCK_SSH_STATUS:"
out_ssh_port="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" ssh port 2222)"
t_equals "ssh port 路由" "$out_ssh_port" "MOCK_SSH_PORT:2222"
out_ssh_dis="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" ssh disable-pwd)"
t_equals "ssh disable-pwd 路由" "$out_ssh_dis" "MOCK_SSH_DISPWD:"
out_ssh_en="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" ssh enable-pwd)"
t_equals "ssh enable-pwd 路由" "$out_ssh_en" "MOCK_SSH_ENPWD:"
out_ssh_f2b="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" ssh fail2ban)"
t_equals "ssh fail2ban 路由" "$out_ssh_f2b" "MOCK_SSH_F2B:"
rc_ssh_invalid=0
bash "$MAIN" ssh not_exist_action >/dev/null 2>&1 || rc_ssh_invalid=$?
t_equals "ssh 非法子命令返回 2" "$rc_ssh_invalid" "2"

# 4.4 xray 子命令分发
out_xray_start="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" xray start)"
t_equals "xray start 路由" "$out_xray_start" "MOCK_XRAY_START:"
out_xray_stop="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" xray stop)"
t_equals "xray stop 路由" "$out_xray_stop" "MOCK_XRAY_STOP:"
out_xray_restart="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" xray restart)"
t_equals "xray restart 路由" "$out_xray_restart" "MOCK_XRAY_RESTART:"
out_xray_reload="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" xray reload)"
t_equals "xray reload 路由" "$out_xray_reload" "MOCK_XRAY_RELOAD:"
out_xray_status="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" xray status)"
t_equals "xray status 路由" "$out_xray_status" "MOCK_XRAY_STATUS:"
out_xray_val="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" xray validate)"
t_equals "xray validate 路由" "$out_xray_val" "MOCK_XRAY_VALIDATE:"
rc_xray_invalid=0
bash "$MAIN" xray not_exist_action >/dev/null 2>&1 || rc_xray_invalid=$?
t_equals "xray 非法子命令返回 2" "$rc_xray_invalid" "2"

# 4.5 detect 子命令分发
out_det_virt="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" detect virt)"
t_equals "detect virt 路由" "$out_det_virt" "MOCK_DETECT_VIRT:"
out_det_mem="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" detect mem)"
t_equals "detect mem 路由" "$out_det_mem" "MOCK_DETECT_MEM:"
out_det_status="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" detect status)"
t_equals "detect status 路由" "$out_det_status" "MOCK_DETECT_STATUS:"
rc_det_invalid=0
bash "$MAIN" detect not_exist_action >/dev/null 2>&1 || rc_det_invalid=$?
t_equals "detect 非法子命令返回 2" "$rc_det_invalid" "2"

# 4.6 update 子命令分发
out_up_check="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" update check)"
t_equals "update check 路由" "$out_up_check" "MOCK_UPDATE_CHECK:"
out_up_run="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" update run)"
t_equals "update run 路由" "$out_up_run" "MOCK_UPDATE_RUN:"
out_up_rb="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" update rollback)"
t_equals "update rollback 路由" "$out_up_rb" "MOCK_UPDATE_ROLLBACK:"
rc_up_invalid=0
bash "$MAIN" update not_exist_action >/dev/null 2>&1 || rc_up_invalid=$?
t_equals "update 非法子命令返回 2" "$rc_up_invalid" "2"

# 4.7 uninstall 子命令分发
out_un_run="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" uninstall run --yes)"
t_equals "uninstall run --yes 路由" "$out_un_run" "MOCK_UNINSTALL_RUN:--yes"
out_un_yes="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" uninstall --yes)"
t_equals "uninstall --yes 路由" "$out_un_yes" "MOCK_UNINSTALL_RUN:--yes"
rc_un_invalid=0
bash "$MAIN" uninstall not_exist_action >/dev/null 2>&1 || rc_un_invalid=$?
t_equals "uninstall 非法子命令返回 2" "$rc_un_invalid" "2"

# 4.8 system 子命令分发
out_sys="$(XMG_LIB_DIR="$MOCK_LIB" bash "$MAIN" system)"
t_contains "system 刷新状态" "$out_sys" "MOCK_SYS_REFRESH:force"
t_contains "system 打印摘要" "$out_sys" "MOCK_SYS_SUMMARY"

rm -rf "$MOCK_LIB"
