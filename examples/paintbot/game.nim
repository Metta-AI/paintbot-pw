import std/[os, strutils]
import jsony
import polyworld/[cli, tapes]
import sim, bots, controls
when defined(coworld): import polyworld/coworld

type
  Frame* = object
    commands*: array[Seats, Command]
    hash*: uint32
  LegacyCommand = object
    walk, shoot, direct: bool
    goal, aim: Point
  LegacyFrame = object
    commands: array[Seats, LegacyCommand]
    hash: uint32
  LegacyRecording = object
    seed*: int32
    frames*: seq[LegacyFrame]
  Communication* = object
    tick*, slot*: int
    text*: string
  PreSoundCommand = object
    walk, shoot, direct: bool
    goal, aim: Point
    chargeGrenade: bool
  PreSoundFrame = object
    commands: array[Seats, PreSoundCommand]
    hash: uint32
  PriorRecording = object
    seed*: int32
    frames*: seq[PreSoundFrame]
    names*: array[Seats, string]
    communications*: seq[Communication]
  PreSoundRecording = object
    seed: int32
    frames: seq[PreSoundFrame]
    names: array[Seats, string]
    communications: seq[Communication]
    endTick: int32
  Recording* = object
    seed*: int32
    frames*: seq[Frame]
    names*: array[Seats, string]
    communications*: seq[Communication]
    endTick*: int32
type LegacyMetadataRecording = object
  seed: int32
  frames: seq[LegacyFrame]
  names: array[Seats, string]
  communications: seq[Communication]
proc convertFrames(frames: seq[LegacyFrame]): seq[Frame] =
  for f in frames:
    var next = Frame(hash: f.hash)
    for i, c in f.commands:
      next.commands[i] = Command(walk: c.walk, shoot: c.shoot, direct: c.direct,
          goal: c.goal, aim: c.aim)
    result.add next
proc convertFrames(frames: seq[PreSoundFrame]): seq[Frame] =
  for f in frames:
    var next = Frame(hash: f.hash)
    for i, c in f.commands:
      next.commands[i] = Command(walk: c.walk, shoot: c.shoot, direct: c.direct,
        goal: c.goal, aim: c.aim, chargeGrenade: c.chargeGrenade)
    result.add next
var replayRulesVersion* = 28
proc loadRecording*(path: string): Recording =
  replayRulesVersion = loadReplayFileHeader(path).gameVersion.int
  visionRulesVersion = replayRulesVersion
  if replayRulesVersion == 1:
    let old = loadReplayFile(path, "paintbot_pw", 1, LegacyRecording)
    result.seed = old.seed
    result.frames = convertFrames(old.frames)
  elif replayRulesVersion in [2, 3, 4, 5]:
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, LegacyMetadataRecording)
    result = Recording(seed: old.seed, frames: convertFrames(old.frames),
        names: old.names, communications: old.communications)
  elif replayRulesVersion in [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]:
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, PriorRecording)
    result = Recording(seed:old.seed,frames:convertFrames(old.frames),names:old.names,communications:old.communications)
  elif replayRulesVersion in [23, 24, 25]:
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, PreSoundRecording)
    result = Recording(seed:old.seed,frames:convertFrames(old.frames),names:old.names,
      communications:old.communications,endTick:old.endTick)
  elif replayRulesVersion in [26, 27, 28]:
    result = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, Recording)
  else:
    raise newException(ReplayError, "Unsupported Paintbot replay version")
  if replayRulesVersion < 23: result.endTick = MatchTicks
  elif result.endTick <= 0 or result.endTick > 28800:
    raise newException(ReplayError, "Invalid match duration")
  if result.frames.len > 28800 or result.communications.len > 20000:
    raise newException(ReplayError, "Replay limits exceeded")
  for i in 0..<Seats:
    if result.names[i].len == 0: result.names[i] = (if team(i) ==
        0: "Ember" else: "Azure") & " " & $(i div 2 + 1)
    if result.names[i].len > 256: raise newException(ReplayError, "Invalid player name")
  for item in result.communications:
    if item.slot notin 0..<Seats or item.tick notin 0..result.frames.len or
        item.text.len > 1024:
      raise newException(ReplayError, "Invalid communication")
var
  world*: World
  recording*: Recording
  replayMode*: bool
  options*: GameOptions
  players: array[Seats, Bot]
  bridge: File
proc setup*() =
  when defined(coworld): options = coworldOptions(Seats)
  else:
    options = GameOptions(seed: 2026, maximumTicks: HeartMeterMatchTicks, speed: 1)
    let args = commandLineParams(); var i = 0
    while i < args.len:
      if not options.takeCommonFlag(args, i, args[i]): raise newException(
          ValueError, "Unknown argument: "&args[i])
      inc i
  when not defined(coworld):
    options.validateGameOptions(Seats, "live games require exactly 16 bots")
  replayMode = options.replayPath.len > 0
  if replayMode:
    recording = loadRecording(options.replayPath)
    if recording.frames.len > 28800: raise newException(ValueError, "Replay tick limit exceeded")
    world = newWorld(recording.seed, recording.endTick)
  else:
    world = newWorld(options.seed, options.maximumTicks); recording.seed = options.seed
    recording.endTick = world.endTick
    players = loadBots(options.botGroups, options.playerSlot)
    for i in 0..<Seats:
      recording.names[i] = if i == options.playerSlot-1: "You" else: "Bot " & $(i+1)
    when defined(coworld):
      for i in 0..<min(Seats, config.players.len): recording.names[
          i] = config.players[i].name
    if getEnv("PW_POLICY_FD").len > 0:
      if not open(bridge, FileHandle(parseInt(getEnv("PW_POLICY_FD"))),
          fmReadWrite): raise newException(IOError, "Cannot open policy bridge")
proc advance*() =
  if replayMode or world.tick < recording.frames.len:
    if world.tick >= recording.frames.len: return
    if world.winner != -1: raise newException(ReplayError, "Replay has frames after victory")
    let f = recording.frames[world.tick]
    world.step(f.commands, replayRulesVersion)
    if world.stateHash() != f.hash: raise newException(ReplayError,
        "Replay hash mismatch at " & $world.tick)
  else:
    var commands = players.decide(world)
    flushPlayerCommands(commands, options.playerSlot.int-1)
    for slot, messages in shouts:
      for message in messages:
        if recording.communications.len < 20000:
          recording.communications.add Communication(tick: world.tick+1,
              slot: slot, text: message)
    if bridge != nil:
      let snapshot = world.toJson()
      bridge.writeLine("{\"rulesVersion\":" & $replayRulesVersion & "," &
          "\"heard\":" & heard.toJson() & "," & snapshot[1..^1]); bridge.flushFile()
      let external = bridge.readLine().fromJson(seq[tuple[slot: int,
          command: Command, chat: seq[string]]])
      for item in external:
        if item.slot < 0 or item.slot >= Seats: raise newException(ValueError, "Invalid WASM slot")
        commands[item.slot] = item.command
        shouts[item.slot] = @[]
        for message in item.chat[0..<min(4,item.chat.len)]:
          if message.len > 1024: raise newException(ValueError, "Communication too long")
          shouts[item.slot].add message[0..<min(256,message.len)]
          if recording.communications.len < 20000:
            recording.communications.add Communication(tick: world.tick+1,
                slot: item.slot, text: message)
    deliverSpeech(world)
    world.step(commands)
    recording.frames.add Frame(commands: commands, hash: world.stateHash())
proc runHeadless*() =
  setup()
  let limit = if replayMode: recording.frames.len else: options.maximumTicks.int
  while (world.tick < limit or (not replayMode and replayRulesVersion in 20..22 and limit >= 7200)) and world.winner == -1: advance()
  if replayMode and world.tick != limit: raise newException(ReplayError, "Replay has frames after victory")
  if not replayMode and options.recordPath.len > 0: saveReplayFile(
      options.recordPath, "paintbot_pw", replayRulesVersion.uint16, recording)
  echo "ticks=", world.tick, " captures=", world.captures, " hash=",
      world.stateHash()
  when defined(coworld):
    finishCoworld(NumericCoworldResults[float](scores: world.scores(), ticks: world.tick,
        seed: world.seed, outcome: if world.winner <
        0: "time_limit" else: $world.winner))
