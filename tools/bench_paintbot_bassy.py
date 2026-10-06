"""Compare the old BASIC runtime and current Bassy JIT on identical Paintbot matches."""

import argparse
import json
import re
import shutil
import statistics
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def command(arguments, cwd=ROOT):
    """Run a command and retain diagnostics if it fails."""
    result = subprocess.run(arguments, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def summarize(samples):
    """Compare medians while retaining every individual timing sample."""
    keys = ["startup_ms", "decision_ms", "simulation_ms", "total_ms",
            "p50_decision_ms", "p95_decision_ms"]
    medians = {
        engine: {key: statistics.median(sample[key] for sample in samples
                                        if sample["engine"] == engine)
                 for key in keys}
        for engine in ["old", "new"]
    }
    return {"medians": medians,
            "decision_speedup": medians["old"]["decision_ms"] /
                                medians["new"]["decision_ms"],
            "total_speedup": medians["old"]["total_ms"] /
                             medians["new"]["total_ms"]}


def main():
    """Build isolated revisions and alternate timed runs without concurrency."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old-ref", default="537826a")
    parser.add_argument("--runs", type=int, default=6)
    parser.add_argument("--ticks", type=int, default=1200)
    parser.add_argument("--policies", nargs="+", default=["base", "jev"])
    parser.add_argument("--output", type=Path, default=ROOT / "tmp/bassy-benchmarks.json")
    args = parser.parse_args()
    if args.runs < 1 or args.ticks < 1:
        parser.error("runs and ticks must be positive")
    for policy in args.policies:
        if policy not in ["base", "jev"]:
            parser.error("policies must be base or jev")
    report = {
        "old_revision": command(["git", "rev-parse", args.old_ref]).strip(),
        "new_revision": command(["git", "rev-parse", "HEAD"]).strip(),
        "working_tree_changes": bool(command(["git", "status", "--porcelain"])),
        "compiler": command(["nim", "--version"]).splitlines()[0],
        "flags": ["release", "headless"],
        "warmup_ticks": 240,
        "measured_ticks": args.ticks,
        "runs_per_engine": args.runs,
        "policies": {},
    }
    # A sibling snapshot inherits the same workspace dependency paths.
    with tempfile.TemporaryDirectory(prefix=".paintbot-basic-bench-", dir=ROOT.parent) as directory:
        temporary = Path(directory)
        old = temporary / "old"
        old.mkdir()
        # Reuse the workspace dependency configuration from the parent directory.
        config = ROOT.parent / "nim.cfg"
        if config.exists():
            text = re.sub(r'--path:"([^\"]+)"',
                          lambda match: '--path:"' + str((ROOT.parent / match[1]).resolve()) + '"',
                          config.read_text())
            (temporary / "nim.cfg").write_text(text)
        archive = temporary / "old.tar"
        subprocess.run(["git", "archive", "--output=" + str(archive), args.old_ref,
                        "src", "examples/paintbot", "config.nims",
                        "coworld/dependencies.lock"], cwd=ROOT, check=True)
        with tarfile.open(archive) as files:
            files.extractall(old, filter="data")
        (old / "tools").mkdir()
        shutil.copyfile(ROOT / "tools/bench_paintbot_basic.nim",
                        old / "tools/bench_paintbot_basic.nim")
        # Old config paths point one directory up. Supply the same dependencies.
        for dependency in ["silky", "shady", "noisy", "windy", "gltf", "vmath"]:
            (temporary / dependency).symlink_to(ROOT.parent / dependency,
                                                target_is_directory=True)
        binaries = {}
        for engine, source in [("old", old), ("new", ROOT)]:
            binary = temporary / engine / "bench"
            binary.parent.mkdir(exist_ok=True)
            flags = ["nim", "c", "-d:release", "-d:headless", "-d:Samples=1",
                     "-d:MeasuredTicks=" + str(args.ticks),
                     "--nimcache:" + str(temporary / (engine + "-cache")),
                     "--out:" + str(binary)]
            if engine == "old":
                flags.append("-d:oldBasic")
            command(flags + ["tools/bench_paintbot_basic.nim"], cwd=source)
            binaries[engine] = binary
        for policy in args.policies:
            samples = []
            for run in range(args.runs):
                order = ["old", "new"] if run % 2 == 0 else ["new", "old"]
                for engine in order:
                    source = old if engine == "old" else ROOT
                    output = command([str(binaries[engine]),
                                      str(source / "examples/paintbot/players" /
                                          (policy + ".bas"))], cwd=source)
                    sample = json.loads(output.splitlines()[-1])
                    sample.update(engine=engine, run=run)
                    samples.append(sample)
                    print(policy, engine, "decision_ms=", sample["decision_ms"],
                          "hash=", sample["state_hash"], flush=True)
            hashes = {sample["state_hash"] for sample in samples}
            if len(hashes) != 1:
                raise RuntimeError("Old and new trajectories differ: " + str(hashes))
            report["policies"][policy] = {"samples": samples, **summarize(samples)}
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + "\n")
            print(policy, "decision speedup=",
                  report["policies"][policy]["decision_speedup"], flush=True)
    print("Saved", args.output)


if __name__ == "__main__":
    main()
