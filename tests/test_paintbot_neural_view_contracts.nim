## The SeatView neural contracts (docs/neural/seat-view.md): observation teams.view.1 (512
## floats, the teams game, team 1 mirrored) with action contract teams.view.1, and observation
## ffa.view.1 (FFA-kin, width per match) with action contract ffa.view.1 pointer. Ids and
## hashes, sizes and layouts, the retired contracts, the teams.view.1u<K> family, the ffa.view.1
## row order (exactly nearAgents(20000)'s), the kin mask, and the hosted loader at 16 and 50
## seats. Column-by-column SeatView parity is tests/test_paintbot_seat_view_parity.nim's.
## Synthetic actors (seeded random weights) only.
import std/[unittest, os, random, options, strutils, math]
import polyworld/cli
import ../examples/paintbot/[sim, kinship, bots, seat_view, contract_hash, neural_contract, neural_actor,
  neural_host]
import paintbot_pwnet2_fixture

const PlayersDir = currentSourcePath.parentDir / ".." / "examples" / "paintbot" / "players"

proc policy(decode: string): string =
  ## A full neural policy.bas: observe, infer, select, then the reference decode.
  "paintbot_observe(neuralObservation())\n" &
    "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
    "neuralSample()\n" & readFile(PlayersDir / decode)

proc place(w: var World, slot: int, p: Point) =
  w.cogs[slot].hp = FfaMaxHp.int32
  w.cogs[slot].shield = 0
  w.cogs[slot].pos = p
  w.cogs[slot].goal = p
  w.equipment[slot].lives = 1

proc near(p: Point, dx = 0, dz = 0): Point = point(p.x.int+dx, p.z.int+dz)

proc handSet(k: Kinship): World =
  ## FFA-kin, seats 0..5 alive: seat 0 faces +x; 1 (+300), 3 (+300, +300), 5 (+300, -300; the
  ## same distance as 3) and 4 (+600) in view, 2 behind; every other seat out of the match.
  gameMode = gmFfaKin
  kinshipOverride = some(k)
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
  result.place(4, spot.near(600))
  result.place(5, spot.near(300, -300))
  result.cogs[0].aim = spot.near(1000)
  result.cogs[1].hp = 4
  result.controlHearts[3].owner = 1
  result.controlHearts[4].owner = 3
  result.controlHearts[5].owner = 0
  result.controlHearts[7].owner = 2

proc ffaObservation(w: World, slot: int, mask = 0'u32): seq[float32] =
  beginViews(w)
  let v = seatView(slot)
  result = newSeq[float32](v.ffaViewLayout.size)
  encodeFfaView(v, result, ffaViewRows(v), mask)

proc checkRowsAreNearAgents(w: World, slot: int) =
  ## ffaViewRows' agents are exactly nearAgents(20000)'s list, entry by entry, and the
  ## observation's cog rows follow it; control hearts are nearest first, ties by index.
  let o = w.ffaObservation(slot)
  let v = seatView(slot)
  let rows = ffaViewRows(v)
  let l = v.ffaViewLayout
  let n = v.nearAgents(NearMaxRadius).int
  check rows.agents.len == n and n <= l.cogRows
  let bodies = nearAgentsFor(w, slot, NearMaxRadius)
  check bodies.len == n
  beginViews(w)
  let again = seatView(slot)
  discard again.nearAgents(20000)
  for k in 0..<n:
    let a = rows.agents[k]
    check a.identity == again.nearAgentId(k) and a.identity == bodies[k].identity.int32
    check a.x == again.nearAgentX(k) and a.z == again.nearAgentY(k)
    check a.hp == again.nearAgentHp(k) and a.team == again.nearAgentTeam(k)
    let at = l.cogOffset + k*FfaCogWidth
    check o[at] == 1 and o[at+43] == float32(a.identity)/float32(MaxSeats-1)
  for k in n..<l.cogRows:
    for c in 0..<FfaCogWidth: check o[l.cogOffset + k*FfaCogWidth + c] == 0
  check rows.hearts.len == l.heartRows
  let me = Point(x: again.selfX, z: again.selfY)
  for k in 1..<rows.hearts.len:
    let a = rows.hearts[k-1]
    let b = rows.hearts[k]
    let da = distance2(me, Point(x: again.controlX(a), z: again.controlY(a)))
    let db = distance2(me, Point(x: again.controlX(b), z: again.controlY(b)))
    check da < db or (da == db and a < b)

var bundleCount = 0
proc bundle(source, model: string, manifest = "", count = Seats): seq[Bot] =
  ## Every seat runs `source` over `model` (and `manifest`, when given).
  inc bundleCount
  let path = getTempDir() / ("paintbot-view-contracts-" & $getCurrentProcessId() & "-" & $bundleCount & ".bas")
  writeFile(path, source)
  writeFile(path & ".model.bin", model)
  if manifest.len > 0: writeFile(path & ".neural.json", manifest)
  defer:
    removeFile(path)
    removeFile(path & ".model.bin")
    if manifest.len > 0: removeFile(path & ".neural.json")
  loadBots(@[BotGroup(path: path, count: count)])

proc loadError(model: string, manifest = ""): string =
  ## loadNeuralSeat's refusal of `model` (and `manifest`); "" when it loads.
  inc bundleCount
  let path = getTempDir() / ("paintbot-view-load-" & $getCurrentProcessId() & "-" & $bundleCount & ".bas")
  writeFile(path, "")
  writeFile(path & ".model.bin", model)
  if manifest.len > 0: writeFile(path & ".neural.json", manifest)
  defer:
    removeFile(path)
    removeFile(path & ".model.bin")
    if manifest.len > 0: removeFile(path & ".neural.json")
  try:
    discard loadNeuralSeat(path, 0)
    ""
  except ValueError as e:
    e.msg

proc manifestFor(observation, action: string, decoder = ""): string =
  "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" & observation &
    "\", \"action_contract\": \"" & action & "\"" & (if decoder.len > 0: ", \"decoder\": " & decoder else: "") & "}"

proc teamsDense(r: var Rand, inputs = TeamsViewSize, observation = ObservationContractTeamsView1Hash,
    action = ActionContractTeamsView1Hash): string =
  encode2(inputs, ActionSizes, [r.dense(inputs, LogitSize, bias = true)], observation, action)

proc playBundle(model: string, seats: int, map: string, layout: KinLayout, ticks: int32): (seq[Bot], World) =
  ## Every seat plays the ffa.view.1 bundle for a whole match of `ticks` ticks.
  configureSeats(seats)
  configureMap(map)
  gameMode = gmFfaKin
  kinLayoutPin = some(layout)
  for i in 0..<MaxSeats: peakNativeWork[i] = 0
  var players = bundle(policy("neural_decode_ffa.bas"), model, count = seats)
  var w = newWorld(2026, ticks)
  while w.winner == -1 and w.tick < w.endTick:
    let commands = players.decide(w)
    deliverSpeech(w)
    w.step(commands)
  (players, w)

suite "SeatView neural contracts":
  setup:
    visionRulesVersion = LiveRules
    gameMode = gmTeams
    kinshipOverride = none(Kinship)
    kinLayoutPin = none(KinLayout)
  teardown:
    gameMode = gmTeams
    configureSeats(LegacySeats)
    configureMap("")
    kinshipOverride = none(Kinship)
    kinLayoutPin = none(KinLayout)

  test "ids and hashes: every hash is the SHA-256 of its id":
    check sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check ObservationContractTeamsView1 == "paintbot-pw.teams.view.1"
    check ActionContractTeamsView1 == "paintbot-pw.teams.view.1.action.51-25-2-2-2"
    check ObservationContractFfaView1 == "paintbot-pw.ffa.view.1"
    check ActionContractFfaView1Pointer == "paintbot-pw.ffa.view.1.action.pointer"
    check ObservationContractTeamsView1Hash == sha256Hex(ObservationContractTeamsView1)
    check ActionContractTeamsView1Hash == sha256Hex(ActionContractTeamsView1)
    check ObservationContractFfaView1Hash == sha256Hex(ObservationContractFfaView1)
    check ActionContractFfaView1PointerHash == sha256Hex(ActionContractFfaView1Pointer)
    for h in [ObservationContractTeamsView1Hash, ActionContractTeamsView1Hash, ObservationContractFfaView1Hash,
        ActionContractFfaView1PointerHash]:
      check h.len == 64 and h == h.toLowerAscii
    check ocTeamsView1.int == 201 and ocFfaView1.int == 202
    check acTeamsView1.int == 11 and acFfaView1Pointer.int == 12
    for version in ObservationContractVersion:
      check observationContractVersion(observationContractHash(version)) == version
      check observationContractHash(version) == sha256Hex(observationContractId(version))
    for version in ActionContractVersion:
      check actionContractVersion(actionContractHash(version)) == version
      check actionContractHash(version) == sha256Hex(actionContractId(version))
    check pairedAction(ocTeamsView1) == acTeamsView1 and pairedAction(ocFfaView1) == acFfaView1Pointer
    try:
      discard observationContractVersion(sha256Hex("paintbot-pw.no.such.contract"))
      check false
    except ValueError as e:
      check "unknown neural observation contract" in e.msg
    try:
      discard actionContractVersion(ObservationContractTeamsView1Hash)
      check false
    except ValueError as e:
      check "unknown neural action contract" in e.msg

  test "sizes: teams.view.1 is 512; ffa.view.1 follows the match at 16 and 50 seats, cog rows capped at 64":
    check TeamsViewSize == 512 and observationSize(ocTeamsView1) == 512
    check TeamsHeartOffset == 25 and TeamsIdentityOffset == 125 and TeamsPickupOffset == 285
    check TeamsSoundOffset == 445 and TeamsProbeOffset == 485
    check ActionSizes == [51, 25, 2, 2, 2] and LogitSize == 82
    expect ValueError: discard observationSize(ocFfaView1)
    let small = ffaViewLayout(16, 10)
    check small.seats == 16 and small.hearts == 10
    check small.cogOffset == 24 and small.cogRows == 15
    check small.heartOffset == 24 + 15*44 and small.heartRows == 10
    check small.greatOffset == small.heartOffset + 10*12 and small.greatRows == 2
    check small.size == 24 + 15*44 + 10*12 + 2*12
    let big = ffaViewLayout(50, 100)
    check big.cogRows == 49 and big.size == 24 + 49*44 + 100*12 + 2*12
    check ffaViewLayout(65, 10).cogRows == 64 and ffaViewLayout(66, 10).cogRows == 64
    check ffaViewLayout(MaxSeats, 0).cogRows == NearMaxAgents
    check ffaViewLayout(MaxSeats, 0).size == 24 + 64*44 + 2*12
    expect ValueError: discard ffaViewLayout(1, 10)
    expect ValueError: discard ffaViewLayout(MaxSeats+1, 10)
    expect ValueError: discard ffaViewLayout(16, -1)
    # The live match's layout, and every seat's observation fills exactly that width.
    for (seats, map, layout) in [(16, "", klCousins), (50, "big-twin-mesas", klTribes)]:
      configureSeats(seats)
      configureMap(map)
      gameMode = gmFfaKin
      kinLayoutPin = some(layout)
      let w = newWorld(2026, 0)
      check w.cogs.len == seats
      if map != "": check w.controlHearts.len == 100
      let l = ffaViewLayout(seats, w.controlHearts.len)
      check matchLayout() == l
      check l.cogRows == seats - 1
      beginViews(w)
      for slot in 0..<seats:
        let v = seatView(slot)
        check v.ffaViewLayout == l
        var o = newSeq[float32](l.size)
        encodeObservation(v, ocFfaView1, o, rows = ffaViewRows(v))
        for x in o: check x.classify notin {fcNan, fcInf, fcNegInf}
        var short = newSeq[float32](l.size - 1)
        expect ValueError: encodeObservation(v, ocFfaView1, short, rows = ffaViewRows(v))

  test "actorLayout, pointerHeads and pointerTargets follow the layout":
    let small = ffaViewLayout(16, 10)
    check pointerHeads(small) == @[21, 24, 2, 2, 2]
    check pointerTargets(small) == [21 + 9, 9, 19, 9]
    let big = ffaViewLayout(50, 100)
    check pointerHeads(big) == @[111, 58, 2, 2, 2]
    check pointerTargets(big) == [111 + 9, 9, 109, 9]
    let capped = ffaViewLayout(100, 10)
    check pointerHeads(capped) == @[21, 9 + 64, 2, 2, 2]
    for l in [small, big, capped]:
      let heads = pointerHeads(l)
      let targets = pointerTargets(l)
      let a = actorLayout(l, heads, targets)
      check a.present and a.inputs == l.size and a.heads == heads
      var total = 0
      for h in heads: total += h
      check a.outputs == total
      check a.sections[0] == LayoutSection(offset: l.cogOffset, rows: l.cogRows, width: FfaCogWidth, target: targets[0])
      check a.sections[1] == LayoutSection(offset: l.heartOffset, rows: l.heartRows, width: FfaHeartWidth,
        target: targets[1])
      check a.sections[2] == LayoutSection(offset: l.greatOffset, rows: l.greatRows, width: FfaGreatWidth,
        target: targets[2])
      check a.sections[3] == LayoutSection(offset: l.heartOffset, rows: l.heartRows + l.greatRows,
        width: FfaHeartWidth, target: targets[3])
      # The targets are each section's row 0 in the logits: cog rows in the aim head, hearts in
      # the objective head (control rows, then great rows).
      check targets[0] == heads[0] + PointerAimFirstRow
      check targets[2] == targets[1] + l.heartRows
      check a.sections[2].offset == a.sections[1].offset + l.heartRows*FfaHeartWidth
    check actorLayout(small, pointerHeads(small)).sections[0].target == -1

  test "retired contracts are recognised and refused for BASIC parity":
    check RetiredObservationContractIds == ["paintbot-pw.rules37.obs.v1.float448",
      "paintbot-pw.rules37.obs.v2.float506", "paintbot-pw.rules43.obs.v3.float514",
      "paintbot-pw.rules40.obs.ffa.v1.float810", "paintbot-pw.rules48.obs.ffa.v2"]
    check RetiredActionContractIds == ["paintbot-pw.rules37.action.v1.51-25-2-2-2",
      "paintbot-pw.rules37.action.v2.51-25-2-2-2", "paintbot-pw.rules48.action.ffa.v2.pointer"]
    var retired: seq[string]
    for id in RetiredObservationContractIds: retired.add sha256Hex(id)
    for k in [1, 2, 16, 64, 128]:
      retired.add sha256Hex("paintbot-pw.rules39.obs.v2u" & $k)
      retired.add sha256Hex("paintbot-pw.rules43.obs.v3u" & $k)
    for hash in retired:
      check retiredContract(hash)
      check userInputsFromHash(hash) == 0
      try:
        discard observationContractVersion(hash)
        check false
      except ValueError as e:
        check "retired for BASIC parity" in e.msg
    for id in RetiredActionContractIds:
      let hash = sha256Hex(id)
      check retiredContract(hash)
      try:
        discard actionContractVersion(hash)
        check false
      except ValueError as e:
        check "retired for BASIC parity" in e.msg
    for hash in [ObservationContractTeamsView1Hash, ObservationContractFfaView1Hash, ActionContractTeamsView1Hash,
        ActionContractFfaView1PointerHash, userInputsContractHash(3), sha256Hex("paintbot-pw.no.such.contract"),
        sha256Hex("paintbot-pw.rules39.obs.v2u129")]:
      check not retiredContract(hash)
    # The hosted loader refuses a model naming one, by name, before anything else.
    var r = initRand(7)
    for (observation, action, inputs) in [
        (sha256Hex(RetiredObservationContractIds[1]), ActionContractTeamsView1Hash, 506),
        (sha256Hex("paintbot-pw.rules43.obs.v3u4"), ActionContractTeamsView1Hash, 518),
        (ObservationContractTeamsView1Hash, sha256Hex(RetiredActionContractIds[1]), TeamsViewSize)]:
      check "retired for BASIC parity" in loadError(r.teamsDense(inputs, observation, action))

  test "teams.view.1u<K>: hashes, K, and the K user inputs after the 512 floats":
    for k in [1, 2, 7, 64, MaxUserInputs]:
      check userInputsContractId(k) == "paintbot-pw.teams.view.1u" & $k
      check userInputsContractHash(k) == sha256Hex("paintbot-pw.teams.view.1u" & $k)
      check userInputsFromHash(userInputsContractHash(k)) == k
      expect ValueError: discard observationContractVersion(userInputsContractHash(k))
    check userInputsFromHash(ObservationContractTeamsView1Hash) == 0
    check userInputsFromHash(ObservationContractFfaView1Hash) == 0
    expect ValueError: discard userInputsContractHash(0)
    expect ValueError: discard userInputsContractHash(MaxUserInputs+1)
    check clampUserInput(5_000_000) == UserInputLimit and clampUserInput(-5_000_000) == -UserInputLimit
    check userInputFeature(1500) == 1.5'f32
    let w = newWorld(3)
    beginViews(w)
    let v = seatView(4)
    var plain: array[TeamsViewSize, float32]
    encodeTeamsView(v, plain)
    var o = newSeq[float32](TeamsViewSize + 3)
    encodeObservation(v, ocTeamsView1, o, [5'i32, -2000, 0])
    check o[0 ..< TeamsViewSize] == @plain
    check o[TeamsViewSize] == 0.005'f32 and o[TeamsViewSize+1] == -2'f32 and o[TeamsViewSize+2] == 0
    expect ValueError: encodeObservation(v, ocTeamsView1, o, [5'i32, 6])
    var wide = newSeq[float32](TeamsViewSize + MaxUserInputs + 1)
    expect ValueError: encodeObservation(v, ocTeamsView1, wide, newSeq[int32](MaxUserInputs + 1))
    gameMode = gmFfaKin
    let f = newWorld(3)
    beginViews(f)
    let fv = seatView(0)
    # ffa.view.1 takes user inputs only as ffa.view.1u<K> (its own test below): the width must
    # be the layout's size + K exactly.
    var fo = newSeq[float32](fv.ffaViewLayout.size + 1)
    expect ValueError: encodeObservation(fv, ocFfaView1, fo, [1'i32, 2], rows = ffaViewRows(fv))
    expect ValueError: encodeObservation(fv, ocFfaView1, fo, rows = ffaViewRows(fv))

  test "ffa.view.1u<K>: ids, hashes, K, layout, and the K user inputs after the match's ffa.view.1 floats":
    for k in [1, 2, 5, 7, 64, MaxUserInputs]:
      check userInputsContractId(k, ocFfaView1) == "paintbot-pw.ffa.view.1u" & $k
      check userInputsContractHash(k, ocFfaView1) == sha256Hex("paintbot-pw.ffa.view.1u" & $k)
      check userInputsFromHash(userInputsContractHash(k, ocFfaView1), ocFfaView1) == k
      check userInputsContract(userInputsContractHash(k, ocFfaView1)) == (ocFfaView1, k)
      check userInputsContract(userInputsContractHash(k)) == (ocTeamsView1, k)
      # The two families are disjoint, and neither is a base contract or retired.
      check userInputsFromHash(userInputsContractHash(k, ocFfaView1)) == 0
      check userInputsFromHash(userInputsContractHash(k), ocFfaView1) == 0
      check not retiredContract(userInputsContractHash(k, ocFfaView1))
      expect ValueError: discard observationContractVersion(userInputsContractHash(k, ocFfaView1))
    check userInputsContract(ObservationContractFfaView1Hash) == (ocTeamsView1, 0)
    check userInputsContract(ObservationContractTeamsView1Hash) == (ocTeamsView1, 0)
    check userInputsFromHash(ObservationContractFfaView1Hash, ocFfaView1) == 0
    expect ValueError: discard userInputsContractHash(0, ocFfaView1)
    expect ValueError: discard userInputsContractHash(MaxUserInputs+1, ocFfaView1)
    # The base contracts' hashes are unchanged (the ids are).
    check ObservationContractFfaView1Hash == sha256Hex("paintbot-pw.ffa.view.1")
    check ObservationContractTeamsView1Hash == sha256Hex("paintbot-pw.teams.view.1")
    # Layout: the sections are ffa.view.1's; the input count adds K.
    for l in [ffaViewLayout(16, 10), ffaViewLayout(50, 100)]:
      let a = actorLayout(l, pointerHeads(l), pointerTargets(l), 5)
      let b = actorLayout(l, pointerHeads(l), pointerTargets(l))
      check a.inputs == l.size + 5 and b.inputs == l.size
      check a.sections == b.sections and a.heads == b.heads and a.outputs == b.outputs
      # Layout word section 2 offset + 24 names the first user input.
      check resolveWord(a, layoutWord(2, 1, 24), "") == l.size.uint32
      check resolveWord(a, layoutWord(LayoutGlobal, 0), "") == uint32(l.size + 5)
    # Every seat at 16 and 50 seats: the first size floats are encodeFfaView's, byte for byte
    # (with and without the kin mask); then float32(v) / 1000 of each (clamped) input.
    for (seats, map, layout) in [(16, "", klCousins), (50, "big-twin-mesas", klTribes)]:
      configureSeats(seats)
      configureMap(map)
      gameMode = gmFfaKin
      kinLayoutPin = some(layout)
      let w = newWorld(2026, 0)
      let l = ffaViewLayout(seats, w.controlHearts.len)
      beginViews(w)
      let inputs = [5'i32, -2000, 0, 1_500_000, -1_000_000]
      for slot in 0..<seats:
        let v = seatView(slot)
        for mask in [0'u32, FfaObsMaskKin]:
          var plain = newSeq[float32](l.size)
          encodeFfaView(v, plain, ffaViewRows(v), mask)
          var o = newSeq[float32](l.size + inputs.len)
          encodeObservation(v, ocFfaView1, o, inputs, rows = ffaViewRows(v), mask = mask)
          for i in 0..<l.size: check cast[uint32](o[i]) == cast[uint32](plain[i])
          check o[l.size] == 0.005'f32 and o[l.size+1] == -2'f32 and o[l.size+2] == 0
          check o[l.size+3] == userInputFeature(1_500_000) and o[l.size+4] == -1000'f32
          # K = 0 is ffa.view.1 itself.
          var none0 = newSeq[float32](l.size)
          encodeObservation(v, ocFfaView1, none0, rows = ffaViewRows(v), mask = mask)
          check none0 == plain
      let v0 = seatView(0)
      var wide = newSeq[float32](l.size + MaxUserInputs + 1)
      expect ValueError: encodeObservation(v0, ocFfaView1, wide, newSeq[int32](MaxUserInputs + 1), rows = ffaViewRows(v0))

  test "encodeFfaView rows are nearAgents(20000)'s list, entry by entry":
    let k = kinshipFor(klStrangers, 3)
    var w = handSet(k)
    check w.visible(0, 1) and w.visible(0, 3) and w.visible(0, 4) and w.visible(0, 5) and not w.visible(0, 2)
    beginViews(w)
    let rows = ffaViewRows(seatView(0))
    # Nearest first; 3 and 5 tie on distance and go by identity.
    var ids: seq[int32]
    for a in rows.agents: ids.add a.identity
    check ids == @[1'i32, 3, 5, 4]
    w.checkRowsAreNearAgents(0)
    # Two control hearts at the same distance: the lower index first.
    let me = w.cogs[0].pos
    w.controlHearts[8].pos = me.near(0, 900)
    w.controlHearts[2].pos = me.near(0, -900)
    beginViews(w)
    let again = ffaViewRows(seatView(0))
    let a = again.hearts.find(2)
    check a >= 0 and again.hearts.find(8) == a + 1
    w.checkRowsAreNearAgents(0)
    # Whole matches at 16 and 50 seats, every seat, after some play.
    for (seats, map, layout) in [(16, "", klCousins), (50, "big-twin-mesas", klTribes)]:
      configureSeats(seats)
      configureMap(map)
      gameMode = gmFfaKin
      kinLayoutPin = some(layout)
      var m = newWorld(2026, 0)
      let players = loadBots(@[BotGroup(path: PlayersDir / "base.bas", count: seats)])
      for tick in 0..<60:
        let commands = players.decide(m)
        deliverSpeech(m)
        m.step(commands)
      var seen = 0
      for slot in 0..<seats:
        m.checkRowsAreNearAgents(slot)
        beginViews(m)
        seen += ffaViewRows(seatView(slot)).agents.len
      check seen > 0

  test "the kin mask zeroes the kin columns and nothing else":
    # Clones: every seat the observer sees is kin (r = 1), so the unmasked kin columns read it.
    let k = kinshipFor(klClones, 7)
    let w = handSet(k)
    let plain = w.ffaObservation(0)
    let masked = w.ffaObservation(0, FfaObsMaskKin)
    beginViews(w)
    let v = seatView(0)
    let l = v.ffaViewLayout
    let rows = ffaViewRows(v)
    var kinColumns = @[11]
    for kk in 0..<l.cogRows: kinColumns.add l.cogOffset + kk*FfaCogWidth + 37
    var readsKin = false
    for kk, i in rows.hearts:
      let at = l.heartOffset + kk*FfaHeartWidth + 5
      let owner = w.controlHearts[i].owner
      if owner < 0: check masked[at] == -1 and plain[at] == -1
      elif owner == 0: check masked[at] == 1 and plain[at] == 1
      else:
        check masked[at] == 0
        kinColumns.add at
    for c in kinColumns:
      check masked[c] == 0
      if plain[c] != 0: readsKin = true
    check readsKin   # the unmasked observation did read kin somewhere
    for c in 0..<l.size:
      if c notin kinColumns: check masked[c] == plain[c]

  test "teams.view.1 in team 1 is mirrored":
    var w = newWorld(11)
    let cx = (minX() + maxX()) div 2
    let cz = (minZ() + maxZ()) div 2
    # Seat 0 (team 0) and seat 1 (team 1) at mirror-image spots, each with an enemy 300 ahead
    # (+x for seat 0, -x for seat 1) and 200 to its own left, facing it.
    let a = point(cx - 3000, cz - 1000)
    let b = point(2*cx - a.x.int, 2*cz - a.z.int)
    w.cogs[0].pos = a
    w.cogs[0].aim = a.near(1000)
    w.cogs[3].pos = a.near(300, 200)
    w.cogs[1].pos = b
    w.cogs[1].aim = b.near(-1000)
    w.cogs[2].pos = b.near(-300, -200)
    for s in 4..<Seats: w.cogs[s].pos = point(cx, cz - 6000 + 100*s)
    check w.visible(0, 3) and w.visible(1, 2)
    beginViews(w)
    var o0, o1: array[TeamsViewSize, float32]
    encodeTeamsView(seatView(0), o0)
    encodeTeamsView(seatView(1), o1)
    check mapFlip(0) == 1 and mapFlip(1) == -1
    let spanX = float32(maxX() - minX())
    let spanZ = float32(maxZ() - minZ())
    check o0[0] == float32(a.x - cx)/spanX and o0[1] == float32(a.z - cz)/spanZ
    check o1[0] == o0[0] and o1[1] == o0[1]
    let e0 = TeamsIdentityOffset + 3*TeamsIdentityWidth
    let e1 = TeamsIdentityOffset + 2*TeamsIdentityWidth
    check o0[e0] == 1 and o1[e1] == 1
    check o0[e0+1] == 300'f32/spanX and o0[e0+2] == 200'f32/spanZ
    check o1[e1+1] == o0[e0+1] and o1[e1+2] == o0[e0+2]
    check o0[e0+3] == -1 and o1[e1+3] == -1   # both enemies
    # Control hearts: dx, dz mirrored; the heart at the centre of the map reads the same
    # distance on both sides for mirror-image seats.
    for i in 0..<min(TeamsHeartRows, w.controlHearts.len):
      let p = w.controlHearts[i].pos
      let at = TeamsHeartOffset + i*TeamsHeartWidth
      check o0[at+1] == float32(p.x - a.x)/spanX and o0[at+2] == float32(p.z - a.z)/spanZ
      check o1[at+1] == float32(p.x - b.x) * -1/spanX and o1[at+2] == float32(p.z - b.z) * -1/spanZ
    # Probe k = 1 (compass +x) is 200 world units in -x for team 1.
    let v1 = seatView(1)
    let own1 = v1.terrainHeight(b.x.int, b.z.int)
    check o1[TeamsProbeOffset + 3 + 2] ==
      float32(v1.terrainHeight(b.x.int - 200, b.z.int) - own1) / TerrainHeightScale
    check o1[TeamsProbeOffset + 3 + 1] == float32(v1.waterAt(b.x.int - 200, b.z.int))
    # FFA-kin mirrors no seat.
    gameMode = gmFfaKin
    check mapFlip(1) == 1

  test "the hosted loader plays teams.view.1 PWNET001 and PWNET002 actors":
    var r = initRand(41)
    let (pwnet1, _, _, _) = r.pwnet001(TeamsViewSize, 64)
    for model in [pwnet1, r.teamsDense()]:
      let players = bundle(policy("neural_decode.bas"), model)
      for slot in 0..<Seats:
        require not players[slot].failed
        check players[slot].neural.observationContract == ocTeamsView1
        check players[slot].neural.contract == acTeamsView1
        check not players[slot].neural.pointer
        check players[slot].neural.observation.len == TeamsViewSize
        check players[slot].neural.actor.operationCount <= neuralOperationBudget(Seats)
      var w = newWorld(21)
      var moved = 0
      for tick in 0..<120:
        if w.winner != -1: break
        let commands = players.decide(w)
        beginViews(w)
        for slot in 0..<Seats:
          require not players[slot].failed
          if w.cogs[slot].hp > 0:
            # The seat observed exactly its view's teams.view.1.
            var want: array[TeamsViewSize, float32]
            encodeTeamsView(seatView(slot), want)
            check players[slot].neural.observation == @want
            if commands[slot].walk and commands[slot].goal != w.cogs[slot].pos: inc moved
        deliverSpeech(w)
        w.step(commands)
      check moved > 0
    # teams.view.1u3 with its manifest user inputs loads; without them it is refused.
    let withInputs = r.teamsDense(TeamsViewSize + 3, userInputsContractHash(3))
    let base = manifestFor(userInputsContractHash(3), ActionContractTeamsView1Hash)
    let inputsManifest = base[0 ..< base.len-1] & ", \"user_inputs\": {\"count\": 3, \"init\": [1, 2, 3]}}"
    let inputs = bundle(policy("neural_decode.bas"), withInputs, inputsManifest)
    for slot in 0..<Seats:
      require not inputs[slot].failed
      check inputs[slot].neural.observation.len == TeamsViewSize + 3
    check "needs manifest user_inputs" in loadError(withInputs)
    # Wrong width, the other action contract, and the teams contract in FFA-kin are refused.
    check "dimensions" in loadError(r.teamsDense(TeamsViewSize + 1))
    check "cannot be played under action contract" in loadError(r.teamsDense(action = ActionContractFfaView1PointerHash))
    gameMode = gmFfaKin
    check "teams game only" in loadError(r.teamsDense())

  test "one ffa.view.1 layout-word model plays Heartland (16) and a whole Heartland Big match (50) within budget":
    var r = initRand(95)
    let model = r.pointerModel()
    for (seats, map, layout, ticks) in [(16, "", klCousins, 240'i32), (50, "big-twin-mesas", klTribes, 600'i32)]:
      let (players, w) = playBundle(model, seats, map, layout, ticks)
      check w.cogs.len == seats and w.tick == ticks
      let l = ffaViewLayout(seats, w.controlHearts.len)
      let actor = loadActor(model, actorLayout(l, pointerHeads(l), pointerTargets(l)))
      check actor.inputSize == l.size and actor.headSizes == pointerHeads(l)
      check actor.operationCount <= neuralOperationBudget(seats)
      for slot in 0..<seats:
        check not players[slot].failed
        check players[slot].neural.pointer
        check players[slot].neural.observationContract == ocFfaView1
        check players[slot].neural.contract == acFfaView1Pointer
        check players[slot].neural.heads == pointerHeads(l)
        check players[slot].neural.observation.len == l.size
        check peakNativeWork[slot] == actor.operationCount
        check players[slot].neural.telemetry(peakNativeWork[slot], ticks) ==
          "neural: peak_ops=" & $actor.operationCount & " budget=" & $neuralOperationBudget(seats) &
          " model=pwnet2-l11-s0 ticks=" & $ticks
      # The seats moved: the reference decoder turned the pointer heads into real goals.
      var moved = 0
      for slot in 0..<seats:
        if w.cogs[slot].pos != w.spawnAnchor[slot]: inc moved
      check moved > 0

  test "ffa.view.1 pairing, options and width checks at load":
    var r = initRand(96)
    configureSeats(16)
    gameMode = gmFfaKin
    let l = matchLayout()
    let heads = pointerHeads(l)
    var total = 0
    for x in heads: total += x
    let dense = encode2(l.size, heads, [r.dense(l.size, total)], ObservationContractFfaView1Hash,
      ActionContractFfaView1PointerHash)
    check loadError(dense) == ""
    # ffa.view.1 with the teams action contract, and teams.view.1 with the pointer contract.
    check "cannot be played under action contract" in loadError(encode2(l.size, heads, [r.dense(l.size, total)],
      ObservationContractFfaView1Hash, ActionContractTeamsView1Hash))
    check "cannot be played under action contract" in loadError(encode2(TeamsViewSize, ActionSizes,
      [r.dense(TeamsViewSize, LogitSize)], ObservationContractTeamsView1Hash, ActionContractFfaView1PointerHash))
    # A model for another layout is refused with the layout named.
    check "ffa.view.1 layout" in loadError(encode2(l.size + 44, heads, [r.dense(l.size + 44, total)],
      ObservationContractFfaView1Hash, ActionContractFfaView1PointerHash))
    # decoder.sampling is allowed; joint sampling and the forbid are not; retired options say so.
    check loadError(dense, manifestFor(ObservationContractFfaView1Hash, ActionContractFfaView1PointerHash,
      """{"sampling": {"mode": "categorical", "temperature": 0.5}}""")) == ""
    check "not available under action contract ffa.view.1 pointer" in loadError(dense, manifestFor(
      ObservationContractFfaView1Hash, ActionContractFfaView1PointerHash, """{"forbid_objectives": [9]}"""))
    for option in RetiredDecoderOptions:
      check "retired for BASIC parity" in loadError(dense, manifestFor(ObservationContractFfaView1Hash,
        ActionContractFfaView1PointerHash, "{\"" & option & "\": {}}"))
    # ffa.view.1 in the teams game is refused.
    gameMode = gmTeams
    configureSeats(LegacySeats)
    check "FFA-kin only" in loadError(dense)

  test "ffa.view.1u<K>: the hosted loader, manifest checks, one tick of latency; zero inputs play ffa.view.1's match":
    const K = 5
    var r = initRand(97)
    configureSeats(16)
    gameMode = gmFfaKin
    kinLayoutPin = some(klCousins)
    let l = matchLayout()
    let heads = pointerHeads(l)
    var total = 0
    for x in heads: total += x
    let contract = userInputsContractHash(K, ocFfaView1)
    # The ffa.view.1 model, and its ffa.view.1u5 twin: the same weights for the first l.size
    # inputs, K more (nonzero) weights per output for the user inputs.
    let baseDense = r.dense(l.size, total, bias = true)
    var twinDense = Spec(code: 1, params: [uint32(l.size + K), total.uint32, 1, 0, 0, 0, 0, 0])
    let extra = r.weights(total*K, 0.5)
    for o in 0..<total:
      for i in 0..<l.size: twinDense.tensors.add baseDense.tensors[o*l.size + i]
      for j in 0..<K: twinDense.tensors.add extra[o*K + j]
    for o in 0..<total: twinDense.tensors.add baseDense.tensors[total*l.size + o]
    let baseModel = encode2(l.size, heads, [baseDense], ObservationContractFfaView1Hash, ActionContractFfaView1PointerHash)
    let twinModel = encode2(l.size + K, heads, [twinDense], contract, ActionContractFfaView1PointerHash)
    proc inputsManifest(count: int, init: string): string =
      let base = manifestFor(contract, ActionContractFfaView1PointerHash)
      base[0 ..< base.len-1] & ", \"user_inputs\": {\"count\": " & $count & ", \"init\": " & init & "}}"
    let manifest = inputsManifest(K, "[0, 0, 0, 0, 0]")
    # Load checks.
    check loadError(twinModel, manifest) == ""
    check "observation contract ffa.view.1u5 needs manifest user_inputs" in loadError(twinModel)
    check "user_inputs.count does not match observation contract ffa.view.1u5" in
      loadError(twinModel, inputsManifest(4, "[0, 0, 0, 0]"))
    check "user_inputs need observation contract ffa.view.1u<K>" in loadError(baseModel, manifestFor(
      ObservationContractFfaView1Hash, ActionContractFfaView1PointerHash)[0 ..< ^1] &
      ", \"user_inputs\": {\"count\": 1, \"init\": [0]}}")
    check "ffa.view.1 layout" in loadError(encode2(l.size + K - 1, heads, [r.dense(l.size + K - 1, total)], contract,
      ActionContractFfaView1PointerHash), manifest)
    check "ffa.view.1 layout" in loadError(encode2(l.size, heads, [r.dense(l.size, total)], contract,
      ActionContractFfaView1PointerHash), manifest)
    check "cannot be played under action contract" in loadError(encode2(l.size + K, ActionSizes,
      [r.dense(l.size + K, LogitSize)], contract, ActionContractTeamsView1Hash), manifest)
    # (1) Zero user inputs (what a deployed policy.bas writes): the twin plays ffa.view.1's
    # match tick for tick: the same state hashes, the same observation bytes before the tail.
    proc run(model, man, pre: string, ticks: int): (seq[uint32], seq[seq[seq[float32]]], seq[seq[seq[int32]]]) =
      var players = bundle(pre & policy("neural_decode_ffa.bas"), model, man, count = 16)
      var w = newWorld(2026, ticks.int32)
      var hashes: seq[uint32]
      var observed: seq[seq[seq[float32]]]
      var inputs: seq[seq[seq[int32]]]
      while w.winner == -1 and w.tick < w.endTick:
        let commands = players.decide(w)
        var obsTick: seq[seq[float32]]
        var inputTick: seq[seq[int32]]
        for slot in 0..<16:
          doAssert not players[slot].failed
          obsTick.add (if w.cogs[slot].hp > 0: players[slot].neural.observation else: @[])
          inputTick.add players[slot].neural.userInputs
        deliverSpeech(w)
        w.step(commands)
        hashes.add w.stateHash()
        observed.add obsTick
        inputs.add inputTick
      (hashes, observed, inputs)
    let zeroWrites = "neuralInput(0, 0)\nneuralInput(4, 0)\n"
    let (baseHashes, baseObs, _) = run(baseModel, "", "", 240)
    let (twinHashes, twinObs, _) = run(twinModel, manifest, zeroWrites, 240)
    check baseHashes.len == 240 and twinHashes == baseHashes
    var compared = 0
    for t in 0..<baseObs.len:
      for slot in 0..<16:
        if baseObs[t][slot].len == 0: continue
        require twinObs[t][slot].len == l.size + K
        for i in 0..<l.size: require cast[uint32](twinObs[t][slot][i]) == cast[uint32](baseObs[t][slot][i])
        for j in 0..<K: require twinObs[t][slot][l.size + j] == 0
        inc compared
    check compared > 1000
    # (2) Inputs written by policy.bas reach the net one tick later, clamped, persisting
    # across ticks; the prefix is still the seat's own ffa.view.1 of the tick.
    let writes = "neuralInput(0, worldTick)\nneuralInput(1, selfX)\nneuralInput(2, 0 - selfY)\n" &
      "neuralInput(3, 2000000)\nif worldTick = 0 then\n  neuralInput(4, 777)\nend if\n"
    let (liveHashes, liveObs, liveInputs) = run(twinModel, inputsManifest(K, "[1, 2, 3, 4, 5]"), writes, 240)
    check liveHashes.len == 240
    var tails = 0
    for t in 0..<liveObs.len:
      for slot in 0..<16:
        if liveObs[t][slot].len == 0: continue
        let o = liveObs[t][slot]
        let want = if t == 0: @[1'i32, 2, 3, 4, 5] else: liveInputs[t-1][slot]
        for j in 0..<K: require o[l.size + j] == userInputFeature(want[j])
        if t > 0 and liveInputs[t-1][slot][0] == int32(t-1): inc tails
    check tails > 1000
    for slot in 0..<16:
      check liveInputs[^1][slot][3] == UserInputLimit and liveInputs[^1][slot][4] == 777
    # The net reads them: the live run diverges from the zero-input run.
    check liveHashes != twinHashes
    kinLayoutPin = none(KinLayout)
    # ffa.view.1u5 in the teams game is refused.
    gameMode = gmTeams
    configureSeats(LegacySeats)
    check "FFA-kin only" in loadError(twinModel, manifest)

  test "ffa.view.1u<K>: a layout-word model loads at 16 and 50 seats with the input count + K":
    var r = initRand(98)
    const K = 16
    let contract = userInputsContractHash(K, ocFfaView1)
    let model = r.pointerModel(contract)
    let base = manifestFor(contract, ActionContractFfaView1PointerHash)
    let manifest = base[0 ..< base.len-1] & ", \"user_inputs\": {\"count\": 16, \"init\": [" &
      newSeq[int](K).join(", ") & "]}}"
    for (seats, map, layout) in [(16, "", klCousins), (50, "big-twin-mesas", klTribes)]:
      configureSeats(seats)
      configureMap(map)
      gameMode = gmFfaKin
      kinLayoutPin = some(layout)
      let l = matchLayout()
      let actor = loadActor(model, actorLayout(l, pointerHeads(l), pointerTargets(l), K))
      check actor.inputSize == l.size + K
      check actor.operationCount <= neuralOperationBudget(seats)
      let players = bundle(policy("neural_decode_ffa.bas"), model, manifest, count = seats)
      for slot in 0..<seats:
        require not players[slot].failed
        check players[slot].neural.observationContract == ocFfaView1
        check players[slot].neural.observation.len == l.size + K
        check players[slot].neural.userInputs == newSeq[int32](K)
      var w = newWorld(2026, 60)
      while w.winner == -1 and w.tick < w.endTick:
        let commands = players.decide(w)
        for slot in 0..<seats: require not players[slot].failed
        deliverSpeech(w)
        w.step(commands)
      check w.tick == 60
