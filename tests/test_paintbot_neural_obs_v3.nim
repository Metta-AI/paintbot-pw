## Observation contract v3 (paintbot-pw.rules43.obs.v3.float514): v2's 506 floats
## unchanged, then the seat's team's public scoreboard (neural_contract.encodeScoreboardBlock);
## v3u<K> = v3 + K user inputs. The hosted seat loads v3 / v3u<K> actors in the teams game
## and refuses them in FFA-kin; BASIC reads the same scoreboard through teamLives,
## awardBehind and awardBehindSeconds. Synthetic actors (seeded random weights) only.
import std/[unittest, os, random, math, json, strutils]
import polyworld/cli
import ../examples/paintbot/[sim, game, bots, neural_contract, neural_host]

const S = ObservationSizeV2 # first scoreboard column

proc u32(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)
proc randomModel(seed: int, inputs: int, observationContract: string): string =
  ## A PWNET001 actor with seeded random weights, so logits move with the observation.
  const h = 64
  var r = initRand(seed)
  result = "PWNET001"
  let n = inputs*h + 3*h*h + LogitSize*h
  for x in [1,inputs,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
  result.add observationContract
  result.add ActionContractV2Hash
  for x in ActionSizes: result.u32(x.uint32)
  for i in 0..<n:
    let scale = if i < inputs*h: 0.08 elif i < inputs*h + 3*h*h: 0.15 else: 0.6
    result.u32(cast[uint32](float32(r.rand(2.0) - 1.0) * float32(scale)))

proc idle(w: var World, ticks: int) =
  var commands: array[LegacySeats, Command]
  for tick in 0..<ticks: w.step(commands)

proc firstSeat(side: int): int =
  for i in 0..<Seats:
    if team(i) == side: return i

proc v3(w: World, slot: int): array[ObservationSizeV3, float32] =
  for i in 0..<result.len: result[i] = NaN.float32
  encodeObservation(w, slot, result, ocV3)

proc block8(w: World, slot: int): array[ScoreboardBlockSize, float32] =
  let row = w.v3(slot)
  for i in 0..<ScoreboardBlockSize: result[i] = row[S+i]

proc expected(ownLives, enemyLives, ownGlory, enemyGlory, behind, behindSeconds, quiet,
    ticksLeft, endTick: int): array[ScoreboardBlockSize, float32] =
  ## The block written out by hand from its documented formula.
  [float32(ownLives)/32'f32, float32(enemyLives)/32'f32, float32(ownGlory)/1000'f32,
   float32(enemyGlory)/1000'f32, float32(behind)/10'f32, float32(behindSeconds)/60'f32,
   float32(quiet)/100'f32, float32(ticksLeft)/float32(endTick)]

var fixtureCount = 0
proc bundle(source: string, observationContract: string, inputs: int, userInputs = 0,
    init = ""): seq[Bot] =
  ## Every seat runs `source` over a seeded random actor naming `observationContract`
  ## with `inputs` inputs; `userInputs` > 0 adds manifest user_inputs.
  inc fixtureCount
  let path = getTempDir()/("paintbot-obs-v3-" & $getCurrentProcessId() & "-" & $fixtureCount & ".bas")
  writeFile(path, source)
  writeFile(path & ".model.bin", randomModel(5, inputs, observationContract))
  var manifest = "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
    observationContract & "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}"
  if userInputs > 0:
    var zeros: seq[string]
    for i in 0..<userInputs: zeros.add "0"
    manifest.add ", \"user_inputs\": {\"count\": " & $userInputs & ", \"init\": [" &
      (if init.len > 0: init else: zeros.join(", ")) & "]}"
  manifest.add "}"
  writeFile(path & ".neural.json", manifest)
  defer:
    for suffix in ["", ".model.bin", ".neural.json"]:
      if fileExists(path & suffix): removeFile(path & suffix)
  loadBots(@[BotGroup(path: path, count: Seats)])

const
  Act = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
"""
  InputsAct = """
neuralInput(0, worldTick * 3)
neuralInput(2, selfHp - 7)
""" & Act

suite "Observation contract v3 (scoreboard)":
  setup:
    visionRulesVersion = 43
    replayRulesVersion = 43
    gameMode = gmTeams
    configureMap("")
    configureVision("")
    configureGlory(DefaultGloryConfig)
  teardown:
    gameMode = gmTeams
    configureGlory(DefaultGloryConfig)

  test "ids, sizes and hashes; v1, v2 and v2u<K> are unchanged":
    check ScoreboardBlockSize == 8 and ObservationSizeV3 == 514
    check ObservationContractV3 == "paintbot-pw.rules43.obs.v3.float514"
    check ObservationContractV3Hash == "06f16d62adedda6995d393696c0d2ed257aa9380b86341e73d1d6a3c7ea374f1"
    check observationSize(ocV3) == 514 and ocV3.int == 3
    check observationContractVersion(ObservationContractV3Hash) == ocV3
    check observationContractHash(ocV3) == ObservationContractV3Hash
    check observationContractId(ocV3) == ObservationContractV3
    # v1 / v2 / ffa.v1 and the v2u<K> table are what they were.
    check ObservationContractHash == "ed5d16768e3144a04a28420ce227ff2d6a831be9f64f3633326b133a5335b7e2"
    check ObservationContractV2Hash == "e0d7b0b97975725c470ef6119ca2a6caf4aaa6f34cd15bee02bd306489c029e5"
    check ObservationContractFfaV1Hash == "6b19dc324386542eb915d30c2ce1707a8f8e192a0425ee8b2ae9145969583fc7"
    check UserInputsContractHashes[0] == "bd80f4d35088c1f5e673e9b91d16df826e1cfb0e590185dbf4d8bf59af0bdb04"
    check UserInputsContractHashes[63] == "18a5141bf7d78fdf93524757bf261f367cfebe3b489fb6f2988936375bb8f4aa"
    # v3u<K>: its own table, K = 1 .. 128, disjoint from v2u<K> and the plain contracts.
    check v3UserInputsContractId(3) == "paintbot-pw.rules43.obs.v3u3"
    check V3UserInputsContractHashes[0] == "8086b6f36b9c2cf07e9e6586e97221e484f809e08669075663c5dcf9cb63ac36"
    check V3UserInputsContractHashes[63] == "1695203c740b769ff61f9bd18c4687f517db1664069b3ae47e7466060cb77dfb"
    check V3UserInputsContractHashes[127] == "cbb429e7fa93d9bc478f30da689742751baf4c2a4fee50210f2a104de1410e88"
    # Raising the cap from 64 to 128 appended v3u65 .. v3u128; v3u1 .. v3u64 are byte-identical
    # (FNV-1a-64 digest of the concatenated original 64).
    var digest = 0xcbf29ce484222325'u64
    for k in 0..<64:
      for c in V3UserInputsContractHashes[k]: digest = (digest xor uint64(ord(c))) * 0x100000001b3'u64
    check digest == 0x14c778016822e2ab'u64
    for k in 1..MaxUserInputs:
      let h = V3UserInputsContractHashes[k-1]
      check v3UserInputsFromHash(h) == k and userInputsFromHash(h) == 0
      check userInputsFromHash(UserInputsContractHashes[k-1]) == k
      check v3UserInputsFromHash(UserInputsContractHashes[k-1]) == 0
      check userInputsContractHash(ocV3, k) == h
      check userInputsContractHash(ocV2, k) == UserInputsContractHashes[k-1]
      check h notin UserInputsContractHashes
      check h notin [ObservationContractHash, ObservationContractV2Hash, ObservationContractV3Hash]
    for h in [ObservationContractHash, ObservationContractV2Hash, ObservationContractV3Hash]:
      check v3UserInputsFromHash(h) == 0
    expect ValueError: discard userInputsContractHash(ocV3, 0)
    expect ValueError: discard userInputsContractHash(ocV3, 129)
    expect ValueError: discard userInputsContractHash(ocV2, 129)
    expect ValueError: discard userInputsContractHash(ocV1, 1)
    let w = newWorld(3)
    var v2row: array[ObservationSizeV2, float32]
    var v3row: array[ObservationSizeV3, float32]
    var small: array[ScoreboardBlockSize-1, float32]
    expect ValueError: encodeObservation(w, 0, v2row, ocV3)
    expect ValueError: encodeObservation(w, 0, v3row, ocV2)
    expect ValueError: encodeObservation(w, Seats, v3row, ocV3)
    expect ValueError: encodeScoreboardBlock(w, 0, small)

  test "v3's first 506 floats equal v2 exactly on stepped worlds; the block matches its formula":
    var compared = 0
    var sawDeficit, sawGloryGap = false
    for seed in [1'i32, 2, 3]:
      configureRules(43)
      configureGlory(parseGloryConfig(parseJson("""{"behind_lives": 5}""")))
      var w = newWorld(seed, 2400)
      var actions: array[ActionSizes.len, int32]
      var commands: array[LegacySeats, Command]
      var a: array[ObservationSizeV2, float32]
      while w.winner == -1 and w.tick < w.endTick:
        if w.tick mod 8 == 0:
          for slot in 0..<Seats:
            encodeObservation(w, slot, a, ocV2)
            let c = w.v3(slot)
            for i in 0..<ObservationSizeV2: require a[i] == c[i]
            let side = team(slot)
            var own, enemy = 0
            for i in 0..<Seats:
              if team(i) == side: own += w.equipment[i].lives else: enemy += w.equipment[i].lives
            let want = expected(own, enemy, w.glory[side], w.glory[1-side], 5, 5, 10,
              w.endTick-w.tick, w.endTick)
            for i in 0..<ScoreboardBlockSize: require c[S+i] == want[i]
            for i in S..<ObservationSizeV3: require c[i] >= 0'f32 and c[i] <= 1'f32
            # Glory columns repeat v1's own-team / enemy-team glory columns 17 and 18.
            require c[S+2] == c[17] and c[S+3] == c[18]
            if own != enemy: sawDeficit = true
            if w.glory[0] != w.glory[1]: sawGloryGap = true
            inc compared
        for slot in 0..<Seats:
          trainingBotActions(w, slot, 2, actions)
          commands[slot] = decodeActions(w, slot, actions)
        w.step(commands)
    check compared > 4000
    check sawDeficit and sawGloryGap

  test "hand-set worlds: rules-43 glory config, a death, both sides, the last tick":
    configureGlory(parseGloryConfig(parseJson(
      """{"behind_lives": 5, "behind_lives_seconds": 3, "quiet_supplies": 25}""")))
    var w = newWorld(2026)
    w.pickups.setLen(0)
    check w.endTick == HeartMeterMatchTicks
    let red = firstSeat(0)
    let blue = firstSeat(1)
    # Start: 8 cogs x 4 lives a side, glory at the match length in seconds.
    let g0 = w.endTick div TickRate
    check w.block8(red) == expected(32, 32, g0, g0, 5, 3, 25, w.endTick, w.endTick)
    check w.block8(blue) == w.block8(red)
    # Hand-set glory and lives: each side reads its own first.
    w.glory = [412'i32, 77'i32]
    w.equipment[red].lives = 1
    w.equipment[red+2].lives = 0
    check w.teamLives(0) == 32-3-4 and w.teamLives(1) == 32
    check w.block8(red) == expected(25, 32, 412, 77, 5, 3, 25, w.endTick, w.endTick)
    check w.block8(blue) == expected(32, 25, 77, 412, 5, 3, 25, w.endTick, w.endTick)
    for slot in 0..<Seats: check w.block8(slot) == w.block8(team(slot))
    # A death costs one life on the victim's side, and the block sees it at once.
    w.cogs[blue].shield = 0
    w.damage(blue, -1, 10_000)
    check w.equipment[blue].lives == 3
    check w.block8(blue)[0] == 31'f32/32 and w.block8(red)[1] == 31'f32/32
    # The block's lives are the award's: at the next 3-second boundary the side behind is
    # paid 5 x (enemy lives - own lives), read straight off the block.
    let behindRed = int(round((w.block8(red)[1] - w.block8(red)[0])*32))
    check behindRed == 31-25
    let gloryBefore = w.glory
    w.idle(3*TickRate - w.tick.int)
    check w.glory[0] == gloryBefore[0] - 3 + 5*behindRed
    check w.glory[1] == gloryBefore[1] - 3
    check w.block8(red)[2] == float32(w.glory[0])/1000 and w.block8(blue)[3] == float32(w.glory[0])/1000
    # Near the end: one tick left, then none.
    w.tick = w.endTick - 1
    check w.block8(red)[7] == 1'f32/float32(w.endTick)
    w.tick = w.endTick
    check w.block8(red)[7] == 0
    # The defaults (no glory config): 1 per life, every 5 s, 10 for quiet supplies.
    configureGlory(DefaultGloryConfig)
    let d = w.block8(red)
    check d[4] == 0.1'f32 and d[5] == 5'f32/60 and d[6] == 0.1'f32
    # A shorter match: the clock is relative to its own end tick.
    var short = newWorld(7, 480)
    short.idle(120)
    check short.block8(3)[7] == 360'f32/480

  test "v3u<K>: v3 unchanged, then the K user inputs":
    var w = newWorld(9)
    w.idle(30)
    let inputs = [1500'i32, -700, 0, 1_000_000]
    var row: array[ObservationSizeV3 + 4, float32]
    encodeObservationInputs(w, 5, row, w.observedBodies(5), inputs, ocV3)
    let plain = w.v3(5)
    for i in 0..<ObservationSizeV3: check row[i] == plain[i]
    check row[ObservationSizeV3] == 1.5'f32 and row[ObservationSizeV3+1] == -0.7'f32
    check row[ObservationSizeV3+2] == 0 and row[ObservationSizeV3+3] == 1000
    # v2u<K> is unchanged: the default version is still v2.
    var row2: array[ObservationSizeV2 + 4, float32]
    var row2v: array[ObservationSizeV2 + 4, float32]
    encodeObservationInputs(w, 5, row2, w.observedBodies(5), inputs)
    encodeObservationInputs(w, 5, row2v, w.observedBodies(5), inputs, ocV2)
    check row2 == row2v
    for i in 0..<ObservationSizeV2: check row2[i] == row[i]
    expect ValueError: encodeObservationInputs(w, 5, row, w.observedBodies(5), inputs, ocV1)
    expect ValueError: encodeObservationInputs(w, 5, row2, w.observedBodies(5), inputs, ocV3)

  test "FFA-kin refuses v3: the encoder and the hosted loader":
    gameMode = gmFfaKin
    configureRules(44)
    let w = newWorld(4)
    var row: array[ObservationSizeV3, float32]
    var small: array[ScoreboardBlockSize, float32]
    expect ValueError: encodeObservation(w, 0, row, ocV3)
    expect ValueError: encodeScoreboardBlock(w, 0, small)
    let players = bundle(Act, ObservationContractV3Hash, ObservationSizeV3)
    for slot in 0..<Seats:
      check players[slot].failed
      check players[slot].neural.actor.isNil
    let inputs = bundle(InputsAct, V3UserInputsContractHashes[2], ObservationSizeV3 + 3, 3)
    for slot in 0..<Seats: check inputs[slot].failed
    gameMode = gmTeams

  test "hosted v3 and v3u<K> actors load and play; mismatches are refused":
    let players = bundle(Act, ObservationContractV3Hash, ObservationSizeV3)
    for slot in 0..<Seats:
      require not players[slot].failed
      check players[slot].neural.observationContract == ocV3
      check players[slot].neural.observation.len == ObservationSizeV3
    var w = newWorld(21)
    for tick in 0..<240:
      if w.winner != -1: break
      let commands = players.decide(w)
      for slot in 0..<Seats:
        require not players[slot].failed
        if w.cogs[slot].hp > 0:
          # The seat's observation is exactly the reference encoder's v3 row.
          let want = w.v3(slot)
          for i in 0..<ObservationSizeV3: require players[slot].neural.observation[i] == want[i]
      w.step(commands)
    # v3u3: the seat's user inputs follow v3's 514 floats, one tick late.
    let withInputs = bundle(InputsAct, V3UserInputsContractHashes[2], ObservationSizeV3 + 3, 3, "5, 6, 7")
    for slot in 0..<Seats:
      require not withInputs[slot].failed
      check withInputs[slot].neural.observationContract == ocV3
      check withInputs[slot].neural.observation.len == ObservationSizeV3 + 3
    var u = newWorld(22)
    var lastRun: array[LegacySeats, int] # the last tick the seat's script ran (-1: never)
    for slot in 0..<Seats: lastRun[slot] = -1
    for tick in 0..<120:
      if u.winner != -1: break
      let now = u.tick.int
      let commands = withInputs.decide(u)
      for slot in 0..<Seats:
        require not withInputs[slot].failed
        if u.cogs[slot].hp <= 0: continue
        let obs = withInputs[slot].neural.observation
        let want = u.v3(slot)
        for i in 0..<ObservationSizeV3: require obs[i] == want[i]
        # Input 0 is what the script set on its last run (init 5 before any); input 1 is
        # never written and keeps its init.
        let input0 = if lastRun[slot] < 0: 5'i32 else: int32(lastRun[slot]*3)
        require obs[ObservationSizeV3] == userInputFeature(input0)
        require obs[ObservationSizeV3+1] == userInputFeature(6)
        if lastRun[slot] < 0: require obs[ObservationSizeV3+2] == userInputFeature(7)
        lastRun[slot] = now
      u.step(commands)
    # Refused: a v3 actor of the wrong width, a v3u3 actor without manifest user_inputs,
    # a count that does not match, and a v2-width actor claiming v3u3.
    for players in [bundle(Act, ObservationContractV3Hash, ObservationSizeV2),
                    bundle(Act, V3UserInputsContractHashes[2], ObservationSizeV3 + 3),
                    bundle(InputsAct, V3UserInputsContractHashes[2], ObservationSizeV3 + 3, 2),
                    bundle(InputsAct, V3UserInputsContractHashes[2], ObservationSizeV2 + 3, 3)]:
      for slot in 0..<Seats: check players[slot].failed

proc ask(w: World, a, b: string): array[LegacySeats, (int32, int32)] =
  ## Runs `walkTo(a, b)` for every seat on this world; every seat's goal.
  let path = getTempDir() / ("paintbot-scoreboard-probe-" & $getCurrentProcessId() & ".bas")
  writeFile(path, "walkTo(" & a & ", " & b & ")\n")
  defer: removeFile(path)
  let players = loadBots(@[BotGroup(path: path, count: Seats)])
  let commands = players.decide(w)
  for slot in 0..<Seats:
    doAssert not players[slot].failed, players[slot].error
    result[slot] = (commands[slot].goal.x, commands[slot].goal.z)

suite "BASIC scoreboard builtins":
  setup:
    visionRulesVersion = 43
    replayRulesVersion = 43
    gameMode = gmTeams
    configureMap("")
    configureVision("")
    configureGlory(DefaultGloryConfig)
  teardown:
    gameMode = gmTeams
    configureGlory(DefaultGloryConfig)

  test "teamLives, awardBehind and awardBehindSeconds read the scoreboard":
    configureGlory(parseGloryConfig(parseJson("""{"behind_lives": 5, "behind_lives_seconds": 7}""")))
    var w = newWorld(2026)
    w.equipment[firstSeat(0)].lives = 1
    w.equipment[firstSeat(1)].lives = 2
    let lives = w.ask("teamLives(0)", "teamLives(1)")
    let awards = w.ask("awardBehind()", "awardBehindSeconds()")
    let invalid = w.ask("teamLives(2)", "teamLives(-1)")
    for slot in 0..<Seats:
      check lives[slot] == (29'i32, 30'i32)
      check awards[slot] == (5'i32, 7'i32)
      check invalid[slot] == (-1'i32, -1'i32)
    # They are the v3 block's values, unscaled.
    let b = w.block8(0)
    check b[0] == 29'f32/32 and b[1] == 30'f32/32 and b[4] == 5'f32/10 and b[5] == 7'f32/60
    configureGlory(DefaultGloryConfig)
    for slot, v in w.ask("awardBehind()", "awardBehindSeconds()"): check v == (1'i32, 5'i32)

  test "FFA-kin reads -1":
    gameMode = gmFfaKin
    configureRules(44)
    let w = newWorld(2026)
    for v in w.ask("teamLives(0)", "teamLives(1)"): check v == (-1'i32, -1'i32)
    for v in w.ask("awardBehind()", "awardBehindSeconds()"): check v == (-1'i32, -1'i32)
    gameMode = gmTeams
