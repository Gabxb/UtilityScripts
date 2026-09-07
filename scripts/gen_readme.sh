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
  # 必须用 -P：调用方的模式含后视断言 (?<=...)，-E 不支持 PCRE，会静默匹配不到
  grep -oP "$pattern" "$TARGET" 2>/dev/null | head -1 || true
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
# eth0 上挂了多个地址（link-local 元数据地址 + 实际内网地址），全列出来，
# 原来 exit 只取第一个，恰好取到 169.254 那个，看不出真实内网段
LAN_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{printf "`%s` ", $2}' | xargs || true)
GATEWAY=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
DNS_SRV=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf | xargs)

# 境内线路：cip.cc 是文本格式，取 IP 与地址行
CN_RAW=$(try 15 'curl -sS --max-time 12 cip.cc')
CN_IP=$(printf '%s' "$CN_RAW" | awk -F': *' '/^IP/{print $2; exit}' | xargs || true)
CN_LOC=$(printf '%s' "$CN_RAW" | awk -F': *' '/^地址/{print $2; exit}' | xargs || true)
CN_ISP=$(printf '%s' "$CN_RAW" | awk -F': *' '/^运营商/{print $2; exit}' | xargs || true)
# 三个字段一并回填：只补 IP 会渲染出"IP 有值、归属地采集失败"的自相矛盾表格
if [[ -z "$CN_IP" ]]; then
  CN_IP=$(old_value '(?<=\| 出口 IP \| `)[0-9]+(?:\.[0-9]+){3}')
  CN_LOC=$(old_value '(?<=\| 归属地 \| )[^|]+' | xargs || true)
  CN_ISP=$(old_value '(?<=\| 运营商 \| )[^|]+' | xargs || true)
fi
: "${CN_IP:=采集失败}" "${CN_LOC:=采集失败}" "${CN_ISP:=采集失败}"

# 境外线路：先拿出口 IP，再查归属。
#
# 两处历史坑：
#   · api.ip.sb 从 2026-09 起 TLS 握手就被打断（SSL_ERROR_SYSCALL），单点依赖不可取，
#     这里改成多端点依次尝试，任一成功即止
#   · jget 原来直接 grep，无匹配返回 1，在 set -e 下会让脚本当场退出 ——
#     "采集失败沿用旧值" 的兜底逻辑永远走不到。所有取值一律以 || true 收尾
fetch_egress_ip() {
  local ep raw cand
  for ep in 'https://api.ipify.org' 'https://www.cloudflare.com/cdn-cgi/trace' 'http://ip-api.com/line?fields=query'; do
    raw=$(try 15 "curl -sS --max-time 12 '${ep}'")
    # cloudflare trace 是 key=value 多行格式，其余两个直接返回裸 IP
    cand=$(printf '%s' "$raw" | grep -oE '(^|ip=)([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 | sed 's/^ip=//' || true)
    [[ -n "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  # 显式 return 0：全部端点失败时函数体最后一句是失败的 [[ -n ]]，
  # 会把 1 当成返回值，在 set -e 下直接终止整个脚本。调用方靠空输出判断失败
  return 0
}

# 境外出口是一个轮换代理池，粒度比想象的粗：实测同一天内命中过 AS4760 HKT、
# AS138997 Eons、AS41378 Kirino（香港与台湾两地），连 /24 前缀都不稳定。
# 所以具体 IP 或网段都不是可写入文档的事实 —— 写进去只会让每次 cron
# 产出一个数字不同的空洞提交，正是本脚本开头要避免的噪音。
#
# 另外轮换有粘滞性：短时间内连续请求往往落在同一出口，单次运行只能看到池子的一角，
# 直接报告本次采样会让"覆盖国家"在 Taiwan 和 Hong Kong、Taiwan 之间来回跳。
# 因此把历次观察累积进本地状态文件，README 只报告累计并集 ——
# 观察越多集合越稳定，文件也就不再变动。
readonly POOL_FILE="${REPO_DIR}/.egress_pool.tsv"

for _ in $(seq 1 "${GEN_README_SAMPLES:-4}"); do
  ip=$(fetch_egress_ip)
  [[ -n "$ip" ]] || continue
  grep -qF "	${ip}	" "$POOL_FILE" 2>/dev/null && continue
  line=$(try 15 "curl -sS --max-time 12 'http://ip-api.com/line/${ip}?fields=country,as'")
  c=$(printf '%s\n' "$line" | sed -n '1p'); a=$(printf '%s\n' "$line" | sed -n '2p')
  [[ -n "$c" ]] && printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d')" "$ip" "$c" "$a" >>"$POOL_FILE"
done

# 累计并集；排序去重保证渲染结果只随事实变化，不随采样顺序变化
N_EGRESS=$(awk -F'\t' 'NF>=3{print $2}' "$POOL_FILE" 2>/dev/null | sort -u | grep -c . || true)
# 用 awk 而非 paste -sd'、'：paste 的分隔符只取首字节，会把多字节的顿号截成乱码
join_by() { awk -v sep="$1" 'NF{ out = out (n++ ? sep : "") $0 } END{ print out }'; }
OV_COUNTRIES=$(awk -F'\t' 'NF>=3{print $3}' "$POOL_FILE" 2>/dev/null | sort -u | join_by '、' || true)
OV_ASES=$(awk -F'\t' 'NF>=4&&$4!=""{print $4}' "$POOL_FILE" 2>/dev/null | sort -u | sed 's/^/`/; s/$/`/' | join_by '、' || true)
OV_FIRST_SEEN=$(awk -F'\t' 'NF>=3{print $1}' "$POOL_FILE" 2>/dev/null | sort | head -1 || true)
: "${OV_COUNTRIES:=采集失败}" "${OV_ASES:=采集失败}" "${N_EGRESS:=0}"

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

**境外线路出口** — \`curl https://api.ipify.org\` 取 IP，\`ip-api.com\` 查归属

境外出口是一个**轮换代理池**，每个请求都可能换一个地址，且跨多个 AS 与地区，连 \`/24\` 前缀都不固定。因此本节只记录轮换范围，不记录具体出口 IP。

| 项目 | 值 |
|---|---|
| 出口稳定性 | 逐次轮换，短时间内有粘滞 |
| 已观察到的出口数 | ${N_EGRESS} 个不同 IP（自 ${OV_FIRST_SEEN:-?} 起累计） |
| 覆盖国家 / 地区 | ${OV_COUNTRIES} |
| 覆盖 AS | ${OV_ASES} |

明细见 \`.egress_pool.tsv\`（本地累计，不入库）。

**内网**

| 项目 | 值 |
|---|---|
| eth0 | ${LAN_IP} |
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
| TCP connect | **结果不可信** | 保留地址 \`192.0.2.1:12345\` 也返回连接成功，上游有透明代理应答 SYN |
| TCP 22（GitHub） | 可用 | \`ssh -T git@github.com\` 认证成功，早期被拦截的情况已不复现 |
| TCP 443（ssh.github.com） | 认证失败 | 端口通，但该 host 未配对应 key，报 \`Permission denied (publickey)\` |
| HTTPS 443 | 部分可用 | 出站端口不受限，但个别站点在 TLS 握手阶段被打断 |
| google / youtube | 可达 | 走境外线路，HTTP 200 约 0.3～0.5 s |
| facebook / twitter | **TLS 握手被打断** | \`SSL_ERROR_SYSCALL\`，非超时；环境自身出站策略 |
| api.ip.sb / api.myip.com | **TLS 握手被打断** | 同上，故 geoip 改用 \`ip-api.com\` 明文接口 |

所以节点可用性只能靠**完整协议握手 + 真实 HTTP 请求**验证，ICMP 与 TCP 层探测在此环境全部无效。

境内线路虽然存在，但**不能用来测 GFW** —— 分流由上游按目标 IP 决定，境外节点的连接必然走境外线路。

境外出口是轮换池，同一节点在不同时刻可能经由不同国家、不同 AS 的出口去连接，探活结果因此存在天然抖动，比较跨天的 \`sub_alive.txt\` 时需留意这一点。

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

- 探活结果反映**境外轮换出口**到节点的连通性，不代表中国大陆可达性；出口每次请求都可能变化，跨天结果不可直接对比
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
# 出口 IP 逐次轮换，"本次采样"和采样命中数每回都不同，必须与时间戳一样排除，
# 否则每半小时一个只有 IP 差异的提交，README 历史会被彻底刷成噪音
# 出口 IP 计数随每次采样缓慢增长，本身不算环境变化 —— 与时间戳同样排除。
# 覆盖国家与 AS 则保留在比对内：那是真正影响探活解读的事实，变了就该提交
strip_volatile() {
  sed -E '/^> 最后更新：/d
          /^\| 生成时刻 \|/d
          /^\| 已观察到的出口数 \|/d'
}

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
echo "  境外出口 轮换池 ${N_EGRESS} 个 IP / ${OV_COUNTRIES}"
echo "  节点数据 sub.txt ${N_SUB} 个，可用 ${N_ALIVE} 个"
