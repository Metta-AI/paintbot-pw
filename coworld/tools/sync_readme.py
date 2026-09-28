"""Copy coworld/paintbot/guide.md into the Paintbot manifest's inline game.docs.readme.

    python3 coworld/tools/sync_readme.py          # rewrite the manifest
    python3 coworld/tools/sync_readme.py --check  # exit 1 if they differ

The manifest carries the player guide inline (Coworld shows it on the game page), so guide.md
is the source and this keeps the copy verbatim. coworld/paintbot/test_runtime.py checks it.
"""

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUIDE = ROOT / "coworld/paintbot/guide.md"
MANIFEST = ROOT / "coworld/paintbot/coworld_manifest_template.json"


def synced_manifest() -> str:
    """The manifest text with the readme replaced by guide.md, in the file's own formatting."""
    manifest = json.loads(MANIFEST.read_text())
    manifest["game"]["docs"]["readme"] = {"type": "text", "value": GUIDE.read_text()}
    return json.dumps(manifest, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if the readme is stale")
    args = parser.parse_args()
    text = synced_manifest()
    if text == MANIFEST.read_text():
        return 0
    if args.check:
        print(f"{MANIFEST.relative_to(ROOT)}: readme differs from guide.md; run {Path(__file__).name}", file=sys.stderr)
        return 1
    MANIFEST.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
