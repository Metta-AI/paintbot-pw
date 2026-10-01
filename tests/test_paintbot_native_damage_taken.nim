## pw_seat_damage_taken_stats (training library only): damage taken by source. Reading it changes nothing
## (hashes identical); over full scripted matches the four hit counts sum to pw_seat_stats' hits_taken, and the
## health lost to enemy guns, grenades and spray, summed over victims, equals the damage the attackers dealt by
## that weapon (pw_seat_stats, pw_seat_grenade_stats, pw_seat_spray_stats), summed over attackers.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "training telemetry exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc scriptedWorld(seed, ticks: int32, source: string): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  for slot in 0..<Seats:
    doAssert pw_set_seat_script(result, slot.cint,
      cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0

proc play(handle: pointer, ticks: int, read: bool): seq[uint32] =
  var actions: array[LegacySeats*ActionSizes.len, int32]
  var rewards, terminals: array[LegacySeats, float32]
  var eight: array[8, int32]
  for tick in 0..<ticks:
    if terminals[0] == 1: break
    doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    if read:
      for slot in 0..<Seats: doAssert pw_seat_damage_taken_stats(handle, slot.cint, ibuf(eight)) == 0
    result.add pw_state_hash(handle)

suite "Damage taken by source":
  configureRules(NativeRules)
  let baseSource = readFile(Base)

  test "reading it every tick leaves a scripted world byte-identical":
    let reference = scriptedWorld(31, 1200, baseSource)
    let expected = play(reference, 1200, false)
    pw_destroy(reference)
    let reading = scriptedWorld(31, 1200, baseSource)
    check play(reading, 1200, true) == expected
    pw_destroy(reading)

  test "full scripted matches: hits sum to hits_taken; taken by weapon equals dealt by weapon":
    var gunTotal, grenadeTotal, sprayTotal, otherHits = 0
    for seed in [41'i32, 42, 43, 44]:
      checkpoint "seed " & $seed
      let h = scriptedWorld(seed, 2400, baseSource)
      discard play(h, 2400, false)
      var stats: array[LegacySeats*8, int32]
      check pw_seat_stats(h, ibuf(stats)) == 0
      var taken: array[4, int]                 # health lost, summed over victims, by source
      var dealtEnemy, dealtGrenade, dealtSpray, dealtTeam = 0
      for slot in 0..<Seats:
        var eight: array[8, int32]
        var six: array[6, int32]
        var four: array[4, int32]
        check pw_seat_damage_taken_stats(h, slot.cint, ibuf(eight)) == 0
        check pw_seat_grenade_stats(h, slot.cint, ibuf(six)) == 0
        check pw_seat_spray_stats(h, slot.cint, ibuf(four)) == 0
        check eight[0] + eight[2] + eight[4] + eight[6] == stats[slot*8+3]   # hits_taken
        for k in 0..3:
          check eight[2*k] >= 0 and eight[2*k+1] >= 0
          check eight[2*k] > 0 or eight[2*k+1] == 0                         # no health lost without a hit
          taken[k] += eight[2*k+1]
        otherHits += eight[6]
        dealtEnemy += stats[slot*8]
        dealtTeam += stats[slot*8+1]
        dealtGrenade += six[3]
        dealtSpray += four[0]
      let dealtGun = dealtEnemy - dealtGrenade - dealtSpray
      check taken[0] == dealtGun
      check taken[1] == dealtGrenade
      check taken[2] == dealtSpray
      check taken[3] >= dealtTeam                # teammates' damage, plus self and map
      gunTotal += taken[0]; grenadeTotal += taken[1]; sprayTotal += taken[2]
      pw_destroy(h)
    echo "health lost over 4 matches: gun ", gunTotal, ", grenade ", grenadeTotal, ", spray ", sprayTotal,
      "; other hits ", otherHits
    check gunTotal > 0

  test "zero after create and reset; bad arguments":
    let h = scriptedWorld(5, 2400, baseSource)
    var eight: array[8, int32]
    check pw_seat_damage_taken_stats(h, 0, ibuf(eight)) == 0 and eight == default(array[8, int32])
    discard play(h, 600, false)
    var any = 0
    for slot in 0..<Seats:
      check pw_seat_damage_taken_stats(h, slot.cint, ibuf(eight)) == 0
      for v in eight: any += v
    check any > 0
    check pw_reset(h, 6, 2400) == 0
    for slot in 0..<Seats:
      check pw_seat_damage_taken_stats(h, slot.cint, ibuf(eight)) == 0 and eight == default(array[8, int32])
    check pw_seat_damage_taken_stats(h, Seats.cint, ibuf(eight)) == -1
    check pw_seat_damage_taken_stats(h, -1, ibuf(eight)) == -1
    check pw_seat_damage_taken_stats(h, 0, nil) == -1
    check pw_seat_damage_taken_stats(nil, 0, ibuf(eight)) == -1
    pw_destroy(h)
