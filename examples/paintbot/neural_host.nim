## Seat-owned FP32 buffers. Integer handles never index shared state.
import std/[os, json]
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
    # The seat's apparent identities for this tick, resolved once for the observation
    # and the action decode (both read the same pre-action world).
    bodies: array[Seats, int]
    bodiesReady: bool

proc neuralTelemetry*(peakOperations: int64, hiddenSize, ticks: int): string =
  ## One private seat-log line: peak native operations in a tick against the budget, the
  ## model width and the ticks played. Diagnostics only; it reads no simulation state.
  "neural: peak_ops=" & $peakOperations & " budget=" & $MaxNeuralOperations &
    " model=w" & $hiddenSize & " ticks=" & $ticks

proc telemetry*(seat: NeuralSeat, peakOperations: int64, ticks: int): string =
  ## Empty for a seat without a loaded neural model, so plain BASIC seats log nothing.
  if seat.isNil or seat.actor.isNil: ""
  else: neuralTelemetry(peakOperations, seat.actor.hiddenSize, ticks)

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
  if fileExists(manifestPath):
    if getFileSize(manifestPath) > 8192: raise newException(ValueError, "oversized neural manifest")
    let manifest = parseJson(readFile(manifestPath))
    if manifest["observation_contract"].getStr != actor.observationContract or
        manifest["action_contract"].getStr != actor.actionContract:
      raise newException(ValueError, "package and actor contract mismatch")
  result.actor = actor
  result.contract = contract
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
      apply(decodeLogits(seat.world[], seat.slot, seat.logits, bodies, seat.contract, seat.memory))
      if seat.contract == acV2:
        seat.memory.recordAimMemory(seat.world[], seat.slot, bodies)
    except ValueError as e:
      raise newException(BasicError, "neural action failed: " & e.msg)
    seat.acted = true
    1, 128)
