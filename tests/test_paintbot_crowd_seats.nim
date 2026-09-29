## Crowd builds (-d:pwSeats=50, Heartland Big): 10 tribes of 5 siblings play FFA-kin with the
## baseline ffa.bas on big-twin-mesas. Run with `nim r -d:pwSeats=50`; a 16-seat build skips.
import std/[unittest, os, options]
import polyworld/[cli, tapes]
import ../examples/paintbot/[sim, game, bots, kinship]

const Root = currentSourcePath().parentDir.parentDir
const Ffa = Root / "coworld/paintbot/players/ffa.bas"
const Ticks = 240'i32

when Seats != 50:
  echo "test_paintbot_crowd_seats: build with -d:pwSeats=50 (this is a ", Seats, "-seat build); skipped"
else:
  suite "Heartland Big crowd: 50 seats, 10 tribes of 5":
    setup:
      visionRulesVersion = 45
      replayRulesVersion = 45
      replayMode = false
      gameMode = gmFfaKin
      kinshipOverride = none(Kinship)
      kinLayoutPin = some(klTribes)
    teardown:
      configureMap("")
      gameMode = gmTeams
      kinLayoutPin = none(KinLayout)

    test "tribes are ten families of five full siblings":
      for seed in [1'i32, 7, 2026]:
        let k = kinshipFor(klTribes, seed)
        var sizes = newSeq[int](Seats)
        for i in 0..<Seats:
          check k.family[i] in 0'i8..9'i8
          inc sizes[k.family[i]]
          for j in 0..<Seats:
            let expected = if i == j: 100 elif k.family[i] == k.family[j]: 50 else: 0
            check k.rPercent(i, j) == expected.int32
        check sizes[0..9] == @[5, 5, 5, 5, 5, 5, 5, 5, 5, 5]

    test "a 50-seat match plays on big-twin-mesas and replays hash for hash":
      configureMap("big-twin-mesas")
      var players = loadBots(@[BotGroup(path: Ffa, count: Seats)])
      world = newLiveWorld(2026, Ticks)
      check activeKinship.layout == klTribes
      var recording = Recording(seed: 2026, endTick: world.endTick, map: mapName())
      for i in 0..<Seats:
        check not world.blocked(world.cogs[i].pos)
        check world.cogs[i].pos.x.int in minX()..maxX() and world.cogs[i].pos.z.int in minZ()..maxZ()
      for tick in 0..<Ticks:
        let commands = players.decide(world)
        deliverSpeech(world)
        world.step(commands)
        recording.frames.add Frame(commands: commands, hash: world.stateHash())
      for slot in 0..<Seats: check not players[slot].failed
      let path = getTempDir() / "paintbot-crowd-seats.replay"
      defer: removeFile(path)
      game.recording = recording
      saveRecording(path, game.recording)
      check ReplayGame == "paintbot_pw_s50"
      check loadReplayFileHeader(path).game == "paintbot_pw_s50"
      gameMode = gmTeams
      kinLayoutPin = none(KinLayout)
      configureMap("")
      let loaded = loadRecording(path)
      check gameMode == gmFfaKin
      check activeKinship.layout == klTribes
      check loaded.map == "big-twin-mesas"
      var again = newWorld(loaded.seed, loaded.endTick)
      for f in loaded.frames:
        again.step(f.commands)
        check again.stateHash() == f.hash
