# XMG 极致性能与系统健壮性深度优化设计规格书 (Spec)

- **日期**：2026-10-20
- **状态**：待用户复核 (Spec Review Gate)
- **目标环境**：
  - 硬件：0.5C / 215MB~256MB 极小内存 VPS 至多核高配机型
  - 网络：纯 IPv4、纯 IPv6、双栈、NAT 端口映射机型
  - 虚拟化：KVM、OpenVZ (OVZ)、LXC、Docker
  - 操作系统：Debian 11/12+、Ubuntu 20.04/22.04/24.04+、Alpine/Busybox
- **优化范围**：核心性能压榨（子进程消灭）、渲染器与模板对齐、WARP 端点探测优化、诊断卡片可观测性增强与单测补齐

---

## 1. 背景与优化动机 (Intent & The Why)

XMG 在经过前序重构后，已建立了基于 `state.env` 的单一真相源、双事务原子提交回滚、全面的 CLI 门面与 884 个单元测试断言。系统已完整运转。

但在针对目标机器（0.5C / 215MB RAM 极小内存 VPS 及受限 NAT 容器）的实际生产运行场景中，仍存在若干细粒度性能开销、模板一致性瑕疵与边界体验盲区：
1. **频繁子进程派生（Fork Overhead）**：在字符串处理与数组格式化中，仍存在 ~35 处使用 `echo "$x" | tr ... | cut ...` 的外部工具管道调用。在 0.5C / 215MB 极受限机器上，一次 fork+exec 的内存拷贝开销极高，易在脚本执行瞬间造成数百 KB~数 MB 的内存毛刺与 CPU 延迟；
2. **渲染器与模板规范不对齐**：`templates/config.template.json` 包含 `blocked`（blackhole）出站，但 `render.sh`（无论 jq 还是纯 Bash 引擎）在重组 outbounds 时均将 `blocked` 丢弃；同时 jq 引擎中存在一段不可达的死代码判断；
3. **WARP 测速延迟过长**：端点优选（11 个候选项）采用串行 ping 探测，弱网或有节点丢包超时时，导致用户卡顿等待 10~20 秒；纯 IPv6 环境下的节点直连分享链接缺少对 IPv6 地址的严谨格式处理；
4. **诊断自检深度欠缺**：`xmg doctor` 健康卡片缺少对自签/ACME 证书剩余有效期的巡检，以及缺少对上游 DoH 的真实连通性/往返延迟评级。

本设计的核心意图：在保持零外部新依赖（零 jq、零 python 强制依赖）的前提下，将性能压榨与细节严谨性推向极致。

---

## 2. 目标、非目标与反目标 (Goals, Non-Goals & Anti-Goals)

### 2.1 目标 (Goals)
1. **消灭热路径中的外部子进程调用**：将全模块中所有针对简单字符串裁剪、分隔符替换、前后缀修剪的 `tr` / `cut` / `head` / `sed` 管道，改写为 Bash 4.4+ 原生参数展开（`${var//...}`、`${var#*...}`、`${var%%...}`）与内建重定向，实现纯 Bash 内建零 fork 字符串处理；
2. **统一 Xray 模板与渲染引擎**：
   - 在 `render.sh` 的纯 Bash 引擎和 jq 引擎中统一保留 `tag: blocked`（blackhole）出站，确保路由阻断规则有闭环出站；
   - 修复 `render.sh` 中 jq 引擎在模板文件缺失时的不可达回退分支，确保优先使用内置骨架完成 jq 注入；
3. **优化 WARP 端点测速与 IPv6 节点直连链接**：
   - 优化 `xmg_warp_optimize_endpoint` 探测逻辑，降低单节点超时阈值（ping -W 1 / connect-timeout 1），减少用户等待时间；
   - 优化 `xmg_proxy_vless_link`，当直连监听或公网地址为纯 IPv6 字面量时，确保主机部分规范化为 `[IPv6]` 形式；
4. **增强健康诊断卡片 (`doctor.sh`)**：
   - 增加证书到期剩余天数自动检测，若 <= 15 天提示黄色告警；
   - 增加当前生效 DoH 的真实网络解析延迟探测（<50ms 优/绿色，<200ms 良/黄色，超时 差/红色）；
5. **保证测试套件完整性**：
   - 现有 884 个断言 100% 保持通过；
   - 针对上述优化点增加单元测试用例，总通过断言数只增不减。

### 2.2 非目标 (Non-Goals)
1. 不推翻现有的两阶段提交（`state.sh`）机制与 CLI 命令门面结构；
2. 不引入任何 C/Rust/Go 二进制辅助工具；
3. 不变更 Xray 配置的核心数据结构和协议入站类型。

### 2.3 反目标 (Anti-Goals)
1. 绝不增加向后兼容包装层或废弃逻辑（直接修改到位，符合过时即删原则）；
2. 绝不为了代码抽象而增加无谓的中间调用链，最简实现优先。

---

## 3. 详细设计与模块改造方案 (Technical Specifications)

### 3.1 模块 1：纯 Bash 内建优化与子进程消灭 (Performance Tuning)

#### 3.1.1 `lib/render.sh`
- 消除 `warp_reserved="[$(echo "$warp_reserved" | tr ' ' ',')]"`：
  ```bash
  # 原实现: echo ... | tr
  # 优化后纯 Bash:
  local clean_res="${warp_reserved//[\[\]]/}"
  clean_res="${clean_res//[[:space:]]/,}"
  while [[ "$clean_res" =~ ,, ]]; do clean_res="${clean_res//,,/,}"; done
  clean_res="${clean_res#,}"
  clean_res="${clean_res%,}"
  warp_reserved="[$clean_res]"
  ```
- 统一添加 `blocked` 出站：
  在 `outbounds` 数组末尾始终追加：
  ```json
  {
    "protocol": "blackhole",
    "tag": "blocked",
    "settings": {}
  }
  ```
- 修复 jq 引擎模板加载死分支：
  ```bash
  if [ -n "$tpl_file" ] && [ -f "$tpl_file" ]; then
      if MSYS_NO_PATHCONV=1 jq "${jq_args[@]}" "$jq_filter" < "$tpl_file"; then
          rendered=1
      fi
  elif [ "$has_jq" -eq 1 ]; then
      # 模板文件缺失但安装了 jq 时，使用内置骨架执行 jq 注入
      if printf '%s\n' "$_XMG_DEFAULT_CONFIG_TEMPLATE" | MSYS_NO_PATHCONV=1 jq "${jq_args[@]}" "$jq_filter"; then
          rendered=1
      fi
  fi
  ```

#### 3.1.2 `lib/warp.sh`
- `_xmg_warp_get_account_vars` 中的保留字段解析：
  消除 `echo "$raw_res" | tr -d '[]' | tr ',' ' '`，直接使用 Bash 替换：
  ```bash
  local nums="${raw_res//[\[\]]/}"
  nums="${nums//,/ }"
  local r0="0" r1="0" r2="0"
  read -r r0 r1 r2 _ <<< "$nums"
  reserved_json="[$r0, $r1, $r2]"
  ```
- `_xmg_warp_clean_ipv4` / `_xmg_warp_clean_ipv6`：
  消除 `val="$(echo "$val" | tr -d '[:space:]')"`，直接使用 `val="${val//[[:space:]]/}"`。
- `xmg_warp_optimize_endpoint`：
  - 探测超时参数收敛：ping 参数从 `-c 2 -W 1` 收紧至 `-c 1 -W 1`（在首轮快速筛选中单包即能代表可达性与 RTT）；
  - curl fallback 从 `--connect-timeout 2` 收敛至 `--connect-timeout 1`；
  - 测速总耗时从平均 15~22 秒大幅压缩至 3~5 秒内。

#### 3.1.3 `lib/detect.sh`
- 第 399 行：
  消除 `done <<< "$(cat "$mounts_file" 2>/dev/null || true)"`，
  直接改用内建输入重定向：
  `done < "$mounts_file" 2>/dev/null`。

#### 3.1.4 `lib/common.sh`
- `xmg_kill_apt_lock_holders`：
  消除多层 `tr` 和 `grep`，使用纯 Bash 数组去重与规范化。

---

### 3.2 模块 2：节点直连链接规范化 (`lib/proxy.sh`)

在 `xmg_proxy_vless_link` 中：
- 当用户处于纯 IPv6 环境，且 `domain` 或公网 IP 为 IPv6 字面量时（如 `2001:db8::1`）：
  在直连模式链接 `vless://${uuid}@${host}:${port}...` 中：
  如果 `${host}` 包含冒号 `:` 且未被方括号包围，自动包裹为 `[${host}]`，保证所有客户端（V2rayN、Sing-box、Clash-verge）均能合法解析端口。

---

### 3.3 模块 3：健康诊断与可观测性升级 (`lib/doctor.sh`)

#### 3.3.1 证书有效期巡检 (`_xmg_doctor_get_cert_status`)
- 检查 `/opt/xmg/etc/xray/certs/fullchain.crt` 或 `PROXY_VLESS_CERT_FILE`；
- 使用 `openssl x509 -enddate -noout -in <cert>` 提取到期时间；
- 纯 Bash 计算剩余有效天数：
  - 剩余 > 30 天：显示 `正常 (剩余 XX 天)`（绿色）；
  - 剩余 1~30 天：显示 `即将过期 (剩余 XX 天)`（黄色）；
  - 已经过期或无效：显示 `已过期 / 损坏`（红色，标记为需要关注项）；
- 无证书配置时：显示 `未配置`。

#### 3.3.2 DoH 真实连通性与往返延迟评级 (`_xmg_doctor_get_doh_latency`)
- 使用当前激活的 DoH 服务器（如 `https://1.1.1.1/dns-query` 或 IPv6 DoH）；
- 执行极低开销的轻量解析探测（超时 2 秒）：
  - 耗时 < 80ms：`优秀 (<80ms)`（绿色）；
  - 耗时 80~200ms：`良好 (XXms)`（黄色）；
  - 耗时 > 200ms 或超时：`高延迟 / 超时`（红色）。

---

### 3.4 模块 4：测试套件补齐与持续验证 (`tests/`)

新增针对性回归测试断言至 `tests/cases/`:
1. `test_render.sh`: 验证渲染出的配置中 `outbounds` 严格包含 `tag: blocked`，验证 jq 在模板丢失时能平滑由内置骨架生成；
2. `test_warp.sh`: 验证 `warp_reserved` 纯 Bash 转换的边界情况（含连续空格、逗号混合、制表符等）；
3. `test_proxy_cli.sh`: 验证 IPv6 直连链接正确生成 `[IPv6]:port` 格式；
4. `test_doctor.sh`: 验证新增证书检测函数与 DoH 测速桩的输出匹配。

---

## 4. 交付与验证标准 (Acceptance Criteria)

1. **测试套件全量通过**：运行 `tests/run.sh`，`PASS >= 890, FAIL = 0`，测试断言只增不减；
2. **零外部依赖违背**：在无 `jq`、无 `python` 的测试桩环境中，所有核心命令均可正常生成合法配置并执行原子落盘；
3. **零回滚破坏**：所有新逻辑不得破坏既有原子回滚机制。
