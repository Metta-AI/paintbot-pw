import std/[unittest, os, strutils]
import polyworld/cli
import ../examples/paintbot/[bots, sim, neural_contract, neural_host]

proc u32(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)
proc zeroModel(actionContract = ActionContractHash): string =
  const h = 64
  const n = ObservationSize*h + 3*h*h + LogitSize*h
  result = "PWNET001"
  for x in [1,ObservationSize,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
  result.add ObservationContractHash
  result.add actionContract
  for x in ActionSizes: result.u32(x.uint32)
  result.add repeat('\0', n*4)

const NeuralSource = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
"""
proc fixture(source: string, model = true, actionContract = ActionContractHash,
    manifest = ""): array[Seats,Bot] =
  let path = getTempDir()/"paintbot-neural-host-test.bas"
  writeFile(path,source)
  if model: writeFile(path & ".model.bin", zeroModel(actionContract))
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
