```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AVA-2568/xmg/main/install.sh)
```
```
xmg/
├── xmg.sh                # 主入口 ✅（已改）
├── install.sh
├── uninstall.sh
├── README.md
├── lib/
│   ├── common.sh
│   ├── system.sh         # 可保留（非核心）
│   ├── monitor.sh        # ✅ 新增（核心）
│   ├── menu.sh           # ✅ 修改
│   ├── caddy.sh
│   ├── xray.sh
│   ├── site.sh
│   ├── firewall.sh
│   └── update.sh        ✅ 新增

```

```
/opt/xmg/                  程序目录
/usr/local/bin/xmg         命令入口
/etc/xmg/                  xmg 配置和备份目录
/etc/xmg/backup/           配置备份目录
/var/www/mask-site/        默认站点目录
/etc/caddy/Caddyfile       Caddy 配置
/usr/local/etc/xray/config.json  Xray 配置
```

```
xmg #运行
#更新
cd /opt/xmg
git pull --ff-only
#卸载
bash /opt/xmg/uninstall.sh
```

---

## ⚠️ 免责声明

1. 本项目（"xmg"）仅供**教育、科学研究及个人安全测试**之目的。
2. 使用者在下载或使用本项目代码时，必须严格遵守所在地区的法律法规。
3. 对任何滥用本项目代码导致的行为或后果均不承担任何责任。
4. 本项目不对因使用代码引起的任何直接或间接损害负责。
5. 建议在测试完成后 24 小时内删除本项目相关部署。

---
