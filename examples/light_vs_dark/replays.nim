## Light vs Dark action-only replay format and playback cursor.
##
## A replay stores accepted overlord commands and one canonical simulation
## hash per tick. It never stores bot source, bot identity, or simulation
## snapshots, so replaying a match reveals what was done and never how the
## deciding program was written.

import
  polyworld/tapes,
  content

const
  ReplayGame* = "light_vs_dark"
  ReplayFormatVersion* = 1'u16
  ReplayGameVersion* = 9'u16

  ActionMove* = 1'u8
  ActionAttack* = 2'u8
  ActionHarvest* = 3'u8
  ActionBuild* = 4'u8
  ActionTrain* = 5'u8
  ActionSetRally* = 6'u8
  ActionCancel* = 7'u8
  ActionAttackMove* = 8'u8
  ActionKindHigh* = ActionAttackMove

  MaxReplayBytes* = 64 * 1024 * 1024
  MaxReplayActions* = 4_000_000
  MaxReplayHashes* = 10_000_000
  MaxMatchTicks* = uint32(TickRate) * 60 * 60
    ## One hour, an absolute ceiling well above any configured match.

type
  ReplayPlayerSetup* = object
    id*: uint8
      ## Zero is Light and one is Dark.
    startX*, startY*: uint8
      ## North-west corner tile of the opening town hall.

  Setup* = object
    mapSeed*: int32
    tickRate*: uint16
    gridTiles*: uint16
    decisionTicks*: uint16
    maximumTicks*: uint32
    mapHash*: uint64
      ## Fingerprint of the generated terrain, checked against a fresh
      ## generation at load so a generator change fails by name.
    contentHash*: uint64
      ## Fingerprint of every tuning table, checked the same way.
    players*: array[PlayerCount, ReplayPlayerSetup]

  ReplayAction* = object
    tick*: uint32
    playerId*: uint8
    kind*: uint8
    entityId*: int32
      ## The acting unit or structure, always owned by `playerId`.
    first*, second*, third*: int32
      ## Payload interpreted per kind:
      ##   Move      x, y, unused
      ##   Attack    target id, unused, unused
      ##   Harvest   mine id or tile index, tree flag, unused
      ##   Build     building kind, x, y
      ##   Train     unit kind, unused, unused
      ##   SetRally  x, y, unused
      ##   Cancel    unused, unused, unused

  ReplayHeader* = TapeHeader[Setup]
  ReplayData* = ActionTape[Setup, ReplayAction]
  ReplayRecorder* = TapeRecorder[Setup, ReplayAction]
  ReplayPlayer* = TapePlayer[Setup, ReplayAction]

proc fail(message: string) {.noreturn.} =
  ## Raises one Light vs Dark replay error.
  raise newException(ReplayError, message)

proc initReplayData*(setup: Setup): ReplayData =
  ## Creates an empty replay with a versioned deterministic setup.
  initActionTape[Setup, ReplayAction](
    setup,
    ReplayFormatVersion,
    ReplayGameVersion
  )

proc initReplayRecorder*(setup: Setup): ReplayRecorder =
  ## Creates an in-memory recorder for one match.
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
  if int(action.playerId) >= PlayerCount:
    fail("replay action names an unknown player")
  recorder.data.actions.appendAction(action, MaxReplayActions)

proc recordAction*(
    recorder: ReplayRecorder,
    tick: uint32,
    playerId: int32,
    kind: uint8,
    entityId: int32,
    first = 0'i32,
    second = 0'i32,
    third = 0'i32
) =
  ## Records one accepted command without any bot implementation detail.
  recorder.record ReplayAction(
    tick: tick,
    playerId: uint8(playerId),
    kind: kind,
    entityId: entityId,
    first: first,
    second: second,
    third: third
  )

proc recordHash*(recorder: ReplayRecorder, hash: uint64) =
  ## Appends the canonical simulation hash for one completed tick.
  recordHash(recorder, hash, MaxReplayHashes)

proc validateSetup(setup: Setup) =
  ## Validates the immutable match description.
  if setup.tickRate != uint16(TickRate):
    fail("replay setup has an unsupported tick rate")
  if setup.gridTiles != uint16(GridSide):
    fail("replay setup has an unsupported map size")
  if setup.decisionTicks != uint16(DecisionTicks):
    fail("replay setup has an unsupported decision interval")
  if setup.maximumTicks == 0:
    fail("replay setup has an invalid duration")
  if setup.maximumTicks > MaxMatchTicks:
    fail("replay setup duration exceeds the match limit")
  if setup.maximumTicks > uint32(MaxReplayHashes):
    fail("replay setup duration exceeds the hash limit")
  if setup.mapHash == 0:
    fail("replay setup has no deterministic map fingerprint")
  if setup.contentHash == 0:
    fail("replay setup has no deterministic content fingerprint")
  for index, player in setup.players:
    if int(player.id) != index:
      fail("replay setup players are out of canonical order")
    if int32(player.startX) >= GridSide or int32(player.startY) >= GridSide:
      fail("replay setup places a player outside the map")
  if setup.players[0].startX == setup.players[1].startX and
      setup.players[0].startY == setup.players[1].startY:
    fail("replay setup starts both players on one tile")

proc validateAction(action: ReplayAction, setup: Setup) =
  ## Validates one command's kind, ownership range, and payload bounds.
  if action.kind == 0 or action.kind > ActionKindHigh:
    fail("replay action kind is invalid")
  if int(action.playerId) >= PlayerCount:
    fail("replay action names an unknown player")
  if action.tick > setup.maximumTicks:
    fail("replay action exceeds the configured duration")
  if action.tick == 0 or action.tick mod uint32(setup.decisionTicks) != 0:
    fail("replay action did not land on a decision tick")

  proc requireTile(x, y: int32) =
    if x < 0 or x >= GridSide or y < 0 or y >= GridSide:
      fail("replay action names a tile outside the map")

  case action.kind
  of ActionMove, ActionAttackMove:
    if not action.entityId.isUnitId:
      fail("replay move does not name a unit")
    requireTile(action.first, action.second)
  of ActionAttack:
    if not action.entityId.isUnitId:
      fail("replay attack does not name a unit")
    if not (action.first.isUnitId or action.first.isBuildingId):
      fail("replay attack does not name an entity")
  of ActionHarvest:
    if not action.entityId.isUnitId:
      fail("replay harvest does not name a unit")
    if action.second == 0:
      if not action.first.isMineId:
        fail("replay harvest does not name a gold mine")
    elif action.second == 1:
      if action.first < 0 or action.first >= GridCells:
        fail("replay harvest names a tile outside the map")
    else:
      fail("replay harvest has an invalid resource flag")
  of ActionBuild:
    if not action.entityId.isUnitId:
      fail("replay build does not name a peon")
    if action.first < 0 or action.first > int32(BuildableHigh.ord):
      fail("replay build names an unbuildable structure")
    requireTile(action.second, action.third)
  of ActionTrain:
    if not action.entityId.isPlayerBuildingId:
      fail("replay train does not name a structure")
    if action.first < 0 or action.first > int32(UnitKind.high.ord):
      fail("replay train names an unknown unit")
  of ActionSetRally:
    if not action.entityId.isPlayerBuildingId:
      fail("replay rally does not name a structure")
    requireTile(action.first, action.second)
  of ActionCancel:
    if not (action.entityId.isUnitId or action.entityId.isPlayerBuildingId):
      fail("replay cancel does not name an owned entity")
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
