## The Paintbot action-camera director: event timing, lookahead, and a
## coverage floor on a recorded match.
import std/[unittest, os, options]
import vmath
import polyworld/actioncam
import ../examples/paintbot/[sim, game, analysis, kinship, camdirector, camera_eval]

const Root = currentSourcePath().parentDir.parentDir

proc allSeen(i: int): bool = true

proc posesOf(w: World): array[Seats, Vec3] =
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
