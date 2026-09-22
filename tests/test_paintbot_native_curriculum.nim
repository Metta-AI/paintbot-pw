## Curriculum knobs on the native training environment: a fire-gated base.bas seat fires
## at most once per period of cooldown windows and no more often than ungated; a damage-
## scaled seat lands hits that deal nothing; defaults leave the world hash unchanged.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "curriculum knobs exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

var shots: array[Seats, seq[int32]]
var issued = 0 # Ticks on which seat 0's script ordered a shot (before the gate).
observeShot = proc(tick: int32, slot: int) = shots[slot].add tick

proc scriptedWorld(seed, ticks: int32, source: string): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  for slot in 0..<Seats:
    doAssert pw_set_seat_script(result, slot.cint,
      cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0

proc play(handle: pointer, ticks: int): seq[uint32] =
  var actions: array[Seats*ActionSizes.len, int32]
  var rewards, terminals: array[Seats, float32]
  var orders: array[10, int32]
  for slot in 0..<Seats: shots[slot] = @[]
  issued = 0
  for tick in 0..<ticks:
    if terminals[0] == 1: break
    doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    doAssert pw_seat_orders(handle, 0, ibuf(orders)) == 0
    if orders[3] == 1: inc issued
    result.add pw_state_hash(handle)

suite "Native curriculum knobs":
  configureRules(NativeRules)
  let baseSource = readFile(Base)
  test "a gated base.bas seat fires at most once per period of cooldown windows":
    # The worlds diverge after the first suppressed shot, so counts across worlds are
    # not comparable; the gate's promise is per window: honoured shots are at least
    # period x 24 ticks apart, so at most span/(period x 24)+1 of them, and never more
    # than the script ordered. Ungated, base.bas orders a shot most ticks it sees a foe
    # and the gun fires every cooldown window it is allowed to.
    for seed in [11'i32, 12]:
      let plain = scriptedWorld(seed, 2400, baseSource)
      let plainHashes = play(plain, 2400)
      let ungated = shots[0].len
      let ungatedOrders = issued
      pw_destroy(plain)
      check ungated >= 8
      check ungated <= ungatedOrders
      for period in [2'i32, 4]:
        let gated = scriptedWorld(seed, 2400, baseSource)
        check pw_set_seat_fire_period(gated, 0, period) == 0
        let gatedHashes = play(gated, 2400)
        let fired = shots[0]
        check fired.len > 0
        check fired.len <= issued
        check fired.len <= gatedHashes.len div (period.int*FireCooldownTicks) + 1
        for i in 1..<fired.len: check fired[i]-fired[i-1] >= period*FireCooldownTicks.int32
        check pw_seat_script_status(gated, 0, nil, 0) == 1 # The script ran untouched.
        check gatedHashes != plainHashes
        # Period 1 on the same handle after a reset is exact again.
        check pw_set_seat_fire_period(gated, 0, 1) == 0
        check pw_reset(gated, seed, 2400) == 0
        check play(gated, 2400) == plainHashes
        pw_destroy(gated)
  test "period 1 and scale 1000 leave a scripted world byte-identical":
    let reference = scriptedWorld(21, 1200, baseSource)
    let expected = play(reference, 1200)
    pw_destroy(reference)
    let knobbed = scriptedWorld(21, 1200, baseSource)
    for slot in 0..<Seats:
      check pw_set_seat_fire_period(knobbed, slot.cint, 1) == 0
      check pw_set_seat_damage_scale(knobbed, slot.cint, 1000) == 0
    check play(knobbed, 1200) == expected
    pw_destroy(knobbed)
  test "a damage-scaled seat lands hits that deal nothing; invalid arguments are refused":
    let handle = scriptedWorld(11, 2400, baseSource)
    check pw_set_seat_damage_scale(handle, 0, 0) == 0
    discard play(handle, 2400)
    var stats: array[Seats*8, int32]
    check pw_seat_stats(handle, ibuf(stats)) == 0
    check stats[2] > 0      # hits_enemy landed
    check stats[0] == 0     # damage_dealt_enemy
    check stats[4] == 0     # kills
    check pw_set_seat_fire_period(handle, 0, 0) == -1
    check pw_set_seat_fire_period(handle, 16, 2) == -1
    check pw_set_seat_damage_scale(handle, 0, -1) == -1
    check pw_set_seat_damage_scale(nil, 0, 1000) == -1
    pw_destroy(handle)
