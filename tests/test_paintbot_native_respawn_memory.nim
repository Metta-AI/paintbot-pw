## Contract v2's aim memory across death and respawn: the training library clears a seat's
## memory exactly when the hosted seat does (neural_host.beginTick: on every decided tick
## the seat is dead, or alive after a tick it was dead), so the lead of an identity aim on a
## respawned seat's first decisions is the hosted seat's. A fighting reference engine that
## applies the hosted rule matches the handle hash for hash over hundreds of respawns, with
## pw_action_candidates reading the same memory; hosted neural seats with every decoder
## option equal the ABI over a seed sweep that includes 47; and the exact configuration the
## divergence was found in (seed 47, side 0) equals the ABI while the test shows a decision
## where the pre-fix memory would have led differently (on the unfixed library this test
## fails at tick 448). PW_RM_TICKS (default 1500), PW_RM_SEEDS (default 8) and
## PW_RM_FIRST_SEED (default 40) size the sweep. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, strutils]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots, neural_host]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc fightingActions(w: World, actions: var array[Seats*ActionSizes.len, int32], seed: int) =
  ## Identity aims at the nearest apparent enemy (so respawned seats aim at identities at
  ## once), compass aims otherwise; objectives toward the centre hearts; fire on two ticks
  ## in three; compass walking on some ticks so the lead's own-step term moves.
  for slot in 0..<Seats:
    let o = slot*ActionSizes.len
    let t = w.tick.int
    actions[o] = if (t div 30 + slot) mod 4 == 0: int32(43 + (t div 11 + slot) mod 8)
                 else: int32(1 + (slot div 2 + seed + t div 150) mod 10)
    actions[o+1] = int32(17 + (t div 13 + slot) mod 8)
    if (t + slot*7 + seed) mod 3 == 0:
      # The seat's own identity (always resolved, even while dead): the old never-cleared
      # memory kept the dead body's position, so on the first tick after a respawn that
      # moved the body less than a teleport it led the aim by the respawn displacement
      # (the divergence found at seed 47); any identity, seen or not, otherwise.
      actions[o+1] = if (t + slot) mod 2 == 0: int32(slot + 1) else: int32(1 + (t*7 + slot*5 + seed) mod 16)
      actions[o+2] = 1
      continue
    let bodies = w.observedBodies(slot)
    var best = high(int64)
    for identity, body in bodies:
      if body < 0 or w.observedTeam(slot, body) == team(slot): continue
      let d = distance2(w.cogs[slot].pos, w.cogs[body].pos)
      if d < best:
        best = d
        actions[o+1] = int32(identity + 1)
    actions[o+2] = int32(t mod 3 != 0)
    actions[o+3] = 0
    actions[o+4] = int32(slot mod 5 == 0)

suite "Native aim memory across death and respawn":
  configureRules(NativeRules)
  test "the handle matches a reference engine applying the hosted reset rule, over hundreds of respawns":
    var differing, respawns = 0
    for seed in [0'i32, 1, 2, 3, 4, 5, 6, 7]:
      let matchSeed = seed + 501
      var reference = newWorld(matchSeed, 3000)
      let handle = pw_create(matchSeed, 3000)
      require handle != nil
      check pw_set_action_contract(handle, 2) == 0
      var actions: array[Seats*ActionSizes.len, int32]
      var commands: array[Seats, Command]
      var rewards, terminals: array[Seats, float32]
      var hosted, old: array[Seats, AimMemory]
      var wasAlive: array[Seats, bool]
      for slot in 0..<Seats:
        hosted[slot].resetAimMemory()
        old[slot].resetAimMemory()
      var goals: array[ActionSizes[0]*2, int32]
      var aims: array[ActionSizes[1]*2, int32]
      while reference.winner == -1 and reference.tick < reference.endTick:
        fightingActions(reference, actions, seed.int)
        for slot in 0..<Seats:
          let alive = reference.cogs[slot].hp > 0
          if not alive or not wasAlive[slot]: hosted[slot].resetAimMemory()   # neural_host.beginTick
          if alive and not wasAlive[slot] and reference.tick > 0: inc respawns
          wasAlive[slot] = alive
          let o = slot*ActionSizes.len
          var heads: array[ActionSizes.len, int32]
          for hh in 0..<ActionSizes.len: heads[hh] = actions[o+hh]
          let bodies = reference.observedBodies(slot)
          commands[slot] = reference.decodeActions(slot, heads, bodies, acV2, hosted[slot])
          if alive and reference.decodeActions(slot, heads, bodies, acV2, old[slot]) != commands[slot]: inc differing
          # pw_action_candidates reads the memory the decode will use.
          if alive and actions[o+1] in 1'i32..16'i32:
            require pw_action_candidates(handle, slot.cint, actions[o], actions[o+4], ibuf(goals), ibuf(aims)) == 0
            let k = actions[o+1].int
            let (found, p) = reference.aimCandidate(slot, k, bodies, acV2, hosted[slot],
              reference.plannedStep(slot, reference.goalCandidate(slot, actions[o].int)[1], actions[o+4] != 0))
            if found: require aims[2*k] == p.x and aims[2*k+1] == p.z
          hosted[slot].recordAimMemory(reference, slot, bodies)
          old[slot].recordAimMemory(reference, slot, bodies)
        reference.step(commands)
        require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(handle) == reference.stateHash()
      pw_destroy(handle)
    echo "  respawns ", respawns, ", decisions the old never-cleared memory would change ", differing
    check respawns > 100
  test "a reset handle starts clean: the rule holds across pw_reset":
    let handle = pw_create(9, 600)
    require handle != nil
    defer: pw_destroy(handle)
    check pw_set_action_contract(handle, 2) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    for pass in 0..1:
      var reference = newWorld(9, 600)
      if pass == 1: check pw_reset(handle, 9, 600) == 0
      var hosted: array[Seats, AimMemory]
      var wasAlive: array[Seats, bool]
      for slot in 0..<Seats: hosted[slot].resetAimMemory()
      while reference.winner == -1 and reference.tick < reference.endTick:
        fightingActions(reference, actions, 5)
        var commands: array[Seats, Command]
        for slot in 0..<Seats:
          let alive = reference.cogs[slot].hp > 0
          if not alive or not wasAlive[slot]: hosted[slot].resetAimMemory()
          wasAlive[slot] = alive
          let o = slot*ActionSizes.len
          let bodies = reference.observedBodies(slot)
          commands[slot] = reference.decodeActions(slot, actions.toOpenArray(o, o+ActionSizes.len-1), bodies, acV2, hosted[slot])
          hosted[slot].recordAimMemory(reference, slot, bodies)
        reference.step(commands)
        require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(handle) == reference.stateHash()

suite "Hosted neural seats and the native ABI agree across respawns (every decoder option)":
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
    let path = getTempDir()/"paintbot-native-respawn-memory-test.bas"
    writeFile(path, "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "paintbot_act(neuralLogits())\n")
    writeFile(path & ".model.bin", zeroModel())
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      ObservationContractHash & "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}, \"decoder\": " & decoder & "}")
    defer:
      removeFile(path); removeFile(path & ".model.bin"); removeFile(path & ".neural.json")
    loadBots(@[BotGroup(path: path, count: Seats)])
  let ticks = parseInt(getEnv("PW_RM_TICKS", "1500"))
  let seeds = parseInt(getEnv("PW_RM_SEEDS", "8"))
  let firstSeed = parseInt(getEnv("PW_RM_FIRST_SEED", "40"))
  test "sampling + fire hold (radius) + forbid + snap + steady + retarget + shot gate + strafe on either side, seed 47 included":
    let full = "{\"sampling\": {\"mode\": \"categorical\"}, \"fire_hold_teammates\": {\"radius\": 150}, " &
      "\"forbid_objectives\": [9, 10], \"aim_snap\": {}, \"steady_shot\": {}, \"aim_retarget\": {}, \"shot_gate\": {}, " &
      "\"strafe_legs\": {\"legs\": [6, 9], \"shot_legs\": [6, 9], \"reverse_permille\": 200}}"
    let plainHold = "{\"sampling\": {\"mode\": \"categorical\"}, \"fire_hold_teammates\": true}"
    var matches, respawns, oldRuleDiffers = 0
    var seedList: seq[int32]
    for i in 0..<seeds: seedList.add int32(firstSeed + i)
    if 47'i32 notin seedList: seedList.add 47
    for seed in seedList:
      for side in 0..1:
        let on = neuralSeats(full)
        let off = neuralSeats(plainHold)
        var players: array[Seats, Bot]
        for slot in 0..<Seats: players[slot] = if team(slot) == side: on[slot] else: off[slot]
        var world = newWorld(seed, ticks.int32)
        let handle = pw_create(seed, ticks.int32)
        require handle != nil
        check pw_set_action_contract(handle, 2) == 0
        var river = [9'i32, 10]
        for slot in 0..<Seats:
          check pw_set_seat_sampling(handle, slot.cint, 1000, 0) == 0
          check pw_set_seat_fire_hold(handle, slot.cint, 1) == 0
          if team(slot) != side: continue
          check pw_set_seat_fire_hold_radius(handle, slot.cint, 150) == 0
          check pw_set_seat_forbid_objectives(handle, slot.cint, ibuf(river), 2) == 0
          check pw_set_seat_aim_snap(handle, slot.cint, 22500) == 0
          check pw_set_seat_steady_shot(handle, slot.cint, 1) == 0
          check pw_set_seat_aim_retarget(handle, slot.cint, 1, 5250, 160000, 2500000) == 0
          check pw_set_seat_shot_gate(handle, slot.cint, 5250) == 0
          check pw_set_seat_strafe(handle, slot.cint, 5250, 6, 9, 6, 9, 200) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var rewards, terminals: array[Seats, float32]
        var zero: array[LogitSize, float32]
        var wasAlive: array[Seats, bool]
        var oldMemory: array[Seats, AimMemory]   # the pre-fix library's rule: recorded every tick, never cleared
        for slot in 0..<Seats: oldMemory[slot].resetAimMemory()
        var steps, seen, differs = 0
        while world.winner == -1 and world.tick < world.endTick:
          for slot in 0..<Seats:
            let o = slot*ActionSizes.len
            for head in 0..<ActionSizes.len: actions[o+head] = 0
            let alive = world.cogs[slot].hp > 0
            if alive and not wasAlive[slot] and world.tick > 0: inc seen
            wasAlive[slot] = alive
            if alive:
              require pw_sample_actions(handle, slot.cint, fbuf(zero), ibuf(actions.toOpenArray(o, o+ActionSizes.len-1))) == 0
          let pre = world
          var hostMemory: array[Seats, AimMemory]
          for slot in 0..<Seats:
            hostMemory[slot] = players[slot].neural.memory
            if pre.cogs[slot].hp <= 0 or not wasAlive[slot] or pre.tick == 0: hostMemory[slot].resetAimMemory()
          let commands = players.decide(world)
          for slot in 0..<Seats: require not players[slot].failed
          for slot in 0..<Seats:
            let bodies = pre.observedBodies(slot)
            if pre.cogs[slot].hp > 0:
              let o = slot*ActionSizes.len
              var heads: array[ActionSizes.len, int32]
              for hh in 0..<ActionSizes.len: heads[hh] = actions[o+hh]
              if pre.decodeActions(slot, heads, bodies, acV2, oldMemory[slot]) !=
                  pre.decodeActions(slot, heads, bodies, acV2, hostMemory[slot]): inc differs
            oldMemory[slot].recordAimMemory(pre, slot, bodies)
          world.step(commands)
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == world.stateHash()
          inc steps
        for slot in 0..<Seats:
          check pw_seat_fire_held(handle, slot.cint) == players[slot].neural.fireHolds.int32
        echo "  hosted==ABI seed ", seed, " side ", side, " steps ", steps, " respawns ", seen,
          " decisions the old rule would have decoded differently ", differs
        respawns += seen
        oldRuleDiffers += differs
        inc matches
        pw_destroy(handle)
    check matches == seedList.len * 2 and respawns > 0
    echo "  decisions the pre-fix library's memory would have decoded differently: ", oldRuleDiffers
  test "the configuration the divergence was found in (seed 47, side 0: sampling + fire hold on one side, sampling on the other)":
    let full = "{\"sampling\": {\"mode\": \"categorical\"}, \"fire_hold_teammates\": true}"
    let plainHold = "{\"sampling\": {\"mode\": \"categorical\"}}"
    var matches, respawns, oldRuleDiffers = 0
    let seedList = @[47'i32]
    for seed in seedList:
      for side in 0..0:
        let on = neuralSeats(full)
        let off = neuralSeats(plainHold)
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
        var actions: array[Seats*ActionSizes.len, int32]
        var rewards, terminals: array[Seats, float32]
        var zero: array[LogitSize, float32]
        var wasAlive: array[Seats, bool]
        var oldMemory: array[Seats, AimMemory]   # the pre-fix library's rule: recorded every tick, never cleared
        for slot in 0..<Seats: oldMemory[slot].resetAimMemory()
        var steps, seen, differs = 0
        while world.winner == -1 and world.tick < world.endTick:
          for slot in 0..<Seats:
            let o = slot*ActionSizes.len
            for head in 0..<ActionSizes.len: actions[o+head] = 0
            let alive = world.cogs[slot].hp > 0
            if alive and not wasAlive[slot] and world.tick > 0: inc seen
            wasAlive[slot] = alive
            if alive:
              require pw_sample_actions(handle, slot.cint, fbuf(zero), ibuf(actions.toOpenArray(o, o+ActionSizes.len-1))) == 0
          let pre = world
          var hostMemory: array[Seats, AimMemory]
          for slot in 0..<Seats:
            hostMemory[slot] = players[slot].neural.memory
            if pre.cogs[slot].hp <= 0 or not wasAlive[slot] or pre.tick == 0: hostMemory[slot].resetAimMemory()
          let commands = players.decide(world)
          for slot in 0..<Seats: require not players[slot].failed
          for slot in 0..<Seats:
            let bodies = pre.observedBodies(slot)
            if pre.cogs[slot].hp > 0:
              let o = slot*ActionSizes.len
              var heads: array[ActionSizes.len, int32]
              for hh in 0..<ActionSizes.len: heads[hh] = actions[o+hh]
              if pre.decodeActions(slot, heads, bodies, acV2, oldMemory[slot]) !=
                  pre.decodeActions(slot, heads, bodies, acV2, hostMemory[slot]): inc differs
            oldMemory[slot].recordAimMemory(pre, slot, bodies)
          world.step(commands)
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == world.stateHash()
          inc steps
        for slot in 0..<Seats:
          check pw_seat_fire_held(handle, slot.cint) == players[slot].neural.fireHolds.int32
        echo "  hosted==ABI seed ", seed, " side ", side, " steps ", steps, " respawns ", seen,
          " decisions the old rule would have decoded differently ", differs
        respawns += seen
        oldRuleDiffers += differs
        inc matches
        pw_destroy(handle)
    check matches == 1 and respawns > 0
    # The case the fix is for happens here: a decision where the pre-fix library's memory
    # would have led the aim differently from the hosted seat's (tick 447, seat 13).
    check oldRuleDiffers > 0
