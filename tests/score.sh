#!/usr/bin/env bash
# XMG 工程质量 100 分自动化评分器（5 维度 × 20 分 = 100 分，纯 Bash 零外部依赖）
# 用法: bash tests/score.sh [--skip-tests]
# shellcheck shell=bash
unset BASH_ENV ENV 2>/dev/null || true
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

SKIP_TESTS=0
[ "${1:-}" = "--skip-tests" ] && SKIP_TESTS=1

PROD_FILES=("xmg" "install.sh" lib/*.sh)

# 辅助：过滤注释行并计数匹配
_count_prod_grep() {
    local pattern="$1"
    local hits=""
    hits="$(grep -rnE "$pattern" "${PROD_FILES[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
    if [ -z "$hits" ]; then
        printf '0'
        return 0
    fi
    local c=0 _l=""
    while IFS= read -r _l; do
        [ -n "$_l" ] && c=$((c + 1))
    done <<< "$hits"
    printf '%d' "$c"
}

# ==============================================================================
# 维度 1: 语法与静态安全门禁 (20 分)
# ==============================================================================
s1=20
d1_notes=()

# 1.1 bash -n 全量语法检查 (5 分)
syntax_err=0
for f in "${PROD_FILES[@]}" tests/run.sh tests/lib.sh tests/score.sh tests/cases/test_*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
        syntax_err=$((syntax_err + 1))
    fi
done
if [ "$syntax_err" -gt 0 ]; then
    s1=$((s1 - 5))
    d1_notes+=("语法错误=${syntax_err}(-5)")
fi

# 1.2 危险/非兼容语法清零: sed -i, echo -e, eval, grep -P, curl -k (5 分，每类 -1)
for pair in \
    'sed_i:\bsed[[:space:]]+-i\b' \
    'echo_e:\becho[[:space:]]+-e\b' \
    'eval:(^|[;&|][[:space:]]*)eval[[:space:]]+' \
    'grep_P:\bgrep[[:space:]][^|]*-[a-zA-Z]*P' \
    'curl_k:\bcurl[[:space:]][^|]*([[:space:]]-k\b|--insecure)'; do
    label="${pair%%:*}"
    pat="${pair#*:}"
    cnt="$(_count_prod_grep "$pat")"
    if [ "$cnt" -gt 0 ]; then
        s1=$((s1 - 1))
        d1_notes+=("${label}=${cnt}(-1)")
    fi
done

# 1.3 read 缺 -r / 硬编码 /tmp/xmg 路径 (5 分)
read_no_r="$(_count_prod_grep '\bread[[:space:]]+[^-][^|]*[a-zA-Z_]')"
hard_tmp="$(_count_prod_grep '/tmp/xmg[a-zA-Z0-9_.-]*')"
if [ "$read_no_r" -gt 0 ] || [ "$hard_tmp" -gt 0 ]; then
    s1=$((s1 - 5))
    d1_notes+=("read_no_r=${read_no_r},hard_tmp=${hard_tmp}(-5)")
fi

# 1.4 curl / wget 网络请求超时保护 (5 分，每处 -2，最多扣 5)
no_to=0
for f in "${PROD_FILES[@]}"; do
    mapfile -t _lines < "$f"
    total_l="${#_lines[@]}"
    for (( idx=0; idx<total_l; idx++ )); do
        line="${_lines[$idx]}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ (^|[[:space:]\;\&\|\(])(curl|wget)[[:space:]]+ ]]; then
            # 排除提示文案/命令检测/循环列表
            [[ "$line" == *"command -v"* || "$line" == *"--version"* || "$line" == *"for "* || "$line" == *"xmg_error"* || "$line" == *"xmg_warn"* || "$line" == *"die "* ]] && continue
            block="$line"
            [ $((idx + 1)) -lt "$total_l" ] && block+=$'\n'"${_lines[$((idx + 1))]}"
            [ $((idx + 2)) -lt "$total_l" ] && block+=$'\n'"${_lines[$((idx + 2))]}"
            if [[ "$block" != *"--max-time"* && "$block" != *" -m "* && "$block" != *"--timeout"* && "$block" != *" -T "* && "$block" != *"--connect-timeout"* ]]; then
                no_to=$((no_to + 1))
            fi
        fi
    done
done
if [ "$no_to" -gt 0 ]; then
    ded=$((no_to * 2))
    [ "$ded" -gt 5 ] && ded=5
    s1=$((s1 - ded))
    d1_notes+=("curl/wget缺超时=${no_to}(-${ded})")
fi
[ "$s1" -lt 0 ] && s1=0

# ==============================================================================
# 维度 2: 低配 VPS 零 Fork 性能规范 (20 分)
# ==============================================================================
s2=20
d2_notes=()

# 2.1 无用 cat <file> | ... 管道（排除 systemctl cat）(4 分，每处 -2)
cat_pipe_hits="$(grep -rnE '\bcat[[:space:]]+[^|]+\|[[:space:]]*(grep|awk|sed|head|tail|wc|tr|cut|jq)\b' "${PROD_FILES[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v 'systemctl cat' || true)"
cat_pipe=0
if [ -n "$cat_pipe_hits" ]; then
    while IFS= read -r _l; do [ -n "$_l" ] && cat_pipe=$((cat_pipe + 1)); done <<< "$cat_pipe_hits"
fi
if [ "$cat_pipe" -gt 0 ]; then
    ded=$((cat_pipe * 2))
    [ "$ded" -gt 4 ] && ded=4
    s2=$((s2 - ded))
    d2_notes+=("cat管道=${cat_pipe}(-${ded})")
fi

# 2.2 无用 echo/printf | grep/awk/sed/tr/cut/wc 字符串管道（排除命令替换内部如 echo "$(cmd | grep)"）(16 分，每处 -1)
str_pipe_hits="$(grep -rnE '(^|[;&|[:space:]])(echo|printf)[[:space:]]+[^$|]+\|[[:space:]]*(grep|awk|sed|tr|cut|wc)\b' "${PROD_FILES[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
# 再精确扫描 echo "$var" | ... / printf '%s\n' "$var" | ...
str_pipe_hits2="$(grep -rnE '(^|[;&|[:space:]])(echo|printf)[[:space:]]+[^|]*\|[[:space:]]*(grep|awk|sed|tr|cut|wc)\b' "${PROD_FILES[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE '(echo|printf)[[:space:]]+[^|]*\$\([^)]*\|' || true)"
str_pipe=0
if [ -n "$str_pipe_hits2" ]; then
    while IFS= read -r _l; do [ -n "$_l" ] && str_pipe=$((str_pipe + 1)); done <<< "$str_pipe_hits2"
fi
if [ "$str_pipe" -gt 0 ]; then
    ded="$str_pipe"
    [ "$ded" -gt 16 ] && ded=16
    s2=$((s2 - ded))
    d2_notes+=("echo/printf管道=${str_pipe}(-${ded})")
fi
[ "$s2" -lt 0 ] && s2=0

# ==============================================================================
# 维度 3: 跨平台与边界健壮性 (20 分)
# ==============================================================================
s3=20
d3_notes=()

# 3.1 零 SC2155 (local x=$(...)) (5 分)
sc2155="$(_count_prod_grep '^[[:space:]]*local[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*=\$\([^\(]')"
if [ "$sc2155" -gt 0 ]; then
    s3=$((s3 - 5))
    d3_notes+=("SC2155=${sc2155}(-5)")
fi

# 3.2 xmg.files 清单完整性 (5 分)
manifest_err=0
if [ ! -f xmg.files ]; then
    manifest_err=1
else
    while IFS= read -r mf; do
        [ -z "$mf" ] && continue
        [ -f "$mf" ] || manifest_err=$((manifest_err + 1))
    done < xmg.files
    for libf in lib/*.sh; do
        grep -Fxq "$libf" xmg.files || manifest_err=$((manifest_err + 1))
    done
fi
if [ "$manifest_err" -gt 0 ]; then
    s3=$((s3 - 5))
    d3_notes+=("清单不一致=${manifest_err}(-5)")
fi

# 3.3 测试框架隔离：零相对路径 source lib/ + run.sh 清理 BASH_ENV (5 分)
rel_src="$(grep -rnE '\bsource[[:space:]]+lib/' tests/cases/ 2>/dev/null | grep -v 'test_framework_selfcheck.sh' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$rel_src" ] || ! grep -q 'unset BASH_ENV' tests/run.sh; then
    s3=$((s3 - 5))
    d3_notes+=("测试隔离不完整(-5)")
fi

# 3.4 零孤立死函数（全仓库生产+测试仅出现 1 次即定义本身的 xmg_* 函数）(5 分，每个 -2)
dead_cnt=0
all_search_files=("${PROD_FILES[@]}" tests/run.sh tests/lib.sh tests/cases/test_*.sh)
while IFS= read -r fn; do
    [ -z "$fn" ] && continue
    refs="$(grep -ow "$fn" "${all_search_files[@]}" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${refs:-0}" -le 1 ]; then
        dead_cnt=$((dead_cnt + 1))
    fi
done < <(grep -hoE '^[[:space:]]*_?xmg_[a-zA-Z0-9_]+\(\)' "${PROD_FILES[@]}" 2>/dev/null | sed 's/^[[:space:]]*//; s/()$//' | sort -u)
if [ "$dead_cnt" -gt 0 ]; then
    ded=$((dead_cnt * 2))
    [ "$ded" -gt 5 ] && ded=5
    s3=$((s3 - ded))
    d3_notes+=("孤立死函数=${dead_cnt}(-${ded})")
fi
[ "$s3" -lt 0 ] && s3=0

# ==============================================================================
# 维度 4: 单元测试与核心覆盖度 (20 分)
# ==============================================================================
s4=20
d4_notes=()

# 4.1 全量测试套件执行 (10 分)
test_summary="SKIPPED"
if [ "$SKIP_TESTS" -eq 0 ]; then
    test_out="$(BASH_ENV= bash tests/run.sh 2>&1)"
    test_rc=$?
    test_summary="$(printf '%s\n' "$test_out" | grep -E '^PASS=[0-9]+ FAIL=[0-9]+' | tail -n 1 || true)"
    if [ "$test_rc" -ne 0 ] || [[ "$test_summary" != *"FAIL=0"* ]] || [ -z "$test_summary" ]; then
        s4=$((s4 - 10))
        d4_notes+=("全量测试未通过:${test_summary:-rc=$test_rc}(-10)")
    fi
fi

# 4.2 全部 lib/*.sh 模块覆盖度：每个模块至少被 >=2 个测试文件引用 (10 分，每个不足 -3)
low_cov=0
for libf in lib/*.sh; do
    bn="${libf##*/}"
    c="$(grep -rl "$bn" tests/cases/ 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${c:-0}" -lt 2 ]; then
        low_cov=$((low_cov + 1))
        d4_notes+=("低覆盖:${bn}=${c}")
    fi
done
if [ "$low_cov" -gt 0 ]; then
    ded=$((low_cov * 3))
    [ "$ded" -gt 10 ] && ded=10
    s4=$((s4 - ded))
fi
[ "$s4" -lt 0 ] && s4=0

# ==============================================================================
# 维度 5: 工程规范与交付一致性 (20 分)
# ==============================================================================
s5=20
d5_notes=()

# 5.1 版本号格式规范 (5 分)
ver="$(sed -n 's/.*XMG_VERSION:-\([0-9][0-9.]*\).*/\1/p' xmg | head -n 1)"
if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    s5=$((s5 - 5))
    d5_notes+=("版本号异常(-5)")
fi

# 5.2 静态门禁固化在 test_framework_selfcheck.sh (10 分)
gate_file="tests/cases/test_framework_selfcheck.sh"
for kw in "sed -i" "echo -e" "source lib/" "字符串管道" "超时"; do
    if ! grep -q "$kw" "$gate_file" 2>/dev/null; then
        s5=$((s5 - 2))
        d5_notes+=("缺少门禁:${kw}(-2)")
    fi
done

# 5.3 自动化评分器就绪 (5 分)
[ -f tests/score.sh ] || { s5=$((s5 - 5)); d5_notes+=("缺少score.sh(-5)"); }
[ "$s5" -lt 0 ] && s5=0

# ==============================================================================
# 汇总输出
# ==============================================================================
total=$((s1 + s2 + s3 + s4 + s5))

printf '============================================================\n'
printf ' XMG 工程质量评分报告 (版本: v%s)\n' "${ver:-unknown}"
printf '============================================================\n'
printf ' 1. 语法与静态安全门禁   : %2d / 20  %s\n' "$s1" "${d1_notes[*]:-OK}"
printf ' 2. 低配零Fork性能规范   : %2d / 20  %s\n' "$s2" "${d2_notes[*]:-OK}"
printf ' 3. 跨平台与边界健壮性   : %2d / 20  %s\n' "$s3" "${d3_notes[*]:-OK}"
printf ' 4. 单元测试与核心覆盖度 : %2d / 20  %s (%s)\n' "$s4" "${d4_notes[*]:-OK}" "$test_summary"
printf ' 5. 工程规范与交付一致性 : %2d / 20  %s\n' "$s5" "${d5_notes[*]:-OK}"
printf -- '------------------------------------------------------------\n'
printf ' 综合总分                : %3d / 100\n' "$total"
printf '============================================================\n'

[ "$total" -eq 100 ]
