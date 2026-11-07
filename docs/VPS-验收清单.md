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
- `[Xray]` 确认配置校验为 OK、`GOMEMLIMIT` 已按当前机型注入；
- `[DNS]` 内置 DoH 连通，出站 `domainStrategy: UseIP`（或纯 IPv6 下 `UseIPv6`）。

---

## 1. 安装与基线

```bash
# 从仓库安装（或克隆后执行）
bash install.sh

# 确认目录自包含
ls -la /opt/xmg/
readlink -f /usr/local/bin/xmg      # 应指向 /opt/xmg/bin/xmg

# 跑一遍仓库内测试（tests/ 不随安装包落盘，需在仓库目录执行）
bash tests/run.sh
# 期望：FAIL=0（断言数随用例增长，以实际汇总为准）
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
# Environment="GOMEMLIMIT=64MiB"（215MB 机型示例，实际由脚本按机型计算）
# Environment="GODEBUG=madvdontneed=1"
# Environment="GOMAXPROCS=<有效核数，上限 4>"（0.5C 机型为 1）
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

## D2. REALITY 入站与分享链接结构

```bash
xmg proxy apply --reality on --reality-port 8443 --reality-sni www.microsoft.com
xmg xray validate
xmg proxy link reality
xmg proxy link vless
```

**期望**：

- `config.json` 内 REALITY 入站含 `"security": "reality"` 与 `realitySettings`（`target` / `dest` / `serverNames` / `privateKey` / `shortIds`），且**不含** `certificates`；
- 链接结构为 `vless://<uuid>@<host>:<port>?encryption=none&security=reality&sni=...&fp=chrome&pbk=...&sid=...&spx=%2F&type=xhttp&path=...&mode=...`；
- `<host>` 必须是客户端可达的**公网地址**：NAT/容器机型用 `--public-host` 或 `XMG_PUBLIC_HOST` 显式声明，链接里出现 `10.x` / `172.16-31.x` / `192.168.x` 即为错误；
- `pbk` 是**公钥**（base64url），不是服务端 `privateKey`；
- IPv6 主机在链接中带方括号：`@[2001:db8::1]:8443`；
- path 含空格 / `?` / `&` / 中文时，链接里必须是 `%XX` 编码，不能出现裸空格或第二个 `?`；
- TLS 直连链接：ACME（CA 签发）证书**不带** `allowInsecure=1`；自签证书才附带，避免无谓的证书校验降级；
- CDN 链接的 `alpn` 为 `h2,http/1.1`（XHTTP 是 TCP/TLS 传输，不支持 QUIC/HTTP3）。

NAT 机型多入站时用方案级端口，避免两条链接共用同一个公网端口：

```bash
xmg proxy apply --vless-external-port 20001 --reality-external-port 20002
xmg proxy link vless      # 端口应为 20001
xmg proxy link reality    # 端口应为 20002
```

`xmg proxy status --json` 应包含 `reality_enabled` / `reality_port` / `reality_sni` / `external_port` /
`vless_external_port` / `reality_external_port`，且不出现任何密码或私钥字段。

---

## E. NAT 与纯 IPv6 网络适配

**9. NAT 端口映射连通性**

NAT 机通常分配高位端口（如 10022 SSH, 11080 SOCKS, 10443 VLESS）：
```bash
# 外部通过映射端口验证 SOCKS5
curl --socks5-user testuser --socks5 testpass123 --socks5-hostname <公网IP>:<公网映射端口> https://cloudflare.com/cdn-cgi/trace
```

多入站同时启用时，外部映射端口要用方案级参数分别声明（全局 `--external-port` 只适合单入站）：

```bash
xmg proxy apply --vless-external-port 10443 --reality-external-port 18443
xmg doctor        # NAT 机型未声明外部端口时，输出 [提示] 行
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
| 全量自动化测试 | `FAIL=0`，退出码 0（断言总数随用例增长，以实际汇总为准） |
| 全部脚本静态语法 | 所有 `lib/*.sh`、`xmg`、`install.sh` 执行 `bash -n` 零语法错误 |
| 模块瘦身与解耦 | 彻底剥离 `caddy.sh`、`site.sh`、`third-party.sh`，清单与菜单同步更新 |
| 环境自省模块 (`detect.sh`) | 架构探测、内存阶梯 (extreme_low)、网络双栈/NAT/NAT64 探测全部覆盖 |
| 状态两阶段原子提交 | 批量暂存 `stage` + 一次性落盘 `commit_draft`，消灭 N+1 磁盘写放大 |
| Xray 官方规范补齐 | 注入 `rejectUnknownSni: true`、`domainStrategy` 闭环、`connIdle: 60`、双栈 DoH |
| REALITY 入站 | XHTTP + REALITY 字段下发、密钥对自动生成、`vless://` 链接含 `pbk`/`sid`/`spx` |
| 分享链接规范 | query 值完整百分号编码、IPv6 主机加方括号、ACME 证书不附带 `allowInsecure` |
| 内存压制与解耦 | drop-in 按运行时内存（cgroup 配额）注入 `GOMEMLIMIT` / `GOGC` / `GOMAXPROCS`，`nofile` 按内存分档 |
| 专属调优 (`tune.sh`) | extreme_low 网络缓冲（4MB）、8192 conntrack、容器安全熔断与 Swap 预检 |
| 自检诊断工具 (`doctor.sh`) | `xmg doctor` 结构化输出终端自检卡片，含 NAT 外部端口与 Go 参数漂移提示 |
| 安装自检 (`selftest.sh`) | `xmg selftest` 按发行版/init/防火墙后端切换断言，清单比对可发现升级中断 |
| Alpine / OpenRC | 发行版/init/包管理器抽象、`/etc/init.d/xray`、`xmg-firewall` 开机重放、unbound DoT |
| 防火墙联动 | `xmg firewall allow` 自动纳入已启用的 SOCKS5 / VLESS / REALITY 端口 |

---

## 安装类验收（Debian / Ubuntu / Alpine 通用）

装完即可跑，**不依赖仓库**（自检模块随安装包落盘）：

```bash
xmg selftest        # 只读一致性自检，FAIL 时退出码 1
xmg selftest -q     # 只看 FAIL / WARN
```

它按发行版自动切换断言：Debian/Ubuntu 校验 `systemd` unit + drop-in，Alpine 校验 `/etc/init.d/xray` + 运行级；防火墙按 ufw / iptables 分流；OpenRC 额外校验 `/etc/sysctl.conf` 标记块。覆盖安装完整性（含清单比对，能发现升级中断）、内核与配置语法、服务注册与运行态、入站端口监听、防火墙链、DNS 可用性。

需要「从零安装 → 配置 → 启防火墙 → 卸载」的完整链路验收时，用仓库脚本（会真实改动系统，仅限一次性 VPS/快照）：

```bash
# 常规验收（跳过防火墙启用，避免影响 SSH）
bash tests/acceptance.sh

# 追加防火墙启用验证：会真实启停 ufw / iptables
bash tests/acceptance.sh --with-firewall

# 离线环境 / 只想看现状
bash tests/acceptance.sh --skip-core --keep
```

`tests/acceptance.sh` 启动时同样自行探测**发行版家族 / init 系统 / 包管理器 / 防火墙后端**，覆盖 Debian 11/12、Ubuntu 20.04+、Alpine 3.16+ 以及任意 systemd 或 OpenRC 系统，不为单一发行版写专用断言。

覆盖链路：安装落盘 → `xmg os` 与脚本独立探测结果**一致性比对** → 内核安装与服务注册（systemd unit+drop-in / OpenRC init 脚本，按 init 自动切换）→ 代理配置闭环（含端口实际监听）→ 防火墙（ufw 状态与规则 / iptables `XMG-IN` 链与 IPv6 NDP、DHCPv6 放通）→ 调优持久化 → 卸载残留（含 sysctl/limits/unbound 等系统目录产物）。

输出示例（数值随环境与实际安装状态变化）：

```
PASS=41  FAIL=0  SKIP=2   (debian / systemd / ufw)
PASS=44  FAIL=0  SKIP=1   (alpine / openrc / iptables)
```

容器内跑 Alpine（任意装了 Docker 的机器）：

```bash
docker run --rm -it --privileged -v "$PWD":/xmg alpine:3.20 \
  sh -c "apk add --no-cache bash curl && bash /xmg/tests/acceptance.sh --with-firewall"
```

容器内跑 Debian / Ubuntu：

```bash
docker run --rm -it --privileged -v "$PWD":/xmg debian:12 \
  sh -c "apt-get update -qq && apt-get install -y -qq curl && bash /xmg/tests/acceptance.sh --with-firewall"
```

> 容器内 `init` 不是 PID 1，`systemd` 会被识别为 `none`，此时服务注册相关断言自动 SKIP；要验证 systemd 路径请用真实 VPS 或 `--privileged` + systemd 镜像。

以下 A1–A7 为 Alpine 上的**手工**核查命令（一键脚本已覆盖同样内容，保留用于逐项定位）。Debian/Ubuntu 对照执行时：`apk` → `apt-get`、`rc-service`/`rc-update` → `systemctl`、`/etc/init.d/xray` → `/etc/systemd/system/xray.service`。

**A1. 基础识别**

```bash
apk add --no-cache bash curl
bash install.sh
xmg os
```

期望：`family=alpine`、`Init: openrc`、`包管理: apk`；`xmg doctor` 的 `[系统]` 行同样体现这三点。

**A2. 内核安装与服务注册**

```bash
xmg core install
rc-service xray status
rc-update show | grep xray
grep -E 'GOMEMLIMIT|rc_ulimit|command=' /etc/init.d/xray
```

期望：二进制落 `/usr/local/bin/xray`；`/etc/init.d/xray` 存在且含 `GOMEMLIMIT=`、`rc_ulimit`；`xray` 已进 `default` 运行级；`xmg xray restart` 走 `rc-service`。

**A3. 代理配置闭环**

```bash
xmg proxy apply --socks on --socks-port 1080 --socks-user u --socks-pass p
xmg proxy status
xmg xray validate
```

期望：配置校验通过、服务自动重启成功（失败会双回滚并返回 4）。

**A4. 防火墙 iptables 后端**

```bash
xmg firewall status          # 后端应显示 iptables
xmg firewall allow
xmg firewall enable
iptables -S XMG-IN
iptables -S INPUT | grep XMG-IN
rc-service xmg-firewall status
```

期望：`XMG-IN` 链含 22/80/443 RETURN + 末尾 DROP，且挂在 `INPUT` 首部；重启后 `rc-service xmg-firewall` 能重放规则（`xmg firewall reload`）。

**A5. 调优持久化**

```bash
xmg tune bbr
xmg tune net
sysctl net.ipv4.tcp_congestion_control
grep -A3 'xmg:99-xmg' /etc/sysctl.conf
grep tcp_bbr /etc/modules
```

期望：BBR 生效；`/etc/sysctl.conf` 出现 XMG 标记块；重启后参数仍生效。

**A6. 加密 DNS（unbound 后端）**

```bash
xmg tune dot          # 选 Cloudflare
rc-service unbound status
grep forward-addr /etc/unbound/unbound.conf
nslookup cloudflare.com
```

期望：`127.0.0.1:53` 由 unbound 接管，`forward-tls-upstream: yes`；若 853 受阻会自动回滚并提示。

**A7. 卸载残留**

```bash
xmg uninstall run --yes
ls /etc/init.d/ | grep -E 'xray|xmg'
rc-update show | grep -E 'xray|xmg'
```

期望：XMG 生成的 `xray` / `xmg-firewall` 脚本与运行级注册全部清除，非 XMG 服务不受影响。

---

## 单栈 / 双栈（Debian / Ubuntu / Alpine 通用）

**N1. 纯 IPv4 主机**

```bash
xmg detect net                    # 期望 IPv4=1 IPv6=0
xmg firewall status               # UFW 路径：IPV6=yes 纠偏不报错
xmg firewall enable               # iptables 路径：只出现 iptables，不出现 ip6tables
iptables -S XMG-IN
ip6tables -S XMG-IN 2>&1          # 期望不存在该链（或提示链不存在）
```

期望：IPv4 侧规则完整；`/etc/resolv.conf` 或 unbound 配置中不出现 `::1`（`xmg tune dot` 走 unbound 时）。

**N2. 纯 IPv6 主机**

```bash
xmg detect net                    # 期望 IPv4=0 IPv6=1 NAT64=0
xmg doctor                        # [网络] 行应为 IPv4 无 / IPv6 正常
grep -E 'queryStrategy|https\+local' /opt/xmg/xray/config.json   # 应为 IPv6 DoH / UseIPv6
xmg tune dot                      # 选择 IPv6 上游；IPv4 上游应被安全拦截
```

**N3. 双栈主机**

```bash
xmg detect net                    # 期望 IPv4=1 IPv6=1
xmg firewall enable
iptables -S XMG-IN
ip6tables -S XMG-IN
```

期望 IPv6 链必须包含：`-p ipv6-icmp --icmpv6-type 133..136`、`-p udp --dport 546`，否则重启后 IPv6 邻居发现/地址续租会被默认 DROP 打断。

**N4. NAT64 主机**

```bash
xmg detect net                    # 期望 NAT64=1
getent ahosts ipv4only.arpa       # 应能解析出 64:ff9b::/96 前缀地址
```

期望：NAT64=1 时 `xmg tune dns` 不按纯 IPv6 拦截 IPv4 DNS，配置类 DoH 仍可用。

**N5. 单栈 + WARP 双栈（重点）**

纯 IPv4 主机开 WARP 后无需改配置：出站 `address` 已同时包含 `172.16.0.2/32` 与 `fd01::/128`，`queryStrategy`/`domainStrategy` 本来就是 `UseIP`。

纯 IPv6 主机开 WARP（全局接管）则必须放开策略，否则只查 AAAA，WARP 带来的 IPv4 出口形同虚设：

```bash
xmg warp enable
grep -E 'queryStrategy|domainStrategy' /opt/xmg/xray/config.json   # 期望 UseIP
xmg warp disable
grep queryStrategy /opt/xmg/xray/config.json                        # 期望收回 UseIPv6
```

分流模式（`routing`）不改全局策略——未被 WARP 命中的流量仍需走宿主机原栈。

**DNS 服务器地址按可用协议族下发**（`dns.servers`）：

```bash
xmg proxy export >/dev/null 2>&1; grep -A6 '"servers"' /opt/xmg/xray/config.json
```

| 宿主机 | DNS 列表 |
| --- | --- |
| 双栈 / 探测失败 | 1.1.1.1、8.8.8.8、`[2606:4700:4700::1111]`、`[2001:4860:4860::8888]`、localhost |
| 纯 IPv6 | 仅两个 IPv6 DoH + localhost |
| 纯 IPv4 | 仅两个 IPv4 DoH + localhost |

注意：`https+local://` 属于 DOHL 本地模式，按 Xray 官方文档**不进入路由系统**，即 DNS 查询始终直连、不会走 WARP 隧道。若要让 DNS 跟随隧道，需要改成非 local 的 `https://` 并配 `dns.tag` + `routing.rules` 指向 `warp-out`（未默认开启）。

**N6. 变更后必须换进程**

Xray 的出站、WARP 隧道、DNS 策略都在进程启动时建立，`SIGHUP` 不支持重载。以下操作都必须触发「停 → 等进程退出 → 启 → 等 active」：

```bash
xmg proxy apply        # 节点增删改
xmg warp enable|disable
xmg core install       # 内核二进制更新（旧进程持有旧 inode）
xmg update             # 代码更新
xmg xray restart       # 手动
```

验证：`xmg selftest` 的「服务运行中」应 PASS；若失败会明确提示 `xmg xray status` / `xmg doctor`。
