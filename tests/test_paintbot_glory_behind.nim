import std/[unittest]
import polyworld/[cli]
import ../examples/paintbot/[sim, game]

proc idle(w: var World, ticks: int) =
  var commands: array[Seats, Command]
  for tick in 0..<ticks: w.step(commands)

proc behindAwards(w: World): seq[GloryEvent] =
  for event in w.gloryEvents:
    if event.kind == gloryBehindLives: result.add event

proc firstSeat(side: int): int =
  for i in 0..<Seats:
    if team(i) == side: return i

suite "Glory for being behind in lives":
  setup:
    visionRulesVersion = 39
    replayRulesVersion = 39
  test "level teams earn nothing":
    var w = newWorld(2026)
    w.pickups.setLen(0)
    w.idle(2*GloryBehindLivesTicks)
    check w.behindAwards.len == 0
    check w.glory == [590'i32, 590'i32]
  test "every five seconds the team behind earns one glory per missing life":
    var w = newWorld(2026)
    w.pickups.setLen(0)
    let seat = firstSeat(0)
    w.equipment[seat].lives -= 3
    w.idle(GloryBehindLivesTicks-1)
    check w.behindAwards.len == 0
    w.idle(1)
    check w.tick == GloryBehindLivesTicks
    check w.glory == [598'i32, 595'i32]
    let awards = w.behindAwards
    check awards.len == 1
    check awards[0].team == 0
    check awards[0].amount == 3*GloryBehindLives
    # The deficit keeps paying on every five-second boundary while it lasts.
    w.idle(GloryBehindLivesTicks)
    check w.glory == [596'i32, 590'i32]
  test "a death costs a life and pays the dead cog's team at the next boundary":
    var w = newWorld(2026)
    w.pickups.setLen(0)
    let victim = firstSeat(1)
    let before = w.equipment[victim].lives
    w.cogs[victim].shield = 0
    w.damage(victim, -1, 10_000)
    check w.equipment[victim].lives == before-1
    w.idle(GloryBehindLivesTicks)
    let awards = w.behindAwards
    check awards.len == 1
    check awards[0].team == 1
    check awards[0].amount == 1
    check w.glory == [595'i32, 596'i32]
  test "rules 38, live in 0.3.39, does not pay for lives":
    visionRulesVersion = 38
    replayRulesVersion = 38
    var w = newWorld(2026)
    w.pickups.setLen(0)
    w.equipment[firstSeat(0)].lives -= 3
    w.idle(2*GloryBehindLivesTicks)
    check w.behindAwards.len == 0
    check w.glory == [590'i32, 590'i32]
  test "rules 39 pays nothing for friendly fire; rules 38 still pays thirty per hit":
    var w = newWorld(2026)
    w.pickups.setLen(0)
    var a = -1
    var b = -1
    for i in 0..<Seats:
      if team(i) == 0:
        if a < 0: a = i elif b < 0: b = i
    w.cogs[b].shield = 0
    w.damage(b, a, 1)
    check w.gloryEvents.len == 0
    check w.glory == [600'i32, 600'i32]
    visionRulesVersion = 38
    replayRulesVersion = 38
    var old = newWorld(2026)
    old.pickups.setLen(0)
    old.cogs[b].shield = 0
    old.damage(b, a, 1)
    check old.gloryEvents.len == 1
    check old.gloryEvents[0].kind == gloryFriendlyFire
    check old.glory == [600'i32+GloryFriendlyFire, 600'i32]
