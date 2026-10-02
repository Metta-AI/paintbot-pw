## pw_set_hit_log / pw_hit_events (training library only): per-step hit attribution. Recording and
## reading it changes nothing (hashes identical to a world that never turns it on); over full
## scripted matches the events, by victim, sum to pw_seat_damage_taken_stats (hits and health by
## source) and pw_seat_stats (hits_taken, deaths; kills by attacker), and every seat that ends the
## match out of lives has exactly one final event, its last.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, importutils]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "training telemetry exists only under -d:pwTraining".}

privateAccess(NativeEnv)
const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
const HitInts = 8
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc scriptedWorld(seed, ticks, rules: int32, source: string, log: bool): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  if rules > 0: doAssert pw_set_rules(result, rules) == 0
  if log: doAssert pw_set_hit_log(result, 1) == 0
  doAssert pw_reset(result, seed, ticks) == 0
  for slot in 0..<Seats:
    doAssert pw_set_seat_script(result, slot.cint,
      cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0

proc play(handle: pointer, ticks: int, events: var seq[array[HitInts, int32]]): seq[uint32] =
  var actions: array[LegacySeats*ActionSizes.len, int32]
  var rewards, terminals: array[LegacySeats, float32]
  var buffer = newSeq[int32](64*HitInts)
  for tick in 0..<ticks:
    if terminals[0] == 1: break
    doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    let count = pw_hit_events(handle, nil, 0)
    doAssert count >= 0
    if count > 0:
      if buffer.len < count*HitInts: buffer.setLen(count*HitInts)
      doAssert pw_hit_events(handle, ibuf(buffer), count.cint) == count
      for i in 0..<count:
        var e: array[HitInts, int32]
        for k in 0..<HitInts: e[k] = buffer[i*HitInts+k]
        events.add e
    result.add pw_state_hash(handle)

suite "Hit attribution":
  configureRules(NativeRules)
  let baseSource = readFile(Base)

  test "arguments":
    let h = pw_create(1, 100)
    check pw_set_hit_log(nil, 1) == -1 and pw_set_hit_log(h, 2) == -1 and pw_set_hit_log(h, -1) == -1
    check pw_hit_events(nil, nil, 0) == -1 and pw_hit_events(h, nil, -1) == -1 and pw_hit_events(h, nil, 1) == -1
    check pw_hit_events(h, nil, 0) == 0
    pw_destroy(h)

  test "recording and reading every tick leaves scripted worlds byte-identical":
    for rules in [0'i32, 48]:
      var none, some: seq[array[HitInts, int32]]
      let off = scriptedWorld(31, 1500, rules, baseSource, false)
      let expected = play(off, 1500, none)
      check none.len == 0   # off: nothing is recorded
      pw_destroy(off)
      let on = scriptedWorld(31, 1500, rules, baseSource, true)
      check play(on, 1500, some) == expected
      check some.len > 0
      pw_destroy(on)

  test "full scripted matches: events sum to the damage-taken and seat stats; one final per seat out":
    var finals, matches, shots = 0
    for rules in [0'i32, 48]:
      for seed in [41'i32, 42, 43]:
        checkpoint "rules " & $rules & " seed " & $seed
        let h = scriptedWorld(seed, 14400, rules, baseSource, true)
        var events: seq[array[HitInts, int32]]
        discard play(h, 14400, events)
        inc matches
        var stats: array[LegacySeats*8, int32]
        check pw_seat_stats(h, ibuf(stats)) == 0
        var state: array[LegacySeats*8, float32]
        check pw_seat_state(h, fbuf(state)) == 0
        var hits, health: array[LegacySeats, array[4, int]]
        var killed, final, kills, lastIndex, finalIndex: array[LegacySeats, int]
        for slot in 0..<Seats: lastIndex[slot] = -1; finalIndex[slot] = -1
        for i, e in events:
          let (attacker, victim) = (e[0].int, e[1].int)
          check victim in 0..<Seats and attacker in -1..<Seats
          check e[2] >= 0 and e[3] >= 0 and e[4] in 0'i32..3 and e[5] in 0'i32..1 and e[6] in 0'i32..1 and e[7] in 0'i32..1
          check e[7] == 0 or (attacker >= 0 and e[4] != 0)   # only a seat's weapon can be disguised
          check e[6] == 0 or e[5] == 1       # a final event is a death
          check finalIndex[victim] < 0       # nothing hits a seat after its final death
          let fromEnemy = attacker >= 0 and attacker != victim and team(attacker) != team(victim)
          let source = if fromEnemy and e[4] != 0: e[4].int-1 else: 3
          inc hits[victim][source]; health[victim][source] += e[2]
          killed[victim] += e[5]
          if e[6] == 1: inc final[victim]; finalIndex[victim] = i
          if fromEnemy and e[5] == 1: inc kills[attacker]
          lastIndex[victim] = i
        for slot in 0..<Seats:
          var eight: array[8, int32]
          check pw_seat_damage_taken_stats(h, slot.cint, ibuf(eight)) == 0
          for k in 0..3:
            check hits[slot][k] == eight[2*k]
            check health[slot][k] == eight[2*k+1]
          check hits[slot][0]+hits[slot][1]+hits[slot][2]+hits[slot][3] == stats[slot*8+3]   # hits_taken
          check killed[slot] == stats[slot*8+5]                                               # deaths
          check kills[slot] == stats[slot*8+4]                                                # kills
          let gone = state[slot*8+2] <= 0 and state[slot*8+4] <= 0                            # hp, lives
          check final[slot] == (if gone: 1 else: 0)
          if final[slot] == 1: check finalIndex[slot] == lastIndex[slot]
          finals += final[slot]
          var six: array[6, int32]
          var grenade: array[6, int32]
          check pw_seat_shot_orders(h, slot.cint, ibuf(six)) == 0
          check pw_seat_grenade_stats(h, slot.cint, ibuf(grenade)) == 0
          check six[1] == grenade[0]                                   # throws
          for k in 0..2: check six[3+k] >= 0 and six[3+k] <= six[k]
          shots += six[0]+six[1]+six[2]
        pw_destroy(h)
    check matches == 6 and finals > 0 and shots > 0

  test "disguised is the shooter's uniform at the order tick: gun wind-up, grenade in flight, spray burst":
    # Seat 0 orders each weapon while wearing a uniform; the order takes it off, the hit lands later.
    proc run(weapon: int): seq[array[HitInts, int32]] =
      let h = pw_create(77, 2000)
      doAssert pw_set_rules(h, 48) == 0 and pw_set_hit_log(h, 1) == 0 and pw_reset(h, 77, 2000) == 0
      let env = cast[ptr NativeEnv](h)
      for slot in 0..<Seats: env.world.cogs[slot].shield = 0
      # The enemy stands still a short clear walk from the shooter.
      let origin = env.world.cogs[0].pos
      var spot = origin
      for d in [(260, 0), (-260, 0), (0, 260), (0, -260)]:
        let p = Point(x: origin.x+d[0].int32, z: origin.z+d[1].int32)
        if not env.world.blocked(p) and env.world.lineClear(origin, p): spot = p; break
      doAssert spot != origin
      env.world.cogs[1].pos = spot; env.world.cogs[1].goal = spot
      env.world.uniforms[0] = true
      case weapon
      of 2: env.world.equipment[0].grenade = true
      of 3: env.world.equipment[0].sprayCan = true
      else: discard
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var rewards, terminals: array[LegacySeats, float32]
      var buffer: array[32*HitInts, int32]
      var order = (if weapon == 2: 2 else: 0)   # the tick the shot is ordered
      for tick in 0..<40:
        # nine = walk, goal, shoot, aim, charge_grenade, sneak, direct
        var cmd = [0'i32, 0, 0, 0, spot.x, spot.z, 0, 0, 0]
        if weapon == 2:
          if tick < 2: cmd[6] = 1            # charge two ticks, then release: the throw order
          if tick == 2:
            # the grenade lands where the charge reaches along the aim: put the enemy there
            let target = env.world.grenadeTarget(0)
            env.world.cogs[1].pos = target; env.world.cogs[1].goal = target
            check env.world.uniforms[0]      # still disguised when it orders the throw
            order = tick
        elif tick == 0:
          cmd[3] = 1                         # the gun's wind-up start / the spray's trigger
          check env.world.uniforms[0]
        doAssert pw_set_seat_command(h, 0, cast[ptr UncheckedArray[int32]](addr cmd[0])) == 0
        doAssert pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        if tick >= order: check not env.world.uniforms[0]   # the order took the uniform off
        let count = pw_hit_events(h, ibuf(buffer), 32)
        for i in 0..<count:
          var e: array[HitInts, int32]
          for k in 0..<HitInts: e[k] = buffer[i*HitInts+k]
          if e[0] == 0: result.add e
      var six: array[6, int32]
      check pw_seat_shot_orders(h, 0, ibuf(six)) == 0
      let slot = [0, 0, 1, 2][weapon]
      check six[slot] == 1 and six[3+slot] == 1
      pw_destroy(h)
    for weapon in 1..3:
      checkpoint "weapon " & $weapon
      let events = run(weapon)
      var hitEnemy = false
      for e in events:
        check e[4] == weapon.int32
        check e[7] == 1     # disguised at the order, though the uniform was off when the hit landed
        if e[1] == 1: hitEnemy = true
      check hitEnemy
