## Headless action-camera evaluation over Paintbot replays.
##
##     nim r -d:release examples/paintbot/camera_eval.nim [--speed:4] [--cam:hold=4] a.replay [b.replay ...]
##
## Plays each replay through the viewer's camera director at 60 frames a
## second and the given playback speed, with no lens, then reports:
##
## - coverage: the share of key events (downs, grenade blasts, territory
##   flips, great-heart captures) whose position is on screen at the tick they
##   happen, and "early": on screen half a second before;
## - cuts/min: frames where the camera jumps (target moves over 20 m at once),
##   per wall-clock minute;
## - retargets/min: shot changes to a different place, per wall-clock minute;
## - pan: mean and 90th-percentile camera target speed in m/s, cuts excluded.
##
## The screen is the default 1440x900 spectator view at yaw 0, tilt 0.92.
import std/[algorithm, os, strformat, strutils, tables]
import vmath
import polyworld/actioncam
import game, sim, analysis, camdirector, projection

const
  Fps = 60
  EarlyTicks = 12
  CutMeters = 20'f32
  ScreenWidth = 1440
  ScreenHeight = 900
  Margin = 0.03'f32

type
  Tally* = object
    events*, covered*, early*: int
  Totals* = object
    kinds*: OrderedTable[string, Tally]
    frames*, cuts*, retargets*: int
    insetFrames*, eitherCovered*: int
      ## Frames showing the inset; key events on screen in the main view or the inset.
    highlights*, missedHighlights*: int
    replays*: int
      ## Instant replays that would start (counted, not played: the harness never seeks).
      ## Instant-replay candidates, and those neither the main view nor the inset showed.
    panSamples*: seq[float32]
    distanceSum*: float

proc keyKind(kind: string): bool =
  kind in ["down", "grenade blast", "territory", "great heart"]

proc onScreen(target: Vec3, distance: float32, p: Vec3): bool =
  let (_, view, projection) = spectatorCamera(target, distance, 0, 0.92,
    ScreenWidth, ScreenHeight)
  let s = projected(projection*view, p)
  s[0] in Margin..(1-Margin) and s[1] in Margin..(1-Margin)

proc allSeen(i: int): bool = true

var overrides: seq[(string, float32)]
  ## --cam:<field>=<value> overrides of CameraGrading fields (and lookahead=0/1),
  ## applied on top of the replay's mode grading.

proc graded(): CameraGrading =
  result = gradingFor()
  for (field, value) in overrides:
    var found = field == "lookahead"
    for name, slot in result.fieldPairs:
      if name == field:
        when slot is int: slot = value.int
        else: slot = value
        found = true
    if not found: quit "unknown --cam field: " & field

proc evaluate*(path: string, speed: float32, totals: var Totals) =
  recording = loadRecording(path)
  replayMode = true
  world = newWorld(recording.seed, recording.endTick)
  let index = indexReplay()
  world = newWorld(recording.seed, recording.endTick)
  let director = newDirector(mapSpan(), lookahead = true, grading = graded())
  for (field, value) in overrides:
    if field == "lookahead": director.lookahead = value != 0
  var
    target = vec3(0, 0, 0)
    distance = 60'f32
    accumulator = 0'f32
    lastLock = 0'i32
    lastLockTarget: Vec3
    nextEvent = 0
  # Events whose early check is pending, by index into index.events.
  var early: Table[int, bool]
  var instant: InstantReplay
  let dt = 1'f32/Fps
  while true:
    let finished = world.winner >= 0 or world.tick >= recording.frames.len
    if finished: break
    accumulator += speed*TickRate/Fps
    while accumulator >= 1 and world.tick < recording.frames.len and world.winner < 0:
      accumulator -= 1
      advance()
    var poses: array[Seats, Vec3]
    for i, c in world.cogs: poses[i] = world.worldPoint(c.pos)
    let tickChanged = director.tick != world.tick
    if tickChanged:
      director.noteInterests(world, index, poses, allSeen, -1)
    director.cam.chooseShot(dt, max(1, speed.int32))
    let before = target
    director.cam.follow(target, distance, dt, max(1, speed.int32))
    let inset = director.insetShot(dt)
    if speed <= 2:
      let calm = director.cam.interestScore(director.cam.lockId) < CalmScore
      if instant.update(world.tick, dt, calm) >= 0:
        inc totals.replays
        if existsEnv("CAMERA_EVAL_VERBOSE"):
          echo &"  instant replay at {world.tick div TickRate div 60}:{world.tick div TickRate mod 60:02}"
        instant.cancel()
        instant.cooldown = ReplayCooldownSeconds
    if inset.show: inc totals.insetFrames
    inc totals.frames
    totals.distanceSum += distance
    let moved = length(vec2(target.x-before.x, target.z-before.z))
    if moved > CutMeters: inc totals.cuts
    else: totals.panSamples.add moved/dt
    if director.cam.locked and director.cam.lockId != lastLock:
      if lastLock != 0 and length(vec2(director.cam.lockTarget.x-lastLockTarget.x,
          director.cam.lockTarget.z-lastLockTarget.z)) > 12:
        inc totals.retargets
      lastLock = director.cam.lockId
      lastLockTarget = director.cam.lockTarget
    if not tickChanged: continue
    # Early checks: the first frame an event is at most half a second ahead.
    # Several ticks may pass in one frame, so events are scored when their
    # tick has been reached, not only on an exact match.
    for n in nextEvent..<index.events.len:
      let e = index.events[n]
      if e.tick > world.tick+EarlyTicks: break
      if keyKind(e.kind) and n notin early and e.tick > world.tick:
        early[n] = onScreen(target, distance, world.worldPoint(point(e.x, e.z), 1))
    while nextEvent < index.events.len and index.events[nextEvent].tick <= world.tick:
      let e = index.events[nextEvent]
      if keyKind(e.kind) and e.tick > 0:
        var t = totals.kinds.mgetOrPut(e.kind, Tally())
        inc t.events
        let
          at = world.worldPoint(point(e.x, e.z), 1)
          main = onScreen(target, distance, at)
        if main: inc t.covered
        let shown = main or inset.show and onScreen(inset.target, inset.distance, at)
        if shown: inc totals.eitherCovered
        if world.isHighlight(e):
          inc totals.highlights
          if not shown:
            inc totals.missedHighlights
            instant.noteMissed(e.tick.int32, at)
        if early.getOrDefault(nextEvent, false): inc t.early
        totals.kinds[e.kind] = t
      inc nextEvent

proc coverage*(totals: Totals): float =
  ## Share of key events on screen when they happened.
  var events, covered = 0
  for t in totals.kinds.values:
    events += t.events
    covered += t.covered
  covered / max(1, events)

proc cutsPerMinute*(totals: Totals): float =
  totals.cuts.float / max(1e-9, totals.frames / Fps / 60)

proc percentile(values: seq[float32], p: float): float32 =
  if values.len == 0: return 0
  let sorted = values.sorted()
  sorted[min(sorted.high, int(p*sorted.len.float))]

when isMainModule:
  var speed = 1'f32
  var paths: seq[string]
  for arg in commandLineParams():
    if arg.startsWith("--speed:"): speed = parseFloat(arg["--speed:".len..^1]).float32
    elif arg.startsWith("--cam:"):
      let kv = arg["--cam:".len..^1].split('=')
      overrides.add (kv[0], parseFloat(kv[1]).float32)
    else: paths.add arg
  if paths.len == 0: quit "usage: camera_eval [--speed:N] <replay> [...]"
  var totals: Totals
  for path in paths: evaluate(path, speed, totals)
  var all: Tally
  echo &"replays {paths.len}  speed {speed}x  wall-clock {totals.frames/Fps/60:.1f} min"
  for kind, t in totals.kinds:
    all.events += t.events; all.covered += t.covered; all.early += t.early
    echo &"  {kind:<14} {t.events:5} events  coverage {100*t.covered/max(1, t.events):5.1f}%  early {100*t.early/max(1, t.events):5.1f}%"
  let minutes = totals.frames/Fps/60
  var mean = 0'f32
  for v in totals.panSamples: mean += v
  mean /= max(1, totals.panSamples.len).float32
  echo &"  {\"all\":<14} {all.events:5} events  coverage {100*all.covered/max(1, all.events):5.1f}%  early {100*all.early/max(1, all.events):5.1f}%"
  echo &"  with inset {100*totals.eitherCovered/max(1, all.events):5.1f}%  inset shown {100*totals.insetFrames/max(1, totals.frames):5.1f}% of frames  " &
    &"highlights {totals.highlights} (missed {totals.missedHighlights}, {totals.missedHighlights.float/minutes:.2f}/min)  " &
    &"instant replays {totals.replays} ({totals.replays.float/minutes:.2f}/min)"
  echo &"  cuts/min {totals.cuts.float/minutes:.2f}  retargets/min {totals.retargets.float/minutes:.2f}  " &
    &"pan mean {mean:.2f} m/s  p90 {percentile(totals.panSamples, 0.9):.2f} m/s  mean distance {totals.distanceSum/max(1, totals.frames).float:.1f}"
