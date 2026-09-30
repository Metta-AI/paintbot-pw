## Neural BASIC I/O on the hosted seat (PLAN-neural-basic-io parts A and B, on SeatView): user
## inputs, the head-level phase (masks, temperatures, neuralSample, neuralChoice /
## neuralSetChoice), neuralObs and neuralLogit. The heads reach the engine only through BASIC
## verbs: every policy here selects with neuralSample and acts through the reference decode
## (players/neural_decode.bas). Synthetic actors only (seeded random weights); no bundle or
## checkpoint.
import std/[unittest, os, strutils, random, math, json]
import polyworld/cli
import ../examples/paintbot/[bots, sim, neural_contract, neural_host, contract_hash]

proc u32(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)
proc randomModel(seed: int, inputs: int, observationContract: string,
    actionContract = ActionContractTeamsView1Hash): string =
  ## A PWNET001 actor with seeded random weights, so logits move with the observation.
  const h = 64
  var r = initRand(seed)
  result = "PWNET001"
  let n = inputs*h + 3*h*h + LogitSize*h
  for x in [1,inputs,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
  result.add observationContract
  result.add actionContract
  for x in ActionSizes: result.u32(x.uint32)
  for i in 0..<n:
    let scale = if i < inputs*h: 0.08 elif i < inputs*h + 3*h*h: 0.15 else: 0.6
    result.u32(cast[uint32](float32(r.rand(2.0) - 1.0) * float32(scale)))

const
  Schema2 = "paintbot-neural-basic/2"
  Observe = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
"""
  ## The reference reading of the heads, in BASIC (walkTo / lookAt / shootAt / chargeGrenade / sneak).
  Decode = staticRead("../examples/paintbot/players/neural_decode.bas")
  Act = Observe & "neuralSample()\n" & Decode

var fixtureCount = 0
proc manifestFor(observationContract: string, decoder = "", userInputs = "",
    actionContract = ActionContractTeamsView1Hash, schema = Schema2): string =
  result = "{\"schema\": \"" & schema & "\", \"observation_contract\": \"" & observationContract &
    "\", \"action_contract\": \"" & actionContract & "\", \"sha256\": {}"
  if decoder.len > 0: result.add ", \"decoder\": " & decoder
  if userInputs.len > 0: result.add ", \"user_inputs\": " & userInputs
  result.add "}"
proc bundle(source: string, decoder = "", userInputs = 0, init = "", inputs = -1,
    observationContract = "", manifest = "x", model = true): seq[Bot] =
  ## Every seat runs `source` over a seeded random actor (observation contract teams.view.1,
  ## its action contract); `userInputs` > 0 makes it a teams.view.1u<K> actor with manifest
  ## user_inputs.
  inc fixtureCount
  let path = getTempDir()/("paintbot-basic-io-" & $getCurrentProcessId() & "-" & $fixtureCount & ".bas")
  let contract = if observationContract.len > 0: observationContract
                 elif userInputs > 0: userInputsContractHash(userInputs)
                 else: ObservationContractTeamsView1Hash
  let width = if inputs >= 0: inputs else: TeamsViewSize + userInputs
  writeFile(path, source)
  if model: writeFile(path & ".model.bin", randomModel(7, width, contract))
  var inputsJson = ""
  if userInputs > 0:
    var zeros: seq[string]
    for i in 0..<userInputs: zeros.add "0"
    inputsJson = "{\"count\": " & $userInputs & ", \"init\": [" &
      (if init.len > 0: init else: zeros.join(", ")) & "]}"
  let text = if manifest == "x": manifestFor(contract, decoder, inputsJson) else: manifest
  if text.len > 0: writeFile(path & ".neural.json", text)
  defer:
    for suffix in ["", ".model.bin", ".neural.json"]:
      if fileExists(path & suffix): removeFile(path & suffix)
  loadBots(@[BotGroup(path:path,count:Seats)])

proc play(players: seq[Bot], seed: int32, ticks: int): seq[uint32] =
  ## The hosted tick loop; one world hash per tick. Every seat must stay enabled.
  var world = newWorld(seed)
  for tick in 0..<ticks:
    if world.winner != -1 or world.tick >= world.endTick: break
    let commands = players.decide(world)
    for slot in 0..<Seats:
      if players[slot].failed:
        checkpoint "seat " & $slot & " failed at tick " & $tick & ": " & players[slot].error
        fail()
        return
    world.step(commands)
    result.add world.stateHash()

suite "neural BASIC I/O on the hosted seat":
  test "neuralSample + the reference decode replays hash for hash under every kept decoder option":
    for decoder in ["", """{"sampling": {"mode": "categorical", "temperature": 0.8}}""",
        """{"sampling": {"mode": "categorical"}, "forbid_objectives": [9, 10]}""",
        """{"forbid_objectives": [3], "joint_sampling": {"when": {"head": 3, "value": 0}, "head": 4, "offsets": [0, 1]}}"""]:
      checkpoint decoder
      let reference = bundle(Act, decoder)
      let expected = reference.play(2026, 500)
      check expected.len == 500
      let again = bundle(Act, decoder)
      check again.play(2026, 500) == expected
      check again[3].neural.telemetry(1, 500) == reference[3].neural.telemetry(1, 500)
      check bundle(Act, decoder).play(2027, 500) != expected

  test "neuralMask forbids like decoder.forbid_objectives; neuralTemperature samples like decoder.sampling":
    for sampling in ["", "\"sampling\": {\"mode\": \"categorical\"}"]:
      let native = bundle(Act, "{" & sampling & (if sampling.len > 0: ", " else: "") &
        "\"forbid_objectives\": [9, 10]}").play(99, 400)
      let decoder = if sampling.len > 0: "{" & sampling & "}" else: ""
      let basic = bundle("neuralMask(0, 1536)\n" & Act, decoder).play(99, 400)
      check native == basic
      # neuralMaskFrom addresses the same choices through a window.
      check bundle("neuralMaskFrom(0, 8, 6)\n" & Act, decoder).play(99, 400) == native
    for (milli, t) in [(1000, "1.0"), (700, "0.7"), (2500, "2.5")]:
      let native = bundle(Act, "{\"sampling\": {\"mode\": \"categorical\", \"temperature\": " & t & "}}").play(5, 400)
      check bundle("neuralTemperature(-1, " & $milli & ")\n" & Act).play(5, 400) == native
      # Per head: the same five calls.
      var perHead = ""
      for head in 0..4: perHead.add "neuralTemperature(" & $head & ", " & $milli & ")\n"
      check bundle(perHead & Act).play(5, 400) == native
    # Temperature 0 on a head = that head left out of decoder.sampling.heads.
    let native = bundle(Act, """{"sampling": {"mode": "categorical", "heads": [0, 2, 3, 4]}}""").play(5, 400)
    check bundle("neuralTemperature(1, 0)\n" & Act, """{"sampling": {"mode": "categorical"}}""").play(5, 400) == native
    # Masks and temperatures last one tick: set on tick 0 only, the rest is the manifest's.
    let once = bundle("if worldTick = 0 then\n  neuralTemperature(-1, 0)\nend if\n" & Act,
      """{"sampling": {"mode": "categorical"}}""")
    check once.play(5, 3).len == 3

  test "the grenade mask in BASIC: three spellings, one match":
    let decoder = """{"sampling": {"mode": "categorical"}}"""
    let expected = bundle(Act & "chargeGrenade(0)\n", decoder).play(11, 500)
    for variant in ["neuralMask(3, 2)\n" & Act,
                    Observe & "neuralSample()\nneuralSetChoice(3, 0)\n" & Decode]:
      check bundle(variant, decoder).play(11, 500) == expected
    # The mask changes the selection itself: unmasked, the grenade head selects 1 on some
    # decisions; masked, never.
    proc grenadeSelections(players: seq[Bot]): int =
      var world = newWorld(11)
      for tick in 0..<100:
        let commands = players.decide(world)
        for slot in 0..<Seats:
          require not players[slot].failed
          if world.cogs[slot].hp > 0 and players[slot].neural.selected[3] == 1: inc result
        world.step(commands)
    check grenadeSelections(bundle(Act, decoder)) > 0
    check grenadeSelections(bundle("neuralMask(3, 2)\n" & Act, decoder)) == 0

  test "the heads are numbers: nothing is issued without a BASIC verb; neuralSetChoice is what neuralChoice reads":
    # Assertions inside BASIC: a mismatch calls neuralSetChoice(9, 9), which disables the seat.
    let checks = Observe & """
neuralSample()
m = neuralChoice(0)
neuralSetChoice(0, 43)
if neuralChoice(0) <> 43 then
  neuralSetChoice(9, 9)
end if
neuralSetChoice(0, m)
if neuralChoice(0) <> m then
  neuralSetChoice(9, 9)
end if
neuralSetChoice(1, 24)
neuralSetChoice(2, 1)
if neuralChoice(1) <> 24 or neuralChoice(2) <> 1 then
  neuralSetChoice(9, 9)
end if
""" & Decode
    let players = bundle(checks, """{"sampling": {"mode": "categorical"}}""")
    var world = newWorld(4)
    for tick in 0..<120:
      let commands = players.decide(world)
      for slot in 0..<Seats:
        checkpoint players[slot].error
        check not players[slot].failed
        if world.cogs[slot].hp > 0:
          # The decode read the choices as set: compass aim 24 - 17 = 7 (1, -1), shooting.
          check commands[slot].shoot
          check players[slot].neural.choices[1] == 24 and players[slot].neural.choices[2] == 1
          check players[slot].neural.choices[0] == players[slot].neural.selected[0]
      world.step(commands)
    # Selected but never decoded: the seat issues nothing (the empty command).
    let silent = bundle(Observe & "neuralSample()\nm = neuralChoice(0)\nneuralSetChoice(0, 1)\n")
    let commands = silent.decide(newWorld(4))
    for slot in 0..<Seats:
      check not silent[slot].failed
      check silent[slot].neural.sampled
      check commands[slot] == Command()

  test "neuralLogit(i) reads the tick's logit i x 1000, after run_neural_net":
    # The seat writes neuralLogit(i) into its user inputs, which Nim reads back.
    const Indices = [0, 50, 51, 75, 76, 81]
    var source = Observe
    for k, i in Indices: source.add "neuralInput(" & $k & ", neuralLogit(" & $i & "))\n"
    source.add "neuralSample()\n" & Decode
    let players = bundle(source, userInputs = Indices.len)
    var world = newWorld(12)
    var checked = 0
    for tick in 0..<30:
      let commands = players.decide(world)
      for slot in 0..<Seats:
        require not players[slot].failed
        if world.cogs[slot].hp <= 0: continue
        let n = players[slot].neural
        for k, i in Indices:
          check n.userInputs[k] == int32(round(float64(n.logits[i]) * 1000))
          inc checked
      world.step(commands)
    check checked > 1000
    # A logit is some milli-value, not always 0: the random actor's logits move.
    var nonzero = false
    for x in players[0].neural.userInputs:
      if x != 0: nonzero = true
    check nonzero

  test "call-order and range errors disable the seat like every other neural misuse":
    for bad in [Observe & "neuralSample()\nneuralMask(0, 1)\n",
                Observe & "neuralSample()\nneuralTemperature(-1, 1000)\n",
                "neuralTemperature(-2, 1000)\n" & Act, "neuralTemperature(5, 1000)\n" & Act,
                "neuralTemperature(0, -1)\n" & Act, "neuralTemperature(0, 100001)\n" & Act,
                "neuralMask(5, 1)\n" & Act, "neuralMaskFrom(0, 51, 1)\n" & Act, "neuralMaskFrom(0, -1, 1)\n" & Act,
                "neuralMask(2, 3)\n" & Act, "neuralMask(0, -1)\nneuralMaskFrom(0, 32, -1)\n" & Act,
                "neuralSample()\n", Observe & "neuralChoice(0)\n", Observe & "neuralSample()\nneuralChoice(5)\n",
                Observe & "neuralSample()\nneuralSetChoice(1, 25)\n", Observe & "neuralSample()\nneuralSetChoice(2, -1)\n",
                Observe & "neuralSetChoice(0, 0)\n", Observe & "neuralSample()\nneuralSample()\n",
                Act & "neuralSample()\n", "neuralInput(0, 1)\n" & Act,
                "neuralObs(-1)\n", "neuralObs(512)\n",
                "neuralLogit(0)\n", "paintbot_observe(neuralObservation())\nneuralLogit(0)\n",
                Observe & "neuralLogit(-1)\n", Observe & "neuralLogit(82)\n"]:
      let players = bundle(bad)
      discard players.decide(newWorld(3))
      if not players[0].failed: checkpoint "did not fail: " & bad
      check players[0].failed
    # Seats without a neural model cannot use any of it.
    for plain in ["neuralMask(0, 1)\n", "neuralObs(0)\n", "neuralLogit(0)\n", "neuralTemperature(-1, 0)\n"]:
      let players = bundle(plain, manifest = "", model = false)
      discard players.decide(newWorld(3))
      check players[0].failed

  test "neuralObs reads the tick's observation x 1000, before or after paintbot_observe":
    let players = bundle("""
a = neuralObs(0)
b = neuralObs(511)
paintbot_observe(neuralObservation())
if neuralObs(0) <> a or neuralObs(511) <> b then
  neuralSetChoice(9, 9)
end if
""" & Observe.splitLines()[1] & "\nneuralSample()\n" & Decode)
    var world = newWorld(8)
    for tick in 0..<30:
      let commands = players.decide(world)
      for slot in 0..<Seats: check not players[slot].failed
      world.step(commands)
    discard players.decide(world)
    require world.cogs[5].hp > 0
    var expected = newSeq[float32](TeamsViewSize)
    beginViews(world)
    encodeObservation(seatView(5), ocTeamsView1, expected)
    for i in [0, 1, 2, 8, 12, 14, 21, 22, 23, 125, 485, 511]:
      check round(float64(players[5].neural.observation[i]) * 1000) == round(float64(expected[i]) * 1000)
      check players[5].neural.observation[i] == expected[i]

  test "user inputs: init at match start, one tick of latency, persist across ticks and deaths, clamped":
    let source = """
if worldTick > 0 then
  neuralInput(0, worldTick * 10)
end if
neuralInput(1, 2000000)
neuralInput(2, -2000000)
""" & Act
    let players = bundle(source, userInputs = 3, init = "5, -7, 123")
    check not players[0].failed
    check players[0].neural.userInputs == @[5'i32, -7, 123]
    check players[0].neural.observation.len == TeamsViewSize + 3
    var world = newWorld(21)
    for tick in 0..<40:
      let commands = players.decide(world)
      for slot in 0..<Seats: check not players[slot].failed
      let obs = players[2].neural.observation
      if tick == 0:
        check obs[512] == 0.005'f32 and obs[513] == -0.007'f32 and obs[514] == 0.123'f32
      elif tick == 1:
        check obs[512] == 0.005'f32 and obs[513] == 1000'f32 and obs[514] == -1000'f32
      else:
        check obs[512] == float32((tick-1)*10) / 1000'f32
      world.step(commands)
    # A dead seat does not run its script: its inputs stay where it left them.
    let before = players[2].neural.userInputs
    world.cogs[2].hp = 0
    discard players.decide(world)
    check players[2].neural.userInputs == before
    # The tick going back is a new match: init again.
    var fresh = newWorld(21)
    discard players.decide(fresh)
    check players[2].neural.observation[512] == 0.005'f32
    check players[2].neural.observation[514] == 0.123'f32
    # The encoder (teams.view.1 then the inputs) on the same world.
    var expected = newSeq[float32](TeamsViewSize + 3)
    beginViews(fresh)
    encodeObservation(seatView(4), ocTeamsView1, expected, [5'i32, -7, 123])
    check players[4].neural.observation == expected

  test "a user-input actor reads its inputs: a goal set in BASIC changes the net's input, not the world rules":
    # Two bundles differing only in the constant goal fed as user inputs play different
    # matches (the inputs reach the net); the same goal twice replays exactly.
    let goalA = bundle(Act, userInputs = 2, init = "1000, 2000")
    let goalB = bundle(Act, userInputs = 2, init = "-3000, 500")
    let a = goalA.play(31, 300)
    check a == bundle(Act, userInputs = 2, init = "1000, 2000").play(31, 300)
    check a != goalB.play(31, 300)
    # A goal read back from the observation equals the goal set (neuralObs of the tail).
    let readBack = bundle("""
if worldTick > 1 and (neuralObs(512) <> 4321 or neuralObs(513) <> -99) then
  neuralSetChoice(9, 9)
end if
neuralInput(0, 4321)
neuralInput(1, -99)
""" & Act, userInputs = 2)
    check readBack.play(31, 100).len == 100

  test "user-input actors above the old 32 and 64 caps: K = 33 .. 128 load and play, K = 129 is rejected":
    for k in [33, 34, 64, 65, 66, 128]:
      checkpoint "K = " & $k
      # The last input is written and read back through the observation tail.
      let players = bundle("""
if worldTick > 1 and neuralObs(""" & $(TeamsViewSize + k - 1) & """) <> 777 then
  neuralSetChoice(9, 9)
end if
neuralInput(""" & $(k - 1) & """, 777)
neuralInput(0, worldTick)
""" & Act, userInputs = k)
      check not players[0].failed
      check players[0].neural.userInputs.len == k
      check players.play(31, 100).len == 100
    let k128 = userInputsContractHash(128)
    var zeros: seq[string]
    for i in 0..<129: zeros.add "0"
    check bundle(Act, userInputs = 128, manifest = manifestFor(k128, userInputs =
      "{\"count\": 129, \"init\": [" & zeros.join(", ") & "]}"))[0].failed
    for bad in ["neuralInput(128, 1)\n", "neuralObs(" & $(TeamsViewSize + 128) & ")\n"]:
      checkpoint bad
      let outOfRange = bundle(bad & Act, userInputs = 128)
      discard outOfRange.decide(newWorld(3))
      check outOfRange[0].failed

  test "user-input bundles are validated: contract, width and manifest must agree":
    check not bundle(Act, userInputs = 2)[0].failed
    check bundle(Act, userInputs = 2, init = "1, 2, 3")[0].failed                       # init length
    check bundle(Act, userInputs = 2, inputs = TeamsViewSize)[0].failed             # actor width
    check bundle(Act, userInputs = 2, inputs = TeamsViewSize + 3)[0].failed
    let k2 = userInputsContractHash(2)
    check bundle(Act, userInputs = 2, manifest = manifestFor(k2))[0].failed             # no user_inputs
    check bundle(Act, userInputs = 2, manifest = "")[0].failed                          # no manifest at all
    check bundle(Act, userInputs = 2, manifest = manifestFor(k2, userInputs =
      "{\"count\": 2, \"init\": [0, 0]}", schema = "paintbot-neural-basic/1"))[0].failed # schema 1
    check bundle(Act, userInputs = 2, manifest = manifestFor(k2, userInputs =
      "{\"count\": 3, \"init\": [0, 0, 0]}"))[0].failed                                 # count vs contract
    check bundle(Act, manifest = manifestFor(ObservationContractTeamsView1Hash, userInputs =
      "{\"count\": 1, \"init\": [0]}"))[0].failed                                       # teams.view.1 actor with inputs
    for bad in ["[]", "{\"count\": 2}", "{\"init\": [0, 0]}", "{\"count\": 2, \"init\": [0, 1000001]}",
                "{\"count\": 2, \"init\": [0, 0.5]}", "{\"count\": 2, \"init\": [0, 0], \"x\": 1}",
                "{\"count\": 0, \"init\": []}"]:
      checkpoint bad
      check bundle(Act, userInputs = 2, manifest = manifestFor(k2, userInputs = bad))[0].failed
    check parseUserInputs(parseJson("{\"count\": 3, \"init\": [1000000, -1000000, 0]}")) == @[1000000'i32, -1000000, 0]
    for k in 1..MaxUserInputs:
      check userInputsFromHash(userInputsContractHash(k)) == k
      check userInputsContractHash(k) == sha256Hex(userInputsContractId(k))
    # The cap is 128; the teams.view.1u<K> hashes are the SHA-256 of their ids (pinned from
    # an independent sha256 of "paintbot-pw.teams.view.1u<K>").
    check MaxUserInputs == 128
    check userInputsContractId(7) == "paintbot-pw.teams.view.1u7"
    check ObservationContractTeamsView1Hash == "8ee935f46326c0c513fac82c14634becf48199c364f4688553fa26aedbc1f08e"
    check userInputsContractHash(1) == "ebcc4b0e1b3542c99c04b7ec7466a0244c26b495b0b174b9c10791fd3cab9a60"
    check userInputsContractHash(32) == "1006d74e5bd17d8d7e1d45ac98dcf8d884b45548a698333a98166bf0047cb900"
    check userInputsContractHash(64) == "10d64eb9a884839996372c62fb3373a8b11bc51b9b7281166d6311043eb0ffcf"
    check userInputsContractHash(128) == "40f2dd5ee2a19d984849e2db01ac42be57ef0a4b05fa86c6fd3eb184e57f2bca"
    var zeros129: seq[string]
    for i in 0..<129: zeros129.add "0"
    expect ValueError: discard parseUserInputs(parseJson("{\"count\": 129, \"init\": [" & zeros129.join(", ") & "]}"))
    expect ValueError: discard userInputsContractHash(0)
    expect ValueError: discard userInputsContractHash(129)
    check userInputsFromHash(ObservationContractTeamsView1Hash) == 0
    # The retired v2u<K> / v3u<K> families are not user-input contracts any more: a bundle
    # naming one is refused.
    for id in ["paintbot-pw.rules39.obs.v2u2", "paintbot-pw.rules43.obs.v3u2"]:
      checkpoint id
      check userInputsFromHash(sha256Hex(id)) == 0
      check bundle(Act, userInputs = 2, observationContract = sha256Hex(id))[0].failed
