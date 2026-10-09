#!/usr/bin/env bash
# 测试断言框架 — 零依赖，仅用 bash 内建
#
# 重要约束：所有断言函数必须直接在当前 shell 调用。
# 一旦放进管道左端、$(...) 或后台任务，就会进入子 shell，
# 计数器自增只改副本，父进程读到的仍是旧值（失败会静默通过）。
# 框架会用 BASHPID 检测这种误用并直接报错。
#
# shellcheck shell=bash

TESTS_PASS=0
TESTS_FAIL=0

# 本 shell 的身份。BASHPID 在子 shell 里会变，$$ 不会，故用 BASHPID 检测。
# 老 bash 无 BASHPID 时两者都为空串，退化为不检测（行为同修复前）。
T_LIB_PID="${BASHPID:-}"

# 若当前处于子 shell，打印显式错误并返回 0（让调用方走失败计数分支）。
# 无法在函数内部补救——子 shell 的变量改动无法回传父进程，只能让误用暴露出来。
_t_guard_subshell() {
    if [ "${BASHPID:-}" != "$T_LIB_PID" ]; then
        printf '  [ERROR] %s: 断言在子 shell 中被调用，计数无法回传，判定结果不可信。\n' "$1" >&2
        printf '         请直接调用，不要放进管道 / $(...) / 后台任务。\n' >&2
        printf '         命令本身需要管道时，把整条命令写成字符串：t_assert "描述" "cmd | cat"\n' >&2
        return 0
    fi
    return 1
}

t_assert() {
    local desc="$1"
    shift

    if _t_guard_subshell "$desc"; then
        TESTS_FAIL=$((TESTS_FAIL + 1))
        return 0
    fi

    # 没有命令可比对退出码，判失败（与修复前 "command not found" 的结果一致）。
    if [ "$#" -eq 0 ]; then
        TESTS_FAIL=$((TESTS_FAIL + 1))
        printf '  [FAIL] %s\n' "$desc" >&2
        printf '         未提供待执行的命令\n' >&2
        return 0
    fi

    # 分派规则：只有「参数整体就是一条命令字符串」（$# -eq 1）才走 eval。
    #
    # 绝不能用 $* 判断是否含元字符：$* 是把所有参数用空格拼成一个字符串，
    # 参数内部的引号信息全部丢失。于是
    #     t_assert "描述" grep -qE "listen|inbounds" file
    # 拼接后变成 `grep -qE listen|inbounds file`，| 被误判为管道而走 eval，
    # eval 又把它解析成真管道 → 正则被拆成两个命令，判定完全失真
    # （假失败：明明匹配成功却判FAIL；假通过：false "|| true" 变成 true）。
    #
    # $# -eq 1 说明调用方自己把整条命令写成了一个字符串，此时它本就该被
    # 当作 shell 代码解析；$# -gt 1 说明参数边界由调用方用引号定好了，
    # 必须原样交给 execve，绝不二次解析。
    local rc=0
    if [ "$#" -eq 1 ]; then
        # 单参数为空字符串：没有可执行的命令，语义同 $# -eq 0，判失败。
        # 必须显式拦下：`eval ""` 不报错且 PIPESTATUS=(0)，rc=0，
        # 会把"调用方根本没给命令"静默判成通过（$# 分派引入的行为变化）。
        if [ -z "$1" ]; then
            TESTS_FAIL=$((TESTS_FAIL + 1))
            printf '  [FAIL] %s\n' "$desc" >&2
            printf '         未提供待执行的命令\n' >&2
            return 0
        fi

        # 整条命令是一个字符串：必须 eval 在当前 shell 展开，
        # 否则 "$@" 会把整串当成单个命令名去查找，必然 command not found。
        #
        # PIPESTATUS 必须与管道在同一次 eval 内、紧跟其后读取：
        # eval 自身是单条命令，跨语句读拿到的是 eval 的退出码而非管道各段状态。
        local -a _t_st=()
        eval "$1
_t_st=(\"\${PIPESTATUS[@]}\")" >/dev/null 2>&1
        # 语义同 pipefail：管道任一段失败即视为断言失败。
        local i
        for i in "${_t_st[@]}"; do
            if [ "$i" -ne 0 ]; then
                rc=1
            fi
        done
    else
        # 多参数：参数边界与引号由 bash 正常处理，直接调用，不做任何二次解析。
        "$@" >/dev/null 2>&1 || rc=1
    fi

    if [ "$rc" -eq 0 ]; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        printf '  [FAIL] %s\n' "$desc" >&2
        printf '         命令失败: %s\n' "$*" >&2
    fi
    return 0
}

t_contains() {
    local desc="$1" hay="$2" needle="$3"

    if _t_guard_subshell "$desc"; then
        TESTS_FAIL=$((TESTS_FAIL + 1))
        return 0
    fi

    if [[ "$hay" == *"$needle"* ]]; then
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        TESTS_FAIL=$((TESTS_FAIL + 1))
        printf '  [FAIL] %s\n' "$desc" >&2
        printf '         期望包含: %s\n' "$needle" >&2
        # 用 bash 内建截断，不依赖 head（BusyBox 行为不一致）
        printf '         实际内容: %s\n' "${hay:0:400}" >&2
    fi
    return 0
}

t_not_contains() {
    local desc="$1" hay="$2" needle="$3"

    if _t_guard_subshell "$desc"; then
        TESTS_FAIL=$((TESTS_FAIL + 1))
        return 0
    fi

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

    if _t_guard_subshell "$desc"; then
        TESTS_FAIL=$((TESTS_FAIL + 1))
        return 0
    fi

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

t_fail() {
    local desc="$*"

    if _t_guard_subshell "$desc"; then
        TESTS_FAIL=$((TESTS_FAIL + 1))
        return 0
    fi

    TESTS_FAIL=$((TESTS_FAIL + 1))
    printf '  [FAIL] %s\n' "$desc" >&2
    return 0
}

t_summary() {
    printf '\nPASS=%d FAIL=%d\n' "$TESTS_PASS" "$TESTS_FAIL" >&2
    [ "$TESTS_FAIL" -eq 0 ]
}