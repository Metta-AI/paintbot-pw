## Seat-owned FP32 buffers. Integer handles never index shared state.
import std/[os, json, strutils, math]
import polyworld/rngs
import polyworld/basic
import sim, neural_actor, neural_contract

const MaxNeuralOperations* = 4_000_000'i64

type
  NeuralBudgetError* = object of ValueError
    ## The package's model needs more native operations per tick than the budget allows.
    operations*: int64
    hiddenSize*: int
  NeuralSeat* = ref object
    actor*: Actor
    observation*, logits*, state*: seq[float32]
    slot*: int
    world: ptr World
    observed, inferred, acted: bool
    previousTick: int32
    previouslyAlive: bool
    nativeWork*: int64
    # The action contract the actor was trained against (named by its embedded hash)
    # and, for contract v2, the seat's one-tick aim memory. The memory follows the
    # recurrent state: cleared at initial use, match reset, death and respawn.
    contract*: ActionContractVersion
    memory*: AimMemory
    # The observation contract the actor was trained against (named by its embedded
    # hash): v1 (448 floats) or v2 (v1 + terrain block); selects the encoder.
    observationContract*: ObservationContractVersion
    # The bundle's decoder options (manifest "decoder", schema 2): fireHoldTeammates
    # applies holdFire to every decoded command; fireHolds counts the orders it held.
    fireHoldTeammates*: bool
    fireHolds*: int
    # decoder.fire_hold_teammates {"radius": r}: the hold's radius (FireHoldRadius = 55 for
    # the boolean form and when the field is absent).
    fireHoldRadius*: int32
    # decoder.sampling: the seat's own draw stream (seeded from the match seed and the
    # slot the first time the seat sees the world; never part of the world or its hash),
    # the options, and how many decisions were drawn. Off = argmax, no stream, no draw.
    sampling*: SamplingOptions
    sampleRng: Rng
    sampleSeeded: bool
    sampleDraws*: int
    # decoder.forbid_objectives: movement-head indices never selected (argmax or draw);
    # forbidHits counts decisions whose unmasked argmax objective was one of them.
    forbidden*: ObjectiveMask
    forbidAny*: bool
    forbidHits*: int
    # decoder.strafe_legs: the options, the seat's leg state and its own draw stream
    # (seeded like the sampling stream, with its own salt, the first time the seat sees
    # the world; never part of the world or its hash).
    strafe*: StrafeOptions
    strafeState*: StrafeState
    strafeRng: Rng
    strafeSeeded: bool
    # decoder.aim_snap: the options (stateless rule); aimSnaps counts the decisions whose
    # compass aim it replaced with an identity.
    aimSnap*: AimSnapOptions
    aimSnaps*: int
    # decoder.steady_shot: on/off (stateless rule, read from the gun's windup state);
    # steadyShots counts the order ticks it held, steadyTicks every decision it held.
    steadyShot*: bool
    steadyShots*, steadyTicks*: int
    # decoder.aim_retarget: the options (stateless rule); aimRetargets counts the decisions
    # whose aim it replaced with the rule's enemy identity.
    aimRetarget*: AimRetargetOptions
    aimRetargets*: int
    # decoder.shot_gate: the options (stateless rule); shotGates counts the shoot orders it
    # dropped.
    shotGate*: ShotGateOptions
    shotGates*: int
    # decoder.spray_aim / decoder.spray_gate: the options (stateless rules for a ready spray
    # can); sprayAims counts re-aimed shoot orders, sprayGates dropped ones.
    sprayAim*: SprayAimOptions
    sprayAims*: int
    sprayGate*: SprayGateOptions
    sprayGates*: int
    # The seat's apparent identities for this tick, resolved once for the observation
    # and the action decode (both read the same pre-action world).
    bodies: array[Seats, int]
    bodiesReady: bool
    # Neural BASIC I/O (PLAN-neural-basic-io). Every field below is unused, and every
    # path byte-identical, unless the bundle or policy.bas asks for it.
    # Part A, user inputs (manifest "user_inputs", observation contract v2u<K>): the live
    # values neuralInput writes (K = len), their match-start values, and the snapshot the
    # tick's observation reads (taken at beginTick: one tick of latency).
    userInputs*, userInputInit*: seq[int32]
    userInputView: seq[int32]
    observationFresh: bool
    # A training policy-script seat (native pw_set_seat_policy_script): no actor; the
    # trainer's logits for the tick are fed in and run_neural_net copies them.
    external*: bool
    fedLogits*: seq[float32]
    logitsFed*: bool
    # Part B, the tick's head-level phase: BASIC masks and temperatures (before
    # selection), the selection and its applied masks / temperatures (milli, 0 = argmax),
    # the working heads, and the command buffer neuralDecode fills and neuralIssue issues.
    masks: HeadMasks
    maskSet: bool
    temperatures: HeadTemperatures
    temperatureSet: array[ActionSizes.len, bool]
    sampled*, decoded*: bool
    selected*, choices*: array[ActionSizes.len, int32]
    appliedMasks*: HeadMasks
    appliedTemperatures*: array[ActionSizes.len, int32]
    buffer: Command
    decodeMemory: AimMemory

proc samplingLogSeed(seat: NeuralSeat): uint64 =
  ## The stream's initial state for the log (the state before any draw), recomputed from
  ## the match seed so the line does not depend on how far the stream has advanced; 0
  ## until the seat has seen a world.
  if seat.sampleSeeded and not seat.world.isNil: samplingSeed(seat.world[].seed, seat.slot) else: 0

proc samplingTelemetry*(options: SamplingOptions, seed: uint64, draws: int): string =
  ## The sampling part of the seat log line: mode, temperature, the heads sampled, the
  ## stream's seed and the decisions drawn, so a replay question can be answered from the
  ## log alone.
  result = " sampling=categorical t=" & formatFloat(options.temperature, ffDecimal, 3) & " heads="
  for head, on in options.heads:
    if on: result.add $head
  result.add " seed=0x" & toHex(seed, 16).toLowerAscii & " draws=" & $draws

proc forbidTelemetry*(forbidden: ObjectiveMask, hits: int): string =
  ## The forbid part of the seat log line: the forbidden indices and how many decisions
  ## the mask changed the argmax objective of.
  result = " forbid_objectives="
  var first = true
  for index, on in forbidden:
    if not on: continue
    if not first: result.add ","
    result.add $index
    first = false
  result.add " forbid_hits=" & $hits

proc strafeTelemetry*(options: StrafeOptions, state: StrafeState): string =
  ## The strafe part of the seat log line: the parameters, legs started and decisions
  ## whose movement head the strafe replaced.
  " strafe=r" & $options.range & ",legs" & $options.legTicks[0] & "-" & $options.legTicks[1] &
    ",shot" & $options.shotLegTicks[0] & "-" & $options.shotLegTicks[1] & ",rev" & $options.reversePermille &
    " strafe_legs=" & $state.legs & " strafe_ticks=" & $state.ticks

proc aimSnapTelemetry*(options: AimSnapOptions, snaps: int): string =
  ## The aim-snap part of the seat log line: the angle, its integer threshold and the
  ## decisions snapped.
  " aim_snap=" & formatFloat(options.maxAngleMillideg.float / 1000, ffDecimal, 3) &
    "deg,cos_q15=" & $options.cosQ15 & " aim_snaps=" & $snaps

proc steadyShotTelemetry*(shots, ticks: int): string =
  ## The steady-shot part of the seat log line: order ticks held and decisions held.
  " steady_shot=on steady_shots=" & $shots & " steady_ticks=" & $ticks

proc aimRetargetTelemetry*(options: AimRetargetOptions, retargets: int): string =
  ## The aim-retarget part of the seat log line: the parameters and the decisions retargeted.
  " aim_retarget=r" & $options.maxRange & ",hp" & $options.hpWeight & ",carry" & $options.carryWeight &
    " aim_retargets=" & $retargets

proc shotGateTelemetry*(options: ShotGateOptions, gates: int): string =
  ## The shot-gate part of the seat log line: the range and the shoot orders dropped.
  " shot_gate=r" & $options.maxRange & " shot_gates=" & $gates

proc sprayAimTelemetry*(options: SprayAimOptions, aims: int): string =
  " spray_aim=r" & $options.maxRange & " spray_aims=" & $aims

proc sprayGateTelemetry*(options: SprayGateOptions, gates: int): string =
  " spray_gate=t" & $options.maxTeammates & ",e" & $options.minEnemies & " spray_gates=" & $gates

proc neuralTelemetry*(peakOperations: int64, hiddenSize, ticks: int,
    fireHolds = -1, sampling = "", options = "", fireHoldRadius = FireHoldRadius.int32): string =
  ## One private seat-log line: peak native operations in a tick against the budget, the
  ## model width and the ticks played; with the fire-hold decoder option on, also the
  ## number of shoot orders it held (omitted, and the line unchanged, when it is off).
  ## Diagnostics only; it reads no simulation state.
  result = "neural: peak_ops=" & $peakOperations & " budget=" & $MaxNeuralOperations &
    " model=w" & $hiddenSize & " ticks=" & $ticks
  if fireHolds >= 0: result.add " fire_holds=" & $fireHolds
  if fireHoldRadius != FireHoldRadius.int32 and fireHolds >= 0: result.add " fire_hold_radius=" & $fireHoldRadius
  result.add sampling
  result.add options

proc telemetry*(seat: NeuralSeat, peakOperations: int64, ticks: int): string =
  ## Empty for a seat without a loaded neural model, so plain BASIC seats log nothing.
  if seat.isNil or seat.actor.isNil: ""
  else: neuralTelemetry(peakOperations, seat.actor.hiddenSize, ticks,
    if seat.fireHoldTeammates: seat.fireHolds else: -1,
    if seat.sampling.enabled: samplingTelemetry(seat.sampling, seat.samplingLogSeed, seat.sampleDraws) else: "",
    (if seat.forbidAny: forbidTelemetry(seat.forbidden, seat.forbidHits) else: "") &
    (if seat.strafe.enabled: strafeTelemetry(seat.strafe, seat.strafeState) else: "") &
    (if seat.aimSnap.enabled: aimSnapTelemetry(seat.aimSnap, seat.aimSnaps) else: "") &
    (if seat.steadyShot: steadyShotTelemetry(seat.steadyShots, seat.steadyTicks) else: "") &
    (if seat.aimRetarget.enabled: aimRetargetTelemetry(seat.aimRetarget, seat.aimRetargets) else: "") &
    (if seat.shotGate.enabled: shotGateTelemetry(seat.shotGate, seat.shotGates) else: "") &
    (if seat.sprayAim.enabled: sprayAimTelemetry(seat.sprayAim, seat.sprayAims) else: "") &
    (if seat.sprayGate.enabled: sprayGateTelemetry(seat.sprayGate, seat.sprayGates) else: ""),
    seat.fireHoldRadius)

proc parseSamplingOptions*(value: JsonNode): SamplingOptions =
  ## decoder.sampling: {"mode": "categorical", "temperature": t, "heads": [i, ...]}. mode is
  ## required and only "categorical" is known; temperature is optional (1.0) within
  ## [MinSamplingTemperature, MaxSamplingTemperature]; heads is optional (every head) and
  ## lists distinct head indices 0 ..< ActionSizes.len. Anything else rejects the bundle.
  if value.kind != JObject: raise newException(ValueError, "decoder.sampling must be an object")
  result.enabled = true
  result.temperature = 1'f32
  for head in 0..<ActionSizes.len: result.heads[head] = true
  var sawMode = false
  for key, field in value:
    case key
    of "mode":
      if field.kind != JString or field.getStr != "categorical":
        raise newException(ValueError, "decoder.sampling.mode must be \"categorical\"")
      sawMode = true
    of "temperature":
      if field.kind notin {JFloat, JInt}: raise newException(ValueError, "decoder.sampling.temperature must be a number")
      let t = field.getFloat
      if t != t or t < float(MinSamplingTemperature) or t > float(MaxSamplingTemperature):
        raise newException(ValueError, "decoder.sampling.temperature must be within [0.01, 10]")
      result.temperature = float32(t)
    of "heads":
      if field.kind != JArray or field.len == 0: raise newException(ValueError, "decoder.sampling.heads must be a non-empty array")
      for head in 0..<ActionSizes.len: result.heads[head] = false
      for item in field:
        if item.kind != JInt or item.getInt notin 0..<ActionSizes.len:
          raise newException(ValueError, "decoder.sampling.heads entries must be head indices 0 .. " & $(ActionSizes.len-1))
        if result.heads[item.getInt]: raise newException(ValueError, "decoder.sampling.heads repeats a head")
        result.heads[item.getInt] = true
    else: raise newException(ValueError, "unknown decoder.sampling field: " & key)
  if not sawMode: raise newException(ValueError, "decoder.sampling.mode is required")

proc parseForbidObjectives*(value: JsonNode): ObjectiveMask =
  ## decoder.forbid_objectives: a non-empty array of distinct movement-head candidate
  ## indices 0 ..< ActionSizes[0] that leaves at least one index allowed.
  if value.kind != JArray or value.len == 0:
    raise newException(ValueError, "decoder.forbid_objectives must be a non-empty array")
  for item in value:
    if item.kind != JInt or item.getInt notin 0..<ActionSizes[0]:
      raise newException(ValueError, "decoder.forbid_objectives entries must be objective indices 0 .. " & $(ActionSizes[0]-1))
    if result[item.getInt]: raise newException(ValueError, "decoder.forbid_objectives repeats an index")
    result[item.getInt] = true
  if value.len >= ActionSizes[0]: raise newException(ValueError, "decoder.forbid_objectives must leave an objective allowed")

proc parseStrafeOptions*(value: JsonNode): StrafeOptions =
  ## decoder.strafe_legs: {"range": r, "legs": [min, max], "shot_legs": [min, max],
  ## "reverse_permille": p}; every field optional (the pw-diag / base.bas values
  ## 5250, [3, 6], [6, 9], 800); anything else rejects the bundle.
  if value.kind != JObject: raise newException(ValueError, "decoder.strafe_legs must be an object")
  result = defaultStrafeOptions()
  proc integer(field: JsonNode, name: string): int32 =
    if field.kind != JInt or field.getBiggestInt < int32.low or field.getBiggestInt > int32.high:
      raise newException(ValueError, "decoder.strafe_legs." & name & " must be an integer")
    int32(field.getBiggestInt)
  proc pair(field: JsonNode, name: string): array[2, int32] =
    if field.kind != JArray or field.len != 2:
      raise newException(ValueError, "decoder.strafe_legs." & name & " must be [min, max]")
    [integer(field[0], name), integer(field[1], name)]
  for key, field in value:
    case key
    of "range": result.range = integer(field, key)
    of "legs": result.legTicks = pair(field, key)
    of "shot_legs": result.shotLegTicks = pair(field, key)
    of "reverse_permille": result.reversePermille = integer(field, key)
    else: raise newException(ValueError, "unknown decoder.strafe_legs field: " & key)
  let problem = strafeOptionsError(result)
  if problem.len > 0: raise newException(ValueError, "decoder.strafe_legs." & problem)

proc parseAimSnapOptions*(value: JsonNode): AimSnapOptions =
  ## decoder.aim_snap: {"max_angle_deg": a}; a is optional (22.5), a number that is a
  ## multiple of 0.001 within 0.001 .. 90; anything else rejects the bundle.
  if value.kind != JObject: raise newException(ValueError, "decoder.aim_snap must be an object")
  var millideg = DefaultAimSnapMillideg
  for key, field in value:
    case key
    of "max_angle_deg":
      if field.kind notin {JFloat, JInt}: raise newException(ValueError, "decoder.aim_snap.max_angle_deg must be a number")
      let degrees = field.getFloat
      let scaled = degrees * 1000
      if degrees != degrees or scaled < 0.5 or scaled > float(MaxAimSnapMillideg) + 0.5 or
          abs(scaled - round(scaled)) > 1e-6:
        raise newException(ValueError, "decoder.aim_snap." & aimSnapOptionsError(0))
      millideg = int32(round(scaled))
    else: raise newException(ValueError, "unknown decoder.aim_snap field: " & key)
  aimSnapOptions(millideg)

proc parseSteadyShot*(value: JsonNode): bool =
  ## decoder.steady_shot: {} (no parameters); anything else rejects the bundle.
  if value.kind != JObject: raise newException(ValueError, "decoder.steady_shot must be an object")
  for key, field in value: raise newException(ValueError, "unknown decoder.steady_shot field: " & key)
  true

proc optionInteger(field: JsonNode, name: string): int32 =
  ## An integer manifest field that fits int32; ValueError naming the field otherwise.
  if field.kind != JInt or field.getBiggestInt < int32.low or field.getBiggestInt > int32.high:
    raise newException(ValueError, name & " must be an integer")
  int32(field.getBiggestInt)

proc parseAimRetargetOptions*(value: JsonNode): AimRetargetOptions =
  ## decoder.aim_retarget: {"max_range": r, "hp_weight": h, "carry_weight": c}; every
  ## field optional (base.bas's 5250, 160000, 2500000), integers, r within 1 .. 20000 and
  ## h, c within 0 .. 1e9; anything else rejects the bundle.
  if value.kind != JObject: raise newException(ValueError, "decoder.aim_retarget must be an object")
  var maxRange = DefaultRetargetRange
  var hpWeight = DefaultRetargetHpWeight
  var carryWeight = DefaultRetargetCarryWeight
  for key, field in value:
    case key
    of "max_range": maxRange = optionInteger(field, "decoder.aim_retarget.max_range")
    of "hp_weight": hpWeight = optionInteger(field, "decoder.aim_retarget.hp_weight")
    of "carry_weight": carryWeight = optionInteger(field, "decoder.aim_retarget.carry_weight")
    else: raise newException(ValueError, "unknown decoder.aim_retarget field: " & key)
  aimRetargetOptions(maxRange, hpWeight, carryWeight)

proc parseShotGateOptions*(value: JsonNode): ShotGateOptions =
  ## decoder.shot_gate: {"max_range": r}; r optional (5250), an integer within 1 .. 20000;
  ## anything else rejects the bundle.
  if value.kind != JObject: raise newException(ValueError, "decoder.shot_gate must be an object")
  var maxRange = DefaultShotGateRange
  for key, field in value:
    case key
    of "max_range": maxRange = optionInteger(field, "decoder.shot_gate.max_range")
    else: raise newException(ValueError, "unknown decoder.shot_gate field: " & key)
  shotGateOptions(maxRange)

proc parseFireHold*(value: JsonNode): (bool, int32) =
  ## decoder.fire_hold_teammates: a boolean (true = the hold at the gun's hit tolerance,
  ## 55; false = off), or an object {"radius": r} with r optional (55), an integer within
  ## 1 .. MaxFireHoldRadius (the object form turns the hold on); anything else rejects the
  ## bundle.
  case value.kind
  of JBool: return (value.getBool, FireHoldRadius.int32)
  of JObject:
    result = (true, FireHoldRadius.int32)
    for key, field in value:
      case key
      of "radius":
        if field.kind != JInt: raise newException(ValueError, "decoder.fire_hold_teammates.radius must be an integer")
        let r = field.getBiggestInt
        if r < 1 or r > MaxFireHoldRadius:
          raise newException(ValueError, "decoder.fire_hold_teammates.radius must be within 1 .. " & $MaxFireHoldRadius)
        result[1] = int32(r)
      else: raise newException(ValueError, "unknown decoder.fire_hold_teammates field: " & key)
  else: raise newException(ValueError, "decoder.fire_hold_teammates must be a boolean or an object")

proc parseSprayAimOptions*(value: JsonNode): SprayAimOptions =
  ## decoder.spray_aim: {"max_range": r}; r optional (850), an integer within 1 .. 850.
  if value.kind != JObject: raise newException(ValueError, "decoder.spray_aim must be an object")
  var maxRange = DefaultSprayAimRange
  for key, field in value:
    case key
    of "max_range": maxRange = optionInteger(field, "decoder.spray_aim.max_range")
    else: raise newException(ValueError, "unknown decoder.spray_aim field: " & key)
  sprayAimOptions(maxRange)

proc parseSprayGateOptions*(value: JsonNode): SprayGateOptions =
  ## decoder.spray_gate: {"max_teammates": t, "min_enemies": e}; both optional (0, 1),
  ## integers, t within 0 .. 7 and e within 0 .. 8.
  if value.kind != JObject: raise newException(ValueError, "decoder.spray_gate must be an object")
  var maxTeammates = DefaultSprayMaxTeammates
  var minEnemies = DefaultSprayMinEnemies
  for key, field in value:
    case key
    of "max_teammates": maxTeammates = optionInteger(field, "decoder.spray_gate.max_teammates")
    of "min_enemies": minEnemies = optionInteger(field, "decoder.spray_gate.min_enemies")
    else: raise newException(ValueError, "unknown decoder.spray_gate field: " & key)
  sprayGateOptions(maxTeammates, minEnemies)

proc parseUserInputs*(value: JsonNode): seq[int32] =
  ## Manifest "user_inputs": {"count": K, "init": [K integers]}, K within 1 .. 32, every
  ## init value within -1,000,000 .. 1,000,000; both fields required; anything else
  ## rejects the bundle. Returns the init values (K = their count).
  if value.kind != JObject: raise newException(ValueError, "user_inputs must be an object")
  var count = -1
  var sawInit = false
  for key, field in value:
    case key
    of "count":
      if field.kind != JInt or field.getBiggestInt notin 1..MaxUserInputs:
        raise newException(ValueError, "user_inputs.count must be an integer within 1 .. " & $MaxUserInputs)
      count = field.getInt
    of "init":
      if field.kind != JArray: raise newException(ValueError, "user_inputs.init must be an array")
      sawInit = true
      result = @[]
      for item in field:
        if item.kind != JInt or item.getBiggestInt < -UserInputLimit or item.getBiggestInt > UserInputLimit:
          raise newException(ValueError, "user_inputs.init entries must be integers within -" &
            $UserInputLimit & " .. " & $UserInputLimit)
        result.add int32(item.getBiggestInt)
    else: raise newException(ValueError, "unknown user_inputs field: " & key)
  if count < 0: raise newException(ValueError, "user_inputs.count is required")
  if not sawInit: raise newException(ValueError, "user_inputs.init is required")
  if result.len != count: raise newException(ValueError, "user_inputs.init must have user_inputs.count entries")

proc configureSeat(seat: NeuralSeat, manifest: JsonNode, userInputs: int) =
  ## The manifest's decoder options and user inputs onto the seat (nil manifest = none).
  ## `userInputs` is the K the actor's (or handle's) observation contract names.
  var fireHold = false
  var fireHoldRadius = FireHoldRadius.int32
  var sampling: SamplingOptions
  var forbidden: ObjectiveMask
  var strafe: StrafeOptions
  var aimSnap: AimSnapOptions
  var steadyShot = false
  var aimRetarget: AimRetargetOptions
  var shotGate: ShotGateOptions
  var sprayAim: SprayAimOptions
  var sprayGate: SprayGateOptions
  var init: seq[int32]
  var sawInputs = false
  if not manifest.isNil:
    # Decoder options are a schema-2 field. Every key must be one this host knows, so a
    # bundle asking for an option the host lacks fails here instead of playing without it.
    if manifest.hasKey("decoder"):
      if manifest{"schema"}.getStr != "paintbot-neural-basic/2":
        raise newException(ValueError, "decoder options need package schema 2")
      let decoder = manifest["decoder"]
      if decoder.kind != JObject: raise newException(ValueError, "decoder options must be an object")
      for key, value in decoder:
        case key
        of "fire_hold_teammates":
          (fireHold, fireHoldRadius) = parseFireHold(value)
        of "sampling":
          sampling = parseSamplingOptions(value)
        of "forbid_objectives":
          forbidden = parseForbidObjectives(value)
        of "strafe_legs":
          strafe = parseStrafeOptions(value)
        of "aim_snap":
          aimSnap = parseAimSnapOptions(value)
        of "steady_shot":
          steadyShot = parseSteadyShot(value)
        of "aim_retarget":
          aimRetarget = parseAimRetargetOptions(value)
        of "shot_gate":
          shotGate = parseShotGateOptions(value)
        of "spray_aim":
          sprayAim = parseSprayAimOptions(value)
        of "spray_gate":
          sprayGate = parseSprayGateOptions(value)
        else: raise newException(ValueError, "unknown decoder option: " & key)
      # The steady shot stands the seat still with movement index 0; a bundle that also
      # forbids index 0 asks for both, so it is rejected rather than resolved either way.
      if steadyShot and forbidden[SteadyMovement]:
        raise newException(ValueError, "decoder.steady_shot needs movement index 0, which decoder.forbid_objectives forbids")
    if manifest.hasKey("user_inputs"):
      if manifest{"schema"}.getStr != "paintbot-neural-basic/2":
        raise newException(ValueError, "user_inputs need package schema 2")
      init = parseUserInputs(manifest["user_inputs"])
      sawInputs = true
  if sawInputs and userInputs == 0:
    raise newException(ValueError, "user_inputs need observation contract v2u<K>")
  if userInputs > 0 and not sawInputs:
    raise newException(ValueError, "observation contract v2u" & $userInputs & " needs manifest user_inputs")
  if sawInputs and init.len != userInputs:
    raise newException(ValueError, "user_inputs.count does not match observation contract v2u" & $userInputs)
  seat.fireHoldTeammates = fireHold
  seat.fireHoldRadius = fireHoldRadius
  seat.sampling = sampling
  seat.forbidden = forbidden
  seat.forbidAny = forbidden.forbidsAny
  seat.strafe = strafe
  seat.strafeState = initStrafeState(seat.slot)
  seat.aimSnap = aimSnap
  seat.steadyShot = steadyShot
  seat.aimRetarget = aimRetarget
  seat.shotGate = shotGate
  seat.sprayAim = sprayAim
  seat.sprayGate = sprayGate
  seat.userInputInit = init
  seat.userInputs = init
  seat.userInputView = init
  seat.memory.resetAimMemory()
  seat.logits = newSeq[float32](LogitSize)

proc observationFor(hash: string): (ObservationContractVersion, int) =
  ## The encoder and user-input count an observation contract hash names: v1, v2, or
  ## v2u<K> (= v2 + K); ValueError for anything else.
  let k = userInputsFromHash(hash)
  if k > 0: (ocV2, k) else: (observationContractVersion(hash), 0)

proc loadNeuralSeat*(sourcePath: string, slot: int): NeuralSeat =
  result = NeuralSeat(slot: slot, previousTick: -1)
  let modelPath = sourcePath & ".model.bin"
  if not fileExists(modelPath): return
  let actor = loadActorFile(modelPath)
  # Model metadata is authoritative even when running a local unpacked package. The
  # observation contract hash selects the encoder (v1, or v2 = v1 + terrain block) and
  # fixes the input width; the action contract hash selects the decoder: v1 (identity
  # aim = body position) or v2 (lead-compensated identity aim); anything else is rejected.
  # Checks run in the order they always have (dimensions, then contracts), so a bundle
  # rejected before v2 existed is rejected with the same message; an unknown observation
  # hash is held to v1's width for the dimension check.
  var observationContract = ocV1
  var userInputs = 0
  var observationKnown = true
  try: (observationContract, userInputs) = observationFor(actor.observationContract)
  except ValueError: observationKnown = false
  if actor.inputSize != observationSize(observationContract) + userInputs or actor.outputSize != LogitSize or
      actor.headSizes != @ActionSizes:
    raise newException(ValueError, "neural actor dimensions do not match Paintbot contract")
  if not observationKnown:
    raise newException(ValueError, "neural actor contract mismatch")
  var contract: ActionContractVersion
  try: contract = actionContractVersion(actor.actionContract)
  except ValueError: raise newException(ValueError, "neural actor contract mismatch")
  if actor.operationCount > MaxNeuralOperations:
    let e = newException(NeuralBudgetError, "neural actor exceeds native operation budget")
    e.operations = actor.operationCount
    e.hiddenSize = actor.hiddenSize
    raise e
  let manifestPath = sourcePath & ".neural.json"
  var manifest: JsonNode = nil
  if fileExists(manifestPath):
    if getFileSize(manifestPath) > 8192: raise newException(ValueError, "oversized neural manifest")
    manifest = parseJson(readFile(manifestPath))
    if manifest{"observation_contract"}.getStr != actor.observationContract or
        manifest{"action_contract"}.getStr != actor.actionContract:
      raise newException(ValueError, "package and actor contract mismatch")
  result.configureSeat(manifest, userInputs)
  result.actor = actor
  result.contract = contract
  result.observationContract = observationContract
  result.observation = newSeq[float32](observationSize(observationContract) + userInputs)
  result.state = newSeq[float32](actor.hiddenSize)

proc policyNeuralSeat*(manifestText: string, slot: int, observationHash: string): NeuralSeat =
  ## A training policy-script seat (native pw_set_seat_policy_script): the bundle's
  ## manifest governs the seat exactly as on the host (decoder options, sampling, user
  ## inputs, action contract), but there is no actor: the trainer feeds each tick's logits.
  ## The manifest's observation contract must be `observationHash`, the handle's.
  ## ValueError when the manifest would be rejected.
  result = NeuralSeat(slot: slot, previousTick: -1, external: true)
  if manifestText.len > 8192: raise newException(ValueError, "oversized neural manifest")
  let manifest = parseJson(manifestText)
  if manifest.kind != JObject or manifest{"schema"}.getStr notin
      ["paintbot-neural-basic/1", "paintbot-neural-basic/2"]:
    raise newException(ValueError, "unsupported neural package schema")
  if manifest{"observation_contract"}.getStr != observationHash:
    raise newException(ValueError, "manifest observation contract does not match the handle's")
  let (observationContract, userInputs) = observationFor(observationHash)
  var contract: ActionContractVersion
  try: contract = actionContractVersion(manifest{"action_contract"}.getStr)
  except ValueError: raise newException(ValueError, "neural actor contract mismatch")
  result.configureSeat(manifest, userInputs)
  result.contract = contract
  result.observationContract = observationContract
  result.observation = newSeq[float32](observationSize(observationContract) + userInputs)
  result.fedLogits = newSeq[float32](LogitSize)

proc beginTick*(seat: NeuralSeat, w: var World) =
  let alive = w.cogs[seat.slot].hp > 0
  if not alive or not seat.previouslyAlive or w.tick <= seat.previousTick:
    for i in 0..<seat.state.len: seat.state[i] = 0
    seat.memory.resetAimMemory()
  if seat.userInputs.len > 0:
    # User inputs persist across ticks and deaths; a new match starts from init. The
    # tick's observation reads what the previous tick's script left.
    if seat.previousTick < 0 or w.tick <= seat.previousTick: seat.userInputs = seat.userInputInit
    seat.userInputView = seat.userInputs
  seat.previouslyAlive = alive
  seat.bodiesReady = false
  seat.previousTick = w.tick
  seat.world = addr w
  if seat.sampling.enabled and not seat.sampleSeeded:
    # One stream per seat per match, from the match seed: its position depends only on
    # the decisions taken, and it survives death and respawn (the stream is not state
    # the network reads; resetting it would only correlate draws after every respawn).
    seat.sampleRng = samplingRng(w.seed, seat.slot)
    seat.sampleSeeded = true
  if seat.strafe.enabled:
    if not seat.strafeSeeded:
      # Seeded like the sampling stream: one per seat per match, from the match seed.
      seat.strafeRng = strafeRng(w.seed, seat.slot)
      seat.strafeSeeded = true
    if not alive: seat.strafeState.leg = 0
  seat.observed = false
  seat.inferred = false
  seat.acted = false
  seat.nativeWork = 0
  seat.observationFresh = false
  if seat.maskSet: seat.masks = default(HeadMasks)
  seat.maskSet = false
  seat.temperatureSet = default(array[ActionSizes.len, bool])
  seat.sampled = false
  seat.decoded = false

proc bodiesFor(seat: NeuralSeat): array[Seats, int] =
  if not seat.bodiesReady:
    seat.bodies = seat.world[].observedBodies(seat.slot)
    seat.bodiesReady = true
  seat.bodies

proc require(seat: NeuralSeat, condition: bool, message: string) =
  if seat.actor.isNil and not seat.external: raise newException(BasicError, "no neural model in policy package")
  if not condition: raise newException(BasicError, message)

proc ensureObservation(seat: NeuralSeat) =
  ## Encode this tick's observation into the seat's buffer (once per tick; the world is
  ## the unchanged pre-action world, so every encode of a tick is the same bytes).
  if seat.observationFresh: return
  if seat.userInputView.len > 0:
    encodeObservationInputs(seat.world[], seat.slot, seat.observation, seat.bodiesFor(), seat.userInputView)
  elif seat.observationContract == ocV1:
    encodeObservation(seat.world[], seat.slot, seat.observation, seat.bodiesFor())
  else:
    encodeObservation(seat.world[], seat.slot, seat.observation, seat.bodiesFor(), seat.observationContract)
  seat.observationFresh = true

proc samplePhase(seat: NeuralSeat) =
  ## Selection (forbid / BASIC masks, argmax or sampling / BASIC temperatures), then the
  ## aim-phase decoder options in the hosted order: aim retarget, aim snap, spray aim,
  ## shot gate, spray gate. Leaves the heads in seat.choices. With no BASIC mask or
  ## temperature this is exactly the selection paintbot_act has always made.
  let bodies = seat.bodiesFor()
  var actions: array[ActionSizes.len, int32]
  var anyTemperature = false
  for on in seat.temperatureSet:
    if on: anyTemperature = true
  if seat.maskSet or anyTemperature:
    var masks = seat.masks
    for i in 0..<ActionSizes[0]:
      if seat.forbidden[i]: masks[0][i] = true
    var temperatures: HeadTemperatures
    for head in 0..<ActionSizes.len:
      temperatures[head] =
        if seat.temperatureSet[head]: seat.temperatures[head]
        elif seat.sampling.enabled and seat.sampling.heads[head]: seat.sampling.temperature
        else: 0'f32
      seat.appliedTemperatures[head] =
        if seat.temperatureSet[head]: int32(round(float64(seat.temperatures[head]) * 1000))
        elif temperatures[head] > 0: int32(round(float64(temperatures[head]) * 1000))
        else: 0'i32
    if not seat.sampleSeeded:
      seat.sampleRng = samplingRng(seat.world[].seed, seat.slot)
      seat.sampleSeeded = true
    var draws = 0
    actions = sampleHeads(seat.logits, temperatures, masks, seat.sampleRng, draws)
    if draws > 0: inc seat.sampleDraws
    seat.appliedMasks = masks
  else:
    actions = if seat.sampling.enabled: sampleActions(seat.logits, seat.sampling, seat.sampleRng, seat.forbidden)
              else: argmaxActions(seat.logits, seat.forbidden)
    if seat.sampling.enabled: inc seat.sampleDraws
    seat.appliedMasks = default(HeadMasks)
    seat.appliedMasks[0] = seat.forbidden
    for head in 0..<ActionSizes.len:
      seat.appliedTemperatures[head] =
        if seat.sampling.enabled and seat.sampling.heads[head]: int32(round(float64(seat.sampling.temperature) * 1000))
        else: 0'i32
  if seat.forbidAny and seat.forbidden[argmaxActions(seat.logits)[0]]: inc seat.forbidHits
  seat.selected = actions
  if seat.aimRetarget.enabled and seat.world[].aimRetargetActions(seat.slot, actions, bodies,
      seat.contract, seat.memory, seat.aimRetarget):
    inc seat.aimRetargets
  let beforeSnap = actions
  var snapped = seat.aimSnap.enabled and seat.world[].aimSnapActions(seat.slot, actions, bodies, seat.aimSnap)
  var sprayAimed = seat.sprayAim.enabled and seat.world[].sprayAimActions(seat.slot, actions, bodies,
    seat.contract, seat.memory, seat.sprayAim)
  if seat.shotGate.enabled and seat.world[].shotGateActions(seat.slot, actions, beforeSnap, snapped,
      bodies, seat.contract, seat.memory, seat.shotGate):
    snapped = false   # a dropped order never shot, so it was never snapped or re-aimed
    sprayAimed = false
    inc seat.shotGates
  if snapped: inc seat.aimSnaps
  if sprayAimed: inc seat.sprayAims
  if seat.sprayGate.enabled and seat.world[].sprayGateActions(seat.slot, actions, bodies, seat.contract,
      seat.memory, seat.sprayGate):
    inc seat.sprayGates
  seat.choices = actions
  seat.sampled = true

proc decodePhase(seat: NeuralSeat) =
  ## The movement-phase options (strafe, steady shot), the decode, the fire hold; the
  ## command goes to the buffer, not the world. Records the contract-v2 aim memory.
  let bodies = seat.bodiesFor()
  var actions = seat.choices
  if seat.strafe.enabled:
    var forbidden = seat.forbidden
    if seat.maskSet:
      for i in 0..<ActionSizes[0]:
        if seat.masks[0][i]: forbidden[i] = true
    discard seat.world[].strafeActions(seat.slot, actions, bodies, seat.strafe, seat.strafeState,
      seat.strafeRng, forbidden)
  if seat.steadyShot:
    let held = seat.world[].steadyShotActions(seat.slot, actions, true)
    if held != ssNone: inc seat.steadyTicks
    if held == ssOrder: inc seat.steadyShots
  seat.choices = actions
  seat.decodeMemory = seat.memory
  var command = decodeActions(seat.world[], seat.slot, actions, bodies, seat.contract, seat.memory)
  if seat.fireHoldTeammates and seat.world[].holdFire(seat.slot, command, seat.fireHoldRadius): inc seat.fireHolds
  seat.buffer = command
  seat.decoded = true
  if seat.contract == acV2:
    seat.memory.recordAimMemory(seat.world[], seat.slot, bodies)

proc candidateMemory(seat: NeuralSeat): AimMemory =
  ## The memory this tick's decode reads (the recorded one replaces it after decoding).
  if seat.decoded: seat.decodeMemory else: seat.memory

proc aimCandidatePoint(seat: NeuralSeat, aim: int): (bool, Point) =
  ## neuralAimX/Z: aim head index `aim` under the seat's contract, with the tick's current
  ## movement and sneak heads for a contract-v2 identity lead (pw_action_candidates' rule).
  let w = seat.world
  if w[].cogs[seat.slot].hp <= 0: return (false, Point())
  if aim == 0: return (true, w[].cogs[seat.slot].aim)
  var ownStep = Point()
  if seat.contract == acV2 and aim in 1..16:
    let (found, goal) = w[].goalCandidate(seat.slot, seat.choices[0].int)
    ownStep = w[].plannedStep(seat.slot, if found: goal else: w[].cogs[seat.slot].pos, seat.choices[4] != 0)
  w[].aimCandidate(seat.slot, aim, seat.bodiesFor(), seat.contract, seat.candidateMemory(), ownStep)

proc addNeuralFunctions*(h: var Host, seat: NeuralSeat,
    apply: proc(command: Command) {.closure.}) =
  # A handle is a typed capability interpreted only within this seat's closure.
  discard h.addFunction("neuralModel", 0, proc(a: openArray[int32]): int32 = 1, 4)
  discard h.addFunction("neuralObservation", 0, proc(a: openArray[int32]): int32 = 2, 4)
  discard h.addFunction("neuralLogits", 0, proc(a: openArray[int32]): int32 = 3, 4)
  discard h.addFunction("neuralState", 0, proc(a: openArray[int32]): int32 = 4, 4)
  discard h.addFunction("paintbot_observe", 1, proc(a: openArray[int32]): int32 =
    seat.require(a[0] == 2 and not seat.observed, "invalid or repeated neural observation")
    try:
      seat.ensureObservation()
    except ValueError as e:
      raise newException(BasicError, "neural observation failed: " & e.msg)
    seat.observed = true
    1, 512)
  discard h.addFunction("run_neural_net", 4, proc(a: openArray[int32]): int32 =
    seat.require(a[0] == 1 and a[1] == 2 and a[2] == 3 and a[3] == 4,
      "invalid typed neural buffer handles")
    seat.require(seat.observed and not seat.inferred, "neural inference requires fresh observation; limited to once per tick")
    if seat.external:
      # Training: the trainer ran the actor on this tick's observation; its logits stand in.
      seat.require(seat.logitsFed, "no trainer logits for this tick")
      for i in 0..<LogitSize: seat.logits[i] = seat.fedLogits[i]
    else:
      try:
        seat.actor.infer(seat.observation, seat.state, seat.logits)
      except ValueError as e:
        raise newException(BasicError, "neural inference failed: " & e.msg)
      seat.nativeWork = seat.actor.operationCount
    seat.inferred = true
    1, 16)
  discard h.addFunction("paintbot_act", 1, proc(a: openArray[int32]): int32 =
    # = neuralDecode + neuralIssue (sampling first when neuralSample was not called).
    seat.require(a[0] == 3 and seat.inferred and not seat.acted, "neural action requires fresh logits")
    try:
      if not seat.sampled: seat.samplePhase()
      if not seat.decoded: seat.decodePhase()
      apply(seat.buffer)
    except ValueError as e:
      raise newException(BasicError, "neural action failed: " & e.msg)
    seat.acted = true
    1, 128)

  # Neural BASIC I/O (PLAN-neural-basic-io). Part A: user inputs.
  discard h.addFunction("neuralInput", 2, proc(a: openArray[int32]): int32 =
    seat.require(seat.userInputs.len > 0, "no user inputs in policy package")
    seat.require(a[0] >= 0 and a[0] < seat.userInputs.len.int32, "neuralInput index out of range")
    seat.userInputs[a[0]] = clampUserInput(a[1])
    1, 4)
  discard h.addFunction("neuralObs", 1, proc(a: openArray[int32]): int32 =
    seat.require(a[0] >= 0 and a[0] < seat.observation.len.int32, "neuralObs index out of range")
    try:
      seat.ensureObservation()
    except ValueError as e:
      raise newException(BasicError, "neural observation failed: " & e.msg)
    int32(clamp(round(float64(seat.observation[a[0]]) * 1000), float64(int32.low), float64(int32.high))), 4)
  # Part B: the head-level phase. Masks and temperatures apply to this tick's selection.
  proc maskFrom(head, first, bits: int32): int32 =
    seat.require(not seat.sampled, "neuralMask must come before the tick's selection")
    seat.require(head in 0'i32..<ActionSizes.len.int32, "neuralMask head out of range")
    seat.require(first >= 0 and first < ActionSizes[head].int32, "neuralMaskFrom first choice out of range")
    for bit in 0..31:
      let choice = first.int + bit
      if choice >= ActionSizes[head]: break
      seat.masks[head][choice] = ((cast[uint32](bits) shr bit) and 1) != 0
    seat.maskSet = true
    1
  discard h.addFunction("neuralMask", 2, proc(a: openArray[int32]): int32 = maskFrom(a[0], 0, a[1]), 4)
  discard h.addFunction("neuralMaskFrom", 3, proc(a: openArray[int32]): int32 = maskFrom(a[0], a[1], a[2]), 4)
  discard h.addFunction("neuralTemperature", 2, proc(a: openArray[int32]): int32 =
    seat.require(not seat.sampled, "neuralTemperature must come before the tick's selection")
    seat.require(a[0] in -1'i32..<ActionSizes.len.int32, "neuralTemperature head out of range")
    seat.require(a[1] == 0 or a[1] in MinBasicTemperatureMilli..MaxBasicTemperatureMilli,
      "neuralTemperature must be 0 (argmax) or within 1 .. 100000 milli")
    let t = float32(float64(a[1]) / 1000.0)
    for head in 0..<ActionSizes.len:
      if a[0] == -1 or a[0] == head.int32:
        seat.temperatures[head] = t
        seat.temperatureSet[head] = true
    1, 4)
  discard h.addFunction("neuralSample", 0, proc(a: openArray[int32]): int32 =
    seat.require(seat.inferred and not seat.sampled, "neuralSample requires fresh logits; once per tick")
    try: seat.samplePhase()
    except ValueError as e: raise newException(BasicError, "neural action failed: " & e.msg)
    1, 48)
  discard h.addFunction("neuralChoice", 1, proc(a: openArray[int32]): int32 =
    seat.require(seat.sampled, "neuralChoice requires neuralSample or neuralDecode first")
    seat.require(a[0] in 0'i32..<ActionSizes.len.int32, "neuralChoice head out of range")
    seat.choices[a[0]], 4)
  discard h.addFunction("neuralSetChoice", 2, proc(a: openArray[int32]): int32 =
    seat.require(seat.sampled and not seat.decoded, "neuralSetChoice must come between neuralSample and neuralDecode")
    seat.require(a[0] in 0'i32..<ActionSizes.len.int32, "neuralSetChoice head out of range")
    seat.require(a[1] >= 0 and a[1] < ActionSizes[a[0]].int32, "neuralSetChoice choice out of range")
    seat.choices[a[0]] = a[1]
    1, 4)
  discard h.addFunction("neuralDecode", 0, proc(a: openArray[int32]): int32 =
    seat.require(seat.inferred and not seat.decoded, "neuralDecode requires fresh logits; once per tick")
    try:
      if not seat.sampled: seat.samplePhase()
      seat.decodePhase()
    except ValueError as e: raise newException(BasicError, "neural action failed: " & e.msg)
    1, 64)
  discard h.addFunction("neuralIssue", 0, proc(a: openArray[int32]): int32 =
    seat.require(seat.decoded and not seat.acted, "neuralIssue requires neuralDecode; once per tick")
    apply(seat.buffer)
    seat.acted = true
    1, 16)
  proc cmdRead(field: int): HostProc =
    result = proc(a: openArray[int32]): int32 =
      seat.require(seat.decoded, "command readers require neuralDecode first")
      let c = seat.buffer
      case field
      of 0: c.walk.int32
      of 1: c.goal.x
      of 2: c.goal.z
      of 3: c.shoot.int32
      of 4: c.aim.x
      of 5: c.aim.z
      of 6: c.chargeGrenade.int32
      of 7: c.sneak.int32
      else: c.direct.int32
  for field, name in ["cmdWalk", "cmdGoalX", "cmdGoalZ", "cmdShoot", "cmdAimX", "cmdAimZ",
      "cmdGrenade", "cmdSneak", "cmdDirect"]:
    discard h.addFunction(name, 0, cmdRead(field), 4)
  discard h.addFunction("cmdSet", 2, proc(a: openArray[int32]): int32 =
    # Field ids as the readers (pw_seat_orders' layout): 0 walk, 1 goal x, 2 goal z,
    # 3 shoot, 4 aim x, 5 aim z, 6 grenade, 7 sneak, 8 direct. Flags are value != 0; an
    # aim coordinate is clamped to the map as lookAt clamps it; a goal is kept verbatim
    # as walkTo keeps it.
    seat.require(seat.decoded and not seat.acted, "cmdSet requires neuralDecode and comes before neuralIssue")
    seat.require(a[0] in 0'i32..8'i32, "cmdSet field out of range")
    let v = a[1]
    case a[0]
    of 0: seat.buffer.walk = v != 0
    of 1: seat.buffer.goal.x = v
    of 2: seat.buffer.goal.z = v
    of 3: seat.buffer.shoot = v != 0
    of 4: seat.buffer.aim.x = clamp(v, minX().int32, maxX().int32)
    of 5: seat.buffer.aim.z = clamp(v, minZ().int32, maxZ().int32)
    of 6: seat.buffer.chargeGrenade = v != 0
    of 7: seat.buffer.sneak = v != 0
    else: seat.buffer.direct = v != 0
    1, 4)
  # Candidate readers (pw_action_candidates for the seat): INT32_MIN when the candidate
  # does not exist now. Goal 0 is the seat's position, aim 0 its current aim.
  proc goalRead(axis: int): HostProc =
    result = proc(a: openArray[int32]): int32 =
      seat.require(a[0] in 0'i32..<ActionSizes[0].int32, "neuralGoal index out of range")
      let w = seat.world
      if w[].cogs[seat.slot].hp <= 0: return low(int32)
      let (found, p) = if a[0] == 0: (true, w[].cogs[seat.slot].pos) else: w[].goalCandidate(seat.slot, a[0].int)
      if not found: low(int32) elif axis == 0: p.x else: p.z
  discard h.addFunction("neuralGoalX", 1, goalRead(0), 8)
  discard h.addFunction("neuralGoalZ", 1, goalRead(1), 8)
  proc aimRead(axis: int): HostProc =
    result = proc(a: openArray[int32]): int32 =
      seat.require(seat.sampled, "neuralAim readers require neuralSample or neuralDecode first")
      seat.require(a[0] in 0'i32..<ActionSizes[1].int32, "neuralAim index out of range")
      let (found, p) = seat.aimCandidatePoint(a[0].int)
      if not found: low(int32) elif axis == 0: p.x else: p.z
  discard h.addFunction("neuralAimX", 1, aimRead(0), 16)
  discard h.addFunction("neuralAimZ", 1, aimRead(1), 16)
