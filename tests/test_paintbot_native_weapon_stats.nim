## Per-weapon kills and enemy-hit locations (pw_seat_weapon_stats) through the native
## training ABI: arguments and reset; the counters equal an independent derivation from the
## reference engine's world through the observeHit / observeTag hooks (weapon from the world
## itself: a spray hit is a newly set sprayHits bit, a grenade hit has this tick's blast of
## the attacker around the victim, anything else is the gun; locations from the shooter's
## and victim's positions at the event); the kill split sums to pw_seat_stats' kills and
## the spray kills equal pw_seat_spray_stats[2]; every world hash equals the reference
## engine's, so the counters change nothing. PW_WS_TICKS (default 2400) and PW_WS_SEEDS
## (default 3) size the matches. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, strutils]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots, topography]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"

type Derived* = array[Seats, array[9, int]]  # the pw_seat_weapon_stats layout

proc classes(w: World, p: Point): (bool, bool, bool) =
  (inWater(p), terrainHeight(p.x.int, p.z.int) >= HighGroundHeight, w.trenchAt(p) >= 0)

proc derivedStep*(w: var World, commands: array[Seats, Command], acc: var Derived) =
  ## Step `w`, adding each enemy damage event of the step to `acc`, derived without the
  ## library's telemetry. Weapon: a spray hit when the attacker's sprayHits bit for the
  ## victim is newly set this step (first event of the pair; a burst started this step
  ## clears the old bits); a grenade hit when a blast of this tick owned by the attacker
  ## reaches the victim (explosions add their blast before dealing damage, and come after
  ## the gun and spray phases); otherwise the gun. A kill is the observeTag after the event.
  var preHits: array[Seats, uint32]
  var preBurst: array[Seats, int32]
  for i in 0..<Seats:
    preHits[i] = w.equipment[i].sprayHits
    preBurst[i] = w.equipment[i].burst
  var seen: array[Seats, uint32]
  var lastWeapon: array[Seats, int]
  let wp = addr w
  let ap = addr acc
  observeHit = proc(tick: int32, victim, attacker: int, pos: Point) =
    if attacker < 0 or attacker == victim or team(attacker) == team(victim): return
    let e = wp[].equipment[attacker]
    let bit = 1'u32 shl victim
    var weapon = 0
    let started = preBurst[attacker] == 0 and e.burst == SprayTicks
    if (e.sprayHits and bit) != 0 and (seen[attacker] and bit) == 0 and
        (started or (preHits[attacker] and bit) == 0):
      seen[attacker] = seen[attacker] or bit
      weapon = 2
    else:
      for b in wp[].blasts:
        if b.tick == tick and b.owner == attacker.int32 and
            distance2(b.pos, pos) <= (GrenadeBlastRadius+Radius).int64*(GrenadeBlastRadius+Radius):
          weapon = 1
    lastWeapon[victim] = weapon
    let (fw, fh, ft) = wp[].classes(wp[].cogs[attacker].pos)
    let (tw, th, tt) = wp[].classes(pos)
    for (on, k) in [(fw, 3), (fh, 4), (ft, 5), (tw, 6), (th, 7), (tt, 8)]:
      if on: inc ap[][attacker][k]
  observeTag = proc(tick: int32, victim, attacker: int, pos: Point) =
    if attacker < 0 or attacker == victim or team(attacker) == team(victim): return
    inc ap[][attacker][lastWeapon[victim]]
  try: w.step(commands)
  finally:
    observeHit = nil
    observeTag = nil

proc read(h: pointer): (Derived, array[Seats*8, int32], array[Seats, array[4, int32]]) =
  for s in 0..<Seats:
    var st: array[9, int32]
    doAssert pw_seat_weapon_stats(h, s.cint, ibuf(st)) == 0
    for k in 0..8: result[0][s][k] = st[k].int
    var sp: array[4, int32]
    doAssert pw_seat_spray_stats(h, s.cint, ibuf(sp)) == 0
    result[2][s] = sp
  doAssert pw_seat_stats(h, ibuf(result[1])) == 0

suite "Native per-weapon kills and hit locations":
  configureRules(NativeRules)
  let ticks = parseInt(getEnv("PW_WS_TICKS", "2400"))
  let seeds = parseInt(getEnv("PW_WS_SEEDS", "3"))
  let baseSource = readFile(Base)
  test "arguments and reset":
    let h = pw_create(1, 240)
    require h != nil
    defer: pw_destroy(h)
    var st: array[9, int32]
    check pw_seat_weapon_stats(h, 0, ibuf(st)) == 0 and st == default(array[9, int32])
    check pw_seat_weapon_stats(nil, 0, ibuf(st)) == -1
    check pw_seat_weapon_stats(h, -1, ibuf(st)) == -1 and pw_seat_weapon_stats(h, Seats.cint, ibuf(st)) == -1
    check pw_seat_weapon_stats(h, 0, nil) == -1
    check HighGroundHeight == 216
  test "base.bas on every seat: counters equal the hook derivation, hashes equal the reference engine":
    var totals: array[9, int]
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
      var actions: array[Seats*ActionSizes.len, int32]
      var rewards, terminals: array[Seats, float32]
      for pass in 0..1:
        if pass == 1:
          # A reset clears the counters with the rest of the match telemetry.
          require pw_reset(h, matchSeed, ticks.int32) == 0
          let (zero, _, _) = read(h)
          check zero == default(Derived)
          break
        while w.tick < ticks and w.winner == -1:
          let commands = players.decide(w)
          deliverSpeech(w)
          w.derivedStep(commands, derived)
          require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(h) == w.stateHash()
        let (native, stats, spray) = read(h)
        check native == derived
        for s in 0..<Seats:
          check native[s][0] + native[s][1] + native[s][2] == stats[s*8+4]
          check native[s][2] == spray[s][2]
          for k in 0..8: totals[k] += native[s][k]
      pw_destroy(h)
    echo "  weapon stats totals [gun, grenade, spray kills, from water/high/trench, to water/high/trench]: ", totals
    # Every counter is exercised: gun and grenade kills, hits from/to each terrain class.
    check totals[0] > 0 and totals[1] > 0
    for k in 3..8: check totals[k] > 0
  test "caller-driven spray seekers: spray kills are counted and still match":
    var sprayKills = 0
    for seed in 0..<2*seeds:
      let matchSeed = int32(seed + 601)
      var w = newWorld(matchSeed, ticks.int32)
      let h = pw_create(matchSeed, ticks.int32)
      require h != nil
      var derived: Derived
      var actions: array[Seats*ActionSizes.len, int32]
      var rewards, terminals: array[Seats, float32]
      var commands: array[Seats, Command]
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
      for s in 0..<Seats:
        check native[s][0] + native[s][1] + native[s][2] == stats[s*8+4]
        check native[s][2] == spray[s][2]
        sprayKills += native[s][2]
      pw_destroy(h)
    echo "  spray kills: ", sprayKills
    check sprayKills > 0
