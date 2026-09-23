import std/[unittest, os, tempfiles]
import polyworld/[cli]
import ../examples/paintbot/[sim, game, bots]

proc idle(w: var World, ticks: int) =
  var commands: array[Seats, Command]
  for tick in 0..<ticks: w.step(commands)

proc mirror(p: Point): Point = point(Width-p.x.int, Height-p.z.int)

proc park(w: var World) =
  ## Every cog out and waiting to respawn, so none can touch a heart.
  for i in 0..<Seats:
    w.cogs[i].hp = 0; w.cogs[i].respawn = 10_000

suite "Glory hearts":
  setup:
    visionRulesVersion = 38
    replayRulesVersion = 38
  test "the first mirrored pair appears at 0:20 on open dry land and lasts thirty seconds":
    var w = newWorld(2026)
    check w.nextGloryHeart == GloryHeartFirstTick
    w.park()
    w.idle(GloryHeartFirstTick)
    check w.gloryHearts.len == 0
    w.idle(1)
    check w.gloryHearts.len == 2
    let a = w.gloryHearts[0]
    let b = w.gloryHearts[1]
    check b.pos == mirror(a.pos)
    check a.expiresAt == GloryHeartFirstTick+GloryHeartTicks
    for heart in w.gloryHearts:
      check not w.blocked(heart.pos)
      check riverBlend(heart.pos.x.int, heart.pos.z.int) == 0
    check w.nextGloryHeart in GloryHeartFirstTick+GloryHeartMinGap..GloryHeartFirstTick+GloryHeartMaxGap
    # Untouched hearts vanish when their thirty seconds are up.
    w.idle(a.expiresAt-w.tick)
    var alive = false
    for heart in w.gloryHearts:
      if heart.pos == a.pos: alive = true
    check alive
    w.idle(1)
    for heart in w.gloryHearts:
      check heart.pos != a.pos
      check heart.pos != b.pos
  test "pairs keep coming every ten to twenty seconds":
    var w = newWorld(7)
    w.park()
    var spawns = 0
    var last = -1'i32
    for tick in 0..<5*60*TickRate:
      let before = w.nextGloryHeart
      w.idle(1)
      if w.nextGloryHeart != before:
        inc spawns
        if last >= 0: check before-last in GloryHeartMinGap..GloryHeartMaxGap
        last = before
    check spawns >= 14
    check spawns <= 29
  test "touching a heart pays the toucher's team twenty glory, once":
    var w = newWorld(2026)
    w.pickups.setLen(0)
    w.idle(GloryHeartFirstTick+1)
    let heart = w.gloryHearts[0]
    let glory = w.glory
    # Blue cog 3 drives onto the heart; nobody else is near it.
    w.cogs[3].pos = point(heart.pos.x.int+GloryHeartReach-10, heart.pos.z.int)
    w.cogs[3].goal = w.cogs[3].pos
    w.idle(1)
    check w.glory[1] == glory[1]-(w.tick div TickRate-(w.tick-1) div TickRate)+GloryHeartAward
    check w.glory[0] == glory[0]-(w.tick div TickRate-(w.tick-1) div TickRate)
    check w.gloryHearts.len == 1
    check w.gloryHearts[0].pos == mirror(heart.pos)
    check w.gloryEvents[^1].kind == gloryHeart
    check w.gloryEvents[^1].team == 1
    check w.gloryEvents[^1].amount == GloryHeartAward
    check w.gloryPickups.len == 1
    check w.gloryPickups[0].seat == 3
    check w.gloryPickups[0].amount == GloryHeartAward
    check w.gloryPickups[0].pos == heart.pos
    # A heart is not a supply: the quiet-supplies clock keeps running.
    check w.lastSupplyTick == [0'i32, 0'i32]
    let after = w.glory
    w.idle(1)
    check w.glory[1] <= after[1]
    # The pickup is remembered for the viewer, then forgotten.
    w.idle(GloryEventLifetime-2)
    check w.gloryPickups.len == 1
    w.idle(1)
    check w.gloryPickups.len == 0
  test "dead cogs cannot take a heart":
    var w = newWorld(2026)
    w.idle(GloryHeartFirstTick+1)
    w.park()
    let heart = w.gloryHearts[0]
    w.cogs[0].pos = heart.pos
    w.idle(1)
    check w.gloryHearts.len == 2
    check w.gloryPickups.len == 0
  test "glory hearts are part of the rules 38 hash and absent from rules 37":
    var w = newWorld(2026)
    w.idle(GloryHeartFirstTick+1)
    var tampered = w
    tampered.gloryHearts[0].pos.x += 1
    check tampered.stateHash() != w.stateHash()
    visionRulesVersion = 37
    replayRulesVersion = 37
    var old = newWorld(2026)
    check old.nextGloryHeart == 0
    old.idle(GloryHeartFirstTick+GloryHeartTicks)
    check old.gloryHearts.len == 0
    check old.gloryPickups.len == 0
    var oldTampered = old
    oldTampered.nextGloryHeart = 99
    check oldTampered.stateHash() == old.stateHash()
  test "BASIC sees glory hearts only when they are in view":
    var w = newWorld(2026)
    w.idle(GloryHeartFirstTick+1)
    let heart = w.gloryHearts[0]
    # Cog 0 stands 600 units west of the heart and faces it; cog 1 faces away.
    w.cogs[0].pos = point(heart.pos.x.int-600, heart.pos.z.int)
    w.cogs[0].aim = heart.pos
    w.cogs[1].pos = point(heart.pos.x.int-600, heart.pos.z.int+300)
    w.cogs[1].aim = point(heart.pos.x.int-2000, heart.pos.z.int+300)
    let (file, path) = createTempFile("glory-hearts-", ".bas")
    file.write("walkTo(gloryHeartX(0),gloryHeartY(0))\nlookAt(gloryHeartCount(),gloryHeartX(9))")
    file.close()
    defer: removeFile(path)
    let players = loadBots(@[BotGroup(path: path, count: Seats)])
    let seen = w.canSeePoint(0, heart.pos)
    let commands = players.decide(w)
    if seen: check commands[0].goal == heart.pos
    check commands[0].aim == point(2, -1)
    check commands[1].goal == point(-1, -1)
