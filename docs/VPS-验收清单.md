# xmg Xray 配置层 — VPS 验收清单

开发机为 Cygwin（无 systemd、无真实 xray、非 ext4），以下项**无法在本机验证**，需在目标 VPS 上确认。
本机已验证的范围见文末。

建议按顺序执行，每项都给出可直接复制的命令。

---

## 0. 安装与基线

```bash
# 从仓库安装（或直接复制 xmg/ 到 /opt/xmg 后）
bash install.sh

# 确认目录自包含
ls -la /opt/xmg/
readlink -f /usr/local/bin/xmg      # 应指向 /opt/xmg/bin/xmg

# 跑一遍自带测试（Linux 上应远快于开发机）
bash /opt/xmg/tests/run.sh
# 期望：FAIL=0
```

---

## A. 文件与权限（ext4）

**1. 权限位是否真正生效**

```bash
stat -c '%a %n' /opt/xmg/etc/xray /opt/xmg/etc/xray/state.env
# 期望：目录 700、state.env 600
# 注意：state.env 内含 SOCKS5 密码明文，权限收不住是真问题
```

**2. systemd drop-in 与 reload**

```bash
cat /etc/systemd/system/xray.service.d/20-xmg.conf
# 期望：ExecStart 指向 /opt/xmg/xray/config.json

systemctl daemon-reload && systemctl enable --now xray && systemctl status xray --no-pager
```

---

## B. 内核安装

**3. `--without-geodata` 与 `--beta` 是否被官方脚本接受**

> 注：`--without-geodata` 已核对官方 `install-release.sh`（第 248 行解析、815 行文档），**确认支持**，此项只需实测 `--beta` 是否真取到预览版。

```bash
xmg core status                     # 看通道，默认应为 preview
xmg core install                    # 实际下载 + 安装
xray version                        # 确认装到的是预览版而非 stable
xmg core install --version v26.9.30 # 若需锁版本
```

**4. 内存体检阈值（215MB 机型）**

```bash
cat /proc/meminfo | grep MemAvailable
xmg core install                    # 观察是否出现内存告警
# 若告警：先 xmg tune 创建 swap 再重试
```

---

## C. 配置语义与启动（最关键）

**5. 真实 `xray run -test`**

```bash
xray run -test -c /opt/xmg/xray/config.json
# 期望：Configuration OK.
```

> ⚠️ **重要**：`run -test` **不会拒绝错误字段名**。实测 `network` 写成 `method`、甚至 `method` 填非法值，它都返回 OK 然后**静默回落**到默认 raw 传输 —— 配置"能加载"、服务"能启动"，但过不了 CDN，日志也不报错。

**6. 确认实际生效的传输是 xhttp（能抓到上面的静默失效）**

```bash
# 临时把 loglevel 调成 info
sed -i 's/"loglevel": "warning"/"loglevel": "info"/' /opt/xmg/xray/config.json
systemctl restart xray
journalctl -u xray -n 50 --no-pager | grep -iE "xhttp|transport|inbound"
# 期望：能看到 xhttp 相关字样；若无，说明字段名写错被静默忽略了
# 验证完记得改回 warning
```

**7. 两方案是否都能起来**

```bash
xmg proxy status                          # 确认两个方案都启用
ss -lntp | grep -E ':(1080|443)'          # 确认两个端口都在监听
```

**8. DNS 解析行为**

```bash
journalctl -u xray -n 30 --no-pager | grep -iE "dns|doh"
# 期望：出现 local DOH 模式字样
```

---

## D. 证书（acme）

**9. acme.sh 真实签发**

> ⚠️ **已知问题**：`acme.sh` 的签发命令**缺少 challenge 方式**（`--standalone` / `--webroot` / DNS 之一），且新版 acme.sh 需先注册账号（`--accountemail`）。真实签发大概率需要补这两个参数。需要域名 + 公网 + 80/443 可达。

```bash
xmg proxy acme your-domain.com
# 若失败，检查是否缺 challenge 方式与账号注册
```

---

## E. 系统层 DNS

**10. systemd-resolved DoT 是否生效（需 systemd ≥ 243）**

```bash
resolvectl status | grep -iE "DNSOverTLS|DNS Servers"
# 期望：DNSOverTLS=opportunistic，DNS 为境外上游
```

**11. DNS 菜单在真实 TTY 下的交互**

```bash
xmg tune
# 进 DNS 菜单，确认文案与"空回车选默认"的行为
```

---

## F. 网络与交互

**12. NAT 机型 SOCKS5 可达性**

NAT 机上若无独立公网 IPv4，需服务商做**端口映射**才能从公网访问 SOCKS5。VLESS+XHTTP+TLS 走 CDN 不受此影响（回源由 CDN 发起）。

```bash
# 从外部测试 SOCKS5（需先确认端口映射）
curl --socks5-user alice --socks5 supersecret --socks5-hostname <地址>:1080 https://ifconfig.me
```

**13. 交互菜单流程**

```bash
xmg menu    # 确认能看到「代理方案」「Xray 内核」两个新菜单项
xmg proxy menu
xmg core menu
```

**14. 过 CDN（VLESS + XHTTP + TLS）**

- path 必须**客户端与服务端一致**
- 连不上 Cloudflare → 在 CF 面板启用 **gRPC 支持**
- Nginx 无法转发流式上行 → 用 `grpc_pass` 而非 `proxy_pass`
- 其他 CDN 不兼容 → 把 `mode` 改为 `packet-up`（兼容性最强）
- 长连接被 CDN 掐断 → SSH 等需配应用层保活（XHTTP 传输层保活不足以依赖）

---

## 本机已验证的范围（开发机 Cygwin）

以下已确认，无需你在 VPS 上重复：

| 项 | 结论 |
|---|---|
| 全量测试 | `PASS=266 FAIL=0`，退出码 0 |
| 全部脚本语法 | 33 个脚本 `bash -n` 通过 |
| `--without-geodata` | 官方脚本支持（inst.sh:248 / 815） |
| 生成的 config.json | 合法 JSON，双方案共存时 2 个 inbound、tag/端口分离 |
| 字段铁律 | 产物中无 `network` / `mux` / `flow` / `extra` / `email` / `accounts` / `noauth` / `tcpSettings` |
| 必需字段 | 产物含 `"method": "xhttp"`、`"decryption": "none"`、`"auth": "password"` |
| SOCKS 入站 | 不带 `streamSettings`（产物中仅 1 处，属 VLESS） |
| CLI 幂等 | 同参数重复 apply，config.json 与 state.env 均不变 |
| CLI 返回码 | `apply` = 0（成功）；配置非法 = 2；端口冲突 = 2 且不触碰现网 |
| 原子写入 | 备份失败时现网字节不变（md5 相同）且不谎报已回滚；回滚成功时字节恢复为原始配置 |
| 备份清理 | 保留上限生效、不影响其他前缀、目录不存在不阻断 |

---

## 排查提示

- **配置改了没生效**：`xmg proxy apply` 是幂等的，确认返回码为 0；返回 2 表示校验失败（现网未被触碰），返回 4 表示运行失败（有旧配置时会回滚）
- **服务起不来**：`journalctl -u xray -n 100 --no-pager`，同时确认 `xray run -test -c /opt/xmg/xray/config.json`
- **想看当前配置全貌**：`xmg proxy status`（文本）或 `xmg proxy status --json`
- **回退**：备份在 `/opt/xmg/backups/`（保留最近 5 份），手动恢复即 `cp` 回 `/opt/xmg/xray/config.json`
- **`xmg proxy export` 会输出含密码的明文**，不要贴到终端日志或工单里
