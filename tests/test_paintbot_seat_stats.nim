## Per-seat combat telemetry for training hosts: a scripted firing seat accrues damage
## dealt, a seat that never fires stays at zero, deaths and hits reconcile, and the
## telemetry changes no state hash. Build with --mm:arc --threads:on -d:pwTraining.
import std/unittest
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "seat stats exist only under -d:pwTraining".}

proc openSpot(w: World, near: Point): Point =
  ## A standable point near `near` with a clear view back to it.
  for r in 0..30:
    for dz in -r..r:
      for dx in -r..r:
        if abs(dx) != r and abs(dz) != r: continue
        let p = point(near.x.int+dx*40, near.z.int+dz*40)
        if not w.blocked(p) and w.lineClear(near, p) and w.lineClear(p, near): return p
  doAssert false, "no open spot"

suite "Seat combat telemetry":
  configureRules(NativeRules)
  test "a firing seat accrues damage dealt; a silent seat stays at zero; hashes unchanged":
    var w = newWorld(2026, 1200)
    var silent = w # Same world, stepped without any listener.
    # Seat 0 (Ember) and seat 1 (Azure) stand point blank in the open; everyone else
    # is parked far away so nobody else trades fire.
    let a = openSpot(w, point(3200, 2000))
    let b = openSpot(w, point(a.x.int+240, a.z.int))
    for i in 0..<Seats:
      let p = if i == 0: a elif i == 1: b else: openSpot(w, point(400+(i div 2)*300, if team(i) == 0: 300 else: 3700))
      w.cogs[i].pos = p; w.cogs[i].goal = p; w.cogs[i].shield = 0
    silent = w
    var stats: CombatTelemetry
    for s in stats.mitems: s = SeatStats(firstFriendlyFireTick: -1)
    var commands: array[Seats, Command]
    for i in 0..<Seats: commands[i] = Command(walk: true, goal: w.cogs[i].pos, aim: w.cogs[i].pos)
    commands[0] = Command(walk: true, goal: a, aim: b, shoot: true)
    for tick in 0..<240:
      combatTelemetry = addr stats
      w.step(commands)
      combatTelemetry = nil
      silent.step(commands)
      check w.stateHash() == silent.stateHash()
    check stats[0].damageDealtEnemy > 0
    check stats[0].hitsEnemy > 0
    check stats[0].damageDealtTeam == 0
    check stats[0].firstFriendlyFireTick == -1
    check stats[1].hitsTaken == stats[0].hitsEnemy
    check stats[1].deaths >= 1
    check stats[0].kills == stats[1].deaths
    for i in 2..<Seats:
      check stats[i] == SeatStats(firstFriendlyFireTick: -1)
    check stats[1].damageDealtEnemy == 0 and stats[1].hitsEnemy == 0
  test "native handle exposes the same counters and resets them":
    let handle = pw_create(2026, 2400)
    require handle != nil
    var stats: array[Seats*8, int32]
    check pw_seat_stats(handle, cast[ptr UncheckedArray[int32]](addr stats[0])) == 0
    for slot in 0..<Seats:
      for k in 0..<7: check stats[slot*8+k] == 0
      check stats[slot*8+7] == -1
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    var tick = 0
    while terminals[0] == 0 and tick < 2400:
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        actions[o] = int32(1+(slot div 2) mod 10)
        actions[o+1] = int32(1+(slot+1) mod 16) # identity aim at the next seat
        actions[o+2] = 1
      check pw_step(handle, cast[ptr UncheckedArray[int32]](addr actions[0]),
        cast[ptr UncheckedArray[cfloat]](addr rewards[0]), cast[ptr UncheckedArray[cfloat]](addr terminals[0])) == 0
      inc tick
    check pw_seat_stats(handle, cast[ptr UncheckedArray[int32]](addr stats[0])) == 0
    var hitsTaken, hitsEnemy, deaths, kills, dealt = 0
    for slot in 0..<Seats:
      hitsTaken += stats[slot*8+3]; hitsEnemy += stats[slot*8+2]; deaths += stats[slot*8+5]
      kills += stats[slot*8+4]; dealt += stats[slot*8]+stats[slot*8+1]
      check stats[slot*8+6] >= 0
      check stats[slot*8+7] == -1 or stats[slot*8+7] in 0..<tick
    check dealt > 0
    check hitsTaken >= hitsEnemy # Friendly fire and map damage count as hits taken too.
    check deaths >= kills
    check pw_reset(handle, 7, 240) == 0
    check pw_seat_stats(handle, cast[ptr UncheckedArray[int32]](addr stats[0])) == 0
    for slot in 0..<Seats:
      for k in 0..<7: check stats[slot*8+k] == 0
      check stats[slot*8+7] == -1
    pw_destroy(handle)
