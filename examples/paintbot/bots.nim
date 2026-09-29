## Bounded, persistent BASIC players: every seat is a BASIC script with typed observations.
import polyworld/[basic, cli, controllers]
import sim, oracle, neural_host, kinship
export oracle
when defined(coworld): import polyworld/coworld

type HeardMessage* = object
  slot*: int
  pos*: Point
  text*: string
type Bot* = ref object
  runtime*: Runtime
  failed*: bool
  error*: string ## The BasicError that disabled the seat, if any.
  output*: PrintProc
  strings*: StringPool
  neural*: NeuralSeat
# One decision's scratch (active world, commands, vision cache, shouts) and the hearing
# carried to the next decision. Training builds run many worlds on many threads: there
# the same variables are thread-local and the native host copies `heard` in and out
# around each step, so a handle may migrate between threads.
type
  NearAgent = object
    identity, body: int32
    d2: int64
  NearGrid = object
    ## Living cogs bucketed by NearCell squares, rebuilt on the first query of a tick.
    tick: int32
    built: bool
    originX, originZ, nx, nz: int
    cellStart, items: seq[int32]
const
  NearCell = 500
  NearMaxRadius = 20000
  NearMaxAgents = 64
when defined(pwTraining):
  var
    shouts* {.threadvar.}: seq[seq[string]]
    heard* {.threadvar.}: seq[seq[HeardMessage]]
    active* {.threadvar.}: World
    commands* {.threadvar.}: seq[Command]
  var visionCache {.threadvar.}: seq[seq[int8]]
  var nearGrid {.threadvar.}: NearGrid
  var nearLists {.threadvar.}: seq[seq[NearAgent]]
else:
  var
    shouts*: seq[seq[string]]
    heard*: seq[seq[HeardMessage]]
    active*: World
    commands*: seq[Command]
  var visionCache: seq[seq[int8]]
  var nearGrid: NearGrid
  var nearLists: seq[seq[NearAgent]]
proc resetVisionCache() =
  ## One unknown (0) visibility entry per observer and body, sized to this match's seats.
  visionCache.setLen(Seats)
  for row in visionCache.mitems:
    row.setLen(Seats)
    for v in row.mitems: v = 0
proc bodyForSeat(observer, identity: int): int =
  if identity notin 0..<Seats: return -1
  if identity == observer: return observer
  result = -1
  for body in 0..<Seats:
    if active.observedSeat(observer, body) != identity: continue
    if visionCache[observer][body] == 0:
      visionCache[observer][body] = if active.visible(observer, body): 1 else: -1
    if visionCache[observer][body] != 1: continue
    # If the genuine cog and its impersonator are both visible, report the
    # nearer body under their shared identity. No real-seat side channel.
    if result < 0 or distance2(active.cogs[observer].pos, active.cogs[body].pos) <
        distance2(active.cogs[observer].pos, active.cogs[result].pos): result = body
proc visibleToBot(slot, other: int): bool = bodyForSeat(slot, other) >= 0
proc buildNearGrid() =
  let g = addr nearGrid
  g.originX = minX(); g.originZ = minZ()
  g.nx = (maxX()-minX()) div NearCell+1; g.nz = (maxZ()-minZ()) div NearCell+1
  g.cellStart = newSeq[int32](g.nx*g.nz+1)
  var cells = newSeq[int](Seats)
  for b in 0..<Seats:
    cells[b] = -1
    let c = active.cogs[b]
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
  g.tick = active.tick; g.built = true
proc nearAgents(slot, radius: int): int =
  ## The agents `slot` can see within `radius`, nearest first, under the identities it
  ## observes (a disguised body reports its disguise; of two bodies sharing an identity the
  ## nearer is kept, as playerX does). Visits only grid cells the circle touches, so the
  ## cost follows the neighbourhood, not the roster.
  if nearLists.len != Seats: nearLists.setLen(Seats)
  nearLists[slot].setLen(0)
  let me = active.cogs[slot]
  if me.hp <= 0: return 0
  if not nearGrid.built or nearGrid.tick != active.tick: buildNearGrid()
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
        let d2 = distance2(me.pos, active.cogs[b].pos)
        if d2 > r2: continue
        if visionCache[slot][b] == 0:
          visionCache[slot][b] = if active.visible(slot, b): 1 else: -1
        if visionCache[slot][b] != 1: continue
        let identity = active.observedSeat(slot, b).int32
        var dup = -1
        for i, e in nearLists[slot]:
          if e.identity == identity: dup = i; break
        if dup < 0: nearLists[slot].add NearAgent(identity: identity, body: b.int32, d2: d2)
        elif d2 < nearLists[slot][dup].d2 or (d2 == nearLists[slot][dup].d2 and b < nearLists[slot][dup].body):
          nearLists[slot][dup] = NearAgent(identity: identity, body: b.int32, d2: d2)
  # Nearest first; ties by identity, so the order never depends on the grid's scan order.
  let list = addr nearLists[slot]
  for i in 1..<list[].len:
    let e = list[][i]; var j = i-1
    while j >= 0 and (list[][j].d2 > e.d2 or (list[][j].d2 == e.d2 and list[][j].identity > e.identity)):
      list[][j+1] = list[][j]; dec j
    list[][j+1] = e
  if list[].len > NearMaxAgents: list[].setLen(NearMaxAgents)
  list[].len
proc nearAgentsFor*(w: World, slot, radius: int): seq[tuple[identity, body: int]] =
  ## Test hook: the nearAgents answer for one seat against a fresh tick of `w`.
  active = w
  resetVisionCache()
  nearGrid.built = false
  discard nearAgents(slot, radius)
  for e in nearLists[slot]: result.add (e.identity.int, e.body.int)
const DataNames = ["selfId","selfTeam","selfX","selfY","selfHp","carrying","homeX","homeY","heartX","heartY","worldTick","ownHeartX","ownHeartY","ownHeartStolen","hasGrenade","hasSpray","armorHp","livesLeft","grenadeCharge","trenchId"]
proc limits*(): Limits =
  # An advised seat drafts a structured request and, with the terrain prompt on, probes water
  # along three routes and scans every trench and remembered supply for three candidates on the
  # ask tick. That peaked at 19,000 of the old 20,000 instructions and disabled seats late in a
  # match, so the budget carries headroom: the heaviest measured arm uses about 38% of it. The
  # plain baseline peaks near 5,000 instructions and is unaffected.
  result=defaultLimits()
  result.maxSourceBytes=128*1024; result.maxInstructions=50000
  result.maxMemoryBytes=2*1024*1024; result.maxWorkUnits=125000
  if Seats > LegacySeats:
    # Crowd matches: a script's roster loops grow with the seat count, and so does its budget.
    result.maxInstructions=50000*Seats div LegacySeats; result.maxWorkUnits=125000*Seats div LegacySeats
  result.maxArrayElements=4096;result.maxGlobals=512;result.maxCallDepth=16
  result.maxPrintBytes=1024;result.maxPrintEvents=128
proc host(slot:int, strings:StringPool, neural:NeuralSeat): Host =
  result=initHost()
  result.addNeuralFunctions(neural, proc(command: Command) = commands[slot] = command)
  result.addStringFunctions(strings)
  result.addOracleFunctions(slot,strings)
  discard result.addFunction("shout",1,proc(a:openArray[int32]):int32 =
    if shouts[slot].len>=4:return 0
    shouts[slot].add strings.getString(a[0])[0..<min(256,strings.getString(a[0]).len)];1,68)
  discard result.addFunction("heardCount",0,proc(a:openArray[int32]):int32 = heard[slot].len.int32,4)
  discard result.addFunction("heardText",1,proc(a:openArray[int32]):int32 =
    let i=a[0].int
    if i<0 or i>=heard[slot].len:return strings.putString("")
    strings.putString(heard[slot][i].text),4)
  proc getHeard(field:int):HostProc =
    result = proc(a:openArray[int32]):int32 =
      let i=a[0].int
      if i<0 or i>=heard[slot].len:return -1
      if field==0:heard[slot][i].slot.int32
      elif field==1:heard[slot][i].pos.x
      else:heard[slot][i].pos.z
  for axis in 0..2:
    discard result.addFunction(["heardSlot","heardX","heardY"][axis],1,getHeard(axis),4)
  discard result.addFunction("sneak",1,proc(a:openArray[int32]):int32 =
    commands[slot].sneak=a[0]!=0;1,4)
  discard result.addFunction("soundCount",0,proc(a:openArray[int32]):int32 =
    var count = 0
    for cue in active.sounds:
      if cue.listener==slot.int32 and active.tick-cue.tick<=SoundLifetime: inc count
    count.int32,4)
  proc getSound(field:int):HostProc =
    result = proc(a:openArray[int32]):int32 =
      var index=0
      for cue in active.sounds:
        if cue.listener!=slot.int32 or active.tick-cue.tick>SoundLifetime:continue
        if index==a[0]:
          return (case field
            of 0:cue.kind
            of 1:cue.direction
            of 2:cue.distance
            else:active.tick-cue.tick)
        inc index
      -1
  for field in 0..3:
    discard result.addFunction(["soundKind","soundDirection","soundDistance","soundAge"][field],1,getSound(field),4)
  for name in DataNames:discard result.addData(name)
  discard result.addFunction("visible",1,proc(a:openArray[int32]):int32 = int32(visibleToBot(slot,a[0].int)),4)
  # FFA-kin: every seat is its own side, so a visible cog's team is its seat.
  discard result.addFunction("playerTeam",1,proc(a:openArray[int32]):int32 =
    if not visibleToBot(slot,a[0].int): -1'i32
    elif ffa(): bodyForSeat(slot,a[0].int).int32
    else: active.observedTeam(slot,bodyForSeat(slot,a[0].int)).int32,4)
  # Nearby agents: nearAgents(radius) lists the agents this seat can see within radius
  # (clamped to 20000), nearest first, at most 64; nearAgentId/X/Y/Hp/Team(k) read entry k,
  # -1 (Hp 0) past the end. Cost follows the neighbourhood, so large games stay cheap.
  discard result.addFunction("nearAgents",1,proc(a:openArray[int32]):int32 = nearAgents(slot,a[0].int).int32,16)
  proc nearField(field:int):HostProc =
    result = proc(a:openArray[int32]):int32 =
      let k=a[0].int
      if k<0 or k>=nearLists[slot].len: return (if field==3: 0'i32 else: -1'i32)
      let e=nearLists[slot][k];let c=active.cogs[e.body]
      case field
      of 0: e.identity
      of 1: c.pos.x
      of 2: c.pos.z
      of 3: c.hp
      else: (if ffa(): e.body else: active.observedTeam(slot,e.body.int).int32)
  for field in 0..4:
    discard result.addFunction(["nearAgentId","nearAgentX","nearAgentY","nearAgentHp","nearAgentTeam"][field],1,nearField(field),4)
  discard result.addFunction("hasUniform",0,proc(a:openArray[int32]):int32 = active.uniforms[slot].int32,4)
  discard result.addFunction("playerX",1,proc(a:openArray[int32]):int32 =
    if visibleToBot(slot,a[0].int):active.cogs[bodyForSeat(slot,a[0].int)].pos.x else: -1,4)
  discard result.addFunction("playerY",1,proc(a:openArray[int32]):int32 =
    if visibleToBot(slot,a[0].int):active.cogs[bodyForSeat(slot,a[0].int)].pos.z else: -1,4)
  discard result.addFunction("playerHp",1,proc(a:openArray[int32]):int32 =
    if visibleToBot(slot,a[0].int):active.cogs[bodyForSeat(slot,a[0].int)].hp else:0,4)
  discard result.addFunction("playerCarrying",1,proc(a:openArray[int32]):int32 =
    if visibleToBot(slot,a[0].int):active.cogs[bodyForSeat(slot,a[0].int)].carrying.int32 else:0,4)
  discard result.addFunction("chargeGrenade",1,proc(a:openArray[int32]):int32 =
    commands[slot].chargeGrenade=a[0]!=0;1,4)
  discard result.addFunction("pickupCount",0,proc(a:openArray[int32]):int32 = active.pickups.len.int32,4)
  discard result.addFunction("pickupVisible",1,proc(a:openArray[int32]):int32 =
    let i=a[0].int
    int32(i>=0 and i<active.pickups.len and active.pickups[i].readyAt<=active.tick and active.canSeePoint(slot,active.pickups[i].pos)),4)
  proc getPickup(field:int):HostProc =
    result = proc(a:openArray[int32]):int32 =
      let i=a[0].int
      if i<0 or i>=active.pickups.len or active.pickups[i].readyAt>active.tick or not active.canSeePoint(slot,active.pickups[i].pos):return -1
      if field==0:active.pickups[i].pos.x
      elif field==1:active.pickups[i].pos.z
      else:active.pickups[i].kind.int32
  for axis in 0..2:
    discard result.addFunction(["pickupX","pickupY","pickupKind"][axis],1,getPickup(axis),4)
  discard result.addFunction("heartCount",0,proc(a:openArray[int32]):int32 = active.controlHearts.len.int32,4)
  discard result.addFunction("glory",1,proc(a:openArray[int32]):int32 =
    (if a[0] >= 0 and a[0] <= 1: active.glory[a[0]] else: -1'i32),4)
  # The public scoreboard (observation contract v3's block): team t's lives left, the sum the
  # behind-in-lives glory award compares, and that award (glory per life trailed) and its
  # period in seconds as the match's glory config sets them. The HUD shows all of it. The
  # teams game only: FFA-kin (no teams) reads -1, as does a team other than 0 or 1.
  discard result.addFunction("teamLives",1,proc(a:openArray[int32]):int32 =
    (if not ffa() and a[0] >= 0 and a[0] <= 1: active.teamLives(a[0].int) else: -1'i32),4)
  discard result.addFunction("awardBehind",0,proc(a:openArray[int32]):int32 =
    (if ffa(): -1'i32 else: gloryRules().behindLives),4)
  discard result.addFunction("awardBehindSeconds",0,proc(a:openArray[int32]):int32 =
    (if ffa(): -1'i32 else: gloryRules().behindLivesSeconds),4)
  # Rules 47: team t's cogs out of the match (dead, no lives left), the count the
  # behind-in-cogs glory award compares, and that award and its period. FFA-kin reads -1.
  discard result.addFunction("teamCogsOut",1,proc(a:openArray[int32]):int32 =
    (if not ffa() and a[0] >= 0 and a[0] <= 1: active.teamCogsOut(a[0].int) else: -1'i32),4)
  discard result.addFunction("awardBehindCogs",0,proc(a:openArray[int32]):int32 =
    (if ffa(): -1'i32 else: gloryRules().behindCogs),4)
  discard result.addFunction("awardBehindCogsSeconds",0,proc(a:openArray[int32]):int32 =
    (if ffa(): -1'i32 else: gloryRules().behindCogsSeconds),4)
  # Rules 38: glory hearts are fog-gated like pickups; hidden or invalid ones read -1.
  discard result.addFunction("gloryHeartCount",0,proc(a:openArray[int32]):int32 = active.gloryHearts.len.int32,4)
  proc getGloryHeart(field:int):HostProc =
    result = proc(a:openArray[int32]):int32 =
      let i=a[0].int
      if i<0 or i>=active.gloryHearts.len or not active.canSeePoint(slot,active.gloryHearts[i].pos):return -1
      if field==0:active.gloryHearts[i].pos.x
      elif field==1:active.gloryHearts[i].pos.z
      else:active.gloryHearts[i].expiresAt-active.tick
  for axis in 0..2:
    discard result.addFunction(["gloryHeartX","gloryHeartY","gloryHeartTicksLeft"][axis],1,getGloryHeart(axis),4)
  proc getControl(field:int):HostProc =
    result = proc(a:openArray[int32]):int32 =
      let i=a[0].int
      if i<0 or i>=active.controlHearts.len:return -1
      if field==0:active.controlHearts[i].pos.x
      elif field==1:active.controlHearts[i].pos.z
      elif field==2:active.controlHearts[i].owner
      elif field==6:active.heartPoints(i)
      elif i>=active.heartCaptures.len:
        if field==3: -1'i32 else: 0'i32
      elif field==3:active.heartCaptures[i].team
      elif field==4:active.heartCaptures[i].ticks
      else:active.heartCaptures[i].contested.int32
  for axis in 0..6:
    discard result.addFunction(["controlX","controlY","controlOwner",
      "controlCaptureTeam","controlCaptureTicks","controlContested","controlPoints"][axis],1,getControl(axis),4)
  # FFA-kin (Heartland) functions exist only in that mode: the teams game keeps exactly its
  # old host names, so submitted scripts using kin, gene, seatScore... as variables still compile.
  # gameMode is set before any seat is built (coworld config, replay header, native reset).
  # Before rules 48 kinship, genes, raw scores and who is still in the match are public, with
  # no line of sight. From rules 48 (the FFA-kin fog of war, sim.ffaFog) they are known only for
  # the seat itself and the seats it can see now (visible(i)); for any other seat kin, gene,
  # seatScore and seatAlive read -1, exactly what an invalid seat reads. seatCount, the hearts
  # (heartOwner, controlOwner, capture fields: properties of the map heart, which every seat
  # sees) and shouts (heard within range whatever the line of sight) are unchanged.
  if ffa():
    proc seatIndex(value: int32): bool = value >= 0 and value < Seats
    proc inMatch(i: int): bool = active.cogs[i].hp > 0 or active.equipment[i].lives > 0
    proc known(value: int32): bool =
      ## A valid seat whose per-seat facts this seat may read under the current rules.
      seatIndex(value) and (not ffaFog() or value == slot.int32 or visibleToBot(slot, value.int))
    discard result.addFunction("gameMode",0,proc(a:openArray[int32]):int32 = 1,4)
    discard result.addFunction("seatCount",0,proc(a:openArray[int32]):int32 = Seats.int32,4)
    discard result.addFunction("kin",1,proc(a:openArray[int32]):int32 =
      if not known(a[0]): -1'i32
      else: activeKinship.rPercent(slot, a[0].int),4)
    discard result.addFunction("gene",2,proc(a:openArray[int32]):int32 =
      if not known(a[0]) or a[1] < 0 or a[1] >= Loci or not inMatch(a[0].int): -1'i32
      else: int32((activeKinship.genes[a[0]] shr a[1].uint32) and 1'u32),4)
    discard result.addFunction("seatScore",1,proc(a:openArray[int32]):int32 =
      if known(a[0]): active.seatScore[a[0]] else: -1'i32,4)
    discard result.addFunction("seatAlive",1,proc(a:openArray[int32]):int32 =
      if known(a[0]): int32(inMatch(a[0].int)) else: -1'i32,4)
    discard result.addFunction("heartOwner",1,proc(a:openArray[int32]):int32 =
      if a[0] >= 0 and a[0] < active.controlHearts.len: active.controlHearts[a[0]].owner else: -1'i32,4)
    discard result.addFunction("territoryBoost",0,proc(a:openArray[int32]):int32 =
      active.territoryBoost(slot).int32,4)
    discard result.addFunction("greatHeartCount",0,proc(a:openArray[int32]):int32 =
      active.greatHearts.len.int32,4)
    proc getGreatHeart(field:int):HostProc =
      result = proc(a:openArray[int32]):int32 =
        if a[0] < 0 or a[0] >= active.greatHearts.len: return -1
        let heart = active.greatHearts[a[0]]
        case field
        of 0: heart.pos.x
        of 1: heart.pos.z
        of 2: heart.present.int32
        of 3: heart.progress
        else: max(0'i32, heart.dormantUntil-active.tick)
    for field, name in ["greatHeartX","greatHeartY","greatHeartPresent","greatHeartProgress","greatHeartDormant"]:
      discard result.addFunction(name,1,getGreatHeart(field),4)
  discard result.addFunction("mapMinX",0,proc(a:openArray[int32]):int32 = minX().int32,4)
  discard result.addFunction("mapMinY",0,proc(a:openArray[int32]):int32 = minZ().int32,4)
  discard result.addFunction("mapMaxX",0,proc(a:openArray[int32]):int32 = maxX().int32,4)
  discard result.addFunction("mapMaxY",0,proc(a:openArray[int32]):int32 = maxZ().int32,4)
  discard result.addFunction("terrainHeight",2,proc(a:openArray[int32]):int32 =
    if visionRulesVersion >= 9: terrainHeight(clamp(a[0].int,minX(),maxX()),clamp(a[1].int,minZ(),maxZ())).int32 else: 0'i32,4)
  # Trenches are public geometry - the tactical map outlines them - so they are not fog-gated.
  # Asking trenchAt about an enemy still needs that enemy's position, which only a cog that
  # can see it has, so nothing hidden leaks through it.
  discard result.addFunction("trenchCount",0,proc(a:openArray[int32]):int32 =
    active.trenches.len.int32,4)
  proc trenchField(field: int): HostProc =
    result = proc(a:openArray[int32]):int32 =
      if a[0] < 0 or a[0] >= active.trenches.len: return -1
      let t = active.trenches[a[0]]
      case field
      of 0: t.x + t.w div 2
      of 1: t.z + t.h div 2
      of 2: t.w
      else: t.h
  for field, name in ["trenchX", "trenchY", "trenchW", "trenchH"]:
    discard result.addFunction(name,1,trenchField(field),4)
  discard result.addFunction("trenchAt",2,proc(a:openArray[int32]):int32 =
    active.trenchAt(Point(x:a[0],z:a[1])).int32,8)
  # The lake is public geometry too. A cog in it moves at a quarter of its speed, and the
  # navigator routes by distance rather than time, so without this a policy cannot know that
  # the shortest way to a heart is the slowest one - and the most exposed.
  discard result.addFunction("waterAt",2,proc(a:openArray[int32]):int32 =
    let x = clamp(a[0].int,minX(),maxX()); let z = clamp(a[1].int,minZ(),maxZ())
    int32(visionRulesVersion >= 30 and riverBlend(x, z) > 0 and terrainHeight(x, z) < RiverWaterHeight),8)
  discard result.addFunction("walkTo",2,proc(a:openArray[int32]):int32 =
    commands[slot].walk=true;commands[slot].goal=Point(x:a[0],z:a[1]);1,4)
  discard result.addFunction("lookAt",2,proc(a:openArray[int32]):int32 =
    commands[slot].aim=Point(x:clamp(a[0],minX().int32,maxX().int32),z:clamp(a[1],minZ().int32,maxZ().int32));1,4)
  discard result.addFunction("shootAt",2,proc(a:openArray[int32]):int32 =
    commands[slot].shoot=true;commands[slot].aim=Point(x:clamp(a[0],minX().int32,maxX().int32),z:clamp(a[1],minZ().int32,maxZ().int32));1,4)
proc loadBots*(groups:seq[BotGroup], playerSlot = 0'i32):seq[Bot] =
  result = newSeq[Bot](Seats)
  # A hosted game journals every advisor request and answer to the asking seat's own log:
  # it is the only record of a decision's exact state that leaves the pod.
  when defined(coworld):
    oracleJournal = proc(slot: int, line: string) = playerLog(slot, line)
  let sources=groups.expandBotSources(controllerKinds(Seats,playerSlot))
  var paths = newSeq[string](Seats)
  var nextSlot = 0
  for group in groups:
    for unused in 0..<group.count:
      while nextSlot < Seats and isPlayerIndex(playerSlot, nextSlot): inc nextSlot
      if nextSlot < Seats: paths[nextSlot] = group.path
      inc nextSlot
  for slot in 0..<Seats:
    if isPlayerIndex(playerSlot, slot): continue
    # Oracle drafts are text-heavy: four times the default handle count, same 64 KiB arena.
    var stringLimits=defaultStringLimits()
    stringLimits.maxStrings=1024
    let strings=initStringPool(stringLimits)
    var neural: NeuralSeat
    var neuralFailed = false
    try:
      neural = loadNeuralSeat(paths[slot], slot)
    except CatchableError as e:
      neural = NeuralSeat(slot: slot)
      neuralFailed = true
      when defined(coworld):
        if e of NeuralBudgetError:
          # The rejected model's cost, so the seat log says how far over budget it was.
          let budget = (ref NeuralBudgetError)(e)
          playerLog(slot, neuralTelemetry(budget.operations, budget.model, 0) & "\n")
        playerError(slot, "Neural package failed: " & e.msg)
      else: echo "seat ", slot, " neural package failed: ", e.msg
    let h=host(slot,strings,neural)
    let p=when defined(coworld):compilePlayer(sources[slot],h,limits(),slot)
      else:compile(sources[slot],h,limits())
    strings.bindProgram(p)
    result[slot]=Bot(runtime:initRuntime(p,h,limits()),strings:strings,neural:neural,failed:neuralFailed)
    when defined(coworld):result[slot].output=playerPrinter(slot)
when defined(pwTraining):
  var peakInstructions* {.threadvar.}: array[MaxSeats, int64]
  var peakWork* {.threadvar.}: array[MaxSeats, int64]
  var peakStrings* {.threadvar.}: array[MaxSeats, int64]
  var peakNativeWork* {.threadvar.}: array[MaxSeats, int64]
  proc loadScriptBot*(source: string, slot: int): Bot =
    ## One seat from BASIC source text, exactly as loadBots builds a file seat without a
    ## neural package: same string limits, host functions, compile limits and runtime
    ## budget. Raises BasicError when the source does not compile.
    var stringLimits=defaultStringLimits()
    stringLimits.maxStrings=1024
    let strings=initStringPool(stringLimits)
    let neural = loadNeuralSeat("/nonexistent/paintbot-pw-script-seat", slot)
    let h=host(slot,strings,neural)
    let p=compile(source,h,limits())
    strings.bindProgram(p)
    Bot(runtime:initRuntime(p,h,limits()),strings:strings,neural:neural)
  proc loadPolicyBot*(source, manifest: string, slot: int, observationHash: string): Bot =
    ## A training policy-script seat: the bundle's policy.bas and manifest.json, built as
    ## loadBots builds a hosted neural seat (same limits, host functions and budget), with
    ## neural_host.policyNeuralSeat in place of the actor: the trainer feeds the logits.
    ## Raises ValueError when the manifest is rejected, BasicError when the source does not
    ## compile.
    var stringLimits=defaultStringLimits()
    stringLimits.maxStrings=1024
    let strings=initStringPool(stringLimits)
    let neural = policyNeuralSeat(manifest, slot, observationHash)
    let h=host(slot,strings,neural)
    let p=compile(source,h,limits())
    strings.bindProgram(p)
    Bot(runtime:initRuntime(p,h,limits()),strings:strings,neural:neural)
else:
  var peakInstructions*, peakWork*, peakStrings*, peakNativeWork*: array[MaxSeats, int64] ## per-seat BASIC peaks, for PW_BASIC_PEAKS
proc logNeuralTelemetry*(bots: openArray[Bot], ticks: int,
    log: proc(slot: int, text: string)) =
  ## Writes each neural seat's telemetry line (peak operations against the budget) through
  ## `log`, one line per seat that loaded a neural model. Plain BASIC seats are skipped, and
  ## nothing here touches the world or the seats' runtimes.
  for slot in 0..<Seats:
    if bots[slot].isNil: continue
    let line = bots[slot].neural.telemetry(peakNativeWork[slot], ticks)
    if line.len > 0: log(slot, line & "\n")
proc decide*(bots:openArray[Bot],w:World):seq[Command] =
  shouts=newSeq[seq[string]](Seats)
  # Speech heard last tick (deliverSpeech); none yet on a match's first decision.
  if heard.len != Seats: heard.setLen(Seats)
  active=w;commands=newSeq[Command](Seats)
  resetVisionCache()
  nearGrid.built=false
  nearLists.setLen(Seats)
  for l in nearLists.mitems: l.setLen(0)
  beginOracleTick(w.tick)
  for slot in 0..<Seats:
    let b=(if slot < bots.len: bots[slot] else: nil);let cog=w.cogs[slot]
    # FFA-kin has no team hearts: home is the seat's spawn anchor, and the carried-heart data
    # all read home (never stolen). selfTeam is the seat.
    var home, heart, ownPos: Point
    var ownStolen = false
    if ffa():
      home = w.spawnAnchor[slot]; heart = home; ownPos = home
    else:
      home = home(team(slot))
      let enemyHeart=w.hearts[1-team(slot)];let own=w.hearts[team(slot)]
      heart=if enemyHeart.carrier<0 or w.visible(slot,enemyHeart.carrier.int):enemyHeart.pos else:home(1-team(slot))
      ownPos=if own.carrier<0 or w.visible(slot,own.carrier.int):own.pos else:home
      ownStolen = own.carrier>=0
    let selfTeam = if ffa(): slot else: team(slot)
    if b.isNil: continue
    b.neural.beginTick(active)
    if b.failed or cog.hp<=0:continue
    let values=[slot.int32,selfTeam.int32,cog.pos.x,cog.pos.z,cog.hp,cog.carrying.int32,home.x,home.z,heart.x,heart.z,w.tick,ownPos.x,ownPos.z,int32(ownStolen),w.equipment[slot].grenade.int32,w.equipment[slot].sprayCan.int32,w.equipment[slot].armor,w.equipment[slot].lives,w.equipment[slot].charge,w.trenchAt(cog.pos).int32]
    b.runtime.restart()
    b.strings.reset()
    try:
      for j,name in DataNames:b.runtime.setData(name,values[j])
      let stats = b.runtime.run(b.output)
      peakNativeWork[slot] = max(peakNativeWork[slot], b.neural.nativeWork)
      peakInstructions[slot] = max(peakInstructions[slot], stats.instructions)
      peakWork[slot] = max(peakWork[slot], stats.workUnits)
      peakStrings[slot] = max(peakStrings[slot], b.strings.stringCount.int64)
    except BasicError as e:
      b.failed=true;b.error=e.msg;commands[slot]=Command()
      when defined(coworld):playerError(slot,e.msg)
      elif not defined(pwTraining):echo "seat ",slot," disabled: ",e.msg
  commands

proc deliverSpeech*(w: World) =
  ## Next-tick hearing matches CTF's 20%-of-map-width radius, regardless of vision.
  heard=newSeq[seq[HeardMessage]](Seats)
  for sender in 0..<Seats:
    if w.cogs[sender].hp<=0:continue
    for receiver in 0..<Seats:
      if receiver==sender or w.cogs[receiver].hp<=0:continue
      if distance2(w.cogs[sender].pos,w.cogs[receiver].pos)>(Width div 5).int64*(Width div 5):continue
      for message in shouts[sender]:
        heard[receiver].add HeardMessage(slot:w.observedSeat(receiver,sender),pos:w.cogs[sender].pos,text:message)
