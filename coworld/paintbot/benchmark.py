# /// script
# requires-python = ">=3.11"
# dependencies = ["pydantic>=2,<3", "wasmtime==48.0.0"]
# ///
"""Paired advisor ablation through the hosted Paintbot handoff, without paid defaults."""

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, Field


class Results(BaseModel):
    scores: list[float] = Field(min_length=16, max_length=16)
    ticks: int
    seed: int
    outcome: str


class Request(BaseModel):
    state: object
    questions: dict[str, object]
    model: str


class JournalRow(BaseModel):
    slot: int = Field(ge=0, lt=16)
    id: int = Field(ge=1)
    tick: int = Field(ge=0)
    latency_ms: float = Field(ge=0)
    request: Request
    answers: dict[str, object] | None


class Episode(BaseModel):
    seed: int
    candidate_team: int
    advisor: Literal["off", "on"]
    directory: str
    scores: list[float]
    candidate_score: float
    opponent_score: float
    outcome: str
    ticks: int
    wall_seconds: float
    policy_failure: bool
    completed_requests: int
    failed_requests: int
    latency_mean_ms: float | None
    latency_p95_ms: float | None
    estimated_completed_request_cost_usd: float | None
    artifacts: dict[str, str]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--opponent", type=Path, required=True)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--seeds", type=int, nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ticks", type=int, default=14400)
    parser.add_argument("--tick-seconds", type=float, default=1 / 24)
    parser.add_argument("--interval", type=int, default=24)
    parser.add_argument("--deadline", type=float, default=2)
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--model", default="typesafe/jev-1.13")
    parser.add_argument("--cost-per-request-usd", type=float)
    parser.add_argument("--port", type=int, default=8088)
    args = parser.parse_args()
    if not os.environ.get("COGAME_ORACLE_URL") and not os.environ.get(
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME"
    ):
        parser.error(
            "Set COGAME_ORACLE_URL or AWS_ENDPOINT_URL_BEDROCK_RUNTIME explicitly"
        )
    if len(set(args.seeds)) != len(args.seeds):
        parser.error("Seeds must be unique")
    if (
        args.ticks < 1
        or args.interval < 1
        or args.deadline <= 0
        or args.tick_seconds < 0
        or args.timeout <= 0
    ):
        parser.error(
            "Ticks, interval, deadline and timeout must be positive; pacing must be nonnegative"
        )
    if args.cost_per_request_usd is not None and args.cost_per_request_usd < 0:
        parser.error("Cost must be nonnegative")
    numeric = [args.tick_seconds, args.deadline, args.timeout]
    if args.cost_per_request_usd is not None:
        numeric.append(args.cost_per_request_usd)
    if not all(math.isfinite(value) for value in numeric):
        parser.error("Timing and cost values must be finite")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    engine = args.engine.resolve()
    # Freeze exactly the same policy bytes for all pairs, even if the source is rebuilt mid-run.
    policies = {}
    for role, source in (("candidate", args.candidate), ("opponent", args.opponent)):
        destination = output / (role + source.suffix)
        destination.write_bytes(source.read_bytes())
        policies[role] = destination
    endpoint = urlsplit(
        os.environ.get("COGAME_ORACLE_URL")
        or os.environ["AWS_ENDPOINT_URL_BEDROCK_RUNTIME"]
    )
    manifest = {
        "endpoint": {
            "scheme": endpoint.scheme,
            "host": endpoint.hostname,
            "port": endpoint.port,
            "path": endpoint.path,
        },
        "runtime": {
            "python": sys.version,
            "wasmtime": importlib.metadata.version("wasmtime"),
            "pydantic": importlib.metadata.version("pydantic"),
        },
        "source_sha256": {
            str(path.relative_to(root)): digest(path)
            for path in [
                Path(__file__).resolve(),
                root / "coworld/paintbot/local.py",
                *sorted((root / "coworld/paintbot/runtime").glob("*.py")),
            ]
        },
        "schema": "paintbot-advisor-benchmark/1",
        "revision": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip(),
        "working_diff_sha256": hashlib.sha256(
            subprocess.check_output(["git", "diff", "HEAD"], cwd=root)
        ).hexdigest(),
        "engine": {"path": str(engine), "sha256": digest(engine)},
        "policies": {
            role: {"path": str(path), "sha256": digest(path)}
            for role, path in policies.items()
        },
        "parameters": {
            key: str(value) if isinstance(value, Path) else value
            for key, value in vars(args).items()
        },
        "cost_basis": "User-supplied estimate per completed request, including failures; not provider billing. Null means unknown.",
        "journal_coverage": "Completed requests only, after deadline + 1s drain; accepted or cancelled requests are not counted.",
        "treatment": "Global oracle on/off; opponent must not ask. Candidate occupies all eight seats of each team in turn.",
        "status": "running",
        "episodes": [],
        "pairs": [],
    }
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    episodes = []
    for seed in args.seeds:
        for team in (0, 1):
            pair = {}
            # Counterbalance order across teams and seeds to reduce temporal provider drift.
            modes = (
                ("off", "on")
                if (args.seeds.index(seed) + team) % 2 == 0
                else ("on", "off")
            )
            for mode in modes:
                directory = output / f"seed-{seed}-team-{team}-{mode}"
                command = [
                    sys.executable,
                    str(root / "coworld/paintbot/local.py"),
                    "--engine",
                    str(engine),
                    "--seed",
                    str(seed),
                    "--ticks",
                    str(args.ticks),
                    "--output",
                    str(directory),
                    "--port",
                    str(args.port),
                    "--timeout",
                    str(args.timeout),
                    "--drain-seconds",
                    str(args.deadline + 1 if mode == "on" else 0),
                ]
                for slot in range(16):
                    command.extend(
                        [
                            "--policy",
                            str(
                                policies[
                                    "candidate" if slot % 2 == team else "opponent"
                                ]
                            ),
                        ]
                    )
                env = dict(
                    os.environ,
                    COGAME_ORACLE=mode,
                    COGAME_ORACLE_MODEL=args.model,
                    COGAME_ORACLE_INTERVAL=str(args.interval),
                    COGAME_ORACLE_DEADLINE=str(args.deadline),
                    COGAME_TICK_SECONDS=str(args.tick_seconds),
                    COGAME_ORACLE_LOG=str(directory / "oracle.jsonl"),
                )
                # Do not inherit internal engine switches from an interactive debugging session.
                env.pop("PW_ORACLE", None)
                env.pop("PW_ORACLE_INTERVAL", None)
                started = time.monotonic()
                completed = subprocess.run(
                    command, env=env, capture_output=True, text=True, check=False
                )
                (output / f"{directory.name}.log").write_text(
                    completed.stdout + completed.stderr
                )
                completed.check_returncode()
                result = Results.model_validate_json(
                    (directory / "results.json").read_text()
                )
                assert result.seed == seed
                journal = directory / "oracle.jsonl"
                rows = (
                    [
                        JournalRow.model_validate_json(line)
                        for line in journal.read_text().splitlines()
                    ]
                    if journal.exists()
                    else []
                )
                if mode == "on" and not rows:
                    raise ValueError(
                        "Advisor-on episode produced no requests; this is not an advisor comparison"
                    )
                if any(row.slot % 2 != team for row in rows):
                    raise ValueError(
                        "Opponent requested advice; use a non-advisor opponent to isolate the candidate treatment"
                    )
                if any(row.request.model != args.model for row in rows):
                    raise ValueError("Journal model does not match the benchmark model")
                if mode == "off" and rows:
                    raise ValueError("Advisor-off episode produced requests")
                latencies = sorted(row.latency_ms for row in rows)
                episode = Episode(
                    seed=seed,
                    candidate_team=team,
                    advisor=mode,
                    directory=directory.name,
                    scores=result.scores,
                    candidate_score=statistics.mean(result.scores[team::2]),
                    opponent_score=statistics.mean(result.scores[1 - team :: 2]),
                    outcome=result.outcome,
                    ticks=result.ticks,
                    wall_seconds=time.monotonic() - started,
                    policy_failure=(directory / "failure.json").exists(),
                    completed_requests=len(rows),
                    failed_requests=sum(row.answers is None for row in rows),
                    latency_mean_ms=statistics.mean(latencies) if latencies else None,
                    latency_p95_ms=latencies[math.ceil(0.95 * len(latencies)) - 1]
                    if latencies
                    else None,
                    estimated_completed_request_cost_usd=(
                        len(rows) * args.cost_per_request_usd
                        if args.cost_per_request_usd is not None
                        else None
                    ),
                    artifacts={
                        path.name: digest(path)
                        for path in directory.iterdir()
                        if path.is_file()
                    },
                )
                pair[mode] = episode
                episodes.append(episode)
                manifest["episodes"] = [episode.model_dump() for episode in episodes]
                manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            manifest["pairs"].append(
                {
                    "seed": seed,
                    "candidate_team": team,
                    "score_delta": pair["on"].candidate_score
                    - pair["off"].candidate_score,
                    "margin_delta": (
                        pair["on"].candidate_score - pair["on"].opponent_score
                    )
                    - (pair["off"].candidate_score - pair["off"].opponent_score),
                }
            )
    manifest["mean_paired_score_delta"] = statistics.mean(
        pair["score_delta"] for pair in manifest["pairs"]
    )
    manifest["mean_paired_margin_delta"] = statistics.mean(
        pair["margin_delta"] for pair in manifest["pairs"]
    )
    if digest(engine) != manifest["engine"]["sha256"]:
        raise ValueError("Engine changed during benchmark")
    manifest["status"] = (
        "policy_failure"
        if any(episode.policy_failure for episode in episodes)
        else "complete"
    )
    if any(
        episode.advisor == "on"
        and episode.failed_requests == episode.completed_requests
        for episode in episodes
    ):
        manifest["status"] = "advisor_failure"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(manifest_path)
    if manifest["status"] != "complete":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
