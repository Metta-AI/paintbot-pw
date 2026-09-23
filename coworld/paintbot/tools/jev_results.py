"""Read the win rate of Jev experiment arms from their hosted Experience Requests.

    python3 coworld/paintbot/tools/jev_results.py dist/jev-xp/requests.json

Win rate is the only usable statistic: the loser's glory is zeroed at the final tick, so every
episode reads as <winner> to 0 and the margin carries no information. Pairs of requests that
name the same arm on opposite sides are pooled, which is the point of running both.

Wilson interval at 95%, the same estimator the league tooling uses.
"""

from __future__ import annotations

import json
import math
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


def wilson(wins: int, n: int, z: float = 1.96) -> tuple[float, float, float]:
    if n == 0:
        return (0.0, 0.0, 1.0)
    p = wins / n
    d = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return p, max(0.0, centre - half), min(1.0, centre + half)


def fetch(xreq: str) -> dict:
    out = subprocess.run(["coworld", "xp-request", "get", xreq, "--json"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def main() -> None:
    # The API does not echo `notes` back, so which side the candidate took cannot be recovered
    # from the request. `jev_experiment.py --fire` records it; read that, never guess. Reading
    # the wrong column silently reports every win as a loss.
    manifest = json.loads(Path(sys.argv[1]).read_text())
    arms: dict[str, list[int]] = defaultdict(list)
    for xreq, meta in manifest.items():
        d = fetch(xreq)
        for episode in d.get("episodes", []):
            if episode.get("status") != "completed":
                continue
            by_position = {p["position"]: p["score"] for p in episode.get("participant_scores", [])}
            if 0 not in by_position or 1 not in by_position:
                continue
            even, odd = by_position[0], by_position[1]
            ours, theirs = (even, odd) if meta["candidate_even"] else (odd, even)
            if ours == theirs:
                continue
            key = meta["arm"] if "opponent" not in meta else f'{meta["arm"]} vs {meta["opponent"]}'
            arms[key].append(1 if ours > theirs else 0)

    width = max([16] + [len(a) for a in arms])
    print(f"{'arm':<{width}} {'n':>4} {'wins':>5} {'rate':>6}   95% Wilson")
    for arm, results in sorted(arms.items()):
        wins, n = sum(results), len(results)
        p, lo, hi = wilson(wins, n)
        flag = "" if lo <= 0.5 <= hi else "   <- separates from a coin flip"
        print(f"{arm:<{width}} {n:>4} {wins:>5} {p:>6.3f}   [{lo:.3f}, {hi:.3f}]{flag}")


if __name__ == "__main__":
    main()
