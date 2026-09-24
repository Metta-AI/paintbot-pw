## Versioned policy-visible float observations and categorical actuators.
## Used unchanged by BASIC deployment and native Puffer rollouts.
import std/math
import polyworld/rngs
import sim

const
  ObservationSize* = 448
  ActionSizes* = [51, 25, 2, 2, 2]
  LogitSize* = 82
  ObservationContract* = "paintbot-pw.rules37.obs.v1.float448"
  ActionContract* = "paintbot-pw.rules37.action.v1.51-25-2-2-2"
  ObservationContractHash* = "ed5d16768e3144a04a28420ce227ff2d6a831be9f64f3633326b133a5335b7e2"
  ActionContractHash* = "55922d42d4065a069b3193f31e056c3a53cd34175b10fed7ff0d8c22b50a473e"
  ## Action contract v2: the same five heads and sizes; an identity aim resolves to the
  ## body's lead-compensated aim point (leadAimPoint) instead of its current position.
  ## Directional aim, movement, fire, grenade and sneak decode exactly as in v1.
  ActionContractV2* = "paintbot-pw.rules37.action.v2.51-25-2-2-2"
  ActionContractV2Hash* = "51f602ef167919ca825595f9d81777cb807afbb0938a20102457d0594e2b4317"
  ## Observation contract v2: the v1 observation, unchanged in order and value, in
  ## columns 0 .. ObservationSize-1, followed by a public terrain block
  ## (TerrainBlockSize floats; encodeTerrainBlock documents every column). Selected per
  ## seat by the actor's embedded observation hash; v1 actors keep the v1 encoder.
  TerrainBlockSize* = 58
  ObservationSizeV2* = ObservationSize + TerrainBlockSize
  ObservationContractV2* = "paintbot-pw.rules37.obs.v2.float506"
  ObservationContractV2Hash* = "e0d7b0b97975725c470ef6119ca2a6caf4aaa6f34cd15bee02bd306489c029e5"
  ## Terrain heights (w.elevation: terrain plus trench, centimetres; the playable
  ## rules-37 span measures -260 .. 551) are divided by this, so every height and height
  ## delta the block carries lies within about [-1, 1] (the river bed below a level
  ## bank is -200 / 800 = -0.25).
  TerrainHeightScale* = 800
  Directions =[(1,0), (1,1), (0,1), (-1,1), (-1,0), (-1,-1), (0,-1), (1,-1)]
  # Lead compensation (contract v2), derived from the gun in mechanics.nim (rules >= 10):
  # the tick a shoot order is applied the shooter first moves, then gunAim = aim - pos is
  # locked; the ray leaves GunWindupTicks ticks later from wherever the shooter then
  # stands, along the locked vector. With one move per tick the shooter has made 6 moves
  # when the ray leaves and the direction was fixed after the first, so for a target
  # velocity u and the shooter's own per-tick step v the ray through the target's future
  # position needs aim = body + (GunWindupTicks+1)*u - GunWindupTicks*v. base.bas ("the
  # ray leaves six moves after the order... aim where they will be, minus our own drift")
  # uses the same 6 and 5, with its planned leg as v while in contact.
  LeadTargetMoves* = GunWindupTicks + 1
  LeadOwnMoves* = GunWindupTicks
  # A larger per-axis displacement than any one-tick move (MoveSpeed 28, diagonal yield
  # steps included) is a respawn or teleport, not a velocity; base.bas uses the same 60.
  TeleportStep* = 60
static: doAssert LeadTargetMoves == 6 and LeadOwnMoves == 5 and TeleportStep > 2*MoveSpeed
const
  # Decoder fire hold (a per-bundle option, off by default; not part of any action
  # contract: candidates and hashes are untouched). A shoot order is held when a teammate
  # the seat can see stands within the gun's own hit tolerance (mechanics.nim tests every
  # ray sample against Radius) of the segment from the seat to the aim the order leaves,
  # and no farther along it than the aim point itself.
  FireHoldRadius* = Radius
  # decoder.fire_hold_teammates {"radius": r}: pw-diag4 found 97-100 % of the v7
  # champion's gun friendly fire comes from teammates outside the 55-unit hold at the
  # order tick who walk into the ray during the windup; a wider radius holds those
  # orders. 1 .. MaxFireHoldRadius; the default (and the boolean form) stays Radius.
  MaxFireHoldRadius* = 2000'i32
static: doAssert FireHoldRadius == 55
static: doAssert ObservationSizeV2 == 506 and ObservationContractV2 == "paintbot-pw.rules37.obs.v2.float" & $ObservationSizeV2

type
  ObservationContractVersion* = enum
    ocV1 = 1, ocV2 = 2
  ActionContractVersion* = enum
    acV1 = 1, acV2 = 2
  AimMemory* = object
    ## What a seat saw one tick ago, kept by the host outside the World (never hashed,
    ## never serialized): the pre-step tick it was recorded on and, per apparent
    ## identity, the body it resolved to and that body's position. Contract v2 derives
    ## the target's velocity from it; contract v1 never reads it.
    tick*: int32 # -1 when nothing is recorded
    bodies*: array[Seats, int]
    positions*: array[Seats, Point]

proc actionContractHash*(version: ActionContractVersion): string =
  case version
  of acV1: ActionContractHash
  of acV2: ActionContractV2Hash
proc actionContractId*(version: ActionContractVersion): string =
  case version
  of acV1: ActionContract
  of acV2: ActionContractV2
proc actionContractVersion*(hash: string): ActionContractVersion =
  ## The contract an actor or manifest hash names; ValueError for anything else.
  if hash == ActionContractHash: acV1
  elif hash == ActionContractV2Hash: acV2
  else: raise newException(ValueError, "unknown neural action contract")

proc observationContractHash*(version: ObservationContractVersion): string =
  case version
  of ocV1: ObservationContractHash
  of ocV2: ObservationContractV2Hash
proc observationContractId*(version: ObservationContractVersion): string =
  case version
  of ocV1: ObservationContract
  of ocV2: ObservationContractV2
proc observationSize*(version: ObservationContractVersion): int =
  case version
  of ocV1: ObservationSize
  of ocV2: ObservationSizeV2
proc observationContractVersion*(hash: string): ObservationContractVersion =
  ## The contract an actor or manifest hash names; ValueError for anything else.
  if hash == ObservationContractHash: ocV1
  elif hash == ObservationContractV2Hash: ocV2
  else: raise newException(ValueError, "unknown neural observation contract")

proc observedBodies*(w: World, slot: int): array[Seats, int] =
  ## Match BASIC identity resolution, including uniforms and duplicate identities.
  ## Pure in the world: hosts that observe, decode and drive bots on one unchanged
  ## tick may compute it once per seat and pass it to the overloads below.
  for i in 0..<Seats: result[i] = -1
  result[slot] = slot
  for body in 0..<Seats:
    if body == slot or not w.visible(slot, body): continue
    let identity = w.observedSeat(slot, body)
    if identity notin 0..<Seats or identity == slot: continue
    let previous = result[identity]
    if previous < 0 or distance2(w.cogs[slot].pos, w.cogs[body].pos) <
        distance2(w.cogs[slot].pos, w.cogs[previous].pos): result[identity] = body

proc relativeTeam(value, side: int): float32 =
  if value < 0: 0'f32
  elif value == side: 1'f32
  else: -1'f32

proc encodeObservation*(w: World, slot: int, output: var openArray[float32],
    bodies: array[Seats, int]) =
  if slot notin 0..<Seats or output.len != ObservationSize:
    raise newException(ValueError, "invalid neural observation dimensions or seat")
  for i in 0..<output.len: output[i] = 0
  let me = w.cogs[slot]
  let gear = w.equipment[slot]
  let side = team(slot)
  let flip = if side == 0: 1'f32 else: -1'f32
  let spanX = float32(maxX()-minX())
  let spanZ = float32(maxZ()-minZ())
  var k = 0
  template put(value: untyped) =
    output[k] = float32(value)
    inc k
  template position(p: Point) =
    put(float32(p.x-me.pos.x)*flip/spanX)
    put(float32(p.z-me.pos.z)*flip/spanZ)
  # Self features (24). Public own-state metadata; no hidden entity state.
  put(float32(me.pos.x-Width div 2)*flip/spanX)
  put(float32(me.pos.z-Height div 2)*flip/spanZ)
  put(float32(me.hp)/3)
  put(float32(gear.armor)/3)
  put(float32(gear.lives)/4)
  put(gear.grenade.int)
  put(gear.sprayCan.int)
  put(float32(gear.charge)/24)
  put(float32(me.cooldown)/72)
  put(float32(me.respawn)/72)
  put(float32(me.shield)/36)
  put(me.carrying.int)
  position(me.aim)
  put(float32(w.tick)/max(1, w.endTick).float32)
  put(float32(w.scoreTicks[side])/max(1, w.heartMeterTarget()).float32)
  put(float32(w.scoreTicks[1-side])/max(1, w.heartMeterTarget()).float32)
  put(float32(w.glory[side])/1000)
  put(float32(w.glory[1-side])/1000)
  put(float32(slot div 2)/7)
  put(w.uniforms[slot].int)
  put((w.trenchAt(me.pos)>=0).int)
  put(float32(gear.windup)/5)
  put(float32(gear.sprayCooldown)/60)
  # Public hearts (10 * 8).
  for i in 0..<10:
    if i >= w.controlHearts.len: k += 8; continue
    let heart = w.controlHearts[i]
    put(1)
    position(heart.pos)
    put(relativeTeam(heart.owner.int, side))
    if i < w.heartCaptures.len:
      let capture = w.heartCaptures[i]
      put(relativeTeam(capture.team.int, side))
      put(float32(capture.ticks)/HeartCaptureTicks)
      put(capture.contested.int)
    else: k += 3
    put(float32(w.heartPoints(i))/5)
  # Fog-gated apparent identities (16 * 8). No true-team or real-seat leakage.
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0: k += 8; continue
    let other = w.cogs[body]
    put(1)
    position(other.pos)
    put(relativeTeam(w.observedTeam(slot,body),side))
    put(float32(other.hp)/3)
    put(other.carrying.int)
    put((identity == slot).int)
    put(float32(identity div 2)/7)
  # Fog-gated available pickups (32 * 5), stable public pickup index.
  for i in 0..<32:
    if i >= w.pickups.len or w.pickups[i].readyAt > w.tick or
        not w.canSeePoint(slot,w.pickups[i].pos): k += 5; continue
    let pickup = w.pickups[i]
    put(1)
    position(pickup.pos)
    put(float32(pickup.kind.ord)/4)
    put(float32(i)/31)
  # Listener-relative sound bins (8 * 4). Never include exact sound origins.
  var soundCount = 0
  for sound in w.sounds:
    if soundCount >= 8: break
    if sound.listener != slot.int32 or w.tick-sound.tick notin 0..SoundLifetime: continue
    put(1)
    put(float32(sound.kind)/4)
    put(float32((sound.direction.int+(if side==0:0 else:4)) mod 8)/7)
    put(float32(sound.distance)/4)
    inc soundCount
  k += (8-soundCount)*4
  # Local public terrain: center and eight compass samples (9 * 2).
  for i in 0..<9:
    let delta = if i==0: (0,0) else: Directions[i-1]
    let p = point(me.pos.x.int+int(flip)*delta[0]*200,
                  me.pos.z.int+int(flip)*delta[1]*200)
    put((p.x.int>=minX() and p.x.int<=maxX() and p.z.int>=minZ() and
      p.z.int<=maxZ() and not w.blocked(p) and w.traversable(me.pos,p)).int)
    put(float32(w.elevation(p)-w.elevation(me.pos))/1000)
  doAssert k == 442 # Six reserved zeros preserve the fixed-width contract.
proc encodeObservation*(w: World, slot: int, output: var openArray[float32]) =
  if slot notin 0..<Seats or output.len != ObservationSize:
    raise newException(ValueError, "invalid neural observation dimensions or seat")
  w.encodeObservation(slot, output, w.observedBodies(slot))

proc inWater*(p: Point): bool =
  ## Standing in the river's water: exactly the predicate mechanics.nim uses to quarter a
  ## wading seat's speed (rules >= 30; bank ground above the waterline is dry).
  visionRulesVersion >= 30 and riverBlend(p.x.int, p.z.int) > 0 and
    terrainHeight(p.x.int, p.z.int) < RiverWaterHeight

proc encodeTerrainBlock*(w: World, slot: int, output: var openArray[float32],
    bodies: array[Seats, int]) =
  ## Observation contract v2's terrain block (TerrainBlockSize floats), written at
  ## output[0 ..< TerrainBlockSize]. Public terrain only, read at points the v1 block
  ## already reveals: the seat's own position, the ten public hearts and the bodies the
  ## seat can see under its apparent identities (fog and uniforms exactly as v1; a slot v1
  ## leaves empty stays empty here). "Wet" is inWater, "height" is w.elevation (terrain
  ## plus trench) / TerrainHeightScale.
  ##   0      self wet (0/1)
  ##   1      self height
  ##   2+2i   heart i (0..9) wet               (0 when the heart is absent)
  ##   3+2i   heart i height minus self height  (0 when the heart is absent)
  ##   22+2j  identity j (0..15) wet               (0 when v1's identity slot j is empty)
  ##   23+2j  identity j height minus self height  (0 when empty; the seat's own slot reads 0)
  ##   54     visible apparent enemies wet / 8
  ##   55     visible apparent enemies dry / 8
  ##   56     visible apparent teammates wet / 8 (the seat itself excluded)
  ##   57     visible apparent teammates dry / 8 (the seat itself excluded)
  if slot notin 0..<Seats or output.len != TerrainBlockSize:
    raise newException(ValueError, "invalid neural terrain block dimensions or seat")
  for i in 0..<output.len: output[i] = 0
  let me = w.cogs[slot]
  let side = team(slot)
  let own = w.elevation(me.pos)
  const scale = TerrainHeightScale.float32
  output[0] = inWater(me.pos).float32
  output[1] = float32(own)/scale
  for i in 0..<10:
    if i >= w.controlHearts.len: continue
    let p = w.controlHearts[i].pos
    output[2+2*i] = inWater(p).float32
    output[3+2*i] = float32(w.elevation(p)-own)/scale
  var enemyWet, enemyDry, mateWet, mateDry = 0
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0: continue
    let p = w.cogs[body].pos
    let wet = inWater(p)
    output[22+2*identity] = wet.float32
    output[23+2*identity] = float32(w.elevation(p)-own)/scale
    if identity == slot: continue
    let relation = relativeTeam(w.observedTeam(slot, body), side)
    if relation < 0:
      if wet: inc enemyWet else: inc enemyDry
    elif relation > 0:
      if wet: inc mateWet else: inc mateDry
  output[54] = float32(enemyWet)/8
  output[55] = float32(enemyDry)/8
  output[56] = float32(mateWet)/8
  output[57] = float32(mateDry)/8
static: doAssert 58 == TerrainBlockSize

proc encodeObservation*(w: World, slot: int, output: var openArray[float32],
    bodies: array[Seats, int], version: ObservationContractVersion) =
  ## The observation of the given contract. v1 is the encoder above, called unchanged;
  ## v2 writes the same v1 floats in columns 0 .. ObservationSize-1 and the terrain
  ## block after them.
  if slot notin 0..<Seats or output.len != observationSize(version):
    raise newException(ValueError, "invalid neural observation dimensions or seat")
  case version
  of ocV1: w.encodeObservation(slot, output, bodies)
  of ocV2:
    w.encodeObservation(slot, output.toOpenArray(0, ObservationSize-1), bodies)
    w.encodeTerrainBlock(slot, output.toOpenArray(ObservationSize, ObservationSizeV2-1), bodies)
proc encodeObservation*(w: World, slot: int, output: var openArray[float32],
    version: ObservationContractVersion) =
  if slot notin 0..<Seats or output.len != observationSize(version):
    raise newException(ValueError, "invalid neural observation dimensions or seat")
  w.encodeObservation(slot, output, w.observedBodies(slot), version)

proc resetAimMemory*(m: var AimMemory) =
  m.tick = -1
  for i in 0..<Seats:
    m.bodies[i] = -1
    m.positions[i] = Point()

proc recordAimMemory*(m: var AimMemory, w: World, slot: int, bodies: array[Seats, int]) =
  ## Record once per decided tick, on the same pre-step world the actions were decoded
  ## against, with the identities that decode resolved.
  m.tick = w.tick
  for identity in 0..<Seats:
    let body = bodies[identity]
    m.bodies[identity] = body
    m.positions[identity] = if body >= 0: w.cogs[body].pos else: Point()

proc oneTickStep(a, b: Point): Point =
  ## b - a when it can be one tick's movement; zero across a respawn or teleport.
  let dx = b.x - a.x
  let dz = b.z - a.z
  if abs(dx) > TeleportStep or abs(dz) > TeleportStep: Point() else: Point(x: dx, z: dz)

proc plannedStep*(w: World, slot: int, goal: Point, sneak: bool): Point =
  ## The move the world will make for the seat on the coming tick towards `goal` (the
  ## command's goal, clamped as the step clamps it): the same waypoint, speed (carrying,
  ## sneaking, wading) and trench damping as mechanics.nim, before any blocking or
  ## yielding. Zero when the seat is already there.
  let me = w.cogs[slot]
  let clamped = Point(x: clamp(goal.x, (minX()+100).int32, (maxX()-100).int32),
                      z: clamp(goal.z, (minZ()+100).int32, (maxZ()-100).int32))
  let dest = w.waypointFor(slot, me.pos, clamped)
  var speed = if me.carrying: MoveSpeed*7 div 10 else: MoveSpeed
  if visionRulesVersion >= 26 and sneak: speed = speed div 2
  if visionRulesVersion >= 30 and riverBlend(me.pos.x.int, me.pos.z.int) > 0 and
      terrainHeight(me.pos.x.int, me.pos.z.int) < RiverWaterHeight:
    speed = speed div 4
  if distance2(me.pos, dest) <= speed.int64*speed: return Point()
  result = direction(me.pos, dest, speed)
  let trench = w.trenchAt(me.pos)
  if trench >= 0:
    let t = w.trenches[trench]
    if abs(me.pos.x+result.x-(t.x+t.w div 2)) > abs(me.pos.x-(t.x+t.w div 2)): result.x = result.x div 5
    if abs(me.pos.z+result.z-(t.z+t.h div 2)) > abs(me.pos.z-(t.z+t.h div 2)): result.z = result.z div 5

proc leadAimPoint*(w: World, slot, identity, body: int, m: AimMemory, ownStep: Point): Point =
  ## Contract v2 identity aim: the point a shoot order issued now must name so that the
  ## gun's ray meets `body` if the body keeps last tick's velocity and the seat keeps
  ## making `ownStep` (see LeadTargetMoves). The body's velocity is its last-tick
  ## displacement as the seat itself could observe it: only when the same body was seen
  ## under the same identity one tick ago; a first tick, a gap, a respawn or a teleport
  ## counts as zero. The seat's own step is the move its movement head orders this tick
  ## (plannedStep), which is what the world will do, not a guess from the past. With a
  ## still target and a still seat the point is the body's position, the contract v1 aim.
  let now = w.cogs[body].pos
  result = now
  if m.tick == w.tick - 1 and m.bodies[identity] == body:
    let u = oneTickStep(m.positions[identity], now)
    result.x += u.x * LeadTargetMoves.int32
    result.z += u.z * LeadTargetMoves.int32
  result.x -= ownStep.x * LeadOwnMoves.int32
  result.z -= ownStep.z * LeadOwnMoves.int32

proc goalCandidate*(w: World, slot, movement: int): (bool, Point) =
  ## Where movement head index `movement` sends the seat, and whether that candidate
  ## exists now (a missing heart or an unavailable/unseen pickup keeps the goal).
  let me = w.cogs[slot]
  let flip = if team(slot)==0: 1 else: -1
  if movement in 1..10:
    if movement-1 < w.controlHearts.len: return (true, w.controlHearts[movement-1].pos)
  elif movement in 11..42:
    let i = movement-11
    if i < w.pickups.len and w.pickups[i].readyAt <= w.tick and
        w.canSeePoint(slot,w.pickups[i].pos): return (true, w.pickups[i].pos)
  elif movement >= 43 and movement <= 50:
    let delta = Directions[movement-43]
    return (true, point(clamp(me.pos.x.int+flip*delta[0]*200,minX(),maxX()),
                        clamp(me.pos.z.int+flip*delta[1]*200,minZ(),maxZ())))
  (false, me.pos)

proc aimCandidate*(w: World, slot, aim: int, bodies: array[Seats, int],
    version: ActionContractVersion, memory: AimMemory, ownStep: Point): (bool, Point) =
  ## Where aim head index `aim` points under `version`, and whether that candidate
  ## exists now (an identity nobody visible carries keeps the aim). `ownStep` is the
  ## seat's planned move for this tick (read under v2 only).
  let me = w.cogs[slot]
  let flip = if team(slot)==0: 1 else: -1
  if aim in 1..16:
    let body = bodies[aim-1]
    if body >= 0:
      return (true, if version == acV2: w.leadAimPoint(slot, aim-1, body, memory, ownStep)
                    else: w.cogs[body].pos)
  elif aim >= 17 and aim <= 24:
    let delta = Directions[aim-17]
    return (true, point(clamp(me.pos.x.int+flip*delta[0]*5000,minX(),maxX()),
                        clamp(me.pos.z.int+flip*delta[1]*5000,minZ(),maxZ())))
  (false, me.aim)

proc orderedAim*(w: World, slot: int, command: Command): Point =
  ## The aim the world holds once `command` is applied, as mechanics.nim applies it: an
  ## aim order wins; else a walk towards somewhere else aims there; else the current aim.
  if command.aim != Point(): command.aim
  elif command.walk and command.goal != w.cogs[slot].pos: command.goal
  else: w.cogs[slot].aim

proc teammateInLine*(w: World, slot: int, aim: Point, radius = FireHoldRadius.int32): bool =
  ## Whether a teammate's body, as the seat itself can see it (fog-gated, apparent team,
  ## and the gun's own line-of-sight test), lies within `radius` (default FireHoldRadius,
  ## the gun's hit tolerance) of the segment from the seat to `aim` and no farther along
  ## it than `aim`. Integer geometry only.
  let origin = w.cogs[slot].pos
  let dx = int64(aim.x) - origin.x
  let dz = int64(aim.z) - origin.z
  let len2 = dx*dx + dz*dz
  if len2 == 0: return false
  for body in 0..<Seats:
    if body == slot or w.cogs[body].hp <= 0: continue
    if not w.visible(slot, body) or w.observedTeam(slot, body) != team(slot): continue
    let p = w.cogs[body].pos
    let ex = int64(p.x) - origin.x
    let ez = int64(p.z) - origin.z
    let along = ex*dx + ez*dz
    if along < 0 or along > len2: continue
    # perpendicular^2 = e2 - along^2/len2 <= R^2  <=>  e2*len2 - along^2 <= R^2*len2
    # (|e|^2, |d|^2 < 2^27 on a 6400 x 4000 map and R <= MaxFireHoldRadius < 2^11, so
    # every product fits in 63 bits).
    let e2 = ex*ex + ez*ez
    if e2*len2 - along*along > radius.int64*radius*len2: continue
    if visionRulesVersion >= 9 and not w.lineClear(origin, p): continue
    return true
  false

proc holdFire*(w: World, slot: int, command: var Command, radius = FireHoldRadius.int32): bool =
  ## The decoder fire hold: drop the shoot order when a teammate is in the line of fire
  ## (teammateInLine of the aim the order leaves, within `radius` of it). The aim,
  ## movement and every other part of the command are untouched, so the world still turns
  ## to face the target. Applies to the shoot order whichever weapon it would fire.
  ## Returns whether the order was held.
  if not command.shoot or w.cogs[slot].hp <= 0: return false
  if not w.teammateInLine(slot, w.orderedAim(slot, command), radius): return false
  command.shoot = false
  true

proc decodeActions*(w: World, slot: int, actions: openArray[int32],
    bodies: array[Seats, int], version: ActionContractVersion,
    memory: AimMemory, fireHold = false): Command =
  ## The shared decoder of every host. `version` selects the identity-aim rule; the
  ## memory is read only under contract v2 (the host records it with recordAimMemory
  ## after decoding each tick). `fireHold` applies holdFire to the decoded command (the
  ## bundle's decoder option; false decodes exactly as before).
  if slot notin 0..<Seats or actions.len != ActionSizes.len:
    raise newException(ValueError, "invalid neural action dimensions or seat")
  for i,size in ActionSizes:
    if actions[i] < 0 or actions[i] >= size.int32:
      raise newException(ValueError, "neural action index out of range")
  let me = w.cogs[slot]
  result.goal = me.pos
  result.aim = me.aim
  if me.hp <= 0: return
  result.walk = true
  let (goalFound, goal) = w.goalCandidate(slot, actions[0].int)
  if goalFound: result.goal = goal
  result.shoot = actions[2] != 0
  result.chargeGrenade = actions[3] != 0
  result.sneak = actions[4] != 0
  let ownStep = if version == acV2 and actions[1] in 1'i32..16'i32:
      w.plannedStep(slot, result.goal, result.sneak)
    else: Point()
  let (aimFound, aim) = w.aimCandidate(slot, actions[1].int, bodies, version, memory, ownStep)
  if aimFound: result.aim = aim
  if fireHold: discard w.holdFire(slot, result)
proc decodeActions*(w: World, slot: int, actions: openArray[int32],
    bodies: array[Seats, int]): Command =
  ## Contract v1: an identity aim is the body's current position.
  w.decodeActions(slot, actions, bodies, acV1, default(AimMemory))
proc decodeActions*(w: World, slot: int, actions: openArray[int32],
    version: ActionContractVersion, memory: AimMemory): Command =
  if slot notin 0..<Seats or actions.len != ActionSizes.len:
    raise newException(ValueError, "invalid neural action dimensions or seat")
  # Identity aim is the only head that resolves bodies; keep the cost to that case.
  if actions.len == ActionSizes.len and actions[1] in 1'i32..16'i32:
    return w.decodeActions(slot, actions, w.observedBodies(slot), version, memory)
  var none: array[Seats, int]
  for i in 0..<Seats: none[i] = -1
  w.decodeActions(slot, actions, none, version, memory)
proc decodeActions*(w: World, slot: int, actions: openArray[int32]): Command =
  w.decodeActions(slot, actions, acV1, default(AimMemory))

proc argmaxActions*(logits: openArray[float32]): array[ActionSizes.len, int32] =
  ## Deterministic headwise argmax, the deployed selection rule (first maximum wins).
  if logits.len != LogitSize: raise newException(ValueError,"invalid neural logit size")
  var offset = 0
  for head,size in ActionSizes:
    var best = 0
    for i in 0..<size:
      if classify(logits[offset+i]) in {fcNan,fcInf,fcNegInf}:
        raise newException(ValueError,"non-finite neural logits")
      if logits[offset+i] > logits[offset+best]: best = i
    result[head] = best.int32
    offset += size

# Decoder sampling (bundle option decoder.sampling, schema 2; not a contract change): the
# categorical heads are drawn from softmax(logits / temperature) instead of taken by argmax,
# from a stream the seat owns. The stream is SplitMix64 (polyworld/rngs, the engine's own
# replay-portable generator) seeded from the match seed and the seat's slot, so a replay of
# the same match reproduces the same draws on the same engine build, two seats never share
# a stream, and the world's own rng (which the state hash covers) is never touched: with the
# option absent nothing here runs and every hash is byte-identical. One draw per sampled
# head per call, in head order, so the stream position depends only on how many decisions
# the seat has taken. Probabilities are formed in float64 from the float32 logits; the draw
# is (next() shr 11) * 2^-53, the standard 53-bit uniform. Determinism holds per engine
# build: the actor's float32 logits are themselves only argmax-stable across CPU
# architectures (a one-ulp logit difference can move a sampled draw, never an argmax).
type
  SamplingOptions* = object
    enabled*: bool
    temperature*: float32      # > 0; 1.0 = the training-time distribution
    heads*: array[ActionSizes.len, bool]  # which heads are sampled; the rest take argmax

const
  SamplingSalt* = 0x53414d504c450000'u64  # "SAMPLE" in the high bytes, slot below it
  MinSamplingTemperature* = 0.01'f32
  MaxSamplingTemperature* = 10'f32

proc samplingRng*(matchSeed: int32, slot: int): Rng =
  ## The seat's sampling stream for a match: the match seed (the world's) salted with the
  ## slot so every seat draws differently.
  initRng(matchSeed, SamplingSalt xor (uint64(slot+1) shl 32))

proc samplingSeed*(matchSeed: int32, slot: int): uint64 =
  ## The stream's initial state, for telemetry.
  samplingRng(matchSeed, slot).state

proc uniform53(rng: var Rng): float64 =
  float64(rng.next() shr 11) * (1.0 / 9007199254740992.0)

proc sampleActions*(logits: openArray[float32], options: SamplingOptions,
    rng: var Rng): array[ActionSizes.len, int32] =
  ## Headwise categorical draw for the heads the options sample, argmax for the others;
  ## with the options disabled exactly argmaxActions (no draw). Exactly one draw per
  ## sampled head per call. Non-finite logits are rejected like argmax rejects them.
  if not options.enabled: return argmaxActions(logits)
  if logits.len != LogitSize: raise newException(ValueError,"invalid neural logit size")
  if options.temperature < MinSamplingTemperature or options.temperature > MaxSamplingTemperature:
    raise newException(ValueError,"invalid sampling temperature")
  let argmax = argmaxActions(logits)   # also the finiteness check
  var offset = 0
  for head,size in ActionSizes:
    if not options.heads[head]:
      result[head] = argmax[head]
      offset += size
      continue
    let top = float64(logits[offset+argmax[head]])
    let inverse = 1.0 / float64(options.temperature)
    var total = 0.0
    for i in 0..<size: total += exp((float64(logits[offset+i]) - top) * inverse)
    let threshold = rng.uniform53() * total
    var cumulative = 0.0
    var pick = size-1
    for i in 0..<size:
      cumulative += exp((float64(logits[offset+i]) - top) * inverse)
      if threshold < cumulative:
        pick = i
        break
    result[head] = pick.int32
    offset += size

# Decoder objective forbid (bundle option decoder.forbid_objectives, schema 2; not a
# contract change): the listed movement-head candidate indices are never chosen, as if
# their logits were -inf. The actor's logits are still checked for finiteness exactly as
# argmax checks them; the forbidden entries are then skipped by argmax and carry no mass
# in a sampled draw (the remaining candidates are renormalised). With nothing forbidden
# these are exactly argmaxActions / sampleActions (the same code runs), so the option
# absent is byte-identical. The pw-diag river veto forbids 9 and 10, the two river hearts.
type
  ObjectiveMask* = array[ActionSizes[0], bool]  # true = the movement-head index is forbidden

proc forbidsAny*(mask: ObjectiveMask): bool =
  for forbidden in mask:
    if forbidden: return true
  false

proc argmaxActions*(logits: openArray[float32], forbidden: ObjectiveMask): array[ActionSizes.len, int32] =
  ## argmaxActions with the forbidden movement-head indices skipped: the first maximum
  ## among the allowed ones. Nothing forbidden = argmaxActions.
  result = argmaxActions(logits)   # size and finiteness checks, every other head
  if not forbidden.forbidsAny: return
  var best = -1
  for i in 0..<ActionSizes[0]:
    if forbidden[i]: continue
    if best < 0 or logits[i] > logits[best]: best = i
  if best < 0: raise newException(ValueError, "every objective candidate is forbidden")
  result[0] = best.int32

proc sampleActions*(logits: openArray[float32], options: SamplingOptions,
    rng: var Rng, forbidden: ObjectiveMask): array[ActionSizes.len, int32] =
  ## sampleActions with the forbidden movement-head indices removed from the draw (and
  ## from argmax when the movement head is not sampled). Still exactly one draw per
  ## sampled head per call. Nothing forbidden = sampleActions; options disabled = the
  ## masked argmax with no draw.
  if not forbidden.forbidsAny: return sampleActions(logits, options, rng)
  if not options.enabled: return argmaxActions(logits, forbidden)
  if logits.len != LogitSize: raise newException(ValueError,"invalid neural logit size")
  if options.temperature < MinSamplingTemperature or options.temperature > MaxSamplingTemperature:
    raise newException(ValueError,"invalid sampling temperature")
  let argmax = argmaxActions(logits, forbidden)   # also the finiteness check
  var offset = 0
  for head,size in ActionSizes:
    if not options.heads[head]:
      result[head] = argmax[head]
      offset += size
      continue
    let top = float64(logits[offset+argmax[head]])
    let inverse = 1.0 / float64(options.temperature)
    var total = 0.0
    for i in 0..<size:
      if head == 0 and forbidden[i]: continue
      total += exp((float64(logits[offset+i]) - top) * inverse)
    let threshold = rng.uniform53() * total
    var cumulative = 0.0
    var pick = -1
    for i in 0..<size:
      if head == 0 and forbidden[i]: continue
      pick = i   # the last allowed index when rounding leaves the threshold uncovered
      cumulative += exp((float64(logits[offset+i]) - top) * inverse)
      if threshold < cumulative: break
    result[head] = pick.int32
    offset += size

# Decoder strafe legs (bundle option decoder.strafe_legs, schema 2; not a contract change):
# base.bas's footwork in contact (its planLeg), as pw-diag measured it (first-contact.md,
# lever 2). While the seat sees an apparent enemy within range and is not in a trench,
# its movement head is replaced by a compass step: a leg perpendicular to the nearest such
# enemy, turned 3/4 lateral plus the direction to the objective the movement head chose
# (a heart or pickup), held for legs[0]..legs[1] ticks, reversing across the line with
# probability reverse_permille/1000 at every new leg. A shoot order the gun can take this
# tick is only issued with at least shot_legs[0] ticks of the current leg left: when fewer
# remain a new leg of shot_legs[0]..shot_legs[1] ticks starts on that tick, so the seat's
# own movement over the windup is the planned step contract v2's lead subtracts. No order
# is dropped. Out of contact the leg ends. Integer geometry only; the random draws (two
# per new leg: reverse, then length) come from a stream the seat owns, SplitMix64 seeded
# from the match seed and the slot like the sampling stream but with its own salt, so it
# never shifts the sampling draws and the world's rng is untouched.
type
  StrafeOptions* = object
    enabled*: bool
    range*: int32                   # contact: an apparent enemy within this distance
    legTicks*: array[2, int32]      # leg length without a shot, inclusive
    shotLegTicks*: array[2, int32]  # leg length when a ready shot starts it, inclusive
    reversePermille*: int32         # chance per new leg of reversing across the line
  StrafeState* = object
    leg*: int32        # ticks left on the current leg (0 = none)
    zig*: int32        # +1 / -1: which side of the line to the threat
    direction*: int32  # compass 0..7 of the current leg (movement index 43+direction)
    legs*: int32       # legs started (telemetry)
    ticks*: int32      # decisions whose movement head the strafe replaced (telemetry)

const
  StrafeSalt* = 0x5354524146450000'u64  # "STRAFE" in the high bytes, slot below it
  DefaultStrafeRange* = 5250'i32        # base.bas's contact range (d2 <= 27562500) = GunRange
  DefaultStrafeLegs* = [3'i32, 6]
  DefaultStrafeShotLegs* = [6'i32, 9]
  DefaultStrafeReversePermille* = 800'i32
  MaxStrafeRange* = 20000'i32
  MaxStrafeLegTicks* = 72'i32
  MinStrafeShotLegTicks* = LeadOwnMoves.int32 + 1  # the order tick plus the windup's moves
  StrafeFirstCompass* = 43
static: doAssert DefaultStrafeRange == GunRange and MinStrafeShotLegTicks == 6

proc defaultStrafeOptions*(): StrafeOptions =
  StrafeOptions(enabled: true, range: DefaultStrafeRange, legTicks: DefaultStrafeLegs,
    shotLegTicks: DefaultStrafeShotLegs, reversePermille: DefaultStrafeReversePermille)

proc strafeOptionsError*(o: StrafeOptions): string =
  ## "" when the parameters are usable; otherwise why not (the host and the native ABI
  ## reject the same values).
  if o.range < 1 or o.range > MaxStrafeRange: return "range must be within 1 .. " & $MaxStrafeRange
  if o.legTicks[0] < 1 or o.legTicks[0] > o.legTicks[1] or o.legTicks[1] > MaxStrafeLegTicks:
    return "legs must be [min, max] with 1 <= min <= max <= " & $MaxStrafeLegTicks
  if o.shotLegTicks[0] < MinStrafeShotLegTicks or o.shotLegTicks[0] > o.shotLegTicks[1] or
      o.shotLegTicks[1] > MaxStrafeLegTicks:
    return "shot_legs must be [min, max] with " & $MinStrafeShotLegTicks & " <= min <= max <= " & $MaxStrafeLegTicks
  if o.reversePermille < 0 or o.reversePermille > 1000: return "reverse_permille must be within 0 .. 1000"
  ""

proc strafeRng*(matchSeed: int32, slot: int): Rng =
  ## The seat's strafe stream for a match (its own salt: independent of the sampling stream).
  initRng(matchSeed, StrafeSalt xor (uint64(slot+1) shl 32))

proc strafeSeed*(matchSeed: int32, slot: int): uint64 =
  strafeRng(matchSeed, slot).state

proc initStrafeState*(slot: int): StrafeState =
  ## No leg; the first leg side alternates by pairs of team members, as base.bas seeds zig.
  result.zig = if (slot div 2) mod 4 < 2: 1 else: -1

proc isqrt64(n: int64): int64 =
  if n <= 0: return 0
  var x = n
  var y = (x+1) div 2
  while y < x:
    x = y
    y = (x + n div x) div 2
  x

proc strafeActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    bodies: array[Seats, int], options: StrafeOptions, state: var StrafeState, rng: var Rng,
    forbidden: ObjectiveMask = default(ObjectiveMask)): bool =
  ## Apply the strafe to the seat's selected head indices on the pre-step world, before
  ## they are decoded: returns whether the movement head was replaced (by a compass index
  ## 43..50). `bodies` are the seat's apparent identities (observedBodies). Compass
  ## headings the forbid mask lists are never taken. Options disabled = untouched.
  if not options.enabled: return false
  let me = w.cogs[slot]
  if me.hp <= 0 or w.trenchAt(me.pos) >= 0:
    state.leg = 0
    return false
  var threat = -1
  var best = int64(options.range) * options.range
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0 or body == slot or w.cogs[body].hp <= 0: continue
    if w.observedTeam(slot, body) == team(slot): continue
    let d = distance2(me.pos, w.cogs[body].pos)
    if d > int64(options.range) * options.range: continue
    if threat < 0 or d < best:
      threat = body
      best = d
  if threat < 0:
    state.leg = 0
    return false
  let gear = w.equipment[slot]
  let ready = if gear.sprayCan: gear.sprayCooldown == 0 else: me.cooldown == 0 and gear.windup == 0
  let wantShot = actions[2] != 0 and ready
  if state.leg <= 0 or (wantShot and state.leg < options.shotLegTicks[0]):
    if int32(rng.next() mod 1000'u64) < options.reversePermille: state.zig = -state.zig
    let span = if wantShot: options.shotLegTicks else: options.legTicks
    state.leg = span[0] + int32(rng.next() mod uint64(span[1] - span[0] + 1))
    inc state.legs
    # Perpendicular to the line to the threat, scaled to 1000, on the zig side.
    let tx = int64(w.cogs[threat].pos.x) - me.pos.x
    let tz = int64(w.cogs[threat].pos.z) - me.pos.z
    let reach = isqrt64(tx*tx + tz*tz)
    var lx, lz = 0'i64
    if reach > 0:
      lx = -tz * 1000 * state.zig div reach
      lz = tx * 1000 * state.zig div reach
    # Keep some progress toward the objective the movement head chose (heart or pickup).
    if actions[0] in 1'i32..42'i32:
      let (found, goal) = w.goalCandidate(slot, actions[0].int)
      if found:
        let fx = int64(goal.x) - me.pos.x
        let fz = int64(goal.z) - me.pos.z
        let far = isqrt64(fx*fx + fz*fz)
        if far > 60:
          lx = lx * 3 div 4 + fx * 1000 div far
          lz = lz * 3 div 4 + fz * 1000 div far
    # The allowed compass heading nearest the leg (a diagonal's projection is scaled by
    # 1/sqrt 2 so all eight headings compete fairly); movement compass steps are mirrored
    # for team 1 exactly as goalCandidate mirrors them.
    let flip = if team(slot) == 0: 1'i64 else: -1'i64
    var bestScore = low(int64)
    var heading = -1
    for k, delta in Directions:
      if forbidden[StrafeFirstCompass + k]: continue
      let dot = flip * (delta[0].int64 * lx + delta[1].int64 * lz)
      let score = if delta[0] != 0 and delta[1] != 0: dot * 7071 else: dot * 10000
      if heading < 0 or score > bestScore:
        heading = k
        bestScore = score
    if heading < 0:
      state.leg = 0
      return false
    state.direction = heading.int32
  dec state.leg
  actions[0] = int32(StrafeFirstCompass + state.direction)
  inc state.ticks
  true

# Decoder aim snap (bundle option decoder.aim_snap, schema 2; not a contract change): the
# pw-diag2 rules-39 diagnosis (lever 1) found 63 % of the champion's rays fired with a
# compass aim (index 17..24) while an enemy was visible, a median 10 degrees off it,
# hitting about 0.06. When the decision issues a shoot order with a compass aim and an
# enemy the seat can see (its apparent identities: fog-gated, apparent team, exactly
# observedBodies) stands within max_angle of that compass heading, the aim head becomes
# that enemy's identity index (1..16), so the identity candidate (contract v2: the
# lead-compensated aim point) is what the order aims at. The heading is the compass
# direction the index names (mirrored for team 1 exactly as aimCandidate mirrors it);
# the enemy's bearing is its body's position seen from the seat's. Among the enemies
# within the angle the nearest in angle wins, then the nearer body, then the lower
# identity index. Integer geometry: the angle test compares squared cosines against a
# Q15 threshold (AimSnapCosScale) derived once from the angle in millidegrees, so the
# snap is exact and platform-independent given that threshold (the log line prints it).
# Stateless: nothing is kept between decisions and no stream is drawn.
type
  AimSnapOptions* = object
    enabled*: bool
    maxAngleMillideg*: int32  # 1 .. MaxAimSnapMillideg
    cosQ15*: int64            # round(cos(max angle) * AimSnapCosScale): the integer threshold

const
  AimSnapCosScale* = 32768'i64
  DefaultAimSnapMillideg* = 22500'i32  # the pw-diag2 counterfactual's 22.5 degrees
  MaxAimSnapMillideg* = 90000'i32
  AimFirstCompass* = 17
static: doAssert Width.int64*Width + Height.int64*Height < (1'i64 shl 26)

proc aimSnapOptionsError*(maxAngleMillideg: int32): string =
  ## "" when the angle is usable; otherwise why not (the host and the native ABI reject
  ## the same values).
  if maxAngleMillideg < 1 or maxAngleMillideg > MaxAimSnapMillideg:
    return "max_angle_deg must be a multiple of 0.001 within 0.001 .. 90"
  ""

proc aimSnapOptions*(maxAngleMillideg: int32): AimSnapOptions =
  ## The enabled option for a valid angle, with its integer threshold; ValueError otherwise.
  let problem = aimSnapOptionsError(maxAngleMillideg)
  if problem.len > 0: raise newException(ValueError, "decoder.aim_snap." & problem)
  let radians = float64(maxAngleMillideg) / 1000.0 * PI / 180.0
  AimSnapOptions(enabled: true, maxAngleMillideg: maxAngleMillideg,
    cosQ15: max(0'i64, int64(round(cos(radians) * float64(AimSnapCosScale)))))

proc aimSnapActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    bodies: array[Seats, int], options: AimSnapOptions): bool =
  ## Apply the aim snap to the seat's selected head indices on the pre-step world, before
  ## they are decoded: returns whether the aim head was replaced (by an identity index
  ## 1..16). Only a live seat's shoot order (head 2 = 1) with a compass aim (17..24) is
  ## considered. `bodies` are the seat's apparent identities (observedBodies). Options
  ## disabled = untouched.
  if not options.enabled or actions[2] == 0: return false
  if actions[1] notin AimFirstCompass.int32..(AimFirstCompass+Directions.len-1).int32: return false
  let me = w.cogs[slot]
  if me.hp <= 0: return false
  let flip = if team(slot) == 0: 1'i64 else: -1'i64
  let delta = Directions[actions[1] - AimFirstCompass]
  let hx = flip * delta[0]
  let hz = flip * delta[1]
  let threshold = options.cosQ15 * options.cosQ15 * (hx*hx + hz*hz)
  const scale2 = AimSnapCosScale * AimSnapCosScale
  var best = -1
  var bestDot, bestE2 = 0'i64
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0 or body == slot or w.cogs[body].hp <= 0: continue
    if w.observedTeam(slot, body) == team(slot): continue
    let ex = int64(w.cogs[body].pos.x) - me.pos.x
    let ez = int64(w.cogs[body].pos.z) - me.pos.z
    let e2 = ex*ex + ez*ez
    let dot = hx*ex + hz*ez
    if e2 == 0 or dot <= 0: continue
    # angle <= max  <=>  dot / (|h| |e|) >= cos(max)  <=>  dot^2 S^2 >= cosQ^2 |h|^2 |e|^2
    # (dot^2 < 2^28, |e|^2 < 2^26, |h|^2 <= 2, cosQ and S <= 2^15: every product fits in 63 bits).
    if dot*dot*scale2 < threshold*e2: continue
    # Nearer in angle = a larger dot / |e|: dot_a^2 |e_b|^2 > dot_b^2 |e_a|^2.
    let a = dot*dot*bestE2
    let b = bestDot*bestDot*e2
    if best < 0 or a > b or (a == b and e2 < bestE2):
      best = identity
      bestDot = dot
      bestE2 = e2
  if best < 0: return false
  actions[1] = int32(best + 1)
  true

# Decoder steady shot (bundle option decoder.steady_shot, schema 2; not a contract
# change): the second half of pw-diag2's lever 1. Under rules 39 the champion's sampled
# movement index changed during 85 % of its shot windups, a median 85 u of own drift that
# v2's lead never subtracted (base.bas: 0). With the option on, the seat stands still
# (movement index 0 = SteadyMovement: goal = its own position, so the world makes no step
# and v2's planned own step is zero) on every decision from a shoot order the gun takes
# until the ray leaves, stated in the gun's own windup state (mechanics.nim stepEquipment):
#   - the order tick: the decision's shoot head is 1 and the gun takes the order on this
#     step (gunTakesOrder): the seat is alive, carries the gun (no spray can, whose branch
#     replaces the gun's), equipment.windup == 0 and cogs.cooldown <= 1 on the pre-step
#     world (the step decrements the cooldown before it tests it, so 1 fires). The step
#     then sets windup = GunWindupTicks and locks gunAim after this tick's move;
#   - the windup ticks: the seat is alive, carries the gun and equipment.windup > 0 on the
#     pre-step world (GunWindupTicks .. 1), whatever the shoot head says. The ray leaves
#     after the move of the tick whose pre-step windup is 1, so these are exactly the
#     GunWindupTicks moves the lead's own-drift term (LeadOwnMoves) counts.
# Six decisions per shot, all read from the world, so the rule keeps no state and draws
# nothing; every other head stands. The fire hold (and the training ABI's fire period)
# is decided after the decode, so an order it then drops has still stood its order tick;
# no windup starts for it and the next decision is free.
type
  SteadyShotHold* = enum
    ssNone = 0, ssOrder = 1, ssWindup = 2
const SteadyMovement* = 0'i32
static: doAssert LeadOwnMoves == GunWindupTicks

proc gunTakesOrder*(w: World, slot: int): bool =
  ## Whether a shoot order decided on this pre-step world starts the gun's windup on the
  ## coming step (the gun branch of mechanics.nim stepEquipment).
  let c = w.cogs[slot]
  let e = w.equipment[slot]
  c.hp > 0 and not e.sprayCan and e.windup == 0 and c.cooldown <= 1

proc steadyShotActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    enabled: bool): SteadyShotHold =
  ## Apply the steady shot to the seat's selected head indices on the pre-step world,
  ## before they are decoded: on an order tick or a windup tick (see above) the movement
  ## head becomes SteadyMovement and which of the two is returned; ssNone = untouched.
  if not enabled: return ssNone
  let c = w.cogs[slot]
  let e = w.equipment[slot]
  if c.hp <= 0 or e.sprayCan: return ssNone
  if e.windup > 0: result = ssWindup
  elif actions[2] != 0 and w.gunTakesOrder(slot): result = ssOrder
  else: return ssNone
  actions[0] = SteadyMovement

# Decoder aim retarget (bundle option decoder.aim_retarget, schema 2; not a contract
# change): the pw-diag3 rules-39 diagnosis found target choice decides v4 against
# base.bas. Only 41 % of v4's rays went at the enemy base.bas's own rule picks; the
# others hit 0.15. Every live-field opponent picks by that rule 85-88 % of the time.
# With the option on, every shoot order the policy makes (shoot head 1, identity or
# compass aim; a keep aim, index 0, is left alone) takes the aim index of the visible
# apparent enemy identity with the smallest
#   cost = d^2 - (3 - hp) * hp_weight - carrying * carry_weight
# among those with d <= max_range, where d is measured from the seat's position to the
# identity's aim candidate under the seat's action contract (v2: the lead-compensated
# point, with the seat's own planned step from the movement and sneak heads as they
# stand, exactly what pw_action_candidates reports). The inputs are the seat's own
# observation identity block (present, apparent team -1, hp, carrying; observedBodies)
# and its aim candidates: no hidden state. Ties go to the lower identity. When no enemy
# qualifies the order stands (and the aim snap, which runs next, may still snap it).
# Stateless, no draws. The defaults are base.bas's rule and diag3_run.py --retarget.
type
  AimRetargetOptions* = object
    enabled*: bool
    maxRange*: int32     # 1 .. MaxRetargetRange
    hpWeight*: int32     # 0 .. MaxRetargetWeight, per missing hp point
    carryWeight*: int32  # 0 .. MaxRetargetWeight, for an enemy carrying a heart

const
  DefaultRetargetRange* = 5250'i32         # GunRange
  DefaultRetargetHpWeight* = 160000'i32    # base.bas: (3 - hp) * 160000
  DefaultRetargetCarryWeight* = 2500000'i32  # base.bas: carrier bonus
  MaxRetargetRange* = 20000'i32
  MaxRetargetWeight* = 1_000_000_000'i32
  RetargetFullHp* = 3'i64
static: doAssert DefaultRetargetRange == GunRange

proc aimRetargetOptionsError*(maxRange, hpWeight, carryWeight: int32): string =
  ## "" when the parameters are usable; otherwise why not (the host and the native ABI
  ## reject the same values).
  if maxRange < 1 or maxRange > MaxRetargetRange: return "max_range must be within 1 .. " & $MaxRetargetRange
  if hpWeight < 0 or hpWeight > MaxRetargetWeight: return "hp_weight must be within 0 .. " & $MaxRetargetWeight
  if carryWeight < 0 or carryWeight > MaxRetargetWeight: return "carry_weight must be within 0 .. " & $MaxRetargetWeight
  ""

proc aimRetargetOptions*(maxRange = DefaultRetargetRange, hpWeight = DefaultRetargetHpWeight,
    carryWeight = DefaultRetargetCarryWeight): AimRetargetOptions =
  ## The enabled option for valid parameters (the defaults are base.bas's); ValueError otherwise.
  let problem = aimRetargetOptionsError(maxRange, hpWeight, carryWeight)
  if problem.len > 0: raise newException(ValueError, "decoder.aim_retarget." & problem)
  AimRetargetOptions(enabled: true, maxRange: maxRange, hpWeight: hpWeight, carryWeight: carryWeight)

proc plannedOwnStep(w: World, slot: int, actions: array[ActionSizes.len, int32],
    version: ActionContractVersion): Point =
  ## The own step a v2 identity candidate subtracts for these heads: the planned move of
  ## the movement and sneak heads (pw_action_candidates' rule); zero under v1.
  if version != acV2: return Point()
  let (found, goal) = w.goalCandidate(slot, actions[0].int)
  w.plannedStep(slot, if found: goal else: w.cogs[slot].pos, actions[4] != 0)

proc aimRetargetActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    bodies: array[Seats, int], version: ActionContractVersion, memory: AimMemory,
    options: AimRetargetOptions): bool =
  ## Apply the aim retarget to the seat's selected head indices on the pre-step world,
  ## before the aim snap and the decode: returns whether the aim head was replaced (by
  ## an identity index 1..16 other than the one it held). Only a live seat's shoot order
  ## (head 2 = 1) with an identity or compass aim (1..24) is considered. `bodies` are
  ## the seat's apparent identities (observedBodies) and `memory` its aim memory, the
  ## ones the decode reads. Options disabled = untouched.
  if not options.enabled or actions[2] == 0 or actions[1] == 0: return false
  let me = w.cogs[slot]
  if me.hp <= 0: return false
  let ownStep = w.plannedOwnStep(slot, actions, version)
  let reach2 = int64(options.maxRange) * options.maxRange
  var best = -1
  var bestCost = 0'i64
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0 or w.observedTeam(slot, body) == team(slot): continue
    let (found, aim) = w.aimCandidate(slot, identity + 1, bodies, version, memory, ownStep)
    if not found: continue
    let d2 = distance2(me.pos, aim)
    if d2 > reach2: continue
    let other = w.cogs[body]
    let cost = d2 - (RetargetFullHp - other.hp) * options.hpWeight -
      (if other.carrying: int64(options.carryWeight) else: 0'i64)
    if best < 0 or cost < bestCost:
      best = identity
      bestCost = cost
  if best < 0 or actions[1] == int32(best + 1): return false
  actions[1] = int32(best + 1)
  true

# Decoder shot gate (bundle option decoder.shot_gate, schema 2; not a contract change):
# after retarget, 9 % of v4's rays were still compass shots at nothing within range,
# hitting 0.016; each costs a cooldown and a six-tick steady stand. With the option on,
# a live seat's shoot order, as it stands after the aim retarget and the aim snap, is
# dropped (shoot head 0) when
#   - its aim is still a compass index (17..24): no snap is configured, or the snap found
#     no visible enemy in its cone;
#   - the aim snap turned it into an enemy identity whose body lies beyond max_range;
#   - it is an identity aim (the policy's or the retarget's) whose aim candidate lies
#     beyond max_range, measured as the retarget measures it.
# A keep aim (index 0), and an identity aim within range or one no visible body carries,
# pass: exactly pw-diag3's `--shot-gate` counterfactual (diag3_run.py gate_drop), with
# the snap test read from the snap itself (observedBodies) instead of the diag state. A
# dropped order is the decision without the shot: its aim head returns to what it was
# before the snap (the snap only rewrites shoot orders), so the strafe, the steady
# shot, the decode and the fire hold all see a decision that never ordered a shot.
# Stateless, no draws.
type
  ShotGateOptions* = object
    enabled*: bool
    maxRange*: int32  # 1 .. MaxShotGateRange

const
  DefaultShotGateRange* = 5250'i32  # GunRange
  MaxShotGateRange* = 20000'i32
static: doAssert DefaultShotGateRange == GunRange

proc shotGateOptionsError*(maxRange: int32): string =
  ## "" when the range is usable; otherwise why not (host and native ABI agree).
  if maxRange < 1 or maxRange > MaxShotGateRange: return "max_range must be within 1 .. " & $MaxShotGateRange
  ""

proc shotGateOptions*(maxRange = DefaultShotGateRange): ShotGateOptions =
  ## The enabled option for a valid range; ValueError otherwise.
  let problem = shotGateOptionsError(maxRange)
  if problem.len > 0: raise newException(ValueError, "decoder.shot_gate." & problem)
  ShotGateOptions(enabled: true, maxRange: maxRange)

proc shotGateActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    beforeSnap: array[ActionSizes.len, int32], snapped: bool, bodies: array[Seats, int],
    version: ActionContractVersion, memory: AimMemory, options: ShotGateOptions): bool =
  ## Apply the shot gate to the heads as they stand after the aim snap (`snapped`: the
  ## snap replaced the aim; `beforeSnap`: the heads it received): returns whether the
  ## shoot order was dropped, in which case `actions` becomes `beforeSnap` with shoot
  ## head 0. Options disabled = untouched.
  if not options.enabled or actions[2] == 0: return false
  let me = w.cogs[slot]
  if me.hp <= 0: return false
  let aim = actions[1]
  let reach2 = int64(options.maxRange) * options.maxRange
  var drop = false
  if aim >= AimFirstCompass.int32:
    drop = true
  elif aim >= 1:
    if snapped:
      drop = distance2(me.pos, w.cogs[bodies[aim - 1]].pos) > reach2
    else:
      let (found, point) = w.aimCandidate(slot, aim.int, bodies, version, memory,
        w.plannedOwnStep(slot, actions, version))
      drop = found and distance2(me.pos, point) > reach2
  if not drop: return false
  actions = beforeSnap
  actions[2] = 0
  true

proc decodeLogits*(w: World, slot: int, logits: openArray[float32],
    bodies: array[Seats, int], version: ActionContractVersion,
    memory: AimMemory, fireHold = false): Command =
  w.decodeActions(slot, argmaxActions(logits), bodies, version, memory, fireHold)
proc decodeLogits*(w: World, slot: int, logits: openArray[float32]): Command =
  w.decodeActions(slot, argmaxActions(logits))

proc trainingBotActions*(w: World, slot, level: int,
    actions: var openArray[int32], bodies: array[Seats, int]) =
  ## Deliberately simple policy-visible curriculum opponent, never the learner.
  ## Level 1 idles; level 2 captures and fires at the nearest apparent enemy.
  if actions.len != ActionSizes.len or level notin 1..2:
    raise newException(ValueError,"invalid training bot configuration")
  for i in 0..<actions.len: actions[i] = 0
  if level == 1 or w.cogs[slot].hp <= 0: return
  let me = w.cogs[slot]
  var best = high(int64)
  for i,heart in w.controlHearts:
    if i >= 10 or heart.owner == team(slot).int32: continue
    let d = distance2(me.pos,heart.pos)
    if d < best:
      best = d
      actions[0] = int32(i+1)
  # Keep looking in different directions when no opponent is seen.
  actions[1] = int32(17+(w.tick.int div 24+slot div 2) mod 8)
  best = high(int64)
  for identity,body in bodies:
    if body < 0 or w.observedTeam(slot,body) == team(slot): continue
    let d = distance2(me.pos,w.cogs[body].pos)
    if d < best:
      best = d
      actions[1] = int32(identity+1)
      actions[2] = 1
proc trainingBotActions*(w: World, slot, level: int, actions: var openArray[int32]) =
  if actions.len != ActionSizes.len or level notin 1..2:
    raise newException(ValueError,"invalid training bot configuration")
  if level == 1 or slot notin 0..<Seats or w.cogs[slot].hp <= 0:
    for i in 0..<actions.len: actions[i] = 0
    return
  w.trainingBotActions(slot, level, actions, w.observedBodies(slot))
