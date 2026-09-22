"""Paintbot seat documents: fetch, verify and stage each seat's BASIC source file."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from urllib.parse import unquote, urlsplit
from urllib.request import urlopen

MAX_FILE = 100 * 1024 * 1024  # download bound; the BASIC source limit is checked by the host


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
