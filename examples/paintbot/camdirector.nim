## Paintbot's action-camera director: scores what is worth watching each
## simulation tick and feeds the shared ActionCam. It has no graphics
## dependencies, so camera_eval can run it headless over replays.
##
## Scores are rebuilt every tick and replace the previous tick's, so they can
## fall as well as rise: a past event decays, a separating pair cools off.
## With `lookahead` (replays, where the whole event index is known), events up
## to LeadTicks ahead are scored too, so the camera is already there when a
## cog goes down or a heart flips.
import std/math
import vmath
import polyworld/actioncam
import game, sim, analysis
from kinship import activeKinship, rPercent

const
  PastTicks = 36
    ## How long a past event stays interesting.
  HalfLifeTicks = 12'f32
    ## A past event's score halves every half second.
  LeadTicks = 48
    ## With lookahead, events this many ticks ahead are scored.
  LeadFloor = 0.6'f32
    ## Share of its score an event has at the far edge of the lead window.
  HitTicks = 24
    ## A hit links shooter and victim for one second either side.
  LeadSeconds = 0.5'f32
    ## Shots are framed where a moving subject will be this soon.
  LeadMaxMeters = 6'f32
  CoverageSeconds = 40'f32
    ## A cog unseen this long reaches the full coverage bonus.
  InsetScore = 110'f32
    ## An interest this strong outside the main shot earns the inset.
  InsetKeepScore = 60'f32
  InsetHoldSeconds = 3'f32
  InsetGapSeconds = 3'f32
    ## After the inset hides it stays down this long unless something urgent appears.
  InsetUrgentScore = 150'f32
  ReplayLeadTicks = 2*TickRate
    ## An instant replay starts this long before the missed highlight.
  ReplayTailTicks = TickRate*3 div 2
  ReplayMaxAgeTicks = 8*TickRate
    ## A missed highlight older than this is no longer worth rewinding for.
  ReplayCooldownSeconds* = 45'f32
  SeekQuietSeconds = 10'f32
    ## After a manual seek or skip, no instant replay for this long.
  MissScanTicks* = 12
    ## Ticks passed in one frame beyond this are a seek, not playback: nothing
    ## jumped over counts as missed.
  ReplayFocusId* = 1_700_000_000'i32
  CalmScore* = 100'f32
    ## An instant replay waits until the held shot scores below this.

type
  Director* = ref object
    cam*: ActionCam
    tick*: int32
      ## Simulation tick the interests were last rebuilt for, or -1.
    lookahead*: bool
      ## Score future events from the index (replays only).
    coverageBonus*: float32
      ## Extra score for a cog the camera has not shown in CoverageSeconds.
    lastPoses: array[Seats, Vec3]
    velocity: array[Seats, Vec3]
      ## Smoothed metres per tick.
    lastInShot: array[Seats, int32]
    insetId: int32
    insetTarget: Vec3
    insetDistance: float32
    insetHold: float32
      ## Wall-clock seconds the inset keeps its subject before it may hide or change.
    insetGap: float32
      ## Wall-clock seconds before a hidden inset may show a new subject.
  InsetShot* = tuple[show: bool, target: Vec3, distance: float32]
  InstantReplay* = object
    ## Rewinds to a highlight the main camera missed, then returns.
    active*: bool
    resumeTick*, endTick*: int32
    focus*: Vec3
    cooldown*: float32
      ## Wall-clock seconds until another replay may start.
    missed: seq[tuple[tick: int32, position: Vec3]]

proc newDirector*(mapSpan: float32, lookahead = false): Director =
  ## Creates a director tuned for Paintbot's arena scale.
  result = Director(
    cam: initActionCam(minDistance = 26, maxDistance = 150, tight = 0.6,
      followRate = 1.0, zoomRate = 0.7, holdSeconds = 4, mapSpan = mapSpan),
    tick: -1,
    lookahead: lookahead,
    coverageBonus: 20)
  result.cam.clusterShare = 0.35
  result.cam.fatigueSeconds = 14
  result.cam.jumpDistance = 90
  result.cam.sameShotMargin = 1.3

proc related(a, b: int): bool =
  ## Whether two FFA-kin seats share any kinship.
  ffa() and activeKinship.rPercent(a, b) > 0

proc opponents(a, b: int): bool =
  ## Whether two seats fight: other team, or unrelated in FFA-kin.
  if ffa(): not related(a, b) else: team(a) != team(b)

proc mapSpan*(): float32 =
  ## Ground width of the current map in metres.
  (maxX()-minX()).float32/100

proc worldPoint*(w: World, p: Point, y = 0'f32): Vec3 =
  ## Viewer-space position of a simulation point, including terrain height.
  vec3(p.x.float32/100-32, y+(
    if replayRulesVersion >= 9: w.elevation(p).float32/100 else: 0'f32),
    p.z.float32/100-20)

proc firstFrom(moments: seq[Moment], tick: int): int =
  ## Index of the first moment at or after `tick`; moments are in tick order.
  var hi = moments.len
  while result < hi:
    let mid = (result+hi) div 2
    if moments[mid].tick < tick: result = mid+1 else: hi = mid

proc timeWeight(d: Director, age: int): float32 =
  ## Multiplier for an event `age` ticks old; negative ages are still to come.
  if age >= 0:
    if age > PastTicks: 0'f32 else: pow(0.5'f32, age.float32/HalfLifeTicks)
  elif not d.lookahead or -age > LeadTicks: 0'f32
  else: LeadFloor+(1-LeadFloor)*(1-(-age).float32/LeadTicks)

proc closeness(w: World): float32 =
  ## One when the teams are level on cogs standing plus lives, falling
  ## toward zero in a blowout. FFA-kin is always close.
  if ffa(): return 1
  var strength: array[2, int]
  for i, c in w.cogs:
    strength[team(i)] += w.equipment[i].lives + (if c.hp > 0: 1 else: 0)
  let total = strength[0]+strength[1]
  if total == 0: 1'f32 else: 1-abs(strength[0]-strength[1]).float32/total.float32

proc impact(w: World, event: Moment): float32 =
  ## How much an event matters to the match beyond its kind.
  result = 1
  case event.kind
  of "down":
    if event.slot in 0..<Seats:
      if w.equipment[event.slot].lives <= 0: result *= 1.2
      if not ffa():
        var standing = 0
        for i, c in w.cogs:
          if team(i) == team(event.slot) and c.hp > 0: inc standing
        if standing <= 1: result *= 1.5
        elif standing <= 2: result *= 1.25
  of "territory":
    if not ffa() and event.side in 0..1:
      var owned: array[2, int]
      for h in w.controlHearts:
        if h.owner in 0..1: inc owned[h.owner]
      # A flip that takes or ties the heart lead matters more.
      if abs(owned[0]-owned[1]) <= 1: result *= 1.3
  else: discard

proc noteInterests*(d: Director, w: World, index: ReplayIndex,
    poses: array[Seats, Vec3], seen: proc(i: int): bool, lens: int) =
  ## Rebuilds the scored interests for the current simulation tick.
  var cam = d.cam
  cam.beginFrame(w.tick)
  let
    tick = w.tick
    stakes = 0.8'f32+0.4'f32*w.closeness()
  # Motion: a smoothed velocity per cog, reset across respawns and seeks.
  let elapsed = if d.tick >= 0 and tick > d.tick: tick-d.tick else: 0
  for i in 0..<Seats:
    if elapsed in 1..4 and length(poses[i]-d.lastPoses[i]) < 4:
      d.velocity[i] = mix(d.velocity[i], (poses[i]-d.lastPoses[i])/elapsed.float32, 0.25)
    else:
      d.velocity[i] = vec3(0, 0, 0)
    d.lastPoses[i] = poses[i]
  proc led(p, v: Vec3): Vec3 =
    ## Leads a shot in the direction of travel.
    var ahead = v*(LeadSeconds*TickRate.float32)
    ahead.y = 0
    let n = length(ahead)
    if n > LeadMaxMeters: ahead = ahead*(LeadMaxMeters/n)
    p+ahead
  # Coverage: which cogs the current shot holds.
  if cam.locked:
    for i in 0..<Seats:
      if length(vec2(poses[i].x-cam.lockTarget.x, poses[i].z-cam.lockTarget.z)) <=
          cam.lockDistance*0.5:
        d.lastInShot[i] = tick
  # Hits in the last and next second, by shooter and victim.
  var hitAge: seq[tuple[attacker, victim, age: int]]
  for n in firstFrom(index.hits, tick-HitTicks)..<index.hits.len:
    let hit = index.hits[n]
    if hit.tick > tick+(if d.lookahead: HitTicks else: 0): break
    hitAge.add (hit.slot, hit.victim, int(tick-hit.tick))
  proc recentHit(a, b: int): bool =
    for h in hitAge:
      if (h.attacker == a and h.victim == b) or (h.attacker == b and h.victim == a):
        return true
  for i, c in w.cogs:
    if c.hp <= 0 or not seen(i): continue
    # The bonus reaches only as far as a pan, so it widens the shot rather
    # than cutting across the map to an idle cog.
    let unseen =
      if cam.locked and length(vec2(poses[i].x-cam.lockTarget.x,
          poses[i].z-cam.lockTarget.z)) > cam.jumpRange()*0.5: 0'f32
      else: max(0, tick-d.lastInShot[i]).float32/TickRate.float32
    cam.noteInterest(int32(i+1), led(poses[i], d.velocity[i]),
      15+d.coverageBonus*min(1, unseen/CoverageSeconds), 5, tick, 1, replace = true)
    # Danger: a cog one hit from going down with an opponent in sight.
    if c.hp == 1 and maxHp() > 1:
      for j, o in w.cogs:
        if o.hp > 0 and opponents(i, j) and seen(j) and w.visible(j, i) and
            length(poses[i]-poses[j]) < 25:
          cam.noteInterest(int32(1_600_000_000+i), led(poses[i], d.velocity[i]),
            70*stakes, 6, tick, 1, replace = true)
          break
    proc duel(id: int32, j: int, gap: float32) =
      ## Two opponents close together: hot when they can see or are hitting
      ## each other, lukewarm across a wall.
      let
        sighted = w.visible(i, j) or w.visible(j, i)
        base = (100-gap)*(if sighted: 1'f32 else: 0.35'f32)
        score = (base+(if recentHit(i, j): 30'f32 else: 0'f32))*stakes
      cam.noteInterest(id, led((poses[i]+poses[j])*0.5, (d.velocity[i]+d.velocity[j])*0.5),
        score, gap*0.5+3, tick, 1, replace = true)
    when Seats <= 16:
      for j in i+1..<Seats:
        if not opponents(i, j) or w.cogs[j].hp <= 0 or not seen(j): continue
        let gap = length(poses[i]-poses[j])
        if gap < 40: duel(int32(100+i*Seats+j), j, gap)
    else:
      # Crowds: every pair within 40 m is thousands of interests a tick. Each cog adds
      # only its nearest opponent (unrelated, in FFA-kin), in an id range of its own.
      var nearest = -1
      var nearestGap = 40'f32
      for j in 0..<Seats:
        if j == i or w.cogs[j].hp <= 0 or not seen(j) or not opponents(i, j): continue
        let gap = length(poses[i]-poses[j])
        if gap < nearestGap: nearest = j; nearestGap = gap
      if nearest >= 0: duel(int32(1_500_000_000+i), nearest, nearestGap)
  # Shooter and victim framed together while a hit is fresh or coming.
  for n in firstFrom(index.hits, tick-HitTicks)..<index.hits.len:
    let hit = index.hits[n]
    let weight = d.timeWeight(tick-hit.tick)
    if hit.tick > tick+LeadTicks: break
    if weight <= 0 or hit.slot notin 0..<Seats or hit.victim notin 0..<Seats: continue
    if not seen(hit.slot) and not seen(hit.victim): continue
    let
      a = poses[hit.slot]
      b = poses[hit.victim]
    cam.noteInterest(int32(700_000_000+n), (a+b)*0.5, 70*weight*stakes,
      length(a-b)*0.5+3, tick, 1, replace = true)
  for n, h in w.controlHearts:
    var nearby: array[2, int]
    var total = 0
    for i, c in w.cogs:
      if c.hp > 0 and seen(i) and distance2(c.pos, h.pos) < 1000000:
        inc nearby[team(i)]
        inc total
    if total > 0:
      let contested = if ffa(): total > 1 else: nearby[0] > 0 and nearby[1] > 0
      var score = if contested: 125'f32 else: 45'f32
      # A capture under way heats up as it nears the flip.
      if n < w.heartCaptures.len and w.heartCaptures[n].team >= 0:
        score = max(score, 45+90*min(1, w.heartCaptures[n].ticks.float32/HeartCaptureTicks.float32))
      cam.noteInterest(int32(1000+n), w.worldPoint(h.pos, 2), score*stakes, 9, tick, 1,
        replace = true)
  if ffa():
    for n, g in w.greatHearts:
      if g.progress > 0 and g.dormantUntil <= tick:
        cam.noteInterest(int32(5000+n), w.worldPoint(g.pos, 2),
          60+80*min(1, g.progress.float32/GreatHeartCaptureTicks.float32), 12, tick, 1,
          replace = true)
  for n in firstFrom(index.events, tick-PastTicks)..<index.events.len:
    let event = index.events[n]
    if event.tick > tick+LeadTicks: break
    let timing = d.timeWeight(tick-event.tick)
    if timing <= 0: continue
    if event.slot >= 0 and not seen(event.slot): continue
    let weight = case event.kind
      of "grenade blast": 165'f32
      of "down": 145'f32
      of "great heart": 150'f32
      of "territory": 130'f32
      of "great heart charge": 100'f32
      of "tag", "spray": 100'f32
      else: 0'f32
    if weight > 0 and (lens < 0 or event.slot >= 0):
      cam.noteInterest(int32(10000+n), w.worldPoint(point(event.x, event.z), 1),
        weight*timing*w.impact(event)*stakes, 9, tick, 1, replace = true)
  d.tick = tick

proc insetShot*(d: Director, dt: float32): InsetShot =
  ## A second view on the strongest action outside the main shot, held for a
  ## few seconds so it does not flicker.
  let cam = d.cam
  d.insetHold = max(0, d.insetHold-max(dt, 0))
  d.insetGap = max(0, d.insetGap-max(dt, 0))
  if not cam.locked: return
  proc outside(p: Vec3): bool =
    length(vec2(p.x-cam.lockTarget.x, p.z-cam.lockTarget.z)) > cam.lockDistance*0.7
  var bestId = 0'i32
  var best = -1'f32
  for interest in cam.liveInterests:
    if not outside(interest.position): continue
    if interest.id == d.insetId and interest.score >= InsetKeepScore:
      d.insetTarget = interest.position
      d.insetDistance = 26+interest.radius*2
      bestId = interest.id
      break
    let bar = if d.insetId == 0 and d.insetGap > 0: InsetUrgentScore else: InsetScore
    if interest.score >= bar and interest.score > best:
      best = interest.score
      bestId = interest.id
      d.insetTarget = interest.position
      d.insetDistance = 26+interest.radius*2
  if bestId != 0:
    if bestId != d.insetId: d.insetHold = InsetHoldSeconds
    d.insetId = bestId
  elif d.insetHold <= 0 or not outside(d.insetTarget):
    if d.insetId != 0: d.insetGap = InsetGapSeconds
    d.insetId = 0
  if d.insetId != 0 or d.insetHold > 0 and outside(d.insetTarget):
    result = (true, d.insetTarget, d.insetDistance)

proc isHighlight*(w: World, event: Moment): bool =
  ## Whether an event deserves an instant replay if the camera missed it: a cog out
  ## of lives or one of the last two standing goes down, a heart flip that takes or
  ## ties the heart lead, or a great heart falls.
  case event.kind
  of "down": w.impact(event) >= 1.2
  of "territory": w.impact(event) > 1
  of "great heart": true
  else: false

proc noteMissed*(r: var InstantReplay, tick: int32, position: Vec3) =
  ## Remembers a highlight the main camera did not have on screen.
  if not r.active: r.missed.add (tick, position)

proc finish*(r: var InstantReplay, tick: int32): int32 =
  ## Ends a running replay. Returns the tick to seek forward to, or -1 when
  ## playback has already reached the moment the replay started from.
  result = -1
  if not r.active: return
  r.active = false
  r.cooldown = ReplayCooldownSeconds
  if tick < r.resumeTick: result = r.resumeTick

proc update*(r: var InstantReplay, tick: int32, dt: float32, calm: bool,
    allowed = true): int32 =
  ## Advances the replay state. Returns a tick to seek to, or -1. A running
  ## replay ends as soon as it is no longer `allowed` (fast playback).
  result = -1
  if r.active:
    if tick >= r.endTick or not allowed: return r.finish(tick)
    return
  r.cooldown = max(0, r.cooldown-max(dt, 0))
  var n = 0
  for m in r.missed:
    if tick-m.tick <= ReplayMaxAgeTicks and m.tick <= tick:
      r.missed[n] = m
      inc n
  r.missed.setLen(n)
  if not allowed or r.missed.len == 0 or r.cooldown > 0 or not calm: return
  let m = r.missed[^1]
  r.missed.setLen(0)
  r.active = true
  r.resumeTick = tick
  r.endTick = m.tick+ReplayTailTicks
  r.focus = m.position
  result = max(0, m.tick-ReplayLeadTicks)

proc cancel*(r: var InstantReplay) =
  ## Drops a running replay and anything queued, as after a manual seek, and
  ## holds off the next one so a skip is never followed by a rewind.
  r.active = false
  r.missed.setLen(0)
  r.cooldown = max(r.cooldown, SeekQuietSeconds)

iterator eventsBetween*(index: ReplayIndex, after, upTo: int): Moment =
  ## Yields the index events with after < tick <= upTo.
  for n in firstFrom(index.events, after+1)..<index.events.len:
    if index.events[n].tick > upTo: break
    yield index.events[n]
