"""Host-side advisor oracle for BASIC seats.

Seats stay sandboxed inside the engine: they cannot open sockets. A BASIC seat instead drafts a
JSON question (`state` + `questions`) that the engine ships to the host in its per-tick bridge
line; the host posts it to one operator-configured endpoint outside the sandbox and returns the
answer over the bridge on a later tick (see `host.basic_oracle_round`). Nothing here blocks a
game tick.

Limits apply per seat: one request in flight, a minimum spacing in game ticks, bounded body
and answer sizes, and a hard wall-clock deadline after which the request is reported failed.
The endpoint, model and credential come only from the host environment; the guest chooses
neither. `COGAME_ORACLE_URL` names an endpoint directly (local play: TypeSafe, or OpenRouter's
`https://openrouter.ai/api/v1/systemone`, which serves the same wire format). Hosted Softmax
pods hold no provider key; there the platform's LLM sidecar does, at the reserved
`AWS_ENDPOINT_URL_BEDROCK_RUNTIME`, and the oracle posts to its `/v1/systemone` route naming the
asking seat in `X-Coworld-Player-Slot`, so spend and the request-rate bucket are charged to that
seat under the league's limits. With neither variable, or with `COGAME_ORACLE=off`, every ask is
refused, so certification pods that run with no network behave exactly as before.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

MAX_BODY = 32 * 1024
MAX_ANSWER = 64 * 1024
MAX_STORED = 4  # unread answers kept per seat before the oldest is dropped

STATUS_PENDING = 0
STATUS_FAILED = -1
STATUS_TOO_SMALL = -2

SIDECAR_ENV = "AWS_ENDPOINT_URL_BEDROCK_RUNTIME"  # historical name; the value is the sidecar's base URL
SIDECAR_PATH = "/v1/systemone"
# The sidecar takes canonical OpenRouter slugs only, so no moving `latest` alias here.
SIDECAR_MODEL = "typesafe/jev-1.13"
# System One asks have their own sidecar bucket of 120 a minute per player slot (four times the
# chat ceiling), so the game's own spacing of one ask a second per seat sits at half of it.
SIDECAR_INTERVAL = 24
SLOT_HEADER = "X-Coworld-Player-Slot"
LOGGED_FAILURES = 8
# `urlopen`'s timeout bounds each socket operation, not the request: a peer that drips its reply
# never trips it. Past this multiple of the deadline `poll` reports the request failed regardless.
DEADLINE_GRACE = 2.0
LOGGED_BODY = 300


@dataclass
class _Seat:
    last_tick: int = -(10**9)
    inflight: int | None = None
    started: float = 0.0  # monotonic time the in-flight request was queued
    answers: dict[int, bytes | None] = field(default_factory=dict)  # id -> bytes, or None = failed
    next_id: int = 1


class Oracle:
    def __init__(
        self,
        url: str,
        key: str | None = None,
        model: str = "jev-latest",
        *,
        min_interval: int = 24,
        deadline: float = 2.0,
        workers: int = 16,
        sidecar: bool = False,
        log_path: str | None = None,
    ):
        self.url, self.key, self.model = url, key, model
        self.min_interval, self.deadline = min_interval, deadline
        self.sidecar = sidecar
        self._route_missing = False
        self._reported = 0
        self._pool = ThreadPoolExecutor(max_workers=workers)
        self._seats: dict[int, _Seat] = {}
        self._lock = threading.Lock()
        self.requests = self.failures = 0
        # Optional JSONL journal of every request and its raw answers, for offline replay and scoring.
        self._log = None
        if log_path:
            descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            os.fchmod(descriptor, 0o600)
            self._log = os.fdopen(descriptor, "a", encoding="utf-8")

    @classmethod
    def from_env(cls, env=os.environ) -> Oracle | None:
        if env.get("COGAME_ORACLE", "").strip().lower() == "off":
            return None
        url = env.get("COGAME_ORACLE_URL", "").strip()
        base = env.get(SIDECAR_ENV, "").strip().rstrip("/")
        if url and not url.startswith("https://"):
            print("oracle: off, COGAME_ORACLE_URL must be https", file=sys.stderr)
            return None
        if not url and not base.startswith(("http://", "https://")):
            return None
        deadline = float(env.get("COGAME_ORACLE_DEADLINE", "2"))
        log_path = env.get("COGAME_ORACLE_LOG") or None
        if url:
            return cls(
                url,
                env.get("COGAME_ORACLE_KEY") or None,
                env.get("COGAME_ORACLE_MODEL", "jev-latest"),
                min_interval=int(env.get("COGAME_ORACLE_INTERVAL", "24")),
                deadline=deadline,
                log_path=log_path,
            )
        # The platform owns this variable (a game manifest cannot set it) and the sidecar is
        # pod-local, so plain http is expected here and nowhere else.
        return cls(
            base + SIDECAR_PATH,
            None,
            env.get("COGAME_ORACLE_MODEL", SIDECAR_MODEL),
            min_interval=int(env.get("COGAME_ORACLE_INTERVAL", str(SIDECAR_INTERVAL))),
            deadline=deadline,
            sidecar=True,
            log_path=log_path,
        )

    def _seat(self, slot: int) -> _Seat:
        return self._seats.setdefault(slot, _Seat())

    def ask(self, slot: int, tick: int, body: bytes, request_id: int | None = None) -> int:
        """Queue a request. Returns a request id >= 1, or 0 when refused (rate limit, in flight, bad
        body, or a hosted sidecar already found to have no System One route).

        The engine assigns ids for BASIC seats (`request_id`); a caller that passes none takes
        the seat's next id here.
        """
        if len(body) > MAX_BODY:
            return 0
        try:
            document = json.loads(body)
            if not isinstance(document, dict) or not isinstance(document.get("questions"), dict):
                return 0
            if "state" not in document or not 1 <= len(document["questions"]) <= 64:
                return 0
        except ValueError:
            return 0
        payload = {"state": document["state"], "questions": document["questions"], "model": self.model}
        with self._lock:
            seat = self._seat(slot)
            if self._route_missing or seat.inflight is not None or tick - seat.last_tick < self.min_interval:
                return 0
            if request_id is None:
                request_id = seat.next_id
                seat.next_id += 1
            elif request_id < 1 or request_id in seat.answers:
                return 0
            seat.inflight = request_id
            seat.started = time.monotonic()
            seat.last_tick = tick
            self.requests += 1
        self._pool.submit(self._call, slot, request_id, json.dumps(payload).encode(), tick)
        return request_id

    def poll(self, slot: int, request_id: int, capacity: int) -> tuple[int, bytes]:
        """(status, answer). status is the answer length when ready, else PENDING/FAILED/TOO_SMALL."""
        with self._lock:
            seat = self._seat(slot)
            if request_id == seat.inflight:
                if time.monotonic() - seat.started <= self.deadline * DEADLINE_GRACE:
                    return STATUS_PENDING, b""
                # Abandon it: the seat may ask again, and whatever the worker brings back late is dropped.
                seat.inflight = None
                self.failures += 1
                overdue = True
            else:
                overdue = False
        if overdue:
            self._report(slot, f"no complete reply within {self.deadline * DEADLINE_GRACE:g}s")
            return STATUS_FAILED, b""
        with self._lock:
            if request_id not in seat.answers:
                return STATUS_FAILED, b""
            answer = seat.answers[request_id]
            if answer is None:
                del seat.answers[request_id]
                return STATUS_FAILED, b""
            if len(answer) > capacity:
                return STATUS_TOO_SMALL, b""
            del seat.answers[request_id]
            return len(answer), answer

    def _call(self, slot: int, request_id: int, payload: bytes, tick: int | None = None) -> None:
        answer: bytes | None = None
        started = time.monotonic()
        try:
            answer = self._fetch(slot, payload)
        except Exception as e:  # noqa: BLE001 - whatever went wrong, the seat must not be left pending
            self._report(slot, f"{type(e).__name__}: {e}")
        finally:
            with self._lock:
                if self._log is not None:
                    row = {
                        "slot": slot,
                        "id": request_id,
                        "tick": tick,
                        "model": self.model,
                        "latency_ms": round((time.monotonic() - started) * 1000),
                        "request": json.loads(payload),
                        "answers": json.loads(answer) if answer is not None else None,
                    }
                    self._log.write(json.dumps(row, separators=(",", ":")) + "\n")
                    self._log.flush()
                seat = self._seat(slot)
                if seat.inflight != request_id:
                    return  # abandoned past the deadline, and already reported to the seat as failed
                seat.inflight = None
                if answer is None:
                    self.failures += 1
                seat.answers[request_id] = answer
                while len(seat.answers) > MAX_STORED:
                    del seat.answers[min(seat.answers)]

    def unusable(self, slot: int, what: str) -> None:
        """An answer arrived but nothing in it could be used; count and report it like any failure."""
        with self._lock:
            self.failures += 1
        self._report(slot, what)

    def _fetch(self, slot: int, payload: bytes) -> bytes | None:
        """The endpoint's `answers` as compact JSON, or None (reported) when there is no usable answer."""
        headers = {"Content-Type": "application/json"}
        if self.sidecar:
            headers[SLOT_HEADER] = str(slot)  # and no credential: the sidecar holds it, and is plain http
        elif self.key:
            headers["Authorization"] = f"Bearer {self.key}"
        request = urllib.request.Request(self.url, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.deadline) as response:
                raw = response.read(MAX_ANSWER + 1)
        except urllib.error.HTTPError as e:
            # A sidecar without the System One route answers 404 to every seat for the whole episode,
            # so stop asking. Nothing else stops it: a 429 is this seat's request ceiling (it clears in
            # seconds) or its spend limit (it does not, and the seat's asks fail for the rest of the
            # episode), and a 4xx or 5xx may be one seat's or one moment's problem.
            if self.sidecar and e.code in (404, 405, 501):
                with self._lock:
                    self._route_missing = True
            # The body names the cause (model not allowed, spend limit, route); a bare status does not.
            try:
                detail = e.read(LOGGED_BODY).decode("utf-8", "replace")
            except OSError as unread:
                detail = f"(body unread: {type(unread).__name__})"
            self._report(slot, f"HTTP {e.code} {detail}")
            return None
        if len(raw) > MAX_ANSWER:
            self._report(slot, f"answer exceeds {MAX_ANSWER} bytes")
            return None
        document = json.loads(raw)
        answers = document.get("answers") if isinstance(document, dict) else None
        if not isinstance(answers, dict):
            self._report(slot, f"reply has no answers object: {raw[:LOGGED_BODY].decode('utf-8', 'replace')}")
            return None
        return json.dumps(answers, separators=(",", ":")).encode()

    def _report(self, slot: int, what: str) -> None:
        """The first few failures go to the game log; an advised seat that silently plays unadvised
        scores like any other episode, so nothing else would show it."""
        with self._lock:
            self._reported += 1
            reported = self._reported
        if reported <= LOGGED_FAILURES:
            print(f"oracle: seat {slot} ask to {self.url} failed: {what}", file=sys.stderr)
        elif reported == LOGGED_FAILURES + 1:
            print("oracle: further failures are not logged; the closing line counts them", file=sys.stderr)

    def close(self) -> None:
        self._pool.shutdown(wait=False, cancel_futures=True)
        with self._lock:
            if self._log is not None:
                self._log.close()
                self._log = None


def _thousandths(value) -> int | None:
    try:
        return max(-(10**9), min(10**9, round(float(value) * 1000)))
    except (TypeError, ValueError, OverflowError):  # OverflowError: infinity, which JSON `1e999` parses to
        return None


def flatten(answers: dict, questions: dict) -> dict:
    """The endpoint's answers as the int32 view a BASIC seat reads (see oracle.nim).

    value: noul -> P(true) x 1000, score -> score x 1000, choice -> index in criterion order;
    confidence x 1000 (-1 when absent); probabilities per label x 1000 for choices. Anything
    malformed is left out so the seat sees it as missing rather than as a wrong number.
    """
    flat = {}
    for key, answer in answers.items():
        question = questions.get(key)
        if not isinstance(answer, dict) or not isinstance(question, dict):
            continue
        kind = question.get("type")
        value = None
        probabilities = {}
        if kind == "noul":
            value = _thousandths(answer.get("noul"))
        elif kind == "score":
            value = _thousandths(answer.get("score"))
        elif kind == "choice":
            labels = list(question.get("criteria") or {})
            if answer.get("choice") in labels:
                value = labels.index(answer["choice"])
            raw = answer.get("probabilities")
            for label, p in (raw.items() if isinstance(raw, dict) else ()):
                scaled = _thousandths(p)
                if label in labels and scaled is not None:
                    probabilities[label] = scaled
        if value is None:
            continue
        confidence = _thousandths(answer.get("confidence")) if "confidence" in answer else None
        flat[key] = {
            "value": value,
            "confidence": -1 if confidence is None else confidence,
            "probabilities": probabilities,
        }
    return flat
