## Heartleaf action-only replay format and playback cursor.
##
## A replay stores accepted villager commands and one canonical simulation
## hash per tick. It never stores bot source or bot identity, so replaying a
## game reveals what was done and never how the deciding program was written.

import
  polyworld/tapes,
  content

const
  ReplayGame* = "heartleaf"
  ReplayFormatVersion* = 1'u16
  ReplayGameVersion* = 3'u16

  ActionMove* = 1'u8
  ActionGather* = 2'u8
  ActionInvite* = 3'u8
  ActionAccept* = 4'u8
  ActionDecline* = 5'u8
  ActionEnterHouse* = 6'u8
  ActionExitHouse* = 7'u8
  ActionStop* = 8'u8
  ActionTalk* = 9'u8
  ActionKindHigh* = ActionTalk

  MaxReplayBytes* = 64 * 1024 * 1024
  MaxReplayActions* = 4_000_000
  MaxReplayHashes* = 10_000_000
  MaxGameTicks* = uint32(gameLengthTicks(MaxDayCount))

type
  Setup* = object
    mapSeed*: int32
    tickRate*: uint16
    gridTiles*: uint16
    decisionTicks*: uint16
    dayCount*: uint16
    maximumTicks*: uint32
    mapHash*: uint64
      ## Fingerprint of the generated village, checked against a fresh
      ## generation at load so a generator change fails by name.
    contentHash*: uint64
      ## Fingerprint of every tuning value, checked the same way.

  ReplayAction* = object
    tick*: uint32
    playerId*: uint8
      ## The acting villager slot, 0 .. 8.
    kind*: uint8
    first*, second*: int32
      ## Payload interpreted per kind:
      ##   Move        x, y
      ##   Gather      garden id, unused
      ##   Invite      target slot, unused
      ##   Accept      host slot, unused
      ##   Decline     host slot, unused
      ##   EnterHouse  house id, unused
      ##   ExitHouse   unused, unused
      ##   Stop        unused, unused
      ##   Talk        target slot, unused

  ReplayHeader* = TapeHeader[Setup]
  ReplayData* = ActionTape[Setup, ReplayAction]
  ReplayRecorder* = TapeRecorder[Setup, ReplayAction]
  ReplayPlayer* = TapePlayer[Setup, ReplayAction]

proc fail(message: string) {.noreturn.} =
  ## Raises one Heartleaf replay error.
  raise newException(ReplayError, message)

proc initReplayData*(setup: Setup): ReplayData =
  ## Creates an empty replay with a versioned deterministic setup.
  initActionTape[Setup, ReplayAction](
    setup,
    ReplayFormatVersion,
    ReplayGameVersion
  )

proc initReplayRecorder*(setup: Setup): ReplayRecorder =
  ## Creates an in-memory recorder for one game.
  initTapeRecorder[Setup, ReplayAction](
    setup,
    ReplayFormatVersion,
    ReplayGameVersion
  )

proc record*(recorder: ReplayRecorder, action: ReplayAction) =
  ## Appends one accepted command in deterministic tick order.
  if recorder == nil:
    return
  if action.kind == 0 or action.kind > ActionKindHigh:
    fail("replay action kind is invalid")
  if int(action.playerId) >= VillagerCount:
    fail("replay action names an unknown villager")
  recorder.data.actions.appendAction(action, MaxReplayActions)

proc recordAction*(
    recorder: ReplayRecorder,
    tick: uint32,
    playerId: int32,
    kind: uint8,
    first = 0'i32,
    second = 0'i32
) =
  ## Records one accepted command without any bot implementation detail.
  recorder.record ReplayAction(
    tick: tick,
    playerId: uint8(playerId),
    kind: kind,
    first: first,
    second: second
  )

proc recordHash*(recorder: ReplayRecorder, hash: uint64) =
  ## Appends the canonical simulation hash for one completed tick.
  recordHash(recorder, hash, MaxReplayHashes)

proc validateSetup(setup: Setup) =
  ## Validates the immutable game description.
  if setup.tickRate != uint16(TickRate):
    fail("replay setup has an unsupported tick rate")
  if setup.gridTiles != uint16(GridSide):
    fail("replay setup has an unsupported map size")
  if setup.decisionTicks != uint16(DecisionTicks):
    fail("replay setup has an unsupported decision interval")
  if setup.dayCount == 0 or setup.dayCount > uint16(MaxDayCount):
    fail("replay setup has an invalid day count")
  if setup.maximumTicks !=
      uint32(gameLengthTicks(int32(setup.dayCount))):
    fail("replay setup duration disagrees with its day count")
  if setup.mapHash == 0:
    fail("replay setup has no deterministic map fingerprint")
  if setup.contentHash == 0:
    fail("replay setup has no deterministic content fingerprint")

proc validateAction(action: ReplayAction, setup: Setup) =
  ## Validates one command's kind, actor, and payload bounds.
  if action.kind == 0 or action.kind > ActionKindHigh:
    fail("replay action kind is invalid")
  if int(action.playerId) >= VillagerCount:
    fail("replay action names an unknown villager")
  if action.tick > setup.maximumTicks:
    fail("replay action exceeds the configured duration")
  if action.tick == 0 or action.tick mod uint32(setup.decisionTicks) != 0:
    fail("replay action did not land on a decision tick")

  case action.kind
  of ActionMove:
    if action.first < 0 or action.first >= GridSide or
        action.second < 0 or action.second >= GridSide:
      fail("replay move names a tile outside the map")
  of ActionGather:
    if action.first < 0 or action.first >= GardenCount:
      fail("replay gather does not name a garden")
  of ActionInvite, ActionAccept, ActionDecline, ActionTalk:
    if action.first < 0 or action.first >= VillagerCount:
      fail("replay action does not name a villager")
    if action.first == int32(action.playerId):
      fail("replay action names the actor itself")
  of ActionEnterHouse:
    if action.first < 0 or action.first >= VillagerCount:
      fail("replay enter does not name a house")
  of ActionExitHouse, ActionStop:
    discard
  else:
    fail("replay action kind is invalid")

proc validate*(data: ReplayData) =
  ## Validates versions, setup bounds, command payloads, and hash coverage.
  data.header.requireTapeVersion(
    ReplayFormatVersion,
    ReplayGameVersion
  )
  let setup = data.header.setup
  setup.validateSetup()
  if data.actions.len > MaxReplayActions:
    fail("replay action limit exceeded")
  if data.hashes.len > MaxReplayHashes:
    fail("replay hash limit exceeded")
  if data.hashes.len > int(setup.maximumTicks):
    fail("replay hashes exceed the configured duration")
  var lastTick = 0'u32
  for index, action in data.actions:
    if action.tick > uint32(data.hashes.len):
      fail("replay action exceeds the recorded duration")
    if index > 0 and action.tick < lastTick:
      fail("replay actions move backward in time")
    action.validateAction(setup)
    lastTick = action.tick

proc encodeReplay*(data: ReplayData): string =
  ## Encodes a validated replay using the shared Flatty envelope.
  data.validate()
  encodeReplayFile(
    ReplayGame,
    ReplayGameVersion,
    data,
    MaxReplayBytes
  )

proc decodeReplay*(bytes: string): ReplayData =
  ## Decodes and validates one replay buffer.
  result = decodeReplayFile(
    ReplayGame,
    ReplayGameVersion,
    bytes,
    ReplayData,
    MaxReplayBytes
  )
  result.validate()

proc saveReplay*(path: string, data: ReplayData) =
  ## Writes one complete replay file.
  data.validate()
  saveReplayFile(
    path,
    ReplayGame,
    ReplayGameVersion,
    data,
    MaxReplayBytes
  )

proc loadReplay*(path: string): ReplayData =
  ## Loads one complete replay file.
  result = loadReplayFile(
    path,
    ReplayGame,
    ReplayGameVersion,
    ReplayData,
    MaxReplayBytes
  )
  result.validate()

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  ## Creates a playback cursor over validated command data.
  data.validate()
  initTapePlayer(data)
