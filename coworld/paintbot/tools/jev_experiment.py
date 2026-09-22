"""Build the Jev experiment arms and their hosted Experience Request bodies.

    python3 coworld/paintbot/tools/jev_experiment.py --coworld-id cow_xxxxxxxx --out dist/jev-xp

Each arm is `players/jev.bas` with one group of switches flipped, so a run separates one change
at a time instead of measuring the whole rewrite at once. Every arm faces the same opponent over
the same number of episodes with the same seat layout, which is what makes the margins
comparable; the notes field carries the arm name so `coworld xp-request list --mine` reads as a
table of the experiment.

The Coworld id must be a version that carries the structured oracle API (path state keys,
`oracleCriterionField`, `oracleReady`). Against an older version the arm files do not compile
and every seat fails, so the tool refuses to write bodies without one.

Prints the upload and create commands; it runs nothing itself.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
JEV = ROOT / "coworld/paintbot/players/jev.bas"
LEAGUE = "league_b9458ff8-0854-4e21-82b8-3c99942902e0"
OPPONENT = "paintbot-pw-basic-r22"   # the game's own BASIC baseline, champion in the league
SEATS = 16
EPISODES = 24            # 8 was never enough to separate two arms; 24 full-length games was
SPEND_LIMIT_USD = 0.10   # a measured Jev game costs about $0.016 across all its seats

# name -> (what the arm tests, switch overrides)
ARMS: dict[str, tuple[str, dict[str, int]]] = {
    "a1-structured": ("the structured draft as shipped: fields instead of sentences, five "
                      "questions in one request", {}),
    "a2-no-nouls": ("whether the three extra yes/no questions cost anything in play",
                    {"useNouls": 0}),
    "a3-score": ("valuing each candidate on its own scale instead of choosing between them",
                 {"useScore": 1}),
    "a4-margin": ("hysteresis: switch objective only when the top candidate beats `current` by "
                  "a margin in probability", {"kMargin": 150}),
    "a5-wide": ("the wider objective list at full length, now that the options are structured",
                {"useWide": 1}),
    "a6-retreat": ("the retreat choice and break-off dial, now that retSent and the question's "
                   "polarity are fixed", {"useRetreat": 1, "useDial": 1}),
    "a7-echo": ("squadmates repeating the callout they adopted, which reaches past the 12.8 m "
                "shout radius but pins the hold and the leader-takeover timer open",
                {"useEcho": 1}),
}


def arm_source(base: str, overrides: dict[str, int]) -> str:
    out = base
    for name, value in overrides.items():
        pattern = re.compile(rf"^  {name} = -?\d+$", re.MULTILINE)
        found = pattern.findall(out)
        assert len(found) == 1, f"{name}: expected one init line, found {len(found)}"
        out = pattern.sub(f"  {name} = {value}", out)
    return out


def roster() -> list[dict]:
    """Even slots are the candidate, odd slots the opponent: in Paintbot PW slot parity is the
    team, so this is one policy against the other with no seat advantage either way."""
    return [
        {"player": ({"policy_ref": "%CANDIDATE%"} if slot % 2 == 0 else {"top_n": 1}),
         "slot": slot}
        for slot in range(SEATS)
    ]


def body(arm: str, coworld_id: str, purpose: str) -> dict:
    return {
        "idempotency_key": f"jev-{arm}-{coworld_id}",
        "coworld_id": coworld_id,
        "roster": roster(),
        "included_players": [OPPONENT],
        "num_episodes": EPISODES,
        "episode_player_llm_spend_limit_usd": SPEND_LIMIT_USD,
        "notes": f"jev experiment arm {arm}: {purpose}",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coworld-id", required=True,
                        help="uploaded paintbot-pw version carrying the structured oracle API")
    parser.add_argument("--out", default="dist/jev-xp", help="directory for arm files and bodies")
    args = parser.parse_args()

    out = ROOT / args.out
    out.mkdir(parents=True, exist_ok=True)
    base = JEV.read_text()
    assert "oracleReady()" in base, f"{JEV} predates the readiness probe; regenerate it first"

    print(f"# {len(ARMS)} arms, {EPISODES} episodes each, opponent {OPPONENT}\n")
    for arm, (purpose, overrides) in ARMS.items():
        source = arm_source(base, overrides)
        bas = out / f"{arm}.bas"
        bas.write_text(source)
        name = f"daveey1-jev-{arm}"
        request = body(arm, args.coworld_id, purpose)
        text = json.dumps(request, indent=2).replace("%CANDIDATE%", f"{name}:v1")
        (out / f"{arm}.json").write_text(text + "\n")
        flips = ", ".join(f"{k}={v}" for k, v in overrides.items()) or "shipped defaults"
        print(f"# {arm}: {flips}")
        print(f"coworld upload-policy --file {bas.relative_to(ROOT)} --name {name}")
        print(f"coworld xp-request create {(out / f'{arm}.json').relative_to(ROOT)}\n")
    print("# then: coworld xp-request list --mine")
    print("# and per arm: coworld xp-request episodes <xreq_id>")


if __name__ == "__main__":
    main()
