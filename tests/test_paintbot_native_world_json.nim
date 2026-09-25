## The whole-world JSON (pw_world_json) through the native training ABI: sizing call,
## too-small buffer, bad arguments; the object parses with the pre-#51 bridge's shape
## (rulesVersion, heard, then the World fields: tick, 16 cogs and equipment, control hearts);
## reading it never changes the world hash; and a pw_set_seat_command walk order shows up
## as movement in later snapshots. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, json, math]
import ../examples/paintbot/[sim, native_env]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

proc snapshot(env: pointer): JsonNode =
  let n = pw_world_json(env, nil, 0)
  doAssert n > 0
  var buffer = newString(n)
  doAssert pw_world_json(env, cast[ptr UncheckedArray[char]](addr buffer[0]), n.int32) == n
  parseJson(buffer)

suite "pw_world_json":
  test "arguments and sizing":
    check pw_world_json(nil, nil, 0) == -1
    let env = pw_create(7, 600)
    check pw_world_json(env, nil, -1) == -1
    check pw_world_json(env, nil, 16) == -1
    let n = pw_world_json(env, nil, 0)
    check n > 100
    var small = newString(8)
    for i in 0..<small.len: small[i] = '#'
    check pw_world_json(env, cast[ptr UncheckedArray[char]](addr small[0]), 8) == n
    check small == "########"  # too small: nothing written
    pw_destroy(env)

  test "shape matches the old bridge's world line":
    let env = pw_create(11, 600)
    let w = snapshot(env)
    check w["rulesVersion"].getInt == NativeRules
    check w["heard"].kind == JObject
    check w["tick"].getInt == 0
    check w["cogs"].len == Seats
    check w["equipment"].len == Seats
    check w["controlHearts"].len > 0
    check w["cogs"][0].hasKey("pos")
    pw_destroy(env)

  test "reading is pure and commands move the seat":
    let env = pw_create(23, 600)
    let start = snapshot(env)
    let x0 = start["cogs"][0]["pos"]["x"].getInt
    let z0 = start["cogs"][0]["pos"]["z"].getInt
    # Goal: the nearest control heart at least 20 m away (a reachable point; arbitrary points can
    # sit inside terrain, where the walk stops at the nearest reachable spot).
    var goal = [0, 0]
    var best = Inf
    for h in start["controlHearts"].getElems:
      let (hx, hz) = (h["pos"]["x"].getInt, h["pos"]["z"].getInt)
      let d = hypot(float(hx - x0), float(hz - z0))
      if d > 2000 and d < best:
        best = d
        goal = [hx, hz]
    check best < Inf
    var actions = newSeq[int32](Seats * pw_action_count())
    var rewards = newSeq[cfloat](Seats)
    var terminals = newSeq[cfloat](Seats)
    for tick in 0..<96:
      var nine = [1'i32, goal[0].int32, goal[1].int32, 0, 0, 0, 0, 0, 0]
      check pw_set_seat_command(env, 0, cast[ptr UncheckedArray[int32]](addr nine[0])) == 0
      let before = pw_state_hash(env)
      discard snapshot(env)
      check pw_state_hash(env) == before  # a pure read
      check pw_step(env, cast[ptr UncheckedArray[int32]](addr actions[0]),
        cast[ptr UncheckedArray[cfloat]](addr rewards[0]), cast[ptr UncheckedArray[cfloat]](addr terminals[0])) == 0
    let later = snapshot(env)
    check later["tick"].getInt == 96
    let x1 = later["cogs"][0]["pos"]["x"].getInt
    let z1 = later["cogs"][0]["pos"]["z"].getInt
    let after = hypot(float(goal[0] - x1), float(goal[1] - z1))
    checkpoint "start (" & $x0 & "," & $z0 & ") end (" & $x1 & "," & $z1 & ") goal (" & $goal[0] & "," & $goal[1] & ")"
    check after < best / 2  # walked most of the way to the heart
    pw_destroy(env)
