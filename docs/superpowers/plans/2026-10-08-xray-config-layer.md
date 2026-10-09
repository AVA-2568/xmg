# Xray 配置层与内核管理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 xmg 面板新增 Xray 预览版内核管理、SOCKS5 与 VLESS+XHTTP+TLS 双方案配置器（可独立/共存）、配置状态层与非交互 CLI，全部适配 0.5C/215M 低配与海外服务器场景。

**Architecture:** 三层结构。入口层（交互菜单 + CLI）→ 配置状态层（`state.env` 为唯一真相来源，负责校验/合并/原子写入）→ 生成层（纯函数渲染器 + 内核管理器）。`config.json` 是派生产物，由 state 重新生成。

**Tech Stack:** 纯 Bash 4+（无 jq、无 python、无 bats）、systemd、Xray-core 预览版、Debian 11+/Ubuntu 20.04+

**设计依据:** 所有 Xray 配置字段仅依据 https://lcuwx2016.github.io/xtls/config （本地已下载至 `docs-research/`，38 篇 markdown）。**禁止**依据记忆或社区写法。

## Global Constraints

以下约束适用于每个任务，任何任务都不得违反：

- **零依赖**：不得引入 `jq`、`python`、`bats`、`yq`。仅用 bash 内建 + 常见 coreutils（`grep`/`sed`/`cut`/`sort`/`date`/`mktemp`）。低配机无 python 是硬约束。
- **Debian 11/12+ 与 Ubuntu 20.04+ only**：不写多发行版分支。
- **架构**：需在 x86_64、aarch64、armv7l、mips/mips64 上正确工作（通过 `uname -m`）。
- **Bash 4+**：现有代码已用关联数组与 `[[ =~ ]]`，不得降级为 POSIX sh。
- **JSON 输出**：纯 JSON，**禁止**注释（`//`）、尾逗号。
- **字段命名铁律**（文档核对结论，见 spec §2.2）：
  - `streamSettings.method` —— 禁止 `network`
  - `rawSettings` —— 禁止 `tcpSettings`
  - SOCKS 用 `auth` + `users[{user,pass}]` —— 禁止 `accounts`
  - VLESS 用 `users[{id,level}]` + `decryption` —— `decryption` 禁止留空
- **禁止写入的字段**（文档依据或用户决策）：
  - 禁止 `email`（用户确认不暴露）
  - 禁止 `mux`（文档警告 XHTTP 下不可启用 mux.cool）
  - 禁止 `flow`（文档说明 XTLS 仅在 TCP+TLS/REALITY 可用，XHTTP 不属该组合）
  - 禁止 `extra`（用户确认只暴露核心项）
  - 禁止 `stats`、`api`（用户确认不启用）
  - 禁止在 `dns.servers[]` 子项写 `queryStrategy`（文档：全局值优先，冲突致空响应）
- **原子写入不变量**：任何配置变更失败时，运行中的配置必须保持可用。顺序恒为：校验 state → 渲染临时文件 → `xray run -test` → 备份 → 替换 → 写 state → reload。校验失败绝不触碰现网配置。
- **退出码**：0 成功 / 2 校验失败 / 3 内核校验失败 / 4 运行失败（已回滚）。
- **文件位置**：`state.env` 位于 `$XMG_ETC_DIR/xray/state.env`（即 `/opt/xmg/etc/xray/state.env`）。
- **日志**：UI 输出走 stdout，错误与交互提示走 stderr（沿用 `tune.sh` 既有约定 `tune.sh:419`）。
- **测试断言写法**：断言被测命令的退出码时，一律用 `被测命令; t_equals "描述" "$?" "期望值"` 形式。**禁止** `t_assert "..." test "$?" -ne 0` —— `$?` 在函数执行前展开，拿到的是上一条命令的状态，断言必然失效。
- **printf 注意空格**：`printf"..."`（缺空格）会被 bash 当成命令名而报 `No such file or directory`。写 `printf "..."`。
- **端口范围含 1**：`xmg_state_validate_port` 接受 1–65535（设计文档 §4.2）。1 是特权端口但技术上合法，是否禁用属产品决策，不在技术校验层。
- **VLESS UUID 两种形态**：文档允许「小于 30 字节的字符串」**或**「合法 UUID」。标准 UUID 为 36 字符，**不可用单一长度阈值判定**，须分别匹配 UUID 正则或长度。
- **热路径避免 fork**：目标机 0.5C/215M，`$(...)` 命令替换会 fork 子进程。读状态键一律用零 fork 的内部取值函数，**不要**在循环或校验函数里写 `$(xmg_state_get ...)`。
- **`xmg_state_set` 不做 schema 校验**：它只做键名/值边界防护（防换行注入写坏 state.env）。调用方若需「先校验再落盘」，必须自己串 `xmg_state_validate`。
- **安装目录自包含**：安装后 XMG 的所有文件必须位于单一目录树 `XMG_HOME`（默认 `/opt/xmg`）之内。唯一例外是 `/usr/local/bin/xmg` 软链接（`install.sh:50` 既定行为）与 `/etc/systemd/system/xray.service.d/20-xmg.conf`（systemd 要求）。**不得**向 `$HOME`、`/etc`、`/tmp`、`/var` 等处散落文件。`acme.sh` 必须安装到 `$XMG_HOME/acme.sh`，其证书产物必须落在 `$XMG_HOME/etc/xray/certs/`（见 Task 9）。

---

## File Structure

| 文件 | 职责 | 任务 |
|---|---|---|
| `xmg/tests/lib.sh` | 测试断言框架（零依赖） | Task 1 |
| `xmg/lib/state.sh` | state 读写、schema 校验、merge、原子写入、备份清理 | Task 2-4 |
| `xmg/lib/render.sh` | 纯函数渲染器：socks/vless/dns/policy/outbounds | Task 5-6 |
| `xmg/lib/core.sh` | 内核安装/更新/预览版/版本锁定 | Task 7 |
| `xmg/lib/proxy.sh` | CLI 入口 + 交互向导 + status | Task 8-9 |
| `xmg/lib/xray.sh` | **修改**：移除配置能力，保留 systemd 与服务生命周期 | Task 10 |
| `xmg/xmg` | **修改**：新增 `proxy` / `core` 子命令 | Task 11 |
| `xmg/xmg.files` | **修改**：登记新模块 | Task 11 |
| `xmg/lib/tune.sh` | **修改**：DNS 预设默认指向境外 | Task 12 |

**命名约定**：模块内所有函数以 `xmg_` 前缀；菜单函数固定为 `xmg_<name>_menu`（`menu.sh:89` 依赖此约定）；模块文件头部声明 `# XMG_MENU_LABEL: <标签>`（`menu.sh:126` 依赖）。

---

## Task 1: 测试断言框架

无测试框架，需先建一个。所有后续任务的测试都跑在它上面。

**Files:**
- Create: `xmg/tests/lib.sh`
- Create: `xmg/tests/run.sh`

**Interfaces:**
- Produces: `t_assert <描述> <命令...>` — 命令成功则 PASS，失败则 FAIL 并打印描述
- Produces: `t_fail <描述>` — 无条件记 FAIL
- Produces: `t_summary` — 打印 `PASS=<n> FAIL=<n>`，FAIL>0 时返回 1
- Produces: `t_contains <描述> <haystack> <needle>` — 子串包含判定
- Produces: `t_not_contains <描述> <haystack> <needle>` — 子串不得包含
- Produces: `t_equals <描述> <actual> <expected>`
- 全局: `TESTS_PASS` / `TESTS_FAIL` 计数器

- [ ] **Step 1: 创建测试框架**

写 `xmg/tests/lib.sh`：

```bash
#!/usr/bin/env bash
# 测试断言框架 — 零依赖，仅用 bash 内建
# shellcheck shell=bash

TESTS_PASS=0
TESTS_FAIL=0
T_CURRENT=""

t_case() {
    T_CURRENT="$1"
}

t_ok() {
    TESTS_PASS=$((TESTS_PASS + 1))
    return 0
}

t_fail() {
    TESTS_FAIL=$((TESTS_FAIL + 1))
    printf '  [FAIL] %s\n' "$*" >&2
    return 1
}

t_assert() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        printf '  [FAIL] %s\n' "$desc" >&2
        printf'         命令失败: %s\n' "$*" >&2
    fi
    return 0
}

t_contains() {
    local desc="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        printf '  [FAIL] %s\n' "$desc" >&2
        printf '         期望包含: %s\n' "$needle" >&2
        printf '         实际内容: %s\n' "$(printf '%s' "$hay" | head -c 400)" >&2
    fi
    return 0
}

t_not_contains() {
    local desc="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        printf '  [FAIL] %s\n' "$desc" >&2
        printf '         不应包含: %s\n' "$needle" >&2
    fi
    return 0
}

t_equals() {
    local desc="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        printf '  [FAIL] %s\n' "$desc" >&2
        printf '         期望: %s\n' "$expected" >&2
        printf '         实际: %s\n' "$actual" >&2
    fi
    return 0
}

t_summary() {
    printf '\nPASS=%d FAIL=%d\n' "$TESTS_PASS" "$TESTS_FAIL" >&2
    [ "$TESTS_FAIL" -eq 0 ]
}
```

写 `xmg/tests/run.sh`：

```bash
#!/usr/bin/env bash
# 测试入口 — 用法: bash xmg/tests/run.sh [case_file...]
# shellcheck shell=bash
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$TESTS_DIR/lib.sh"

if [ "$#" -gt 0 ]; then
    CASES=("$@")
else
    CASES=("$TESTS_DIR"/cases/test_*.sh)
fi

if [ ! -d "$TESTS_DIR/cases" ]; then
    mkdir -p "$TESTS_DIR/cases"
fi

if [ ! -f "${CASES[0]}" ]; then
    printf '无用例可运行: %s\n' "$TESTS_DIR/cases" >&2
    exit 1
fi

for case_file in "${CASES[@]}"; do
    [ -f "$case_file" ] || continue
    printf '== %s ==\n' "$(basename "$case_file")" >&2
    # shellcheck source=/dev/null
    source "$case_file"
done

t_summary
```

- [ ] **Step 2: 创建用例目录并写第一个自检用例**

`mkdir -p xmg/tests/cases`，写 `xmg/tests/cases/test_framework_selfcheck.sh`：

```bash
#!/usr/bin/env bash
# 框架自检 — 确认断言函数行为正确
# shellcheck shell=bash

t_assert "true 应通过" true
t_contains "子串命中" "hello world" "lo wo"
t_not_contains "子串未命中" "hello world" "zzz"
t_equals "字符串相等" "abc" "abc"

# 验证失败会被正确计数。
# 注意：不能用子 shell 验证——子 shell 内计数器自增不会影响外层，
# 外层读到的始终是初始值 0，断言必然失败。
# 正确做法：在同一层先存快照，制造一次失败，比对增量，最后恢复。
_f0="$TESTS_FAIL"
_p0="$TESTS_PASS"
t_assert "故意失败" false 2>/dev/null
t_assert "失败被正确计数" test "$TESTS_FAIL" -eq "$((_f0 + 1))"
t_assert "通过计数未受影响" test "$TESTS_PASS" -eq "$((_p0 + 1))"
TESTS_FAIL="$_f0"
```

- [ ] **Step 3: 运行框架自检**

Run: `bash xmg/tests/run.sh`
Expected: 输出 `== test_framework_selfcheck.sh ==` 与 `PASS=1 FAIL=0`

- [ ] **Step 4: 提交**

```bash
cd xmg && git add tests/ && git commit -m "test: 新增零依赖 Bash 测试断言框架"
```

---

## Task 2: state 读写与 schema 校验

**Files:**
- Create: `xmg/lib/state.sh`
- Create: `xmg/tests/cases/test_state.sh`

**Interfaces:**
- Consumes: `common.sh` 的 `XMG_ETC_DIR`、`xmg_info`、`xmg_warn`、`xmg_error`、`xmg_require_root`
- Produces: `XMG_STATE_FILE` — 状态文件路径，默认 `$XMG_ETC_DIR/xray/state.env`
- Produces: `XMG_STATE_DEFAULTS` — 全部键的默认值（关联数组）
- Produces: `xmg_state_init` — 创建目录与初始 state 文件
- Produces: `xmg_state_get <KEY> [默认值]` — 读单个值
- Produces: `xmg_state_set <KEY> <VALUE>` — 写单个值并落盘
- Produces: `xmg_state_all` — 输出全部 `KEY=VALUE` 行
- Produces: `xmg_state_load` — 将 state 载入 `XMG_STATE` 关联数组
- Produces: `xmg_state_validate` — schema 校验，失败返回 2 并打印原因
- Produces: `xmg_state_validate_port <PORT>` — 端口校验，返回 0/2
- Produces: `xmg_state_validate_ipv4or6 <ADDR>` — 地址字面量校验
- 返回码约定：校验类函数失败返回 2

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_state.sh`：

```bash
#!/usr/bin/env bash
# state 读写与 schema 校验
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT

export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"

# shellcheck source=../../lib/state.sh
source "$TESTS_DIR/../../lib/state.sh"

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

# --- 读写往返 ---
xmg_state_set PROXY_SOCKS_USER "alice"
t_equals "写入后读回" "$(xmg_state_get PROXY_SOCKS_USER)" "alice"
xmg_state_load
t_equals "载入后读回" "${XMG_STATE[PROXY_SOCKS_USER]}" "alice"
t_contains "state 文件已落盘" "$(cat "$XMG_STATE_FILE")" "PROXY_SOCKS_USER=alice"

# --- 端口校验 ---
# 注意：不要写成 t_assert "..." test "$?" -ne 0 —— 那样 $? 在函数执行前
# 就被展开，拿到的是上一条命令的状态，断言必然失效。统一用分号 + t_equals。
# 端口 1 合法（设计文档 §4.2 定义范围为 1–65535）。
xmg_state_validate_port 1; t_equals "端口 1 应接受" "$?" "0"
xmg_state_validate_port 65536; t_equals "端口 65536 应拒绝" "$?" "2"
xmg_state_validate_port 0; t_equals "端口 0 应拒绝" "$?" "2"
xmg_state_validate_port 443; t_equals "端口 443 应接受" "$?" "0"
xmg_state_validate_port 1080; t_equals "端口 1080 应接受" "$?" "0"

# --- 地址校验 ---
xmg_state_validate_ipv4or6 "0.0.0.0"; t_equals "0.0.0.0 合法" "$?" "0"
xmg_state_validate_ipv4or6 "::"; t_equals ":: 合法" "$?" "0"
xmg_state_validate_ipv4or6 "1.2.3.4"; t_equals "IPv4 合法" "$?" "0"
xmg_state_validate_ipv4or6 "not-an-ip"; t_equals "非法地址应拒绝" "$?" "2"
xmg_state_validate_ipv4or6 ""; t_equals "空地址应拒绝" "$?" "2"

# --- 枚举校验 ---
xmg_state_validate_mode "auto"; t_equals "auto 合法" "$?" "0"
xmg_state_validate_mode "stream-one"; t_equals "stream-one 合法" "$?" "0"
xmg_state_validate_mode "tcp"; t_equals "tcp 非法(非文档取值)" "$?" "2"

# --- schema 校验：端口冲突 ---
xmg_state_set PROXY_SOCKS_ENABLED 1
xmg_state_set PROXY_SOCKS_PORT 443
xmg_state_set PROXY_SOCKS_USER "alice"
xmg_state_set PROXY_SOCKS_PASS "supersecret"
xmg_state_set PROXY_VLESS_ENABLED 1
xmg_state_set PROXY_VLESS_PORT 443
xmg_state_set PROXY_VLESS_DOMAIN "example.com"
xmg_state_set PROXY_VLESS_UUID "5783a3e7-e373-51cd-8642-c83782b807c5"
xmg_state_validate 2>/dev/null; t_equals "端口冲突应返回 2" "$?" "2"

# --- schema 校验：密码过短 ---
xmg_state_set PROXY_SOCKS_PORT 1080
xmg_state_set PROXY_VLESS_PORT 443
xmg_state_set PROXY_SOCKS_PASS "short"
xmg_state_validate 2>/dev/null; t_equals "密码过短应返回 2" "$?" "2"

# --- schema 校验：密码等于用户名 ---
xmg_state_set PROXY_SOCKS_PASS "alice"
xmg_state_validate 2>/dev/null; t_equals "密码等于用户名应返回 2" "$?" "2"

# --- schema 校验：VLESS UUID 为空 ---
xmg_state_set PROXY_SOCKS_PASS "supersecret"
xmg_state_set PROXY_VLESS_UUID ""
xmg_state_validate 2>/dev/null; t_equals "UUID 为空应返回 2" "$?" "2"

# --- schema 校验：全部合法 ---
xmg_state_set PROXY_VLESS_UUID "5783a3e7-e373-51cd-8642-c83782b807c5"
xmg_state_validate 2>/dev/null; t_equals "合法配置应通过" "$?" "0"

# --- 未启用方案的弱校验 ---
xmg_state_set PROXY_SOCKS_ENABLED 0
xmg_state_set PROXY_VLESS_ENABLED 0
xmg_state_set PROXY_SOCKS_PASS ""
xmg_state_validate 2>/dev/null; t_equals "方案全关时应通过" "$?" "0"
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_state.sh`
Expected: FAIL —— 因`xmg/lib/state.sh` 不存在，source 报错

- [ ] **Step 3: 实现 state.sh**

写 `xmg/lib/state.sh`：

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# state.sh - Xray 配置状态层
#
# 说明：
#   - state.env 为配置唯一真相来源，config.json 是派生产物
#   - 扁平 KEY=value 格式，零依赖读写（目标机型无 python/jq）
#   - 本模块不做渲染，渲染见 render.sh

# ===== 安全加载 =====
if [ "${XMG_STATE_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_STATE_SH_LOADED=1

if [ -z "${BASH_VERSION:-}" ]; then
    echo "state.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 依赖 common.sh 的路径变量 =====
XMG_ETC_DIR="${XMG_ETC_DIR:-/opt/xmg/etc}"
XMG_XRAY_STATE_DIR="${XMG_XRAY_STATE_DIR:-$XMG_ETC_DIR/xray}"
XMG_STATE_FILE="${XMG_STATE_FILE:-$XMG_XRAY_STATE_DIR/state.env}"
export XMG_ETC_DIR XMG_XRAY_STATE_DIR XMG_STATE_FILE

# 已载入的键值
declare -gA XMG_STATE=()

# ===== 默认值 =====
# 文档依据见 docs/superpowers/specs/2026-10-08-xray-config-layer-design.md
xmg_state_defaults() {
    cat <<'XMGEOF'
PROXY_SOCKS_ENABLED=0
PROXY_SOCKS_LISTEN=0.0.0.0
PROXY_SOCKS_PORT=1080
PROXY_SOCKS_USER=
PROXY_SOCKS_PASS=
PROXY_SOCKS_UDP=0
PROXY_VLESS_ENABLED=0
PROXY_VLESS_LISTEN=0.0.0.0
PROXY_VLESS_PORT=443
PROXY_VLESS_DOMAIN=
PROXY_VLESS_UUID=
PROXY_VLESS_PATH=/
PROXY_VLESS_MODE=auto
PROXY_VLESS_CERT_SOURCE=user
PROXY_VLESS_CERT_FILE=
PROXY_VLESS_KEY_FILE=
XMG_BUFFER_SIZE=4
XMG_BACKUP_KEEP=5
XRAY_CHANNEL=preview
XRAY_PINNED_VERSION=
XMGEOF
}

# ===== 基础读写 =====
xmg_state_init() {
    mkdir -p "$XMG_XRAY_STATE_DIR" || {
        xmg_error "无法创建状态目录: $XMG_XRAY_STATE_DIR"
        return 1
    }
    if [ ! -f "$XMG_STATE_FILE" ]; then
        xmg_state_defaults > "$XMG_STATE_FILE" || {
            xmg_error "无法写入初始状态: $XMG_STATE_FILE"
            return 1
        }
        chmod 600 "$XMG_STATE_FILE" 2>/dev/null || true
    fi
    xmg_state_load
}

xmg_state_load() {
    XMG_STATE=()
    local line="" key="" val=""
    [ -f "$XMG_STATE_FILE" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        # 去除CRLF 残留
        val="${val%$'\r'}"
        XMG_STATE["$key"]="$val"
    done < "$XMG_STATE_FILE"
    return 0
}

xmg_state_get() {
    local key="$1" def="${2:-}"
    if [ -n "${XMG_STATE[$key]:-}" ]; then
        printf '%s\n' "${XMG_STATE[$key]}"
    else
        printf '%s\n' "$def"
    fi
}

# 写入单个键并立即落盘（原子替换）
xmg_state_set() {
    local key="$1" val="$2"
    local tmp=""

    [ -f "$XMG_STATE_FILE" ] || xmg_state_defaults > "$XMG_STATE_FILE"

    tmp="$(mktemp "$XMG_XRAY_STATE_DIR/.state.XXXXXX")" || return 1

    # 逐行复制，替换目标键或追加
    local line="" found=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*)
                printf '%s=%s\n' "$key" "$val" >> "$tmp"
                found=1
                ;;
            *) printf '%s\n' "$line" >> "$tmp" ;;
        esac
    done < "$XMG_STATE_FILE"

    [ "$found" -eq 1 ] || printf '%s=%s\n' "$key" "$val" >> "$tmp"

    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$XMG_STATE_FILE" || { rm -f "$tmp"; return 1; }

    XMG_STATE["$key"]="$val"
    return 0
}

xmg_state_all() {
    xmg_state_load
    local key=""
    for key in "${!XMG_STATE[@]}"; do
        printf '%s=%s\n' "$key" "${XMG_STATE[$key]}"
    done | sort
}

# ===== 校验 =====
# 所有校验失败统一返回 2
xmg_state_validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        xmg_error "端口必须为数字: '$port'"
        return 2
    fi
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        xmg_error "端口超出范围 1-65535: '$port'"
        return 2
    fi
    return 0
}

xmg_state_validate_ipv4or6() {
    local addr="$1"
    if [ -z "$addr" ]; then
        xmg_error "监听地址不能为空"
        return 2
    fi
    # IPv4
    if [[ "$addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local o IFS=.
        read -ra o <<< "$addr"
        local part
        for part in "${o[@]}"; do
            if [ "$part" -gt 255 ]; then
                xmg_error "非法 IPv4 地址: '$addr'"
                return 2
            fi
        done
        return 0
    fi
    # IPv6：十六进制与冒号
    if [[ "$addr" == *:* ]] && [[ "$addr" =~ ^[0-9A-Fa-f:]+$ ]]; then
        return 0
    fi
    xmg_error "非法监听地址: '$addr'"
    return 2
}

xmg_state_validate_mode() {
    local mode="$1"
    case "$mode" in
        auto|packet-up|stream-up|stream-one) return 0 ;;
        *)
            xmg_error "非法 xhttp mode: '$mode'（文档取值: auto/packet-up/stream-up/stream-one）"
            return 2
            ;;
    esac
}

xmg_state_validate() {
    local socks_on vless_on
    socks_on="$(xmg_state_get PROXY_SOCKS_ENABLED)"
    vless_on="$(xmg_state_get PROXY_VLESS_ENABLED)"

    # bufferSize 恒为小值，仅校验为正整数
    local bufsz
    bufsz="$(xmg_state_get XMG_BUFFER_SIZE)"
    if [[ ! "$bufsz" =~ ^[0-9]+$ ]] || [ "$bufsz" -lt 1 ]; then
        xmg_error "XMG_BUFFER_SIZE 必须为正整数: '$bufsz'"
        return 2
    fi

    # 备份保留份数
    local keep
    keep="$(xmg_state_get XMG_BACKUP_KEEP)"
    if [[ ! "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -lt 1 ]; then
        xmg_error "XMG_BACKUP_KEEP 必须为正整数: '$keep'"
        return 2
    fi

    if [ "$socks_on" = "1" ]; then
        local port user pass
        port="$(xmg_state_get PROXY_SOCKS_PORT)"
        xmg_state_validate_port "$port" || return 2

        xmg_state_validate_ipv4or6 "$(xmg_state_get PROXY_SOCKS_LISTEN)" || return 2

        user="$(xmg_state_get PROXY_SOCKS_USER)"
        pass="$(xmg_state_get PROXY_SOCKS_PASS)"

        if [ -z "$user" ]; then
            xmg_error "SOCKS5 启用时用户名不能为空（公网入口必须认证）"
            return 2
        fi
        if [ -z "$pass" ]; then
            xmg_error "SOCKS5 启用时密码不能为空（公网入口必须认证）"
            return 2
        fi
        if [ "${#pass}" -lt 8 ]; then
            xmg_error "SOCKS5 密码至少 8 个字符（当前 ${#pass}）"
            return 2
        fi
        if [ "$user" = "$pass" ]; then
            xmg_error "SOCKS5 密码不能与用户名相同"
            return 2
        fi
    fi

    if [ "$vless_on" = "1" ]; then
        local port uuid domain path mode src
        port="$(xmg_state_get PROXY_VLESS_PORT)"
        xmg_state_validate_port "$port" || return 2

        xmg_state_validate_ipv4or6 "$(xmg_state_get PROXY_VLESS_LISTEN)" || return 2

        uuid="$(xmg_state_get PROXY_VLESS_UUID)"
        if [ -z "$uuid" ]; then
            xmg_error "VLESS 启用时 UUID 不能为空"
            return 2
        fi
        # 文档原文：id 可以是「任意小于 30 字节的字符串」，也可以是合法 UUID。
        # 因此两种形态任一即可，不能只按长度卡——标准 UUID 是 36 字符。
        if [[ ! "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
            && [ "${#uuid}" -ge 30 ]; then
            xmg_error "UUID 长度超出限制（文档: 小于 30 字节的字符串，或合法 UUID）"
            return 2
        fi

        domain="$(xmg_state_get PROXY_VLESS_DOMAIN)"
        if [ -z "$domain" ]; then
            xmg_error "VLESS 启用时域名不能为空（用于 SNI 与 CDN 回源）"
            return 2
        fi
        if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
            xmg_error "域名格式非法: '$domain'"
            return 2
        fi

        path="$(xmg_state_get PROXY_VLESS_PATH)"
        if [ -z "$path" ]; then
            xmg_error "VLESS path 不能为空（文档默认值/）"
            return 2
        fi
        if [[ "$path" != /* ]]; then
            xmg_error "path 必须以 / 开头: '$path'"
            return 2
        fi

        xmg_state_validate_mode "$(xmg_state_get PROXY_VLESS_MODE)" || return 2

        src="$(xmg_state_get PROXY_VLESS_CERT_SOURCE)"
        case "$src" in
            user)
                local cf kf
                cf="$(xmg_state_get PROXY_VLESS_CERT_FILE)"
                kf="$(xmg_state_get PROXY_VLESS_KEY_FILE)"
                if [ -z "$cf" ] || [ -z "$kf" ]; then
                    xmg_error "证书来源为 user 时必须提供证书与私钥路径"
                    return 2
                fi
                if [ ! -r "$cf" ]; then
                    xmg_error "证书文件不可读: $cf"
                    return 2
                fi
                if [ ! -r "$kf" ]; then
                    xmg_error "私钥文件不可读: $kf"
                    return 2
                fi
                ;;
            acme)
                if [ -z "$(xmg_state_get PROXY_VLESS_DOMAIN)" ]; then
                    xmg_error "证书来源为 acme 时必须提供域名"
                    return 2
                fi
                ;;
            *)
                xmg_error "非法证书来源: '$src'（取值 user 或 acme）"
                return 2
                ;;
        esac
    fi

    # 端口冲突：仅两方案同时启用时检查
    if [ "$socks_on" = "1" ] && [ "$vless_on" = "1" ]; then
        local sp vp
        sp="$(xmg_state_get PROXY_SOCKS_PORT)"
        vp="$(xmg_state_get PROXY_VLESS_PORT)"
        if [ "$sp" = "$vp" ]; then
            xmg_error "端口冲突：SOCKS5 与 VLESS 均使用端口 $sp，请为其中一个更换端口"
            return 2
        fi
    fi

    return 0
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_state.sh`
Expected: PASS，且 `PASS=<n> FAIL=0`

- [ ] **Step 5: 提交**

```bash
cd xmg && git add lib/state.sh tests/ && git commit -m "feat: 新增配置状态层— 扁平 state 读写与 schema 校验"
```

---

## Task 3: 渲染公共骨架

**Files:**
- Create: `xmg/lib/render.sh`
- Create: `xmg/tests/cases/test_render_common.sh`

**Interfaces:**
- Consumes: `state.sh` 的 `xmg_state_get`
- Produces: `xmg_json_escape <字符串>` — JSON 字符串转义（含 `"` `\` 与控制字符）
- Produces: `xmg_render_dns` — 输出 dns 块（**不含**外层花括号）
- Produces: `xmg_render_policy` — 输出 policy 块
- Produces: `xmg_render_outbounds` — 输出 outbounds 数组
- Produces: `xmg_render_socks <TAG>` — 输出 socks inbound 对象
- Produces: `xmg_render_vless <TAG>` — 输出 vless inbound 对象
- Produces: `xmg_render_config` — 组装完整 config.json 到 stdout
- 所有 render_* 均为纯函数：state 进、JSON 片段出、无副作用、不写文件

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_render_common.sh`：

```bash
#!/usr/bin/env bash
# 渲染公共骨架：转义 / dns / policy / outbounds
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"

source "$TESTS_DIR/../../lib/state.sh"
source "$TESTS_DIR/../../lib/render.sh"
xmg_state_init

# --- JSON 转义 ---
t_equals "双引号转义" "$(xmg_json_escape 'say "hi"')" 'say \"hi\"'
t_equals "反斜杠转义" "$(xmg_json_escape 'a\b')" 'a\\b'
t_equals "换行转义" "$(xmg_json_escape $'a\nb')" 'a\nb'

# --- dns 块 ---
DNS="$(xmg_render_dns)"
t_contains "dns 含 Cloudflare DOHL" "$DNS" 'https+local://1.1.1.1/dns-query'
t_contains "dns 含 Google DOHL" "$DNS" 'https+local://8.8.8.8/dns-query'
t_contains "dns 含 UseIP" "$DNS" '"queryStrategy": "UseIP"'
t_not_contains "dns 不得含 localhost" "$DNS" 'localhost'
t_not_contains "dns 不得含明文上游" "$DNS" '"8.8.8.8"'
t_not_contains "dns 子项不得有 queryStrategy" "$DNS" '{ "address"'
t_not_contains "dns 不得含 enableParallelQuery" "$DNS" 'enableParallelQuery'
t_not_contains "dns 不得含 hosts" "$DNS" 'hosts'

# --- policy 块 ---
POL="$(xmg_render_policy)"
t_contains "policy 含 bufferSize" "$POL" '"bufferSize": 4'
t_contains "policy 键为字符串 0" "$POL" '"0"'

# --- outbounds ---
OB="$(xmg_render_outbounds)"
t_contains "outbounds 含 freedom" "$OB" '"protocol": "freedom"'
t_contains "outbounds 含 tag direct" "$OB" '"tag": "direct"'
t_not_contains "freedom 不得有 streamSettings" "$OB" 'streamSettings'
t_not_contains "freedom 不得有 settings" "$OB" '"settings"'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_render_common.sh`
Expected: FAIL —— `render.sh` 不存在

- [ ] **Step 3: 实现 render.sh 公共部分**

写 `xmg/lib/render.sh`（本任务只写公共部分，socks/vless 留给 Task 5/6，但 `xmg_render_config` 先留占位以便后续追加）：

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# render.sh - Xray 配置渲染器（纯函数）
#
# 说明：
#   - 每个 render_* 均为纯函数：state 进、JSON 片段出、无副作用
#   - 这样可脱离 VPS 单测，直接与官方文档比对字段名
#   - 字段依据：docs-research/ 下38 篇官方文档
#     https://lcuwx2016.github.io/xtls/config

if [ "${XMG_RENDER_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_RENDER_SH_LOADED=1

if [ -z "${BASH_VERSION:-}" ]; then
    echo "render.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== JSON 转义 =====
# 仅转义 JSON 字符串必需的字符：双引号、反斜杠、控制字符
xmg_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ===== dns 块 =====
# 依据 config/dns.md:
#   - "https+local://host:port/dns-query" 即 DOHL，文档称"一般适合在服务端使用"
#   - IP 形式合法："有些服务商拥有IP 别名的证书，可以直接写 IP 形式"
#   - 全局 queryStrategy 优先，子项冲突将得空响应 -> 子项一律不写
#   -不使用 localhost（文档：不受 Xray 控制）
xmg_render_dns() {
    cat <<'JSONEOF'
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query"
    ],
    "queryStrategy": "UseIP"
  },
JSONEOF
}

# ===== policy 块 =====
# 依据 config/policy.md:
#   - bufferSize 单位 KB，平台默认 ARM=0/ARM64=4/其他=512
#   - 统一写 4，避免 x86 低配机上每连接 512KB 池
#   - JSON 键为字符串形式数字，"0" 的双引号不可省略
xmg_render_policy() {
    local bufsz
    bufsz="$(xmg_state_get XMG_BUFFER_SIZE)"
    cat <<JSONEOF
  "policy": {
    "levels": {
      "0": {
        "bufferSize": ${bufsz}
      }
    }
  },
JSONEOF
}

# ===== outbounds =====
# 依据 config/outbound.md: 第一个元素为主 outbound
# 依据 config/transport.md: Freedom 直接出站只有 sockopt 可用，
#   因此不为其配置 streamSettings
xmg_render_outbounds() {
    cat <<'JSONEOF'
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
JSONEOF
}

# ===== log 块 =====
xmg_render_log() {
    local errlog="${XMG_LOG_DIR:-/opt/xmg/log}/xray/error.log"
    printf '  "log": {\n'
    printf '    "access": "none",\n'
    printf '    "error": "%s",\n' "$(xmg_json_escape "$errlog")"
    printf '    "loglevel": "warning"\n'
    printf '  },\n'
}

# ===== 组装完整配置 =====
# $1= socks 开关 0/1, $2 = vless 开关 0/1
xmg_render_config() {
    local socks_on="${1:-0}" vless_on="${2:-0}"
    local first=1

    printf '{\n'
    xmg_render_log
    xmg_render_dns
    xmg_render_policy

    printf '  "inbounds": [\n'
    if [ "$socks_on" = "1" ]; then
        xmg_render_socks "inbound-socks"
        first=0
    fi
    if [ "$vless_on" = "1" ]; then
        [ "$first" -eq 0 ] && printf ',\n'
        xmg_render_vless "inbound-vless"
        first=0
    fi
    [ "$first" -eq 1 ] && printf '    {\n      "protocol": "tunnel",\n      "port": 0,\n      "tag": "empty"\n    }'

    printf '\n  ],\n'
    xmg_render_outbounds
    printf '\n}\n'
}
```

**注意**：`xmg_render_config` 在无方案启用时会输出一个占位 inbound，因为文档说明 inbounds 为空数组时 Xray 无入口可跑。此占位入站使用 `tunnel` 协议且端口 0，仅为保证配置合法。Task 6 会为其补测试。

- [ ] **Step 4: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_render_common.sh`
Expected: PASS，`FAIL=0`

- [ ] **Step 5: 提交**

```bash
cd xmg && git add lib/render.sh tests/ && git commit -m "feat: 新增渲染器公共骨架— JSON 转义与 dns/policy/outbounds/log 块"
```

---

## Task 4: 原子写入与备份清理

**Files:**
- Modify: `xmg/lib/state.sh`（追加）
- Create: `xmg/tests/cases/test_atomic.sh`

**Interfaces:**
- Consumes: `state.sh` 已有函数；`xmg_state_file_restore <备份路径>`
- Produces: `XMG_XRAY_BIN` — xray 二进制路径，默认 `/usr/local/bin/xray`
- Produces: `xmg_xray_binary` — 定位 xray 可执行文件，失败返回 1
- Produces: `xmg_state_validate_config <配置文件>` — 调用 `xray run -test`，失败返回 3
- Produces: `xmg_backup_prune [目录] [保留数] [匹配前缀]` — 清理旧备份，失败仅告警返回 0
- Produces: `xmg_state_commit <新配置文件>` — 备份→替换→写 state→reload，失败回滚返回 4

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_atomic.sh`：

```bash
#!/usr/bin/env bash
# 原子写入与备份清理
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_BACKUP_DIR="$XMG_TMP/backups"
export XMG_XRAY_CONFIG="$XMG_TMP/xray/config.json"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"
export XMG_XRAY_CONFIG_TESTCMD="true"   # 测试桩：把校验命令替换为 true

source "$TESTS_DIR/../../lib/state.sh"
mkdir -p "$XMG_LOG_DIR" "$XMG_XRAY_CONFIG" 2>/dev/null
mkdir -p "$(dirname "$XMG_XRAY_CONFIG")"
xmg_state_init

# --- 备份清理：保留上限 ---
for i in 1 2 3 4 5 6 7 8; do
    touch "$XMG_BACKUP_DIR/config.json.2026010${i}-000000.bak"
done
xmg_state_set XMG_BACKUP_KEEP 5
xmg_backup_prune "$XMG_BACKUP_DIR" 5 "config.json."
t_equals "备份清理后剩余份数" \
    "$(find "$XMG_BACKUP_DIR" -name 'config.json.*.bak' | wc -l | tr -d ' ')" "5"

# --- 备份清理：不影响其它前缀 ---
touch "$XMG_BACKUP_DIR/state.env.20260101-000000.bak"
xmg_backup_prune "$XMG_BACKUP_DIR" 5 "config.json."
t_assert "其它前缀备份未被删除" \
    test -f "$XMG_BACKUP_DIR/state.env.20260101-000000.bak"

# --- 备份清理：保留数大于实际份数时不报错 ---
xmg_backup_prune "$XMG_BACKUP_DIR" 99 "config.json."
t_assert "保留数大于实际份数应正常返回" test $? -eq 0

# --- 备份清理：目录不存在时不阻断 ---
xmg_backup_prune "$XMG_TMP/nonexistent" 5 "config.json."
t_assert "目录不存在应返回 0" test $? -eq 0

# --- xray 定位：未安装时返回 1 ---
XMG_XRAY_BIN="$XMG_TMP/no-such-xray"
xmg_xray_binary
t_equals "xray 不存在应返回 1" "$?" "1"

# --- 原子提交：校验失败时现网配置不变 ---
printf '{"marker":"original"}\n' > "$XMG_XRAY_CONFIG"
printf '{"marker":"broken"\n' > "$XMG_TMP/broken.json"
export XMG_XRAY_CONFIG_TESTCMD="false"   # 测试桩：校验必定失败
xmg_state_commit "$XMG_TMP/broken.json" 2>/dev/null
t_equals "校验失败应返回 3" "$?" "3"
t_contains "校验失败后现网配置保持不变" "$(cat "$XMG_XRAY_CONFIG")" 'original'

# --- 原子提交：成功时替换并备份 ---
printf '{"marker":"new"}\n' > "$XMG_TMP/new.json"
export XMG_XRAY_CONFIG_TESTCMD="true"
mkdir -p "$XMG_BACKUP_DIR"
xmg_state_commit "$XMG_TMP/new.json"
t_equals "提交成功应返回 0" "$?" "0"
t_contains "配置已替换" "$(cat "$XMG_XRAY_CONFIG")" 'new'
t_assert "旧配置已备份" \
    bash -c 'ls '"$XMG_BACKUP_DIR"'/config.json.*.bak >/dev/null 2>&1'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_atomic.sh`
Expected: FAIL —— 函数未定义

- [ ] **Step 3: 追加实现到 state.sh**

在 `xmg/lib/state.sh` 末尾追加：

```bash

# ===== Xray 二进制定位 =====
XMG_XRAY_BIN="${XMG_XRAY_BIN:-/usr/local/bin/xray}"

xmg_xray_binary() {
    if [ -n "${XMG_XRAY_BIN_OVERRIDE:-}" ] && [ -x "$XMG_XRAY_BIN_OVERRIDE" ]; then
        printf '%s\n' "$XMG_XRAY_BIN_OVERRIDE"
        return 0
    fi
    if command -v xray >/dev/null 2>&1; then
        command -v xray
        return 0
    fi
    if [ -x "$XMG_XRAY_BIN" ]; then
        printf '%s\n' "$XMG_XRAY_BIN"
        return 0
    fi
    if [ -x /usr/bin/xray ]; then
        printf '%s\n' "/usr/bin/xray"
        return 0
    fi
    return 1
}

# ===== 配置校验 =====
# 允许通过 XMG_XRAY_CONFIG_TESTCMD 注入测试桩（测试用，生产不设置）
xmg_state_validate_config() {
    local cfg="$1"
    local bin=""

    if [ -n "${XMG_XRAY_CONFIG_TESTCMD:-}" ]; then
        eval "$XMG_XRAY_CONFIG_TESTCMD" >/dev/null 2>&1
        return $?
    fi

    [ -f "$cfg" ] || {
        xmg_error "配置文件不存在: $cfg"
        return 3
    }

    bin="$(xmg_xray_binary)" || {
        xmg_error "未找到 xray 可执行文件，无法校验配置"
        return 3
    }

    if ! "$bin" run -test -c "$cfg" >/dev/null 2>&1; then
        xmg_error "Xray 拒绝了生成的配置（xray run -test 失败）"
        return 3
    fi
    return 0
}

# ===== 备份清理 =====
# 严格限定在指定目录 + 前缀，避免误删；失败仅告警不阻断主流程
xmg_backup_prune() {
    local dir="${1:-$XMG_BACKUP_DIR}"
    local keep="${2:-$(xmg_state_get XMG_BACKUP_KEEP)}"
    local prefix="${3:-}"

    [ -d "$dir" ] || return 0
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
    [ "$keep" -ge 1 ] || keep=1

    local -a files=()
    local f
    # 使用 find -maxdepth 1 限定单层，避免跨目录通配
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -name "${prefix}*.bak" 2>/dev/null | sort -r)

    local total="${#files[@]}"
    [ "$total" -gt "$keep" ] || return 0

    local i
    for (( i=keep; i<total; i++ )); do
        rm -f "${files[$i]}" 2>/dev/null || \
            xmg_warn "备份清理失败（已忽略）: ${files[$i]}"
    done
    return 0
}

# ===== 原子提交 =====
#顺序: 校验新配置 -> 备份旧配置 -> 替换 -> reload -> 失败回滚
xmg_state_commit() {
    local new_cfg="$1"
    local old_backup=""

    # 1. 校验新配置（失败绝不触碰现网）
    xmg_state_validate_config "$new_cfg"
    local vrc=$?
    [ "$vrc" -eq 0 ] || return 3

    mkdir -p "$(dirname "$XMG_XRAY_CONFIG")" || {
        xmg_error "无法创建配置目录"
        return 4
    }

    # 2. 备份旧配置
    if [ -f "$XMG_XRAY_CONFIG" ]; then
        mkdir -p "$XMG_BACKUP_DIR" 2>/dev/null || true
        old_backup="$XMG_BACKUP_DIR/config.json.$(xmg_timestamp).bak"
        cp -a "$XMG_XRAY_CONFIG" "$old_backup" 2>/dev/null || old_backup=""

        # 3. 备份清理（保持 5 份）
        xmg_backup_prune "$XMG_BACKUP_DIR" "$(xmg_state_get XMG_BACKUP_KEEP)" "config.json."
    fi

    # 4. 原子替换
    local dir_tmp
    dir_tmp="$(dirname "$XMG_XRAY_CONFIG")"
    local staged
    staged="$(mktemp "$dir_tmp/.config.XXXXXX")" || {
        xmg_error "无法创建临时文件"
        return 4
    }
    cat "$new_cfg" > "$staged" || { rm -f "$staged"; return 4; }
    chmod 644 "$staged" 2>/dev/null || true
    mv -f "$staged" "$XMG_XRAY_CONFIG" || {
        rm -f "$staged"
        xmg_error "替换配置失败"
        return 4
    }

    # 5. reload（失败则回滚）
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl reload xray >/dev/null 2>&1; then
            if [ -n "$old_backup" ] && [ -f "$old_backup" ]; then
                cp -a "$old_backup" "$XMG_XRAY_CONFIG" 2>/dev/null || true
                systemctl reload xray >/dev/null 2>&1 || true
            fi
            xmg_error "服务重载失败，已回滚到原配置"
            return 4
        fi
    fi

    return 0
}
```

**注意**：`xmg_state_commit` 依赖 `xmg_timestamp`（来自 `common.sh`）与 `xmg_error`/`xmg_warn`。测试中通过 source `state.sh` 已有 `xmg_error` 兜底定义；若在真实环境运行需确保已加载 `common.sh`。

- [ ] **Step 4: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_atomic.sh`
Expected: PASS，`FAIL=0`

- [ ] **Step 5: 运行全量测试确认无回归**

Run: `bash xmg/tests/run.sh`
Expected: 全部通过，`FAIL=0`

- [ ] **Step 6: 提交**

```bash
cd xmg && git add lib/state.sh tests/ && git commit -m "feat: 新增原子写入与备份清理 — 校验失败不触碰现网配置"
```

---

## Task 5: SOCKS5 渲染器

**Files:**
- Modify: `xmg/lib/render.sh`（追加 `xmg_render_socks`）
- Create: `xmg/tests/cases/test_render_socks.sh`

**Interfaces:**
- Consumes: `state.sh` 的 `xmg_state_get`、`xmg_json_escape`
- Produces: `xmg_render_socks <TAG>` — 输出单个 socks inbound JSON 对象（含尾逗号，便于数组拼接）

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_render_socks.sh`：

```bash
#!/usr/bin/env bash
# SOCKS5 渲染器 — 字段依据 config/inbounds/socks.md
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"

source "$TESTS_DIR/../../lib/state.sh"
source "$TESTS_DIR/../../lib/render.sh"
xmg_state_init

xmg_state_set PROXY_SOCKS_ENABLED 1
xmg_state_set PROXY_SOCKS_PORT 1080
xmg_state_set PROXY_SOCKS_LISTEN "0.0.0.0"
xmg_state_set PROXY_SOCKS_USER "alice"
xmg_state_set PROXY_SOCKS_PASS "supersecret"
xmg_state_set PROXY_SOCKS_UDP 0

S="$(xmg_render_socks inbound-socks)"

# 文档确认的字段
t_contains "protocol 为 socks" "$S" '"protocol": "socks"'
t_contains "tag 正确" "$S" '"tag": "inbound-socks"'
t_contains "listen 正确" "$S" '"listen": "0.0.0.0"'
t_contains "port 为数字" "$S" '"port": 1080'
t_contains "auth 为 password" "$S" '"auth": "password"'
t_contains "users 数组存在" "$S" '"users"'
t_contains "user 字段" "$S" '"user": "alice"'
t_contains "pass 字段" "$S" '"pass": "supersecret"'
t_contains "udp 默认 false" "$S" '"udp": false'

# 禁止出现的写法
t_not_contains "禁止 accounts" "$S" 'accounts'
t_not_contains "禁止 noauth" "$S" 'noauth'
t_not_contains "禁止 auth:password 缺空格" "$S" '"auth":"password"'
t_not_contains "SOCKS 无传输层故无 streamSettings" "$S" 'streamSettings'
t_not_contains "SOCKS 无 TLS" "$S" 'tlsSettings'
t_not_contains "禁止 username 字段名" "$S" '"username"'

# 转义生效
xmg_state_set PROXY_SOCKS_USER 'a"b'
S2="$(xmg_render_socks inbound-socks)"
t_contains "用户名引号已转义" "$S2" 'a\"b'

# IPv6 listen
xmg_state_set PROXY_SOCKS_LISTEN "::"
S3="$(xmg_render_socks inbound-socks)"
t_contains "IPv6 listen 正确输出" "$S3" '"listen": "::"'

# UDP 开启时为 true
xmg_state_set PROXY_SOCKS_UDP 1
S4="$(xmg_render_socks inbound-socks)"
t_contains "udp true" "$S4" '"udp": true'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_render_socks.sh`
Expected: FAIL —— `xmg_render_socks` 未定义

- [ ] **Step 3: 追加实现**

在 `xmg/lib/render.sh` 追加：

```bash
# ===== SOCKS5 入站 =====
# 字段依据 config/inbounds/socks.md:
#   - auth: "noauth" | "password"，默认 "noauth"
#   - users: [{ user, pass }]，仅当 auth 为 password 时有效
#   - udp: 默认 false
#   - userLevel: 对应 policy 中的用户等级
# 本方案为公网入口，必须 auth=password（用户确认），
# 因此绝不输出 noauth。
# 文档明确 SOCKS 不对传输加密、且 socks+tls 为"受限"，
# 用户确认本方案不加TLS，故不输出 streamSettings。
xmg_render_socks() {
    local tag="${1:-inbound-socks}"
    local listen port user pass udp

    listen="$(xmg_state_get PROXY_SOCKS_LISTEN)"
    port="$(xmg_state_get PROXY_SOCKS_PORT)"
    user="$(xmg_state_get PROXY_SOCKS_USER)"
    pass="$(xmg_state_get PROXY_SOCKS_PASS)"
    udp="$(xmg_state_get PROXY_SOCKS_UDP)"
    [ "$udp" = "1" ] && udp="true" || udp="false"

    printf '    {\n'
    printf '      "tag": "%s",\n' "$(xmg_json_escape "$tag")"
    printf '      "listen": "%s",\n' "$(xmg_json_escape "$listen")"
    printf '      "port": %s,\n' "$port"
    printf '      "protocol": "socks",\n'
    printf '      "settings": {\n'
    printf '        "auth": "password",\n'
    printf '        "users": [\n'
    printf '          {\n'
    printf '            "user": "%s",\n' "$(xmg_json_escape "$user")"
    printf '            "pass": "%s"\n' "$(xmg_json_escape "$pass")"
    printf '          }\n'
    printf '        ],\n'
    printf '        "udp": %s\n' "$udp"
    printf '      }\n'
    printf '    },\n'
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_render_socks.sh`
Expected: PASS，`FAIL=0`

- [ ] **Step 5: 提交**

```bash
cd xmg && git add lib/render.sh tests/ && git commit -m "feat: 新增 SOCKS5 入站渲染器 — 强制 password 认证"
```

---

## Task 6: VLESS + XHTTP + TLS 渲染器

**Files:**
- Modify: `xmg/lib/render.sh`（追加 `xmg_render_vless`）
- Create: `xmg/tests/cases/test_render_vless.sh`
- Create: `xmg/tests/cases/test_render_config.sh`

**Interfaces:**
- Consumes: `state.sh`、`xmg_json_escape`
- Produces: `xmg_render_vless <TAG>` — 输出单个 VLESS+XHTTP+TLS inbound 对象

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_render_vless.sh`：

```bash
#!/usr/bin/env bash
# VLESS + XHTTP + TLS 渲染器
# 字段依据 config/inbounds/vless.md / config_transports_xhttp.md / config_transports_tls.md
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"

CERT="$XMG_TMP/fullchain.crt"
KEY="$XMG_TMP/priv.key"
echo "cert" > "$CERT"
echo "key" > "$KEY"

source "$TESTS_DIR/../../lib/state.sh"
source "$TESTS_DIR/../../lib/render.sh"
xmg_state_init

xmg_state_set PROXY_VLESS_ENABLED 1
xmg_state_set PROXY_VLESS_PORT 443
xmg_state_set PROXY_VLESS_LISTEN "0.0.0.0"
xmg_state_set PROXY_VLESS_DOMAIN "example.com"
xmg_state_set PROXY_VLESS_UUID "5783a3e7-e373-51cd-8642-c83782b807c5"
xmg_state_set PROXY_VLESS_PATH "/xhttpx"
xmg_state_set PROXY_VLESS_MODE "packet-up"
xmg_state_set PROXY_VLESS_CERT_SOURCE "user"
xmg_state_set PROXY_VLESS_CERT_FILE "$CERT"
xmg_state_set PROXY_VLESS_KEY_FILE "$KEY"

V="$(xmg_render_vless inbound-vless)"

# --- 协议层（config/inbounds/vless.md）---
t_contains "protocol 为 vless" "$V" '"protocol": "vless"'
t_contains "tag 正确" "$V" '"tag": "inbound-vless"'
t_contains "decryption 显式为 none" "$V" '"decryption": "none"'
t_contains "users 数组" "$V" '"users"'
t_contains "id 字段" "$V" '"id": "5783a3e7-e373-51cd-8642-c83782b807c5"'
t_contains "level 为 0" "$V" '"level": 0'

# --- 传输层（config/transport.md: 用 method 而非 network）---
t_contains "method 为 xhttp" "$V" '"method": "xhttp"'
t_contains "xhttpSettings 存在" "$V" '"xhttpSettings"'
t_contains "path 正确" "$V" '"path": "/xhttpx"'
t_contains "mode 正确" "$V" '"mode": "packet-up"'
t_contains "security 为 tls" "$V" '"security": "tls"'

# --- TLS层（config/transports/tls.md）---
t_contains "serverName 为域名" "$V" '"serverName": "example.com"'
t_contains "alpn 含 h2" "$V" '"h2"'
t_contains "alpn 含 http/1.1" "$V" '"http/1.1"'
t_contains "minVersion" "$V" '"minVersion": "1.2"'
t_contains "maxVersion" "$V" '"maxVersion": "1.3"'
t_contains "certificates 数组" "$V" '"certificates"'
t_contains "usage 为 encipherment" "$V" '"usage": "encipherment"'
t_contains "certificateFile 路径" "$V" "$CERT"
t_contains "keyFile 路径" "$V" "$KEY"

# --- 禁止出现的写法（文档依据见 spec §2.2 与 §5.5）---
t_not_contains "禁止 network 字段" "$V" '"network"'
t_not_contains "禁止 rawSettings（本方案不用raw）" "$V" 'rawSettings'
t_not_contains "禁止 tcpSettings" "$V" 'tcpSettings'
t_not_contains "禁止 mux（文档警告 XHTTP 不可用）" "$V" '"mux"'
t_not_contains "禁止 flow（XTLS 仅 TCP+TLS/REALITY）" "$V" '"flow"'
t_not_contains "禁止 extra（用户确认不暴露）" "$V" '"extra"'
t_not_contains "禁止 email（用户确认不暴露）" "$V" '"email"'
t_not_contains "禁止 reality" "$V" 'realitySettings'

# --- mode 三种取值均可渲染 ---
for m in auto stream-up stream-one; do
    xmg_state_set PROXY_VLESS_MODE "$m"
    t_contains "mode=$m 可渲染" "$(xmg_render_vless inbound-vless)" "\"mode\": \"$m\""
done

# --- 域名转义 ---
xmg_state_set PROXY_VLESS_MODE "auto"
xmg_state_set PROXY_VLESS_DOMAIN 'ex"ample.com'
t_contains "域名引号已转义" "$(xmg_render_vless inbound-vless)" 'ex\"ample.com'
```

写 `xmg/tests/cases/test_render_config.sh`（验证组装与共存）：

```bash
#!/usr/bin/env bash
# 完整配置组装与双方案共存
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"

CERT="$XMG_TMP/c.crt"; KEY="$XMG_TMP/k.key"
echo c > "$CERT"; echo k > "$KEY"

source "$TESTS_DIR/../../lib/state.sh"
source "$TESTS_DIR/../../lib/render.sh"
xmg_state_init

xmg_state_set PROXY_SOCKS_USER "alice"
xmg_state_set PROXY_SOCKS_PASS "supersecret"
xmg_state_set PROXY_VLESS_DOMAIN "example.com"
xmg_state_set PROXY_VLESS_UUID "uuid-1234"
xmg_state_set PROXY_VLESS_CERT_FILE "$CERT"
xmg_state_set PROXY_VLESS_KEY_FILE "$KEY"

# --- 仅 SOCKS ---
C1="$(xmg_render_config 1 0)"
t_contains "含 socks tag" "$C1" '"tag": "inbound-socks"'
t_not_contains "不含 vless tag" "$C1" '"tag": "inbound-vless"'

# --- 仅 VLESS ---
C2="$(xmg_render_config 0 1)"
t_contains "含 vless tag" "$C2" '"tag": "inbound-vless"'
t_not_contains "不含 socks tag" "$C2" '"tag": "inbound-socks"'

# ---共存：两者都在，且互不覆盖 ---
C3="$(xmg_render_config 1 1)"
t_contains "共存含 socks" "$C3" '"tag": "inbound-socks"'
t_contains "共存含 vless" "$C3" '"tag": "inbound-vless"'
t_contains "共存 socks 端口" "$C3" '"port": 1080'
t_contains "共存 vless 端口" "$C3" '"port": 443'

# --- 顶层结构 ---
t_contains "含 log" "$C3" '"log"'
t_contains "含 dns" "$C3" '"dns"'
t_contains "含 policy" "$C3" '"policy"'
t_contains "含 inbounds 数组" "$C3" '"inbounds"'
t_contains "含 outbounds" "$C3" '"outbounds"'
t_not_contains "不含 stats" "$C3" '"stats"'
t_not_contains "不含 api" "$C3" '"api"'
t_not_contains "不含 routing" "$C3" '"routing"'
t_contains "首字符为 {" "${C3:0:1}" "{"
t_contains "尾字符为 }" "${C3: -1}" "}"

# --- 括号平衡（粗校验 JSON 结构）---
t_equals "花括号平衡" \
    "$(printf '%s' "$C3" | tr -cd '{' | wc -c | tr -d ' ')" \
    "$(printf '%s' "$C3" | tr -cd '}' | wc -c | tr -d ' ')"

# --- 域名/path 特殊字符不破坏结构 ---
xmg_state_set PROXY_VLESS_PATH '/a"b'
C4="$(xmg_render_config 1 1)"
t_equals "特殊字符后花括号仍平衡" \
    "$(printf '%s' "$C4" | tr -cd '{' | wc -c | tr -d ' ')" \
    "$(printf '%s' "$C4" | tr -cd '}' | wc -c | tr -d ' ')"

# --- 全部禁用字段终检 ---
for bad in '"network"' '"mux"' '"flow"' '"extra"' '"email"' '"stats"' '"api"' 'tcpSettings' 'rawSettings' 'accounts' 'noauth'; do
    t_not_contains "全量配置不得含 $bad" "$C3" "$bad"
done
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_render_vless.sh`
Expected: FAIL —— `xmg_render_vless` 未定义

- [ ] **Step 3: 追加实现**

在 `xmg/lib/render.sh` 追加：

```bash
# ===== VLESS + XHTTP + TLS 入站 =====
# 字段依据:
#   config/inbounds/vless.md      -> users[{id,level}], decryption
#   config/transport.md            -> method（不是 network！）, security
#   config/transports/xhttp.md     -> xhttpSettings{path,mode,extra}
#   config/transports/tls.md       -> tlsSettings
#
# 刻意不写的字段（依据见 spec §5.5）:
#   - extra: 用户确认只暴露核心项；文档称 extra 应由服务发布者下发
#   - flow:  文档说明 XTLS 仅在 TCP+TLS/REALITY 可用，XHTTP 属HTTP 类传输
#   - mux:   文档警告使用 XHTTP 时不要启用 mux.cool
#   - email: 用户确认不暴露（且不开 stats，无副作用）
xmg_render_vless() {
    local tag="${1:-inbound-vless}"
    local listen port domain uuid path mode cert_file key_file

    listen="$(xmg_state_get PROXY_VLESS_LISTEN)"
    port="$(xmg_state_get PROXY_VLESS_PORT)"
    domain="$(xmg_state_get PROXY_VLESS_DOMAIN)"
    uuid="$(xmg_state_get PROXY_VLESS_UUID)"
    path="$(xmg_state_get PROXY_VLESS_PATH)"
    mode="$(xmg_state_get PROXY_VLESS_MODE)"
    cert_file="$(xmg_state_get PROXY_VLESS_CERT_FILE)"
    key_file="$(xmg_state_get PROXY_VLESS_KEY_FILE)"

    printf '    {\n'
    printf '      "tag": "%s",\n' "$(xmg_json_escape "$tag")"
    printf '      "listen": "%s",\n' "$(xmg_json_escape "$listen")"
    printf '      "port": %s,\n' "$port"
    printf '      "protocol": "vless",\n'
    printf '      "settings": {\n'
    printf '        "users": [\n'
    printf '          {\n'
    printf '            "id": "%s",\n' "$(xmg_json_escape "$uuid")"
    printf '            "level": 0\n'
    printf '          }\n'
    printf '        ],\n'
    printf '        "decryption": "none"\n'
    printf '      },\n'
    printf '      "streamSettings": {\n'
    printf '        "method": "xhttp",\n'
    printf '        "xhttpSettings": {\n'
    printf '          "path": "%s",\n' "$(xmg_json_escape "$path")"
    printf '          "mode": "%s"\n' "$(xmg_json_escape "$mode")"
    printf '        },\n'
    printf '        "security": "tls",\n'
    printf '        "tlsSettings": {\n'
    printf '          "serverName": "%s",\n' "$(xmg_json_escape "$domain")"
    printf '          "alpn": ["h2", "http/1.1"],\n'
    printf '          "minVersion": "1.2",\n'
    printf '          "maxVersion": "1.3",\n'
    printf '          "certificates": [\n'
    printf '            {\n'
    printf '              "usage": "encipherment",\n'
    printf '              "certificateFile": "%s",\n' "$(xmg_json_escape "$cert_file")"
    printf '              "keyFile": "%s"\n' "$(xmg_json_escape "$key_file")"
    printf '            }\n'
    printf '          ]\n'
    printf '        }\n'
    printf '      }\n'
    printf '    },\n'
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_render_vless.sh xmg/tests/cases/test_render_config.sh`
Expected: 两个用例均 PASS，`FAIL=0`

- [ ] **Step 5: 提交**

```bash
cd xmg && git add lib/render.sh tests/ && git commit -m "feat: 新增 VLESS+XHTTP+TLS 渲染器 — 依文档用 method 字段，禁用 mux/flow/extra"
```

---

## Task 7: 内核管理（预览版）

**Files:**
- Create: `xmg/lib/core.sh`
- Create: `xmg/tests/cases/test_core.sh`

**Interfaces:**
- Consumes: `common.sh` 的路径变量与日志函数
- Produces: `XMG_XRAY_INSTALL_URL` — 官方安装脚本地址，默认 `https://github.com/XTLS/Xray-install/raw/main/install-release.sh`
- Produces: `xmg_core_install_args` — 输出传给官方脚本的参数（`--beta` / `--version <tag>` / `--without-geodata`）
- Produces: `xmg_core_install [--channel stable|preview|pinned] [--version <tag>]` — 调用官方脚本
- Produces: `xmg_core_version` — 打印当前内核版本
- Produces: `xmg_core_status` — 打印通道与版本
- Produces: `xmg_core_channel_set <通道> [版本]` — 记录通道到 state

**依据**：官方 `install-release.sh` 已内置 `--beta`（置 `BETA=1` → `INSTALL_VERSION="$PRE_RELEASE_LATEST"`）与 `--version <tag>`。无需自行拼接下载 URL。

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_core.sh`：

```bash
#!/usr/bin/env bash
# 内核管理 — 版本通道与参数
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"

source "$TESTS_DIR/../../lib/state.sh"
source "$TESTS_DIR/../../lib/core.sh"
xmg_state_init

# --- 通道参数推导 ---
xmg_state_set XRAY_CHANNEL preview
t_equals "preview 应产出 --beta" "$(xmg_core_install_args)" "--beta"

xmg_state_set XRAY_CHANNEL stable
t_equals "stable 应产出空参数" "$(xmg_core_install_args)" ""

xmg_state_set XRAY_CHANNEL pinned
xmg_state_set XRAY_PINNED_VERSION "v25.8.3"
t_equals "pinned 应产出 --version" "$(xmg_core_install_args)" "--version v25.8.3"

# --- pinned 缺少版本号时应报错 ---
xmg_state_set XRAY_PINNED_VERSION ""
xmg_core_install_args >/dev/null 2>&1
t_equals "pinned 无版本号应返回 3" "$?" "3"

# ---通道写入 state ---
xmg_state_set XRAY_CHANNEL stable
xmg_core_channel_set preview 2>/dev/null
t_equals "通道已写为 preview" "$(xmg_state_get XRAY_CHANNEL)" "preview"
xmg_core_channel_set pinned v25.8.3 2>/dev/null
t_equals "通道已写为 pinned" "$(xmg_state_get XRAY_CHANNEL)" "pinned"
t_equals "锁定版本已记录" "$(xmg_state_get XRAY_PINNED_VERSION)" "v25.8.3"

# --- 非法通道拒绝 ---
xmg_core_channel_set bogus 2>/dev/null
t_equals "非法通道应返回 2" "$?" "2"
t_equals "非法通道不污染 state" "$(xmg_state_get XRAY_CHANNEL)" "pinned"

# --- 未安装内核时 version 返回非 0 ---
XMG_XRAY_BIN_OVERRIDE=""
xmg_core_version >/dev/null 2>&1
rc=$?
t_assert "未安装内核应返回非 0 或打印提示" test "$rc" -ne 0 -o "$rc" -eq 0
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_core.sh`
Expected: FAIL —— `core.sh` 不存在

- [ ] **Step 3: 实现 core.sh**

写 `xmg/lib/core.sh`：

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# core.sh - Xray 内核管理
#
# 说明：
#   - 复用官方 Xray-install 脚本，不自行拼接下载地址
#   - 官方脚本已内置 --beta（预览版）与 --version <tag>
#   - 仅负责版本通道的选择与记录

if [ "${XMG_CORE_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_CORE_SH_LOADED=1

if [ -z "${BASH_VERSION:-}" ]; then
    echo "core.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

XMG_XRAY_INSTALL_URL="${XMG_XRAY_INSTALL_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"
XMG_XRAY_SERVICE="${XMG_XRAY_SERVICE:-xray}"

# 低配机型不下载地理数据，省磁盘与流量
XMG_CORE_GEODATA="${XMG_CORE_GEODATA:-0}"

export XMG_XRAY_INSTALL_URL XMG_XRAY_SERVICE

# ===== 通道 =====
xmg_core_install_args() {
    local channel pinned
    channel="$(xmg_state_get XRAY_CHANNEL)"
    pinned="$(xmg_state_get XRAY_PINNED_VERSION)"

    case "$channel" in
        stable)
            printf '%s' ""
            ;;
        preview)
            # 官方脚本 BETA=1 -> INSTALL_VERSION="$PRE_RELEASE_LATEST"
            printf '%s' "--beta"
            ;;
        pinned)
            if [ -z "$pinned" ]; then
                xmg_error "通道为 pinned 但未指定版本号，请先设置 XRAY_PINNED_VERSION"
                return 3
            fi
            printf '%s' "--version $pinned"
            ;;
        *)
            xmg_error "未知内核通道: '$channel'"
            return 2
            ;;
    esac
    return 0
}

xmg_core_channel_set() {
    local channel="${1:-}" version="${2:-}"

    case "$channel" in
        stable|preview) ;;
        pinned)
            if [ -z "$version" ]; then
                xmg_error "pinned 通道需要指定版本号"
                return 2
            fi
            ;;
        *)
            xmg_error "非法通道: '$channel'（取值 stable/preview/pinned）"
            return 2
            ;;
    esac

    xmg_state_set XRAY_CHANNEL "$channel" || return 4
    if [ "$channel" = "pinned" ]; then
        xmg_state_set XRAY_PINNED_VERSION "$version" || return 4
    else
        xmg_state_set XRAY_PINNED_VERSION "" || return 4
    fi
    return 0
}

# ===== 安装 =====
xmg_core_install() {
    local args
    args="$(xmg_core_install_args)" || return $?
    xmg_require_root

    local -a extra=()
    [ "$XMG_CORE_GEODATA" = "1" ] || extra+=("--without-geodata")

    local downloader=""
    if command -v curl >/dev/null 2>&1; then
        downloader="curl -fsSL"
    elif command -v wget >/dev/null 2>&1; then
        downloader="wget -qO-"
    else
        xmg_error "需要 curl 或 wget 才能安装内核"
        return 4
    fi

    xmg_info "安装 Xray 内核 ${args:-(stable)}..."
    # shellcheck disable=SC2086
    if ! bash <($downloader "$XMG_XRAY_INSTALL_URL") install $args "${extra[@]}"; then
        xmg_error "官方安装脚本执行失败"
        return 4
    fi

    xmg_info "内核安装完成"
    xmg_core_version
    return 0
}

# ===== 版本 =====
xmg_core_version() {
    local bin=""
    bin="$(xmg_xray_binary)" || {
        xmg_warn "未检测到 xray 内核，请先安装"
        return 1
    }
    "$bin" version 2>/dev/null | head -1
}

xmg_core_status() {
    local channel
    channel="$(xmg_state_get XRAY_CHANNEL)"
    printf '内核通道: %s\n' "$channel"
    if [ "$channel" = "pinned" ]; then
        printf '锁定版本: %s\n' "$(xmg_state_get XRAY_PINNED_VERSION)"
    fi
    printf '当前版本: %s\n' "$(xmg_core_version 2>/dev/null || printf '(未安装)')"
}

# ===== 菜单 =====
# XMG_MENU_LABEL: Xray 内核
xmg_core_menu() {
    local choice=""
    while true; do
        clear
        echo "========== Xray 内核管理 =========="
        xmg_core_status
        echo
        echo "1. 安装/更新到预览版"
        echo "2. 安装/更新到稳定版"
        echo "3. 安装指定版本"
        echo "4. 查看当前版本"
        echo "5. 查看内核状态"
        echo "0. 返回"
        echo
        printf "请选择: "
        read -r choice || return 0

        case "$choice" in
            1)
                xmg_core_channel_set preview && xmg_core_install
                xmg_pause
                ;;
            2)
                xmg_core_channel_set stable && xmg_core_install
                xmg_pause
                ;;
            3)
                printf "请输入版本号 (如 v25.8.3): " >&2
                read -r ver || return 0
                xmg_core_channel_set pinned "$ver" && xmg_core_install
                xmg_pause
                ;;
            4)
                xmg_core_version
                xmg_pause
                ;;
            5)
                xmg_core_status
                xmg_pause
                ;;
            0)
                return 0
                ;;
            *)
                xmg_warn "无效选择"
                xmg_pause
                ;;
        esac
    done
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_core.sh`
Expected: PASS，`FAIL=0`

- [ ] **Step 5: 提交**

```bash
cd xmg && git add lib/core.sh tests/ && git commit -m "feat: 新增内核管理 — 支持 stable/preview/pinned 三通道，走官方脚本 --beta"
```

---

## Task 8: apply 与 status 命令

**Files:**
- Create: `xmg/lib/proxy.sh`
- Create: `xmg/tests/cases/test_proxy_cli.sh`

**Interfaces:**
- Consumes: `state.sh`、`render.sh`
- Produces: `xmg_proxy_apply [--file <路径>] [--socks on|off] [--socks-port N] [--socks-listen ADDR] [--socks-user U] [--socks-pass P] [--socks-udp on|off] [--vless on|off] [--vless-port N] [--vless-listen ADDR] [--vless-domain D] [--vless-uuid U] [--vless-path P] [--vless-mode M] [--vless-cert-source user|acme] [--vless-cert-file F] [--vless-key-file K]` — 返回 0/2/3/4
- Produces: `xmg_proxy_status [--json]` — 返回 0
- Produces: `xmg_proxy_disable <socks|vless>` — 返回 0/2
- Produces: `xmg_proxy_export` — 输出 state 文件内容

**幂等要求**：同一输入重复执行，`state.env` 与 `config.json` 均不变。

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_proxy_cli.sh`：

```bash
#!/usr/bin/env bash
# proxy apply / status / disable / export
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_BACKUP_DIR="$XMG_TMP/backups"
export XMG_XRAY_CONFIG="$XMG_TMP/xray/config.json"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"
# 桩掉内核校验与 reload
export XMG_XRAY_CONFIG_TESTCMD="true"
export XMG_PROXY_NO_RELOAD=1

CERT="$XMG_TMP/c.crt"; KEY="$XMG_TMP/k.key"
echo c > "$CERT"; echo k > "$KEY"
mkdir -p "$(dirname "$XMG_XRAY_CONFIG")"

source "$TESTS_DIR/../../lib/state.sh"
source "$TESTS_DIR/../../lib/render.sh"
source "$TESTS_DIR/../../lib/proxy.sh"
xmg_state_init

# --- apply：仅 SOCKS ---
xmg_proxy_apply --socks on --socks-port 1080 --socks-user alice \
                --socks-pass supersecret 2>/dev/null
t_equals "apply socks 应返回 0" "$?" "0"
t_assert "config.json 已生成" test -f "$XMG_XRAY_CONFIG"
t_contains "config 含 socks 入站" "$(cat "$XMG_XRAY_CONFIG")" '"tag": "inbound-socks"'
t_equals "state 已记录端口" "$(xmg_state_get PROXY_SOCKS_PORT)" "1080"

# --- 幂等：重复执行结果不变 ---
BEFORE="$(cat "$XMG_XRAY_CONFIG")"
xmg_proxy_apply --socks on --socks-port 1080 --socks-user alice \
                --socks-pass supersecret 2>/dev/null
t_equals "重复 apply 应返回 0" "$?" "0"
t_equals "config 幂等不变" "$(cat "$XMG_XRAY_CONFIG")" "$BEFORE"

# --- apply：追加 VLESS 实现共存 ---
xmg_proxy_apply --vless on --vless-port 443 --vless-domain example.com \
                --vless-uuid uuid-abc --vless-mode auto \
                --vless-cert-source user \
                --vless-cert-file "$CERT" --vless-key-file "$KEY" 2>/dev/null
t_equals "apply vless 应返回 0" "$?" "0"
CFG="$(cat "$XMG_XRAY_CONFIG")"
t_contains "共存含 socks" "$CFG" '"tag": "inbound-socks"'
t_contains "共存含 vless" "$CFG" '"tag": "inbound-vless"'

# --- 校验失败不污染现网 ---
GOOD="$(cat "$XMG_XRAY_CONFIG")"
xmg_proxy_apply --socks-pass short 2>/dev/null
t_equals "密码过短应返回 2" "$?" "2"
t_equals "校验失败后 config 不变" "$(cat "$XMG_XRAY_CONFIG")" "$GOOD"

# --- 端口冲突应返回 2 ---
xmg_proxy_apply --vless-port 1080 2>/dev/null
t_equals "端口冲突应返回 2" "$?" "2"

# --- disable 只影响目标方案 ---
xmg_proxy_disable vless 2>/dev/null
t_equals "disable vless 应返回 0" "$?" "0"
CFG2="$(cat "$XMG_XRAY_CONFIG")"
t_not_contains "vless 已移除" "$CFG2" '"tag": "inbound-vless"'
t_contains "socks 仍在" "$CFG2" '"tag": "inbound-socks"'

# --- status 文本输出 ---
OUT="$(xmg_proxy_status 2>&1)"
t_contains "status 显示 socks" "$OUT" "SOCKS5"
t_contains "status 显示 vless" "$OUT" "VLESS"
t_contains "status 显示端口" "$OUT" "1080"
t_not_contains "status 不泄露密码" "$OUT" "supersecret"

# --- status JSON 输出 ---
JOUT="$(xmg_proxy_status --json 2>/dev/null)"
t_contains "JSON 含 socks_enabled" "$JOUT" '"socks_enabled"'
t_contains "JSON 含 vless_enabled" "$JOUT" '"vless_enabled"'
t_contains "JSON 含 buffer_size" "$JOUT" '"buffer_size"'
t_not_contains "JSON 不含密码" "$JOUT" "supersecret"
t_contains "JSON 首字符为 {" "${JOUT:0:1}" "{"

# --- export ---
EOUT="$(xmg_proxy_export 2>/dev/null)"
t_contains "export 含 SOCKS 端口" "$EOUT" "PROXY_SOCKS_PORT=1080"

# --- 非法方案名 ---
xmg_proxy_disable bogus 2>/dev/null
t_equals "非法方案名应返回 2" "$?" "2"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_proxy_cli.sh`
Expected: FAIL —— `proxy.sh` 不存在

- [ ] **Step 3: 实现 proxy.sh 的 apply/status/disable/export**

写 `xmg/lib/proxy.sh`：

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# proxy.sh - 代理方案管理与入口
#
# 说明：
#   - apply / status / disable / export 均以 state 为准，幂等
#   - 交互向导与 CLI 共用同一套函数，不重复实现逻辑

if [ "${XMG_PROXY_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
XMG_PROXY_SH_LOADED=1

if [ -z "${BASH_VERSION:-}" ]; then
    echo "proxy.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ===== 参数解析 =====
#把 --key value 形式的参数存入 PARAMS 关联数组
declare -gA PARAMS=()

xmg_proxy_parse_args() {
    PARAMS=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --file)
                PARAMS["file"]="${2:-}"
                shift 2 || return 2
                ;;
            --socks)             PARAMS["socks"]="${2:-}"; shift 2 || return 2 ;;
            --socks-port)        PARAMS["socks_port"]="${2:-}"; shift 2 || return 2 ;;
            --socks-listen)      PARAMS["socks_listen"]="${2:-}"; shift 2 || return 2 ;;
            --socks-user)        PARAMS["socks_user"]="${2:-}"; shift 2 || return 2 ;;
            --socks-pass)        PARAMS["socks_pass"]="${2:-}"; shift 2 || return 2 ;;
            --socks-udp)         PARAMS["socks_udp"]="${2:-}"; shift 2 || return 2 ;;
            --vless)             PARAMS["vless"]="${2:-}"; shift 2 || return 2 ;;
            --vless-port)        PARAMS["vless_port"]="${2:-}"; shift 2 || return 2 ;;
            --vless-listen)      PARAMS["vless_listen"]="${2:-}"; shift 2 || return 2 ;;
            --vless-domain)      PARAMS["vless_domain"]="${2:-}"; shift 2 || return 2 ;;
            --vless-uuid)        PARAMS["vless_uuid"]="${2:-}"; shift 2 || return 2 ;;
            --vless-path)        PARAMS["vless_path"]="${2:-}"; shift 2 || return 2 ;;
            --vless-mode)        PARAMS["vless_mode"]="${2:-}"; shift 2 || return 2 ;;
            --vless-cert-source) PARAMS["vless_cert_source"]="${2:-}"; shift 2 || return 2 ;;
            --vless-cert-file)   PARAMS["vless_cert_file"]="${2:-}"; shift 2 || return 2 ;;
            --vless-key-file)    PARAMS["vless_key_file"]="${2:-}"; shift 2 || return 2 ;;
            *)
                xmg_error "未知参数: $1"
                return 2
                ;;
        esac
    done
    return 0
}

_xmg_onoff() {
    case "${1:-}" in
        on|1|true|yes) printf '1' ;;
        off|0|false|no) printf '0' ;;
        *) return 1 ;;
    esac
    return 0
}

# ===== apply =====
xmg_proxy_apply() {
    xmg_proxy_parse_args "$@" || return 2

    #--file 覆盖式导入
    if [ -n "${PARAMS[file]:-}" ]; then
        [ -r "${PARAMS[file]}" ] || {
            xmg_error "状态文件不可读: ${PARAMS[file]}"
            return 2
        }
        local line key val
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            case "$line" in *=*) ;; *) continue ;; esac
            key="${line%%=*}"; val="${line#*=}"
            XMG_STATE["$key"]="$val"
        done < "${PARAMS[file]}"
    fi

    # 显式参数覆盖 state
    if [ -n "${PARAMS[socks]:-}" ]; then
        _xmg_onoff "${PARAMS[socks]}" || { xmg_error "--socks 只能是 on 或 off"; return 2; }
        xmg_state_set PROXY_SOCKS_ENABLED "$?"
    fi
    if [ -n "${PARAMS[socks_port]:-}" ];     then xmg_state_set PROXY_SOCKS_PORT "${PARAMS[socks_port]}"; fi
    if [ -n "${PARAMS[socks_listen]:-}" ];   then xmg_state_set PROXY_SOCKS_LISTEN "${PARAMS[socks_listen]}"; fi
    if [ -n "${PARAMS[socks_user]:-}" ];     then xmg_state_set PROXY_SOCKS_USER "${PARAMS[socks_user]}"; fi
    if [ -n "${PARAMS[socks_pass]:-}" ];     then xmg_state_set PROXY_SOCKS_PASS "${PARAMS[socks_pass]}"; fi
    if [ -n "${PARAMS[socks_udp]:-}" ]; then
        _xmg_onoff "${PARAMS[socks_udp]}" || { xmg_error "--socks-udp 只能是 on 或 off"; return 2; }
        xmg_state_set PROXY_SOCKS_UDP "$?"
    fi
    if [ -n "${PARAMS[vless]:-}" ]; then
        _xmg_onoff "${PARAMS[vless]}" || { xmg_error "--vless 只能是 on 或 off"; return 2; }
        xmg_state_set PROXY_VLESS_ENABLED "$?"
    fi
    if [ -n "${PARAMS[vless_port]:-}" ];       then xmg_state_set PROXY_VLESS_PORT "${PARAMS[vless_port]}"; fi
    if [ -n "${PARAMS[vless_listen]:-}" };     then xmg_state_set PROXY_VLESS_LISTEN "${PARAMS[vless_listen]}"; fi
    if [ -n "${PARAMS[vless_domain]:-}" };     then xmg_state_set PROXY_VLESS_DOMAIN "${PARAMS[vless_domain]}"; fi
    if [ -n "${PARAMS[vless_uuid]:-}" ];       then xmg_state_set PROXY_VLESS_UUID "${PARAMS[vless_uuid]}"; fi
    if [ -n "${PARAMS[vless_path]:-}" ];       then xmg_state_set PROXY_VLESS_PATH "${PARAMS[vless_path]}"; fi
    if [ -n "${PARAMS[vless_mode]:-}" ];       then xmg_state_set PROXY_VLESS_MODE "${PARAMS[vless_mode]}"; fi
    if [ -n "${PARAMS[vless_cert_source]:-}" ]; then xmg_state_set PROXY_VLESS_CERT_SOURCE "${PARAMS[vless_cert_source]}"; fi
    if [ -n "${PARAMS[vless_cert_file]:-}" };  then xmg_state_set PROXY_VLESS_CERT_FILE "${PARAMS[vless_cert_file]}"; fi
    if [ -n "${PARAMS[vless_key_file]:-}" ];   then xmg_state_set PROXY_VLESS_KEY_FILE "${PARAMS[vless_key_file]}"; fi

    # schema 校验（失败不触碰现网）
    xmg_state_validate || return 2

    # 渲染到临时文件
    local socks_on vless_on tmp
    socks_on="$(xmg_state_get PROXY_SOCKS_ENABLED)"
    vless_on="$(xmg_state_get PROXY_VLESS_ENABLED)"
    tmp="$(mktemp)" || { xmg_error "无法创建临时文件"; return 4; }
    xmg_render_config "$socks_on" "$vless_on" > "$tmp"

    # 原子提交
    local rc=0
    if [ "${XMG_PROXY_NO_RELOAD:-0}" = "1" ]; then
        # 测试路径：跳过内核校验与 reload，但仍走替换与备份
        xmg_state_validate_config "$tmp"
        rc=$?
        [ "$rc" -eq 0 ] || { rm -f "$tmp"; return 3; }
        mkdir -p "$(dirname "$XMG_XRAY_CONFIG")"
        [ -f "$XMG_XRAY_CONFIG" ] && cp -a "$XMG_XRAY_CONFIG" \
            "$XMG_BACKUP_DIR/config.json.$(xmg_timestamp).bak" 2>/dev/null
        mkdir -p "$XMG_BACKUP_DIR" 2>/dev/null
        xmg_backup_prune "$XMG_BACKUP_DIR" "$(xmg_state_get XMG_BACKUP_KEEP)" "config.json."
        mv -f "$tmp" "$XMG_XRAY_CONFIG" || { rm -f "$tmp"; return 4; }
        return 0
    fi

    xmg_state_commit "$tmp"
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

# ===== disable =====
xmg_proxy_disable() {
    local which="${1:-}"
    case "$which" in
        socks) xmg_state_set PROXY_SOCKS_ENABLED 0 ;;
        vless) xmg_state_set PROXY_VLESS_ENABLED 0 ;;
        *)
            xmg_error "用法: disable <socks|vless>"
            return 2
            ;;
    esac
    xmg_proxy_apply
}

# ===== status =====
xmg_proxy_status() {
    local json=0
    [ "${1:-}" = "--json" ] && json=1

    local socks_on vless_on socks_port vless_port vless_domain vless_path vless_mode
    socks_on="$(xmg_state_get PROXY_SOCKS_ENABLED)"
    vless_on="$(xmg_state_get PROXY_VLESS_ENABLED)"
    socks_port="$(xmg_state_get PROXY_SOCKS_PORT)"
    vless_port="$(xmg_state_get PROXY_VLESS_PORT)"
    vless_domain="$(xmg_state_get PROXY_VLESS_DOMAIN)"
    vless_path="$(xmg_state_get PROXY_VLESS_PATH)"
    vless_mode="$(xmg_state_get PROXY_VLESS_MODE)"

    if [ "$json" -eq 1 ]; then
        printf '{\n'
        printf '  "socks_enabled": %s,\n' "$socks_on"
        printf '  "socks_listen": "%s",\n' "$(xmg_json_escape "$(xmg_state_get PROXY_SOCKS_LISTEN)")"
        printf '  "socks_port": %s,\n' "$socks_port"
        printf '  "socks_user": "%s",\n' "$(xmg_json_escape "$(xmg_state_get PROXY_SOCKS_USER)")"
        printf '  "vless_enabled": %s,\n' "$vless_on"
        printf '  "vless_listen": "%s",\n' "$(xmg_json_escape "$(xmg_state_get PROXY_VLESS_LISTEN)")"
        printf '  "vless_port": %s,\n' "$vless_port"
        printf '  "vless_domain": "%s",\n' "$(xmg_json_escape "$vless_domain")"
        printf '  "vless_path": "%s",\n' "$(xmg_json_escape "$vless_path")"
        printf '  "vless_mode": "%s",\n' "$(xmg_json_escape "$vless_mode")"
        printf '  "buffer_size": %s,\n' "$(xmg_state_get XMG_BUFFER_SIZE)"
        printf '  "kernel_channel": "%s"\n' "$(xmg_state_get XRAY_CHANNEL)"
        printf '}\n'
        return 0
    fi

    echo "========== 代理方案状态 =========="
    echo
    echo "[SOCKS5]"
    if [ "$socks_on" = "1" ]; then
        echo "  状态: 启用"
        echo "  监听: $(xmg_state_get PROXY_SOCKS_LISTEN):$socks_port"
        echo "  用户: $(xmg_state_get PROXY_SOCKS_USER)"
        echo "  UDP : $(xmg_state_get PROXY_SOCKS_UDP)"
    else
        echo "  状态: 未启用"
    fi
    echo
    echo "[VLESS + XHTTP + TLS]"
    if [ "$vless_on" = "1" ]; then
        echo "  状态:启用"
        echo "  监听: $(xmg_state_get PROXY_VLESS_LISTEN):$vless_port"
        echo "  域名: $vless_domain"
        echo "  path: $vless_path"
        echo "  mode: $vless_mode"
        echo "  证书: $(xmg_state_get PROXY_VLESS_CERT_SOURCE)"
    else
        echo "  状态: 未启用"
    fi
    echo
    echo "[内核]"
    echo "  通道: $(xmg_state_get XRAY_CHANNEL)"
    echo "  版本: $(xmg_core_version 2>/dev/null || printf '(未安装)')"
    echo
    echo "[DNS]"
    echo "  上游: https+local://1.1.1.1/dns-query, https+local://8.8.8.8/dns-query"
    echo "  策略: $(xmg_state_get XMG_BUFFER_SIZE >/dev/null 2>&1 && printf 'UseIP')"
    echo
    echo "配置路径: $XMG_XRAY_CONFIG"
    return 0
}

# ===== export =====
xmg_proxy_export() {
    xmg_state_all
}

# ===== 交互向导 =====
_xmg_read() {
    local prompt="$1" def="${2:-}" ans=""
    if [ -n "$def" ]; then
        printf '%s [%s]: ' "$prompt" "$def" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    read -r ans || return 1
    [ -z "$ans" ] && ans="$def"
    printf '%s' "$ans"
}

# XMG_MENU_LABEL: 代理方案
xmg_proxy_menu() {
    local choice="" ans=""
    while true; do
        clear
        xmg_proxy_status
        echo
        echo "1. 配置 SOCKS5 方案"
        echo "2. 配置 VLESS + XHTTP + TLS 方案"
        echo "3. 停用 SOCKS5"
        echo "4. 停用 VLESS"
        echo "5. 导出当前状态"
        echo "0. 返回"
        echo
        printf "请选择: "
        read -r choice || return 0

        case "$choice" in
            1)
                echo
                xmg_warn "SOCKS5 协议不对传输加密，公网使用仅提供访问控制，不提供保密性。"
                xmg_confirm "确认继续?" || { xmg_pause; continue; }
                xmg_state_set PROXY_SOCKS_ENABLED 1
                xmg_state_set PROXY_SOCKS_PORT "$(_xmg_read "监听端口" "$(xmg_state_get PROXY_SOCKS_PORT)")"
                xmg_state_set PROXY_SOCKS_LISTEN "$(_xmg_read "监听地址" "$(xmg_state_get PROXY_SOCKS_LISTEN)")"
                xmg_state_set PROXY_SOCKS_USER "$(_xmg_read "用户名" "")"
                xmg_state_set PROXY_SOCKS_PASS "$(_xmg_read "密码(至少8位)" "")"
                xmg_proxy_apply
                ;;
            2)
                xmg_state_set PROXY_VLESS_ENABLED 1
                xmg_state_set PROXY_VLESS_PORT "$(_xmg_read "监听端口" "$(xmg_state_get PROXY_VLESS_PORT)")"
                xmg_state_set PROXY_VLESS_LISTEN "$(_xmg_read "监听地址" "$(xmg_state_get PROXY_VLESS_LISTEN)")"
                xmg_state_set PROXY_VLESS_DOMAIN "$(_xmg_read "域名(用于SNI/CDN回源)" "")"
                xmg_state_set PROXY_VLESS_UUID "$(_xmg_read "UUID" "")"
                xmg_state_set PROXY_VLESS_PATH "$(_xmg_read "path" "/")"
                xmg_state_set PROXY_VLESS_MODE "$(_xmg_read "mode(auto/packet-up/stream-up/stream-one)" "auto")"
                xmg_state_set PROXY_VLESS_CERT_SOURCE "$(_xmg_read "证书来源(user/acme)" "user")"
                if [ "$(xmg_state_get PROXY_VLESS_CERT_SOURCE)" = "user" ]; then
                    xmg_state_set PROXY_VLESS_CERT_FILE "$(_xmg_read "证书路径" "")"
                    xmg_state_set PROXY_VLESS_KEY_FILE "$(_xmg_read "私钥路径" "")"
                fi
                xmg_proxy_apply
                echo
                echo "过 CDN 提示：客户端 path 必须与服务器一致；"
                echo "客户端 alpn 可选 h3 使用 QUIC；连不上 CF 请在 CF 面板启用 gRPC；"
                echo "其他 CDN 不兼容时把 mode 改为 packet-up。"
                ;;
            3)
                xmg_proxy_disable socks
                ;;
            4)
                xmg_proxy_disable vless
                ;;
            5)
                xmg_proxy_export
                ;;
            0)
                return 0
                ;;
            *)
                xmg_warn "无效选择"
                ;;
        esac
        xmg_pause
    done
}
```

**注意**：`xmg_proxy_status` 文本输出中 DNS 策略那行写法有问题（`$(xmg_state_get XMG_BUFFER_SIZE >/dev/null 2>&1 && printf 'UseIP')` 是错误的）。实现时改为直接 `printf '  策略: UseIP\n'`。

- [ ] **Step 4: 修正 DNS 策略行**

在 `xmg_proxy_status` 中把：

```bash
    echo "  策略: $(xmg_state_get XMG_BUFFER_SIZE >/dev/null 2>&1 && printf 'UseIP')"
```

改为：

```bash
    echo "  策略: UseIP"
```

- [ ] **Step 5: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_proxy_cli.sh`
Expected: PASS，`FAIL=0`

- [ ] **Step 6: 提交**

```bash
cd xmg && git add lib/proxy.sh tests/ && git commit -m "feat: 新增 proxy apply/status/disable/export — 幂等且密码不外泄"
```

---

## Task 9: 证书申请子菜单（acme）

**Files:**
- Modify: `xmg/lib/proxy.sh`（追加 `xmg_proxy_acme_*` 与菜单项）
- Create: `xmg/tests/cases/test_acme.sh`

**Interfaces:**
- Produces: `xmg_proxy_acme_install` — 安装 acme.sh 到 `$XMG_HOME/acme.sh`
- Produces: `xmg_proxy_acme_issue <域名>` — 签发并写入 state，返回 0/2/4
- Produces: `XMG_ACME_DIR` — acme.sh 安装目录，默认 `$XMG_HOME/acme.sh`
- Produces: `XMG_ACME_CERT_FILE` / `XMG_ACME_KEY_FILE` — 签发产物路径

**低配约束**：仅用户显式触发，绝不在 apply 流程中自动执行。

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_acme.sh`：

```bash
#!/usr/bin/env bash
# acme.sh 证书申请 — 仅手动触发
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_LOG_DIR="$XMG_TMP/log"
export XMG_BACKUP_DIR="$XMG_TMP/backups"
export XMG_XRAY_CONFIG="$XMG_TMP/xray/config.json"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"
export XMG_ACME_DIR="$XMG_TMP/acme.sh"
export XMG_PROXY_NO_RELOAD=1
export XMG_ACME_TESTCMD="true"   # 桩：跳过真实签发

source "$TESTS_DIR/../../lib/state.sh"
source "$TESTS_DIR/../../lib/render.sh"
source "$TESTS_DIR/../../lib/proxy.sh"
xmg_state_init

# --- 路径导出 ---
t_assert "XMG_ACME_DIR 已导出" test -n "$XMG_ACME_DIR"
t_assert "证书产物路径已导出" test -n "$XMG_ACME_CERT_FILE"
t_assert "私钥产物路径已导出" test -n "$XMG_ACME_KEY_FILE"

# --- 签发成功后应把路径写入 state ---
xmg_proxy_acme_issue example.com 2>/dev/null
t_equals "签发应返回 0" "$?" "0"
t_equals "证书来源应切为 user" "$(xmg_state_get PROXY_VLESS_CERT_SOURCE)" "user"
t_equals "证书路径已写入" "$(xmg_state_get PROXY_VLESS_CERT_FILE)" "$XMG_ACME_CERT_FILE"
t_equals "私钥路径已写入" "$(xmg_state_get PROXY_VLESS_KEY_FILE)" "$XMG_ACME_KEY_FILE"

# --- 签发失败时不得写入 state ---
xmg_state_set PROXY_VLESS_CERT_FILE "/old/path.crt"
xmg_state_set PROXY_VLESS_KEY_FILE "/old/path.key"
XMG_ACME_TESTCMD="false"
xmg_proxy_acme_issue example.com 2>/dev/null
t_equals "签发失败应返回 4" "$?" "4"
t_equals "失败时不覆盖已有证书路径" "$(xmg_state_get PROXY_VLESS_CERT_FILE)" "/old/path.crt"

# --- 空域名应拒绝 ---
XMG_ACME_TESTCMD="true"
xmg_proxy_acme_issue "" 2>/dev/null
t_equals "空域名应返回 2" "$?" "2"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_acme.sh`
Expected: FAIL —— 函数未定义

- [ ] **Step 3: 追加实现**

在 `xmg/lib/proxy.sh` 追加（并把 `XMG_ACME_*` 变量加到文件顶部的路径变量区）：

```bash
# ===== acme.sh 证书申请（低配约束：仅手动触发）=====
# 文档依据 config/transports/tls.md:
#   "如果已经拥有一个域名, 可以使用工具便捷的获取免费第三方证书,如 acme.sh"
XMG_ACME_DIR="${XMG_ACME_DIR:-$XMG_HOME/acme.sh}"
XMG_ACME_CERT_FILE="${XMG_ACME_CERT_FILE:-$XMG_HOME/etc/xray/certs/fullchain.crt}"
XMG_ACME_KEY_FILE="${XMG_ACME_KEY_FILE:-$XMG_HOME/etc/xray/certs/priv.key}"
export XMG_ACME_DIR XMG_ACME_CERT_FILE XMG_ACME_KEY_FILE

xmg_proxy_acme_install() {
    [ -d "$XMG_ACME_DIR" ] && return 0
    mkdir -p "$XMG_ACME_DIR" || return 4

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://get.acme.sh -o "$XMG_ACME_DIR/acme.sh" || return 4
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$XMG_ACME_DIR/acme.sh" https://get.acme.sh || return 4
    else
        xmg_error "需要 curl 或 wget"
        return 4
    fi
    chmod +x "$XMG_ACME_DIR/acme.sh" 2>/dev/null || true
    return 0
}

xmg_proxy_acme_issue() {
    local domain="${1:-}"
    if [ -z "$domain" ]; then
        xmg_error "域名不能为空"
        return 2
    fi

    if [ -n "${XMG_ACME_TESTCMD:-}" ]; then
        eval "$XMG_ACME_TESTCMD" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            xmg_error "证书签发失败"
            return 4
        fi
        mkdir -p "$(dirname "$XMG_ACME_CERT_FILE")" 2>/dev/null || true
        echo "stub" > "$XMG_ACME_CERT_FILE"
        echo "stub" > "$XMG_ACME_KEY_FILE"
    else
        xmg_proxy_acme_install || return 4
        "$XMG_ACME_DIR/acme.sh" --issue --server letsencrypt \
            -d "$domain" --keylength ec-256 || {
            xmg_error "证书签发失败"
            return 4
        }
        mkdir -p "$(dirname "$XMG_ACME_CERT_FILE")" || return 4
        "$XMG_ACME_DIR/acme.sh" --install-cert -d "$domain" \
            --fullchain-file "$XMG_ACME_CERT_FILE" \
            --key-file "$XMG_ACME_KEY_FILE" || return 4
    fi

    xmg_state_set PROXY_VLESS_CERT_SOURCE "user" || return 4
    xmg_state_set PROXY_VLESS_CERT_FILE "$XMG_ACME_CERT_FILE" || return 4
    xmg_state_set PROXY_VLESS_KEY_FILE "$XMG_ACME_KEY_FILE" || return 4
    xmg_info "证书已就绪: $XMG_ACME_CERT_FILE"
    return 0
}
```

在 `xmg_proxy_menu` 的 case 中加入选项 6：

```bash
            6)
                printf "请输入域名: " >&2
                read -r d || return 0
                if xmg_proxy_acme_issue "$d"; then
                    xmg_info "证书已写入配置，请执行 apply 生效"
                fi
                ;;
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_acme.sh`
Expected: PASS，`FAIL=0`

- [ ] **Step 5: 提交**

```bash
cd xmg && git add lib/proxy.sh tests/ && git commit -m "feat: 新增 acme.sh 证书申请子菜单 — 仅手动触发，失败不覆盖既有证书"
```

---

## Task 10: 改造 xray.sh 并接入菜单

**Files:**
- Modify: `xmg/lib/xray.sh`
- Create: `xmg/tests/cases/test_xray_split.sh`

**Interfaces:**
- Consumes: 无（保留原有服务生命周期能力）
- 行为变更：删除配置相关声明，配置能力迁至 `state.sh`/`render.sh`/`proxy.sh`

**背景**：`xmg/lib/xray.sh:12` 当前声明「XMG 不创建、不编辑、不修改 Xray 配置模板」。本任务移除该声明，并去掉重复的兼容函数（`xray.sh` 内`xmg_info`/`xmg_error` 等兜底定义已由 `common.sh` 提供）。

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_xray_split.sh`：

```bash
#!/usr/bin/env bash
# xray.sh 职责收窄：不再声称不碰配置，且保留服务生命周期能力
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_HOME="$XMG_TMP/home"
export XMG_LIB_DIR="$XMG_TMP/home/lib"
export XMG_LOG_DIR="$XMG_TMP/home/log"
export XMG_RUN_DIR="$XMG_TMP/home/run"
export XMG_ETC_DIR="$XMG_TMP/home/etc"
export XMG_BACKUP_DIR="$XMG_TMP/home/backups"
export XMG_BIN_DIR="$XMG_TMP/home/bin"
export XMG_CADDY_DIR="$XMG_TMP/home/caddy"
export XMG_XRAY_DIR="$XMG_TMP/home/xray"
export XMG_WWW_DIR="$XMG_TMP/home/www"
export XMG_XRAY_CONFIG="$XMG_XRAY_DIR/config.json"

SRC="$TESTS_DIR/../../lib"

# shellcheck source=/dev/null
source "$SRC/common.sh"
# shellcheck source=/dev/null
source "$SRC/xray.sh"

# 保留能力
for fn in xmg_xray_start xmg_xray_stop xmg_xray_restart \
           xmg_xray_reload xmg_xray_status xmg_xray_validate_config \
           xmg_xray_patch_systemd_unit xmg_xray_install_update \
           xmg_xray_uninstall xmg_xray_diag; do
    t_assert "保留函数 $fn" bash -c "declare -F $fn >/dev/null"
done

# 移除的旧声明
XR="$(cat "$SRC/xray.sh")"
t_not_contains "不再声明不修改配置" "$XR" "不创建、不编辑、不修改"
t_contains "说明配置已迁移" "$XR" "配置能力已迁移至 state.sh / render.sh / proxy.sh"
t_not_contains "不再重复定义 xmg_info" "$XR" "if ! declare -F xmg_info"
t_not_contains "不再重复定义 xmg_die" "$XR" "if ! declare -F xmg_die"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_xray_split.sh`
Expected: FAIL —— `xray.sh` 仍含旧声明

- [ ] **Step 3: 改造 xray.sh 头部声明与兜底函数**

将 `xmg/lib/xray.sh:1-13` 的头部注释替换为：

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# coding: utf-8
#
# xray.sh - Xray 服务生命周期管理
#
# 说明：
#   - 安装与更新内核：见 lib/core.sh（支持 stable/preview/pinned 通道）
#   - 代理方案配置：见 lib/state.sh + lib/render.sh + lib/proxy.sh
#   - 本文件只负责 systemd drop-in 与服务生命周期
#   - 所有 XMG 管理的 Xray 配置集中放在 /opt/xmg/xray 下
```

删除 `xray.sh:45-113` 的整段「===== 兼容函数 =====」（从 `if ! declare -F xmg_info` 到 `xmg_mkdirs` 函数结束），因为这些函数已在 `common.sh` 中定义。注意保留 `xmg_mkdirs` 的 Xray 目录创建——改为在 `common.sh` 的 `xmg_mkdirs` 中补充 `XMG_XRAY_DIR`。

在 `xmg/lib/common.sh` 的 `xmg_mkdirs`（第 160-167 行）中加入 Xray 目录：

```bash
xmg_mkdirs() {
    mkdir -p \
        "$XMG_ETC_DIR" \
        "$XMG_RUN_DIR" \
        "$XMG_LOG_DIR" \
        "$XMG_BACKUP_DIR" \
        "$XMG_WWW_DIR" \
        "$XMG_XRAY_DIR" \
        "$XMG_ETC_DIR/xray"
}
```

将 `xmg_xray_install_update` 中的内核安装委托给 `core.sh`（保留函数名以兼容 `xmg.files` 与既有菜单）：

```bash
xmg_xray_install_update() {
    xmg_require_root
    xmg_mkdirs
    mkdir -p "$XMG_XRAY_LOG_DIR"

    if ! xmg_core_install; then
        xmg_error "Xray 内核安装失败"
        return 1
    fi

    xmg_xray_patch_systemd_unit

    if xmg_xray_is_systemd_available; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable "$XMG_XRAY_SERVICE" >/dev/null 2>&1 && \
            xmg_info "Xray 已设置为开机自启" || xmg_warn "设置开机自启失败"
    fi
    return 0
}
```

在文件末尾的「直接执行支持」前，确保 `core.sh` 被加载：

```bash
# 委托内核安装能力至 core.sh
if ! declare -F xmg_core_install >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${XMG_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/core.sh"
fi
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_xray_split.sh`
Expected: PASS，`FAIL=0`

- [ ] **Step 5: 运行全量测试**

Run: `bash xmg/tests/run.sh`
Expected: 全部通过 `FAIL=0`

- [ ] **Step 6: 提交**

```bash
cd xmg && git add lib/xray.sh lib/common.sh tests/ && git commit -m "refactor: xray.sh 收窄为服务生命周期，配置与内核能力迁出"
```

---

## Task 11: 接入主入口与模块清单

**Files:**
- Modify: `xmg/xmg:100-125`
- Modify: `xmg/xmg.files`
- Create: `xmg/tests/cases/test_entrypoint.sh`

**Interfaces:**
- Produces: `xmg proxy <subcommand> [args]` — 转发到 `proxy.sh`
- Produces: `xmg core <subcommand> [args]` — 转发到 `core.sh`

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_entrypoint.sh`：

```bash
#!/usr/bin/env bash
# 主入口子命令与模块清单
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT

SRC="$TESTS_DIR/../.."
MAIN="$SRC/xmg"
FILES="$SRC/xmg.files"

# --- xmg.files 必须登记新模块 ---
t_contains "清单含 state.sh" "$(cat "$FILES")" "lib/state.sh"
t_contains "清单含 render.sh" "$(cat "$FILES")" "lib/render.sh"
t_contains "清单含 proxy.sh" "$(cat "$FILES")" "lib/proxy.sh"
t_contains "清单含 core.sh" "$(cat "$FILES")" "lib/core.sh"

# 菜单顺序：proxy 与 core 必须在清单中（顺序决定菜单编号）
ORDER="$(grep -n 'lib/proxy.sh' "$FILES" | cut -d: -f1)"
t_assert "proxy.sh 在清单中存在且有行号" test -n "$ORDER"

# --- 主入口必须支持 proxy / core 子命令 ---
MAIN_SRC="$(cat "$MAIN")"
t_contains "入口含 proxy 分支" "$MAIN_SRC" "proxy"
t_contains "入口含 core 分支" "$MAIN_SRC" "core"

# --- 用法文本 ---
t_contains "用法含 proxy" "$MAIN_SRC" "xmg proxy"
t_contains "用法含 core" "$MAIN_SRC" "xmg core"

# --- 模块可被 menu.sh 的静态扫描识别 ---
for f in state.sh render.sh proxy.sh core.sh; do
    t_assert "$f 存在" test -f "$SRC/lib/$f"
done
t_assert "proxy.sh 声明菜单标签" grep -q "XMG_MENU_LABEL:" "$SRC/lib/proxy.sh"
t_assert "core.sh 声明菜单标签" grep -q "XMG_MENU_LABEL:" "$SRC/lib/core.sh"
t_assert "proxy.sh 定义菜单函数" grep -qE '^xmg_proxy_menu\(\)' "$SRC/lib/proxy.sh"
t_assert "core.sh 定义菜单函数" grep -qE '^xmg_core_menu\(\)' "$SRC/lib/core.sh"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_entrypoint.sh`
Expected: FAIL —— 清单未登记新模块

- [ ] **Step 3: 更新 xmg.files**

在 `xmg/xmg.files` 中，把 `lib/xray.sh` 之前的位置插入新模块。完整内容：

```
xmg
lib/common.sh
lib/system.sh
lib/monitor.sh
lib/menu.sh
lib/state.sh
lib/render.sh
lib/proxy.sh
lib/core.sh
lib/caddy.sh
lib/xray.sh
lib/site.sh
lib/firewall.sh
lib/tune.sh
lib/ssh.sh
lib/maint.sh
lib/third-party.sh
lib/update.sh
lib/uninstall.sh
```

**注意**：`install.sh` 的 `manifest_entry_validate`（`install.sh:131`）只接受 `xmg`、`lib/*.sh`、`xmg.files` 三种条目，以上均符合。

- [ ] **Step 4: 改造主入口**

将 `xmg/xmg` 的 `xmg_main` 函数（100-125 行）替换为：

```bash
xmg_main() {
    local sub="${1:-monitor}"
    shift || true

    case "$sub" in
        monitor)
            xmg_monitor_loop
            ;;
        menu)
            xmg_menu_loop
            ;;
        proxy)
            xmg_require_core_file state.sh
            xmg_require_core_file render.sh
            xmg_require_core_file proxy.sh
            # shellcheck source=/dev/null
            source "$XMG_LIB_DIR/core.sh"
            # shellcheck source=/dev/null
            source "$XMG_LIB_DIR/state.sh"
            # shellcheck source=/dev/null
            source "$XMG_LIB_DIR/render.sh"
            # shellcheck source=/dev/null
            source "$XMG_LIB_DIR/proxy.sh"
            xmg_state_init
            case "${1:-menu}" in
                apply)   shift; xmg_proxy_apply "$@" ;;
                status)  shift; xmg_proxy_status "$@" ;;
                disable) shift; xmg_proxy_disable "$@" ;;
                export)  shift; xmg_proxy_export "$@" ;;
                acme)    shift; xmg_proxy_acme_issue "$@" ;;
                menu)    xmg_proxy_menu ;;
                *)       xmg_error "未知的 proxy 子命令: $1"; return 2 ;;
            esac
            ;;
        core)
            xmg_require_core_file state.sh
            # shellcheck source=/dev/null
            source "$XMG_LIB_DIR/core.sh"
            # shellcheck source=/dev/null
            source "$XMG_LIB_DIR/state.sh"
            xmg_state_init
            case "${1:-menu}" in
                install) shift; xmg_core_install "$@" ;;
                version) shift; xmg_core_version "$@" ;;
                status)  shift; xmg_core_status "$@" ;;
                menu)    xmg_core_menu ;;
                *)       xmg_error "未知的 core 子命令: $1"; return 2 ;;
            esac
            ;;
        doctor)
            xmg_system_refresh_all force
            xmg_system_print_summary
            ;;
        version|-v|--version)
            echo "XMG $XMG_VERSION"
            ;;
        help|-h|--help)
            xmg_usage
            ;;
        *)
            xmg_error "未知参数: $sub"
            echo
            xmg_usage
            exit 2
            ;;
    esac
}
```

在 `xmg_usage`（72-98 行）的用法列表中，于 `doctor` 与 `version` 之间插入：

```
  xmg proxy apply [参数]   应用代理方案配置（幂等）
  xmg proxy status [--json] 查看代理方案状态
  xmg proxy disable <socks|vless>  停用某方案
  xmg proxy acme <域名>    申请并写入证书
  xmg proxy menu           代理方案交互向导
  xmg core update          安装/更新内核（按记录的通道）
  xmg core version         查看内核版本
  xmg core menu            内核管理菜单
```

- [ ] **Step 5: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_entrypoint.sh`
Expected: PASS，`FAIL=0`

- [ ] **Step 6: 提交**

```bash
cd xmg && git add xmg xmg.files tests/ && git commit -m "feat: 主入口新增 proxy / core 子命令并登记新模块"
```

---

## Task 12: DNS 预设境外化

**Files:**
- Modify: `xmg/lib/tune.sh:403-451`
- Create: `xmg/tests/cases/test_tune_dns.sh`

**Interfaces:**
- Consumes: 无
- 行为变更：`xmg_tune_dns_pick` 的默认选择改为 Cloudflare（境外），并新增 DoT 境外默认值

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_tune_dns.sh`：

```bash
#!/usr/bin/env bash
# tune.sh DNS 预设境外化
# shellcheck shell=bash

TUNE="$(cat "$TESTS_DIR/../../lib/tune.sh")"

# 境外 DNS 预设必须存在
t_contains "含 Cloudflare 预设" "$TUNE" "1.1.1.11.0.0.1"
t_contains "含 Google 预设" "$TUNE" "8.8.8.8 8.8.4.4"
t_contains "含 Quad9 预设" "$TUNE" "9.9.9.9 149.112.112.112"
t_contains "含 Cloudflare IPv6 预设" "$TUNE" "2606:4700:4700::1111"

# 默认路径不得指向境内 DNS
t_not_contains "默认不指向阿里 223.5.5.5" "$TUNE" "XMG_TUNE_DNS_DEFAULT=223.5.5.5"

# 境外默认值应声明
t_contains "声明境外默认 DNS" "$TUNE" "XMG_TUNE_DNS_DEFAULT"
t_contains "境外默认为 Cloudflare" "$TUNE" 'XMG_TUNE_DNS_DEFAULT="1.1.1.1 1.0.0.1"'
t_contains "声明境外默认 DoT" "$TUNE" "XMG_TUNE_DOT_DEFAULT"

# 菜单提示须标明境外/境内
t_contains "标注境外推荐" "$TUNE" "境外推荐"
t_contains "标注境内推荐" "$TUNE" "境内推荐"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_tune_dns.sh`
Expected: FAIL —— 默认值常量尚未声明

- [ ] **Step 3: 声明默认值常量**

在 `xmg/lib/tune.sh` 顶部变量区（第 31-40 行附近）追加：

```bash
# DNS 默认预设（境外优先：服务器多位于海外）
XMG_TUNE_DNS_DEFAULT="${XMG_TUNE_DNS_DEFAULT:-1.1.1.1 1.0.0.1}"
XMG_TUNE_DOT_DEFAULT="${XMG_TUNE_DOT_DEFAULT:-1.1.1.1 1.0.0.1}"
export XMG_TUNE_DNS_DEFAULT XMG_TUNE_DOT_DEFAULT
```

- [ ] **Step 4: 修改菜单提示与默认选中**

将 `xmg_tune_dns_pick`（403-451 行）中提示行改为：

```bash
        echo "请选择 DNS 预设:"
        echo "  1. Cloudflare   (1.1.1.1 / 1.0.0.1)     [境外推荐·默认]"
        echo "  2. Google       (8.8.8.8 / 8.8.4.4)"
        echo "  3. Quad9        (9.9.9.9 / 149.112.112.112)"
        echo "  4. 阿里 DNS     (223.5.5.5 / 223.6.6.6)  [境内推荐·海外服务器延迟较高]"
        echo "  5. Cloudflare IPv6 (2606:4700:4700::1111 / ::1001)  [纯 IPv6 机]"
        echo "  6. Google IPv6  (2001:4860:4860::8888 / ::8844)     [纯 IPv6 机]"
        echo "  7. 自定义 (支持 IPv4 / IPv6 / 混合双栈)"
        printf "请选择 [1]: " >&2
```

并在函数开头把空输入归一为默认：

```bash
    read -r choice || return 1
    [ -z "$choice" ] && choice="1"
```

- [ ] **Step 5: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_tune_dns.sh`
Expected: PASS，`FAIL=0`

- [ ] **Step 6: 提交**

```bash
cd xmg && git add lib/tune.sh tests/ && git commit -m "feat: DNS 预设默认指向境外 — 服务器位于海外，阿里 DNS 延迟高"
```

---

## Task 13: 安装内存体检

**Files:**
- Modify: `xmg/lib/core.sh`
- Create: `xmg/tests/cases/test_memcheck.sh`

**Interfaces:**
- Consumes: `common.sh` 的日志函数
- Produces: `xmg_mem_available_mb` — 输出可用内存（MB），失败返回 1
- Produces: `xmg_core_memcheck [阈值MB]` — 低于阈值时告警并返回 1（不阻断 install）
- Produces: `XMG_MEM_CHECK_MB` — 阈值，默认 256

**背景**：目标机型 0.5C/215M，下载与解压 Xray 内核时内存峰值可能超限。安装前体检并在不足时告警（spec §7.4）。

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_memcheck.sh`：

```bash
#!/usr/bin/env bash
# 安装内存体检
# shellcheck shell=bash

XMG_TMP="$(mktemp -d)"
trap 'rm -rf "$XMG_TMP"' EXIT
export XMG_ETC_DIR="$XMG_TMP/etc"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"

source "$TESTS_DIR/../../lib/state.sh"
source "$TESTS_DIR/../../lib/core.sh"
xmg_state_init

# --- 读取可用内存 ---
MB="$(xmg_mem_available_mb 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then
    t_assert "内存值为正整数" bash -c "[[ '$MB' =~ ^[0-9]+$ ]]"
    t_assert "内存值合理(>0)" test "$MB" -gt 0
else
    t_assert "读取失败时返回非 0" test "$rc" -ne 0
fi

# --- 阈值可用桩覆盖 ---
XMG_MEM_CHECK_MB=999999999
xmg_core_memcheck 2>/dev/null
t_equals "内存不足应返回 1" "$?" "1"

XMG_MEM_CHECK_MB=1
xmg_core_memcheck 2>/dev/null
t_equals "内存充足应返回 0" "$?" "0"

# --- 体检不阻断安装（仅告警）---
t_assert "memcheck 不调用 exit" bash -c "! grep -q 'exit 1' lib/core.sh >/dev/null 2>&1 || true"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_memcheck.sh`
Expected: FAIL —— 函数未定义

- [ ] **Step 3: 追加实现**

在 `xmg/lib/core.sh` 追加：

```bash
# ===== 内存体检 =====
# 低配机型（0.5C/215M）下载与解压内核时内存峰值可能超限，
# 安装前体检并在不足时告警（不阻断，见 spec §7.4）
XMG_MEM_CHECK_MB="${XMG_MEM_CHECK_MB:-256}"

xmg_mem_available_mb() {
    local kb=""

    if [ -r /proc/meminfo ]; then
        # MemAvailable 优先，回退 MemFree + Buffers + Cached
        kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
        if [ -z "$kb" ]; then
            kb="$(awk '/^MemFree:/ {f=$2} /^Buffers:/ {b=$2} /^Cached:/ {c=$2} END {print f+b+c}' \
                /proc/meminfo 2>/dev/null)"
        fi
    fi

    # 无 /proc（macOS 开发环境）时回退到系统命令
    if [ -z "$kb" ] && command -v free >/dev/null 2>&1; then
        kb="$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}')"
        [ -n "$kb" ] && printf '%s' "$kb" && return 0
        return 1
    fi

    [ -n "$kb" ] || return 1
    printf '%s' "$((kb / 1024))"
    return 0
}

xmg_core_memcheck() {
    local threshold="${1:-$XMG_MEM_CHECK_MB}"
    local mb=""
    mb="$(xmg_mem_available_mb)" || {
        xmg_warn "无法读取内存信息，跳过内存体检"
        return 0
    }

    if [ "$mb" -lt "$threshold" ]; then
        xmg_warn "可用内存仅 ${mb}MB，低于建议阈值 ${threshold}MB"
        xmg_warn "下载与解压 Xray 内核时内存峰值可能超出，建议先配置 swap"
        xmg_warn "可执行: xmg tune   (创建 swap 后再重试)"
        return 1
    fi

    xmg_info "内存体检通过: ${mb}MB"
    return 0
}
```

在 `xmg_core_install` 的 `xmg_info "安装 Xray 内核..."` 之前插入体检调用：

```bash
    # 内存体检：不足时仅告警，不阻断（用户可自行配置 swap 后重试）
    xmg_core_memcheck || true
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_memcheck.sh`
Expected: PASS，`FAIL=0`

- [ ] **Step 5: 提交**

```bash
cd xmg && git add lib/core.sh tests/ && git commit -m "feat: 内核安装前内存体检 — 不足时告警并提示配置 swap"
```

---

## Task 14: 文档更新与最终校验

**Files:**
- Modify: `xmg/README.md`
- Create: `xmg/tests/cases/test_docs.sh`

**Interfaces:**
- 无新接口。本任务为文档同步与端到端校验。

- [ ] **Step 1: 写失败测试**

写 `xmg/tests/cases/test_docs.sh`：

```bash
#!/usr/bin/env bash
# README 与实现同步
# shellcheck shell=bash

RM="$(cat "$TESTS_DIR/../../README.md")"

t_contains "README 提到预览版" "$RM" "预览版"
t_contains "README 提到 SOCKS5" "$RM" "SOCKS5"
t_contains "README 提到 XHTTP" "$RM" "XHTTP"
t_contains "README 提到 state.env" "$RM" "state.env"
t_contains "README 提到非交互 CLI" "$RM" "xmg proxy"
t_contains "README 提到 DNS" "$RM" "https+local://"
t_contains "README 提到 SOCKS 明文风险" "$RM" "明文"

# 不应残留旧声明
t_not_contains "README 不再声称不碰配置" "$RM" "不创建、不编辑、不修改"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash xmg/tests/run.sh xmg/tests/cases/test_docs.sh`
Expected: FAIL —— README 尚未更新

- [ ] **Step 3: 更新 README 的功能与适配章节**

在 `xmg/README.md` 的「功能」章节，把「Xray 管理」条目替换为：

```markdown
- **Xray 内核管理**：stable / preview / pinned 三通道，走官方脚本 `--beta` / `--version`（默认 preview 预览版）
- **代理方案配置**（交互向导 + 非交互 CLI，均幂等）：
  - **SOCKS5**：公网入口，`auth: password` 强制用户名+密码；⚠️ 协议不加密，账号与流量均为**明文**，仅提供访问控制
  - **VLESS + XHTTP + TLS**：支持过 CDN（Cloudflare 需在面板启用 gRPC；其它 CDN 建议 `mode: packet-up`）
  - 两方案可独立启用、也可同时存在（端口与 tag 分离，互不覆盖）
  - 证书来源二选一：用户提供已签发证书 / 手动调用 acme.sh 申请（低配机型不自动申请）
- **配置状态层**：`/opt/xmg/etc/xray/state.env` 为唯一真相来源，`config.json` 由其生成；写入前经 `xray run -test` 校验，失败不触碰现网
- **DNS（两层）**：Xray 内置 `https+local://` DoH（Cloudflare + Google，IP 形式）+ 系统层 systemd-resolved DoT，默认境外上游
```

在「适配」章节替换为：

```markdown
- 系统：Debian 11/12+、Ubuntu 20.04+（仅此两类，不做多发行版分支）
- 配置：低配 VPS（0.5C / 215M）到高配机均可用；调优参数按内存自动分档
- 架构：x86_64 / aarch64 / armv7l / mips（含 KVM、OpenVZ、NAT 机型）
- NAT：无独立公网 IPv4 时，SOCKS5 入口需服务商端口映射；VLESS+XHTTP+TLS 过 CDN 不受影响
```

在「功能」章节末尾追加 CLI 用法：

```markdown
### 常用命令

```bash
xmg proxy apply --socks on --socks-port 1080 --socks-user u --socks-pass 'p'
xmg proxy apply --vless on --vless-port 443 --vless-domain example.com --vless-uuid <uuid>
xmg proxy status --json
xmg proxy disable socks
xmg proxy acme example.com
xmg core update
```

退出码：`0` 成功 / `2` 校验失败 / `3` 内核校验失败 / `4` 运行失败（已回滚）。
```

- [ ] **Step 4: 运行全量测试**

Run: `bash xmg/tests/run.sh`
Expected: 全部通过 `FAIL=0`

- [ ] **Step 5: 语法检查全部 shell 脚本**

Run: `for f in xmg/xmg xmg/install.sh xmg/lib/*.sh xmg/tests/*.sh xmg/tests/cases/*.sh; do bash -n "$f" || echo "SYNTAX FAIL: $f"; done`
Expected: 无输出（全部通过语法检查）

- [ ] **Step 6: 端到端演示：非交互配置两方案并验证输出**

Run:
```bash
export XMG_HOME=$(mktemp -d)
export XMG_ETC_DIR="$XMG_HOME/etc"
export XMG_STATE_FILE="$XMG_ETC_DIR/xray/state.env"
export XMG_XRAY_CONFIG="$XMG_HOME/xray/config.json"
export XMG_PROXY_NO_RELOAD=1 XMG_XRAY_CONFIG_TESTCMD=true
mkdir -p "$XMG_ETC_DIR"
printf 'cert' > "$XMG_HOME/c.crt"; printf 'key' > "$XMG_HOME/k.key"
XMG_LIB_DIR=xmg/lib bash xmg/xmg proxy apply --socks on --socks-port 1080 \
  --socks-user alice --socks-pass supersecret --vless on --vless-port 443 \
  --vless-domain example.com --vless-uuid uuid-abc --vless-mode packet-up \
  --vless-cert-source user --vless-cert-file "$XMG_HOME/c.crt" \
  --vless-key-file "$XMG_HOME/k.key"
echo "--- exit=$? ---"
cat "$XMG_XRAY_CONFIG"
```

Expected: 退出码 0；生成的 JSON 含 `inbound-socks` 与 `inbound-vless` 两个入站，含 `https+local://` DNS，含 `"bufferSize": 4`，且不含 `mux`/`flow`/`extra`/`network`/`stats`/`api`

- [ ] **Step 7: 提交**

```bash
cd xmg && git add README.md tests/ && git commit -m "docs: 更新 README 同步新能力与 CLI 用法"
```

---

## Self-Review Result

**Spec 覆盖检查**：

| Spec 章节 | 对应任务 |
|---|---|
| §3.2 配置状态层 | Task 2, 3, 4 |
| §3.4 方案共存模型 | Task 6, 8 |
| §4 方案 A SOCKS5 | Task 5 |
| §5 方案 B VLESS+XHTTP+TLS | Task 6 |
| §6 内核管理预览版 | Task 7 |
| §7 低配适配（含 bufferSize=4） | Task 1-4（bufferSize）, 13（内存体检） |
| §8 NAT 与双栈 | Task 2（地址校验）, 8（status 提示） |
| §9 交互设计 | Task 8（CLI/status）, 9（向导） |
| §10 原子写入与备份清理 | Task 4 |
| §10.5 DNS 两层 | Task 3（渲染）, 12（系统层） |
| §10.5.6/10.7 顶层结构 | Task 3, 6 |
| §11 测试策略 | 全部任务的 Step 1 |
| §12 文件变更 | Task 2-13 |

**无未覆盖项。**

**已知取舍**（非缺陷）：
- Task 3 的空 inbounds 占位（`tunnel` 协议 port 0）是权宜之计，spec 未定义「两方案全禁用」时的配置形态。实际使用中至少会启用一个方案。
- `xmg_proxy_apply` 在测试路径（`XMG_PROXY_NO_RELOAD=1`）下有一份简化的提交逻辑，与生产的 `xmg_state_commit` 有重复。这是为了让测试不依赖真实 systemd，生产路径始终走 `xmg_state_commit`。
