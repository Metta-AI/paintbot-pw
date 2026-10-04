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
# Schema 1 and schema 2 carry the same three files; only schema 2 may carry "decoder" options and
# "user_inputs". The actor's own embedded contract hashes are what the host binds and decodes by.
SCHEMA = "paintbot-neural-basic/1"
SCHEMAS = ("paintbot-neural-basic/1", "paintbot-neural-basic/2")
# A seat perceives only its SeatView and acts only through BASIC (docs/neural/seat-view.md): the
# observation contracts are built from SeatView values, and the model's heads reach the engine only
# through policy.bas. neural_contract.nim holds the same ids.
OBSERVATION_CONTRACT_TEAMS_VIEW_1 = "paintbot-pw.teams.view.1"
OBSERVATION_CONTRACT_FFA_VIEW_1 = "paintbot-pw.ffa.view.1"
# teams.view.1h (203): teams.view.1's 512 floats, then the engine's 100-float motion-history block (612 floats);
# neural_contract.nim encodeTeamsViewH.
OBSERVATION_CONTRACT_TEAMS_VIEW_1H = "paintbot-pw.teams.view.1h"
# teams.view.1s (204): teams.view.1h's 612 floats, then the engine's 128-float stop-clock block (740 floats);
# neural_contract.nim encodeTeamsViewS.
OBSERVATION_CONTRACT_TEAMS_VIEW_1S = "paintbot-pw.teams.view.1s"
# teams.view.1t (205): teams.view.1s's 740 floats, then the engine's 11-float hunt-clock block (751 floats);
# neural_contract.nim encodeTeamsViewT.
OBSERVATION_CONTRACT_TEAMS_VIEW_1T = "paintbot-pw.teams.view.1t"
ACTION_CONTRACT_TEAMS_VIEW_1 = "paintbot-pw.teams.view.1.action.51-25-2-2-2"
ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET = "paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23"
ACTION_CONTRACT_TEAMS_VIEW_1_MOVE = "paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23-23-23"
# Its target-conditioned aim-offset variant (15): contract 13's seven heads and decode, but heads 5 and 6 carry one
# 23-logit row per identity (16 rows each, 818 logits per seat) and are drawn from the chosen identity's row.
ACTION_CONTRACT_TEAMS_VIEW_1_TARGET = "paintbot-pw.teams.view.1.action.51-25-2-2-2-23x16-23x16"
# Its raw variant (16): 63 x 7 u per-identity offset rows, then walk direction (256), walk distance (8) and look
# direction (128) heads the reference decoder reads; 2,490 logits per seat.
ACTION_CONTRACT_TEAMS_VIEW_1_RAW = "paintbot-pw.teams.view.1.action.51-25-2-2-2-63x16-63x16-256-8-128"
ACTION_CONTRACT_FFA_VIEW_1_POINTER = "paintbot-pw.ffa.view.1.action.pointer"


def contract_hash(contract_id):
    return hashlib.sha256(contract_id.encode()).hexdigest()


OBSERVATION_CONTRACT_TEAMS_VIEW_1_HASH = contract_hash(OBSERVATION_CONTRACT_TEAMS_VIEW_1)
OBSERVATION_CONTRACT_FFA_VIEW_1_HASH = contract_hash(OBSERVATION_CONTRACT_FFA_VIEW_1)
OBSERVATION_CONTRACT_TEAMS_VIEW_1H_HASH = contract_hash(OBSERVATION_CONTRACT_TEAMS_VIEW_1H)
OBSERVATION_CONTRACT_TEAMS_VIEW_1S_HASH = contract_hash(OBSERVATION_CONTRACT_TEAMS_VIEW_1S)
OBSERVATION_CONTRACT_TEAMS_VIEW_1T_HASH = contract_hash(OBSERVATION_CONTRACT_TEAMS_VIEW_1T)
ACTION_CONTRACT_TEAMS_VIEW_1_HASH = contract_hash(ACTION_CONTRACT_TEAMS_VIEW_1)
ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET_HASH = contract_hash(ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET)
ACTION_CONTRACT_TEAMS_VIEW_1_MOVE_HASH = contract_hash(ACTION_CONTRACT_TEAMS_VIEW_1_MOVE)
ACTION_CONTRACT_TEAMS_VIEW_1_TARGET_HASH = contract_hash(ACTION_CONTRACT_TEAMS_VIEW_1_TARGET)
ACTION_CONTRACT_TEAMS_VIEW_1_RAW_HASH = contract_hash(ACTION_CONTRACT_TEAMS_VIEW_1_RAW)
ACTION_CONTRACT_FFA_VIEW_1_POINTER_HASH = contract_hash(ACTION_CONTRACT_FFA_VIEW_1_POINTER)
TEAMS_VIEW_1_SIZE = 512
TEAMS_VIEW_1H_SIZE = 612
TEAMS_VIEW_1S_SIZE = 740
TEAMS_VIEW_1T_SIZE = 751
ACTION_SIZES = (51, 25, 2, 2, 2)  # action contract teams.view.1
ACTION_SIZES_OFFSET = (51, 25, 2, 2, 2, 23, 23)  # its aim-offset variant
ACTION_SIZES_MOVE = (51, 25, 2, 2, 2, 23, 23, 23, 23)  # its movement-offset variant
# Heads after the five main ones, per teams action contract: aim offsets 5-6, then movement offsets 7-8.
EXTRA_HEADS = {ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET_HASH: 2, ACTION_CONTRACT_TEAMS_VIEW_1_MOVE_HASH: 4,
               ACTION_CONTRACT_TEAMS_VIEW_1_TARGET_HASH: 2, ACTION_CONTRACT_TEAMS_VIEW_1_RAW_HASH: 5}
# Contracts retired for BASIC parity: their observations read state a BASIC seat cannot (cooldowns,
# shield, aim, heart meters, the end tick, cover probes), or their actions were decoded natively.
RETIRED_OBSERVATION_CONTRACTS = ("paintbot-pw.rules37.obs.v1.float448", "paintbot-pw.rules37.obs.v2.float506",
                                 "paintbot-pw.rules43.obs.v3.float514", "paintbot-pw.rules40.obs.ffa.v1.float810",
                                 "paintbot-pw.rules48.obs.ffa.v2")
RETIRED_ACTION_CONTRACTS = ("paintbot-pw.rules37.action.v1.51-25-2-2-2", "paintbot-pw.rules37.action.v2.51-25-2-2-2",
                            "paintbot-pw.rules48.action.ffa.v2.pointer")
MAX_USER_INPUTS, USER_INPUT_LIMIT = 256, 1000000
RETIRED_USER_INPUTS = 128  # the retired v2u<K> / v3u<K> families existed only up to the cap of their day
RETIRED_CONTRACT_HASHES = (
    {contract_hash(c) for c in RETIRED_OBSERVATION_CONTRACTS + RETIRED_ACTION_CONTRACTS}
    | {contract_hash("paintbot-pw.rules39.obs.v2u%d" % k) for k in range(1, RETIRED_USER_INPUTS + 1)}
    | {contract_hash("paintbot-pw.rules43.obs.v3u%d" % k) for k in range(1, RETIRED_USER_INPUTS + 1)})
RETIRED_MESSAGE = "was retired for BASIC parity (docs/neural/seat-view.md); retrain on teams.view.1 or ffa.view.1"
# Schema-2 "decoder" options: selection only (the network's own distribution, reshaped). Every key must be
# one the host knows, so a bundle asking for an option this release lacks is rejected at staging rather than
# played without it. neural_host.nim holds the same rules.
DECODER_OPTIONS = {"sampling": dict, "forbid_objectives": list, "joint_sampling": dict}
# Native decoder rules retired for BASIC parity: a manifest naming one is refused (write it in policy.bas).
RETIRED_DECODER_OPTIONS = ("fire_hold_teammates", "strafe_legs", "aim_snap", "steady_shot", "aim_retarget",
                           "shot_gate", "spray_aim", "spray_gate")
MAX_JOINT_OFFSET = 1000
SAMPLING_HEADS = 5
MIN_SAMPLING_TEMPERATURE, MAX_SAMPLING_TEMPERATURE = 0.01, 10.0
OBJECTIVE_CANDIDATES = 51  # movement-head size of action contract teams.view.1
ACTOR_MAGIC = b"PWNET001"


def user_inputs_contract_id(count, base=OBSERVATION_CONTRACT_TEAMS_VIEW_1):
    """Observation contract teams.view.1u<K> (teams.view.1's 512 floats, then K user inputs) or, with base
    ffa.view.1, ffa.view.1u<K> (the match's ffa.view.1 floats, then K user inputs). neural_contract.nim
    userInputsContractId."""
    return base + "u%d" % count


USER_INPUTS_CONTRACT_HASHES = {contract_hash(user_inputs_contract_id(k)): k for k in range(1, MAX_USER_INPUTS + 1)}
FFA_USER_INPUTS_CONTRACT_HASHES = {contract_hash(user_inputs_contract_id(k, OBSERVATION_CONTRACT_FFA_VIEW_1)): k
                                   for k in range(1, MAX_USER_INPUTS + 1)}
TEAMS_H_USER_INPUTS_CONTRACT_HASHES = {contract_hash(user_inputs_contract_id(k, OBSERVATION_CONTRACT_TEAMS_VIEW_1H)): k
                                       for k in range(1, MAX_USER_INPUTS + 1)}
TEAMS_S_USER_INPUTS_CONTRACT_HASHES = {contract_hash(user_inputs_contract_id(k, OBSERVATION_CONTRACT_TEAMS_VIEW_1S)): k
                                       for k in range(1, MAX_USER_INPUTS + 1)}
TEAMS_T_USER_INPUTS_CONTRACT_HASHES = {contract_hash(user_inputs_contract_id(k, OBSERVATION_CONTRACT_TEAMS_VIEW_1T)): k
                                       for k in range(1, MAX_USER_INPUTS + 1)}


def user_input_feature(value):
    """The float32 a user input feeds the net (neural_contract.nim userInputFeature after clampUserInput):
    float32(clamp(v, +-1,000,000)) / 1000 in float32. The value is exact in float32 and the float64 quotient
    rounds to the float32 quotient (53 >= 2 * 24 + 2), so this is bit-identical to the engine."""
    v = max(-USER_INPUT_LIMIT, min(USER_INPUT_LIMIT, int(value)))
    return struct.unpack("<f", struct.pack("<f", v / 1000.0))[0]


def user_inputs_row(base_row, inputs):
    """The row of observation contract teams.view.1u<K> / ffa.view.1u<K>: the base contract's row unchanged,
    then the K user-input features (zeros for a seat whose policy.bas wrote none)."""
    return list(base_row) + [user_input_feature(v) for v in inputs]


def validate_user_inputs(value):
    """user_inputs: {"count": K, "init": [K ints]}, K within 1 .. 256, init values within +-1,000,000. Returns K."""
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
        if info.get("layout_dependent"):
            raise ValueError("layout words need observation contract ffa.view.1")
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


def validate_sampling(value, offset_heads=False):
    """decoder.sampling: {"mode": "categorical", "temperature": t, "heads": [i, ...]}; heads 5 and 6 only
    under action contract teams.view.1 aim-offset or movement-offset, heads 7 and 8 only under movement-offset.
    offset_heads: the contract's extra heads (0, 2 or 4; True = 2, the aim-offset contract)."""
    extra = 2 if offset_heads is True else int(offset_heads)
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
                if isinstance(item, bool) or not isinstance(item, int) or not 0 <= item < SAMPLING_HEADS + 5:
                    raise ValueError("decoder.sampling.heads entries must be head indices 0 .. %d" % (SAMPLING_HEADS + 4))
            if len(set(field)) != len(field):
                raise ValueError("decoder.sampling.heads repeats a head")
            if extra < 2 and any(SAMPLING_HEADS <= item < SAMPLING_HEADS + 2 for item in field):
                raise ValueError("decoder.sampling.heads 5 and 6 need action contract teams.view.1 aim-offset")
            if extra < 4 and any(SAMPLING_HEADS + 2 <= item < SAMPLING_HEADS + 4 for item in field):
                raise ValueError("decoder.sampling.heads 7 and 8 need action contract teams.view.1 movement-offset")
            if extra < 5 and any(item >= SAMPLING_HEADS + 4 for item in field):
                raise ValueError("decoder.sampling.heads 9 needs action contract teams.view.1 raw")
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


def layer_norm_ops(d):
    """One LayerNorm row of width d (neural_actor.layerNormOps)."""
    return 8 * d + 4 * TRANSCENDENTAL_OPS


def token_norm_ops(tokens, widths):
    """What a token layer's norm flag adds: one LayerNorm row per token per normalised width."""
    return sum(tokens * layer_norm_ops(d) for d in widths)


def pointer_ops(tokens, z, width):
    return width + tokens * (2 * z + 2)


def pointer_k_ops(tokens, z, width, k):
    """POINTER_K's published cost (neural_actor.nim pointerKOps)."""
    return width + tokens * k * (2 * z + 2)


def attn_pool_ops(tokens, z, width, heads, key_width, value_width):
    """ATTN_POOL's published cost (neural_actor.attnPoolOps)."""
    return (width + (2 * width * heads * key_width + heads * key_width)
            + tokens * ((2 * z * heads * key_width + heads * key_width) + heads * (2 * key_width + 1)
                        + heads * (TRANSCENDENTAL_OPS + 3) + (2 * z * heads * value_width + heads * value_width)
                        + 2 * heads * value_width)
            + heads * (tokens + TRANSCENDENTAL_OPS))


TOKEN_PAIR_FEATURES = 10


def token_pair_ops(tokens, d, p, width):
    """TOKEN_PAIR's published cost (neural_actor.tokenPairOps)."""
    return (width + tokens * (4 * d * p + 2 + d) + tokens * tokens * (18 + 2 * TOKEN_PAIR_FEATURES * p + 6 * p)
            + tokens * (TRANSCENDENTAL_OPS + p) + token_pool_ops(tokens, d + 2 * p))


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
    if version != 2 or not 1 <= inputs <= 4096 or not 2 <= outputs <= 4096 or not 1 <= heads <= 32:
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
    conditionals = []  # COND_HEAD (condition head, re-selected head), in layer order
    exposed = set()    # ENTITY_ATTN layers whose token rows a later layer reads (their copy is costed once)

    def expose(source):
        nonlocal operations
        kind, tokens, d = token_layers[source]
        if kind == "attn" and source not in exposed:
            exposed.add(source)
            operations += tokens * d + tokens

    for k in range(count):
        code = u32()
        if code != 13 and conditionals:
            bad("layer %d: COND_HEAD layers must come after every other layer" % k)
        # FP32 parameters (RMSNORM eps, ENTITY_ATTN eps, the token layers' norm eps) are read as bits, never as
        # layout words.
        q = [u32() if (code, j) in ((2, 1), (5, 7), (7, 7), (8, 7)) else word() for j in range(8)]
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

        def token_norm():
            """The token layers' params 6 (norm, 0 or 1) and 7 (its eps; 0 without norm)."""
            norm = flag(6)
            if norm:
                epsilon(7)
            elif q[7] != 0:
                bad(where + "unused parameter 7 must be 0")
            return norm

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
            if q[5] != 0:
                bad(where + "unused parameter 5 must be 0")
            norm = token_norm()
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
                if norm:
                    weights(2 * mlp[l])  # gain, shift
            out = 2 * mlp[-1]
            token_layers[k] = ("mlp", tokens, mlp[-1])
            operations += token_mlp_ops(tokens, mlp) + (token_norm_ops(tokens, mlp[1:]) if norm else 0)
        elif code == 8:  # TOKEN_MIX
            source, z = q[0], q[1]
            for j in range(2, 6):
                if q[j] != 0:
                    bad(where + "unused parameter %d must be 0" % j)
            norm = token_norm()
            if source >= k or token_layers.get(source, ("",))[0] not in ("mlp", "attn", "pair"):
                bad(where + "TOKEN_MIX source must name an earlier TOKEN_MLP, ENTITY_ATTN or TOKEN_PAIR layer")
            if not 1 <= z <= lim["token_model"]:
                bad(where + "TOKEN_MIX width must be 1..%d" % lim["token_model"])
            expose(source)
            _, tokens, token_in = token_layers[source]
            weights(z * token_in + z + z * width + (2 * z if norm else 0))
            out = width + 2 * z
            if out > lim["width"]:
                bad(where + "TOKEN_MIX output exceeds %d" % lim["width"])
            token_layers[k] = ("mix", tokens, z)
            operations += token_mix_ops(tokens, token_in, width, z) + (token_norm_ops(tokens, [z]) if norm else 0)
        elif code == 9:  # POINTER
            source, offset = q[0], q[1]
            unused(2)
            if source >= k or token_layers.get(source, ("",))[0] not in ("mix", "mlp", "attn", "pair"):
                bad(where + "POINTER source must name an earlier TOKEN_MIX, TOKEN_MLP, ENTITY_ATTN or TOKEN_PAIR layer")
            expose(source)
            _, tokens, z = token_layers[source]
            if offset > width or tokens > width - offset:
                bad(where + "POINTER offset + tokens exceeds width %d" % width)
            weights(z + 1)
            out = width
            operations += pointer_ops(tokens, z, width)
        elif code == 15:  # POINTER_K: K logits per token (action contract 15's per-identity offset rows)
            source, offset, kk = q[0], q[1], q[2]
            unused(3)
            if source >= k or token_layers.get(source, ("",))[0] not in ("mix", "mlp", "attn", "pair"):
                bad(where + "POINTER_K source must name an earlier TOKEN_MIX, TOKEN_MLP, ENTITY_ATTN or TOKEN_PAIR layer")
            if not 1 <= kk <= lim["width"]:
                bad(where + "POINTER_K needs 1..%d logits per token" % lim["width"])
            expose(source)
            _, tokens, z = token_layers[source]
            if offset > width or tokens * kk > width - offset:
                bad(where + "POINTER_K offset + tokens * K exceeds width %d" % width)
            weights(kk * z + kk)
            out = width
            operations += pointer_k_ops(tokens, z, width, kk)
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
            if source >= k or token_layers.get(source, ("",))[0] not in ("mlp", "mix", "attn", "pair"):
                bad(where + "ATTN_POOL source must name an earlier TOKEN_MLP, TOKEN_MIX, ENTITY_ATTN or TOKEN_PAIR layer")
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
        elif code == 14:  # TOKEN_PAIR
            source, pw, geo_base, geo_stride, gx, gz = q[:6]
            flag(6)  # self_pairs
            unused(7)
            if source >= k or token_layers.get(source, ("",))[0] not in ("mlp", "mix", "attn"):
                bad(where + "TOKEN_PAIR source must name an earlier TOKEN_MLP, TOKEN_MIX or ENTITY_ATTN layer")
            if not 1 <= pw <= lim["token_model"]:
                bad(where + "TOKEN_PAIR width must be 1..%d" % lim["token_model"])
            expose(source)
            _, tokens, d = token_layers[source]
            if not 1 <= geo_stride <= inputs or gx >= geo_stride or gz >= geo_stride:
                bad(where + "TOKEN_PAIR geometry stride / columns")
            if geo_base > inputs or (tokens - 1) * geo_stride + geo_stride > inputs - geo_base:
                bad(where + "TOKEN_PAIR geometry outside the input")
            if d + 2 * pw > 1024:
                bad(where + "TOKEN_PAIR rows exceed 1024")
            weights(2 * pw * d + pw * TOKEN_PAIR_FEATURES + pw)
            out = width + 2 * (d + 2 * pw)
            if out > lim["width"]:
                bad(where + "TOKEN_PAIR output exceeds %d" % lim["width"])
            token_layers[k] = ("pair", tokens, d + 2 * pw)
            operations += token_pair_ops(tokens, d, pw, width)
        elif code == 16:  # DELAY: y = [x, prev]; state = the slice and a primed flag (neural_actor.nim lkDelay)
            offset, length = q[0], q[1]
            unused(2)
            if not 1 <= length <= lim["width"] or offset > width or length > width - offset:
                bad(where + "DELAY slice outside the width %d" % width)
            weights(length)
            state += length + 1
            if state > lim["state"]:
                bad(where + "recurrent state exceeds %d" % lim["state"])
            out = width + length
            if out > lim["width"]:
                bad(where + "DELAY output exceeds %d" % lim["width"])
            operations += length
        elif code == 13:  # COND_HEAD
            when_head, head = q[0], q[1]
            unused(2)
            if when_head >= heads or head >= heads:
                bad(where + "COND_HEAD heads must be 0..%d" % (heads - 1))
            if when_head == head:
                bad(where + "COND_HEAD head must differ from the condition head")
            weights(sizes[head] * sizes[when_head])
            if head in [c[1] for c in conditionals]:
                bad(where + "COND_HEAD %d: head %d is already re-selected" % (len(conditionals), head))
            if head in [c[0] for c in conditionals]:
                bad(where + "COND_HEAD %d: head %d is an earlier COND_HEAD's condition" % (len(conditionals), head))
            conditionals.append((when_head, head))
            out = width
            operations += width + sizes[head]
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
                action_contract=contracts[1].decode(), conditionals=conditionals)


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
    observation_contract = manifest["observation_contract"]
    action_contract = manifest["action_contract"]
    for field, digest in (("observation", observation_contract), ("action", action_contract)):
        if digest in RETIRED_CONTRACT_HASHES:
            raise ValueError("neural %s contract %s" % (field, RETIRED_MESSAGE))
    teams_inputs = USER_INPUTS_CONTRACT_HASHES.get(observation_contract, 0)
    ffa_inputs = FFA_USER_INPUTS_CONTRACT_HASHES.get(observation_contract, 0)
    teams_h_inputs = TEAMS_H_USER_INPUTS_CONTRACT_HASHES.get(observation_contract, 0)
    teams_s_inputs = TEAMS_S_USER_INPUTS_CONTRACT_HASHES.get(observation_contract, 0)
    teams_t_inputs = TEAMS_T_USER_INPUTS_CONTRACT_HASHES.get(observation_contract, 0)
    user_inputs_named = teams_inputs or ffa_inputs or teams_h_inputs or teams_s_inputs or teams_t_inputs
    teams_h = observation_contract == OBSERVATION_CONTRACT_TEAMS_VIEW_1H_HASH or teams_h_inputs > 0
    teams_s = observation_contract == OBSERVATION_CONTRACT_TEAMS_VIEW_1S_HASH or teams_s_inputs > 0
    teams_t = observation_contract == OBSERVATION_CONTRACT_TEAMS_VIEW_1T_HASH or teams_t_inputs > 0
    teams = (observation_contract == OBSERVATION_CONTRACT_TEAMS_VIEW_1_HASH or teams_inputs > 0 or teams_h or teams_s
             or teams_t)
    if not teams and observation_contract != OBSERVATION_CONTRACT_FFA_VIEW_1_HASH and not ffa_inputs:
        raise ValueError("unknown neural observation contract")
    if action_contract not in (ACTION_CONTRACT_TEAMS_VIEW_1_HASH, ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET_HASH,
                               ACTION_CONTRACT_TEAMS_VIEW_1_MOVE_HASH, ACTION_CONTRACT_TEAMS_VIEW_1_TARGET_HASH,
                               ACTION_CONTRACT_TEAMS_VIEW_1_RAW_HASH, ACTION_CONTRACT_FFA_VIEW_1_POINTER_HASH):
        raise ValueError("unknown neural action contract")
    if teams != (action_contract != ACTION_CONTRACT_FFA_VIEW_1_POINTER_HASH):
        raise ValueError("observation contract teams.view.1 goes with action contract teams.view.1 (or its aim-offset "
                         "variant), ffa.view.1 with ffa.view.1 pointer")
    offset = EXTRA_HEADS.get(action_contract, 0)
    if "decoder" in manifest:
        if manifest.get("schema") != "paintbot-neural-basic/2":
            raise ValueError("decoder options need package schema 2")
        decoder = manifest["decoder"]
        if not isinstance(decoder, dict):
            raise ValueError("decoder options must be an object")
        for key, value in decoder.items():
            if key in RETIRED_DECODER_OPTIONS:
                raise ValueError("decoder." + key + " was retired for BASIC parity (docs/neural/seat-view.md); "
                                 "write the rule in policy.bas")
            if key not in DECODER_OPTIONS:
                raise ValueError("unknown decoder option: " + str(key))
            if type(value) is not DECODER_OPTIONS[key]:
                raise ValueError("decoder." + key + " must be a " + DECODER_OPTIONS[key].__name__)
            if key == "sampling":
                validate_sampling(value, offset)
            elif key == "forbid_objectives":
                validate_forbid_objectives(value)
            elif key == "joint_sampling":
                validate_joint_sampling(value)
            if not teams and key != "sampling":
                # The other options read head indices of the fixed teams contract.
                raise ValueError("decoder." + key + " is not available under action contract ffa.view.1 pointer")
    user_inputs = 0
    if "user_inputs" in manifest:
        if manifest.get("schema") != "paintbot-neural-basic/2":
            raise ValueError("user_inputs need package schema 2")
        user_inputs = validate_user_inputs(manifest["user_inputs"])
    family = ("teams.view.1tu" if teams_t else "teams.view.1su" if teams_s else "teams.view.1hu" if teams_h
              else "teams.view.1u" if teams else "ffa.view.1u")
    if user_inputs and not user_inputs_named:
        raise ValueError("user_inputs need observation contract %s<K>" % family)
    if user_inputs_named and not user_inputs:
        raise ValueError("observation contract %s%d needs manifest user_inputs" % (family, user_inputs_named))
    if user_inputs and user_inputs_named != user_inputs:
        raise ValueError("user_inputs.count does not match observation contract %s%d" % (family, user_inputs_named))
    files["policy.bas"].decode("utf-8")
    if not files["model.bin"]:
        raise ValueError("empty neural model")
    if files["model.bin"][:8] == PWNET2_MAGIC:
        info = validate_pwnet2(files["model.bin"], observation_contract, action_contract, seats)
        if info.get("conditionals") and "joint_sampling" in (manifest.get("decoder") or {}):
            raise ValueError("decoder.joint_sampling cannot be combined with the model's COND_HEAD layers")
        if any(head >= SAMPLING_HEADS for pair in info.get("conditionals", []) for head in pair):
            raise ValueError("COND_HEAD layers may name only heads 0 .. 4")
    if teams:
        # The fixed-width contract: the actor is checked at staging as the host checks it at load.
        inputs, observation = actor_header(files["model.bin"])
        if observation != observation_contract:
            raise ValueError("package and actor contract mismatch")
        base_size = (TEAMS_VIEW_1T_SIZE if teams_t else TEAMS_VIEW_1S_SIZE if teams_s else TEAMS_VIEW_1H_SIZE if teams_h
                     else TEAMS_VIEW_1_SIZE)
        if inputs != base_size + user_inputs:
            raise ValueError("neural actor input count must be %d for observation contract teams.view.1%s%s"
                             % (base_size + user_inputs, "t" if teams_t else "s" if teams_s else "h" if teams_h else "",
                                "u%d" % user_inputs if user_inputs else ""))
    return files["policy.bas"], files["model.bin"], manifest


def stage_package(data, source_path, seats=16):
    source, model, manifest = unpack_package(data, seats)
    source_path.write_bytes(source)
    source_path.with_name(source_path.name + ".model.bin").write_bytes(model)
    source_path.with_name(source_path.name + ".neural.json").write_text(json.dumps(manifest))
    return source
