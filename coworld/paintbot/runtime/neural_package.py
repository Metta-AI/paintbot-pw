"""Bounded neural BASIC package staging. No archive paths are extracted."""
import hashlib
import io
import json
import zipfile

MAX_MODEL_BYTES = 16 * 1024 * 1024
MAX_SOURCE_BYTES = 64 * 1024
MAX_MANIFEST_BYTES = 8192
# Schema 1: bundles built against action contract v1. Schema 2: the same three files;
# the manifest may name action contract v2 (lead-compensated identity aim), which only
# hosts that know schema 2 can decode. Both stay accepted; the actor's own embedded
# contract hashes are what the host binds and decodes by.
SCHEMA = "paintbot-neural-basic/1"
SCHEMAS = ("paintbot-neural-basic/1", "paintbot-neural-basic/2")
# Schema-2 decoder options: "decoder": {"fire_hold_teammates": true}. Every key must be
# one the host knows and every value the declared type, so a bundle asking for an option
# this release lacks is rejected at staging rather than played without it.
DECODER_OPTIONS = {"fire_hold_teammates": bool}


def unpack_package(data):
    """Return validated (source, model, manifest); only three fixed files are allowed."""
    if len(data) > MAX_MODEL_BYTES + MAX_SOURCE_BYTES + MAX_MANIFEST_BYTES + 4096:
        raise ValueError("neural package exceeds size limit")
    limits = {"manifest.json": MAX_MANIFEST_BYTES, "policy.bas": MAX_SOURCE_BYTES,
              "model.bin": MAX_MODEL_BYTES}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        if len(entries) != 3 or {e.filename for e in entries} != set(limits):
            raise ValueError("package must contain exactly manifest.json, policy.bas, model.bin")
        files = {}
        for entry in entries:
            if entry.flag_bits & 1 or entry.file_size > limits[entry.filename]:
                raise ValueError("encrypted or oversized package entry")
            with archive.open(entry) as stream:
                payload = stream.read(limits[entry.filename] + 1)
            if len(payload) > limits[entry.filename]:
                raise ValueError("oversized package entry")
            files[entry.filename] = payload
    manifest = json.loads(files["manifest.json"])
    if not isinstance(manifest, dict) or manifest.get("schema") not in SCHEMAS:
        raise ValueError("unsupported neural package schema")
    if not isinstance(manifest.get("sha256"), dict):
        raise ValueError("neural package sha256 must be an object")
    for name in ("policy.bas", "model.bin"):
        digest = hashlib.sha256(files[name]).hexdigest()
        if manifest.get("sha256", {}).get(name) != digest:
            raise ValueError("neural package hash mismatch: " + name)
    for field in ("observation_contract", "action_contract"):
        digest = manifest.get(field, "")
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValueError("invalid contract hash")
    if "decoder" in manifest:
        if manifest.get("schema") != "paintbot-neural-basic/2":
            raise ValueError("decoder options need package schema 2")
        decoder = manifest["decoder"]
        if not isinstance(decoder, dict):
            raise ValueError("decoder options must be an object")
        for key, value in decoder.items():
            if key not in DECODER_OPTIONS:
                raise ValueError("unknown decoder option: " + str(key))
            if type(value) is not DECODER_OPTIONS[key]:
                raise ValueError("decoder." + key + " must be a " + DECODER_OPTIONS[key].__name__)
    files["policy.bas"].decode("utf-8")
    if not files["model.bin"]:
        raise ValueError("empty neural model")
    return files["policy.bas"], files["model.bin"], manifest


def stage_package(data, source_path):
    source, model, manifest = unpack_package(data)
    source_path.write_bytes(source)
    source_path.with_name(source_path.name + ".model.bin").write_bytes(model)
    source_path.with_name(source_path.name + ".neural.json").write_text(json.dumps(manifest))
    return source
