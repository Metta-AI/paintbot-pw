## Paintbot's action-camera director: scores what is worth watching each
## simulation tick and feeds the shared ActionCam. It has no graphics
## dependencies, so camera_eval can run it headless over replays.
import vmath
import polyworld/actioncam
import game, sim, analysis
from kinship import activeKinship, rPercent

type
  Director* = ref object
    cam*: ActionCam
    tick*: int32
      ## Simulation tick the interests were last rebuilt for, or -1.

proc newDirector*(mapSpan: float32): Director =
  ## Creates a director tuned for Paintbot's arena scale.
  Director(
    cam: initActionCam(minDistance = 26, maxDistance = 150, tight = 0.6,
      followRate = 1.0, zoomRate = 0.7, holdSeconds = 2.8, mapSpan = mapSpan),
    tick: -1)

proc related(a, b: int): bool =
  ## Whether two FFA-kin seats share any kinship.
  ffa() and activeKinship.rPercent(a, b) > 0

proc mapSpan*(): float32 =
  ## Ground width of the current map in metres.
  (maxX()-minX()).float32/100

proc worldPoint*(w: World, p: Point, y = 0'f32): Vec3 =
  ## Viewer-space position of a simulation point, including terrain height.
  vec3(p.x.float32/100-32, y+(
    if replayRulesVersion >= 9: w.elevation(p).float32/100 else: 0'f32),
    p.z.float32/100-20)

proc noteInterests*(d: Director, w: World, index: ReplayIndex,
    poses: array[Seats, Vec3], seen: proc(i: int): bool, lens: int) =
  ## Rebuilds the scored interests for the current simulation tick.
  var cam = d.cam
  cam.beginFrame(w.tick)
  for i, c in w.cogs:
    if c.hp <= 0 or not seen(i): continue
    cam.noteInterest(int32(i+1), poses[i], 15, 5, w.tick, 1)
    when Seats <= 16:
      for j in i+1..<Seats:
        if (not ffa() and team(i) == team(j)) or w.cogs[j].hp <= 0 or not seen(j): continue
        let gap = length(poses[i]-poses[j])
        if gap < 40:
          cam.noteInterest(int32(100+i*Seats+j), (poses[i]+poses[j])*0.5,
            100-gap, gap*0.5+3, w.tick, 1)
    else:
      # Crowds: every pair within 40 m is thousands of interests a tick. Each cog adds
      # only its nearest opponent (unrelated, in FFA-kin), in an id range of its own.
      var nearest = -1
      var nearestGap = 40'f32
      for j in 0..<Seats:
        if j == i or w.cogs[j].hp <= 0 or not seen(j): continue
        if (not ffa() and team(i) == team(j)) or related(i, j): continue
        let gap = length(poses[i]-poses[j])
        if gap < nearestGap: nearest = j; nearestGap = gap
      if nearest >= 0:
        cam.noteInterest(int32(1_500_000_000+i), (poses[i]+poses[nearest])*0.5,
          100-nearestGap, nearestGap*0.5+3, w.tick, 1)
  for n, h in w.controlHearts:
    var nearby: array[2, int]
    var total = 0
    for i, c in w.cogs:
      if c.hp > 0 and seen(i) and distance2(c.pos, h.pos) < 1000000:
        inc nearby[team(i)]
        inc total
    if total > 0:
      let contested = if ffa(): total > 1 else: nearby[0] > 0 and nearby[1] > 0
      cam.noteInterest(int32(1000+n), w.worldPoint(h.pos, 2),
        (if contested: 125'f32 else: 45'f32), 9, w.tick, 1)
  # Events are recorded in tick order: start at the first one from the last 36 ticks.
  var first = 0
  var hi = index.events.len
  while first < hi:
    let mid = (first+hi) div 2
    if index.events[mid].tick < w.tick-36: first = mid+1 else: hi = mid
  for n in first..<index.events.len:
    let event = index.events[n]
    if event.tick > w.tick: break
    if w.tick-event.tick > 36: continue
    if event.slot >= 0 and not seen(event.slot): continue
    let weight = case event.kind
      of "grenade blast": 165'f32
      of "down": 145'f32
      of "tag", "spray": 100'f32
      of "territory": 130'f32
      else: 0'f32
    if weight > 0 and (lens < 0 or event.slot >= 0):
      cam.noteInterest(int32(10000+n), w.worldPoint(point(event.x, event.z), 1),
        weight, 9, w.tick, 1)
  d.tick = w.tick
