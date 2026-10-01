## Observation contract teams.view.1h (203): teams.view.1's 512 floats, then the engine's 100-float motion-history
## block (neural_contract.encodeTeamsViewH). Through the native ABI: sizes and hashes, the base 512 columns byte-equal to
## a 201 handle's on the same game, every history column against an independent per-seat record built from SeatView,
## gaps (a skipped observation) and pw_reset starting the history over. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, random, importutils]
import ../examples/paintbot/[sim, neural_contract, native_env, seat_view]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
privateAccess(NativeEnv)

proc worldOf(h: pointer): ptr World = addr cast[ptr NativeEnv](h).world

type Rec = object
  tick: int
  alive: bool
  self: Point
  seen: array[16, bool]
  pos: array[16, Point]

proc snapshot(w: World, slot: int): Rec =
  beginViews(w)
  let v = seatView(slot)
  result = Rec(tick: w.tick.int, alive: v.selfHp > 0, self: Point(x: v.selfX, z: v.selfY))
  for j in 0..<16:
    if v.visible(j) == 1:
      result.seen[j] = true
      result.pos[j] = Point(x: v.playerX(j), z: v.playerY(j))

proc expected(cur: Rec, r1, r2: ptr Rec, slot: int): seq[float32] =
  ## the 100 history floats, from the test's own records (nil = no record at that tick)
  result = newSeq[float32](HistoryWidth)
  if not cur.alive: return
  let flip = float32(mapFlip(slot))
  for k, r in [r1, r2]:
    if r == nil: continue
    for j in 0..<16:
      if cur.seen[j] and r.seen[j]:
        result[j*6 + k*3] = float32(r.pos[j].x - cur.pos[j].x) * flip / 28'f32
        result[j*6 + k*3 + 1] = float32(r.pos[j].z - cur.pos[j].z) * flip / 28'f32
        result[j*6 + k*3 + 2] = 1
  if r1 != nil:
    result[96] = float32(cur.self.x - r1.self.x) * flip / 28'f32
    result[97] = float32(cur.self.z - r1.self.z) * flip / 28'f32
    if r2 != nil:
      result[98] = float32(r1.self.x - r2.self.x) * flip / 28'f32
      result[99] = float32(r1.self.z - r2.self.z) * flip / 28'f32

suite "Observation contract teams.view.1h (203)":
  configureRules(NativeRules)

  test "sizes, hashes, user-input variants; 201 / 202 unchanged":
    check TeamsViewHSize == 612 and HistoryWidth == 100
    check observationContractVersion(ObservationContractTeamsView1hHash) == ocTeamsView1h
    check pw_observation_size_for(203) == 612 and pw_observation_size_for(201) == 512
    let h = pw_create_observation(1, 600, 203)
    require h != nil
    defer: pw_destroy(h)
    check pw_handle_observation_size(h) == 612 and pw_observation_contract(h) == 203
    var hex: array[65, char]
    check pw_observation_contract_hash(203, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
    check $cast[cstring](addr hex[0]) == ObservationContractTeamsView1hHash
    let hk = pw_create_observation_inputs_v(1, 600, 203, 244)
    require hk != nil
    defer: pw_destroy(hk)
    check pw_handle_observation_size(hk) == 612 + 244
    check pw_user_inputs_contract_hash_v(203, 244, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
    check $cast[cstring](addr hex[0]) == userInputsContractHash(244, ocTeamsView1h)
    check userInputsContractId(244, ocTeamsView1h) == "paintbot-pw.teams.view.1hu244"
    check pairs(ocTeamsView1h, acTeamsView1) and pairs(ocTeamsView1h, acTeamsView1Raw)
    check pw_set_game_mode(h, 1) == -1   # the teams game only

  test "every history column equals the per-seat record; the base 512 equal a 201 handle's (300 ticks)":
    var r = initRand(7)
    let a = pw_create_observation(41, 900, 201)
    let b = pw_create_observation(41, 900, 203)
    defer: pw_destroy(a); pw_destroy(b)
    var oa = newSeq[cfloat](Seats*512)
    var ob = newSeq[cfloat](Seats*612)
    var ra, rb = newSeq[cfloat](Seats)
    var actions = newSeq[int32](Seats*5)
    var rewards, terminals = newSeq[cfloat](Seats)
    var recs: array[16, seq[Rec]]
    var compared, withHistory = 0
    for t in 0..<300:
      check pw_observe(a, fbuf(oa), fbuf(ra)) == 0
      check pw_observe(b, fbuf(ob), fbuf(rb)) == 0
      let w = worldOf(b)
      for s in 0..<Seats:
        for i in 0..<512: check oa[s*512+i] == ob[s*612+i]
        let cur = snapshot(w[], s)
        var r1, r2: ptr Rec = nil
        for q in recs[s].mitems:
          if q.tick == cur.tick - 1 and q.alive: r1 = addr q
          if q.tick == cur.tick - 2 and q.alive: r2 = addr q
        let want = expected(cur, r1, r2, s)
        for i in 0..<HistoryWidth:
          check abs(ob[s*612 + 512 + i] - want[i]) <= 1e-6
        if r1 != nil: inc withHistory
        inc compared
        if cur.alive: recs[s].add cur
      for s in 0..<Seats:
        actions[s*5] = int32(r.rand(50)); actions[s*5+1] = int32(r.rand(24))
        actions[s*5+2] = int32(r.rand(1)); actions[s*5+3] = 0; actions[s*5+4] = 0
      let rc1 = pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals))
      let rc2 = pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals))
      check rc1 == rc2
      if rc1 != 0 or terminals[0] > 0: break
    check compared > 3000 and withHistory > 2000

  test "a skipped observation is a gap (zeros for t-1, t-2 kept); two skipped = all zeros; pw_reset starts over":
    let h = pw_create_observation(43, 900, 203)
    defer: pw_destroy(h)
    var ob = newSeq[cfloat](Seats*612)
    var rs = newSeq[cfloat](Seats)
    var actions = newSeq[int32](Seats*5)
    for s in 0..<Seats: actions[s*5] = 43   # everyone steps, so own displacement is nonzero
    var rewards, terminals = newSeq[cfloat](Seats)
    for t in 0..<3:
      check pw_observe(h, fbuf(ob), fbuf(rs)) == 0
      check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_observe(h, fbuf(ob), fbuf(rs)) == 0
    var moved = false
    for s in 0..<Seats:
      if ob[s*612 + 608] != 0 or ob[s*612 + 609] != 0: moved = true
    check moved
    # skip one tick's observation: the next one has no t-1 record (its t-1 columns and both own displacements are 0),
    # but the observation two ticks back is still its t-2
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_observe(h, fbuf(ob), fbuf(rs)) == 0
    var t2seen = false
    for s in 0..<Seats:
      for j in 0..<16:
        for c in 0..<3: check ob[s*612 + 512 + j*6 + c] == 0
        if ob[s*612 + 512 + j*6 + 5] == 1: t2seen = true
      for i in 608..<612: check ob[s*612 + i] == 0
    check t2seen
    # skip two more: neither t-1 nor t-2 was observed, so the whole block is 0
    for k in 0..<3: check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_observe(h, fbuf(ob), fbuf(rs)) == 0
    for s in 0..<Seats:
      for i in 512..<612: check ob[s*612 + i] == 0
    check pw_reset(h, 44, 900) == 0
    check pw_observe(h, fbuf(ob), fbuf(rs)) == 0
    for s in 0..<Seats:
      for i in 512..<612: check ob[s*612 + i] == 0
