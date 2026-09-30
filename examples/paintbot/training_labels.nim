## TRAINING-ONLY privileged supervision labels (pw_seat_privileged_labels).
##
## These are facts a seat cannot perceive through its SeatView (docs/neural/seat-view.md):
## its gun cooldown and windup, spray cooldown, shield, respawn countdown, current aim, both
## heart meters, and the lead-compensated aim point of the nearest enemy it can see (the
## retired contract-v2 lead formula, recomputed here). They exist only to supervise a
## trainer's auxiliary heads. They never feed an observation, a BASIC builtin or a neural
## builtin: the hosted engine never imports this module (it refuses to compile without
## -d:pwTraining), and tests/test_paintbot_seat_view_boundary.nim checks that seat_view,
## bots and the neural modules never import it.
when not defined(pwTraining): {.error: "training_labels is training-only (-d:pwTraining)".}
import sim

const
  PrivilegedLabelCount* = 12
  LabelLeadTargetMoves = GunWindupTicks + 1  # the ray leaves after the order tick's move and the windup
  LabelLeadOwnMoves = GunWindupTicks
  LabelTeleportStep = 60                     # a larger per-axis step is a respawn, not a velocity

type LabelMemory* = object
  ## The pre-step positions of every body on the last labelled tick (-1 = none).
  tick*: int32
  positions*: seq[Point]

proc recordLabelMemory*(m: var LabelMemory, w: World) =
  ## Record the pre-step world's positions (call once per step, before the world steps).
  m.tick = w.tick
  m.positions.setLen(w.cogs.len)
  for i, c in w.cogs: m.positions[i] = c.pos

proc resetLabelMemory*(m: var LabelMemory) =
  m.tick = -1
  m.positions.setLen(0)

proc plannedStep(w: World, slot: int): Point =
  ## The move the world makes for the seat this tick towards its current goal (mechanics.nim's
  ## speed rules and trench damping, before blocking or yielding); zero when it is there.
  let me = w.cogs[slot]
  let dest = w.waypointFor(slot, me.pos, me.goal)
  var speed = if me.carrying: MoveSpeed*7 div 10 else: MoveSpeed
  speed = boostedSpeed(speed, w.territoryBoost(slot))
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

proc privilegedLabels*(w: World, slot: int, m: LabelMemory): array[PrivilegedLabelCount, float32] =
  ## The seat's labels on the pre-step world `w`, raw engine units:
  ##   0 gun cooldown (ticks), 1 gun windup (ticks), 2 spray cooldown (ticks), 3 shield (ticks),
  ##   4 respawn (ticks), 5 aim x, 6 aim z, 7 own team's heart meter (scoreTicks), 8 enemy
  ##   team's heart meter (both 0 in FFA-kin), 9 lead valid (1 when an enemy is visible),
  ##   10 lead x, 11 lead z: for the nearest visible enemy body (true team, sim.visible),
  ##   body + 6 * u - 5 * v, u its displacement since the last labelled tick (zero on a gap or
  ##   a step beyond 60 per axis) and v the seat's own planned step towards its current goal.
  let me = w.cogs[slot]
  let gear = w.equipment[slot]
  result[0] = me.cooldown.float32
  result[1] = gear.windup.float32
  result[2] = gear.sprayCooldown.float32
  result[3] = me.shield.float32
  result[4] = me.respawn.float32
  result[5] = me.aim.x.float32
  result[6] = me.aim.z.float32
  if not ffa():
    result[7] = w.scoreTicks[team(slot)].float32
    result[8] = w.scoreTicks[1-team(slot)].float32
  if me.hp <= 0: return
  var target = -1
  var best = high(int64)
  for body in 0..<w.cogs.len:
    if body == slot or not w.visible(slot, body): continue
    if not ffa() and team(body) == team(slot): continue
    let d = distance2(me.pos, w.cogs[body].pos)
    if d < best:
      best = d
      target = body
  if target < 0: return
  var p = w.cogs[target].pos
  if m.tick == w.tick - 1 and target < m.positions.len:
    let dx = p.x - m.positions[target].x
    let dz = p.z - m.positions[target].z
    if abs(dx) <= LabelTeleportStep and abs(dz) <= LabelTeleportStep:
      p.x += dx * LabelLeadTargetMoves.int32
      p.z += dz * LabelLeadTargetMoves.int32
  let own = w.plannedStep(slot)
  p.x -= own.x * LabelLeadOwnMoves.int32
  p.z -= own.z * LabelLeadOwnMoves.int32
  result[9] = 1
  result[10] = p.x.float32
  result[11] = p.z.float32
