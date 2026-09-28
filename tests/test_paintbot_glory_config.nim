## Rules 43: the glory awards come from the Coworld config's "glory" object, and teams
## recordings carry them so replays pay the same awards.
import std/[json, os, unittest]
import polyworld/[cli, tapes]
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

suite "Configurable glory awards (rules 43)":
  setup:
    visionRulesVersion = 43
    replayRulesVersion = 43
    gameMode = gmTeams
    configureMap("")
    configureVision("")
    configureGlory(DefaultGloryConfig)

  test "absent or empty glory keeps the defaults":
    check parseGloryConfig(nil) == DefaultGloryConfig
    check parseGloryConfig(newJNull()) == DefaultGloryConfig
    check parseGloryConfig(parseJson("{}")) == DefaultGloryConfig
    check DefaultGloryConfig == GloryConfig(quietSupplies: 10, quietSupplySeconds: 30,
      behindLives: 1, behindLivesSeconds: 5, heart: 20)

  test "each key overrides one award and leaves the others":
    let g = parseGloryConfig(parseJson("""{"behind_lives": 5}"""))
    check g.behindLives == 5
    check g.quietSupplies == GloryQuietSupplies
    check g.behindLivesSeconds == 5
    check g.heart == GloryHeartAward
    let all = parseGloryConfig(parseJson("""{"quiet_supplies": 0, "quiet_supplies_seconds": 12,
      "behind_lives": 3, "behind_lives_seconds": 2, "heart": 50}"""))
    check all == GloryConfig(quietSupplies: 0, quietSupplySeconds: 12, behindLives: 3,
      behindLivesSeconds: 2, heart: 50)

  test "bad glory configs are refused":
    for text in ["""[]""", """{"behind": 5}""", """{"behind_lives": 1.5}""",
        """{"behind_lives": "5"}""", """{"behind_lives": -1}""", """{"behind_lives": 1001}""",
        """{"behind_lives_seconds": 0}""", """{"quiet_supplies_seconds": 601}"""]:
      expect ValueError:
        discard parseGloryConfig(parseJson(text))

  test "the game config reads glory for teams and refuses it in FFA-kin":
    applyGameConfig("""{"glory": {"behind_lives": 5}}""")
    check gloryChoice.behindLives == 5
    applyGameConfig("""{}""")
    check gloryChoice == DefaultGloryConfig
    expect ValueError:
      applyGameConfig("""{"mode": "ffa_kin", "glory": {"behind_lives": 5}}""")
    gameMode = gmTeams

  test "behind_lives scales the award per missing life":
    configureGlory(parseGloryConfig(parseJson("""{"behind_lives": 5}""")))
    var w = newWorld(2026)
    w.pickups.setLen(0)
    w.equipment[firstSeat(0)].lives -= 3
    w.idle(GloryBehindLivesTicks)
    let awards = w.behindAwards
    check awards.len == 1
    check awards[0].team == 0
    check awards[0].amount == 15
    check w.glory == [595'i32 + 15, 595'i32]

  test "behind_lives_seconds sets the period":
    configureGlory(parseGloryConfig(parseJson("""{"behind_lives_seconds": 2}""")))
    var w = newWorld(2026)
    w.pickups.setLen(0)
    w.equipment[firstSeat(1)].lives -= 1
    w.idle(2*TickRate-1)
    check w.behindAwards.len == 0
    w.idle(1)
    check w.behindAwards.len == 1
    check w.behindAwards[0].team == 1

  test "quiet_supplies and its period are configurable":
    configureGlory(parseGloryConfig(parseJson("""{"quiet_supplies": 7, "quiet_supplies_seconds": 3}""")))
    var w = newWorld(2026)
    w.pickups.setLen(0)
    w.idle(3*TickRate)
    check w.glory == [597'i32 + 7, 597'i32 + 7]

  test "a teams recording keeps its glory awards through a replay":
    let g = parseGloryConfig(parseJson("""{"quiet_supplies": 7, "quiet_supplies_seconds": 1}"""))
    configureGlory(g)
    recording = Recording(seed: 2026, endTick: HeartMeterMatchTicks, map: mapName(),
      vision: visionMode(), glory: g)
    world = newWorld(recording.seed, recording.endTick)
    var commands: array[Seats, Command]
    for tick in 0..<240:
      world.step(commands)
      recording.frames.add Frame(commands: commands, hash: world.stateHash())
    let path = getTempDir()/"paintbot-glory-config.replay"
    defer: removeFile(path)
    saveRecording(path, recording)
    check loadReplayFileHeader(path).gameVersion == 43
    configureGlory(DefaultGloryConfig)
    let loaded = loadRecording(path)
    check loaded.glory == g
    check gloryRules() == g
    var again = newWorld(loaded.seed, loaded.endTick)
    for f in loaded.frames:
      again.step(f.commands)
      check again.stateHash() == f.hash
    # The awards are part of the replay: the default awards do not reproduce it.
    configureGlory(DefaultGloryConfig)
    var wrong = newWorld(loaded.seed, loaded.endTick)
    var mismatch = false
    for f in loaded.frames:
      wrong.step(f.commands)
      if wrong.stateHash() != f.hash: mismatch = true
    check mismatch

  test "rules 42 recordings load with the default awards":
    visionRulesVersion = 42
    replayRulesVersion = 42
    configureGlory(parseGloryConfig(parseJson("""{"behind_lives": 5}""")))
    recording = Recording(seed: 2026, endTick: HeartMeterMatchTicks, map: mapName(),
      vision: visionMode(), glory: gloryRules())
    world = newWorld(recording.seed, recording.endTick)
    var commands: array[Seats, Command]
    for tick in 0..<24:
      world.step(commands)
      recording.frames.add Frame(commands: commands, hash: world.stateHash())
    let path = getTempDir()/"paintbot-glory-config-42.replay"
    defer: removeFile(path)
    saveRecording(path, recording)
    check loadReplayFileHeader(path).gameVersion == 42
    let loaded = loadRecording(path)
    check loaded.glory == DefaultGloryConfig
    check gloryRules() == DefaultGloryConfig
