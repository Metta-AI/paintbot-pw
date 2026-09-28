"""Verify that the Paintbot bundle uses inventoried CC0 art and open fonts."""

import hashlib
import json
from pathlib import Path, PurePosixPath
import struct
import sys

ROOT = Path(__file__).resolve().parents[3]
FONT_FILES = {"fonts/Rubik-Regular.ttf", "fonts/Rubik-Bold.ttf"}
EXTRA_FILES = FONT_FILES | {"paintbot/art/paint-crew.png"}


class PaintbotArtError(Exception):
    """Describe a missing, changed, or incompatible Paintbot asset."""


def verify(art, selection=None):
    """Validate the shipped files and every external model dependency."""
    art = Path(art)
    selection = selection or ROOT / "examples/paintbot/webdata.txt"
    try:
        catalog = json.loads((art / "licenses/assets.json").read_text())
        entries = {entry["path"]: entry for entry in catalog["files"]}
        pending = [name.strip() for name in Path(selection).read_text().splitlines()
                   if name.strip() and not name.lstrip().startswith("#")]
        pending.extend(sorted(EXTRA_FILES))
        checked = set()
        while pending:
            name = pending.pop()
            if name in checked:
                continue
            relative = PurePosixPath(name)
            if relative.is_absolute() or ".." in relative.parts or "\\" in name:
                raise PaintbotArtError(f"Invalid art path: {name}")
            if name not in entries:
                raise PaintbotArtError(f"Art is not in the reviewed inventory: {name}")
            entry = entries[name]
            expected = "OFL-1.1" if name in FONT_FILES else "CC0-1.0"
            if entry["license"] != expected:
                raise PaintbotArtError(f"Expected {expected} for {name}; got {entry['license']}")
            source = catalog["sources"][entry["source"]]
            if source["license"] != expected or not (art / source["notice"]).is_file():
                raise PaintbotArtError(f"Missing or incompatible source notice: {name}")
            path = art / name
            if not path.resolve().is_relative_to(art.resolve()):
                raise PaintbotArtError(f"Asset escapes the art checkout: {name}")
            data = path.read_bytes()
            if data.startswith(b"version https://git-lfs.github.com/spec/v1"):
                raise PaintbotArtError(f"LFS content missing for {name}; run git lfs pull")
            if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
                raise PaintbotArtError(f"Asset differs from its reviewed digest: {name}")
            if relative.suffix == ".glb":
                magic, version, total, length, kind = struct.unpack_from("<IIIII", data)
                if (magic, version, total, kind) != (0x46546C67, 2, len(data), 0x4E4F534A):
                    raise PaintbotArtError(f"Invalid GLB header: {name}")
                document = json.loads(data[20:20 + length])
                for field in ("images", "buffers"):
                    for item in document.get(field, []):
                        uri = item.get("uri", "")
                        if not uri or uri.startswith("data:"):
                            continue
                        if ":" in uri or uri.startswith("/"):
                            raise PaintbotArtError(f"External model URL in {name}: {uri}")
                        dependency = relative.parent / uri
                        pending.append(dependency.as_posix())
            checked.add(name)
        return checked
    except (OSError, ValueError, KeyError, TypeError, struct.error) as error:
        raise PaintbotArtError(f"Cannot verify Paintbot art: {error}") from error


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify_art.py <polyworld_art checkout>")
    files = verify(sys.argv[1])
    print(f"Verified {len(files) - len(FONT_FILES)} CC0 assets and {len(FONT_FILES)} OFL fonts.")
