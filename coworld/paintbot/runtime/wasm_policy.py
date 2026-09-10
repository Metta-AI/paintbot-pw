"""Paintbot file-policy loading and isolated Wasmtime reactor instances."""

from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path
from urllib.parse import unquote, urlsplit
from urllib.request import urlopen

import wasmtime

MAX_FILE = 100 * 1024 * 1024
MAX_FRAME = 16 * 1024 * 1024
MAX_REPLY = 64 * 1024


def local_path(uri: str) -> Path:
    parsed = urlsplit(uri)
    if parsed.scheme == "file" and parsed.netloc in ("", "localhost"):
        return Path(unquote(parsed.path))
    if not parsed.scheme:
        return Path(uri)
    raise ValueError("output must be a local path or file URI")


def read_uri(uri: str, limit: int = MAX_FILE) -> bytes:
    parsed = urlsplit(uri)
    if parsed.scheme in ("", "file"):
        with local_path(uri).open("rb") as source:
            data = source.read(limit + 1)
    elif parsed.scheme == "https":
        with urlopen(uri, timeout=30) as source:
            data = source.read(limit + 1)
    elif parsed.scheme == "s3":
        import boto3
        from botocore.config import Config

        client = boto3.client(
            "s3",
            config=Config(
                connect_timeout=10, read_timeout=30, retries={"max_attempts": 2}
            ),
        )
        response = client.get_object(
            Bucket=parsed.netloc, Key=unquote(parsed.path.lstrip("/"))
        )
        try:
            data = response["Body"].read(limit + 1)
        finally:
            response["Body"].close()
            client.close()
    else:
        raise ValueError("supported policy URI schemes: file, https, s3")
    if len(data) > limit:
        raise ValueError(f"file exceeds {limit} bytes")
    return data


def load_seats(uri: str) -> dict:
    document = json.loads(read_uri(uri, 1024 * 1024))
    if document.get("schema") != "coworld-player-seats/1":
        raise ValueError("expected coworld-player-seats/1")
    seats = document["seats"]
    if not 1 <= len(seats) <= 32 or [s["slot"] for s in seats] != list(
        range(len(seats))
    ):
        raise ValueError("seats must be contiguous, ordered slots 0..N-1, with N <= 32")
    local_path(document["player_status_uri"])
    for seat in seats:
        local_path(seat["log_uri"])
        if (
            not isinstance(seat["size_bytes"], int)
            or not 0 <= seat["size_bytes"] <= MAX_FILE
        ):
            raise ValueError("invalid policy size")
    return document


def verified_policy(seat: dict) -> bytes:
    data = read_uri(seat["file_uri"])
    if (
        len(data) != seat["size_bytes"]
        or "sha256:" + hashlib.sha256(data).hexdigest() != seat["content_hash"]
    ):
        raise ValueError(
            f"policy file size or SHA-256 mismatch for slot {seat['slot']}"
        )
    return data


def write_json(uri: str, document: dict) -> None:
    path = local_path(uri)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(document, indent=2) + "\n")
    temporary.replace(path)


def decode_replies(data: bytes) -> list[bytes]:
    if len(data) < 4 or len(data) > MAX_REPLY:
        raise ValueError("invalid reply buffer size")
    count = struct.unpack_from("<I", data)[0]
    if count > 64:
        raise ValueError("too many reply packets")
    offset, replies = 4, []
    for _ in range(count):
        if offset + 4 > len(data):
            raise ValueError("truncated reply length")
        size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        if size == 0 or offset + size > len(data):
            raise ValueError("truncated or empty reply packet")
        reply = data[offset : offset + size]
        # A policy may control its actuator mask and shout, never join or claim another seat.
        if not (
            (reply[0] == 0x84 and size == 2) or (reply[0] == 0x81 and size <= 1024)
        ):
            raise ValueError("unsupported player reply packet")
        if reply[0] == 0x81 and (
            size < 3 or struct.unpack_from("<H", reply, 1)[0] != size - 3
        ):
            raise ValueError("invalid chat packet length")
        replies.append(reply)
        offset += size
    if offset != len(data):
        raise ValueError("trailing reply bytes")
    return replies


class Policy:
    """Use and close on its owning thread. No filesystem, environment, or network grants."""

    def __init__(self, engine: wasmtime.Engine, module: wasmtime.Module, slot: int):
        self.store = wasmtime.Store(engine)
        self.store.set_limits(
            memory_size=256 * 1024 * 1024, memories=1, tables=4, instances=2
        )
        self.store.set_wasi(wasmtime.WasiConfig())
        self.store.set_fuel(20_000_000_000)
        self.store.set_epoch_deadline(6000)
        linker = wasmtime.Linker(engine)
        linker.define_wasi()
        try:
            self.instance = linker.instantiate(self.store, module)
            self.exports = self.instance.exports(self.store)
            self.memory = self.exports["memory"]
            if not isinstance(self.memory, wasmtime.Memory):
                raise TypeError("missing exported memory")
            expected = {
                "paintbot_init": (["i32"], []),
                "paintbot_buffer": (["i32"], ["i32"]),
                "paintbot_step": ([], ["i32"]),
                "paintbot_output_size": ([], ["i32"]),
            }
            for name, signature in expected.items():
                function = self.exports[name]
                if not isinstance(function, wasmtime.Func):
                    raise TypeError(f"missing function {name}")
                t = function.type(self.store)
                if (
                    [str(v) for v in t.params],
                    [str(v) for v in t.results],
                ) != signature:
                    raise ValueError(f"wrong signature for {name}")
            if "_initialize" in self.exports:
                self.exports["_initialize"](self.store)
            self.exports["paintbot_init"](self.store, slot)
        except BaseException:
            self.store.close()
            raise
        finally:
            linker.close()

    def step(self, frame: bytes) -> list[bytes]:
        if len(frame) > MAX_FRAME:
            raise ValueError("observation exceeds 16 MiB")
        self.store.set_fuel(20_000_000_000)
        self.store.set_epoch_deadline(
            3000
        )  # 30 seconds at the host's 10 ms epoch cadence.
        ptr = self.exports["paintbot_buffer"](self.store, len(frame))
        self._check_range(ptr, len(frame))
        self.memory.write(self.store, frame, ptr)
        ptr = self.exports["paintbot_step"](self.store)
        size = self.exports["paintbot_output_size"](self.store)
        if not 4 <= size <= MAX_REPLY:
            raise ValueError("policy reply exceeds limits")
        self._check_range(ptr, size)
        return decode_replies(bytes(self.memory.read(self.store, ptr, ptr + size)))

    def _check_range(self, ptr: int, size: int) -> None:
        if ptr < 0 or ptr + size > self.memory.data_len(self.store):
            raise ValueError("policy returned an out-of-bounds pointer")

    def close(self) -> None:
        self.store.close()
