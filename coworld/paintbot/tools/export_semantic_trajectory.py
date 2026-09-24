"""Join Paintbot's private BASIC oracle journal to executed Jev objective decisions.

The output is one ``CompleteEpisode`` JSONL row in the Coworld decision trajectory
contract. Only the Jev baseline's objective choice has an authoritative applied
directive in the policy log. Other oracle questions remain in the request/answer
evidence; this exporter does not invent executed actions for them.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from urllib.parse import unquote, urlparse
from uuid import NAMESPACE_URL, uuid5


def fields(line: str) -> dict[str, int]:
    return {key: int(value) for key, value in (part.split("=", 1) for part in line.split()[1:])}


def log_path(uri: str) -> Path:
    parsed = urlparse(uri)
    if parsed.scheme != "file" or parsed.netloc:
        raise ValueError("Training export requires local private player logs")
    return Path(unquote(parsed.path))


def read_seat(path: Path) -> dict[int, dict]:
    questions: dict[str, dict] = {}
    asks: dict[int, dict] = {}
    answers: dict[int, dict] = {}
    applied: dict[int, dict] = {}
    failures: dict[int, dict] = {}
    policy_asks: dict[int, dict] = {}
    outcomes: dict[int, dict] = {}
    for line in path.read_text().splitlines():
        if line.startswith("oracle-q "):
            _, key, body = line.split(" ", 2)
            digest = key.removeprefix("h=")
            question_set = json.loads(body)
            if digest in questions and questions[digest] != question_set:
                raise ValueError("Oracle question hash reused for different questions")
            questions[digest] = question_set
        elif line.startswith("oracle-ask "):
            _, identity, tick, question, state = line.split(" ", 4)
            request_id = int(identity.removeprefix("id="))
            if request_id in asks or question.removeprefix("q=") not in questions:
                raise ValueError("Duplicate oracle ask or missing question definition")
            asks[request_id] = {
                "tick": int(tick.removeprefix("t=")),
                "state": json.loads(state),
                "questions": questions[question.removeprefix("q=")],
            }
        elif line.startswith("oracle-ans "):
            _, identity, tick, status, body = line.split(" ", 4)
            request_id = int(identity.removeprefix("id="))
            if request_id in answers:
                raise ValueError("Duplicate oracle answer")
            answers[request_id] = {
                "tick": int(tick.removeprefix("t=")),
                "status": int(status.removeprefix("status=")),
                "body": json.loads(body),
            }
        elif line.startswith("ask t="):
            entry = fields(line)
            if entry["id"] in policy_asks:
                raise ValueError("Duplicate Jev policy ask")
            policy_asks[entry["id"]] = entry
        elif line.startswith("ans t="):
            entry = fields(line)
            if entry["id"] in applied:
                raise ValueError("Duplicate Jev policy answer")
            applied[entry["id"]] = entry
        elif line.startswith("fail t="):
            entry = fields(line)
            if entry["id"] in failures:
                raise ValueError("Duplicate Jev policy failure")
            failures[entry["id"]] = entry
        elif line.startswith("objout t="):
            entry = fields(line)
            if entry["id"] in outcomes:
                raise ValueError("Duplicate objective outcome")
            outcomes[entry["id"]] = entry
        elif line.startswith("score t="):
            raise ValueError("Score-arm decisions need a separate executed-action join")
    if set(policy_asks) != set(asks) or not set(answers | applied | failures | outcomes) <= set(asks):
        raise ValueError("Jev policy and oracle request IDs do not match")
    for request_id, ask in asks.items():
        policy_ask = policy_asks[request_id]
        if policy_ask["t"] != ask["tick"]:
            raise ValueError("Jev policy and oracle ask ticks differ")
        if request_id in applied and request_id in failures:
            raise ValueError("One oracle request cannot both apply and fail")
        if request_id in applied and (
            request_id not in answers or answers[request_id]["status"] < 1
        ):
            raise ValueError("Applied Jev advice requires a delivered oracle answer")
        if request_id in failures and request_id in answers and answers[request_id]["status"] >= 1:
            raise ValueError("Failed Jev advice has a successful oracle answer")
    return {
        request_id: {
            **ask,
            "answer": answers.get(request_id),
            "applied": applied.get(request_id),
            "failure": failures.get(request_id),
            "outcome": outcomes.get(request_id),
        }
        for request_id, ask in asks.items()
    }


def export(
    seats_path: Path,
    results_path: Path,
    output: Path,
    episode_id: str,
    source_revision: str,
) -> dict:
    roster = json.loads(seats_path.read_text())
    results = json.loads(results_path.read_text())
    seats = roster["seats"]
    if len(seats) != 16 or [seat["slot"] for seat in seats] != list(range(16)):
        raise ValueError("Paintbot training export requires all 16 ordered seats")
    if len(results["scores"]) != 16 or results["ticks"] < 1 or not episode_id:
        raise ValueError("Complete Paintbot results and an episode ID are required")
    if len(source_revision) != 40 or any(char not in "0123456789abcdef" for char in source_revision):
        raise ValueError("Pin the game to a 40-character source revision")
    decisions = []
    for seat in seats:
        slot = seat["slot"]
        policy = seat["content_hash"]
        if not policy.startswith("sha256:"):
            raise ValueError("Player policy must have a content hash")
        for request_id, record in read_seat(log_path(seat["log_uri"])).items():
            question = record["questions"]["objective"]
            if question["type"] != "choice":
                raise ValueError("Jev objective exporter requires a choice question")
            labels = list(question["criteria"])
            answer = record["answer"]
            effect = record["applied"]
            objective_answer = answer["body"].get("objective") if answer is not None else None
            if effect is not None and (
                effect["t"] < record["tick"]
                or effect["n"] != len(labels)
                or effect["rawobj"] != (objective_answer["v"] if objective_answer is not None else -1)
            ):
                raise ValueError("Policy objective differs from its delivered typed answer")
            if answer is not None and answer["tick"] < record["tick"]:
                raise ValueError("Oracle answer predates its request")
            chosen = effect["rawobj"] if effect is not None else -1
            if chosen < -1 or chosen >= len(labels):
                raise ValueError("Model selected an unknown objective")
            applied = bool(
                effect is not None
                and effect["applied"] == 1
                and effect["explored"] == 0
                and effect["ansobj"] == effect["rawobj"]
            )
            if effect is not None and effect["rawobj"] == len(labels) - 1 and effect["ansobj"] == effect["rawobj"] and effect["explored"] == 0:
                status = "accepted"
                reason = None
            elif applied:
                status = "accepted"
                reason = None
            elif effect is not None:
                status = "fallback"
                reason = "policy_override" if effect["ansobj"] != effect["rawobj"] else "objective_not_applied"
            else:
                status = "missing"
                reason = "oracle_failed" if record["failure"] is not None else "answer_not_consumed"
            attempt_id = f"{slot}:{request_id}:oracle"
            decision_id = f"slot:{slot}:oracle:{request_id}:objective"
            decisions.append(
                {
                    "schema_version": "1",
                    "event_type": "decision",
                    "event_id": str(uuid5(NAMESPACE_URL, episode_id + ":" + decision_id)),
                    "episode_id": episode_id,
                    "decision_id": decision_id,
                    "decision_index": 0,
                    "game": "paintbot-pw",
                    "source_revision": source_revision,
                    "seat": str(slot),
                    "visibility": "private",
                    "observation": record["state"],
                    "prompt": {"state": record["state"], "questions": record["questions"]},
                    "attempts": [
                        {
                            "attempt_id": attempt_id,
                            "policy": policy,
                            "origin": "model" if answer is not None and answer["status"] > 0 else "unknown",
                            "response": answer["body"] if answer is not None else None,
                            "parsed_action": {"choice": labels[chosen]} if chosen >= 0 else None,
                            "accepted": status == "accepted",
                            "rejection_reason": reason,
                            "latency_ms": None,
                        }
                    ],
                    "selected_attempt_id": attempt_id if status == "accepted" else None,
                    "executed_action": (
                        {
                            "objective_heart": effect["obj"],
                            "guard_heart": effect["guard"],
                            "objective_choice": labels[effect["ansobj"]],
                        }
                        if effect is not None and effect["applied"] == 1
                        else {"objective_choice": "current"}
                        if status == "accepted"
                        else None
                    ),
                    "action_status": status,
                    "fallback_origin": "paintbot-policy" if status == "fallback" else None,
                    "reward": record["outcome"] if applied else None,
                    "terminal": False,
                    "ask_tick": record["tick"],
                }
            )
    decisions.sort(key=lambda row: (row["ask_tick"], int(row["seat"]), row["decision_id"]))
    for index, decision in enumerate(decisions):
        del decision["ask_tick"]
        decision["decision_index"] = index
    episode = {
        "schema_version": "1",
        "event_type": "episode",
        "event_id": str(uuid5(NAMESPACE_URL, episode_id + ":episode")),
        "episode_id": episode_id,
        "game": "paintbot-pw",
        "source_revision": source_revision,
        "status": "completed",
        "outcome": results,
        "participant_outcomes": {"scores": results["scores"]},
    }
    complete = {"schema_version": "1", "episode": episode, "decisions": decisions}
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(json.dumps(complete, ensure_ascii=False, separators=(",", ":")) + "\n")
    return complete


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seats", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--episode-id", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    complete = export(args.seats, args.results, args.output, args.episode_id, args.source_revision)
    print(json.dumps({"decisions": len(complete["decisions"]), "output": str(args.output)}))


if __name__ == "__main__":
    main()
