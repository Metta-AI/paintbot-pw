## Paintbot PW WASM baseline: `players/base.bas` ported to the sprite protocol.
##
## The policy is the one the BASIC file runs, section for section and with the same constants
## (world centimetres): a three-second progress timer, a fog-gated threat scan, two stateless
## squads of four that agree on a heart without talking, ten-second pickup memory, refusing a
## fight we are visibly losing, staggered callouts, short random legs across the line to the
## threat while in contact, a gun lead of the full windup minus our own drift, distance-matched
## grenade charges, and a quiet approach toward sounds.
##
## Actions go out as direct orders (reply packet 0x85, see runtime/sprite.py): the same
## `walkTo`/`lookAt`/`shootAt`/`chargeGrenade`/`sneak` a BASIC seat has, so the engine paths and
## aims for this cog exactly as it does for the BASIC one. Two things differ: the frame's gun-ready
## icon replaces BASIC's cooldown estimate, and the `carrying`/`thief` branches of the BASIC file,
## dead in territory play, are not ported. Sprite pixels are five centimetres; the red endzone
## sprite fixes the world origin. Labels are the ones `coworld/paintbot/runtime/sprite.py` emits.
import std/[math, strutils]
import baseline/protocols

const
  Scale = 5                    # world centimetres per sprite pixel
  MaxHearts = 16
  MaxPickups = 32
  HomeX = [960, 5440]
  HomeY = 2000
  OrderWalk = 1'u8
  OrderShoot = 2'u8
  OrderCharge = 4'u8
  OrderSneak = 8'u8
  OrderAim = 16'u8

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

  Order = object               # one tick's BASIC-style actions
    walk, shoot, charge, sneak, aimSet: bool
    goal, aim: Pt

  Bot = ref object
    slot, team: int
    tick: int
    originX, originY: int      # sprite pixel of world (0, 0)
    originKnown: bool
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
    grenadeCharge: int         # ticks the grenade has been held (the engine counts the same)
    wasDead: bool

# ---- arithmetic -------------------------------------------------------------------------

proc isqrt(n: int): int =
  if n <= 0: 0 else: int(sqrt(float(n)))

proc d2(a, b: Pt): int =
  let dx = a.x - b.x
  let dy = a.y - b.y
  dx * dx + dy * dy

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

proc decide(bot: Bot, f: Frame, shout: var string): Order =
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

  # Where we want to be. Later rules override earlier ones; one walkTo is issued at the end.
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
  bot.objective = objective

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

  # Facing with nothing to shoot: sweep, then turn to speech and sound.
  if best < 0:
    let scan = (worldTick div 24 + selfId) mod 4
    var look = goal
    if holding or scan == 1:
      look = Pt(x: me.x + 2000, y: me.y)
      if scan == 1:
        look = Pt(x: me.x, y: me.y + 2000)
      if scan == 2:
        look.x = me.x - 2000
      if scan == 3:
        look = Pt(x: me.x, y: me.y - 2000)
    if f.heard.len > 0:
      look = f.heard[0]
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
    result.aimSet = true
    result.aim = look

  if worldTick mod 360 == selfId * 21:
    if best >= 0:
      shout = "Contact! Cover this lane."
    elif foesNear - friendsNear >= 1:
      shout = "Too many. Falling back."
    else:
      shout = "Moving with the squad."

  # Footwork. In contact, move in short random legs across the line to the threat. A shot is
  # only ordered at the start of a leg that lasts the whole windup, so our own drift is known.
  var move = goal
  let inContact = best >= 0 and trenchId < 0
  if inContact:
    if bot.legTicks > 0 and myVX * myVX + myVY * myVY < 64:
      bot.stalled += 1
    else:
      bot.stalled = 0
    if bot.stalled >= 3:
      # Blocked for three ticks: let the engine's pathing take over for a second.
      bot.pathUntil = worldTick + 24
      bot.stalled = 0
      bot.legTicks = 0
    let wantShot = f.gunReady and (not f.hasSpray or bestCost < 640000)
    if worldTick >= bot.pathUntil:
      if bot.legTicks <= 0 or (wantShot and bot.legTicks < 6):
        if wantShot:
          bot.planLeg(6, 9, bestPos, goal, me, holding)
        else:
          bot.planLeg(3, 6, bestPos, goal, me, holding)
      bot.legTicks -= 1
      move = Pt(x: me.x + bot.legX * 4, y: me.y + bot.legY * 4)
      if holding:
        # Stay inside the ring: turn back toward its centre when the leg would leave it.
        let dx = me.x + bot.legX * 2 - goal.x
        let dy = me.y + bot.legY * 2 - goal.y
        if dx * dx + dy * dy > 9000:
          move = goal
          bot.legTicks = 0
  else:
    bot.legTicks = 0
    bot.stalled = 0
  result.walk = true
  result.goal = move

  # Gun: the ray leaves six moves after the order, from wherever we then stand, along the
  # direction locked one move from now. Aim where they will be, minus our own drift.
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
    result.aimSet = true
    result.aim = Pt(x: tx, y: ty)
    if (not f.hasSpray or bestCost < 640000) and clear and f.gunReady:
      result.shoot = true

  for i in 0 ..< 16:
    if f.cogs[i].seen:
      bot.oldPos[i] = f.cogs[i].pos
      bot.lastSeen[i] = worldTick

  # Grenade: match the charge to the distance, never onto a visible teammate.
  var charging = false
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
      result.aimSet = true
      result.aim = Pt(x: nx, y: ny)
      if bot.grenadeCharge < need:
        result.charge = true
        charging = true
        bot.grenadeCharge += 1
      else:
        shout = "Grenade out!"
  if not charging:
    bot.grenadeCharge = 0

  # Quiet approach to the objective when nothing is in sight but something was heard.
  if best < 0 and f.sounds.len > 0 and objective >= 0:
    if d2(f.hearts[objective].pos, me) < 810000:
      result.sneak = true

  bot.lastPos = me

# ---- component wrapper (the ABI shim in singlepod/baseline_wasm.nim calls these) ----------

proc orderBlob(order: Order): string =
  ## Reply packet 0x85: flags, goal x/z, aim x/z as little-endian int32 world centimetres.
  var flags = 0'u8
  if order.walk: flags = flags or OrderWalk
  if order.shoot: flags = flags or OrderShoot
  if order.charge: flags = flags or OrderCharge
  if order.sneak: flags = flags or OrderSneak
  if order.aimSet: flags = flags or OrderAim
  result = newStringOfCap(18)
  result.add(char(0x85))
  result.add(char(flags))
  for v in [order.goal.x, order.goal.y, order.aim.x, order.aim.y]:
    let u = cast[uint32](int32(v))
    for shift in [0, 8, 16, 24]:
      result.add(char((u shr shift) and 255))

type BaselineComponent* = object
  bot: Bot
  client: ProtocolClient

proc initBaselineComponent*(slot: int): BaselineComponent =
  result.bot = Bot(slot: slot, team: slot mod 2, objective: -1)
  result.client = initProtocolClient()

proc onMessage*(component: var BaselineComponent, message: string): seq[string] =
  ## Applies one game frame and returns this tick's order and any shout.
  component.client.applyFrame(message)
  let bot = component.bot
  bot.tick += component.client.frameAdvance
  if not component.client.mapCameraReady:
    return
  let frame = bot.parseFrame(component.client)
  if not frame.alive:
    bot.wasDead = true
    return
  if bot.wasDead:
    bot.wasDead = false
    bot.legTicks = 0
    bot.grenadeCharge = 0
    bot.lastPos = frame.me
  var shout = ""
  let order = bot.decide(frame, shout)
  result.add(orderBlob(order))
  if shout.len > 0:
    result.add(chatBlob(shout))
