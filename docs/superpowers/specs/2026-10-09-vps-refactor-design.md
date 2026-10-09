# xmg 低配 VPS (0.5C/215M) 极简架构重构规格说明书 (Spec)

- **日期**：2026-10-09
- **状态**：待用户复核 (Spec Review Gate)
- **目标环境**：
  - 规格：0.5C / 215MB RAM（极低内存 NAT 机或微型 VPS）
  - 网络：IPv4 / IPv6（支持双栈、纯 IPv6 及 NAT 端口映射）
  - 虚拟化：KVM、OpenVZ (OVZ)、LXC
  - 操作系统：Debian 11/12+、Ubuntu 20.04+
- **参考依据**：
  - Xray 官方规范：https://lcuwx2016.github.io/xtls/config/
  - RFC 1928 / RFC 1929 (SOCKS5 规范)

---

## 1. 现状痛点与重构动机

当前 xmg 拥有纯 Bash 与状态驱动雏形（`state.env` + `render.sh`），且开发机全量测试通过（`PASS=266`）。但在真实低配机型与容器化环境下暴露出系统性结构缺陷：

1. **代码膨胀与职责蔓延**：
   - `lib/caddy.sh`（26KB）与 `lib/site.sh`（8KB）属于断裂的半成品（明确声明不管理 `Caddyfile`，导致站点无法访问），在 215MB 机器上引入 Caddy 常驻内存纯属冗余；
   - `lib/third-party.sh` 仅为运行 3 个外部测试脚本引入大量交互代码，违背极简无依赖原则；
   - `lib/uninstall.sh` 清理时强删宿主全局 `/etc/caddy` 与 APT 源，破坏宿主环境。
2. **极低内存 (215MB) 适配失真**：
   - 内存分档 `<=` 512MB 统一归为 low，仍赋予 16MB TCP 缓冲与 32768 conntrack，极易发生突发流量内核 OOM；
   - 内核安装内存体检硬编码 256MB，在 215MB 机器上 100% 告警并死循环建议创建 Swap；
   - Xray 未配置 `GOMEMLIMIT` 与 `GOMAXPROCS`，Go 运行时内存回收滞后；
   - 默认部署 Python 栈的 fail2ban，常驻 40MB~70MB 内存，直接吃满物理内存。
3. **NAT 映射与 IPv6 盲区**：
   - 监控与防火墙写死 22/80/443 端口，导致 NAT 机型状态失真，开启 UFW 易掐断非 22 端口的 SSH 导致失联；
   - ACME 证书申请依赖 HTTP-01（公网 80 端口），NAT 机型下必死；
   - 纯 IPv6 机器直连 GitHub 下载内核因缺少 AAAA 解析直接超时，且 DNS 调优与 DoH 渲染硬编码 IPv4 导致纯 IPv6 VPS 彻底断网。
4. **状态写入 N+1 放大与 Xray 配置缺陷**：
   - `apply` 时循环写入 `state.env` 导致 10+ 次磁盘重写与 20+ 次子进程 fork，存在半写入隐患；
   - TLS 入站缺失 `rejectUnknownSni: true`，暴露真实证书与源站；
   - Freedom 出站保持默认 `AsIs`，导致内置 DoH 被旁路闲置；
   - SOCKS5 默认监听 0.0.0.0 暴露明文密码。

---

## 2. 重构设计原则 (Architecture Principles)

1. **绝对零冗余 (Zero-Bloat)**：不写无法闭环的半吊子模块，不保留向后兼容；果断剔除 Caddy、Site、Third-party；
2. **极低内存第一优先级 (Memory-First)**：针对 215MB 设立专用 Extreme-Low 档位，全链路限制峰值与常驻内存；
3. **容器与权限感知 (Container-Aware)**：自动识别 KVM、OpenVZ、LXC，对只读 `/proc/sys`、受限内核模块及无 Swap 权限实现优雅平滑降级，绝不因权限缺失导致 `xmg_die`；
4. **NAT 与 IPv6 全场景闭环 (Network-Complete)**：解耦本地监听端口与公网映射端口；纯 IPv6 环境下自动启用 NAT64 路由代理并动态适配双栈 DoH；
5. **两阶段原子事务 (Atomic Transactions)**：配置先批量生成并执行 `xray run -test` 严格校验，确认无误后原子替换现网配置与 `state.env`，失败完整回滚。

---

## 3. 模块架构与职责重构

重构后核心架构收敛为 4 个清晰层级：

```
[命令行与交互层]  xmg 主入口 + lib/menu.sh (极简菜单)
                           │
[环境与能力自省]  lib/detect.sh (架构/内存/NAT/IPv6 探测)
                           │
[状态与两阶段事务] lib/state.sh (state.env 批处理 + 原子提交)
                           │
[协议纯函数渲染]  lib/render.sh (严格遵循 Xray 官方规范)
                           │
[核心生命周期与系统] lib/core.sh + lib/system.sh + lib/firewall.sh
```

### 3.1 模块重组与清理清单
- **彻底删除**：
  - `lib/caddy.sh`：剔除 Caddy 安装与管理；
  - `lib/site.sh`：剔除无头站点拉取；
  - `lib/third-party.sh`：剔除外部脚本聚合器；
  - 对应菜单入口与 `xmg.files` 清单条目同步移除。
- **合并与收敛**：
  - 合并 `lib/xray.sh` 与 `lib/core.sh`：统一由 `lib/core.sh` 负责 Xray 内核下载、安装、验证、systemd drop-in 注入及服务启停；在原 `lib/xray.sh` 保留轻量调用门面以保证已有测试用例兼容。
  - 新增 `lib/detect.sh`：集中处理环境嗅探，供全系统调用。
  - 新增 `xmg doctor` 诊断命令：专为远程 VPS 用户设计，一键输出诊断报告。

---

## 4. 核心子系统详细设计

### 4.1 环境能力自省层 (`lib/detect.sh`)

提供全局自省函数，返回结构化状态或只读环境变量：

```bash
# 1. 虚拟化与容器检测
# 返回: kvm | openvz | lxc | docker | unknown
xmg_detect_virt()

# 2. 容器只读/特权检测
# 检查 /proc/sys 可写性与 CAP_SYS_ADMIN 权限
# 返回: 0 (完全特权/独立内核) | 1 (受限容器)
xmg_detect_container_restricted()

# 3. 内存阶梯分档
# extreme_low (<=256MB) | low (<=512MB) | mid (<=2048MB) | high (>2048MB)
xmg_detect_mem_profile()

# 4. 网络双栈与 NAT 探测
# 探测: has_ipv4 (0/1), has_ipv6 (0/1), is_nat (0/1), has_nat64 (0/1)
xmg_detect_network()
```

- **纯 IPv6 连通自愈**：当探测到 `has_ipv4=0 && has_ipv6=1` 时，检测 `curl -s https://api.github.com` 是否超时；若超时，自动引导配置公共 DNS64/NAT64（如 `Trek/Cloudflare NAT64`），确保 `github.com` 等纯 IPv4 资源能顺利下载。

---

### 4.2 极低资源 (215MB) 极限保护设计

#### 4.2.1 专用 Extreme-Low 网络内核参数
针对 `<= 256MB` 机器设立专用微型档位：
- `conntrack_max`: `8192`（内存开销仅 ~2.6MB Slab）；
- `tcp_rmem` / `tcp_wmem` 上限: `4194304` (4MB，收敛突发连接内存峰值)；
- `tcp_max_tw_buckets`: `4096`；
- `somaxconn` / `netdev_max_backlog`: `2048`；
- **容器安全熔断**：在执行 `sysctl` 时若探测到处于非特权容器，逐项过滤只读参数，静默跳过并告警，杜绝脚本中断。

#### 4.2.2 Swap 自动防护与防磁盘打满
- 在创建 Swap 前，先通过 `df -m /` 检查根分区剩余空间；若可用空间 `< 1200MB`，自动将 Swap 尺寸收缩至 `256MB` 或中止，避免 `No space left on device`。
- 若处于 OpenVZ/非特权 LXC，检测到 `swapon` 失败时友好提示“当前容器环境受宿主机限制无法启用独立 Swap”，清除临时文件并平滑返回，不阻断主流程。

#### 4.2.3 Xray 安装包解压峰值避险
- 在执行内核安装时，若检测到 `/tmp` 为 tmpfs 且可用容量 `< 60MB`，自动将临时下载目录重定向至磁盘物理路径（如 `/opt/xmg/tmp`），并在安装完成后立即清理，规避内存爆破 OOM。

#### 4.2.4 Go 运行时内存与线程主动压制
在 systemd 服务 drop-in (`/etc/systemd/system/xray.service.d/20-xmg.conf`) 中注入：
```ini
[Service]
Environment="GOMEMLIMIT=100MiB"
Environment="GODEBUG=madvdontneed=1"
Environment="GOMAXPROCS=1"
MemoryAccounting=yes
MemoryHigh=150M
MemoryMax=180M
```
- **核心逻辑**：
  - `GOMEMLIMIT=100MiB`：强制 Go 运行时在堆内存接近 100MB 时触发主动 GC，并配合 `madvdontneed=1` 立即将物理内存页归还给 Linux 内核；
  - `GOMAXPROCS=1`：针对 0.5C 限制单线程调度，避免多核并发调度导致的协程栈膨胀与 CPU 争抢；
  - `MemoryHigh/Max`：通过 cgroup 建立内存硬防护。

#### 4.2.5 轻量化安全策略替代 Python fail2ban
- 弃用臃肿的 `fail2ban`（淘汰 Python 3 运行时）；
- 对 SSH 登录防护改用内核级原生策略：通过 Linux `iptables/ip6tables` 的 `recent` 模块实现 60 秒内失败握手限频，开销为 0 内存；若在无模块容器内，则推荐引导使用 SSH 密钥认证并禁用密码。

---

### 4.3 Xray 协议规范与配置渲染 (`lib/render.sh`)

对照官方文档严格修订：

#### 4.3.1 VLESS + XHTTP + TLS
- **入站防御加固**：
  ```json
  "streamSettings": {
    "method": "xhttp",
    "xhttpSettings": {
      "path": "/my-path",
      "mode": "packet-up"
    },
    "security": "tls",
    "tlsSettings": {
      "serverName": "example.com",
      "rejectUnknownSni": true,
      "alpn": ["h2", "http/1.1"],
      "minVersion": "1.2",
      "maxVersion": "1.3"
    }
  }
  ```
  - 新增 `"rejectUnknownSni": true`：彻底切断无 SNI 探测对源站证书的泄露。
  - 默认模式设定为 `packet-up`（最佳 CDN 兼容性）。

#### 4.3.2 SOCKS5 安全与 NAT 解耦
- 提供 `PROXY_SOCKS_LISTEN` 配置项：默认建议用户绑定 `127.0.0.1`（本地转发模式）；若用户显式开启公网 `0.0.0.0`，在交互与 CLI 中给予醒目明文警告；
- 增加 NAT 公网映射端口提示，消除外网连通混淆。

#### 4.3.3 内置 DoH 与 Freedom 闭环出站
- **DNS 渲染动态双栈**：
  - IPv4 正常时使用 `https+local://1.1.1.1/dns-query` 与 `https+local://8.8.8.8/dns-query`；
  - 纯 IPv6 时动态渲染为 `https+local://[2606:4700:4700::1111]/dns-query` 与 `https+local://[2001:4860:4860::8888]/dns-query`；
  - `queryStrategy`：双栈设为 `UseIP`，纯 IPv6 设为 `UseIPv6`。
- **Freedom 出站策略修复**：
  ```json
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIP"
      }
    }
  ]
  ```
  - 显式声明 `domainStrategy: "UseIP"`（或 `UseIPv6`），打通代理出站对内置 DoH 的依赖，终结系统 `/etc/resolv.conf` 旁路问题。

#### 4.3.4 连接空闲回收 (Policy)
- 在 policy 中除 `bufferSize: 4` 外，补齐连接空闲回收：
  ```json
  "policy": {
    "levels": {
      "0": {
        "bufferSize": 4,
        "connIdle": 60
      }
    }
  }
  ```
  - `connIdle: 60`（由默认 300 秒降至 60 秒）：迅速回收 CDN 断连或失效连接套接字，防止小内存泄露。

---

### 4.4 状态批处理与两阶段原子提交 (`lib/state.sh`)

消除循环单键写入的 N+1 问题：

```bash
# 1. 内存批量暂存：仅更新当前 shell 变量或生成 staged 缓存文件
xmg_state_stage KEY VALUE ...

# 2. 两阶段原子提交事务
xmg_state_commit()
```
**提交时序**：
1. **生成配置草稿**：基于 staged 状态渲染生成 `/opt/xmg/xray/config.json.staged`；
2. **预检配置合法性**：执行 `xray run -test -c config.json.staged`；若失败直接中止，原配置和原状态毫发无损（返回码 2）；
3. **备份当前运行状态**：备份现网 `state.env` 与 `config.json`；
4. **原子落盘替换**：通过 `mv -f` 原子替换 `state.env` 与 `config.json`；
5. **重载服务**：调用 systemd reload；若重载失败，立即恢复旧文件并二次重载（自动双回滚，返回码 4）。

---

### 4.5 远程 VPS 专用自检工具 (`xmg doctor`)

由于开发机无法复现目标内核与外部 NAT 网络，新增 `xmg doctor` 命令，输出紧凑的信息密集自检报告：

```
==================================================
              xmg 系统与网络健康自检报告
==================================================
[环境] 虚拟化: KVM | 内存: 215MB (Extreme-Low) | 容器特权: 正常
[网络] IPv4: 正常 | IPv6: 未分配 | NAT: 否 (独立公网IP)
[资源] 当前可用内存: 134MB | Swap: 512MB (已挂载)
[内核] BBR: 启用 (fq + bbr) | TCP缓冲: 4MB | 连接跟踪: 8192
[Xray] 状态: 运行中 (PID: 1248) | 运行时内存: 28MB (Limit: 100MB)
       配置校验: OK | 监听端口: :443 (VLESS), :1080 (SOCKS)
[DNS]  内置DoH: 连通 | 出站解析模式: UseIP
==================================================
所有基础指标正常，符合 0.5C/215M 极低开销运行标准。
```

---

## 5. 验收标准与交付清单 (Acceptance Criteria)

1. **测试基线通过**：本地测试套件 `bash tests/run.sh` 保证 100% 绿灯（`FAIL=0`）；
2. **静态语法检查**：所有 `lib/*.sh`、`xmg`、`install.sh` 执行 `bash -n` 零语法错误；
3. **内存基线**：在 215MB 测试环境下，Xray 服务启动后常驻 RSS 稳定在 `< 45MB`；
4. **纯 IPv6 / NAT 容错**：在无独立 IPv4 或端口受限环境中，安装与配置过程不抛出死锁异常；
5. **用户远程验证**：提供明确的单步验证命令，由用户在远程目标 VPS 上最终运行 `xmg doctor` 与 `xmg proxy apply` 进行闭环验收。
