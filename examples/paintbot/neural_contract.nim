## Versioned policy-visible float observations and categorical actuators.
## Used unchanged by BASIC deployment and native Puffer rollouts.
import std/math
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
  Directions = [(1,0), (1,1), (0,1), (-1,1), (-1,0), (-1,-1), (0,-1), (1,-1)]
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

type
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

proc decodeActions*(w: World, slot: int, actions: openArray[int32],
    bodies: array[Seats, int], version: ActionContractVersion,
    memory: AimMemory): Command =
  ## The shared decoder of every host. `version` selects the identity-aim rule; the
  ## memory is read only under contract v2 (the host records it with recordAimMemory
  ## after decoding each tick).
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
proc decodeLogits*(w: World, slot: int, logits: openArray[float32],
    bodies: array[Seats, int], version: ActionContractVersion,
    memory: AimMemory): Command =
  w.decodeActions(slot, argmaxActions(logits), bodies, version, memory)
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
