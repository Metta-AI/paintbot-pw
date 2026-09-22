## Proves the native BASIC seats match the production Python host: replays recorded by
## coworld/paintbot/local.py (the deployed engine, sixteen file seats) are compared tick
## for tick against a native handle running the same source on every seat.
##
##   nim r --mm:arc --threads:on -d:pwTraining tools/paintbot_script_parity.nim \
##       SCRIPT.bas REPLAY.bin [REPLAY.bin ...]
##
## Prints one JSON line per replay with the seed, tick count, and whether every frame
## hash matched; exits non-zero on any mismatch.
import std/[os, strutils, json]
import ../examples/paintbot/[sim, neural_contract, native_env, game]

proc main() =
  let args = commandLineParams()
  if args.len < 2: quit("usage: paintbot_script_parity SCRIPT.bas REPLAY.bin [...]", 2)
  let source = readFile(args[0])
  var failures = 0
  for path in args[1..^1]:
    let recording = loadRecording(path)
    configureRules(NativeRules)
    let handle = pw_create(recording.seed, recording.endTick)
    doAssert handle != nil
    for slot in 0..<Seats:
      doAssert pw_set_seat_script(handle, slot.cint,
        cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    var matched = 0
    var firstMismatch = -1
    for tick, frame in recording.frames:
      if pw_step(handle, cast[ptr UncheckedArray[int32]](addr actions[0]),
          cast[ptr UncheckedArray[cfloat]](addr rewards[0]),
          cast[ptr UncheckedArray[cfloat]](addr terminals[0])) != 0:
        firstMismatch = tick; break
      if pw_state_hash(handle) != frame.hash:
        firstMismatch = tick; break
      inc matched
    var statuses: seq[int]
    for slot in 0..<Seats: statuses.add pw_seat_script_status(handle, slot.cint, nil, 0).int
    let ended = terminals[0] == 1
    pw_destroy(handle)
    let ok = firstMismatch < 0 and matched == recording.frames.len and ended
    if not ok: inc failures
    echo $(%*{"replay": path, "seed": recording.seed, "frames": recording.frames.len,
      "matched": matched, "first_mismatch": firstMismatch, "native_terminal": ended,
      "seat_status": statuses, "replay_version": replayRulesVersion, "passed": ok})
  quit(if failures > 0: 1 else: 0)

main()
