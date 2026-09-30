## Per-weapon enemy damage dealt and taken (pw_seat_weapon_damage) through the native training ABI:
## arguments and reset; the counters equal an independent derivation from the reference engine's
## world (weapon from the world itself, as test_paintbot_native_weapon_stats derives it: a spray
## hit is a newly set sprayHits bit, a grenade hit has this tick's blast of the attacker around the
## victim, anything else is the gun; the amount from the damageObserver hook); the dealt split sums
## to pw_seat_stats' damage_dealt_enemy, spray dealt equals pw_seat_spray_stats[0], and dealt and
## taken balance per weapon over the match; every world hash equals the reference engine's, so the
## counters change nothing. PW_WD_TICKS (default 2400) and PW_WD_SEEDS (default 3) size the
## matches. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, strutils]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"

type Derived = array[LegacySeats, array[6, int]]  # the pw_seat_weapon_damage layout

proc derivedStep(w: var World, commands: openArray[Command], acc: var Derived) =
  ## Step `w`, adding each enemy damage event's health removed to `acc` under the weapon derived
  ## from the world (test_paintbot_native_weapon_stats' rule), without the library's telemetry.
  var preHits: array[LegacySeats, uint32]
  var preBurst: array[LegacySeats, int32]
  for i in 0..<Seats:
    preHits[i] = w.equipment[i].sprayHits.words[0]
    preBurst[i] = w.equipment[i].burst
  var seen: array[LegacySeats, uint32]
  var lastWeapon: array[LegacySeats, int]
  let wp = addr w
  let ap = addr acc
  observeHit = proc(tick: int32, victim, attacker: int, pos: Point) =
    lastWeapon[victim] = -1
    if attacker < 0 or attacker == victim or team(attacker) == team(victim): return
    let e = wp[].equipment[attacker]
    let bit = 1'u32 shl victim
    var weapon = 0
    let started = preBurst[attacker] == 0 and e.burst == SprayTicks
    if (e.sprayHits.words[0] and bit) != 0 and (seen[attacker] and bit) == 0 and
        (started or (preHits[attacker] and bit) == 0):
      seen[attacker] = seen[attacker] or bit
      weapon = 2
    else:
      for b in wp[].blasts:
        if b.tick == tick and b.owner == attacker.int32 and
            distance2(b.pos, pos) <= (grenadeBlastRadius()+Radius).int64*(grenadeBlastRadius()+Radius):
          weapon = 1
    lastWeapon[victim] = weapon
  damageObserver = proc(w: var World, victim, attacker, removed: int, killed: bool) =
    if attacker < 0 or attacker == victim or team(attacker) == team(victim): return
    let weapon = lastWeapon[victim]
    if weapon < 0: return
    ap[][attacker][weapon] += removed
    ap[][victim][3 + weapon] += removed
  try: w.step(commands)
  finally:
    observeHit = nil
    damageObserver = nil

proc read(h: pointer): (Derived, array[LegacySeats*8, int32], array[LegacySeats, array[4, int32]]) =
  for s in 0..<Seats:
    var d: array[6, int32]
    doAssert pw_seat_weapon_damage(h, s.cint, ibuf(d)) == 0
    for k in 0..5: result[0][s][k] = d[k].int
    var sp: array[4, int32]
    doAssert pw_seat_spray_stats(h, s.cint, ibuf(sp)) == 0
    result[2][s] = sp
  doAssert pw_seat_stats(h, ibuf(result[1])) == 0

proc checkMatch(native: Derived, stats: array[LegacySeats*8, int32], spray: array[LegacySeats, array[4, int32]],
    totals: var array[6, int]) =
  var balance: array[3, int]
  for s in 0..<Seats:
    check native[s][0] + native[s][1] + native[s][2] == stats[s*8]   # damage_dealt_enemy
    check native[s][2] == spray[s][0]                                 # spray enemy damage
    for k in 0..2: balance[k] += native[s][k] - native[s][3+k]
    for k in 0..5: totals[k] += native[s][k]
  check balance == [0, 0, 0]

suite "Native per-weapon enemy damage":
  configureRules(NativeRules)
  let ticks = parseInt(getEnv("PW_WD_TICKS", "2400"))
  let seeds = parseInt(getEnv("PW_WD_SEEDS", "3"))
  let baseSource = readFile(Base)
  test "arguments and reset":
    let h = pw_create(1, 240)
    require h != nil
    defer: pw_destroy(h)
    var d: array[6, int32]
    check pw_seat_weapon_damage(h, 0, ibuf(d)) == 0 and d == default(array[6, int32])
    check pw_seat_weapon_damage(nil, 0, ibuf(d)) == -1
    check pw_seat_weapon_damage(h, -1, ibuf(d)) == -1 and pw_seat_weapon_damage(h, Seats.cint, ibuf(d)) == -1
    check pw_seat_weapon_damage(h, 0, nil) == -1
  test "base.bas on every seat: counters equal the derivation, hashes equal the reference engine":
    var totals: array[6, int]
    for seed in 0..<seeds:
      let matchSeed = int32(seed + 501)
      resetOracle()
      var w = newWorld(matchSeed, ticks.int32)
      let players = loadBots(@[BotGroup(path: Base, count: Seats)])
      let h = pw_create(matchSeed, ticks.int32)
      require h != nil
      for s in 0..<Seats:
        check pw_set_seat_script(h, s.cint, cast[ptr UncheckedArray[char]](unsafeAddr baseSource[0]),
          baseSource.len.int32) == 0
      var derived: Derived
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var rewards, terminals: array[LegacySeats, float32]
      while w.tick < ticks and w.winner == -1:
        let commands = players.decide(w)
        deliverSpeech(w)
        w.derivedStep(commands, derived)
        require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(h) == w.stateHash()
      let (native, stats, spray) = read(h)
      check native == derived
      checkMatch(native, stats, spray, totals)
      require pw_reset(h, matchSeed, ticks.int32) == 0
      let (zero, _, _) = read(h)
      check zero == default(Derived)   # a reset clears them with the rest of the match telemetry
      pw_destroy(h)
    echo "  weapon damage totals [dealt gun, grenade, spray, taken gun, grenade, spray]: ", totals
    check totals[0] > 0 and totals[1] > 0
  test "caller-driven spray seekers: spray damage is counted and still matches":
    var totals: array[6, int]
    for seed in 0..<2*seeds:
      let matchSeed = int32(seed + 601)
      var w = newWorld(matchSeed, ticks.int32)
      let h = pw_create(matchSeed, ticks.int32)
      require h != nil
      var derived: Derived
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var rewards, terminals: array[LegacySeats, float32]
      var commands: array[LegacySeats, Command]
      while w.tick < ticks and w.winner == -1:
        for slot in 0..<Seats:
          let o = slot*ActionSizes.len
          let t = w.tick.int
          actions[o] = int32(1 + (slot div 2 + seed + t div 97) mod 10)
          if not w.equipment[slot].sprayCan:
            var best = high(int64)
            for i, p in w.pickups:
              if i >= 32 or p.kind notin {sprayPickup, grenadePickup}: continue
              let (found, g) = w.goalCandidate(slot, 11 + i)
              if not found: continue
              let d = distance2(w.cogs[slot].pos, g)
              if d < best:
                best = d
                actions[o] = int32(11 + i)
          actions[o+1] = if (t + slot) mod 3 == 0: 0'i32 else: int32(1 + (t div 5 + slot*3) mod 16)
          actions[o+2] = int32(w.tick mod 3 != 0)
          actions[o+3] = int32((t + slot*7) mod 40 < 12)
          actions[o+4] = 0
          commands[slot] = decodeActions(w, slot, actions.toOpenArray(o, o+4))
        w.derivedStep(commands, derived)
        require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(h) == w.stateHash()
      let (native, stats, spray) = read(h)
      check native == derived
      checkMatch(native, stats, spray, totals)
      pw_destroy(h)
    echo "  weapon damage totals (spray seekers): ", totals
    check totals[2] > 0 and totals[5] > 0
