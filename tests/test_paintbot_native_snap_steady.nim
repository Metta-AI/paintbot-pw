## The decoder options aim_snap and steady_shot through the native training ABI:
## arguments, read-back and reset semantics (and the steady shot's refusal to share index 0
## with a forbid mask); a handle with the options on matches the reference engine applying
## neural_contract.aimSnapActions, strafeActions and steadyShotActions (in that order)
## before the shared decoder, hash for hash under both contracts and across a reset, with
## the counts and executed heads reported; options off byte-identical to a fresh handle;
## and 16 hosted neural seats with the options (with forbid, sampling, strafe and hold)
## equal to the ABI, hash for hash. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, strutils]
import polyworld/[rngs, cli]
import ../examples/paintbot/[sim, neural_contract, native_env, bots, neural_host]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc shootingActions(w: World, actions: var array[Seats*ActionSizes.len, int32], seed: int) =
  ## Heart objectives on a schedule, mostly compass aims turning with the tick (an
  ## identity aim at the nearest apparent enemy one decision in five), fire on two ticks
  ## in three, grenade and sneak on schedules.
  for slot in 0..<Seats:
    let o = slot*ActionSizes.len
    actions[o] = int32(1+(slot div 2+seed+w.tick.int div 53) mod 10)
    actions[o+1] = int32(17+(w.tick.int div 9+slot+seed) mod 8)
    if (w.tick.int + slot) mod 5 == 0:
      let bodies = w.observedBodies(slot)
      var best = high(int64)
      for identity, body in bodies:
        if body < 0 or w.observedTeam(slot, body) == team(slot): continue
        let d = distance2(w.cogs[slot].pos, w.cogs[body].pos)
        if d < best:
          best = d
          actions[o+1] = int32(identity+1)
    actions[o+2] = int32(w.tick mod 3 != 0)
    actions[o+3] = int32(w.tick mod 48 < 12)
    actions[o+4] = int32(slot mod 5 == 0)

suite "Native decoder aim snap and steady shot":
  configureRules(NativeRules)
  test "arguments, defaults, read-back and reset semantics":
    let h = pw_create(1, 240)
    require h != nil
    defer: pw_destroy(h)
    var stats: array[3, int32]
    check pw_seat_aim_snap_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, -1, 0]
    check pw_seat_steady_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, 0, -1]
    for (seat, angle) in [(-1, 22500'i32), (Seats, 22500'i32), (0, -1'i32), (0, 90001'i32)]:
      check pw_set_seat_aim_snap(h, seat.cint, angle) == -1
    check pw_set_seat_aim_snap(nil, 0, 22500) == -1
    check pw_seat_aim_snap_stats(nil, 0, ibuf(stats)) == -1
    check pw_seat_aim_snap_stats(h, 0, nil) == -1
    check pw_set_seat_aim_snap(h, 0, 22500) == 0
    check pw_seat_aim_snap_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, -1, 30274]
    check pw_set_seat_aim_snap(h, 0, 90000) == 0 and pw_set_seat_aim_snap(h, 0, 1) == 0
    check pw_set_seat_aim_snap(h, 0, 0) == 0   # off
    check pw_seat_aim_snap_stats(h, 0, ibuf(stats)) == 0 and stats[2] == 0
    for (seat, on) in [(-1, 1'i32), (Seats, 1'i32), (0, 2'i32), (0, -1'i32)]:
      check pw_set_seat_steady_shot(h, seat.cint, on) == -1
    check pw_set_seat_steady_shot(nil, 0, 1) == -1
    check pw_seat_steady_stats(nil, 0, ibuf(stats)) == -1
    check pw_seat_steady_stats(h, 0, nil) == -1
    # The steady shot stands the seat on movement index 0: it will not share it with a forbid.
    var zero = [0'i32, 9]
    var river = [9'i32, 10]
    check pw_set_seat_forbid_objectives(h, 0, ibuf(zero), 2) == 0
    check pw_set_seat_steady_shot(h, 0, 1) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(river), 2) == 0
    check pw_set_seat_steady_shot(h, 0, 1) == 0
    check pw_set_seat_forbid_objectives(h, 0, ibuf(zero), 2) == -1
    check pw_seat_forbidden_objectives(h, 0, nil) == 2   # unchanged: still 9, 10
    check pw_set_seat_steady_shot(h, 0, 0) == 0
    check pw_set_seat_forbid_objectives(h, 0, ibuf(zero), 2) == 0
    check pw_set_seat_forbid_objectives(h, 0, nil, 0) == 0
    # Options persist across reset; counts reset.
    check pw_set_seat_aim_snap(h, 3, 22500) == 0
    check pw_set_seat_steady_shot(h, 3, 1) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, cfloat]
    var w = newWorld(1, 240)
    for tick in 0..<120:
      shootingActions(w, actions, 0)
      require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      var commands: array[Seats, Command]
      w.step(commands)   # only the tick matters to shootingActions' schedules
    check pw_seat_steady_stats(h, 3, ibuf(stats)) == 0
    check stats[0] > 0 and stats[1] >= stats[0]
    check pw_reset(h, 2, 240) == 0
    check pw_seat_steady_stats(h, 3, ibuf(stats)) == 0
    check stats == [0'i32, 0, -1]
    check pw_seat_aim_snap_stats(h, 3, ibuf(stats)) == 0
    check stats == [0'i32, -1, 30274]
  test "an options-on handle matches the reference engine applying snap, strafe and steady before the shared decoder":
    for contract in [1'i32, 2]:
      for seed in [0'i32, 1]:
        let matchSeed = seed + 91
        var reference = newWorld(matchSeed, 900)
        let handle = pw_create(matchSeed, 900)
        require handle != nil
        check pw_set_action_contract(handle, contract) == 0
        let version = ActionContractVersion(contract)
        # Seats 0 mod 4: snap + steady; 1 mod 4: snap 45 only; 2 mod 4: steady + strafe +
        # snap; 3 mod 4: plain.
        var snapOn: array[Seats, AimSnapOptions]
        var steadyOn, strafeOn: array[Seats, bool]
        for slot in 0..<Seats:
          case slot mod 4
          of 0:
            snapOn[slot] = aimSnapOptions(22500); steadyOn[slot] = true
          of 1:
            snapOn[slot] = aimSnapOptions(45000)
          of 2:
            snapOn[slot] = aimSnapOptions(22500); steadyOn[slot] = true; strafeOn[slot] = true
          else: discard
          if snapOn[slot].enabled: check pw_set_seat_aim_snap(handle, slot.cint, snapOn[slot].maxAngleMillideg) == 0
          if steadyOn[slot]: check pw_set_seat_steady_shot(handle, slot.cint, 1) == 0
          if strafeOn[slot]: check pw_set_seat_strafe(handle, slot.cint, 5250, 3, 6, 6, 9, 800) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var commands: array[Seats, Command]
        var rewards, terminals: array[Seats, float32]
        var states: array[Seats, StrafeState]
        var rngs: array[Seats, Rng]
        var memories: array[Seats, AimMemory]
        var snaps, shots, ticks: array[Seats, int32]
        var totalSnaps, totalShots, totalTicks, overridden = 0
        for pass in 0..1:
          reference = newWorld(matchSeed, 900)
          if pass == 1: check pw_reset(handle, matchSeed, 900) == 0
          for slot in 0..<Seats:
            states[slot] = initStrafeState(slot)
            rngs[slot] = strafeRng(matchSeed, slot)
            memories[slot].resetAimMemory()
            snaps[slot] = 0; shots[slot] = 0; ticks[slot] = 0
          while reference.winner == -1 and reference.tick < reference.endTick:
            shootingActions(reference, actions, seed.int)
            var snapLast, strafeLast, steadyLast: array[Seats, int32]
            for slot in 0..<Seats:
              let o = slot*ActionSizes.len
              var heads: array[ActionSizes.len, int32]
              for head in 0..<ActionSizes.len: heads[head] = actions[o+head]
              let bodies = reference.observedBodies(slot)
              snapLast[slot] = -1; strafeLast[slot] = -1; steadyLast[slot] = -1
              if reference.aimSnapActions(slot, heads, bodies, snapOn[slot]):
                snapLast[slot] = heads[1]
                inc snaps[slot]
              if strafeOn[slot] and reference.strafeActions(slot, heads, bodies, defaultStrafeOptions(),
                  states[slot], rngs[slot]):
                strafeLast[slot] = heads[0]
              let held = reference.steadyShotActions(slot, heads, steadyOn[slot])
              if held != ssNone:
                if strafeLast[slot] >= 0: inc overridden
                strafeLast[slot] = -1
                steadyLast[slot] = heads[0]
                inc ticks[slot]
                if held == ssOrder: inc shots[slot]
              commands[slot] = reference.decodeActions(slot, heads, bodies, version, memories[slot])
              if version == acV2: memories[slot].recordAimMemory(reference, slot, bodies)
            reference.step(commands)
            require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
            require pw_state_hash(handle) == reference.stateHash()
            for slot in 0..<Seats:
              var stats: array[3, int32]
              check pw_seat_aim_snap_stats(handle, slot.cint, ibuf(stats)) == 0
              check stats[0] == snaps[slot] and stats[1] == snapLast[slot]
              check pw_seat_steady_stats(handle, slot.cint, ibuf(stats)) == 0
              check stats == [shots[slot], ticks[slot], steadyLast[slot]]
              check pw_seat_strafe_stats(handle, slot.cint, ibuf(stats)) == 0
              check stats == [states[slot].legs, states[slot].ticks, strafeLast[slot]]
          for slot in 0..<Seats:
            totalSnaps += snaps[slot]; totalShots += shots[slot]; totalTicks += ticks[slot]
        pw_destroy(handle)
        checkpoint "contract " & $contract & " seed " & $seed
        # The rules actually ran: snaps, steadied shots with their windups, strafe legs overridden.
        check totalSnaps > 50 and totalShots > 50 and totalTicks >= 5*totalShots and overridden > 0
  test "options off are byte-identical to a fresh handle; toggling back off restores it":
    let plain = pw_create(2026, 600)
    let toggled = pw_create(2026, 600)
    require plain != nil and toggled != nil
    defer:
      pw_destroy(plain)
      pw_destroy(toggled)
    check pw_set_action_contract(plain, 2) == 0 and pw_set_action_contract(toggled, 2) == 0
    for slot in 0..<Seats:
      check pw_set_seat_aim_snap(toggled, slot.cint, 22500) == 0
      check pw_set_seat_steady_shot(toggled, slot.cint, 1) == 0
      check pw_set_seat_aim_snap(toggled, slot.cint, 0) == 0
      check pw_set_seat_steady_shot(toggled, slot.cint, 0) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, cfloat]
    var w = newWorld(2026, 600)
    var memories: array[Seats, AimMemory]
    for slot in 0..<Seats: memories[slot].resetAimMemory()
    for tick in 0..<600:
      shootingActions(w, actions, 3)
      check pw_step(plain, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step(toggled, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_state_hash(plain) == pw_state_hash(toggled)
      var commands: array[Seats, Command]
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        let bodies = w.observedBodies(slot)
        commands[slot] = w.decodeActions(slot, actions.toOpenArray(o, o+ActionSizes.len-1), bodies, acV2, memories[slot])
        memories[slot].recordAimMemory(w, slot, bodies)
      w.step(commands)
      check w.stateHash() == pw_state_hash(plain)
      if terminals[0] != 0: break

suite "Hosted neural seats and the native ABI take the same decoder path (aim snap, steady shot)":
  configureRules(NativeRules)
  proc u32(s: var string, value: uint32) =
    for i in 0..3: s.add char((value shr (8*i)) and 255)
  proc zeroModel(): string =
    ## A valid contract-v2 actor whose logits are all zero: a sampled head is a uniform
    ## draw over its allowed candidates, so compass aims and shoot orders are frequent.
    const h = 64
    const n = ObservationSize*h + 3*h*h + LogitSize*h
    result = "PWNET001"
    for x in [1,ObservationSize,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
    result.add ObservationContractHash
    result.add ActionContractV2Hash
    for x in ActionSizes: result.u32(x.uint32)
    result.add repeat('\0', n*4)
  proc neuralSeats(decoder: string): array[Seats, Bot] =
    let path = getTempDir()/"paintbot-native-snap-steady-test.bas"
    writeFile(path, "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "paintbot_act(neuralLogits())\n")
    writeFile(path & ".model.bin", zeroModel())
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      ObservationContractHash & "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}, \"decoder\": " & decoder & "}")
    defer:
      removeFile(path); removeFile(path & ".model.bin"); removeFile(path & ".neural.json")
    loadBots(@[BotGroup(path: path, count: Seats)])
  test "every hosted seat's world equals the ABI's, hash for hash, with matching counts":
    for (decoder, full, angle) in [
        ("{\"fire_hold_teammates\": true, \"forbid_objectives\": [9, 10], \"strafe_legs\": {}, " &
         "\"sampling\": {\"mode\": \"categorical\"}, \"aim_snap\": {\"max_angle_deg\": 22.5}, \"steady_shot\": {}}", true, 22500'i32),
        ("{\"sampling\": {\"mode\": \"categorical\"}, \"aim_snap\": {\"max_angle_deg\": 45}, \"steady_shot\": {}}", false, 45000'i32)]:
      for seed in [3'i32, 4]:
        let players = neuralSeats(decoder)
        var world = newWorld(seed, 600)
        let handle = pw_create(seed, 600)
        require handle != nil
        check pw_set_action_contract(handle, 2) == 0
        var river = [9'i32, 10]
        for slot in 0..<Seats:
          check pw_set_seat_sampling(handle, slot.cint, 1000, 0) == 0
          check pw_set_seat_aim_snap(handle, slot.cint, angle) == 0
          check pw_set_seat_steady_shot(handle, slot.cint, 1) == 0
          if full:
            check pw_set_seat_forbid_objectives(handle, slot.cint, ibuf(river), 2) == 0
            check pw_set_seat_strafe(handle, slot.cint, 5250, 3, 6, 6, 9, 800) == 0
            check pw_set_seat_fire_hold(handle, slot.cint, 1) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var rewards, terminals: array[Seats, float32]
        var zero: array[LogitSize, float32]
        var steps = 0
        while world.winner == -1 and world.tick < world.endTick:
          # A hosted seat decides (and draws) only while alive on the pre-step world.
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
        var snaps, shots = 0
        for slot in 0..<Seats:
          let seat = players[slot].neural
          var stats: array[3, int32]
          check pw_seat_aim_snap_stats(handle, slot.cint, ibuf(stats)) == 0
          check stats[0] == seat.aimSnaps.int32 and stats[2] == seat.aimSnap.cosQ15.int32
          check pw_seat_steady_stats(handle, slot.cint, ibuf(stats)) == 0
          check stats[0] == seat.steadyShots.int32 and stats[1] == seat.steadyTicks.int32
          let line = seat.telemetry(10, steps)
          check line.contains(" aim_snap=" & formatFloat(angle.float/1000, ffDecimal, 3) & "deg,cos_q15=" &
            $seat.aimSnap.cosQ15 & " aim_snaps=" & $seat.aimSnaps)
          check line.contains(" steady_shot=on steady_shots=" & $seat.steadyShots & " steady_ticks=" & $seat.steadyTicks)
          snaps += seat.aimSnaps
          shots += seat.steadyShots
        checkpoint decoder & " seed " & $seed & " steps " & $steps & " snaps " & $snaps & " shots " & $shots
        check steps > 100 and snaps > 0 and shots > 20
        pw_destroy(handle)
