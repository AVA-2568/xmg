# XMG 全模块深度重构与安全加固实现计划 (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 全量重构与优化 XMG 20 个模块及安装/生命周期/测试套件，彻底根除跨模块状态撕裂、SSH 锁死漏洞、极低内存 OOM 隐患与权限安全缺陷，补齐 CLI 全指令闭环与自动化测试矩阵。

**Architecture:** 
- 以 `state.sh` 为单一真相源（SSOT），实现 `state.env` + `config.json` 双文件两阶段原子联合提交与失败联动回滚；
- 收编 WARP 出站至统一渲染管线 `render.sh`，纠正 `"network": "xhttp"` 协议规范；
- 补齐 `xmg` 全子命令非交互门面，强化目录权限（0700/0600）与安全边界，适配现代 Linux 发行版与极小内存（<=256MB）环境；
- 扩充测试套件覆盖率至 100% 模块全覆盖。

**Tech Stack:** Pure Bash 4.4+, Linux sysctl, UFW/nftables, OpenSSH sshd_config.d / systemd socket, Xray-core VLESS/XHTTP/SOCKS5/WireGuard.

## Global Constraints
- 严格遵循纯 Bash 零外部重依赖（零 jq、零 python）；
- 极低规格（<=256MB）下严禁在热路径执行 `apt-get update` 或 `git clone`；
- 不保留向后兼容：过时 fallback 与废弃映射直接删除；
- 遵循单一职责与清晰架构分层，底层库禁止反向依赖上层业务模块；
- 敏感配置目录权限强制为 `0700`，配置文件强制为 `0600`。

---

### Task 1: 清单自包含与基础目录权限安全加固

**Files:**
- Modify: `xmg.files`
- Modify: `install.sh`
- Modify: `lib/common.sh`
- Create: `tests/cases/test_manifest_integrity.sh`
- Create: `tests/cases/test_install_unit.sh`

**Interfaces:**
- Consumes: `xmg_mkdirs`, `install_dirs`, `manifest_entry_validate`
- Produces: `xmg.files` 自包含且所有目录权限严格收敛至 0700/0600，`common.sh` 不再逆向加载 `detect.sh`/`doctor.sh`，`xmg_systemctl` 状态查询在 `set -e` 下安全返回。

- [ ] **Step 1: 编写清单自包含与安装单元测试**

```bash
# tests/cases/test_manifest_integrity.sh
SRC="$TESTS_DIR/.."
FILES="$SRC/xmg.files"
t_contains "清单自包含 xmg.files 自身" "$(cat "$FILES")" "xmg.files"
for f in "$SRC"/lib/*.sh; do
    base="lib/$(basename "$f")"
    t_contains "清单包含 $base" "$(cat "$FILES")" "$base"
done
```

```bash
# tests/cases/test_install_unit.sh
SRC="$TESTS_DIR/.."
source "$SRC/install.sh"
t_assert "合法清单项验证通过" manifest_entry_validate "lib/common.sh"
t_assert "拒绝路径穿越条目" ! manifest_entry_validate "../etc/passwd"
t_assert "拒绝根路径条目" ! manifest_entry_validate "/bin/sh"
```

- [ ] **Step 2: 运行测试验证失败**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: FAIL（`清单自包含 xmg.files 自身` 失败）

- [ ] **Step 3: 实施最小改动修复**

1. 在 `xmg.files` 顶部或末尾添加 `xmg.files` 自身；
2. 修改 `install.sh` 中的 `install_dirs`：将 `$XMG_ETC_DIR`、`$XMG_BACKUP_DIR`、`$XMG_XRAY_DIR` 的权限由 `755` 修改为 `700`；
3. 修改 `lib/common.sh`：
   - 彻底删除末尾处自动 source `detect.sh` 与 `doctor.sh` 的逻辑；
   - 将 `xmg_mkdirs` 中 `/opt/xmg/log` 权限设为 `0750`，`error.log` 设为 `0640`，彻底移除 777/666；
   - 修改 `xmg_systemctl`：在 `status|is-active|is-enabled` 分支中使用 `systemctl "$action" "$service" || return $?` 并明确捕获退出码，防止触发 `set -e` 终止。

- [ ] **Step 4: 运行测试验证通过**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: PASS

- [ ] **Step 5: 提交改动**

```bash
git add xmg.files install.sh lib/common.sh tests/cases/test_manifest_integrity.sh tests/cases/test_install_unit.sh
git commit -m "fix(security): enforce manifest self-containment, tighten directories to 0700/0600, and decouple common.sh"
```

---

### Task 2: CLI 门面全闭环与系统采集加固

**Files:**
- Modify: `xmg`
- Modify: `lib/system.sh`
- Create: `tests/cases/test_cli_facade.sh`
- Create: `tests/cases/test_system_metrics.sh`

**Interfaces:**
- Consumes: `xmg_main`, `xmg_usage`, `xmg_read_mem`, `xmg_read_disk_root`
- Produces: `xmg` 支持 `tune`, `firewall`, `ssh`, `xray`, `detect`, `update`, `uninstall`, `system` 子命令；`system.sh` 具备 `LC_ALL=C` 保护与 Cgroup 容器内存计算。

- [ ] **Step 1: 编写 CLI 门面与系统指标测试**

```bash
# tests/cases/test_cli_facade.sh
SRC="$TESTS_DIR/.."
MAIN="$SRC/xmg"
out="$(bash "$MAIN" version)"
t_contains "xmg version 极速输出" "$out" "XMG"
out_help="$(bash "$MAIN" help)"
t_contains "帮助含 tune" "$out_help" "xmg tune"
t_contains "帮助含 firewall" "$out_help" "xmg firewall"
t_contains "帮助含 ssh" "$out_help" "xmg ssh"
t_contains "帮助含 xray" "$out_help" "xmg xray"
```

```bash
# tests/cases/test_system_metrics.sh
SRC="$TESTS_DIR/.."
source "$SRC/lib/system.sh"
# 模拟中文 locale 环境变量
LC_ALL=zh_CN.UTF-8 root_pct="$(xmg_read_disk_root)"
t_assert "中文 Locale 下磁盘用量为纯数字百分比" test -n "$root_pct"
```

- [ ] **Step 2: 运行测试验证失败**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: FAIL（`帮助含 tune` 失败）

- [ ] **Step 3: 实施最小改动修复**

1. 修改 `xmg`：
   - 将 `version` 与 `help` 判断提前至最顶层，直接 echo 退出，不预加载任何非必要模块；
   - 补齐子命令路由：`tune`、`firewall`、`ssh`、`xray`、`detect`、`update`、`uninstall`、`system`；
   - 删除在 `monitor`、`menu` 等分支中的裸 `set +e`，改用子 shell 或局部容错；
   - 统一参数校验错误返回码为 `2`；
   - 完善 `xmg_usage` 帮助输出。
2. 修改 `lib/system.sh`：
   - 在 `xmg_read_disk_root` 中强制使用 `LC_ALL=C df -hP /`；
   - 在 `xmg_read_mem` 中增加 Cgroup 内存探测（若存在 `/sys/fs/cgroup/memory.max` 或 v1 对应文件且数值有效，优先基于 Cgroup 限额计算百分比）。

- [ ] **Step 4: 运行测试验证通过**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: PASS

- [ ] **Step 5: 提交改动**

```bash
git add xmg lib/system.sh tests/cases/test_cli_facade.sh tests/cases/test_system_metrics.sh
git commit -m "feat(cli): complete all subcommand routing, prevent set +e leakage, and harden system metrics"
```

---

### Task 3: 状态引擎与双文件两阶段联合事务

**Files:**
- Modify: `lib/state.sh`
- Modify: `lib/render.sh`
- Create: `tests/cases/test_state_atomic_dual.sh`
- Create: `tests/cases/test_render_extreme.sh`

**Interfaces:**
- Consumes: `xmg_state_commit`, `_xmg_render_config_bash`, `_xmg_json_escape_into`
- Produces: `state.sh` 支持 `state.env` + `config.json` 联合原子提交与失败联动回滚；`render.sh` 遵循 `"network": "xhttp"` 并转义控制字符。

- [ ] **Step 1: 编写联合两阶段提交与极端渲染测试**

```bash
# tests/cases/test_state_atomic_dual.sh
SRC="$TESTS_DIR/.."
source "$SRC/lib/state.sh"
# 模拟验证失败时两份文件均不被污染
# 模拟重载失败时两份文件均完整还原
```

```bash
# tests/cases/test_render_extreme.sh
SRC="$TESTS_DIR/.."
source "$SRC/lib/render.sh"
# 断言 streamSettings 中 protocol/network 为 xhttp
# 断言含有特殊控制字符的输入被安全转义为合法 JSON
```

- [ ] **Step 2: 运行测试验证失败**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: FAIL

- [ ] **Step 3: 实施最小改动修复**

1. 修改 `lib/state.sh`：
   - 状态 Schema 扩充 `WARP_ENABLED`、`WARP_MODE`、`WARP_ENDPOINT`、`WARP_PRIVATE_KEY`、`WARP_PUBLIC_KEY`、`WARP_IPV4`、`WARP_IPV6`、`WARP_RESERVED`；
   - 重构 `xmg_state_commit`：
     - Phase 1: 仅渲染临时配置并执行 `xray run -test`，失败直接返回 3，绝不修改 `state.env`；
     - Phase 2: 同时对 `config.json` 与 `state.env` 创建对齐备份；原子落盘新 `state.env` 并原子替换 `config.json`；若后续服务重启或健康探测失败，触发双回滚（同时还原 `config.json` 与 `state.env`）并返回 4。
2. 修改 `lib/render.sh`：
   - 将 VLESS 入站传输协议统一规范为 `"network": "xhttp"`；
   - 增加 ASCII 控制字符（U+0000 ~ U+001F）的安全转义；
   - 对数字型字段（`port`、`bufferSize`）强制进行非空算术校验保底，杜绝裸逗号语法崩溃；
   - 支持动态渲染 `warp-out` 原生 WireGuard 出站与路由规则。

- [ ] **Step 4: 运行测试验证通过**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: PASS

- [ ] **Step 5: 提交改动**

```bash
git add lib/state.sh lib/render.sh tests/cases/test_state_atomic_dual.sh tests/cases/test_render_extreme.sh
git commit -m "fix(state): implement dual-file atomic commit & rollback and standardize xhttp network field"
```

---

### Task 4: WARP 原生出站收编与 Proxy 协同

**Files:**
- Modify: `lib/warp.sh`
- Modify: `lib/proxy.sh`
- Create: `tests/cases/test_warp_proxy_synergy.sh`

**Interfaces:**
- Consumes: `xmg_warp_enable`, `xmg_warp_disable`, `xmg_proxy_apply`
- Produces: WARP 配置通过 `state.sh` 统一管理，执行 `xmg proxy apply` 不再抹除 WARP，移除 `apt-get install jq`，修复端点 IPv6 方括号。

- [ ] **Step 1: 编写 WARP 与 Proxy 协同状态一致性测试**

```bash
# tests/cases/test_warp_proxy_synergy.sh
SRC="$TESTS_DIR/.."
# 先启用 WARP (global 模式)
# 再执行 proxy apply 变更 VLESS 端口
# 断言 config.json 中依然完整包含 warp-out 出站且排在首位
# 断言 state.env 中 WARP_ENABLED 保持为 1
```

- [ ] **Step 2: 运行测试验证失败**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: FAIL

- [ ] **Step 3: 实施最小改动修复**

1. 修改 `lib/warp.sh`：
   - 彻底删除使用 `jq` 原地改写现网 `config.json` 的代码；
   - 彻底移除 `apt-get install jq` 逻辑；
   - `xmg_warp_enable` 和 `xmg_warp_disable` 改为向 `state.sh` 写入 stage 参数并调用 `xmg_proxy_apply` 统一落盘与生效；
   - 修复端点优选：对于 IPv6 地址在 curl 检测时自动包裹方括号 `http://[$host]:80`；
2. 修改 `lib/proxy.sh`：
   - 修复提前提交草稿的时序漏洞，与 `state.sh` 的联合两阶段事务严格对齐；
   - 替换 OpenSSL 自签证书命令中的进程替换语法，改用原生 `-newkey ec -pkeyopt ec_paramgen_curve:prime256v1`。

- [ ] **Step 4: 运行测试验证通过**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: PASS

- [ ] **Step 5: 提交改动**

```bash
git add lib/warp.sh lib/proxy.sh tests/cases/test_warp_proxy_synergy.sh
git commit -m "fix(warp): eliminate state drift by unifying WARP into state engine and proxy pipeline"
```

---

### Task 5: 防火墙自适应放行与 SSH 防锁死加固

**Files:**
- Modify: `lib/firewall.sh`
- Modify: `lib/ssh.sh`
- Create: `tests/cases/test_firewall.sh`
- Create: `tests/cases/test_ssh.sh`

**Interfaces:**
- Consumes: `xmg_firewall_allow_basic`, `xmg_ssh_change_port`, `xmg_ssh_fail2ban_setup`
- Produces: 防火墙自动感知自定义 SSH 端口并放行；`ssh.sh` 修复未定义函数并适配 Ubuntu `ssh.socket`。

- [ ] **Step 1: 编写防火墙与 SSH 安全加固测试**

```bash
# tests/cases/test_firewall.sh
SRC="$TESTS_DIR/.."
source "$SRC/lib/firewall.sh"
# 模拟自定义 SSH 端口为 2222
# 运行基础放行，断言生成规则中同时包含 22/tcp 和 2222/tcp
```

```bash
# tests/cases/test_ssh.sh
SRC="$TESTS_DIR/.."
source "$SRC/lib/ssh.sh"
# 验证 fail2ban jail 生成时提取真实配置的 SSH 端口，而非写死 22
```

- [ ] **Step 2: 运行测试验证失败**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: FAIL

- [ ] **Step 3: 实施最小改动修复**

1. 修改 `lib/firewall.sh`：
   - 头部补充依赖加载与自声明标签 `# XMG_MENU_LABEL: 防火墙管理`；
   - 动态提取当前活跃与配置的 SSH 端口，在 `xmg_firewall_allow_basic` 中同时放行 22 与真实 SSH 端口；
   - 检查并确保 `/etc/default/ufw` 中 `IPV6=yes`；
   - 支持非交互 CLI 调用：`xmg_firewall_allow_custom_port <port> [proto]`。
2. 修改 `lib/ssh.sh`：
   - 将 fail2ban 生成中的未定义函数 `xmg_ssh_get_port` 替换为现存真实的 `xmg_ssh_effective port`；
   - 适配 Ubuntu 22.10+ / 24.04：检测 `ssh.socket`，若存在则写入 `/etc/systemd/system/ssh.socket.d/listen.conf` 覆盖 `ListenStream`；
   - 禁用密码登录前严密复核 `.ssh` 目录（0700）与 `authorized_keys` 文件权限。

- [ ] **Step 4: 运行测试验证通过**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: PASS

- [ ] **Step 5: 提交改动**

```bash
git add lib/firewall.sh lib/ssh.sh tests/cases/test_firewall.sh tests/cases/test_ssh.sh
git commit -m "fix(security): prevent SSH lockout in firewall, fix fail2ban port bug, and adapt ssh.socket"
```

---

### Task 6: 内核调优极低内存抗 OOM 与健康体检纠偏

**Files:**
- Modify: `lib/tune.sh`
- Modify: `lib/doctor.sh`
- Modify: `lib/detect.sh`
- Create: `tests/cases/test_tune_oom_guard.sh`

**Interfaces:**
- Consumes: `xmg_tune_net_extreme_low`, `xmg_doctor_cli`, `xmg_detect_network`
- Produces: `extreme_low` 下缓冲区收敛至 1MB 且下发 `net.ipv4.tcp_mem`；`doctor.sh` 真实展示 DNS，`detect.sh` 排除 ULA 与虚拟网卡。

- [ ] **Step 1: 编写调优 OOM 防护与体检纠偏测试**

```bash
# tests/cases/test_tune_oom_guard.sh
SRC="$TESTS_DIR/.."
source "$SRC/lib/tune.sh"
# 验证 extreme_low 档位下 buffer 为 1MB 且 tcp_mem 有效设定
# 验证 extreme_low 下 vm.swappiness 为 60
```

- [ ] **Step 2: 运行测试验证失败**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: FAIL

- [ ] **Step 3: 实施最小改动修复**

1. 修改 `lib/tune.sh`：
   - 在 `extreme_low` 档位中将 `buf_max` 收敛为 `1048576` (1MB)，显式配置 `net.ipv4.tcp_mem`；
   - 分档设置 `vm.swappiness`：极小内存且有 Swap 时设为 60（防止 Direct Reclaim 突发 OOM），高配机设为 10；
   - 修复 `xmg_tune_sysctl_apply` 退出码截断防溢出（归一化为 0 或 1）；
   - 在 Btrfs 文件系统创建 Swap 前先执行 `chattr +C` 禁用 COW；
   - 修复 DoT IPv6 `/dev/tcp` 测试。
2. 修改 `lib/detect.sh`：
   - IPv6 探测复用 `cur_dev` 排除 Docker/虚拟网卡，并排除 ULA 前缀正则；
   - 归一化受限容器探测函数语义；
   - 为 RFC 7050 NAT64 探测增设 2 秒超时兜底。
3. 修改 `lib/doctor.sh`：
   - 删除无条件覆写为 `1.1.1.1` 的逻辑，真实展示配置文件中的 DNS；
   - 增设防火墙、SSH 端口、NTP 时钟同步体检项；
   - 完善 Critical 联合判定规则。

- [ ] **Step 4: 运行测试验证通过**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: PASS

- [ ] **Step 5: 提交改动**

```bash
git add lib/tune.sh lib/doctor.sh lib/detect.sh tests/cases/test_tune_oom_guard.sh
git commit -m "fix(tune): harden extreme-low memory TCP buffers, fix doctor DNS overwrite, and exclude ULA IPv6"
```

---

### Task 7: 模块解耦、生命周期安全与全模块自声明

**Files:**
- Modify: `lib/core.sh`
- Modify: `lib/xray.sh`
- Modify: `lib/menu.sh`
- Modify: `lib/update.sh`
- Modify: `lib/uninstall.sh`
- Create: `tests/cases/test_lifecycle_update_rollback.sh`
- Create: `tests/cases/test_uninstall_safety.sh`

**Interfaces:**
- Consumes: `xmg_uninstall_cli`, `xmg_update_run`, `xmg_menu_discover_modules`
- Produces: drop-in 收敛至 `xray.sh`；所有模块统一标签自声明；`update.sh` 支持原子替换与回滚；`uninstall.sh` 保护系统官方 unit 并支持 `--yes`。

- [ ] **Step 1: 编写生命周期安全与回滚测试**

```bash
# tests/cases/test_uninstall_safety.sh
SRC="$TESTS_DIR/.."
source "$SRC/lib/uninstall.sh"
# 模拟系统存在 /lib/systemd/system/xray.service
# 运行卸载清理逻辑，断言该系统原生文件绝不被删除
# 断言危险路径 (XMG_HOME=/) 触发卸载被安全拦截
```

```bash
# tests/cases/test_lifecycle_update_rollback.sh
SRC="$TESTS_DIR/.."
source "$SRC/lib/update.sh"
# 验证更新失败时触发完整自动回滚，恢复所有模块与清单
```

- [ ] **Step 2: 运行测试验证失败**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: FAIL

- [ ] **Step 3: 实施最小改动修复**

1. 修改 `lib/core.sh` 与 `lib/xray.sh`：
   - 将 systemd drop-in 生成与覆盖逻辑统一移回 `lib/xray.sh`；
   - 补齐 `# XMG_MENU_LABEL: Xray 服务管理`；
   - 规范临时解压目录路径。
2. 修改 `lib/menu.sh`：
   - 彻底删除 `xmg_menu_label_for_file` 内的硬编码 `case` 映射；
   - 确保 `lib/*.sh` 所有文件均具备标准 `# XMG_MENU_LABEL: xxx` 自声明。
3. 修改 `lib/update.sh`：
   - 备份范围扩大至 `lib`、`bin`、`templates`、`xmg.files`；
   - 实行原子目录替换，更新失败自动触发回滚；彻底删除 17 模块硬编码 fallback。
4. 修改 `lib/uninstall.sh`：
   - 清理范围严格限制在 XMG 自治目录与 drop-in，坚决禁止删除 `/lib/systemd/.../xray.service`；
   - 将 `xmg-warp.service` 与孤儿进程纳入清理；
   - 增加 `$XMG_HOME` 路径安全断言，支持 `--yes` 非交互选项。

- [ ] **Step 4: 运行测试验证通过**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: PASS

- [ ] **Step 5: 提交改动**

```bash
git add lib/core.sh lib/xray.sh lib/menu.sh lib/update.sh lib/uninstall.sh tests/cases/test_lifecycle_update_rollback.sh tests/cases/test_uninstall_safety.sh
git commit -m "fix(lifecycle): secure uninstall boundaries, enforce atomic updates, and standardize module labels"
```

---

### Task 8: 全量测试集成、端到端回归与交付验收

**Files:**
- Modify: `tests/run.sh`
- Modify: `README.md`
- Modify: `xmg` (若有版本更新)

**Interfaces:**
- Consumes: 全量测试套件
- Produces: 自动化测试覆盖全部 20 个核心模块，全量用例 PASS，测试点 700+，文档与实现 100% 对齐。

- [ ] **Step 1: 集成所有新增测试至 `tests/run.sh`**

将新增的 8 个测试用例加入 `tests/run.sh` 的执行序列中：
- `test_manifest_integrity.sh`
- `test_install_unit.sh`
- `test_cli_facade.sh`
- `test_system_metrics.sh`
- `test_state_atomic_dual.sh`
- `test_render_extreme.sh`
- `test_warp_proxy_synergy.sh`
- `test_firewall.sh`
- `test_ssh.sh`
- `test_tune_oom_guard.sh`
- `test_lifecycle_update_rollback.sh`
- `test_uninstall_safety.sh`

- [ ] **Step 2: 运行全局全量回归测试**

运行: `& "I:\Git\bin\bash.exe" tests/run.sh`
预期: PASS >= 700, FAIL = 0

- [ ] **Step 3: 运行语法与静态校验**

运行: `& "I:\Git\bin\bash.exe" -c 'for f in xmg install.sh lib/*.sh tests/*.sh tests/cases/*.sh; do bash -n "$f" || exit 1; done'`
预期: 零语法错误

- [ ] **Step 4: 同步更新 README.md 与帮助文档**

确保 README.md 中新增的 CLI 指令与实现完全一致。

- [ ] **Step 5: 提交集成验收**

```bash
git add tests/run.sh README.md
git commit -m "chore(test): integrate full module test suites, verify 700+ assertions, and update docs"
```
