#!/usr/bin/env bash
#
# 生成 README.md：环境信息全部实时采集，不手工维护
#
# 设计要点：
#   · 只写稳定信息 —— 运行时长、内存已用率这类每分钟都变的指标一律不写，
#     否则每次 cron 都产生一个只有数字差异的提交，把历史刷成噪音
#   · 采集失败时沿用旧值 —— 出口 IP 查询超时不能让 README 出现空白
#   · 幂等 —— 实质内容没变时不动文件，交给 auto_sync 判断是否需要提交
#
# 用法：
#   bash scripts/gen_readme.sh            # 生成/更新 README.md
#   bash scripts/gen_readme.sh --stdout   # 只打印，不写文件
#
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

readonly REPO_DIR="${GEN_README_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly TARGET="${REPO_DIR}/README.md"
TO_STDOUT=0
[[ "${1:-}" == "--stdout" ]] && TO_STDOUT=1

cd "$REPO_DIR"

# 从现有 README 里取回某个字段的旧值，供采集失败时兜底
old_value() {
  local pattern="$1"
  [[ -f "$TARGET" ]] || return 0
  grep -oE "$pattern" "$TARGET" 2>/dev/null | head -1 || true
}

# 带超时的取值，失败返回空
try() { timeout "${1}" bash -c "${2}" 2>/dev/null || true; }

# ---------------------------------------------------------------- 采集
STAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
UTC_STAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
TZ_NAME=$(readlink -f /etc/localtime | sed 's#.*/zoneinfo/##')
TZ_OFFSET=$(date '+%:z')

OS_NAME=$(grep -oP '(?<=^PRETTY_NAME=").*(?="$)' /etc/os-release 2>/dev/null || echo unknown)
KERNEL=$(uname -sr)
ARCH=$(uname -m)
HOSTNAME_V=$(hostname)
PID1=$(cat /proc/1/comm 2>/dev/null || echo unknown)
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs || echo unknown)
CPU_CORES=$(nproc)
MEM_TOTAL=$(free -h | awk '/^Mem:/{print $2}')
DISK_TOTAL=$(df -h / | awk 'NR==2{print $2}')
DISK_AVAIL=$(df -h / | awk 'NR==2{print $4}')
LAN_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2; exit}')
GATEWAY=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
DNS_SRV=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf | xargs)

# 境内线路：cip.cc 是文本格式，取 IP 与地址行
CN_RAW=$(try 15 'curl -sS --max-time 12 cip.cc')
CN_IP=$(printf '%s' "$CN_RAW" | awk -F': *' '/^IP/{print $2; exit}' | xargs || true)
CN_LOC=$(printf '%s' "$CN_RAW" | awk -F': *' '/^地址/{print $2; exit}' | xargs || true)
CN_ISP=$(printf '%s' "$CN_RAW" | awk -F': *' '/^运营商/{print $2; exit}' | xargs || true)
[[ -z "$CN_IP" ]] && CN_IP=$(old_value '123\.[0-9.]+|(?<=境内线路出口 \| `)[0-9.]+')
: "${CN_IP:=采集失败}" "${CN_LOC:=采集失败}" "${CN_ISP:=采集失败}"

# 境外线路：ip.sb 返回 JSON，一次拿全
OS_RAW=$(try 20 'curl -sS --max-time 15 https://api.ip.sb/geoip')
jget() { printf '%s' "$OS_RAW" | grep -oE "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
OV_IP=$(jget ip); OV_CITY=$(jget city); OV_REGION=$(jget region)
OV_COUNTRY=$(jget country); OV_ISP=$(jget isp); OV_ASORG=$(jget asn_organization)
OV_TZ=$(printf '%s' "$OS_RAW" | grep -oE '"timezone":"[^"]*"' | cut -d'"' -f4 | sed 's#\\/#/#g')
OV_ASN=$(printf '%s' "$OS_RAW" | grep -oE '"asn":[0-9]+' | grep -oE '[0-9]+')
[[ -z "$OV_IP" ]] && OV_IP=$(old_value '42\.200\.[0-9.]+')
OV_PTR=$(try 10 "getent hosts ${OV_IP} | awk '{print \$2}'")
: "${OV_IP:=采集失败}" "${OV_ISP:=未知}" "${OV_ASORG:=未知}" "${OV_TZ:=未知}"
OV_LOC=$(printf '%s' "${OV_COUNTRY:-} · ${OV_REGION:-} · ${OV_CITY:-}" | sed 's/ · $//; s/^ · //')

# 工具版本，缺失则标未安装
ver() { command -v "$1" >/dev/null 2>&1 && eval "$2" || echo "未安装"; }
V_GIT=$(ver git       'git --version | awk "{print \$3}"')
V_PY=$(ver python3    'python3 -V | awk "{print \$2}"')
V_SB=$(ver sing-box   'sing-box version | head -1 | awk "{print \$3}"')
V_XR=$(ver xray       'xray version | head -1 | awk "{print \$2}"')
V_SSH=$(ver ssh       'ssh -V 2>&1 | awk "{print \$1}"')
V_SSL=$(ver openssl   'openssl version | awk "{print \$2}"')
V_CURL=$(ver curl     'curl -V | head -1 | awk "{print \$2}"')
V_CRON=$(ver crontab  'dpkg -l cron 2>/dev/null | awk "/^ii/{print \$3}"')

# 数据规模与脚本行数，全部实测而非写死
count_lines() { [[ -f "$1" ]] && grep -c . "$1" || echo 0; }
N_SUB_MD=$(count_lines sub.md)
N_SUB=$(count_lines sub.txt)
N_ALIVE=$(count_lines sub_alive.txt)
lc() { [[ -f "$1" ]] && wc -l < "$1" | xargs || echo 0; }
L_PIPE=$(lc scripts/subs_pipeline.py); L_NORM=$(lc scripts/normalize_subs.py)
L_PROBE=$(lc scripts/probe_nodes.py);  L_SYNC=$(lc scripts/auto_sync.sh)
L_SSH=$(lc scripts/github-ssh-push.sh); L_GEN=$(lc scripts/gen_readme.sh)
# ---------------------------------------------------------------- 渲染
render() {
cat <<EOF
# UtilityScripts

订阅节点处理与自动化工具集：订阅清洗归一化、节点真实可用性探测、SSH 配置、自动同步。

> 本文件由 \`scripts/gen_readme.sh\` 自动生成，环境信息实时采集，请勿手工编辑。
> 最后更新：**${STAMP}**（仅在环境信息实质变化时刷新，纯时间差异不会产生提交）

## 运行环境

### 时间与时区

| 项目 | 值 |
|---|---|
| 时区 | ${TZ_NAME} |
| UTC 偏移 | UTC${TZ_OFFSET} |
| 生成时刻 | ${STAMP} ／ ${UTC_STAMP} |

该环境无 systemd，\`timedatectl\` 不可用，时区通过符号链接设置：

\`\`\`bash
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
\`\`\`

### 系统与硬件

| 项目 | 值 |
|---|---|
| 发行版 | ${OS_NAME} |
| 内核 | ${KERNEL} |
| 架构 | ${ARCH} |
| 虚拟化 | PID 1 为 \`${PID1}\`$([[ "$PID1" == firecracker* ]] && echo "（Firecracker microVM，非 Docker）") |
| 主机名 | ${HOSTNAME_V} |
| CPU | ${CPU_MODEL} × ${CPU_CORES} 核 |
| 内存 | ${MEM_TOTAL} |
| 磁盘 | ${DISK_TOTAL}（可用 ${DISK_AVAIL}） |

### 网络

本机为**双线分流**：境内与境外目标走不同出口，分流由上游网关决定（本机只有一个默认网关 \`${GATEWAY}\`，无法自行选路）。

**境内线路出口** — \`curl cip.cc\`

| 项目 | 值 |
|---|---|
| 出口 IP | \`${CN_IP}\` |
| 归属地 | ${CN_LOC} |
| 运营商 | ${CN_ISP} |

**境外线路出口** — \`curl https://api.ip.sb/geoip\`

| 项目 | 值 |
|---|---|
| 出口 IP | \`${OV_IP}\` |
| 反向解析 | ${OV_PTR:-无} |
| 归属地 | ${OV_LOC} |
| ISP | ${OV_ISP} |
| AS | AS${OV_ASN:-?} ${OV_ASORG} |
| IP 时区 | ${OV_TZ} |

**内网**

| 项目 | 值 |
|---|---|
| eth0 | \`${LAN_IP}\` |
| 默认网关 | \`${GATEWAY}\` |
| DNS | \`${DNS_SRV}\` |
EOF
}
render_tail() {
cat <<EOF

### 实测出站限制

以下限制均经对照实验确认，直接决定了探活脚本的设计：

| 协议 / 目标 | 状态 | 判定依据 |
|---|---|---|
| ICMP | **完全禁止** | \`8.8.8.8\`、\`1.1.1.1\` 均 100% 丢包，与保留地址 \`192.0.2.1\` 无差异 |
| TCP 22（GitHub） | **被拦截** | \`kex_exchange_identification: Connection closed\`，改走 \`ssh.github.com:443\` |
| TCP connect | **结果不可信** | 保留地址 \`192.0.2.1:12345\` 也返回连接成功，上游有透明代理应答 SYN |
| HTTPS 443 | 正常 | 任意端口出站可用 |
| google / youtube | 可达 | 走境外线路，HTTP 200 约 0.8 s |
| facebook / twitter | 超时 | 环境自身出站策略，与 GFW 无关 |

所以节点可用性只能靠**完整协议握手 + 真实 HTTP 请求**验证，ICMP 与 TCP 层探测在此环境全部无效。

境内线路虽然存在，但**不能用来测 GFW** —— 分流由上游按目标 IP 决定，境外节点的连接必然走香港线路。

### 已安装工具

| 工具 | 版本 | 用途 |
|---|---|---|
| git | ${V_GIT} | 版本控制与自动同步 |
| python3 | ${V_PY} | 订阅解析与流水线 |
| sing-box | ${V_SB} | 探活主引擎（vless/trojan/ss/hysteria2） |
| Xray-core | ${V_XR} | 探活第二引擎（xhttp、Reality 原生） |
| OpenSSH | ${V_SSH} | SSH 推送 |
| OpenSSL | ${V_SSL} | TLS 握手检测 |
| curl | ${V_CURL} | 出口 IP 探测 |
| cron | ${V_CRON} | 定时同步（守护进程需手动拉起） |

## 仓库内容

| 文件 | 行数 | 说明 |
|---|---|---|
| \`scripts/subs_pipeline.py\` | ${L_PIPE} | 流水线入口：汇总 → 清洗 → 命名 → 探活 → 输出 |
| \`scripts/normalize_subs.py\` | ${L_NORM} | 解析、去广告、去重、国家识别（170+ 地区词、旗帜 emoji） |
| \`scripts/probe_nodes.py\` | ${L_PROBE} | 双引擎探活，取真实出口 IP 与归属国家 |
| \`scripts/auto_sync.sh\` | ${L_SYNC} | 幂等自动同步到 GitHub，本地优先，支持 cron |
| \`scripts/gen_readme.sh\` | ${L_GEN} | 生成本文件，环境信息实时采集 |
| \`scripts/github-ssh-push.sh\` | ${L_SSH} | SSH/GPG 密钥生成、展示、验证与推送 |

| 数据文件 | 规模 |
|---|---|
| \`sub.md\` | ${N_SUB_MD} 行原始订阅（多来源拼接，含大量重复） |
| \`sub.txt\` | ${N_SUB} 个唯一节点，按国家码编号 |
| \`sub_alive.txt\` | ${N_ALIVE} 个探活确认可用的节点 |

## 快速开始

\`\`\`bash
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
\`\`\`

### 命名规则

节点统一命名为 \`国家码 + 序号\`（\`US1\` \`US2\` \`HK1\`），国家判定优先级：

1. **探活实测的真实出口国家** — 唯一可靠依据
2. GeoIP 查询节点地址归属
3. 节点名中的旗帜 emoji、中英文地区词、已有国家码前缀
4. 域名首段提示（如 \`jp3.example.com\`）

实测中订阅原标注准确率约 57%，故默认以实测出口为准。

## 注意事项

- 探活结果反映**境外线路出口（${OV_IP}）**到节点的连通性，不代表中国大陆可达性
- 探活并发上限为 3，超过后代理连接会被关闭，导致健康节点被误判
- 回显服务必须用 HTTPS，明文 HTTP 会被部分节点出口拦截返回 400 页面
- \`sub_report.tsv\` 含节点真实出口 IP，默认不纳入版本控制

---

<div align="center">

\`\`\`
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
\`\`\`

**A I Y**

</div>
EOF
}
# ---------------------------------------------------------------- 写入
# 比对时剔除时间戳行：否则每次 cron 都会因为分钟数不同而产生一个空洞提交
strip_volatile() { sed -E '/^> 最后更新：/d; /^\| 生成时刻 \|/d'; }

NEW_CONTENT=$(render; render_tail)

if (( TO_STDOUT )); then
  printf '%s\n' "$NEW_CONTENT"
  exit 0
fi

if [[ -f "$TARGET" ]]; then
  # 先落到变量再比，便于排查；注意 [[ == ]] 右侧必须加引号，
  # 否则 markdown 里的 * 会被当成 glob 模式而不是字面量
  OLD_NORM=$(strip_volatile <"$TARGET")
  NEW_NORM=$(printf '%s\n' "$NEW_CONTENT" | strip_volatile)
  if [[ -n "${GEN_README_DEBUG:-}" ]]; then
    printf 'debug: 旧 %s 字节 / 新 %s 字节\n' "${#OLD_NORM}" "${#NEW_NORM}" >&2
    diff <(printf '%s\n' "$OLD_NORM") <(printf '%s\n' "$NEW_NORM") >&2 || true
  fi
  if [[ "$OLD_NORM" == "$NEW_NORM" ]]; then
    echo "环境信息无实质变化，README.md 保持不动"
    exit 0
  fi
fi

printf '%s\n' "$NEW_CONTENT" >"$TARGET"
echo "README.md 已更新（$(wc -l <"$TARGET" | xargs) 行）"
echo "  境内出口 ${CN_IP} / ${CN_LOC}"
echo "  境外出口 ${OV_IP} / ${OV_LOC}"
echo "  节点数据 sub.txt ${N_SUB} 个，可用 ${N_ALIVE} 个"
