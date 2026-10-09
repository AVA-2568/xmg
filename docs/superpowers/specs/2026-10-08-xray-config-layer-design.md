# xmg Xray 配置层与内核管理设计规格

日期：2026-10-08
状态：待用户复核
范围：子系统 A（Xray 内核管理）+ B（配置状态层与 CLI）+ C（双方案配置器）

---

## 1. 背景与目标

### 1.1 现状

`xmg` 是纯 Bash VPS 管理面板（约 5600 行），模块化设计（`lib/*.sh` + `xmg.files` 清单驱动菜单）。

当前 `lib/xray.sh:12` 明确声明：

> XMG 不创建、不编辑、不修改 Xray 配置模板

即面板**完全没有协议配置能力**。`xray.sh` 仅做四件事：调用官方安装脚本装内核、用 systemd drop-in 把 `ExecStart` 指向 `/opt/xmg/xray/config.json`、服务生命周期管理、诊断输出。配置需用户手工编写。

官方安装脚本默认安装 GitHub 标记为 Latest 的版本，面板未暴露 `--beta`（预览版）或 `--version <tag>`。

### 1.2 目标

1. **Xray 内核可更新到预览版**，并可指定/锁定版本。
2. **提供基于 xray 内核的交互式配置方案**，且两种方案可独立存在、也可同时存在：
   - 方案 A：SOCKS5 入站（公网开放，强制用户名+密码认证，明文无 TLS）
   - 方案 B：VLESS + XHTTP + TLS 入站（支持过 CDN）
3. **解决三个已确认的交互痛点**：无法非交互/脚本化、无状态回显、无校验/报错不直观。
4. **适配低配机型**：0.5C/215M 起步，可能是 NAT 机，可能无独立公网 IPv4，需支持 IPv4 与 IPv6 双栈。

### 1.3 非目标（本轮不做）

以下子系统已识别但**不在本 spec 范围**：

- 低配/NAT 适配的独立完善（除本 spec 已列条目外）
- 安装器 `install.sh` 与卸载器 `lib/uninstall.sh` 的重构（现状已属 manifest 驱动、幂等、带校验，收益有限）
- 面板 UI 信息架构的整体重做（`lib/menu.sh` 的模块发现机制与"按回车返回"交互）
- 外部工具（YABS / 融合怪 / IP 体检）的功能重做
- `tune.sh` DNS 模块的**重写** —— 仅调整其预设默认指向境外 DNS（§10.5.3），其余逻辑不动

---

## 2. 依据与约束

### 2.1 配置字段的唯一依据

本 spec 中所有 Xray 配置字段、取值、默认值与限制条件，**仅依据**：

> https://lcuwx2016.github.io/xtls/config

不使用记忆、社区模板、V2Ray 习惯或第三方文章。文档未提及的字段一律不写入配置。

已核对的文档页面（38 篇）包含：`config/`、`inbound`、`outbound`、`transport`、`inbounds/socks`、`inbounds/vless`、`transports/xhttp`、`transports/tls`、`transports/sockopt`、`policy`、`log`、`stats`、`api` 等。

### 2.2 与既有认知显著不同的关键点（必须遵守）

以下均为本次核对文档后确认的**当前预览版**行为，与社区常见写法不同：

| 事项 | 文档确认的写法 | 说明 |
|---|---|---|
| 传输方式字段名 | `streamSettings.method` | **不是** `network` |
| 原 TCP 传输 | `rawSettings`（`method: "raw"`） | `raw` 是「更名自曾经的 TCP 传输层」 |
| xhttp 模式取值 | `auto` \| `packet-up` \| `stream-up` \| `stream-one` | 共三种具体模式 |
| xhttp 参数容器 | `xhttpSettings.extra` | 当 `extra` 存在时，**只有** `host`/`path`/`mode`/`extra` 四项生效 |
| SOCKS 认证字段 | `auth: "noauth"` \| `"password"` + `users[{user,pass}]` | 非 `accounts` |
| VLESS 用户字段 | `users[{id,level,email,flow,reverse}]` + `decryption` | `decryption` 不可留空，禁用须显式 `"none"` |
| `bufferSize` 默认值 | ARM/MIPS=`0`、ARM64/MIPS64=`4`、其他=`512`（单位 KB） | 低配机需显式写入 |
| XHTTP + mux | 文档警告使用 XHTTP 时**不要启用 mux.cool** | 因此方案 B 不生成 `mux` 块 |

### 2.3 平台约束

- **仅支持 Debian 11/12+ 与 Ubuntu 20.04+**（用户确认）。安装与运行不再做多发行版分支。
- 需在 x86_64、ARM64、ARM、MIPS 等架构上正确识别（KVM / OpenVZ / NAT 机型均需覆盖）。

---

## 3. 架构

### 3.1 三层结构

```
入口层        交互菜单 (xmg menu)          非交互 CLI (xmg proxy ...)
                    \                        /
配置状态层      /opt/xmg/etc/xray/state.env  ← 唯一真相来源
                schema 校验 · merge · status · 原子写入
生成层        render_socks · render_vless_xhttp · core 管理
                        ↓
              /opt/xmg/xray/config.json + systemd drop-in
```

### 3.2 核心设计决策：配置状态层

**问题根源**：配置知识只存在于用户手动编辑的 `config.json` 中。三个交互痛点（无法脚本化、无状态回显、无校验）本质是同一个缺失——没有独立于 JSON 的、可编程访问的配置状态。

**方案**：引入 `/opt/xmg/etc/xray/state.env` 作为**唯一真相来源**（single source of truth）。`config.json` 降级为**派生产物**，由 state 重新生成。

**为何用扁平 `KEY=value` 而非 JSON**：
- 目标机型为 0.5C/215M，读写状态必须**零依赖**（不引入 `jq`）
- 便于 `grep` 排查
- 向后兼容 Bash，无需解析器

**这一改动一次性带来三个痛点的解法**：

| 痛点 | 解法 |
|---|---|
| 无法非交互/脚本化 | state 是稳定、文档化的文件；CLI 仅做「参数 → state」映射 |
| 无状态回显 | `status` 直接读 state，展示当前实际配置全貌 |
| 无校验/报错不直观 | 所有写入（无论来自菜单还是 CLI）都过同一个 schema 校验函数 |

### 3.3 模块划分

| 模块 | 职责 | 依赖 |
|---|---|---|
| `lib/state.sh` | state 读写、schema 校验、merge、原子写入 | `common.sh` |
| `lib/render.sh` | `render_socks` / `render_vless_xhttp`（纯函数） | `state.sh` |
| `lib/proxy.sh` | 交互向导 + CLI 入口 + `status` 回显 | `state.sh` `render.sh` |
| `lib/core.sh` | 内核安装/更新/版本锁定（预览版） | `common.sh` |

**渲染器为纯函数**：state 进、JSON 片段出，无副作用。这使它们可脱离 VPS 单测——直接对生成的 JSON 字段名与官方文档比对。

### 3.4 方案共存模型

每个方案在 state 中拥有**独立命名切片**，共用字段互不干扰：

```
PROXY_SOCKS_ENABLED=1
PROXY_SOCKS_PORT=1080
PROXY_SOCKS_USER=...
PROXY_SOCKS_PASS=...
PROXY_SOCKS_UDP=0

PROXY_VLESS_ENABLED=1
PROXY_VLESS_LISTEN=0.0.0.0
PROXY_VLESS_PORT=443
PROXY_VLESS_DOMAIN=example.com
PROXY_VLESS_UUID=<uuid>
PROXY_VLESS_PATH=/
PROXY_VLESS_MODE=auto
PROXY_VLESS_CERT_SOURCE=user

XRAY_CHANNEL=preview
```

（`state.env` 中每行均为 `KEY=value`。上例列出全部键；scheme 未启用时其字段保留上次值但不渲染。）

**合并语义**：`apply` 时只渲染 `ENABLED=1` 的方案，写入互不相交的 inbound 块，tag 分别为 `inbound-socks` 与 `inbound-vless`。

- 启用 A + B → 一个 config.json 含两个 inbound
- 关闭 A → 仅移除 `inbound-socks` 块，B 完全不受影响

---

## 4. 方案 A：SOCKS5 入站

### 4.1 定位与安全声明

公网开放的 SOCKS5 服务端入口。**必须**启用用户名密码认证。

> **安全风险（需在面板与文档中明示）**：官方文档明确指出 SOCKS 协议不对传输加密，「不适宜经公网中传输」。用户已确认本方案**不加 TLS**（`纯 socks 明文`）。因此 SOCKS5 用户名/密码与代理流量在公网上均为明文，仅能提供访问控制，不能提供保密性。面板在启用时必须一次性告警，用户确认后方可继续。

### 4.2 暴露的参数

| 参数 | 状态键 | 校验规则 |
|---|---|---|
| 启用 | `PROXY_SOCKS_ENABLED` | 布尔 |
| 监听地址 | `PROXY_SOCKS_LISTEN` | IPv4/IPv6 字面量，默认 `0.0.0.0` |
| 端口 | `PROXY_SOCKS_PORT` | 1–65535，且不与方案 B 端口冲突 |
| 用户名 | `PROXY_SOCKS_USER` | 非空，≥1 字符 |
| 密码 | `PROXY_SOCKS_PASS` | 非空，≥8 字符，**不可等于用户名** |
| UDP | `PROXY_SOCKS_UDP` | 默认 0（关闭） |

### 4.3 生成的 JSON

字段依据 `config/inbounds/socks`：

```json
{
  "tag": "inbound-socks",
  "listen": "<listen>",
  "port": <port>,
  "protocol": "socks",
  "settings": {
    "auth": "password",
    "users": [
      { "user": "<user>", "pass": "<pass>" }
    ],
    "udp": false
  }
}
```

**关键约束**：`auth` 必须为 `"password"`。默认值 `"noauth"` 在公网场景下禁止使用，用户亦已明确要求必须输入用户名密码。

`streamSettings` 不写入（本方案无传输层配置）。

**关于 `udp`**：文档指出 SOCKS 未启用 XUDP 时，UDP 流量会改走协议原生 UDP 路径，绕过已配置的传输方式。由于本方案无传输层，UDP 无法获得任何保护。默认关闭 UDP；若用户开启，需在面板提示其不受传输安全保护。

### 4.4 IPv4/IPv6 双栈

- `listen` 为 `0.0.0.0` 时仅 IPv4；为 `::` 时同时监听 v4/v6
- 面板需说明：若监听 `::` 且需仅 IPv6，按文档须设 `sockopt.V6Only: true`
- **UDP 注意事项**（文档明确）：若入站基于 UDP 且网卡存在多个 IP 而外部连接的是非首选地址，Xray 会错误使用首选地址作为源地址回复，导致连接不通。NAT/多 IP 机型上启用 UDP 时，面板须提示此风险。

---

## 5. 方案 B：VLESS + XHTTP + TLS（支持过 CDN）

### 5.1 定位

面向 CDN 穿透的公网入口。XHTTP 依据文档描述「支持三种模式（packet-up / stream-up / stream-one），可穿透绝大多数支持 HTTP 的中间盒（CDN / 反代），并原生支持 QUIC H3 过 CDN」。

### 5.2 暴露的参数（仅 6 项核心）

用户已确认只暴露核心项，`extra` 内其余二十余字段一律使用文档默认值、不写入配置。

| 参数 | 状态键 | 校验规则 |
|---|---|---|
| 启用 | `PROXY_VLESS_ENABLED` | 布尔 |
| 监听地址 | `PROXY_VLESS_LISTEN` | IPv4/IPv6 字面量，默认 `0.0.0.0`，语义同 §4.4 |
| 域名 | `PROXY_VLESS_DOMAIN` | 非空合法域名（用于 SNI / CDN 回源） |
| 端口 | `PROXY_VLESS_PORT` | 1–65535，不与方案 A 端口冲突 |
| UUID | `PROXY_VLESS_UUID` | 非空字符串（文档：可小于 30 字节的字符串或合法 UUID） |
| path | `PROXY_VLESS_PATH` | 默认 `/` |
| mode | `PROXY_VLESS_MODE` | 枚举 `auto`\|`packet-up`\|`stream-up`\|`stream-one`，默认 `auto` |
| 证书来源 | `PROXY_VLESS_CERT_SOURCE` | 枚举 `user`（用户提供）\|`acme`（面板申请） |

### 5.3 mode 的语义差异（面板须向用户解释）

依据文档，服务端 `"auto"` 默认**同时接受三种模式**；若设为具体模式则仅接受它（`stream-up` 例外——它还接受 `stream-one`）。

| 模式 | 上行 | 下行 | 兼容性 | 适用 |
|---|---|---|---|---|
| `packet-up` | 分包 POST | 流式 GET | 最高 | 穿透各种 CDN / 中间盒 |
| `stream-up` | 流式 POST | 流式 GET | 高 | TLS H2 过 CDN、REALITY |
| `stream-one` | 流式 POST 请求体 | 同一 POST 响应体 | 中 | REALITY、支持双向流式的中间盒 |

面板建议：过 CDN 优先 `packet-up`（兼容性最强）；文档另提示「连不上 CF，启用 CF 面板内的 gRPC 支持」。

### 5.4 证书

两种来源（用户已确认两者都要）：

**`user` — 用户提供已签发证书**
- 面板读取 `certificateFile` / `keyFile` 路径
- 校验：两文件均存在且可读
- 过 CDN 场景下证书须为该域名的有效证书（自签证书不会被 CDN 边缘接受）

**`acme` — 面板一键申请**
- 集成 acme.sh（官方文档在 TLS 页提及「可以使用工具便捷的获取免费第三方证书,如 acme.sh」）
- **不自动执行**，仅在用户显式进入子菜单时触发（低配约束，见 §7）
- 申请与续期失败不得影响已有配置的运行

### 5.5 生成的 JSON

字段依据 `config/inbounds/vless`、`config/transport`、`config/transports/xhttp`、`config/transports/tls`：

```json
{
  "tag": "inbound-vless",
  "listen": "<listen>",
  "port": <port>,
  "protocol": "vless",
  "settings": {
    "users": [
      {
        "id": "<uuid>",
        "level": 0
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "method": "xhttp",
    "xhttpSettings": {
      "path": "<path>",
      "mode": "<mode>"
    },
    "security": "tls",
    "tlsSettings": {
      "serverName": "<domain>",
      "alpn": ["h2", "http/1.1"],
      "minVersion": "1.2",
      "maxVersion": "1.3",
      "certificates": [
        {
          "usage": "encipherment",
          "certificateFile": "<cert path>",
          "keyFile": "<key path>"
        }
      ]
    }
  }
}
```

**字段依据说明**：

- `method: "xhttp"` —— 依据 `config/transport` 的 StreamSettingsObject
- **不写 `extra`** —— 文档明确「extra 应由服务发布者直接下发给客户端，不应让客户端随意改」，且 `extra` 存在时只有四项生效。本方案只暴露四项中的三项，`extra` 一律省略，由文档默认值生效
- `decryption: "none"` —— 文档明确「不能留空，禁用需显式设置为 "none"」
- **不写 `flow`** —— 文档说明 XTLS 仅在 `TCP+TLS/REALITY` 下可用；XHTTP 为 HTTP 类传输，不属该组合，故不设 `flow: "xtls-rprx-vision"`
- **不写 `mux`** —— 文档警告「使用 XHTTP 时不要启用 mux.cool，新版 Xray 服务端已有检查，只接受纯 XUDP」
- `alpn` 默认 `["h2","http/1.1"]` —— 文档标注的默认值
- 证书 `usage` 默认 `encipherment` —— 文档标注的默认值
- 证书热重载由内核每 3600 秒自动完成，无需干预
- **不写 `email`** —— 用户已确认不暴露该字段。需注意其副作用：文档指出「如果对应用户没有指定 Email，则不会开启统计」，且本方案不开 `stats`（见 §10.6），故无影响。仅 `level: 0` 为必需默认值（文档：用于套用 policy 策略，本方案写入 `bufferSize: 4`）

### 5.6 过 CDN 的配套提示

面板在方案 B 配置完成后，应依据文档给出提示：

- **客户端与服务端 path 必须一致**
- 客户端 `alpn` 可选 `"h3"` 以使用 QUIC
- **CDN 优选 IP 场景**：客户端 `address` 填 IP，`serverName`(SNI) 填域名
- **连不上 Cloudflare**：需在 CF 面板内启用 gRPC 支持
- **Nginx 无法转发流式上行**：使用 `grpc_pass` 而非普通 `proxy_pass`
- **其他 CDN / 反代不兼容**：将 `mode` 改为 `packet-up`
- **长连接被 CDN 掐断**：XHTTP 的传输层保活不足以依赖，需为 SSH 等长连接配置应用层保活（文档明确警告）

---

## 6. 子系统 A：Xray 内核管理（预览版）

### 6.1 现状与依据

`lib/xray.sh:23` 固定使用官方安装脚本 `install-release.sh`，且以默认参数调用（`xray.sh:168`、`xray.sh:173`），因此只能装到 GitHub 标记为 Latest 的版本。

核对官方 `install-release.sh` 确认其已内置预览版支持：

- `--beta` 参数 → 置 `BETA=1`，最终 `INSTALL_VERSION="$PRE_RELEASE_LATEST"`（对应 `PRE_RELEASE_LATEST` 由 releases 列表中匹配 `Xray-linux-<MACHINE>.zip` 的首个 tag 得出）
- `--version <tag>` 参数 → 显式指定版本
- `--without-geodata`、`--without-logfiles`、`-f/--force` 等现有参数

因此**无需自行拼接下载 URL**，直接透传官方参数即可。

### 6.2 暴露的能力

| 能力 | 实现 |
|---|---|
| 安装最新版 | 官方脚本，默认参数 |
| **安装/更新到预览版** | 官方脚本 `--beta` |
| 安装指定版本 | 官方脚本 `--version <tag>` |
| 切换版本通道 | state 记录 `XRAY_CHANNEL=stable\|preview\|pinned` + `XRAY_PINNED_VERSION` |
| 跳过地理数据 | 传 `--without-geodata`（低配省空间，见 §7） |
| 查看当前版本 | `xray version` |

**默认通道选择**：本项目要求预览版，故 `XRAY_CHANNEL` 默认 `preview`。

### 6.3 保留能力

以下现有能力保留：systemd drop-in（`20-xmg.conf`，优先级高于官方 `10-donot_touch_single_conf.conf`）、服务生命周期、配置校验 `xray run -test`、诊断。

---

## 7. 低配机型适配（0.5C/215M）

### 7.1 已确认采纳的处置

| 操作 | 问题 | 处置 |
|---|---|---|
| `curl` 下载内核 zip | 二进制 ~20MB+，解压峰值内存可能超 215MB | 保留官方脚本；安装前做内存体检，不足时告警 |
| 自动申请证书 | DNS 校验跑 acme.sh，耗时且吃内存 | **改为手动子菜单**，绝不自动触发 |
| YABS / 融合怪 / iperf | 外部脚本，215M 易 OOM 且拉长安装 | **移出自动流程**，仅保留在「外部工具」手动入口 |
| 一键 BBR / FQ | 本身开销小，但改全局 sysctl | 保留手动触发，不自动 |
| vnstat / 磁盘清理 | 轻量 | 保留 |
| `tune.sh` 内存分档 | **现状已按 `MemTotal` 分档**（`≤512MB`/`≤2GB`/`>2GB`），conntrack 与 TCP 缓冲已随内存缩放 | **不重构**，本轮不动 |

### 7.2 bufferSize 统一写入 4

**决策**（用户确认）：显式写入 `policy.levels["0"].bufferSize = 4`，不依赖 Xray 的平台默认值。

**理由**：`config/policy` 文档标注 `bufferSize` 默认值在 ARM/MIPS 为 `0`、ARM64/MIPS64 为 `4`、**其他平台为 `512`**（单位 KB）。KVM x86 机型上默认值会为每条连接分配 512KB 缓存池，0.5C/215M 机器上数条并发即造成压力。统一写入 4 可使内存开销与架构无关。

该值为全局内存预留，各方案共用：

```json
{
  "policy": {
    "levels": {
      "0": {
        "bufferSize": 4
      }
    }
  }
}
```

**注意**：`policy` 中 JSON 对象的键为字符串形式的数字，`"0"` 的双引号不可省略（文档明确说明这是 JSON 要求）。

### 7.3 架构识别

面板需通过 `uname -m` 识别架构并在诊断中展示，覆盖：x86_64、aarch64（ARM64）、armv7l（ARM）、mips / mips64 / mips64le 等，适配 KVM / OpenVZ / NAT 各类机型。

架构信息同时用于：
- 诊断输出
- 提示 Xray 平台默认 `bufferSize` 的差异（尽管本方案统一写 4）
- acme.sh 证书签发时的算法选择

### 7.4 安装内存体检

安装流程中，于下载内核前读取 `/proc/meminfo` 的 `MemTotal`，结合 `XMG_TUNE_SYSCTL_SWAP_CONF` 检查 swap 是否存在。当可用内存低于阈值时给出明确告警而非静默继续。

---

## 8. NAT 机型与双栈

### 8.1 NAT 适配

**决策**：检测到无独立公网 IPv4 时，在 `status` 与诊断中**明确提示但不阻断操作**。

提示内容需区分两个方案的实际可达性：

- **方案 A（SOCKS5）**：NAT 机上公网不可达，**须由服务商做端口映射**方可使用
- **方案 B（VLESS+XHTTP+TLS 过 CDN）**：可用 —— CDN 负责对外入口，回源由 CDN 发起

面板不应隐藏方案 A，因为部分 NAT 机型确实提供端口映射；仅提示其前置条件。

### 8.2 IPv4 / IPv6 双栈

面板在两方案中均需支持 `listen` 为 IPv4、IPv6 或双栈：

| listen | 效果 |
|---|---|
| `0.0.0.0` | 仅 IPv4 |
| `::` | 同时监听 IPv6 与 IPv4（文档：两者等价） |
| `::` + `sockopt.V6Only: true` | 仅 IPv6（文档明确：仅支持 Linux） |

方案 B 的 CDN 场景下，面板须提示：客户端 `address` 可填优选 IP，`serverName`(SNI) 仍填域名。

---

## 9. 交互设计

### 9.1 状态回显

`xmg proxy status` 输出需包含：

- 内核：当前版本、通道（stable/preview/pinned）
- 方案 A：启用状态、监听地址与端口、认证用户名（**密码不显示**）、UDP 状态
- 方案 B：启用状态、监听地址与端口、域名、path、mode、证书来源与到期时间
- 生效的 config.json 路径与最近一次校验结果
- DNS：Xray 内置上游（2 个 DOHL 地址）与 `queryStrategy` 取值；系统层当前 DNS 来源（resolved drop-in / resolv.conf）

### 9.2 输入校验与错误呈现

针对「报错不直观」痛点：

- **即时校验**：每个字段在输入后立刻校验，不等提交
- **错误信息格式**：统一为「字段名 + 问题 + 建议」，例如
  `端口 443 已被方案 A 占用，请为方案 B 选择其他端口`
- **shellcheck 友好**：错误输出统一走 stderr，避免污染管道
- 端口冲突检测需在**配置阶段**而非启动失败时才发现

### 9.3 非交互 CLI

所有能力必须可脚本化，示例：

```bash
# 应用配置（声明式，幂等）
xmg proxy apply --socks on --socks-port 1080 \
                --socks-user u --socks-pass 'p' \
                --vless on --vless-port 443 \
                --vless-domain example.com --vless-uuid <uuid>

# 从文件应用
xmg proxy apply --file /path/to/state.env

# 导出当前状态
xmg proxy status --json

# 停用某方案（不触碰另一方案）
xmg proxy disable socks

# 内核
xmg core update --channel preview
xmg core install --version v25.x.x
```

设计要求：
- 所有 CLI 命令**幂等**，可安全重复执行
- `--json` 输出供脚本消费
- 退出码明确：0 成功，非 0 失败（校验失败与运行失败需可区分）

### 9.4 交互菜单

菜单作为 CLI 的等价前端，调用同一套 state 函数，不重复实现逻辑。

沿用现有 `menu.sh` 的模块发现机制（`xmg.files` 清单 + `# XMG_MENU_LABEL:` 自声明 + `xmg_<name>_menu` 函数约定），新增模块接入无需改动 `menu.sh`。

---

## 10. 原子写入与错误处理

### 10.1 写入流程

任何配置变更（无论来自菜单还是 CLI）必须走同一条路径：

1. 读取当前 state
2. 应用变更到内存中的新 state
3. **schema 校验**新 state（端口范围、UUID 非空、路径端口不冲突、证书文件可读）
4. **渲染**为完整 `config.json` 到临时文件
5. **内核校验**：`xray run -test -c <tmp>`
6. 校验失败 → 删除临时文件，**运行中的配置不受任何影响**，返回明确错误
7. 校验成功 → 备份旧 `config.json` 到 `$XMG_BACKUP_DIR`，并执行备份清理（§10.4）
8. 原子替换 `config.json`
9. 写回 state
10. `systemctl reload xray`（失败则回滚 config 与 state）

**核心不变量**：配置永远不会是半成品。低配机型上服务被打断的代价很高，因此任一步失败都必须保持原有可用状态。

### 10.2 错误分类

| 类别 | 退出码 | 含义 |
|---|---|---|
| 校验失败 | 2 | 用户输入问题，配置未变更 |
| 内核校验失败 | 3 | 生成的 JSON 不被内核接受，配置未变更 |
| 运行失败 | 4 | reload 失败，已回滚 |

### 10.3 日志

`log` 配置写入 config.json，依据文档：

- `access`：`none`（低配机器不做访问日志，避免磁盘与 IO 压力）
- `error`：写入 `$XMG_LOG_DIR/xray/error.log`
- `loglevel`：`warning`（文档默认值）
- `maskAddress`：支持 `quarter`/`half`/`full`，分享日志时保护 IP 隐私

### 10.4 备份自动清理

用户已确认自动清理。低配机器磁盘有限，备份不可无限累积。

**清理策略**：

- 备份文件名沿用现有 `xmg_timestamp()` 格式：`<base>.<YYYYmmdd-HHMMSS>.bak`
- **保留上限**：`XMG_BACKUP_KEEP`，默认 **5**（份）
- 清理时机：每次成功创建新备份**之后**，仅针对 `config.json.*.bak` 这一类
- 清理方式：按时间戳倒序排序，删除第 N 份及更早的
- 清理失败（权限/只读文件系统）**不得阻断主流程**，仅告警
- 保留策略同时记入 state（`XMG_BACKUP_KEEP`），便于用户调整

**安全约束**：清理必须**严格限定**在 `$XMG_BACKUP_DIR` 内，且只匹配 `config.json.*.bak`。不得使用跨目录通配（低配机 BusyBox/GNU find 差异易踩坑）。为避免误删，state 与 `config.json` 的备份**不参与**本清理（由各自模块管理）。

### 10.5 DNS 配置（两层）

用户确认：服务器位于海外，DNS 需安全配置。采用**两层**结构。

#### 10.5.1 为何分两层

| 层 | 作用 | 归属|
|---|---|---|
| 系统层 | 操作系统级域名解析（apt、acme.sh 等外部工具依赖） | 复用 `tune.sh` 已有能力 |
| Xray 内置层 | Xray 内部解析，防污染、防篡改 | 本 spec 新增，写入 config.json |

两者独立：即使Xray 层未启用，系统层仍保护面板自身的外部工具调用。

#### 10.5.2 Xray 内置层设计

**选用 DOHL 模式**，依据文档明确表述：

> 当值是 "https+local://host:port/dns-query" 的形式…即 DOH 请求不会经过路由组件，直接通过 Freedom outbound 对外请求，以降低耗时。**一般适合在服务端使用**。

**为何不用 `localhost`**：文档明确「当使用 localhost 时，本机的 DNS 请求不受 Xray 控制，需要额外的配置才可以使 DNS 请求由 Xray 转发」。本方案要求 DNS 完全由 Xray 管理，故不使用 `localhost`。

**为何不写 `hosts` 静态映射**：文档在 local 模式章节提示，由于 local 模式直接由核心向外连接，「如果地址是一个域名将交由系统本身进行解析」。使用 IP 形式的上游（`1.1.1.1` / `8.8.8.8`）可完全避免域名解析，从而规避文档所述的回环问题（回环的完整描述见 `config/sockopt` 的 `domainStrategy` 章节警告）。

**上游选择**（用户确认：Cloudflare + Google）：

| 用途 | 地址 |
|---|---|
| 主 | `https+local://1.1.1.1/dns-query` |
| 备 | `https+local://8.8.8.8/dns-query` |

**使用 IP 形式的依据**（文档原文）：

> 有些服务商拥有 IP 别名的证书，可以直接写 IP 形式，比如 https://1.1.1.1/dns-query

两者均为境外 IP，对海外服务器延迟低，且避免引入任何域名解析依赖。

**关键约束**（文档明确）：全局 `queryStrategy` 值优先。当子项中的 `queryStrategy` 与全局值冲突时，**子项将得到空响应**。因此本方案：

- 全局 `queryStrategy: "UseIP"`（文档默认值，允许查询 A + AAAA）
- **不在任何 server 子项中写 `queryStrategy`**（避免冲突导致空响应）

此约束已在测试断言中固化。

**不启用 `enableParallelQuery`**：文档说明并行查询策略为「动态分组，组内竞速，组间回退」，在仅两个同构上游时收益有限，且增加并发查询的内存占用——与 0.5C/215M 的低配目标相悖。默认 `disableCache: false`（即启用缓存，文档默认值），降低重复查询开销。

**不写 `tag` 到 dns 块**：文档说明该 tag 用于路由 `inboundTag` 匹配，而本方案不启用 `routing`，写了也无匹配对象。

生成的 dns 块：

```json
{
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query"
    ],
    "queryStrategy": "UseIP"
  }
}
```

#### 10.5.3 系统层设计

复用 `tune.sh` 已有能力（`xmg_tune_dns_optimize` / `xmg_tune_dns_dot`），**本spec 不重写**。仅做两处与海外场景相关的调整：

1. **预设默认值改为境外 DNS**：现有 `tune.sh:411-417` 的预设列表中，选项 1-3 为 Cloudflare / Google / Quad9（标注「境外推荐」）。默认指向应选 **Cloudflare（1.1.1.1 / 1.0.0.1）**，而非选项 4 阿里 DNS（标注「境内推荐」）——阿里 DNS 对海外服务器延迟高且可能受污染影响。
2. **DoT 上游同步境外化**：`tune.sh` 的 DoT 预设应与 Xray 内置层保持一致的境外上游，避免系统层与Xray 层解析结果分歧。

**NAT 机型注意**：若系统层 DoT 因NAT 出口受限导致解析失败，`tune.sh` 现有的 DoT 双层回退机制（853 不通自动回退明文 53）已覆盖此场景，无需额外改动。

#### 10.5.4 DNS 相关的验证

集成验证需增加：

- `xray run -test` 通过（验证 dns 块语法与 `https+local://` 前缀被接受）
- 实际启动后 `xmg proxy status` 能展示 DNS 配置摘要
- 方案 A（SOCKS5）启用时，客户端能通过 SOCKS5 正常解析域名（验证 Xray 内置 DNS 生效）

### 10.6 不启用 stats 与 api

用户已确认本轮**不启用**统计与 API：

- **不写 `stats` 块** —— 依据文档「目前统计信息不需要任何参数，只要 StatsObject 项存在，内部的统计即会开启」，不写即关闭
- **不写 `api` 块** —— 依据文档，API 需 gRPC 监听端口；在 NAT 机型上该端口通常不可达，且会增加内存与监听开销
- **不在 `policy` 中设 `statsUserUplink` / `statsUserDownlink` 等统计项**

**连带影响**：`status` 无法展示分用户流量。流量统计改由面板现有的 `vnstat`（系统层网卡级）承担，与 Xray 协议层统计无关。此为明确取舍，非遗漏。

### 10.7 生成的 config.json 顶层结构

完整文件骨架（字段依据见各章节）：

```json
{
  "log": {
    "access": "none",
    "error": "<XMG_LOG_DIR>/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query"
    ],
    "queryStrategy": "UseIP"
  },
  "policy": {
    "levels": {
      "0": {
        "bufferSize": 4
      }
    }
  },
  "inbounds": [
    "<按启用状态渲染 inbound-socks 与 inbound-vless>"
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
```

**说明**：

- 顶层字段顺序：`log` → `dns` → `policy` → `inbounds` → `outbounds`（JSON 对象键顺序无语义要求，此处按阅读顺序排列）
- `inbounds` 为数组，长度随启用方案变化（0 / 1 / 2）
- **无 `stats`、无 `api`、无 `routing`** —— 本轮均不启用
- `outbounds` 仅一个 `freedom` 直连出站。文档说明「列表中的第一个元素作为主 outbound」，路由未匹配时流量由主 outbound 发出
- `freedom` 出站**不配置 `streamSettings`** —— 依据文档「对于 Freedom 这类直接出站，对端通常是任意普通公网目标…此时传输配置不需要（也基本不能）与另一端协商，而是用于控制本地发出连接时的行为，此时只有 sockopt 可用」
- `freedom` 出站的 `settings` 为空 —— 文档中 `domainStrategy` / `redirect` / `userLevel` / `fragment` / `noises` 均为可选，且 `domainStrategy: "AsIs"` 是文档所述的默认行为，故不写入

---

## 11. 测试策略

### 11.1 渲染器单测（无需 VPS）

渲染器为纯函数（state 进、JSON 片段出），可在本机直接测试：

- 对每种参数组合生成 JSON
- 断言生成的字段名与官方文档**逐字一致**（防幻觉）
- 断言**不含**任何文档未提及的字段
- 断言不出现 `network`、`tcpSettings`、`accounts`、`flow` 等已知错误写法
- 断言 `auth` 在方案 A 中恒为 `"password"`
- 断言 `decryption` 恒为 `"none"` 且非空
- 断言方案 B 不生成 `mux` 块
- 断言 `bufferSize` 恒为 `4`
- **断言不含 `email`、`stats`、`api`、`routing` 块**（用户已确认不启用/不暴露）
- **断言 `dns` 块恰含 2 个 server，且均为 `https+local://` 前缀**（§10.5.2）
- **断言 `dns` 块中任何 server 均未写 `queryStrategy`** —— 文档明确全局值优先，冲突将导致空响应
- **断言不含 `localhost` / 纯明文 `8.8.8.8` 形式的上游** —— 前者不受 Xray 控制，后者明文易被污染
- 断言 `outbounds` 恒为单个 `freedom` 且其上无 `streamSettings`

### 11.2 状态层单测

- schema 校验：端口越界、空 UUID、密码等于用户名、端口冲突等各用例
- merge：启用 A+B 生成两个 inbound；关闭 A 后 B 的块逐字不变
- 幂等：同一输入应用两次，state 与 config.json 均不变（diff 为空）

### 11.3 集成验证（需真实环境）

- `xray run -test` 校验生成配置
- 实际启动后 socks5 认证连接成功
- 实际启动后 VLESS+XHTTP+TLS 连接成功
- 端口冲突时正确拒绝且不破坏原配置
- 校验失败时运行中配置保持不变

---

## 12. 目录与文件变更

| 路径 | 变更 |
|---|---|
| `lib/state.sh` | **新增** — state 读写、schema 校验、merge、原子写入 |
| `lib/render.sh` | **新增** — 两个纯函数渲染器 |
| `lib/proxy.sh` | **新增** — 向导、CLI、status |
| `lib/core.sh` | **新增** — 内核管理（从现 `xray.sh` 拆分） |
| `lib/xray.sh` | **改造** — 保留 systemd 与服务生命周期，配置能力迁出 |
| `xmg` | **改造** — 新增 `proxy` / `core` 子命令 |
| `xmg.files` | **修改** — 加入新模块 |
| `/opt/xmg/etc/xray/state.env` | **新增** — 唯一真相来源 |
| `/opt/xmg/etc/xray/schema.sh` | **新增** — 校验规则定义 |

---

## 13. 决策记录

### 13.1 已在正文确定的设计决策（供复核）

| 决策 | 取值 | 依据 |
|---|---|---|
| SOCKS5 认证 | `auth: "password"` 强制，账号密码必填 | 用户确认 + 文档 `inbounds/socks` |
| SOCKS5 传输安全 | 不加 TLS（明文），面板一次性告警 | 用户确认 + 文档明确警告 |
| SOCKS5 `listen` 默认 | `0.0.0.0`（纯 IPv4） | §4.4 规避 NAT 多 IP 下 UDP 回复异常 |
| SOCKS5 UDP 默认 | 关闭 | 无传输层保护，见 §4.3 |
| state 文件位置 | `/opt/xmg/etc/xray/state.env` | 与现有 `$XMG_ETC_DIR` 一致 |
| state 文件格式 | 扁平 `KEY=value`，零依赖读写 | 低配约束，不引入 `jq` |
| 内核默认通道 | `preview`（预览版） | 用户要求 |
| `bufferSize` | 显式写入 `4`（单位 KB） | 用户确认，规避 x86 默认 512 |
| 支持发行版 | 仅 Debian 11/12+、Ubuntu 20.04+ | 用户确认 |
| 方案共存 | 两块独立，端口与 tag 分离 | 用户确认 |
| 方案 B 参数面 | 仅 6 项核心，其余用文档默认值 | 用户确认 |
| 证书来源 | `user` 与 `acme` 两者都提供，均手动触发 | 用户确认 |
| 低配取舍 | 证书/测速改手动、安装加内存体检、不动 `tune.sh` | 用户确认 |
| 备份清理 | 自动清理，保留 5 份（`XMG_BACKUP_KEEP` 可调） | 用户确认 |
| 方案 B `email` | **不暴露**，生成的 JSON 不含该字段 | 用户确认 |
| `stats` / `api` | **均不启用**；流量统计由 `vnstat` 承担 | 用户确认 |
| DNS 分层 | 两层：系统 DoT（复用 `tune.sh`）+ Xray 内置 DOHL | 用户确认 |
| DNS 上游 | `https+local://1.1.1.1/dns-query` + `https+local://8.8.8.8/dns-query`（IP 形式） | 用户确认（Cloudflare + Google） |
| DNS 全局策略 | `queryStrategy: "UseIP"`；子项**一律不写** `queryStrategy` | 文档：全局优先，冲突致空响应 |

### 13.2 已无待确认项

原三项（备份保留策略、`email` 是否暴露、是否开 `stats`/`api`）均已确认，见 §13.1。本 spec 至此无未决问题。
