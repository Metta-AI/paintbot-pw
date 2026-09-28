#!/usr/bin/env python3
"""THROWAWAY (measurement PR only, never merged): split each CI command into compile and run.

For `nim r FLAGS FILE ARGS`: `nim c FLAGS -o:BIN FILE` twice (cold nimcache, then warm), then
`BIN ARGS`. For `nim c ...`: the compile twice. Anything else: run once. Prints one
MEASURE<TAB>command<TAB>compile_cold<TAB>compile_warm<TAB>run<TAB>status line per command.
"""

import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import run_ci_shard as r  # noqa: E402


def timed(args, cwd):
    exe = shutil.which(args[0]) or args[0]
    start = time.monotonic()
    code = subprocess.run([exe, *args[1:]], cwd=cwd).returncode
    return time.monotonic() - start, code


def split_nim(args):
    """(flags, file, program_args) for nim r/c; the file is the first non-flag .nim arg."""
    rest = args[2:]
    for i, a in enumerate(rest):
        if not a.startswith("-") and a.endswith(".nim"):
            return rest[:i], a, rest[i + 1:]
    raise ValueError(args)


def main():
    shard, shards = int(sys.argv[1]), int(sys.argv[2])
    bins, _ = r.plan(r.load_manifest(), shards, r.load_durations())
    out_dir = r.ROOT / "tmp" / "ci-measure"
    out_dir.mkdir(parents=True, exist_ok=True)
    failed = 0
    for c in bins[shard]:
        cwd = r.ROOT / c.cwd
        args = shlex.split(c.command)
        cold = warm = run = 0.0
        status = "ok"
        print(f"::group::{c.command}", flush=True)
        if args[0] == "nim" and args[1] in ("r", "c"):
            flags, src, prog = split_nim(args)
            binary = out_dir / f"{Path(src).stem}-{c.index}{'.exe' if os.name == 'nt' else ''}"
            compile_args = ["nim", "c", *flags, f"-o:{binary}", src]
            cold, code = timed(compile_args, cwd)
            if code == 0:
                warm, code = timed(compile_args, cwd)
            if code != 0:
                status = f"compile-fail({code})"
            elif args[1] == "r":
                run, code = timed([str(binary), *prog], cwd)
                if code != 0:
                    status = f"run-fail({code})"
        else:
            run, code = timed(args, cwd)
            if code != 0:
                status = f"run-fail({code})"
        print("::endgroup::", flush=True)
        failed += status != "ok"
        print(f"MEASURE\t{c.command}\t{cold:.1f}\t{warm:.1f}\t{run:.1f}\t{status}", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
