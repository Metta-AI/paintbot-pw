"""Rebuild the CC0 Paintbot model in the public art checkout."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
art = Path(os.environ.get("POLYWORLD_ART", root.parent / "polyworld_art"))
subprocess.run([sys.executable, str(art / "paintbot/source/build_cover.py")], check=True)
