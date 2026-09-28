#!/usr/bin/env python3
"""THROWAWAY (measurement PR only, never merged): evidence for splitting and --opt:speed.

part A: per-test run time of the two heaviest tests (debug, as CI runs them today), by
        std/unittest name filter, plus the unfiltered test count.
part B: the same with --opt:speed; --opt:speed run time of the top-10 run-time commands;
        compile options under --opt:speed; a flipped assertion must still fail.
"""

import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tmp" / "ci-exp"
HEAVY = {
    "tests/test_paintbot_jev_baseline.nim": [],
    "tests/test_paintbot_neural_basic_io.nim": ["-d:headless"],
}
TOP = [
    "nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_respawn_memory.nim",
    "nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_curriculum.nim",
    "nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_net2.nim",
    "nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_spray.nim",
    "nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_weapon_stats.nim",
    "nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_retarget_gate.nim",
    "nim r -d:headless tests/test_paintbot_neural_host.nim",
    "nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_fire_hold_radius.nim",
]


def run(args, capture=False):
    start = time.monotonic()
    p = subprocess.run([shutil.which(args[0]) or args[0], *args[1:]], cwd=ROOT,
                       capture_output=capture, text=True)
    if capture:
        sys.stdout.write(p.stdout[-4000:])
        sys.stdout.write(p.stderr[-2000:])
    return time.monotonic() - start, p.returncode, (p.stdout if capture else "")


def compile_(src, flags, tag):
    binary = OUT / f"{Path(src).stem}-{tag}"
    t, code, _ = run(["nim", "c", *flags, f"-o:{binary}", src])
    print(f"EXP\tcompile\t{tag}\t{src}\t{t:.1f}\t{code}", flush=True)
    return binary


def per_test(src, flags, tag):
    names = re.findall(r'^\s*test "(.*)":\s*$', (ROOT / src).read_text(), re.M)
    binary = compile_(src, flags, tag)
    t, code, out = run([str(binary)], capture=True)
    print(f"EXP\tfull\t{tag}\t{src}\t{t:.1f}\t{code}\tOK={out.count('[OK]')}\tFAILED={out.count('[FAILED]')}\tnames={len(names)}", flush=True)
    for name in names:
        t, code, out = run([str(binary), name], capture=True)
        print(f"EXP\ttest\t{tag}\t{src}\t{t:.1f}\t{code}\tOK={out.count('[OK]')}\t{name}", flush=True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    part = sys.argv[1]
    if part == "A":
        for src, flags in HEAVY.items():
            per_test(src, flags, "debug")
        return
    # part B
    probe = OUT / "probe.nim"
    probe.write_text(
        'import std/unittest\n'
        'echo "OPTS assertions=", compileOption("assertions"), " checks=", compileOption("checks"),'
        ' " boundChecks=", compileOption("boundChecks"), " overflowChecks=", compileOption("overflowChecks"),'
        ' " rangeChecks=", compileOption("rangeChecks"), " stackTrace=", compileOption("stackTrace"),'
        ' " lineTrace=", compileOption("lineTrace"), " opt=", compileOption("opt", "speed")\n'
        'var s = @[1, 2, 3]\n'
        'var i = 3\n'
        'test "a false check fails": check 1 + 1 == 3\n'
        'test "an out-of-bounds index raises": expect(IndexDefect): discard s[i]\n'
        'test "doAssert fires": expect(AssertionDefect): doAssert i == 4\n'
        'test "assert fires": expect(AssertionDefect): assert i == 4\n'
    )
    for tag, flags in (("debug", []), ("speed", ["--opt:speed"])):
        b = compile_(str(probe), flags, f"probe-{tag}")
        t, code, out = run([str(b)], capture=True)
        print(f"EXP\tprobe\t{tag}\texit={code}\tOK={out.count('[OK]')}\tFAILED={out.count('[FAILED]')}", flush=True)
    # flip one real assertion in jev_baseline: baseHashes.len == Ticks -> != Ticks
    src = ROOT / "tests" / "test_paintbot_jev_baseline.nim"
    flipped = ROOT / "tests" / "test_paintbot_jev_baseline_flipped.nim"
    text = src.read_text()
    assert "check baseHashes.len == Ticks" in text
    flipped.write_text(text.replace("check baseHashes.len == Ticks", "check baseHashes.len != Ticks"))
    b = compile_(str(flipped.relative_to(ROOT)), ["--opt:speed"], "flipped-speed")
    t, code, out = run([str(b), "without an oracle*"], capture=True)
    print(f"EXP\tflipped\tspeed\texit={code}\tOK={out.count('[OK]')}\tFAILED={out.count('[FAILED]')}", flush=True)
    flipped.unlink()
    for src, flags in HEAVY.items():
        per_test(src, [*flags, "--opt:speed"], "speed")
    for command in TOP:
        args = shlex.split(command)
        flags, src = args[2:-1], args[-1]
        b = compile_(src, [*flags, "--opt:speed"], "speed")
        t, code, _ = run([str(b)])
        print(f"EXP\trun\tspeed\t{src}\t{t:.1f}\t{code}", flush=True)


if __name__ == "__main__":
    main()
