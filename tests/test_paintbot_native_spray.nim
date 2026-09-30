## The spray-can counters (pw_seat_spray_stats) through the native training ABI: arguments and
## reset; the counters equal an independent derivation from the world (each spray burst's
## newly touched bodies seen through the observeHit hook) on a handle whose seats seek spray
## cans, played against the reference engine driven by the reference decoder script, hash for
## hash. (The spray_aim / spray_gate decoder options were native decoder rules, retired for
## BASIC parity.) Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const DecoderSource = staticRead("../examples/paintbot/players/neural_decode.bas")
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc sprayActions(w: World, actions: var array[LegacySeats*ActionSizes.len, int32], seed: int) =
  ## Seats without a spray can walk to a spray pickup they can see when there is one, else to
  ## a heart; seats with a can walk to the hearts in turn. Aims cycle keep, identities and
  ## compass headings; fire on two ticks in three.
  beginViews(w)
  for slot in 0..<Seats:
    let o = slot*ActionSizes.len
    let t = w.tick.int
    let v = seatView(slot)
    actions[o] = int32(1 + (slot div 2 + seed + t div 97) mod 10)
    if not w.equipment[slot].sprayCan:
      var best = high(int64)
      for i, p in w.pickups:
        if i >= 32 or p.kind != sprayPickup or v.pickupVisible(i) == 0: continue
        let d = distance2(w.cogs[slot].pos, Point(x: v.pickupX(i), z: v.pickupY(i)))
        if d < best:
          best = d
          actions[o] = int32(11 + i)
    actions[o+1] = case (t + slot + seed) mod 6
      of 0: 0'i32
      of 1, 2: int32(1 + (t div 5 + slot*3) mod 16)
      else: int32(17 + (t div 9 + slot + seed) mod 8)
    actions[o+2] = int32(w.tick mod 3 != 0)
    actions[o+3] = 0
    actions[o+4] = 0

type Derived* = array[LegacySeats, array[4, int]]  # enemy damage, team damage, enemy kills, team kills

proc derivedStep*(w: var World, commands: array[LegacySeats, Command], acc: var Derived) =
  ## Step `w` and add each spray hit of the step to `acc`, derived independently of the
  ## library's telemetry: a damage event (observeHit) is a spray hit when the attacker's
  ## sprayHits bit for the victim is newly set this step (a burst started this step clears
  ## the old bits) and it is the first event of that pair this step; the health it removes
  ## follows from the victim's hp and armor at that moment and SprayDamage.
  var preHits: array[LegacySeats, uint32]
  var preBurst: array[LegacySeats, int32]
  for i in 0..<Seats:
    preHits[i] = w.equipment[i].sprayHits.words[0]
    preBurst[i] = w.equipment[i].burst
  var seen: array[LegacySeats, uint32]
  let wp = addr w
  let ap = addr acc
  observeHit = proc(tick: int32, victim, attacker: int, pos: Point) =
    if attacker < 0 or attacker == victim: return
    let e = wp[].equipment[attacker]
    let bit = 1'u32 shl victim
    if (e.sprayHits.words[0] and bit) == 0 or (seen[attacker] and bit) != 0: return
    let started = preBurst[attacker] == 0 and e.burst == SprayTicks
    if not started and (preHits[attacker] and bit) != 0: return
    seen[attacker] = seen[attacker] or bit
    let hp = wp[].cogs[victim].hp.int
    let absorbed = min(wp[].equipment[victim].armor.int, SprayDamage)
    let after = max(0, hp - (SprayDamage - absorbed))
    let mate = team(attacker) == team(victim)
    ap[][attacker][if mate: 1 else: 0] += hp - after
    if after == 0: inc ap[][attacker][if mate: 3 else: 2]
  try: w.step(commands)
  finally: observeHit = nil

suite "Native spray counters":
  configureRules(NativeRules)
  test "arguments and reset":
    let h = pw_create(1, 240)
    require h != nil
    defer: pw_destroy(h)
    var stats: array[4, int32]
    check pw_seat_spray_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, 0, 0, 0]
    check pw_seat_spray_stats(nil, 0, ibuf(stats)) == -1
    check pw_seat_spray_stats(h, -1, ibuf(stats)) == -1
    check pw_seat_spray_stats(h, Seats.cint, ibuf(stats)) == -1 and pw_seat_spray_stats(h, 0, nil) == -1
  test "spray seekers: the counters match an independent derivation; hashes match the reference decoder":
    var totalSprayDamage, totalTeamDamage, totalKills = 0
    for seed in [0'i32, 1, 2]:
      let matchSeed = seed + 301
      var reference = newWorld(matchSeed, 2400)
      var seats: seq[Bot]
      for slot in 0..<Seats: seats.add loadDecoderBot(DecoderSource, slot, ObservationContractTeamsView1Hash, acTeamsView1)
      let handle = pw_create(matchSeed, 2400)
      require handle != nil
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var rewards, terminals: array[LegacySeats, float32]
      var derived: Derived
      while reference.winner == -1 and reference.tick < reference.endTick:
        sprayActions(reference, actions, seed.int)
        for slot in 0..<Seats:
          for head in 0..<ActionSizes.len: seats[slot].neural.fedChoices[head] = actions[slot*ActionSizes.len+head]
          seats[slot].neural.choicesFed = true
        let decided = decideSeats(seats, reference)
        var commands: array[LegacySeats, Command]
        for slot in 0..<Seats: commands[slot] = decided[slot]
        reference.derivedStep(commands, derived)
        require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(handle) == reference.stateHash()
      for slot in 0..<Seats:
        var stats: array[4, int32]
        check pw_seat_spray_stats(handle, slot.cint, ibuf(stats)) == 0
        check stats == [derived[slot][0].int32, derived[slot][1].int32, derived[slot][2].int32, derived[slot][3].int32]
        totalSprayDamage += derived[slot][0]; totalTeamDamage += derived[slot][1]
        totalKills += derived[slot][2] + derived[slot][3]
      # A reset clears the counters with the rest of the match telemetry.
      check pw_reset(handle, matchSeed, 2400) == 0
      for slot in 0..<Seats:
        var stats: array[4, int32]
        check pw_seat_spray_stats(handle, slot.cint, ibuf(stats)) == 0 and stats == [0'i32, 0, 0, 0]
      pw_destroy(handle)
    checkpoint "spray damage enemy " & $totalSprayDamage & " team " & $totalTeamDamage & " kills " & $totalKills
    check totalSprayDamage > 0
