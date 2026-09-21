## Paintbot PW WASM baseline: `players/base.bas` ported to the sprite protocol.
##
## The policy is the same one the BASIC file runs, section for section and with the same
## constants (world centimetres): a three-second progress timer, a fog-gated threat scan,
## two stateless squads of four that agree on a heart without talking, ten-second pickup
## memory, refusing a fight we are visibly losing, staggered callouts, short random legs
## across the line to the threat while in contact, a gun lead of the full windup minus our
## own drift, distance-matched grenade charges, and a quiet approach toward sounds.
##
## Three things the sprite interface changes, and nothing else:
## - Movement is an 8-way d-pad and the engine walks a WASM cog straight at the requested
##   point, so this file carries its own navigation: a cost field over the walkability map
##   (40 cm cells, no corner cutting) followed with a line-of-sight lookahead waypoint.
## - `lookAt`/`shootAt` become a turret that turns 5 brads (7 degrees) per tick. The aim is
##   laid on the lead point and the shot is ordered when the aim has settled on it at the
##   start of a leg that lasts the whole windup. The gun-ready icon replaces BASIC's
##   cooldown estimate. Idle scanning is a continuous sweep instead of four instant looks.
## - Sprite pixels are five centimetres; the red endzone sprite fixes the world origin.
## `carrying`/`thief` branches of the BASIC file are dead in territory play and not ported.
##
## Labels are the ones `coworld/paintbot/runtime/sprite.py` emits.
import std/[math, strutils, heapqueue]
import baseline/protocols

const
  Scale = 5                    # world centimetres per sprite pixel
  BtnUp = 1'u8
  BtnDown = 2'u8
  BtnLeft = 4'u8
  BtnRight = 8'u8
  BtnSelect = 16'u8
  BtnA = 32'u8
  BtnB = 64'u8
  BtnC = 128'u8
  AimBrads = 256
  AimRate = 5                  # brads a held rotate button turns per tick
  Deadband = 2                 # the turret cannot settle tighter than +-AimRate/2
  FireMiss = 150               # cm of perpendicular miss at range the shot still tolerates:
                               # a dodging target moves its impact point by more than this
                               # during the windup, so the turret's last 2 brads are not
                               # worth waiting for
  NavCell = 8                  # sprite pixels per nav cell (40 cm)
  RepathTicks = 10
  Lookahead = 6
  StepCost = 5'i32
  DiagCost = 7'i32
  MaxHearts = 16
  MaxPickups = 32
  HomeX = [960, 5440]
  HomeY = 2000

type
  Pt = object
    x, y: int                  # world cm; y is the map's downward axis (world z)

  Cog = object
    seen: bool
    pos: Pt
    hp: int
    team: int

  Heart = object
    pos: Pt
    owner: int
    captureTeam: int

  PickupSeen = object
    pos: Pt
    kind: int                  # 0 grenade, 1 spray, 2 medkit, 3 armor, 4 uniform

  Sound = object
    kind, direction, age: int

  Frame = object
    alive: bool
    me: Pt
    myHp, armorHp: int
    hasGrenade, hasSpray, gunReady: bool
    aim: int                   # own aim in brads, -1 when the marker is absent
    cogs: array[16, Cog]
    unknown: seq[Cog]          # visible bodies with no seat marker attached
    hearts: seq[Heart]
    pickups: seq[PickupSeen]
    trenches: seq[tuple[x0, y0, x1, y1: int]]
    sounds: seq[Sound]
    heard: seq[Pt]

  Memory = object
    pos: Pt
    kind: int
    tick: int

  Bot = ref object
    slot, team: int
    tick: int
    originX, originY: int      # sprite pixel of world (0, 0)
    originKnown: bool
    # navigation
    navBuilt: bool
    gridW, gridH: int
    cellWalk: seq[bool]
    navDist: seq[int32]
    navGoal: int
    navStamp: int
    # BASIC state, same names
    started: bool
    rngState: int
    zig: int
    lastPos: Pt
    progressPos: Pt
    avoidUntil: array[MaxHearts, int]
    objective: int
    memory: seq[Memory]
    oldPos: array[16, Pt]
    lastSeen: array[16, int]
    idleCapture: int
    legX, legY, legTicks, stalled, pathUntil: int
    # turret and actuators
    estAim: int
    rotSign: int
    firedLast: bool
    nadeCharge: int
    stuckTicks, jinkUntil: int
    jinkBits: uint8
    wasDead: bool

# ---- arithmetic -------------------------------------------------------------------------

proc isqrt(n: int): int =
  if n <= 0: 0 else: int(sqrt(float(n)))

proc d2(a, b: Pt): int =
  let dx = a.x - b.x
  let dy = a.y - b.y
  dx * dx + dy * dy

proc bradsOf(dx, dy: int): int =
  ## Aim angle toward (dx, dy): 0 east, 64 north (map y grows downward).
  if dx == 0 and dy == 0:
    return 0
  (int(round(arctan2(-float(dy), float(dx)) * 128.0 / PI)) + AimBrads) mod AimBrads

proc bradsErr(desired, current: int): int =
  ## Signed shortest arc from current to desired; positive = counter-clockwise (B).
  (desired - current + AimBrads + 128) mod AimBrads - 128

proc octantBits(dx, dy: int): uint8 =
  ## D-pad bits for the 8-way direction nearest to (dx, dy).
  if dx == 0 and dy == 0:
    return 0
  let octant = (int(round(arctan2(float(dy), float(dx)) / (PI / 4))) + 8) mod 8
  case octant
  of 0: BtnRight
  of 1: BtnRight or BtnDown
  of 2: BtnDown
  of 3: BtnDown or BtnLeft
  of 4: BtnLeft
  of 5: BtnLeft or BtnUp
  of 6: BtnUp
  else: BtnUp or BtnRight

proc nextRandom(bot: Bot) =
  bot.rngState = (bot.rngState * 75 + 74) mod 65537

# ---- frame parsing ----------------------------------------------------------------------

proc toWorld(bot: Bot, x, y, width, height: int): Pt =
  Pt(x: (x + width div 2 - bot.originX) * Scale,
     y: (y + height div 2 - bot.originY) * Scale)

proc parseFrame(bot: Bot, client: ProtocolClient): Frame =
  var
    bodies: seq[tuple[pos: Pt, team: int, isSelf: bool]]
    seats: seq[tuple[pos: Pt, id: int]]
    hps: seq[tuple[pos: Pt, hp, shield: int]]
    marks: seq[tuple[pos: Pt, label: string]]   # per-cog items: grenade, spray, ready
  result.aim = -1
  if not bot.originKnown:
    for o in client.spriteObjects():
      if o.label.startsWith("endzone red rect "):
        # The red endzone sprite sits at world (960, 2000): pixel (192, 400) plus the origin.
        bot.originX = o.x + o.width div 2 - 192
        bot.originY = o.y + o.height div 2 - 400
        bot.originKnown = true
        break
  if not bot.originKnown:
    return
  for o in client.spriteObjects():
    let p = bot.toWorld(o.x, o.y, o.width, o.height)
    let label = o.label
    if label.startsWith("self "):
      result.alive = true
      result.me = p
      bodies.add((p, bot.team, true))
    elif label.startsWith("player "):
      let parts = label.splitWhitespace()
      if parts.len >= 2:
        bodies.add((p, (if parts[1] == "red": 0 else: 1), false))
    elif label.startsWith("seat "):
      try:
        seats.add((p, parseInt(label[5 .. ^1])))
      except ValueError:
        discard
    elif label.startsWith("hp "):
      let tail = label[3 .. ^1]
      let slash = tail.find('/')
      if slash > 0:
        try:
          var shield = 0
          let cut = tail.find(" shield ")
          if cut >= 0:
            shield = parseInt(tail[cut + 8 .. ^1])
          hps.add((p, parseInt(tail[0 ..< slash]), shield))
        except ValueError:
          discard
    elif label == "grenade carried" or label == "spray can carried" or
        label == "fire icon" or label == "fire icon cooldown":
      marks.add((p, label))
    elif label.startsWith("own aim "):
      try:
        result.aim = parseInt(label[8 .. ^1])
      except ValueError:
        discard
    elif label.startsWith("control heart "):
      let parts = label.splitWhitespace()
      if parts.len == 5:
        try:
          let index = parseInt(parts[2])
          while result.hearts.len <= index:
            result.hearts.add(Heart(owner: -1, captureTeam: -1))
          result.hearts[index].pos = p
          result.hearts[index].owner = parseInt(parts[4])
        except ValueError:
          discard
    elif label.startsWith("control capture "):
      let parts = label.splitWhitespace()
      if parts.len == 8:
        try:
          let index = parseInt(parts[2])
          while result.hearts.len <= index:
            result.hearts.add(Heart(owner: -1, captureTeam: -1))
          result.hearts[index].captureTeam = parseInt(parts[4])
        except ValueError:
          discard
    elif o.width == 14 and o.height == 14:
      let kind = case label
        of "grenade": 0
        of "spray can": 1
        of "med kit": 2
        of "shield": 3
        of "uniform": 4
        else: -1
      if kind >= 0:
        result.pickups.add(PickupSeen(pos: p, kind: kind))
    elif label == "trench":
      let hw = o.width * Scale div 2
      let hh = o.height * Scale div 2
      result.trenches.add((p.x - hw, p.y - hh, p.x + hw, p.y + hh))
    elif label.startsWith("sound kind "):
      let parts = label.splitWhitespace()
      if parts.len == 9:
        try:
          result.sounds.add(Sound(kind: parseInt(parts[2]), direction: parseInt(parts[4]),
                                  age: parseInt(parts[8])))
        except ValueError:
          discard
    elif label.startsWith("shout "):
      result.heard.add(p)
  # Attach seat numbers and hit points to the nearest body; the hp bar floats 65 cm above.
  for b in bodies:
    var slot = -1
    if b.isSelf:
      slot = bot.slot
    else:
      var bestD = 400
      for s in seats:
        let d = d2(s.pos, b.pos)
        if d < bestD and s.id != bot.slot:
          bestD = d
          slot = s.id
    var hp = 3
    var shield = 0
    var bestD = 10000
    for h in hps:
      let d = d2(h.pos, Pt(x: b.pos.x, y: b.pos.y - 65))
      if d < bestD:
        bestD = d
        hp = h.hp
        shield = h.shield
    if b.isSelf:
      result.myHp = hp
      result.armorHp = shield
      for m in marks:
        if d2(m.pos, b.pos) <= 400:
          if m.label == "grenade carried": result.hasGrenade = true
          elif m.label == "spray can carried": result.hasSpray = true
          elif m.label == "fire icon": result.gunReady = true
    elif slot >= 0 and slot < 16:
      result.cogs[slot] = Cog(seen: true, pos: b.pos, hp: hp, team: b.team)
    else:
      result.unknown.add(Cog(seen: true, pos: b.pos, hp: hp, team: b.team))

# ---- navigation -------------------------------------------------------------------------

proc pixelWalkable(client: ProtocolClient, x, y: int): bool =
  if x < 0 or y < 0 or x >= client.walkabilityWidth or y >= client.walkabilityHeight:
    return false
  client.walkabilityMask[y * client.walkabilityWidth + x]

proc buildNav(bot: Bot, client: ProtocolClient) =
  bot.gridW = (client.walkabilityWidth + NavCell - 1) div NavCell
  bot.gridH = (client.walkabilityHeight + NavCell - 1) div NavCell
  bot.cellWalk = newSeq[bool](bot.gridW * bot.gridH)
  for cy in 0 ..< bot.gridH:
    for cx in 0 ..< bot.gridW:
      let x = cx * NavCell + NavCell div 2
      let y = cy * NavCell + NavCell div 2
      bot.cellWalk[cy * bot.gridW + cx] =
        client.pixelWalkable(x, y) and client.pixelWalkable(x + 3, y) and
        client.pixelWalkable(x - 3, y) and client.pixelWalkable(x, y + 3) and
        client.pixelWalkable(x, y - 3)
  bot.navDist = newSeq[int32](bot.gridW * bot.gridH)
  bot.navGoal = -1
  bot.navBuilt = true

proc cellOf(bot: Bot, p: Pt): int =
  let cx = clamp((p.x div Scale + bot.originX) div NavCell, 0, bot.gridW - 1)
  let cy = clamp((p.y div Scale + bot.originY) div NavCell, 0, bot.gridH - 1)
  cy * bot.gridW + cx

proc cellCenter(bot: Bot, cell: int): Pt =
  Pt(x: ((cell mod bot.gridW) * NavCell + NavCell div 2 - bot.originX) * Scale,
     y: ((cell div bot.gridW) * NavCell + NavCell div 2 - bot.originY) * Scale)

proc nearestOpenCell(bot: Bot, cell: int): int =
  if bot.cellWalk[cell]:
    return cell
  let cx = cell mod bot.gridW
  let cy = cell div bot.gridW
  for r in 1 .. 12:
    for dy in -r .. r:
      for dx in -r .. r:
        if max(abs(dx), abs(dy)) != r:
          continue
        let nx = cx + dx
        let ny = cy + dy
        if nx < 0 or ny < 0 or nx >= bot.gridW or ny >= bot.gridH:
          continue
        if bot.cellWalk[ny * bot.gridW + nx]:
          return ny * bot.gridW + nx
  cell

const Neighbours = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]

proc computeField(bot: Bot, goal, start: int) =
  ## Dijkstra from the goal until the start cell is settled; every cell with a smaller
  ## distance than the start is final by then, which is all the descent below reads.
  for i in 0 ..< bot.navDist.len:
    bot.navDist[i] = -1
  var heap = initHeapQueue[(int32, int32)]()
  bot.navDist[goal] = 0
  heap.push((0'i32, int32(goal)))
  while heap.len > 0:
    let (dcur, cur32) = heap.pop()
    let cur = int(cur32)
    if dcur > bot.navDist[cur]:
      continue
    if cur == start:
      return
    let cx = cur mod bot.gridW
    let cy = cur div bot.gridW
    for (dx, dy) in Neighbours:
      let nx = cx + dx
      let ny = cy + dy
      if nx < 0 or ny < 0 or nx >= bot.gridW or ny >= bot.gridH:
        continue
      let nc = ny * bot.gridW + nx
      if not bot.cellWalk[nc]:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalk[cy * bot.gridW + nx] and bot.cellWalk[ny * bot.gridW + cx]):
        continue
      let nd = dcur + (if dx != 0 and dy != 0: DiagCost else: StepCost)
      if bot.navDist[nc] < 0 or nd < bot.navDist[nc]:
        bot.navDist[nc] = nd
        heap.push((nd, int32(nc)))

proc gridRayClear(bot: Bot, a, b: Pt): bool =
  let steps = isqrt(d2(a, b)) div 20 + 1
  for s in 0 .. steps:
    let p = Pt(x: a.x + (b.x - a.x) * s div steps, y: a.y + (b.y - a.y) * s div steps)
    if not bot.cellWalk[bot.cellOf(p)]:
      return false
  true

proc navSteer(bot: Bot, me, target: Pt): Pt =
  ## Direction to move: along the cost field toward `target`, beelining without a grid.
  if not bot.navBuilt:
    return Pt(x: target.x - me.x, y: target.y - me.y)
  let goal = bot.nearestOpenCell(bot.cellOf(target))
  let start = bot.nearestOpenCell(bot.cellOf(me))
  if goal != bot.navGoal or bot.tick - bot.navStamp >= RepathTicks:
    bot.computeField(goal, start)
    bot.navGoal = goal
    bot.navStamp = bot.tick
  if bot.navDist[start] <= 0:
    # At the goal, or no path to it (beeline until the next refresh).
    return Pt(x: target.x - me.x, y: target.y - me.y)
  var node = start
  var waypoint = bot.cellCenter(start)
  var haveClear = false
  for _ in 0 ..< Lookahead:
    var next = -1
    var bestD = bot.navDist[node]
    let cx = node mod bot.gridW
    let cy = node div bot.gridW
    for (dx, dy) in Neighbours:
      let nx = cx + dx
      let ny = cy + dy
      if nx < 0 or ny < 0 or nx >= bot.gridW or ny >= bot.gridH:
        continue
      let nc = ny * bot.gridW + nx
      if bot.navDist[nc] < 0 or bot.navDist[nc] >= bestD:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalk[cy * bot.gridW + nx] and bot.cellWalk[ny * bot.gridW + cx]):
        continue
      bestD = bot.navDist[nc]
      next = nc
    if next < 0:
      break
    node = next
    if bot.gridRayClear(me, bot.cellCenter(node)):
      waypoint = bot.cellCenter(node)
      haveClear = true
    else:
      break
  if not haveClear:
    waypoint = bot.cellCenter(node)
  Pt(x: waypoint.x - me.x, y: waypoint.y - me.y)

# ---- the policy ---------------------------------------------------------------------------

proc planLeg(bot: Bot, minTicks, maxTicks: int, threat, goal, self: Pt, holding: bool) =
  ## Next dodge leg: mostly reverse across the line to the threat, keep some progress toward
  ## the goal, hold it for legTicks so a shot ordered now flies true.
  bot.nextRandom()
  if bot.rngState mod 5 != 0:
    bot.zig = 0 - bot.zig
  if bot.zig == 0:
    bot.zig = 1
  bot.nextRandom()
  bot.legTicks = minTicks + bot.rngState mod (maxTicks - minTicks + 1)
  let tx = threat.x - self.x
  let ty = threat.y - self.y
  var root = isqrt(tx * tx + ty * ty)
  bot.legX = 0
  bot.legY = 0
  if root > 0:
    bot.legX = (0 - ty) * 100 * bot.zig div root
    bot.legY = tx * 100 * bot.zig div root
  if not holding:
    let fx = goal.x - self.x
    let fy = goal.y - self.y
    root = isqrt(fx * fx + fy * fy)
    if root > 60:
      bot.legX = bot.legX * 3 div 4 + fx * 100 div root
      bot.legY = bot.legY * 3 div 4 + fy * 100 div root
  root = isqrt(bot.legX * bot.legX + bot.legY * bot.legY)
  if root > 0:
    bot.legX = bot.legX * 28 div root
    bot.legY = bot.legY * 28 div root

proc decide(bot: Bot, f: Frame, shout: var string): uint8 =
  let selfId = bot.slot
  let selfTeam = bot.team
  let me = f.me
  let worldTick = bot.tick
  if not bot.started:
    bot.started = true
    bot.rngState = selfId * 4099 + 977
    bot.zig = (if selfId mod 4 >= 2: -1 else: 1)
    bot.lastPos = me
    bot.progressPos = me
  var myVX = me.x - bot.lastPos.x
  var myVY = me.y - bot.lastPos.y
  if myVX > 60 or myVX < -60 or myVY > 60 or myVY < -60:
    # A respawn teleports us; that is not a velocity.
    myVX = 0
    myVY = 0
  if f.aim >= 0:
    bot.estAim = f.aim
  var trenchId = -1
  for i, t in f.trenches:
    if me.x >= t.x0 and me.x < t.x1 and me.y >= t.y0 and me.y < t.y1:
      trenchId = i

  # Drop an unreachable assignment after three seconds without meaningful progress. As in
  # the BASIC file, `objective` here is last tick's value.
  if worldTick mod 72 == 0:
    let dxp = me.x - bot.progressPos.x
    let dyp = me.y - bot.progressPos.y
    let previous = bot.objective
    if dxp * dxp + dyp * dyp < 40000 and previous >= 0 and previous < MaxHearts and
        previous < f.hearts.len:
      if d2(f.hearts[previous].pos, me) > 160000:
        bot.avoidUntil[previous] = worldTick + 360
    bot.progressPos = me

  # Opponents and teammates in view. Every sprite is fog gated by the host.
  var best = -1
  var bestCost = high(int)
  var bestPos = me
  var foesNear = 0
  var friendsNear = 1
  var foeSumX = 0
  var foeSumY = 0
  var foesSeen = 0
  proc consider(i: int, c: Cog) =
    let dx = c.pos.x - me.x
    let dy = c.pos.y - me.y
    let dd = dx * dx + dy * dy
    if c.team != selfTeam:
      let cost = dd - (3 - c.hp) * 160000
      if cost < bestCost and dd <= 27562500:
        best = i
        bestCost = cost
        bestPos = c.pos
      foesSeen += 1
      foeSumX += c.pos.x
      foeSumY += c.pos.y
      if dd < 6760000:
        foesNear += 1
    else:
      if dd < 1440000:
        friendsNear += 1
  for i in 0 ..< 16:
    if i != selfId and f.cogs[i].seen:
      consider(i, f.cogs[i])
  for c in f.unknown:
    consider(16, c)

  # Where we want to be. Later rules override earlier ones; one move is issued at the end.
  var goal = Pt(x: HomeX[1 - selfTeam], y: HomeY)
  var holding = false

  # Territory: two squads of four, a pure function of public ownership and the squad number.
  var objective = -1
  let heartCount = min(f.hearts.len, MaxHearts)
  if heartCount > 0:
    let member = (selfId div 2) mod 8
    let squad = member div 4
    let seat = member mod 4
    var otherTarget = -1
    for pass in 0 ..< 2:
      let refY = (if pass == 1: HomeY + 1500 else: HomeY - 1500)
      var choice = -1
      var choiceCost = high(int)
      for j in 0 ..< heartCount:
        if f.hearts[j].owner != selfTeam and j != otherTarget:
          let dx = (f.hearts[j].pos.x - HomeX[selfTeam]) div 8
          let dy = (f.hearts[j].pos.y - refY) div 8
          var cost = dx * dx + dy * dy
          if f.hearts[j].owner == -1:
            cost -= 20000
          if pass == squad and bot.avoidUntil[j] > worldTick:
            cost += 4000000
          if cost < choiceCost:
            choice = j
            choiceCost = cost
      if pass == squad:
        objective = choice
      elif pass < squad:
        otherTarget = choice
    if objective < 0 and otherTarget >= 0:
      objective = otherTarget
    if objective >= 0:
      let hx = f.hearts[objective].pos.x
      let hy = f.hearts[objective].pos.y
      goal = Pt(x: hx, y: hy)
      # Seats 0 and 1 stand in the ring. Seats 2 and 3 cover from outside it on the opposing
      # side, and step in if nobody on our team is capturing.
      if seat >= 2:
        if f.hearts[objective].captureTeam == selfTeam:
          bot.idleCapture = 0
        else:
          bot.idleCapture += 1
        let dx = hx - me.x
        let dy = hy - me.y
        if dx * dx + dy * dy > 640000 or bot.idleCapture < 96:
          let side = (if seat == 3: -1 else: 1)
          var ax = 3200 - hx
          var ay = 2000 - hy
          if selfTeam == 0:
            ax += 1200
          else:
            ax -= 1200
          let root = isqrt(ax * ax + ay * ay)
          if root > 0:
            goal = Pt(x: hx + (ax * 3 - ay * 2 * side) * 90 div root,
                      y: hy + (ay * 3 + ax * 2 * side) * 90 div root)
      let dx = goal.x - me.x
      let dy = goal.y - me.y
      if dx * dx + dy * dy < 8100:
        holding = true

  # Remember seen supplies for ten seconds and equip when it is safe to.
  for p in f.pickups:
    var found = false
    for m in bot.memory.mitems:
      if d2(m.pos, p.pos) < 2500:
        m.tick = worldTick + 1
        m.kind = p.kind
        found = true
        break
    if not found and bot.memory.len < MaxPickups:
      bot.memory.add(Memory(pos: p.pos, kind: p.kind, tick: worldTick + 1))
  block pickups:
    var nearest = -1
    var nearestCost = 4840000
    for j, m in bot.memory:
      if m.tick > 0 and worldTick - m.tick < 240:
        let kind = m.kind
        let wanted = (kind == 0 and not f.hasGrenade) or (kind == 2 and f.myHp < 3) or
          (kind == 3 and f.armorHp < 3 and f.myHp == 3)
        if wanted:
          var cost = d2(m.pos, me)
          if kind == 2 and f.myHp == 1:
            # A medkit is worth a whole life to a cog on one hit point.
            cost = cost div 4
          var visibleNow = false
          for p in f.pickups:
            if d2(p.pos, m.pos) < 2500:
              visibleNow = true
          if cost < 10000 and not visibleNow:
            bot.memory[j].tick = 0
          elif cost < nearestCost:
            nearest = j
            nearestCost = cost
    if nearest >= 0 and (best < 0 or bestCost > 1440000 or f.myHp == 1):
      goal = bot.memory[nearest].pos
      holding = false

  # Refuse a fight we are visibly losing: head for the heart far from them and near us.
  if foesNear - friendsNear >= 1 and foesSeen > 0:
    let cx = foeSumX div foesSeen
    let cy = foeSumY div foesSeen
    var away = -1
    var awayScore = low(int)
    for j in 0 ..< heartCount:
      let ex = (f.hearts[j].pos.x - cx) div 16
      let ey = (f.hearts[j].pos.y - cy) div 16
      let mx = (f.hearts[j].pos.x - me.x) div 16
      let my = (f.hearts[j].pos.y - me.y) div 16
      let score = ex * ex + ey * ey - (mx * mx + my * my) div 2
      if score > awayScore:
        away = j
        awayScore = score
    if away >= 0:
      goal = f.hearts[away].pos
      holding = false

  bot.objective = objective

  # Facing with nothing to shoot: look toward the goal, sweep while holding, then turn to
  # speech and sound.
  var desiredAim = -1
  var sweep = false
  if best < 0:
    var look = goal
    if holding:
      sweep = true
    if f.heard.len > 0:
      look = f.heard[0]
      sweep = false
    if f.sounds.len > 0:
      var soundBest = -1
      var soundCost = high(int)
      for j, s in f.sounds:
        if j >= 12:
          break
        var cost = s.age
        if s.kind == 1 or s.kind == 2:
          cost -= 48
        if cost < soundCost:
          soundBest = j
          soundCost = cost
      if soundBest >= 0:
        let bearing = f.sounds[soundBest].direction
        var dxSound = 0
        var dySound = 0
        if bearing == 0 or bearing == 1 or bearing == 7:
          dxSound = 1000
        if bearing == 3 or bearing == 4 or bearing == 5:
          dxSound = -1000
        if bearing == 1 or bearing == 2 or bearing == 3:
          dySound = 1000
        if bearing == 5 or bearing == 6 or bearing == 7:
          dySound = -1000
        look = Pt(x: me.x + dxSound, y: me.y + dySound)
        sweep = false
    if not sweep and (look.x != me.x or look.y != me.y):
      desiredAim = bradsOf(look.x - me.x, look.y - me.y)

  if worldTick mod 360 == selfId * 21:
    if best >= 0:
      shout = "Contact! Cover this lane."
    elif foesNear - friendsNear >= 1:
      shout = "Too many. Falling back."
    else:
      shout = "Moving with the squad."

  # Footwork. In contact, move in short random legs across the line to the threat. A shot is
  # only ordered at the start of a leg that lasts the whole windup, so our own drift is known.
  var moveDir = Pt(x: 0, y: 0)
  var holdStill = false
  let inContact = best >= 0 and trenchId < 0
  var legFresh = false
  var wantShot = false
  if inContact:
    if bot.legTicks > 0 and myVX * myVX + myVY * myVY < 64:
      bot.stalled += 1
    else:
      bot.stalled = 0
    if bot.stalled >= 3:
      # Blocked for three ticks: let the navigation field take over for a second.
      bot.pathUntil = worldTick + 24
      bot.stalled = 0
      bot.legTicks = 0
    wantShot = f.gunReady and (not f.hasSpray or bestCost < 640000)
    if worldTick >= bot.pathUntil:
      if bot.legTicks <= 0:
        if wantShot:
          bot.planLeg(6, 9, bestPos, goal, me, holding)
        else:
          bot.planLeg(3, 6, bestPos, goal, me, holding)
      elif wantShot and bot.legTicks < 6:
        # BASIC re-plans here every tick until it fires. With a turret that must settle on
        # the lead point first, a fresh leg each tick would move that point by up to 280 cm
        # every tick, so extend the current leg instead and keep its direction.
        bot.nextRandom()
        bot.legTicks = 6 + bot.rngState mod 4
      legFresh = bot.legTicks >= 6
      bot.legTicks -= 1
      moveDir = Pt(x: bot.legX, y: bot.legY)
      if holding:
        # Stay inside the ring: turn back toward its centre when the leg would leave it.
        let dx = me.x + bot.legX * 2 - goal.x
        let dy = me.y + bot.legY * 2 - goal.y
        if dx * dx + dy * dy > 9000:
          moveDir = Pt(x: goal.x - me.x, y: goal.y - me.y)
          bot.legTicks = 0
          legFresh = false
    else:
      moveDir = bot.navSteer(me, goal)
  else:
    bot.legTicks = 0
    bot.stalled = 0
    if holding or (objective >= 0 and d2(me, f.hearts[objective].pos) < 16900 and
        bot.stuckTicks >= 6):
      # Inside the ring (or blocked by a squadmate inside the capture radius): stand.
      holdStill = true
    else:
      moveDir = bot.navSteer(me, goal)
      if d2(me, goal) < 400:
        holdStill = true

  # Gun: the ray leaves after the windup from wherever we then stand, along the direction
  # locked at the order. Lay the aim where they will be, minus our own drift, and fire when
  # the turret has settled there at the start of a leg that outlasts the windup.
  var wantFire = false
  if best >= 0:
    var tx = bestPos.x
    var ty = bestPos.y
    if best < 16 and bot.lastSeen[best] == worldTick - 1:
      tx += (tx - bot.oldPos[best].x) * 6
      ty += (ty - bot.oldPos[best].y) * 6
    if inContact and worldTick >= bot.pathUntil:
      tx -= bot.legX * 5
      ty -= bot.legY * 5
    else:
      tx -= myVX * 5
      ty -= myVY * 5
    # Hold fire when a visible teammate stands in the line.
    var clear = true
    let sx = tx - me.x
    let sy = ty - me.y
    let reach = isqrt(sx * sx + sy * sy)
    if reach > 0:
      for i in 0 ..< 16:
        if i != selfId and f.cogs[i].seen and f.cogs[i].team == selfTeam:
          let ox = f.cogs[i].pos.x - me.x
          let oy = f.cogs[i].pos.y - me.y
          let along = (ox * sx + oy * sy) div reach
          var across = (ox * sy - oy * sx) div reach
          if across < 0:
            across = 0 - across
          if along > 0 and along < reach and across < 95:
            clear = false
    desiredAim = bradsOf(sx, sy)
    let err = abs(bradsErr(desiredAim, bot.estAim))
    let perpMiss = int(float(reach) * sin(float(err) * PI / 128.0))
    let settled = err <= Deadband and perpMiss <= FireMiss
    if (not f.hasSpray or bestCost < 640000) and clear and f.gunReady and settled and
        (not inContact or worldTick < bot.pathUntil or legFresh):
      wantFire = true
    when defined(aimTrace):
      # Diagnostic build: publish the fire gate as chat on every gun-ready tick.
      if f.gunReady:
        shout = "T err=" & $err & " miss=" & $perpMiss & " reach=" & $reach & " clear=" &
          $int(clear) & " ic=" & $int(inContact) & " leg=" & $bot.legTicks & " fresh=" &
          $int(legFresh) & " path=" & $int(worldTick < bot.pathUntil) & " fire=" & $int(wantFire)

  for i in 0 ..< 16:
    if f.cogs[i].seen:
      bot.oldPos[i] = f.cogs[i].pos
      bot.lastSeen[i] = worldTick

  # Grenade: match the charge to the distance, never onto a visible teammate. The throw
  # leaves along the current aim, so the turret lays on the target before charging.
  var nadeC = false
  if f.hasGrenade and best >= 0:
    let nx = bestPos.x
    let ny = bestPos.y
    let dd = d2(bestPos, me)
    var safe = true
    for i in 0 ..< 16:
      if f.cogs[i].seen and f.cogs[i].team == selfTeam:
        if d2(f.cogs[i].pos, bestPos) < 202500:
          safe = false
    if safe and dd > 160000 and dd < 1562500:
      var need = (isqrt(dd) - 150) * 24 div 1130 + 1
      if need < 1:
        need = 1
      desiredAim = bradsOf(nx - me.x, ny - me.y)
      wantFire = false
      let err = abs(bradsErr(desiredAim, bot.estAim))
      if bot.nadeCharge > 0 or err <= Deadband + 2:
        if bot.nadeCharge < need:
          nadeC = true
          bot.nadeCharge += 1
        else:
          bot.nadeCharge = 0          # release this tick = the throw
          shout = "Grenade out!"
  if not nadeC:
    bot.nadeCharge = 0

  # Stuck outside of contact: burst in a random direction and force a repath.
  if not holdStill and myVX * myVX + myVY * myVY < 4:
    bot.stuckTicks += 1
  else:
    bot.stuckTicks = 0
  var moveMask = (if holdStill: 0'u8 else: octantBits(moveDir.x, moveDir.y))
  if bot.stuckTicks > 20 and best < 0:
    bot.stuckTicks = 0
    bot.jinkUntil = worldTick + 10
    bot.nextRandom()
    bot.jinkBits = octantBits(bot.rngState mod 7 - 3, (bot.rngState div 7) mod 7 - 3)
    if bot.jinkBits == 0:
      bot.jinkBits = BtnUp
    bot.navGoal = -1
  if worldTick < bot.jinkUntil and best < 0:
    moveMask = bot.jinkBits

  # Quiet approach to the objective when nothing is in sight but something was heard.
  var sneak = false
  if best < 0 and f.sounds.len > 0 and objective >= 0:
    if d2(f.hearts[objective].pos, me) < 810000:
      sneak = true

  # Rotate toward the desired aim by the shortest arc; never on the tick a shot is ordered.
  var rotBits = 0'u8
  if wantFire:
    discard
  elif sweep:
    rotBits = BtnB
  elif desiredAim >= 0:
    let err = bradsErr(desiredAim, bot.estAim)
    if err > Deadband:
      rotBits = BtnB
    elif err < -Deadband:
      rotBits = BtnSelect
  var mask = moveMask or rotBits
  if wantFire:
    mask = mask or BtnA
  if nadeC:
    mask = mask or BtnC
  if sneak and rotBits == 0 and not wantFire:
    mask = mask or BtnB or BtnSelect
  bot.rotSign =
    if (mask and BtnB) != 0 and (mask and BtnSelect) != 0: 0
    elif (mask and BtnB) != 0: 1
    elif (mask and BtnSelect) != 0: -1
    else: 0
  bot.firedLast = wantFire
  bot.lastPos = me
  mask

# ---- component wrapper (the ABI shim in singlepod/baseline_wasm.nim calls these) ----------

type BaselineComponent* = object
  bot: Bot
  client: ProtocolClient
  lastMask: uint8
  hasSent: bool

proc initBaselineComponent*(slot: int): BaselineComponent =
  result.bot = Bot(slot: slot, team: slot mod 2, navGoal: -1, objective: -1)
  result.client = initProtocolClient()

proc onMessage*(component: var BaselineComponent, message: string): seq[string] =
  ## Applies one game frame and returns the changed input mask and any shout.
  component.client.applyFrame(message)
  let bot = component.bot
  bot.tick += component.client.frameAdvance
  if bot.rotSign != 0 and component.client.frameAdvance > 1:
    bot.estAim = floorMod(bot.estAim + bot.rotSign * AimRate * (component.client.frameAdvance - 1),
                          AimBrads)
  if not component.client.mapCameraReady:
    return
  let frame = bot.parseFrame(component.client)
  if not bot.navBuilt and component.client.walkabilityReady and bot.originKnown:
    bot.buildNav(component.client)
  var mask = 0'u8
  var shout = ""
  if frame.alive:
    if bot.wasDead:
      bot.wasDead = false
      bot.legTicks = 0
      bot.nadeCharge = 0
      bot.navGoal = -1
      bot.stuckTicks = 0
      bot.lastPos = frame.me
    mask = bot.decide(frame, shout)
  else:
    bot.wasDead = true
    bot.rotSign = 0
    bot.firedLast = false
  if not component.hasSent or mask != component.lastMask:
    result.add(inputBlob(mask))
    component.lastMask = mask
    component.hasSent = true
  if shout.len > 0:
    result.add(chatBlob(shout))
