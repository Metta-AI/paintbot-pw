## Seat-owned FP32 buffers. Integer handles never index shared state.
import std/[os, json, strutils]
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
    # The bundle's decoder options (manifest "decoder", schema 2): fireHoldTeammates
    # applies holdFire to every decoded command; fireHolds counts the orders it held.
    fireHoldTeammates*: bool
    fireHolds*: int
    # decoder.sampling: the seat's own draw stream (seeded from the match seed and the
    # slot the first time the seat sees the world; never part of the world or its hash),
    # the options, and how many decisions were drawn. Off = argmax, no stream, no draw.
    sampling*: SamplingOptions
    sampleRng: Rng
    sampleSeeded: bool
    sampleDraws*: int
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

proc neuralTelemetry*(peakOperations: int64, hiddenSize, ticks: int,
    fireHolds = -1, sampling = ""): string =
  ## One private seat-log line: peak native operations in a tick against the budget, the
  ## model width and the ticks played; with the fire-hold decoder option on, also the
  ## number of shoot orders it held (omitted, and the line unchanged, when it is off).
  ## Diagnostics only; it reads no simulation state.
  result = "neural: peak_ops=" & $peakOperations & " budget=" & $MaxNeuralOperations &
    " model=w" & $hiddenSize & " ticks=" & $ticks
  if fireHolds >= 0: result.add " fire_holds=" & $fireHolds
  result.add sampling

proc telemetry*(seat: NeuralSeat, peakOperations: int64, ticks: int): string =
  ## Empty for a seat without a loaded neural model, so plain BASIC seats log nothing.
  if seat.isNil or seat.actor.isNil: ""
  else: neuralTelemetry(peakOperations, seat.actor.hiddenSize, ticks,
    if seat.fireHoldTeammates: seat.fireHolds else: -1,
    if seat.sampling.enabled: samplingTelemetry(seat.sampling, seat.samplingLogSeed, seat.sampleDraws) else: "")

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

proc loadNeuralSeat*(sourcePath: string, slot: int): NeuralSeat =
  result = NeuralSeat(slot: slot, previousTick: -1)
  let modelPath = sourcePath & ".model.bin"
  if not fileExists(modelPath): return
  let actor = loadActorFile(modelPath)
  if actor.inputSize != ObservationSize or actor.outputSize != LogitSize or
      actor.headSizes != @ActionSizes:
    raise newException(ValueError, "neural actor dimensions do not match Paintbot contract")
  # Model metadata is authoritative even when running a local unpacked package. The
  # action contract hash selects the decoder: v1 (identity aim = body position) or v2
  # (lead-compensated identity aim); anything else is rejected.
  if actor.observationContract != ObservationContractHash:
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
  var sampling: SamplingOptions
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
          if value.kind != JBool: raise newException(ValueError, "decoder.fire_hold_teammates must be a boolean")
          fireHold = value.getBool
        of "sampling":
          sampling = parseSamplingOptions(value)
        else: raise newException(ValueError, "unknown decoder option: " & key)
  result.actor = actor
  result.contract = contract
  result.fireHoldTeammates = fireHold
  result.sampling = sampling
  result.memory.resetAimMemory()
  result.observation = newSeq[float32](ObservationSize)
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
      encodeObservation(seat.world[], seat.slot, seat.observation, seat.bodiesFor())
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
      if seat.sampling.enabled:
        let actions = sampleActions(seat.logits, seat.sampling, seat.sampleRng)
        inc seat.sampleDraws
        command = decodeActions(seat.world[], seat.slot, actions, bodies, seat.contract, seat.memory)
      else:
        command = decodeLogits(seat.world[], seat.slot, seat.logits, bodies, seat.contract, seat.memory)
      if seat.fireHoldTeammates and seat.world[].holdFire(seat.slot, command): inc seat.fireHolds
      apply(command)
      if seat.contract == acV2:
        seat.memory.recordAimMemory(seat.world[], seat.slot, bodies)
    except ValueError as e:
      raise newException(BasicError, "neural action failed: " & e.msg)
    seat.acted = true
    1, 128)
