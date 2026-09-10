## Replay analysis is reconstructed from hash-verified simulation, never guessed.
import game, sim

type
  Moment* = object
    tick*, slot*, side*, victim*: int
    kind*: string
    x*, z*: int32
  Sample* = object
    tick*: int
    red*, blue*: int32
  Checkpoint* = object
    state*: World
  ReplayIndex* = object
    events*: seq[Moment]
    momentum*: seq[Sample]
    checkpoints*: seq[Checkpoint]

proc snapshot(w: World): World =
  result = w
  # Explicit copies keep checkpoint storage independent of mutable sequences.
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

proc indexReplay*(): ReplayIndex =
  var tags: seq[Moment]
  observeTag = proc(tick: int32, victim, attacker: int, pos: Point) =
    tags.add Moment(tick: tick + 1, slot: attacker, side: team(attacker),
        victim: victim, kind: "tag", x: pos.x, z: pos.z)
  defer: observeTag = nil
  world = newWorld(recording.seed)
  result.checkpoints.add Checkpoint(state: snapshot(world))
  while world.tick < recording.frames.len:
    let previous = world.cogs
    let equipment = world.equipment
    let hearts = world.hearts
    advance()
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
      if cog.captures > previous[i].captures: event("capture")
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
    if world.tick mod 24 == 0 or world.tick == recording.frames.len:
      var glory: array[2, int32]
      for i, c in world.cogs: glory[team(i)] += c.tags + c.captures * 10
      result.momentum.add Sample(tick: world.tick, red: glory[0], blue: glory[1])
    if world.tick mod 240 == 0:
      result.checkpoints.add Checkpoint(state: snapshot(world))
  world = newWorld(recording.seed)

proc restore*(index: ReplayIndex, tick: int) =
  let target = clamp(tick, 0, recording.frames.len)
  world = snapshot(index.checkpoints[min(target div 240,
      index.checkpoints.high)].state)
  while world.tick < target: advance()
