# xmg - 极简低配 VPS 代理与网络管理引擎

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AVA-2568/xmg/main/install.sh)
```

目录：`/opt/xmg/` | 入口：`xmg`

---

## 🎯 核心定位与设计目标

专为 **0.5C / 215MB RAM 极低内存 VPS**、**NAT 端口映射机器** 与 **纯 IPv6 / 双栈主机** 打造的极简、坚固、零臃肿代理与核心网络栈管理引擎。

- **零外部重依赖**：纯 Bash 4.4+ 实现，零 jq、零 python，拒绝常驻外部中间件。
- **内存极限防护**：针对 `<= 256MB` 设立专属 `extreme_low` 档位；systemd 注入 `GOMEMLIMIT=100MiB` / `GODEBUG=madvdontneed=1` / `GOMAXPROCS=1`，Xray 常驻内存稳定在 20MB~35MB。
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
  - **VLESS + XHTTP + TLS**：严格遵循最新官方规范（`method: "xhttp"`、`mode: "packet-up"`）；注入 `"rejectUnknownSni": true` 防源站探测；出站显式声明 `domainStrategy` 闭环内置 DoH；`connIdle: 60` 极速回收空闲套接字。
  - **SOCKS5**：公网或本地入口，`auth: password` 认证，支持绑定 `127.0.0.1` 本地安全转发或 `0.0.0.0` 公网暴露。
  - 状态批处理：消灭循环磁盘读写，单一原子事务落盘。
- **专属系统调优 (`xmg tune`)**：
  - **四阶内核网络缓冲优化**：新增 `extreme_low` (<=256MB) 档位（`conntrack_max=8192`，4MB TCP 缓冲，收敛突发连接内存峰值）；受限容器静默容错；
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
xmg proxy status --json
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
```

---

## 💻 适配环境

- **操作系统**：Debian 11/12+、Ubuntu 20.04+
- **硬件规格**：0.5C / 215M 极低内存机器至多核高配机型（调优参数按内存四阶自适应）
- **虚拟化架构**：KVM、OpenVZ (OVZ)、LXC、Docker，涵盖常规 VPS 与 NAT 玩具鸡
- **网络栈**：纯 IPv4、纯 IPv6（自适应 IPv6 DoH）、IPv4/IPv6 双栈、NAT 端口映射机型

---

## ⚠️ 免责声明

1. 本项目（"xmg"）仅供**教育、科学研究及个人安全测试**之目的。
2. 使用者在下载或使用本项目代码时，必须严格遵守所在地区的法律法规。
3. 对任何滥用本项目代码导致的行为或后果均不承担任何责任。
4. 本项目不对因使用代码引起的任何直接或间接损害负责。
5. 建议在测试完成后 24 小时内删除本项目相关部署。
