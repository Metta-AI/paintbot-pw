## Owned-run decision evidence (training library only): pw_debug_set_trace, pw_debug_status_json,
## pw_debug_trace_json and pw_debug_observation_json. The status names the handle's actual decision
## boundary and whether every seat is a plain BASIC controller under default knobs; the trace of the
## last completed step records each seat's SeatView observation, the order its program decided, that
## order normalized as the raw-command ABI normalizes it, and the command the world actually executed
## (after fire gating, immediately before simulation), with VM failure/budget and world/controller
## digests. Tracing is opt-in and changes nothing: hashes, orders and pw_world_save bytes are identical
## with it on or off; inspection never takes a decision. Public synthetic fixtures only.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, json, sequtils]
import ../examples/paintbot/[sim, native_env, contract_hash, neural_contract]

when not defined(pwTraining): {.error: "the debug trace exists only under -d:pwTraining".}

const
  Root = currentSourcePath().parentDir.parentDir
  Base = Root / "coworld/paintbot/players/base.bas"
  Advised = Root / "examples/paintbot/players/advised.bas"
  CommandKeys = ["walk", "goal_x", "goal_z", "shoot", "aim_x", "aim_z", "charge_grenade", "sneak",
    "direct", "self_destruct"]
  # A stateful synthetic controller: persistent record, array, string and rnd state. It names the
  # advisor and the neural net only inside a comment and a string, and has a variable whose name
  # starts with an advisor builtin's: none of that is a reference to either.
  Stateful* = """
' synthetic public fixture: oracleAsk() and run_neural_net appear only in comments and strings
TYPE Memo
  count AS INTEGER
  text AS STRING
END TYPE
DIM memo AS Memo
DIM hist(8)
memo.count = memo.count + 1
oracleNotes = oracleNotes + 1
r = rnd(1000)
hist(memo.count mod 8) = hist(memo.count mod 8) + r
if memo.count mod 40 = 1 then
  memo.text = memo.text + "oracleAsk"
end if
walkTo(selfX + r - 500, selfY + (r mod 7) * 100 - 300)
if r mod 3 = 0 then
  shootAt(selfX + 800, selfY + r - 500)
end if
if r mod 5 = 0 then
  sneak(1)
end if
"""
  NeuralRef = "x = neuralModel()\nwalkTo(selfX, selfY)\n"
  Runaway = "while 1 = 1\n  x = x + 1\nwend\n"

proc cbuf(s: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])

proc save(h: pointer): seq[byte] =
  let n = pw_world_save(h, nil, 0)
  doAssert n > 0
  result = newSeq[byte](n)
  doAssert pw_world_save(h, cast[ptr UncheckedArray[byte]](addr result[0]), n) == n

proc sameSave(a, b: pointer): bool =
  ## Byte equality of two handles' pw_world_save blobs (a bool, so a failure does not print megabytes).
  let aa = save(a)
  let bb = save(b)
  if aa != bb:
    for i in 0..<min(aa.len, bb.len):
      if aa[i] != bb[i]:
        echo "first save difference ", i, " / ", aa.len, " values ", aa[i], " ", bb[i]
        break
  aa == bb

proc readText(call: proc(output: ptr UncheckedArray[char], capacity: int32): cint): string =
  ## pw_world_json size-query semantics: capacity 0 sizes, a short buffer is left untouched.
  let n = call(nil, 0)
  doAssert n > 0, "size query returned " & $n
  var short = newString(n - 1)
  if short.len > 0:
    for c in short.mitems: c = '#'
    doAssert call(cast[ptr UncheckedArray[char]](addr short[0]), int32(n - 1)) == n
    doAssert short.allIt(it == '#'), "a short buffer was written"
  result = newString(n)
  doAssert call(cast[ptr UncheckedArray[char]](addr result[0]), n) == n

proc statusText(h: pointer): string =
  readText(proc(o: ptr UncheckedArray[char], c: int32): cint = pw_debug_status_json(h, o, c))
proc status(h: pointer): JsonNode = parseJson(statusText(h))
proc traceText(h: pointer): string =
  readText(proc(o: ptr UncheckedArray[char], c: int32): cint = pw_debug_trace_json(h, o, c))
proc trace(h: pointer): JsonNode = parseJson(traceText(h))
proc observationText(h: pointer, seat: int): string =
  readText(proc(o: ptr UncheckedArray[char], c: int32): cint = pw_debug_observation_json(h, seat.cint, o, c))

proc scripted(seed, ticks: int32, source = Stateful): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  for s in 0..<Seats: doAssert pw_set_seat_script(result, s.cint, cbuf(source), source.len.int32) == 0

proc step(h: pointer): cint =
  var actions = newSeq[int32](Seats*5)
  var rewards, terminals = newSeq[cfloat](Seats)
  pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals))

proc ten(c: JsonNode): array[10, int32] =
  ## A command object as pw_seat_orders_ex / pw_set_seat_command_ex order its fields.
  doAssert c.kind == JObject and c.len == 10, "command has exactly ten fields: " & $c
  for i, k in CommandKeys:
    doAssert c.hasKey(k), "missing " & k
    let v = c[k]
    if k in ["goal_x", "goal_z", "aim_x", "aim_z"]:
      doAssert v.kind == JInt; result[i] = v.getInt.int32
    else:
      doAssert v.kind == JBool, k & " must be a strict boolean"; result[i] = v.getBool.int32

proc ordersEx(h: pointer, seat: int): array[10, int32] =
  var o: array[11, int32]
  doAssert pw_seat_orders_ex(h, seat.cint, ibuf(o)) == 0
  for i in 0..8: result[i] = o[i]
  result[9] = o[10]

proc decided(h: pointer, seat: int): array[10, int32] =
  var o: array[10, int32]
  doAssert pw_seat_decided_orders(h, seat.cint, ibuf(o)) == 0
  doAssert o[9] == 1
  for i in 0..8: result[i] = o[i]

proc reasons(j: JsonNode): seq[string] = j["reasons"].getElems.mapIt(it.getStr)

suite "pw_debug_status_json":
  test "a fresh all-BASIC handle is supported at pre_decision and the read is pure":
    let h = scripted(7, 600)
    let before = save(h)
    let t1 = statusText(h)
    let j = parseJson(t1)
    check j["schema_version"].getStr == "paintbot_native_debug_v1"
    check j["tick"].kind == JInt and j["tick"].getInt == 0
    check j["terminal"].kind == JBool and not j["terminal"].getBool
    check j["phase"].getStr == "pre_decision"
    check j["supported"].kind == JBool and j["supported"].getBool
    check j["reasons"].kind == JArray and j["reasons"].len == 0
    check j["pending_override"].kind == JBool and not j["pending_override"].getBool
    check j["trace_enabled"].kind == JBool and not j["trace_enabled"].getBool
    check j["seats"].getInt == Seats
    check j["rules_version"].getInt == pw_rules(h)
    check j["program_sha256"].len == 16
    for p in j["program_sha256"]: check p.getStr == sha256Hex(Stateful)
    check j["controller_sha256"].getStr.len == 64
    check j["world_hash"].kind == JString and j["world_hash"].getStr == $pw_state_hash(h)
    check j["snapshot_build_id"].getStr.len == 64
    check statusText(h) == t1
    let unchanged = save(h) == before
    check unchanged
    pw_destroy(h)

  test "phase follows the actual decision boundary; a taken decision or pending command is unsupported":
    let h = scripted(11, 600)
    check pw_script_decide(h) == 1
    var j = status(h)
    check j["phase"].getStr == "post_decision_pre_step"
    check not j["supported"].getBool
    check "phase_not_pre_decision" in reasons(j)
    check step(h) == 0
    j = status(h)
    check j["tick"].getInt == 1 and j["phase"].getStr == "pre_decision" and j["supported"].getBool
    var cmd = [1'i32, 100, 100, 0, 0, 0, 0, 0, 0, 0]
    check pw_set_seat_command_ex(h, 2, ibuf(cmd)) == 0
    j = status(h)
    check j["pending_override"].getBool and not j["supported"].getBool
    check "pending_override" in reasons(j)
    check j["phase"].getStr == "pre_decision"
    pw_destroy(h)

  test "terminal handles are inspectable but unsupported":
    let h = scripted(3, 4)
    for i in 0..<4: check step(h) == 0
    let j = status(h)
    check j["terminal"].getBool and not j["supported"].getBool and "terminal" in reasons(j)
    pw_destroy(h)

  test "unsupported controllers and knobs are reported from actual handle state":
    proc reasonsAfter(change: proc(h: pointer)): seq[string] =
      let h = scripted(5, 600)
      change(h)
      let j = status(h)
      check not j["supported"].getBool
      result = reasons(j)
      pw_destroy(h)
    check "no_basic_program:4" in reasonsAfter(proc(h: pointer) =
      doAssert pw_set_seat_script(h, 4, nil, 0) == 0)
    check "damage_scale:1" in reasonsAfter(proc(h: pointer) =
      doAssert pw_set_seat_damage_scale(h, 1, 900) == 0)
    check "fire_period:2" in reasonsAfter(proc(h: pointer) =
      doAssert pw_set_seat_fire_period(h, 2, 2) == 0)
    check "action_override:3" in reasonsAfter(proc(h: pointer) =
      doAssert pw_set_seat_override(h, 3, 1) == 0)
    check "handicap" in reasonsAfter(proc(h: pointer) =
      doAssert pw_set_seat_damage_taken(h, 6, 500) == 0)
    check "teacher_classes" in reasonsAfter(proc(h: pointer) =
      doAssert pw_set_teacher_classes(h, 1, 0) == 0)
    check "shadow_script:5" in reasonsAfter(proc(h: pointer) =
      doAssert pw_set_seat_shadow_script(h, 5, cbuf(Stateful), Stateful.len.int32) == 0)
    var advised = readFile(Advised)
    check "advisor_reference:7" in reasonsAfter(proc(h: pointer) =
      doAssert pw_set_seat_script(h, 7, cbuf(advised), advised.len.int32) == 0)
    check "neural_reference:8" in reasonsAfter(proc(h: pointer) =
      doAssert pw_set_seat_script(h, 8, cbuf(NeuralRef), NeuralRef.len.int32) == 0)
    check "compile_failed:9" in reasonsAfter(proc(h: pointer) =
      var bad = "this is not basic ((("
      doAssert pw_set_seat_script(h, 9, cbuf(bad), bad.len.int32) == 1)

  test "the shipped baseline is a supported BASIC controller":
    let base = readFile(Base)
    let h = scripted(9, 600, base)
    let j = status(h)
    check j["supported"].getBool and j["reasons"].len == 0
    pw_destroy(h)

suite "pw_debug_trace_json":
  test "off by default; enabling captures the last completed step":
    let h = scripted(21, 600)
    check pw_debug_trace_json(h, nil, 0) == -2
    check pw_debug_set_trace(h, 2) == -1
    check pw_debug_set_trace(h, 1) == 0
    check status(h)["trace_enabled"].getBool
    check pw_debug_trace_json(h, nil, 0) == -2   # nothing completed yet
    for i in 0..<5: check step(h) == 0
    let pre = status(h)
    let obs = (0..<Seats).mapIt(parseJson(observationText(h, it)))
    check step(h) == 0
    let post = status(h)
    let j = trace(h)
    check j["schema_version"].getStr == "paintbot_native_debug_v1"
    check j["tick"].getInt == 5
    check j["world_hash_before"].getStr == pre["world_hash"].getStr
    check j["world_hash_after"].getStr == post["world_hash"].getStr
    check j["world_hash_after"].getStr == $pw_state_hash(h)
    check j["controller_sha256_before"].getStr == pre["controller_sha256"].getStr
    check j["controller_sha256_after"].getStr == post["controller_sha256"].getStr
    check j["controller_sha256_before"].getStr != j["controller_sha256_after"].getStr
    check j["decided_ahead"].kind == JBool and not j["decided_ahead"].getBool
    check j["seats"].len == Seats
    for s in 0..<Seats:
      let e = j["seats"][s]
      check e["seat"].getInt == s
      check e["program"].getStr == "basic"
      check e["decided"].getBool
      check e["observation_missing_reason"].kind == JNull
      let o = e["observation"]
      check o["visibility"].getStr == "seat" and o["as_of_tick"].getInt == 5
      check o["source"].getStr == "seat_view"
      check o["self"]["worldTick"].getInt == 5
      check o["self"]["selfId"].kind == JInt
      check o["agents"].len == Seats
      check o["agents"][0].hasKey("visible") and o["agents"][0].hasKey("carrying")
      # the observation evidence is the one the pure read reported at pre_decision(5)
      check o == obs[s]["observation"]
      check e["intended"].ten == decided(h, s)
      check e["normalized"].ten == e["intended"].ten   # BASIC already clamps its aim
      check e["applied"].ten == ordersEx(h, s)
      check not e["replaced_by_raw_command"].getBool
      let vm = e["vm"]
      check vm["ran"].getBool and not vm["failed"].getBool and vm["error"].kind == JNull
      check vm["instructions"].getInt > 0 and vm["work_units"].getInt > 0
      check vm["max_instructions"].getInt >= vm["instructions"].getInt
      check vm["max_work_units"].getInt >= vm["work_units"].getInt
      check e["source_trace"].kind == JNull
    pw_destroy(h)

  test "a raw command is the applied command; the program's intention is kept separately":
    let h = scripted(23, 600)
    check pw_debug_set_trace(h, 1) == 0
    check step(h) == 0
    var cmd = [1'i32, 12345, -777, 1, 99999999, -99999999, 0, 1, 0, 0]
    check pw_set_seat_command_ex(h, 3, ibuf(cmd)) == 0
    check step(h) == 0
    let e = trace(h)["seats"][3]
    check e["replaced_by_raw_command"].getBool
    let applied = e["applied"].ten
    check applied == ordersEx(h, 3)
    check applied[1] == 12345 and applied[2] == -777 and applied[3] == 1 and applied[7] == 1
    check applied[4] < 99999999 and applied[5] > -99999999   # aim clamped to the map, goal verbatim
    check e["intended"].ten == decided(h, 3)
    check e["intended"].ten != applied
    pw_destroy(h)

  test "the applied command is the one after fire gating":
    let h = scripted(31, 600)
    check pw_set_seat_fire_period(h, 0, 4) == 0
    check pw_debug_set_trace(h, 1) == 0
    var gated = 0
    for i in 0..<300:
      check step(h) == 0
      let e = trace(h)["seats"][0]
      if e["intended"]["shoot"].getBool and not e["applied"]["shoot"].getBool:
        inc gated
        check e["normalized"]["shoot"].getBool
    check gated > 0
    pw_destroy(h)

  test "a decision taken ahead by pw_script_decide is traced once, with its pre-decision digests":
    let h = scripted(41, 600)
    check pw_debug_set_trace(h, 1) == 0
    check step(h) == 0
    let pre = status(h)
    check pw_script_decide(h) == 1
    check step(h) == 0
    let j = trace(h)
    check j["tick"].getInt == 1 and j["decided_ahead"].getBool
    check j["controller_sha256_before"].getStr == pre["controller_sha256"].getStr
    check j["world_hash_before"].getStr == pre["world_hash"].getStr
    pw_destroy(h)

  test "a VM failure is evidence, not a crash":
    let h = scripted(43, 600)
    check pw_set_seat_script(h, 6, cbuf(Runaway), Runaway.len.int32) == 0
    check pw_debug_set_trace(h, 1) == 0
    check step(h) == 0
    let e = trace(h)["seats"][6]
    check e["vm"]["failed"].getBool and e["vm"]["error"].getStr.len > 0
    check e["intended"].ten == [0'i32, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    check step(h) == 0
    let later = trace(h)["seats"][6]
    check not later["decided"].getBool and later["observation"].kind == JNull
    check later["observation_missing_reason"].getStr == "program_failed"
    check later["vm"]["failed"].getBool
    pw_destroy(h)

  test "seats without a program report applied commands and no decision":
    let h = scripted(45, 600)
    check pw_set_seat_script(h, 4, nil, 0) == 0
    check pw_debug_set_trace(h, 1) == 0
    check step(h) == 0
    let e = trace(h)["seats"][4]
    check e["program"].getStr == "none" and not e["decided"].getBool
    check e["intended"].kind == JNull and e["normalized"].kind == JNull and e["vm"].kind == JNull
    check e["observation_missing_reason"].getStr == "no_program"
    discard e["applied"].ten
    pw_destroy(h)

  test "tracing and inspection change nothing: hashes, orders and saves match an untraced twin":
    # The twin restores the exact initial state. Process-local string owner IDs are canonical
    # in snapshots, so every subsequent save byte must match despite interleaved decisions.
    let traced = scripted(51, 900)
    let plain = scripted(51, 900)
    let start = save(traced)
    check pw_world_load(plain, cast[ptr UncheckedArray[byte]](unsafeAddr start[0]), start.len.int64) == 0
    check sameSave(traced, plain)
    check pw_debug_set_trace(traced, 1) == 0
    for t in 0..<400:
      if t == 150: check pw_debug_set_trace(traced, 0) == 0
      if t == 220: check pw_debug_set_trace(traced, 1) == 0
      discard statusText(traced)
      discard observationText(traced, t mod Seats)
      check sameSave(traced, plain)
      check step(traced) == 0
      check step(plain) == 0
      check pw_state_hash(traced) == pw_state_hash(plain)
      for s in 0..<Seats: check ordersEx(traced, s) == ordersEx(plain, s)
    check sameSave(traced, plain)
    check status(traced)["controller_sha256"] == status(plain)["controller_sha256"]
    pw_destroy(traced)
    pw_destroy(plain)

  test "disabling drops the record; a reset drops it and keeps tracing on":
    let h = scripted(53, 600)
    check pw_debug_set_trace(h, 1) == 0
    check step(h) == 0
    check pw_debug_trace_json(h, nil, 0) > 0
    check pw_debug_set_trace(h, 0) == 0
    check pw_debug_trace_json(h, nil, 0) == -2
    check pw_debug_set_trace(h, 1) == 0
    check step(h) == 0
    check pw_reset(h, 54, 600) == 0
    check pw_debug_trace_json(h, nil, 0) == -2
    check status(h)["trace_enabled"].getBool
    check step(h) == 0
    check trace(h)["tick"].getInt == 0
    pw_destroy(h)

suite "trace lifecycle and argument validation":
  test "script, shadow and policy changes invalidate captured evidence":
    let h = scripted(73, 600)
    defer: pw_destroy(h)
    check pw_debug_set_trace(h, 1) == 0
    check step(h) == 0
    check pw_set_seat_script(h, 0, cbuf(Stateful), Stateful.len.int32) == 0
    check pw_debug_trace_json(h, nil, 0) == -2
    check step(h) == 0
    check pw_set_seat_shadow_script(h, 1, cbuf(Stateful), Stateful.len.int32) == 0
    check pw_debug_trace_json(h, nil, 0) == -2
    check pw_set_seat_shadow_script(h, 1, nil, 0) == 0
    check step(h) == 0
    let manifest = $(%*{"schema": "paintbot-neural-basic/2",
      "observation_contract": ObservationContractTeamsView1Hash,
      "action_contract": ActionContractTeamsView1Hash})
    check pw_set_seat_policy_script(h, 2, cbuf(Stateful), Stateful.len.int32,
      cbuf(manifest), manifest.len.int32) == 0
    check pw_debug_trace_json(h, nil, 0) == -2
    check "policy_seat:2" in reasons(status(h))
    check not status(h)["supported"].getBool

  test "invalid buffers are refused without changing state":
    let h = scripted(75, 600)
    defer: pw_destroy(h)
    let before = save(h)
    check pw_debug_status_json(h, nil, 1) == -1
    check pw_debug_status_json(h, nil, -1) == -1
    check pw_debug_trace_json(h, nil, 1) == -1
    check pw_debug_trace_json(h, nil, -1) == -1
    check pw_debug_observation_json(h, 0, nil, 1) == -1
    check pw_debug_observation_json(h, 0, nil, -1) == -1
    let unchanged = save(h) == before
    check unchanged

suite "pw_debug_observation_json":
  test "the seat's pure SeatView observation, bad seats refused":
    let h = scripted(61, 600)
    let before = save(h)
    let a = observationText(h, 2)
    check observationText(h, 2) == a
    let unchanged = save(h) == before
    check unchanged
    let j = parseJson(a)
    check j["schema_version"].getStr == "paintbot_native_debug_v1"
    check j["seat"].getInt == 2 and j["tick"].getInt == 0 and j["phase"].getStr == "pre_decision"
    check j["observation"]["self"]["selfId"].kind == JInt
    check j["observation"]["self"].len == 21
    check pw_debug_observation_json(h, -1, nil, 0) == -1
    check pw_debug_observation_json(h, Seats.cint, nil, 0) == -1
    check pw_debug_observation_json(nil, 0, nil, 0) == -1
    check pw_debug_status_json(nil, nil, 0) == -1
    check pw_debug_trace_json(nil, nil, 0) == -1
    check pw_debug_set_trace(nil, 1) == -1
    pw_destroy(h)
