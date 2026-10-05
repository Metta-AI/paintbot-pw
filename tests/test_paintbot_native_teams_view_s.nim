## Observation contract teams.view.1s (204): teams.view.1h's 612 floats, then the engine's 128-float stop-clock block
## (neural_contract.encodeTeamsViewS). Through the native ABI: sizes and hashes; the first 612 columns byte-equal to a
## 203 handle's on the same game; every stop-clock column against an independent reference that keeps each seat's whole
## sighting record and recomputes the eight values from scratch every tick; scripted footwork with exact expected
## values (a stand, an un-read stop, a death and respawn, an un-read across a sight loss, a skipped observation, the
## 32-tick caps, a dead observer, a repeated encode, pw_reset); pw_world_save / load; and the sufficiency check: a port
## of a stop-reading script's stateful per-foe gun clock (lastFire / nextFire) is reproduced, tick for tick, by a
## MEMORYLESS function of the eight columns. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, random, importutils, os]
import ../examples/paintbot/[sim, neural_contract, native_env, seat_view]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
privateAccess(NativeEnv)

const
  W = 740
  Root = currentSourcePath().parentDir.parentDir

proc worldOf(h: pointer): ptr World = addr cast[ptr NativeEnv](h).world

# ---------------------------------------------------------------------------------------------------------------------
# The independent reference: the seat's whole record (one entry per tick it was observed alive on), and the eight
# values recomputed from it by scanning back, with no running state.
type
  Sight = object
    seen: array[16, bool]
    pos: array[16, Point]
  Record = object
    at: seq[int]          # tick -> index into sights, -1 = the seat took nothing in on that tick
    sights: seq[Sight]

proc take(r: var Record, w: World, slot: int): bool =
  ## Record this tick for the seat if it is alive; whether it was.
  beginViews(w)
  let v = seatView(slot)
  while r.at.len <= w.tick.int: r.at.add -1
  if v.selfHp <= 0: return false
  var s: Sight
  for j in 0..<16:
    if v.visible(j) == 1:
      s.seen[j] = true
      s.pos[j] = Point(x: v.playerX(j), z: v.playerY(j))
  r.at[w.tick.int] = r.sights.len
  r.sights.add s
  true

proc seenAt(r: Record, u, j: int): bool = u >= 0 and u < r.at.len and r.at[u] >= 0 and r.sights[r.at[u]].seen[j]
proc posAt(r: Record, u, j: int): Point = r.sights[r.at[u]].pos[j]
proc stepAt(r: Record, u, j: int): int =
  ## 0 = no step at u (not visible at u and u - 1), 1 = still, 2 = fast
  if not (r.seenAt(u, j) and r.seenAt(u - 1, j)): return 0
  let a = r.posAt(u, j)
  let b = r.posAt(u - 1, j)
  let d = int64(a.x - b.x)*int64(a.x - b.x) + int64(a.z - b.z)*int64(a.z - b.z)
  if d <= 64: 1 else: 2
proc isStop(r: Record, u, j: int): bool = r.stepAt(u, j) == 1 and r.stepAt(u - 1, j) == 2

proc reference(r: Record, t, j: int): array[8, float32] =
  result = [1'f32, 0, 0, 0, 1, 0, 1, 0]
  var stop = -1
  for u in countdown(t, 0):
    if r.isStop(u, j): stop = u; break
  if stop >= 0:
    var brk = -1
    for u in stop+1..t:
      if r.stepAt(u, j) == 2: brk = u; break
    if t - stop <= 32:
      result[0] = float32(t - stop) / 32
      result[1] = 1
      result[2] = float32(min((if brk >= 0: brk else: t + 1) - stop, 8)) / 8
      result[3] = float32(brk < 0)
    for s in countdown(stop - 1, 0):
      if not r.isStop(s, j): continue
      var held = true
      for u in s+1..s+4:
        if r.stepAt(u, j) == 2: held = false
      if held:
        if t - s <= 32:
          result[4] = float32(t - s) / 32
          result[5] = 1
        break
  if r.seenAt(t, j):
    var first = t
    while r.seenAt(first - 1, j): dec first
    var before = first - 1
    while before >= 0 and not r.seenAt(before, j): dec before
    result[6] = float32(if before < 0: 32 else: min(first - before, 32)) / 32
    result[7] = float32(min(t - first + 1, 32)) / 32
  else:
    var last = t - 1
    while last >= 0 and not r.seenAt(last, j): dec last
    result[6] = float32(if last < 0: 32 else: min(t - last, 32)) / 32

# ---------------------------------------------------------------------------------------------------------------------
# The sufficiency check. A stop-reading script keeps, per foe, a gun clock from its footwork: a stop sets lastFire =
# t - 1 and nextFire = t + 24; a fast step within 5 ticks of lastFire un-reads the stop (the values before it come
# back); a foe coming into view after more than 12 unseen ticks whose nextFire has passed gets nextFire = t + 1. This
# is that state machine, stateful, from the same sightings (one documented deviation from the script: its lastSeen
# starts at 0, here at "never").
type GunClock = object
  lastSeen, lastFire, nextFire, prevFire, prevNext: int
  old, vel: Point

proc initClock(): GunClock = GunClock(lastSeen: -1000, lastFire: -1000, nextFire: 31)

proc advance(c: var GunClock, t: int, visible: bool, pos: Point, stats: var array[3, int]) =
  if not visible: return
  if c.lastSeen == t - 1:
    let fx = pos.x - c.old.x
    let fz = pos.z - c.old.z
    let cm = int64(fx)*fx + int64(fz)*fz
    let pm = int64(c.vel.x)*c.vel.x + int64(c.vel.z)*c.vel.z
    if cm <= 64 and pm > 64:
      c.prevFire = c.lastFire
      c.prevNext = c.nextFire
      c.lastFire = t - 1
      c.nextFire = t + 24
      inc stats[0]
    if cm > 64 and t - c.lastFire <= 5:
      c.lastFire = c.prevFire
      c.nextFire = c.prevNext
      inc stats[1]
    c.vel = Point(x: fx, z: fz)
  else:
    if t - c.lastSeen > 12 and c.nextFire < t:
      c.nextFire = t + 1
      inc stats[2]
    c.vel = Point(x: 0, z: 0)
  c.old = pos
  c.lastSeen = t

proc window(next, t: int): int = (if next - t in 0..25: next - t else: -1)

proc reconstruct(c: openArray[cfloat], t: int, visibleNow: bool): (int, int) =
  ## (min(t - lastFire, 33), nextFire - t within 0 .. 25 else -1) from the eight columns, the tick and visible-now
  ## alone: no state.
  let age = int(c[0]*32 + 0.5)
  let valid = c[1] == 1
  let unread = valid and c[3] == 0 and int(c[2]*8 + 0.5) <= 4
  # the stop the clock stands on: the current one unless it was un-read, then the last one that held
  let eff = if valid and not unread: age elif c[5] == 1: int(c[4]*32 + 0.5) else: -1
  let sinceFire = if eff >= 0: min(eff + 1, 33) else: 33
  # no such stop within 32 ticks: whatever nextFire holds has passed, unless it is still the opening value
  var next = if eff >= 0: t - eff + 24 else: 31
  let run = int(c[7]*32 + 0.5)
  if visibleNow and run <= 2 and int(c[6]*32 + 0.5) > 12:
    let first = t - run + 1
    if next < first: next = first + 1
  (sinceFire, window(next, t))

proc baseScript(): string = readFile(Root / "coworld/paintbot/players/base.bas")

suite "Observation contract teams.view.1s (204)":
  configureRules(NativeRules)

  test "sizes, hashes, user-input variants; 201 / 203 unchanged":
    check TeamsViewSSize == 740 and StopWidth == 128 and StopIdentityWidth == 8
    check observationContractVersion(ObservationContractTeamsView1sHash) == ocTeamsView1s
    check observationContractId(ocTeamsView1s) == "paintbot-pw.teams.view.1s"
    check pw_observation_size_for(204) == 740 and pw_observation_size_for(203) == 612 and
      pw_observation_size_for(201) == 512 and pw_observation_size_for(207) == -1
    let h = pw_create_observation(1, 600, 204)
    require h != nil
    defer: pw_destroy(h)
    check pw_create_observation(1, 600, 207) == nil
    check pw_handle_observation_size(h) == 740 and pw_observation_contract(h) == 204
    var hex: array[65, char]
    check pw_observation_contract_hash(204, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
    check $cast[cstring](addr hex[0]) == ObservationContractTeamsView1sHash
    let hk = pw_create_observation_inputs_v(1, 600, 204, 109)
    require hk != nil
    defer: pw_destroy(hk)
    check pw_handle_observation_size(hk) == 740 + 109
    check pw_user_inputs_contract_hash_v(204, 109, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
    check $cast[cstring](addr hex[0]) == userInputsContractHash(109, ocTeamsView1s)
    check userInputsContractId(109, ocTeamsView1s) == "paintbot-pw.teams.view.1su109"
    check userInputsContract(userInputsContractHash(109, ocTeamsView1s)) == (ocTeamsView1s, 109)
    check pairs(ocTeamsView1s, acTeamsView1) and pairs(ocTeamsView1s, acTeamsView1Raw)
    check pairedAction(ocTeamsView1s) == acTeamsView1
    check pw_set_game_mode(h, 1) == -1   # the teams game only

  proc game(seed: int32, scripted, team: bool, ticks: int): array[8, int] =
    ## One game on a 203 and a 204 handle side by side. Returns [rows compared, valid stops seen, un-read stops seen,
    ## valid stands seen, clock ticks compared, clock stop events, clock un-reads, clock reappearances].
    var r = initRand(seed.int)
    let a = pw_create_observation(seed, 0, 203)
    let b = pw_create_observation(seed, 0, 204)
    doAssert a != nil and b != nil
    defer: pw_destroy(a); pw_destroy(b)
    doAssert pw_set_rules(a, 48) == 0 and pw_set_rules(b, 48) == 0
    for h in [a, b]:   # line-of-sight vision (sight comes and goes) or team vision
      cast[ptr NativeEnv](h).vision = team
      cast[ptr NativeEnv](h).nextVision = team
    doAssert pw_reset(a, seed, 0) == 0 and pw_reset(b, seed, 0) == 0
    if scripted:
      let source = baseScript()
      for s in 0..<Seats:
        for h in [a, b]:
          doAssert pw_set_seat_script(h, s.cint, cast[ptr UncheckedArray[char]](unsafeAddr source[0]),
            source.len.int32) == 0
    var oa = newSeq[cfloat](Seats*612)
    var ob = newSeq[cfloat](Seats*W)
    var ra, rb = newSeq[cfloat](Seats)
    var actions = newSeq[int32](Seats*5)
    var hold = newSeq[int](Seats)
    var rewards, terminals = newSeq[cfloat](Seats)
    var recs = newSeq[Record](Seats)
    var clocks = newSeq[array[16, GunClock]](Seats)
    var stats: array[3, int]
    for s in 0..<Seats:
      for j in 0..<16: clocks[s][j] = initClock()
    for step in 0..<ticks:
      doAssert pw_observe(a, fbuf(oa), fbuf(ra)) == 0
      doAssert pw_observe(b, fbuf(ob), fbuf(rb)) == 0
      let w = worldOf(b)
      let t = w.tick.int
      for s in 0..<Seats:
        for i in 0..<612: doAssert oa[s*612+i] == ob[s*W+i]
        let alive = recs[s].take(w[], s)
        inc result[0]
        if not alive:
          for i in 612..<W: doAssert ob[s*W+i] == 0
          continue
        let sight = recs[s].sights[^1]
        for j in 0..<16:
          let o = s*W + 612 + j*8
          let want = recs[s].reference(t, j)
          for c in 0..<8:
            if ob[o+c] != want[c]:
              echo "DIFF seed ", seed, " tick ", t, " seat ", s, " identity ", j, " column ", c, ": ", ob[o+c],
                " want ", want[c]
              doAssert false
          if want[1] == 1:
            inc result[1]
            if want[3] == 0 and want[2] <= 0.5: inc result[2]
          if want[5] == 1: inc result[3]
          clocks[s][j].advance(t, sight.seen[j], sight.pos[j], stats)
          # lastFire on every tick; nextFire on the ticks the identity is visible, the only ones the script reads it on
          var got = reconstruct(ob.toOpenArray(o, o+7), t, sight.seen[j])
          var truth = (min(t - clocks[s][j].lastFire, 33), window(clocks[s][j].nextFire, t))
          if not sight.seen[j]:
            got[1] = -1
            truth[1] = -1
          if got != truth:
            echo "CLOCK seed ", seed, " tick ", t, " seat ", s, " identity ", j, ": columns give ", got, ", the clock ",
              truth, " columns ", @(ob.toOpenArray(o, o+7))
            doAssert false
          inc result[4]
      for s in 0..<Seats:
        # sticky random footwork: walk a few ticks, stand a few ticks
        if hold[s] == 0:
          actions[s*5] = if r.rand(2) == 0: 0'i32 else: int32(r.rand(50))
          hold[s] = 1 + r.rand(9)
        dec hold[s]
        actions[s*5+1] = int32(r.rand(24))
        actions[s*5+2] = int32(r.rand(3) == 0); actions[s*5+3] = 0; actions[s*5+4] = 0
      let rc1 = pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals))
      let rc2 = pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals))
      doAssert rc1 == rc2
      doAssert pw_state_hash(a) == pw_state_hash(b)
      if rc1 != 0 or terminals[0] > 0: break
    for i in 0..2: result[5+i] = stats[i]

  test "every column equals the from-scratch reference; the first 612 equal a 203 handle's; the gun clock is a memoryless function of the columns":
    var total: array[8, int]
    for (seed, scripted, team, ticks) in [(41'i32, true, false, 700), (42'i32, false, false, 500),
        (43'i32, true, true, 500), (44'i32, false, true, 300)]:
      let g = game(seed, scripted, team, ticks)
      echo "  seed ", seed, (if scripted: " scripts" else: " random footwork"), (if team: ", team vision" else: ""),
        ": rows ", g[0], ", valid stops ", g[1],
        ", un-read ", g[2], ", stands ", g[3], "; clock ticks ", g[4], ", stop events ", g[5], ", un-reads ", g[6],
        ", reappearances ", g[7]
      for i in 0..<8: total[i] += g[i]
    check total[0] > 20000 and total[1] > 5000 and total[2] > 200 and total[3] > 2000
    check total[4] > 200000 and total[5] > 500 and total[6] > 50 and total[7] > 50

  test "scripted footwork: a stand, an un-read stop, death and respawn, an un-read across a sight loss, a skipped observation, the caps":
    let h = pw_create_observation(51, 0, 204)
    require h != nil
    defer: pw_destroy(h)
    cast[ptr NativeEnv](h).vision = true       # team vision: a living teammate is always visible to a living seat
    cast[ptr NativeEnv](h).nextVision = true
    require pw_set_rules(h, 48) == 0 and pw_reset(h, 51, 0) == 0
    let w = worldOf(h)
    var ob = newSeq[cfloat](Seats*W)
    var rs = newSeq[cfloat](Seats)
    let hp = w.cogs[2].hp
    let home = w.cogs[2].pos
    var x = 0'i32
    proc see(tick: int, move: int32, alive = true): array[8, float32] =
      ## Put identity 2 (seat 0's teammate) `move` further along x, or dead, at `tick`; seat 0's columns for it.
      w.tick = tick.int32
      x += move
      w.cogs[2].pos = Point(x: home.x + x, z: home.z)
      w.cogs[2].hp = if alive: hp else: 0
      doAssert pw_observe(h, fbuf(ob), fbuf(rs)) == 0
      for c in 0..<8: result[c] = ob[612 + 2*8 + c]
    template q(n: int): float32 = float32(n) / 32
    template e(n: int): float32 = float32(n) / 8
    const None = [1'f32, 0, 0, 0]
    proc cols(stop: array[4, float32], stand: array[2, float32], gap, run: float32): array[8, float32] =
      [stop[0], stop[1], stop[2], stop[3], stand[0], stand[1], gap, run]
    # first sight, two fast steps, then a stand of eight ticks
    check see(100, 0) == cols(None, [1'f32, 0], 1, q(1))
    check see(101, 28) == cols(None, [1'f32, 0], 1, q(2))
    check see(102, 28) == cols(None, [1'f32, 0], 1, q(3))
    check see(103, 0) == cols([q(0), 1, e(1), 1], [1'f32, 0], 1, q(4))        # the stop
    check see(104, 8) == cols([q(1), 1, e(2), 1], [1'f32, 0], 1, q(5))        # 8 units is still
    for k in 2..7: check see(103 + k, 0) == cols([q(k), 1, e(min(k + 1, 8)), 1], [1'f32, 0], 1, q(4 + k))
    check see(111, 28) == cols([q(8), 1, e(8), 0], [1'f32, 0], 1, q(12))      # it moves: the stand's length is final
    check see(112, 9) == cols([q(9), 1, e(8), 0], [1'f32, 0], 1, q(13))       # 9 units is fast
    # a second stop, un-read after two ticks; the stand at 103 is the one that held
    check see(113, 0) == cols([q(0), 1, e(1), 1], [q(10), 1], 1, q(14))
    check see(114, 0) == cols([q(1), 1, e(2), 1], [q(11), 1], 1, q(15))
    check see(115, 28) == cols([q(2), 1, e(2), 0], [q(12), 1], 1, q(16))      # live 0, length 2: un-read
    # a third stop right after: the un-read one does not become the stand
    check see(116, 0) == cols([q(0), 1, e(1), 1], [q(13), 1], 1, q(17))
    for k in 1..4: check see(116 + k, 0) == cols([q(k), 1, e(k + 1), 1], [q(13 + k), 1], 1, q(17 + k))
    check see(121, 28) == cols([q(5), 1, e(5), 0], [q(18), 1], 1, q(22))      # broken after 5 ticks: it held
    check see(122, 0) == cols([q(0), 1, e(1), 1], [q(6), 1], 1, q(23))        # so it is the stand of the next stop
    # death: not visible, the stop's clock runs on; respawn elsewhere is a first sight, not a step
    check see(123, 0, alive = false) == cols([q(1), 1, e(2), 1], [q(7), 1], q(1), 0)
    check see(124, 0, alive = false) == cols([q(2), 1, e(3), 1], [q(8), 1], q(2), 0)
    check see(125, 5000) == cols([q(3), 1, e(4), 1], [q(9), 1], q(3), q(1))   # the jump is no step
    check see(126, 0) == cols([q(4), 1, e(5), 1], [q(10), 1], q(3), q(2))     # still after no step: no new stop
    check see(127, 28) == cols([q(5), 1, e(5), 0], [q(11), 1], q(3), q(3))    # first fast step 5 ticks after: it held
    # a stop un-read across a one-tick sight loss
    check see(128, 0) == cols([q(0), 1, e(1), 1], [q(6), 1], q(3), q(4))
    check see(129, 0, alive = false) == cols([q(1), 1, e(2), 1], [q(7), 1], q(1), 0)
    check see(130, 0) == cols([q(2), 1, e(3), 1], [q(8), 1], q(2), q(1))
    check see(131, 28) == cols([q(3), 1, e(3), 0], [q(9), 1], q(2), q(2))     # fast within 4 ticks of the stop
    # a repeated encode of the same tick changes nothing
    check see(131, 0) == cols([q(3), 1, e(3), 0], [q(9), 1], q(2), q(2))
    # two skipped observations are a sight gap of three ticks
    check see(134, 28) == cols([q(6), 1, e(3), 0], [q(12), 1], q(3), q(1))
    # the caps: the stand (122) and the stop (128) are valid through 32 ticks, then read as none
    check see(154, 0) == cols([q(26), 1, e(3), 0], [q(32), 1], q(20), q(1))
    check see(155, 0) == cols([q(27), 1, e(3), 0], [1'f32, 0], q(20), q(2))
    check see(160, 0) == cols([q(32), 1, e(3), 0], [1'f32, 0], q(5), q(1))
    check see(161, 0) == cols(None, [1'f32, 0], q(5), q(2))
    check see(230, 0) == cols(None, [1'f32, 0], q(32), q(1))                  # the gap is capped
    for k in 1..40: discard see(230 + k, 0)
    check see(271, 0) == cols(None, [1'f32, 0], q(32), q(32))                 # the run is capped
    # a dead observer: its block is zeros and the tick is a sight gap for it
    let own = w.cogs[0].hp
    w.cogs[0].hp = 0
    discard see(272, 0)
    for i in 612..<W: check ob[i] == 0
    w.cogs[0].hp = own
    check see(273, 0) == cols(None, [1'f32, 0], q(2), q(1))
    # stop-clock columns of an identity never seen: none, never
    discard see(274, 28)
    discard see(275, 28)
    check see(276, 0) == cols([q(0), 1, e(1), 1], [1'f32, 0], q(2), q(4))
    # pw_reset starts every clock over
    check pw_reset(h, 52, 0) == 0
    check pw_observe(h, fbuf(ob), fbuf(rs)) == 0
    for s in 0..<Seats:
      for j in 0..<16:
        let o = s*W + 612 + j*8
        check ob[o] == 1 and ob[o+1] == 0 and ob[o+2] == 0 and ob[o+3] == 0 and ob[o+4] == 1 and ob[o+5] == 0
        check ob[o+6] == 1 and (ob[o+7] == q(1) or ob[o+7] == 0)

  test "pw_world_save / pw_world_load carry the stop clocks: the loaded handle's rows continue exactly":
    let a = pw_create_observation(45, 900, 204)
    let b = pw_create_observation(45, 900, 204)
    require a != nil and b != nil
    defer: pw_destroy(a); pw_destroy(b)
    var oa = newSeq[cfloat](Seats*W)
    var ob = newSeq[cfloat](Seats*W)
    var rs = newSeq[cfloat](Seats)
    var actions = newSeq[int32](Seats*5)
    var rewards, terminals = newSeq[cfloat](Seats)
    for t in 0..<60:
      for s in 0..<Seats: actions[s*5] = (if (t div 5 + s) mod 2 == 0: 0'i32 else: int32((t + s) mod 51))
      check pw_observe(a, fbuf(oa), fbuf(rs)) == 0
      check pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    let size = pw_world_save(a, nil, 0)
    require size > 0
    var blob = newSeq[byte](size)
    require pw_world_save(a, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == size
    require pw_world_load(b, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == 0
    var stops = 0
    for t in 0..<30:
      check pw_observe(a, fbuf(oa), fbuf(rs)) == 0
      check pw_observe(b, fbuf(ob), fbuf(rs)) == 0
      for i in 0..<Seats*W: check oa[i] == ob[i]
      for s in 0..<Seats:
        for j in 0..<16:
          if oa[s*W + 612 + j*8 + 1] == 1: inc stops
      for s in 0..<Seats: actions[s*5] = (if (t div 4 + s) mod 2 == 0: 0'i32 else: int32((t * 3 + s) mod 51))
      check pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check stops > 0
