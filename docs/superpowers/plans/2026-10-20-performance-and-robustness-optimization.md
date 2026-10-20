# XMG 极致性能与系统健壮性深度优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消灭热路径中所有外部子进程开销，统一渲染器与模板出站规范，优化 WARP 测速与 IPv6 直连链接，并增强健康诊断卡片的可观测性。

**Architecture:** 基于纯 Bash 4.4+ 原生参数展开消除 `tr/cut/sed` 进程派生；在 `render.sh` 中统一保留 `blocked` 黑洞出站并修补 jq 内置骨架回退；规范化 IPv6 节点直连 URL；在 `doctor.sh` 引入证书剩余天数与 DoH 延迟探测（带 Mock 测试桩保护）。

**Tech Stack:** Bash 4.4+, Xray-core, Linux /proc 内核接口, Systemd, UFW, OpenSSL

**Spec:** `docs/superpowers/specs/2026-10-20-performance-and-robustness-optimization-design.md`

## Global Constraints

- 硬件与环境：0.5C / 215MB RAM 极小内存 VPS、NAT 机器及纯 IPv6 容器
- 零外部新依赖：运行态严禁引入 `jq` 或 `python` 作为强依赖，全部纯 Bash 4.4+ 实现
- 质量底线：全量运行 `tests/run.sh`，现有 884 个测试用例必须 100% 保持通过，新增优化点补齐单测，断言总数只增不减
- 零向后兼容包袱：过时或死分支代码直接清理，不留兼容层

## Review Focus

- 纯 Bash 参数展开处理空值或格式畸形时的边界容错（如 reserved 包含制表符或空字符串）
- 纯 IPv6 直连节点链接中，若地址已有方括号时不得重复包裹 `[[...]]`
- `doctor.sh` 在离线测试模式（`XMG_TEST_MODE=1`）下严禁发起真实外部网络探测或卡顿超时
- 追加 `blocked` 出站后，`direct` 或 `warp-out` 仍必须稳居第一出站以保证默认路由策略不变
- 模板文件缺失且安装了 jq 时，配置渲染必须能够经由内置骨架通过 jq 正确完成注入

---

### Task 1: 纯 Bash 原生参数展开与外部子进程消除

**Files:**
- Modify: `lib/detect.sh:390-405`
- Modify: `lib/warp.sh:140-180, 220-235, 1020-1060`
- Modify: `lib/common.sh:185-245`
- Modify: `lib/render.sh:210-220, 575-585`
- Test: `tests/cases/test_detect.sh`
- Test: `tests/cases/test_warp.sh`

**Interfaces:**
- `_xmg_warp_clean_ipv4`: 纯 Bash 消除空白，入参 IP 字符串，输出纯净 IPv4
- `_xmg_warp_clean_ipv6`: 纯 Bash 消除空白，入参 IP 字符串，输出纯净 IPv6
- `_xmg_warp_get_account_vars`: 提取 account.json 保留字段，输出格式化 `[r0, r1, r2]`
- `xmg_detect_container_restricted`: 改用 `< "$mounts_file"` 纯内建输入重定向

- [ ] **Step 1: 编写/更新针对子进程消除与边界处理的测试断言**
  在 `tests/cases/test_warp.sh` 中新增测试用例：
  ```bash
  # 验证各种畸形空白与逗号格式下的保留字段纯 Bash 规整能力
  ```
- [ ] **Step 2: 改造 `lib/detect.sh` 移除 mounts 读取时的 `cat` 与子 shell**
  将 `done <<< "$(cat "$mounts_file" 2>/dev/null || true)"` 改为 `done < "$mounts_file" 2>/dev/null`。
- [ ] **Step 3: 改造 `lib/warp.sh` 中的字符串裁剪与凭据解析**
  消除 `echo "$val" | tr -d '[:space:]'`，改用 `${val//[[:space:]]/}`；
  消除 `_xmg_warp_get_account_vars` 中通过 `echo | tr` 提取保留字段的逻辑，改用纯 Bash 参数替换与 read。
- [ ] **Step 4: 改造 `lib/render.sh` 中 `warp_reserved` 数组格式化**
  消除 `echo "$warp_reserved" | tr ' ' ','`，改用纯 Bash 原生替换。
- [ ] **Step 5: 运行相关测试集验证**
  运行: `I:/Git/bin/bash.exe tests/run.sh`
  期望: 包含 `test_detect.sh`, `test_warp.sh`, `test_render.sh` 在内的全部测试 PASS
- [ ] **Step 6: Commit**
  ```bash
  git add lib/detect.sh lib/warp.sh lib/common.sh lib/render.sh tests/cases/test_warp.sh
  git commit -m "perf(core): eliminate fork and external subshell pipelines across core modules"
  ```

---

### Task 2: 渲染引擎与模板一致性加固

**Files:**
- Modify: `lib/render.sh:100-140, 395-430, 660-770, 865-885`
- Modify: `templates/config.template.json`
- Test: `tests/cases/test_render.sh`

**Interfaces:**
- `_XMG_DEFAULT_CONFIG_TEMPLATE`: 内置骨架补充 `blocked` (blackhole) 出站
- `_xmg_render_config_bash`: 纯 Bash 引擎渲染时始终追加 `tag: blocked`
- `xmg_render_config`: jq 过滤器中保留 `tag: blocked`，并在模板文件缺失时由内置骨架通过 jq 生成配置

- [ ] **Step 1: 在 `tests/cases/test_render.sh` 编写出站对齐与模板回退测试**
  断言渲染出的 JSON 中严格包含 `"tag": "blocked"`；
  断言在未提供模板文件且安装 jq 的环境下，配置能被 jq 正确渲染。
- [ ] **Step 2: 在 `lib/render.sh` 内置模板与纯 Bash 渲染器中追加 `tag: blocked`**
  ```json
  {
    "protocol": "blackhole",
    "tag": "blocked",
    "settings": {}
  }
  ```
- [ ] **Step 3: 在 `lib/render.sh` jq 过滤器中同步保留 `blocked` 出站**
  确保无论 `warp_on` 为 0/1、`warp_mode` 为 global/routing，`outbounds` 末尾均统一追加 `blocked` 出站。
- [ ] **Step 4: 修复 `lib/render.sh` 中的死分支逻辑**
  修复 `elif [ "$has_jq" -eq 1 ]` 分支，当外部模板文件不存在时直接将 `_XMG_DEFAULT_CONFIG_TEMPLATE` 送入 jq 渲染。
- [ ] **Step 5: 运行 `test_render.sh` 验证**
  运行: `I:/Git/bin/bash.exe -c "source tests/lib.sh; bash tests/cases/test_render.sh; t_summary"`
  期望: 全部 PASS
- [ ] **Step 6: Commit**
  ```bash
  git add lib/render.sh templates/config.template.json tests/cases/test_render.sh
  git commit -m "fix(render): align blackhole outbound and fix fallback template branch for jq engine"
  ```

---

### Task 3: WARP 探测提速与纯 IPv6 直连链接规范化

**Files:**
- Modify: `lib/warp.sh:350-410`
- Modify: `lib/proxy.sh:280-312`
- Test: `tests/cases/test_warp.sh`
- Test: `tests/cases/test_proxy_cli.sh`

**Interfaces:**
- `xmg_warp_optimize_endpoint`: 探测超时收敛至 1 秒，耗时压缩至 3~5 秒内
- `xmg_proxy_vless_link`: 自动识别 IPv6 字面量并包裹 `[IPv6]` 标准方括号

- [ ] **Step 1: 在 `tests/cases/test_proxy_cli.sh` 中添加 IPv6 直连链接格式断言**
  断言当 `PROXY_VLESS_DOMAIN="2001:db8::1"` 时，生成的直连节点 URL 主机部分为 `[2001:db8::1]:<port>`，且不破坏普通域名。
- [ ] **Step 2: 改造 `lib/proxy.sh` 中的 `xmg_proxy_vless_link`**
  对 `domain` 进行检查：若包含 `:` 且首尾不为 `[` 与 `]`，自动包裹方括号。
- [ ] **Step 3: 优化 `lib/warp.sh` 中的 `xmg_warp_optimize_endpoint` 超时阈值**
  将 ping 发包数设为 `-c 1 -W 1`，curl 连接超时设为 `--connect-timeout 1`。
- [ ] **Step 4: 运行 `test_warp.sh` 与 `test_proxy_cli.sh` 验证**
  运行: `I:/Git/bin/bash.exe tests/run.sh`
  期望: PASS
- [ ] **Step 5: Commit**
  ```bash
  git add lib/warp.sh lib/proxy.sh tests/cases/test_proxy_cli.sh
  git commit -m "feat(proxy): normalize ipv6 direct links and optimize warp endpoint latency probing"
  ```

---

### Task 4: 健康诊断卡片可观测性升级 (`doctor.sh`)

**Files:**
- Modify: `lib/doctor.sh:420-560, 600-680`
- Test: `tests/cases/test_doctor.sh`

**Interfaces:**
- `_xmg_doctor_get_cert_status`: 检查证书文件并输出剩余天数（支持 `MOCK_CERT_STATUS`）
- `_xmg_doctor_get_doh_latency`: 探测生效 DoH 的网络往返时延（支持 `MOCK_DOH_LATENCY` 与测试模式短路）

- [ ] **Step 1: 在 `tests/cases/test_doctor.sh` 增加证书与 DoH 探测的单元测试用例**
  使用 `MOCK_CERT_STATUS` 和 `MOCK_DOH_LATENCY` 验证输出格式与颜色判定。
- [ ] **Step 2: 实现 `_xmg_doctor_get_cert_status`**
  定位证书路径，使用 `openssl x509 -enddate -noout` 提取时间戳并计算剩余天数。
- [ ] **Step 3: 实现 `_xmg_doctor_get_doh_latency`**
  在生产环境下通过 curl 获取 `time_connect`，测试模式或离线模式下安全回退。
- [ ] **Step 4: 将两项指标集成至 `xmg_doctor_run` 诊断终端卡片中**
  在 [Xray 运行状态] 卡片中输出证书状态，在 [DNS 解析] 卡片中输出 DoH 解析延迟评级。
- [ ] **Step 5: 运行 `test_doctor.sh` 验证**
  运行: `I:/Git/bin/bash.exe -c "source tests/lib.sh; bash tests/cases/test_doctor.sh; t_summary"`
  期望: 全部 PASS
- [ ] **Step 6: Commit**
  ```bash
  git add lib/doctor.sh tests/cases/test_doctor.sh
  git commit -m "feat(doctor): add certificate validity inspection and doh latency grading"
  ```

---

### Task 5: 全量回归与边界测试验证

**Files:**
- Test: `tests/run.sh`
- Test: `tests/cases/*.sh`

- [ ] **Step 1: 运行测试套件全量回归**
  运行: `I:/Git/bin/bash.exe tests/run.sh`
  期望: PASS >= 890, FAIL = 0
- [ ] **Step 2: 核验无遗留临时文件与 Git 状态**
  运行: `git status`
  期望: 工作区干净无未提交修改
- [ ] **Step 3: 运行静态语法检查与无子进程管道审计**
  确保无新增反模式或语法警告。
