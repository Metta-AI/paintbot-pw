"""Compress shared assets and install the Paintbot startup loader."""

import gzip
import re
import sys
from pathlib import Path


def package(output: Path) -> None:
    data = (output / "paintbot.data").read_bytes()
    if data != (output / "play/paintbot.data").read_bytes():
        raise ValueError("Replay/live asset layouts differ")
    # Crowd builds (s<N>/, Heartland Big) load the same artwork package.
    for crowd in sorted(output.glob("s[0-9]*/paintbot.data")):
        if crowd.read_bytes() != data:
            raise ValueError(f"{crowd.parent.name} asset layout differs from the replay viewer's")
        crowd.unlink()
    (output / "paintbot.data.gz").write_bytes(
        gzip.compress(data, compresslevel=9, mtime=0)
    )
    loader = (output / "startup.js").read_text()
    (output / "play/startup.js").write_text(loader)
    for directory in (output, output / "play"):
        html = (directory / "index.html").read_text()
        replacement = '<script src="startup.js"></script>'
        if directory.name == "play":
            replacement = (
                '<script>Module.assetPackage="../paintbot.data.gz";</script>'
                + replacement
            )
        html, count = re.subn(
            r'<script[^>]*src="paintbot\.js"[^>]*></script>', replacement, html
        )
        if count != 1:
            raise ValueError(f"Expected one generated script tag in {directory}")
        (directory / "index.html").write_text(html)
        (directory / "paintbot.data").unlink()
    print(
        f"Artwork: {len(data):,} raw bytes -> {(output / 'paintbot.data.gz').stat().st_size:,} gzip bytes"
    )


if __name__ == "__main__":
    package(Path(sys.argv[1]))
