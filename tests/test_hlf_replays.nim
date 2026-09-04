## Heartleaf replays: roundtrip fidelity and named rejection of everything
## malformed.

import
  ../examples/heartleaf/content,
  ../examples/heartleaf/replays,
  polyworld/tapes

proc sampleSetup(): Setup =
  Setup(
    mapSeed: DefaultSeed,
    tickRate: uint16(TickRate),
    gridTiles: uint16(GridSide),
    decisionTicks: uint16(DecisionTicks),
    dayCount: 2,
    maximumTicks: uint32(gameLengthTicks(2)),
    mapHash: 0xDEADBEEF'u64,
    contentHash: contentHash()
  )

proc sampleReplay(): ReplayData =
  let recorder = initReplayRecorder(sampleSetup())
  recorder.recordAction(uint32(DecisionTicks), 0, ActionGather, 3)
  recorder.recordAction(uint32(DecisionTicks), 1, ActionMove, 64, 64)
  recorder.recordAction(uint32(DecisionTicks * 2), 0, ActionInvite, 4)
  recorder.recordAction(uint32(DecisionTicks * 2), 4, ActionAccept, 0)
  recorder.recordAction(uint32(DecisionTicks * 3), 4, ActionEnterHouse, 0)
  recorder.recordAction(uint32(DecisionTicks * 4), 4, ActionExitHouse)
  recorder.recordAction(uint32(DecisionTicks * 4), 0, ActionStop)
  for tick in 0 ..< gameLengthTicks(2):
    recorder.recordHash(uint64(tick) * 0x9E3779B97F4A7C15'u64 + 1)
  recorder.data

echo "Testing roundtrip fidelity"
block roundtrip:
  let
    data = sampleReplay()
    encoded = encodeReplay(data)
    decoded = decodeReplay(encoded)
  doAssert decoded.header.setup == data.header.setup
  doAssert decoded.actions.len == data.actions.len
  doAssert decoded.hashes.len == data.hashes.len
  for index in 0 ..< data.actions.len:
    doAssert decoded.actions[index] == data.actions[index]

proc rejects(mutate: proc(data: var ReplayData)) : bool =
  var data = sampleReplay()
  data.mutate()
  try:
    discard encodeReplay(data)
    false
  except ReplayError:
    true

echo "Testing named rejection"
block rejections:
  doAssert rejects(proc(data: var ReplayData) =
    data.header.setup.tickRate = 60),
    "a foreign tick rate was accepted"
  doAssert rejects(proc(data: var ReplayData) =
    data.header.setup.mapHash = 0),
    "a missing map fingerprint was accepted"
  doAssert rejects(proc(data: var ReplayData) =
    data.header.setup.contentHash = 0),
    "a missing content fingerprint was accepted"
  doAssert rejects(proc(data: var ReplayData) =
    data.header.setup.dayCount = 0),
    "a zero-day game was accepted"
  doAssert rejects(proc(data: var ReplayData) =
    data.header.setup.maximumTicks += 1),
    "a duration that disagrees with the day count was accepted"
  doAssert rejects(proc(data: var ReplayData) =
    data.hashes.setLen(data.hashes.len + 1)),
    "hashes past the configured duration were accepted"
  doAssert rejects(proc(data: var ReplayData) =
    data.actions[0].playerId = uint8(VillagerCount)),
    "an unknown villager was accepted"
  doAssert rejects(proc(data: var ReplayData) =
    data.actions[0].kind = ActionKindHigh + 1),
    "an unknown action kind was accepted"
  doAssert rejects(proc(data: var ReplayData) =
    data.actions[0].first = int32(GardenCount)),
    "an out-of-range garden was accepted"
  doAssert rejects(proc(data: var ReplayData) =
    data.actions[0].tick = uint32(DecisionTicks) + 1),
    "an off-cadence action was accepted"
  doAssert rejects(proc(data: var ReplayData) =
    data.actions[2].first = 0),
    "a self-invitation was accepted"
  doAssert rejects(proc(data: var ReplayData) =
    let action = data.actions[0]
    data.actions[0] = data.actions[^1]
    data.actions[^1] = action),
    "time-travelling actions were accepted"

echo "Testing the envelope"
block envelope:
  var caught = false
  try:
    discard decodeReplay("NOT-A-HEARTLEAF-REPLAY")
  except ReplayError:
    caught = true
  doAssert caught, "invalid magic was accepted"

echo "test_hlf_replays: all checks passed"
