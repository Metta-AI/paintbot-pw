## Observation contract teams.view.1t (205): teams.view.1s's 740 floats, then the engine's 11-float hunt-clock block
## (neural_contract.encodeTeamsViewT): col 740 enemy_gap, cols 741 + r heart_gap[r] for map heart r xor selfTeam.
## Through the native ABI: sizes and hashes; the first 740 columns byte-equal to a 204 handle's on the same game; every
## hunt column against an independent reference that keeps each seat's whole record (per alive tick: whether an
## enemy-parity identity was in sight, which hearts were within 600 u) and recomputes the 11 values from scratch every
## tick (Heartwick at rules 47 and 48, team and per-cog vision, generated maps, big-twin-mesas, games past both caps);
## scripted exact values (parked, the walk to the 2760 cap, an enemy in and out of sight to the 720 cap, a skipped
## observation, a repeated encode, death and respawn, a disguise either way, a new match, pw_reset, fewer than ten and
## no hearts); the mirror invariant behind the team frame; BASIC equivalence with policy.bas's hunt inputs 36..42; a
## 204 bundle and its zero-widened 205 copy playing identically; pw_world_save / load.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, random, importutils, os, strutils]
import bassy
import polyworld/[cli]
import ../examples/paintbot/[sim, neural_contract, neural_actor, native_env, seat_view, bots, oracle, maps, contract_hash]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] =
  (if s.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr s[0]) else: nil)
privateAccess(NativeEnv)

const
  W = 751
  S = 740            # teams.view.1s's width: the hunt block's first column
  Root = currentSourcePath().parentDir.parentDir
  Decoder = staticRead("../examples/paintbot/players/neural_decode.bas")
  Head = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), " &
    "neuralLogits(), neuralState())\nneuralSample()\n"
  H0 = [8, 9, 7, 1, 3, 5]   # policy.bas's six hunt hearts (team 0; team 1 reads h xor 1)
  # pw-arch hunt inputs 36..42, verbatim: paintbot-rl origin/pw/zc-launch-s2 pw/league/pod/recipe_view/v0.policy.bas
  # lines 131-228 (blob d0a3743c), ported to Bassy: integer division is `\`.
  HuntSnippet = """
hiJ = 1 - selfTeam
while hiJ < 16
  if visible(hiJ) then
    if playerHp(hiJ) > 0 then
      hiSeen = worldTick
    end if
  end if
  hiJ = hiJ + 2
wend
hiU = (worldTick - hiSeen) * 1000 \ 240
if hiU > 3000 then
  hiU = 3000
end if
neuralInput(35, tlV)
neuralInput(36, hiU)
hvK = 0
while hvK < 6
  hvH = 8
  if selfTeam = 0 then
    if hvK = 1 then
      hvH = 9
    end if
    if hvK = 2 then
      hvH = 7
    end if
    if hvK = 3 then
      hvH = 1
    end if
    if hvK = 4 then
      hvH = 3
    end if
    if hvK = 5 then
      hvH = 5
    end if
  else
    hvH = 9
    if hvK = 1 then
      hvH = 8
    end if
    if hvK = 2 then
      hvH = 6
    end if
    if hvK = 3 then
      hvH = 0
    end if
    if hvK = 4 then
      hvH = 2
    end if
    if hvK = 5 then
      hvH = 4
    end if
  end if
  hvX = controlX(hvH) - selfX
  hvY = controlY(hvH) - selfY
  hvLast = hvT0
  if hvK = 1 then
    hvLast = hvT1
  end if
  if hvK = 2 then
    hvLast = hvT2
  end if
  if hvK = 3 then
    hvLast = hvT3
  end if
  if hvK = 4 then
    hvLast = hvT4
  end if
  if hvK = 5 then
    hvLast = hvT5
  end if
  if hvX * hvX + hvY * hvY <= 360000 then
    hvLast = worldTick
    if hvK = 0 then
      hvT0 = worldTick
    end if
    if hvK = 1 then
      hvT1 = worldTick
    end if
    if hvK = 2 then
      hvT2 = worldTick
    end if
    if hvK = 3 then
      hvT3 = worldTick
    end if
    if hvK = 4 then
      hvT4 = worldTick
    end if
    if hvK = 5 then
      hvT5 = worldTick
    end if
  end if
  hvV = (worldTick - hvLast) * 3000 \ 2760
  if hvV > 3000 then
    hvV = 3000
  end if
  neuralInput(37 + hvK, hvV)
  hvK = hvK + 1
wend
"""

proc worldOf(h: pointer): ptr World = addr cast[ptr NativeEnv](h).world
proc setVision(h: pointer, team: bool) =
  cast[ptr NativeEnv](h).vision = team
  cast[ptr NativeEnv](h).nextVision = team
proc bits(x: cfloat): uint32 = cast[uint32](x)
proc mirror(p: Point): Point = Point(x: int32(Width) - p.x, z: int32(Height) - p.z)
proc baseScript(): string = readFile(Root / "coworld/paintbot/players/base.bas")
proc setPolicy(handle: pointer, seat: int, source, manifest: string): cint =
  pw_set_seat_policy_script(handle, seat.cint, cbuf(source), source.len.int32, cbuf(manifest), manifest.len.int32)

# ---------------------------------------------------------------------------------------------------------------------
# The independent reference: the seat's whole record, one entry per tick it was observed alive on, taken from the world
# (the identity each body shows this seat, world visibility, body hp, positions), and the 11 values recomputed from it by
# scanning back, with no running state.
type HuntRecord = object
  at: seq[int]         # tick -> index into enemy / near, -1 = the seat took nothing in on that tick
  enemy: seq[bool]     # an enemy-parity identity was in sight, alive
  near: seq[uint16]    # bit i: within 600 u of map heart i (i < 10)

proc take(r: var HuntRecord, w: World, slot: int): bool =
  ## Record this tick for the seat if it is alive; whether it was.
  while r.at.len <= w.tick.int: r.at.add -1
  if w.cogs[slot].hp <= 0: return false
  var seen = false
  for body in 0..<Seats:
    if body == slot: continue
    if w.observedSeat(slot, body) mod 2 != team(slot) and w.visible(slot, body) and w.cogs[body].hp > 0: seen = true
  var near = 0'u16
  for i in 0..<min(10, w.controlHearts.len):
    if distance2(w.cogs[slot].pos, w.controlHearts[i].pos) <= 600*600: near = near or (1'u16 shl i)
  r.at[w.tick.int] = r.enemy.len
  r.enemy.add seen
  r.near.add near
  true

proc reference(r: HuntRecord, t, side, hearts: int): array[11, float32] =
  ## The latest recorded tick at or before t with an enemy in sight (within 600 u of heart i). Nothing older than the
  ## cap is looked at: an older one reads the cap either way. None in reach: the match start, tick 0.
  var e = -1
  for u in countdown(t, max(0, t - 720)):
    if r.at[u] >= 0 and r.enemy[r.at[u]]:
      e = u
      break
  result[0] = float32(if e >= 0: t - e else: min(t, 720)) / 720
  var last: array[10, int]
  var found = 0'u16
  let all = uint16((1 shl hearts) - 1)
  for u in countdown(t, max(0, t - 2760)):
    if found == all: break
    if r.at[u] < 0: continue
    let hit = r.near[r.at[u]] and not found
    if hit == 0: continue
    for i in 0..<hearts:
      if (hit and (1'u16 shl i)) != 0: last[i] = u
    found = found or hit
  for k in 0..<10:
    let i = k xor side
    if i < hearts:
      result[1+k] = float32(if (found and (1'u16 shl i)) != 0: t - last[i] else: min(t, 2760)) / 2760

type
  GameSpec = object
    seed, rules, map: int32   # map -1 = the rules' own island (Heartwick)
    team, scripted: bool      # team vision; base.bas on every seat (else sticky random heads)
    parked: bool              # every seat stays put facing its own side (no enemy in sight: the 720 cap is reached)
    ticks, fire: int          # fire: one random tick in `fire` shoots (0 = never)
  GameStats = object
    rows, dead, enemyZero, enemyMid, enemyCap, heartZero, heartMid, heartCap, ticks: int

proc game(g: GameSpec): GameStats =
  ## One game on a 204 and a 205 handle side by side: the first 740 columns byte-equal, the block equal to the reference.
  var r = initRand(g.seed.int)
  let a = pw_create_observation(g.seed, 0, 204)
  let b = pw_create_observation(g.seed, 0, 205)
  doAssert a != nil and b != nil
  defer: pw_destroy(a); pw_destroy(b)
  for h in [a, b]:
    doAssert pw_set_rules(h, g.rules) == 0 and pw_set_map(h, g.map) == 0
    setVision(h, g.team)
    doAssert pw_reset(h, g.seed, 0) == 0
  if g.scripted:
    let source = baseScript()
    for s in 0..<Seats:
      for h in [a, b]:
        doAssert pw_set_seat_script(h, s.cint, cbuf(source), source.len.int32) == 0
  var oa = newSeq[cfloat](Seats*S)
  var ob = newSeq[cfloat](Seats*W)
  var ra, rb = newSeq[cfloat](Seats)
  var actions = newSeq[int32](Seats*5)
  var hold = newSeq[int](Seats)
  var rewards, terminals = newSeq[cfloat](Seats)
  var recs = newSeq[HuntRecord](Seats)
  for step in 0..<g.ticks:
    doAssert pw_observe(a, fbuf(oa), fbuf(ra)) == 0
    doAssert pw_observe(b, fbuf(ob), fbuf(rb)) == 0
    let w = worldOf(b)
    let t = w.tick.int
    let hearts = min(10, w.controlHearts.len)
    for s in 0..<Seats:
      for i in 0..<S: doAssert bits(oa[s*S+i]) == bits(ob[s*W+i])
      inc result.rows
      if not recs[s].take(w[], s):
        for c in 0..<11: doAssert ob[s*W+S+c] == 0
        inc result.dead
        continue
      let want = recs[s].reference(t, team(s), hearts)
      for c in 0..<11:
        if bits(ob[s*W+S+c]) != bits(want[c]):
          echo "DIFF seed ", g.seed, " tick ", t, " seat ", s, " column ", S+c, ": ", ob[s*W+S+c], " want ", want[c]
          doAssert false
      if want[0] == 0: inc result.enemyZero elif want[0] == 1: inc result.enemyCap else: inc result.enemyMid
      for k in 0..<10:
        if (k xor team(s)) >= hearts: continue
        if want[1+k] == 0: inc result.heartZero elif want[1+k] == 1: inc result.heartCap else: inc result.heartMid
    if g.parked:
      for s in 0..<Seats:
        actions[s*5] = 0
        actions[s*5+1] = 21   # compass west, mirrored for team 1: toward the seat's own side
        actions[s*5+2] = 0; actions[s*5+3] = 0; actions[s*5+4] = 0
    elif not g.scripted:
      for s in 0..<Seats:
        # sticky random heads: head for a heart (or anywhere) for a while
        if hold[s] == 0:
          actions[s*5] = if r.rand(1) == 0: int32(1 + r.rand(max(hearts, 1) - 1)) else: int32(r.rand(50))
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
    inc result.ticks
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
  let path = getTempDir()/("paintbot-view-t-" & $getCurrentProcessId() & ".bas")
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

suite "Observation contract teams.view.1t (205)":
  configureRules(NativeRules)

  test "sizes, hashes, user-input variants; 201 / 203 / 204 unchanged; 208 refused":
    check TeamsViewTSize == 751 and HuntWidth == 11 and HuntHearts == 10
    check EnemyGapCap == 720 and HeartGapCap == 2760 and HeartNear2 == 360000
    check ObservationContractTeamsView1tHash == sha256Hex("paintbot-pw.teams.view.1t")
    check observationContractVersion(ObservationContractTeamsView1tHash) == ocTeamsView1t
    check observationContractId(ocTeamsView1t) == "paintbot-pw.teams.view.1t"
    check observationSize(ocTeamsView1t) == 751
    check pw_observation_size_for(205) == 751 and pw_observation_size_for(204) == 740 and
      pw_observation_size_for(203) == 612 and pw_observation_size_for(201) == 512 and pw_observation_size_for(208) == -1
    let h = pw_create_observation(1, 600, 205)
    require h != nil
    defer: pw_destroy(h)
    check pw_create_observation(1, 600, 208) == nil
    check pw_handle_observation_size(h) == 751 and pw_observation_contract(h) == 205
    var hex: array[65, char]
    check pw_observation_contract_hash(205, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
    check $cast[cstring](addr hex[0]) == ObservationContractTeamsView1tHash
    check pw_observation_contract_hash(208, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == -1
    let hk = pw_create_observation_inputs_v(1, 600, 205, 43)
    require hk != nil
    defer: pw_destroy(hk)
    check pw_handle_observation_size(hk) == 751 + 43 and pw_handle_user_inputs(hk) == 43
    check pw_create_observation_inputs_v(1, 600, 208, 43) == nil
    for k in [1'i32, 43, 256]:
      check pw_user_inputs_contract_hash_v(205, k, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
      check $cast[cstring](addr hex[0]) == userInputsContractHash(k.int, ocTeamsView1t)
      check userInputsContractHash(k.int, ocTeamsView1t) == sha256Hex("paintbot-pw.teams.view.1tu" & $k)
    for k in [0'i32, 257]:
      check pw_user_inputs_contract_hash_v(205, k, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == -1
    check pw_user_inputs_contract_hash_v(208, 1, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == -1
    check userInputsContractId(43, ocTeamsView1t) == "paintbot-pw.teams.view.1tu43"
    check userInputsContract(userInputsContractHash(43, ocTeamsView1t)) == (ocTeamsView1t, 43)
    check pairs(ocTeamsView1t, acTeamsView1) and pairs(ocTeamsView1t, acTeamsView1Raw)
    check pairedAction(ocTeamsView1t) == acTeamsView1
    check ocTeamsView1t in TeamsObservationContracts and ocTeamsView1t in HistoryObservationContracts
    check pw_set_game_mode(h, 1) == -1   # the teams game only

  test "every hunt column equals the from-scratch reference; the first 740 equal a 204 handle's":
    var total: GameStats
    let specs = [
      GameSpec(seed: 61, rules: 48, map: -1, scripted: true, ticks: 1200),
      GameSpec(seed: 62, rules: 47, map: -1, ticks: 3200, fire: 6),
      GameSpec(seed: 63, rules: 48, map: -1, team: true, ticks: 3200),
      GameSpec(seed: 64, rules: 47, map: -1, team: true, scripted: true, ticks: 900),
      GameSpec(seed: 65, rules: 48, map: 0, ticks: 900, fire: 4),        # twin-mesas
      GameSpec(seed: 66, rules: 47, map: 7, scripted: true, ticks: 900),  # atoll
      GameSpec(seed: 67, rules: 48, map: 10, ticks: 1200, fire: 4),      # big-twin-mesas: 100 hearts, rows 0..9
      GameSpec(seed: 68, rules: 48, map: -1, parked: true, ticks: 1500),
      GameSpec(seed: 69, rules: 47, map: 3, parked: true, ticks: 1000)]   # crater
    var long = 0
    for g in specs:
      let s = game(g)
      echo "  seed ", g.seed, " rules ", g.rules, " map ", g.map, (if g.team: " team vision" else: ""),
        (if g.parked: " parked" elif g.scripted: " base.bas" else: " random heads"), ": ticks ", s.ticks, ", rows ", s.rows, ", dead ", s.dead,
        "; enemy 0 / mid / cap ", s.enemyZero, " / ", s.enemyMid, " / ", s.enemyCap,
        "; hearts 0 / mid / cap ", s.heartZero, " / ", s.heartMid, " / ", s.heartCap
      if s.ticks >= 2900: inc long
      total.rows += s.rows; total.dead += s.dead
      total.enemyZero += s.enemyZero; total.enemyMid += s.enemyMid; total.enemyCap += s.enemyCap
      total.heartZero += s.heartZero; total.heartMid += s.heartMid; total.heartCap += s.heartCap
    check long >= 2   # two games run past both caps
    check total.rows > 100000 and total.dead > 1000
    check total.enemyZero > 10000 and total.enemyMid > 10000 and total.enemyCap > 1000
    check total.heartZero > 1000 and total.heartMid > 100000 and total.heartCap > 10000

  test "scripted: parked, the walk to the cap, an enemy in and out of sight, a skipped observation, a repeated encode, death and respawn, a disguise, a new match, pw_reset":
    let h = pw_create_observation(71, 0, 205)
    require h != nil
    defer: pw_destroy(h)
    setVision(h, false)   # line of sight: an identity is visible only where this test puts it
    require pw_set_rules(h, 48) == 0 and pw_reset(h, 71, 0) == 0
    let w = worldOf(h)
    var ob = newSeq[cfloat](Seats*W)
    var rs = newSeq[cfloat](Seats)
    var hp: array[16, int32]
    proc prepare() =
      for s in 0..<Seats: hp[s] = w.cogs[s].hp
      for s in 1..<Seats: w.cogs[s].hp = 0
    prepare()
    require w.controlHearts.len == 10
    proc heart(i: int, dx = 0'i32): Point = Point(x: w.controlHearts[i].pos.x + dx, z: w.controlHearts[i].pos.z)
    proc nearHearts(p: Point): seq[int] =
      for i in 0..<w.controlHearts.len:
        if distance2(p, w.controlHearts[i].pos) <= 360000: result.add i
    let far = Point(x: 3200, z: 2000)
    require nearHearts(far).len == 0
    for i in 0..<10: require nearHearts(heart(i)) == @[i]
    require nearHearts(heart(2, 600)) == @[2] and nearHearts(heart(2, 601)).len == 0
    proc look(t: int, pos: Point, alive = true, other = -1, mask = 0xFFFF'u32): array[11, float32] =
      ## Seat 0 at `pos` (alive or dead) on tick t, facing +x; body `other` (if any) alive 150 u ahead of it, every
      ## other seat dead; seat 0's hunt block after the observe.
      w.tick = t.int32
      w.cogs[0].pos = pos
      w.cogs[0].hp = if alive: hp[0] else: 0
      w.cogs[0].aim = Point(x: pos.x + 1000, z: pos.z)
      for s in 1..<Seats: w.cogs[s].hp = 0
      if other >= 0:
        w.cogs[other].hp = hp[other]
        w.cogs[other].pos = Point(x: pos.x + 150, z: pos.z)
      if mask == 0xFFFF'u32: doAssert pw_observe(h, fbuf(ob), fbuf(rs)) == 0
      else: doAssert pw_observe_seats(h, mask, fbuf(ob), fbuf(rs)) == 0
      for c in 0..<11: result[c] = ob[S + c]
    proc sees(identity: int): bool =
      beginViews(w[])
      seatView(0).visible(identity) == 1 and seatView(0).playerHp(identity) > 0
    template q(n: int): float32 = float32(n) / 720
    template g(n: int): float32 = float32(n) / 2760
    proc row(t, e: int, near: array[10, int]): array[11, float32] =
      ## Seat 0 (team 0, r = map heart index) with the last enemy sighting e and the last visits near.
      result[0] = float32(min(t - e, 720)) / 720
      for r in 0..<10: result[1+r] = float32(min(t - near[r], 2760)) / 2760
    var n: array[10, int]   # the last visit to each heart (0 = the match start)
    var e = 0               # the last enemy sighting
    var x: array[11, float32]
    # nothing yet: the match start is the last sighting and visit
    check look(100, far) == row(100, e, n)
    check look(100, far)[0] == q(100) and look(100, far)[3] == g(100)
    # parked at exactly 600 u: within (inclusive)
    n[2] = 101
    x = look(101, heart(2, 600))
    check x == row(101, e, n) and x[3] == 0
    # 601 u: out, one tick since
    x = look(102, heart(2, 601))
    check x == row(102, e, n) and x[3] == g(1)
    # walking away: linear to exactly 1 at 2760 ticks, then held
    for d in [2, 100, 1380, 2759, 2760, 2761, 3000]:
      x = look(101 + d, far)
      check x == row(101 + d, e, n)
      check x[3] == float32(min(d, 2760)) / 2760
      check (x[3] == 1) == (d >= 2760)
    # an enemy in sight, then out: 0, then one tick, ..., exactly 1 at 720, held
    x = look(3200, far, other = 1)
    require sees(1)
    e = 3200
    check x == row(3200, e, n) and x[0] == 0
    check look(3201, far)[0] == q(1) and look(3201, far) == row(3201, e, n)
    check look(3919, far)[0] == q(719) and look(3920, far)[0] == 1 and look(4000, far)[0] == 1
    # a skipped observation takes nothing in: the visit on 4020 (seat 0 not observed) does not count
    n[4] = 4010
    check look(4010, heart(4)) == row(4010, e, n)
    discard look(4020, heart(4), mask = 0xFFFE'u32)
    x = look(4021, far)
    check x == row(4021, e, n) and x[5] == g(11)
    # a repeated encode in the same tick writes the same floats and takes nothing more in
    let first = look(4022, far)
    check look(4022, heart(6), other = 1) == first
    check first[7] == 1 and first[0] == 1
    check look(4023, far) == row(4023, e, n) and look(4023, far)[7] == 1
    # death and respawn: zeros while dead (near heart 8 and in sight of an enemy: neither counts), the clocks span the
    # death, and the spawn heart reads 0 on the first alive tick
    n[2] = 4099
    check look(4099, heart(2)) == row(4099, e, n)
    x = look(4100, far, other = 1)
    require sees(1)
    e = 4100
    check x == row(4100, e, n) and x[0] == 0
    for t in 4101..4110:
      x = look(t, heart(8), alive = false, other = 1)
      for c in 0..<11: check x[c] == 0
    n[0] = 4111
    x = look(4111, heart(0))
    check x == row(4111, e, n)
    check x[0] == q(11) and x[1] == 0 and x[3] == g(12) and x[9] == 1
    # a disguised enemy shows a friendly-parity identity: not an enemy sighting
    w.uniforms[1] = true
    x = look(4200, far, other = 1)
    require sees(2) and not sees(1)
    check x == row(4200, e, n) and x[0] == q(100)
    w.uniforms[1] = false
    # a disguised teammate shows an enemy-parity identity: an enemy sighting
    w.uniforms[2] = true
    x = look(4201, far, other = 2)
    require sees(3)
    e = 4201
    check x == row(4201, e, n) and x[0] == 0
    w.uniforms[2] = false
    # a tick before the last one taken in (a new match on the same seat) starts the clocks over
    n = default(array[10, int])
    e = 0
    x = look(50, far)
    check x == row(50, e, n) and x[0] == q(50) and x[3] == g(50)
    # pw_reset starts them over too: a visit at 5000, then a reset, then tick 5100 reads the match start, not 100 ticks
    discard look(5000, heart(2))
    require pw_reset(h, 72, 0) == 0
    prepare()
    x = look(5100, far)
    check x == row(5100, 0, default(array[10, int]))
    check x[3] == 1 and x[0] == 1

  test "fewer than ten hearts: rows past the heart count read 0, in either team's frame; no hearts at all":
    let h = pw_create_observation(73, 0, 205)
    require h != nil
    defer: pw_destroy(h)
    setVision(h, false)
    require pw_set_rules(h, 48) == 0 and pw_reset(h, 73, 0) == 0
    let w = worldOf(h)
    var ob = newSeq[cfloat](Seats*W)
    var rs = newSeq[cfloat](Seats)
    for s in 2..<Seats: w.cogs[s].hp = 0
    w.controlHearts.setLen(5)
    w.heartCaptures.setLen(5)
    # seat 0 faces west, seat 1 east: neither sees the other; both out of reach of every heart
    w.cogs[0].pos = Point(x: 3000, z: 2000); w.cogs[0].aim = Point(x: 2000, z: 2000)
    w.cogs[1].pos = Point(x: 3400, z: 2000); w.cogs[1].aim = Point(x: 4400, z: 2000)
    for s in 0..1:
      for c in w.controlHearts: require distance2(w.cogs[s].pos, c.pos) > 360000
    w.tick = 200
    require pw_observe(h, fbuf(ob), fbuf(rs)) == 0
    for s in 0..1:
      check ob[s*W + S] == float32(200) / 720
      for r in 0..<10:
        let want = if (r xor s) < 5: float32(200) / 2760 else: 0'f32
        check ob[s*W + S + 1 + r] == want
    w.controlHearts.setLen(0)
    w.heartCaptures.setLen(0)
    w.tick = 201
    require pw_observe(h, fbuf(ob), fbuf(rs)) == 0
    for s in 0..1:
      check ob[s*W + S] == float32(201) / 720
      for r in 0..<10: check ob[s*W + S + 1 + r] == 0

  test "hearts come in mirrored pairs (heart i and i xor 1) on every shipped map and on Heartwick at rules 40 .. 48":
    var cases: seq[(int32, int32)]
    for rules in NativeRules..LiveRules: cases.add (rules.int32, -1'i32)
    for m in 0..<MapNames.len: cases.add (LiveRules.int32, m.int32)
    for (rules, m) in cases:
      let h = pw_create_observation(74, 0, 205)
      require h != nil
      require pw_set_rules(h, rules) == 0 and pw_set_map(h, m) == 0 and pw_reset(h, 74, 0) == 0
      let w = worldOf(h)
      checkpoint "rules " & $rules & " map " & (if m < 0: "Heartwick" else: MapNames[m])
      check w.controlHearts.len >= 10 and w.controlHearts.len mod 2 == 0
      for i in 0..<w.controlHearts.len: check w.controlHearts[i xor 1].pos == mirror(w.controlHearts[i].pos)
      if m >= 0 or rules == LiveRules:
        echo "  ", (if m < 0: "Heartwick" else: MapNames[m]), ": ", w.controlHearts.len, " hearts"
      pw_destroy(h)

  test "a team-1 seat at the mirrored position reads the same hunt block as its team-0 counterpart":
    let h = pw_create_observation(75, 0, 205)
    require h != nil
    defer: pw_destroy(h)
    setVision(h, false)
    require pw_set_rules(h, 48) == 0 and pw_reset(h, 75, 0) == 0
    let w = worldOf(h)
    var ob = newSeq[cfloat](Seats*W)
    var rs = newSeq[cfloat](Seats)
    for s in 2..<Seats: w.cogs[s].hp = 0
    # seat 0's walk (heart 0, 2, 4, 6, 8 and the open), seat 1 on its mirror image, aims mirrored too
    var path: seq[(int, Point, Point)]
    var t = 10
    for i in [0, 2, 4, 6, 8]:
      let p = w.controlHearts[i].pos
      for k in 0..<5:
        path.add (t, Point(x: p.x + int32(k*200), z: p.z), Point(x: p.x + 1000, z: p.z + 300))
        t += 7
      t += 300
    path.add (3500, Point(x: 1000, z: 1000), Point(x: 5000, z: 2000))
    path.add (3510, Point(x: 2800, z: 2000), Point(x: 5000, z: 2000))   # facing each other across the centre
    var compared, seen = 0
    for (tick, p, aim) in path:
      w.tick = tick.int32
      w.cogs[0].pos = p; w.cogs[0].aim = aim
      w.cogs[1].pos = mirror(p); w.cogs[1].aim = mirror(aim)
      require pw_observe(h, fbuf(ob), fbuf(rs)) == 0
      beginViews(w[])
      let v01 = seatView(0).visible(1)
      require v01 == seatView(1).visible(0)
      if v01 == 1: inc seen
      for c in 0..<11: check bits(ob[S + c]) == bits(ob[W + S + c])
      inc compared
    check compared == path.len and seen > 0

  test "BASIC equivalence: policy.bas's hunt inputs 36..42 are 3 x these columns one tick later, within 1e-3":
    const K = 43
    var init = newSeq[string](K)
    for i in 0..<K: init[i] = "0"
    let manifest = "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      userInputsContractHash(K, ocTeamsView1t) & "\", \"action_contract\": \"" & ActionContractTeamsView1Hash &
      "\", \"sha256\": {}, \"user_inputs\": {\"count\": " & $K & ", \"init\": [" & init.join(", ") & "]}}"
    let policy = HuntSnippet & Head & Decoder
    var compared, enemyMid, enemyCap, heartZero, heartMid, heartCap, respawns = 0
    var worst = 0.0
    for (seed, rules, team, ticks) in [(81'i32, 48'i32, false, 3300), (82'i32, 47'i32, true, 1500)]:
      let h = pw_create_observation_inputs_v(seed, 0, 205, K)
      require h != nil
      require pw_set_rules(h, rules) == 0
      setVision(h, team)
      require pw_reset(h, seed, 0) == 0
      for s in 0..<Seats: require setPolicy(h, s, policy, manifest) == 0
      let n = W + K
      var cur, prev = newSeq[cfloat](Seats*n)
      var rs = newSeq[cfloat](Seats)
      var wasAlive: array[LegacySeats, bool]
      var logits = newSeq[float32](Seats*LogitSize)
      var actions = newSeq[int32](Seats*5)
      var rewards, terminals = newSeq[cfloat](Seats)
      var hold: array[LegacySeats, int]
      var r = initRand(seed.int)
      for step in 0..<ticks:
        require pw_observe(h, fbuf(cur), fbuf(rs)) == 0
        let w = worldOf(h)
        for s in 0..<Seats:
          let o = s*n
          if step > 0 and wasAlive[s]:
            # row t's user inputs are what the script computed on tick t - 1, the tick of the previous row
            let g4 = float64(cur[o + W + 36])
            let e4 = 3*float64(prev[o + S])
            worst = max(worst, abs(g4 - e4))
            check abs(g4 - e4) <= 1e-3
            if prev[o + S] > 0 and prev[o + S] < 1: inc enemyMid
            if prev[o + S] == 1: inc enemyCap
            for k in 0..<6:
              let g5 = float64(cur[o + W + 37 + k])
              let e5 = 3*float64(prev[o + S + 1 + H0[k]])
              worst = max(worst, abs(g5 - e5))
              check abs(g5 - e5) <= 1e-3
              let c = prev[o + S + 1 + H0[k]]
              if c == 0: inc heartZero elif c == 1: inc heartCap else: inc heartMid
            inc compared
          let alive = w.cogs[s].hp > 0
          if alive and not wasAlive[s] and step > 0: inc respawns
          wasAlive[s] = alive
        prev = cur
        for s in 0..<Seats:
          if hold[s] == 0:
            for i in 0..<LogitSize: logits[s*LogitSize + i] = 0
            logits[s*LogitSize + (if r.rand(1) == 0: 1 + r.rand(9) else: r.rand(50))] = 5          # movement
            logits[s*LogitSize + 51 + r.rand(24)] = 5                                               # aim
            logits[s*LogitSize + 76 + int(r.rand(5) == 0)] = 5                                      # fire
            logits[s*LogitSize + 78] = 5; logits[s*LogitSize + 80] = 5                              # no grenade, no sneak
            hold[s] = 1 + r.rand(200)
          dec hold[s]
        let rc = pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals))
        require rc == 0 or rc == -2
        if rc != 0 or terminals[0] > 0: break
      for s in 0..<Seats: check pw_seat_script_status(h, s.cint, nil, 0) == 1
      pw_destroy(h)
    echo "  compared ", compared, " seat-ticks, worst |input - 3 x column| ", worst, "; enemy mid / cap ", enemyMid,
      " / ", enemyCap, "; hearts 0 / mid / cap ", heartZero, " / ", heartMid, " / ", heartCap, "; respawns ", respawns
    check compared > 50000 and enemyMid > 1000 and enemyCap > 100 and heartZero > 100 and heartMid > 10000 and
      heartCap > 1000 and respawns > 0

  test "zero-column widening: a 204 bundle and its 205 copy with 11 zero columns at 740 play identically (logits and hashes)":
    let install = pw_create_observation(76, 0, 205)
    require install != nil and pw_set_rules(install, 48) == 0 and pw_set_map(install, -1) == 0 and
      pw_reset(install, 76, 0) == 0
    discard pw_state_hash(install)   # installs the handle's rules and map on this thread
    pw_destroy(install)
    var compared = 0
    for k in [0, 4]:
      var r = initRand(91 + k)
      let narrowIn = S + k
      var encoder = newSeq[float32](narrowIn*Hidden)
      for x in encoder.mitems: x = float32(r.rand(2.0) - 1.0) * 0.08
      var rest = newSeq[float32](3*Hidden*Hidden + LogitSize*Hidden)
      for i, x in rest.mpairs: x = float32(r.rand(2.0) - 1.0) * (if i < 3*Hidden*Hidden: 0.15'f32 else: 0.6'f32)
      var wide = newSeq[float32]((W + k)*Hidden)
      for o in 0..<Hidden:
        for i in 0..<narrowIn:
          wide[o*(W + k) + (if i < S: i else: i + 11)] = encoder[o*narrowIn + i]
      let narrowHash = if k > 0: userInputsContractHash(k, ocTeamsView1s) else: ObservationContractTeamsView1sHash
      let wideHash = if k > 0: userInputsContractHash(k, ocTeamsView1t) else: ObservationContractTeamsView1tHash
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

  test "pw_world_save / pw_world_load carry the hunt clocks: the loaded handle's rows continue exactly":
    let a = pw_create_observation(77, 900, 205)
    let b = pw_create_observation(77, 900, 205)
    require a != nil and b != nil
    defer: pw_destroy(a); pw_destroy(b)
    var oa = newSeq[cfloat](Seats*W)
    var ob = newSeq[cfloat](Seats*W)
    var rs = newSeq[cfloat](Seats)
    var actions = newSeq[int32](Seats*5)
    var rewards, terminals = newSeq[cfloat](Seats)
    for t in 0..<300:
      for s in 0..<Seats: actions[s*5] = int32(1 + (t div 60 + s) mod 10)   # heart to heart
      check pw_observe(a, fbuf(oa), fbuf(rs)) == 0
      check pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    let size = pw_world_save(a, nil, 0)
    require size > 0
    var blob = newSeq[byte](size)
    require pw_world_save(a, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == size
    require pw_world_load(b, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == 0
    var visited, apart = 0
    for t in 0..<60:
      check pw_observe(a, fbuf(oa), fbuf(rs)) == 0
      check pw_observe(b, fbuf(ob), fbuf(rs)) == 0
      for i in 0..<Seats*W: check bits(oa[i]) == bits(ob[i])
      for s in 0..<Seats:
        for r in 0..<10:
          let c = oa[s*W + S + 1 + r]
          if c == 0: inc visited elif c < 1: inc apart
      for s in 0..<Seats: actions[s*5] = int32(1 + (t div 20 + s) mod 10)
      check pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check visited > 0 and apart > 0
