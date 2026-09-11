## Replay analysis is reconstructed from hash-verified simulation, never guessed.
import game, sim

type
  Moment* = object
    tick*, slot*, side*, victim*: int
    kind*: string
    x*, z*: int32
  Sample* = object
    tick*: int
    red*, blue*: float
    redHearts*, blueHearts*: int32
  Checkpoint* = object
    state*: World
  ReplayIndex* = object
    events*: seq[Moment]
    hits*: seq[Moment]
    momentum*: seq[Sample]
    checkpoints*: seq[Checkpoint]

proc snapshot*(w: World): World =
  result = w
  # Explicit copies keep checkpoint storage independent of mutable sequences.
  result.heartCaptures = @[]
  for h in w.heartCaptures: result.heartCaptures.add h
  result.usedBigHearts = @[]
  for used in w.usedBigHearts: result.usedBigHearts.add used
  result.controlHearts = @[]
  for h in w.controlHearts:result.controlHearts.add h
  result.pickups = @[]
  for x in w.pickups: result.pickups.add x
  result.trenches = @[]
  for x in w.trenches: result.trenches.add x
  result.grenades = @[]
  for x in w.grenades: result.grenades.add x
  result.blasts = @[]
  for x in w.blasts: result.blasts.add x
  result.balls = @[]
  for ball in w.balls: result.balls.add ball
  result.cover = @[]
  for cover in w.cover: result.cover.add cover

proc graphSample*(w: World): Sample =
  result = Sample(tick:w.tick,redHearts:w.captures[0],blueHearts:w.captures[1])
  if visionRulesVersion >= 23:
    result.red = w.scoreTicks[0].float/TickRate
    result.blue = w.scoreTicks[1].float/TickRate
  else:
    result.red = w.captures[0].float
    result.blue = w.captures[1].float

proc sampleGraphs*(index: var ReplayIndex, w: World) =
  # Sample ownership changes exactly, plus one-second points and the final bonus.
  let sample = graphSample(w)
  if index.momentum.len > 0:
    let previous = index.momentum[^1]
    if sample.tick <= previous.tick: return
    if sample.tick mod TickRate != 0 and w.winner == -1 and
        sample.redHearts == previous.redHearts and sample.blueHearts == previous.blueHearts:
      return
  index.momentum.add sample

proc indexReplay*(): ReplayIndex =
  var tags, hits: seq[Moment]
  observeHit = proc(tick: int32, victim, attacker: int, pos: Point) =
    hits.add Moment(tick: tick+1, slot: attacker, side: team(attacker),
        victim: victim, kind: "hit", x: pos.x, z: pos.z)
  defer: observeHit = nil
  observeTag = proc(tick: int32, victim, attacker: int, pos: Point) =
    tags.add Moment(tick: tick + 1, slot: attacker, side: team(attacker),
        victim: victim, kind: "tag", x: pos.x, z: pos.z)
  defer: observeTag = nil
  world = newWorld(recording.seed, recording.endTick)
  result.checkpoints.add Checkpoint(state: snapshot(world))
  result.sampleGraphs(world)
  while world.tick < recording.frames.len:
    let previous = world.cogs
    let equipment = world.equipment
    let hearts = world.hearts
    var owners:seq[int32]
    for h in world.controlHearts:owners.add h.owner
    advance()
    for i,h in world.controlHearts:
      if h.owner!=owners[i] and h.owner>=0:
        result.events.add Moment(tick:world.tick,slot: -1,side:h.owner.int,
          kind:"territory",victim:i,x:h.pos.x,z:h.pos.z)
    result.hits.add hits
    hits.setLen(0)
    result.events.add tags
    tags.setLen(0)
    for i, cog in world.cogs:
      template event(label: string) =
        result.events.add Moment(tick: world.tick, slot: i, side: team(i),
            kind: label, x: cog.pos.x, z: cog.pos.z)
      if world.equipment[i].grenade and not equipment[i].grenade: event("grenade pickup")
      if world.equipment[i].sprayCan and not equipment[i].sprayCan: event("spray pickup")
      if world.equipment[i].armor > equipment[i].armor: event("shield pickup")
      if world.equipment[i].burst > equipment[i].burst: event("spray")
      if cog.hp > previous[i].hp and previous[i].hp > 0: event("heal")
      if cog.hp == 0 and previous[i].hp > 0:
        event("down")
      if visionRulesVersion<13 and cog.captures > previous[i].captures: event("capture")
      if cog.carrying and not previous[i].carrying: event("pickup")
    for g in world.grenades:
      if g.releasedAt == world.tick-1:
        result.events.add Moment(tick: world.tick, slot: g.owner, side: team(
            g.owner.int), kind: "grenade throw", x: g.target.x, z: g.target.z)
    for b in world.blasts:
      if b.tick == world.tick-1:
        result.events.add Moment(tick: world.tick, slot: b.owner, side: team(
            b.owner.int), kind: "grenade blast", x: b.pos.x, z: b.pos.z)
    for side in 0..1:
      if hearts[side].carrier >= 0 and world.hearts[side].carrier < 0:
        result.events.add Moment(tick: world.tick, slot: hearts[side].carrier,
            side: side, kind: (if world.hearts[side].pos == home(
            side): "return" else: "drop"), x: world.hearts[side].pos.x,
            z: world.hearts[side].pos.z)
      if hearts[side].returnAt > 0 and world.hearts[side].returnAt == 0 and
          world.hearts[side].carrier < 0:
        result.events.add Moment(tick: world.tick, slot: -1, side: side,
            kind: "return", x: home(side).x, z: home(side).z)
    result.sampleGraphs(world)
    if world.tick == recording.frames.len and result.momentum[^1].tick != world.tick:
      result.momentum.add graphSample(world)
    if world.tick mod 240 == 0:
      result.checkpoints.add Checkpoint(state: snapshot(world))
  world = newWorld(recording.seed, recording.endTick)

proc restore*(index: ReplayIndex, tick: int) =
  let target = clamp(tick, 0, recording.frames.len)
  world = snapshot(index.checkpoints[min(target div 240,
      index.checkpoints.high)].state)
  while world.tick < target: advance()
