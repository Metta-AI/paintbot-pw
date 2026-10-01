## The seat count is per match (configureSeats), not per build: one engine plays teams and
## FFA-kin matches of any size from 2 to MaxSeats, records the count (rules 46) and replays them
## hash for hash. Heartland Big is 50 seats in 10 tribes of 5.
import std/[unittest, os, options]
import polyworld/[cli, tapes]
import ../examples/paintbot/[sim, game, bots, kinship]

const
  Root = currentSourcePath().parentDir.parentDir
  Base = Root / "coworld/paintbot/players/base.bas"
  Jev = Root / "coworld/paintbot/players/jev.bas"
  Ffa = Root / "coworld/paintbot/players/ffa.bas"
  Ticks = 240'i32

proc play(seats: int, script, map: string): Recording =
  ## A live match of `seats` seats on `map`, recorded the way game.advance records it.
  configureSeats(seats)
  configureMap(map)
  var players = loadBots(@[BotGroup(path: script, count: seats)])
  world = newLiveWorld(2026, Ticks)
  check world.cogs.len == seats
  result = Recording(seed: 2026, endTick: world.endTick, map: mapName(), seats: seats.int32,
    names: newSeq[string](seats))
  for i in 0..<seats:
    check not world.blocked(world.cogs[i].pos)
    check world.cogs[i].pos.x.int in minX()..maxX() and world.cogs[i].pos.z.int in minZ()..maxZ()
  for tick in 0..<Ticks:
    let commands = players.decide(world)
    check commands.len == seats
    deliverSpeech(world)
    world.step(commands)
    result.frames.add Frame(commands: commands, hash: world.stateHash())
  for slot in 0..<seats: check not players[slot].failed

proc replays(original: Recording, name: string) =
  let path = getTempDir() / ("paintbot-seat-counts-" & name & ".replay")
  defer: removeFile(path)
  recording = original
  saveRecording(path, recording)
  check loadReplayFileHeader(path).gameVersion.int == (if ffa(): FfaReplayVersionBase else: 0) + LiveRules
  let mode = gameMode
  gameMode = gmTeams
  kinshipOverride = none(Kinship)
  configureSeats(LegacySeats)
  configureMap("")
  let loaded = loadRecording(path)
  check gameMode == mode
  check loaded.seats == original.seats
  check Seats == original.seats.int
  check loaded.names.len == Seats
  var again = newWorld(loaded.seed, loaded.endTick)
  check again.cogs.len == Seats
  for f in loaded.frames:
    again.step(f.commands)
    check again.stateHash() == f.hash

suite "Paintbot seat counts are per match":
  setup:
    visionRulesVersion = LiveRules
    replayRulesVersion = LiveRules
    replayMode = false
    kinshipOverride = none(Kinship)
    kinLayoutPin = none(KinLayout)
    gameMode = gmTeams
  teardown:
    configureSeats(LegacySeats)
    configureMap("")
    gameMode = gmTeams
    kinshipOverride = none(Kinship)
    kinLayoutPin = none(KinLayout)

  test "tribes fill the seats with families of five full siblings":
    for seats in [50, 100, 16]:
      configureSeats(seats)
      let k = kinshipFor(klTribes, 7)
      check k.family.len == seats
      var sizes = newSeq[int](seats)
      var loners = 0
      for i in 0..<seats:
        if k.family[i] < 0: inc loners
        else: inc sizes[k.family[i]]
        for j in 0..<seats:
          let expected = if i == j: 100'i32
            elif k.family[i] >= 0 and k.family[i] == k.family[j]: 50'i32
            else: 0'i32
          check k.rPercent(i, j) == expected
      var tribes: seq[int]
      for size in sizes:
        if size > 0: tribes.add size
      check tribes.len == seats div TribeSize
      for size in tribes: check size == TribeSize
      check loners == seats mod TribeSize

  for (seats, map) in [(8, ""), (16, ""), (50, "big-twin-mesas")]:
    test "teams with " & $seats & " seats play and replay":
      replays(play(seats, Base, map), "teams-" & $seats)

  test "Jev with eight seats plays and replays":
    replays(play(8, Jev, ""), "jev-8")

  for (seats, map) in [(50, "big-twin-mesas"), (100, "big-twin-mesas")]:
    test "Heartland with " & $seats & " seats in tribes plays and replays":
      gameMode = gmFfaKin
      kinLayoutPin = some(klTribes)
      let original = play(seats, Ffa, map)
      check activeKinship.layout == klTribes
      check activeKinship.family.len == seats
      replays(original, "ffa-" & $seats)

  test "a recording before rules 46 must hold 16 seats":
    let original = play(8, Base, "")
    replayRulesVersion = 45
    let path = getTempDir() / "paintbot-seat-counts-45.replay"
    defer: removeFile(path)
    recording = original
    expect ReplayError: saveRecording(path, recording)
