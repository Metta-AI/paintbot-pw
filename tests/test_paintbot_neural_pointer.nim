## Action contract ffa.v2 pointer (with observation contract ffa.v2): heads sized by the match,
## the objective and aim heads decoded through the tick's row -> entity map, the hosted seat at
## any seat count (one layout-word model.bin plays Heartland and a whole 50-seat Heartland Big
## match within its budget), and the pairing and option rules at load.
import std/[unittest, os, random, options, strutils]
import polyworld/cli
import ../examples/paintbot/[sim, kinship, bots, neural_contract, neural_actor, neural_host]
import paintbot_pwnet2_fixture

const NeuralSource = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
"""

proc place(w: var World, slot: int, p: Point) =
  w.cogs[slot].hp = FfaMaxHp.int32
  w.cogs[slot].shield = 0
  w.cogs[slot].pos = p
  w.cogs[slot].goal = p
  w.equipment[slot].lives = 1

proc near(p: Point, dx = 0, dz = 0): Point = point(p.x.int+dx, p.z.int+dz)

proc handSet(): World =
  ## Seat 0 faces +x; seats 1 (+300) and 3 (+300, +300) in view, seat 2 behind; others out.
  gameMode = gmFfaKin
  kinshipOverride = some(kinshipFor(klCousins, 11))
  result = newWorld(2026, 0)
  kinshipOverride = none(Kinship)
  for i in 0..<result.cogs.len:
    result.cogs[i].hp = 0
    result.equipment[i].lives = 0
  let spot = result.greatHearts[0].pos.near(0, 600)
  result.place(0, spot)
  result.place(1, spot.near(300))
  result.place(2, spot.near(-300))
  result.place(3, spot.near(300, 300))
  result.cogs[0].aim = spot.near(1000)

proc playBundle(model: string, seats: int, map: string, layout: KinLayout, ticks: int32): (seq[Bot], World) =
  ## Every seat plays the bundle for a whole match of `ticks` ticks.
  configureSeats(seats)
  configureMap(map)
  gameMode = gmFfaKin
  kinLayoutPin = some(layout)
  let path = getTempDir() / ("paintbot-pointer-" & $seats & ".bas")
  writeFile(path, NeuralSource)
  writeFile(path & ".model.bin", model)
  defer:
    removeFile(path)
    removeFile(path & ".model.bin")
  for i in 0..<MaxSeats: peakNativeWork[i] = 0
  var players = loadBots(@[BotGroup(path: path, count: seats)])
  var w = newWorld(2026, ticks)
  while w.winner == -1 and w.tick < w.endTick:
    let commands = players.decide(w)
    deliverSpeech(w)
    w.step(commands)
  (players, w)

suite "Action contract ffa.v2 pointer":
  setup:
    visionRulesVersion = LiveRules
    kinshipOverride = none(Kinship)
    kinLayoutPin = none(KinLayout)
  teardown:
    gameMode = gmTeams
    configureSeats(LegacySeats)
    configureMap("")
    kinLayoutPin = none(KinLayout)

  test "id, hash, heads and pointer targets follow the match layout":
    check ActionContractFfaV2Pointer == "paintbot-pw.rules48.action.ffa.v2.pointer"
    check actionContractVersion(ActionContractFfaV2PointerHash) == acFfaV2Pointer
    check actionContractHash(acFfaV2Pointer) == ActionContractFfaV2PointerHash
    check acFfaV2Pointer.int == 3
    let small = ffaV2Layout(16, 10)
    check pointerHeads(small) == @[21, 24, 2, 2, 2]
    check pointerTargets(small) == [21 + 9, 9, 19, 9]
    let big = ffaV2Layout(50, 100)
    check pointerHeads(big) == @[111, 58, 2, 2, 2]
    check pointerTargets(big) == [111 + 9, 9, 109, 9]

  test "objective and aim indices decode through the tick's rows":
    var w = handSet()
    let rows = w.ffaV2Rows(0)
    check rows.cogs == @[1, 3]
    let h = w.controlHearts.len
    var memory: PointerMemory
    memory.resetPointerMemory(w.cogs.len)
    let me = w.cogs[0].pos
    proc decode(a: array[5, int32]): Command = decodePointerActions(w, 0, a, rows, memory)
    # Objective: stay, compass, a control heart row, a great heart row.
    check decode([0'i32, 0, 0, 0, 0]).goal == me
    check decode([1'i32, 0, 0, 0, 0]).goal == point(me.x.int+200, me.z.int)
    for k in [0, 3, h-1]:
      check decode([int32(9+k), 0, 0, 0, 0]).goal == w.controlHearts[rows.hearts[k]].pos
    check decode([int32(9+h), 0, 0, 0, 0]).goal == w.greatHearts[rows.greats[0]].pos
    check decode([int32(9+h+1), 0, 0, 0, 0]).goal == w.greatHearts[rows.greats[1]].pos
    # Aim: keep, compass, cog row k (standing still: its position), a row past the seen cogs.
    check decode([0'i32, 0, 0, 0, 0]).aim == w.cogs[0].aim
    check decode([0'i32, 3, 0, 0, 0]).aim == point(me.x.int, clamp(me.z.int+5000, minZ(), maxZ()))
    check decode([0'i32, 9, 1, 0, 0]).aim == w.cogs[1].pos
    check decode([0'i32, 10, 1, 0, 0]).aim == w.cogs[3].pos
    check decode([0'i32, 11, 1, 0, 0]).aim == w.cogs[0].aim
    let c = decode([0'i32, 9, 1, 1, 1])
    check c.shoot and c.chargeGrenade and c.sneak and c.walk
    expect ValueError: discard decode([int32(pointerHeads(w.ffaV2Layout)[0]), 0, 0, 0, 0])
    expect ValueError: discard decode([0'i32, int32(8 + w.cogs.len), 0, 0, 0])
    # A dead seat idles.
    w.cogs[0].hp = 0
    check not decode([9'i32, 9, 1, 0, 0]).walk

  test "the aim leads a cog seen moving last tick (contract v2's rule), keyed by seat id":
    var w = handSet()
    var memory: PointerMemory
    memory.resetPointerMemory(w.cogs.len)
    let rows0 = w.ffaV2Rows(0)
    memory.recordPointerMemory(w, rows0)
    w.tick += 1
    w.cogs[3].pos = w.cogs[3].pos.near(10, -4)   # seat 3 moved (10, -4) in one tick
    let rows = w.ffaV2Rows(0)
    let k = rows.cogs.find(3)
    check k >= 0
    let aim = decodePointerActions(w, 0, [0'i32, int32(9+k), 1, 0, 0], rows, memory).aim
    check aim == w.cogs[3].pos.near(60, -24)

  test "one layout-word model.bin plays Heartland (16) and a whole Heartland Big match (50) within budget":
    var r = initRand(95)
    let model = r.pointerModel()
    for (seats, map, layout, ticks) in [(16, "", klCousins, 240'i32), (50, "big-twin-mesas", klTribes, 600'i32)]:
      let (players, w) = playBundle(model, seats, map, layout, ticks)
      check w.cogs.len == seats and w.tick == ticks
      let l = ffaV2Layout(w)
      let actor = loadActor(model, actorLayout(l, pointerHeads(l), pointerTargets(l)))
      check actor.inputSize == l.size
      check actor.operationCount <= neuralOperationBudget(seats)
      for slot in 0..<seats:
        check not players[slot].failed
        check players[slot].neural.pointer
        check peakNativeWork[slot] == actor.operationCount
        check players[slot].neural.telemetry(peakNativeWork[slot], ticks) ==
          "neural: peak_ops=" & $actor.operationCount & " budget=" & $neuralOperationBudget(seats) &
          " model=pwnet2-l11-s0 ticks=" & $ticks
      # The seats moved: the pointer heads decoded into real goals.
      var moved = 0
      for slot in 0..<seats:
        if w.cogs[slot].goal != w.spawnAnchor[slot]: inc moved
      check moved > 0

  test "pairing, options and width checks at load":
    var r = initRand(96)
    configureSeats(16)
    gameMode = gmFfaKin
    let l = matchLayout()
    let heads = pointerHeads(l)
    var total = 0
    for x in heads: total += x
    let path = getTempDir() / "paintbot-pointer-load.bas"
    writeFile(path, NeuralSource)
    defer:
      removeFile(path)
      removeFile(path & ".model.bin")
      if fileExists(path & ".neural.json"): removeFile(path & ".neural.json")
    # A fixed-width DENSE model for this layout loads.
    writeFile(path & ".model.bin", encode2(l.size, heads, [r.dense(l.size, total)],
      ObservationContractFfaV2Hash, ActionContractFfaV2PointerHash))
    let seat = loadNeuralSeat(path, 0)
    check seat.pointer and seat.heads == heads and seat.observation.len == l.size and seat.logits.len == total
    # ffa.v2 with action contract v1, and v1 with the pointer contract, are refused.
    writeFile(path & ".model.bin", encode2(l.size, heads, [r.dense(l.size, total)],
      ObservationContractFfaV2Hash, ActionContractHash))
    expect ValueError: discard loadNeuralSeat(path, 0)
    writeFile(path & ".model.bin", encode2(ObservationSize, ActionSizes, [r.dense(ObservationSize, LogitSize)],
      ObservationContractHash, ActionContractFfaV2PointerHash))
    expect ValueError: discard loadNeuralSeat(path, 0)
    # A model for another layout is refused with the layout named.
    writeFile(path & ".model.bin", encode2(l.size + 44, heads, [r.dense(l.size + 44, total)],
      ObservationContractFfaV2Hash, ActionContractFfaV2PointerHash))
    try:
      discard loadNeuralSeat(path, 0)
      check false
    except ValueError as e:
      check "ffa.v2 layout" in e.msg
    # decoder.sampling is allowed; any other decoder option is refused.
    writeFile(path & ".model.bin", encode2(l.size, heads, [r.dense(l.size, total)],
      ObservationContractFfaV2Hash, ActionContractFfaV2PointerHash))
    writeFile(path & ".neural.json", """{"schema": "paintbot-neural-basic/2", "observation_contract": """" &
      ObservationContractFfaV2Hash & """", "action_contract": """" & ActionContractFfaV2PointerHash &
      """", "decoder": {"sampling": {"mode": "categorical", "temperature": 0.5}}}""")
    check loadNeuralSeat(path, 0).sampling.enabled
    writeFile(path & ".neural.json", """{"schema": "paintbot-neural-basic/2", "observation_contract": """" &
      ObservationContractFfaV2Hash & """", "action_contract": """" & ActionContractFfaV2PointerHash &
      """", "decoder": {"aim_snap": {}}}""")
    expect ValueError: discard loadNeuralSeat(path, 0)
