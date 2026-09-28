## FFA-kin recordings are stamped 1000 + rules and carry the mode and the match's kinship, so a
## replay rebuilds the recorded families and verifies every hash. Teams recordings are unchanged.
import std/[unittest, os]
import polyworld/[cli, tapes]
import ../examples/paintbot/[sim, game, bots, kinship]

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"

proc record(ticks: int32): Recording =
  ## A live match driven by 16 base.bas seats, recorded the way game.advance records it.
  var players = loadBots(@[BotGroup(path: Base, count: Seats)])
  world = newWorld(2026, ticks)
  result = Recording(seed: 2026, endTick: world.endTick)
  while world.winner == -1:
    let commands = players.decide(world)
    deliverSpeech(world)
    world.step(commands)
    result.frames.add Frame(commands: commands, hash: world.stateHash())
  for slot in 0..<Seats: doAssert not players[slot].failed, "seat " & $slot & " failed"

suite "FFA-kin replay payload":
  setup:
    visionRulesVersion = 40
    replayRulesVersion = 40
    replayMode = false
  teardown:
    gameMode = gmTeams
    kinshipOverride = none(Kinship)
    replayMode = false

  test "an FFA recording saves as 1040, round-trips its kinship and replays hash for hash":
    let path = getTempDir() / "paintbot-ffa-replay-test.replay"
    defer: removeFile(path)
    gameMode = gmFfaKin
    let played = kinshipFor(klCousins, 9) # an override, so the seed's sample would be wrong
    kinshipOverride = some(played)
    let original = record(240)
    check original.frames.len == 240
    check world.winner == -3
    check world.matchOutcome() == "ended"
    recording = original
    saveRecording(path, recording)
    check loadReplayFileHeader(path).gameVersion == 1040
    # Forget everything the loader must restore.
    gameMode = gmTeams
    kinshipOverride = none(Kinship)
    activeKinship = sampleKinship(1)
    visionRulesVersion = 39
    let loaded = loadRecording(path)
    check gameMode == gmFfaKin
    check replayRulesVersion == 40
    check visionRulesVersion == 40
    check activeKinship == played
    check loaded.seed == original.seed
    check loaded.endTick == original.endTick
    check loaded.frames == original.frames
    # Replay through game.advance, which checks every frame's hash and refuses frames after
    # the end; the final frame ends the match with winner -3.
    recording = loaded
    replayMode = true
    world = newWorld(recording.seed, recording.endTick)
    check activeKinship == played
    while world.tick < recording.frames.len and world.winner == -1: advance()
    check world.tick == 240
    check world.winner == -3
    check world.stateHash() == original.frames[^1].hash
    advance() # past the last frame: a no-op, not "frames after victory"
    check world.tick == 240

  test "a teams recording still saves as version 40 with the old type":
    let path = getTempDir() / "paintbot-teams-replay-test.replay"
    defer: removeFile(path)
    gameMode = gmTeams
    world = newWorld(2026, 14400)
    recording = Recording(seed: 2026, endTick: world.endTick)
    var commands: array[Seats, Command]
    for tick in 0..<24:
      world.step(commands)
      recording.frames.add Frame(commands: commands, hash: world.stateHash())
    saveRecording(path, recording)
    check loadReplayFileHeader(path).gameVersion == 40
    check loadReplayFile(path, "paintbot_pw", 40, Recording).frames == recording.frames
    kinshipOverride = some(kinshipFor(klClones, 1))
    gameMode = gmFfaKin
    check loadRecording(path).frames == recording.frames
    check gameMode == gmTeams
    check kinshipOverride.isNone
    check world.matchOutcome() == "time_limit"

  test "FFA replays with an unknown rules number or a corrupt kinship are refused":
    let path = getTempDir() / "paintbot-ffa-bad-replay-test.replay"
    defer: removeFile(path)
    let k = kinshipFor(klFours, 3)
    var bad = RecordingFfa(seed: 1, endTick: 240, mode: 1, layout: k.layout.uint8,
      family: k.family, genes: k.genes, ibd: k.ibd)
    saveReplayFile(path, "paintbot_pw", 1039, bad)
    expect ReplayError: discard loadRecording(path)
    bad.ibd[0][1] = 33
    saveReplayFile(path, "paintbot_pw", 1040, bad)
    expect ReplayError: discard loadRecording(path)
    bad.ibd = k.ibd
    bad.layout = 9
    saveReplayFile(path, "paintbot_pw", 1040, bad)
    expect ReplayError: discard loadRecording(path)
    bad.layout = k.layout.uint8
    template refused(field, value: untyped) =
      ## One corrupt field, restored afterwards, must make the loader refuse the replay.
      let saved = field
      field = value
      saveReplayFile(path, "paintbot_pw", 1040, bad)
      expect ReplayError: discard loadRecording(path)
      field = saved
    refused(bad.mode, 0'u8) # a teams mode inside an FFA payload
    refused(bad.mode, 2'u8)
    refused(bad.family[4], 16'i8) # family ids are -1 (loner) or 0..15
    refused(bad.family[4], -2'i8)
    refused(bad.ibd[3][3], 31'i8) # r_ii must be 1
    refused(bad.ibd[2][5], (if k.ibd[2][5] == 0: 8'i8 else: 0'i8)) # asymmetric
    refused(bad.ibd[7][1], -1'i8)
    saveReplayFile(path, "paintbot_pw", 1040, bad)
    check loadRecording(path).endTick == 240
    check activeKinship == k

  test "a live match after an FFA replay load draws its own kinship":
    let path = getTempDir() / "paintbot-ffa-override-test.replay"
    defer: removeFile(path)
    let k = kinshipFor(klPairs, 5)
    saveReplayFile(path, "paintbot_pw", 1040, RecordingFfa(seed: 1, endTick: 240, mode: 1,
      layout: k.layout.uint8, family: k.family, genes: k.genes, ibd: k.ibd))
    discard loadRecording(path)
    check kinshipOverride == some(k) # replay analysis rebuilds the recorded world from it
    check newWorld(1, 240).spawnAnchor == newWorld(1, 240).spawnAnchor
    check activeKinship == k
    # game.setup's live branch builds its world with newLiveWorld, which drops the override.
    let live = newLiveWorld(77, 240)
    check kinshipOverride.isNone
    check activeKinship == sampleKinship(77)
    check live.endTick == 240
