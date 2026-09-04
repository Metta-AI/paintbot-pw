import
  std/strutils,
  polyworld/tapes

type TapeAction = object
  tick*: uint32
  kind*: uint8

echo "Testing action order and exact-tick playback"
block:
  var
    actions: seq[TapeAction]
    action: TapeAction
    index = 0
  actions.appendAction(TapeAction(tick: 12, kind: 1), 100)
  actions.appendAction(TapeAction(tick: 12, kind: 2), 100)
  actions.appendAction(TapeAction(tick: 24, kind: 1), 100)
  doAssert not actions.takeActionAt(index, 0, action)
  doAssert actions.takeActionAt(index, 12, action) and action.kind == 1
  doAssert actions.takeActionAt(index, 12, action) and action.kind == 2
  doAssert not actions.takeActionAt(index, 12, action)
  doAssert actions.takeActionAt(index, 24, action)
  doAssert replayFinished(index, actions.len)
  try:
    actions.appendAction(TapeAction(tick: 10, kind: 1), 100)
    doAssert false, "recording backward in time should fail"
  except ReplayError:
    discard

echo "Testing a live seek cursor skips consumed ticks"
block:
  var actions = @[
    TapeAction(tick: 12, kind: 1),
    TapeAction(tick: 12, kind: 2),
    TapeAction(tick: 24, kind: 1)
  ]
  doAssert actions.actionIndexAfter(0) == 0
  doAssert actions.actionIndexAfter(11) == 0
  doAssert actions.actionIndexAfter(12) == 2
  doAssert actions.actionIndexAfter(23) == 2
  doAssert actions.actionIndexAfter(24) == 3
  var
    action: TapeAction
    index = 0
  try:
    discard actions.takeActionAt(index, 24, action)
    doAssert false, "seeking forward with a live cursor should fail"
  except ReplayError:
    discard
  index = actions.actionIndexAfter(20)
  doAssert actions.takeActionAt(index, 24, action) and action.kind == 1

echo "Testing skipped ticks are loud"
block:
  var
    actions = @[
      TapeAction(tick: 5, kind: 1),
      TapeAction(tick: 7, kind: 1),
      TapeAction(tick: 10, kind: 1)
    ]
    action: TapeAction
    index = 0
  doAssert actions.takeActionAt(index, 5, action)
  try:
    discard actions.takeActionAt(index, 10, action)
    doAssert false, "skipping an unconsumed tick should fail"
  except ReplayError:
    discard

echo "Testing hash lookup and mismatch text"
block:
  var
    hashes: seq[uint64]
    check: ReplayHashCheck
    found: uint64
  hashes.appendHash(0x11, 3, 100)
  hashes.appendHash(0x22, 3, 100)
  hashes.appendHash(0x33, 3, 100)
  doAssert hashes.hashAt(1, found) and found == 0x11
  doAssert hashes.hashAt(3, found) and found == 0x33
  doAssert not hashes.hashAt(0, found)
  doAssert not hashes.hashAt(4, found)
  hashes.checkReplayHash(2, 0x22, check)
  doAssert check.mismatches == 0
  hashes.checkReplayHash(2, 0x99, check)
  doAssert check.mismatches == 1
  doAssert check.firstTick == 2
  doAssert check.error.contains("tick 2")
  hashes.checkReplayHash(3, 0x00, check)
  doAssert check.mismatches == 2
  try:
    hashes.appendHash(0x44, 3, 100)
    doAssert false, "too many hashes should fail"
  except ReplayError:
    discard

echo "Testing generic tape recorder and player"
block:
  type
    Setup = object
      maximumTicks*: uint32
    Command = object
      tick*: uint32
      kind*: uint8
  let recorder = initTapeRecorder[Setup, Command](
    Setup(maximumTicks: 4),
    1,
    1
  )
  recorder.data.actions.appendAction(Command(tick: 2, kind: 1), 10)
  recorder.data.actions.appendAction(Command(tick: 4, kind: 2), 10)
  recorder.recordHash(0x11, 10)
  recorder.recordHash(0x22, 10)
  recorder.recordHash(0x33, 10)
  recorder.recordHash(0x44, 10)
  recorder.data.header.requireTapeVersion(1, 1)
  let player = initTapePlayer(recorder.data)
  var command: Command
  doAssert not player.takeActionAt(1, command)
  doAssert player.takeActionAt(2, command) and command.kind == 1
  doAssert player.actionsAt(4).len == 1
  doAssert player.finished
  var hash: uint64
  doAssert player.hashAt(4, hash) and hash == 0x44
  player.syncCursor(0)
  doAssert not player.finished

echo "Testing replay completion rejects divergence and missing ticks"
block:
  var check: ReplayHashCheck
  check.requireReplayComplete(0, 0)
  check.requireReplayComplete(2, 2)
  for tick in [1'u32, 3'u32]:
    try:
      check.requireReplayComplete(tick, 2)
      doAssert false, "playback must consume exactly the recorded ticks"
    except ReplayError:
      discard
  check = ReplayHashCheck(mismatches: 1, firstTick: 2)
  try:
    check.requireReplayComplete(2, 2)
    doAssert false, "a hash mismatch must fail replay verification"
  except ReplayError as error:
    doAssert error.msg.contains("first at tick 2")

echo "Tape tests passed"
