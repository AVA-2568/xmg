#!/usr/bin/env bash**# ===== 安全加载 =====
if [ "${XMG_XR**_SH_LOADED:-0}" = "1" ]; then
   **eturn 0 2>/dev/null || exit 0
fi
**G_XRAY_SH_LOADED=1

XMG_XRAY_SERV**E="${XMG_XRAY_SERVICE:-xray}"
X**_XRAY_INSTALL_SCRIPT_URL="${XMG_X**Y_INSTALL_SCRIPT_URL:-https://raw**ithubusercontent.com/XTLS/Xray-in**all/main/install-release.sh}"

xm**xray_binary_exists() {
    xmg_cm**exists xray
}

xmg_xray_service_e**sts() {
    xmg_cmd_exists system**l || return 1
    systemctl cat "**MG_XRAY_SERVICE" >/dev/null 2>&1
**
xmg_xray_fetch_install_script() **    local tmp=""

    xmg_require**oot

    if ! xmg_cmd_exists curl**then
        xmg_die "curl 不存在，无法** Xray 安装脚本"
    fi

    tmp="$(mk**mp)" || xmg_die "创建临时文件失败"

    i**! curl -fsSL "$XMG_XRAY_INSTALL_S**IPT_URL" -o "$tmp"; then
        ** -f "$tmp"
        xmg_die "下载 Xr** 安装脚本失败"
    fi

    if [ ! -s "$**p" ]; then
        rm -f "$tmp"
 **     xmg_die "下载到的 Xray 安装脚本为空"
 ** fi

    chmod +x "$tmp" || {
   **   rm -f "$tmp"
        xmg_die "** Xray 安装脚本执行权限失败"
    }

    prin** '%s\n' "$tmp"
}

xmg_xray_run_in**aller() {
    local action="$1"
 ** shift || true

    local script=**
    local rc=0

    script="$(xm**xray_fetch_install_script)"

    **sh "$script" "$action" "$@" || rc**?

    rm -f "$script"

    retur**"$rc"
}

xmg_xray_install_update(**{
    xmg_require_root

    if xm**xray_binary_exists; then
        **g_warn "检测到 Xray 已存在，本操作将执行安装/更新"**       if ! xmg_confirm "是否继续?"; **en
            xmg_info "已取消"
   **       return 0
        fi
    fi**    xmg_info "开始安装/更新 Xray..."

 ** if ! xmg_xray_run_installer inst**l; then
        xmg_die "Xray 安装/**失败"
    fi

    xmg_info "Xray 安装**新完成"
    xmg_warn "XMG 不处理 Xray 配**件，请用户自行维护配置"
}

# 兼容旧调用名
xmg_xray**nstall() {
    xmg_xray_install_u**ate
}

xmg_xray_update_geodata() **    xmg_require_root

    xmg_inf**"开始更新 Xray geodata..."

    if ! **g_xray_run_installer install-geod**a; then
        xmg_die "Xray geo**ta 更新失败"
    fi

    xmg_info "Xr** geodata 更新完成"
}

xmg_xray_uninst**l() {
    xmg_require_root

    i**! xmg_xray_binary_exists && ! xmg**ray_service_exists; then
        **g_warn "未检测到 Xray 已安装"
        re**rn 0
    fi

    xmg_warn "即将卸载 X**y"
    xmg_warn "XMG 不负责备份或删除用户自定**Xray 配置文件"

    if ! xmg_confirm **认卸载 Xray?"; then
        xmg_info**已取消"
        return 0
    fi

   **f ! xmg_xray_run_installer remove**then
        xmg_die "Xray 卸载失败"
**  fi

    xmg_info "Xray 已卸载"
   **mg_warn "官方卸载脚本默认可能保留 json 配置和日志文**如需彻底清理请用户自行确认后处理"
}

xmg_xray_sta**() {
    xmg_systemctl start "$XM**XRAY_SERVICE"
    xmg_info "Xray **动"
}

xmg_xray_stop() {
    xmg_s**temctl stop "$XMG_XRAY_SERVICE"
 ** xmg_info "Xray 已停止"
}

xmg_xray_**start() {
    xmg_systemctl resta** "$XMG_XRAY_SERVICE"
    xmg_info**Xray 已重启"
}

xmg_xray_status() {
**  if ! xmg_cmd_exists systemctl; **en
        xmg_warn "systemctl 不存**无法查看 Xray 状态"
        return 1
  **fi

    systemctl status "$XMG_XR**_SERVICE" --no-pager || true
}

x**_xray_menu() {
    local choice="**
    while true; do
        clear**       echo "========== Xray 管理 =**======="
        echo "1. 安装/更新 X**y"
        echo "2. 更新 Xray geoda**"
        echo "3. 卸载 Xray"
     ** echo "4. 启动 Xray"
        echo "** 停止 Xray"
        echo "6. 重启 Xra**
        echo "7. 查看 Xray 状态"
   **   echo "0. 返回"
        echo
    **  echo "说明:"
        echo "  - XM**只管理 Xray 安装和服务生命周期"
        echo ** - XMG 不创建、不编辑、不校验 Xray 配置文件"
   **   echo "  - 本模块已移除日志查看功能"
      **echo
        printf "请选择: "

    **  read -r choice || return 0

   **   case "$choice" in
            **
                xmg_xray_install**pdate
                xmg_pause
 **             ;;
            2)
  **            xmg_xray_update_geoda**
                xmg_pause
      **        ;;
            3)
       **       xmg_xray_uninstall
       **       xmg_pause
                **
            4)
                x**_xray_start
                xmg_p**se
                ;;
           **)
                xmg_xray_stop
 **             xmg_pause
          **    ;;
            6)
           **   xmg_xray_restart
             ** xmg_pause
                ;;
   **       7)
                xmg_xra**status
                xmg_pause
**              ;;
            0)
 **             return 0
           **   ;;
            *)
            **  xmg_warn "无效选择"
               **mg_pause
                ;;
     ** esac
    done
}
