#!/usr/bin/env python3
"""Heartland league readout from recorded matches (plan task C6).

Re-simulates FFA-kin replays (gameVersion 1040) headlessly with tools/kin_replay_counters.nim,
which rebuilds each match in the native training library and checks every frame hash, so the pair
counters are exactly pw_pair_stats'. Then emits the hamilton suite of tools/kin_eval.py over all
the episodes and per policy (the seat names recorded in the replay; hosted names carry the policy
version), as the per-checkpoint kinship readout for the live league.

    python tools/kin_replay_stats.py REPLAY_OR_DIR [...] --out tmp/kin-league [--workers 4]

Hosted replays are gzipped; they are decompressed on the fly. A replay that fails to load or to
reproduce (recorded under rules this build does not play) is listed under "errors", never counted.
Policy keys are the seat names; --name-regex keeps only the first capture group of each name
(for example '^(.*?)(?:#\\d+)?$').
"""

import argparse
import gzip
import json
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kin_eval  # noqa: E402

ROOT = kin_eval.ROOT
DEFAULT_TOOL = ROOT / "tmp" / "kin-replay-counters"


def build_tool(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["nim", "c", "--mm:arc", "--threads:on", "-d:pwTraining", "-d:headless", "-d:release",
                    "--hints:off", f"-o:{path}", "tools/kin_replay_counters.nim"], cwd=ROOT, check=True)


def replay_files(inputs):
    out = []
    for item in inputs:
        p = Path(item)
        if p.is_dir():
            out += sorted(x for x in p.rglob("*") if x.is_file() and x.suffix in (".replay", ".bin", ".raw", ".gz"))
        else:
            out.append(p)
    return out


def counters(tool: Path, paths, scratch: Path):
    """Run the Nim tool over some replays; gunzip first where needed. One JSON object per replay."""
    args, back = [], {}
    for n, p in enumerate(paths):
        with open(p, "rb") as f:
            gz = f.read(2) == b"\x1f\x8b"
        if gz:
            plain = scratch / f"{n}-{p.stem}.raw"
            with gzip.open(p, "rb") as src, open(plain, "wb") as dst:
                dst.write(src.read())
            back[str(plain)] = str(p)
            args.append(str(plain))
        else:
            args.append(str(p))
    run = subprocess.run([str(tool), *args], capture_output=True, text=True)
    rows = [json.loads(line) for line in run.stdout.splitlines() if line.startswith("{")]
    if run.returncode != 0 and len(rows) < len(args):
        done = {r["path"] for r in rows}
        for a in args:
            if a not in done:
                rows.append({"path": a, "error": f"tool exited {run.returncode}: {run.stderr.strip()[-300:]}"})
    for r in rows:
        r["path"] = back.get(r["path"], r["path"])
    return rows


def episode(row, name_re):
    """A kin_eval-shaped episode from one tool row."""
    flat = row["r"]
    r = [[round(flat[16 * i + j], 4) for j in range(16)] for i in range(16)]
    fam = row["family"]
    families = [[s for s in range(16) if fam[s] == f] for f in sorted({f for f in fam if f >= 0})]
    families += [[s] for s in range(16) if fam[s] < 0]
    names = row["names"]
    if name_re:
        names = [(m.group(1) if (m := name_re.match(n)) and m.groups() else n) for n in names]
    seat = row["seat"]
    return {"suite": "league", "cond": {}, "seed": row["seed"], "path": row["path"],
            "layout": kin_eval.LAYOUT_NAMES.get(row["layout"], str(row["layout"])),
            "ticks": row["ticks"], "r": r, "families": sorted(families, key=lambda g: g[0]),
            "policy": names, "group": None, "weak": [], "status": [1] * 16,
            "s": [round(seat[3 * i + 1] * 4320, 2) for i in range(16)], "R": row["scores"],
            "own": [seat[3 * i + 1] for i in range(16)], "kin": [seat[3 * i + 2] for i in range(16)],
            "death": [int(seat[3 * i]) for i in range(16)], "results": row["results"], "pairs": row["pairs"]}


def per_policy(eps, reps):
    out = {}
    for name in sorted({n for e in eps for n in e["policy"]}):
        def key(ep, i, j, name=name):
            return kin_eval.r_bucket(ep["r"][i][j]) if ep["policy"][i] == name else None
        units = kin_eval.hamilton_units(eps, key)
        seats = [(e, s) for e in eps for s in range(16) if e["policy"][s] == name]
        out[name] = {
            "episodes": len({id(e) for e, _ in seats}), "seats": len(seats),
            "mean_R": kin_eval.mean([e["R"][s] for e, s in seats]),
            "mean_s": kin_eval.mean([e["s"][s] for e, s in seats]),
            "curve": kin_eval.curve_table(units, kin_eval.R_BUCKETS, reps, 101, xs=kin_eval.R_BUCKETS),
        }
    return out


def render(res, meta):
    parts = [f"<h2 id=all>All episodes ({res['episodes']})</h2>", kin_eval.render_hamilton(res["hamilton"])]
    parts.append("<h2 id=policies>Per policy (focal seat i runs the policy)</h2><table><tr><th>policy</th>"
                 "<th>episodes</th><th>seats</th><th>mean R</th><th>mean raw s</th><th>harm slope</th>"
                 "<th>defend slope</th></tr>")
    for name, v in res["per_policy"].items():
        parts.append(f"<tr><td>{kin_eval.html.escape(name)}</td><td>{v['episodes']}</td><td>{v['seats']}</td>"
                     f"<td>{kin_eval.fmt(v['mean_R'])}</td><td>{kin_eval.fmt(v['mean_s'])}</td>"
                     f"<td>{kin_eval.ci(v['curve']['harm']['slope'])}</td>"
                     f"<td>{kin_eval.ci(v['curve']['defend']['slope'])}</td></tr>")
    parts.append("</table>")
    for name, v in res["per_policy"].items():
        charts = "".join(kin_eval.svg_curve(f"{m}: {name}", [("", "--a", kin_eval.curve_series(
            v["curve"], m, kin_eval.R_BUCKETS, kin_eval.R_BUCKETS))]) for m in kin_eval.HEADLINE)
        parts.append(f"<h3>{kin_eval.html.escape(name)}</h3><div class=charts>{charts}</div>"
                     + kin_eval.metric_table(v["curve"], kin_eval.R_BUCKETS))
    if res["errors"]:
        parts.append("<h2>Replays not counted</h2><table><tr><th>replay</th><th>reason</th></tr>" + "".join(
            f"<tr><td>{kin_eval.html.escape(e['path'])}</td><td>{kin_eval.html.escape(e['error'])}</td></tr>"
            for e in res["errors"]) + "</table>")
    return (f"<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport "
            f"content='width=device-width,initial-scale=1'><title>Heartland league kinship</title>"
            f"<style>{kin_eval.CSS}</style></head><body><h1>Heartland league kinship readout</h1>"
            f"<p class=muted>{res['episodes']} replays · bootstrap {meta['bootstrap']} · {meta['finished']}</p>"
            + "".join(parts) + "</body></html>")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("replays", nargs="+", help="replay files or directories")
    ap.add_argument("--out", required=True)
    ap.add_argument("--tool", default=None, help="kin-replay-counters binary (built into tmp/ if missing)")
    ap.add_argument("--workers", type=int, default=1)
    ap.add_argument("--bootstrap", type=int, default=1000)
    ap.add_argument("--name-regex", default=None)
    args = ap.parse_args(argv)
    tool = Path(args.tool) if args.tool else DEFAULT_TOOL
    if not tool.exists():
        if args.tool:
            raise SystemExit(f"{tool}: no such tool")
        print(f"building {tool} ...", file=sys.stderr)
        build_tool(tool)
    files = replay_files(args.replays)
    if not files:
        raise SystemExit("no replays found")
    name_re = re.compile(args.name_regex) if args.name_regex else None
    started = time.time()
    with tempfile.TemporaryDirectory(prefix="kin-replays-") as scratch:
        chunks = [files[k::max(1, args.workers)] for k in range(max(1, args.workers))]
        with ThreadPoolExecutor(max(1, args.workers)) as pool:
            rows = [r for part in pool.map(lambda c: counters(tool, c, Path(scratch)), [c for c in chunks if c])
                    for r in part]
    errors = [{"path": r["path"], "error": r["error"]} for r in rows if "error" in r]
    eps = [episode(r, name_re) for r in rows if "error" not in r]
    for e in eps:
        e["pairs"] = kin_eval.array.array("i", e["pairs"])
    print(f"{len(eps)} replays counted, {len(errors)} not, {time.time() - started:.1f}s", file=sys.stderr)
    ns = argparse.Namespace(bootstrap=args.bootstrap)
    res = {"episodes": len(eps), "errors": errors,
           "replays": [{"path": e["path"], "seed": e["seed"], "layout": e["layout"], "ticks": e["ticks"],
                        "policy": e["policy"], "R": e["R"], "s": e["s"], "death": e["death"]} for e in eps],
           "hamilton": kin_eval.analyse_hamilton(eps, ns) if eps else {"skipped": "no replays reproduced"},
           "per_policy": per_policy(eps, args.bootstrap) if eps else {}}
    meta = {"bootstrap": args.bootstrap, "finished": time.strftime("%Y-%m-%d %H:%M:%S"),
            "inputs": [str(f) for f in files]}
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "results.json").write_text(json.dumps({"meta": meta, "results": res}, indent=1, default=lambda o: None))
    (out / "report.html").write_text(render(res, meta) if eps else
                                     f"<!doctype html><title>Heartland league kinship</title><pre>{json.dumps(errors, indent=1)}</pre>")
    print(f"wrote {out / 'report.html'} and {out / 'results.json'}", file=sys.stderr)
    return res


if __name__ == "__main__":
    main()
