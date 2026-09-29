## Rules 47: a team with more cogs out of the match (dead, no lives left) than the enemy earns
## glory for each extra cog out, on top of the behind-in-lives award.
import std/[json, os, unittest]
import polyworld/[cli, tapes]
import ../examples/paintbot/[sim, game]

proc idle(w: var World, ticks: int) =
  var commands: array[LegacySeats, Command]
  for tick in 0..<ticks: w.step(commands)

proc awards(w: World, kind: GloryKind): seq[GloryEvent] =
  for event in w.gloryEvents:
    if event.kind == kind: result.add event

proc seats(side: int): seq[int] =
  for i in 0..<Seats:
    if team(i) == side: result.add i

proc knockOut(w: var World, seat: int) =
  ## Kill the cog on its last life, so it is out of the match.
  w.equipment[seat].lives = 1
  w.cogs[seat].shield = 0
  w.damage(seat, -1, 10_000)
  doAssert w.cogs[seat].hp <= 0 and w.equipment[seat].lives == 0

suite "Glory for being behind in cogs (rules 47)":
  setup:
    visionRulesVersion = 47
    replayRulesVersion = 47
    gameMode = gmTeams
    configureMap("")
    configureVision("")
    configureGlory(DefaultGloryConfig)

  test "level teams earn nothing":
    var w = newWorld(2026)
    w.pickups.setLen(0)
    w.idle(2*GloryBehindCogsTicks)
    check w.awards(gloryBehindCogs).len == 0
    check w.glory == [590'i32, 590'i32]

  test "every five seconds the team with more cogs out earns one glory per extra cog out":
    var w = newWorld(2026)
    w.pickups.setLen(0)
    let ember = seats(0)
    let startLives = w.equipment[ember[0]].lives
    w.knockOut(ember[0])
    w.knockOut(ember[1])
    check w.teamCogsOut(0) == 2
    check w.teamCogsOut(1) == 0
    w.idle(GloryBehindCogsTicks-1)
    check w.awards(gloryBehindCogs).len == 0
    w.idle(1)
    let cogs = w.awards(gloryBehindCogs)
    check cogs.len == 1
    check cogs[0].team == 0
    check cogs[0].amount == 2*GloryBehindCogs
    # The lost lives pay the behind-in-lives award too.
    let lives = w.awards(gloryBehindLives)
    check lives.len == 1
    check lives[0].amount == 2*startLives*GloryBehindLives
    check w.glory == [595'i32 + 2*startLives + 2, 595'i32]

  test "only the difference pays, and a cog still alive on its last life is not out":
    var w = newWorld(2026)
    w.pickups.setLen(0)
    let ember = seats(0)
    let azure = seats(1)
    w.knockOut(ember[0])
    w.knockOut(ember[1])
    w.knockOut(ember[2])
    w.knockOut(azure[0])
    w.equipment[azure[1]].lives = 0 # alive, no spare lives: not out
    check w.teamCogsOut(0) == 3
    check w.teamCogsOut(1) == 1
    w.idle(GloryBehindCogsTicks)
    let cogs = w.awards(gloryBehindCogs)
    check cogs.len == 1
    check cogs[0].team == 0
    check cogs[0].amount == 2

  test "behind_cogs and behind_cogs_seconds come from the glory config":
    configureGlory(parseGloryConfig(parseJson("""{"behind_cogs": 5, "behind_cogs_seconds": 2}""")))
    var w = newWorld(2026)
    w.pickups.setLen(0)
    w.knockOut(seats(1)[0])
    w.idle(2*TickRate-1)
    check w.awards(gloryBehindCogs).len == 0
    w.idle(1)
    let cogs = w.awards(gloryBehindCogs)
    check cogs.len == 1
    check cogs[0].team == 1
    check cogs[0].amount == 5

  test "rules 46 pays nothing for cogs out":
    visionRulesVersion = 46
    replayRulesVersion = 46
    var w = newWorld(2026)
    w.pickups.setLen(0)
    w.knockOut(seats(0)[0])
    w.idle(2*GloryBehindCogsTicks)
    check w.awards(gloryBehindCogs).len == 0
    check w.awards(gloryBehindLives).len == 1 # lives still pay (awards are kept four seconds)

  test "a rules 47 recording keeps its behind-in-cogs awards through a replay":
    let g = parseGloryConfig(parseJson("""{"behind_cogs": 7, "behind_cogs_seconds": 1}"""))
    configureGlory(g)
    recording = Recording(seed: 2026, endTick: HeartMeterMatchTicks, map: mapName(),
      vision: visionMode(), glory: g)
    world = newWorld(recording.seed, recording.endTick)
    var commands: array[LegacySeats, Command]
    for tick in 0..<120:
      world.step(commands)
      recording.frames.add Frame(commands: @(commands), hash: world.stateHash())
    let path = getTempDir()/"paintbot-glory-cogs.replay"
    defer: removeFile(path)
    saveRecording(path, recording)
    check loadReplayFileHeader(path).gameVersion == 47
    configureGlory(DefaultGloryConfig)
    let loaded = loadRecording(path)
    check loaded.glory == g
    check gloryRules() == g
    var again = newWorld(loaded.seed, loaded.endTick)
    for f in loaded.frames:
      again.step(f.commands)
      check again.stateHash() == f.hash

  test "rules 43-46 recordings keep their format and load with the default cogs award":
    for rules in [43, 45, 46]:
      checkpoint "rules " & $rules
      visionRulesVersion = rules
      replayRulesVersion = rules
      let g = parseGloryConfig(parseJson("""{"behind_lives": 5, "quiet_supplies_seconds": 1}"""))
      configureGlory(g)
      recording = Recording(seed: 2026, endTick: HeartMeterMatchTicks, map: mapName(),
        vision: visionMode(), glory: g)
      world = newWorld(recording.seed, recording.endTick)
      var commands: array[LegacySeats, Command]
      for tick in 0..<48:
        world.step(commands)
        recording.frames.add Frame(commands: @(commands), hash: world.stateHash())
      let path = getTempDir()/("paintbot-glory-cogs-" & $rules & ".replay")
      defer: removeFile(path)
      saveRecording(path, recording)
      check loadReplayFileHeader(path).gameVersion == rules.uint16
      configureGlory(DefaultGloryConfig)
      let loaded = loadRecording(path)
      check loaded.glory.behindLives == 5
      check loaded.glory.quietSupplySeconds == 1
      check loaded.glory.behindCogs == DefaultGloryConfig.behindCogs
      var again = newWorld(loaded.seed, loaded.endTick)
      for f in loaded.frames:
        again.step(f.commands)
        check again.stateHash() == f.hash
