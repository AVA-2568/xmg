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

    # 清掉模块的「加载一次」守卫，让每个用例都能按自己导出的环境变量
    # 重新加载模块。守卫是为生产环境单进程设计的（模块只加载一次），
    # 而本入口在同一个 shell 里 source 多个用例，两者语义冲突：
    # 第一个 source 某模块的用例会锁死该模块按彼时环境推导出的路径变量，
    # 后续用例即使导出新路径，守卫也会直接 return 而不重新推导，
    # 表现为跨用例污染（曾导致 set -u 下 unbound variable 直接崩掉入口）。
    # 用前缀展开 + case 匹配，避免以后新增模块时漏改这里。
    for _xmg_g in "${!XMG_@}"; do
        case "$_xmg_g" in
            *_SH_LOADED) unset "$_xmg_g" ;;
        esac
    done

    # shellcheck source=/dev/null
    source "$case_file"
done

t_summary