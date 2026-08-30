#!/usr/bin/env python3
"""订阅节点归一化工具

功能：解析多来源订阅 → 剔除广告/信息行 → 去重 → 按国家识别码重命名 → 输出

命名规则：同一国家码内按出现顺序编号，US1 US2 US3 ...
国家识别优先级：旗帜 emoji > 名称中的地区词 > 域名中的国家提示 > 原有国家码前缀

用法：
    python3 normalize_subs.py sub.md other1.txt other2.txt -o sub.txt
    cat raw | python3 normalize_subs.py - -o sub.txt
"""
from __future__ import annotations

import argparse
import base64
import binascii
import collections
import json
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# 支持的协议前缀
SCHEMES = (
    "vless", "vmess", "ss", "ssr", "trojan",
    "hysteria", "hysteria2", "hy2", "tuic", "snell",
)
SCHEME_RE = re.compile(r"^(" + "|".join(SCHEMES) + r")://", re.I)

# 旗帜 emoji 由两个 regional indicator 组成，可直接换算为国家码
RI_BASE = 0x1F1E6


def flag_to_code(text: str) -> str | None:
    """从旗帜 emoji 提取 ISO 国家码，如 🇺🇸 → US"""
    chars = [c for c in text if RI_BASE <= ord(c) <= RI_BASE + 25]
    if len(chars) >= 2:
        return "".join(chr(ord(c) - RI_BASE + ord("A")) for c in chars[:2])
    return None
# 地区名 → 国家码。键为小写，匹配时按键长度降序，避免「美国」先被「美」截走
REGION_MAP: dict[str, str] = {
    # 东亚
    "香港": "HK", "hongkong": "HK", "hong kong": "HK", "hk": "HK", "港": "HK",
    "台湾": "TW", "taiwan": "TW", "台北": "TW", "新北": "TW", "彰化": "TW", "tw": "TW", "台": "TW",
    "日本": "JP", "japan": "JP", "东京": "JP", "大阪": "JP", "埼玉": "JP", "名古屋": "JP",
    "tokyo": "JP", "osaka": "JP", "jp": "JP",
    "韩国": "KR", "korea": "KR", "首尔": "KR", "seoul": "KR", "kr": "KR",
    "中国": "CN", "china": "CN", "北京": "CN", "上海": "CN", "广州": "CN", "深圳": "CN", "cn": "CN",
    "澳门": "MO", "macao": "MO", "macau": "MO", "mo": "MO",
    # 东南亚 / 南亚
    "新加坡": "SG", "singapore": "SG", "狮城": "SG", "sg": "SG",
    "马来西亚": "MY", "malaysia": "MY", "吉隆坡": "MY", "my": "MY",
    "泰国": "TH", "thailand": "TH", "曼谷": "TH", "th": "TH",
    "越南": "VN", "vietnam": "VN", "vn": "VN",
    "菲律宾": "PH", "philippines": "PH", "马尼拉": "PH", "ph": "PH",
    "印尼": "ID", "印度尼西亚": "ID", "indonesia": "ID", "雅加达": "ID", "id": "ID",
    "印度": "IN", "india": "IN", "孟买": "IN", "in": "IN",
    "巴基斯坦": "PK", "pakistan": "PK", "pk": "PK",
    "孟加拉": "BD", "bangladesh": "BD", "bd": "BD",
    # 北美
    "美国": "US", "美國": "US", "unitedstates": "US", "united states": "US", "usa": "US",
    "洛杉矶": "US", "圣何塞": "US", "西雅图": "US", "达拉斯": "US", "凤凰城": "US",
    "硅谷": "US", "纽约": "US", "芝加哥": "US", "迈阿密": "US", "拉斯维加斯": "US",
    "波特兰": "US", "丹佛": "US", "亚特兰大": "US", "休斯顿": "US", "圣克拉拉": "US",
    "losangeles": "US", "los angeles": "US", "san jose": "US", "seattle": "US",
    "new york": "US", "chicago": "US", "dallas": "US", "miami": "US", "us": "US",
    "加拿大": "CA", "canada": "CA", "多伦多": "CA", "温哥华": "CA", "蒙特利尔": "CA", "ca": "CA",
    "墨西哥": "MX", "mexico": "MX", "mx": "MX",
    # 南美
    "巴西": "BR", "brazil": "BR", "圣保罗": "BR", "br": "BR",
    "阿根廷": "AR", "argentina": "AR", "ar": "AR",
    "智利": "CL", "chile": "CL", "cl": "CL",
    "哥伦比亚": "CO", "colombia": "CO", "co": "CO",
    "秘鲁": "PE", "peru": "PE", "pe": "PE",
    # 西欧 / 北欧
    "英国": "UK", "英國": "UK", "unitedkingdom": "UK", "united kingdom": "UK",
    "伦敦": "UK", "london": "UK", "britain": "UK", "england": "UK", "uk": "UK", "gb": "UK",
    "德国": "DE", "germany": "DE", "法兰克福": "DE", "柏林": "DE",
    "frankfurt": "DE", "berlin": "DE", "de": "DE",
    "法国": "FR", "france": "FR", "巴黎": "FR", "paris": "FR", "马赛": "FR", "fr": "FR",
    "荷兰": "NL", "netherlands": "NL", "阿姆斯特丹": "NL", "amsterdam": "NL", "nl": "NL",
    "比利时": "BE", "belgium": "BE", "be": "BE",
    "卢森堡": "LU", "luxembourg": "LU", "lu": "LU",
    "爱尔兰": "IE", "ireland": "IE", "都柏林": "IE", "dublin": "IE", "ie": "IE",
}
REGION_MAP.update({
    # 南欧 / 中欧
    "意大利": "IT", "italy": "IT", "米兰": "IT", "罗马": "IT", "milan": "IT", "it": "IT",
    "西班牙": "ES", "spain": "ES", "马德里": "ES", "madrid": "ES", "es": "ES",
    "葡萄牙": "PT", "portugal": "PT", "里斯本": "PT", "pt": "PT",
    "瑞士": "CH", "switzerland": "CH", "苏黎世": "CH", "zurich": "CH", "ch": "CH",
    "奥地利": "AT", "austria": "AT", "维也纳": "AT", "vienna": "AT", "at": "AT",
    "希腊": "GR", "greece": "GR", "雅典": "GR", "gr": "GR",
    "土耳其": "TR", "turkey": "TR", "伊斯坦布尔": "TR", "istanbul": "TR", "tr": "TR",
    # 北欧
    "瑞典": "SE", "sweden": "SE", "斯德哥尔摩": "SE", "se": "SE",
    "挪威": "NO", "norway": "NO", "奥斯陆": "NO", "no": "NO",
    "芬兰": "FI", "finland": "FI", "赫尔辛基": "FI", "helsinki": "FI", "fi": "FI",
    "丹麦": "DK", "denmark": "DK", "哥本哈根": "DK", "dk": "DK",
    "冰岛": "IS", "iceland": "IS", "is": "IS",
    # 东欧
    "俄罗斯": "RU", "russia": "RU", "莫斯科": "RU", "moscow": "RU",
    "圣彼得堡": "RU", "ru": "RU",
    "乌克兰": "UA", "ukraine": "UA", "基辅": "UA", "ua": "UA",
    "波兰": "PL", "poland": "PL", "华沙": "PL", "warsaw": "PL", "pl": "PL",
    "捷克": "CZ", "czech": "CZ", "布拉格": "CZ", "prague": "CZ", "cz": "CZ",
    "罗马尼亚": "RO", "romania": "RO", "ro": "RO",
    "匈牙利": "HU", "hungary": "HU", "布达佩斯": "HU", "hu": "HU",
    "保加利亚": "BG", "bulgaria": "BG", "bg": "BG",
    "塞尔维亚": "RS", "serbia": "RS", "rs": "RS",
    "克罗地亚": "HR", "croatia": "HR", "hr": "HR",
    "斯洛伐克": "SK", "slovakia": "SK", "sk": "SK",
    "斯洛文尼亚": "SI", "slovenia": "SI", "si": "SI",
    "立陶宛": "LT", "lithuania": "LT", "lt": "LT",
    "拉脱维亚": "LV", "latvia": "LV", "lv": "LV",
    "爱沙尼亚": "EE", "estonia": "EE", "ee": "EE",
    "摩尔多瓦": "MD", "moldova": "MD", "md": "MD",
    "白俄罗斯": "BY", "belarus": "BY", "by": "BY",
    # 中东 / 中亚
    "伊朗": "IR", "iran": "IR", "德黑兰": "IR", "tehran": "IR", "ir": "IR",
    "以色列": "IL", "israel": "IL", "il": "IL",
    "阿联酋": "AE", "迪拜": "AE", "dubai": "AE", "emirates": "AE", "ae": "AE",
    "沙特": "SA", "saudi": "SA", "sa": "SA",
    "卡塔尔": "QA", "qatar": "QA", "qa": "QA",
    "科威特": "KW", "kuwait": "KW", "kw": "KW",
    "亚美尼亚": "AM", "armenia": "AM", "am": "AM",
    "格鲁吉亚": "GE", "georgia": "GE", "ge": "GE",
    "哈萨克斯坦": "KZ", "kazakhstan": "KZ", "kz": "KZ",
    "阿塞拜疆": "AZ", "azerbaijan": "AZ", "az": "AZ",
    # 大洋洲 / 非洲
    "澳大利亚": "AU", "澳洲": "AU", "australia": "AU", "悉尼": "AU", "sydney": "AU", "au": "AU",
    "新西兰": "NZ", "newzealand": "NZ", "new zealand": "NZ", "nz": "NZ",
    "南非": "ZA", "southafrica": "ZA", "south africa": "ZA", "za": "ZA",
    "埃及": "EG", "egypt": "EG", "eg": "EG",
    "尼日利亚": "NG", "nigeria": "NG", "ng": "NG",
    "摩洛哥": "MA", "morocco": "MA", "ma": "MA",
    "肯尼亚": "KE", "kenya": "KE", "ke": "KE",
    # 特殊标识：非国家，保留原样以便区分
    "cloudflare": "CF", "cf": "CF", "warp": "CF",
    "欧洲": "EU", "europe": "EU", "eu": "EU",
    "亚洲": "AS", "asia": "AS",
    "seychelles": "SC", "塞舌尔": "SC", "sc": "SC",
})
# 广告 / 信息节点特征：这类"节点"只用于在客户端展示文案，应整条剔除
AD_PATTERNS = [
    r"剩余流量", r"到期时间", r"过期时间", r"距离下次", r"重置", r"套餐",
    r"续费", r"充值", r"购买", r"下单", r"官网", r"官方网站", r"频道", r"群组",
    r"客服", r"教程", r"使用说明", r"注意事项", r"公告", r"通知", r"邀请",
    r"流量用完", r"请勿", r"禁止", r"免费", r"试用", r"抽奖", r"折扣", r"优惠",
    r"traffic", r"expire", r"expir", r"reset", r"renew", r"official",
    r"channel", r"telegram", r"t\.me", r"@\w+bot", r"subscribe", r"website",
    r"^\s*$",
]
AD_RE = re.compile("|".join(AD_PATTERNS), re.I)

# 需要从节点名中剔除的噪音：emoji、装饰符号、倍率标记、运营商前缀
NOISE_RE = re.compile(
    r"[\U0001F000-\U0001FAFF☀-➿️‍←-⇿]"  # emoji / 箭头
    r"|\b\d+(\.\d+)?\s*[xX×倍]\b"                                      # 倍率 2x / 1.5倍
    r"|[|｜\[\]()（）【】<>《》]"                                        # 分隔与括号
)


def strip_noise(name: str) -> str:
    """清掉 emoji、括号、倍率等装饰，只留可读文字"""
    return re.sub(r"\s{2,}", " ", NOISE_RE.sub(" ", name)).strip(" -_·—、,，.")


def try_b64decode(text: str) -> str | None:
    """尝试按 base64 解码；不是 base64 就返回 None"""
    compact = re.sub(r"\s+", "", text)
    if len(compact) < 16 or not re.fullmatch(r"[A-Za-z0-9+/_\-=]+", compact):
        return None
    padded = compact.replace("-", "+").replace("_", "/")
    padded += "=" * (-len(padded) % 4)
    try:
        raw = base64.b64decode(padded, validate=False)
    except (binascii.Error, ValueError):
        return None
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return decoded if SCHEME_RE.search(decoded) else None
class Node:
    """单个节点：raw 为去掉名称后的链接主体，name 为原始名称"""

    __slots__ = ("scheme", "body", "name", "host", "port", "ident", "source", "sni")

    def __init__(self, scheme, body, name, host, port, ident, source, sni=""):
        self.scheme, self.body, self.name = scheme, body, name
        self.host, self.port, self.ident, self.source = host, port, ident, source
        self.sni = sni

    def render(self, new_name: str) -> str:
        # vmess 的名称在 base64(JSON) 的 ps 字段里，需整体重新编码
        if self.scheme == "vmess" and isinstance(self.body, dict):
            cfg = dict(self.body)
            cfg["ps"] = new_name
            payload = base64.b64encode(
                json.dumps(cfg, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            ).decode("ascii")
            return "vmess://" + payload
        return f"{self.body}#{urllib.parse.quote(new_name, safe='')}"


def parse_vmess(body: str):
    """vmess:// 后接 base64(JSON)，取出 add/port/ps/id"""
    payload = body[len("vmess://"):]
    padded = payload.replace("-", "+").replace("_", "/")
    padded += "=" * (-len(padded) % 4)
    try:
        cfg = json.loads(base64.b64decode(padded, validate=False).decode("utf-8"))
    except (binascii.Error, ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(cfg, dict):
        return None
    host = str(cfg.get("add", "")).strip()
    port = str(cfg.get("port", "")).strip()
    name = str(cfg.get("ps", "") or "")
    ident = str(cfg.get("id", ""))
    if not host or not port:
        return None
    # 重新序列化时名称由调用方替换，这里保留原 cfg 以便改名
    return host, port, name, ident, cfg


def parse_line(line: str, source: str) -> Node | None:
    """把一行订阅文本解析为 Node；无法识别返回 None"""
    line = line.strip()
    if not line or not SCHEME_RE.match(line):
        return None
    scheme = SCHEME_RE.match(line).group(1).lower()

    if scheme == "vmess":
        parsed = parse_vmess(line)
        if not parsed:
            return None
        host, port, name, ident, cfg = parsed
        node = Node(scheme, line, name, host, port, ident, source)
        node.body = cfg  # vmess 需要整体重编码，render 时特殊处理
        return node

    body, _, frag = line.partition("#")
    name = urllib.parse.unquote(frag)
    try:
        parts = urllib.parse.urlsplit(body)
    except ValueError:
        return None
    host, port = parts.hostname or "", str(parts.port or "")
    ident = parts.username or ""
    if scheme == "ss" and not host:
        # 旧式 ss://base64(method:pass@host:port)
        payload = body[len("ss://"):].split("?")[0]
        decoded = try_b64decode(payload) or ""
        m = re.match(r"^(?P<cred>[^@]+)@(?P<host>[^:]+):(?P<port>\d+)", decoded)
        if not m:
            return None
        host, port, ident = m.group("host"), m.group("port"), m.group("cred")
    if not host or not port:
        return None
    qs = urllib.parse.parse_qs(parts.query)
    sni = (qs.get("sni") or qs.get("host") or qs.get("peer") or [""])[0]
    return Node(scheme, body, name, host, port, ident, source, sni)
# 长键优先匹配，避免「美国」被「美」抢先；两字母键单独走严格匹配
LONG_KEYS = sorted((k for k in REGION_MAP if len(k) > 2), key=len, reverse=True)
SHORT_KEYS = {k: v for k, v in REGION_MAP.items() if len(k) <= 2}
SHORT_RE = re.compile(r"\b(" + "|".join(sorted(SHORT_KEYS, key=len, reverse=True)) + r")\b", re.I)
# 名称形如 US1 / HK-02 / JP_3：开头两三位字母即国家码
PREFIX_RE = re.compile(r"^([A-Za-z]{2,3})[\s\-_·]*\d*$")
# 域名首段形如 jp3.xxx.com / hk-node.xxx：开头两位字母后紧跟数字或分隔符
DOMAIN_HINT_RE = re.compile(r"^([a-z]{2})[\d\-_]")


def detect_country(node: "Node", geoip: dict[str, str] | None = None) -> str:
    """按优先级判定国家码：GeoIP 实测 > 旗帜 > 名称地区词 > 已有前缀 > 域名提示"""
    info = (geoip or {}).get((node.host or "").lower())
    if info and not info[1]:
        return info[0]                         # 实测归属，且非 anycast，最可信

    name = node.name or ""
    code = flag_to_code(name)
    if code:
        return code

    clean = strip_noise(name)
    low = clean.lower()

    for key in LONG_KEYS:                      # 「美国」「hongkong」等长词，子串匹配安全
        if key in low:
            return REGION_MAP[key]

    for cand in (node.sni or "", node.host or ""):
        m = DOMAIN_HINT_RE.match(cand.lower().split(".")[0])
        if m and m.group(1) in SHORT_KEYS:     # SNI/域名首段 jp3.* / hk-*
            return SHORT_KEYS[m.group(1)]

    m = PREFIX_RE.match(clean)                 # 「US1」「CF10」这类已编号的名称
    if m and m.group(1).lower() in REGION_MAP:
        return REGION_MAP[m.group(1).lower()]

    m = SHORT_RE.search(low)                   # 「hk 01」「node us」，需词边界
    if m:
        return SHORT_KEYS[m.group(1).lower()]

    if info:
        return info[0]                         # anycast 但推断不出，退回注册国
    return "XX"


IPV4_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
# ip-api 返回 ISO 码 GB，订阅习惯用 UK
CC_ALIAS = {"GB": "UK"}
GEOIP_ENDPOINT = "http://ip-api.com/batch?fields=status,countryCode,query,as,org"
# anycast/CDN 的 IP 没有固定物理位置，GeoIP 结果不可作为落地国依据
ANYCAST_RE = re.compile(r"cloudflare|fastly|akamai|incapsula|imperva", re.I)
GEOIP_BATCH = 100          # 单请求上限
GEOIP_INTERVAL = 4.0       # 免费版 15 请求/分钟，留足余量


def resolve_hosts(hosts: list[str]) -> dict[str, str | None]:
    """域名 → IP；已是 IP 的原样返回，解析失败为 None"""
    out: dict[str, str | None] = {}
    for host in hosts:
        if IPV4_RE.match(host):
            out[host] = host
            continue
        try:
            out[host] = socket.gethostbyname(host)
        except OSError:
            out[host] = None
    return out


def geoip_lookup(ips: list[str]) -> dict[str, tuple[str, bool]]:
    """批量查询 IP 归属。返回 ip → (国家码, 是否 anycast)。只发送 IP，不含凭据"""
    result: dict[str, tuple[str, bool]] = {}
    for i in range(0, len(ips), GEOIP_BATCH):
        chunk = ips[i:i + GEOIP_BATCH]
        req = urllib.request.Request(
            GEOIP_ENDPOINT,
            data=json.dumps(chunk).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                for item in json.load(resp):
                    if item.get("status") == "success" and item.get("countryCode"):
                        code = item["countryCode"].upper()
                        org = f'{item.get("as", "")} {item.get("org", "")}'
                        result[item["query"]] = (CC_ALIAS.get(code, code),
                                                 bool(ANYCAST_RE.search(org)))
        except (urllib.error.URLError, ValueError, TimeoutError) as exc:
            print(f"  GeoIP 查询失败（{len(chunk)} 个 IP）: {exc}", file=sys.stderr)
        if i + GEOIP_BATCH < len(ips):
            time.sleep(GEOIP_INTERVAL)
    return result


def build_geoip_map(nodes: list["Node"]) -> dict[str, tuple[str, bool]]:
    """返回 host → (国家码, 是否 anycast)。解析或查询失败的 host 不出现"""
    hosts = sorted({n.host.lower() for n in nodes})
    ip_of = resolve_hosts(hosts)
    unresolved = [h for h, ip in ip_of.items() if ip is None]
    ips = sorted({ip for ip in ip_of.values() if ip})
    print(f"GeoIP: {len(hosts)} 个 host（{len(unresolved)} 个 DNS 解析失败）"
          f"→ {len(ips)} 个 IP，分 {(len(ips) - 1) // GEOIP_BATCH + 1} 批查询")
    cc_of_ip = geoip_lookup(ips)
    return {h: cc_of_ip[ip] for h, ip in ip_of.items() if ip and ip in cc_of_ip}
# @@MARK2@@
def load_lines(path: str) -> list[str]:
    """读入一个来源；整体是 base64 时先解码"""
    text = sys.stdin.read() if path == "-" else Path(path).read_text(
        encoding="utf-8", errors="replace")
    decoded = try_b64decode(text)
    if decoded:
        text = decoded
    return text.splitlines()
def main() -> int:
    ap = argparse.ArgumentParser(description="订阅节点归一化：去广告、去重、按国家码重命名")
    ap.add_argument("inputs", nargs="+", help="订阅文件路径，- 表示标准输入")
    ap.add_argument("-o", "--output", default="sub.txt", help="输出文件（默认 sub.txt）")
    ap.add_argument("--geoip", action="store_true",
                    help="用 ip-api.com 实测每个节点 IP 的归属国家（只发送 IP，不含凭据）")
    args = ap.parse_args()

    stats = collections.Counter()
    nodes: list[Node] = []

    for path in args.inputs:
        lines = load_lines(path)
        stats[f"读入行:{path}"] = len(lines)
        for line in lines:
            line = line.strip()
            if not line:
                continue
            stats["总行数"] += 1
            if not SCHEME_RE.match(line):
                stats["非节点行"] += 1
                continue
            node = parse_line(line, path)
            if node is None:
                stats["解析失败"] += 1
                continue
            if AD_RE.search(node.name):
                stats["广告/信息节点"] += 1
                continue
            nodes.append(node)

    # 去重：同协议 + 同主机 + 同端口 + 同凭据视为同一节点，保留首次出现
    seen: dict[tuple, Node] = {}
    for node in nodes:
        key = (node.scheme, node.host.lower(), node.port, node.ident)
        if key in seen:
            stats["重复节点"] += 1
            continue
        seen[key] = node
    unique = list(seen.values())

    # 分组编号：国家码字母序，组内保持原始出现顺序
    geoip = build_geoip_map(unique) if args.geoip else {}
    grouped: dict[str, list[Node]] = collections.defaultdict(list)
    for node in unique:
        grouped[detect_country(node, geoip)].append(node)

    out_lines: list[str] = []
    for code in sorted(grouped):
        for idx, node in enumerate(grouped[code], 1):
            out_lines.append(node.render(f"{code}{idx}"))

    Path(args.output).write_text("\n".join(out_lines) + "\n", encoding="utf-8")

    print(f"输入来源 {len(args.inputs)} 份，共 {stats['总行数']} 行")
    for k in ("非节点行", "解析失败", "广告/信息节点", "重复节点"):
        if stats[k]:
            print(f"  剔除 {k}: {stats[k]}")
    print(f"输出 {len(out_lines)} 个节点 → {args.output}")
    print("国家码分布: " + "  ".join(
        f"{c}×{len(v)}" for c, v in sorted(grouped.items(), key=lambda x: -len(x[1]))))
    if "XX" in grouped:
        print(f"提示: {len(grouped['XX'])} 个节点无法识别国家，已标记为 XX")
    return 0


if __name__ == "__main__":
    sys.exit(main())
