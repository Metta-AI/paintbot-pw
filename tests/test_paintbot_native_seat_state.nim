## Every seat's public body state (pw_seat_state) through the native training ABI: bad
## arguments; on base.bas matches (both teams scripted, so seats fight, die, respawn, carry
## hearts and pick up weapons) every tick's 16 x 8 floats equal the same fields read from
## pw_world_json (an independent serialisation of the world); reading never changes the
## world hash, and a twin handle that never reads has the same hash every tick.
## PW_SS_TICKS (default 1500) and PW_SS_SEEDS (default 2) size the matches.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, json, os, strutils]
import ../examples/paintbot/[sim, native_env]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])

proc snapshot(env: pointer): JsonNode =
  let n = pw_world_json(env, nil, 0)
  doAssert n > 0
  var buffer = newString(n)
  doAssert pw_world_json(env, cast[ptr UncheckedArray[char]](addr buffer[0]), n.int32) == n
  parseJson(buffer)

proc scripted(seed, ticks: int): pointer =
  result = pw_create(seed.int32, ticks.int32)
  let source = readFile(Base)
  for slot in 0..<Seats:
    doAssert pw_set_seat_script(result, slot.cint, cast[ptr UncheckedArray[char]](unsafeAddr source[0]),
      source.len.int32) == 0

proc expected(w: JsonNode): array[Seats*SeatStateFloats, float32] =
  for slot in 0..<Seats:
    let c = w["cogs"][slot]
    let e = w["equipment"][slot]
    let o = slot*SeatStateFloats
    result[o] = c["pos"]["x"].getInt.float32
    result[o+1] = c["pos"]["z"].getInt.float32
    result[o+2] = c["hp"].getInt.float32
    result[o+3] = e["armor"].getInt.float32
    result[o+4] = e["lives"].getInt.float32
    result[o+5] = c["respawn"].getInt.float32
    result[o+6] = (if c["carrying"].getBool: 1'f32 else: 0'f32)
    result[o+7] = float32((if e["grenade"].getBool: 1 else: 0) + (if e["sprayCan"].getBool: 2 else: 0))

suite "pw_seat_state":
  test "arguments":
    var out16: array[Seats*SeatStateFloats, cfloat]
    check pw_seat_state(nil, fbuf(out16)) == -1
    let env = pw_create(3, 100)
    check pw_seat_state(env, nil) == -1
    check pw_seat_state(env, fbuf(out16)) == 0
    pw_destroy(env)

  test "equals pw_world_json every tick; pure read":
    let ticks = parseInt(getEnv("PW_SS_TICKS", "1500"))
    let seeds = parseInt(getEnv("PW_SS_SEEDS", "2"))
    var deaths, carries, respawning, grenades = 0
    for seed in 1..seeds:
      let env = scripted(seed * 17, ticks)
      let twin = scripted(seed * 17, ticks)
      var actions = newSeq[int32](Seats * pw_action_count())
      var rewards = newSeq[cfloat](Seats)
      var terminals = newSeq[cfloat](Seats)
      var got: array[Seats*SeatStateFloats, cfloat]
      for tick in 0..<ticks:
        let before = pw_state_hash(env)
        check pw_seat_state(env, fbuf(got)) == 0
        check pw_state_hash(env) == before
        check pw_state_hash(twin) == before
        let want = expected(snapshot(env))
        for i in 0..<got.len:
          if got[i] != want[i]:
            checkpoint "seed " & $seed & " tick " & $tick & " float " & $i & ": " & $got[i] & " != " & $want[i]
            check got[i] == want[i]
            break
        for slot in 0..<Seats:
          let o = slot*SeatStateFloats
          if got[o+5] > 0: inc respawning
          if got[o+6] > 0: inc carries
          if (got[o+7].int and 1) != 0: inc grenades
        let rc = pw_step(env, cast[ptr UncheckedArray[int32]](addr actions[0]),
          cast[ptr UncheckedArray[cfloat]](addr rewards[0]), cast[ptr UncheckedArray[cfloat]](addr terminals[0]))
        check pw_step(twin, cast[ptr UncheckedArray[int32]](addr actions[0]),
          cast[ptr UncheckedArray[cfloat]](addr rewards[0]), cast[ptr UncheckedArray[cfloat]](addr terminals[0])) == rc
        if rc != 0 or terminals[0] > 0: break
      var stats: array[Seats*8, int32]
      check pw_seat_stats(env, cast[ptr UncheckedArray[int32]](addr stats[0])) == 0
      for slot in 0..<Seats: deaths += stats[slot*8+5]
      pw_destroy(env)
      pw_destroy(twin)
    checkpoint "deaths " & $deaths & " respawning-seat-ticks " & $respawning & " carrying-seat-ticks " & $carries &
      " grenade-seat-ticks " & $grenades
    check deaths > 0          # the matches exercised death / respawn,
    check respawning > 0
    check grenades > 0        # and equipment (carrying is reported, not required: rules 45 hearts are owned)
