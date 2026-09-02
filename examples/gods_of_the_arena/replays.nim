## Gods of the Arena action-only replay format and playback cursor.

import
  polyworld/tapes,
  content

const
  ReplayGame* = "gods_of_the_arena"
  ReplayFormatVersion* = 3'u16
  ReplayGameVersion* = 13'u16
  ReplayGridTiles* = 128'u16
  ActionWalkTo* = 1'u8
  ActionAttackTarget* = 2'u8
  ActionBuyItem* = 3'u8
  ActionUseItem* = 4'u8
  ActionAttackMove* = 5'u8
  MaxReplayBytes* = 64 * 1024 * 1024
  MaxReplayActions* = 10_000_000
  MaxReplayHashes* = 100_000_000
  MaxReplayHeroes* = 256

type
  ReplayHero* = object
    id*: int32
    team*: uint8
    slot*: uint8
    lane*: uint8
    class*: uint8

  Setup* = object
    mapSeed*: int32
    mapHash*: uint64
    tickRate*: uint16
    gridTiles*: uint16
    spawnIntervalTicks*: uint32
    maximumTicks*: uint32
    heroes*: seq[ReplayHero]

  ReplayAction* = object
    tick*: uint32
    heroId*: int32
    kind*: uint8
    first*: int32
    second*: int32

  ReplayHeader* = TapeHeader[Setup]
  ReplayData* = ActionTape[Setup, ReplayAction]
  ReplayRecorder* = TapeRecorder[Setup, ReplayAction]
  ReplayPlayer* = TapePlayer[Setup, ReplayAction]

proc fail(message: string) {.noreturn.} =
  ## Raises one Gods of the Arena replay error.
  raise newException(ReplayError, message)

proc initReplayData*(setup: Setup): ReplayData =
  ## Creates an empty replay with a versioned deterministic setup.
  initActionTape[Setup, ReplayAction](
    setup,
    ReplayFormatVersion,
    ReplayGameVersion
  )

proc initReplayRecorder*(setup: Setup): ReplayRecorder =
  ## Creates an in-memory Gods of the Arena action recorder.
  initTapeRecorder[Setup, ReplayAction](
    setup,
    ReplayFormatVersion,
    ReplayGameVersion
  )

proc record*(recorder: ReplayRecorder, action: ReplayAction) =
  ## Appends one bot action in deterministic tick order.
  if recorder == nil:
    return
  if action.kind != ActionWalkTo and
      action.kind != ActionAttackTarget and
      action.kind != ActionBuyItem and
      action.kind != ActionUseItem and
      action.kind != ActionAttackMove:
    fail("replay action kind is invalid")
  recorder.data.actions.appendAction(action, MaxReplayActions)

proc recordWalkTo*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId,
    x,
    y: int32
) =
  ## Records one walkTo action without bot implementation details.
  recorder.record ReplayAction(
    tick: tick,
    heroId: heroId,
    kind: ActionWalkTo,
    first: x,
    second: y
  )

proc recordAttackMove*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId,
    x,
    y: int32
) =
  ## Records one attack-move action without bot implementation details.
  recorder.record ReplayAction(
    tick: tick,
    heroId: heroId,
    kind: ActionAttackMove,
    first: x,
    second: y
  )

proc recordAttackTarget*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId,
    targetId: int32
) =
  ## Records one attackTarget action without bot implementation details.
  recorder.record ReplayAction(
    tick: tick,
    heroId: heroId,
    kind: ActionAttackTarget,
    first: targetId
  )

proc recordBuyItem*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId,
    itemId: int32
) =
  ## Records one buyItem action without bot implementation details.
  recorder.record ReplayAction(
    tick: tick,
    heroId: heroId,
    kind: ActionBuyItem,
    first: itemId
  )

proc recordUseItem*(
    recorder: ReplayRecorder,
    tick: uint32,
    heroId,
    slot: int32
) =
  ## Records one useItem action without bot implementation details.
  recorder.record ReplayAction(
    tick: tick,
    heroId: heroId,
    kind: ActionUseItem,
    first: slot
  )

proc recordHash*(recorder: ReplayRecorder, hash: uint64) =
  ## Appends the canonical simulation hash for one completed tick.
  recordHash(recorder, hash, MaxReplayHashes)

proc validate*(data: ReplayData) =
  ## Validates versions, setup bounds, actor IDs, and action ordering.
  data.header.requireTapeVersion(
    ReplayFormatVersion,
    ReplayGameVersion
  )
  let setup = data.header.setup
  if setup.tickRate != uint16(TickRate):
    fail("replay setup has an unsupported tick rate")
  if setup.gridTiles != ReplayGridTiles:
    fail("replay setup has an unsupported map size")
  if setup.mapHash == 0:
    fail("replay setup has no deterministic map fingerprint")
  if setup.spawnIntervalTicks == 0 or setup.maximumTicks == 0:
    fail("replay setup has an invalid duration")
  if setup.spawnIntervalTicks > uint32(int32.high):
    fail("replay setup spawn interval is too large")
  if setup.maximumTicks > uint32(MaxReplayHashes):
    fail("replay setup duration exceeds the hash limit")
  if setup.heroes.len == 0 or setup.heroes.len > MaxReplayHeroes:
    fail("replay setup has an invalid hero count")
  if data.actions.len > MaxReplayActions:
    fail("replay action limit exceeded")
  if data.hashes.len > MaxReplayHashes:
    fail("replay hash limit exceeded")
  if data.hashes.len != int(setup.maximumTicks):
    fail("replay must contain exactly one hash per simulation tick")
  for i, hero in setup.heroes:
    if hero.team > 1 or hero.lane > 2 or
        hero.class > uint8(HeroClass.high.ord):
      fail("replay setup has invalid hero metadata")
    for j in 0 ..< i:
      if setup.heroes[j].id == hero.id:
        fail("replay setup contains a duplicate hero ID")
  var lastTick = 0'u32
  for i, action in data.actions:
    if i > 0 and action.tick < lastTick:
      fail("replay actions move backward in time")
    if setup.maximumTicks > 0 and action.tick > setup.maximumTicks:
      fail("replay action exceeds the configured duration")
    if action.kind != ActionWalkTo and
        action.kind != ActionAttackTarget and
        action.kind != ActionBuyItem and
        action.kind != ActionUseItem and
        action.kind != ActionAttackMove:
      fail("replay action kind is invalid")
    var knownHero = false
    for hero in setup.heroes:
      if hero.id == action.heroId:
        knownHero = true
        break
    if not knownHero:
      fail("replay action references an unknown hero")
    lastTick = action.tick

proc encodeReplay*(data: ReplayData): string =
  ## Encodes a validated arena replay using the shared Flatty envelope.
  data.validate()
  encodeReplayFile(
    ReplayGame,
    ReplayGameVersion,
    data,
    MaxReplayBytes
  )

proc decodeReplay*(bytes: string): ReplayData =
  ## Decodes and validates one arena replay buffer.
  result = decodeReplayFile(
    ReplayGame,
    ReplayGameVersion,
    bytes,
    ReplayData,
    MaxReplayBytes
  )
  result.validate()

proc saveReplay*(path: string, data: ReplayData) =
  ## Writes one complete arena replay file.
  data.validate()
  saveReplayFile(
    path,
    ReplayGame,
    ReplayGameVersion,
    data,
    MaxReplayBytes
  )

proc loadReplay*(path: string): ReplayData =
  ## Loads one complete arena replay file.
  result = loadReplayFile(
    path,
    ReplayGame,
    ReplayGameVersion,
    ReplayData,
    MaxReplayBytes
  )
  result.validate()

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  ## Creates a playback cursor over validated action data.
  data.validate()
  initTapePlayer(data)
