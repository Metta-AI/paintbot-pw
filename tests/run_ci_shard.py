#!/usr/bin/env python3
"""Run one shard of the CI test manifest (tests/ci_tests.txt).

    python tests/run_ci_shard.py --shard I --of N   run shard I of N (0-based)
    python tests/run_ci_shard.py --check --of N     check the shard plan; print it

Commands are split into N shards by greedy longest-first bin packing over the durations in
tests/ci_durations.json (seconds, from the ubuntu-latest job; a command missing from the table
counts as DEFAULT_SECONDS). The plan depends only on the manifest and that table, so every
runner, on every OS, computes the same plan. Within a shard, commands run in manifest order.

A shard runs every one of its commands even after a failure, prints a timing summary, and exits
non-zero if any command failed. Commands run from the repository root (or their cwd= tag) with no
shell, so they behave the same under bash and PowerShell runners.

--check asserts that each manifest command lands in exactly one shard. With
--legacy-workflow FILE it also asserts that the manifest equals the `run:` steps of that
workflow file (command, working directory and the Windows skip), which is how the move out of
build.yml was verified; it needs PyYAML.
"""

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tests" / "ci_tests.txt"
DURATIONS = ROOT / "tests" / "ci_durations.json"
DEFAULT_SECONDS = 60.0
IN_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"


@dataclass(frozen=True)
class Command:
    index: int  # position in the manifest
    line: int  # 1-based line number in the manifest
    command: str
    cwd: str  # relative to the repo root; "" for the root
    posix_only: bool


def load_manifest(path=MANIFEST):
    commands = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        text = raw.strip()
        if not text or text.startswith("#"):
            continue
        cwd, posix_only = "", False
        if text.startswith("["):
            end = text.index("]")
            for tag in text[1:end].split():
                if tag == "posix-only":
                    posix_only = True
                elif tag.startswith("cwd="):
                    cwd = tag[len("cwd="):]
                else:
                    sys.exit(f"{path}:{number}: unknown tag {tag!r}")
            text = text[end + 1:].strip()
        if not text:
            sys.exit(f"{path}:{number}: tags without a command")
        commands.append(Command(len(commands), number, text, cwd, posix_only))
    return commands


def load_durations(path=DURATIONS):
    return json.loads(path.read_text(encoding="utf-8"))["seconds"] if path.exists() else {}


def plan(commands, shards, durations):
    """Greedy longest-first bin packing. Returns a list of shards, each in manifest order."""
    order = sorted(commands, key=lambda c: (-durations.get(c.command, DEFAULT_SECONDS), c.index))
    loads = [0.0] * shards
    bins = [[] for _ in range(shards)]
    for c in order:
        target = min(range(shards), key=lambda s: (loads[s], s))
        loads[target] += durations.get(c.command, DEFAULT_SECONDS)
        bins[target].append(c)
    return [sorted(b, key=lambda c: c.index) for b in bins], loads


def legacy_steps(workflow):
    """The `run:` steps of the pre-manifest build.yml, as (command, cwd, posix_only)."""
    import yaml

    doc = yaml.safe_load(Path(workflow).read_text(encoding="utf-8"))
    job = doc["jobs"]["build"]
    default_dir = job["defaults"]["run"]["working-directory"]  # the checkout path
    steps = []
    for step in job["steps"]:
        if "run" not in step or step.get("name") == "Install dependencies":
            continue
        command = " ".join(step["run"].split())
        cwd = step.get("working-directory", default_dir)
        cwd = "" if cwd == default_dir else os.path.relpath(cwd, default_dir).replace(os.sep, "/")
        condition = step.get("if")
        if condition not in (None, "runner.os != 'Windows'"):
            sys.exit(f"unexpected step condition {condition!r}")
        steps.append((command, cwd, condition is not None))
    return steps


def check(commands, shards, durations, workflow):
    ok = True
    seen = {}
    for c in commands:
        if c.command in seen:
            print(f"duplicate command on lines {seen[c.command]} and {c.line}: {c.command}")
            ok = False
        seen[c.command] = c.line
    bins, loads = plan(commands, shards, durations)
    assigned = [c.index for b in bins for c in b]
    if sorted(assigned) != list(range(len(commands))):
        print("shard plan does not assign every command exactly once")
        ok = False
    for s, (b, load) in enumerate(zip(bins, loads)):
        print(f"shard {s}: {len(b)} commands, estimated {load:.0f}s")
        for c in b:
            print(f"  {durations.get(c.command, DEFAULT_SECONDS):5.0f}s  {c.command}")
    missing = [c.command for c in commands if c.command not in durations]
    stale = sorted(set(durations) - {c.command for c in commands})
    for m in missing:
        print(f"note: no duration recorded, assuming {DEFAULT_SECONDS:.0f}s: {m}")
    for m in stale:
        print(f"note: duration recorded for a command not in the manifest: {m}")
    if workflow:
        old = legacy_steps(workflow)
        new = [(c.command, c.cwd, c.posix_only) for c in commands]
        print(f"legacy workflow {workflow}: {len(old)} run steps; manifest: {len(new)} commands")
        for item in old:
            if item not in new:
                print(f"  only in workflow: {item}")
                ok = False
        for item in new:
            if item not in old:
                print(f"  only in manifest: {item}")
                ok = False
        if ok and old != new:
            print("  same commands, different order")
            ok = False
        if old == new:
            print("  identical: same commands, tags and order")
    print(f"{len(commands)} commands, {shards} shards: {'OK' if ok else 'FAILED'}")
    return ok


def group(title):
    print(f"::group::{title}" if IN_ACTIONS else f"\n=== {title}", flush=True)


def endgroup():
    if IN_ACTIONS:
        print("::endgroup::", flush=True)


def run_shard(commands, shard, shards, durations):
    bins, loads = plan(commands, shards, durations)
    mine = bins[shard]
    print(f"shard {shard} of {shards}: {len(mine)} of {len(commands)} commands, "
                f"estimated {loads[shard]:.0f}s", flush=True)
    results = []
    for n, c in enumerate(mine, 1):
        label = f"[{n}/{len(mine)}] {c.command}" + (f"  (in {c.cwd})" if c.cwd else "")
        if c.posix_only and os.name == "nt":
            print(f"skip (posix-only) {label}", flush=True)
            results.append(("skip", 0.0, c))
            continue
        group(label)
        args = shlex.split(c.command)
        exe = shutil.which(args[0])
        start = time.monotonic()
        try:
            code = subprocess.run([exe or args[0], *args[1:]], cwd=ROOT / c.cwd).returncode
        except OSError as error:
            print(f"could not start: {error}", flush=True)
            code = -1
        elapsed = time.monotonic() - start
        endgroup()
        status = "ok" if code == 0 else f"FAIL({code})"
        if code != 0 and IN_ACTIONS:
            print(f"::error title=CI test failed::{c.command} (exit {code}, manifest line {c.line})")
        print(f"{status} {elapsed:6.1f}s  {c.command}", flush=True)
        results.append((status, elapsed, c))
    failed = [r for r in results if r[0].startswith("FAIL")]
    total = sum(r[1] for r in results)
    print(f"\nsummary: shard {shard} of {shards}, {len(results)} commands, "
                f"{len(failed)} failed, {total:.0f}s")
    for status, elapsed, c in results:
        print(f"  {status:9} {elapsed:6.1f}s  {c.command}")
    sys.stdout.flush()
    return not failed


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--shard", type=int)
    parser.add_argument("--of", type=int, required=True, dest="shards")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--legacy-workflow")
    args = parser.parse_args()
    if args.shards < 1:
        parser.error("--of must be at least 1")
    commands, durations = load_manifest(), load_durations()
    if args.check:
        sys.exit(0 if check(commands, args.shards, durations, args.legacy_workflow) else 1)
    if args.shard is None or not 0 <= args.shard < args.shards:
        parser.error("--shard must be in [0, --of)")
    sys.exit(0 if run_shard(commands, args.shard, args.shards, durations) else 1)


if __name__ == "__main__":
    main()
