```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AVA-2568/xmg/main/install.sh)
```


```
/opt/xmg/                  目录
```

```
xmg #运行
```

---

## 功能

- **实时监控**：CPU 负载 / 内存 / 磁盘 / 服务状态 / 端口监听，低资源模式
- **Xray 管理**：官方脚本安装、systemd drop-in 统一配置路径、服务生命周期、诊断
- **Caddy 管理**：APT 优先 + 官方二进制兜底（不执行 apt-get update）、服务生命周期
- **站点管理**：Git 拉取部署、备份、清空（路径安全校验）
- **防火墙管理**：UFW 基础管理，Debian 一键安装 UFW（Ubuntu 预装）
- **系统调优**：
  - 一键 BBR + FQ（自动检测内核支持，需 4.9+）
  - 一键内核网络参数优化（按内存自适应档位：low ≤512MB / mid ≤2GB / high >2GB，
    conntrack 上限与 TCP 缓冲区随内存缩放，适配 0.5C/215M 小内存机型）
  - nofile limits（PAM limits.d + systemd DefaultLimitNOFILE）
  - 一键 DNS 优化（systemd-resolved 自动走 drop-in；预设 Cloudflare/Google/Quad9/阿里 +
    Cloudflare/Google IPv6（纯 IPv6 机器）；自定义支持 IPv4/IPv6/混合；可选 chattr +i 防覆盖）
  - 一键加密 DNS (DoT)：`DNSOverTLS=opportunistic` 双层回退——853 不通自动回退明文 53 不断网；
    支持 IPv6 上游；resolved 未启用的系统（如 Debian 11）自动迁移接管，切换后解析验证失败自动整体回滚
  - 时间同步一键配置（chrony 优先，回退 systemd-timesyncd，可选时区 Asia/Shanghai）
  - Swap 一键创建/删除（dd 写入防 hole，自动持久化 fstab + swappiness）
- **SSH 安全**：
  - 修改端口（先放行 UFW 再改配置，`sshd -t` 校验失败自动回滚）
  - 禁用/恢复密码登录（无密钥时拒绝禁用，防锁死）
  - fail2ban 一键部署（systemd backend，Debian 12 无 auth.log 也可用；递增封禁）
- **系统维护**：
  - 一键系统更新（apt / dnf / yum，reboot-required 提示）
  - 一键磁盘清理（journal 持久化限容 50M + apt 缓存 + 旧包清理）
  - 流量统计 (vnstat) 与磁盘占用概览
- **外部工具**：预置 IP 质量体检 / YABS / 融合怪（仅收录实测可访问地址），支持自定义第三方脚本
- **更新 / 回滚**：版本对比 GitHub Raw，更新前自动备份，支持回滚

## 适配

- 系统：Debian 11/12+、Ubuntu 20.04+
- 配置：低配 VPS（0.5C / 215MB）到高配机均可用，调优参数按内存自动分档

---

## ⚠️ 免责声明

1. 本项目（"xmg"）仅供**教育、科学研究及个人安全测试**之目的。
2. 使用者在下载或使用本项目代码时，必须严格遵守所在地区的法律法规。
3. 对任何滥用本项目代码导致的行为或后果均不承担任何责任。
4. 本项目不对因使用代码引起的任何直接或间接损害负责。
5. 建议在测试完成后 24 小时内删除本项目相关部署。
---
