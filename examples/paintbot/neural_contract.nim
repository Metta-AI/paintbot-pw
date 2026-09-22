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
  Directions = [(1,0), (1,1), (0,1), (-1,1), (-1,0), (-1,-1), (0,-1), (1,-1)]

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

proc decodeActions*(w: World, slot: int, actions: openArray[int32],
    bodies: array[Seats, int]): Command =
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
  let movement = actions[0].int
  let flip = if team(slot)==0: 1 else: -1
  if movement in 1..10:
    if movement-1 < w.controlHearts.len: result.goal = w.controlHearts[movement-1].pos
  elif movement in 11..42:
    let i = movement-11
    if i < w.pickups.len and w.pickups[i].readyAt <= w.tick and
        w.canSeePoint(slot,w.pickups[i].pos): result.goal = w.pickups[i].pos
  elif movement >= 43:
    let delta = Directions[movement-43]
    result.goal = point(clamp(me.pos.x.int+flip*delta[0]*200,minX(),maxX()),
                        clamp(me.pos.z.int+flip*delta[1]*200,minZ(),maxZ()))
  let aim = actions[1].int
  if aim in 1..16:
    if bodies[aim-1] >= 0: result.aim = w.cogs[bodies[aim-1]].pos
  elif aim >= 17:
    let delta = Directions[aim-17]
    result.aim = point(clamp(me.pos.x.int+flip*delta[0]*5000,minX(),maxX()),
                       clamp(me.pos.z.int+flip*delta[1]*5000,minZ(),maxZ()))
  result.shoot = actions[2] != 0
  result.chargeGrenade = actions[3] != 0
  result.sneak = actions[4] != 0
proc decodeActions*(w: World, slot: int, actions: openArray[int32]): Command =
  if slot notin 0..<Seats or actions.len != ActionSizes.len:
    raise newException(ValueError, "invalid neural action dimensions or seat")
  # Identity aim is the only head that resolves bodies; keep the cost to that case.
  if actions.len == ActionSizes.len and actions[1] in 1'i32..16'i32:
    return w.decodeActions(slot, actions, w.observedBodies(slot))
  var none: array[Seats, int]
  for i in 0..<Seats: none[i] = -1
  w.decodeActions(slot, actions, none)

proc decodeLogits*(w: World, slot: int, logits: openArray[float32]): Command =
  if logits.len != LogitSize: raise newException(ValueError,"invalid neural logit size")
  var actions: array[ActionSizes.len,int32]
  var offset = 0
  for head,size in ActionSizes:
    var best = 0
    for i in 0..<size:
      if classify(logits[offset+i]) in {fcNan,fcInf,fcNegInf}:
        raise newException(ValueError,"non-finite neural logits")
      if logits[offset+i] > logits[offset+best]: best = i
    actions[head] = best.int32
    offset += size
  w.decodeActions(slot,actions)

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
