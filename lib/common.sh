#!/usr/bin/env bash**# common.sh 是 Bash 库文件，明确拒绝非 Bash**主
[ -n "${BASH_VERSION:-}" ] || {**   echo "common.sh: requires bash**>&2
    return 1 2>/dev/null || e**t 1
}

# 既兼容 source，也兼容被直接执行
if [**${XMG_COMMON_SH_LOADED:-0}" = "1"**; then
    return 0 2>/dev/null |**exit 0
fi
XMG_COMMON_SH_LOADED=1
**MG_ETC_DIR="${XMG_ETC_DIR:-/etc/x**}"
XMG_RUN_DIR="${XMG_RUN_DIR:-/r**/xmg}"
XMG_LOG_DIR="${XMG_LOG_DIR**/var/log/xmg}"
XMG_BACKUP_DIR="${**G_BACKUP_DIR:-/var/backups/xmg}"
**G******IR="${X**_WWW_DIR:-***r/www/xmg**
XMG_COLOR="${X****OLOR:-auto}"

**颜色转义序**存变量（初始化***引用，避免**径反复做**替**
X**_C_RESET=""
XMG****OLD=""
XMG**_RED=""
XMG_C**REEN=""
XMG_C****LOW=""
XMG**_CYAN=""

x****as_tty()**
    [ -t **]
}

**g_color**nabled() {
    case**$**G_COLOR" in**       always) return** ;;
        never***return 1**;
        auto)   x**_has_tty ;;
**     **)      xmg_has**ty ;;
    esac***
xmg_color_init** {
    #**动时初始化一次颜色****免***里**用 $(...)
    if xmg_color_enabled**then
        X**_C_RESET=$'\033**m'
       **MG_C_BOLD****033****
**     **MG_C_RED=$'\033**1m'
        X****_GREEN=$'\033[32m'
       ****_C_YELLOW=$**033[33m****      XMG_C_C**N=$'\033[**m'
    else
**     **MG_C_RESET**"
**      XMG_C_BOLD=""
        XMG_C**ED=""
        XMG_C_GREEN=""
    **  XMG_C_YELLOW=""
        XMG_C_C**N=""
    fi
**
# 保留这**兼容函数，供******次性脚本使用
xmg_c** {
    local**ode="$1"
   **f xmg_color_enabled***hen
       **rintf**\033[%sm' "$code"
**  fi
}

xmg_reset() {
   **f**mg_color_enabled;**hen
        printf**\033[0**
    fi
}

#***控制台提示接口：这是公共 API，不是“日志系统”
**必须保持稳定**其他模块调用**mg_info()**
    printf '%s[**FO**s %s\n**"$XMG_C**REEN***$XMG_C_RESET" "$*"
}

xmg_warn** {
**  printf '%s[**RN]%s %s****"$XMG_C**ELLOW" "$XMG**_RESET" "$*"**&**}

x**_error() {
    printf**%s[ERROR]%***s\n' "$**G_C_RED"**$XMG_C_RESET"**$*" >&2
**
**g_die** {
    xmg_error "$*"
    exit **}

xmg_cmd**xists** {
    command**v "$1" >/**v/null 2>&1**

xmg_require**ash** {
    if** -z "${BASH**ERSION**}" ]; then
**      echo "错误:**要 bash 运行"**&**        exit**
    fi
**
xmg_is_root****
    [ "${**ID}" -eq ***
}

xmg_require_root****
    xmg_is_root || xmg_die "**作需要 root**限，请使用 sudo 或**oot**户执行"
}

xmg_mkdirs() {
**  mkdir -p \
**     **$XMG**T**DIR" \
        "$XMG**UN**IR" \
        "$**G_LOG_DIR" \
**     **$XMG_BACK**_DIR" \
        "$***_WWW_DIR"
**
xmg_pause()**
**  local dummy=""
   **rintf '\n按 Enter**回...'
    read****dummy
}

x**_confirm() {
   **ocal prompt="${1:-确认****"
    local**ns=""

    printf '%***y/N]: '**$prompt"
    read -**ans || return *****  case "$ans" in
        y|Y***s|YES) return** ;;
        *)          **eturn** ;;
** **sac
}

x**_timestamp() {
    date '+%Y%m**-%H%M***
}

xmg**ackup**ile() {
    local file**$**
    local base=""
    local dst=**
    local ts=""

    [ -e "$file**] || return **
    xmg_mkdirs

**  base="$(basename "$file")"
**  ts="$(xmg_timestamp)"
    dst="**MG_BACKUP_DIR/${base**${ts}.bak"

**  cp -a "$**le**"$dst" ||**eturn 1
   **mg_info "已*** $file ->**dst"
}

x**_systemctl() {
   **ocal**ction="$1"
   **ocal service="$2"

   **mg_require_root**   **f ! xmg_cmd**xists systemctl; then**       xmg_die "**系统未发现**ystem**l，可能不是 system**系统"
    fi****  case "$action**in
        start|**op**estart|reload|**able|disable|status|**-active|is-enabled)
**         **ystemctl "$action"**$service"
            ;;
       **)
**          xmg_die "** systemctl 操作:**action"
           **;
**  esac
}
****
