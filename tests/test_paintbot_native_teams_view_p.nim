## Observation contract teams.view.1p (206): teams.view.1t's 751 floats, then the seat's OWN TRUE timers
## (neural_contract.encodeTeamsViewP, seat_view.ownTimers): 751 gun cooldown / 72, 752 shield / 36, 753 gun wind-up / 5,
## 754 spray cooldown / 60, as read on the pre-step world of the seat's previous alive encoded tick ("S2", pw
## PLAN-features 7c-132), held across a death, zeros before the first alive encode of a match, zeros on a dead row.
## Through the native ABI: sizes and hashes; the first 751 columns byte-equal to a 205 handle's on the same game; every
## timer column against an independent reference that keeps each seat's whole record of true timers (one entry per alive
## tick, read off the world's cogs / equipment, cross-checked against pw_seat_privileged_labels) and applies the S2 rule
## by scanning back (Heartwick at rules 47 and 48, base.bas and random heads, team vision, generated maps, new matches),
## with the mechanics counted: deaths and respawns, the slow 72-tick shot under armour and in a trench, the hit caps (an
## armour-breaking hit with no hp drop, and an hp drop), spray-can shots; scripted exact values (the S2 hold, a repeated
## encode, a skipped observation, death and respawn, a new match, pw_reset); stepped mechanics with exact sequences (a
## seat walks onto the spray can and fires it, 13 ticks of recovery at rules 48 to 0; the 72-tick shot in a trench,
## under armour and carrying; the armour-break and hp-drop caps from an enemy's shot; the wind-up; the spawn shield);
## the hosted host's block equal to the native env's row and to the reference; a 205 bundle and its zero-widened 206
## copy playing identically; pw_world_save / load.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, random, importutils, os]
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
  W = 755
  T = 751            # teams.view.1t's width: the timer block's first column
  Root = currentSourcePath().parentDir.parentDir
  Decoder = staticRead("../examples/paintbot/players/neural_decode.bas")
  Head = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), " &
    "neuralLogits(), neuralState())\nneuralSample()\n"
  Scales = [72'f32, 36, 5, 60]
  SprayCycle = SprayTicks + StrongSprayRecoveryTicks   # 13 at rules >= 40 (rules 48 included)

proc worldOf(h: pointer): ptr World = addr cast[ptr NativeEnv](h).world
proc setVision(h: pointer, team: bool) =
  cast[ptr NativeEnv](h).vision = team
  cast[ptr NativeEnv](h).nextVision = team
proc bits(x: float32): uint32 = cast[uint32](x)
proc baseScript(): string = readFile(Root / "coworld/paintbot/players/base.bas")

type Timers = array[4, int32]   # cooldown, shield, windup, spray cooldown (block order)

proc truth(w: World, slot: int): Timers =
  ## The seat's true timers, read straight off the world (not through seat_view).
  [w.cogs[slot].cooldown, w.cogs[slot].shield, w.equipment[slot].windup, w.equipment[slot].sprayCooldown]

proc scaled(x: Timers): array[4, float32] =
  for i in 0..3: result[i] = float32(x[i]) / Scales[i]

# ---------------------------------------------------------------------------------------------------------------------
# The independent reference: per seat, every alive tick it was observed on this match with its true timers; the S2 value
# at tick t is the entry with the latest tick before t (zeros when there is none), found by scanning back.
type TimerRecord = object
  ticks: seq[int32]
  vals: seq[Timers]

proc s2(r: TimerRecord, t: int32): Timers =
  for i in countdown(r.ticks.len - 1, 0):
    if r.ticks[i] < t: return r.vals[i]

proc lastBefore(r: TimerRecord, t: int32): int32 =
  ## The tick of the entry s2 reads (-1 = none).
  result = -1
  for i in countdown(r.ticks.len - 1, 0):
    if r.ticks[i] < t: return r.ticks[i]

proc take(r: var TimerRecord, w: World, slot: int) =
  r.ticks.add w.tick
  r.vals.add truth(w, slot)

type
  Coverage = object
    rows, alive, dead, first, respawn, matches: int
    shownCd72, shownCdMid, shownShield, shownWindup, shownSpray: int   # alive rows whose block shows it
    slowArmour, slowTrench, normalShot: int   # gun shots by cooldown set (72 = slow) and what made them slow
    capArmourBreak, capHpDrop: int            # cooldown capped to 24 by a hit: armour broken (no hp drop) / hp drop
    sprayShots, sprayPickups, deaths: int

proc add(a: var Coverage, b: Coverage) =
  a.rows += b.rows; a.alive += b.alive; a.dead += b.dead; a.first += b.first; a.respawn += b.respawn
  a.matches += b.matches
  a.shownCd72 += b.shownCd72; a.shownCdMid += b.shownCdMid; a.shownShield += b.shownShield
  a.shownWindup += b.shownWindup; a.shownSpray += b.shownSpray
  a.slowArmour += b.slowArmour; a.slowTrench += b.slowTrench; a.normalShot += b.normalShot
  a.capArmourBreak += b.capArmourBreak; a.capHpDrop += b.capHpDrop
  a.sprayShots += b.sprayShots; a.sprayPickups += b.sprayPickups; a.deaths += b.deaths

proc `$`(c: Coverage): string =
  "rows " & $c.rows & " (alive " & $c.alive & ", dead " & $c.dead & ", first " & $c.first & ", respawn " & $c.respawn &
    "), matches " & $c.matches & "; shown cd 72 / mid " & $c.shownCd72 & " / " & $c.shownCdMid & ", shield " &
    $c.shownShield & ", windup " & $c.shownWindup & ", spray " & $c.shownSpray & "; shots normal " & $c.normalShot &
    ", slow armour " & $c.slowArmour & ", slow trench " & $c.slowTrench & "; caps armour-break " & $c.capArmourBreak &
    ", hp-drop " & $c.capHpDrop & "; spray pickups " & $c.sprayPickups & ", shots " & $c.sprayShots & "; deaths " &
    $c.deaths

type Pre = object
  ## A seat's state on the pre-step world, for counting what the step did.
  hp, armor, cooldown, spray: int32
  sprayCan, carrying, trench: bool

proc pre(w: World, s: int): Pre =
  Pre(hp: w.cogs[s].hp, armor: w.equipment[s].armor, cooldown: w.cogs[s].cooldown,
    spray: w.equipment[s].sprayCooldown, sprayCan: w.equipment[s].sprayCan, carrying: w.cogs[s].carrying,
    trench: w.trenchAt(w.cogs[s].pos) >= 0)

proc count(c: var Coverage, before: Pre, w: World, s: int) =
  ## What the step did to seat s's timers (the mechanics this suite must exercise).
  let after = pre(w, s)
  if before.hp > 0 and after.hp <= 0: inc c.deaths
  if before.hp <= 0 or after.hp <= 0: return
  if not before.sprayCan and after.sprayCan: inc c.sprayPickups
  if after.spray == SprayCycle and before.spray <= 1: inc c.sprayShots
  if before.cooldown == 0 and after.cooldown == 3*FireCooldownTicks:
    if before.armor > 0: inc c.slowArmour
    elif before.trench and not before.carrying: inc c.slowTrench
  elif before.cooldown == 0 and after.cooldown == FireCooldownTicks: inc c.normalShot
  if before.cooldown - 1 > FireCooldownTicks and after.cooldown == FireCooldownTicks:
    if before.armor > 0 and after.armor == 0 and after.hp == before.hp: inc c.capArmourBreak
    elif after.hp < before.hp: inc c.capHpDrop

proc checkRow(c: var Coverage, rec: var TimerRecord, w: World, s: int, row: openArray[float32], what: string) =
  ## Seat s's block against the reference on the tick just observed, then the tick is recorded (alive only).
  inc c.rows
  if w.cogs[s].hp <= 0:
    for k in 0..3:
      if row[T + k] != 0:
        echo what, ": DEAD ROW tick ", w.tick, " seat ", s, " column ", T + k, " = ", row[T + k]
        doAssert false
    inc c.dead
    return
  inc c.alive
  let last = rec.lastBefore(w.tick)
  if last < 0: inc c.first
  elif last < w.tick - 1: inc c.respawn
  let want = scaled(rec.s2(w.tick))
  for k in 0..3:
    if bits(row[T + k]) != bits(want[k]):
      echo what, ": DIFF tick ", w.tick, " seat ", s, " column ", T + k, ": ", row[T + k], " want ", want[k],
        " (S2 tick ", last, ")"
      doAssert false
  if want[0] == 1: inc c.shownCd72 elif want[0] > 0: inc c.shownCdMid
  if want[1] > 0: inc c.shownShield
  if want[2] > 0: inc c.shownWindup
  if want[3] > 0: inc c.shownSpray
  rec.take(w, s)

proc labelsAgree(h: pointer, w: World, s: int) =
  ## The world fields the reference reads are the privileged labels' timers (training_labels.nim).
  var l: array[21, float32]   # pw_seat_privileged_labels writes 21 floats
  doAssert pw_seat_privileged_labels(h, s.cint, cast[Buffer](addr l[0])) == 0
  let x = truth(w, s)
  doAssert l[0] == x[0].float32 and l[3] == x[1].float32 and l[1] == x[2].float32 and l[2] == x[3].float32

type GameSpec = object
  seed, rules, map: int32   # map -1 = the rules' own island (Heartwick); 0 .. 9 the generated maps
  team, scripted: bool      # team vision; base.bas on every seat (else sticky random heads)
  ticks, fire, episodes: int  # fire: one random tick in `fire` shoots; episodes: matches played (pw_reset between)

proc game(g: GameSpec): Coverage =
  ## One game (g.episodes matches) on a 205 and a 206 handle side by side: the first 751 columns byte-equal, the block
  ## equal to the reference.
  var r = initRand(g.seed.int)
  let a = pw_create_observation(g.seed, 0, 205)
  let b = pw_create_observation(g.seed, 0, 206)
  doAssert a != nil and b != nil
  defer: pw_destroy(a); pw_destroy(b)
  for h in [a, b]:
    doAssert pw_set_rules(h, g.rules) == 0 and pw_set_map(h, g.map) == 0
    setVision(h, g.team)
  var oa = newSeq[float32](Seats*T)
  var ob = newSeq[float32](Seats*W)
  var ra, rb = newSeq[float32](Seats)
  var actions = newSeq[int32](Seats*5)
  var hold = newSeq[int](Seats)
  var rewards, terminals = newSeq[float32](Seats)
  for episode in 0..<g.episodes:
    let seed = g.seed + int32(1000*episode)
    for h in [a, b]: doAssert pw_reset(h, seed, 0) == 0
    if g.scripted and episode == 0:
      let source = baseScript()
      for s in 0..<Seats:
        for h in [a, b]: doAssert pw_set_seat_script(h, s.cint, cbuf(source), source.len.int32) == 0
    inc result.matches
    var recs = newSeq[TimerRecord](Seats)   # a new match: the reference starts over
    let w = worldOf(b)
    let hearts = min(10, w.controlHearts.len)
    for step in 0..<g.ticks:
      doAssert pw_observe(a, fbuf(oa), fbuf(ra)) == 0
      doAssert pw_observe(b, fbuf(ob), fbuf(rb)) == 0
      var before: array[LegacySeats, Pre]
      for s in 0..<Seats:
        for i in 0..<T: doAssert bits(oa[s*T+i]) == bits(ob[s*W+i])
        if step mod 97 == 0: labelsAgree(b, w[], s)
        result.checkRow(recs[s], w[], s, ob.toOpenArray(s*W, s*W + W - 1), "seed " & $seed)
        before[s] = pre(w[], s)
      if not g.scripted:
        for s in 0..<Seats:
          # sticky random heads: a heart, a pickup or anywhere for a while; fire on one tick in `fire`
          if hold[s] == 0:
            actions[s*5] = case r.rand(2)
              of 0: int32(1 + r.rand(max(hearts, 1) - 1))
              of 1: int32(11 + r.rand(max(1, min(w.pickups.len, 32)) - 1))
              else: int32(r.rand(50))
            hold[s] = 1 + r.rand(240)
          dec hold[s]
          actions[s*5+1] = int32(r.rand(24))
          actions[s*5+2] = int32(g.fire > 0 and r.rand(g.fire - 1) == 0)
          actions[s*5+3] = 0
          actions[s*5+4] = 0
      let rc1 = pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals))
      let rc2 = pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals))
      doAssert rc1 == rc2
      doAssert pw_state_hash(a) == pw_state_hash(b)
      for s in 0..<Seats: result.count(before[s], w[], s)
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
  logits: seq[seq[seq[float32]]]   # per tick, per seat (empty: not a policy seat, or dead)

proc hosted(policy, model, manifest: string, seed: int32, ticks: int, policySeats: set[int8]): HostedRun =
  ## The game's own loop over a staged bundle: policy seats run it, the rest base.bas.
  let path = getTempDir()/("paintbot-view-p-" & $getCurrentProcessId() & ".bas")
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

proc pickupIndex(w: World, kind: PickupKind, side: int): int =
  ## The pickup of that kind nearer team `side`'s home (-1 = none).
  result = -1
  for i, p in w.pickups:
    if p.kind != kind: continue
    if result < 0 or distance2(p.pos, home(side)) < distance2(w.pickups[result].pos, home(side)): result = i

suite "Observation contract teams.view.1p (206)":
  configureRules(NativeRules)

  test "sizes, hashes, user-input variants; 201 / 203 / 204 / 205 unchanged; 208 refused":
    check TeamsViewPSize == 755 and TimerWidth == 4 and TeamsViewTSize == 751
    check TimerCooldownScale == 72 and TimerShieldScale == 36 and TimerWindupScale == 5 and TimerSprayScale == 60
    check 3*FireCooldownTicks == 72 and GunWindupTicks == 5   # the slow shot and the wind-up fill their scales
    check ObservationContractTeamsView1pHash == sha256Hex("paintbot-pw.teams.view.1p")
    check observationContractVersion(ObservationContractTeamsView1pHash) == ocTeamsView1p
    check observationContractId(ocTeamsView1p) == "paintbot-pw.teams.view.1p"
    check observationSize(ocTeamsView1p) == 755
    check pw_observation_size_for(206) == 755 and pw_observation_size_for(205) == 751 and
      pw_observation_size_for(204) == 740 and pw_observation_size_for(203) == 612 and
      pw_observation_size_for(201) == 512 and pw_observation_size_for(208) == -1
    let h = pw_create_observation(1, 600, 206)
    require h != nil
    defer: pw_destroy(h)
    check pw_create_observation(1, 600, 208) == nil
    check pw_handle_observation_size(h) == 755 and pw_observation_contract(h) == 206
    var hex: array[65, char]
    check pw_observation_contract_hash(206, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
    check $cast[cstring](addr hex[0]) == ObservationContractTeamsView1pHash
    check pw_observation_contract_hash(208, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == -1
    for v in 201'i32..205'i32:
      check pw_observation_contract_hash(v, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
      check $cast[cstring](addr hex[0]) == observationContractHash(ObservationContractVersion(v))
    check ObservationContractTeamsView1tHash == sha256Hex("paintbot-pw.teams.view.1t")
    let hk = pw_create_observation_inputs_v(1, 600, 206, 110)
    require hk != nil
    defer: pw_destroy(hk)
    check pw_handle_observation_size(hk) == 755 + 110 and pw_handle_user_inputs(hk) == 110
    check pw_create_observation_inputs_v(1, 600, 208, 43) == nil
    for k in [1'i32, 110, 256]:
      check pw_user_inputs_contract_hash_v(206, k, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
      check $cast[cstring](addr hex[0]) == userInputsContractHash(k.int, ocTeamsView1p)
      check userInputsContractHash(k.int, ocTeamsView1p) == sha256Hex("paintbot-pw.teams.view.1pu" & $k)
    for k in [0'i32, 257]:
      check pw_user_inputs_contract_hash_v(206, k, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == -1
    check pw_user_inputs_contract_hash_v(208, 1, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == -1
    check userInputsContractId(110, ocTeamsView1p) == "paintbot-pw.teams.view.1pu110"
    check userInputsContract(userInputsContractHash(110, ocTeamsView1p)) == (ocTeamsView1p, 110)
    check pairs(ocTeamsView1p, acTeamsView1) and pairs(ocTeamsView1p, acTeamsView1Raw)
    check pairedAction(ocTeamsView1p) == acTeamsView1
    check ocTeamsView1p in TeamsObservationContracts and ocTeamsView1p in HistoryObservationContracts
    check not retiredContract(ObservationContractTeamsView1pHash)   # engine state beyond BASIC, not retired
    check pw_set_game_mode(h, 1) == -1   # the teams game only

  test "every timer column equals the S2 reference; the first 751 equal a 205 handle's":
    var total: Coverage
    let specs = [
      GameSpec(seed: 61, rules: 48, map: -1, scripted: true, ticks: 1500, episodes: 2),
      GameSpec(seed: 62, rules: 48, map: -1, ticks: 1800, fire: 3, episodes: 2),
      GameSpec(seed: 63, rules: 47, map: -1, team: true, ticks: 1500, fire: 4, episodes: 1),
      GameSpec(seed: 64, rules: 48, map: -1, team: true, scripted: true, ticks: 1200, episodes: 1),
      GameSpec(seed: 65, rules: 48, map: 0, ticks: 1000, fire: 3, episodes: 2),       # twin-mesas
      GameSpec(seed: 66, rules: 48, map: 3, scripted: true, ticks: 1000, episodes: 1),  # crater
      GameSpec(seed: 67, rules: 48, map: 7, ticks: 1000, fire: 2, episodes: 1),       # atoll
      GameSpec(seed: 68, rules: 48, map: 9, scripted: true, ticks: 1000, episodes: 1)]  # delta
    for g in specs:
      let s = game(g)
      echo "  seed ", g.seed, " rules ", g.rules, " map ", g.map, (if g.team: " team vision" else: ""),
        (if g.scripted: " base.bas" else: " random heads"), ": ", s
      total.add s
    echo "  total: ", total
    check total.rows > 200000 and total.dead > 10000 and total.first == 16*total.matches
    check total.matches >= 11 and total.respawn > 200 and total.deaths > 200
    # 72 / 72 shows on one row per slow shot (the row after the shot's next tick)
    check total.shownCd72 > 50 and total.shownCdMid > 100000 and total.shownShield > 10000 and
      total.shownWindup > 10000 and total.shownSpray > 1000
    check total.normalShot > 500 and total.slowArmour > 10 and total.slowTrench > 10
    check total.capArmourBreak > 0 and total.capHpDrop > 0
    check total.sprayPickups > 10 and total.sprayShots > 100

  test "scripted S2: the previous alive tick's timers, a repeated encode, a skipped observation, death, a new match, pw_reset":
    let h = pw_create_observation(71, 0, 206)
    require h != nil
    defer: pw_destroy(h)
    require pw_set_rules(h, 48) == 0 and pw_reset(h, 71, 0) == 0
    let w = worldOf(h)
    var ob = newSeq[float32](Seats*W)
    var rs = newSeq[float32](Seats)
    let hp0 = w.cogs[0].hp
    proc look(t: int, x: Timers, alive = true, mask = 0xFFFF'u32): array[4, float32] =
      ## Seat 0 alive (or dead) on tick t with timers x; its block after the observe.
      w.tick = t.int32
      w.cogs[0].hp = if alive: hp0 else: 0
      w.cogs[0].cooldown = x[0]; w.cogs[0].shield = x[1]
      w.equipment[0].windup = x[2]; w.equipment[0].sprayCooldown = x[3]
      if mask == 0xFFFF'u32: doAssert pw_observe(h, fbuf(ob), fbuf(rs)) == 0
      else: doAssert pw_observe_seats(h, mask, fbuf(ob), fbuf(rs)) == 0
      for k in 0..3: result[k] = ob[T + k]
    const
      Z: Timers = [0'i32, 0, 0, 0]
      A: Timers = [72'i32, 36, 5, 13]
      B: Timers = [71'i32, 35, 4, 12]
      C: Timers = [24'i32, 0, 0, 0]
      D: Timers = [5'i32, 3, 2, 1]
      E: Timers = [1'i32, 1, 1, 1]
      F: Timers = [60'i32, 20, 3, 7]
    # the first alive tick of the match: zeros, whatever the truth
    check look(100, A) == scaled(Z)
    # the next tick shows the previous tick's truth, not its own
    check look(101, B) == scaled(A)
    check look(102, C) == scaled(B)
    # exact scales: 72 / 72 = 1, 36 / 36 = 1, 5 / 5 = 1, 13 / 60
    check look(103, D) == [float32(24) / 72, 0, 0, 0]
    check look(104, E) == [float32(5) / 72, float32(3) / 36, float32(2) / 5, float32(1) / 60]
    # a repeated encode in the same tick writes the same floats and takes nothing more in
    check look(104, F) == scaled(D)
    check look(105, F) == scaled(E)
    # a skipped observation takes nothing in: tick 106 (seat 0 not observed) does not count
    discard look(106, A, mask = 0xFFFE'u32)
    check look(107, B) == scaled(F)
    # death: zeros on every dead row; the respawn row shows the last alive tick's truth (held across the death)
    for t in 108..130:
      check look(t, A, alive = false) == scaled(Z)
    check look(131, C) == scaled(B)
    check look(132, D) == scaled(C)
    # a tick before the last one taken in (a new match on the same seat) starts over: zeros, then the new truth
    check look(10, E) == scaled(Z)
    check look(11, F) == scaled(E)
    # pw_reset starts over too
    discard look(12, A)
    require pw_reset(h, 72, 0) == 0
    for s in 1..<Seats: w.cogs[s].hp = 0
    check look(500, B) == scaled(Z)
    check look(501, C) == scaled(B)
    # the block never changes the first 751 columns: they are teams.view.1t's (the side-by-side games check every byte)

  test "stepped mechanics: the spray can picked up and fired (13 ticks to 0 at rules 48), the 72-tick shot in a trench, under armour and carrying, the armour-break and hp-drop caps, the wind-up, death and the spawn shield":
    let h = pw_create_observation(81, 0, 206)
    require h != nil
    defer: pw_destroy(h)
    setVision(h, false)
    require pw_set_rules(h, 48) == 0 and pw_set_map(h, -1) == 0 and pw_reset(h, 81, 0) == 0
    check sprayRecoveryTicks() == StrongSprayRecoveryTicks and SprayCycle == 13
    let w = worldOf(h)
    var ob = newSeq[float32](Seats*W)
    var rs = newSeq[float32](Seats)
    var actions = newSeq[int32](Seats*5)
    var rewards, terminals = newSeq[float32](Seats)
    var recs = newSeq[TimerRecord](Seats)
    var cov: Coverage
    var shown: seq[array[4, float32]]   # seat 0's block per observed tick
    var truths: seq[Timers]             # seat 0's truth per observed tick
    proc park() =
      ## Every seat stays, keeps its aim, holds fire.
      for i in 0..<actions.len: actions[i] = 0
    proc tick() =
      ## Observe (every block against the reference), step, count.
      doAssert pw_observe(h, fbuf(ob), fbuf(rs)) == 0
      var before: array[LegacySeats, Pre]
      for s in 0..<Seats:
        cov.checkRow(recs[s], w[], s, ob.toOpenArray(s*W, s*W + W - 1), "stepped")
        before[s] = pre(w[], s)
      var x: array[4, float32]
      for c in 0..3: x[c] = float32(ob[T + c])
      shown.add x
      truths.add truth(w[], 0)
      doAssert pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      for s in 0..<Seats: cov.count(before[s], w[], s)
    proc place(s: int, p: Point) =
      w.cogs[s].pos = p; w.cogs[s].goal = p
    # Seat 0 (team 0) and seat 1 (team 1) only: the others far off in their spawn zones, parked.
    park()
    # 1. the spawn shield: seat 0 alive from tick 0 on; its block shows 36 / 36 one tick late, then down by one per tick
    for i in 0..<40: tick()
    check shown[0] == [0'f32, 0, 0, 0]
    check truths[0][1] > 0
    for i in 1..<40: check shown[i][1] == float32(truths[i-1][1]) / 36
    require truths[39][1] == 0
    # 2. the spray can: seat 0 walks onto it (movement head 11 + its pickup index) and picks it up
    let k = pickupIndex(w[], sprayPickup, 0)
    require k >= 0
    let can = w.pickups[k].pos
    place(0, Point(x: can.x + 300, z: can.z))
    w.cogs[0].aim = can
    var walked = 0
    while not w.equipment[0].sprayCan and walked < 200:
      actions[0] = int32(11 + k)
      tick()
      inc walked
    require w.equipment[0].sprayCan
    check walked > 1 and cov.sprayPickups == 1
    # ... and fires it once (fire head on for one tick, aim east): spray cooldown 13 on the next world, down to 0
    park()
    actions[1] = 17
    actions[2] = 1
    let fired = shown.len
    tick()
    park()
    for i in 0..<20: tick()
    check cov.sprayShots == 1
    check truths[fired][3] == 0 and truths[fired + 1][3] == 13
    for j in 1..13: check truths[fired + j][3] == int32(14 - j)
    check truths[fired + 14][3] == 0
    # S2: the block shows each of those one tick late: 0 on the fire tick + 1, 13 / 60 on + 2, ..., 1 / 60 on + 14, 0 after
    check shown[fired + 1][3] == 0
    for j in 2..14: check shown[fired + j][3] == float32(15 - j) / 60
    check shown[fired + 15][3] == 0 and shown[fired + 20][3] == 0
    # held fire: a shot every 13 ticks, the block cycles 13 .. 1, 0 ... (no gun cooldown or wind-up with the can)
    actions[1] = 17
    actions[2] = 1
    let heldFrom = shown.len
    for i in 0..<60: tick()
    park()
    check cov.sprayShots >= 5
    var cycles = 0
    for j in heldFrom + 1 ..< shown.len:
      if shown[j][3] == float32(13) / 60: inc cycles
      check shown[j][0] == 0 and shown[j][2] == 0
    check cycles >= 4
    # 3. the gun in a trench: no can (a death drops it, so take it away by hand), no armour, in a trench: 72 ticks
    for i in 0..<20: tick()
    w.equipment[0].sprayCan = false
    let trench = w.trenches[0]
    place(0, Point(x: trench.x + trench.w div 2, z: trench.z + trench.h div 2))
    require w[].trenchAt(w.cogs[0].pos) >= 0 and w.equipment[0].armor == 0 and not w.cogs[0].carrying
    actions[1] = 17
    actions[2] = 1
    let gun = shown.len
    tick()
    park()
    for i in 0..<10: tick()
    check truths[gun + 1][0] == 72 and truths[gun + 1][2] == GunWindupTicks
    check shown[gun + 2][0] == 1 and shown[gun + 2][2] == 1   # 72 / 72 and 5 / 5, one tick late
    for j in 2..6: check shown[gun + j][2] == float32(7 - j) / 5   # the wind-up 5 .. 1, then 0
    check shown[gun + 7][2] == 0
    check cov.slowTrench >= 1
    # 4. the hp-drop cap: out of the trench, cooldown still high, an enemy's shot lands: cooldown capped to 24
    proc enemyShoots(want: proc(): bool, limit: int): bool =
      ## Seat 1 (team 1) 900 u east of seat 0, aiming at identity 0 and firing until `want` holds.
      place(1, Point(x: w.cogs[0].pos.x + 900, z: w.cogs[0].pos.z))
      w.cogs[1].aim = w.cogs[0].pos
      for i in 0..<limit:
        if w.cogs[1].hp <= 0 or w.cogs[0].hp <= 0: return false
        actions[5] = 0; actions[6] = 1; actions[7] = 1   # seat 1: stay, aim identity 0, fire
        tick()
        if want(): return true
      false
    block outside:
      # the nearest open ground east of the trench
      for dx in countup(200, 1500, 50):
        let p = Point(x: trench.x + trench.w + dx.int32, z: trench.z + trench.h div 2)
        if not w[].blocked(p) and w[].trenchAt(p) < 0 and not w[].blocked(Point(x: p.x + 900, z: p.z)):
          place(0, p)
          break outside
      doAssert false, "no open ground east of the trench"
    require w[].trenchAt(w.cogs[0].pos) < 0
    for i in 0..<3: tick()
    require w.cogs[0].cooldown > 30
    let capsBefore = cov.capHpDrop
    check enemyShoots(proc(): bool = cov.capHpDrop > capsBefore, 40)
    park()
    for i in 0..<5: tick()
    # 5. the armour-break cap: armour 1, the slow shot under armour (72), then a hit takes the armour and no hp
    for i in 0..<80: tick()
    w.equipment[0].armor = 1
    let slowBefore = cov.slowArmour
    actions[1] = 17
    actions[2] = 1
    tick()
    park()
    check cov.slowArmour == slowBefore + 1
    for i in 0..<3: tick()
    let breaksBefore = cov.capArmourBreak
    check enemyShoots(proc(): bool = cov.capArmourBreak > breaksBefore, 40)
    park()
    let capped = shown.len - 1   # the observed tick before the step that broke the armour
    for i in 0..<3: tick()
    check truths[capped + 1][0] == 24 and shown[capped + 2][0] == float32(24) / 72
    # 6. carrying (no rules >= 40 match carries a heart; set by hand): the slow shot, 72
    for i in 0..<80: tick()
    require w.cogs[0].cooldown == 0 and w.equipment[0].armor == 0
    w.cogs[0].carrying = true
    actions[1] = 17
    actions[2] = 1
    let carried = shown.len
    tick()
    park()
    tick(); tick()
    w.cogs[0].carrying = false
    check truths[carried + 1][0] == 72 and shown[carried + 2][0] == 1
    # 7. death and respawn: zeros while dead; the respawn row shows the last alive tick's truth; then the spawn shield
    damage(w[], 0, 1, 1000)
    require w.cogs[0].hp <= 0
    var deadRows = 0
    while w.cogs[0].hp <= 0 and deadRows < 400:
      tick()
      inc deadRows
      check shown[^1] == [0'f32, 0, 0, 0]
    require w.cogs[0].hp > 0
    tick()   # the respawn row
    check cov.respawn >= 1
    tick()
    check shown[^1][1] == 1   # the spawn shield, 36 / 36, on the row after the respawn row
    # 8. a new match on the handle: zeros on the first row again
    require pw_reset(h, 82, 0) == 0
    for r in recs.mitems: r = TimerRecord()
    tick()
    check shown[^1] == [0'f32, 0, 0, 0]
    tick()
    check shown[^1][1] == 1
    echo "  ", cov

  test "native env and hosted host give the same block (and both the reference's) through a spray-heavy game":
    # The training == host replay of tests/test_paintbot_neural_parity.nim on a 206 handle, with four seats per team
    # walking to the spray cans and firing: every policy seat's hosted observation equals the native row, and its block
    # equals the S2 reference read off the hosted world.
    let manifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": """" &
      ObservationContractTeamsView1pHash & """", "action_contract": """" & ActionContractTeamsView1Hash & "\"}"
    let h = pw_create_observation(91, 0, 206)
    require h != nil
    defer: pw_destroy(h)
    require pw_set_rules(h, 48) == 0 and pw_set_map(h, -1) == 0 and pw_reset(h, 91, 900) == 0
    let w = worldOf(h)
    # seats 0..7 start next to their side's spray can
    for s in 0..<8:
      let k = pickupIndex(w[], sprayPickup, team(s))
      require k >= 0
      w.cogs[s].pos = Point(x: w.pickups[k].pos.x + int32(150 + 40*s), z: w.pickups[k].pos.z)
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
    for step in 0..<900:
      doAssert pw_observe(h, fbuf(ob), fbuf(rs)) == 0
      for s in 0..<Seats:
        let k = pickupIndex(w[], sprayPickup, team(s))
        actions[s*5] = (if s < 8 and not w.equipment[s].sprayCan: int32(11 + k) elif r.rand(3) == 0:
          int32(r.rand(50)) else: 0)
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
    # the hosted replay from the same start: every seat a hosted policy seat fed the chosen heads
    discard pw_state_hash(h)   # installs the handle's rules, map and mode on this thread
    let policy = Head & Decoder
    var players = newSeq[Bot](LegacySeats)
    for slot in 0..<LegacySeats:
      players[slot] = loadPolicyBot(policy, manifest, slot, ObservationContractTeamsView1pHash)
    heard = newSeq[seq[HeardMessage]](LegacySeats)
    var hw = start
    var recs = newSeq[TimerRecord](Seats)
    var cov: Coverage
    var compared = 0
    for t in 0..<hashes.len:
      var alive: array[LegacySeats, bool]
      var before: array[LegacySeats, Pre]
      for slot in 0..<LegacySeats:
        alive[slot] = hw.cogs[slot].hp > 0
        before[slot] = pre(hw, slot)
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
        let row = rows[t][slot*W ..< (slot+1)*W]
        if alive[slot]:
          let bot = players[slot]
          require not bot.failed
          require bot.neural.observation.len == W
          for i in 0..<W: require bits(bot.neural.observation[i]) == bits(row[i])
          inc compared
        cov.checkRow(recs[slot], hw, slot, row, "hosted")
      hw.step(commands)
      require hw.stateHash() == hashes[t]
      for slot in 0..<LegacySeats: cov.count(before[slot], hw, slot)
    echo "  compared ", compared, " seat-ticks; ", cov
    check compared > 5000 and cov.sprayShots > 20 and cov.shownSpray > 100 and cov.normalShot > 20

  test "zero-column widening: a 205 bundle and its 206 copy with 4 zero columns at 751 play identically (logits and hashes)":
    let install = pw_create_observation(76, 0, 206)
    require install != nil and pw_set_rules(install, 48) == 0 and pw_set_map(install, -1) == 0 and
      pw_reset(install, 76, 0) == 0
    discard pw_state_hash(install)   # installs the handle's rules and map on this thread
    pw_destroy(install)
    var compared = 0
    for k in [0, 4]:
      var r = initRand(91 + k)
      let narrowIn = T + k
      var encoder = newSeq[float32](narrowIn*Hidden)
      for x in encoder.mitems: x = float32(r.rand(2.0) - 1.0) * 0.08
      var rest = newSeq[float32](3*Hidden*Hidden + LogitSize*Hidden)
      for i, x in rest.mpairs: x = float32(r.rand(2.0) - 1.0) * (if i < 3*Hidden*Hidden: 0.15'f32 else: 0.6'f32)
      var wide = newSeq[float32]((W + k)*Hidden)
      for o in 0..<Hidden:
        for i in 0..<narrowIn:
          wide[o*(W + k) + (if i < T: i else: i + 4)] = encoder[o*narrowIn + i]
      let narrowHash = if k > 0: userInputsContractHash(k, ocTeamsView1t) else: ObservationContractTeamsView1tHash
      let wideHash = if k > 0: userInputsContractHash(k, ocTeamsView1p) else: ObservationContractTeamsView1pHash
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

  test "pw_world_save / pw_world_load carry the timer hold: the loaded handle's rows continue exactly":
    let a = pw_create_observation(77, 900, 206)
    let b = pw_create_observation(77, 900, 206)
    require a != nil and b != nil
    defer: pw_destroy(a); pw_destroy(b)
    var oa = newSeq[float32](Seats*W)
    var ob = newSeq[float32](Seats*W)
    var rs = newSeq[float32](Seats)
    var actions = newSeq[int32](Seats*5)
    var rewards, terminals = newSeq[float32](Seats)
    proc act(t: int) =
      for s in 0..<Seats:
        actions[s*5] = int32(1 + (t div 60 + s) mod 10)
        actions[s*5+1] = int32(17 + (t + s) mod 8)
        actions[s*5+2] = int32((t + s) mod 3 == 0)
    for t in 0..<300:
      act(t)
      check pw_observe(a, fbuf(oa), fbuf(rs)) == 0
      check pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    let size = pw_world_save(a, nil, 0)
    require size > 0
    var blob = newSeq[byte](size)
    require pw_world_save(a, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == size
    require pw_world_load(b, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == 0
    var held = 0
    for t in 0..<60:
      check pw_observe(a, fbuf(oa), fbuf(rs)) == 0
      check pw_observe(b, fbuf(ob), fbuf(rs)) == 0
      for i in 0..<Seats*W: check bits(oa[i]) == bits(ob[i])
      if t == 0:
        # the first row after the load already shows the pre-save tick's timers (the hold came back with the blob)
        for s in 0..<Seats:
          for c in 0..3:
            if oa[s*W + T + c] != 0: inc held
      act(300 + t)
      check pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check held > 0
