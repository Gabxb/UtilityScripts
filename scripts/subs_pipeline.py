#!/usr/bin/env python3
"""订阅处理流水线：多来源汇总 → 清洗归一化 → 探活 → 按真实出口国家命名 → 输出

一条命令跑完全流程：
    python3 scripts/subs_pipeline.py sub.md 第二份.txt https://example.com/sub

产出：
    sub.txt         全部节点，按国家码编号（可用节点用实测出口国，其余用推断）
    sub_alive.txt   仅探活确认可用的节点，独立编号，日常用这个
    sub_report.tsv  每个节点的判定明细

命名依据的优先级（从高到低）：
    1. 探活实测的真实出口国家 —— 唯一可靠依据
    2. GeoIP 查节点地址归属（--geoip）
    3. 节点名里的旗帜 emoji / 中英文地区词 / 已有国家码前缀
    4. 域名首段提示（jp3.xxx.com）
实测中订阅原标注的准确率只有三成左右，所以默认信实测。
"""
from __future__ import annotations

import argparse
import collections
import importlib.util
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load(name: str):
    """按路径加载同目录模块，避免依赖 sys.path 布局"""
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    if spec is None or spec.loader is None:
        raise ImportError(f"找不到 {HERE / (name + '.py')}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


NS = _load("normalize_subs")
PN = _load("probe_nodes")
def fetch(src: str) -> list[str]:
    """取一个来源的文本行。支持 http(s) 链接、本地文件、- 表示标准输入"""
    if src.startswith(("http://", "https://")):
        req = urllib.request.Request(src, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                text = resp.read().decode("utf-8", errors="replace")
        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"  [跳过] 下载失败 {src}: {exc}", file=sys.stderr)
            return []
        decoded = NS.try_b64decode(text)
        return (decoded or text).splitlines()
    return NS.load_lines(src)


def collect(sources: list[str]) -> tuple[list, collections.Counter]:
    """阶段 1：汇总所有来源，剔除广告/信息行，按 协议+地址+端口+凭据 去重"""
    stats: collections.Counter = collections.Counter()
    nodes = []
    for src in sources:
        lines = fetch(src)
        kept = 0
        for line in lines:
            line = line.strip()
            if not line:
                continue
            stats["总行数"] += 1
            if not NS.SCHEME_RE.match(line):
                stats["非节点行"] += 1
                continue
            node = NS.parse_line(line, src)
            if node is None:
                stats["解析失败"] += 1
                continue
            if NS.AD_RE.search(node.name):
                stats["广告/信息节点"] += 1
                continue
            nodes.append(node)
            kept += 1
        print(f"  {src}: {len(lines)} 行 → 收 {kept} 个节点")

    seen: dict[tuple, object] = {}
    for node in nodes:
        key = (node.scheme, node.host.lower(), node.port, node.ident)
        if key in seen:
            stats["重复节点"] += 1
            continue
        seen[key] = node
    return list(seen.values()), stats
def assign_names(pairs: list[tuple[str, object]]) -> list[tuple[str, object]]:
    """阶段 4：同国家码内按出现顺序编号，返回 [(国家码+序号, node)]"""
    grouped: dict[str, list] = collections.defaultdict(list)
    for code, node in pairs:
        grouped[code].append(node)
    out = []
    for code in sorted(grouped):
        for idx, node in enumerate(grouped[code], 1):
            out.append((f"{code}{idx}", node))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        description="订阅流水线：汇总 → 清洗 → 归一化命名 → 探活 → 输出")
    ap.add_argument("sources", nargs="+", help="订阅来源：文件路径、http(s) 链接或 -")
    ap.add_argument("-o", "--output", default="sub.txt", help="全部节点输出（默认 sub.txt）")
    ap.add_argument("-a", "--alive", default="sub_alive.txt", help="仅可用节点输出")
    ap.add_argument("-r", "--report", default="sub_report.tsv", help="明细报告")
    ap.add_argument("--no-probe", action="store_true", help="跳过探活，只做清洗与命名")
    ap.add_argument("--no-xray", action="store_true", help="探活只用 sing-box")
    ap.add_argument("--geoip", action="store_true",
                    help="未探活的节点也查一次地址归属（探活已开时收益有限）")
    ap.add_argument("--timeout", type=int, default=10, help="单节点探活超时（秒）")
    args = ap.parse_args()

    print(f"[1/5] 汇总 {len(args.sources)} 个来源")
    nodes, stats = collect(args.sources)
    for key in ("非节点行", "解析失败", "广告/信息节点", "重复节点"):
        if stats[key]:
            print(f"  剔除 {key}: {stats[key]}")
    print(f"  去重后 {len(nodes)} 个唯一节点")
    if not nodes:
        print("没有可用节点，退出", file=sys.stderr)
        return 1

    print("[2/5] 初步识别国家（旗帜 / 地区词 / 已有前缀 / 域名提示）")
    geo = NS.build_geoip_map(nodes) if args.geoip else {}
    guess = {id(n): NS.detect_country(n, geo) for n in nodes}
    print("  " + "  ".join(f"{c}×{v}" for c, v in
                           collections.Counter(guess.values()).most_common(12)))

    provisional = assign_names([(guess[id(n)], n) for n in nodes])
    old_name = {id(node): name for name, node in provisional}
    result: dict[str, dict] = {}
    if args.no_probe:
        print("[3/5] 跳过探活（--no-probe）")
    else:
        print(f"[3/5] 探活 {len(provisional)} 个节点（实际跑流量取真实出口）")
        result = PN.probe({name: node.render(name) for name, node in provisional},
                          timeout=args.timeout, use_xray=not args.no_xray)

    print("[4/5] 按最佳已知国家重新编号")
    final_pairs = []
    for name, node in provisional:
        info = result.get(name, {})
        # 实测出口国最可信；没探到就退回初步推断
        code = info.get("exit_cc") or guess[id(node)]
        final_pairs.append((code, node))
    final = assign_names(final_pairs)
    corrected = sum(1 for name, node in provisional
                    if (result.get(name, {}).get("exit_cc") or guess[id(node)]) != guess[id(node)])
    print(f"  实测出口国与初步判断不一致、已按实测修正: {corrected} 个")

    print("[5/5] 输出")
    Path(args.output).write_text(
        "\n".join(node.render(name) for name, node in final) + "\n", encoding="utf-8")
    print(f"  全部 {len(final)} 个 → {args.output}")

    if result:
        alive = [(n, node) for n, node in final if result[old_name[id(node)]]["usable"]]
        alive = assign_names([(re.match(r"^([A-Z]+)", n).group(1), node) for n, node in alive])
        Path(args.alive).write_text(
            "\n".join(node.render(name) for name, node in alive) + "\n", encoding="utf-8")
        print(f"  可用 {len(alive)} 个 → {args.alive}")

        rows = ["name\tusable\texit_ip\texit_cc\tguess_cc\texit_org\tengine\tnote"]
        for name, node in final:
            info = result[old_name[id(node)]]
            rows.append(
                f"{name}\t{'yes' if info['usable'] else 'no'}\t{info['exit_ip']}\t"
                f"{info.get('exit_cc', '')}\t{guess[id(node)]}\t{info.get('exit_org', '')}\t"
                f"{info['engine']}\t{info['note']}")
        Path(args.report).write_text("\n".join(rows) + "\n", encoding="utf-8")
        print(f"  明细 → {args.report}")

        groups = PN.shared_exits({old_name[id(node)]: result[old_name[id(node)]]
                                  for _, node in final})
        if groups:
            print(f"\n注意：{len(groups)} 组节点共用同一出口 IP，"
                  f"共 {sum(len(v) for v in groups.values())} 个，实用上等于 {len(groups)} 个落地")
            for ip, names in sorted(groups.items(), key=lambda x: -len(x[1]))[:6]:
                print(f"  {ip:<16} ×{len(names):<2} {' '.join(names)}")

        cc = collections.Counter(
            result[old_name[id(node)]].get("exit_cc") or "?"
            for _, node in final if result[old_name[id(node)]]["usable"])
        print("\n可用节点真实出口分布: " + "  ".join(f"{k}×{v}" for k, v in cc.most_common()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
