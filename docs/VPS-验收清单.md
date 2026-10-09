# xmg Xray 配置层与低配架构 — VPS 验收清单

开发机为 Cygwin/本地环境（无真实 Linux 内核修改权限、非 systemd PID 1、非 ext4），以下项**无法在本机验证**，需在目标 VPS（特别是 0.5C/215M、NAT、OVZ/LXC 机器）上确认。

建议按顺序执行，每项都给出可直接复制的命令。

---

## 0. 一键快速诊断（推荐首选）

重构后新增自包含的 `xmg doctor` 诊断工具，可一次性扫描并输出结构化卡片：

```bash
# 执行完整自检诊断（含网络外部解析与真实探测）
xmg doctor

# 或进行无副作用干跑检测
xmg doctor --dry-run
```

**期望输出包含**：
- `[环境]` 正确显示虚拟化（KVM / OpenVZ / LXC / Docker）与容器特权状态；
- `[内存]` 215MB 机型正确标记为 `extreme_low` 档位；
- `[网络]` 正确识别 IPv4/IPv6 单双栈及 NAT 环境；
- `[Xray]` 确认配置校验为 OK、`GOMEMLIMIT=100MiB` 生效；
- `[DNS]` 内置 DoH 连通，出站 `domainStrategy: UseIP`（或纯 IPv6 下 `UseIPv6`）。

---

## 1. 安装与基线

```bash
# 从仓库安装（或克隆后执行）
bash install.sh

# 确认目录自包含
ls -la /opt/xmg/
readlink -f /usr/local/bin/xmg      # 应指向 /opt/xmg/bin/xmg

# 跑一遍自带测试（Linux 上应远快于开发机）
bash /opt/xmg/tests/run.sh
# 期望：FAIL=0（438+ 测试全部通过）
```

---

## A. 文件权限与两阶段原子提交（ext4）

**1. 权限位是否真正生效**

```bash
stat -c '%a %n' /opt/xmg/etc/xray /opt/xmg/etc/xray/state.env
# 期望：目录 700、state.env 600
# 注意：state.env 内含配置状态，权限收紧防越权读取
```

**2. 两阶段原子提交与批量落盘**

```bash
# 应用新配置，观察是否单一原子事务落盘，无 N+1 写入刷屏
xmg proxy apply --socks on --socks-port 1080 --socks-user testuser --socks-pass 'testpass123'
# 期望：退出码 0，现网配置 /opt/xmg/xray/config.json 自动更新
```

---

## B. 215MB 极低内存保护与 Go 运行时压制

**3. systemd drop-in 环境变量注入**

```bash
cat /etc/systemd/system/xray.service.d/20-xmg.conf
# 期望看到以下压制参数：
# Environment="GOMEMLIMIT=100MiB"
# Environment="GODEBUG=madvdontneed=1"
# Environment="GOMAXPROCS=1"
```

**4. 实际 Xray 进程内存占用（RSS）检查**

```bash
systemctl restart xray
sleep 2
# 查看 Xray 真实常驻内存（VmRSS 应稳定在 20MB~40MB 之间）
ps aux | grep -v grep | grep xray
cat /proc/$(pgrep -x xray)/status | grep -E 'VmRSS|VmHWM'
```

**5. 215MB 内存体检与安装防爆破**

```bash
xmg core status
# 执行内核安装，观察是否识别 extreme_low 并不再死循环阻断
xmg core install
```

---

## C. 容器兼容性（KVM vs OpenVZ vs LXC）

**6. 系统调优容错性（在 OVZ / 非特权 LXC 上测试）**

```bash
# 执行内核调优
xmg tune
# 期望：
# 1) 在 KVM 上应用完整的 extreme_low 参数（conntrack_max=8192，tcp_rmem/wmem=4MB）；
# 2) 在受限容器（OVZ/LXC）上对只读 sysctl 静默容错或友情提示，脚本绝不中断报错；
# 3) 创建 Swap 时若磁盘不足或容器不支持 swapon，友好提示并清理临时文件，不触发磁盘占满。
```

---

## D. Xray 协议规范与 CDN 防探测

**7. SNI 探测防御（`rejectUnknownSni: true`）**

```bash
# 从外部发起无 SNI 探测请求（伪造 Host / 无域名 TLS 握手）
curl -k -v --resolve yourdomain.com:443:127.0.0.1 https://127.0.0.1:443/
# 期望：Xray 拒绝未识别的 SNI 握手，不泄露源站证书
```

**8. Freedom 出站与内置 DoH 闭环**

```bash
# 确认 config.json 中包含 domainStrategy 闭环
grep -A 5 '"outbounds"' /opt/xmg/xray/config.json
# 期望：包含 "domainStrategy": "UseIP"（或纯 IPv6 下 "UseIPv6"）
# 确认连接空闲回收
grep '"connIdle"' /opt/xmg/xray/config.json
# 期望："connIdle": 60
```

---

## E. NAT 与纯 IPv6 网络适配

**9. NAT 端口映射连通性**

NAT 机通常分配高位端口（如 10022 SSH, 11080 SOCKS, 10443 VLESS）：
```bash
# 外部通过映射端口验证 SOCKS5
curl --socks5-user testuser --socks5 testpass123 --socks5-hostname <公网IP>:<公网映射端口> https://cloudflare.com/cdn-cgi/trace
```

**10. 纯 IPv6 节点自适应**

在纯 IPv6 VPS 上：
- 确认 `xmg doctor` 正确识别 `IPv4: 异常/未分配`，`IPv6: 正常`；
- 确认 `/opt/xmg/xray/config.json` 的 `dns` 模块自动使用 IPv6 DoH（如 `https+local://[2606:4700:4700::1111]/dns-query`）；
- 确认 Xray `queryStrategy` 自动适配为 `UseIPv6`。

---

## 本机已程序化验证范围（开发机断言）

| 验证项 | 结论 |
|---|---|
| 全量自动化测试 | `PASS=438 FAIL=0`，退出码 0 |
| 全部脚本静态语法 | 所有 `lib/*.sh`、`xmg`、`install.sh` 执行 `bash -n` 零语法错误 |
| 模块瘦身与解耦 | 彻底剥离 `caddy.sh`、`site.sh`、`third-party.sh`，清单与菜单同步更新 |
| 环境自省模块 (`detect.sh`) | 架构探测、内存阶梯 (extreme_low)、网络双栈/NAT/NAT64 探测全部覆盖 |
| 状态两阶段原子提交 | 批量暂存 `stage` + 一次性落盘 `commit_draft`，消灭 N+1 磁盘写放大 |
| Xray 官方规范补齐 | 注入 `rejectUnknownSni: true`、`domainStrategy` 闭环、`connIdle: 60`、双栈 DoH |
| 内存压制与解耦 | drop-in 注入 `GOMEMLIMIT=100MiB`，防 tmpfs 爆破，保留全部 10 个兼容接口 |
| 专属调优 (`tune.sh`) | extreme_low 网络缓冲（4MB）、8192 conntrack、容器安全熔断与 Swap 预检 |
| 自检诊断工具 (`doctor.sh`) | `xmg doctor` 结构化输出终端自检卡片，支持 CLI 与菜单 |
