#!/usr/bin/env bash
# shellcheck shell=bash
# 更新生命周期测试：原子替换、失败完整回滚与移除 17 模块硬编码

_TUR_SAVED_HOME="${XMG_HOME-}"
_TUR_SAVED_BIN="${XMG_BIN-}"
_TUR_SAVED_LINK="${XMG_LINK-}"
_TUR_SAVED_LIB="${XMG_LIB_DIR-}"
_TUR_SAVED_ETC="${XMG_ETC_DIR-}"
_TUR_SAVED_BACKUP="${XMG_BACKUP_DIR-}"

_TUR_TMP="$(mktemp -d)"
_TUR_ROOT="$_TUR_TMP/root"
mkdir -p "$_TUR_ROOT"

SRC="$TESTS_DIR/../lib"

# 1. 自声明标签与 17 模块硬编码移除检查
_up_content="$(cat "$SRC/update.sh")"
t_contains "update.sh 包含标准自声明标签" "$_up_content" "# XMG_MENU_LABEL: 版本在线升级"
t_not_contains "update.sh 彻底删除 17 模块硬编码 fallback 列表" "$_up_content" '"firewall.sh" "tune.sh" "doctor.sh" "ssh.sh" "maint.sh"'

# 加载 common.sh 与 update.sh
# shellcheck source=/dev/null
source "$SRC/common.sh"
# shellcheck source=/dev/null
source "$SRC/update.sh"

# 2. 验证清单缺失时 xmg_update_verify 不得基于写死列表假装成功
MOCK_XMG_HOME="$_TUR_ROOT/opt/xmg"
mkdir -p "$MOCK_XMG_HOME/bin" "$MOCK_XMG_HOME/lib" "$MOCK_XMG_HOME/etc/xray" "$MOCK_XMG_HOME/run" "$MOCK_XMG_HOME/log" "$MOCK_XMG_HOME/backups" "$MOCK_XMG_HOME/xray"
touch "$MOCK_XMG_HOME/bin/xmg"
chmod +x "$MOCK_XMG_HOME/bin/xmg"
mkdir -p "$_TUR_ROOT/usr/local/bin"
ln -sf "$MOCK_XMG_HOME/bin/xmg" "$_TUR_ROOT/usr/local/bin/xmg"

export XMG_HOME="$MOCK_XMG_HOME"
export XMG_BIN="$MOCK_XMG_HOME/bin/xmg"
export XMG_LINK="$_TUR_ROOT/usr/local/bin/xmg"
export XMG_LIB_DIR="$MOCK_XMG_HOME/lib"
export XMG_ETC_DIR="$MOCK_XMG_HOME/etc"
export XMG_BACKUP_DIR="$MOCK_XMG_HOME/backups"
export XMG_BIN_DIR="$MOCK_XMG_HOME/bin"
export XMG_RUN_DIR="$MOCK_XMG_HOME/run"
export XMG_LOG_DIR="$MOCK_XMG_HOME/log"
export XMG_XRAY_DIR="$MOCK_XMG_HOME/xray"

# 故意不提供 xmg.files 清单，验证必须拒绝通过
rm -f "$MOCK_XMG_HOME/xmg.files"
_verify_rc=0
xmg_update_verify >/dev/null 2>&1 || _verify_rc=$?
t_assert "缺少 xmg.files 清单时 xmg_update_verify 必须报错拒绝 (非0)" "[ $_verify_rc -ne 0 ]"

# 3. 验证更新失败时的原子回滚（保留原有 lib, bin, templates, xmg.files）
# 初始化原始运行态文件
printf '#!/usr/bin/env bash\nORIG_BIN_V1\n' > "$MOCK_XMG_HOME/bin/xmg"
chmod +x "$MOCK_XMG_HOME/bin/xmg"
printf '# ORIG_COMMON_V1\n' > "$MOCK_XMG_HOME/lib/common.sh"
printf '# ORIG_MENU_V1\n' > "$MOCK_XMG_HOME/lib/menu.sh"
mkdir -p "$MOCK_XMG_HOME/templates"
printf '{"orig": "template_v1"}\n' > "$MOCK_XMG_HOME/templates/config.template.json"
printf 'xmg\nlib/common.sh\nlib/menu.sh\ntemplates/config.template.json\nxmg.files\n' > "$MOCK_XMG_HOME/xmg.files"

# 构造一个损坏的 staging 更新包（例如损坏的语法或缺失关键文件）
_bad_update_src="$_TUR_ROOT/bad_update"
mkdir -p "$_bad_update_src/bin" "$_bad_update_src/lib"
printf 'THIS IS INVALID SYNTAX {{{(' > "$_bad_update_src/bin/xmg"
printf '# corrupted lib\n' > "$_bad_update_src/lib/common.sh"

_apply_rc=0
xmg_update_apply_atomic "$_bad_update_src" >/dev/null 2>&1 || _apply_rc=$?
t_assert "应用损坏更新包时必须失败退出 (返回非0)" "[ $_apply_rc -ne 0 ]"

# 断言：原子回滚确保原始文件分毫不差
t_contains "回滚后 bin/xmg 内容保持原版 V1" "$(cat "$MOCK_XMG_HOME/bin/xmg")" "ORIG_BIN_V1"
t_contains "回滚后 lib/common.sh 内容保持原版 V1" "$(cat "$MOCK_XMG_HOME/lib/common.sh")" "ORIG_COMMON_V1"
t_contains "回滚后 lib/menu.sh 内容保持原版 V1" "$(cat "$MOCK_XMG_HOME/lib/menu.sh")" "ORIG_MENU_V1"
t_contains "回滚后 templates 内容保持原版 V1" "$(cat "$MOCK_XMG_HOME/templates/config.template.json")" "template_v1"
t_contains "回滚后 xmg.files 保持原版清单" "$(cat "$MOCK_XMG_HOME/xmg.files")" "config.template.json"

# 4. 验证从备份完整回滚功能 (lib, bin, templates, xmg.files)
_manual_backup="$MOCK_XMG_HOME/backups/update_manual_test"
mkdir -p "$_manual_backup/bin" "$_manual_backup/lib" "$_manual_backup/templates"
printf '#!/usr/bin/env bash\nBACKUP_BIN_OK\n' > "$_manual_backup/bin/xmg"
chmod +x "$_manual_backup/bin/xmg"
printf '# BACKUP_LIB_OK\n' > "$_manual_backup/lib/common.sh"
printf '{"backup": "ok"}\n' > "$_manual_backup/templates/config.template.json"
printf 'backup.files\n' > "$_manual_backup/xmg.files"

# 破坏当前工作态
rm -rf "$MOCK_XMG_HOME/lib" "$MOCK_XMG_HOME/templates" "$MOCK_XMG_HOME/xmg.files"
printf 'BROKEN_BIN' > "$MOCK_XMG_HOME/bin/xmg"

# 调用回滚
xmg_update_rollback "$_manual_backup" >/dev/null 2>&1

t_contains "手动回滚后 bin/xmg 完整恢复" "$(cat "$MOCK_XMG_HOME/bin/xmg")" "BACKUP_BIN_OK"
t_contains "手动回滚后 lib/common.sh 完整恢复" "$(cat "$MOCK_XMG_HOME/lib/common.sh")" "BACKUP_LIB_OK"
t_contains "手动回滚后 templates 完整恢复" "$(cat "$MOCK_XMG_HOME/templates/config.template.json")" "ok"
t_contains "手动回滚后 xmg.files 完整恢复" "$(cat "$MOCK_XMG_HOME/xmg.files")" "backup.files"
t_assert "手动回滚后命令入口已正确就绪" "[ -L '$XMG_LINK' ] || [ -e '$XMG_LINK' ]"

# 清理测试现场
rm -rf "$_TUR_TMP"
[ -n "$_TUR_SAVED_HOME" ] && export XMG_HOME="$_TUR_SAVED_HOME" || unset XMG_HOME
[ -n "$_TUR_SAVED_BIN" ] && export XMG_BIN="$_TUR_SAVED_BIN" || unset XMG_BIN
[ -n "$_TUR_SAVED_LINK" ] && export XMG_LINK="$_TUR_SAVED_LINK" || unset XMG_LINK
[ -n "$_TUR_SAVED_LIB" ] && export XMG_LIB_DIR="$_TUR_SAVED_LIB" || unset XMG_LIB_DIR
[ -n "$_TUR_SAVED_ETC" ] && export XMG_ETC_DIR="$_TUR_SAVED_ETC" || unset XMG_ETC_DIR
[ -n "$_TUR_SAVED_BACKUP" ] && export XMG_BACKUP_DIR="$_TUR_SAVED_BACKUP" || unset XMG_BACKUP_DIR
unset _TUR_SAVED_HOME _TUR_SAVED_BIN _TUR_SAVED_LINK _TUR_SAVED_LIB _TUR_SAVED_ETC _TUR_SAVED_BACKUP
unset _TUR_TMP _TUR_ROOT _up_content _verify_rc _bad_update_src _apply_rc _manual_backup
