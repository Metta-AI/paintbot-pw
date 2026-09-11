import std/unittest
import ../examples/paintbot/[sim, game, controls, bots]
import polyworld/cli

suite "GOTA-style human seats and action replay":
  test "human seat is empty while all other seats load bots":
    let players = loadBots(@[BotGroup(path: "examples/paintbot/players/base.bas", count: Seats-1)], 3)
    for i, bot in players:
      check bot.isNil == (i == 2)
  test "human actions record once and replay with identical hashes":
    replayMode = false
    options.playerSlot = 1
    recording = Recording(seed: 2026)
    world = newWorld(recording.seed)
    let target = Point(x: world.cogs[0].pos.x+300, z: world.cogs[0].pos.z)
    queueWalkTo(target)
    queueShootAt(target)
    advance()
    check recording.frames.len == 1
    check recording.frames[0].commands[0].walk
    check recording.frames[0].commands[0].shoot
    check recording.frames[0].commands[0].goal == target
    for tick in 1..<24: advance()
    let expected = world.stateHash()
    world = newWorld(recording.seed)
    for tick in 0..<24: advance()
    check recording.frames.len == 24
    check world.stateHash() == expected
    advance()
    check recording.frames.len == 25
    check not recording.frames[^1].commands[0].walk
