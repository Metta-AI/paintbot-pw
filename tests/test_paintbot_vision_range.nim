## The "vision_range" match config: per-cog sight lines reach at most that many metres, in the
## teams game and FFA-kin, at any rules. Beyond it no cog or pickup is visible; within it every
## answer is the unlimited one. Absent, nothing changes (a recording made before the key existed
## loads and re-saves byte for byte); a ranged recording carries its range through a replay.
import std/[unittest, os, json, options, strutils]
import polyworld/[cli, tapes]
import ../examples/paintbot/[sim, game, bots, kinship]

type Ranged = object
  ## game.nim's RecordingRanged, field for field.
  recording: Recording
  visionRange: int32

const
  Root = currentSourcePath().parentDir.parentDir
  Base = Root / "coworld/paintbot/players/base.bas"

proc resetThread() =
  gameMode = gmTeams
  kinshipOverride = none(Kinship)
  kinLayoutPin = none(KinLayout)
  replayRulesVersion = LiveRules
  visionRulesVersion = LiveRules
  configureMap(""); configureVision(""); configureVisionRange(0); configureGlory(DefaultGloryConfig)

proc configError(text: string): string =
  try:
    discard parseMatchConfig(parseJson(text))
  except ValueError as e:
    return e.msg

proc scatter(w: var World, tick: int): seq[Command] =
  ## Every seat roams to a spot drawn from the tick, aiming where it goes.
  result = newSeq[Command](Seats)
  for i in 0..<Seats:
    let x = minX()+300+((i*7919+tick*104729) mod (maxX()-minX()-600))
    let z = minZ()+300+((i*6271+tick*15485863) mod (maxZ()-minZ()-600))
    result[i] = Command(walk: true, goal: point(x, z), aim: point(x, z))

suite "Vision range config":
  teardown: resetThread()

  test "valid values, absent and null":
    check parseMatchConfig(parseJson("{}")).visionRange == 0
    check parseMatchConfig(parseJson("""{"vision_range": null}""")).visionRange == 0
    for n in [1, 20, 200]:
      check parseMatchConfig(parseJson("""{"vision_range": $1}""" % $n)).visionRange == n
    check parseMatchConfig(parseJson("""{"mode": "ffa_kin", "vision_range": 20}""")).visionRange == 20
    check parseMatchConfig(parseJson("""{"vision": "", "vision_range": 20}""")).visionRange == 20
    check "vision_range" in MatchConfigKeys

  test "invalid values and team vision are refused":
    for bad in ["0", "201", "-20", "\"20\"", "20.5", "true", "[20]", "{}"]:
      checkpoint bad
      check configError("""{"vision_range": $1}""" % bad) ==
        "Paintbot vision_range must be an integer 1..200 (metres)"
    check configError("""{"vision": "team", "vision_range": 20}""") ==
      "Paintbot vision_range applies to per-cog vision only, not \"vision\": \"team\""
    expect ValueError: configureVisionRange(-1)
    expect ValueError: configureVisionRange(201)
    check visionRangeMetres() == 0

  test "the host's config path reads it":
    applyGameConfig("""{"vision_range": 20}""")
    check visionRangeChoice == 20
    applyGameConfig("""{}""")
    check visionRangeChoice == 0
    expect ValueError: applyGameConfig("""{"vision_range": 0}""")

suite "Vision range sight lines":
  teardown: resetThread()

  for (mode, rules) in [(gmTeams, LiveRules), (gmTeams, 40), (gmFfaKin, LiveRules)]:
    for metres in [5, 20]:
      test $mode & " rules " & $rules & ", " & $metres & " m: beyond is unseen, within is unchanged":
        resetThread()
        gameMode = mode
        visionRulesVersion = rules
        configureRules(rules)
        var w = newWorld(2026)
        let limit = int64(metres*100)*int64(metres*100)
        var beyond, within, pickupsBeyond = 0
        for tick in 0..<720:
          w.step(w.scatter(tick div 90))
          if tick mod 60 != 59: continue
          for slot in 0..<Seats:
            for other in 0..<Seats:
              configureVisionRange(0)
              let unlimited = w.visible(slot, other)
              configureVisionRange(metres)
              let ranged = w.visible(slot, other)
              let far = distance2(w.cogs[slot].pos, w.cogs[other].pos) > limit
              if slot == other or far == false: check ranged == unlimited
              else: check not ranged
              if slot != other and unlimited:
                if far: inc beyond else: inc within
            for pk in w.pickups:
              configureVisionRange(0)
              let unlimited = w.canSeePoint(slot, pk.pos)
              configureVisionRange(metres)
              let far = distance2(w.cogs[slot].pos, pk.pos) > limit
              check w.canSeePoint(slot, pk.pos) == (unlimited and not far)
              if unlimited and far: inc pickupsBeyond
        # Not vacuous: unlimited sight saw cogs on both sides of the line, and pickups beyond it.
        checkpoint "beyond " & $beyond & " within " & $within & " pickups beyond " & $pickupsBeyond
        check beyond > 0 and within > 0 and pickupsBeyond > 0

  test "BASIC players play as before when the range covers the map, and differently at 20 m":
    proc play(metres: int): seq[uint32] =
      resetThread()
      configureVisionRange(metres)
      var w = newLiveWorld(9100, 600)
      let players = loadBots(@[BotGroup(path: Base, count: Seats)])
      while w.winner == -1 and w.tick < 600:
        let commands = players.decide(w)
        deliverSpeech(w)
        w.step(commands)
        result.add w.stateHash()
    let unlimited = play(0)
    check play(200) == unlimited # Heartwick is 64 m x 40 m
    check play(20) != unlimited

suite "Vision range recordings":
  teardown: resetThread()

  for mode in [gmTeams, gmFfaKin]:
    test $mode & ": a ranged recording keeps its range through a replay":
      resetThread()
      gameMode = mode
      configureVisionRange(20)
      recording = Recording(seed: 2027, endTick: HeartMeterMatchTicks, map: mapName(),
        vision: visionMode(), seats: Seats.int32, names: newSeq[string](Seats))
      world = newLiveWorld(recording.seed, recording.endTick)
      let players = loadBots(@[BotGroup(path: Base, count: Seats)])
      for tick in 0..<240:
        let commands = players.decide(world)
        deliverSpeech(world)
        world.step(commands)
        recording.frames.add Frame(commands: commands, hash: world.stateHash())
      let path = getTempDir()/"paintbot-vision-range.replay"
      defer: removeFile(path)
      saveRecording(path, recording)
      check loadReplayFileHeader(path).gameVersion.int ==
        VisionRangeReplayVersionBase + (if mode == gmFfaKin: FfaReplayVersionBase else: 0) + LiveRules
      resetThread()
      let loaded = loadRecording(path)
      check gameMode == mode
      check replayRulesVersion == LiveRules
      check visionRangeMetres() == 20
      check loaded.frames.len == 240
      var again = newWorld(loaded.seed, loaded.endTick)
      for f in loaded.frames:
        again.step(f.commands)
        check again.stateHash() == f.hash
      # And through the viewer's path (game.setup's replay branch, then advance).
      resetThread()
      recording = loadRecording(path)
      check visionRangeMetres() == 20
      replayMode = true
      world = newWorld(recording.seed, recording.endTick)
      while world.tick < recording.frames.len and world.winner == -1: advance()
      replayMode = false
      check world.tick == 240
      check world.stateHash() == loaded.frames[^1].hash

  test "a ranged recording needs rules 48 on, and a bad stored range is refused":
    let r = Recording(seed: 1, endTick: 100, seats: Seats.int32)
    let path = getTempDir()/"paintbot-vision-range-bad.replay"
    defer: removeFile(path)
    configureVisionRange(20)
    expect ReplayError: saveRecordingAs(path, 47, r)
    expect ReplayError: saveRecordingAs(path, 43, r)
    # Ranged headers below rules 48, and ranges outside 1..200, do not load.
    configureVisionRange(0)
    for (version, metres) in [(VisionRangeReplayVersionBase+47, 20'i32),
        (VisionRangeReplayVersionBase+LiveRules, 0'i32), (VisionRangeReplayVersionBase+LiveRules, 201'i32)]:
      checkpoint $version & " " & $metres
      saveReplayFile(path, "paintbot_pw", version.uint16, Ranged(recording: r, visionRange: metres))
      expect ReplayError: discard loadRecording(path)
    saveReplayFile(path, "paintbot_pw", uint16(VisionRangeReplayVersionBase+LiveRules),
      Ranged(recording: r, visionRange: 20))
    check loadRecording(path).seed == 1 and visionRangeMetres() == 20

  test "a rules-48 teams recording made before vision_range loads, replays and re-saves byte for byte":
    # Recorded on origin/main ab7ce33 (rules 48, before vision_range): 16 seats walking to the
    # enemy home, every third shooting, seed 2048, 48 ticks, gameVersion 48. Never re-record it.
    let path = Root / "tests/data/paintbot_teams_48.replay"
    check loadReplayFileHeader(path).gameVersion == 48
    configureVisionRange(20)
    let loaded = loadRecording(path)
    check visionRangeMetres() == 0
    check loaded.frames.len == 48
    var again = newWorld(loaded.seed, loaded.endTick)
    for f in loaded.frames:
      again.step(f.commands)
      check again.stateHash() == f.hash
    let copy = getTempDir()/"paintbot-teams-48-copy.replay"
    defer: removeFile(copy)
    # The recording as it was made (no names: the loader fills in defaults), saved now.
    saveRecording(copy, Recording(seed: loaded.seed, endTick: loaded.endTick, map: loaded.map,
      vision: loaded.vision, seats: loaded.seats, frames: loaded.frames))
    check readFile(copy) == readFile(path)

  test "an FFA recording made before vision_range loads unranged":
    configureVisionRange(20)
    let loaded = loadRecording(Root / "tests/data/paintbot_ffa_1047.replay")
    check gameMode == gmFfaKin
    check loaded.frames.len == 300 and visionRangeMetres() == 0
