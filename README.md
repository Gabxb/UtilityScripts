# UtilityScripts

订阅节点处理与自动化工具集：订阅清洗归一化、节点真实可用性探测、SSH 配置、自动同步。

> 本文件由 `scripts/gen_readme.sh` 自动生成，环境信息实时采集，请勿手工编辑。
> 最后更新：**2026-09-11 06:43:07 CST**（仅在环境信息实质变化时刷新，纯时间差异不会产生提交）

## 运行环境

### 时间与时区

| 项目 | 值 |
|---|---|
| 时区 | Asia/Shanghai |
| UTC 偏移 | UTC+08:00 |
| 生成时刻 | 2026-09-11 06:43:07 CST ／ 2026-09-10 22:43:07 UTC |

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

当前出口 `123.56.157.253`（中国 北京 北京 ／ 阿里云）。累计观察到 **1** 个不同 IP，全部列出：

| 出口 IP | 归属地 | 运营商 | 首次观察 | 最近观察 |
|---|---|---|---|---|
| `123.56.157.253` | 中国 北京 北京 | 阿里云 | 2026-08-30 | 2026-09-11 |

**境外线路出口** — `curl https://api.ipify.org` 取 IP，`ip-api.com` 查归属

境外是一个**轮换代理池**，每个请求都可能换一个地址，跨多个 AS 与地区，连 `/24` 前缀都不固定。累计观察到 **15** 个不同 IP，全部列出：

| 出口 IP | 归属地 | AS | 首次观察 | 最近观察 |
|---|---|---|---|---|
| `42.200.172.140` | Hong Kong · Central and Western · Central | AS4760 HKT Limited | 2026-08-30 | 2026-08-30 |
| `45.62.172.81` | Hong Kong · Yau Tsim Mong · Tsim Sha Tsui | AS138997 Eons Data Communications Limited | 2026-09-07 | 2026-09-10 |
| `45.62.172.83` | Hong Kong · Yau Tsim Mong · Tsim Sha Tsui | AS138997 Eons Data Communications Limited | 2026-09-07 | 2026-09-07 |
| `103.156.242.194` | Taiwan · Taiwan · Taipei | AS41378 Kirino LLC | 2026-09-07 | 2026-09-07 |
| `103.156.242.196` | Taiwan · Taiwan · Taipei | AS41378 Kirino LLC | 2026-09-07 | 2026-09-07 |
| `103.156.242.197` | Taiwan · Taiwan · Taipei | AS41378 Kirino LLC | 2026-09-07 | 2026-09-07 |
| `212.107.28.50` | Hong Kong · Kowloon · Hong Kong | AS41378 Kirino LLC | 2026-09-07 | 2026-09-07 |
| `212.107.28.51` | Hong Kong · Kowloon · Hong Kong | AS41378 Kirino LLC | 2026-09-07 | 2026-09-07 |
| `212.107.28.55` | Hong Kong · Kowloon · Hong Kong | AS41378 Kirino LLC | 2026-09-07 | 2026-09-07 |
| `212.107.28.56` | Hong Kong · Kowloon · Hong Kong | AS41378 Kirino LLC | 2026-09-07 | 2026-09-09 |
| `212.107.28.57` | Hong Kong · Kowloon · Hong Kong | AS41378 Kirino LLC | 2026-09-07 | 2026-09-07 |
| `212.107.28.58` | Hong Kong · Kowloon · Hong Kong | AS41378 Kirino LLC | 2026-09-07 | 2026-09-07 |
| `212.107.29.67` | Hong Kong · Kowloon · Hong Kong | AS41378 Kirino LLC | 2026-09-07 | 2026-09-07 |
| `212.107.29.70` | Hong Kong · Kowloon · Hong Kong | AS41378 Kirino LLC | 2026-09-07 | 2026-09-07 |
| `103.156.242.195` | Taiwan · Taiwan · Taipei | AS41378 Kirino LLC | 2026-09-11 | 2026-09-11 |

| 汇总 | 值 |
|---|---|
| 覆盖国家 / 地区 | Hong Kong、Taiwan |
| 覆盖 AS | `AS138997 Eons Data Communications Limited`、`AS41378 Kirino LLC`、`AS4760 HKT Limited` |
| 观察起始 | 2026-08-30 |

存档在 `.egress_pool.tsv` 与 `.egress_pool_cn.tsv`（本地累计，不入库；上表由脚本从存档渲染）。

**内网**

| 项目 | 值 |
|---|---|
| eth0 | `169.254.169.252/30` `192.168.20.159/20` |
| 默认网关 | `192.168.16.1` |
| DNS | `192.168.16.1` |

### 实测出站限制

以下限制均经对照实验确认，直接决定了探活脚本的设计：

| 协议 / 目标 | 状态 | 判定依据 |
|---|---|---|
| ICMP | **完全禁止** | `8.8.8.8`、`1.1.1.1` 均 100% 丢包，与保留地址 `192.0.2.1` 无差异 |
| TCP connect | **结果不可信** | 保留地址 `192.0.2.1:12345` 也返回连接成功，上游有透明代理应答 SYN |
| TCP 22（GitHub） | 可用 | `ssh -T git@github.com` 认证成功，早期被拦截的情况已不复现 |
| TCP 443（ssh.github.com） | 认证失败 | 端口通，但该 host 未配对应 key，报 `Permission denied (publickey)` |
| HTTPS 443 | 部分可用 | 出站端口不受限，但个别站点在 TLS 握手阶段被打断 |
| google / youtube | 可达 | 走境外线路，HTTP 200 约 0.3～0.5 s |
| facebook / twitter | **TLS 握手被打断** | `SSL_ERROR_SYSCALL`，非超时；环境自身出站策略 |
| api.ip.sb / api.myip.com | **TLS 握手被打断** | 同上，故 geoip 改用 `ip-api.com` 明文接口 |

所以节点可用性只能靠**完整协议握手 + 真实 HTTP 请求**验证，ICMP 与 TCP 层探测在此环境全部无效。

境内线路虽然存在，但**不能用来测 GFW** —— 分流由上游按目标 IP 决定，境外节点的连接必然走境外线路。

境外出口是轮换池，同一节点在不同时刻可能经由不同国家、不同 AS 的出口去连接，探活结果因此存在天然抖动，比较跨天的 `sub_alive.txt` 时需留意这一点。

### 已安装工具

| 工具 | 版本 | 用途 |
|---|---|---|
| git | 2.39.5 | 版本控制与自动同步 |
| python3 | 3.11.2 | 订阅解析与流水线 |
| sing-box | 1.13.20 | 探活主引擎（vless/trojan/ss/hysteria2） |
| Xray-core | 26.3.27 | 探活第二引擎（xhttp、Reality 原生） |
| OpenSSH | OpenSSH_9.2p1 | SSH 推送 |
| OpenSSL | 3.0.20 | TLS 握手检测 |
| curl | 7.88.1 | 出口 IP 探测 |
| cron | 3.0pl1-162 | 定时同步（每天一次；重启后用 `pgrep -x cron` 确认） |

## 仓库内容

| 文件 | 行数 | 说明 |
|---|---|---|
| `scripts/subs_pipeline.py` | 197 | 流水线入口：汇总 → 清洗 → 命名 → 探活 → 输出 |
| `scripts/normalize_subs.py` | 452 | 解析、去广告、去重、国家识别（170+ 地区词、旗帜 emoji） |
| `scripts/probe_nodes.py` | 539 | 双引擎探活，取真实出口 IP 与归属国家 |
| `scripts/auto_sync.sh` | 461 | 幂等自动同步到 GitHub，本地优先，支持 cron |
| `scripts/gen_readme.sh` | 422 | 生成本文件，环境信息实时采集 |
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
bash scripts/auto_sync.sh --install-cron 1440 # 每天自动同步一次（当前配置）
bash scripts/auto_sync.sh --uninstall-cron    # 停掉定时同步
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

- 探活结果反映**境外轮换出口**到节点的连通性，不代表中国大陆可达性；出口每次请求都可能变化，跨天结果不可直接对比
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
