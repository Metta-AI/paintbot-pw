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
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
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
    serial: bool = False  # never runs alongside another command (timing-sensitive)


def load_manifest(path=MANIFEST):
    commands = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        text = raw.strip()
        if not text or text.startswith("#"):
            continue
        cwd, posix_only, serial = "", False, False
        if text.startswith("["):
            end = text.index("]")
            for tag in text[1:end].split():
                if tag == "posix-only":
                    posix_only = True
                elif tag == "serial":
                    serial = True
                elif tag.startswith("cwd="):
                    cwd = tag[len("cwd="):]
                else:
                    sys.exit(f"{path}:{number}: unknown tag {tag!r}")
            text = text[end + 1:].strip()
        if not text:
            sys.exit(f"{path}:{number}: tags without a command")
        commands.append(Command(len(commands), number, text, cwd, posix_only, serial))
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


def unittest_glob(name, pattern):
    """std/unittest's filter glob: at most one `*`; no `*` means an exact match."""
    if not pattern:
        return True
    if "*" not in pattern:
        return name == pattern
    before, after = pattern.split("*", 1)
    return len(name) >= len(before) + len(after) and name.startswith(before) and name.endswith(after)


def unittest_match(suite, name, pattern):
    """std/unittest's matchFilter for one command-line filter."""
    if pattern == name:
        return True
    if "::" not in pattern:
        return unittest_glob(name, pattern)
    suite_pattern, test_pattern = pattern.split("::", 1)
    return unittest_glob(suite, suite_pattern) and unittest_glob(name, test_pattern)


def unittest_tests(source):
    """(suite, test) names declared with literal strings in a std/unittest file."""
    tests, suite = [], ""
    for line in source.splitlines():
        m = re.match(r'^suite "((?:[^"\\]|\\.)*)":\s*$', line)
        if m:
            suite = m.group(1)
        m = re.match(r'^\s+test "((?:[^"\\]|\\.)*)":\s*$', line)
        if m:
            tests.append((suite, m.group(1)))
    return tests


def check_splits(commands):
    """A std/unittest file listed on several manifest lines (same cwd and flags), each line
    passing test-name filters, must have every test matched by exactly one line, and every
    filter must match a test: std/unittest silently runs nothing for a filter that matches
    nothing, so a renamed test would otherwise drop out of CI."""
    ok = True
    groups = {}
    for c in commands:
        args = shlex.split(c.command)
        if args[:2] != ["nim", "r"]:
            continue
        i = next(i for i, a in enumerate(args) if i >= 2 and not a.startswith("-") and a.endswith(".nim"))
        groups.setdefault((c.cwd, tuple(args[2:i]), args[i]), []).append((c, args[i + 1:]))
    for (cwd, _, src), lines in groups.items():
        if len(lines) < 2:
            continue
        tests = unittest_tests((ROOT / cwd / src).read_text(encoding="utf-8"))
        if not tests:
            print(f"{src}: on {len(lines)} lines but has no literal unittest tests")
            ok = False
            continue
        for c, filters in lines:
            if not filters:
                print(f"{src}: manifest line {c.line} has no test filter, so it repeats every test")
                ok = False
            for f in filters:
                if not any(unittest_match(suite, name, f) for suite, name in tests):
                    print(f"{src}: filter {f!r} (manifest line {c.line}) matches no test")
                    ok = False
        for suite, name in tests:
            owners = [c.line for c, filters in lines
                      if any(unittest_match(suite, name, f) for f in filters)]
            if len(owners) != 1:
                print(f"{src}: test {name!r} is run by manifest lines {owners}, not exactly one")
                ok = False
        print(f"{src}: {len(tests)} tests split across {len(lines)} lines "
              f"(lines {', '.join(str(c.line) for c, _ in lines)})")
    return ok


def check(commands, shards, durations, workflow):
    ok = True
    seen = {}
    for c in commands:
        if c.command in seen:
            print(f"duplicate command on lines {seen[c.command]} and {c.line}: {c.command}")
            ok = False
        seen[c.command] = c.line
    ok = check_splits(commands) and ok
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


def command_env(c, args):
    """The environment for one command. With CI_NIMCACHE_ROOT set (POSIX only), a `nim` command
    gets its own XDG_CACHE_HOME under it, so Nim keeps that command's nimcache in a directory no
    other command (or flag set) shares, and CI can cache the whole root between runs. The
    command's text and flags are unchanged."""
    root = os.environ.get("CI_NIMCACHE_ROOT")
    if not root or os.name == "nt" or args[0] != "nim":
        return None
    key = hashlib.sha1(f"{c.cwd}\0{c.command}".encode()).hexdigest()[:16]
    return {**os.environ, "XDG_CACHE_HOME": str(Path(root) / key)}


def group(title):
    print(f"::group::{title}" if IN_ACTIONS else f"\n=== {title}", flush=True)


def endgroup():
    if IN_ACTIONS:
        print("::endgroup::", flush=True)


def run_one(c, label, capture):
    """Run one command; returns (status, seconds, captured output or None)."""
    args = shlex.split(c.command)
    exe = shutil.which(args[0])
    start = time.monotonic()
    output = None
    try:
        if capture:
            p = subprocess.run([exe or args[0], *args[1:]], cwd=ROOT / c.cwd,
                               env=command_env(c, args), stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, errors="replace")
            output = p.stdout
        else:
            p = subprocess.run([exe or args[0], *args[1:]], cwd=ROOT / c.cwd,
                               env=command_env(c, args))
        code = p.returncode
    except OSError as error:
        output = (output or "") + f"could not start: {error}\n"
        code = -1
    return ("ok" if code == 0 else f"FAIL({code})"), time.monotonic() - start, output


def report(status, elapsed, c):
    if status.startswith("FAIL") and IN_ACTIONS:
        print(f"::error title=CI test failed::{c.command} ({status}, manifest line {c.line})")
    print(f"{status} {elapsed:6.1f}s  {c.command}", flush=True)


def run_shard(commands, shard, shards, durations, jobs=1):
    """Run one shard. With jobs > 1, up to `jobs` commands run at once, longest (by the
    duration table) first, each command's output printed as one block when it finishes;
    `serial` commands then run one at a time. With jobs == 1, commands run in manifest order
    with their output streamed."""
    bins, loads = plan(commands, shards, durations)
    mine = bins[shard]
    print(f"shard {shard} of {shards}: {len(mine)} of {len(commands)} commands, "
          f"estimated {loads[shard]:.0f}s, {jobs} at a time", flush=True)
    results = {}
    runnable = []
    for c in mine:
        if c.posix_only and os.name == "nt":
            print(f"skip (posix-only) {c.command}", flush=True)
            results[c.index] = ("skip", 0.0, c)
        else:
            runnable.append(c)
    label = lambda c: c.command + (f"  (in {c.cwd})" if c.cwd else "")
    if jobs > 1:
        pool = sorted((c for c in runnable if not c.serial),
                      key=lambda c: (-durations.get(c.command, DEFAULT_SECONDS), c.index))
        serial = [c for c in runnable if c.serial]
        lock = threading.Lock()
        queue = list(pool)

        def worker():
            while True:
                with lock:
                    if not queue:
                        return
                    c = queue.pop(0)
                    print(f"start {label(c)}", flush=True)
                status, elapsed, output = run_one(c, label(c), capture=True)
                with lock:
                    group(f"{status} {elapsed:.1f}s {label(c)}")
                    sys.stdout.write(output or "")
                    endgroup()
                    report(status, elapsed, c)
                    results[c.index] = (status, elapsed, c)

        threads = [threading.Thread(target=worker) for _ in range(min(jobs, len(pool)))]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
    else:
        serial = runnable
    for n, c in enumerate(serial, 1):
        group(f"[{n}/{len(serial)}] {label(c)}" + ("  (serial)" if jobs > 1 else ""))
        status, elapsed, _ = run_one(c, label(c), capture=False)
        endgroup()
        report(status, elapsed, c)
        results[c.index] = (status, elapsed, c)
    ordered = [results[c.index] for c in mine]
    failed = [r for r in ordered if r[0].startswith("FAIL")]
    total = sum(r[1] for r in ordered)
    print(f"\nsummary: shard {shard} of {shards}, {len(ordered)} commands, "
          f"{len(failed)} failed, {total:.0f}s of command time")
    for status, elapsed, c in ordered:
        print(f"  {status:9} {elapsed:6.1f}s  {c.command}")
    sys.stdout.flush()
    return not failed


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--shard", type=int)
    parser.add_argument("--of", type=int, required=True, dest="shards")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--legacy-workflow")
    parser.add_argument("--jobs", type=int, default=1,
                        help="commands to run at once within the shard (default 1)")
    args = parser.parse_args()
    if args.shards < 1:
        parser.error("--of must be at least 1")
    commands, durations = load_manifest(), load_durations()
    if args.check:
        sys.exit(0 if check(commands, args.shards, durations, args.legacy_workflow) else 1)
    if args.shard is None or not 0 <= args.shard < args.shards:
        parser.error("--shard must be in [0, --of)")
    sys.exit(0 if run_shard(commands, args.shard, args.shards, durations, max(1, args.jobs)) else 1)


if __name__ == "__main__":
    main()
