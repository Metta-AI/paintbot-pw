"""Copy coworld/paintbot/guide.md into the Paintbot manifest's inline game.docs.readme.

    python3 coworld/tools/sync_readme.py          # rewrite the manifest
    python3 coworld/tools/sync_readme.py --check  # exit 1 if they differ

The manifest carries the player guide inline (Coworld shows it on the game page), so guide.md
is the source. Sections between <!-- readme:skip-start --> and <!-- readme:skip-end --> lines
are for operators (private exports, hosted A/B recipes, campaign notes) and stay out of the
player-facing copy; everything else is copied verbatim. coworld/paintbot/test_runtime.py
checks the manifest matches.
"""

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUIDE = ROOT / "coworld/paintbot/guide.md"
MANIFEST = ROOT / "coworld/paintbot/coworld_manifest_template.json"


SKIP_START = "<!-- readme:skip-start -->"
SKIP_END = "<!-- readme:skip-end -->"


def player_readme(guide: str) -> str:
    """guide.md without its marked operator sections (each marker line and the blank line after
    an end marker go too). Unbalanced or nested markers are an error, not a silent leak."""
    out, skipping, after_end = [], False, False
    for number, line in enumerate(guide.splitlines(keepends=True), 1):
        marker = line.strip()
        if marker == SKIP_START:
            if skipping:
                raise ValueError(f"guide.md:{number}: nested {SKIP_START}")
            skipping = True
        elif marker == SKIP_END:
            if not skipping:
                raise ValueError(f"guide.md:{number}: {SKIP_END} without a start")
            skipping, after_end = False, True
        elif not skipping:
            if not (after_end and marker == ""):
                out.append(line)
            after_end = False
    if skipping:
        raise ValueError(f"guide.md: {SKIP_START} is never closed")
    return "".join(out)


def synced_manifest() -> str:
    """The manifest text with the readme replaced by the player guide, in the file's own formatting."""
    manifest = json.loads(MANIFEST.read_text())
    manifest["game"]["docs"]["readme"] = {"type": "text", "value": player_readme(GUIDE.read_text())}
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
