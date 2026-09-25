import std/[unittest, os, strutils]
import polyworld/cli
import ../examples/paintbot/[bots, sim, neural_contract, neural_host]

proc u32(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)
proc zeroModel(actionContract = ActionContractHash,
    observationContract = ObservationContractHash, inputs = ObservationSize): string =
  const h = 64
  let n = inputs*h + 3*h*h + LogitSize*h
  result = "PWNET001"
  for x in [1,inputs,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
  result.add observationContract
  result.add actionContract
  for x in ActionSizes: result.u32(x.uint32)
  result.add repeat('\0', n*4)

const NeuralSource = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
"""
proc fixture(source: string, model = true, actionContract = ActionContractHash,
    manifest = "", observationContract = ObservationContractHash,
    inputs = ObservationSize): array[Seats,Bot] =
  let path = getTempDir()/"paintbot-neural-host-test.bas"
  writeFile(path,source)
  if model: writeFile(path & ".model.bin", zeroModel(actionContract, observationContract, inputs))
  if manifest.len > 0: writeFile(path & ".neural.json", manifest)
  defer:
    removeFile(path)
    if fileExists(path & ".model.bin"): removeFile(path & ".model.bin")
    if fileExists(path & ".neural.json"): removeFile(path & ".neural.json")
  loadBots(@[BotGroup(path:path,count:Seats)])
proc manifestJson(schema: string, actionContract: string, decoder = ""): string =
  ## A staged manifest as neural_package.py writes it; `decoder` is the raw JSON value.
  result = "{\"schema\": \"" & schema & "\", \"observation_contract\": \"" & ObservationContractHash &
    "\", \"action_contract\": \"" & actionContract & "\", \"sha256\": {}"
  if decoder.len > 0: result.add ", \"decoder\": " & decoder
  result.add "}"
proc mixedFixture(): array[Seats,Bot] =
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
    let expected = int64(2*(ObservationSize*64 + 3*64*64 + LogitSize*64) + 32*64)
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

  test "the bundle's action contract hash selects the decoder; unknown hashes are rejected":
    let v1 = fixture(NeuralSource)
    check v1[0].neural.contract == acV1
    let v2 = fixture(NeuralSource, true, ActionContractV2Hash)
    check v2[0].neural.contract == acV2
    var w = newWorld(2026)
    discard v2.decide(w)
    check not v2[0].failed
    check v2[0].neural.memory.tick == w.tick # v2 records its aim memory after acting
    discard v1.decide(w)
    check not v1[0].failed
    check v1[0].neural.memory.tick == -1 # v1 never touches it
    let unknown = fixture(NeuralSource, true, "0" & ActionContractV2Hash[1..^1])
    discard unknown.decide(w)
    check unknown[0].failed

  test "the bundle's observation contract hash selects the encoder and its width; unknown hashes are rejected":
    let v1 = fixture(NeuralSource)
    check v1[0].neural.observationContract == ocV1
    check v1[0].neural.observation.len == ObservationSize
    let v2 = fixture(NeuralSource, true, ActionContractHash, "", ObservationContractV2Hash, ObservationSizeV2)
    check v2[0].neural.observationContract == ocV2
    check v2[0].neural.observation.len == ObservationSizeV2
    var w = newWorld(2026)
    w.cogs[0].pos = w.controlHearts[8].pos # in the river: the terrain block is not all zero
    discard v2.decide(w)
    check not v2[0].failed
    var expected: array[ObservationSizeV2, float32]
    encodeObservation(w, 0, expected, ocV2)
    check v2[0].neural.observation == @expected
    check v2[0].neural.observation[ObservationSize] == 1
    check v2[0].neural.nativeWork == int64(2*(ObservationSizeV2*64 + 3*64*64 + LogitSize*64) + 32*64)
    discard v1.decide(w)
    var expected1: array[ObservationSize, float32]
    encodeObservation(w, 0, expected1)
    check v1[0].neural.observation == @expected1
    # Observation v2 with action v2 and a schema-2 manifest binding both hashes.
    let both = fixture(NeuralSource, true, ActionContractV2Hash,
      "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" & ObservationContractV2Hash &
      "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}}",
      ObservationContractV2Hash, ObservationSizeV2)
    discard both.decide(w)
    check not both[0].failed
    check both[0].neural.observationContract == ocV2 and both[0].neural.contract == acV2
    # A manifest naming v1 cannot carry a v2 actor.
    let unbound = fixture(NeuralSource, true, ActionContractHash,
      manifestJson("paintbot-neural-basic/2", ActionContractHash), ObservationContractV2Hash, ObservationSizeV2)
    discard unbound.decide(w)
    check unbound[0].failed
    # Width must match the named contract, both ways; an unknown hash fails the seat.
    for (hash, inputs) in [(ObservationContractV2Hash, ObservationSize),
        (ObservationContractHash, ObservationSizeV2),
        ("0" & ObservationContractV2Hash[1..^1], ObservationSizeV2),
        ("0" & ObservationContractHash[1..^1], ObservationSize)]:
      let bad = fixture(NeuralSource, true, ActionContractHash, "", hash, inputs)
      discard bad.decide(w)
      check bad[0].failed

  test "the fire-hold decoder option is read from a schema-2 manifest; older bundles are unaffected":
    const Schema1 = "paintbot-neural-basic/1"
    const Schema2 = "paintbot-neural-basic/2"
    # A v2 bundle with the option: loads, holds, and reports the hold count in its log line.
    let held = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"fire_hold_teammates\": true}"))
    check not held[0].failed
    check held[0].neural.contract == acV2
    check held[0].neural.fireHoldTeammates
    check held[0].neural.telemetry(10, 3) == "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 fire_holds=0"
    var w = newWorld(2026)
    discard held.decide(w)
    check not held[0].failed
    # Explicitly off, and a v1 bundle repackaged under schema 2 with the option on.
    let off = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"fire_hold_teammates\": false}"))
    check not off[0].failed and not off[0].neural.fireHoldTeammates
    let v1Held = fixture(NeuralSource, true, ActionContractHash,
      manifestJson(Schema2, ActionContractHash, "{\"fire_hold_teammates\": true}"))
    check not v1Held[0].failed and v1Held[0].neural.contract == acV1 and v1Held[0].neural.fireHoldTeammates
    # Schema 1 and schema 2 without the field: unchanged behaviour and log line.
    for (schema, contract) in [(Schema1, ActionContractHash), (Schema2, ActionContractHash), (Schema2, ActionContractV2Hash)]:
      let plain = fixture(NeuralSource, true, contract, manifestJson(schema, contract))
      check not plain[0].failed
      check not plain[0].neural.fireHoldTeammates
      check plain[0].neural.telemetry(10, 3) == "neural: peak_ops=10 budget=4000000 model=w64 ticks=3"
    let noManifest = fixture(NeuralSource, true, ActionContractV2Hash)
    check not noManifest[0].failed and not noManifest[0].neural.fireHoldTeammates
    # Rejected: the field under schema 1, an unknown option, a non-boolean, a non-object.
    for (schema, decoder) in [(Schema1, "{\"fire_hold_teammates\": true}"),
                              (Schema2, "{\"fire_hold_teammates\": true, \"other\": 1}"),
                              (Schema2, "{\"fire_hold_teammates\": 1}"),
                              (Schema2, "{\"fire_hold_teammates\": \"true\"}"),
                              (Schema2, "[true]")]:
      let bad = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(schema, ActionContractV2Hash, decoder))
      checkpoint schema & " " & decoder
      check bad[0].failed
  test "the sampling decoder option is read from a schema-2 manifest, seeds per seat and replays exactly":
    const Schema1 = "paintbot-neural-basic/1"
    const Schema2 = "paintbot-neural-basic/2"
    let sampled = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"fire_hold_teammates\": true, \"sampling\": {\"mode\": \"categorical\"}}"))
    check not sampled[0].failed
    check sampled[0].neural.sampling.enabled
    check sampled[0].neural.sampling.temperature == 1'f32
    check sampled[0].neural.sampling.heads == [true, true, true, true, true]
    check sampled[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 fire_holds=0 sampling=categorical t=1.000 heads=01234 seed=0x0000000000000000 draws=0"
    var w = newWorld(2026)
    discard sampled.decide(w)
    check not sampled[0].failed
    check sampled[0].neural.sampleDraws == 1
    check sampled[0].neural.telemetry(10, 1) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=1 fire_holds=0 sampling=categorical t=1.000 heads=01234 seed=0x" &
      toHex(samplingSeed(2026, 0), 16).toLowerAscii & " draws=1"
    # Temperature and a head subset.
    let partial = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"sampling\": {\"mode\": \"categorical\", \"temperature\": 0.5, \"heads\": [2, 0]}}"))
    check not partial[0].failed
    check partial[0].neural.sampling.temperature == 0.5'f32
    check partial[0].neural.sampling.heads == [true, false, true, false, false]
    check partial[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 sampling=categorical t=0.500 heads=02 seed=0x0000000000000000 draws=0"
    # Replay determinism: the same match seed twice gives the same world hash every tick
    # with every seat sampling (the zero model's logits are all equal, so every draw is a
    # uniform choice); the argmax bundle on the same seed diverges from it.
    proc play(manifest: string, seed: int32, ticks: int): seq[uint32] =
      let players = fixture(NeuralSource, true, ActionContractV2Hash, manifest)
      var world = newWorld(seed)
      for tick in 0..<ticks:
        let commands = players.decide(world)
        for slot in 0..<Seats: check not players[slot].failed
        world.step(commands)
        result.add world.stateHash()
    let sampling = manifestJson(Schema2, ActionContractV2Hash, "{\"sampling\": {\"mode\": \"categorical\"}}")
    let once = play(sampling, 2026, 120)
    check once == play(sampling, 2026, 120)
    check once != play(manifestJson(Schema2, ActionContractV2Hash), 2026, 120)
    check once != play(sampling, 2027, 120)
    # Schema 1 and schema 2 without the field: unchanged behaviour and log line.
    for (schema, contract) in [(Schema1, ActionContractHash), (Schema2, ActionContractHash), (Schema2, ActionContractV2Hash)]:
      let plain = fixture(NeuralSource, true, contract, manifestJson(schema, contract))
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
      let bad = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(schema, ActionContractV2Hash, decoder))
      checkpoint schema & " " & decoder
      check bad[0].failed
  test "the forbid and strafe decoder options are read from a schema-2 manifest, logged, and replay exactly":
    const Schema1 = "paintbot-neural-basic/1"
    const Schema2 = "paintbot-neural-basic/2"
    let both = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"forbid_objectives\": [9, 10], \"strafe_legs\": {}}"))
    check not both[0].failed
    check both[0].neural.forbidAny and both[0].neural.forbidden[9] and both[0].neural.forbidden[10]
    check not both[0].neural.forbidden[0]
    check both[0].neural.strafe == defaultStrafeOptions()
    check both[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 forbid_objectives=9,10 forbid_hits=0" &
      " strafe=r5250,legs3-6,shot6-9,rev800 strafe_legs=0 strafe_ticks=0"
    let custom = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"fire_hold_teammates\": true, \"strafe_legs\": {\"range\": 3000, \"legs\": [2, 4], \"shot_legs\": [7, 8], \"reverse_permille\": 500}}"))
    check not custom[0].failed and not custom[0].neural.forbidAny
    check custom[0].neural.strafe == StrafeOptions(enabled: true, range: 3000, legTicks: [2'i32, 4], shotLegTicks: [7'i32, 8], reversePermille: 500)
    check custom[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 fire_holds=0 strafe=r3000,legs2-4,shot7-8,rev500 strafe_legs=0 strafe_ticks=0"
    # The zero model's logits are all equal, so argmax takes index 0 ("keep"): forbidding 0
    # sends the seat to heart 1 instead, and counts the decision.
    let keep = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(Schema2, ActionContractV2Hash))
    let moved = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"forbid_objectives\": [0]}"))
    var w = newWorld(2026)
    let kept = keep.decide(w)
    let went = moved.decide(w)
    check kept[0].goal == w.cogs[0].pos
    check went[0].goal == w.controlHearts[0].pos
    check moved[0].neural.forbidHits == 1
    # Replay determinism with every seat running forbid + strafe + sampling + hold: the same
    # match seed twice gives the same world hash every tick; the options change the match.
    proc play(manifest: string, seed: int32, ticks: int): (seq[uint32], int) =
      let players = fixture(NeuralSource, true, ActionContractV2Hash, manifest)
      var world = newWorld(seed)
      for tick in 0..<ticks:
        let commands = players.decide(world)
        for slot in 0..<Seats: check not players[slot].failed
        world.step(commands)
        result[0].add world.stateHash()
      for slot in 0..<Seats: result[1] += players[slot].neural.strafeState.legs
    let options = manifestJson(Schema2, ActionContractV2Hash,
      "{\"fire_hold_teammates\": true, \"forbid_objectives\": [0, 9, 10], \"strafe_legs\": {}, \"sampling\": {\"mode\": \"categorical\"}}")
    let once = play(options, 2026, 300)
    check once == play(options, 2026, 300)
    check once[1] > 0   # legs were run
    let sampledOnly = manifestJson(Schema2, ActionContractV2Hash, "{\"fire_hold_teammates\": true, \"sampling\": {\"mode\": \"categorical\"}}")
    check once[0] != play(sampledOnly, 2026, 300)[0]
    check once[0] != play(options, 2027, 300)[0]
    # Schema 1 and schema 2 without the fields: unchanged behaviour and log line.
    for (schema, contract) in [(Schema1, ActionContractHash), (Schema2, ActionContractHash), (Schema2, ActionContractV2Hash)]:
      let plain = fixture(NeuralSource, true, contract, manifestJson(schema, contract))
      check not plain[0].failed
      check not plain[0].neural.forbidAny and not plain[0].neural.strafe.enabled
      check plain[0].neural.telemetry(10, 3) == "neural: peak_ops=10 budget=4000000 model=w64 ticks=3"
    # Rejected: under schema 1; bad index lists; bad strafe fields.
    var everything = "["
    for i in 0..<ActionSizes[0]:
      if i > 0: everything.add ","
      everything.add $i
    everything.add "]"
    for (schema, decoder) in [(Schema1, "{\"forbid_objectives\": [9, 10]}"),
                              (Schema1, "{\"strafe_legs\": {}}"),
                              (Schema2, "{\"forbid_objectives\": []}"),
                              (Schema2, "{\"forbid_objectives\": [51]}"),
                              (Schema2, "{\"forbid_objectives\": [-1]}"),
                              (Schema2, "{\"forbid_objectives\": [9, 9]}"),
                              (Schema2, "{\"forbid_objectives\": [9.0]}"),
                              (Schema2, "{\"forbid_objectives\": \"9,10\"}"),
                              (Schema2, "{\"forbid_objectives\": " & everything & "}"),
                              (Schema2, "{\"strafe_legs\": true}"),
                              (Schema2, "{\"strafe_legs\": {\"range\": 0}}"),
                              (Schema2, "{\"strafe_legs\": {\"range\": 20001}}"),
                              (Schema2, "{\"strafe_legs\": {\"range\": 5250.5}}"),
                              (Schema2, "{\"strafe_legs\": {\"legs\": [0, 6]}}"),
                              (Schema2, "{\"strafe_legs\": {\"legs\": [7, 6]}}"),
                              (Schema2, "{\"strafe_legs\": {\"legs\": [3]}}"),
                              (Schema2, "{\"strafe_legs\": {\"shot_legs\": [5, 9]}}"),
                              (Schema2, "{\"strafe_legs\": {\"shot_legs\": [6, 73]}}"),
                              (Schema2, "{\"strafe_legs\": {\"reverse_permille\": 1001}}"),
                              (Schema2, "{\"strafe_legs\": {\"seed\": 1}}")]:
      let bad = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(schema, ActionContractV2Hash, decoder))
      checkpoint schema & " " & decoder
      check bad[0].failed
  test "the aim snap and steady shot decoder options are read from a schema-2 manifest, logged, and replay exactly":
    const Schema1 = "paintbot-neural-basic/1"
    const Schema2 = "paintbot-neural-basic/2"
    let both = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"aim_snap\": {\"max_angle_deg\": 22.5}, \"steady_shot\": {}}"))
    check not both[0].failed
    check both[0].neural.aimSnap == aimSnapOptions(22500) and both[0].neural.steadyShot
    check both[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 aim_snap=22.500deg,cos_q15=30274 aim_snaps=0" &
      " steady_shot=on steady_shots=0 steady_ticks=0"
    # max_angle_deg is optional (22.5); integers and three decimals are fine.
    for (decoder, millideg) in [("{\"aim_snap\": {}}", 22500'i32), ("{\"aim_snap\": {\"max_angle_deg\": 30}}", 30000'i32),
                                ("{\"aim_snap\": {\"max_angle_deg\": 0.001}}", 1'i32),
                                ("{\"aim_snap\": {\"max_angle_deg\": 90}}", 90000'i32),
                                ("{\"aim_snap\": {\"max_angle_deg\": 12.345}}", 12345'i32)]:
      let one = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(Schema2, ActionContractV2Hash, decoder))
      checkpoint decoder
      check not one[0].failed and one[0].neural.aimSnap == aimSnapOptions(millideg) and not one[0].neural.steadyShot
    let steadyOnly = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"fire_hold_teammates\": true, \"steady_shot\": {}, \"forbid_objectives\": [9, 10]}"))
    check not steadyOnly[0].failed and steadyOnly[0].neural.steadyShot and not steadyOnly[0].neural.aimSnap.enabled
    check steadyOnly[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 fire_holds=0 forbid_objectives=9,10 forbid_hits=0" &
      " steady_shot=on steady_shots=0 steady_ticks=0"
    # Replay determinism with every seat sampling + snap + steady (+ strafe + hold): the same
    # match seed twice gives the same world hash every tick; the options change the match.
    proc play(manifest: string, seed: int32, ticks: int): (seq[uint32], int, int) =
      let players = fixture(NeuralSource, true, ActionContractV2Hash, manifest)
      var world = newWorld(seed)
      for tick in 0..<ticks:
        let commands = players.decide(world)
        for slot in 0..<Seats: check not players[slot].failed
        world.step(commands)
        result[0].add world.stateHash()
      for slot in 0..<Seats:
        result[1] += players[slot].neural.aimSnaps
        result[2] += players[slot].neural.steadyShots
    let options = manifestJson(Schema2, ActionContractV2Hash,
      "{\"fire_hold_teammates\": true, \"strafe_legs\": {}, \"sampling\": {\"mode\": \"categorical\"}, " &
      "\"aim_snap\": {\"max_angle_deg\": 45}, \"steady_shot\": {}}")
    let once = play(options, 2026, 400)
    check once == play(options, 2026, 400)
    check once[1] > 0 and once[2] > 0   # snaps and steadied shots happened
    let without = manifestJson(Schema2, ActionContractV2Hash,
      "{\"fire_hold_teammates\": true, \"strafe_legs\": {}, \"sampling\": {\"mode\": \"categorical\"}}")
    check once[0] != play(without, 2026, 400)[0]
    check once[0] != play(options, 2027, 400)[0]
    # Schema 1 and schema 2 without the fields: unchanged behaviour and log line.
    for (schema, contract) in [(Schema1, ActionContractHash), (Schema2, ActionContractHash), (Schema2, ActionContractV2Hash)]:
      let plain = fixture(NeuralSource, true, contract, manifestJson(schema, contract))
      check not plain[0].failed
      check not plain[0].neural.aimSnap.enabled and not plain[0].neural.steadyShot
      check plain[0].neural.telemetry(10, 3) == "neural: peak_ops=10 budget=4000000 model=w64 ticks=3"
    # Rejected: under schema 1; bad angles and fields; steady shot with index 0 forbidden.
    for (schema, decoder) in [(Schema1, "{\"aim_snap\": {}}"),
                              (Schema1, "{\"steady_shot\": {}}"),
                              (Schema2, "{\"aim_snap\": true}"),
                              (Schema2, "{\"aim_snap\": {\"max_angle_deg\": 0}}"),
                              (Schema2, "{\"aim_snap\": {\"max_angle_deg\": -5}}"),
                              (Schema2, "{\"aim_snap\": {\"max_angle_deg\": 90.001}}"),
                              (Schema2, "{\"aim_snap\": {\"max_angle_deg\": 22.5001}}"),
                              (Schema2, "{\"aim_snap\": {\"max_angle_deg\": \"22.5\"}}"),
                              (Schema2, "{\"aim_snap\": {\"max_angle_deg\": true}}"),
                              (Schema2, "{\"aim_snap\": {\"degrees\": 22.5}}"),
                              (Schema2, "{\"steady_shot\": true}"),
                              (Schema2, "{\"steady_shot\": {\"ticks\": 6}}"),
                              (Schema2, "{\"steady_shot\": {}, \"forbid_objectives\": [0, 9]}"),
                              (Schema2, "{\"forbid_objectives\": [0], \"steady_shot\": {}}")]:
      let bad = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(schema, ActionContractV2Hash, decoder))
      checkpoint schema & " " & decoder
      check bad[0].failed
  test "the aim retarget and shot gate decoder options are read from a schema-2 manifest, logged, and replay exactly":
    const Schema1 = "paintbot-neural-basic/1"
    const Schema2 = "paintbot-neural-basic/2"
    let both = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"aim_retarget\": {}, \"shot_gate\": {}}"))
    check not both[0].failed
    check both[0].neural.aimRetarget == aimRetargetOptions(5250, 160000, 2500000)
    check both[0].neural.shotGate == shotGateOptions(5250)
    check both[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 aim_retarget=r5250,hp160000,carry2500000 aim_retargets=0" &
      " shot_gate=r5250 shot_gates=0"
    # Every field is optional (base.bas's rule, the gun range); integers within their ranges.
    for (decoder, retarget, gate) in [
        ("{\"aim_retarget\": {\"max_range\": 4000}}", aimRetargetOptions(4000, 160000, 2500000), ShotGateOptions()),
        ("{\"aim_retarget\": {\"hp_weight\": 0, \"carry_weight\": 0}}", aimRetargetOptions(5250, 0, 0), ShotGateOptions()),
        ("{\"aim_retarget\": {\"max_range\": 1, \"hp_weight\": 1000000000, \"carry_weight\": 1000000000}}",
         aimRetargetOptions(1, 1_000_000_000, 1_000_000_000), ShotGateOptions()),
        ("{\"aim_retarget\": {\"max_range\": 20000}}", aimRetargetOptions(20000), ShotGateOptions()),
        ("{\"shot_gate\": {\"max_range\": 1}}", AimRetargetOptions(), shotGateOptions(1)),
        ("{\"shot_gate\": {\"max_range\": 20000}}", AimRetargetOptions(), shotGateOptions(20000))]:
      let one = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(Schema2, ActionContractV2Hash, decoder))
      checkpoint decoder
      check not one[0].failed and one[0].neural.aimRetarget == retarget and one[0].neural.shotGate == gate
    let full = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(Schema2, ActionContractV2Hash,
      "{\"fire_hold_teammates\": true, \"aim_snap\": {}, \"steady_shot\": {}, \"aim_retarget\": {\"max_range\": 4000, " &
      "\"hp_weight\": 1, \"carry_weight\": 2}, \"shot_gate\": {\"max_range\": 3000}}"))
    check not full[0].failed
    check full[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 fire_holds=0 aim_snap=22.500deg,cos_q15=30274 aim_snaps=0" &
      " steady_shot=on steady_shots=0 steady_ticks=0 aim_retarget=r4000,hp1,carry2 aim_retargets=0 shot_gate=r3000 shot_gates=0"
    # Replay determinism with every seat sampling + retarget + snap + gate (+ strafe, steady,
    # hold): the same match seed twice gives the same world hash every tick; the options
    # change the match.
    proc play(manifest: string, seed: int32, ticks: int): (seq[uint32], int, int) =
      let players = fixture(NeuralSource, true, ActionContractV2Hash, manifest)
      var world = newWorld(seed)
      for tick in 0..<ticks:
        let commands = players.decide(world)
        for slot in 0..<Seats: check not players[slot].failed
        world.step(commands)
        result[0].add world.stateHash()
      for slot in 0..<Seats:
        result[1] += players[slot].neural.aimRetargets
        result[2] += players[slot].neural.shotGates
    let options = manifestJson(Schema2, ActionContractV2Hash,
      "{\"fire_hold_teammates\": true, \"strafe_legs\": {}, \"sampling\": {\"mode\": \"categorical\"}, " &
      "\"aim_snap\": {}, \"steady_shot\": {}, \"aim_retarget\": {}, \"shot_gate\": {}}")
    let once = play(options, 2026, 400)
    check once == play(options, 2026, 400)
    check once[1] > 0 and once[2] > 0   # retargets and gated orders happened
    let without = manifestJson(Schema2, ActionContractV2Hash,
      "{\"fire_hold_teammates\": true, \"strafe_legs\": {}, \"sampling\": {\"mode\": \"categorical\"}, " &
      "\"aim_snap\": {}, \"steady_shot\": {}}")
    check once[0] != play(without, 2026, 400)[0]
    check once[0] != play(options, 2027, 400)[0]
    # Schema 1 and schema 2 without the fields: unchanged behaviour and log line.
    for (schema, contract) in [(Schema1, ActionContractHash), (Schema2, ActionContractHash), (Schema2, ActionContractV2Hash)]:
      let plain = fixture(NeuralSource, true, contract, manifestJson(schema, contract))
      check not plain[0].failed
      check not plain[0].neural.aimRetarget.enabled and not plain[0].neural.shotGate.enabled
      check plain[0].neural.telemetry(10, 3) == "neural: peak_ops=10 budget=4000000 model=w64 ticks=3"
    # Rejected: under schema 1; bad types, ranges and fields.
    for (schema, decoder) in [(Schema1, "{\"aim_retarget\": {}}"),
                              (Schema1, "{\"shot_gate\": {}}"),
                              (Schema2, "{\"aim_retarget\": true}"),
                              (Schema2, "{\"aim_retarget\": []}"),
                              (Schema2, "{\"aim_retarget\": {\"max_range\": 0}}"),
                              (Schema2, "{\"aim_retarget\": {\"max_range\": 20001}}"),
                              (Schema2, "{\"aim_retarget\": {\"max_range\": -5250}}"),
                              (Schema2, "{\"aim_retarget\": {\"max_range\": 5250.0}}"),
                              (Schema2, "{\"aim_retarget\": {\"max_range\": \"5250\"}}"),
                              (Schema2, "{\"aim_retarget\": {\"max_range\": 99999999999}}"),
                              (Schema2, "{\"aim_retarget\": {\"hp_weight\": -1}}"),
                              (Schema2, "{\"aim_retarget\": {\"hp_weight\": 1000000001}}"),
                              (Schema2, "{\"aim_retarget\": {\"hp_weight\": 1.5}}"),
                              (Schema2, "{\"aim_retarget\": {\"carry_weight\": -1}}"),
                              (Schema2, "{\"aim_retarget\": {\"carry_weight\": true}}"),
                              (Schema2, "{\"aim_retarget\": {\"range\": 5250}}"),
                              (Schema2, "{\"shot_gate\": true}"),
                              (Schema2, "{\"shot_gate\": 5250}"),
                              (Schema2, "{\"shot_gate\": {\"max_range\": 0}}"),
                              (Schema2, "{\"shot_gate\": {\"max_range\": 20001}}"),
                              (Schema2, "{\"shot_gate\": {\"max_range\": 5250.5}}"),
                              (Schema2, "{\"shot_gate\": {\"max_range\": null}}"),
                              (Schema2, "{\"shot_gate\": {\"range\": 5250}}")]:
      let bad = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(schema, ActionContractV2Hash, decoder))
      checkpoint schema & " " & decoder
      check bad[0].failed
  test "the fire hold's radius is read from a schema-2 manifest, logged, and replays exactly; true stays 55":
    const Schema1 = "paintbot-neural-basic/1"
    const Schema2 = "paintbot-neural-basic/2"
    let wide = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"fire_hold_teammates\": {\"radius\": 150}}"))
    check not wide[0].failed and wide[0].neural.fireHoldTeammates and wide[0].neural.fireHoldRadius == 150
    check wide[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 fire_holds=0 fire_hold_radius=150"
    # The object form turns the hold on; radius optional (55), 1 .. 2000; true/false as before.
    for (decoder, on, radius) in [("{\"fire_hold_teammates\": {}}", true, 55'i32),
                                  ("{\"fire_hold_teammates\": {\"radius\": 55}}", true, 55'i32),
                                  ("{\"fire_hold_teammates\": {\"radius\": 1}}", true, 1'i32),
                                  ("{\"fire_hold_teammates\": {\"radius\": 2000}}", true, 2000'i32),
                                  ("{\"fire_hold_teammates\": true}", true, 55'i32),
                                  ("{\"fire_hold_teammates\": false}", false, 55'i32)]:
      let one = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(Schema2, ActionContractV2Hash, decoder))
      checkpoint decoder
      check not one[0].failed and one[0].neural.fireHoldTeammates == on and one[0].neural.fireHoldRadius == radius
      if on and radius == 55:
        check one[0].neural.telemetry(10, 3) == "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 fire_holds=0"
    # Replay determinism with every seat sampling and holding at 150; the same seed twice is
    # the same match, and the radius changes it against the boolean form.
    proc play(manifest: string, seed: int32, ticks: int): (seq[uint32], int) =
      let players = fixture(NeuralSource, true, ActionContractV2Hash, manifest)
      var world = newWorld(seed)
      for tick in 0..<ticks:
        let commands = players.decide(world)
        for slot in 0..<Seats: check not players[slot].failed
        world.step(commands)
        result[0].add world.stateHash()
      for slot in 0..<Seats: result[1] += players[slot].neural.fireHolds
    let options = manifestJson(Schema2, ActionContractV2Hash,
      "{\"fire_hold_teammates\": {\"radius\": 150}, \"sampling\": {\"mode\": \"categorical\"}}")
    let boolean = manifestJson(Schema2, ActionContractV2Hash,
      "{\"fire_hold_teammates\": true, \"sampling\": {\"mode\": \"categorical\"}}")
    let explicit55 = manifestJson(Schema2, ActionContractV2Hash,
      "{\"fire_hold_teammates\": {\"radius\": 55}, \"sampling\": {\"mode\": \"categorical\"}}")
    let once = play(options, 2026, 400)
    check once == play(options, 2026, 400)
    let base = play(boolean, 2026, 400)
    check once[1] > base[1] and base[1] > 0
    check once[0] != base[0]
    check play(explicit55, 2026, 400) == base   # radius 55 is exactly the boolean form
    # Rejected: under schema 1; bad radii, types and fields.
    for (schema, decoder) in [(Schema1, "{\"fire_hold_teammates\": {\"radius\": 150}}"),
                              (Schema2, "{\"fire_hold_teammates\": {\"radius\": 0}}"),
                              (Schema2, "{\"fire_hold_teammates\": {\"radius\": -150}}"),
                              (Schema2, "{\"fire_hold_teammates\": {\"radius\": 2001}}"),
                              (Schema2, "{\"fire_hold_teammates\": {\"radius\": 99999999999}}"),
                              (Schema2, "{\"fire_hold_teammates\": {\"radius\": 150.0}}"),
                              (Schema2, "{\"fire_hold_teammates\": {\"radius\": \"150\"}}"),
                              (Schema2, "{\"fire_hold_teammates\": {\"radius\": true}}"),
                              (Schema2, "{\"fire_hold_teammates\": {\"range\": 150}}"),
                              (Schema2, "{\"fire_hold_teammates\": 150}"),
                              (Schema2, "{\"fire_hold_teammates\": [150]}")]:
      let bad = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(schema, ActionContractV2Hash, decoder))
      checkpoint schema & " " & decoder
      check bad[0].failed
  test "the spray aim and spray gate decoder options are read from a schema-2 manifest, logged, and replay exactly":
    const Schema1 = "paintbot-neural-basic/1"
    const Schema2 = "paintbot-neural-basic/2"
    let both = fixture(NeuralSource, true, ActionContractV2Hash,
      manifestJson(Schema2, ActionContractV2Hash, "{\"spray_aim\": {}, \"spray_gate\": {}}"))
    check not both[0].failed
    check both[0].neural.sprayAim == sprayAimOptions(850) and both[0].neural.sprayGate == sprayGateOptions(0, 1)
    check both[0].neural.telemetry(10, 3) ==
      "neural: peak_ops=10 budget=4000000 model=w64 ticks=3 spray_aim=r850 spray_aims=0 spray_gate=t0,e1 spray_gates=0"
    for (decoder, aim, gate) in [
        ("{\"spray_aim\": {\"max_range\": 1}}", sprayAimOptions(1), SprayGateOptions()),
        ("{\"spray_aim\": {\"max_range\": 500}}", sprayAimOptions(500), SprayGateOptions()),
        ("{\"spray_gate\": {\"max_teammates\": 7, \"min_enemies\": 8}}", SprayAimOptions(), sprayGateOptions(7, 8)),
        ("{\"spray_gate\": {\"min_enemies\": 0}}", SprayAimOptions(), sprayGateOptions(0, 0)),
        ("{\"spray_gate\": {\"max_teammates\": 2}}", SprayAimOptions(), sprayGateOptions(2, 1))]:
      let one = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(Schema2, ActionContractV2Hash, decoder))
      checkpoint decoder
      check not one[0].failed and one[0].neural.sprayAim == aim and one[0].neural.sprayGate == gate
    # Replay determinism with every seat sampling and both options: the same seed twice is
    # the same match (spray cans are rare for a zero model; the rule is exercised natively).
    proc play(manifest: string, seed: int32, ticks: int): seq[uint32] =
      let players = fixture(NeuralSource, true, ActionContractV2Hash, manifest)
      var world = newWorld(seed)
      for tick in 0..<ticks:
        let commands = players.decide(world)
        for slot in 0..<Seats: check not players[slot].failed
        world.step(commands)
        result.add world.stateHash()
    let options = manifestJson(Schema2, ActionContractV2Hash,
      "{\"sampling\": {\"mode\": \"categorical\"}, \"spray_aim\": {}, \"spray_gate\": {\"max_teammates\": 1}}")
    check play(options, 2026, 300) == play(options, 2026, 300)
    # Schema 1 and schema 2 without the fields: unchanged behaviour and log line.
    for (schema, contract) in [(Schema1, ActionContractHash), (Schema2, ActionContractHash), (Schema2, ActionContractV2Hash)]:
      let plain = fixture(NeuralSource, true, contract, manifestJson(schema, contract))
      check not plain[0].failed
      check not plain[0].neural.sprayAim.enabled and not plain[0].neural.sprayGate.enabled
      check plain[0].neural.telemetry(10, 3) == "neural: peak_ops=10 budget=4000000 model=w64 ticks=3"
    for (schema, decoder) in [(Schema1, "{\"spray_aim\": {}}"),
                              (Schema1, "{\"spray_gate\": {}}"),
                              (Schema2, "{\"spray_aim\": true}"),
                              (Schema2, "{\"spray_aim\": {\"max_range\": 0}}"),
                              (Schema2, "{\"spray_aim\": {\"max_range\": 851}}"),
                              (Schema2, "{\"spray_aim\": {\"max_range\": 850.0}}"),
                              (Schema2, "{\"spray_aim\": {\"range\": 850}}"),
                              (Schema2, "{\"spray_gate\": 1}"),
                              (Schema2, "{\"spray_gate\": {\"max_teammates\": -1}}"),
                              (Schema2, "{\"spray_gate\": {\"max_teammates\": 8}}"),
                              (Schema2, "{\"spray_gate\": {\"min_enemies\": 9}}"),
                              (Schema2, "{\"spray_gate\": {\"min_enemies\": \"1\"}}"),
                              (Schema2, "{\"spray_gate\": {\"enemies\": 1}}")]:
      let bad = fixture(NeuralSource, true, ActionContractV2Hash, manifestJson(schema, ActionContractV2Hash, decoder))
      checkpoint schema & " " & decoder
  test "an observation-v3 bundle reads its per-team goal from the manifest and appends it to the v2 observation":
    const Schema2 = "paintbot-neural-basic/2"
    proc v3Manifest(schema: string, goal: string, observation = ObservationContractV3Hash): string =
      result = "{\"schema\": \"" & schema & "\", \"observation_contract\": \"" & observation &
        "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}"
      if goal.len > 0: result.add ", \"goal\": " & goal
      result.add "}"
    let goalJson = "{\"red\": [1, 0.25, 0.1, 0.5, -0.25, 0.1, -0.5, 0], \"blue\": [1, 0, 0, 0, 0, 0, 0, 0]}"
    let red: GoalVector = [1'f32, 0.25, 0.1, 0.5, -0.25, 0.1, -0.5, 0]
    let blue: GoalVector = [1'f32, 0, 0, 0, 0, 0, 0, 0]
    let players = fixture(NeuralSource, true, ActionContractV2Hash, v3Manifest(Schema2, goalJson),
      ObservationContractV3Hash, ObservationSizeV3)
    for slot in 0..<Seats:
      check not players[slot].failed
      check players[slot].neural.observationContract == ocV3
      check players[slot].neural.goal == (if team(slot) == 0: red else: blue)
    # The seat's observation is the v2 observation followed by its team's goal.
    var world = newWorld(2026)
    for tick in 0..<40:
      let pre = world
      let commands = players.decide(world)
      for slot in 0..<Seats:
        check not players[slot].failed
        if pre.cogs[slot].hp <= 0: continue
        var v2: array[ObservationSizeV2, float32]
        pre.encodeObservation(slot, v2, pre.observedBodies(slot), ocV2)
        let seat = players[slot].neural
        for i in 0..<ObservationSizeV2: check cast[uint32](seat.observation[i]) == cast[uint32](v2[i])
        for i in 0..<GoalSize: check seat.observation[ObservationSizeV2 + i] == seat.goal[i]
      world.step(commands)
    # Rejected: a v3 actor without a goal or manifest; a goal on a v1/v2 bundle; schema 1;
    # malformed goals.
    let noManifest = fixture(NeuralSource, true, ActionContractV2Hash, "", ObservationContractV3Hash, ObservationSizeV3)
    check noManifest[0].failed
    for (manifest, observation, inputs) in [
        (v3Manifest(Schema2, ""), ObservationContractV3Hash, ObservationSizeV3),
        (v3Manifest("paintbot-neural-basic/1", goalJson), ObservationContractV3Hash, ObservationSizeV3),
        (v3Manifest(Schema2, goalJson, ObservationContractV2Hash), ObservationContractV2Hash, ObservationSizeV2),
        (v3Manifest(Schema2, goalJson, ObservationContractHash), ObservationContractHash, ObservationSize),
        (v3Manifest(Schema2, "{\"red\": [1, 0, 0, 0, 0, 0, 0, 0]}"), ObservationContractV3Hash, ObservationSizeV3),
        (v3Manifest(Schema2, "{\"red\": [1, 0, 0, 0, 0, 0, 0, 0.5], \"blue\": [1, 0, 0, 0, 0, 0, 0, 0]}"), ObservationContractV3Hash, ObservationSizeV3),
        (v3Manifest(Schema2, "{\"red\": [1.5, 0, 0, 0, 0, 0, 0, 0], \"blue\": [1, 0, 0, 0, 0, 0, 0, 0]}"), ObservationContractV3Hash, ObservationSizeV3),
        (v3Manifest(Schema2, "{\"red\": [1, 0, 0, 0, 0, 0, 0], \"blue\": [1, 0, 0, 0, 0, 0, 0, 0]}"), ObservationContractV3Hash, ObservationSizeV3),
        (v3Manifest(Schema2, "{\"red\": [true, 0, 0, 0, 0, 0, 0, 0], \"blue\": [1, 0, 0, 0, 0, 0, 0, 0]}"), ObservationContractV3Hash, ObservationSizeV3),
        (v3Manifest(Schema2, "{\"red\": [1, 0, 0, 0, 0, 0, 0, 0], \"blue\": [1, 0, 0, 0, 0, 0, 0, 0], \"green\": [1, 0, 0, 0, 0, 0, 0, 0]}"), ObservationContractV3Hash, ObservationSizeV3),
        (v3Manifest(Schema2, "[1, 0, 0, 0, 0, 0, 0, 0]"), ObservationContractV3Hash, ObservationSizeV3)]:
      let bad = fixture(NeuralSource, true, ActionContractV2Hash, manifest, observation, inputs)
      checkpoint manifest
      check bad[0].failed
