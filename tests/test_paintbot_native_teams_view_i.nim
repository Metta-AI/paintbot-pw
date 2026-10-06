## Observation contract teams.view.1i (207): teams.view.1p's 755 floats unchanged, then at 755 the held true cooldown /
## 288 (the same S2 value 751 shows / 72; the rules-49 sniper's slow shot is 3 x 96 = 288), then the 81-float rules-49
## ITEM BLOCK (neural_contract.encodeItemBlock), S0 and BASIC perception: 756 hasSniper, 757 misting, 758 mistingTicks
## / 1440, 759 the heal phase, 760 radar, 761 radarTicks / 1440, 762 radarBoost; 763 + 2j the misting / radar flags
## of identity j; 795 + 7r the r-th visible windex-mister / sniper / radar pickup (visible, dx, dz, one-hot kind,
## index / 31). Through the native ABI:
## - sizes, hashes, user-input variants; 208 refused;
## - on rules-49 games (base.bas seats and sticky random heads that walk to the items, the island, twin-mesas and crater,
##   own and team vision) a 207 handle beside a 206 handle: the first 755 columns byte-equal; 755 = 751's held value
##   / 288; the item block equal to a reference built from pw_seat_items (the world's raw fields), the BASIC
##   builtins and pw_pickups filtered by what the seat sees; dead rows zero; coverage of every field counted;
## - stepped: the sniper's 96 and 288 at 755, the mister's and radar's last ticks and the heal phase in the block;
## - the hosted host's 207 rows equal the native env's through an item-heavy game;
## - zero-column widening: a 206 bundle and its 207 copy with 82 zero columns at 755 play identically;
## - pw_world_save / load continue the rows exactly.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, random, importutils, os, algorithm, math]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, neural_contract, neural_actor, native_env, seat_view, bots, oracle, contract_hash]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] =
  (if s.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr s[0]) else: nil)
privateAccess(NativeEnv)

const
  W = 837
  P = 755             # teams.view.1p's width: 755 is the cooldown / 288 column
  B = 756             # the item block's first column
  Root = currentSourcePath().parentDir.parentDir
  Decoder = staticRead("../examples/paintbot/players/neural_decode.bas")
  Head = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), " &
    "neuralLogits(), neuralState())\nneuralSample()\n"

proc worldOf(h: pointer): ptr World = addr cast[ptr NativeEnv](h).world
proc setVision(h: pointer, team: bool) =
  cast[ptr NativeEnv](h).vision = team
  cast[ptr NativeEnv](h).nextVision = team
proc bits(x: float32): uint32 = cast[uint32](x)
proc baseScript(): string = readFile(Root / "coworld/paintbot/players/base.bas")

proc seatItems(h: pointer): seq[float32] =
  result = newSeq[float32](Seats*SeatItemFloats)
  doAssert pw_seat_items(h, fbuf(result)) == 0

proc allPickups(h: pointer): seq[float32] =
  let n = pw_pickups(h, nil, 0)
  result = newSeq[float32](max(1, n)*PickupFloats)
  doAssert pw_pickups(h, fbuf(result), n) == n
  result.setLen(n*PickupFloats)

proc itemReference(h: pointer, w: World, s: int): array[ItemBlockWidth, float32] =
  ## Seat s's item block from pw_seat_items (the world's raw fields, tests/test_paintbot_native_items.nim), the BASIC
  ## identity builtins and pw_pickups filtered by pickupVisible, with the frame formulas of teams.view.1's doc.
  if w.cogs[s].hp <= 0: return
  let it = seatItems(h)
  let o = s*SeatItemFloats
  result[0] = it[o]
  result[1] = it[o+1]
  result[2] = it[o+2] / 1440'f32
  result[3] = (if it[o+1] != 0: float32(it[o+3].int32) / float32(360'i32) else: 0'f32)
  result[4] = it[o+4]
  result[5] = it[o+5] / 1440'f32
  result[6] = it[o+6]
  beginViews(w)
  let v = seatView(s)
  for j in 0..<LegacySeats:
    result[7 + 2*j] = v.playerMisting(j).float32
    result[8 + 2*j] = v.playerRadar(j).float32
  let rows = allPickups(h)
  let flip = (if team(s) == 0: 1'f32 else: -1'f32)
  let spanX = float32(v.mapMaxX - v.mapMinX)
  let spanZ = float32(v.mapMaxY - v.mapMinY)
  var r = 0
  for i in 0..<rows.len div PickupFloats:
    let kind = rows[i*PickupFloats+2].int
    if kind < 5 or v.pickupVisible(i) == 0 or r >= 6: continue
    let q = 39 + 7*r
    result[q] = 1
    result[q+1] = float32(rows[i*PickupFloats].int32 - w.cogs[s].pos.x) * flip / spanX
    result[q+2] = float32(rows[i*PickupFloats+1].int32 - w.cogs[s].pos.z) * flip / spanZ
    result[q+3 + (kind - 5)] = 1
    result[q+6] = float32(i) / 31
    inc r

type Coverage = object
  rows, alive, dead, sniper, cdOver72, misting, mistLast, radar, radarLast, boosted, otherMisting, otherRadar: int
  late: array[3, int]   # visible late-pickup rows by kind
proc `$`(c: Coverage): string =
  "rows " & $c.rows & " (alive " & $c.alive & ", dead " & $c.dead & "); sniper " & $c.sniper & " (755 > 72/288: " &
    $c.cdOver72 & "), misting " & $c.misting & " (last " & $c.mistLast & "), radar " & $c.radar & " (last " &
    $c.radarLast & "), boosted " & $c.boosted & ", others misting / radar " & $c.otherMisting & " / " & $c.otherRadar &
    "; late pickup rows mister / sniper / radar " & $c.late

proc checkRow(c: var Coverage, h: pointer, w: World, s: int, row, row206: openArray[float32], what: string) =
  inc c.rows
  for i in 0..<P:
    if bits(row[i]) != bits(row206[i]):
      echo what, ": PREFIX tick ", w.tick, " seat ", s, " column ", i, ": ", row[i], " vs 206 ", row206[i]
      doAssert false
  if w.cogs[s].hp <= 0:
    for i in P..<W:
      if row[i] != 0:
        echo what, ": DEAD ROW tick ", w.tick, " seat ", s, " column ", i, " = ", row[i]
        doAssert false
    inc c.dead
    return
  inc c.alive
  let cd = int32(round(row206[751] * 72))
  if bits(row[P]) != bits(float32(cd) / 288'f32):
    echo what, ": 755 tick ", w.tick, " seat ", s, ": ", row[P], " want ", cd, " / 288"
    doAssert false
  if cd > 72: inc c.cdOver72
  let want = itemReference(h, w, s)
  for k in 0..<ItemBlockWidth:
    if bits(row[B + k]) != bits(want[k]):
      echo what, ": ITEM tick ", w.tick, " seat ", s, " column ", B + k, ": ", row[B + k], " want ", want[k]
      doAssert false
  if want[0] == 1: inc c.sniper
  if want[1] == 1: inc c.misting
  if want[1] == 1 and want[2] == 0: inc c.mistLast
  if want[4] == 1: inc c.radar
  if want[4] == 1 and want[5] == 0: inc c.radarLast
  if want[6] == 1: inc c.boosted
  for j in 0..<LegacySeats:
    if j == s: continue
    if want[7 + 2*j] == 1: inc c.otherMisting
    if want[8 + 2*j] == 1: inc c.otherRadar
  for r in 0..<6:
    for k in 0..2:
      if want[39 + 7*r + 3 + k] == 1: inc c.late[k]

proc add(a: var Coverage, b: Coverage) =
  a.rows += b.rows; a.alive += b.alive; a.dead += b.dead; a.sniper += b.sniper; a.cdOver72 += b.cdOver72
  a.misting += b.misting; a.mistLast += b.mistLast; a.radar += b.radar; a.radarLast += b.radarLast
  a.boosted += b.boosted; a.otherMisting += b.otherMisting; a.otherRadar += b.otherRadar
  for k in 0..2: a.late[k] += b.late[k]

type GameSpec = object
  seed, map: int32
  team, scripted: bool
  ticks, fire: int

proc lateIndices(w: World): seq[int] =
  for i, p in w.pickups:
    if p.kind >= misterPickup: result.add i

proc game(g: GameSpec): Coverage =
  ## A rules-49 game on a 206 and a 207 handle side by side.
  var r = initRand(g.seed.int)
  let a = pw_create_observation(g.seed, 0, 206)
  let b = pw_create_observation(g.seed, 0, 207)
  doAssert a != nil and b != nil
  defer: pw_destroy(a); pw_destroy(b)
  for h in [a, b]:
    doAssert pw_set_rules(h, 49) == 0 and pw_set_map(h, g.map) == 0
    setVision(h, g.team)
    doAssert pw_reset(h, g.seed, 0) == 0
  if g.scripted:
    let source = baseScript()
    for s in 0..<Seats:
      for h in [a, b]: doAssert pw_set_seat_script(h, s.cint, cbuf(source), source.len.int32) == 0
  var oa = newSeq[float32](Seats*P)
  var ob = newSeq[float32](Seats*W)
  var ra, rb = newSeq[float32](Seats)
  var actions = newSeq[int32](Seats*5)
  var hold = newSeq[int](Seats)
  var rewards, terminals = newSeq[float32](Seats)
  let w = worldOf(b)
  let late = lateIndices(w[])
  doAssert late.len == 6
  for step in 0..<g.ticks:
    doAssert pw_observe(a, fbuf(oa), fbuf(ra)) == 0
    doAssert pw_observe(b, fbuf(ob), fbuf(rb)) == 0
    for s in 0..<Seats:
      result.checkRow(b, w[], s, ob.toOpenArray(s*W, s*W + W - 1), oa.toOpenArray(s*P, s*P + P - 1),
        "seed " & $g.seed)
    if not g.scripted:
      for s in 0..<Seats:
        # sticky random heads: mostly a rules-49 item, else a heart or anywhere; fire on one tick in `fire`
        if hold[s] == 0:
          actions[s*5] = case r.rand(3)
            of 0, 1: int32(11 + late[r.rand(late.len - 1)])
            of 2: int32(1 + r.rand(9))
            else: int32(r.rand(50))
          hold[s] = 1 + r.rand(300)
        dec hold[s]
        actions[s*5+1] = int32(r.rand(24))
        actions[s*5+2] = int32(g.fire > 0 and r.rand(g.fire - 1) == 0)
        actions[s*5+3] = 0
        actions[s*5+4] = 0
    let rc1 = pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals))
    let rc2 = pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals))
    doAssert rc1 == rc2
    doAssert pw_state_hash(a) == pw_state_hash(b)
    if rc1 != 0 or terminals[0] > 0: break

# ---------------------------------------------------------------------------------------------------------------------
# PWNET001 actors for the zero-column widening check (seeded random weights).
proc u32(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)
const Hidden = 64
proc actorFile(inputs: int, contract: string, encoder, rest: seq[float32]): string =
  result = "PWNET001"
  let n = inputs*Hidden + 3*Hidden*Hidden + LogitSize*Hidden
  doAssert encoder.len == inputs*Hidden and rest.len == n - inputs*Hidden
  for x in [1, inputs, Hidden, LogitSize, ActionSizes.len, n]: result.u32(x.uint32)
  result.add contract
  result.add ActionContractTeamsView1Hash
  for x in ActionSizes: result.u32(x.uint32)
  for x in encoder: result.u32(cast[uint32](x))
  for x in rest: result.u32(cast[uint32](x))

type HostedRun = object
  hashes: seq[uint32]
  logits: seq[seq[seq[float32]]]

proc hosted(policy, model, manifest: string, seed: int32, ticks: int, policySeats: set[int8]): HostedRun =
  let path = getTempDir()/("paintbot-view-i-" & $getCurrentProcessId() & ".bas")
  writeFile(path, policy)
  writeFile(path & ".model.bin", model)
  writeFile(path & ".neural.json", manifest)
  defer:
    for suffix in ["", ".model.bin", ".neural.json"]: removeFile(path & suffix)
  resetOracle()
  var players = newSeq[Bot](Seats)
  let neural = loadBots(@[BotGroup(path: path, count: Seats)])
  let plain = loadBots(@[BotGroup(path: Root / "coworld/paintbot/players/base.bas", count: Seats)])
  for slot in 0..<Seats: players[slot] = if slot.int8 in policySeats: neural[slot] else: plain[slot]
  var w = newWorld(seed, ticks.int32)
  while w.tick < ticks and w.winner == -1:
    var alive: array[LegacySeats, bool]
    for slot in 0..<Seats: alive[slot] = w.cogs[slot].hp > 0
    let commands = players.decide(w)
    deliverSpeech(w)
    var logits = newSeq[seq[float32]](Seats)
    for slot in 0..<Seats:
      if slot.int8 notin policySeats: continue
      doAssert not players[slot].failed, players[slot].error
      if alive[slot]: logits[slot] = players[slot].neural.logits
    w.step(commands)
    result.hashes.add w.stateHash()
    result.logits.add logits

suite "Observation contract teams.view.1i (207)":
  configureRules(NativeRules)

  test "sizes, hashes, user-input variants; 201 .. 206 unchanged; 208 refused":
    check TeamsViewISize == 837 and ItemBlockWidth == 81 and TeamsViewPSize == 755
    check ItemCooldownScale == 288 and 3*SniperCooldownTicks == 288 and 3*FireCooldownTicks <= 288
    check ItemTicksScale == 1440 and MisterTicks == 1440 and RadarTicks == 1440 and MisterHealScale == MisterHealTicks
    check FirstLatePickupKind == ord(misterPickup) and ord(sniperPickup) == 6 and ord(radarPickup) == 7
    check ObservationContractTeamsView1iHash == sha256Hex("paintbot-pw.teams.view.1i")
    check observationContractVersion(ObservationContractTeamsView1iHash) == ocTeamsView1i
    check observationContractId(ocTeamsView1i) == "paintbot-pw.teams.view.1i"
    check observationSize(ocTeamsView1i) == 837
    check pw_observation_size_for(207) == 837 and pw_observation_size_for(206) == 755 and
      pw_observation_size_for(205) == 751 and pw_observation_size_for(208) == -1
    let h = pw_create_observation(1, 600, 207)
    require h != nil
    defer: pw_destroy(h)
    check pw_create_observation(1, 600, 208) == nil
    check pw_handle_observation_size(h) == 837 and pw_observation_contract(h) == 207
    var hex: array[65, char]
    check pw_observation_contract_hash(207, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
    check $cast[cstring](addr hex[0]) == ObservationContractTeamsView1iHash
    check pw_observation_contract_hash(208, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == -1
    for v in 201'i32..206'i32:
      check pw_observation_contract_hash(v, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
      check $cast[cstring](addr hex[0]) == observationContractHash(ObservationContractVersion(v))
    let hk = pw_create_observation_inputs_v(1, 600, 207, 109)
    require hk != nil
    defer: pw_destroy(hk)
    check pw_handle_observation_size(hk) == 837 + 109 and pw_handle_user_inputs(hk) == 109
    check pw_create_observation_inputs_v(1, 600, 208, 43) == nil
    for k in [1'i32, 109, 256]:
      check pw_user_inputs_contract_hash_v(207, k, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
      check $cast[cstring](addr hex[0]) == userInputsContractHash(k.int, ocTeamsView1i)
      check userInputsContractHash(k.int, ocTeamsView1i) == sha256Hex("paintbot-pw.teams.view.1iu" & $k)
    for k in [0'i32, 257]:
      check pw_user_inputs_contract_hash_v(207, k, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == -1
    check pw_user_inputs_contract_hash_v(208, 1, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == -1
    check userInputsContract(userInputsContractHash(109, ocTeamsView1i)) == (ocTeamsView1i, 109)
    check pairs(ocTeamsView1i, acTeamsView1) and pairs(ocTeamsView1i, acTeamsView1Raw)
    check pairedAction(ocTeamsView1i) == acTeamsView1
    check ocTeamsView1i in TeamsObservationContracts and ocTeamsView1i in HistoryObservationContracts
    check not retiredContract(ObservationContractTeamsView1iHash)
    check pw_set_game_mode(h, 1) == -1   # the teams game only

  test "the first 755 equal a 206 handle's, 755 is 751's held cooldown / 288, the item block equals the reference":
    var total: Coverage
    let specs = [
      GameSpec(seed: 71, map: -1, scripted: true, ticks: 2400),
      GameSpec(seed: 72, map: -1, ticks: 2400, fire: 3),
      GameSpec(seed: 73, map: 0, team: true, ticks: 2000, fire: 4),
      GameSpec(seed: 74, map: 3, scripted: true, ticks: 2400),
      GameSpec(seed: 75, map: 3, ticks: 2000, fire: 2)]
    for g in specs:
      checkpoint "seed " & $g.seed
      total.add game(g)
    echo "  ", total
    check total.alive > 50000 and total.dead > 1000
    check total.sniper > 1000 and total.misting > 1000 and total.radar > 1000 and total.boosted > 1000
    check total.otherMisting > 100 and total.otherRadar > 100
    check total.late[0] > 100 and total.late[1] > 100 and total.late[2] > 100

  test "stepped: the sniper's 96 and 288 at 755 (held, S2); the mister's and radar's last ticks in the block":
    let h = pw_create_observation(81, 0, 207)
    require h != nil
    defer: pw_destroy(h)
    require pw_set_rules(h, 49) == 0 and pw_set_map(h, -1) == 0 and pw_reset(h, 81, 0) == 0
    let w = worldOf(h)
    for s in 0..<Seats: w.cogs[s].shield = 0
    var ob = newSeq[float32](Seats*W)
    var rs = newSeq[float32](Seats)
    var actions = newSeq[int32](Seats*5)
    var rewards, terminals = newSeq[float32](Seats)
    proc stepObserve() =
      doAssert pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      doAssert pw_observe(h, fbuf(ob), fbuf(rs)) == 0
    proc give(seat: int, kind: PickupKind) =
      w.pickups.add Pickup(pos: w.cogs[seat].pos, kind: kind)
      stepObserve()
      w.pickups.setLen(w.pickups.len - 1)
    give(0, sniperPickup)
    check ob[B] == 1
    let source = "shootAt(selfX + 400, selfY)\n"
    require pw_set_seat_script(h, 0, cbuf(source), source.len.int32) == 0
    var seen: seq[float32]
    for t in 0..<200:
      stepObserve()
      seen.add ob[P]
    check (96'f32 / 288'f32) in seen and max(seen) == 96'f32 / 288'f32
    seen.setLen(0)
    for t in 0..<300:
      w.equipment[0].armor = 3
      stepObserve()
      seen.add ob[P]
      check bits(ob[P]) == bits(float32(int32(round(ob[751] * 72))) / 288'f32)
    check 1'f32 in seen and max(seen) == 1
    # the mister on seat 2, the radar on seat 4 (seat 6, a teammate, beside it)
    let spot = w.cogs[4].pos
    w.cogs[6].pos = Point(x: spot.x + 60, z: spot.z); w.cogs[6].goal = w.cogs[6].pos
    give(2, misterPickup)
    give(4, radarPickup)
    var mistLast, radarLast = false
    for t in 0..<1500:
      let m = ob[2*W + B ..< 2*W + B + 7]
      let r = ob[4*W + B ..< 4*W + B + 7]
      if m[1] == 1 and m[2] == 0: mistLast = true
      if m[1] == 1: check bits(m[3]) == bits(float32(int32(round(m[2] * 1440)) mod 360) / 360'f32)
      if r[4] == 1:
        check r[6] == 1 and ob[6*W + B + 6] == 1   # the carrier and its teammate are boosted
        if r[5] == 0: radarLast = true
      if m[1] == 0 and r[4] == 0 and t > 0: break
      stepObserve()
    check mistLast and radarLast

  test "native env and hosted host give the same rows through an item-heavy rules-49 game":
    let manifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": """" &
      ObservationContractTeamsView1iHash & """", "action_contract": """" & ActionContractTeamsView1Hash & "\"}"
    let h = pw_create_observation(91, 0, 207)
    require h != nil
    defer: pw_destroy(h)
    require pw_set_rules(h, 49) == 0 and pw_set_map(h, -1) == 0 and pw_reset(h, 91, 1500) == 0
    let w = worldOf(h)
    let late = lateIndices(w[])
    require late.len == 6
    # seats 0..11 start beside a rules-49 item
    for s in 0..<12:
      let k = late[s mod 6]
      w.cogs[s].pos = Point(x: w.pickups[k].pos.x + int32(120 + 30*(s div 6)), z: w.pickups[k].pos.z)
      w.cogs[s].goal = w.cogs[s].pos
    let start = w[]
    var r = initRand(91)
    var rows: seq[seq[float32]]
    var acts: seq[seq[int32]]
    var hashes: seq[uint32]
    var ob = newSeq[float32](Seats*W)
    var rs = newSeq[float32](Seats)
    var actions = newSeq[int32](Seats*5)
    var rewards, terminals = newSeq[float32](Seats)
    for step in 0..<1500:
      doAssert pw_observe(h, fbuf(ob), fbuf(rs)) == 0
      for s in 0..<Seats:
        actions[s*5] = (if r.rand(4) > 0: int32(11 + late[(s + step div 200) mod 6]) else: int32(r.rand(50)))
        actions[s*5+1] = int32(17 + r.rand(7))
        actions[s*5+2] = int32(r.rand(2) == 0)
        actions[s*5+3] = 0
        actions[s*5+4] = 0
      rows.add ob
      acts.add actions
      let rc = pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals))
      if rc == -2: break
      doAssert rc == 0
      hashes.add pw_state_hash(h)
      if terminals[0] > 0: break
    discard pw_state_hash(h)   # installs the handle's rules, map and mode on this thread
    let policy = Head & Decoder
    var players = newSeq[Bot](LegacySeats)
    for slot in 0..<LegacySeats:
      players[slot] = loadPolicyBot(policy, manifest, slot, ObservationContractTeamsView1iHash)
    heard = newSeq[seq[HeardMessage]](LegacySeats)
    var hw = start
    var compared, items = 0
    for t in 0..<hashes.len:
      var alive: array[LegacySeats, bool]
      for slot in 0..<LegacySeats:
        alive[slot] = hw.cogs[slot].hp > 0
        let bot = players[slot]
        for i in 0..<bot.neural.fedLogits.len: bot.neural.fedLogits[i] = 0
        var offset = 0
        for head in 0..<ActionSizes.len:
          bot.neural.fedLogits[offset + acts[t][slot*ActionSizes.len + head].int] = 1
          offset += bot.neural.heads[head]
        bot.neural.logitsFed = true
      let commands = decide(players, hw)
      deliverSpeech(hw)
      for slot in 0..<LegacySeats:
        if not alive[slot]: continue
        let row = rows[t][slot*W ..< (slot+1)*W]
        let bot = players[slot]
        require not bot.failed
        require bot.neural.observation.len == W
        for i in 0..<W: require bits(bot.neural.observation[i]) == bits(row[i])
        inc compared
        for i in B..<W:
          if row[i] != 0: inc items
      hw.step(commands)
      require hw.stateHash() == hashes[t]
    echo "  compared ", compared, " seat-ticks; ", items, " nonzero item-block values"
    check compared > 5000 and items > 5000

  test "zero-column widening: a 206 bundle and its 207 copy with 82 zero columns at 755 play identically":
    let install = pw_create_observation(76, 0, 207)
    require install != nil and pw_set_rules(install, 49) == 0 and pw_set_map(install, -1) == 0 and
      pw_reset(install, 76, 0) == 0
    discard pw_state_hash(install)   # installs the handle's rules and map on this thread
    pw_destroy(install)
    var compared = 0
    for k in [0, 4]:
      var r = initRand(191 + k)
      let narrowIn = P + k
      var encoder = newSeq[float32](narrowIn*Hidden)
      for x in encoder.mitems: x = float32(r.rand(2.0) - 1.0) * 0.08
      var rest = newSeq[float32](3*Hidden*Hidden + LogitSize*Hidden)
      for i, x in rest.mpairs: x = float32(r.rand(2.0) - 1.0) * (if i < 3*Hidden*Hidden: 0.15'f32 else: 0.6'f32)
      var wide = newSeq[float32]((W + k)*Hidden)
      for o in 0..<Hidden:
        for i in 0..<narrowIn:
          wide[o*(W + k) + (if i < P: i else: i + (W - P))] = encoder[o*narrowIn + i]
      let narrowHash = if k > 0: userInputsContractHash(k, ocTeamsView1p) else: ObservationContractTeamsView1pHash
      let wideHash = if k > 0: userInputsContractHash(k, ocTeamsView1i) else: ObservationContractTeamsView1iHash
      proc manifestFor(hash: string): string =
        result = "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" & hash &
          "\", \"action_contract\": \"" & ActionContractTeamsView1Hash & "\", \"sha256\": {}"
        if k > 0: result.add ", \"user_inputs\": {\"count\": 4, \"init\": [100, -200, 300, 0]}"
        result.add "}"
      let policy = (if k > 0: "neuralInput(3, worldTick mod 997)\nneuralInput(1, selfX)\n" else: "") & Head & Decoder
      for (seed, seats) in [(92'i32, {0'i8..15'i8}), (93'i32, {0'i8, 3, 6, 9, 12, 15})]:
        checkpoint "K " & $k & " seed " & $seed
        let a = hosted(policy, actorFile(narrowIn, narrowHash, encoder, rest), manifestFor(narrowHash), seed, 700, seats)
        let b = hosted(policy, actorFile(W + k, wideHash, wide, rest), manifestFor(wideHash), seed, 700, seats)
        check a.hashes.len > 300 and a.hashes == b.hashes
        require a.logits.len == b.logits.len
        for t in 0..<a.logits.len:
          for s in 0..<Seats:
            require a.logits[t][s].len == b.logits[t][s].len
            for i in 0..<a.logits[t][s].len: require bits(a.logits[t][s][i]) == bits(b.logits[t][s][i])
            if a.logits[t][s].len > 0: inc compared
    check compared > 5000

  test "pw_world_save / pw_world_load: the loaded handle's rows continue exactly":
    let a = pw_create_observation(77, 900, 207)
    let b = pw_create_observation(77, 900, 207)
    require a != nil and b != nil
    defer: pw_destroy(a); pw_destroy(b)
    for h in [a, b]: require pw_set_rules(h, 49) == 0 and pw_reset(h, 77, 900) == 0
    let late = lateIndices(worldOf(a)[])
    var oa = newSeq[float32](Seats*W)
    var ob = newSeq[float32](Seats*W)
    var rs = newSeq[float32](Seats)
    var actions = newSeq[int32](Seats*5)
    var rewards, terminals = newSeq[float32](Seats)
    proc act(t: int) =
      for s in 0..<Seats:
        actions[s*5] = int32(11 + late[(t div 120 + s) mod late.len])
        actions[s*5+1] = int32(17 + (t + s) mod 8)
        actions[s*5+2] = int32((t + s) mod 3 == 0)
    for t in 0..<400:
      act(t)
      check pw_observe(a, fbuf(oa), fbuf(rs)) == 0
      check pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    let size = pw_world_save(a, nil, 0)
    require size > 0
    var blob = newSeq[byte](size)
    require pw_world_save(a, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == size
    require pw_world_load(b, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == 0
    var nonzero = 0
    for t in 0..<120:
      check pw_observe(a, fbuf(oa), fbuf(rs)) == 0
      check pw_observe(b, fbuf(ob), fbuf(rs)) == 0
      for i in 0..<Seats*W: check bits(oa[i]) == bits(ob[i])
      for s in 0..<Seats:
        for i in P..<W:
          if oa[s*W + i] != 0: inc nonzero
      act(400 + t)
      check pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check nonzero > 0
