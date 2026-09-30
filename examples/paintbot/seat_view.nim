## SeatView: the one perception boundary for BASIC and neural seats (docs/neural/seat-view.md).
##
## A seat, BASIC or neural, perceives the world only through a `SeatView`: one seat's view of
## one tick. Its world is not exported; its procs are exactly the BASIC perception surface
## (bots.nim host() registers one builtin per proc), under the same fog, uniform and
## one-body-per-identity rules. This module is the only perception module that may read the
## simulation's world; the neural modules (neural_contract, neural_actor, neural_host) import
## this one instead of `sim`, and tests/test_paintbot_seat_view_boundary.nim enforces it.
import sim, kinship

# What a seat's code may name besides its view: geometry types, rules globals and constants.
# None of it reads a world.
export Point, point, distance2, team, ffa, ffaFog, maxHp, minX, maxX, minZ, maxZ, Width, Height,
  Seats, LegacySeats, MaxSeats, Loci, TickRate, SoundLifetime, HeartCaptureTicks,
  GreatHeartCaptureTicks, GreatHeartDormantTicks, TerritoryBoostPercent, FfaMatchTicks,
  controlHeartCount, GunRange, MoveSpeed, Radius, visionRulesVersion

type
  HeardMessage* = object
    slot*: int      ## the speaker's identity as the listener sees it
    pos*: Point
    text*: string
  NearAgent = object
    identity, body: int32
    d2: int64
  NearGrid = object
    ## Living cogs bucketed by NearCell squares, rebuilt on the first query of a tick.
    tick: int32
    built: bool
    originX, originZ, nx, nz: int
    cellStart, items: seq[int32]
  SeatView* = object
    ## One seat's view of one tick. Built by `seatView` after `beginViews`; a view from an
    ## earlier `beginViews` is stale and every proc asserts against using it.
    w: ptr World
    slot: int
    epoch: int
  ViewAgent* = object
    ## One entry of `agentsNear`: what nearAgentId/X/Y/Hp/Team report for it.
    identity*, x*, z*, hp*, team*: int32

const
  NearCell = 500
  NearMaxRadius* = 20000
  NearMaxAgents* = 64
  DataNames* = ["selfId","selfTeam","selfX","selfY","selfHp","carrying","homeX","homeY","heartX",
    "heartY","worldTick","ownHeartX","ownHeartY","ownHeartStolen","hasGrenade","hasSpray","armorHp",
    "livesLeft","grenadeCharge","trenchId"]

# One tick's scratch (the world every view reads, the vision cache, the near grid and lists)
# and the speech carried between decisions. Training builds run many worlds on many threads:
# there the same variables are thread-local and the native host copies `heard` in and out
# around each step, so a handle may migrate between threads.
when defined(pwTraining):
  var
    shouts* {.threadvar.}: seq[seq[string]]
    heard* {.threadvar.}: seq[seq[HeardMessage]]
  var viewWorld {.threadvar.}: ptr World
  var viewEpoch {.threadvar.}: int
  var visionCache {.threadvar.}: seq[seq[int8]]
  var nearGrid {.threadvar.}: NearGrid
  var nearLists {.threadvar.}: seq[seq[NearAgent]]
else:
  var
    shouts*: seq[seq[string]]
    heard*: seq[seq[HeardMessage]]
  var viewWorld: ptr World
  var viewEpoch: int
  var visionCache: seq[seq[int8]]
  var nearGrid: NearGrid
  var nearLists: seq[seq[NearAgent]]

proc beginViews*(w: World) =
  ## Starts a tick of views on `w` (the unchanged pre-step world every seat of the tick reads):
  ## clears the vision cache and the near grid and lists. Every view built before is stale.
  viewWorld = unsafeAddr w
  inc viewEpoch
  visionCache.setLen(Seats)
  for row in visionCache.mitems:
    row.setLen(Seats)
    for v in row.mitems: v = 0
  nearGrid.built = false
  nearLists.setLen(Seats)
  for l in nearLists.mitems: l.setLen(0)

proc seatView*(slot: int): SeatView =
  ## Seat `slot`'s view of the world `beginViews` started.
  assert not viewWorld.isNil, "seatView before beginViews"
  assert slot in 0..<Seats, "seatView of an invalid seat"
  SeatView(w: viewWorld, slot: slot, epoch: viewEpoch)

template world(v: SeatView): untyped =
  assert v.epoch == viewEpoch, "stale SeatView (a later beginViews started another tick)"
  v.w[]

proc slot*(v: SeatView): int = v.slot

# ---------------------------------------------------------------------------------------
# Identity resolution: one body per identity, the nearer when two bodies share it.
proc cachedVisible(v: SeatView, body: int): bool =
  if visionCache[v.slot][body] == 0:
    visionCache[v.slot][body] = if v.world.visible(v.slot, body): 1 else: -1
  visionCache[v.slot][body] == 1

proc bodyForSeat(v: SeatView, identity: int): int =
  let observer = v.slot
  if identity notin 0..<Seats: return -1
  if identity == observer: return observer
  result = -1
  for body in 0..<Seats:
    if v.world.observedSeat(observer, body) != identity: continue
    if not v.cachedVisible(body): continue
    # If the genuine cog and its impersonator are both visible, report the
    # nearer body under their shared identity. No real-seat side channel.
    if result < 0 or distance2(v.world.cogs[observer].pos, v.world.cogs[body].pos) <
        distance2(v.world.cogs[observer].pos, v.world.cogs[result].pos): result = body

proc visible*(v: SeatView, identity: int): int32 = int32(v.bodyForSeat(identity) >= 0)

proc playerTeam*(v: SeatView, identity: int): int32 =
  ## FFA-kin: every seat is its own side, so a visible cog's team is its seat.
  let body = v.bodyForSeat(identity)
  if body < 0: -1'i32
  elif ffa(): body.int32
  else: v.world.observedTeam(v.slot, body).int32

proc playerX*(v: SeatView, identity: int): int32 =
  let body = v.bodyForSeat(identity)
  if body >= 0: v.world.cogs[body].pos.x else: -1
proc playerY*(v: SeatView, identity: int): int32 =
  let body = v.bodyForSeat(identity)
  if body >= 0: v.world.cogs[body].pos.z else: -1
proc playerHp*(v: SeatView, identity: int): int32 =
  let body = v.bodyForSeat(identity)
  if body >= 0: v.world.cogs[body].hp else: 0
proc playerCarrying*(v: SeatView, identity: int): int32 =
  let body = v.bodyForSeat(identity)
  if body >= 0: v.world.cogs[body].carrying.int32 else: 0

# ---------------------------------------------------------------------------------------
# Nearby agents.
proc buildNearGrid(w: World) =
  let g = addr nearGrid
  g.originX = minX(); g.originZ = minZ()
  g.nx = (maxX()-minX()) div NearCell+1; g.nz = (maxZ()-minZ()) div NearCell+1
  g.cellStart = newSeq[int32](g.nx*g.nz+1)
  var cells = newSeq[int](Seats)
  for b in 0..<Seats:
    cells[b] = -1
    let c = w.cogs[b]
    if c.hp <= 0: continue
    let cx = clamp((c.pos.x.int-g.originX) div NearCell, 0, g.nx-1)
    let cz = clamp((c.pos.z.int-g.originZ) div NearCell, 0, g.nz-1)
    cells[b] = cz*g.nx+cx
    inc g.cellStart[cells[b]+1]
  for i in 1..g.nx*g.nz: g.cellStart[i] += g.cellStart[i-1]
  g.items = newSeq[int32](g.cellStart[^1])
  var fill = g.cellStart
  for b in 0..<Seats:
    if cells[b] < 0: continue
    g.items[fill[cells[b]]] = b.int32; inc fill[cells[b]]
  g.tick = w.tick; g.built = true

proc collectNear(v: SeatView, radius: int, list: var seq[NearAgent]) =
  ## The agents the seat can see within `radius`, nearest first, under the identities it
  ## observes (a disguised body reports its disguise; of two bodies sharing an identity the
  ## nearer is kept, as playerX does). Visits only grid cells the circle touches, so the
  ## cost follows the neighbourhood, not the roster.
  list.setLen(0)
  let slot = v.slot
  let me = v.world.cogs[slot]
  if me.hp <= 0: return
  if not nearGrid.built or nearGrid.tick != v.world.tick: buildNearGrid(v.world)
  let g = addr nearGrid
  let r = clamp(radius, 0, NearMaxRadius)
  let r2 = r.int64*r
  let x0 = clamp((me.pos.x.int-r-g.originX) div NearCell, 0, g.nx-1)
  let x1 = clamp((me.pos.x.int+r-g.originX) div NearCell, 0, g.nx-1)
  let z0 = clamp((me.pos.z.int-r-g.originZ) div NearCell, 0, g.nz-1)
  let z1 = clamp((me.pos.z.int+r-g.originZ) div NearCell, 0, g.nz-1)
  for cz in z0..z1:
    for cx in x0..x1:
      let cell = cz*g.nx+cx
      for k in g.cellStart[cell]..<g.cellStart[cell+1]:
        let b = g.items[k].int
        if b == slot: continue
        let d2 = distance2(me.pos, v.world.cogs[b].pos)
        if d2 > r2: continue
        if not v.cachedVisible(b): continue
        let identity = v.world.observedSeat(slot, b).int32
        var dup = -1
        for i, e in list:
          if e.identity == identity: dup = i; break
        if dup < 0: list.add NearAgent(identity: identity, body: b.int32, d2: d2)
        elif d2 < list[dup].d2 or (d2 == list[dup].d2 and b < list[dup].body):
          list[dup] = NearAgent(identity: identity, body: b.int32, d2: d2)
  # Nearest first; ties by identity, so the order never depends on the grid's scan order.
  for i in 1..<list.len:
    let e = list[i]; var j = i-1
    while j >= 0 and (list[j].d2 > e.d2 or (list[j].d2 == e.d2 and list[j].identity > e.identity)):
      list[j+1] = list[j]; dec j
    list[j+1] = e
  if list.len > NearMaxAgents: list.setLen(NearMaxAgents)

proc agentTeam(v: SeatView, body: int): int32 =
  if ffa(): body.int32 else: v.world.observedTeam(v.slot, body).int32

proc nearAgents*(v: SeatView, radius: int): int32 =
  ## nearAgents(radius): lists the agents this seat can see within radius (clamped to 20000),
  ## nearest first, at most 64, for nearAgentId/X/Y/Hp/Team to read until the next call.
  v.collectNear(radius, nearLists[v.slot])
  nearLists[v.slot].len.int32

proc nearField(v: SeatView, k, field: int): int32 =
  let list = addr nearLists[v.slot]
  if k < 0 or k >= list[].len: return (if field == 3: 0'i32 else: -1'i32)
  let e = list[][k]
  let c = v.world.cogs[e.body]
  case field
  of 0: e.identity
  of 1: c.pos.x
  of 2: c.pos.z
  of 3: c.hp
  else: v.agentTeam(e.body.int)
proc nearAgentId*(v: SeatView, k: int): int32 = v.nearField(k, 0)
proc nearAgentX*(v: SeatView, k: int): int32 = v.nearField(k, 1)
proc nearAgentY*(v: SeatView, k: int): int32 = v.nearField(k, 2)
proc nearAgentHp*(v: SeatView, k: int): int32 = v.nearField(k, 3)
proc nearAgentTeam*(v: SeatView, k: int): int32 = v.nearField(k, 4)

proc agentsNear*(v: SeatView, radius: int): seq[ViewAgent] =
  ## The list nearAgents(radius) would give, entry by entry as nearAgentId/X/Y/Hp/Team read
  ## it, without replacing the list the seat's own nearAgents call left.
  var list: seq[NearAgent]
  v.collectNear(radius, list)
  for e in list:
    let c = v.world.cogs[e.body]
    result.add ViewAgent(identity: e.identity, x: c.pos.x, z: c.pos.z, hp: c.hp, team: v.agentTeam(e.body.int))

proc nearAgentsFor*(w: World, slot, radius: int): seq[tuple[identity, body: int]] =
  ## Test hook: the nearAgents answer for one seat against a fresh tick of `w`, with bodies.
  beginViews(w)
  let v = seatView(slot)
  discard v.nearAgents(radius)
  for e in nearLists[slot]: result.add (e.identity.int, e.body.int)

# ---------------------------------------------------------------------------------------
# The seat's own data values (the BASIC DATA variables, DataNames order).
proc homeHeart(v: SeatView): tuple[home, heart, ownPos: Point, ownStolen: bool] =
  ## FFA-kin has no team hearts: home is the seat's spawn anchor, and the carried-heart data
  ## all read home (never stolen).
  let slot = v.slot
  if ffa():
    let home = v.world.spawnAnchor[slot]
    return (home, home, home, false)
  let home = home(team(slot))
  let enemyHeart = v.world.hearts[1-team(slot)]
  let own = v.world.hearts[team(slot)]
  let heart = if enemyHeart.carrier < 0 or v.world.visible(slot, enemyHeart.carrier.int): enemyHeart.pos
              else: home(1-team(slot))
  let ownPos = if own.carrier < 0 or v.world.visible(slot, own.carrier.int): own.pos else: home
  (home, heart, ownPos, own.carrier >= 0)

proc selfId*(v: SeatView): int32 = v.slot.int32
proc selfTeam*(v: SeatView): int32 = int32(if ffa(): v.slot else: team(v.slot))
proc selfX*(v: SeatView): int32 = v.world.cogs[v.slot].pos.x
proc selfY*(v: SeatView): int32 = v.world.cogs[v.slot].pos.z
proc selfHp*(v: SeatView): int32 = v.world.cogs[v.slot].hp
proc carrying*(v: SeatView): int32 = v.world.cogs[v.slot].carrying.int32
proc worldTick*(v: SeatView): int32 = v.world.tick
proc hasGrenade*(v: SeatView): int32 = v.world.equipment[v.slot].grenade.int32
proc hasSpray*(v: SeatView): int32 = v.world.equipment[v.slot].sprayCan.int32
proc armorHp*(v: SeatView): int32 = v.world.equipment[v.slot].armor
proc livesLeft*(v: SeatView): int32 = v.world.equipment[v.slot].lives
proc grenadeCharge*(v: SeatView): int32 = v.world.equipment[v.slot].charge
proc trenchId*(v: SeatView): int32 = v.world.trenchAt(v.world.cogs[v.slot].pos).int32

proc dataValues*(v: SeatView): array[DataNames.len, int32] =
  ## The DATA variables a BASIC seat reads, in DataNames order.
  let h = v.homeHeart()
  [v.selfId, v.selfTeam, v.selfX, v.selfY, v.selfHp, v.carrying, h.home.x, h.home.z, h.heart.x,
   h.heart.z, v.worldTick, h.ownPos.x, h.ownPos.z, int32(h.ownStolen), v.hasGrenade, v.hasSpray,
   v.armorHp, v.livesLeft, v.grenadeCharge, v.trenchId]

proc hasUniform*(v: SeatView): int32 = v.world.uniforms[v.slot].int32

# ---------------------------------------------------------------------------------------
# Sounds and speech.
proc soundCount*(v: SeatView): int32 =
  var count = 0
  for cue in v.world.sounds:
    if cue.listener == v.slot.int32 and v.world.tick-cue.tick <= SoundLifetime: inc count
  count.int32

proc soundField(v: SeatView, index, field: int): int32 =
  var i = 0
  for cue in v.world.sounds:
    if cue.listener != v.slot.int32 or v.world.tick-cue.tick > SoundLifetime: continue
    if i == index:
      return (case field
        of 0: cue.kind
        of 1: cue.direction
        of 2: cue.distance
        else: v.world.tick-cue.tick)
    inc i
  -1
proc soundKind*(v: SeatView, i: int): int32 = v.soundField(i, 0)
proc soundDirection*(v: SeatView, i: int): int32 = v.soundField(i, 1)
proc soundDistance*(v: SeatView, i: int): int32 = v.soundField(i, 2)
proc soundAge*(v: SeatView, i: int): int32 = v.soundField(i, 3)

proc heardCount*(v: SeatView): int32 = heard[v.slot].len.int32
proc heardText*(v: SeatView, i: int): string =
  if i < 0 or i >= heard[v.slot].len: "" else: heard[v.slot][i].text
proc heardField(v: SeatView, i, field: int): int32 =
  if i < 0 or i >= heard[v.slot].len: return -1
  if field == 0: heard[v.slot][i].slot.int32
  elif field == 1: heard[v.slot][i].pos.x
  else: heard[v.slot][i].pos.z
proc heardSlot*(v: SeatView, i: int): int32 = v.heardField(i, 0)
proc heardX*(v: SeatView, i: int): int32 = v.heardField(i, 1)
proc heardY*(v: SeatView, i: int): int32 = v.heardField(i, 2)

proc deliverSpeech*(w: World) =
  ## Next-tick hearing matches CTF's 20%-of-map-width radius, regardless of vision.
  heard = newSeq[seq[HeardMessage]](Seats)
  for sender in 0..<Seats:
    if w.cogs[sender].hp<=0:continue
    for receiver in 0..<Seats:
      if receiver==sender or w.cogs[receiver].hp<=0:continue
      if distance2(w.cogs[sender].pos,w.cogs[receiver].pos)>(Width div 5).int64*(Width div 5):continue
      for message in shouts[sender]:
        heard[receiver].add HeardMessage(slot:w.observedSeat(receiver,sender),pos:w.cogs[sender].pos,text:message)

# ---------------------------------------------------------------------------------------
# Pickups, hearts, glory and the scoreboard.
proc pickupCount*(v: SeatView): int32 = v.world.pickups.len.int32
proc pickupSeen(v: SeatView, i: int): bool =
  i >= 0 and i < v.world.pickups.len and v.world.pickups[i].readyAt <= v.world.tick and
    v.world.canSeePoint(v.slot, v.world.pickups[i].pos)
proc pickupVisible*(v: SeatView, i: int): int32 = int32(v.pickupSeen(i))
proc pickupX*(v: SeatView, i: int): int32 = (if v.pickupSeen(i): v.world.pickups[i].pos.x else: -1'i32)
proc pickupY*(v: SeatView, i: int): int32 = (if v.pickupSeen(i): v.world.pickups[i].pos.z else: -1'i32)
proc pickupKind*(v: SeatView, i: int): int32 = (if v.pickupSeen(i): v.world.pickups[i].kind.int32 else: -1'i32)

proc heartCount*(v: SeatView): int32 = v.world.controlHearts.len.int32
proc glory*(v: SeatView, side: int): int32 =
  if side >= 0 and side <= 1: v.world.glory[side] else: -1'i32
# The public scoreboard: team t's lives left, the sum the behind-in-lives glory award
# compares, and that award (glory per life trailed) and its period in seconds as the match's
# glory config sets them. The HUD shows all of it. The teams game only: FFA-kin (no teams)
# reads -1, as does a team other than 0 or 1.
proc teamLives*(v: SeatView, side: int): int32 =
  if not ffa() and side >= 0 and side <= 1: v.world.teamLives(side) else: -1'i32
proc awardBehind*(v: SeatView): int32 = (if ffa(): -1'i32 else: gloryRules().behindLives)
proc awardBehindSeconds*(v: SeatView): int32 = (if ffa(): -1'i32 else: gloryRules().behindLivesSeconds)
# Rules 47: team t's cogs out of the match (dead, no lives left), the count the
# behind-in-cogs glory award compares, and that award and its period. FFA-kin reads -1.
proc teamCogsOut*(v: SeatView, side: int): int32 =
  if not ffa() and side >= 0 and side <= 1: v.world.teamCogsOut(side) else: -1'i32
proc awardBehindCogs*(v: SeatView): int32 = (if ffa(): -1'i32 else: gloryRules().behindCogs)
proc awardBehindCogsSeconds*(v: SeatView): int32 = (if ffa(): -1'i32 else: gloryRules().behindCogsSeconds)

# Rules 38: glory hearts are fog-gated like pickups; hidden or invalid ones read -1.
proc gloryHeartCount*(v: SeatView): int32 = v.world.gloryHearts.len.int32
proc gloryHeartField(v: SeatView, i, field: int): int32 =
  if i < 0 or i >= v.world.gloryHearts.len or not v.world.canSeePoint(v.slot, v.world.gloryHearts[i].pos): return -1
  if field == 0: v.world.gloryHearts[i].pos.x
  elif field == 1: v.world.gloryHearts[i].pos.z
  else: v.world.gloryHearts[i].expiresAt-v.world.tick
proc gloryHeartX*(v: SeatView, i: int): int32 = v.gloryHeartField(i, 0)
proc gloryHeartY*(v: SeatView, i: int): int32 = v.gloryHeartField(i, 1)
proc gloryHeartTicksLeft*(v: SeatView, i: int): int32 = v.gloryHeartField(i, 2)

proc controlField(v: SeatView, i, field: int): int32 =
  if i < 0 or i >= v.world.controlHearts.len: return -1
  if field == 0: v.world.controlHearts[i].pos.x
  elif field == 1: v.world.controlHearts[i].pos.z
  elif field == 2: v.world.controlHearts[i].owner
  elif field == 6: v.world.heartPoints(i)
  elif i >= v.world.heartCaptures.len:
    if field == 3: -1'i32 else: 0'i32
  elif field == 3: v.world.heartCaptures[i].team
  elif field == 4: v.world.heartCaptures[i].ticks
  else: v.world.heartCaptures[i].contested.int32
proc controlX*(v: SeatView, i: int): int32 = v.controlField(i, 0)
proc controlY*(v: SeatView, i: int): int32 = v.controlField(i, 1)
proc controlOwner*(v: SeatView, i: int): int32 = v.controlField(i, 2)
proc controlCaptureTeam*(v: SeatView, i: int): int32 = v.controlField(i, 3)
proc controlCaptureTicks*(v: SeatView, i: int): int32 = v.controlField(i, 4)
proc controlContested*(v: SeatView, i: int): int32 = v.controlField(i, 5)
proc controlPoints*(v: SeatView, i: int): int32 = v.controlField(i, 6)

# ---------------------------------------------------------------------------------------
# FFA-kin (Heartland). Before rules 48 kinship, genes, raw scores and who is still in the
# match are public, with no line of sight. From rules 48 (the FFA-kin fog of war,
# sim.ffaFog) they are known only for the seat itself and the seats it can see now
# (visible(i)); for any other seat kin, gene, seatScore and seatAlive read -1, exactly what
# an invalid seat reads. seatCount, the hearts (heartOwner, controlOwner, capture fields:
# properties of the map heart, which every seat sees) are unchanged. BASIC registers these
# only in FFA-kin; outside it they read as FFA-kin would.
proc seatIndex(value: int): bool = value >= 0 and value < Seats
proc inMatch(v: SeatView, i: int): bool = v.world.cogs[i].hp > 0 or v.world.equipment[i].lives > 0
proc known(v: SeatView, value: int): bool =
  ## A valid seat whose per-seat facts this seat may read under the current rules.
  seatIndex(value) and (not ffaFog() or value == v.slot or v.visible(value) != 0)
proc gameModeValue*(v: SeatView): int32 = int32(ffa())  ## BASIC gameMode()
proc seatCount*(v: SeatView): int32 = Seats.int32
proc kin*(v: SeatView, i: int): int32 =
  if not v.known(i): -1'i32 else: activeKinship.rPercent(v.slot, i)
proc gene*(v: SeatView, i, locus: int): int32 =
  if not v.known(i) or locus < 0 or locus >= Loci or not v.inMatch(i): -1'i32
  else: int32((activeKinship.genes[i] shr locus.uint32) and 1'u32)
proc seatScore*(v: SeatView, i: int): int32 =
  if v.known(i): v.world.seatScore[i] else: -1'i32
proc seatAlive*(v: SeatView, i: int): int32 =
  if v.known(i): int32(v.inMatch(i)) else: -1'i32
proc heartOwner*(v: SeatView, i: int): int32 =
  if i >= 0 and i < v.world.controlHearts.len: v.world.controlHearts[i].owner else: -1'i32
proc territoryBoost*(v: SeatView): int32 = v.world.territoryBoost(v.slot).int32
proc greatHeartCount*(v: SeatView): int32 = v.world.greatHearts.len.int32
proc greatHeartField(v: SeatView, i, field: int): int32 =
  if i < 0 or i >= v.world.greatHearts.len: return -1
  let heart = v.world.greatHearts[i]
  case field
  of 0: heart.pos.x
  of 1: heart.pos.z
  of 2: heart.present.int32
  of 3: heart.progress
  else: max(0'i32, heart.dormantUntil-v.world.tick)
proc greatHeartX*(v: SeatView, i: int): int32 = v.greatHeartField(i, 0)
proc greatHeartY*(v: SeatView, i: int): int32 = v.greatHeartField(i, 1)
proc greatHeartPresent*(v: SeatView, i: int): int32 = v.greatHeartField(i, 2)
proc greatHeartProgress*(v: SeatView, i: int): int32 = v.greatHeartField(i, 3)
proc greatHeartDormant*(v: SeatView, i: int): int32 = v.greatHeartField(i, 4)

# ---------------------------------------------------------------------------------------
# Public geometry: map bounds, terrain, trenches and water.
proc mapMinX*(v: SeatView): int32 = minX().int32
proc mapMinY*(v: SeatView): int32 = minZ().int32
proc mapMaxX*(v: SeatView): int32 = maxX().int32
proc mapMaxY*(v: SeatView): int32 = maxZ().int32
proc terrainHeight*(v: SeatView, x, z: int): int32 =
  if visionRulesVersion >= 9: terrainHeight(clamp(x, minX(), maxX()), clamp(z, minZ(), maxZ())).int32 else: 0'i32
# Trenches are public geometry - the tactical map outlines them - so they are not fog-gated.
# Asking trenchAt about an enemy still needs that enemy's position, which only a cog that
# can see it has, so nothing hidden leaks through it.
proc trenchCount*(v: SeatView): int32 = v.world.trenches.len.int32
proc trenchField(v: SeatView, i, field: int): int32 =
  if i < 0 or i >= v.world.trenches.len: return -1
  let t = v.world.trenches[i]
  case field
  of 0: t.x + t.w div 2
  of 1: t.z + t.h div 2
  of 2: t.w
  else: t.h
proc trenchX*(v: SeatView, i: int): int32 = v.trenchField(i, 0)
proc trenchY*(v: SeatView, i: int): int32 = v.trenchField(i, 1)
proc trenchW*(v: SeatView, i: int): int32 = v.trenchField(i, 2)
proc trenchH*(v: SeatView, i: int): int32 = v.trenchField(i, 3)
proc trenchAt*(v: SeatView, x, z: int32): int32 = v.world.trenchAt(Point(x: x, z: z)).int32
# The lake is public geometry too. A cog in it moves at a quarter of its speed, and the
# navigator routes by distance rather than time, so without this a policy cannot know that
# the shortest way to a heart is the slowest one - and the most exposed.
proc waterAt*(v: SeatView, x, z: int): int32 =
  let cx = clamp(x, minX(), maxX()); let cz = clamp(z, minZ(), maxZ())
  int32(visionRulesVersion >= 30 and riverBlend(cx, cz) > 0 and terrainHeight(cx, cz) < RiverWaterHeight)

