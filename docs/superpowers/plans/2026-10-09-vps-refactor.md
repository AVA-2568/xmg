# xmg 低配 VPS 极简架构重构实施计划 (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 面向 0.5C / 215MB RAM、NAT 映射及纯 IPv6/双栈环境，重构 xmg 为极简、高韧性、零臃肿的代理网关与核心系统管理工具。

**Architecture:** 采用 4 层单向解耦架构：Layer 1 环境与容器自省（`detect.sh`） -> Layer 2 状态批处理与两阶段原子事务（`state.sh`） -> Layer 3 纯函数渲染与官方规范（`render.sh`） -> Layer 4 核心服务压制与轻量系统运维（`core.sh` / `tune.sh` / `system.sh`）。

**Tech Stack:** Bash 4.4+，Linux 内核网络栈（sysctl, iptables/ip6tables），systemd drop-in，Xray core（最新官方规范）。

## Global Constraints

- 目标系统仅限 Debian 11/12+、Ubuntu 20.04+。
- 架构覆盖 x86_64、aarch64、armv7l、mips（KVM / OpenVZ / LXC / NAT）。
- 绝无外部依赖：零 jq、零 python、零外部动态库，纯 Bash 内建及 Linux 基础工具链。
- 不保留向后兼容：过时和半成品代码果断剔除。
- 保证测试绿灯：每个任务提交前必须确保 `bash tests/run.sh` 100% 通过。
- 远程 VPS 验证：所有涉真实内核修改与外部网络连通项，均提供标准自检诊断输出。

---

### Task 1: 瘦身与废弃模块剥离 (Eliminate Bloat & Dead Modules)

**Files:**
- Delete: `lib/caddy.sh`, `lib/site.sh`, `lib/third-party.sh`
- Modify: `xmg.files`, `lib/menu.sh`, `lib/uninstall.sh`, `install.sh`
- Test: `tests/cases/test_entrypoint.sh`

**Interfaces:**
- Consumes: `xmg.files` 清单文件。
- Produces: 剔除 Caddy、Site、Third-party 后的干净清单与菜单定义；`uninstall.sh` 不再侵入宿主机全局 `/etc/caddy` 与 APT 源。

- [ ] **Step 1: 编写废弃模块剔除的断言测试**

在 `tests/cases/test_entrypoint.sh` 中增加测试，确保主菜单和清单中不再包含 `caddy`、`site`、`third-party` 对应项：
```bash
test_no_bloat_modules_in_manifest() {
    assert_false "grep -q 'caddy.sh' xmg.files" "caddy.sh 不应出现在 xmg.files"
    assert_false "grep -q 'site.sh' xmg.files" "site.sh 不应出现在 xmg.files"
    assert_false "grep -q 'third-party.sh' xmg.files" "third-party.sh 不应出现在 xmg.files"
}
```

- [ ] **Step 2: 运行测试以验证失败**

运行：`bash tests/run.sh`
预期：FAIL（因为目前 `xmg.files` 中包含上述模块）。

- [ ] **Step 3: 删除废弃文件并清理引用**

1. 删除文件：
   - `rm -f lib/caddy.sh lib/site.sh lib/third-party.sh`
2. 更新 `xmg.files`：删除包含 `caddy.sh`、`site.sh`、`third-party.sh` 的行。
3. 更新 `lib/menu.sh`：移除对应菜单展示分支。
4. 更新 `lib/uninstall.sh`：移除清理 `/etc/caddy` 和 caddy apt 源的逻辑。

- [ ] **Step 4: 运行回归测试**

运行：`bash tests/run.sh`
预期：PASS（所有 entrypoint 及关联测试通过）。

---

### Task 2: 环境能力与容器自省层 (`lib/detect.sh`)

**Files:**
- Create: `lib/detect.sh`
- Test: `tests/cases/test_detect.sh`
- Modify: `xmg.files`, `lib/common.sh`

**Interfaces:**
- Consumes: `/proc/sys`、`/proc/meminfo`、`/sys/devices/virtual/dmi`、`ip` 命令输出。
- Produces:
  - `xmg_detect_virt`: 输出 `kvm` | `openvz` | `lxc` | `docker` | `unknown`
  - `xmg_detect_mem_profile`: 输出 `extreme_low` (<=256MB) | `low` (<=512MB) | `mid` (<=2048MB) | `high`
  - `xmg_detect_network`: 导出 `XMG_NET_IPV4`, `XMG_NET_IPV6`, `XMG_NET_NAT`, `XMG_NET_NAT64`
  - `xmg_detect_container_restricted`: 返回 0（正常）或 1（受限容器/sysctl只读）

- [ ] **Step 1: 编写自省功能单元测试**

在 `tests/cases/test_detect.sh` 编写 mock 测试：
```bash
test_detect_mem_profile_215m() {
    export MOCK_MEM_TOTAL_KB=220160 # 215MB
    local profile
    profile="$(xmg_detect_mem_profile)"
    assert_eq "$profile" "extreme_low" "215MB 应被判定为 extreme_low 档位"
}
```

- [ ] **Step 2: 运行测试以验证失败**

运行：`bash tests/run.sh`
预期：FAIL（未定义 `xmg_detect_*`）。

- [ ] **Step 3: 实现 `lib/detect.sh`**

编写探测函数，包含对 `/proc/user_beancounters`（OpenVZ）、`systemd-detect-virt` / `/proc/1/environ`（LXC/Docker）、`/proc/meminfo` 分档及 IPv4/IPv6 双栈网络探测。

- [ ] **Step 4: 运行测试并验证通过**

运行：`bash tests/run.sh`
预期：PASS。

---

### Task 3: 状态批处理与两阶段原子提交 (`lib/state.sh`)

**Files:**
- Modify: `lib/state.sh`
- Test: `tests/cases/test_state.sh`, `tests/cases/test_atomic.sh`

**Interfaces:**
- Consumes: `state.env`，各配置键值对。
- Produces:
  - `xmg_state_stage <key> <val>`: 仅在内存暂存变更。
  - `xmg_state_commit`: 批量落盘 `state.env`，生成 `config.json.staged`，内核测试通过后原子替换，重载失败双回滚。

- [ ] **Step 1: 编写批处理与原子提交的测试**

在 `tests/cases/test_state.sh` 中增加：
```bash
test_state_stage_and_commit_batch() {
    xmg_state_stage "TEST_KEY1" "val1"
    xmg_state_stage "TEST_KEY2" "val2"
    xmg_state_commit_draft # 批量落盘
    assert_eq "$(xmg_state_get TEST_KEY1)" "val1"
    assert_eq "$(xmg_state_get TEST_KEY2)" "val2"
}
```

- [ ] **Step 2: 运行测试以验证失败**

运行：`bash tests/run.sh`
预期：FAIL（未实现 `xmg_state_stage` 批处理）。

- [ ] **Step 3: 重构 `lib/state.sh`**

引入暂存缓冲数组/临时字典，修改 `xmg_proxy_apply` 为先 `stage` 后统一 `commit`，彻底消灭循环写入带来的 N+1 文件读写开销。

- [ ] **Step 4: 运行回归测试**

运行：`bash tests/run.sh`
预期：PASS（原有 266 项测试及新增原子测试全部绿灯）。

---

### Task 4: Xray 协议纯函数渲染加固与 DoH 闭环 (`lib/render.sh`)

**Files:**
- Modify: `lib/render.sh`
- Test: `tests/cases/test_render.sh`

**Interfaces:**
- Consumes: `PROXY_VLESS_*`, `PROXY_SOCKS_*`, 以及自省层的网络状态（IPv4/IPv6）。
- Produces:
  - `tlsSettings` 包含 `"rejectUnknownSni": true`
  - `outbounds[0]`（freedom）包含 `"settings": { "domainStrategy": "UseIP" }`（纯 IPv6 下为 `UseIPv6`）
  - `dns` 模块在单栈 IPv6 下动态渲染 IPv6 DoH 地址
  - `policy` 包含 `"connIdle": 60`

- [ ] **Step 1: 编写配置渲染规范的失败测试**

在 `tests/cases/test_render.sh` 中增加断言：
```bash
test_render_vless_reject_unknown_sni() {
    local json
    json="$(xmg_render_config 0 1)"
    assert_true "echo '$json' | grep -q '\"rejectUnknownSni\": true'" "VLESS TLS 必须开启 rejectUnknownSni"
}

test_render_freedom_domain_strategy() {
    local json
    json="$(xmg_render_config 1 1)"
    assert_true "echo '$json' | grep -q '\"domainStrategy\": \"UseIP\"'" "Freedom 出站必须闭环指定 domainStrategy"
}

test_render_policy_conn_idle() {
    local json
    json="$(xmg_render_config 1 1)"
    assert_true "echo '$json' | grep -q '\"connIdle\": 60'" "Policy 必须配置 connIdle 回收连接"
}
```

- [ ] **Step 2: 运行测试以验证失败**

运行：`bash tests/run.sh`
预期：FAIL（现有 `render.sh` 缺少这三个关键字段）。

- [ ] **Step 3: 修订 `lib/render.sh`**

在 `xmg_render_vless`、`xmg_render_outbounds`、`xmg_render_dns`、`xmg_render_policy` 中依规范注入字段并保证零 fork。

- [ ] **Step 4: 运行测试并验证通过**

运行：`bash tests/run.sh`
预期：PASS。

---

### Task 5: 核心生命周期与 215M Go 内存压制 (`lib/core.sh` / `lib/xray.sh`)

**Files:**
- Modify: `lib/core.sh`, `lib/xray.sh`
- Test: `tests/cases/test_core.sh`, `tests/cases/test_xray_split.sh`

**Interfaces:**
- Consumes: systemd unit 配置，官方 Xray 安装脚本。
- Produces:
  - 在 drop-in `20-xmg.conf` 中注入 `GOMEMLIMIT=100MiB`、`GODEBUG=madvdontneed=1`、`GOMAXPROCS=1`
  - 安装解压过程若 `/tmp` 空间不足自动切到物理路径，杜绝 tmpfs OOM
  - `xmg_core_memcheck` 在 215MB 下不报错、不强推 swap，而是输出极低内存运行提示
  - `lib/xray.sh` 保留所有函数作为门面重定向至 `lib/core.sh`，保证 100% 测试兼容

- [ ] **Step 1: 编写 drop-in 环境变量注入测试**

在 `tests/cases/test_core.sh` 中增加：
```bash
test_xray_systemd_dropin_memory_limits() {
    # 验证生成的 dropin 内容包含 GOMEMLIMIT
    local conf
    conf="$(xmg_core_generate_dropin_content)"
    assert_true "echo '$conf' | grep -q 'GOMEMLIMIT=100MiB'" "dropin 必须包含 GOMEMLIMIT 环境变量"
    assert_true "echo '$conf' | grep -q 'GOMAXPROCS=1'" "dropin 必须包含 GOMAXPROCS=1"
}
```

- [ ] **Step 2: 运行测试以验证失败**

运行：`bash tests/run.sh`
预期：FAIL。

- [ ] **Step 3: 实现 `lib/core.sh` 的内存压制与解耦**

更新 drop-in 生成逻辑，优化 `xmg_core_memcheck`，在 `lib/xray.sh` 中保留兼容门面。

- [ ] **Step 4: 运行测试并验证通过**

运行：`bash tests/run.sh`
预期：PASS。

---

### Task 6: 系统调优 Extreme-Low 215M 专属适配 (`lib/tune.sh`)

**Files:**
- Modify: `lib/tune.sh`
- Test: `tests/cases/test_memcheck.sh`, `tests/cases/test_tune_dns.sh`

**Interfaces:**
- Consumes: `xmg_detect_mem_profile`，`xmg_detect_container_restricted`。
- Produces:
  - `extreme_low` 档位内核网络参数（`conntrack_max=8192`，`tcp_rmem/wmem=4MB`，`tw_buckets=4096`）
  - 容器内只读 sysctl 失败熔断（不报致命错误，友好警告）
  - Swap 创建前预检根分区可用空间，不足自动缩减或提示跳过，杜绝磁盘打满

- [ ] **Step 1: 编写 extreme_low 调优参数断言测试**

在 `tests/cases/test_memcheck.sh` 中增加：
```bash
test_tune_extreme_low_profile() {
    # 模拟 215MB
    local profile="extreme_low"
    local net_conf
    net_conf="$(xmg_tune_generate_net_sysctl "$profile")"
    assert_true "echo '$net_conf' | grep -q 'net.netfilter.nf_conntrack_max = 8192'"
    assert_true "echo '$net_conf' | grep -q 'net.core.rmem_max = 4194304'"
}
```

- [ ] **Step 2: 运行测试以验证失败**

运行：`bash tests/run.sh`
预期：FAIL。

- [ ] **Step 3: 更新 `lib/tune.sh`**

添加 `extreme_low` 档位分支，对容器环境增加错误容错机制。

- [ ] **Step 4: 运行测试并验证通过**

运行：`bash tests/run.sh`
预期：PASS。

---

### Task 7: 远程 VPS 一键健康诊断工具 (`xmg doctor`)

**Files:**
- Create: `lib/doctor.sh`
- Modify: `xmg`, `xmg.files`, `lib/menu.sh`
- Test: `tests/cases/test_doctor.sh`

**Interfaces:**
- Consumes: 全局环境、运行中的 Xray 状态、网络连通性、内存与 Swap。
- Produces: 格式化的终端诊断卡片，返回码 `0`（全绿）或 `1`（存在异常项）。

- [ ] **Step 1: 编写 doctor 测试**

在 `tests/cases/test_doctor.sh` 中测试 `xmg doctor` 命令入口与格式输出：
```bash
test_xmg_doctor_output() {
    local output
    output="$(bash xmg doctor --dry-run 2>&1)"
    assert_true "echo '$output' | grep -q 'xmg 系统与网络健康自检报告'"
}
```

- [ ] **Step 2: 运行测试以验证失败**

运行：`bash tests/run.sh`
预期：FAIL。

- [ ] **Step 3: 实现 `lib/doctor.sh` 与 CLI 挂载**

编写自检模块，注册到主 CLI `xmg`。

- [ ] **Step 4: 运行测试并验证通过**

运行：`bash tests/run.sh`
预期：PASS。

---

### Task 8: 全量回归与远程验收清单归档 (Full Regression & Checklist)

**Files:**
- Modify: `docs/VPS-验收清单.md`, `README.md`
- Test: 全量 `tests/run.sh`

- [ ] **Step 1: 运行全量测试套件**

运行：`bash tests/run.sh`
预期：所有测试 100% 通过（FAIL=0）。

- [ ] **Step 2: 更新 `docs/VPS-验收清单.md`**

补充 `xmg doctor` 诊断核验、215M 内存极限观测指令（`cat /proc/meminfo`、`systemctl status xray` RSS 检查）、NAT 端口映射排查流程。

- [ ] **Step 3: 更新 `README.md` 架构与命令说明**

删除废弃的 Caddy 和 Site 描述，强化极低资源与双栈 NAT 优势。
