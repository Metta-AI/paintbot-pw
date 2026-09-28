"""Exercise the art gate with changed bytes and restricted dependencies."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "paintbot_art", ROOT / "coworld/paintbot/tools/verify_art.py"
)
ART = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ART)


def rejects(root, selection, message):
    """Require a rejected bundle and its actionable reason."""
    try:
        ART.verify(root, selection)
    except ART.PaintbotArtError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError("An invalid art bundle passed verification")


def main():
    """Keep the release gate closed for unreviewed or changed artwork."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "licenses").mkdir()
        (root / "LICENSE").write_text("Fixture notice")
        files = []
        sources = {}
        for name in sorted(ART.EXTRA_FILES | {"terrain/test.png"}):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture")
            license = "OFL-1.1" if name in ART.FONT_FILES else "CC0-1.0"
            sources[license] = {"license": license, "notice": "LICENSE"}
            files.append({"path": name, "source": license, "license": license,
                          "bytes": 7, "sha256": hashlib.sha256(b"fixture").hexdigest()})
        catalog = root / "licenses/assets.json"
        document = {"files": files, "sources": sources}
        catalog.write_text(json.dumps(document))
        selection = root / "webdata.txt"
        selection.write_text("terrain/test.png\n")
        assert len(ART.verify(root, selection)) == 4
        (root / "terrain/test.png").write_bytes(b"changed")
        rejects(root, selection, "reviewed digest")
        (root / "terrain/test.png").write_bytes(b"fixture")
        entry = next(item for item in files if item["path"] == "terrain/test.png")
        entry["license"] = "Unity-Asset-Store"
        catalog.write_text(json.dumps(document))
        rejects(root, selection, "Expected CC0-1.0")
        selection.write_text("../private/model.glb\n")
        rejects(root, selection, "Invalid art path")
        selection.write_text("terrain/unreviewed.png\n")
        rejects(root, selection, "not in the reviewed inventory")
    print("Paintbot art provenance gate passed")


main()
