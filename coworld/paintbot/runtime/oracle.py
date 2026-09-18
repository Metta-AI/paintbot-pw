"""Host-side advisor oracle for WASM seats.

Seats stay sandboxed: they cannot open sockets. A seat may instead hand the host a JSON
question (`state` + `questions`) through the `paintbot.oracle_ask` import; the host posts it
to one operator-configured endpoint outside the sandbox and the seat collects the answer on
a later tick with `paintbot.oracle_poll`. Nothing here blocks a game tick.

Limits apply per seat: one request in flight, a minimum spacing in game ticks, bounded body
and answer sizes, and a hard wall-clock deadline after which the request is reported failed.
The endpoint, model and credential come only from the host environment; the guest chooses
neither. Without `COGAME_ORACLE_URL` every ask is refused, so certification pods that run
with no network behave exactly as before.
"""

from __future__ import annotations

import json
import os
import threading
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


@dataclass
class _Seat:
    last_tick: int = -(10**9)
    inflight: int | None = None
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
    ):
        self.url, self.key, self.model = url, key, model
        self.min_interval, self.deadline = min_interval, deadline
        self._pool = ThreadPoolExecutor(max_workers=workers)
        self._seats: dict[int, _Seat] = {}
        self._lock = threading.Lock()
        self.requests = self.failures = 0

    @classmethod
    def from_env(cls, env=os.environ) -> Oracle | None:
        url = env.get("COGAME_ORACLE_URL", "").strip()
        if not url.startswith("https://"):
            return None
        return cls(
            url,
            env.get("COGAME_ORACLE_KEY") or None,
            env.get("COGAME_ORACLE_MODEL", "jev-latest"),
            min_interval=int(env.get("COGAME_ORACLE_INTERVAL", "24")),
            deadline=float(env.get("COGAME_ORACLE_DEADLINE", "2")),
        )

    def _seat(self, slot: int) -> _Seat:
        return self._seats.setdefault(slot, _Seat())

    def ask(self, slot: int, tick: int, body: bytes) -> int:
        """Queue a request. Returns a request id >= 1, or 0 when refused (rate limit, in flight, bad body)."""
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
            if seat.inflight is not None or tick - seat.last_tick < self.min_interval:
                return 0
            request_id = seat.next_id
            seat.next_id += 1
            seat.inflight = request_id
            seat.last_tick = tick
            self.requests += 1
        self._pool.submit(self._call, slot, request_id, json.dumps(payload).encode())
        return request_id

    def poll(self, slot: int, request_id: int, capacity: int) -> tuple[int, bytes]:
        """(status, answer). status is the answer length when ready, else PENDING/FAILED/TOO_SMALL."""
        with self._lock:
            seat = self._seat(slot)
            if request_id == seat.inflight:
                return STATUS_PENDING, b""
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

    def _call(self, slot: int, request_id: int, payload: bytes) -> None:
        answer: bytes | None = None
        try:
            headers = {"Content-Type": "application/json"}
            if self.key:
                headers["Authorization"] = f"Bearer {self.key}"
            request = urllib.request.Request(self.url, data=payload, headers=headers, method="POST")
            with urllib.request.urlopen(request, timeout=self.deadline) as response:
                raw = response.read(MAX_ANSWER + 1)
            if len(raw) <= MAX_ANSWER:
                answers = json.loads(raw).get("answers")
                if isinstance(answers, dict):
                    answer = json.dumps(answers, separators=(",", ":")).encode()
        except (urllib.error.URLError, OSError, ValueError, TypeError):
            answer = None
        with self._lock:
            seat = self._seat(slot)
            if answer is None:
                self.failures += 1
            if seat.inflight == request_id:
                seat.inflight = None
            seat.answers[request_id] = answer
            while len(seat.answers) > MAX_STORED:
                del seat.answers[min(seat.answers)]

    def close(self) -> None:
        self._pool.shutdown(wait=False, cancel_futures=True)
