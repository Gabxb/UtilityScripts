#!/usr/bin/env python3
"""节点探活：sing-box 主引擎 + Xray 补测，产出真实出口 IP 与国家

为什么要实际跑流量：本机 ICMP 被禁（连 8.8.8.8 都 100% 丢包），
TCP connect 又被透明代理伪造成功（保留地址 192.0.2.1 也返回连接成功），
只有完整协议握手 + 真实 HTTP 请求的结果可信。

踩坑记录（改动前请先读）：
  1. 回显服务必须用 HTTPS。明文 HTTP 会被部分节点出口拦截并返回 400 页面，
     导致可用节点被误判为失败（实测可用数从 2 涨到 63）。
  2. 并发上限很低。同一实例并发 >3 时 curl 报 "connection to proxy closed"，
     连串行验证过可用的节点也会失败。sing-box 用 3，Xray 串行。
  3. 批次间不能复用本地端口，前批 TIME_WAIT 会让后批 bind 失败，
     表现为 curl 报「本地端口连不上」，看起来像节点问题。
  4. 一个非法 outbound 会让整个实例拒绝启动，同批全部报废，
     所以必须先做参数自检，并在启动失败时按报错索引剔除重试。
"""
from __future__ import annotations

import base64
import binascii
import collections
import json
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# 必须是 HTTPS，见文件头踩坑记录 1
ECHO_URLS = ("https://api.ipify.org", "https://icanhazip.com", "https://ifconfig.me/ip")
IPV4_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
SB_WORKERS = 3          # sing-box 批内并发，见踩坑记录 2
SB_GROUP = 25           # 单实例承载节点数
XR_GROUP = 25
BASE_PORT = 41000
GEOIP_URL = "http://ip-api.com/batch?fields=status,countryCode,query,as,org"
ANYCAST_RE = re.compile(r"cloudflare|fastly|akamai|incapsula|imperva", re.I)
CC_ALIAS = {"GB": "UK"}
def b64pad(text: str) -> bytes:
    text = text.replace("-", "+").replace("_", "/")
    return base64.b64decode(text + "=" * (-len(text) % 4), validate=False)


def qs1(qs: dict, *keys: str, default: str = "") -> str:
    for key in keys:
        if qs.get(key):
            return qs[key][0]
    return default


def parse_ss(body: str) -> tuple[str, str, str, int] | None:
    """ss:// → (method, password, host, port)，两种编码都支持"""
    payload = body[len("ss://"):].split("?")[0]
    if "@" in payload:
        userinfo, _, hostport = payload.rpartition("@")
        userinfo = urllib.parse.unquote(userinfo)
        try:
            decoded = b64pad(userinfo).decode("utf-8")
        except (binascii.Error, ValueError, UnicodeDecodeError):
            decoded = userinfo                      # 已是明文 method:pass
        if ":" not in decoded:
            return None
        method, _, password = decoded.partition(":")
        m = re.match(r"^\[?([^\]]+)\]?:(\d+)$", hostport)
        if not m:
            return None
        return method, password, m.group(1), int(m.group(2))
    try:
        decoded = b64pad(urllib.parse.unquote(payload)).decode("utf-8")
    except (binascii.Error, ValueError, UnicodeDecodeError):
        return None
    m = re.match(r"^([^:]+):(.*)@([^:]+):(\d+)$", decoded)
    return (m.group(1), m.group(2), m.group(3), int(m.group(4))) if m else None


def split_line(line: str) -> tuple[str, str, urllib.parse.SplitResult, dict, str]:
    """拆出 scheme / body / urlsplit 结果 / query dict / 节点名"""
    body, _, frag = line.partition("#")
    scheme = body.split("://", 1)[0].lower()
    parts = urllib.parse.urlsplit(body)
    return scheme, body, parts, urllib.parse.parse_qs(parts.query), urllib.parse.unquote(frag)
# ------------------------------------------------------------------ sing-box 适配
def sb_tls(qs: dict, host: str) -> dict | None:
    sec = qs1(qs, "security")
    if sec not in ("tls", "reality", "xtls"):
        return None
    tls = {"enabled": True,
           "server_name": qs1(qs, "sni", "peer", "host") or host,
           "insecure": qs1(qs, "allowInsecure", "insecure") in ("1", "true")}
    fp = qs1(qs, "fp")
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    if sec == "reality":
        tls["reality"] = {"enabled": True, "public_key": qs1(qs, "pbk"),
                          "short_id": qs1(qs, "sid")}
        tls.setdefault("utls", {"enabled": True, "fingerprint": "chrome"})
    return tls


def sb_transport(qs: dict) -> dict | None | bool:
    """返回 dict / None（纯 tcp）/ False（sing-box 不支持该传输）"""
    t = qs1(qs, "type", default="tcp").lower()
    if t in ("tcp", "none", ""):
        return None
    if t == "ws":
        tr = {"type": "ws", "path": urllib.parse.unquote(qs1(qs, "path", default="/"))}
        if qs1(qs, "host"):
            tr["headers"] = {"Host": qs1(qs, "host")}
        return tr
    if t == "grpc":
        return {"type": "grpc", "service_name": qs1(qs, "serviceName", "path")}
    if t in ("httpupgrade", "http"):
        return {"type": "httpupgrade",
                "path": urllib.parse.unquote(qs1(qs, "path", default="/"))}
    return False                                    # xhttp / kcp / quic 交给 Xray


SS2022_KEYLEN = {"2022-blake3-aes-128-gcm": 16, "2022-blake3-aes-256-gcm": 32,
                 "2022-blake3-chacha20-poly1305": 32}
UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                     r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
def sb_outbound(line: str, tag: str) -> dict | None:
    """订阅行 → sing-box outbound"""
    scheme, body, parts, qs, _ = split_line(line)
    host, port = parts.hostname, parts.port

    if scheme == "ss":
        got = parse_ss(body)
        if not got:
            return None
        method, password, host, port = got
        return {"type": "shadowsocks", "tag": tag, "server": host, "server_port": port,
                "method": method, "password": password}

    if not host or not port:
        return None

    if scheme in ("hysteria2", "hy2"):
        return {"type": "hysteria2", "tag": tag, "server": host, "server_port": port,
                "password": urllib.parse.unquote(parts.username or ""),
                "tls": {"enabled": True, "server_name": qs1(qs, "sni") or host,
                        "insecure": qs1(qs, "insecure") in ("1", "true")}}

    if scheme not in ("vless", "trojan"):
        return None

    tr = sb_transport(qs)
    if tr is False:
        return None

    if scheme == "vless":
        ob = {"type": "vless", "tag": tag, "server": host, "server_port": port,
              "uuid": urllib.parse.unquote(parts.username or "")}
        if qs1(qs, "flow"):
            ob["flow"] = qs1(qs, "flow")
    else:
        ob = {"type": "trojan", "tag": tag, "server": host, "server_port": port,
              "password": urllib.parse.unquote(parts.username or "")}

    tls = sb_tls(qs, host)
    if tls:
        ob["tls"] = tls
    elif scheme == "trojan":
        ob["tls"] = {"enabled": True, "server_name": host, "insecure": True}
    if tr:
        ob["transport"] = tr
    return ob


def sb_check(ob: dict) -> str:
    """参数自检，返回不合法原因。见文件头踩坑记录 4"""
    reality = (ob.get("tls") or {}).get("reality") or {}
    if reality.get("enabled"):
        try:
            if len(b64pad(reality.get("public_key", ""))) != 32:
                return "reality public_key 不是 32 字节"
        except (binascii.Error, ValueError):
            return "reality public_key 非法 base64"
    if ob.get("type") == "shadowsocks":
        need = SS2022_KEYLEN.get(ob.get("method", ""))
        if need:
            try:
                if len(b64pad(ob.get("password", ""))) != need:
                    return f"ss2022 密钥应为 {need} 字节"
            except (binascii.Error, ValueError):
                return "ss2022 密钥非法 base64"
    if ob.get("type") == "vless" and not UUID_RE.fullmatch(ob.get("uuid", "")):
        return "uuid 格式非法"
    return ""
# ------------------------------------------------------------------ Xray 适配
def xr_stream(qs: dict, host: str) -> dict:
    net = qs1(qs, "type", default="tcp").lower() or "tcp"
    sec = qs1(qs, "security", default="none").lower()
    ss: dict = {"network": "tcp" if net in ("none", "") else net}
    ss["security"] = ("reality" if sec == "reality"
                      else "tls" if sec in ("tls", "xtls") else "none")
    if sec == "reality":
        ss["realitySettings"] = {"serverName": qs1(qs, "sni"), "publicKey": qs1(qs, "pbk"),
                                 "shortId": qs1(qs, "sid"),
                                 "fingerprint": qs1(qs, "fp", default="chrome"),
                                 "spiderX": qs1(qs, "spx", default="/")}
    elif sec in ("tls", "xtls"):
        ss["tlsSettings"] = {"serverName": qs1(qs, "sni") or host,
                             "fingerprint": qs1(qs, "fp", default="chrome"),
                             "allowInsecure": qs1(qs, "allowInsecure") in ("1", "true")}
    if net == "ws":
        ss["wsSettings"] = {"path": urllib.parse.unquote(qs1(qs, "path", default="/"))}
        if qs1(qs, "host"):
            ss["wsSettings"]["headers"] = {"Host": qs1(qs, "host")}
    elif net == "grpc":
        ss["grpcSettings"] = {"serviceName": qs1(qs, "serviceName", "path")}
    elif net == "xhttp":
        ss["xhttpSettings"] = {"host": qs1(qs, "host") or qs1(qs, "sni"),
                               "path": urllib.parse.unquote(qs1(qs, "path", default="/")),
                               "mode": qs1(qs, "mode", default="auto")}
    elif net == "httpupgrade":
        ss["httpupgradeSettings"] = {
            "path": urllib.parse.unquote(qs1(qs, "path", default="/")),
            "host": qs1(qs, "host")}
    return ss


def xr_outbound(line: str, tag: str) -> dict | None:
    scheme, body, parts, qs, _ = split_line(line)
    if scheme == "ss":
        got = parse_ss(body)
        if not got:
            return None
        method, password, host, port = got
        return {"protocol": "shadowsocks", "tag": tag,
                "settings": {"servers": [{"address": host, "port": port,
                                          "method": method, "password": password}]},
                "streamSettings": {"network": "tcp"}}
    if not parts.hostname or not parts.port:
        return None
    if scheme == "vless":
        return {"protocol": "vless", "tag": tag,
                "settings": {"vnext": [{"address": parts.hostname, "port": parts.port,
                                        "users": [{"id": urllib.parse.unquote(parts.username or ""),
                                                   "encryption": "none",
                                                   "flow": qs1(qs, "flow")}]}]},
                "streamSettings": xr_stream(qs, parts.hostname)}
    if scheme == "trojan":
        ss = xr_stream(qs, parts.hostname)
        if ss["security"] == "none":
            ss["security"] = "tls"
            ss["tlsSettings"] = {"serverName": qs1(qs, "sni") or parts.hostname,
                                 "allowInsecure": True}
        return {"protocol": "trojan", "tag": tag,
                "settings": {"servers": [{"address": parts.hostname, "port": parts.port,
                                          "password": urllib.parse.unquote(parts.username or "")}]},
                "streamSettings": ss}
    return None                                     # hysteria2/tuic 不在 Xray 支持范围
# ------------------------------------------------------------------ 公共探测逻辑
def wait_ports(base: int, count: int, budget: float = 12.0) -> list[int]:
    """等 inbound 监听就绪，返回仍未就绪的索引"""
    deadline = time.time() + budget
    pending = set(range(count))
    while pending and time.time() < deadline:
        for idx in sorted(pending):
            sock = socket.socket()
            sock.settimeout(0.25)
            try:
                sock.connect(("127.0.0.1", base + idx))
                pending.discard(idx)
            except OSError:
                pass
            finally:
                sock.close()
        if pending:
            time.sleep(0.4)
    return sorted(pending)


def curl_exit_ip(port: int, timeout: int) -> tuple[bool, str, str]:
    """经本地 SOCKS 端口取真实出口 IP"""
    note = "no-exit-ip"
    for url in ECHO_URLS:
        try:
            run = subprocess.run(
                ["curl", "-sS", "--socks5-hostname", f"127.0.0.1:{port}",
                 "--max-time", str(timeout), url],
                capture_output=True, text=True, timeout=timeout + 5)
            ip = run.stdout.strip()
            if IPV4_RE.fullmatch(ip):
                return True, ip, ""
            err = (run.stderr or "").strip().replace("\n", " ")
            if err:
                note = re.sub(r"^curl: ", "", err)[:70]
            elif ip:
                note = f"非 IP 响应: {ip[:40]}"
        except subprocess.TimeoutExpired:
            note = "timeout"
        except OSError as exc:
            note = type(exc).__name__
    return False, "", note


def geoip_batch(ips: list[str]) -> dict[str, tuple[str, str]]:
    """出口 IP → (国家码, AS/组织)。只发送 IP，不含任何节点凭据"""
    out: dict[str, tuple[str, str]] = {}
    uniq = sorted(set(i for i in ips if i))
    for i in range(0, len(uniq), 100):
        chunk = uniq[i:i + 100]
        req = urllib.request.Request(GEOIP_URL, data=json.dumps(chunk).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                for item in json.load(resp):
                    if item.get("status") == "success" and item.get("countryCode"):
                        code = item["countryCode"].upper()
                        org = f'{item.get("as", "")} {item.get("org", "")}'.strip()
                        out[item["query"]] = (CC_ALIAS.get(code, code), org[:40])
        except (urllib.error.URLError, ValueError, TimeoutError) as exc:
            print(f"    GeoIP 反查失败（{len(chunk)} 个）: {exc}", file=sys.stderr)
        if i + 100 < len(uniq):
            time.sleep(4)
    return out
BAD_IDX_RE = re.compile(r"outbound\[(\d+)\]")


def _renumber(group: list[tuple[str, dict]], tag_key: str) -> list[tuple[str, dict]]:
    """outbound tag 必须与 route 规则里的 out-N 对应，拆分后要重新编号"""
    return [(n, {**ob, tag_key: f"out-{j}"}) for j, (n, ob) in enumerate(group)]


def sb_config(group: list[tuple[str, dict]], base: int) -> dict:
    return {"log": {"level": "error"},
            "inbounds": [{"type": "socks", "tag": f"in-{i}", "listen": "127.0.0.1",
                          "listen_port": base + i} for i in range(len(group))],
            "outbounds": [ob for _, ob in group] + [{"type": "direct", "tag": "direct"}],
            "route": {"rules": [{"inbound": [f"in-{i}"], "outbound": ob["tag"]}
                                for i, (_, ob) in enumerate(group)],
                      "final": "direct"}}


def xr_config(group: list[tuple[str, dict]], base: int) -> dict:
    return {"log": {"loglevel": "error"},
            "inbounds": [{"listen": "127.0.0.1", "port": base + i, "protocol": "socks",
                          "tag": f"in-{i}", "settings": {"udp": False}}
                         for i in range(len(group))],
            "outbounds": [ob for _, ob in group] + [{"protocol": "freedom", "tag": "direct"}],
            "routing": {"rules": [{"type": "field", "inboundTag": [f"in-{i}"],
                                   "outboundTag": ob["tag"]}
                                  for i, (_, ob) in enumerate(group)]}}


def run_group(engine: str, group, base: int, timeout: int, workers: int, attempt: int = 1):
    """拉起一个引擎实例测一组。启动失败时按报错索引剔除后重试"""
    cfg = sb_config(group, base) if engine == "sing-box" else xr_config(group, base)
    tag_key = "tag"
    cfg_fh = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(cfg, cfg_fh)
    cfg_fh.close()
    log_fh = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
    proc = subprocess.Popen([engine, "run", "-c", cfg_fh.name],
                            stdout=log_fh, stderr=subprocess.STDOUT, text=True)
    try:
        time.sleep(1.5)
        if proc.poll() is not None:
            log_fh.close()
            err = Path(log_fh.name).read_text(errors="replace")
            reason = (err.strip().splitlines() or ["unknown"])[-1][:90]
            if attempt <= 20 and len(group) > 1:
                m = BAD_IDX_RE.search(err)
                if m and 0 <= int(m.group(1)) < len(group):
                    # 报错点明确，直接剔除那个节点
                    idx = int(m.group(1))
                    dropped = group[idx][0]
                    kept = _renumber([p for j, p in enumerate(group) if j != idx], tag_key)
                    res = run_group(engine, kept, base, timeout, workers, attempt + 1)
                    return res + [(dropped, False, "", f"配置被拒: {reason[:50]}")]
                # 报错没带索引（如 Xray 的传输层弃用告警），二分定位坏节点，
                # 否则这一组里所有健康节点都会被连带判失败
                mid = len(group) // 2
                left = _renumber(group[:mid], tag_key)
                right = _renumber(group[mid:], tag_key)
                return (run_group(engine, left, base, timeout, workers, attempt + 1)
                        + run_group(engine, right, base + len(left) + 20,
                                    timeout, workers, attempt + 1))
            return [(n, False, "", f"{engine} 启动失败: {reason[:60]}") for n, _ in group]

        stuck = set(wait_ports(base, len(group)))
        idxs = [i for i in range(len(group)) if i not in stuck]
        if workers <= 1:
            probed = [(group[i][0], *curl_exit_ip(base + i, timeout)) for i in idxs]
        else:
            with ThreadPoolExecutor(workers) as ex:
                probed = list(ex.map(
                    lambda i: (group[i][0], *curl_exit_ip(base + i, timeout)), idxs))
        probed += [(group[i][0], False, "", "本地端口未就绪，未实测") for i in sorted(stuck)]
        return probed
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=6)
        except subprocess.TimeoutExpired:
            proc.kill()
        log_fh.close()
        Path(cfg_fh.name).unlink(missing_ok=True)
        Path(log_fh.name).unlink(missing_ok=True)
def _run_engine(engine, builder, checker, lines, names, timeout, workers, group_size, quiet):
    """用指定引擎跑一轮，返回 {name: (ok, exit_ip, note)}"""
    buildable, rejected = [], {}
    for name in names:
        ob = builder(lines[name], f"out-{len(buildable)}")
        if ob is None:
            rejected[name] = f"{engine} 不支持该协议/传输层"
            continue
        why = checker(ob) if checker else ""
        if why:
            rejected[name] = why
            continue
        buildable.append((name, ob))

    out: dict[str, tuple[bool, str, str]] = {n: (False, "", w) for n, w in rejected.items()}
    for i in range(0, len(buildable), group_size):
        group = buildable[i:i + group_size]
        group = [(n, {**ob, "tag": f"out-{j}"}) for j, (n, ob) in enumerate(group)]
        # 批次间不复用端口，见文件头踩坑记录 3
        base = BASE_PORT + (i // group_size) * (group_size + 20)
        t0 = time.time()
        for name, ok, ip, note in run_group(engine, group, base, timeout, workers):
            out[name] = (ok, ip, note)
        if not quiet:
            got = sum(1 for n, _ in group if out.get(n, (False,))[0])
            print(f"    {engine} 组 {i // group_size + 1}: {len(group)} 个 → 可用 {got}"
                  f"（{time.time() - t0:.0f}s）", flush=True)
    return out


def probe(lines: dict[str, str], timeout: int = 10, quiet: bool = False,
          use_xray: bool = True) -> dict[str, dict]:
    """双引擎探活。lines: {节点名: 订阅行}

    sing-box 覆盖 ws/grpc/hysteria2，Xray 覆盖 xhttp 且对 Reality 原生支持，
    两者互为第二意见，取并集压低假阴性。
    """
    have_sb = shutil.which("sing-box")
    have_xr = shutil.which("xray") if use_xray else None
    if not have_sb and not have_xr:
        raise RuntimeError("未找到 sing-box 或 xray，无法探活")

    result = {n: {"usable": False, "exit_ip": "", "note": "未探测", "engine": ""}
              for n in lines}

    if have_sb:
        if not quiet:
            print("  引擎 1/2: sing-box", flush=True)
        for name, (ok, ip, note) in _run_engine(
                "sing-box", sb_outbound, sb_check, lines, list(lines),
                timeout, SB_WORKERS, SB_GROUP, quiet).items():
            result[name] = {"usable": ok, "exit_ip": ip, "note": note,
                            "engine": "sing-box" if ok else ""}

    pending = [n for n in lines if not result[n]["usable"]]
    if have_xr and pending:
        if not quiet:
            print(f"  引擎 2/2: xray（复测 {len(pending)} 个未确认节点，串行）", flush=True)
        for name, (ok, ip, note) in _run_engine(
                "xray", xr_outbound, None, lines, pending,
                timeout, 1, XR_GROUP, quiet).items():
            if ok:
                result[name] = {"usable": True, "exit_ip": ip, "note": "", "engine": "xray"}
            elif result[name]["note"] in ("未探测", ""):
                result[name]["note"] = note

    # 出口 IP 反查国家：这是最准的国家依据，优于按节点 IP 查归属
    geo = geoip_batch([v["exit_ip"] for v in result.values() if v["usable"]])
    for info in result.values():
        cc, org = geo.get(info["exit_ip"], ("", ""))
        info["exit_cc"], info["exit_org"] = cc, org
    return result
def shared_exits(result: dict[str, dict]) -> dict[str, list[str]]:
    """找出共用同一出口 IP 的节点组：这些节点实用上等于同一个落地"""
    by_ip = collections.defaultdict(list)
    for name, info in result.items():
        if info["usable"] and info["exit_ip"]:
            by_ip[info["exit_ip"]].append(name)
    return {ip: sorted(ns) for ip, ns in by_ip.items() if len(ns) > 1}


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="节点探活：sing-box + Xray 双引擎")
    ap.add_argument("sub", help="订阅文件，每行一个节点链接")
    ap.add_argument("-o", "--alive", default="", help="仅输出可用节点到该文件")
    ap.add_argument("--report", default="", help="TSV 明细输出路径")
    ap.add_argument("--timeout", type=int, default=10)
    ap.add_argument("--no-xray", action="store_true", help="只用 sing-box")
    args = ap.parse_args()

    lines: dict[str, str] = {}
    for raw in Path(args.sub).read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if raw and "://" in raw:
            lines[urllib.parse.unquote(raw.partition("#")[2]) or f"n{len(lines)}"] = raw
    print(f"待探活 {len(lines)} 个节点")

    result = probe(lines, timeout=args.timeout, use_xray=not args.no_xray)
    ok = {n: v for n, v in result.items() if v["usable"]}
    print(f"\n确认可用 {len(ok)}/{len(result)}")
    cc = collections.Counter(v["exit_cc"] or "?" for v in ok.values())
    print("真实出口国家: " + "  ".join(f"{k}×{v}" for k, v in cc.most_common()))

    groups = shared_exits(result)
    if groups:
        total = sum(len(v) for v in groups.values())
        print(f"\n共用同一出口的节点 {len(groups)} 组（{total} 个），实用上等于 {len(groups)} 个落地：")
        for ip, names in sorted(groups.items(), key=lambda x: -len(x[1])):
            org = next((result[n]["exit_org"] for n in names), "")
            print(f"  {ip:<16} ×{len(names):<2} {org:<32} {' '.join(names)}")

    if args.report:
        rows = ["name\tusable\texit_ip\texit_cc\texit_org\tengine\tnote"]
        for name in sorted(result):
            v = result[name]
            rows.append(f"{name}\t{'yes' if v['usable'] else 'no'}\t{v['exit_ip']}\t"
                        f"{v.get('exit_cc', '')}\t{v.get('exit_org', '')}\t"
                        f"{v['engine']}\t{v['note']}")
        Path(args.report).write_text("\n".join(rows) + "\n", encoding="utf-8")
        print(f"\n明细 → {args.report}")
    if args.alive:
        Path(args.alive).write_text(
            "\n".join(lines[n] for n in lines if result[n]["usable"]) + "\n", encoding="utf-8")
        print(f"可用节点 → {args.alive}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
