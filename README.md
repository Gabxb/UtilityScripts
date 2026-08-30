# UtilityScripts

订阅节点处理与自动化工具集：订阅清洗归一化、节点真实可用性探测、SSH 配置、自动同步。

> 本文件由 `scripts/gen_readme.sh` 自动生成，环境信息实时采集，请勿手工编辑。
> 最后更新：**2026-08-30 19:48:28 CST**（仅在环境信息实质变化时刷新，纯时间差异不会产生提交）

## 运行环境

### 时间与时区

| 项目 | 值 |
|---|---|
| 时区 | Asia/Shanghai |
| UTC 偏移 | UTC+08:00 |
| 生成时刻 | 2026-08-30 19:48:28 CST ／ 2026-08-30 11:48:28 UTC |

该环境无 systemd，`timedatectl` 不可用，时区通过符号链接设置：

```bash
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
```

### 系统与硬件

| 项目 | 值 |
|---|---|
| 发行版 | Debian GNU/Linux 12 (bookworm) |
| 内核 | Linux 6.6.116 |
| 架构 | x86_64 |
| 虚拟化 | PID 1 为 `firecracker-ini`（Firecracker microVM，非 Docker） |
| 主机名 | 2c0f95d2-f9c4-4d26-80a8-29d078c26819 |
| CPU | Intel(R) Xeon(R) Processor × 2 核 |
| 内存 | 7.8Gi |
| 磁盘 | 20G（可用 15G） |

### 网络

本机为**双线分流**：境内与境外目标走不同出口，分流由上游网关决定（本机只有一个默认网关 `192.168.16.1`，无法自行选路）。

**境内线路出口** — `curl cip.cc`

| 项目 | 值 |
|---|---|
| 出口 IP | `123.56.157.253` |
| 归属地 | 中国 北京 北京 |
| 运营商 | 阿里云 |

**境外线路出口** — `curl https://api.ip.sb/geoip`

| 项目 | 值 |
|---|---|
| 出口 IP | `42.200.172.140` |
| 反向解析 | 42-200-172-140.static.imsbiz.com |
| 归属地 | Hong Kong · Central and Western · Central |
| ISP | Netvigator |
| AS | AS4760 HKT Limited |
| IP 时区 | Asia/Hong_Kong |

**内网**

| 项目 | 值 |
|---|---|
| eth0 | `169.254.169.252/30` |
| 默认网关 | `192.168.16.1` |
| DNS | `192.168.16.1` |

### 实测出站限制

以下限制均经对照实验确认，直接决定了探活脚本的设计：

| 协议 / 目标 | 状态 | 判定依据 |
|---|---|---|
| ICMP | **完全禁止** | `8.8.8.8`、`1.1.1.1` 均 100% 丢包，与保留地址 `192.0.2.1` 无差异 |
| TCP 22（GitHub） | **被拦截** | `kex_exchange_identification: Connection closed`，改走 `ssh.github.com:443` |
| TCP connect | **结果不可信** | 保留地址 `192.0.2.1:12345` 也返回连接成功，上游有透明代理应答 SYN |
| HTTPS 443 | 正常 | 任意端口出站可用 |
| google / youtube | 可达 | 走境外线路，HTTP 200 约 0.8 s |
| facebook / twitter | 超时 | 环境自身出站策略，与 GFW 无关 |

所以节点可用性只能靠**完整协议握手 + 真实 HTTP 请求**验证，ICMP 与 TCP 层探测在此环境全部无效。

境内线路虽然存在，但**不能用来测 GFW** —— 分流由上游按目标 IP 决定，境外节点的连接必然走香港线路。

### 已安装工具

| 工具 | 版本 | 用途 |
|---|---|---|
| git | 2.39.5 | 版本控制与自动同步 |
| python3 | 3.11.2 | 订阅解析与流水线 |
| sing-box | 1.13.20 | 探活主引擎（vless/trojan/ss/hysteria2） |
| Xray-core | 26.3.27 | 探活第二引擎（xhttp、Reality 原生） |
| OpenSSH | OpenSSH_9.2p1 | SSH 推送 |
| OpenSSL | 3.0.19 | TLS 握手检测 |
| curl | 7.88.1 | 出口 IP 探测 |
| cron | 3.0pl1-162 | 定时同步（守护进程需手动拉起） |

## 仓库内容

| 文件 | 行数 | 说明 |
|---|---|---|
| `scripts/subs_pipeline.py` | 197 | 流水线入口：汇总 → 清洗 → 命名 → 探活 → 输出 |
| `scripts/normalize_subs.py` | 452 | 解析、去广告、去重、国家识别（170+ 地区词、旗帜 emoji） |
| `scripts/probe_nodes.py` | 539 | 双引擎探活，取真实出口 IP 与归属国家 |
| `scripts/auto_sync.sh` | 340 | 幂等自动同步到 GitHub，本地优先，支持 cron |
| `scripts/gen_readme.sh` | 305 | 生成本文件，环境信息实时采集 |
| `scripts/github-ssh-push.sh` | 439 | SSH/GPG 密钥生成、展示、验证与推送 |

| 数据文件 | 规模 |
|---|---|
| `sub.md` | 565 行原始订阅（多来源拼接，含大量重复） |
| `sub.txt` | 212 个唯一节点，按国家码编号 |
| `sub_alive.txt` | 115 个探活确认可用的节点 |

## 快速开始

```bash
# 完整流水线：清洗 + 探活 + 输出
python3 scripts/subs_pipeline.py sub.md

# 只清洗不探活（秒级完成）
python3 scripts/subs_pipeline.py sub.md --no-probe

# 单独探活任意订阅
python3 scripts/probe_nodes.py sub.txt --alive alive.txt --report report.tsv

# 自动同步
bash scripts/auto_sync.sh                     # 同步一次
bash scripts/auto_sync.sh --install-cron 30   # 每 30 分钟自动同步
bash scripts/auto_sync.sh --dry-run           # 预演
```

### 命名规则

节点统一命名为 `国家码 + 序号`（`US1` `US2` `HK1`），国家判定优先级：

1. **探活实测的真实出口国家** — 唯一可靠依据
2. GeoIP 查询节点地址归属
3. 节点名中的旗帜 emoji、中英文地区词、已有国家码前缀
4. 域名首段提示（如 `jp3.example.com`）

实测中订阅原标注准确率约 57%，故默认以实测出口为准。

## 注意事项

- 探活结果反映**境外线路出口（42.200.172.140）**到节点的连通性，不代表中国大陆可达性
- 探活并发上限为 3，超过后代理连接会被关闭，导致健康节点被误判
- 回显服务必须用 HTTPS，明文 HTTP 会被部分节点出口拦截返回 400 页面
- `sub_report.tsv` 含节点真实出口 IP，默认不纳入版本控制

---

<div align="center">

```
   ▄▄▄       ██▓▓██   ▓██   ██▓
  ▒████▄    ▓██▒▒██▒   ▒██  ██▒
  ▒██  ▀█▄  ▒██▒▒██░    ▒██ ██░
  ░██▄▄▄▄██ ░██░▒██░    ░ ▐██▓░
   ▓█   ▓██▒░██░░██████▒░ ██▒▓░
   ▒▒   ▓▒█░░▓  ░ ▒░▓  ░  ██▒▒▒
    ▒   ▒▒ ░ ▒  ░ ░ ▒  ░▓██ ░▒░
    ░   ▒    ▒  ░   ░   ▒ ▒ ░░
        ░  ░ ░      ░  ░░ ░
                        ░ ░
```

**A I Y**

</div>
