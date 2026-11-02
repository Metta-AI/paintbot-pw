## Public synthetic owned BASIC action-branch regressions. Training backend only.
## A branch substitutes a complete command, never a controller or its memory.
import std/[unittest, json]
import ../examples/paintbot/native_env

when not defined(pwTraining): {.error: "build with -d:pwTraining".}

const Source = """
TYPE Memo
  text AS STRING
END TYPE
DIM memo AS Memo
memo.text = memo.text + "x"
n = n + 1
r = rnd(100)
walkTo(selfX + 100 + n + r, selfY)
lookAt(selfX + 400, selfY)
"""
const CommandKeys = ["walk", "goal_x", "goal_z", "shoot", "aim_x", "aim_z",
  "charge_grenade", "sneak", "direct", "self_destruct"]
template ibuf(a: untyped): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](addr a[0])
proc save(h: pointer): seq[byte] =
  let n = pw_world_save(h, nil, 0)
  doAssert n > 0
  result = newSeq[byte](n)
  doAssert pw_world_save(h, cast[ptr UncheckedArray[byte]](addr result[0]), n) == n
proc restore(blob: seq[byte]): pointer =
  result = pw_create(999, 80)
  doAssert result != nil
  doAssert pw_world_load(result, cast[ptr UncheckedArray[byte]](unsafeAddr blob[0]), blob.len.int64) == 0
  doAssert pw_debug_set_trace(result, 1) == 0
proc step(h: pointer) =
  var actions: array[80, int32]
  var rewards, terminals: array[16, cfloat]
  doAssert pw_step(h, ibuf(actions),
    cast[ptr UncheckedArray[cfloat]](addr rewards[0]),
    cast[ptr UncheckedArray[cfloat]](addr terminals[0])) == 0
proc readJson(h: pointer, isTrace = false): JsonNode =
  let n = if isTrace: pw_debug_trace_json(h, nil, 0) else: pw_debug_status_json(h, nil, 0)
  doAssert n > 0
  var text = newString(n)
  let p = cast[ptr UncheckedArray[char]](addr text[0])
  doAssert (if isTrace: pw_debug_trace_json(h, p, n) else: pw_debug_status_json(h, p, n)) == n
  parseJson(text)
proc command(j: JsonNode): array[10, int32] =
  doAssert j.kind == JObject and j.len == 10
  for i, key in CommandKeys:
    if i in [1, 2, 4, 5]:
      doAssert j[key].kind == JInt
      result[i] = j[key].getInt.int32
    else:
      doAssert j[key].kind == JBool
      result[i] = j[key].getBool.int32
proc scripted(): pointer =
  result = pw_create(71, 80)
  doAssert result != nil
  let source = Source
  for seat in 0..<16:
    doAssert pw_set_seat_script(result, seat.cint,
      cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0

suite "owned BASIC one-command branches":
  test "no-op replacement preserves observations, intentions, applied commands and full snapshots":
    let parent = scripted()
    defer: pw_destroy(parent)
    step(parent)
    let checkpoint = save(parent)
    let baseline = restore(checkpoint)
    let branch = restore(checkpoint)
    defer: pw_destroy(baseline); pw_destroy(branch)
    require readJson(baseline)["supported"].getBool
    require readJson(branch)["supported"].getBool
    # Read the complete intended command from an independent baseline step, not by
    # deciding on the branch: its original BASIC VM must run exactly once in step.
    step(baseline)
    let expected = readJson(baseline, true)
    var replacement = command(expected["seats"][0]["normalized"])
    require pw_set_seat_command_ex(branch, 0, ibuf(replacement)) == 0
    step(branch)
    for future in 0..<4:
      let a = readJson(baseline, true)
      let b = readJson(branch, true)
      for seat in 0..<16:
        for field in ["observation", "intended", "normalized", "applied", "vm"]:
          check a["seats"][seat][field] == b["seats"][seat][field]
        check b["seats"][seat]["replaced_by_raw_command"].getBool == (future == 0 and seat == 0)
      check pw_state_hash(baseline) == pw_state_hash(branch)
      check readJson(baseline)["controller_sha256"] == readJson(branch)["controller_sha256"]
      let identicalSnapshots = save(baseline) == save(branch)
      check identicalSnapshots
      let unchangedParent = save(parent) == checkpoint
      check unchangedParent
      if future < 3:
        step(baseline)
        step(branch)

# Every seat walks to seat 0 whenever it can see it, so a different seat-0 action is
# answered by the other BASIC controllers on later ticks (a reactive future, not replay).
const Reactive = """
nn = nearAgents(20000)
tx = selfX + 100
ty = selfY
k = 0
while k < nn
  if nearAgentId(k) = 0 then
    tx = nearAgentX(k)
    ty = nearAgentY(k)
  end if
  k = k + 1
wend
walkTo(tx, ty)
"""
proc scripted(source: string, seed = 71'i32, ticks = 80'i32): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  for seat in 0..<16:
    doAssert pw_set_seat_script(result, seat.cint,
      cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0
proc reasons(h: pointer): seq[string] =
  for r in readJson(h)["reasons"]: result.add r.getStr
proc moved(c: array[10, int32], dx: int32): array[10, int32] =
  ## A legal, different command: walk elsewhere, aim elsewhere, every flag still 0 or 1.
  result = c
  result[0] = 1
  result[1] = c[1] + dx
  result[4] = c[4] - dx

suite "owned BASIC branch provenance and gates":
  test "changed legal action: first divergence at the replaced step, then reactive BASIC opponents":
    let parent = scripted(Reactive)
    defer: pw_destroy(parent)
    step(parent)
    let checkpoint = save(parent)
    let baseline = restore(checkpoint)
    let branch = restore(checkpoint)
    defer: pw_destroy(baseline); pw_destroy(branch)
    require readJson(branch)["supported"].getBool
    step(baseline)
    let first = readJson(baseline, true)
    var changed = moved(command(first["seats"][0]["normalized"]), -900)
    require changed != command(first["seats"][0]["applied"])
    require pw_set_seat_command_ex(branch, 0, ibuf(changed)) == 0
    step(branch)
    let a = first
    let b = readJson(branch, true)
    # The step itself: same pre-step world and decisions, only seat 0's executed command differs.
    check a["tick"] == b["tick"]
    check a["world_hash_before"] == b["world_hash_before"]
    check a["controller_sha256_before"] == b["controller_sha256_before"]
    check a["controller_sha256_after"] == b["controller_sha256_after"]
    for seat in 0..<16:
      for field in ["observation", "intended", "normalized", "vm"]:
        check a["seats"][seat][field] == b["seats"][seat][field]
      check (a["seats"][seat]["applied"] == b["seats"][seat]["applied"]) == (seat != 0)
      check b["seats"][seat]["replaced_by_raw_command"].getBool == (seat == 0)
    check command(b["seats"][0]["applied"]) == changed
    check a["world_hash_after"] != b["world_hash_after"]
    check pw_state_hash(baseline) != pw_state_hash(branch)
    # Afterwards nothing is replaced: the opponents' own programs answer the changed world.
    var reactedAt = -1
    for future in 1..40:
      step(baseline); step(branch)
      let fa = readJson(baseline, true)
      let fb = readJson(branch, true)
      for seat in 0..<16:
        check not fb["seats"][seat]["replaced_by_raw_command"].getBool
        if reactedAt < 0 and seat != 0 and fa["seats"][seat]["intended"] != fb["seats"][seat]["intended"]:
          reactedAt = future
      check readJson(baseline)["program_sha256"] == readJson(branch)["program_sha256"]
    check reactedAt >= 1
    check save(parent) == checkpoint

  test "parent and sibling isolation, duplicate setter and restart from the checkpoint":
    let parent = scripted(Reactive)
    defer: pw_destroy(parent)
    step(parent)
    let checkpoint = save(parent)
    let pristine = checkpoint
    let parentHash = pw_state_hash(parent)
    let probe = restore(checkpoint)
    defer: pw_destroy(probe)
    step(probe)
    let base = command(readJson(probe, true)["seats"][0]["normalized"])
    var x = moved(base, -900)
    var y = moved(base, 900)
    let sibA = restore(checkpoint)
    let sibB = restore(checkpoint)
    let twin = restore(checkpoint)
    defer: pw_destroy(sibA); pw_destroy(sibB); pw_destroy(twin)
    # Duplicate: a later call before the step replaces the earlier one.
    require pw_set_seat_command_ex(sibA, 0, ibuf(y)) == 0
    require pw_set_seat_command_ex(sibA, 0, ibuf(x)) == 0
    require pw_set_seat_command_ex(twin, 0, ibuf(x)) == 0
    require pw_set_seat_command_ex(sibB, 0, ibuf(y)) == 0
    check readJson(sibA)["pending_override"].getBool
    check "pending_override" in reasons(sibA)
    # Interleave in different orders; nothing one handle does reaches another.
    step(sibB); step(sibA); step(twin)
    check not readJson(sibA)["pending_override"].getBool
    check command(readJson(sibA, true)["seats"][0]["applied"]) == x
    check command(readJson(sibB, true)["seats"][0]["applied"]) == y
    for t in 0..<6:
      check save(sibA) == save(twin)
      check pw_state_hash(sibA) != pw_state_hash(sibB)
      check save(parent) == pristine
      check pw_state_hash(parent) == parentHash
      if t mod 2 == 0: step(sibA); step(sibB); step(twin)
      else: step(twin); step(sibB); step(sibA)
    check checkpoint == pristine
    # Restart: reloading the checkpoint into a branched handle replays the branch exactly.
    let atEnd = save(sibA)
    require pw_world_load(sibA, cast[ptr UncheckedArray[byte]](unsafeAddr checkpoint[0]), checkpoint.len.int64) == 0
    check save(sibA) == checkpoint
    require pw_set_seat_command_ex(sibA, 0, ibuf(x)) == 0
    for t in 0..<7: step(sibA)
    check save(sibA) == atEnd

  test "replacement normalization and illegal flag rejection leave the handle unchanged":
    let parent = scripted(Source)
    defer: pw_destroy(parent)
    step(parent)
    let checkpoint = save(parent)
    let h = restore(checkpoint)
    let far = restore(checkpoint)
    let farther = restore(checkpoint)
    defer: pw_destroy(h); pw_destroy(far); pw_destroy(farther)
    var ok = [1'i32, 999999, -5, 0, 100000, -100000, 0, 0, 0, 0]
    for flag in [0, 3, 6, 7, 8, 9]:
      for bad in [-1'i32, 2]:
        var c = ok
        c[flag] = bad
        check pw_set_seat_command_ex(h, 0, ibuf(c)) == -1
        if flag != 9:
          check pw_set_seat_command(h, 0, ibuf(c)) == -1
    check pw_set_seat_command_ex(nil, 0, ibuf(ok)) == -1
    check pw_set_seat_command_ex(h, -1, ibuf(ok)) == -1
    check pw_set_seat_command_ex(h, 16, ibuf(ok)) == -1
    check pw_set_seat_command_ex(h, 0, nil) == -1
    check not readJson(h)["pending_override"].getBool
    check readJson(h)["supported"].getBool
    check save(h) == checkpoint
    # Goal verbatim; aim clamped to the map, so two off-map aims on one side apply identically.
    var off2 = ok
    off2[4] = 200000; off2[5] = -200000
    require pw_set_seat_command_ex(far, 0, ibuf(ok)) == 0
    require pw_set_seat_command_ex(farther, 0, ibuf(off2)) == 0
    step(far); step(farther)
    let applied = readJson(far, true)["seats"][0]["applied"]
    check applied["walk"].getBool
    check applied["goal_x"].getInt == 999999 and applied["goal_z"].getInt == -5
    check applied["aim_x"].getInt < 100000 and applied["aim_z"].getInt > -100000
    check applied == readJson(farther, true)["seats"][0]["applied"]
    check save(far) == save(farther)

  test "branch points are refused outside pre-decision phase or with altering seat config":
    let h = scripted(Source)
    defer: pw_destroy(h)
    step(h)
    require readJson(h)["supported"].getBool
    require readJson(h)["phase"].getStr == "pre_decision"
    check pw_script_decide(h) == 1
    check readJson(h)["phase"].getStr == "post_decision_pre_step"
    check "phase_not_pre_decision" in reasons(h)
    check not readJson(h)["supported"].getBool
    step(h)
    check readJson(h)["supported"].getBool
    var c = [0'i32, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    require pw_set_seat_command_ex(h, 1, ibuf(c)) == 0
    check "pending_override" in reasons(h)
    step(h)
    check readJson(h)["supported"].getBool
    require pw_set_seat_override(h, 3, 1) == 0
    check "action_override:3" in reasons(h)
    require pw_set_seat_override(h, 3, 0) == 0
    require pw_set_seat_fire_period(h, 2, 4) == 0
    check "fire_period:2" in reasons(h)
    require pw_set_seat_fire_period(h, 2, 1) == 0
    let shadow = "walkTo(selfX, selfY)\n"
    require pw_set_seat_shadow_script(h, 4,
      cast[ptr UncheckedArray[char]](unsafeAddr shadow[0]), shadow.len.int32) == 0
    check "shadow_script:4" in reasons(h)
    let unscripted = pw_create(71, 80)
    defer: pw_destroy(unscripted)
    check "no_basic_program:0" in reasons(unscripted)
    let short = scripted(Source, 71, 3)
    defer: pw_destroy(short)
    for t in 0..<3: step(short)
    check "terminal" in reasons(short)

  test "a queued command dropped by pw_reset leaves no bytes behind":
    let a = pw_create(71, 80)
    let b = pw_create(71, 80)
    defer: pw_destroy(a); pw_destroy(b)
    var c = [1'i32, 1234, 2345, 1, 0, 0, 1, 1, 1, 0]
    require pw_set_seat_command_ex(a, 0, ibuf(c)) == 0
    require pw_reset(a, 72, 80) == 0
    require pw_reset(b, 72, 80) == 0
    check not readJson(a)["pending_override"].getBool
    let identical = save(a) == save(b)
    check identical
