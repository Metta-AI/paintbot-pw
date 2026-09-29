"""Bounded neural BASIC package staging. No archive paths are extracted."""
import array
import hashlib
import io
import json
import math
import struct
import sys
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
# Schema-2 decoder options: "decoder": {"fire_hold_teammates": true (or {"radius": 150}), "sampling": {...},
# "forbid_objectives": [9, 10], "strafe_legs": {...}, "aim_snap": {"max_angle_deg": 22.5},
# "steady_shot": {}, "aim_retarget": {"max_range": 5250, "hp_weight": 160000, "carry_weight": 2500000},
# "shot_gate": {"max_range": 5250}, "spray_aim": {"max_range": 850},
# "spray_gate": {"max_teammates": 0, "min_enemies": 1},
# "joint_sampling": {"when": {"head": 2, "value": 1}, "head": 0, "offsets": [51 numbers]}}.
# Every key must be one the host knows and every value the declared type, so a bundle
# asking for an option this release lacks is rejected at staging rather than played
# without it. The rules here mirror neural_host.nim's exactly.
DECODER_OPTIONS = {"fire_hold_teammates": (bool, dict), "sampling": dict, "forbid_objectives": list, "strafe_legs": dict,
                   "aim_snap": dict, "steady_shot": dict, "aim_retarget": dict, "shot_gate": dict,
                   "spray_aim": dict, "spray_gate": dict, "joint_sampling": dict}
ACTION_SIZES = (51, 25, 2, 2, 2)  # both action contracts
MAX_JOINT_OFFSET = 1000
SAMPLING_HEADS = 5
MIN_SAMPLING_TEMPERATURE, MAX_SAMPLING_TEMPERATURE = 0.01, 10.0
OBJECTIVE_CANDIDATES = 51  # movement-head size in both action contracts
MAX_STRAFE_RANGE, MAX_STRAFE_LEG_TICKS, MIN_STRAFE_SHOT_LEG_TICKS = 20000, 72, 6
DEFAULT_AIM_SNAP_DEG, MAX_AIM_SNAP_MILLIDEG = 22.5, 90000
STEADY_MOVEMENT = 0  # the movement-head index the steady shot stands the seat on
# decoder.aim_retarget defaults are base.bas's target rule; decoder.shot_gate's is the gun range.
# decoder.fire_hold_teammates: true = the hold at the gun's hit tolerance (55 units); the object form
# {"radius": r} turns the hold on at radius r (optional, 55), an integer within 1 .. 2000.
DEFAULT_FIRE_HOLD_RADIUS, MAX_FIRE_HOLD_RADIUS = 55, 2000
AIM_RETARGET_DEFAULTS = {"max_range": 5250, "hp_weight": 160000, "carry_weight": 2500000}
MAX_RETARGET_RANGE, MAX_RETARGET_WEIGHT = 20000, 1000000000
SHOT_GATE_DEFAULTS = {"max_range": 5250}
# decoder.spray_aim / decoder.spray_gate (a ready spray can only): the spray reach, and a cone with at least
# one enemy and no teammate.
SPRAY_AIM_DEFAULTS = {"max_range": 850}
SPRAY_GATE_DEFAULTS = {"max_teammates": 0, "min_enemies": 1}
SPRAY_LIMITS = {"max_range": (1, 850), "max_teammates": (0, 7), "min_enemies": (0, 8)}
MAX_SHOT_GATE_RANGE = 20000
# Manifest "user_inputs": {"count": K, "init": [K ints]} (schema 2; PLAN-neural-basic-io part A): policy.bas feeds
# the net K extra inputs with neuralInput(i, v), v clamped to +-1,000,000 and fed as float32(v) / 1000 one tick
# later. The actor's observation contract is then v2u<K> (v2's 506 floats + K), whose hash is the SHA-256 of the id
# below, and its input count is 506 + K. neural_host.nim holds the same rules.
MAX_USER_INPUTS, USER_INPUT_LIMIT = 128, 1000000
OBSERVATION_V2_SIZE = 506
# Observation contract v3 (teams game): v2's 506 floats, then an 8-float scoreboard block (neural_contract.nim
# encodeScoreboardBlock). v3u<K> = v3 + K user inputs, exactly as v2u<K> is to v2.
OBSERVATION_V3_SIZE = 514
OBSERVATION_CONTRACT_V3 = "paintbot-pw.rules43.obs.v3.float514"
OBSERVATION_CONTRACT_V3_HASH = hashlib.sha256(OBSERVATION_CONTRACT_V3.encode()).hexdigest()
ACTOR_MAGIC = b"PWNET001"


def user_inputs_contract_id(count):
    return "paintbot-pw.rules39.obs.v2u%d" % count


def v3_user_inputs_contract_id(count):
    return "paintbot-pw.rules43.obs.v3u%d" % count


USER_INPUTS_CONTRACT_HASHES = {hashlib.sha256(user_inputs_contract_id(k).encode()).hexdigest(): k
                               for k in range(1, MAX_USER_INPUTS + 1)}
V3_USER_INPUTS_CONTRACT_HASHES = {hashlib.sha256(v3_user_inputs_contract_id(k).encode()).hexdigest(): k
                                  for k in range(1, MAX_USER_INPUTS + 1)}


def validate_user_inputs(value):
    """user_inputs: {"count": K, "init": [K ints]}, K within 1 .. 128, init values within +-1,000,000. Returns K."""
    if not isinstance(value, dict):
        raise ValueError("user_inputs must be an object")
    for key in value:
        if key not in ("count", "init"):
            raise ValueError("unknown user_inputs field: " + str(key))
    if "count" not in value:
        raise ValueError("user_inputs.count is required")
    count = value["count"]
    if not _is_int(count) or not 1 <= count <= MAX_USER_INPUTS:
        raise ValueError("user_inputs.count must be an integer within 1 .. %d" % MAX_USER_INPUTS)
    if "init" not in value:
        raise ValueError("user_inputs.init is required")
    init = value["init"]
    if not isinstance(init, list):
        raise ValueError("user_inputs.init must be an array")
    for item in init:
        if not _is_int(item) or not -USER_INPUT_LIMIT <= item <= USER_INPUT_LIMIT:
            raise ValueError("user_inputs.init entries must be integers within -%d .. %d" % (USER_INPUT_LIMIT, USER_INPUT_LIMIT))
    if len(init) != count:
        raise ValueError("user_inputs.init must have user_inputs.count entries")
    return count


def actor_header(model):
    """(input count, observation contract hash) from a PWNET001 or PWNET002 actor's header; ValueError when it is
    neither (a PWNET002 model is fully validated here, validate_pwnet2)."""
    if model[:8] == PWNET2_MAGIC:
        info = validate_pwnet2(model)
        return info["inputs"], info["observation_contract"]
    if len(model) < 96 or model[:8] != ACTOR_MAGIC:
        raise ValueError("invalid neural actor magic")
    return int.from_bytes(model[12:16], "little"), model[32:96].decode("ascii", "replace")


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


def validate_fire_hold(value):
    """decoder.fire_hold_teammates: a bool, or {"radius": r} with r optional (55), an integer within 1 .. 2000.
    Returns (enabled, radius)."""
    if isinstance(value, bool):
        return value, DEFAULT_FIRE_HOLD_RADIUS
    if not isinstance(value, dict):
        raise ValueError("decoder.fire_hold_teammates must be a bool or an object")
    radius = DEFAULT_FIRE_HOLD_RADIUS
    for key, field in value.items():
        if key != "radius":
            raise ValueError("unknown decoder.fire_hold_teammates field: " + str(key))
        if not _is_int(field):
            raise ValueError("decoder.fire_hold_teammates.radius must be an integer")
        if not 1 <= field <= MAX_FIRE_HOLD_RADIUS:
            raise ValueError("decoder.fire_hold_teammates.radius must be within 1 .. %d" % MAX_FIRE_HOLD_RADIUS)
        radius = field
    return True, radius


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


def _validate_int_fields(name, value, defaults):
    if not isinstance(value, dict):
        raise ValueError("decoder.%s must be an object" % name)
    options = dict(defaults)
    for key, field in value.items():
        if key not in defaults:
            raise ValueError("unknown decoder.%s field: %s" % (name, key))
        if not _is_int(field):
            raise ValueError("decoder.%s.%s must be an integer" % (name, key))
        options[key] = field
    for key, field in options.items():
        low, high = SPRAY_LIMITS[key]
        if not low <= field <= high:
            raise ValueError("decoder.%s.%s must be within %d .. %d" % (name, key, low, high))
    return options


def validate_spray_aim(value):
    """decoder.spray_aim: {"max_range": r}, r optional (850), an integer within 1 .. 850."""
    return _validate_int_fields("spray_aim", value, SPRAY_AIM_DEFAULTS)


def validate_spray_gate(value):
    """decoder.spray_gate: {"max_teammates": t, "min_enemies": e}, both optional (0, 1), integers,
    t within 0 .. 7 and e within 0 .. 8."""
    return _validate_int_fields("spray_gate", value, SPRAY_GATE_DEFAULTS)


def validate_joint_sampling(value):
    """decoder.joint_sampling: {"when": {"head": h, "value": v}, "head": g, "offsets": [...]} (neural_host.nim
    parseJointSampling): h != g head indices, v a choice of head h, ACTION_SIZES[g] finite numbers in [-1000, 1000]."""
    def head_index(x, name):
        if isinstance(x, bool) or not isinstance(x, int) or not 0 <= x < len(ACTION_SIZES):
            raise ValueError("decoder.joint_sampling.%s must be a head index 0 .. %d" % (name, len(ACTION_SIZES) - 1))
        return x
    for key in value:
        if key not in ("when", "head", "offsets"):
            raise ValueError("unknown decoder.joint_sampling field: " + str(key))
    if not all(k in value for k in ("when", "head", "offsets")):
        raise ValueError("decoder.joint_sampling needs when, head and offsets")
    when = value["when"]
    if not isinstance(when, dict):
        raise ValueError("decoder.joint_sampling.when must be an object")
    for key in when:
        if key not in ("head", "value"):
            raise ValueError("unknown decoder.joint_sampling.when field: " + str(key))
    if "head" not in when or "value" not in when:
        raise ValueError("decoder.joint_sampling.when needs head and value")
    when_head = head_index(when["head"], "when.head")
    if isinstance(when["value"], bool) or not isinstance(when["value"], int):
        raise ValueError("decoder.joint_sampling.when.value must be an integer")
    head = head_index(value["head"], "head")
    if head == when_head:
        raise ValueError("decoder.joint_sampling.head must differ from when.head")
    if not 0 <= when["value"] < ACTION_SIZES[when_head]:
        raise ValueError("decoder.joint_sampling.when.value must be a choice of head %d" % when_head)
    offsets = value["offsets"]
    if not isinstance(offsets, list) or len(offsets) != ACTION_SIZES[head]:
        raise ValueError("decoder.joint_sampling.offsets must list %d numbers" % ACTION_SIZES[head])
    for x in offsets:
        if isinstance(x, bool) or not isinstance(x, (int, float)):
            raise ValueError("decoder.joint_sampling.offsets must be numbers")
        if not (-MAX_JOINT_OFFSET <= x <= MAX_JOINT_OFFSET):
            raise ValueError("decoder.joint_sampling.offsets must be within [-1000, 1000]")


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


# PWNET002 (examples/paintbot/neural_actor.md): a layer stack from a fixed menu. Staging checks the
# structure, the finite weights and the published operation count exactly as neural_actor.nim's loader
# and the host's budget check do, so a malformed or over-budget model is rejected at upload instead of at
# model load. PWNET001 models (and anything else) are left to the host's loader, as before.
PWNET2_MAGIC = b"PWNET002"
MAX_NEURAL_OPERATIONS = 4_000_000  # per seat per tick (neural_host.MaxNeuralOperations)


def neural_budget(seats):
    """neural_host.neuralOperationBudget: the 16-seat budget, x seats / 16 above 16 seats."""
    return MAX_NEURAL_OPERATIONS * seats // 16 if seats > 16 else MAX_NEURAL_OPERATIONS


# Observation contract ffa.v2 (FFA-kin at any seat count; its width follows the match) and its
# action contract, ffa.v2 pointer (heads sized by the match). neural_contract.nim holds both.
OBSERVATION_CONTRACT_FFA_V2 = "paintbot-pw.rules48.obs.ffa.v2"
OBSERVATION_CONTRACT_FFA_V2_HASH = hashlib.sha256(OBSERVATION_CONTRACT_FFA_V2.encode()).hexdigest()
ACTION_CONTRACT_FFA_V2_POINTER = "paintbot-pw.rules48.action.ffa.v2.pointer"
ACTION_CONTRACT_FFA_V2_POINTER_HASH = hashlib.sha256(ACTION_CONTRACT_FFA_V2_POINTER.encode()).hexdigest()
# PWNET002 layout words (neural_actor.nim): a structural uint32 whose high 16 bits are 0xFFFE
# names a quantity of the match layout, resolved by the engine when the seat loads.
LAYOUT_WORD_PREFIX = 0xFFFE0000


class LayoutDependent(Exception):
    """A layout word: the model is validated by the engine against the match's layout."""
PWNET2_LIMITS = dict(parameters=4_194_304, layers=64, width=4096, state=4096, mingru_hidden=1024, groups=8,
                     tokens=256, d_model=256, blocks=8, ff=1024, token_segments=8, token_input=1024, token_model=256,
                     token_mlp_layers=4, pool_heads=32, pool_width=1024)
TRANSCENDENTAL_OPS, MINGRU_UNIT_OPS = 8, 32
ATTN_ALWAYS_VALID = 0xFFFFFFFF


def rms_norm_ops(d):
    return 4 * d + 2 * TRANSCENDENTAL_OPS


def attention_ops(groups, d, heads, blocks, ff, pass_length):
    """ENTITY_ATTN's published cost; groups = [(count, width), ...]."""
    t = sum(count for count, _ in groups)
    embed = sum(count * (2 * width * d + d) for count, width in groups)
    block = (2 * t * rms_norm_ops(d) + t * (6 * d * d + 3 * d) + t * t * (4 * d + 13 * heads)
             + t * heads * TRANSCENDENTAL_OPS + t * (2 * d * d + d) + t * d
             + t * (2 * d * ff + 2 * ff) + t * (2 * ff * d + d) + t * d)
    return embed + blocks * block + t + 2 * t * d + d + TRANSCENDENTAL_OPS + pass_length


def token_pool_ops(t, d):
    return t + 2 * t * d + d + TRANSCENDENTAL_OPS


def token_mlp_ops(tokens, widths):
    """TOKEN_MLP's published cost; widths = [token input, layer outputs...]."""
    return (tokens * widths[0] + sum(tokens * (2 * widths[l - 1] * widths[l] + 2 * widths[l]) for l in range(1, len(widths)))
            + token_pool_ops(tokens, widths[-1]))


def token_mix_ops(tokens, token_in, width, z):
    return 2 * width * z + width + tokens * (2 * token_in * z + 3 * z) + token_pool_ops(tokens, z)


def pointer_ops(tokens, z, width):
    return width + tokens * (2 * z + 2)


def attn_pool_ops(tokens, z, width, heads, key_width, value_width):
    """ATTN_POOL's published cost (neural_actor.attnPoolOps)."""
    return (width + (2 * width * heads * key_width + heads * key_width)
            + tokens * ((2 * z * heads * key_width + heads * key_width) + heads * (2 * key_width + 1)
                        + heads * (TRANSCENDENTAL_OPS + 3) + (2 * z * heads * value_width + heads * value_width)
                        + 2 * heads * value_width)
            + heads * (tokens + TRANSCENDENTAL_OPS))


def segment_near_ops(inputs, tokens):
    """SEGMENT_NEAR's published cost: the copy of the input, 12 per token pair, 8 per token."""
    return inputs + tokens * tokens * 12 + tokens * 8


def validate_pwnet2(model, observation_contract=None, action_contract=None, seats=16):
    """Validate a PWNET002 model.bin; returns its summary dict (operations, state, layers, parameters).
    Raises ValueError with the loader's reason otherwise. A model with layout words is checked
    up to its first word and returned with layout_dependent=True: the engine resolves the words
    against the match's layout and validates the rest when the seat loads. The budget is the
    seat count's (neural_budget)."""
    header = {}
    if len(model) >= 24 and model[:8] == PWNET2_MAGIC:
        # The contracts sit after the header's head sizes: check them before any layout word.
        heads = struct.unpack_from("<I", model, 20)[0]
        at = 24 + 4 * heads
        if 1 <= heads <= 32 and at + 128 <= len(model):
            header = dict(observation_contract=model[at:at + 64].decode("ascii", "replace"),
                          action_contract=model[at + 64:at + 128].decode("ascii", "replace"))
            if observation_contract is not None and (header["observation_contract"] != observation_contract
                                                     or header["action_contract"] != action_contract):
                raise ValueError("package and actor contract mismatch")
    try:
        return _walk_pwnet2(model, observation_contract, action_contract, seats, header)
    except LayoutDependent:
        return dict(format=2, layout_dependent=True, **header)


def _walk_pwnet2(model, observation_contract, action_contract, seats, header):
    lim = PWNET2_LIMITS
    pos = 0

    def u32():
        nonlocal pos
        if pos + 4 > len(model):
            raise ValueError("truncated neural actor")
        value = struct.unpack_from("<I", model, pos)[0]
        pos += 4
        return value

    def word():
        value = u32()
        if value & 0xFFFF0000 == LAYOUT_WORD_PREFIX:
            raise LayoutDependent()
        return value

    def bad(message):
        raise ValueError("invalid PWNET002 actor: " + message)

    parameters = 0

    def weights(n):
        nonlocal pos, parameters
        if parameters + n > lim["parameters"]:
            bad("parameter count")
        if pos + 4 * n > len(model):
            raise ValueError("truncated neural actor")
        values = array.array("f")
        values.frombytes(model[pos:pos + 4 * n])
        if sys.byteorder != "little":
            values.byteswap()
        if not all(map(math.isfinite, values)):
            raise ValueError("nonfinite neural weight")
        pos += 4 * n
        parameters += n

    def finite_f32(bits):
        return math.isfinite(struct.unpack("<f", struct.pack("<I", bits))[0])

    def positive_f32(bits):
        value = struct.unpack("<f", struct.pack("<I", bits))[0]
        return math.isfinite(value) and value > 0

    def nonnegative_f32(bits):
        value = struct.unpack("<f", struct.pack("<I", bits))[0]
        return math.isfinite(value) and value >= 0

    if len(model) > MAX_MODEL_BYTES or model[:8] != PWNET2_MAGIC:
        raise ValueError("invalid neural actor magic")
    pos = 8
    version, inputs, outputs, heads = u32(), word(), word(), u32()
    if version != 2 or not 1 <= inputs <= 4096 or not 2 <= outputs <= 1024 or not 1 <= heads <= 32:
        raise ValueError("unsupported neural actor dimensions/version")
    sizes = [word() for _ in range(heads)]
    if any(not 2 <= size <= 1024 for size in sizes):
        raise ValueError("invalid categorical head")
    if sum(sizes) != outputs:
        raise ValueError("head/output mismatch")
    if pos + 128 > len(model):
        raise ValueError("truncated neural actor")
    contracts = [model[pos:pos + 64], model[pos + 64:pos + 128]]
    pos += 128
    for contract in contracts:
        if any(c not in b"0123456789abcdef" for c in contract):
            raise ValueError("invalid neural contract hash")
    if observation_contract is not None and (contracts[0].decode() != observation_contract
                                             or contracts[1].decode() != action_contract):
        raise ValueError("package and actor contract mismatch")
    count = u32()
    if not 1 <= count <= lim["layers"]:
        bad("layer count must be 1..%d" % lim["layers"])
    width, state, operations, widths = inputs, 0, 0, []
    token_layers = {}  # layer index -> ("mlp" | "mix" | "attn", tokens, floats per token)
    exposed = set()    # ENTITY_ATTN layers whose token rows a later layer reads (their copy is costed once)

    def expose(source):
        nonlocal operations
        kind, tokens, d = token_layers[source]
        if kind == "attn" and source not in exposed:
            exposed.add(source)
            operations += tokens * d + tokens

    for k in range(count):
        code = u32()
        # FP32 parameters (RMSNORM eps, ENTITY_ATTN eps) are read as bits, never as layout words.
        q = [u32() if (code, j) in ((2, 1), (5, 7)) else word() for j in range(8)]
        where = "layer %d: " % k

        def unused(first):
            for j in range(first, 8):
                if q[j] != 0:
                    bad(where + "unused parameter %d must be 0" % j)

        def flag(j):
            if q[j] > 1:
                bad(where + "parameter %d must be 0 or 1" % j)
            return q[j] == 1

        def epsilon(j):
            if not positive_f32(q[j]):
                bad(where + "eps must be finite and positive")

        if code == 1:  # DENSE
            out = q[1]
            if q[0] != width:
                bad(where + "DENSE input %d != width %d" % (q[0], width))
            if not 1 <= out <= lim["width"]:
                bad(where + "DENSE output must be 1..%d" % lim["width"])
            bias, relu = flag(2), flag(3)
            unused(4)
            weights(width * out + (out if bias else 0))
            operations += 2 * width * out + (out if bias else 0) + (out if relu else 0)
        elif code == 2:  # RMSNORM
            if q[0] != width:
                bad(where + "RMSNORM dim %d != width %d" % (q[0], width))
            epsilon(1)
            unused(2)
            weights(width)
            out = width
            operations += rms_norm_ops(width)
        elif code == 3:  # MINGRU
            hidden = q[1]
            if q[0] != width:
                bad(where + "MINGRU input %d != width %d" % (q[0], width))
            if not 1 <= hidden <= lim["mingru_hidden"]:
                bad(where + "MINGRU hidden must be 1..%d" % lim["mingru_hidden"])
            highway, bias = flag(2), flag(3)
            unused(4)
            if highway and width != hidden:
                bad(where + "MINGRU highway needs input == hidden")
            gates = 3 if highway else 2
            weights(gates * hidden * width + (gates * hidden if bias else 0))
            state += hidden
            if state > lim["state"]:
                bad(where + "recurrent state exceeds %d" % lim["state"])
            out = hidden
            operations += 2 * width * gates * hidden + (gates * hidden if bias else 0) + MINGRU_UNIT_OPS * hidden
        elif code == 4:  # RESIDUAL
            unused(1)
            if q[0] >= k:
                bad(where + "RESIDUAL start must name an earlier layer")
            if widths[q[0]] != width:
                bad(where + "RESIDUAL width %d != layer %d output" % (width, q[0]))
            out = width
            operations += width
        elif code == 5:  # ENTITY_ATTN
            groups, d, heads_, blocks, ff, pass_offset, pass_length = q[:7]
            epsilon(7)
            if not 1 <= groups <= lim["groups"]:
                bad(where + "ENTITY_ATTN groups must be 1..%d" % lim["groups"])
            if not 1 <= d <= lim["d_model"]:
                bad(where + "ENTITY_ATTN d_model must be 1..%d" % lim["d_model"])
            if not 1 <= heads_ <= d or d % heads_:
                bad(where + "ENTITY_ATTN heads must divide d_model")
            if blocks > lim["blocks"]:
                bad(where + "ENTITY_ATTN blocks must be 0..%d" % lim["blocks"])
            if not 1 <= ff <= lim["ff"]:
                bad(where + "ENTITY_ATTN ff must be 1..%d" % lim["ff"])
            if pass_offset > inputs or pass_length > inputs - pass_offset:
                bad(where + "ENTITY_ATTN passthrough outside the input")
            shapes, tokens = [], 0
            for g in range(groups):
                offset, stride, n, w, valid = (word() for _ in range(5))
                if not 1 <= n <= lim["tokens"] or not 1 <= w <= inputs or not 1 <= stride <= inputs:
                    bad(where + "ENTITY_ATTN group %d count/width/stride" % g)
                if offset > inputs or (n - 1) * stride + w > inputs - offset:
                    bad(where + "ENTITY_ATTN group %d outside the input" % g)
                if valid != ATTN_ALWAYS_VALID and valid >= w:
                    bad(where + "ENTITY_ATTN group %d valid index outside the token" % g)
                tokens += n
                if tokens > lim["tokens"]:
                    bad(where + "ENTITY_ATTN tokens exceed %d" % lim["tokens"])
                shapes.append((n, w))
            for n, w in shapes:
                weights(d * w + d)
            for _ in range(blocks):
                weights(d + 3 * d * d + 3 * d + d * d + d + d + ff * d + ff + d * ff + d)
            out = 2 * d + pass_length
            if out > lim["width"]:
                bad(where + "ENTITY_ATTN output exceeds %d" % lim["width"])
            token_layers[k] = ("attn", tokens, d)
            operations += attention_ops(shapes, d, heads_, blocks, ff, pass_length)
        elif code == 6:  # CONCAT_INPUT
            offset, length = q[0], q[1]
            unused(2)
            if not 1 <= length <= lim["width"] or offset > inputs or length > inputs - offset:
                bad(where + "CONCAT_INPUT slice outside the input")
            out = width + length
            if out > lim["width"]:
                bad(where + "CONCAT_INPUT output exceeds %d" % lim["width"])
            operations += length
        elif code == 7:  # TOKEN_MLP
            tokens, segments, valid_segment, valid_index, layers = q[:5]
            unused(5)
            if not 1 <= tokens <= lim["tokens"]:
                bad(where + "TOKEN_MLP tokens must be 1..%d" % lim["tokens"])
            if not 1 <= segments <= lim["token_segments"]:
                bad(where + "TOKEN_MLP segments must be 1..%d" % lim["token_segments"])
            if not 1 <= layers <= lim["token_mlp_layers"]:
                bad(where + "TOKEN_MLP layers must be 1..%d" % lim["token_mlp_layers"])
            lengths = []
            for g in range(segments):
                offset, stride, length = word(), word(), word()
                if not 1 <= length <= inputs or stride > inputs:
                    bad(where + "TOKEN_MLP segment %d length/stride" % g)
                if offset > inputs or (tokens - 1) * stride + length > inputs - offset:
                    bad(where + "TOKEN_MLP segment %d outside the input" % g)
                lengths.append(length)
            if sum(lengths) > lim["token_input"]:
                bad(where + "TOKEN_MLP token input exceeds %d" % lim["token_input"])
            if valid_segment == ATTN_ALWAYS_VALID:
                if valid_index != 0:
                    bad(where + "TOKEN_MLP always-valid tokens need valid index 0")
            elif not (valid_segment < segments and valid_index < lengths[valid_segment]):
                bad(where + "TOKEN_MLP valid flag outside the token")
            mlp = [sum(lengths)]
            for _ in range(layers):
                o = word()
                if not 1 <= o <= lim["token_model"]:
                    bad(where + "TOKEN_MLP widths must be 1..%d" % lim["token_model"])
                mlp.append(o)
            for l in range(1, len(mlp)):
                weights(mlp[l] * mlp[l - 1] + mlp[l])
            out = 2 * mlp[-1]
            token_layers[k] = ("mlp", tokens, mlp[-1])
            operations += token_mlp_ops(tokens, mlp)
        elif code == 8:  # TOKEN_MIX
            source, z = q[0], q[1]
            unused(2)
            if source >= k or token_layers.get(source, ("",))[0] not in ("mlp", "attn"):
                bad(where + "TOKEN_MIX source must name an earlier TOKEN_MLP or ENTITY_ATTN layer")
            if not 1 <= z <= lim["token_model"]:
                bad(where + "TOKEN_MIX width must be 1..%d" % lim["token_model"])
            expose(source)
            _, tokens, token_in = token_layers[source]
            weights(z * token_in + z + z * width)
            out = width + 2 * z
            if out > lim["width"]:
                bad(where + "TOKEN_MIX output exceeds %d" % lim["width"])
            token_layers[k] = ("mix", tokens, z)
            operations += token_mix_ops(tokens, token_in, width, z)
        elif code == 9:  # POINTER
            source, offset = q[0], q[1]
            unused(2)
            if source >= k or token_layers.get(source, ("",))[0] not in ("mix", "mlp", "attn"):
                bad(where + "POINTER source must name an earlier TOKEN_MIX, TOKEN_MLP or ENTITY_ATTN layer")
            expose(source)
            _, tokens, z = token_layers[source]
            if offset > width or tokens > width - offset:
                bad(where + "POINTER offset + tokens exceeds width %d" % width)
            weights(z + 1)
            out = width
            operations += pointer_ops(tokens, z, width)
        elif code == 10:  # SEGMENT_NEAR
            tokens, base, stride, xi, zi, vi, ei, ci = q
            scale_x, scale_z, radius, dst, dst_stride = u32(), u32(), u32(), word(), word()
            if k != 0:
                bad(where + "SEGMENT_NEAR must be layer 0")
            if not 1 <= tokens <= lim["tokens"]:
                bad(where + "SEGMENT_NEAR tokens must be 1..%d" % lim["tokens"])
            if not 1 <= stride <= inputs:
                bad(where + "SEGMENT_NEAR stride must be 1..%d" % inputs)
            if base > inputs or tokens * stride > inputs - base:
                bad(where + "SEGMENT_NEAR tokens outside the input")
            if any(i >= stride for i in (xi, zi, vi, ci)) or (ei != ATTN_ALWAYS_VALID and ei >= stride):
                bad(where + "SEGMENT_NEAR index outside the token")
            if not positive_f32(scale_x) or not positive_f32(scale_z):
                bad(where + "SEGMENT_NEAR scales must be finite and positive")
            if not nonnegative_f32(radius):
                bad(where + "SEGMENT_NEAR radius must be finite and >= 0")
            if not (0 if tokens == 1 else 1) <= dst_stride <= inputs or dst >= inputs or \
                    (tokens - 1) * dst_stride >= inputs - dst:
                bad(where + "SEGMENT_NEAR flags outside the input")
            out = inputs
            operations += segment_near_ops(inputs, tokens)
        elif code == 11:  # ATTN_POOL
            source, heads_, key_width, value_width = q[:4]
            unused(4)
            if source >= k or token_layers.get(source, ("",))[0] not in ("mlp", "mix", "attn"):
                bad(where + "ATTN_POOL source must name an earlier TOKEN_MLP, TOKEN_MIX or ENTITY_ATTN layer")
            if not 1 <= heads_ <= lim["pool_heads"]:
                bad(where + "ATTN_POOL heads must be 1..%d" % lim["pool_heads"])
            if not 1 <= key_width <= lim["token_model"] or not 1 <= value_width <= lim["token_model"]:
                bad(where + "ATTN_POOL key and value widths must be 1..%d" % lim["token_model"])
            if heads_ * key_width > lim["pool_width"] or heads_ * value_width > lim["pool_width"]:
                bad(where + "ATTN_POOL heads x width must be at most %d" % lim["pool_width"])
            expose(source)
            _, tokens, z = token_layers[source]
            hk, hv = heads_ * key_width, heads_ * value_width
            weights(hk * width + hk + hk * z + hk + hv * z + hv)
            out = width + hv
            if out > lim["width"]:
                bad(where + "ATTN_POOL output exceeds %d" % lim["width"])
            operations += attn_pool_ops(tokens, z, width, heads_, key_width, value_width)
        elif code == 12:  # PAD
            at, length = q[0], q[1]
            unused(2)
            if at > width:
                bad(where + "PAD position beyond width %d" % width)
            if length > lim["width"]:
                bad(where + "PAD length must be 0..%d" % lim["width"])
            out = width + length
            if out > lim["width"]:
                bad(where + "PAD output exceeds %d" % lim["width"])
            operations += out
        else:
            bad(where + "unknown layer type %d" % code)
        widths.append(out)
        width = out
    if pos != len(model):
        bad("length: %d trailing bytes" % (len(model) - pos))
    if width != outputs:
        bad("last layer width %d != outputs %d" % (width, outputs))
    budget = neural_budget(seats)
    if operations > budget:
        raise ValueError("neural actor exceeds native operation budget: %d > %d" % (operations, budget))
    return dict(format=2, inputs=inputs, outputs=outputs, heads=sizes, layers=count, state=state,
                parameters=parameters, operations=operations, observation_contract=contracts[0].decode(),
                action_contract=contracts[1].decode())


def unpack_package(data, seats=16):
    """Return validated (source, model, manifest); only three fixed files are allowed. `seats` is the
    match's seat count (the neural budget scales with it)."""
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
            allowed = DECODER_OPTIONS[key] if isinstance(DECODER_OPTIONS[key], tuple) else (DECODER_OPTIONS[key],)
            if type(value) not in allowed:
                raise ValueError("decoder." + key + " must be a " + " or a ".join(t.__name__ for t in allowed))
            if key == "fire_hold_teammates":
                validate_fire_hold(value)
            elif key == "sampling":
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
            elif key == "spray_aim":
                validate_spray_aim(value)
            elif key == "spray_gate":
                validate_spray_gate(value)
            elif key == "joint_sampling":
                validate_joint_sampling(value)
        if "steady_shot" in decoder and STEADY_MOVEMENT in decoder.get("forbid_objectives", []):
            raise ValueError("decoder.steady_shot needs movement index 0, which decoder.forbid_objectives forbids")
        if manifest.get("action_contract") == ACTION_CONTRACT_FFA_V2_POINTER_HASH:
            for key in decoder:
                if key != "sampling":
                    # The other options read the fixed contracts' head indices (neural_host.nim).
                    raise ValueError("decoder." + key + " is not available under action contract ffa.v2 pointer")
    user_inputs = 0
    if "user_inputs" in manifest:
        if manifest.get("schema") != "paintbot-neural-basic/2":
            raise ValueError("user_inputs need package schema 2")
        user_inputs = validate_user_inputs(manifest["user_inputs"])
    observation_contract = manifest["observation_contract"]
    if (observation_contract == OBSERVATION_CONTRACT_FFA_V2_HASH) != \
            (manifest["action_contract"] == ACTION_CONTRACT_FFA_V2_POINTER_HASH):
        raise ValueError("observation contract ffa.v2 needs action contract ffa.v2 pointer, and the other way round")
    family, base_size = "v2u", OBSERVATION_V2_SIZE
    named = USER_INPUTS_CONTRACT_HASHES.get(observation_contract, 0)
    if not named and observation_contract in V3_USER_INPUTS_CONTRACT_HASHES:
        family, base_size = "v3u", OBSERVATION_V3_SIZE
        named = V3_USER_INPUTS_CONTRACT_HASHES[observation_contract]
    if user_inputs and not named:
        raise ValueError("user_inputs need observation contract v2u<K> or v3u<K>")
    if named and not user_inputs:
        raise ValueError("observation contract %s%d needs manifest user_inputs" % (family, named))
    if user_inputs and named != user_inputs:
        raise ValueError("user_inputs.count does not match observation contract %s%d" % (family, named))
    files["policy.bas"].decode("utf-8")
    if not files["model.bin"]:
        raise ValueError("empty neural model")
    if files["model.bin"][:8] == PWNET2_MAGIC:
        validate_pwnet2(files["model.bin"], manifest["observation_contract"], manifest["action_contract"], seats)
    if user_inputs:
        inputs, observation = actor_header(files["model.bin"])
        if observation != observation_contract:
            raise ValueError("package and actor contract mismatch")
        if inputs != base_size + user_inputs:
            raise ValueError("neural actor input count must be %d for %d user inputs"
                             % (base_size + user_inputs, user_inputs))
    elif observation_contract == OBSERVATION_CONTRACT_V3_HASH:
        # A new contract, so its actor is checked at staging as the host checks it at load.
        inputs, observation = actor_header(files["model.bin"])
        if observation != observation_contract:
            raise ValueError("package and actor contract mismatch")
        if inputs != OBSERVATION_V3_SIZE:
            raise ValueError("neural actor input count must be %d for observation contract v3" % OBSERVATION_V3_SIZE)
    return files["policy.bas"], files["model.bin"], manifest


def stage_package(data, source_path, seats=16):
    source, model, manifest = unpack_package(data, seats)
    source_path.write_bytes(source)
    source_path.with_name(source_path.name + ".model.bin").write_bytes(model)
    source_path.with_name(source_path.name + ".neural.json").write_text(json.dumps(manifest))
    return source
