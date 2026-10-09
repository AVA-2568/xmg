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

# 回归：命令里带管道时，计数必须发生在当前 shell（曾因管道进子shell 而丢计数）。
# 期望写法是把整条命令写成字符串，由 t_assert 内部 eval 展开。
_qf0="$TESTS_FAIL"
_qp0="$TESTS_PASS"
t_assert "管道成功应通过" "printf hello | grep -q hello"
t_assert "管道左段失败应被计数" "printf hello | grep -q NOTEXIST"
t_assert "管道失败被正确计数" test "$TESTS_FAIL" -eq "$((_qf0 + 1))"
t_assert "管道成功计数正确" test "$TESTS_PASS" -eq "$((_qp0 + 2))"
# 管道右段失败同样算失败（语义同 pipefail）
t_assert "管道右段失败应被计数" "echo hi | grep -q NOTEXIST"
t_assert "管道右段失败被正确计数" test "$TESTS_FAIL" -eq "$((_qf0 + 2))"
TESTS_FAIL="$_qf0"

# 回归：t_assert 被放进子shell（管道/命令替换）时必须显式报错，不能静默通过。
# 计数器无法回传父进程是 bash 固有行为，框架能做的只有把误用暴露成显式错误。
# 因此这里断言的是"错误信息确实打出来了"，而不是去断言子shell 里的计数器。
_err="$(t_assert "子shell误用" false 2>&1 >/dev/null)"
t_contains "子shell误用应显式报错" "$_err" "子 shell 中被调用"
t_contains "子shell误用应给出正确写法" "$_err" 't_assert "描述" "cmd | cat"'
# 子shell 内的计数改动不得污染父进程。
# 快照必须取在上面两条断言之后——它们自身也会正常计入计数器。
_mp0="$TESTS_PASS"
_mf0="$TESTS_FAIL"
t_assert "子shell误用不污染PASS" test "$TESTS_PASS" -eq "$_mp0"
t_assert "子shell误用不污染FAIL" test "$TESTS_FAIL" -eq "$_mf0"

# 回归：t_contains 的失败输出用纯 bash 截断，长内容不应拖垮输出。
_l500="$(printf '%0.sA' $(seq 1 500))"
t_assert "长内容截断不报错" test "${#_l500}" -eq 500
t_assert "bash 截取前400字符" test "${_l500:0:400}" = "$(printf '%0.sA' $(seq 1 400))"

# 回归：多参数里的 shell 元字符不得被二次解析。
# 起因：t_assert 曾用 $* 拼接来判断是否走 eval，$* 会丢掉参数内部的引号，
# 于是 `grep -qE "listen|inbounds" <文件>` 被拼成 `grep -qE listen|inbounds <文件>`，
# | 误判为管道 → eval 把正则拆成两个命令 → 明明匹配成功却判FAIL（假失败），
# 反向则 `false "|| true"` 变成真管道而假通过。
#
# 【关键】这些断言必须绕开本进程计数器，改在子 bash 里断言 t_summary 的可观测输出。
# 原因：若在方向断言之后用「计数增量核对」来验账，两条方向相反的错误会恰好抵消——
#   A(含| 的正则，旧实现假失败) FAIL+1
#   B(含 || 的用例，旧实现假通过) PASS+1
# 核对 "PASS 增量==1 且 FAIL 增量==1" 看到的是净变化，恒等于期望值 → 全部蒙混过关，
# 回归检测力为零（实测装回旧 lib.sh 仍是 PASS=16 FAIL=0、退出码 0）。
# 对称性越强，检测力越为零。子 bash 每次只跑一条断言，不存在抵消。
_MC_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
t_assert "自检用例能定位 lib.sh" test -f "$_MC_LIB"

# 反向：参数里的 || 不得被当成真的"或"，false 必须判FAIL（旧实现假通过）
_mcA="$(bash -c 'source "$1"; t_assert "探针" false "|| true" 2>&1; t_summary' _ "$_MC_LIB" 2>&1)"
t_contains "多参含||必须判FAIL" "$_mcA" "PASS=0 FAIL=1"

# 正向：正则交替含 | ，真实 rc=0，必须判PASS（旧实现假失败）
_mcB="$(bash -c 'source "$1"; t_assert "探针" grep -qE "listen|inbounds" <(printf "listen: 0.0.0.0\ninbounds: []\n") 2>&1; t_summary' _ "$_MC_LIB" 2>&1)"
t_contains "多参正则含|必须判PASS" "$_mcB" "PASS=1 FAIL=0"

# 回归：单参数为空字符串时必须判FAIL（无可执行命令，语义同 $# -eq 0）。
# $# 分派后 eval "" 得到 PIPESTATUS=(0)、rc=0，会把"没给命令"静默判成通过。
_mcC="$(bash -c 'source "$1"; t_assert "探针" "" 2>&1; t_summary' _ "$_MC_LIB" 2>&1)"
t_contains "单参空串必须判FAIL" "$_mcC" "PASS=0 FAIL=1"
