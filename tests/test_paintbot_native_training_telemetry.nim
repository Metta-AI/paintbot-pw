## Training telemetry on the native environment: pw_seat_grenade_stats, pw_seat_equip_stats and
## pw_heart_terrain. Reading them changes nothing (hashes identical); a scripted throw moves the grenade
## counters; armor and uniform pickups move the equipment counters; the counters agree with
## pw_seat_stats / pw_seat_weapon_stats over full scripted matches.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, importutils]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "training telemetry exists only under -d:pwTraining".}

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

proc play(handle: pointer, ticks: int, read: bool): seq[uint32] =
  var actions: array[LegacySeats*ActionSizes.len, int32]
  var rewards, terminals: array[LegacySeats, float32]
  var six: array[6, int32]
  var eight: array[8, int32]
  var hearts: array[128, int32]
  for tick in 0..<ticks:
    if terminals[0] == 1: break
    doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    if read:
      for slot in 0..<Seats:
        doAssert pw_seat_grenade_stats(handle, slot.cint, ibuf(six)) == 0
        doAssert pw_seat_equip_stats(handle, slot.cint, ibuf(eight)) == 0
      doAssert pw_heart_terrain(handle, ibuf(hearts), hearts.len.int32) >= 0
    result.add pw_state_hash(handle)

proc stepWith(handle: pointer, actions: var array[LegacySeats*ActionSizes.len, int32], ticks = 1) =
  var rewards, terminals: array[LegacySeats, float32]
  for t in 0..<ticks: doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0

suite "Native training telemetry":
  configureRules(NativeRules)
  let baseSource = readFile(Base)

  test "reading the new telemetry every tick leaves a scripted world byte-identical":
    let reference = scriptedWorld(31, 1200, baseSource)
    let expected = play(reference, 1200, false)
    pw_destroy(reference)
    let reading = scriptedWorld(31, 1200, baseSource)
    check play(reading, 1200, true) == expected
    pw_destroy(reading)

  test "a scripted throw: release counts once; a blast on an enemy moves hits and damage":
    let h = pw_create(4, 2400)
    require h != nil
    defer: pw_destroy(h)
    let w = addr envOf(h).world
    w[].equipment[0].grenade = true
    var actions: array[LegacySeats*ActionSizes.len, int32]
    actions[0*ActionSizes.len + 3] = 1          # charge
    stepWith(h, actions, 10)
    actions[0*ActionSizes.len + 3] = 0          # release
    stepWith(h, actions, 1)
    var six: array[6, int32]
    check pw_seat_grenade_stats(h, 0, ibuf(six)) == 0
    check six[0] == 1
    require w[].grenades.len > 0
    let lob = w[].grenades[^1]
    check lob.owner == 0
    # Put enemy seat 1 (team 1) on the landing point, unshielded, and let the grenade land.
    w[].cogs[1].pos = lob.target; w[].cogs[1].goal = lob.target
    var waited = 0
    while w[].grenades.len > 0 and waited < 200:
      w[].cogs[1].shield = 0
      w[].cogs[1].pos = lob.target; w[].cogs[1].goal = lob.target
      stepWith(h, actions, 1); inc waited
    check pw_seat_grenade_stats(h, 0, ibuf(six)) == 0
    check six[1] >= 1 and six[3] >= 1           # enemy hit and health removed
    var stats: array[LegacySeats*8, int32]
    check pw_seat_stats(h, ibuf(stats)) == 0
    check six[1] <= stats[0*8 + 2] and six[3] <= stats[0*8 + 0]
    check pw_seat_grenade_stats(h, 16, ibuf(six)) == -1
    check pw_seat_grenade_stats(nil, 0, ibuf(six)) == -1

  test "armor and uniform pickups, the health armor soaks, and ticks disguised":
    let h = pw_create(2, 2400)
    require h != nil
    defer: pw_destroy(h)
    let w = addr envOf(h).world
    var armorAt, uniformAt = -1
    for k, p in w[].pickups:
      if p.kind == armorPickup and armorAt < 0: armorAt = k
      if p.kind == uniformPickup and uniformAt < 0: uniformAt = k
    require armorAt >= 0
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var eight: array[8, int32]
    w[].cogs[0].pos = w[].pickups[armorAt].pos; w[].cogs[0].goal = w[].pickups[armorAt].pos
    stepWith(h, actions, 1)
    check pw_seat_equip_stats(h, 0, ibuf(eight)) == 0
    check eight[0] == 1 and w[].equipment[0].armor == 3
    # One 2-point blow on the armored seat: the armor soaks both points.
    w[].cogs[0].shield = 0
    combatTelemetry = addr envOf(h).stats
    try: w[].damage(0, 1, 2)
    finally: combatTelemetry = nil
    check pw_seat_equip_stats(h, 0, ibuf(eight)) == 0
    check eight[5] == 2
    if uniformAt >= 0:
      w[].cogs[2].pos = w[].pickups[uniformAt].pos; w[].cogs[2].goal = w[].pickups[uniformAt].pos
      stepWith(h, actions, 1)
      check pw_seat_equip_stats(h, 2, ibuf(eight)) == 0
      check eight[1] == 1 and w[].uniforms[2]
      let before = eight[6]
      stepWith(h, actions, 5)
      check pw_seat_equip_stats(h, 2, ibuf(eight)) == 0
      check eight[6] == before + 5
    check pw_seat_equip_stats(h, -1, ibuf(eight)) == -1

  test "over full scripted matches the counters agree with pw_seat_stats and pw_seat_weapon_stats":
    for seed in [41'i32, 42]:
      let h = scriptedWorld(seed, 2400, baseSource)
      discard play(h, 2400, false)
      var stats: array[LegacySeats*8, int32]
      check pw_seat_stats(h, ibuf(stats)) == 0
      var six: array[6, int32]
      var nine: array[9, int32]
      var eight: array[8, int32]
      for slot in 0..<Seats:
        check pw_seat_grenade_stats(h, slot.cint, ibuf(six)) == 0
        check pw_seat_weapon_stats(h, slot.cint, ibuf(nine)) == 0
        check six[2] == nine[1]                       # grenade kills, both calls
        check six[1] <= stats[slot*8 + 2]             # grenade enemy hits <= all enemy hits
        check six[3] <= stats[slot*8 + 0]             # grenade enemy damage <= all enemy damage
        check six[5] <= stats[slot*8 + 1]             # grenade team damage <= all team damage
        check pw_seat_equip_stats(h, slot.cint, ibuf(eight)) == 0
        for v in eight: check v >= 0
      check pw_reset(h, seed, 2400) == 0
      check pw_seat_grenade_stats(h, 0, ibuf(six)) == 0 and six == [0'i32, 0, 0, 0, 0, 0]
      pw_destroy(h)

  test "pw_heart_terrain: one slot per control heart, capacity-bounded, bits 0..1":
    let h = pw_create(1, 600)
    require h != nil
    defer: pw_destroy(h)
    let n = envOf(h).world.controlHearts.len
    var hearts: array[128, int32]
    check pw_heart_terrain(h, ibuf(hearts), hearts.len.int32) == n.cint
    for k in 0..<n: check hearts[k] in 0'i32..3'i32
    var two: array[2, int32]
    check pw_heart_terrain(h, ibuf(two), 2) == n.cint   # truncated write, full count
    check two[0] == hearts[0] and two[1] == hearts[1]
    check pw_heart_terrain(h, nil, 0) == n.cint          # sizing call
    check pw_heart_terrain(nil, ibuf(hearts), 1) == -1
    check pw_heart_terrain(h, nil, 4) == -1
