## Seat-owned FP32 buffers. Integer handles never index shared state. A neural seat reads
## only its SeatView (the observation it encodes) and hands BASIC numbers: observation values,
## logits and head choices. Its policy.bas turns those into the BASIC action verbs; nothing
## here writes a command (docs/neural/seat-view.md).
import std/[os, json, strutils, math]
import polyworld/rngs
import polyworld/basic
import seat_view, neural_actor, neural_contract

const MaxNeuralOperations* = 4_000_000'i64

proc neuralOperationBudget*(seats: int): int64 =
  ## Native operations a seat's model may take per tick in a match of `seats` seats: the
  ## 16-seat budget, scaled like BASIC's instruction budget above 16 seats (x seats / 16).
  if seats > LegacySeats: MaxNeuralOperations * seats div LegacySeats else: MaxNeuralOperations

type
  NeuralBudgetError* = object of ValueError
    ## The package's model needs more native operations per tick than the budget allows.
    operations*: int64
    hiddenSize*: int
    model*: string  # modelTag of the rejected actor
  NeuralSeat* = ref object
    actor*: Actor
    observation*, logits*, state*: seq[float32]
    slot*: int
    # The tick's view (beginTick) and the match seed the seat's streams are seeded from.
    view: SeatView
    viewReady: bool
    matchSeed: int32
    observed, inferred: bool
    previousTick: int32
    previouslyAlive: bool
    nativeWork*: int64
    # The action contract the actor was trained against (named by its embedded hash) and the
    # observation contract (teams.view.1 or ffa.view.1, either with K user inputs: u<K>):
    # selects the encoder.
    contract*: ActionContractVersion
    observationContract*: ObservationContractVersion
    # decoder.sampling: the seat's own draw stream (seeded from the match seed and the
    # slot the first time the seat draws; never part of the world or its hash), the options,
    # and how many decisions were drawn. Off = argmax, no stream, no draw.
    sampling*: SamplingOptions
    joint*: JointSampling      # decoder.joint_sampling (disabled = absent)
    jointDraws*: int           # decisions the joint condition held on
    # The model's COND_HEAD layers (learned conditional heads; the actor's, or for a training
    # policy seat the trainer's, pw_set_seat_conditionals), and the draws they took.
    conditionals*: seq[Conditional]
    conditionalDraws*: int
    sampleRng: Rng
    sampleSeeded: bool
    sampleDraws*: int
    # Training library only (native pw_set_sampling_salt, on a policy seat): a salt mixed into
    # the stream's seed (neural_contract.samplingRngSalted). A hosted seat never sets it: 0 =
    # samplingRng exactly.
    sampleSalt*: int64
    # decoder.forbid_objectives: movement-head indices never selected (argmax or draw);
    # forbidHits counts decisions whose unmasked argmax objective was one of them.
    forbidden*: ObjectiveMask
    forbidAny*: bool
    forbidHits*: int
    # User inputs (manifest "user_inputs", observation contract teams.view.1u<K> or
    # ffa.view.1u<K>): the live
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
    # A training decoder seat (native pw_step's caller heads): no actor, no logits; the
    # caller's head choices are the tick's selection (neuralChoice reads them).
    fedChoices*: array[ActionSizes.len, int32]
    fedOffsetChoices*: array[ExtraHeadsMax, int32]
    choicesFed*: bool
    # Action contracts teams.view.1 aim-offset (heads 5 and 6) and movement-offset (heads 5 to
    # 8), 23 bins each: the extra heads, selected after the five main heads by argmax or a
    # temperature (neuralTemperature(h / -1), or decoder.sampling), on the seat's own stream in
    # head order, and read back with neuralChoice(h). extraHeads = how many (0, 2 or 4).
    offsetHeads*: bool
    extraHeads*: int
    # Action contract 15: heads 5 and 6 are drawn from the 23-logit row of the identity the aim head chose (rows at
    # LogitSize + (head - 5) * TargetRows * 23 + j * 23); no draw (the centre bin) when it chose keep or a compass point.
    targetRows*: bool
    offsetTemperatures: array[ExtraHeadsMax, float32]
    offsetTemperatureSet: array[ExtraHeadsMax, bool]
    offsetSelected*, offsetChoices*: array[ExtraHeadsMax, int32]
    appliedOffsetTemperatures*: array[ExtraHeadsMax, int32]
    # The tick's head-level phase: BASIC masks and temperatures (before selection), the
    # selection and its applied masks / temperatures (milli, 0 = argmax).
    masks: HeadMasks
    maskSet: bool
    temperatures: HeadTemperatures
    temperatureSet: array[ActionSizes.len, bool]
    sampled*: bool
    selected*, choices*: array[ActionSizes.len, int32]
    appliedMasks*: HeadMasks
    appliedTemperatures*: array[ActionSizes.len, int32]
    # Action contract ffa.view.1 pointer (observation contract ffa.view.1): the match layout
    # the seat was loaded for, its heads' sizes (teams.view.1: ActionSizes) and the tick's
    # row -> entity map (the observation's, which neuralRow reads back).
    pointer*: bool
    layout*: FfaViewLayout
    heads*: seq[int]
    rows: FfaViewRows
    rowsReady: bool

proc streamStart(seat: NeuralSeat): Rng =
  ## The seat's stream at match start: samplingRng from the match seed and slot (salted only
  ## on a training policy seat given pw_set_sampling_salt).
  if seat.sampleSalt == 0: samplingRng(seat.matchSeed, seat.slot)
  else: samplingRngSalted(seat.matchSeed, seat.slot, seat.sampleSalt)

proc samplingLogSeed(seat: NeuralSeat): uint64 =
  ## The stream's initial state for the log (the state before any draw), recomputed from
  ## the match seed so the line does not depend on how far the stream has advanced; 0
  ## until the seat has drawn.
  if seat.sampleSeeded: seat.streamStart.state else: 0

proc samplingTelemetry*(options: SamplingOptions, seed: uint64, draws: int): string =
  ## The sampling part of the seat log line: mode, temperature, the heads sampled, the
  ## stream's seed and the decisions drawn, so a replay question can be answered from the
  ## log alone.
  result = " sampling=categorical t=" & formatFloat(options.temperature, ffDecimal, 3) & " heads="
  for head, on in options.heads:
    if on: result.add $head
  result.add " seed=0x" & toHex(seed, 16).toLowerAscii & " draws=" & $draws

proc conditionalTelemetry*(conditionals: openArray[Conditional], draws: int): string =
  ## The COND_HEAD part of the seat log line: each condition head -> re-selected head, and the draws taken.
  result = " cond_heads="
  for k, c in conditionals:
    if k > 0: result.add ","
    result.add "h" & $c.whenHead & "->h" & $c.head
  result.add " draws=" & $draws

proc jointTelemetry*(joint: JointSampling, held: int): string =
  ## The joint-sampling part of the seat log line: the condition, the head re-selected and
  ## how many decisions the condition held on.
  " joint_sampling=h" & $joint.whenHead & "=" & $joint.whenValue & "->h" & $joint.head & " held=" & $held

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

proc neuralTelemetry*(peakOperations: int64, model: string, ticks: int, sampling = "", options = ""): string =
  ## One private seat-log line: peak native operations in a tick against the budget, the
  ## model (`modelTag`: `w<hidden>` for PWNET001, `pwnet2-l<layers>-s<state>` for PWNET002)
  ## and the ticks played, then the selection options' parts. Diagnostics only.
  result = "neural: peak_ops=" & $peakOperations & " budget=" & $neuralOperationBudget(Seats) &
    " model=" & model & " ticks=" & $ticks
  result.add sampling
  result.add options

proc neuralTelemetry*(peakOperations: int64, hiddenSize, ticks: int, sampling = "", options = ""): string =
  ## The PWNET001 form: model `w<hiddenSize>`.
  neuralTelemetry(peakOperations, "w" & $hiddenSize, ticks, sampling, options)

proc telemetry*(seat: NeuralSeat, peakOperations: int64, ticks: int): string =
  ## Empty for a seat without a loaded neural model, so plain BASIC seats log nothing.
  if seat.isNil or seat.actor.isNil: ""
  else: neuralTelemetry(peakOperations, seat.actor.modelTag, ticks,
    if seat.sampling.enabled: samplingTelemetry(seat.sampling, seat.samplingLogSeed, seat.sampleDraws) else: "",
    (if seat.forbidAny: forbidTelemetry(seat.forbidden, seat.forbidHits) else: "") &
    (if seat.joint.enabled: jointTelemetry(seat.joint, seat.jointDraws) else: "") &
    (if seat.conditionals.len > 0: conditionalTelemetry(seat.conditionals, seat.conditionalDraws) else: ""))

proc parseSamplingOptions*(value: JsonNode): SamplingOptions =
  ## decoder.sampling: {"mode": "categorical", "temperature": t, "heads": [i, ...]}. mode is
  ## required and only "categorical" is known; temperature is optional (1.0) within
  ## [MinSamplingTemperature, MaxSamplingTemperature]; heads is optional (every head) and
  ## lists distinct head indices 0 ..< ActionSizes.len, or 5 and 6 (the aim-offset heads) and 7
  ## and 8 (the movement-offset heads; the seat's action contract must have them). Anything
  ## else rejects the bundle.
  if value.kind != JObject: raise newException(ValueError, "decoder.sampling must be an object")
  result.enabled = true
  result.temperature = 1'f32
  for head in 0..<ActionSizes.len: result.heads[head] = true
  for e in 0..<ExtraHeadsMax: result.offsetHeads[e] = true
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
      for e in 0..<ExtraHeadsMax: result.offsetHeads[e] = false
      for item in field:
        if item.kind != JInt or item.getInt notin 0..<(ActionSizes.len + ExtraHeadsMax):
          raise newException(ValueError, "decoder.sampling.heads entries must be head indices 0 .. " &
            $(ActionSizes.len + ExtraHeadsMax - 1))
        let h = item.getInt
        if h >= ActionSizes.len:
          if result.offsetHeads[h - ActionSizes.len]: raise newException(ValueError, "decoder.sampling.heads repeats a head")
          result.offsetHeads[h - ActionSizes.len] = true
          if h - ActionSizes.len < AimOffsetHeads: result.offsetListed = true
          else: result.moveListed = true
          continue
        if result.heads[h]: raise newException(ValueError, "decoder.sampling.heads repeats a head")
        result.heads[h] = true
    else: raise newException(ValueError, "unknown decoder.sampling field: " & key)
  if not sawMode: raise newException(ValueError, "decoder.sampling.mode is required")

proc setConditionals*(seat: NeuralSeat, conditionals: seq[Conditional]) =
  ## The model's COND_HEAD layers onto the seat. A bundle cannot also ask for
  ## decoder.joint_sampling: both re-select a head after the tick's selection.
  # COND_HEAD names the five main heads only (the aim-offset heads are selected after it).
  checkConditionals(conditionals, seat.heads[0 ..< min(seat.heads.len, ActionSizes.len)])
  if conditionals.len > 0 and seat.joint.enabled:
    raise newException(ValueError, "decoder.joint_sampling cannot be combined with the model's COND_HEAD layers")
  seat.conditionals = conditionals
  seat.conditionalDraws = 0

proc parseJointSampling*(value: JsonNode): JointSampling =
  ## decoder.joint_sampling: {"when": {"head": h, "value": v}, "head": g, "offsets": [...]}.
  ## h and g are distinct head indices, v a choice of head h, and offsets exactly
  ## ActionSizes[g] finite numbers within [-1000, 1000]. Anything else rejects the bundle.
  if value.kind != JObject: raise newException(ValueError, "decoder.joint_sampling must be an object")
  var sawWhen, sawHead, sawOffsets = false
  var offsets: JsonNode
  for key, field in value:
    case key
    of "when":
      if field.kind != JObject: raise newException(ValueError, "decoder.joint_sampling.when must be an object")
      var sawH, sawV = false
      for k, f in field:
        case k
        of "head":
          if f.kind != JInt or f.getInt notin 0..<ActionSizes.len:
            raise newException(ValueError, "decoder.joint_sampling.when.head must be a head index 0 .. " & $(ActionSizes.len-1))
          result.whenHead = f.getInt; sawH = true
        of "value":
          if f.kind != JInt: raise newException(ValueError, "decoder.joint_sampling.when.value must be an integer")
          result.whenValue = f.getInt; sawV = true
        else: raise newException(ValueError, "unknown decoder.joint_sampling.when field: " & k)
      if not (sawH and sawV): raise newException(ValueError, "decoder.joint_sampling.when needs head and value")
      sawWhen = true
    of "head":
      if field.kind != JInt or field.getInt notin 0..<ActionSizes.len:
        raise newException(ValueError, "decoder.joint_sampling.head must be a head index 0 .. " & $(ActionSizes.len-1))
      result.head = field.getInt; sawHead = true
    of "offsets":
      offsets = field; sawOffsets = true
    else: raise newException(ValueError, "unknown decoder.joint_sampling field: " & key)
  if not (sawWhen and sawHead and sawOffsets):
    raise newException(ValueError, "decoder.joint_sampling needs when, head and offsets")
  if result.whenHead == result.head: raise newException(ValueError, "decoder.joint_sampling.head must differ from when.head")
  if result.whenValue notin 0..<ActionSizes[result.whenHead]:
    raise newException(ValueError, "decoder.joint_sampling.when.value must be a choice of head " & $result.whenHead)
  if offsets.kind != JArray or offsets.len != ActionSizes[result.head]:
    raise newException(ValueError, "decoder.joint_sampling.offsets must list " & $ActionSizes[result.head] & " numbers")
  for i, x in offsets.elems:
    if x.kind notin {JFloat, JInt}: raise newException(ValueError, "decoder.joint_sampling.offsets must be numbers")
    let v = x.getFloat
    if v != v or v < -float(MaxJointOffset) or v > float(MaxJointOffset):
      raise newException(ValueError, "decoder.joint_sampling.offsets must be within [-1000, 1000]")
    result.offsets[i] = float32(v)
  result.enabled = true

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


proc parseUserInputs*(value: JsonNode): seq[int32] =
  ## Manifest "user_inputs": {"count": K, "init": [K integers]}, K within 1 .. 256, every
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


const RetiredDecoderOptions* = ["fire_hold_teammates", "strafe_legs", "aim_snap", "steady_shot",
  "aim_retarget", "shot_gate", "spray_aim", "spray_gate"]
  ## Native decoder rules retired for BASIC parity (docs/neural/seat-view.md): a manifest
  ## naming one is refused; write the rule in policy.bas instead.

proc configureSeat(seat: NeuralSeat, manifest: JsonNode, userInputs: int, pointer = false, extra = 0, target = false) =
  ## The manifest's selection options and user inputs onto the seat (nil manifest = none).
  ## `userInputs` is the K the actor's (or handle's) observation contract names.
  var sampling: SamplingOptions
  var joint: JointSampling
  var forbidden: ObjectiveMask
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
        of "sampling":
          sampling = parseSamplingOptions(value)
          if sampling.offsetListed and extra < AimOffsetHeads:
            raise newException(ValueError, "decoder.sampling.heads 5 and 6 need action contract teams.view.1 aim-offset")
          if sampling.moveListed and extra < AimOffsetHeads + MoveOffsetHeads:
            raise newException(ValueError, "decoder.sampling.heads 7 and 8 need action contract teams.view.1 movement-offset")
          for e in extra..<ExtraHeadsMax:
            if sampling.offsetHeads[e] and value.hasKey("heads"):
              raise newException(ValueError, "decoder.sampling.heads " & $(ActionSizes.len + e) &
                " is not a head of this action contract")
        of "joint_sampling":
          joint = parseJointSampling(value)
        of "forbid_objectives":
          forbidden = parseForbidObjectives(value)
        else:
          if key in RetiredDecoderOptions:
            raise newException(ValueError, "decoder." & key &
              " was retired for BASIC parity (docs/neural/seat-view.md); write the rule in policy.bas")
          raise newException(ValueError, "unknown decoder option: " & key)
        if pointer and key != "sampling":
          # The other options read head indices of the fixed teams contract.
          raise newException(ValueError, "decoder." & key & " is not available under action contract ffa.view.1 pointer")
    if manifest.hasKey("user_inputs"):
      if manifest{"schema"}.getStr != "paintbot-neural-basic/2":
        raise newException(ValueError, "user_inputs need package schema 2")
      init = parseUserInputs(manifest["user_inputs"])
      sawInputs = true
  # The user-input family of the seat's base contract (pointer: ffa.view.1, else teams.view.1).
  let family = if pointer: "ffa.view.1u" else: "teams.view.1u"
  if sawInputs and userInputs == 0:
    raise newException(ValueError, "user_inputs need observation contract " & family & "<K>")
  if userInputs > 0 and not sawInputs:
    raise newException(ValueError, "observation contract " & family & $userInputs & " needs manifest user_inputs")
  if sawInputs and init.len != userInputs:
    raise newException(ValueError, "user_inputs.count does not match observation contract " & family & $userInputs)
  seat.sampling = sampling
  seat.joint = joint
  seat.forbidden = forbidden
  seat.forbidAny = forbidden.forbidsAny
  seat.userInputInit = init
  seat.userInputs = init
  seat.userInputView = init
  seat.pointer = pointer
  seat.offsetHeads = extra > 0
  seat.extraHeads = extra
  seat.heads = case extra
    of 0: @ActionSizes
    of AimOffsetHeads: @ActionSizesOffset
    of AimOffsetHeads + MoveOffsetHeads: @ActionSizesMove
    else: @ActionSizesRaw   # contract 16 (raw): five extra heads
  seat.targetRows = target
  seat.logits = newSeq[float32](if target: (if extra > AimOffsetHeads: LogitSizeRaw else: LogitSizeTarget)
    else: (case extra
      of 0: LogitSize
      of AimOffsetHeads: LogitSizeOffset
      else: LogitSizeMove))

proc observationFor(hash: string): (ObservationContractVersion, int) =
  ## The encoder and user-input count an observation contract hash names: teams.view.1,
  ## teams.view.1u<K> (= teams.view.1 + K), ffa.view.1 or ffa.view.1u<K> (= ffa.view.1 + K);
  ## ValueError for anything else (a retired contract says so).
  let (base, k) = userInputsContract(hash)
  if k > 0: return (base, k)
  (observationContractVersion(hash), 0)

proc requireMode(observationContract: ObservationContractVersion) =
  ## teams.view.1 is the teams game's 16-seat contract, ffa.view.1 FFA-kin's.
  if observationContract == ocTeamsView1:
    if ffa(): raise newException(ValueError, "observation contract teams.view.1 is for the teams game only")
    if Seats != LegacySeats:
      raise newException(ValueError, "observation contract teams.view.1 needs a 16-seat match; this match has " &
        $Seats & " seats")
  elif not ffa():
    raise newException(ValueError, "observation contract ffa.view.1 is for FFA-kin only")

proc requirePairing(observationContract: ObservationContractVersion, contract: ActionContractVersion) =
  ## teams.view.1 goes with its five-head action contract or the aim-offset variant,
  ## ffa.view.1 with its pointer contract.
  if not pairs(observationContract, contract):
    raise newException(ValueError, "observation contract " & observationContractId(observationContract) &
      " cannot be played under action contract " & actionContractId(contract))

proc matchLayout*(): FfaViewLayout =
  ## The ffa.view.1 layout of the match about to be played: its seats and control hearts.
  ffaViewLayout(Seats, controlHeartCount())

proc pointerSetup(seat: NeuralSeat, layout: FfaViewLayout) =
  ## A pointer seat's heads and logits for the match layout.
  seat.layout = layout
  seat.heads = pointerHeads(layout)
  var total = 0
  for h in seat.heads: total += h
  seat.logits = newSeq[float32](total)

proc readManifest(sourcePath: string, actor: Actor): JsonNode =
  let manifestPath = sourcePath & ".neural.json"
  if not fileExists(manifestPath): return nil
  if getFileSize(manifestPath) > 8192: raise newException(ValueError, "oversized neural manifest")
  result = parseJson(readFile(manifestPath))
  if result{"observation_contract"}.getStr != actor.observationContract or
      result{"action_contract"}.getStr != actor.actionContract:
    raise newException(ValueError, "package and actor contract mismatch")

proc budgetCheck(actor: Actor) =
  if actor.operationCount > neuralOperationBudget(Seats):
    let e = newException(NeuralBudgetError, "neural actor exceeds native operation budget")
    e.operations = actor.operationCount
    e.hiddenSize = actor.hiddenSize
    e.model = actor.modelTag
    raise e

proc loadNeuralSeat*(sourcePath: string, slot: int): NeuralSeat =
  ## The seat's neural model beside its policy.bas (`.model.bin`, `.neural.json`); a seat
  ## without one gets an empty neural seat. Contracts are checked first (a retired contract
  ## is refused by name), then the match mode, dimensions and budget.
  result = NeuralSeat(slot: slot, previousTick: -1)
  let modelPath = sourcePath & ".model.bin"
  if not fileExists(modelPath): return
  let data = readActorFile(modelPath)
  let (peekObservation, peekAction) = peekContracts(data)
  let (observationContract, userInputs) = observationFor(peekObservation)
  let contract = actionContractVersion(peekAction)
  requirePairing(observationContract, contract)
  requireMode(observationContract)
  if observationContract == ocFfaView1:
    let layout = matchLayout()
    let heads = pointerHeads(layout)
    var total = 0
    for h in heads: total += h
    let actor = loadActor(data, actorLayout(layout, heads, pointerTargets(layout), userInputs))
    if actor.inputSize != layout.size + userInputs or actor.outputSize != total or actor.headSizes != heads:
      raise newException(ValueError, "neural actor dimensions do not match this match's ffa.view.1 layout (" &
        $layout.seats & " seats, " & $layout.hearts & " control hearts" &
        (if userInputs > 0: ", " & $userInputs & " user inputs" else: "") & ")")
    budgetCheck(actor)
    result.configureSeat(readManifest(sourcePath, actor), userInputs, pointer = true)
    result.pointerSetup(layout)
    result.setConditionals(actor.conditionals)
    result.actor = actor
    result.contract = contract
    result.observationContract = observationContract
    result.observation = newSeq[float32](layout.size + userInputs)
    result.state = newSeq[float32](actor.stateSize)
    return
  let actor = loadActor(data)
  let heads = actionLogitHeads(contract)
  if actor.inputSize != TeamsViewSize + userInputs or actor.outputSize != actionLogitSize(contract) or
      actor.headSizes != heads:
    raise newException(ValueError, "neural actor dimensions do not match Paintbot contract")
  budgetCheck(actor)
  result.configureSeat(readManifest(sourcePath, actor), userInputs, extra = extraHeads(contract),
    target = targetRows(contract))
  result.setConditionals(actor.conditionals)
  result.actor = actor
  result.contract = contract
  result.observationContract = observationContract
  result.observation = newSeq[float32](TeamsViewSize + userInputs)
  result.state = newSeq[float32](actor.stateSize)

proc policyNeuralSeat*(manifestText: string, slot: int, observationHash: string): NeuralSeat =
  ## A training policy-script seat (native pw_set_seat_policy_script): the bundle's
  ## manifest governs the seat exactly as on the host (selection options, user inputs,
  ## action contract), but there is no actor: the trainer feeds each tick's logits.
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
  let contract = actionContractVersion(manifest{"action_contract"}.getStr)
  requirePairing(observationContract, contract)
  requireMode(observationContract)
  let pointer = contract == acFfaView1Pointer
  result.configureSeat(manifest, userInputs, pointer, extra = extraHeads(contract), target = targetRows(contract))
  result.contract = contract
  result.observationContract = observationContract
  if pointer:
    result.pointerSetup(matchLayout())
    result.observation = newSeq[float32](result.layout.size + userInputs)
    result.fedLogits = newSeq[float32](result.logits.len)
    return
  result.observation = newSeq[float32](TeamsViewSize + userInputs)
  result.fedLogits = newSeq[float32](result.logits.len)

proc decoderNeuralSeat*(slot: int, observationHash: string, contract: ActionContractVersion): NeuralSeat =
  ## A training decoder seat (native pw_step's caller heads): no model and no manifest; the
  ## caller's head choices, fed before each decision (fedChoices, choicesFed), are the tick's
  ## selection, and neuralChoice / neuralRow / neuralLayout read them for the seat's decoder
  ## script. ValueError for an observation contract this match cannot play.
  result = NeuralSeat(slot: slot, previousTick: -1, external: true)
  let (observationContract, _) = observationFor(observationHash)
  requireMode(observationContract)
  requirePairing(observationContract, contract)
  let pointer = observationContract == ocFfaView1
  result.configureSeat(nil, 0, pointer, extra = extraHeads(contract), target = targetRows(contract))
  result.contract = contract
  result.observationContract = observationContract
  if pointer: result.pointerSetup(matchLayout())

proc beginTick*(seat: NeuralSeat, view: SeatView, matchSeed: int32) =
  ## The seat's tick starts on `view` (the pre-step world's): the recurrent state resets at
  ## initial use, match reset, death and respawn; the tick's phase starts over.
  let alive = view.selfHp > 0
  let tick = view.worldTick
  if not alive or not seat.previouslyAlive or tick <= seat.previousTick:
    for i in 0..<seat.state.len: seat.state[i] = 0
  if seat.userInputs.len > 0:
    # User inputs persist across ticks and deaths; a new match starts from init. The
    # tick's observation reads what the previous tick's script left.
    if seat.previousTick < 0 or tick <= seat.previousTick: seat.userInputs = seat.userInputInit
    seat.userInputView = seat.userInputs
  seat.previouslyAlive = alive
  seat.rowsReady = false
  seat.previousTick = tick
  seat.view = view
  seat.viewReady = true
  if seat.matchSeed != matchSeed and seat.sampleSeeded:
    # Another match on the same seat object: its streams start over from the new seed.
    seat.sampleSeeded = false
  seat.matchSeed = matchSeed
  seat.observed = false
  seat.inferred = false
  seat.nativeWork = 0
  seat.observationFresh = false
  if seat.maskSet: seat.masks = default(HeadMasks)
  seat.maskSet = false
  seat.temperatureSet = default(array[ActionSizes.len, bool])
  seat.offsetTemperatureSet = default(array[ExtraHeadsMax, bool])
  seat.sampled = false
  if seat.choicesFed:
    seat.selected = seat.fedChoices
    seat.choices = seat.fedChoices
    seat.offsetSelected = seat.fedOffsetChoices
    seat.offsetChoices = seat.fedOffsetChoices
    seat.appliedMasks = default(HeadMasks)
    seat.appliedTemperatures = default(array[ActionSizes.len, int32])
    seat.sampled = true

proc seedStream(seat: NeuralSeat) =
  ## One stream per seat per match, from the match seed: its position depends only on the
  ## decisions taken, and it survives death and respawn.
  if not seat.sampleSeeded:
    seat.sampleRng = seat.streamStart
    seat.sampleSeeded = true

proc headSize(seat: NeuralSeat, head: int): int =
  ## The size of action head `head` for this seat (a seat without a model: ActionSizes').
  if seat.heads.len > 0: seat.heads[head] else: ActionSizes[head]

proc rowsFor(seat: NeuralSeat): FfaViewRows =
  ## The tick's ffa.view.1 row -> entity map (once per tick: the observation and neuralRow
  ## read the same view).
  if not seat.rowsReady:
    seat.rows = ffaViewRows(seat.view)
    seat.rowsReady = true
  seat.rows

proc require(seat: NeuralSeat, condition: bool, message: string) =
  if seat.actor.isNil and not seat.external: raise newException(BasicError, "no neural model in policy package")
  if not condition: raise newException(BasicError, message)

proc ensureObservation(seat: NeuralSeat) =
  ## Encode this tick's observation into the seat's buffer (once per tick; the view is the
  ## unchanged pre-action tick's, so every encode of a tick is the same bytes).
  if seat.observationFresh: return
  assert seat.viewReady, "neural observation before the seat's first tick"
  if seat.observationContract == ocFfaView1:
    if ffaViewLayout(seat.view) != seat.layout:
      raise newException(ValueError, "the match's ffa.view.1 layout differs from the one the seat was loaded for")
    encodeObservation(seat.view, ocFfaView1, seat.observation, seat.userInputView, rows = seat.rowsFor())
  else:
    encodeObservation(seat.view, ocTeamsView1, seat.observation, seat.userInputView)
  seat.observationFresh = true

proc selectConditionals(seat: NeuralSeat, actions: var array[ActionSizes.len, int32],
    temperatures: openArray[float32], masks: HeadMasks, masked: bool) =
  ## The model's COND_HEAD layers, in order, after the tick's selection (neural_contract.reselectHead):
  ## each re-selects its head from logits + the column of its condition head's choice, under the
  ## head's mask (`masked`) and temperature; an all-zero column changes nothing and takes no draw.
  ## Nothing runs without COND_HEAD layers.
  for c in seat.conditionals:
    let t = temperatures[c.head]
    if t > 0: seat.seedStream()
    var offset = 0
    for h in 0..<c.head: offset += seat.heads[h]
    let size = seat.heads[c.head]
    let offsets = c.conditionalOffsets(actions[c.whenHead].int, seat.heads)
    var zero = true
    for x in offsets:
      if x != 0'f32: zero = false
    # An all-zero column leaves the head's distribution as it was selected: the selection
    # stands and no draw is taken (so a COND_HEAD twin of a joint_sampling bundle draws the
    # same stream as it).
    if zero: continue
    actions[c.head] =
      if masked: reselectHead(seat.logits, offset, size, offsets, masks[c.head].toOpenArray(0, size-1), t,
                              seat.sampleRng)
      else: reselectHead(seat.logits, offset, size, offsets, default(array[0, bool]), t, seat.sampleRng)
    if t > 0: inc seat.conditionalDraws

proc pointerSample(seat: NeuralSeat) =
  ## Selection under action contract ffa.view.1 pointer: per head argmax (first maximum), or with
  ## decoder.sampling / neuralTemperature a categorical draw from softmax(logits / T) on the
  ## seat's stream (pointerSelect). No masks (neuralMask is refused for pointer seats).
  var temperatures = newSeq[float32](ActionSizes.len)
  for head in 0..<ActionSizes.len:
    temperatures[head] =
      if seat.temperatureSet[head]: seat.temperatures[head]
      elif seat.sampling.enabled and seat.sampling.heads[head]: seat.sampling.temperature
      else: 0'f32
    seat.appliedTemperatures[head] =
      if temperatures[head] > 0: int32(round(float64(temperatures[head]) * 1000)) else: 0'i32
  var anyDraw = false
  for t in temperatures:
    if t > 0: anyDraw = true
  if anyDraw: seat.seedStream()
  var draws = 0
  let picked = pointerSelect(seat.logits, seat.heads, temperatures, seat.sampleRng, draws)
  if draws > 0: inc seat.sampleDraws
  for head in 0..<ActionSizes.len: seat.selected[head] = picked[head]
  seat.selectConditionals(seat.selected, temperatures, default(HeadMasks), masked = false)
  seat.appliedMasks = default(HeadMasks)
  seat.choices = seat.selected
  seat.sampled = true

proc selectOffsets(seat: NeuralSeat) =
  ## The extra heads after the five main heads (aim offsets 5 and 6; under movement-offset
  ## also 7 and 8): argmax (first maximum) or, with a temperature (neuralTemperature(h / -1),
  ## else decoder.sampling), one draw each from the seat's stream (pointerSelect's rule), in
  ## head order. With two extra heads this is exactly the aim-offset selection.
  let n = seat.extraHeads
  var temperatures = newSeq[float32](n)
  var sizes = newSeq[int](n)
  var anyDraw = false
  for e in 0..<n:
    sizes[e] = seat.heads[ActionSizes.len + e]
    temperatures[e] =
      if seat.offsetTemperatureSet[e]: seat.offsetTemperatures[e]
      elif seat.sampling.enabled and seat.sampling.offsetHeads[e]: seat.sampling.temperature
      else: 0'f32
    seat.appliedOffsetTemperatures[e] =
      if temperatures[e] > 0: int32(round(float64(temperatures[e]) * 1000)) else: 0'i32
    if temperatures[e] > 0: anyDraw = true
  if seat.targetRows:
    # Contract 15: each offset head draws from the chosen identity's row; with keep or a compass aim there is no
    # target, so no draw and the centre bin (its applied temperature reads 0).
    # Contract 16 (raw): its rows are 63 bins, and its heads 7 .. 9 (walk direction, walk distance, look direction)
    # follow as plain heads from their own logits after the rows (LogitSize + 2 * TargetRows * 63 ..).
    let a = seat.selected[1]
    let j = a - 1
    let nOff = min(n, AimOffsetHeads)
    let rb = sizes[0]                 # bins per identity row: 23 (15) or 63 (16)
    var rowsLen = nOff*rb
    for e in nOff..<n: rowsLen += sizes[e]
    var rows = newSeq[float32](rowsLen)
    if j in 0'i32..<TargetRows.int32:
      for e in 0..<nOff:
        let base = LogitSize + e*TargetRows*rb + j.int*rb
        for b in 0..<rb: rows[e*rb+b] = seat.logits[base+b]
    else:
      for e in 0..<nOff:
        temperatures[e] = 0'f32
        seat.appliedOffsetTemperatures[e] = 0'i32
        rows[e*rb + rb div 2] = 1'f32   # argmax = the centre bin
      anyDraw = false
      for e in nOff..<n:
        if temperatures[e] > 0: anyDraw = true
    var at = nOff*rb
    var src = LogitSize + nOff*TargetRows*rb
    for e in nOff..<n:
      for b in 0..<sizes[e]: rows[at+b] = seat.logits[src+b]
      at += sizes[e]
      src += sizes[e]
    if anyDraw: seat.seedStream()
    var draws = 0
    let picked = pointerSelect(rows, sizes, temperatures, seat.sampleRng, draws)
    for e in 0..<n:
      seat.offsetSelected[e] = picked[e]
      seat.offsetChoices[e] = picked[e]
    return
  if anyDraw: seat.seedStream()
  var draws = 0
  let picked = pointerSelect(seat.logits.toOpenArray(LogitSize, seat.logits.len-1), sizes,
    temperatures, seat.sampleRng, draws)
  for e in 0..<n:
    seat.offsetSelected[e] = picked[e]
    seat.offsetChoices[e] = picked[e]

proc samplePhase(seat: NeuralSeat) =
  ## Selection: forbid / BASIC masks, argmax or sampling / BASIC temperatures, joint sampling
  ## and COND_HEAD. Leaves the heads in seat.choices.
  if seat.pointer:
    seat.pointerSample()
    return
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
    seat.seedStream()
    var draws = 0
    actions = sampleHeads(seat.logits.toOpenArray(0, LogitSize-1), temperatures, masks, seat.sampleRng, draws)
    if draws > 0: inc seat.sampleDraws
    if seat.joint.enabled and jointSelect(seat.logits, seat.joint, masks[seat.joint.head],
        temperatures[seat.joint.head], seat.sampleRng, actions):
      inc seat.jointDraws
    if seat.conditionals.len > 0: seat.selectConditionals(actions, temperatures, masks, masked = true)
    seat.appliedMasks = masks
  else:
    if seat.sampling.enabled: seat.seedStream()
    actions = if seat.sampling.enabled: sampleActions(seat.logits.toOpenArray(0, LogitSize-1), seat.sampling, seat.sampleRng, seat.forbidden)
              else: argmaxActions(seat.logits.toOpenArray(0, LogitSize-1), seat.forbidden)
    if seat.sampling.enabled: inc seat.sampleDraws
    if seat.joint.enabled:
      let jointTemperature = if seat.sampling.enabled and seat.sampling.heads[seat.joint.head]:
                               seat.sampling.temperature else: 0'f32
      if jointTemperature > 0: seat.seedStream()
      let held = if seat.joint.head == 0 and seat.forbidAny:
                   jointSelect(seat.logits, seat.joint, seat.forbidden, jointTemperature, seat.sampleRng, actions)
                 else:
                   jointSelect(seat.logits, seat.joint, default(array[0, bool]), jointTemperature, seat.sampleRng, actions)
      if held: inc seat.jointDraws
    if seat.conditionals.len > 0:
      var temperatures: HeadTemperatures
      var masks: HeadMasks
      masks[0] = seat.forbidden
      for head in 0..<ActionSizes.len:
        if seat.sampling.enabled and seat.sampling.heads[head]: temperatures[head] = seat.sampling.temperature
      seat.selectConditionals(actions, temperatures, masks, masked = true)
    seat.appliedMasks = default(HeadMasks)
    seat.appliedMasks[0] = seat.forbidden
    for head in 0..<ActionSizes.len:
      seat.appliedTemperatures[head] =
        if seat.sampling.enabled and seat.sampling.heads[head]: int32(round(float64(seat.sampling.temperature) * 1000))
        else: 0'i32
  if seat.forbidAny and seat.forbidden[argmaxActions(seat.logits.toOpenArray(0, LogitSize-1))[0]]: inc seat.forbidHits
  seat.selected = actions
  seat.choices = actions
  if seat.offsetHeads: seat.selectOffsets()
  seat.sampled = true

proc neuralLayoutWords(seat: NeuralSeat): array[16, int32] =
  ## pw_observation_layout's 16 words for the seat's observation.
  let width = seat.observation.len.int32
  result[0] = width
  result[12] = Seats.int32
  if seat.observationContract != ocFfaView1:
    result[1] = width
    result[11] = -1
    if seat.viewReady: result[13] = seat.view.heartCount
    return
  let l = seat.layout
  result[1] = FfaHeaderSize
  result[2] = l.cogOffset.int32; result[3] = l.cogRows.int32; result[4] = FfaCogWidth
  result[5] = l.heartOffset.int32; result[6] = l.heartRows.int32; result[7] = FfaHeartWidth
  result[8] = l.greatOffset.int32; result[9] = l.greatRows.int32; result[10] = FfaGreatWidth
  result[11] = FfaValidColumn
  result[13] = l.hearts.int32

proc addNeuralFunctions*(h: var Host, seat: NeuralSeat) =
  ## The neural builtins. Each returns a number (a handle, an observation value, a logit, a
  ## head choice, a layout word or a row's entity); none acts: the seat's policy.bas turns the
  ## numbers into BASIC verbs.
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
      for i in 0..<seat.logits.len: seat.logits[i] = seat.fedLogits[i]
    else:
      try:
        seat.actor.infer(seat.observation, seat.state, seat.logits)
      except ValueError as e:
        raise newException(BasicError, "neural inference failed: " & e.msg)
      seat.nativeWork = seat.actor.operationCount
    seat.inferred = true
    1, 16)
  # User inputs (BASIC -> net).
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
  discard h.addFunction("neuralLogit", 1, proc(a: openArray[int32]): int32 =
    seat.require(seat.inferred, "neuralLogit requires run_neural_net first")
    seat.require(a[0] >= 0 and a[0] < seat.logits.len.int32, "neuralLogit index out of range")
    int32(clamp(round(float64(seat.logits[a[0]]) * 1000), float64(int32.low), float64(int32.high))), 4)
  # The head-level phase. Masks and temperatures apply to this tick's selection.
  proc maskFrom(head, first, bits: int32): int32 =
    seat.require(not seat.sampled, "neuralMask must come before the tick's selection")
    seat.require(not seat.pointer, "neuralMask is not available under action contract ffa.view.1 pointer")
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
    seat.require(a[0] in -1'i32..<seat.heads.len.int32, "neuralTemperature head out of range")
    seat.require(a[1] == 0 or a[1] in MinBasicTemperatureMilli..MaxBasicTemperatureMilli,
      "neuralTemperature must be 0 (argmax) or within 1 .. 100000 milli")
    let t = float32(float64(a[1]) / 1000.0)
    for head in 0..<ActionSizes.len:
      if a[0] == -1 or a[0] == head.int32:
        seat.temperatures[head] = t
        seat.temperatureSet[head] = true
    if seat.offsetHeads:
      for e in 0..<seat.extraHeads:
        if a[0] == -1 or a[0] == int32(ActionSizes.len + e):
          seat.offsetTemperatures[e] = t
          seat.offsetTemperatureSet[e] = true
    1, 4)
  discard h.addFunction("neuralSample", 0, proc(a: openArray[int32]): int32 =
    seat.require(seat.inferred and not seat.sampled, "neuralSample requires fresh logits; once per tick")
    try: seat.samplePhase()
    except ValueError as e: raise newException(BasicError, "neural selection failed: " & e.msg)
    1, 48)
  discard h.addFunction("neuralChoice", 1, proc(a: openArray[int32]): int32 =
    seat.require(seat.sampled, "neuralChoice requires neuralSample first")
    seat.require(a[0] in 0'i32..<seat.heads.len.int32, "neuralChoice head out of range")
    if a[0] >= ActionSizes.len: seat.offsetChoices[a[0] - ActionSizes.len] else: seat.choices[a[0]], 4)
  discard h.addFunction("neuralSetChoice", 2, proc(a: openArray[int32]): int32 =
    # Records the choice the script acted on (pw_seat_policy_choices reports it).
    seat.require(seat.sampled, "neuralSetChoice requires neuralSample first")
    seat.require(a[0] in 0'i32..<seat.heads.len.int32, "neuralSetChoice head out of range")
    seat.require(a[1] >= 0 and a[1] < seat.headSize(a[0].int).int32, "neuralSetChoice choice out of range")
    if a[0] >= ActionSizes.len: seat.offsetChoices[a[0] - ActionSizes.len] = a[1]
    else: seat.choices[a[0]] = a[1]
    1, 4)
  # The observation and action layout (pw_observation_layout's 16 words, then the head
  # sizes at 16 .. 24, 0 for a head the seat's action contract lacks): neuralLayout(i).
  # ffa.view.1 seats only for the section words; any seat for its width and head sizes.
  discard h.addFunction("neuralLayout", 1, proc(a: openArray[int32]): int32 =
    seat.require(a[0] in 0'i32..int32(16 + ActionSizes.len + ExtraHeadsMax - 1), "neuralLayout index out of range")
    let i = a[0].int
    if i >= 16:
      let head = i-16
      return (if seat.heads.len == 0: (if head < ActionSizes.len: ActionSizes[head].int32 else: 0'i32)
              elif head < seat.heads.len: seat.heads[head].int32 else: 0'i32)
    let words = neuralLayoutWords(seat)
    words[i], 4)
  # The tick's row -> entity map (ffa.view.1): neuralRow(section, k) is the identity of cog
  # row k (section 0; nearAgentId(k) after nearAgents(20000); -1 past the agents the seat
  # sees), the control heart index (1) or the great heart index (2) of row k.
  discard h.addFunction("neuralRow", 2, proc(a: openArray[int32]): int32 =
    seat.require(seat.observationContract == ocFfaView1, "neuralRow needs observation contract ffa.view.1")
    seat.require(a[0] in 0'i32..2'i32, "neuralRow section out of range")
    let rows = seat.rowsFor()
    let k = a[1].int
    case a[0]
    of 0:
      seat.require(k in 0..<seat.layout.cogRows, "neuralRow row out of range")
      (if k < rows.agents.len: rows.agents[k].identity else: -1'i32)
    of 1:
      seat.require(k in 0..<rows.hearts.len, "neuralRow row out of range")
      rows.hearts[k].int32
    else:
      seat.require(k in 0..<FfaGreatRows, "neuralRow row out of range")
      rows.greats[k].int32, 8)
