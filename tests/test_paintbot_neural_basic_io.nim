## Neural BASIC I/O on the hosted seat (PLAN-neural-basic-io parts A and B): user inputs,
## the head-level phase, the command buffer and the candidate readers. Synthetic actors
## only (seeded random weights); no bundle or checkpoint.
import std/[unittest, os, strutils, random, math, json]
import polyworld/cli
import ../examples/paintbot/[bots, sim, neural_contract, neural_host]

proc u32(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)
proc randomModel(seed: int, inputs: int, observationContract: string,
    actionContract = ActionContractV2Hash): string =
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
  Act = Observe & "paintbot_act(neuralLogits())\n"

var fixtureCount = 0
proc manifestFor(observationContract: string, decoder = "", userInputs = "",
    actionContract = ActionContractV2Hash, schema = Schema2): string =
  result = "{\"schema\": \"" & schema & "\", \"observation_contract\": \"" & observationContract &
    "\", \"action_contract\": \"" & actionContract & "\", \"sha256\": {}"
  if decoder.len > 0: result.add ", \"decoder\": " & decoder
  if userInputs.len > 0: result.add ", \"user_inputs\": " & userInputs
  result.add "}"
proc bundle(source: string, decoder = "", userInputs = 0, init = "", inputs = -1,
    observationContract = "", manifest = "x", model = true): array[Seats,Bot] =
  ## Every seat runs `source` over a seeded random actor (v2 observation, action contract
  ## v2); `userInputs` > 0 makes it a v2u<K> actor with manifest user_inputs.
  inc fixtureCount
  let path = getTempDir()/("paintbot-basic-io-" & $getCurrentProcessId() & "-" & $fixtureCount & ".bas")
  let contract = if observationContract.len > 0: observationContract
                 elif userInputs > 0: UserInputsContractHashes[userInputs-1]
                 else: ObservationContractV2Hash
  let width = if inputs >= 0: inputs else: ObservationSizeV2 + userInputs
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

proc play(players: array[Seats,Bot], seed: int32, ticks: int): seq[uint32] =
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

const SprayGateBasic* = """
' decoder.spray_gate (#101) in BASIC: drop a shoot order with a ready spray can unless the
' cone it would produce holds at least gateEnemies apparent enemies and at most gateMates
' apparent teammates. Runs between neuralSample and neuralDecode (before the strafe).
sub isqrtN(n)
  root = 0
  if n > 0 then
    root = n
    guess = (root + 1) / 2
    while guess < root
      root = guess
      guess = (root + n / root) / 2
    wend
  end if
end sub
sub sprayGate()
  if neuralChoice(2) = 0 or hasSpray = 0 or neuralObs(23) <> 0 then
    exit sub
  end if
  sx = neuralAimX(neuralChoice(1))
  sz = neuralAimZ(neuralChoice(1))
  if sx = -2147483647 - 1 then
    sx = neuralAimX(0)
    sz = neuralAimZ(0)
  end if
  if sx = 0 and sz = 0 then
    gx = neuralGoalX(neuralChoice(0))
    gz = neuralGoalZ(neuralChoice(0))
    if gx = -2147483647 - 1 then
      gx = selfX
      gz = selfY
    end if
    if gx <> selfX or gz <> selfY then
      sx = gx
      sz = gz
    end if
  end if
  dx = sx - selfX
  dz = sz - selfY
  isqrtN(dx * dx + dz * dz)
  vx = 0
  vz = 0
  if root > 0 then
    vx = dx * 850 / root
    vz = dz * 850 / root
  end if
  isqrtN(vx * vx + vz * vz)
  vl = root
  if vl < 1 then
    vl = 1
  end if
  enemies = 0
  mates = 0
  i = 0
  while i < 16
    if i <> selfId and visible(i) then
      tx = playerX(i) - selfX
      tz = playerY(i) - selfY
      along = (tx * vx + tz * vz) / vl
      across = tx * vz - tz * vx
      if across < 0 then
        across = -across
      end if
      across = across / vl
      if along > 0 and along <= 905 and across <= along * 3 / 5 + 55 then
        if playerTeam(i) = selfTeam then
          mates = mates + 1
        else
          enemies = enemies + 1
        end if
      end if
    end if
    i = i + 1
  wend
  if enemies < gateEnemies or mates > gateMates then
    neuralSetChoice(2, 0)
  end if
end sub
"""

const FullDecoder = """{"sampling": {"mode": "categorical"}, "forbid_objectives": [9, 10],
  "strafe_legs": {}, "aim_snap": {}, "aim_retarget": {}, "shot_gate": {}, "spray_aim": {},
  "spray_gate": {}, "fire_hold_teammates": {"radius": 150}}"""

suite "neural BASIC I/O on the hosted seat":
  test "neuralDecode + neuralIssue (with or without neuralSample) is paintbot_act, hash for hash":
    for decoder in ["", """{"sampling": {"mode": "categorical", "temperature": 0.8}}""", FullDecoder,
        """{"steady_shot": {}, "forbid_objectives": [3], "fire_hold_teammates": true}"""]:
      checkpoint decoder
      let reference = bundle(Act, decoder)
      let expected = reference.play(2026, 500)
      check expected.len == 500
      for variant in [Observe & "neuralDecode()\nneuralIssue()\n",
                      Observe & "neuralSample()\nneuralDecode()\nneuralIssue()\n",
                      Observe & "neuralSample()\npaintbot_act(neuralLogits())\n",
                      Observe & "neuralDecode()\npaintbot_act(neuralLogits())\n"]:
        let players = bundle(variant, decoder)
        check players.play(2026, 500) == expected
        check players[3].neural.telemetry(1, 500) == reference[3].neural.telemetry(1, 500)

  test "neuralMask forbids like decoder.forbid_objectives; neuralTemperature samples like decoder.sampling":
    for sampling in ["", "\"sampling\": {\"mode\": \"categorical\"}, "]:
      let native = bundle(Act, "{" & sampling & "\"forbid_objectives\": [9, 10], \"strafe_legs\": {}}").play(99, 400)
      let basic = bundle("neuralMask(0, 1536)\n" & Act,
        "{" & sampling & "\"strafe_legs\": {}}").play(99, 400)
      check native == basic
      # neuralMaskFrom addresses the same choices through a window.
      check bundle("neuralMaskFrom(0, 8, 6)\n" & Act, "{" & sampling & "\"strafe_legs\": {}}").play(99, 400) == native
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

  test "the grenade mask in BASIC: four spellings, one match":
    let decoder = """{"sampling": {"mode": "categorical"}, "strafe_legs": {}, "aim_retarget": {}}"""
    let expected = bundle(Act & "chargeGrenade(0)\n", decoder).play(11, 500)
    for variant in ["neuralMask(3, 2)\n" & Act,
                    Observe & "neuralSample()\nneuralSetChoice(3, 0)\nneuralDecode()\nneuralIssue()\n",
                    Observe & "neuralDecode()\ncmdSet(6, 0)\nneuralIssue()\n",
                    Observe & "neuralDecode()\nneuralIssue()\nchargeGrenade(0)\n"]:
      check bundle(variant, decoder).play(11, 500) == expected

  test "#101's spray gate in BASIC (between neuralSample and neuralDecode) is decoder.spray_gate, strafe on":
    proc sprayPlay(players: array[Seats,Bot], seed: int32, ticks: int): seq[uint32] =
      # Every live seat holds a spray can, so the gate decides on most shoot orders.
      var world = newWorld(seed)
      for tick in 0..<ticks:
        if world.winner != -1 or world.tick >= world.endTick: break
        for slot in 0..<Seats:
          if world.cogs[slot].hp > 0: world.equipment[slot].sprayCan = true
        let commands = players.decide(world)
        for slot in 0..<Seats:
          if players[slot].failed:
            checkpoint "seat " & $slot & ": " & players[slot].error
            fail()
            return
        world.step(commands)
        result.add world.stateHash()
    let common = "\"sampling\": {\"mode\": \"categorical\"}, \"strafe_legs\": {}, \"aim_retarget\": {}, " &
      "\"shot_gate\": {}, \"fire_hold_teammates\": {\"radius\": 150}"
    var gates = 0
    for (mates, enemies) in [(0, 1), (1, 2), (0, 0)]:
      for sprayAim in ["", ", \"spray_aim\": {}"]:
        let gate = ", \"spray_gate\": {\"max_teammates\": " & $mates & ", \"min_enemies\": " & $enemies & "}"
        let native = bundle(Act, "{" & common & sprayAim & gate & "}")
        let expected = native.sprayPlay(77, 600)
        for slot in 0..<Seats: gates += native[slot].neural.sprayGates
        let basic = bundle(SprayGateBasic & "gateMates = " & $mates & "\ngateEnemies = " & $enemies & "\n" & Observe &
          "neuralSample()\nsprayGate()\nneuralDecode()\nneuralIssue()\n", "{" & common & sprayAim & "}")
        check basic.sprayPlay(77, 600) == expected
    check gates > 100

  test "the command buffer: readers see the decoded command, cmdSet edits it, nothing is issued without neuralIssue":
    # Assertions inside BASIC: a mismatch calls neuralSetChoice(9, 9), which disables the seat.
    let check1 = Observe & """
neuralSample()
m = neuralChoice(0)
k = neuralChoice(1)
gx = neuralGoalX(m)
ax = neuralAimX(k)
az = neuralAimZ(k)
if ax = -2147483647 - 1 then
  ax = neuralAimX(0)
  az = neuralAimZ(0)
end if
neuralDecode()
if cmdAimX() <> ax or cmdAimZ() <> az then
  neuralSetChoice(9, 9)
end if
if gx <> -2147483647 - 1 and m > 0 and cmdGoalX() <> gx then
  neuralSetChoice(9, 9)
end if
if cmdWalk() <> 1 or cmdShoot() <> neuralChoice(2) or cmdSneak() <> neuralChoice(4) or cmdDirect() <> 0 then
  neuralSetChoice(9, 9)
end if
cmdSet(0, 0)
cmdSet(4, -99999999)
cmdSet(5, 99999999)
if cmdWalk() <> 0 or cmdAimX() <> mapMinX() or cmdAimZ() <> mapMaxY() then
  neuralSetChoice(9, 9)
end if
neuralIssue()
"""
    let players = bundle(check1, """{"sampling": {"mode": "categorical"}}""")
    var world = newWorld(4)
    for tick in 0..<120:
      let commands = players.decide(world)
      for slot in 0..<Seats:
        checkpoint players[slot].error
        check not players[slot].failed
        if world.cogs[slot].hp > 0:
          check not commands[slot].walk
          check commands[slot].aim.x == minX().int32 and commands[slot].aim.z == maxZ().int32
      world.step(commands)
    # Decoded but never issued: the seat issues nothing (the empty command).
    let silent = bundle(Observe & "neuralDecode()\n")
    let commands = silent.decide(newWorld(4))
    for slot in 0..<Seats:
      check not silent[slot].failed
      check commands[slot] == Command()

  test "call-order and range errors disable the seat like every other neural misuse":
    for bad in [Observe & "neuralSample()\nneuralMask(0, 1)\n",
                Observe & "neuralSample()\nneuralTemperature(-1, 1000)\n",
                "neuralTemperature(-2, 1000)\n" & Act, "neuralTemperature(5, 1000)\n" & Act,
                "neuralTemperature(0, -1)\n" & Act, "neuralTemperature(0, 100001)\n" & Act,
                "neuralMask(5, 1)\n" & Act, "neuralMaskFrom(0, 51, 1)\n" & Act, "neuralMaskFrom(0, -1, 1)\n" & Act,
                "neuralMask(2, 3)\n" & Act, "neuralMask(0, -1)\nneuralMaskFrom(0, 32, -1)\n" & Act,
                "neuralSample()\n", Observe & "neuralChoice(0)\n", Observe & "neuralSample()\nneuralChoice(5)\n",
                Observe & "neuralSample()\nneuralSetChoice(1, 25)\n", Observe & "neuralSample()\nneuralSetChoice(2, -1)\n",
                Observe & "neuralDecode()\nneuralSetChoice(0, 0)\n", Observe & "neuralSample()\nneuralSample()\n",
                Observe & "neuralDecode()\nneuralDecode()\n", Observe & "neuralIssue()\n",
                Observe & "neuralDecode()\nneuralIssue()\nneuralIssue()\n", Act & "neuralIssue()\n",
                Observe & "cmdWalk()\n", Observe & "cmdSet(0, 1)\n", Observe & "neuralDecode()\ncmdSet(9, 1)\n",
                Observe & "neuralDecode()\nneuralIssue()\ncmdSet(0, 1)\n", "neuralInput(0, 1)\n" & Act,
                "neuralObs(-1)\n", "neuralObs(506)\n", "neuralGoalX(51)\n", Observe & "neuralAimX(0)\n",
                Observe & "neuralSample()\nneuralAimZ(25)\n"]:
      let players = bundle(bad)
      discard players.decide(newWorld(3))
      if not players[0].failed: checkpoint "did not fail: " & bad
      check players[0].failed
    # Seats without a neural model cannot use any of it.
    for plain in ["neuralMask(0, 1)\n", "neuralObs(0)\n", "neuralGoalX(0)\n", "neuralTemperature(-1, 0)\n"]:
      let players = bundle(plain, manifest = "", model = false)
      discard players.decide(newWorld(3))
      check players[0].failed

  test "neuralObs reads the tick's observation x 1000, before or after paintbot_observe":
    let players = bundle("""
a = neuralObs(0)
b = neuralObs(505)
paintbot_observe(neuralObservation())
if neuralObs(0) <> a or neuralObs(505) <> b then
  neuralSetChoice(9, 9)
end if
""" & Observe.splitLines()[1] & "\npaintbot_act(neuralLogits())\n")
    var world = newWorld(8)
    for tick in 0..<30:
      let commands = players.decide(world)
      for slot in 0..<Seats: check not players[slot].failed
      world.step(commands)
    var expected = newSeq[float32](ObservationSizeV2)
    encodeObservation(world, 5, expected, ocV2)
    discard players.decide(world)
    for i in [0, 1, 2, 8, 14, 21, 22, 23, 448, 505]:
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
    check players[0].neural.observation.len == ObservationSizeV2 + 3
    var world = newWorld(21)
    for tick in 0..<40:
      let commands = players.decide(world)
      for slot in 0..<Seats: check not players[slot].failed
      let obs = players[2].neural.observation
      if tick == 0:
        check obs[506] == 0.005'f32 and obs[507] == -0.007'f32 and obs[508] == 0.123'f32
      elif tick == 1:
        check obs[506] == 0.005'f32 and obs[507] == 1000'f32 and obs[508] == -1000'f32
      else:
        check obs[506] == float32((tick-1)*10) / 1000'f32
      world.step(commands)
    # A dead seat does not run its script: its inputs stay where it left them.
    let before = players[2].neural.userInputs
    world.cogs[2].hp = 0
    discard players.decide(world)
    check players[2].neural.userInputs == before
    # The tick going back is a new match: init again.
    var fresh = newWorld(21)
    discard players.decide(fresh)
    check players[2].neural.observation[506] == 0.005'f32
    check players[2].neural.observation[508] == 0.123'f32
    # The encoder matches encodeObservationInputs on the same world.
    var expected = newSeq[float32](ObservationSizeV2 + 3)
    encodeObservationInputs(fresh, 4, expected, fresh.observedBodies(4), [5'i32, -7, 123])
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
if worldTick > 1 and (neuralObs(506) <> 4321 or neuralObs(507) <> -99) then
  neuralSetChoice(9, 9)
end if
neuralInput(0, 4321)
neuralInput(1, -99)
""" & Act, userInputs = 2)
    check readBack.play(31, 100).len == 100

  test "user-input bundles are validated: contract, width and manifest must agree":
    check not bundle(Act, userInputs = 2)[0].failed
    check bundle(Act, userInputs = 2, init = "1, 2, 3")[0].failed                       # init length
    check bundle(Act, userInputs = 2, inputs = ObservationSizeV2)[0].failed             # actor width
    check bundle(Act, userInputs = 2, inputs = ObservationSizeV2 + 3)[0].failed
    let k2 = UserInputsContractHashes[1]
    check bundle(Act, userInputs = 2, manifest = manifestFor(k2))[0].failed             # no user_inputs
    check bundle(Act, userInputs = 2, manifest = "")[0].failed                          # no manifest at all
    check bundle(Act, userInputs = 2, manifest = manifestFor(k2, userInputs =
      "{\"count\": 2, \"init\": [0, 0]}", schema = "paintbot-neural-basic/1"))[0].failed # schema 1
    check bundle(Act, userInputs = 2, manifest = manifestFor(k2, userInputs =
      "{\"count\": 3, \"init\": [0, 0, 0]}"))[0].failed                                 # count vs contract
    check bundle(Act, manifest = manifestFor(ObservationContractV2Hash, userInputs =
      "{\"count\": 1, \"init\": [0]}"))[0].failed                                       # v2 actor with inputs
    for bad in ["[]", "{\"count\": 2}", "{\"init\": [0, 0]}", "{\"count\": 2, \"init\": [0, 1000001]}",
                "{\"count\": 2, \"init\": [0, 0.5]}", "{\"count\": 2, \"init\": [0, 0], \"x\": 1}",
                "{\"count\": 0, \"init\": []}"]:
      checkpoint bad
      check bundle(Act, userInputs = 2, manifest = manifestFor(k2, userInputs = bad))[0].failed
    check parseUserInputs(parseJson("{\"count\": 3, \"init\": [1000000, -1000000, 0]}")) == @[1000000'i32, -1000000, 0]
    for k in 1..MaxUserInputs: check userInputsFromHash(UserInputsContractHashes[k-1]) == k
    check userInputsFromHash(ObservationContractV2Hash) == 0
    check userInputsContractId(7) == "paintbot-pw.rules39.obs.v2u7"
