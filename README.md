# xmg - 极简低配 VPS 代理与网络管理引擎

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AVA-2568/xmg/main/install.sh)
```

目录：`/opt/xmg/` | 入口：`xmg`

> Alpine 默认没有 bash，上面的进程替换语法不可用，请改用 [`Alpine 安装步骤`](#-alpine--openrc-支持)。

---

## 🎯 核心定位与设计目标

专为 **0.5C / 215MB RAM 极低内存 VPS**、**NAT 端口映射机器** 与 **纯 IPv6 / 双栈主机** 打造的极简、坚固、零臃肿代理与核心网络栈管理引擎。

- **零外部重依赖**：纯 Bash 4.4+ 实现，jq / python 全程可选（存在时用于模板渲染加速，缺失自动回退纯 Bash 引擎），拒绝常驻外部中间件。
- **内存极限防护**：针对 `<= 256MB` 设立专属 `extreme_low` 档位；按运行时内存（容器内取 cgroup 配额）动态计算 `GOMEMLIMIT`（32/48/64/100/150MiB）与 `GOGC`，`GOMAXPROCS` 按有效核数自适应（<=512MB 收敛为 1，上限 4），并注入 `GODEBUG=madvdontneed=1`，Xray 常驻内存稳定在 20MB~35MB。
- **容器与虚拟化自省**：自动识别 KVM、OpenVZ (OVZ)、LXC、Docker；对受限容器的只读 `sysctl` 与 Swap 限制平滑熔断降级，绝不因权限缺失崩溃。
- **全场景网络适配**：解耦 NAT 外部映射端口；支持纯 IPv4、纯 IPv6 及双栈环境，内置 DoH 与出站解析动态适配。
- **两阶段原子事务**：`state.env` 批量暂存合并提交，配置经 `xray run -test` 校验通过后原子替换，失败完整双回滚。

---

## 🚀 核心功能

- **健康自检体检 (`xmg doctor`)**：
  一键生成结构化终端卡片，秒级排查环境虚拟化、内存阶梯、单双栈网络/NAT、内核 BBR/缓冲、Xray 服务状态与 Go 内存抑制、DNS 解析连通性。
- **Xray 内核管理 (`xmg core`)**：
  - 支持 stable / preview / pinned 三通道；
  - 针对小内存机型优化临时目录，防 tmpfs 内存爆破 OOM；
  - 自动在 systemd drop-in 中注入 `GOMEMLIMIT` 堆限制；
  - 215MB 极小内存直接放行安装并自适应抑制策略。
- **代理方案配置 (`xmg proxy`)**（交互菜单 + 幂等 CLI）：
  - **VLESS + XHTTP + TLS**：严格遵循最新官方规范（`"network": "xhttp"`、`mode: "packet-up"`）；注入 `"rejectUnknownSni": true` 防源站探测；出站显式声明 `domainStrategy` 闭环内置 DoH；`connIdle: 60` 极速回收空闲套接字。
  - **VLESS + XHTTP + REALITY**：免证书方案，`dest` / `serverNames` / `privateKey` / `shortIds` 按官方字段下发；`xmg proxy keygen` 生成密钥对，`xmg proxy link reality` 输出标准 `vless://` 链接（`security=reality` + `pbk` / `sid` / `spx`）。
  - **SOCKS5**：公网或本地入口，`auth: password` 认证，支持绑定 `127.0.0.1` 本地安全转发或 `0.0.0.0` 公网暴露。
  - 三种入站可共存，端口冲突在校验阶段拦截；状态批处理，单一原子事务落盘。
  - 分享链接按 VLESS URI 规范生成：query 值完整百分号编码（path 含空格 / `?` / `&` / 中文不再截断），ACME 证书不附带 `allowInsecure`，仅自签证书才放宽校验。
- **专属系统调优 (`xmg tune`)**：
  - **四阶内核网络缓冲优化**：新增 `extreme_low` (<=256MB) 档位（`conntrack_max=8192`，1MB TCP 缓冲与 tcp_mem 硬保护，收敛突发连接内存峰值）；受限容器静默容错；
  - 一键 BBR + FQ（内核 4.9+）；
  - nofile limits（PAM limits.d + systemd DefaultLimitNOFILE）；
  - 防磁盘打满的 Swap 管理（创建前预检根分区剩余空间，不足自动缩减；容器环境无法 `swapon` 平滑友好降级）；
  - 双层 DNS 优化（系统层 DoT 853 自动回退 53 + Xray 内置 DoH 境外解析）。
- **系统安全与维护**：
  - SSH 端口安全修改（防锁死自检与回滚）；
  - 禁用/恢复密码登录（无密钥时拒绝禁用）；
  - 一键磁盘清理（journald 限容 50M + apt 缓存清理）；
  - 流量统计与系统更新。

---

## 🛠️ 常用命令

```bash
# 一键全面健康自检
xmg doctor
xmg doctor --dry-run

# 代理配置（幂等 CLI，支持分别或同时启用）
xmg proxy apply --socks on --socks-port 1080 --socks-user u --socks-pass 'p'
xmg proxy apply --vless on --vless-port 443 --vless-domain example.com --vless-uuid <uuid>
xmg proxy apply --reality on --reality-port 8443 --reality-sni www.microsoft.com   # 免证书，自动生成密钥对
xmg proxy apply --external-port 20000   # NAT 机型声明映射后的公网端口（单入站）
xmg proxy apply --vless-external-port 20001 --reality-external-port 20002         # 多入站分别声明
xmg proxy status --json
xmg proxy link vless             # 输出 CDN / 直连两条标准分享链接
xmg proxy link reality           # 输出 REALITY 分享链接（pbk / sid / spx）
xmg proxy keygen                 # 生成 REALITY 密钥对
xmg proxy disable socks
xmg proxy export                 # 导出当前状态配置
xmg proxy menu                   # 交互式向导配置

# 内核管理
xmg core status
xmg core install                 # 按通道安装/更新内核
xmg core version
xmg core menu                    # 切换 stable / preview / pinned 通道

# 系统调优与体检
xmg tune                         # 系统调优菜单 (BBR / 网络参数 / DNS / Swap)
xmg tune bbr && xmg tune net     # 非交互直接下发
xmg doctor                       # 结构化疗程卡片（--dry-run 无副作用）

# 路由与出站
xmg warp status                  # WARP 原生出站
xmg warp enable                  # 全局接管（单栈自动放开 DNS/出站策略）
xmg warp test                    # 解锁与延迟测试
xmg warp export                  # 导出可直接粘贴的 Xray outbound

# 安全与生命周期
xmg firewall allow               # 放行 22/80/443 + 当前 SSH 端口 + 已启用的代理端口
xmg firewall enable
xmg ssh status
xmg ssh fail2ban                 # 安装并配置 fail2ban
xmg xray status                  # 服务生命周期（start/stop/restart/reload/validate）
xmg update check                 # 在线升级（原子替换 + 回滚）
xmg update rollback
xmg uninstall run --yes
xmg detect status                # 虚拟化 / 内存分档 / 网络拓扑
xmg os                           # 发行版 / init / 包管理器
```

> `xmg firewall allow` 会读取当前状态，把已启用的 SOCKS5 / VLESS / REALITY 端口一并放行；
> NAT 机型请先用 `--external-port`（或方案级 `--vless-external-port` / `--reality-external-port`）声明映射端口。

---

## 🧪 验收

**装完即可用**，不依赖仓库（`xmg selftest` 随安装包落盘）：

```bash
xmg selftest          # 安装一致性自检，只读，FAIL 时退出码 1
xmg selftest -q       # 只看 FAIL / WARN
```

它按发行版自动切换断言：Debian/Ubuntu 查 `systemd` unit + drop-in、Alpine 查 `/etc/init.d/xray` + 运行级，防火墙按 ufw / iptables 分流，不为某个发行版写专用分支。

覆盖：发行版家族与 init 识别一致性 → 命令入口与模块完整性（含清单比对，能发现升级中断）→ 内核版本与配置语法 → 服务注册与运行态 → 入站端口实际监听 → 防火墙链与 IPv6 NDP → 调优持久化（systemd 走 sysctl.d，OpenRC 额外校验 `/etc/sysctl.conf` 标记块）→ DNS 可用性。

```
PASS=18  FAIL=0  WARN=1
结论: 安装一致性检查通过
```

需要「从零安装 → 配置 → 启防火墙 → 卸载」的完整链路验收时，用仓库里的脚本（会真实改动系统，仅限一次性 VPS/快照）：

```bash
bash tests/acceptance.sh                  # 常规验收（不动防火墙，避免影响 SSH）
bash tests/acceptance.sh --with-firewall  # 追加防火墙启用验证（会真实启停 ufw/iptables）
bash tests/acceptance.sh --skip-core --keep  # 离线 / 只保留现场
```

```
# 输出形如（数值随环境与实际安装状态变化）
PASS=41  FAIL=0  SKIP=2   (debian / systemd / ufw)
PASS=44  FAIL=0  SKIP=1   (alpine / openrc / iptables)
```

---

## 💻 适配环境

- **操作系统**：Debian 11/12+、Ubuntu 20.04+、Alpine 3.16+（OpenRC）
- **硬件规格**：0.5C / 215M 极低内存机器至多核高配机型（调优参数按内存四阶 + 有效核数自适应；容器内按 cgroup 内存/CPU 配额判定，不看宿主可见值）
- **CPU 架构**：x86_64 / aarch64 / armv7l / armv6l / armv5l / i386 / mips(含 le/64) / riscv64 / ppc64(le) / loong64 / s390x，按官方发布包命名自动映射
- **虚拟化架构**：KVM、OpenVZ (OVZ)、LXC、Docker，涵盖常规 VPS 与 NAT 玩具鸡
- **网络栈**：纯 IPv4、纯 IPv6（自适应 IPv6 DoH）、IPv4/IPv6 双栈、NAT 端口映射机型
  - 单栈自适应：纯 IPv4 不写 `::1` 上游、不下发 `ip6tables` 规则；纯 IPv6 自动切 IPv6 DoH 与 `queryStrategy: UseIPv6`
  - 双栈：防火墙按协议族分别建链，IPv6 侧强制放通 NDP（133-136）与 DHCPv6（546），避免默认 DROP 打断邻居发现
  - NAT64：内置 RFC 7050 主动探测（`ipv4only.arpa`），识别到 NAT64 时不按纯 IPv6 处理
  - NAT 端口映射：外部公网端口无法从本机可靠探测，用 `--external-port` 显式声明后用于客户端分享链接；未声明时体检/链接会提示
  - 单栈 + WARP：隧道带来对端协议族时，全局接管模式下自动把 DNS/出站策略从 `UseIPv6` 放开为 `UseIP`（否则纯 IPv6 机器即便有 WARP IPv4 出口也只查 AAAA，IPv4-only 站点仍不可达）；停用 WARP 时收回

---

## 🏔 Alpine / OpenRC 支持

Alpine 没有 systemd、没有 apt、默认 shell 是 busybox ash，因此 XMG 在启动时先做一次「发行版 / init / 包管理器」探测，再按后端分流。systemd 路径的行为与改造前完全一致。

| 能力 | Debian / Ubuntu (systemd) | Alpine (OpenRC) |
| --- | --- | --- |
| 包管理 | `apt-get` | `apk add --no-cache` |
| 服务控制 | `systemctl` | `rc-service` / `rc-update` |
| Xray 服务注册 | `xray.service` + drop-in 覆盖 | `/etc/init.d/xray`（内建按机型计算的 `GOMEMLIMIT` / `GOMAXPROCS` / `rc_ulimit`） |
| 内核安装 | 官方 `install-release.sh` | 内置原生安装（官方脚本硬校验 systemd，且不识别 apk） |
| 防火墙 | UFW | iptables 私有链 `XMG-IN` + `xmg-firewall` 开机重放（按协议族分别下发，IPv6 自动放通 NDP/DHCPv6） |
| 日志限制 | journald 限容 | 无 journald，提示配合 logrotate |
| 加密 DNS | systemd-resolved `DNSOverTLS` | `unbound` 的 `forward-tls-upstream`（853） |
| 系统调优 | `/etc/sysctl.d` 自动加载 | 写入 `sysctl.d` 并同步 `/etc/sysctl.conf` 标记块 |
| time sync | `timedatectl` + chronyd | `/etc/timezone` + chronyd / busybox ntpd |

### Alpine 安装步骤

Alpine 默认没有 bash，安装前先补齐（`install.sh` 自身需要 bash）：

```bash
apk add --no-cache bash curl
curl -fsSL https://raw.githubusercontent.com/AVA-2568/xmg/main/install.sh | bash
```

安装完成后确认识别结果：

```bash
xmg os
# 发行版 : Alpine Linux v3.20
# ID     : alpine (family=alpine, ver=3.20.3)
# Init   : openrc
# 包管理 : apk
```

### Alpine 上的常用流程

```bash
xmg doctor                 # 体检卡片会多一行 [系统] 发行版/Init/包管理
xmg core install           # 走内置下载安装，写入 /etc/init.d/xray
xmg proxy apply --vless on --vless-port 443 --vless-domain example.com --vless-uuid <uuid>
xmg firewall allow          # 放行 22/80/443 + 当前 SSH 端口
xmg firewall enable         # 启用（自动保证 SSH 端口已放行）
xmg tune bbr && xmg tune net
```

> 注意：Alpine 的 `iptables` 后端依赖内核模块（`ipt_state` / `nf_conntrack`）。OpenVZ 等受限容器可能无法加载，此时命令会明确报错而不是静默失败。

---

## ⚠️ 免责声明

1. 本项目（"xmg"）仅供**教育、科学研究及个人安全测试**之目的。
2. 使用者在下载或使用本项目代码时，必须严格遵守所在地区的法律法规。
3. 对任何滥用本项目代码导致的行为或后果均不承担任何责任。
4. 本项目不对因使用代码引起的任何直接或间接损害负责。
5. 建议在测试完成后 24 小时内删除本项目相关部署。
