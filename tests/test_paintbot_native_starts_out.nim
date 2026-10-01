## pw_set_seat_starts_out (training library only): a seat that begins every match already out. Unset, a match is
## byte-identical; set, the seat is out from tick 0 (hp 0, no lives), never respawns or acts on the world, and the
## match plays on; a side's last seat cannot be put out; the lone-survivor start (one seat of a side in, on one
## life) ends the match for the other side when that seat dies. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, importutils]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "curriculum handicaps exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
privateAccess(NativeEnv)

proc envOf(h: pointer): ptr NativeEnv = cast[ptr NativeEnv](h)

proc scriptedWorld(seed, ticks: int32, source: string): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  for slot in 0..<Seats:
    doAssert pw_set_seat_script(result, slot.cint,
      cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0

proc play(handle: pointer, ticks: int): seq[uint32] =
  var actions: array[LegacySeats*ActionSizes.len, int32]
  var rewards, terminals: array[LegacySeats, float32]
  for tick in 0..<ticks:
    if terminals[0] == 1: break
    doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    result.add pw_state_hash(handle)

proc winner(handle: pointer): int =
  var res: array[8, float32]
  doAssert pw_results(handle, fbuf(res)) == 0
  res[1].int

proc hitOnce(handle: pointer, victim, attacker, amount: int) =
  ## One damage event as the step deals it.
  let env = envOf(handle)
  env.world.cogs[victim].shield = 0
  handicap = addr env.handicapKnobs
  try: env.world.damage(victim, attacker, amount)
  finally: handicap = nil

suite "Seats that start out":
  configureRules(NativeRules)
  let baseSource = readFile(Base)

  test "unset (never called, or set and cleared) a scripted match is byte-identical":
    let reference = scriptedWorld(31, 1200, baseSource)
    let expected = play(reference, 1200)
    pw_destroy(reference)
    let h = scriptedWorld(31, 1200, baseSource)
    check pw_set_seat_starts_out(h, 3, 1) == 0
    check pw_set_seat_starts_out(h, 3, 0) == 0
    check pw_reset(h, 31, 1200) == 0
    check play(h, 1200) == expected
    pw_destroy(h)

  test "a seat set out starts with hp 0 and no lives, never respawns, and the match plays on":
    let h = scriptedWorld(7, 2400, baseSource)
    for seat in [3, 5, 8]: check pw_set_seat_starts_out(h, seat.cint, 1) == 0
    check pw_reset(h, 7, 2400) == 0                       # applies at the next reset
    let env = envOf(h)
    for seat in 0..<Seats:
      if seat in [3, 5, 8]:
        check env.world.cogs[seat].hp == 0 and env.world.equipment[seat].lives == 0
      else:
        check env.world.cogs[seat].hp > 0 and env.world.equipment[seat].lives > 0
    let start = [env.world.cogs[3].pos, env.world.cogs[5].pos, env.world.cogs[8].pos]
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    for tick in 0..<900:
      if terminals[0] == 1: break
      check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      for seat in [3, 5, 8]:
        doAssert env.world.cogs[seat].hp == 0 and env.world.equipment[seat].lives == 0
    check [env.world.cogs[3].pos, env.world.cogs[5].pos, env.world.cogs[8].pos] == start
    check env.world.tick >= 600                           # not ended at the start
    var stats: array[LegacySeats*8, int32]
    check pw_seat_stats(h, ibuf(stats)) == 0
    for seat in [3, 5, 8]:
      check stats[seat*8] == 0 and stats[seat*8+2] == 0   # dealt no damage, landed no hit
      check stats[seat*8+5] == 0                          # and never died: it was never in
    # kept across resets; cleared, the seat starts normally again
    check pw_reset(h, 8, 2400) == 0
    check env.world.cogs[3].hp == 0 and env.world.equipment[3].lives == 0
    check pw_set_seat_starts_out(h, 3, 0) == 0 and pw_reset(h, 8, 2400) == 0
    check env.world.cogs[3].hp > 0 and env.world.equipment[3].lives > 0
    check env.world.cogs[5].hp == 0
    pw_destroy(h)

  test "lone survivor: seven of a side out, the eighth on one life; the match ends when it dies":
    let h = scriptedWorld(11, 2400, baseSource)
    for seat in countup(3, 15, 2): check pw_set_seat_starts_out(h, seat.cint, 1) == 0
    check pw_set_seat_lives(h, 1, 1) == 0
    check pw_reset(h, 11, 2400) == 0
    let env = envOf(h)
    check env.world.cogs[1].hp > 0 and env.world.equipment[1].lives == 1
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check terminals[0] == 0 and winner(h) == -1           # one cog alive: the match is on
    if env.world.cogs[1].hp > 0:
      hitOnce(h, 1, 0, 100)                               # the survivor loses its only life
    check env.world.cogs[1].hp == 0 and env.world.equipment[1].lives == 0
    for tick in 0..<4:
      if terminals[0] == 1: break
      check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check terminals[0] == 1 and winner(h) == 0
    pw_destroy(h)

  test "refusals: a side's last seat, bad arguments":
    let h = pw_create(5, 2400)
    for seat in countup(0, 12, 2): check pw_set_seat_starts_out(h, seat.cint, 1) == 0
    check pw_set_seat_starts_out(h, 14, 1) == -1          # side 0's last seat stays in
    check not envOf(h).handicapKnobs.startsOut[14]
    check pw_set_seat_starts_out(h, 1, 1) == 0            # the other side is its own count
    check pw_set_seat_starts_out(h, 0, 0) == 0 and pw_set_seat_starts_out(h, 14, 1) == 0
    check pw_set_seat_starts_out(h, 0, 2) == -1
    check pw_set_seat_starts_out(h, -1, 1) == -1
    check pw_set_seat_starts_out(h, Seats.cint, 1) == -1
    check pw_set_seat_starts_out(nil, 0, 1) == -1
    pw_destroy(h)
