## Teacher class masks for action contract 16 (raw), training library only (native
## pw_teacher_classes). Given a teacher's decided command for a seat and the pre-step world, the
## masks name, per head, the raw bins whose decode (players/neural_decode.bas, raw branch)
## reproduces that command within tolerance:
##   walk (head 0; heads 7 x 8 for the grid alias 43..50): the engine's movement this tick is the
##     same: (moves, direction(pos, dest, speed)) with dest = the goal (direct) or waypointFor's,
##     speed as mechanics.nim sets it (carrying, territory boost, sneak, wading). WalkMode wmRouted (the
##     default) sets only bins it can prove without a path search: a goal waypointFor walks to straight
##     with the teacher's step, or one it routes to the same target cell as the teacher's (the same
##     dest); wmExact runs waypointFor for every goal (slow);
##   aim (head 1; heads 5 x 6 per identity; head 9 for the look alias 17..24): on a gun ORDER tick
##     (shoot, cooldown 0, windup 0, no spray can) the candidate's direction from the seat is within
##     one SD of the teacher's (zcov_raw's expression: |atan2 difference| <= 26.5 / 5250 x
##     max(gunSpreadPercent(pos, A), 1) / 100); on any other tick the facing half of canSeePoint
##     gives the same answer for every other live cog; keep (bin 0) reproduces the aim the seat's
##     decoder would keep; with no teacher aim (A = 0, 0) the class is keep alone;
##   fire / grenade / sneak: the teacher's value.
## Telemetry for training only: nothing here writes the world, a seat or a decision (the path search
## and sight caches it reads are scratch whose answers never depend on them).
##
## Layout (TeacherClassBytes = 8224 bytes; bit i of a section is byte i shr 3, bit i and 7):
##   [0, 7)       head 0, 51 bits (43..50 all equal: some grid (direction, distance) is in the class)
##   [7, 263)     walk grid, 2048 bits, direction * 8 + distance index
##   [263, 267)   head 1, 25 bits (17..24 all equal: some look direction is in the class)
##   [267, 8205)  offsets, 16 x 3969 bits, identity * 3969 + bin5 * 63 + bin6 (zero unless head-1 bit 1+identity)
##   [8205, 8221) look, 128 bits
##   8221 fire, 8222 grenade, 8223 sneak: bit v set = value v is in the class
when not defined(pwTraining): {.error: "teacher class masks exist only in the training library".}
import std/[math, strutils, bitops]
import sim, seat_view, neural_contract

const
  TcHead0At* = 0
  TcWalkAt* = 7
  TcHead1At* = 263
  TcOffsetAt* = 267
  TcLookAt* = 8205
  TcFireAt* = 8221
  TcGrenadeAt* = 8222
  TcSneakAt* = 8223
  TeacherClassBytes* = 8224
  OffsetRow = RawOffsetBins*RawOffsetBins

# The decoder's integer cos / sin tables (x 10000), read from its own source so the two never differ.
const DecoderSourceRaw = staticRead("players/neural_decode.bas")
proc rawTable(name: string): array[WalkDirections, int32] {.compileTime.} =
  var seen: array[WalkDirections, bool]
  for line in DecoderSourceRaw.splitLines:
    let s = line.strip
    if s.startsWith(name & "(") and " = " in s:
      let index = parseInt(s[name.len+1 ..< s.find(')')])
      result[index] = int32(parseInt(s.split(" = ")[1].strip))
      seen[index] = true
  for i in 0..<WalkDirections: doAssert seen[i], name & " table entry missing: " & $i
const
  RawCos* = rawTable("rwc")
  RawSin* = rawTable("rws")

type
  TeacherCommand* = object
    walk*, shoot*, grenade*, sneak*, direct*: bool
    goal*, aim*: Point
  KeepState* = object
    ## What the seat's decoder would re-issue for "keep" this tick.
    known*: bool
    point*: Point
  ClassMasks* = array[TeacherClassBytes, uint8]

proc setBit(m: var ClassMasks, at, i: int) {.inline.} =
  m[at + (i shr 3)] = m[at + (i shr 3)] or uint8(1 shl (i and 7))
proc getBit*(m: ClassMasks, at, i: int): bool {.inline.} = ((m[at + (i shr 3)] shr (i and 7)) and 1) == 1

proc rnd10k*(v: int): int =
  ## v / 10000 rounded half away from zero (the decoder's rnd10k).
  if v >= 0: (v + 5000) div 10000 else: -((-v + 5000) div 10000)
proc clampToMap*(x, z: int): Point = point(clamp(x, minX(), maxX()), clamp(z, minZ(), maxZ()))
proc walkClamp(p: Point): Point =
  point(clamp(p.x.int, minX()+100, maxX()-100), clamp(p.z.int, minZ()+100, maxZ()-100))
proc flipOf(slot: int): int = (if team(slot) == 1: -1 else: 1)

proc gridGoal*(pos: Point, flip, dir, dist: int): Point =
  let r = WalkDistances[dist]
  clampToMap(pos.x.int + flip*rnd10k(r*RawCos[dir].int), pos.z.int + flip*rnd10k(r*RawSin[dir].int))
proc lookPoint*(pos: Point, flip, k: int): Point =
  clampToMap(pos.x.int + flip*rnd10k(LookDistance*RawCos[2*k].int), pos.z.int + flip*rnd10k(LookDistance*RawSin[2*k].int))
proc offsetPoint*(q: Point, flip, bx, bz: int): Point =
  clampToMap(q.x.int + (bx-RawOffsetCentre)*RawOffsetStep*flip, q.z.int + (bz-RawOffsetCentre)*RawOffsetStep*flip)

# ---------------------------------------------------------------------------------------
# Predicates (shared by the fast masks and the reference).
type MoveKey* = tuple[moves: bool, v: Point]
proc moveSpeed(w: World, s: int, sneak: bool): int =
  ## mechanics.nim's speed for the seat this tick.
  let pos = w.cogs[s].pos
  result = if w.cogs[s].carrying: MoveSpeed*7 div 10 else: MoveSpeed
  result = boostedSpeed(result, w.territoryBoost(s))
  if visionRulesVersion >= 26 and sneak: result = result div 2
  if visionRulesVersion >= 30 and riverBlend(pos.x.int, pos.z.int) > 0 and
      terrainHeight(pos.x.int, pos.z.int) < RiverWaterHeight:
    result = result div 4
proc moveKey*(w: World, s: int, goal: Point, direct: bool, speed: int): MoveKey =
  ## The seat's movement this tick toward its (walk-clamped) goal, as mechanics.nim moves it.
  let pos = w.cogs[s].pos
  let dest = if direct: goal else: w.waypointFor(s, pos, goal)
  if distance2(pos, dest) > speed.int64*speed: (true, direction(pos, dest, speed)) else: (false, Point())

proc coneMask*(w: World, s: int, facing: Point): uint32 =
  ## The facing half of canSeePoint toward every other live cog (bit per seat).
  let c = w.cogs[s]
  let fx = int64(facing.x) - c.pos.x
  let fz = int64(facing.z) - c.pos.z
  for o in 0..<Seats:
    if o == s or w.cogs[o].hp <= 0: continue
    let dx = int64(w.cogs[o].pos.x) - c.pos.x
    let dz = int64(w.cogs[o].pos.z) - c.pos.z
    let dist = dx*dx + dz*dz
    if dist == 0: continue
    let dot = fx*dx + fz*dz
    if not (dot <= 0 or 4*dot*dot < (fx*fx + fz*fz)*dist): result = result or (1'u32 shl o)

proc withinSd*(pos, a, p: Point, sd: float64): bool =
  ## zcov_raw's aim test: the angle between pos -> p and pos -> a is at most sd.
  let ang = arctan2(float(a.z.int - pos.z.int), float(a.x.int - pos.x.int))
  var da = abs(arctan2(float(p.z.int - pos.z.int), float(p.x.int - pos.x.int)) - ang)
  if da > PI: da = 2*PI - da
  da <= sd

type AimTest = object
  order: bool
  pos, a: Point
  sd: float64
  mask: uint32
  # The other live cogs the cone test reads, as offsets from the seat (coneMask's order and skips).
  cogs: int
  cogId: array[MaxSeats, int]
  cogX, cogZ, cogD: array[MaxSeats, int64]

proc coneBit(t: AimTest, k: int, fx, fz: int64): bool {.inline.} =
  let dot = fx*t.cogX[k] + fz*t.cogZ[k]
  dot > 0 and 4*dot*dot >= (fx*fx + fz*fz)*t.cogD[k]
proc coneOf(t: AimTest, p: Point, active: uint32): uint32 {.inline.} =
  ## coneMask(w, s, p) restricted to the cogs in `active` (bit k = the k-th cog of t).
  let fx = int64(p.x) - t.pos.x
  let fz = int64(p.z) - t.pos.z
  var bits = active
  while bits != 0:
    let k = countTrailingZeroBits(bits)
    bits = bits and (bits - 1)
    if t.coneBit(k, fx, fz): result = result or (1'u32 shl t.cogId[k])
proc allCogs(t: AimTest): uint32 = (if t.cogs == 0: 0'u32 else: uint32((1'u64 shl t.cogs) - 1))
proc inClass(t: AimTest, w: World, s: int, p: Point): bool {.inline.} =
  if t.order: withinSd(t.pos, t.a, p, t.sd) else: t.coneOf(p, t.allCogs) == t.mask

proc aimTest(w: World, s: int, cmd: TeacherCommand): AimTest =
  let pos = w.cogs[s].pos
  result.pos = pos
  result.a = cmd.aim
  result.order = cmd.shoot and w.cogs[s].cooldown == 0 and w.equipment[s].windup == 0 and not w.equipment[s].sprayCan
  doAssert Seats <= 32, "teacher class masks are for the 16-seat teams game"
  for o in 0..<Seats:
    if o == s or w.cogs[o].hp <= 0: continue
    let dx = int64(w.cogs[o].pos.x) - pos.x
    let dz = int64(w.cogs[o].pos.z) - pos.z
    if dx*dx + dz*dz == 0: continue
    result.cogId[result.cogs] = o
    result.cogX[result.cogs] = dx; result.cogZ[result.cogs] = dz; result.cogD[result.cogs] = dx*dx + dz*dz
    inc result.cogs
  if result.order:
    result.sd = 26.5 / 5250.0 * max(w.gunSpreadPercent(pos, cmd.aim), 1).float / 100.0
  else:
    result.mask = coneMask(w, s, cmd.aim)
    doAssert result.coneOf(cmd.aim, result.allCogs) == result.mask

proc keepState*(w: World, s: int, known: bool): KeepState =
  ## The decoder's kept point is the engine's stored aim (it keeps what it last ordered, or its
  ## walking goal when it ordered none, as the engine stores them); `known` is the decoder's
  ## aimKnown (it ran on the previous tick of this life and had something to keep).
  KeepState(known: known, point: w.cogs[s].aim)

proc binaries(m: var ClassMasks, cmd: TeacherCommand) =
  m[TcFireAt] = uint8(1 shl cmd.shoot.int)
  m[TcGrenadeAt] = uint8(1 shl cmd.grenade.int)
  m[TcSneakAt] = uint8(1 shl cmd.sneak.int)

# ---------------------------------------------------------------------------------------
# Fast masks.
proc rectFrame(t: AimTest, q: Point, flip, bx0, bx1, bz0, bz1: int, corners: var array[4, Point]): bool =
  ## The rectangle's corner points when every point of it is unclamped (inside the map), the seat lies
  ## outside it and its directions from the seat span less than 90 degrees (every corner pair has a
  ## positive dot product): then a cog's cone answer, which changes only at two directions 120 degrees
  ## apart, is the same at every point when it is the same at the four corners, and the directions of
  ## its points lie between the corners'.
  let xa = q.x.int + (bx0-RawOffsetCentre)*RawOffsetStep*flip
  let xb = q.x.int + (bx1-RawOffsetCentre)*RawOffsetStep*flip
  let za = q.z.int + (bz0-RawOffsetCentre)*RawOffsetStep*flip
  let zb = q.z.int + (bz1-RawOffsetCentre)*RawOffsetStep*flip
  let x0 = min(xa, xb); let x1 = max(xa, xb)
  let z0 = min(za, zb); let z1 = max(za, zb)
  if x0 < minX() or x1 > maxX() or z0 < minZ() or z1 > maxZ(): return false
  let pos = t.pos
  if pos.x.int >= x0 and pos.x.int <= x1 and pos.z.int >= z0 and pos.z.int <= z1: return false
  corners = [point(x0, z0), point(x1, z0), point(x0, z1), point(x1, z1)]
  for i in 0..3:
    for j in i+1..3:
      let dot = (int64(corners[i].x)-pos.x)*(int64(corners[j].x)-pos.x) + (int64(corners[i].z)-pos.z)*(int64(corners[j].z)-pos.z)
      if dot <= 0: return false
  true

proc orderRect(t: AimTest, corners: array[4, Point]): int =
  ## Gun-order rectangle: 1 every point within the SD, 0 none, -1 undecided. Decided only with a
  ## margin far wider than float rounding (the per-point test is zcov_raw's float expression).
  let ax = float(t.a.x.int - t.pos.x.int); let az = float(t.a.z.int - t.pos.z.int)
  if ax == 0 and az == 0: return -1
  var lo = Inf; var hi = -Inf
  for c in corners:
    let cx = float(c.x.int - t.pos.x.int); let cz = float(c.z.int - t.pos.z.int)
    let d = arctan2(ax*cz - az*cx, ax*cx + az*cz)
    lo = min(lo, d); hi = max(hi, d)
  const Margin = 1e-9
  if hi - lo > PI/2: return -1
  if lo > t.sd + Margin or hi < -t.sd - Margin: return 0
  if lo >= -t.sd + Margin and hi <= t.sd - Margin: return 1
  -1

proc fillOffsets(m: var ClassMasks, t: AimTest, w: World, s, identity: int, q: Point, flip, bx0, bx1, bz0, bz1: int,
    active, fixed: uint32): bool =
  ## Marks the rectangle's bins of `identity` that are in the class; true when any is. Cone ticks carry
  ## the cogs whose answer may still vary (`active`) and the answers already settled for the others
  ## (`fixed`, seat bits): a settled answer that differs from the teacher's rules the rectangle out.
  var active = active
  var fixed = fixed
  var corners: array[4, Point]
  let framed = t.rectFrame(q, flip, bx0, bx1, bz0, bz1, corners)
  let base = identity*OffsetRow
  template fillAll() =
    for bx in bx0..bx1:
      for bz in bz0..bz1: m.setBit(TcOffsetAt, base + bx*RawOffsetBins + bz)
    return true
  if framed:
    if t.order:
      case t.orderRect(corners)
      of 0: return false
      of 1: fillAll()
      else: discard
    else:
      var bits = active
      while bits != 0:
        let k = countTrailingZeroBits(bits)
        bits = bits and (bits - 1)
        let fx0 = int64(corners[0].x) - t.pos.x; let fz0 = int64(corners[0].z) - t.pos.z
        let first = t.coneBit(k, fx0, fz0)
        var same = true
        for c in corners[1..3]:
          if t.coneBit(k, int64(c.x) - t.pos.x, int64(c.z) - t.pos.z) != first: same = false; break
        if same:
          active = active and not (1'u32 shl k)
          let bit = 1'u32 shl t.cogId[k]
          if first: fixed = fixed or bit
          if (t.mask and bit) != (fixed and bit): return false   # a settled cog disagrees: none is in
      if active == 0: fillAll()
  let n = (bx1-bx0+1)*(bz1-bz0+1)
  if n <= 16 or (not framed and n <= 64):
    for bx in bx0..bx1:
      for bz in bz0..bz1:
        let p = offsetPoint(q, flip, bx, bz)
        let ok = if t.order: withinSd(t.pos, t.a, p, t.sd)
                 elif framed: (fixed or t.coneOf(p, active)) == t.mask
                 else: t.coneOf(p, t.allCogs) == t.mask
        if ok:
          m.setBit(TcOffsetAt, base + bx*RawOffsetBins + bz); result = true
    return
  let (a2, f2) = if framed: (active, fixed) else: (t.allCogs, 0'u32)
  let bxm = (bx0+bx1) div 2
  let bzm = (bz0+bz1) div 2
  if bx1 > bx0 and bz1 > bz0:
    result = m.fillOffsets(t, w, s, identity, q, flip, bx0, bxm, bz0, bzm, a2, f2) or result
    result = m.fillOffsets(t, w, s, identity, q, flip, bxm+1, bx1, bz0, bzm, a2, f2) or result
    result = m.fillOffsets(t, w, s, identity, q, flip, bx0, bxm, bzm+1, bz1, a2, f2) or result
    result = m.fillOffsets(t, w, s, identity, q, flip, bxm+1, bx1, bzm+1, bz1, a2, f2) or result
  elif bx1 > bx0:
    result = m.fillOffsets(t, w, s, identity, q, flip, bx0, bxm, bz0, bz1, a2, f2) or result
    result = m.fillOffsets(t, w, s, identity, q, flip, bxm+1, bx1, bz0, bz1, a2, f2) or result
  else:
    result = m.fillOffsets(t, w, s, identity, q, flip, bx0, bx1, bz0, bzm, a2, f2) or result
    result = m.fillOffsets(t, w, s, identity, q, flip, bx0, bx1, bzm+1, bz1, a2, f2) or result

type WalkMode* = enum
  wmRouted   ## B (default): a goal walked straight with the teacher's step, or routed to the target cell the
             ## teacher's own goal is routed to (the same field, so the same dest); every bin set is in the
             ## exact class, a routed goal reaching the same step through another target cell is missed
  wmExact    ## C: the exact class, waypointFor for every goal (slow)

proc straightKey(pos, goal: Point, speed: int): MoveKey =
  if distance2(pos, goal) > speed.int64*speed: (true, direction(pos, goal, speed)) else: (false, Point())

type WalkJudge* = object
  ## One seat-tick's walk test (teacherClasses and the reference share it: the class's definition).
  w: ptr World
  s, speed: int
  pos: Point
  want*: MoveKey
  mode: WalkMode
  planned: bool       # rules 38 on: waypointFor's straight / routed decision is available
  teacherTarget: int  # the cell the teacher's goal is routed to; -2: walked straight or direct
proc walkJudge*(w: World, s: int, cmd: TeacherCommand, mode: WalkMode): WalkJudge =
  result = WalkJudge(w: unsafeAddr w, s: s, pos: w.cogs[s].pos, speed: moveSpeed(w, s, cmd.sneak), mode: mode,
    planned: routePlanned(), teacherTarget: -2)
  let goal = if cmd.walk: walkClamp(cmd.goal) else: w.cogs[s].goal
  result.want = moveKey(w, s, goal, cmd.direct, result.speed)
  if result.planned: w.routePrepare(s, result.pos)
  if result.planned and not cmd.direct and not w.routeStraight(s, result.pos, goal):
    result.teacherTarget = w.routeTarget(s, result.pos, goal)
proc teacherRouted*(j: WalkJudge): bool =
  ## The teacher's own goal is routed by waypointFor's field search (not walked straight or direct).
  j.teacherTarget >= -1
proc straightMatches(j: WalkJudge, c: Point): bool {.inline.} =
  ## straightKey(pos, c, speed) == want. A moving step v = direction(pos, c, speed) truncates
  ## u * speed / isqrt(|u|^2) per component, so |u x v| < 2 |u| and u . v > 0 whenever it can
  ## equal want.v: the exact key is computed only for goals passing that.
  let ux = int64(c.x) - j.pos.x
  let uz = int64(c.z) - j.pos.z
  let d2 = ux*ux + uz*uz
  if not j.want.moves: return d2 <= j.speed.int64*j.speed
  if d2 <= j.speed.int64*j.speed: return false
  let cross = ux*j.want.v.z - uz*j.want.v.x
  if ux*j.want.v.x + uz*j.want.v.z <= 0 or cross*cross >= 4*d2: return false
  straightKey(j.pos, c, j.speed) == j.want

proc inClass*(j: WalkJudge, goal: Point): bool =
  ## Whether walking to `goal` (as a decoded walkTo, walk-clamped by the engine) is in the class.
  template w: untyped = j.w[]   # no copy of the world
  let c = walkClamp(goal)
  if j.mode == wmExact or not j.planned: return moveKey(w, j.s, c, false, j.speed) == j.want
  if j.straightMatches(c):
    # The straight step matches: walked straight, or routed to the teacher's target cell.
    if w.routeStraight(j.s, j.pos, c): return true
    return j.teacherTarget >= -1 and w.routeTargetIs(j.s, c, j.teacherTarget)
  # The straight step differs: only a routed goal sharing the teacher's routed target cell.
  j.teacherTarget >= -1 and w.routeTargetIs(j.s, c, j.teacherTarget) and not w.routeStraight(j.s, j.pos, c)

proc teacherClasses*(w: World, s: int, cmd: TeacherCommand, keep: KeepState, m: var ClassMasks,
    mode = wmRouted) =
  ## The fast masks (see the module comment). `w` is the pre-step world; seat `s` must be alive.
  for i in 0..<m.len: m[i] = 0
  beginViews(w)
  let v = seatView(s)
  let pos = w.cogs[s].pos
  let flip = flipOf(s)
  # Walk (goals deduplicated after the engine's walk clamp).
  let judge = walkJudge(w, s, cmd, mode)
  proc walks(g: Point): bool = judge.inClass(g)
  let stay = walks(pos)
  if stay: m.setBit(TcHead0At, 0)
  for b in 1..10:
    if (if b-1 < v.heartCount.int: walks(point(v.controlX(b-1), v.controlY(b-1))) else: stay): m.setBit(TcHead0At, b)
  for b in 11..42:
    let p = v.pickupRow(b-11)
    if (if p.visible: walks(point(p.x, p.z)) else: stay): m.setBit(TcHead0At, b)
  var grid = false
  for dir in 0..<WalkDirections:
    for dist in 0..<WalkDistances.len:
      if walks(gridGoal(pos, flip, dir, dist)):
        m.setBit(TcWalkAt, dir*WalkDistances.len + dist); grid = true
  if grid:
    for b in 43..50: m.setBit(TcHead0At, b)
  # Aim.
  if cmd.aim == Point():
    m.setBit(TcHead1At, 0)
    for j in 0..<TargetRows:
      if not v.identityRow(j).visible: m.setBit(TcHead1At, 1+j)
  else:
    let t = aimTest(w, s, cmd)
    let keepIn = keep.known and t.inClass(w, s, keep.point)
    if keepIn: m.setBit(TcHead1At, 0)
    for j in 0..<TargetRows:
      let r = v.identityRow(j)
      if not r.visible:
        if keepIn: m.setBit(TcHead1At, 1+j)
        continue
      if m.fillOffsets(t, w, s, j, point(r.x, r.z), flip, 0, RawOffsetBins-1, 0, RawOffsetBins-1, t.allCogs, 0):
        m.setBit(TcHead1At, 1+j)
    var look = false
    for k in 0..<LookDirections:
      if t.inClass(w, s, lookPoint(pos, flip, k)):
        m.setBit(TcLookAt, k); look = true
    if look:
      for b in 17..24: m.setBit(TcHead1At, b)
  m.binaries(cmd)
