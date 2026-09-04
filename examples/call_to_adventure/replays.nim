## Call to Adventure action-only replay format and playback cursor.

import
  std/os,
  polyworld/pathing,
  polyworld/tapes,
  content

const
  ReplayGame* = "call_to_adventure"
  ReplayFormatVersion* = 1'u16
  ReplayGameVersion* = 14'u16
  ActionWalkTo* = 1'u8
  ActionAttackTarget* = 2'u8
  ActionPickupTarget* = 3'u8
  ActionHealTarget* = 4'u8
  ActionUseItem* = 5'u8
  ActionDropItem* = 6'u8
  ActionKindHigh* = ActionDropItem
  MaxReplayBytes* = 64 * 1024 * 1024
  MaxReplayActions* = 4_000_000
  MaxReplayHashes* = 10_000_000

type
  ReplayAction* = object
    tick*: uint32
    heroId*: int32
    kind*: uint8
    first*, second*, third*: int32
      ## Walk uses level, x, z. Target actions use `first` as the target ID.
      ## Use and drop use `first` as the inventory slot.

  ReplayHeader* = TapeHeader[Setup]
  ReplayData* = ActionTape[Setup, ReplayAction]
  ReplayRecorder* = TapeRecorder[Setup, ReplayAction]
  ReplayPlayer* = TapePlayer[Setup, ReplayAction]

proc fail(message: string) {.noreturn.} =
  ## Raises one Call to Adventure replay error.
  raise newException(ReplayError, message)

proc initReplayData*(setup: Setup): ReplayData =
  ## Creates an empty replay with a versioned deterministic setup.
  initActionTape[Setup, ReplayAction](
    setup,
    ReplayFormatVersion,
    ReplayGameVersion
  )

proc initReplayRecorder*(setup: Setup): ReplayRecorder =
  ## Creates an in-memory bot-command recorder.
  initTapeRecorder[Setup, ReplayAction](
    setup,
    ReplayFormatVersion,
    ReplayGameVersion
  )

proc recordAction*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId: int32,
    kind: uint8,
    first = 0'i32,
    second = 0'i32,
    third = 0'i32
) =
  ## Records one attempted hero command without storing its BASIC source.
  if recorder == nil:
    return
  if kind == 0 or kind > ActionKindHigh:
    fail("replay action kind is invalid")
  recorder.data.actions.appendAction(
    ReplayAction(
      tick: tick,
      heroId: heroId,
      kind: kind,
      first: first,
      second: second,
      third: third
    ),
    MaxReplayActions
  )

proc recordHash*(recorder: ReplayRecorder, hash: uint64) =
  ## Appends the canonical hash for one completed simulation tick.
  recordHash(recorder, hash, MaxReplayHashes)

proc validateSetup(setup: Setup) =
  ## Validates the immutable expedition description.
  if setup.tickRate != uint16(TickRate):
    fail("replay setup has an unsupported tick rate")
  if setup.gridTiles != uint16(GridTiles):
    fail("replay setup has an unsupported map size")
  if setup.levels != uint8(LevelCount):
    fail("replay setup has an unsupported level count")
  if setup.decisionTicks != uint16(DecisionTicks):
    fail("replay setup has an unsupported decision interval")
  if setup.maximumTicks == 0 or setup.maximumTicks > uint32(MaxReplayHashes):
    fail("replay setup has an invalid duration")
  if setup.mapHash == 0:
    fail("replay setup has no deterministic map fingerprint")
  for slot, member in setup.party:
    if member.id != int32(100 + slot) or member.class != HeroClass(slot):
      fail("replay setup party is not in canonical order")

proc validateAction(action: ReplayAction, setup: Setup) =
  ## Validates one recorded hero command and its payload.
  if action.tick == 0 or action.tick > setup.maximumTicks or
      action.tick mod uint32(setup.decisionTicks) != 0:
    fail("replay action did not land on a decision tick")
  if action.heroId < 100 or action.heroId >= 100 + PartySize:
    fail("replay action names an unknown hero")
  if action.kind == 0 or action.kind > ActionKindHigh:
    fail("replay action kind is invalid")
  if action.kind == ActionWalkTo:
    if action.first < 0 or action.first >= LevelCount or
        action.second < 0 or action.second >= GridTiles or
        action.third < 0 or action.third >= GridTiles:
      fail("replay walk names a tile outside the dungeon")
  elif action.kind == ActionUseItem or action.kind == ActionDropItem:
    if action.first < 0 or action.first >= InventorySlots:
      fail("replay item action names a slot outside the bag")
  elif action.first <= 0:
    fail("replay target action has an invalid target ID")

proc validate*(data: ReplayData) =
  ## Validates versions, setup, commands, and per-tick hash coverage.
  data.header.requireTapeVersion(
    ReplayFormatVersion,
    ReplayGameVersion
  )
  data.header.setup.validateSetup()
  if data.actions.len > MaxReplayActions:
    fail("replay action limit exceeded")
  if data.hashes.len > int(data.header.setup.maximumTicks):
    fail("replay hashes exceed the configured duration")
  var lastTick = 0'u32
  for index, action in data.actions:
    if action.tick > uint32(data.hashes.len):
      fail("replay action exceeds the recorded duration")
    if index > 0 and action.tick < lastTick:
      fail("replay actions move backward in time")
    action.validateAction(data.header.setup)
    lastTick = action.tick

proc encodeReplay*(data: ReplayData): string =
  ## Encodes one validated replay using the shared Flatty envelope.
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
  ## Creates the parent directory and writes one complete replay file.
  data.validate()
  let directory = path.parentDir
  if directory.len > 0:
    createDir(directory)
  saveReplayFile(
    path,
    ReplayGame,
    ReplayGameVersion,
    data,
    MaxReplayBytes
  )

proc loadReplay*(path: string): ReplayData =
  ## Loads one complete Call to Adventure replay file.
  result = loadReplayFile(
    path,
    ReplayGame,
    ReplayGameVersion,
    ReplayData,
    MaxReplayBytes
  )
  result.validate()

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  ## Creates a playback cursor over validated commands.
  data.validate()
  initTapePlayer(data)

proc takeActionAt*(
    player: ReplayPlayer,
    tick: uint32,
    heroId: int32,
    action: var ReplayAction
): bool =
  ## Consumes the next command when it belongs to this decision slot.
  if player == nil or player.finished:
    return false
  let next = player.data.actions[player.actionIndex]
  if next.tick < tick:
    fail("replay playback skipped an action tick")
  if next.tick != tick or next.heroId != heroId:
    return false
  action = next
  inc player.actionIndex
  true
