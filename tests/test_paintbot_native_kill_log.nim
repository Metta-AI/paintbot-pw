## pw_kill_events (training library only): the per-event kill log. Draining it every tick changes
## nothing (hashes identical to a world that never calls it); over scripted matches the events
## agree with the engine's own totals (pw_seat_stats deaths by victim and kills by attacker,
## pw_seat_weapon_stats kills by weapon, one final event per seat out), and with the replay
## analysis (analysis.nim): the credited events are exactly its "tag" feed (tick, attacker, victim)
## and all events are exactly its "down" events. Drain semantics: oldest first, partial drains keep
## the rest, capacity 0 peeks, reset clears.
## Build with --mm:arc --threads:on -d:pwTraining -d:headless.
## PW_KILL_LOG_SEEDS=N PW_KILL_LOG_TICKS=T widen the scripted-match test (the proof run uses 8+
## seeds x 14,400 ticks); CI runs the defaults.
import std/[unittest, os, strutils, importutils, algorithm, sequtils]
import ../examples/paintbot/[sim, game, analysis, neural_contract, native_env]

when not defined(pwTraining): {.error: "training telemetry exists only under -d:pwTraining".}

privateAccess(NativeEnv)
const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
const Jev = Root / "coworld/paintbot/players/jev.bas"
const KillInts = 5
type
  Buffer = ptr UncheckedArray[cfloat]
  Kill = array[KillInts, int32]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc scriptedWorld(seed, ticks, rules: int32, red, blue: string): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  if rules > 0: doAssert pw_set_rules(result, rules) == 0
  doAssert pw_reset(result, seed, ticks) == 0
  for slot in 0..<Seats:
    let source = if slot mod 2 == 0: red else: blue
    doAssert pw_set_seat_script(result, slot.cint,
      cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0

proc drain(handle: pointer, events: var seq[Kill], capacity = 4) =
  ## Drains in small pieces so a step with more deaths than `capacity` exercises partial drains.
  var buffer = newSeq[int32](capacity*KillInts)
  while true:
    let n = pw_kill_events(handle, ibuf(buffer), capacity.cint)
    doAssert n >= 0 and n <= capacity
    for i in 0..<n:
      var e: Kill
      for k in 0..<KillInts: e[k] = buffer[i*KillInts+k]
      events.add e
    if n < capacity: break

proc play(handle: pointer, ticks: int, drainEvery: bool, events: var seq[Kill],
    frames: var seq[Frame]): seq[uint32] =
  ## Steps the match (all seats scripted), recording each tick's executed commands and state hash
  ## as a replay frame, and (drainEvery) draining the kill log after every step.
  let env = cast[ptr NativeEnv](handle)
  var actions: array[LegacySeats*ActionSizes.len, int32]
  var rewards, terminals: array[LegacySeats, float32]
  for tick in 0..<ticks:
    if terminals[0] == 1: break
    doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    if drainEvery: drain(handle, events)
    let hash = pw_state_hash(handle)
    frames.add Frame(commands: env.scriptOrders[0..<Seats], hash: hash)
    result.add hash

proc effectiveRules(rules: int32): int32 = (if rules > 0: rules else: NativeRules.int32)

suite "Kill log":
  configureRules(NativeRules)
  let baseSource = readFile(Base)
  let jevSource = readFile(Jev)
  let seeds = parseInt(getEnv("PW_KILL_LOG_SEEDS", "1"))
  let matchTicks = parseInt(getEnv("PW_KILL_LOG_TICKS", "5000"))

  test "arguments":
    let h = pw_create(1, 100)
    var buffer: array[KillInts, int32]
    check pw_kill_events(nil, nil, 0) == -1
    check pw_kill_events(h, nil, -1) == -1
    check pw_kill_events(h, nil, 1) == -1
    check pw_kill_events(h, nil, 0) == 0
    check pw_kill_events(h, ibuf(buffer), 1) == 0
    pw_destroy(h)

  test "draining every tick leaves scripted worlds byte-identical":
    for rules in [0'i32, 48, 49]:
      checkpoint "rules " & $rules
      var none, some: seq[Kill]
      var f0, f1: seq[Frame]
      let quiet = scriptedWorld(31, 2000, rules, baseSource, jevSource)
      let expected = play(quiet, 2000, false, none, f0)
      check none.len == 0
      check pw_kill_events(quiet, nil, 0) > 0   # recorded all along, never drained
      pw_destroy(quiet)
      let drained = scriptedWorld(31, 2000, rules, baseSource, jevSource)
      check play(drained, 2000, true, some, f1) == expected
      check some.len > 0
      check pw_kill_events(drained, nil, 0) == 0
      pw_destroy(drained)

  test "drain semantics: oldest first, partial drains keep the rest, capacity 0 peeks, reset clears":
    let a = scriptedWorld(17, 3000, 48, baseSource, jevSource)
    let b = scriptedWorld(17, 3000, 48, baseSource, jevSource)
    var fa, fb: seq[Frame]
    var ea, eb: seq[Kill]
    check play(a, 3000, false, ea, fa) == play(b, 3000, false, eb, fb)
    let pending = pw_kill_events(a, nil, 0)
    check pending > 2 and pw_kill_events(b, nil, 0) == pending
    var whole = newSeq[int32](pending*KillInts)
    check pw_kill_events(a, ibuf(whole), pending.cint) == pending   # one full drain
    check pw_kill_events(a, nil, 0) == 0
    var pieces: seq[int32]
    var one: array[KillInts, int32]
    check pw_kill_events(b, ibuf(one), 1) == 1                       # a partial drain ...
    check pw_kill_events(b, nil, 0) == pending-1                     # ... keeps the rest
    pieces.add @one
    var rest = newSeq[int32]((pending-1)*KillInts + KillInts)
    check pw_kill_events(b, ibuf(rest), cint(pending)) == pending-1  # capacity above pending
    pieces.add rest[0..<(pending-1)*KillInts]
    check pieces == whole
    var last = -1'i32
    for i in 0..<pending:
      check whole[i*KillInts] >= last                                 # oldest first
      last = whole[i*KillInts]
    check last < 3000
    # A reset drops whatever was not drained.
    var fc: seq[Frame]
    var ec: seq[Kill]
    check pw_reset(a, 17, 3000) == 0
    discard play(a, 1500, false, ec, fc)
    check pw_kill_events(a, nil, 0) > 0
    check pw_reset(a, 17, 3000) == 0
    check pw_kill_events(a, nil, 0) == 0
    pw_destroy(a); pw_destroy(b)

  test "scripted matches: engine totals and the replay analysis agree with the events":
    var credited, total, finals, matches = 0
    var byWeapon: array[4, int]
    for rules in [0'i32, 48, 49]:
      for n in 0..<seeds:
        let seed = int32(41+n)
        let blue = if n mod 2 == 0: jevSource else: baseSource
        checkpoint "rules " & $rules & " seed " & $seed
        let h = scriptedWorld(seed, matchTicks.int32, rules, baseSource, blue)
        var events: seq[Kill]
        var frames: seq[Frame]
        discard play(h, matchTicks, true, events, frames)
        inc matches
        let now = int32(frames.len)
        var stats: array[LegacySeats*8, int32]
        check pw_seat_stats(h, ibuf(stats)) == 0
        var state: array[LegacySeats*8, float32]
        check pw_seat_state(h, fbuf(state)) == 0
        var deaths, kills, final, lastIndex, finalIndex: array[LegacySeats, int]
        var weaponKills: array[LegacySeats, array[3, int]]
        for slot in 0..<Seats: lastIndex[slot] = -1; finalIndex[slot] = -1
        var previousTick = 0'i32
        for i, e in events:
          let (tick, attacker, victim, weapon) = (e[0], e[1].int, e[2].int, e[3])
          check tick >= previousTick and tick < now
          previousTick = tick
          check victim in 0..<Seats and attacker in -1..<Seats and weapon in 0'i32..3 and e[4] in 0'i32..1
          check finalIndex[victim] < 0          # nothing kills a seat after its final death
          inc deaths[victim]
          if attacker >= 0 and attacker != victim:
            inc credited
            if team(attacker) != team(victim):
              inc kills[attacker]
              if weapon > 0: inc weaponKills[attacker][weapon-1]
          if e[4] == 1: inc final[victim]; finalIndex[victim] = i
          lastIndex[victim] = i
          inc byWeapon[weapon]
        total += events.len
        for slot in 0..<Seats:
          check deaths[slot] == stats[slot*8+5]   # deaths
          check kills[slot] == stats[slot*8+4]    # kills (enemy victims)
          var nine: array[9, int32]
          check pw_seat_weapon_stats(h, slot.cint, ibuf(nine)) == 0
          for k in 0..2: check weaponKills[slot][k] == nine[k]
          let gone = state[slot*8+2] <= 0 and state[slot*8+4] <= 0   # hp, lives
          check final[slot] == (if gone: 1 else: 0)
          if final[slot] == 1: check finalIndex[slot] == lastIndex[slot]
          finals += final[slot]
        # The replay analysis rebuilds the same match from its frames (every frame hash-checked)
        # and its feed must hold exactly these kills.
        replayRulesVersion = effectiveRules(rules)
        recording = Recording(seed: seed, endTick: matchTicks.int32, frames: frames,
          seats: Seats.int32)
        let index = indexReplay()
        var tags, downs, creditedEvents, allEvents: seq[(int, int, int)]
        for m in index.events:
          if m.kind == "tag": tags.add (m.tick-1, m.slot, m.victim)
          elif m.kind == "down": downs.add (m.tick-1, m.slot, -1)
        for e in events:
          allEvents.add (e[0].int, e[2].int, -1)
          if e[1] >= 0 and e[1] != e[2]: creditedEvents.add (e[0].int, e[1].int, e[2].int)
        check tags == creditedEvents            # same kills, same engine order
        check downs.sorted == allEvents.sorted  # every death, credited or not
        pw_destroy(h)
    check matches == 3*seeds and credited > 0 and finals > 0
    check byWeapon[1] > 0                      # gun kills in every configuration
    echo "kill log: ", matches, " matches x ", matchTicks, " ticks, ", total, " deaths (",
      credited, " credited; by weapon other/gun/grenade/spray ", byWeapon, "), ", finals, " finals"

  test "rules 49 self-destruct: seat 0's blast kills are its own (weapon 2), its own death last":
    let source = "selfDestruct()\n"
    let h = pw_create(77, 500)
    doAssert pw_set_rules(h, 49) == 0 and pw_reset(h, 77, 500) == 0
    doAssert pw_set_seat_script(h, 0, cast[ptr UncheckedArray[char]](unsafeAddr source[0]),
      source.len.int32) == 0
    let env = cast[ptr NativeEnv](h)
    for slot in 0..<Seats: env.world.cogs[slot].shield = 0
    let spot = Point(x: env.world.cogs[0].pos.x+40, z: env.world.cogs[0].pos.z)
    env.world.cogs[1].pos = spot; env.world.cogs[1].goal = spot
    env.world.equipment[1].armor = 0
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    var events: seq[Kill]
    var stepTick = -1'i32
    for tick in 0..<40:
      let before = env.world.tick
      doAssert pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      drain(h, events)
      if events.len > 0: stepTick = before; break
    # Every blast victim (seat 1, and whoever else stood in reach) is seat 0's grenade-class kill
    # on the tick the step started from; the bomber's own death is the last event, not credited.
    check events.len >= 2
    var victims: seq[int32]
    for e in events:
      check e[0] == stepTick and e[1] == 0 and e[3] == 2
      victims.add e[2]
    check 1'i32 in victims
    check events.len >= 2 and events[^1][2] == 0 and victims.count(0) == 1
    var stats: array[LegacySeats*8, int32]
    check pw_seat_stats(h, ibuf(stats)) == 0
    check stats[0*8+5] == 1     # the bomber's death
    pw_destroy(h)
