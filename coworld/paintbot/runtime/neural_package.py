"""Bounded neural BASIC package staging. No archive paths are extracted."""
import hashlib
import io
import json
import zipfile

MAX_MODEL_BYTES = 16 * 1024 * 1024
MAX_SOURCE_BYTES = 128 * 1024  # matches maxSourceBytes in bots.nim
MAX_MANIFEST_BYTES = 8192
# Schema 1: bundles built against action contract v1. Schema 2: the same three files;
# the manifest may name action contract v2 (lead-compensated identity aim), which only
# hosts that know schema 2 can decode. Both stay accepted; the actor's own embedded
# contract hashes are what the host binds and decodes by.
SCHEMA = "paintbot-neural-basic/1"
SCHEMAS = ("paintbot-neural-basic/1", "paintbot-neural-basic/2")
# Schema-2 decoder options: "decoder": {"fire_hold_teammates": true, "sampling": {...},
# "forbid_objectives": [9, 10], "strafe_legs": {...}, "aim_snap": {"max_angle_deg": 22.5},
# "steady_shot": {}, "aim_retarget": {"max_range": 5250, "hp_weight": 160000, "carry_weight": 2500000},
# "shot_gate": {"max_range": 5250}}.
# Every key must be one the host knows and every value the declared type, so a bundle
# asking for an option this release lacks is rejected at staging rather than played
# without it. The rules here mirror neural_host.nim's exactly.
DECODER_OPTIONS = {"fire_hold_teammates": bool, "sampling": dict, "forbid_objectives": list, "strafe_legs": dict,
                   "aim_snap": dict, "steady_shot": dict, "aim_retarget": dict, "shot_gate": dict}
SAMPLING_HEADS = 5
MIN_SAMPLING_TEMPERATURE, MAX_SAMPLING_TEMPERATURE = 0.01, 10.0
OBJECTIVE_CANDIDATES = 51  # movement-head size in both action contracts
MAX_STRAFE_RANGE, MAX_STRAFE_LEG_TICKS, MIN_STRAFE_SHOT_LEG_TICKS = 20000, 72, 6
DEFAULT_AIM_SNAP_DEG, MAX_AIM_SNAP_MILLIDEG = 22.5, 90000
STEADY_MOVEMENT = 0  # the movement-head index the steady shot stands the seat on
# decoder.aim_retarget defaults are base.bas's target rule; decoder.shot_gate's is the gun range.
AIM_RETARGET_DEFAULTS = {"max_range": 5250, "hp_weight": 160000, "carry_weight": 2500000}
MAX_RETARGET_RANGE, MAX_RETARGET_WEIGHT = 20000, 1000000000
SHOT_GATE_DEFAULTS = {"max_range": 5250}
MAX_SHOT_GATE_RANGE = 20000


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def validate_forbid_objectives(value):
    """decoder.forbid_objectives: distinct movement-head indices 0 .. 50, at least one left allowed."""
    if not isinstance(value, list) or not value:
        raise ValueError("decoder.forbid_objectives must be a non-empty array")
    for item in value:
        if not _is_int(item) or not 0 <= item < OBJECTIVE_CANDIDATES:
            raise ValueError("decoder.forbid_objectives entries must be objective indices 0 .. %d" % (OBJECTIVE_CANDIDATES - 1))
    if len(set(value)) != len(value):
        raise ValueError("decoder.forbid_objectives repeats an index")
    if len(value) >= OBJECTIVE_CANDIDATES:
        raise ValueError("decoder.forbid_objectives must leave an objective allowed")


def validate_strafe_legs(value):
    """decoder.strafe_legs: {"range": r, "legs": [min, max], "shot_legs": [min, max], "reverse_permille": p},
    every field optional (5250, [3, 6], [6, 9], 800)."""
    if not isinstance(value, dict):
        raise ValueError("decoder.strafe_legs must be an object")
    options = {"range": 5250, "legs": [3, 6], "shot_legs": [6, 9], "reverse_permille": 800}
    for key, field in value.items():
        if key in ("range", "reverse_permille"):
            if not _is_int(field):
                raise ValueError("decoder.strafe_legs.%s must be an integer" % key)
        elif key in ("legs", "shot_legs"):
            if not isinstance(field, list) or len(field) != 2:
                raise ValueError("decoder.strafe_legs.%s must be [min, max]" % key)
            if not all(_is_int(item) for item in field):
                raise ValueError("decoder.strafe_legs.%s must be an integer" % key)
        else:
            raise ValueError("unknown decoder.strafe_legs field: " + str(key))
        options[key] = field
    if not 1 <= options["range"] <= MAX_STRAFE_RANGE:
        raise ValueError("decoder.strafe_legs.range must be within 1 .. %d" % MAX_STRAFE_RANGE)
    low, high = options["legs"]
    if not 1 <= low <= high <= MAX_STRAFE_LEG_TICKS:
        raise ValueError("decoder.strafe_legs.legs must be [min, max] with 1 <= min <= max <= %d" % MAX_STRAFE_LEG_TICKS)
    low, high = options["shot_legs"]
    if not MIN_STRAFE_SHOT_LEG_TICKS <= low <= high <= MAX_STRAFE_LEG_TICKS:
        raise ValueError("decoder.strafe_legs.shot_legs must be [min, max] with %d <= min <= max <= %d"
                         % (MIN_STRAFE_SHOT_LEG_TICKS, MAX_STRAFE_LEG_TICKS))
    if not 0 <= options["reverse_permille"] <= 1000:
        raise ValueError("decoder.strafe_legs.reverse_permille must be within 0 .. 1000")


def validate_aim_snap(value):
    """decoder.aim_snap: {"max_angle_deg": a}, a optional (22.5), a multiple of 0.001 within 0.001 .. 90."""
    if not isinstance(value, dict):
        raise ValueError("decoder.aim_snap must be an object")
    for key, field in value.items():
        if key != "max_angle_deg":
            raise ValueError("unknown decoder.aim_snap field: " + str(key))
        if isinstance(field, bool) or not isinstance(field, (int, float)):
            raise ValueError("decoder.aim_snap.max_angle_deg must be a number")
        try:
            scaled = float(field) * 1000
        except OverflowError:
            scaled = float("inf")
        if scaled != scaled or not 0.5 <= scaled <= MAX_AIM_SNAP_MILLIDEG + 0.5 or abs(scaled - round(scaled)) > 1e-6:
            raise ValueError("decoder.aim_snap.max_angle_deg must be a multiple of 0.001 within 0.001 .. 90")


def validate_steady_shot(value):
    """decoder.steady_shot: {} (no parameters)."""
    if not isinstance(value, dict):
        raise ValueError("decoder.steady_shot must be an object")
    for key in value:
        raise ValueError("unknown decoder.steady_shot field: " + str(key))


def validate_aim_retarget(value):
    """decoder.aim_retarget: {"max_range": r, "hp_weight": h, "carry_weight": c}, every field optional
    (5250, 160000, 2500000), integers with r within 1 .. 20000 and h, c within 0 .. 1e9."""
    if not isinstance(value, dict):
        raise ValueError("decoder.aim_retarget must be an object")
    options = dict(AIM_RETARGET_DEFAULTS)
    for key, field in value.items():
        if key not in AIM_RETARGET_DEFAULTS:
            raise ValueError("unknown decoder.aim_retarget field: " + str(key))
        if not _is_int(field):
            raise ValueError("decoder.aim_retarget.%s must be an integer" % key)
        options[key] = field
    if not 1 <= options["max_range"] <= MAX_RETARGET_RANGE:
        raise ValueError("decoder.aim_retarget.max_range must be within 1 .. %d" % MAX_RETARGET_RANGE)
    for key in ("hp_weight", "carry_weight"):
        if not 0 <= options[key] <= MAX_RETARGET_WEIGHT:
            raise ValueError("decoder.aim_retarget.%s must be within 0 .. %d" % (key, MAX_RETARGET_WEIGHT))
    return options


def validate_shot_gate(value):
    """decoder.shot_gate: {"max_range": r}, r optional (5250), an integer within 1 .. 20000."""
    if not isinstance(value, dict):
        raise ValueError("decoder.shot_gate must be an object")
    options = dict(SHOT_GATE_DEFAULTS)
    for key, field in value.items():
        if key not in SHOT_GATE_DEFAULTS:
            raise ValueError("unknown decoder.shot_gate field: " + str(key))
        if not _is_int(field):
            raise ValueError("decoder.shot_gate.%s must be an integer" % key)
        options[key] = field
    if not 1 <= options["max_range"] <= MAX_SHOT_GATE_RANGE:
        raise ValueError("decoder.shot_gate.max_range must be within 1 .. %d" % MAX_SHOT_GATE_RANGE)
    return options


def validate_sampling(value):
    """decoder.sampling: {"mode": "categorical", "temperature": t, "heads": [i, ...]}."""
    if not isinstance(value, dict):
        raise ValueError("decoder.sampling must be an object")
    if value.get("mode") != "categorical":
        raise ValueError('decoder.sampling.mode must be "categorical"')
    for key, field in value.items():
        if key == "mode":
            continue
        if key == "temperature":
            if isinstance(field, bool) or not isinstance(field, (int, float)):
                raise ValueError("decoder.sampling.temperature must be a number")
            if not (MIN_SAMPLING_TEMPERATURE <= field <= MAX_SAMPLING_TEMPERATURE):
                raise ValueError("decoder.sampling.temperature must be within [0.01, 10]")
        elif key == "heads":
            if not isinstance(field, list) or not field:
                raise ValueError("decoder.sampling.heads must be a non-empty array")
            for item in field:
                if isinstance(item, bool) or not isinstance(item, int) or not 0 <= item < SAMPLING_HEADS:
                    raise ValueError("decoder.sampling.heads entries must be head indices 0 .. %d" % (SAMPLING_HEADS - 1))
            if len(set(field)) != len(field):
                raise ValueError("decoder.sampling.heads repeats a head")
        else:
            raise ValueError("unknown decoder.sampling field: " + str(key))


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
            if key == "sampling":
                validate_sampling(value)
            elif key == "forbid_objectives":
                validate_forbid_objectives(value)
            elif key == "strafe_legs":
                validate_strafe_legs(value)
            elif key == "aim_snap":
                validate_aim_snap(value)
            elif key == "steady_shot":
                validate_steady_shot(value)
            elif key == "aim_retarget":
                validate_aim_retarget(value)
            elif key == "shot_gate":
                validate_shot_gate(value)
        if "steady_shot" in decoder and STEADY_MOVEMENT in decoder.get("forbid_objectives", []):
            raise ValueError("decoder.steady_shot needs movement index 0, which decoder.forbid_objectives forbids")
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
