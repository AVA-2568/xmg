#!/usr/bin/env bash
# 清单自包含与完整性测试
# shellcheck shell=bash

SRC="$TESTS_DIR/.."
FILES="$SRC/xmg.files"

# 1. 测试 xmg.files 必须自包含 xmg.files 自身
t_contains "清单自包含 xmg.files 自身" "$(cat "$FILES")" "xmg.files"

# 2. 测试 lib/*.sh 下除测试外的所有模块均包含在 xmg.files 中
for f in "$SRC"/lib/*.sh; do
    [ -f "$f" ] || continue
    base="lib/$(basename "$f")"
    t_contains "清单包含 $base" "$(cat "$FILES")" "$base"
done

# 3. 测试清单中绝无废弃模块（caddy, site, third-party）
t_not_contains "清单绝无废弃模块 caddy" "$(cat "$FILES")" "caddy"
t_not_contains "清单绝无废弃模块 site" "$(cat "$FILES")" "site"
t_not_contains "清单绝无废弃模块 third-party" "$(cat "$FILES")" "third-party"
