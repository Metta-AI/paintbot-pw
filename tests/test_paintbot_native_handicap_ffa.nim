## Curriculum handicaps and per-seat counters in FFA-kin (Heartland: ffa.view.1, ffa_kin, live
## rules): pw_set_seat_max_hp above the rules' 10, pw_set_seat_damage_scale in a real shooting
## encounter, pw_set_seat_capture_ticks on the FFA control-heart capture, and the pickup / shout
## counters (pw_seat_pickup_stats, pw_seat_shout_stats) against hand-counted scenarios. Every
## knob neutral (and every counter read) leaves a scripted Heartland match byte-identical.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, importutils]
import ../examples/paintbot/[sim, kinship, neural_contract, native_env]

when not defined(pwTraining): {.error: "curriculum handicaps exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const HeartlandConfig = """{"seed": 2026, "max_ticks": 8640, "mode": "ffa_kin", "kin_layout": "cousins"}"""
privateAccess(NativeEnv)

proc envOf(h: pointer): ptr NativeEnv = cast[ptr NativeEnv](h)
proc cp(text: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr text[0])
proc ip(buffer: var seq[int32]): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr buffer[0])
proc fp(buffer: var seq[float32]): ptr UncheckedArray[cfloat] = cast[ptr UncheckedArray[cfloat]](addr buffer[0])

proc heartland(seed = 2026'i32, ticks = 2400'i32): pointer =
  ## A 16-seat Heartland handle (FFA-kin, ffa.view.1, live rules).
  result = pw_create_observation(7, 0, ocFfaView1.int32)
  doAssert result != nil
  doAssert pw_set_rules(result, LiveRules) == 0
  doAssert pw_set_config_json(result, cp(HeartlandConfig), HeartlandConfig.len.int32, nil, 0) == 0
  doAssert pw_set_seats(result, 16) == 0
  doAssert pw_reset(result, seed, ticks) == 0
  doAssert pw_game_mode(result) == 1

proc step(h: pointer, commands: seq[array[9, int32]] = @[]) =
  ## One pw_step with every seat on a raw command: `commands[s]` for the seats it lists, the
  ## empty command (stay, no aim, no fire) for the rest.
  let n = pw_seats(h).int
  for s in 0..<n:
    var c: array[9, int32]
    if s < commands.len: c = commands[s]
    doAssert pw_set_seat_command(h, s.cint, cast[ptr UncheckedArray[int32]](addr c[0])) == 0
  var actions = newSeq[int32](n*32)
  var rewards, terminals = newSeq[float32](n)
  doAssert pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0

proc place(h: pointer, slot: int, p: Point) =
  let w = addr envOf(h).world
  w[].cogs[slot].pos = p; w[].cogs[slot].goal = p

proc farHeart(h: pointer, target: int): int =
  ## The control heart farthest from `target`.
  let w = addr envOf(h).world
  result = target
  for k, heart in w[].controlHearts:
    if distance2(heart.pos, w[].controlHearts[target].pos) > distance2(w[].controlHearts[result].pos, w[].controlHearts[target].pos):
      result = k

proc parkOthers(h: pointer, keep: openArray[int], at: Point) =
  for s in 0..<pw_seats(h).int:
    if s notin keep: h.place(s, at)

proc scripted(source: string): pointer =
  result = heartland(2026, 1200)
  for seat in 0..<pw_seats(result):
    doAssert pw_set_seat_script(result, seat.cint, cp(source), source.len.int32) == 0
  doAssert pw_reset(result, 2026, 1200) == 0

proc playHashes(h: pointer, ticks: int, readCounters = false): seq[uint32] =
  let n = pw_seats(h).int
  var actions = newSeq[int32](n*32)
  var rewards, terminals = newSeq[float32](n)
  var stats = newSeq[int32](n*8)
  var five = newSeq[int32](5)
  for tick in 0..<ticks:
    if terminals[0] == 1: break
    doAssert pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0
    if readCounters:
      doAssert pw_seat_stats(h, ip(stats)) == 0
      for s in 0..<n:
        doAssert pw_seat_pickup_stats(h, s.cint, ip(five)) == 0
        doAssert pw_seat_shout_stats(h, s.cint, ip(five)) == 0
    result.add pw_state_hash(h)

suite "FFA-kin handicaps and counters (Heartland)":
  teardown:
    configureSeats(LegacySeats)

  test "every knob neutral, and reading every counter, leaves a scripted Heartland match byte-identical":
    let source = readFile(Root / "coworld/heartland/players/ffa.bas")
    let reference = scripted(source)
    let expected = playHashes(reference, 1200)
    pw_destroy(reference)
    let knobbed = scripted(source)
    for slot in 0..<pw_seats(knobbed):
      check pw_set_seat_max_hp(knobbed, slot.cint, 25) == 0 and pw_set_seat_max_hp(knobbed, slot.cint, 0) == 0
      check pw_set_seat_capture_ticks(knobbed, slot.cint, 36) == 0 and pw_set_seat_capture_ticks(knobbed, slot.cint, 0) == 0
      check pw_set_seat_damage_scale(knobbed, slot.cint, 500) == 0 and pw_set_seat_damage_scale(knobbed, slot.cint, 1000) == 0
    check pw_reset(knobbed, 2026, 1200) == 0
    let got = playHashes(knobbed, 1200, readCounters = true)
    check got.len == expected.len and got == expected
    pw_destroy(knobbed)

  test "max_hp above the rules' 10 in FFA: spawns with it at the next reset; 0 restores 10; 1..30":
    let h = heartland()
    defer: pw_destroy(h)
    check maxHp() == FfaMaxHp
    check pw_set_seat_max_hp(h, 0, 15) == 0 and pw_set_seat_max_hp(h, 1, 5) == 0 and pw_set_seat_max_hp(h, 2, 30) == 0
    check envOf(h).world.cogs[0].hp == FfaMaxHp   # not until the next reset
    check pw_reset(h, 2026, 2400) == 0
    let w = addr envOf(h).world
    check w[].cogs[0].hp == 15 and w[].cogs[1].hp == 5 and w[].cogs[2].hp == 30 and w[].cogs[3].hp == FfaMaxHp
    check pw_set_seat_max_hp(h, 0, 0) == 0
    check pw_reset(h, 2026, 2400) == 0
    check envOf(h).world.cogs[0].hp == FfaMaxHp and envOf(h).world.cogs[1].hp == 5
    check pw_set_seat_max_hp(h, 0, 31) == -1 and pw_set_seat_max_hp(h, 0, -1) == -1 and pw_set_seat_max_hp(h, 16, 3) == -1

  test "damage_scale 500 halves the damage a seat deals in a shooting encounter; same hits":
    proc encounter(permille: int32): tuple[hits, removed: int32] =
      let h = heartland(2026, 2400)
      defer: pw_destroy(h)
      doAssert pw_set_seat_max_hp(h, 1, 30) == 0
      doAssert pw_reset(h, 2026, 2400) == 0
      doAssert pw_set_seat_damage_scale(h, 0, permille) == 0
      let w = addr envOf(h).world
      let a = w[].controlHearts[0].pos
      var v = a
      for d in [(500, 0), (-500, 0), (0, 500), (0, -500), (350, 350), (-350, -350)]:
        let p = point(a.x.int+d[0], a.z.int+d[1])
        if not w[].blocked(p) and w[].traversable(a, p): v = p; break
      doAssert v != a
      h.place(0, a); h.place(1, v)
      h.parkOthers([0, 1], w[].controlHearts[h.farHeart(0)].pos)
      let start = w[].cogs[1].hp
      for t in 0..<200:
        h.step(@[[0'i32, 0, 0, 1, v.x, v.z, 0, 0, 0]])
      var stats = newSeq[int32](pw_seats(h)*8)
      doAssert pw_seat_stats(h, ip(stats)) == 0
      doAssert w[].cogs[1].hp > 0
      (stats[1*8+3], start - w[].cogs[1].hp)
    let full = encounter(1000)
    let half = encounter(500)
    checkpoint "full " & $full & " half " & $half
    check full.hits > 0 and full.removed > 0
    check half.hits == full.hits
    check half.removed == full.removed div 2

  test "capture_ticks: a lone seat takes an unowned FFA control heart in that many ticks":
    proc captureTime(knob: int32, knobSeat = 0): int =
      let h = heartland(2026, 2400)
      defer: pw_destroy(h)
      doAssert pw_set_seat_capture_ticks(h, knobSeat.cint, knob) == 0
      let w = addr envOf(h).world
      let target = 0
      doAssert w[].controlHearts[target].owner == -1
      h.place(0, w[].controlHearts[target].pos)
      h.parkOthers([0], w[].controlHearts[h.farHeart(target)].pos)
      result = 0
      while w[].controlHearts[target].owner != 0 and result < 600:
        h.step(); inc result
    let normal = captureTime(0)
    let slow = captureTime(144)
    let fast = captureTime(36)
    let other = captureTime(36, knobSeat = 5)
    checkpoint "normal " & $normal & " slow " & $slow & " fast " & $fast
    check normal in (HeartCaptureTicks - 2)..(HeartCaptureTicks + 2)
    check slow - normal == 144 - HeartCaptureTicks
    check normal - fast == HeartCaptureTicks - 36
    check other == normal   # another seat's knob does not touch seat 0
    let h = heartland()
    defer: pw_destroy(h)
    check pw_set_seat_capture_ticks(h, 0, -1) == -1 and pw_set_seat_capture_ticks(h, 0, 1441) == -1
    check pw_set_seat_capture_ticks(h, 16, 72) == -1 and pw_set_seat_capture_ticks(nil, 0, 72) == -1
    check pw_set_seat_capture_ticks(h, 0, 1) == 0 and pw_set_seat_capture_ticks(h, 0, 1440) == 0

  test "pickup counters match a hand-counted walk over the pickups":
    let h = heartland()
    defer: pw_destroy(h)
    let w = addr envOf(h).world
    # Park everyone but seat 0 where no pickup is within reach.
    var park = -1
    for k, heart in w[].controlHearts:
      var clear = true
      for p in w[].pickups:
        if distance2(p.pos, heart.pos) <= 400*400: clear = false
      if clear: park = k; break
    require park >= 0
    h.parkOthers([0], w[].controlHearts[park].pos)
    var expected: array[PickupKind, int32]
    var byKind: array[PickupKind, seq[int]]
    for k, p in w[].pickups: byKind[p.kind].add k
    checkpoint "pickups " & $w[].pickups.len
    for kind in [grenadePickup, sprayPickup, medkitPickup, armorPickup]:
      if byKind[kind].len == 0: continue
      let k = byKind[kind][0]
      # 1. Needed: taken.
      case kind
      of grenadePickup: w[].equipment[0].grenade = false
      of sprayPickup: w[].equipment[0].sprayCan = false
      of medkitPickup: w[].cogs[0].hp = 1
      of armorPickup: w[].equipment[0].armor = 0
      else: discard
      h.place(0, w[].pickups[k].pos); h.step()
      inc expected[kind]
      check w[].pickups[k].readyAt > w[].tick
      if kind == medkitPickup: check w[].cogs[0].hp == FfaMaxHp
      # 2. The same pickup again while it recharges: nothing.
      h.place(0, point(w[].pickups[k].pos.x.int+300, w[].pickups[k].pos.z.int)); h.step()
      h.place(0, w[].pickups[k].pos); h.step()
      # 3. Another ready pickup of the kind, not needed: nothing.
      if byKind[kind].len > 1:
        let other = byKind[kind][1]
        h.place(0, w[].pickups[other].pos); h.step()
        check w[].pickups[other].readyAt <= w[].tick
    var got = newSeq[int32](5)
    check pw_seat_pickup_stats(h, 0, ip(got)) == 0
    for kind in PickupKind: check got[kind.ord] == expected[kind]
    var total = 0
    for kind in PickupKind: total += expected[kind]
    check total > 0
    for s in 1..<pw_seats(h).int:
      check pw_seat_pickup_stats(h, s.cint, ip(got)) == 0
      check got == @[0'i32, 0, 0, 0, 0]
    check pw_seat_pickup_stats(h, 16, ip(got)) == -1 and pw_seat_pickup_stats(h, 0, nil) == -1
    check pw_reset(h, 2026, 2400) == 0
    check pw_seat_pickup_stats(h, 0, ip(got)) == 0 and got == @[0'i32, 0, 0, 0, 0]

  test "shout counters match a hand-counted conversation (cap 4 a tick, 256 bytes a shout)":
    var long = ""
    for i in 0..<300: long.add 'a'
    let chatty = "shout(strNew(\"hi\"))\nshout(strNew(\"abcd\"))\nshout(strNew(\"x\"))\nshout(strNew(\"y\"))\n" &
      "shout(strNew(\"dropped\"))\nshout(strNew(\"dropped\"))\n"
    let loud = "shout(strNew(\"" & long & "\"))\n"
    let h = heartland()
    defer: pw_destroy(h)
    check pw_set_seat_script(h, 0, cp(chatty), chatty.len.int32) == 0
    check pw_set_seat_script(h, 3, cp(loud), loud.len.int32) == 0
    var msg = newSeq[char](256)
    check pw_seat_script_status(h, 0, cast[ptr UncheckedArray[char]](addr msg[0]), 256) == 1
    check pw_seat_script_status(h, 3, cast[ptr UncheckedArray[char]](addr msg[0]), 256) == 1
    let w = addr envOf(h).world
    let p = w[].controlHearts[0].pos
    h.place(0, p)
    h.place(1, point(p.x.int+200, p.z.int))
    h.place(3, point(p.x.int, p.z.int+200))
    let far = w[].controlHearts[h.farHeart(0)].pos
    check distance2(far, p) > (Width div 5 + 400).int64 * (Width div 5 + 400)
    h.parkOthers([0, 1, 3], far)
    const T = 10
    for t in 0..<T: h.step()
    check pw_seat_script_status(h, 0, nil, 0) == 1 and pw_seat_script_status(h, 3, nil, 0) == 1
    var got = newSeq[int32](3)
    check pw_seat_shout_stats(h, 0, ip(got)) == 0
    check got == @[4'i32*T, 8*T, 1*T]       # 4 accepted a tick, 2+4+1+1 bytes; hears seat 3
    check pw_seat_shout_stats(h, 3, ip(got)) == 0
    check got == @[1'i32*T, 256*T, 4*T]     # truncated to 256 bytes; hears seat 0
    check pw_seat_shout_stats(h, 1, ip(got)) == 0
    check got == @[0'i32, 0, 5*T]           # silent; hears both
    for s in [2, 4, 5, 15]:
      check pw_seat_shout_stats(h, s.cint, ip(got)) == 0
      check got == @[0'i32, 0, 0]           # out of earshot
    check pw_seat_shout_stats(h, 16, ip(got)) == -1 and pw_seat_shout_stats(nil, 0, ip(got)) == -1
    check pw_reset(h, 2026, 2400) == 0
    check pw_seat_shout_stats(h, 0, ip(got)) == 0 and got == @[0'i32, 0, 0]
