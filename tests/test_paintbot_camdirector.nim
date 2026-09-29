## The Paintbot action-camera director: event timing, lookahead, and a
## coverage floor on a recorded match.
import std/[unittest, os, options]
import vmath
import polyworld/actioncam
import ../examples/paintbot/[sim, game, analysis, kinship, camdirector, camera_eval]

const Root = currentSourcePath().parentDir.parentDir

proc allSeen(i: int): bool = true

proc posesOf(w: World): array[MaxSeats, Vec3] =
  for i, c in w.cogs: result[i] = w.worldPoint(c.pos)

suite "camera director":
  setup:
    configureMap("")
    visionRulesVersion = 41
    replayRulesVersion = 41
    gameMode = gmTeams
    kinshipOverride = none(Kinship)
    replayMode = false

  test "a coming event is scored only with lookahead":
    var w = newWorld(2026, 2000)
    let h = w.controlHearts[0].pos
    let index = ReplayIndex(events: @[Moment(tick: 20, slot: -1, side: 0,
      kind: "territory", x: h.x, z: h.z)])
    let ahead = newDirector(mapSpan(), lookahead = true)
    ahead.noteInterests(w, index, w.posesOf, allSeen, -1)
    check ahead.cam.interestScore(10000) > 0
    let live = newDirector(mapSpan())
    live.noteInterests(w, index, w.posesOf, allSeen, -1)
    check live.cam.interestScore(10000) == -1

  test "a coming event grows as it nears and decays once past":
    var w = newWorld(2026, 2000)
    let h = w.controlHearts[0].pos
    let index = ReplayIndex(events: @[Moment(tick: 60, slot: -1, side: 0,
      kind: "territory", x: h.x, z: h.z)])
    let d = newDirector(mapSpan(), lookahead = true)
    var scores: seq[float32]
    for tick in [0'i32, 50, 60, 72, 110]:
      w.tick = tick
      d.noteInterests(w, index, w.posesOf, allSeen, -1)
      scores.add d.cam.interestScore(10000)
    check scores[0] == -1          # beyond the lead window
    check scores[1] > 0
    check scores[2] > scores[1]    # peaks when it happens
    check abs(scores[3] - scores[2]*0.5) < 1  # one half-life later
    # Gone once too old; it may linger one tick after its last note.
    check scores[4] == -1

  test "the recorded match keeps a coverage floor":
    # A breakage guard, not a tuning target: the fixture is an 18-second match with only
    # 11 key events (6 of them near-simultaneous opening captures). Tune with camera_eval
    # over real league replays instead.
    var totals: Totals
    evaluate(Root / "tests/data/paintbot_ffa_1040.replay", 1, totals)
    check totals.frames > 0
    check totals.coverage >= 0.5

suite "inset and instant replay":
  test "the inset frames strong action outside the main shot and holds it":
    let d = newDirector(200)
    var cam = d.cam
    cam.beginFrame(0)
    cam.noteInterest(1, vec3(0, 0, 0), 150, 4, 0, 1000)
    cam.chooseShot(0)
    check d.insetShot(0).show == false
    cam.noteInterest(2, vec3(120, 0, 0), 130, 4, 0, 1000)
    let shot = d.insetShot(1/60)
    check shot.show
    check abs(shot.target.x-120) < 1
    # The runner-up cools below the keep bar: the inset holds a moment, then hides.
    cam.noteInterest(2, vec3(120, 0, 0), 20, 4, 0, 1000, replace = true)
    check d.insetShot(1).show
    check not d.insetShot(3).show

  test "an instant replay waits for calm, rewinds, and returns":
    var r: InstantReplay
    r.noteMissed(100, vec3(5, 0, 5))
    check r.update(110, 1/60, calm = false) == -1
    let back = r.update(120, 1/60, calm = true)
    check back == 100-2*TickRate
    check r.active
    check r.update(110, 1/60, calm = true) == -1
    # It ends past where it started from, so playback carries on with no seek.
    check r.update(100+TickRate*3 div 2, 1/60, calm = true) == -1
    check not r.active
    # Cooldown: a fresh miss right away must wait.
    r.noteMissed(130, vec3(0, 0, 0))
    check r.update(131, 1/60, calm = true) == -1

  test "a stale miss is dropped":
    var r: InstantReplay
    r.noteMissed(100, vec3(0, 0, 0))
    check r.update(100+9*TickRate, 1/60, calm = true) == -1
    check not r.active

  test "fast playback ends a replay and returns only forward":
    var r: InstantReplay
    r.noteMissed(200, vec3(0, 0, 0))
    check r.update(230, 1/60, calm = true) == 200-2*TickRate
    check r.update(170, 1/60, calm = true, allowed = false) == 230
    check not r.active
    var late: InstantReplay
    late.noteMissed(200, vec3(0, 0, 0))
    discard late.update(230, 1/60, calm = true)
    check late.finish(231) == -1

  test "a manual seek holds off the next replay":
    var r: InstantReplay
    r.cancel()
    r.noteMissed(300, vec3(0, 0, 0))
    check r.update(301, 1, calm = true) == -1
    check r.update(302, 10, calm = true) != -1

suite "per-mode grading":
  teardown:
    gameMode = gmTeams

  test "each game mode gets its own grading":
    gameMode = gmTeams
    check gradingFor() == TeamsGrading
    check newDirector(100).grading == TeamsGrading
    gameMode = gmFfaKin
    check gradingFor() == FfaGrading
    let d = newDirector(100)
    check d.grading == FfaGrading
    check d.cam.holdSeconds == FfaGrading.hold
    check d.cam.fatigueSeconds == FfaGrading.fatigue
