"""Build the Jev experiment arms and their hosted Experience Request bodies.

    python3 coworld/paintbot/tools/jev_experiment.py --coworld-id cow_xxxxxxxx --out dist/jev-xp

Each arm is `players/jev.bas` with one group of switches flipped, so a run separates one change
at a time instead of measuring the whole rewrite at once.

The design follows what 100 hosted episodes on this Coworld established (see the guide,
"Comparing two builds on hosted episodes"):

- **Head-to-head against the shipped build, not against the plain baseline.** Two advised arms
  that could not be told apart from each other both beat `paintbot-pw-basic` 20 of 20, so a
  battery against it is pure ceiling and carries no information. `a0-vs-baseline` is the one
  exception, a sanity arm that only asks whether the shipped build still beats the baseline.
- **Every arm is split into equal halves with the sides swapped**, so each arm is two requests.
  Not because Red is favoured - rules 35 mirrored the map - but because 60 head-to-head
  episodes came out 35/60 to the even side from noise alone, which is the size of the effects
  these batteries chase. An unbalanced battery measures the draw.
- **Win rate is the right statistic *here*.** The loser's glory is zeroed at the final tick, so
  the gap between the two scores only restates who won. The winner's own glory is a real
  measure of how fast the win was, and against an opponent an arm nearly always beats that is
  what to compare - but these arms are close to each other, so each has a glory number only for
  the games it won and the means are over selected, non-comparable subsets. Count paired wins
  and take a Wilson interval.
- **`episode_player_llm_spend_limit_usd` is not optional.** A seat with no budget has no
  advisor, plays as the baseline and still scores, so the request looks healthy and measures
  nothing.

At 60 episodes an arm's Wilson interval is about +/-0.12: enough to reject a 70/30 effect, not
enough to separate 0.62 from a coin flip. Raise `--episodes` to about 250 to claim a win that
size; episodes are cheap and run in parallel, so the limit is patience.

The Coworld id must be a version carrying the structured oracle API (path state keys,
`oracleCriterionField`, `oracleReady`). Against an older version the arms do not compile and
every seat fails, so the tool refuses to write bodies without one.

Prints the upload and create commands; it runs nothing itself.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
JEV = ROOT / "coworld/paintbot/players/jev.bas"
VARIANT = "competition"
BASELINE = "paintbot-pw-basic-v22:v1"   # the league's plain BASIC filler
SEATS = 16
EPISODES = 60            # 30 a side; about +/-0.12 Wilson. ~250 to call a 0.62 effect.
SPEND_LIMIT_USD = 0.50

REFERENCE = "a1-structured"

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
    "a6-no-retreat": ("dropping the retreat choice and break-off dial, which went live on the "
                      "thinnest margin the rules allow (0.553 over 360, [0.501, 0.603]) and is "
                      "the first switch to re-examine", {"useRetreat": 0, "useDial": 0}),
    "a7-echo": ("the old echoing relay, where every adopter repeats the callout, as the control "
                "arm for the one-voice change", {"useEcho": 1}),
}


def arm_source(base: str, overrides: dict[str, int]) -> str:
    out = base
    for name, value in overrides.items():
        pattern = re.compile(rf"^  {name} = -?\d+$", re.MULTILINE)
        found = pattern.findall(out)
        assert len(found) == 1, f"{name}: expected one init line, found {len(found)}"
        out = pattern.sub(f"  {name} = {value}", out)
    return out


def body(*, coworld_id: str, candidate: str, opponent: str, candidate_even: bool,
         episodes: int, note: str) -> dict:
    """All sixteen seats pinned: even seats are Red, odd are Blue."""
    roster = []
    for slot in range(SEATS):
        even = slot % 2 == 0
        ref = candidate if even == candidate_even else opponent
        roster.append({"slot": slot, "player": {"policy_ref": ref}})
    return {
        "target": {"coworld_id": coworld_id, "variant_id": VARIANT},
        "roster": roster,
        "num_episodes": episodes,
        "execution_backend": "k8s",
        "episode_player_llm_spend_limit_usd": SPEND_LIMIT_USD,
        "notes": note,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coworld-id", required=True,
                        help="uploaded paintbot-pw version carrying the structured oracle API")
    parser.add_argument("--out", default="dist/jev-xp", help="directory for arm files and bodies")
    parser.add_argument("--episodes", type=int, default=EPISODES,
                        help="episodes per arm, split evenly between the two side assignments")
    parser.add_argument("--fire", action="store_true",
                        help="create the requests and record them in requests.json")
    args = parser.parse_args()

    assert args.episodes % 2 == 0, "episodes must be even so the two side halves are equal"
    half = args.episodes // 2

    out = ROOT / args.out
    out.mkdir(parents=True, exist_ok=True)
    base = JEV.read_text(encoding="utf-8")
    assert "oracleReady()" in base, f"{JEV} predates the readiness probe; regenerate it first"

    def policy(arm: str) -> str:
        return f"jev-{arm}:v1"

    print(f"# {len(ARMS)} arms, {args.episodes} episodes each ({half} a side), "
          f"head-to-head against {REFERENCE}\n")
    for arm, (purpose, overrides) in ARMS.items():
        bas = out / f"{arm}.bas"
        bas.write_text(arm_source(base, overrides), encoding="utf-8")
        flips = ", ".join(f"{k}={v}" for k, v in overrides.items()) or "shipped defaults"
        print(f"# {arm}: {flips}")
        print(f"coworld upload-policy --file {bas.relative_to(ROOT)} --name jev-{arm}")

    print()
    for arm, (purpose, _) in ARMS.items():
        # The reference arm has nothing to play against itself; check it against the baseline.
        opponent = BASELINE if arm == REFERENCE else policy(REFERENCE)
        against = "the plain BASIC baseline" if arm == REFERENCE else REFERENCE
        for candidate_even in (True, False):
            side = "even" if candidate_even else "odd"
            name = f"{arm}-{side}"
            note = (f"jev arm {arm} vs {against}, candidate on {side} seats, {half} episodes: "
                    f"{purpose}")
            path = out / f"{name}.json"
            path.write_text(json.dumps(
                body(coworld_id=args.coworld_id, candidate=policy(arm), opponent=opponent,
                     candidate_even=candidate_even, episodes=half, note=note), indent=2) + "\n")
            print(f"coworld xp-request create {path.relative_to(ROOT)}")

    if args.fire:
        # The manifest is the only record of which side each candidate took: the API returns
        # `notes` as null, so a reader that infers the side from the request scores every win as
        # a loss. Write it before reading anything back.
        manifest = {}
        for arm in ARMS:
            for side in ("even", "odd"):
                path = out / f"{arm}-{side}.json"
                result = subprocess.run(["coworld", "xp-request", "create", str(path)],
                                        capture_output=True, text=True)
                found = re.search(r"xreq_[0-9a-f-]{36}", result.stdout)
                if not found:
                    print(f"{arm}-{side}: FAILED {result.stdout.strip()[:120]}")
                    continue
                manifest[found.group(0)] = {"arm": arm, "candidate_even": side == "even"}
                print(f"{arm}-{side}: {found.group(0)}")
        (out / "requests.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"\nwrote {out / 'requests.json'} with {len(manifest)} requests")
        print(f"score with: python3 coworld/paintbot/tools/jev_results.py "
              f"{(out / 'requests.json').relative_to(ROOT)}")
        return

    print("\n# then: coworld xp-request list --mine")
    print("# per request: coworld xp-request get <xreq_id> --json")
    print("# instrument check before trusting a score, per arm:")
    print("#   coworld episode-logs <ereq_id> -d logs/ && grep -c '^ans ' logs/*  "
          "# a seat whose asks all fail plays as the baseline and still scores")


if __name__ == "__main__":
    main()
