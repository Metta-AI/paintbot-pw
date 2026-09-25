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
  var observationKnown = true
  try: observationContract = observationContractVersion(actor.observationContract)
  except ValueError: observationKnown = false
  if actor.inputSize != observationSize(observationContract) or actor.outputSize != LogitSize or
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
  if fileExists(manifestPath):
    if getFileSize(manifestPath) > 8192: raise newException(ValueError, "oversized neural manifest")
    let manifest = parseJson(readFile(manifestPath))
    if manifest{"observation_contract"}.getStr != actor.observationContract or
        manifest{"action_contract"}.getStr != actor.actionContract:
      raise newException(ValueError, "package and actor contract mismatch")
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
  result.actor = actor
  result.contract = contract
  result.observationContract = observationContract
  result.fireHoldTeammates = fireHold
  result.fireHoldRadius = fireHoldRadius
  result.sampling = sampling
  result.forbidden = forbidden
  result.forbidAny = forbidden.forbidsAny
  result.strafe = strafe
  result.strafeState = initStrafeState(slot)
  result.aimSnap = aimSnap
  result.steadyShot = steadyShot
  result.aimRetarget = aimRetarget
  result.shotGate = shotGate
  result.sprayAim = sprayAim
  result.sprayGate = sprayGate
  result.memory.resetAimMemory()
  result.observation = newSeq[float32](observationSize(observationContract))
  result.logits = newSeq[float32](LogitSize)
  result.state = newSeq[float32](actor.hiddenSize)

proc beginTick*(seat: NeuralSeat, w: var World) =
  let alive = w.cogs[seat.slot].hp > 0
  if not alive or not seat.previouslyAlive or w.tick <= seat.previousTick:
    for i in 0..<seat.state.len: seat.state[i] = 0
    seat.memory.resetAimMemory()
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

proc bodiesFor(seat: NeuralSeat): array[Seats, int] =
  if not seat.bodiesReady:
    seat.bodies = seat.world[].observedBodies(seat.slot)
    seat.bodiesReady = true
  seat.bodies

proc require(seat: NeuralSeat, condition: bool, message: string) =
  if seat.actor.isNil: raise newException(BasicError, "no neural model in policy package")
  if not condition: raise newException(BasicError, message)

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
      if seat.observationContract == ocV1:
        encodeObservation(seat.world[], seat.slot, seat.observation, seat.bodiesFor())
      else:
        encodeObservation(seat.world[], seat.slot, seat.observation, seat.bodiesFor(), seat.observationContract)
    except ValueError as e:
      raise newException(BasicError, "neural observation failed: " & e.msg)
    seat.observed = true
    1, 512)
  discard h.addFunction("run_neural_net", 4, proc(a: openArray[int32]): int32 =
    seat.require(a[0] == 1 and a[1] == 2 and a[2] == 3 and a[3] == 4,
      "invalid typed neural buffer handles")
    seat.require(seat.observed and not seat.inferred, "neural inference requires fresh observation; limited to once per tick")
    try:
      seat.actor.infer(seat.observation, seat.state, seat.logits)
    except ValueError as e:
      raise newException(BasicError, "neural inference failed: " & e.msg)
    seat.nativeWork = seat.actor.operationCount
    seat.inferred = true
    1, 16)
  discard h.addFunction("paintbot_act", 1, proc(a: openArray[int32]): int32 =
    seat.require(a[0] == 3 and seat.inferred and not seat.acted, "neural action requires fresh logits")
    try:
      let bodies = seat.bodiesFor()
      var command: Command
      if seat.forbidAny or seat.strafe.enabled or seat.aimSnap.enabled or seat.steadyShot or
          seat.aimRetarget.enabled or seat.shotGate.enabled or seat.sprayAim.enabled or seat.sprayGate.enabled:
        # Order: forbid (selection), sampling or argmax, aim retarget (aim), aim snap (aim),
        # spray aim (aim), shot gate (shoot), spray gate (shoot), strafe (movement), steady
        # shot (movement), decode, hold.
        var actions = if seat.sampling.enabled: sampleActions(seat.logits, seat.sampling, seat.sampleRng, seat.forbidden)
                      else: argmaxActions(seat.logits, seat.forbidden)
        if seat.sampling.enabled: inc seat.sampleDraws
        if seat.forbidAny and seat.forbidden[argmaxActions(seat.logits)[0]]: inc seat.forbidHits
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
        if seat.strafe.enabled:
          discard seat.world[].strafeActions(seat.slot, actions, bodies, seat.strafe, seat.strafeState,
            seat.strafeRng, seat.forbidden)
        if seat.steadyShot:
          let held = seat.world[].steadyShotActions(seat.slot, actions, true)
          if held != ssNone: inc seat.steadyTicks
          if held == ssOrder: inc seat.steadyShots
        command = decodeActions(seat.world[], seat.slot, actions, bodies, seat.contract, seat.memory)
      elif seat.sampling.enabled:
        let actions = sampleActions(seat.logits, seat.sampling, seat.sampleRng)
        inc seat.sampleDraws
        command = decodeActions(seat.world[], seat.slot, actions, bodies, seat.contract, seat.memory)
      else:
        command = decodeLogits(seat.world[], seat.slot, seat.logits, bodies, seat.contract, seat.memory)
      if seat.fireHoldTeammates and seat.world[].holdFire(seat.slot, command, seat.fireHoldRadius): inc seat.fireHolds
      apply(command)
      if seat.contract == acV2:
        seat.memory.recordAimMemory(seat.world[], seat.slot, bodies)
    except ValueError as e:
      raise newException(BasicError, "neural action failed: " & e.msg)
    seat.acted = true
    1, 128)
