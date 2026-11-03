"""Self-contained Linux replay worker build/test entry for the CI shard runner."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "linux":
        print("Replay debugger requires Linux fd3/procfs and libcrypto; not supported on this OS")
        return
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="replay-debugger-", dir=os.environ.get("TMPDIR")) as tmp:
        build = Path(tmp)
        env = dict(os.environ, PW_TEST_REPLAY_DEBUGGER=str(build / "worker"))
        for source, name in [("examples/paintbot/replay_debugger.nim", "worker"),
                             ("tests/test_paintbot_debugger.nim", "tests")]:
            subprocess.run(["nim", "c", "-d:headless", "-d:release", "--hints:off",
                            f"--nimcache:{build / ('cache-' + name)}", f"-o:{build / name}", source],
                           cwd=root, env=env, check=True)
        subprocess.run([str(build / "tests")], cwd=root, env=env, check=True)


if __name__ == "__main__":
    main()
