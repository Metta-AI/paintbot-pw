## The spray decoder options (decoder.spray_aim, decoder.spray_gate) and the spray-can
## counters (pw_seat_spray_stats) through the native training ABI: arguments, read-back and
## reset semantics; a handle with the options on matches the reference engine applying
## neural_contract's rules in the hosted order (retarget, snap, spray aim, shot gate, spray
## gate, strafe, steady) before the shared decoder, hash for hash, with the counts and
## executed heads reported; the counters equal an independent derivation from the world
## (each spray burst's newly touched bodies seen through the observeHit hook); options off
## byte-identical; hosted neural seats with both options on either side equal the ABI.
## PW_SP_TICKS (default 1500) and PW_SP_SEEDS (default 8) size the hosted matches.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, strutils]
import polyworld/[rngs, cli]
import ../examples/paintbot/[sim, neural_contract, native_env, bots, neural_host]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc sprayActions(w: World, actions: var array[Seats*ActionSizes.len, int32], seed: int) =
  ## Seats without a spray can walk to a visible spray pickup when there is one, else to a
  ## heart; seats with a can walk to the enemy half's hearts. Aims cycle compass headings,
  ## identities and keep; fire on two ticks in three.
  for slot in 0..<Seats:
    let o = slot*ActionSizes.len
    let t = w.tick.int
    actions[o] = int32(1 + (slot div 2 + seed + t div 97) mod 10)
    if not w.equipment[slot].sprayCan:
      var best = high(int64)
      for i, p in w.pickups:
        if i >= 32 or p.kind != sprayPickup: continue
        let (found, g) = w.goalCandidate(slot, 11 + i)
        if not found: continue
        let d = distance2(w.cogs[slot].pos, g)
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

type Derived* = array[Seats, array[4, int]]  # enemy damage, team damage, enemy kills, team kills

proc derivedStep*(w: var World, commands: array[Seats, Command], acc: var Derived) =
  ## Step `w` and add each spray hit of the step to `acc`, derived independently of the
  ## library's telemetry: a damage event (observeHit) is a spray hit when the attacker's
  ## sprayHits bit for the victim is newly set this step (a burst started this step clears
  ## the old bits) and it is the first event of that pair this step; the health it removes
  ## follows from the victim's hp and armor at that moment and SprayDamage.
  var preHits: array[Seats, uint32]
  var preBurst: array[Seats, int32]
  for i in 0..<Seats:
    preHits[i] = w.equipment[i].sprayHits
    preBurst[i] = w.equipment[i].burst
  var seen: array[Seats, uint32]
  let wp = addr w
  let ap = addr acc
  observeHit = proc(tick: int32, victim, attacker: int, pos: Point) =
    if attacker < 0 or attacker == victim: return
    let e = wp[].equipment[attacker]
    let bit = 1'u32 shl victim
    if (e.sprayHits and bit) == 0 or (seen[attacker] and bit) != 0: return
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

suite "Native decoder spray aim, spray gate and spray counters":
  configureRules(NativeRules)
  test "arguments, defaults, read-back and reset semantics":
    let h = pw_create(1, 240)
    require h != nil
    defer: pw_destroy(h)
    var stats: array[4, int32]
    check pw_seat_spray_aim_stats(h, 0, ibuf(stats)) == 0
    check stats[0..2] == @[0'i32, -1, 0]
    check pw_seat_spray_gate_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, -1, -1, -1]
    check pw_seat_spray_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, 0, 0, 0]
    for (seat, r) in [(-1, 850'i32), (Seats, 850'i32), (0, -1'i32), (0, 851'i32)]:
      check pw_set_seat_spray_aim(h, seat.cint, r) == -1
    for (seat, t, e) in [(-1, 0'i32, 1'i32), (Seats, 0'i32, 1'i32), (0, 8'i32, 1'i32), (0, -2'i32, 1'i32),
                         (0, 0'i32, -1'i32), (0, 0'i32, 9'i32)]:
      check pw_set_seat_spray_gate(h, seat.cint, t, e) == -1
    check pw_set_seat_spray_aim(nil, 0, 850) == -1 and pw_set_seat_spray_gate(nil, 0, 0, 1) == -1
    check pw_seat_spray_aim_stats(h, 0, nil) == -1 and pw_seat_spray_gate_stats(nil, 0, ibuf(stats)) == -1
    check pw_seat_spray_stats(h, Seats.cint, ibuf(stats)) == -1 and pw_seat_spray_stats(h, 0, nil) == -1
    check pw_set_seat_spray_aim(h, 0, 850) == 0 and pw_set_seat_spray_aim(h, 0, 1) == 0
    check pw_seat_spray_aim_stats(h, 0, ibuf(stats)) == 0 and stats[2] == 1
    check pw_set_seat_spray_aim(h, 0, 0) == 0
    check pw_seat_spray_aim_stats(h, 0, ibuf(stats)) == 0 and stats[2] == 0
    check pw_set_seat_spray_gate(h, 0, 7, 8) == 0
    check pw_seat_spray_gate_stats(h, 0, ibuf(stats)) == 0 and stats == [0'i32, -1, 7, 8]
    check pw_set_seat_spray_gate(h, 0, -1, 99) == 0   # off; min_enemies ignored
    check pw_seat_spray_gate_stats(h, 0, ibuf(stats)) == 0 and stats == [0'i32, -1, -1, -1]
    check pw_set_seat_spray_aim(h, 3, 850) == 0 and pw_set_seat_spray_gate(h, 3, 0, 1) == 0
    check pw_reset(h, 2, 240) == 0
    check pw_seat_spray_aim_stats(h, 3, ibuf(stats)) == 0 and stats[0..2] == @[0'i32, -1, 850]
    check pw_seat_spray_gate_stats(h, 3, ibuf(stats)) == 0 and stats == [0'i32, -1, 0, 1]
  test "an options-on handle matches the reference engine; the counters match an independent derivation":
    var totalAims, totalGates, totalSprayDamage, totalTeamDamage, gatedSeats = 0
    for contract in [1'i32, 2]:
      for seed in [0'i32, 1, 2]:
        let matchSeed = seed + 301
        var reference = newWorld(matchSeed, 2400)
        let handle = pw_create(matchSeed, 2400)
        require handle != nil
        check pw_set_action_contract(handle, contract) == 0
        let version = ActionContractVersion(contract)
        # Seats 0 mod 4: spray aim + spray gate + retarget + snap + steady; 1 mod 4: spray
        # gate (2 teammates, 2 enemies) only; 2 mod 4: spray aim 500 + shot gate + strafe;
        # 3 mod 4: plain (their spray counters still count).
        var aimOn: array[Seats, SprayAimOptions]
        var gateOn: array[Seats, SprayGateOptions]
        var retargetOn: array[Seats, AimRetargetOptions]
        var snapOn: array[Seats, AimSnapOptions]
        var shotOn: array[Seats, ShotGateOptions]
        var steadyOn, strafeOn: array[Seats, bool]
        for slot in 0..<Seats:
          case slot mod 4
          of 0:
            aimOn[slot] = sprayAimOptions(); gateOn[slot] = sprayGateOptions()
            retargetOn[slot] = aimRetargetOptions(); snapOn[slot] = aimSnapOptions(22500); steadyOn[slot] = true
          of 1: gateOn[slot] = sprayGateOptions(2, 2)
          of 2:
            aimOn[slot] = sprayAimOptions(500); shotOn[slot] = shotGateOptions(); strafeOn[slot] = true
          else: discard
          if aimOn[slot].enabled: check pw_set_seat_spray_aim(handle, slot.cint, aimOn[slot].maxRange) == 0
          if gateOn[slot].enabled:
            check pw_set_seat_spray_gate(handle, slot.cint, gateOn[slot].maxTeammates, gateOn[slot].minEnemies) == 0
          let r = retargetOn[slot]
          if r.enabled: check pw_set_seat_aim_retarget(handle, slot.cint, 1, r.maxRange, r.hpWeight, r.carryWeight) == 0
          if snapOn[slot].enabled: check pw_set_seat_aim_snap(handle, slot.cint, 22500) == 0
          if shotOn[slot].enabled: check pw_set_seat_shot_gate(handle, slot.cint, 5250) == 0
          if steadyOn[slot]: check pw_set_seat_steady_shot(handle, slot.cint, 1) == 0
          if strafeOn[slot]: check pw_set_seat_strafe(handle, slot.cint, 5250, 3, 6, 6, 9, 800) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var commands: array[Seats, Command]
        var rewards, terminals: array[Seats, float32]
        var states: array[Seats, StrafeState]
        var rngs: array[Seats, Rng]
        var memories: array[Seats, AimMemory]
        var aims, gates: array[Seats, int32]
        var derived: Derived
        for slot in 0..<Seats:
          states[slot] = initStrafeState(slot)
          rngs[slot] = strafeRng(matchSeed, slot)
          memories[slot].resetAimMemory()
        while reference.winner == -1 and reference.tick < reference.endTick:
          sprayActions(reference, actions, seed.int)
          var aimLast, gateLast: array[Seats, int32]
          for slot in 0..<Seats:
            let o = slot*ActionSizes.len
            var heads: array[ActionSizes.len, int32]
            for head in 0..<ActionSizes.len: heads[head] = actions[o+head]
            let bodies = reference.observedBodies(slot)
            aimLast[slot] = -1; gateLast[slot] = -1
            discard reference.aimRetargetActions(slot, heads, bodies, version, memories[slot], retargetOn[slot])
            let beforeSnap = heads
            var snapped = reference.aimSnapActions(slot, heads, bodies, snapOn[slot])
            var sprayed = reference.sprayAimActions(slot, heads, bodies, version, memories[slot], aimOn[slot])
            if reference.shotGateActions(slot, heads, beforeSnap, snapped, bodies, version, memories[slot], shotOn[slot]):
              snapped = false
              sprayed = false
            if sprayed:
              aimLast[slot] = heads[1]
              inc aims[slot]
            if reference.sprayGateActions(slot, heads, bodies, version, memories[slot], gateOn[slot]):
              gateLast[slot] = 0
              inc gates[slot]
            if strafeOn[slot]:
              discard reference.strafeActions(slot, heads, bodies, defaultStrafeOptions(), states[slot], rngs[slot])
            discard reference.steadyShotActions(slot, heads, steadyOn[slot])
            commands[slot] = reference.decodeActions(slot, heads, bodies, version, memories[slot])
            if version == acV2: memories[slot].recordAimMemory(reference, slot, bodies)
          reference.derivedStep(commands, derived)
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == reference.stateHash()
          for slot in 0..<Seats:
            var stats: array[4, int32]
            check pw_seat_spray_aim_stats(handle, slot.cint, ibuf(stats)) == 0
            check stats[0] == aims[slot] and stats[1] == aimLast[slot]
            check pw_seat_spray_gate_stats(handle, slot.cint, ibuf(stats)) == 0
            check stats[0] == gates[slot] and stats[1] == gateLast[slot]
        for slot in 0..<Seats:
          var stats: array[4, int32]
          check pw_seat_spray_stats(handle, slot.cint, ibuf(stats)) == 0
          check stats == [derived[slot][0].int32, derived[slot][1].int32, derived[slot][2].int32, derived[slot][3].int32]
          totalAims += aims[slot]; totalGates += gates[slot]
          totalSprayDamage += derived[slot][0]; totalTeamDamage += derived[slot][1]
          if gateOn[slot].enabled and gates[slot] > 0: inc gatedSeats
        pw_destroy(handle)
    checkpoint "spray aims " & $totalAims & " spray gates " & $totalGates & " spray damage enemy " &
      $totalSprayDamage & " team " & $totalTeamDamage
    check totalAims > 0 and totalGates > 10 and totalSprayDamage > 0 and gatedSeats > 1
  test "options off are byte-identical to a fresh handle; toggling back off restores it":
    let plain = pw_create(2026, 1200)
    let toggled = pw_create(2026, 1200)
    require plain != nil and toggled != nil
    defer:
      pw_destroy(plain)
      pw_destroy(toggled)
    for slot in 0..<Seats:
      check pw_set_seat_spray_aim(toggled, slot.cint, 850) == 0 and pw_set_seat_spray_gate(toggled, slot.cint, 0, 1) == 0
      check pw_set_seat_spray_aim(toggled, slot.cint, 0) == 0 and pw_set_seat_spray_gate(toggled, slot.cint, -1, 0) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, cfloat]
    var w = newWorld(2026, 1200)
    for tick in 0..<1200:
      sprayActions(w, actions, 3)
      check pw_step(plain, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step(toggled, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_state_hash(plain) == pw_state_hash(toggled)
      var commands: array[Seats, Command]
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        commands[slot] = w.decodeActions(slot, actions.toOpenArray(o, o+ActionSizes.len-1), w.observedBodies(slot))
      w.step(commands)
      check w.stateHash() == pw_state_hash(plain)
      if terminals[0] != 0: break

suite "Hosted neural seats and the native ABI take the same spray options":
  configureRules(NativeRules)
  proc u32(s: var string, value: uint32) =
    for i in 0..3: s.add char((value shr (8*i)) and 255)
  proc zeroModel(): string =
    const h = 64
    const n = ObservationSize*h + 3*h*h + LogitSize*h
    result = "PWNET001"
    for x in [1,ObservationSize,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
    result.add ObservationContractHash
    result.add ActionContractV2Hash
    for x in ActionSizes: result.u32(x.uint32)
    result.add repeat('\0', n*4)
  proc neuralSeats(decoder: string): array[Seats, Bot] =
    let path = getTempDir()/"paintbot-native-spray-test.bas"
    writeFile(path, "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "paintbot_act(neuralLogits())\n")
    writeFile(path & ".model.bin", zeroModel())
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      ObservationContractHash & "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}, \"decoder\": " & decoder & "}")
    defer:
      removeFile(path); removeFile(path & ".model.bin"); removeFile(path & ".neural.json")
    loadBots(@[BotGroup(path: path, count: Seats)])
  let ticks = parseInt(getEnv("PW_SP_TICKS", "1500"))
  let seeds = parseInt(getEnv("PW_SP_SEEDS", "8"))
  test "both spray options on either side: every tick's world equals the ABI's, counts equal":
    let decoder = "{\"sampling\": {\"mode\": \"categorical\"}, \"fire_hold_teammates\": true, " &
      "\"spray_aim\": {}, \"spray_gate\": {\"max_teammates\": 1, \"min_enemies\": 1}}"
    let plainSeats = "{\"sampling\": {\"mode\": \"categorical\"}}"
    var matches, aims, gates = 0
    for seedIndex in 0..<seeds:
      let seed = int32(3 + seedIndex)
      for side in 0..1:
        let on = neuralSeats(decoder)
        let off = neuralSeats(plainSeats)
        var players: array[Seats, Bot]
        for slot in 0..<Seats: players[slot] = if team(slot) == side: on[slot] else: off[slot]
        var world = newWorld(seed, ticks.int32)
        let handle = pw_create(seed, ticks.int32)
        require handle != nil
        check pw_set_action_contract(handle, 2) == 0
        for slot in 0..<Seats:
          check pw_set_seat_sampling(handle, slot.cint, 1000, 0) == 0
          if team(slot) != side: continue
          check pw_set_seat_fire_hold(handle, slot.cint, 1) == 0
          check pw_set_seat_spray_aim(handle, slot.cint, 850) == 0
          check pw_set_seat_spray_gate(handle, slot.cint, 1, 1) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var rewards, terminals: array[Seats, float32]
        var zero: array[LogitSize, float32]
        var steps = 0
        while world.winner == -1 and world.tick < world.endTick:
          for slot in 0..<Seats:
            let o = slot*ActionSizes.len
            for head in 0..<ActionSizes.len: actions[o+head] = 0
            if world.cogs[slot].hp > 0:
              require pw_sample_actions(handle, slot.cint, fbuf(zero), ibuf(actions.toOpenArray(o, o+ActionSizes.len-1))) == 0
          let commands = players.decide(world)
          for slot in 0..<Seats: require not players[slot].failed
          world.step(commands)
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == world.stateHash()
          inc steps
        var a, g = 0
        for slot in 0..<Seats:
          let seat = players[slot].neural
          var stats: array[4, int32]
          check pw_seat_spray_aim_stats(handle, slot.cint, ibuf(stats)) == 0 and stats[0] == seat.sprayAims.int32
          check pw_seat_spray_gate_stats(handle, slot.cint, ibuf(stats)) == 0 and stats[0] == seat.sprayGates.int32
          check pw_seat_fire_held(handle, slot.cint) == seat.fireHolds.int32
          let line = seat.telemetry(10, steps)
          if team(slot) == side:
            check line.contains(" spray_aim=r850 spray_aims=" & $seat.sprayAims & " spray_gate=t1,e1 spray_gates=" & $seat.sprayGates)
            a += seat.sprayAims; g += seat.sprayGates
          else:
            check not line.contains("spray")
        echo "  hosted==ABI seed ", seed, " side ", side, " steps ", steps, " spray aims ", a, " spray gates ", g
        aims += a; gates += g
        inc matches
        pw_destroy(handle)
    check matches == seeds * 2
    checkpoint "aims " & $aims & " gates " & $gates
    check aims + gates > 0
