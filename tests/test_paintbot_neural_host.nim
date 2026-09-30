import std/[unittest, os, strutils]
import polyworld/cli
import ../examples/paintbot/[bots, sim, neural_contract, neural_host, contract_hash]

proc u32(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)
proc zeroModel(actionContract = ActionContractTeamsView1Hash,
    observationContract = ObservationContractTeamsView1Hash, inputs = TeamsViewSize): string =
  const h = 64
  let n = inputs*h + 3*h*h + LogitSize*h
  result = "PWNET001"
  for x in [1,inputs,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
  result.add observationContract
  result.add actionContract
  for x in ActionSizes: result.u32(x.uint32)
  result.add repeat('\0', n*4)

# A full policy: select the heads (neuralSample), then the reference BASIC decode of them.
const NeuralSource = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
neuralSample()
""" & staticRead("../examples/paintbot/players/neural_decode.bas")
proc writePackage(path, source: string, model: bool, actionContract, manifest, observationContract: string,
    inputs: int) =
  writeFile(path, source)
  if model: writeFile(path & ".model.bin", zeroModel(actionContract, observationContract, inputs))
  if manifest.len > 0: writeFile(path & ".neural.json", manifest)
proc removePackage(path: string) =
  for suffix in ["", ".model.bin", ".neural.json"]:
    if fileExists(path & suffix): removeFile(path & suffix)
proc fixture(source: string, model = true, actionContract = ActionContractTeamsView1Hash,
    manifest = "", observationContract = ObservationContractTeamsView1Hash,
    inputs = TeamsViewSize): seq[Bot] =
  let path = getTempDir()/"paintbot-neural-host-test.bas"
  writePackage(path, source, model, actionContract, manifest, observationContract, inputs)
  defer: removePackage(path)
  loadBots(@[BotGroup(path:path,count:Seats)])
proc loadError(manifest = "", actionContract = ActionContractTeamsView1Hash,
    observationContract = ObservationContractTeamsView1Hash, inputs = TeamsViewSize): string =
  ## The ValueError message loading the package into seat 0 raises ("" when it loads).
  let path = getTempDir()/"paintbot-neural-host-test-error.bas"
  writePackage(path, NeuralSource, true, actionContract, manifest, observationContract, inputs)
  defer: removePackage(path)
  try:
    discard loadNeuralSeat(path, 0)
    ""
  except ValueError as e: e.msg
proc manifestJson(schema: string, actionContract: string, decoder = "",
    observationContract = ObservationContractTeamsView1Hash): string =
  ## A staged manifest as neural_package.py writes it; `decoder` is the raw JSON value.
  result = "{\"schema\": \"" & schema & "\", \"observation_contract\": \"" & observationContract &
    "\", \"action_contract\": \"" & actionContract & "\", \"sha256\": {}"
  if decoder.len > 0: result.add ", \"decoder\": " & decoder
  result.add "}"
proc mixedFixture(): seq[Bot] =
  ## Slot 0 runs the neural package; every other seat is plain BASIC.
  let neuralPath = getTempDir()/"paintbot-neural-host-test-neural.bas"
  let plainPath = getTempDir()/"paintbot-neural-host-test-plain.bas"
  writeFile(neuralPath, NeuralSource)
  writeFile(neuralPath & ".model.bin", zeroModel())
  writeFile(plainPath, "walkTo(selfX,selfY)\n")
  defer:
    removeFile(neuralPath)
    removeFile(neuralPath & ".model.bin")
    removeFile(plainPath)
  loadBots(@[BotGroup(path:neuralPath,count:1), BotGroup(path:plainPath,count:Seats-1)])

suite "native BASIC neural host":
  test "seat buffers are independent and recurrence resets on death and match reset":
    let players = fixture(NeuralSource)
    var w = newWorld(2026)
    discard players.decide(w)
    check not players[0].failed
    check players[0].neural.nativeWork > 0
    check peakNativeWork[0] == players[0].neural.nativeWork
    check players[0].neural.state[0] == 0.25'f32
    players[0].neural.state[0] = 42
    check players[1].neural.state[0] == 0.25'f32
    w.tick = 1
    w.cogs[0].hp = 0
    discard players.decide(w)
    check players[0].neural.state[0] == 0
    w.tick = 2
    w.cogs[0].hp = 3
    discard players.decide(w)
    check players[0].neural.state[0] == 0.25'f32
    players[0].neural.state[0] = 42
    w.tick = 0
    discard players.decide(w)
    check players[0].neural.state[0] == 0.25'f32

  test "repeated inference fails seat and discards commands":
    let players = fixture(NeuralSource & "run_neural_net(1,2,3,4)\n")
    let commands = players.decide(newWorld(2026))
    check players[0].failed
    check not commands[0].walk and not commands[0].shoot

  test "wrong typed handles fail explicitly":
    let players = fixture("paintbot_observe(neuralState())\n")
    discard players.decide(newWorld(2026))
    check players[0].failed

  test "plain BASIC remains supported and missing model fails explicitly":
    let plain = fixture("walkTo(selfX,selfY)\n",false)
    discard plain.decide(newWorld(2026))
    check not plain[0].failed
    let missing = fixture(NeuralSource,false)
    discard missing.decide(newWorld(2026))
    check missing[0].failed

  test "seat telemetry line names peak operations, budget, width and ticks":
    check neuralTelemetry(238080, 128, 1200) ==
      "neural: peak_ops=238080 budget=4000000 model=w128 ticks=1200"

  test "seat telemetry is logged for neural seats and not for plain seats":
    let players = mixedFixture()
    var w = newWorld(2026)
    discard players.decide(w)
    w.tick = 1
    discard players.decide(w)
    check not players[0].failed and not players[1].failed
    let expected = int64(2*(TeamsViewSize*64 + 3*64*64 + LogitSize*64) + 32*64)
    check players[0].neural.nativeWork == expected
    var lines: seq[(int, string)]
    players.logNeuralTelemetry(2, proc(slot: int, text: string) = lines.add((slot, text)))
    check lines.len == 1
    check lines[0][0] == 0
    check lines[0][1] == "neural: peak_ops=" & $expected & " budget=4000000 model=w64 ticks=2\n"
    # A plain seat logs nothing, and the world is untouched by telemetry.
    let before = w.stateHash()
    players.logNeuralTelemetry(2, proc(slot: int, text: string) = discard)
    check w.stateHash() == before

  test "the bundle's action contract hash names teams.view.1's heads; retired, unpaired and unknown hashes are rejected":
    let teams = fixture(NeuralSource)
    check teams[0].neural.contract == acTeamsView1
    check teams[0].neural.heads == @ActionSizes
    var w = newWorld(2026)
    discard teams.decide(w)
    check not teams[0].failed
    for id in RetiredActionContractIds:
      checkpoint id
      check (loadError(actionContract = sha256Hex(id))) ==
        "neural action contract was retired for BASIC parity (docs/neural/seat-view.md); retrain on teams.view.1 or ffa.view.1"
      check fixture(NeuralSource, true, sha256Hex(id))[0].failed
    # ffa.view.1's pointer heads cannot be played on a teams.view.1 observation.
    let unpaired = loadError(actionContract = ActionContractFfaView1PointerHash)
    check "observation contract paintbot-pw.teams.view.1" in unpaired and "paintbot-pw.ffa.view.1.action.pointer" in unpaired
    check loadError(actionContract = "0" & ActionContractTeamsView1Hash[1..^1]) == "unknown neural action contract"
    let unknown = fixture(NeuralSource, true, "0" & ActionContractTeamsView1Hash[1..^1])
    discard unknown.decide(w)
    check unknown[0].failed

  test "the bundle's observation contract hash selects the encoder and its width; unknown hashes are rejected":
    let teams = fixture(NeuralSource)
    check teams[0].neural.observationContract == ocTeamsView1
    check teams[0].neural.observation.len == TeamsViewSize
    var w = newWorld(2026)
    w.cogs[0].pos = w.controlHearts[8].pos # in the river: the wet and height columns are not all zero
    discard teams.decide(w)
    check not teams[0].failed
    var expected: array[TeamsViewSize, float32]
    beginViews(w)
    encodeObservation(seatView(0), ocTeamsView1, expected)
    check teams[0].neural.observation == @expected
    check teams[0].neural.observation[13] == 1   # self wet
    check teams[0].neural.nativeWork == int64(2*(TeamsViewSize*64 + 3*64*64 + LogitSize*64) + 32*64)
    # A schema-2 manifest binding both hashes.
    let both = fixture(NeuralSource, true, ActionContractTeamsView1Hash,
      manifestJson("paintbot-neural-basic/2", ActionContractTeamsView1Hash))
    discard both.decide(w)
    check not both[0].failed
    check both[0].neural.observationContract == ocTeamsView1 and both[0].neural.contract == acTeamsView1
    # A manifest naming another contract than the actor's cannot carry it.
    check loadError(manifestJson("paintbot-neural-basic/2", ActionContractTeamsView1Hash,
      observationContract = ObservationContractFfaView1Hash)) == "package and actor contract mismatch"
    check loadError(manifestJson("paintbot-neural-basic/2", ActionContractFfaView1PointerHash)) ==
      "package and actor contract mismatch"
    # Width must match the named contract, both ways; ffa.view.1 is FFA-kin's; an unknown hash fails the seat.
    for inputs in [TeamsViewSize - 1, TeamsViewSize + 1]:
      check loadError(inputs = inputs) == "neural actor dimensions do not match Paintbot contract"
    check loadError(actionContract = ActionContractFfaView1PointerHash,
      observationContract = ObservationContractFfaView1Hash) == "observation contract ffa.view.1 is for FFA-kin only"
    check loadError(observationContract = "0" & ObservationContractTeamsView1Hash[1..^1]) ==
      "unknown neural observation contract"
    for (hash, inputs) in [(ObservationContractTeamsView1Hash, TeamsViewSize + 1),
        ("0" & ObservationContractTeamsView1Hash[1..^1], TeamsViewSize)]:
      let bad = fixture(NeuralSource, true, ActionContractTeamsView1Hash, "", hash, inputs)
      discard bad.decide(w)
      check bad[0].failed

  test "a retired observation contract is refused at load, by name":
    const Retired = "neural observation contract was retired for BASIC parity (docs/neural/seat-view.md); " &
      "retrain on teams.view.1 or ffa.view.1"
    var ids = @RetiredObservationContractIds
    for k in [1, 32, 128]:
      ids.add "paintbot-pw.rules39.obs.v2u" & $k
      ids.add "paintbot-pw.rules43.obs.v3u" & $k
    for id in ids:
      checkpoint id
      let hash = sha256Hex(id)
      check retiredContract(hash)
      # Refused whatever the actor's width or action contract, before its dimensions are read.
      check loadError(observationContract = hash) == Retired
      check loadError(observationContract = hash, inputs = 448) == Retired
      check loadError(observationContract = hash, actionContract = sha256Hex(RetiredActionContractIds[1])) == Retired
      check fixture(NeuralSource, true, ActionContractTeamsView1Hash, "", hash)[0].failed
      # The training policy seat refuses the same hash.
      try:
        discard policyNeuralSeat(manifestJson("paintbot-neural-basic/2", ActionContractTeamsView1Hash,
          observationContract = hash), 0, hash)
        check false
      except ValueError as e:
        check e.msg == Retired
    for current in [ObservationContractTeamsView1Hash, ObservationContractFfaView1Hash, userInputsContractHash(32),
        ActionContractTeamsView1Hash, ActionContractFfaView1PointerHash]:
      check not retiredContract(current)

  test "retired decoder options are rejected with the retired-for-BASIC-parity message":
    const Schema1 = "paintbot-neural-basic/1"
    const Schema2 = "paintbot-neural-basic/2"
    const Keys = ["fire_hold_teammates", "strafe_legs", "aim_snap", "steady_shot", "aim_retarget", "shot_gate",
      "spray_aim", "spray_gate"]
    check @RetiredDecoderOptions == @Keys
    for key in Keys:
      let message = "decoder." & key & " was retired for BASIC parity (docs/neural/seat-view.md); write the rule in policy.bas"
      for value in ["{}", "true", "false", "{\"radius\": 150}"]:
        for decoder in ["{\"" & key & "\": " & value & "}",
                        "{\"sampling\": {\"mode\": \"categorical\"}, \"" & key & "\": " & value & "}",
                        "{\"" & key & "\": " & value & ", \"forbid_objectives\": [9, 10]}"]:
          checkpoint decoder
          check loadError(manifestJson(Schema2, ActionContractTeamsView1Hash, decoder)) == message
          check fixture(NeuralSource, true, ActionContractTeamsView1Hash,
            manifestJson(Schema2, ActionContractTeamsView1Hash, decoder))[0].failed
          # The training policy seat refuses it the same way.
          try:
            discard policyNeuralSeat(manifestJson(Schema2, ActionContractTeamsView1Hash, decoder), 0,
              ObservationContractTeamsView1Hash)
            check false
          except ValueError as e:
            check e.msg == message
    # Other decoder errors keep their own messages.
    check loadError(manifestJson(Schema2, ActionContractTeamsView1Hash, "{\"other\": 1}")) == "unknown decoder option: other"
    check loadError(manifestJson(Schema2, ActionContractTeamsView1Hash, "[true]")) == "decoder options must be an object"
    check loadError(manifestJson(Schema1, ActionContractTeamsView1Hash, "{\"strafe_legs\": {}}")) ==
      "decoder options need package schema 2"
    # Schema 1 and schema 2 without decoder options: the plain log line.
    for schema in [Schema1, Schema2]:
      let plain = fixture(NeuralSource, true, ActionContractTeamsView1Hash, manifestJson(schema, ActionContractTeamsView1Hash))
      check not plain[0].failed
      check plain[0].neural.telemetry(10, 3) == "neural: peak_ops=10 budget=4000000 model=w64 ticks=3"

  test "the sampling decoder option is read from a schema-2 manifest, seeds per seat and replays exactly":
    const Schema1 = "paintbot-neural-basic/1"
    const Schema2 = "paintbot-neural-basic/2"
    let sampled = fixture(NeuralSource, true, ActionContractTeamsView1Hash,
      manifestJson(Schema2, ActionContractTeamsView1Hash, "{\"sampling\": {\"mode\": \"categorical\"}}"))
    check not sampled[0].failed
    check sampled[0].neural.sampling.enabled
    check sampled[0].neural.sampling.temperature == 1'f32
    check sampled[0].neural.sampling.heads == [true, true, true, true, true]
    check sampled[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 sampling=categorical t=1.000 heads=01234 seed=0x0000000000000000 draws=0"
    var w = newWorld(2026)
    discard sampled.decide(w)
    check not sampled[0].failed
    check sampled[0].neural.sampleDraws == 1
    check sampled[0].neural.telemetry(10, 1) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=1 sampling=categorical t=1.000 heads=01234 seed=0x" &
      toHex(samplingSeed(2026, 0), 16).toLowerAscii & " draws=1"
    # Temperature and a head subset.
    let partial = fixture(NeuralSource, true, ActionContractTeamsView1Hash,
      manifestJson(Schema2, ActionContractTeamsView1Hash, "{\"sampling\": {\"mode\": \"categorical\", \"temperature\": 0.5, \"heads\": [2, 0]}}"))
    check not partial[0].failed
    check partial[0].neural.sampling.temperature == 0.5'f32
    check partial[0].neural.sampling.heads == [true, false, true, false, false]
    check partial[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 sampling=categorical t=0.500 heads=02 seed=0x0000000000000000 draws=0"
    # Replay determinism: the same match seed twice gives the same world hash every tick
    # with every seat sampling (the zero model's logits are all equal, so every draw is a
    # uniform choice); the argmax bundle on the same seed diverges from it.
    proc play(manifest: string, seed: int32, ticks: int): seq[uint32] =
      let players = fixture(NeuralSource, true, ActionContractTeamsView1Hash, manifest)
      var world = newWorld(seed)
      for tick in 0..<ticks:
        let commands = players.decide(world)
        for slot in 0..<Seats: check not players[slot].failed
        world.step(commands)
        result.add world.stateHash()
    let sampling = manifestJson(Schema2, ActionContractTeamsView1Hash, "{\"sampling\": {\"mode\": \"categorical\"}}")
    let once = play(sampling, 2026, 120)
    check once == play(sampling, 2026, 120)
    check once != play(manifestJson(Schema2, ActionContractTeamsView1Hash), 2026, 120)
    check once != play(sampling, 2027, 120)
    # Schema 1 and schema 2 without the field: unchanged behaviour and log line.
    for schema in [Schema1, Schema2]:
      let plain = fixture(NeuralSource, true, ActionContractTeamsView1Hash, manifestJson(schema, ActionContractTeamsView1Hash))
      check not plain[0].failed
      check not plain[0].neural.sampling.enabled
      check plain[0].neural.telemetry(10, 3) == "neural: peak_ops=10 budget=4000000 model=w64 ticks=3"
    # Rejected: under schema 1; no mode; another mode; bad temperatures; bad heads; unknown field; not an object.
    for (schema, decoder) in [(Schema1, "{\"sampling\": {\"mode\": \"categorical\"}}"),
                              (Schema2, "{\"sampling\": {}}"),
                              (Schema2, "{\"sampling\": {\"mode\": \"argmax\"}}"),
                              (Schema2, "{\"sampling\": {\"mode\": \"categorical\", \"temperature\": 0}}"),
                              (Schema2, "{\"sampling\": {\"mode\": \"categorical\", \"temperature\": 11}}"),
                              (Schema2, "{\"sampling\": {\"mode\": \"categorical\", \"temperature\": \"1\"}}"),
                              (Schema2, "{\"sampling\": {\"mode\": \"categorical\", \"heads\": []}}"),
                              (Schema2, "{\"sampling\": {\"mode\": \"categorical\", \"heads\": [5]}}"),
                              (Schema2, "{\"sampling\": {\"mode\": \"categorical\", \"heads\": [1, 1]}}"),
                              (Schema2, "{\"sampling\": {\"mode\": \"categorical\", \"heads\": \"all\"}}"),
                              (Schema2, "{\"sampling\": {\"mode\": \"categorical\", \"seed\": 1}}"),
                              (Schema2, "{\"sampling\": true}")]:
      let bad = fixture(NeuralSource, true, ActionContractTeamsView1Hash, manifestJson(schema, ActionContractTeamsView1Hash, decoder))
      checkpoint schema & " " & decoder
      check bad[0].failed
  test "the forbid decoder option is read from a schema-2 manifest, logged, and replays exactly":
    const Schema1 = "paintbot-neural-basic/1"
    const Schema2 = "paintbot-neural-basic/2"
    let both = fixture(NeuralSource, true, ActionContractTeamsView1Hash,
      manifestJson(Schema2, ActionContractTeamsView1Hash, "{\"forbid_objectives\": [9, 10]}"))
    check not both[0].failed
    check both[0].neural.forbidAny and both[0].neural.forbidden[9] and both[0].neural.forbidden[10]
    check not both[0].neural.forbidden[0]
    check both[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 forbid_objectives=9,10 forbid_hits=0"
    let sampled = fixture(NeuralSource, true, ActionContractTeamsView1Hash,
      manifestJson(Schema2, ActionContractTeamsView1Hash, "{\"sampling\": {\"mode\": \"categorical\"}, \"forbid_objectives\": [3]}"))
    check not sampled[0].failed and sampled[0].neural.forbidAny
    check sampled[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 sampling=categorical t=1.000 heads=01234 " &
      "seed=0x0000000000000000 draws=0 forbid_objectives=3 forbid_hits=0"
    # The zero model's logits are all equal, so argmax takes index 0 (stay): the reference
    # decode walks to the seat's own position. Forbidding 0 selects movement 1 (control heart
    # 0) instead, which the decode walks to, and counts the decision.
    let keep = fixture(NeuralSource, true, ActionContractTeamsView1Hash, manifestJson(Schema2, ActionContractTeamsView1Hash))
    let moved = fixture(NeuralSource, true, ActionContractTeamsView1Hash,
      manifestJson(Schema2, ActionContractTeamsView1Hash, "{\"forbid_objectives\": [0]}"))
    var w = newWorld(2026)
    let kept = keep.decide(w)
    let went = moved.decide(w)
    check kept[0].walk and kept[0].goal == w.cogs[0].pos
    check went[0].walk and went[0].goal == w.controlHearts[0].pos
    check moved[0].neural.selected[0] == 1
    check moved[0].neural.forbidHits == 1
    # Replay determinism with every seat running forbid + sampling: the same match seed twice
    # gives the same world hash every tick; the option changes the match.
    proc play(manifest: string, seed: int32, ticks: int): (seq[uint32], int) =
      let players = fixture(NeuralSource, true, ActionContractTeamsView1Hash, manifest)
      var world = newWorld(seed)
      for tick in 0..<ticks:
        let commands = players.decide(world)
        for slot in 0..<Seats: check not players[slot].failed
        world.step(commands)
        result[0].add world.stateHash()
      for slot in 0..<Seats: result[1] += players[slot].neural.forbidHits
    let options = manifestJson(Schema2, ActionContractTeamsView1Hash,
      "{\"forbid_objectives\": [0, 9, 10], \"sampling\": {\"mode\": \"categorical\"}}")
    let once = play(options, 2026, 300)
    check once == play(options, 2026, 300)
    check once[1] > 0   # the zero model's argmax (0) is forbidden on every decision
    let sampledOnly = manifestJson(Schema2, ActionContractTeamsView1Hash, "{\"sampling\": {\"mode\": \"categorical\"}}")
    check once[0] != play(sampledOnly, 2026, 300)[0]
    check once[0] != play(options, 2027, 300)[0]
    # Schema 1 and schema 2 without the field: unchanged behaviour and log line.
    for schema in [Schema1, Schema2]:
      let plain = fixture(NeuralSource, true, ActionContractTeamsView1Hash, manifestJson(schema, ActionContractTeamsView1Hash))
      check not plain[0].failed
      check not plain[0].neural.forbidAny
      check plain[0].neural.telemetry(10, 3) == "neural: peak_ops=10 budget=4000000 model=w64 ticks=3"
    # Rejected: under schema 1; bad index lists.
    var everything = "["
    for i in 0..<ActionSizes[0]:
      if i > 0: everything.add ","
      everything.add $i
    everything.add "]"
    for (schema, decoder) in [(Schema1, "{\"forbid_objectives\": [9, 10]}"),
                              (Schema2, "{\"forbid_objectives\": []}"),
                              (Schema2, "{\"forbid_objectives\": [51]}"),
                              (Schema2, "{\"forbid_objectives\": [-1]}"),
                              (Schema2, "{\"forbid_objectives\": [9, 9]}"),
                              (Schema2, "{\"forbid_objectives\": [9.0]}"),
                              (Schema2, "{\"forbid_objectives\": \"9,10\"}"),
                              (Schema2, "{\"forbid_objectives\": " & everything & "}")]:
      let bad = fixture(NeuralSource, true, ActionContractTeamsView1Hash, manifestJson(schema, ActionContractTeamsView1Hash, decoder))
      checkpoint schema & " " & decoder
      check bad[0].failed
