# XMG 现状基线（2026-11-07）

本文件用于补齐 **2026-10-20 性能优化规格之后** 落地但未回写设计文档的能力，作为后续改动的对照基线。

> 历史文档（`2026-10-08` / `2026-10-09` / `2026-10-19` / `2026-10-20` 的 spec 与 plan）保留为当时的决策记录，**不再代表当前实现**。实现与文档冲突时以本文件与代码为准。

---

## 1. 本基线覆盖的增量

| 能力 | 关键实现 | 旧文档状态 |
| --- | --- | --- |
| VLESS + XHTTP + REALITY 入站（免证书） | `lib/render.sh` / `lib/proxy.sh` / `lib/state.sh` | 未覆盖 |
| 三种入站共存与端口冲突校验 | `xmg_state_validate` | 仅 SOCKS5 + VLESS |
| 标准 `vless://` 分享链接（编码 / pbk / spx / allowInsecure 策略） | `_xmg_urlencode` / `xmg_proxy_*_link` | 未覆盖 |
| NAT 方案级外部映射端口 | `PROXY_VLESS_EXTERNAL_PORT` / `PROXY_REALITY_EXTERNAL_PORT` | 未覆盖 |
| Alpine / OpenRC 全链路 | `lib/os.sh` + `lib/xray.sh` + `lib/firewall.sh` + `lib/tune.sh` | 未覆盖 |
| 安装一致性自检 `xmg selftest` | `lib/selftest.sh` | 未覆盖 |
| 跨发行版验收 `tests/acceptance.sh` | `tests/acceptance.sh` | 未覆盖 |
| 运行时内存/CPU 真源（cgroup 配额）与分档参数 | `lib/detect.sh` + `lib/xray.sh` + `lib/os.sh` | 仅 `GOMEMLIMIT=100MiB` 写死 |
| 架构包名映射扩展 | `xmg_core_arch_slug` | 仅常见架构 |
| 防火墙与代理端口联动 | `_xmg_fw_enabled_proxy_ports` | 未覆盖 |

---

## 2. 模块与入口

`xmg.files` 为安装清单真源，当前 20 个 `lib/*.sh`：

- 支撑层：`common.sh`、`os.sh`、`detect.sh`、`system.sh`
- 配置层：`state.sh`（状态与原子事务）、`render.sh`（Xray JSON 渲染）
- 能力层：`proxy.sh`、`core.sh`、`xray.sh`、`warp.sh`、`tune.sh`、`firewall.sh`、`ssh.sh`、`maint.sh`
- 观测与生命周期：`doctor.sh`、`selftest.sh`、`menu.sh`、`monitor.sh`、`update.sh`、`uninstall.sh`

入口 `xmg` 只静态依赖 `common.sh` / `system.sh` / `menu.sh` / `monitor.sh`；其余模块按子命令懒加载，并各自带 `XMG_*_SH_LOADED` 守卫与依赖兜底（允许单文件 source，供测试使用）。

菜单由清单 + 文件头 `# XMG_MENU_LABEL` + `xmg_xxx_menu()` 自动发现；只有标签没有菜单函数的模块不会出现在菜单（`detect.sh` 属于 CLI-only，标签仅为分类标记）。

---

## 3. 状态模型

`/opt/xmg/etc/xray/state.env`（0600）为唯一状态源，新增键：

| 键 | 含义 |
| --- | --- |
| `PROXY_REALITY_ENABLED` / `_PORT` / `_LISTEN` | REALITY 入站开关与监听 |
| `PROXY_REALITY_UUID` / `_PATH` / `_MODE` | 用户标识与 XHTTP 参数 |
| `PROXY_REALITY_DEST` / `_SNI` | 回落目标与 serverName |
| `PROXY_REALITY_PRIVATE_KEY` / `_PUBLIC_KEY` / `_SHORT_ID` | REALITY 密钥对与 shortId（私钥不出链接） |
| `PROXY_EXTERNAL_PORT` | 全局 NAT 映射端口（单入站兼容） |
| `PROXY_VLESS_EXTERNAL_PORT` / `PROXY_REALITY_EXTERNAL_PORT` | 方案级 NAT 映射端口（优先于全局） |
| `PROXY_PUBLIC_HOST` | 客户端可达的公网地址（NAT/容器无法自动探测时显式声明，优先级最高） |

校验边界（`xmg_state_validate`）在落盘前统一执行，失败返回 2 且不触碰现网：

- 端口 1–65535（含前导零归一、超长串拦截）；
- 三个外部端口键均参与校验，非法值不再静默写入；
- REALITY 启用时 `uuid` / `path` / `mode` / `dest` / `sni` / `privateKey` / `shortId` 全部校验；
- 多入站同时启用时端口不得冲突。

事务模型不变：`stage` 内存暂存 → `validate` → 配置 `xray run -test` → 双文件原子替换；任一步失败完整回滚。

---

## 4. 分享链接规范

结构遵循 VLESS URI：

```
vless://<uuid>@<host>:<port>?<query>#<remark>
```

实现要点：

1. **百分号编码**：`_xmg_urlencode` 按字节处理，保留 unreserved（`A-Za-z0-9-_.~`）与 query 合法的 `:`、`@`；其余（含 `/` `?` `&` `#` 空格、UTF-8）编码为 `%XX`。IPv6 SNI 的 `:` 不编码，避免客户端解析失败。
2. **TLS（XHTTP）**：`encryption=none&security=tls&sni&fp=chrome&alpn=h2,http/1.1&type=xhttp&host&path&mode`。
   CDN 模式地址固定 `:443`，直连模式使用主机端口（NAT 时取外部映射端口）。
3. **REALITY**：`security=reality&sni&fp=chrome&pbk&sid&spx=%2F&type=xhttp&path&mode`。
   `pbk` 取 `apply` 时随密钥对落盘的 `PROXY_REALITY_PUBLIC_KEY`，旧数据回退到 `xray x25519 -i` 反推；
   两者都缺失时拒绝生成链接，不再输出 `<PUBLIC_KEY>` 占位符。`sid` 未启用时省略该参数，长度必须是偶数位十六进制。
4. **证书校验降级**：仅当证书来源为 `user` 且判定为自签（或无 openssl 无法判定）时，直连链接附带 `allowInsecure=1`；ACME/CA 证书不带。
5. **IPv6**：authority 部分自动加方括号。
6. **NAT**：方案级外部端口优先，未声明时回落到全局；仍未声明则使用监听端口并告警，`xmg doctor` 在 NAT 机型输出 `[提示]`。
7. **公网地址**：`XMG_PUBLIC_HOST` → `PROXY_PUBLIC_HOST`（`--public-host` 落盘）→ 本机全局地址 → Cloudflare trace 出口探测。
   私网段（10/8、172.16/12、192.168/16、100.64/10、127/8、169.254/16、fe80::/10、fc00::/7）一律跳过；
   仍无法确定时拒绝生成链接，绝不把内网地址塞给客户端。

已知限制：CDN 链接固定 443（Cloudflare 常规入口）；直连链接的 authority 使用域名，若域名开启 Cloudflare 代理说明本意就是 CDN，直连应改用仅 DNS 的子域。

---

## 4.1 WARP 出站

- 账号：内置 Cloudflare 注册（多 API 版本回退）+ `xmg warp import` 外部凭据导入；`reserved` 由 `client_id` 解码补齐。
- 出站：`protocol: wireguard`，`noKernelTun`，`mtu 1280`，`keepAlive 25`；全局模式置顶为默认出站，分流模式按 AI/流媒体域名清单命中。
- 配置合并：优先用 jq 做无损增量；**无 jq 时仅 XMG 托管配置（`$XMG_HOME/xray/config.json`）可交由渲染器重建**，外部自定义配置会明确报错，绝不写出非法 JSON。
- 单栈适配：纯 IPv6 + 全局模式自动把 `queryStrategy` / `domainStrategy` 放开为 `UseIP`，停用时收回。
- 失败回滚：重启失败会同时还原配置、`warp.env` 与 state，避免「状态说已启用、配置已回滚」的鬼状态。

---

## 5. 运行时资源模型

内存与 CPU 统一取 `detect.sh` 真源：容器内以 cgroup 配额收敛 `/proc/meminfo` 与 `nproc`，避免把宿主规格当成容器规格。

| 运行时内存 | GOMEMLIMIT | GOGC | nofile |
| --- | --- | --- | --- |
| ≤ 96MB | 32MiB | 40 | 32768 |
| ≤ 192MB | 48MiB | 40 | 65536 |
| ≤ 384MB | 64MiB | 60 | 131072 |
| ≤ 512MB | 100MiB | 默认 | 131072 |
| ≤ 1024MB | 100MiB | 默认 | 524288 |
| ≤ 2048MB | 150MiB | 默认 | 524288 |
| > 2048MB | 150MiB | 默认 | 1048576 |

- `GOMAXPROCS`：有效内存 ≤512MB 或有效核数 = 1 时收敛为 1，否则取 `min(核数, 4)`；
- `GODEBUG=madvdontneed=1` 恒定注入；
- systemd 走 `xray.service.d/20-xmg.conf`，OpenRC 写入 `/etc/init.d/xray` 的 `export` 与 `rc_ulimit`；
- drop-in 不再「存在即跳过」，而是与当前机型期望内容整体比对，升配/降配后自动刷新；
- `xmg doctor` 对落盘值与期望值做漂移比对并提示。

---

## 6. Alpine / OpenRC

- `lib/os.sh` 提供发行版 / init / 包管理器 / 服务管理抽象：`xmg_svc_*`、`xmg_pkg_*`、`xmg_init_*`；
- Xray 服务注册：systemd 走 unit + drop-in，OpenRC 走内置 `/etc/init.d/xray`（含 `GOMEMLIMIT` / `GOMAXPROCS` / `rc_ulimit`）；
- 防火墙：ufw 或 iptables 私有链 `XMG-IN` + `xmg-firewall` 开机重放；IPv6 侧强制放通 NDP（133–136）与 DHCPv6（546）；
- 加密 DNS：systemd-resolved `DNSOverTLS` 或 unbound `forward-tls-upstream`；
- 调优持久化：`/etc/sysctl.d` + OpenRC 额外维护 `/etc/sysctl.conf` 标记块与 `/etc/modules`；
- BusyBox 兼容：`sysctl` 全量写入、`free`/`df` 参数差异、`install` 参数缺失均已分流处理。

---

## 7. 自检与验收

- `xmg selftest`：只读，按发行版/init/防火墙后端切换断言，覆盖环境识别、清单落盘、内核与配置语法、服务注册与运行态、入站端口监听、防火墙链与 NDP、调优持久化、DNS。
- `tests/run.sh`：34 个用例文件、1000+ 断言；`tests/` **不随安装包落盘**，需在仓库目录执行。
- `tests/acceptance.sh`：从零安装 → 配置 → 防火墙 → 调优 → 卸载的整链验收，自动探测发行版/init/防火墙后端；`--with-firewall` 会真实启停防火墙。
- 本机（Windows/Cygwin）无法验证：符号链接、`rm` 权限、`mktemp` POSIX 路径、真实内核参数、systemd PID 1。相关告警属于开发机环境限制，需在目标 VPS 复核。

---

## 8. 后续待决

1. 直连链接 authority 是否改为公网 IP（当前用域名；域名开启 Cloudflare 代理即视为 CDN 场景，直连应使用仅 DNS 的子域）。
2. 单入站旧配置（全局 `--external-port`）与新方案级端口并存的生命周期策略。
3. `detect.sh` 是否需要菜单入口（当前仅 CLI，已移除无效标签）。
