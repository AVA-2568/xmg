# XMG 全模块深度重构与安全加固设计规格书 (Spec)

- **日期**：2026-10-19
- **状态**：待用户复核 (Spec Review Gate)
- **目标环境**：
  - 硬件：0.5C / 215MB~256MB 极小内存 VPS 至多核高配机型
  - 网络：纯 IPv4、纯 IPv6、双栈、NAT 端口映射机型
  - 虚拟化：KVM、OpenVZ (OVZ)、LXC、Docker
  - 操作系统：Debian 11/12+、Ubuntu 20.04/22.04/24.04+、Alpine/Busybox
- **优化模式**：选项 C（全量深度重构：CLI 全指令闭环 + 安全与环境边界加固 + 状态两阶段事务一致性 + 纯 Bash 极致性能 + 全模块单测补齐）

---

## 1. 现状痛点与重构动机

通过 3 个子代理对全量 20 个模块及测试套件的显微镜级精读审计，识别出以下系统级缺陷：

### 1.1 致命级安全与可用性缺陷 (P0)
1. **状态裂隙（State Drift / Split-Brain）**：
   - `lib/warp.sh` 原地用 `jq` 改写 `config.json`，而 `lib/proxy.sh` 调用 `lib/render.sh` 时不感知 WARP 状态。用户一旦执行 `xmg proxy apply`，现网 WARP 出站被无情抹去，VPS 真实高污染 IP 暴露，而 `warp.env` 却虚假显示已启用。
   - `lib/proxy.sh` 在 `xray run -test` 验证前提前落盘 `state.env`。一旦后续校验失败或服务重启闪退，`config.json` 触发回滚，而 `state.env` 却留下了未生效新参数，配置真相源彻底分裂。
2. **SSH 锁死与安全失控**：
   - `lib/firewall.sh` 硬编码放行 22 端口，未感知用户自定义 SSH 端口。开启 UFW 后，非 22 端口会话被掐断，用户永久失联。
   - `lib/ssh.sh` 调用了不存在的函数 `xmg_ssh_get_port`，导致 fail2ban 监控端口永远写死为 22，自定义端口完全失去防爆破保护。
   - Ubuntu 22.10+ / 24.04 LTS 默认采用 systemd `ssh.socket` 机制，单纯重启 `ssh.service` 端口修改根本不生效。
3. **网络与环境误判导致路由瘫痪**：
   - `lib/detect.sh` 在 IPv6 网卡遍历中未过滤 Docker/CNI/Tailscale/ULA 网卡，将内网 IPv6 误判为公网 IPv6，导致单双栈路由决策错误引发断网。
   - `lib/doctor.sh` 采集到真实 DNS 后紧接着无条件被硬编码 `1.1.1.1` 覆盖。
4. **生命周期与特权越界**：
   - `xmg.files` 清单遗漏了 `xmg.files` 自身，安装后 `/opt/xmg/xmg.files` 缺失，破坏菜单顺序与更新自检。
   - `install.sh` 对 `/opt/xmg/etc` 设定 755 权限，凭证与私钥被系统所有低权限用户可读；`common.sh` 中的 `xmg_mkdirs` 对日志设定 777/666 权限。
   - `lib/uninstall.sh` 误删系统官方 `/lib/systemd/.../xray.service`，毁坏宿主机原生环境；且遗漏 `xmg-warp.service` 清理。
5. **协议规范偏差**：
   - `lib/render.sh` 中 `streamSettings` 写成 `"method": "xhttp"`，而官方标准为 `"network": "xhttp"`，部分内核版本会退化为 TCP 导致握手失败。

### 1.2 架构、性能与测试盲区 (P1/P2)
1. **CLI 门面严重断层**：`xmg` 缺少 `tune`、`firewall`、`ssh`、`maint`、`update`、`uninstall`、`xray`、`detect` 的非交互式命令行路由，无法满足脚本化与 CI/CD 自动化运维需求；菜单分支滥用全局 `set +e`。
2. **极低内存 (<=256MB) 适配漏洞**：`tune.sh` 在 `extreme_low` 档位下 buffer 放宽至 4MB 且无 `net.ipv4.tcp_mem`，大并发时易突发 OOM；`vm.swappiness=10` 对极小内存 VPS 属于反向优化（应保持 60）；`warp.sh` 内残留 `apt-get install jq`，极小内存机型执行必 OOM。
3. **架构分层与职责归属**：`common.sh` 末尾逆向加载 `detect.sh` 和 `doctor.sh`；`core.sh` 与 `xray.sh` 职责倒挂；`menu.sh` 残留过时的模块标签硬编码。
4. **测试覆盖大面积空白**：`install.sh`、`system.sh`、`update.sh`、`uninstall.sh`、`firewall.sh`、`ssh.sh`、`monitor.sh` 7 个核心模块测试覆盖率为 0%。

---

## 2. 总体架构设计原则

1. **单一真相源与联合双事务 (Unified SSOT & Atomic Dual-Commit)**：
   - 所有配置状态（包括 Proxy、Core 通道、WARP 模式与端点）统一由 `state.sh`（`state.env`）集中管理；
   - `config.json` 只能由 `render.sh` 基于 `state.env` 纯函数式渲染生成，任何模块严禁私自原地修改现网配置；
   - 实行 `state.env` 与 `config.json` 双文件联合两阶段原子提交与失败联动回滚。
2. **CLI 门面全量闭环与非交互支持 (Complete CLI Facade)**：
   - `xmg` 作为统一顶层入口，为所有 20 个子模块提供非交互式 CLI 子命令与参数解析（支持 `--yes`、`--json`、`--quiet`），交互式 TUI 仅作为可选操作形态。
3. **安全第一与权限最小化 (Least Privilege & Defensive Security)**：
   - 彻底封堵 SSH 端口修改断网风险（动态识别活跃端口、Ubuntu socket 机制适配、延迟看门狗）；
   - 目录与敏感凭据权限严格收紧为 `0700` / `0600`，彻底移除 777/666 反模式；
   - 卸载与清理逻辑严格界定在 XMG 自治目录与 drop-in，绝不误触宿主官方服务单元。
4. **极低内存（<=256MB）绝对存活防护 (Extreme-Low Memory Guard)**：
   - 严禁在运行路径中执行 `apt-get update`、`git clone` 等高内存消耗命令；
   - `extreme_low` 档位内核网络缓冲区收敛至 1MB，精确设定 `net.ipv4.tcp_mem` 配额，Swap swappiness 保持 60；
   - Xray 进程维持 `GOMEMLIMIT=100MiB` + `GOMAXPROCS=1` + `--without-geodata`。
5. **零向后兼容包袱与模块自声明 (Zero Legacy & Self-Describing Modules)**：
   - 彻底删除所有过时的 fallback 与硬编码映射；
   - 所有菜单模块统一在头部通过 `# XMG_MENU_LABEL: xxx` 自声明标签；
   - 底层基础库（`common.sh`）严禁逆向 source 上层业务模块。
6. **强制测试验证驱动 (Evidence-First Verification)**：
   - 为全部模块补齐独立单元与集成测试，覆盖率从当前的约 50% 提升至 100% 模块全覆盖。

---

## 3. 核心子系统详细重构方案

### 3.1 状态引擎与事务层 (`lib/state.sh` + `lib/render.sh`)

#### 【统一状态键 Schema 扩充】
将 WARP 状态收纳进 `state.env`：
- `WARP_ENABLED` (0/1)
- `WARP_MODE` (global / routing)
- `WARP_ENDPOINT` (IP:Port)
- `WARP_PRIVATE_KEY` / `WARP_PUBLIC_KEY`
- `WARP_IPV4` / `WARP_IPV6`
- `WARP_RESERVED` (形如 "[230, 19, 10]")

#### 【两阶段原子联合提交规范】
重构 `xmg_state_commit`：
- **Phase 1: 预检 (Prepare)**
  1. 接收内存暂存的草稿；
  2. 由 `render.sh` 生成临时 `tmp_config.json`；
  3. 执行 `xray run -test -c tmp_config.json`（测试模式下走 mock stub）；
  4. 校验失败直接报错退出，`state.env` 与现网 `config.json` 保持原样不变。
- **Phase 2: 提交与联动回滚 (Commit & Rollback)**
  1. 将现网 `config.json` 备份为 `config.json.bak.<ts>`；
  2. 将现网 `state.env` 备份为 `state.env.bak.<ts>`；
  3. 原子落盘新 `state.env` 并原子替换 `config.json`；
  4. 重启 Xray 服务并探测就绪状态；
  5. 若服务启动失败或崩溃：
     - 原子恢复 `config.json.bak.<ts>`；
     - 原子恢复 `state.env.bak.<ts>`；
     - 重启服务恢复原状，向用户输出错误及 journal 日志，退出码返回 4。

#### 【渲染器规范纠正】
- `render.sh` 中 `streamSettings` 统一输出 `"network": "xhttp"`；
- 支持将 WARP `warp-out` 原生作为出站节点动态合并，并在 `global` 模式下置为首选默认出口，前置 `geoip:private` 直连规则；
- 强化数字字段兜底，防止裸逗号语法错误；严格转义 ASCII 控制字符。

---

### 3.2 代理方案与 WARP 重构 (`lib/proxy.sh` + `lib/warp.sh`)

- **`lib/warp.sh` 纯态化改造**：
  - 移除所有使用 `jq` 直接原地改写 `config.json` 的代码；
  - 移除内部调用 `apt-get install jq`；
  - WARP 的启用/停用操作转为调用 `xmg_stage WARP_ENABLED ...`，然后统一走 `xmg_proxy_apply` 提交；
  - 修复端点优选网络探测：针对 IPv6 地址强制添加方括号 `http://[$host]:80`；支持纯 Bash Base64 3 字节保留字段解码。
- **`lib/proxy.sh` 规范化**：
  - 修复提前提交草稿的时序漏洞，与两阶段提交严格对齐；
  - 移除 OpenSSL 进程替换 `<(...)` 黑魔法，改用原生 `-newkey ec -pkeyopt ec_paramgen_curve:prime256v1`。

---

### 3.3 系统调优、安全防护与网络探测 (`lib/detect.sh` + `lib/tune.sh` + `lib/firewall.sh` + `lib/ssh.sh`)

- **`lib/detect.sh` 网络探测加固**：
  - IPv6 探测复用网卡白名单过滤，排除 `docker*`、`veth*` 等虚拟网卡；
  - 增加 ULA 前缀正则排除，杜绝内网 IPv6 误报为公网单双栈；
  - 归一化受限容器探测函数语义；
  - 为 RFC 7050 NAT64 探测增设 2 秒超时兜底。
- **`lib/tune.sh` 极低内存抗 OOM 优化**：
  - `extreme_low` 档位收敛 `buf_max=1048576` (1MB)，显式计算并下发 `net.ipv4.tcp_mem` 页面配额；
  - 分档设置 `vm.swappiness`：极低内存有 Swap 机器设为 60（防止 Direct Reclaim 突发 OOM），高配机设为 10；
  - 修复 `xmg_tune_sysctl_apply` 退出码防溢出归一；
  - 修复 Swap 创建前检测 Btrfs 文件系统并执行 `chattr +C` 禁用 COW 属性；
  - 修复 DoT IPv6 `/dev/tcp` 连通性测试。
- **`lib/firewall.sh` SSH 动态感知与防锁死**：
  - 废除硬编码 `ufw allow 22/tcp`；
  - 动态读取当前活跃及配置的 SSH 端口（从 `sshd_config` 及环境变量获取），强制自动放行真实 SSH 端口；
  - 安装启用 UFW 前强制确保 `/etc/default/ufw` 中 `IPV6=yes`；
  - 增加非交互命令行调用 `xmg firewall allow <port>/<proto>`。
- **`lib/ssh.sh` 现代系统适配与权限复核**：
  - 修复未定义函数 `xmg_ssh_get_port`，改用真实的 `xmg_ssh_effective port`，恢复 fail2ban 监控有效性；
  - 增加对 Ubuntu 22.10+ / 24.04 的 `ssh.socket` 探测与 drop-in 覆盖适配；
  - 禁用密码登录前严密复核 `.ssh` 目录（0700）与 `authorized_keys`（0600）文件权限。

---

### 3.4 基础层、生命周期与 CLI 门面 (`xmg` + `install.sh` + `lib/common.sh` + `lib/system.sh` + `lib/doctor.sh` + `lib/update.sh` + `lib/uninstall.sh` + `lib/menu.sh`)

- **`xmg` 主入口 CLI 门面全闭环**：
  - 补齐以下顶级子命令路由，全面支持无头非交互操作：
    - `xmg tune [bbr|net|dns|dot|swap|status|menu]`
    - `xmg firewall [status|allow|enable|disable|menu]`
    - `xmg ssh [status|port|disable-pwd|enable-pwd|fail2ban|menu]`
    - `xmg xray [start|stop|restart|reload|status|validate]`
    - `xmg detect [virt|mem|net|status]`
    - `xmg update [check|run|rollback]`
    - `xmg uninstall [--yes]`
    - `xmg system` (打印系统概况摘要)
  - 将 `version` 与 `help` 前置，零依赖极速响应；
  - 消除顶层全局 `set +e`。
- **`install.sh` 权限与安全硬化**：
  - 将 `$XMG_ETC_DIR`、`$XMG_BACKUP_DIR`、`$XMG_XRAY_DIR` 目录权限收紧为 `0700`；配置文件设为 `0600`；
  - 将 `xmg.files` 自身补全至清单内；
  - 实现本地/远程临时目录安全解压与原子落盘，增加退出 Trap 自动清理临时文件。
- **`lib/common.sh` 架构解耦**：
  - 彻底移除文件末尾对 `detect.sh` 和 `doctor.sh` 的反向加载；
  - 改造 `xmg_systemctl` 状态查询命令，在 `set -e` 严格模式下安全捕获返回码，绝不导致主脚本中断；
  - 收紧 `xmg_mkdirs` 目录权限为 `0755`，文件为 `0644`。
- **`lib/system.sh` 容器适配与 Locale 防御**：
  - 增加 Cgroup v1/v2 容器内存配额探测，容器内准确计算配额使用率；
  - `df` 命令强制前置 `LC_ALL=C`，防止中文/国际化表头导致磁盘用量解析损坏。
- **`lib/doctor.sh` 诊断纠偏**：
  - 保留真实提取的 DNS 配置，删除无条件覆盖逻辑；
  - 增加防火墙、SSH 端口、系统 NTP 时钟偏差诊断项；
  - 完善 Critical 联合判定规则。
- **`lib/update.sh` 原子性与自愈**：
  - 备份范围扩大至 `lib`、`bin`、`templates`、`xmg.files`；
  - 实行原子目录替换，更新失败自动触发回滚；彻底废弃静态 17 个模块 fallback 列表。
- **`lib/uninstall.sh` 安全边界与非交互**：
  - 清理范围严格收敛至 XMG 自治目录与 drop-in，禁止触碰 `/lib/systemd/.../xray.service`；
  - 增加对 `xmg-warp.service` 的停止与清理；增加路径安全性前置断言；支持 `--yes` 非交互一键卸载。
- **`lib/menu.sh` 规范清理**：
  - 清除硬编码 fallback，所有模块统一使用 `# XMG_MENU_LABEL:` 自声明。

---

## 4. 全模块自动化测试套件矩阵 (Test Matrix)

在保留现有 15 个用例（569 个测试点）的基础上，新增并补全以下测试用例：

1. **`test_manifest_integrity.sh`**：
   - 验证 `xmg.files` 自包含自身；
   - 验证清单与 `lib/*.sh` 形成双向一一映射；
   - 验证无废弃模块残留。
2. **`test_cli_facade.sh`**：
   - 验证 `xmg help` / `xmg version` 极速返回且退出码为 0；
   - 验证所有新增子命令（`tune`、`firewall`、`ssh`、`xray`、`detect`、`update`、`uninstall`、`system`）的分发逻辑与未知参数的退出码 2。
3. **`test_state_atomic_dual.sh`**：
   - 验证两阶段联合提交：模拟 `xray run -test` 失败，断言 `state.env` 与 `config.json` 均保持旧版未动；
   - 模拟服务重启失败，断言 `state.env` 与 `config.json` 均成功自动回滚至备份。
4. **`test_warp_proxy_synergy.sh`**：
   - 验证在启用 WARP 之后执行 `proxy apply`，生成的 `config.json` 必须完整保留 `warp-out` 与分流规则，彻底杜绝状态撕裂。
5. **`test_firewall.sh`**：
   - 验证自定义 SSH 端口下，防火墙基础规则必须同时保留并放行该端口；
   - 验证纯 IPv6 环境下 `/etc/default/ufw` 开启逻辑。
6. **`test_ssh.sh`**：
   - 验证 fail2ban jail 配置必须动态提取真实 SSH 端口；
   - 验证 Ubuntu `ssh.socket` 模式下的配置覆盖行为。
7. **`test_install_uninstall_lifecycle.sh`**：
   - 验证安装目录权限严格为 `0700`，配置文件严格为 `0600`；
   - 验证卸载流程绝对不删除 `/lib/systemd/system/xray.service`；
   - 验证危险路径（如 `/`、空字符串）触发卸载时被强制阻断；
   - 验证 `--yes` 非交互式卸载流程。
8. **`test_render_extreme.sh`**：
   - 验证在包含控制字符、转义引号、空端口、空 bufferSize 等极端输入下，`render.sh` 输出的 JSON 语法完全合法；
   - 验证 `streamSettings` 输出 `"network": "xhttp"`。

---

## 5. 验收与交付标准

1. **语法与静态检查**：所有 20 个模块及所有测试文件经 `bash -n` 校验零语法错误；
2. **自动化测试**：新旧测试套件全量通过，预期通过断言数从 569 扩充至 700+，零 FAIL；
3. **状态零撕裂验证**：通过自动化测试断言在各种失败与交叉调用场景下，`state.env` 与 `config.json` 强一致；
4. **安全底线验证**：权限、SSH 防锁死、防火墙自适应与系统官方服务保护全部通过自动化断言。
