## The decoder options aim_retarget and shot_gate through the native training ABI:
## arguments, read-back and reset semantics; a handle with the options on matches the
## reference engine applying neural_contract.aimRetargetActions, aimSnapActions,
## shotGateActions, strafeActions and steadyShotActions (in that order) before the shared
## decoder, hash for hash under both contracts and across a reset, with the counts and
## executed heads reported; options off byte-identical to a fresh handle; and hosted
## neural seats with the options (with forbid, sampling, snap, strafe, steady and hold) on
## either side equal to the ABI, hash for hash, over eight seeds. PW_RG_TICKS (default
## 600) sets the hosted matches' length and PW_RG_SEEDS (default 8) their seed count.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, strutils]
import polyworld/[rngs, cli]
import ../examples/paintbot/[sim, neural_contract, native_env, bots, neural_host]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc shootingActions(w: World, actions: var array[Seats*ActionSizes.len, int32], seed: int) =
  ## Heart objectives or compass legs on a schedule; aims cycle through compass headings,
  ## arbitrary identities and keep; fire on two ticks in three; grenade and sneak on
  ## schedules. Many shoot orders are aimed badly, so the retarget and the gate both act.
  for slot in 0..<Seats:
    let o = slot*ActionSizes.len
    let t = w.tick.int
    actions[o] = if (t div 40 + slot) mod 3 == 0: int32(43 + (t div 17 + slot) mod 8)
                 else: int32(1+(slot div 2+seed+t div 53) mod 10)
    actions[o+1] = case (t + slot + seed) mod 7
      of 0: 0'i32
      of 1, 2: int32(1 + (t div 5 + slot*3) mod 16)
      else: int32(17+(t div 9+slot+seed) mod 8)
    actions[o+2] = int32(w.tick mod 3 != 0)
    actions[o+3] = int32(w.tick mod 48 < 12)
    actions[o+4] = int32(slot mod 5 == 0)

suite "Native decoder aim retarget and shot gate":
  configureRules(NativeRules)
  test "arguments, defaults, read-back and reset semantics":
    let h = pw_create(1, 240)
    require h != nil
    defer: pw_destroy(h)
    var stats: array[3, int32]
    check pw_seat_aim_retarget_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, -1, 0]
    check pw_seat_shot_gate_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, -1, 0]
    for (seat, on, r, hp, carry) in [(-1, 1'i32, 5250'i32, 160000'i32, 2500000'i32), (Seats, 1'i32, 5250'i32, 160000'i32, 2500000'i32),
        (0, 2'i32, 5250'i32, 160000'i32, 2500000'i32), (0, -1'i32, 5250'i32, 160000'i32, 2500000'i32),
        (0, 1'i32, 0'i32, 160000'i32, 2500000'i32), (0, 1'i32, 20001'i32, 160000'i32, 2500000'i32),
        (0, 1'i32, 5250'i32, -1'i32, 2500000'i32), (0, 1'i32, 5250'i32, 1_000_000_001'i32, 2500000'i32),
        (0, 1'i32, 5250'i32, 160000'i32, -1'i32), (0, 1'i32, 5250'i32, 160000'i32, 1_000_000_001'i32)]:
      check pw_set_seat_aim_retarget(h, seat.cint, on, r, hp, carry) == -1
    check pw_set_seat_aim_retarget(nil, 0, 1, 5250, 160000, 2500000) == -1
    check pw_seat_aim_retarget_stats(nil, 0, ibuf(stats)) == -1
    check pw_seat_aim_retarget_stats(h, 0, nil) == -1
    check pw_set_seat_aim_retarget(h, 0, 1, 5250, 160000, 2500000) == 0
    check pw_seat_aim_retarget_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, -1, 5250]
    check pw_set_seat_aim_retarget(h, 0, 1, 1, 0, 0) == 0 and pw_set_seat_aim_retarget(h, 0, 1, 20000, 1_000_000_000, 1_000_000_000) == 0
    check pw_set_seat_aim_retarget(h, 0, 0, -7, -7, -7) == 0   # off: the parameters are ignored
    check pw_seat_aim_retarget_stats(h, 0, ibuf(stats)) == 0 and stats[2] == 0
    for (seat, r) in [(-1, 5250'i32), (Seats, 5250'i32), (0, -1'i32), (0, 20001'i32)]:
      check pw_set_seat_shot_gate(h, seat.cint, r) == -1
    check pw_set_seat_shot_gate(nil, 0, 5250) == -1
    check pw_seat_shot_gate_stats(nil, 0, ibuf(stats)) == -1
    check pw_seat_shot_gate_stats(h, 0, nil) == -1
    check pw_set_seat_shot_gate(h, 0, 5250) == 0
    check pw_seat_shot_gate_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, -1, 5250]
    check pw_set_seat_shot_gate(h, 0, 1) == 0 and pw_set_seat_shot_gate(h, 0, 20000) == 0
    check pw_set_seat_shot_gate(h, 0, 0) == 0   # off
    check pw_seat_shot_gate_stats(h, 0, ibuf(stats)) == 0 and stats[2] == 0
    # Options persist across reset; counts reset.
    check pw_set_seat_aim_retarget(h, 3, 1, 5250, 160000, 2500000) == 0
    check pw_set_seat_shot_gate(h, 3, 5250) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, cfloat]
    var w = newWorld(1, 240)
    for tick in 0..<200:
      shootingActions(w, actions, 0)
      require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      var commands: array[Seats, Command]
      w.step(commands)   # only the tick matters to shootingActions' schedules
    check pw_seat_shot_gate_stats(h, 3, ibuf(stats)) == 0
    check stats[0] > 0
    check pw_reset(h, 2, 240) == 0
    check pw_seat_shot_gate_stats(h, 3, ibuf(stats)) == 0
    check stats == [0'i32, -1, 5250]
    check pw_seat_aim_retarget_stats(h, 3, ibuf(stats)) == 0
    check stats == [0'i32, -1, 5250]
  test "an options-on handle matches the reference engine applying retarget, snap, gate, strafe and steady before the shared decoder":
    for contract in [1'i32, 2]:
      for seed in [0'i32, 1]:
        let matchSeed = seed + 91
        var reference = newWorld(matchSeed, 900)
        let handle = pw_create(matchSeed, 900)
        require handle != nil
        check pw_set_action_contract(handle, contract) == 0
        let version = ActionContractVersion(contract)
        # Seats 0 mod 4: retarget + snap + gate + steady; 1 mod 4: retarget (custom weights)
        # only; 2 mod 4: gate (3000) + snap 45 + strafe, no retarget; 3 mod 4: plain.
        var retargetOn: array[Seats, AimRetargetOptions]
        var gateOn: array[Seats, ShotGateOptions]
        var snapOn: array[Seats, AimSnapOptions]
        var steadyOn, strafeOn: array[Seats, bool]
        for slot in 0..<Seats:
          case slot mod 4
          of 0:
            retargetOn[slot] = aimRetargetOptions(); gateOn[slot] = shotGateOptions()
            snapOn[slot] = aimSnapOptions(22500); steadyOn[slot] = true
          of 1:
            retargetOn[slot] = aimRetargetOptions(4000, 0, 900000)
          of 2:
            gateOn[slot] = shotGateOptions(3000); snapOn[slot] = aimSnapOptions(45000); strafeOn[slot] = true
          else: discard
          let r = retargetOn[slot]
          if r.enabled: check pw_set_seat_aim_retarget(handle, slot.cint, 1, r.maxRange, r.hpWeight, r.carryWeight) == 0
          if gateOn[slot].enabled: check pw_set_seat_shot_gate(handle, slot.cint, gateOn[slot].maxRange) == 0
          if snapOn[slot].enabled: check pw_set_seat_aim_snap(handle, slot.cint, snapOn[slot].maxAngleMillideg) == 0
          if steadyOn[slot]: check pw_set_seat_steady_shot(handle, slot.cint, 1) == 0
          if strafeOn[slot]: check pw_set_seat_strafe(handle, slot.cint, 5250, 3, 6, 6, 9, 800) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var commands: array[Seats, Command]
        var rewards, terminals: array[Seats, float32]
        var states: array[Seats, StrafeState]
        var rngs: array[Seats, Rng]
        var memories: array[Seats, AimMemory]
        var retargets, snaps, gates, shots, ticks: array[Seats, int32]
        var totalRetargets, totalGates, snappedDrops, totalSnaps = 0
        for pass in 0..1:
          reference = newWorld(matchSeed, 900)
          if pass == 1: check pw_reset(handle, matchSeed, 900) == 0
          for slot in 0..<Seats:
            states[slot] = initStrafeState(slot)
            rngs[slot] = strafeRng(matchSeed, slot)
            memories[slot].resetAimMemory()
            retargets[slot] = 0; snaps[slot] = 0; gates[slot] = 0; shots[slot] = 0; ticks[slot] = 0
          while reference.winner == -1 and reference.tick < reference.endTick:
            shootingActions(reference, actions, seed.int)
            var retargetLast, snapLast, gateLast, strafeLast, steadyLast: array[Seats, int32]
            for slot in 0..<Seats:
              let o = slot*ActionSizes.len
              var heads: array[ActionSizes.len, int32]
              for head in 0..<ActionSizes.len: heads[head] = actions[o+head]
              let bodies = reference.observedBodies(slot)
              retargetLast[slot] = -1; snapLast[slot] = -1; gateLast[slot] = -1
              strafeLast[slot] = -1; steadyLast[slot] = -1
              if reference.aimRetargetActions(slot, heads, bodies, version, memories[slot], retargetOn[slot]):
                retargetLast[slot] = heads[1]
                inc retargets[slot]
              let beforeSnap = heads
              var snapped = reference.aimSnapActions(slot, heads, bodies, snapOn[slot])
              if reference.shotGateActions(slot, heads, beforeSnap, snapped, bodies, version, memories[slot], gateOn[slot]):
                if snapped: inc snappedDrops
                snapped = false
                gateLast[slot] = 0
                inc gates[slot]
              if snapped:
                snapLast[slot] = heads[1]
                inc snaps[slot]
              if strafeOn[slot] and reference.strafeActions(slot, heads, bodies, defaultStrafeOptions(),
                  states[slot], rngs[slot]):
                strafeLast[slot] = heads[0]
              let held = reference.steadyShotActions(slot, heads, steadyOn[slot])
              if held != ssNone:
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
              check pw_seat_aim_retarget_stats(handle, slot.cint, ibuf(stats)) == 0
              check stats == [retargets[slot], retargetLast[slot], (if retargetOn[slot].enabled: retargetOn[slot].maxRange else: 0'i32)]
              check pw_seat_shot_gate_stats(handle, slot.cint, ibuf(stats)) == 0
              check stats == [gates[slot], gateLast[slot], (if gateOn[slot].enabled: gateOn[slot].maxRange else: 0'i32)]
              check pw_seat_aim_snap_stats(handle, slot.cint, ibuf(stats)) == 0
              check stats[0] == snaps[slot] and stats[1] == snapLast[slot]
              check pw_seat_steady_stats(handle, slot.cint, ibuf(stats)) == 0
              check stats == [shots[slot], ticks[slot], steadyLast[slot]]
              check pw_seat_strafe_stats(handle, slot.cint, ibuf(stats)) == 0
              check stats == [states[slot].legs, states[slot].ticks, strafeLast[slot]]
          for slot in 0..<Seats:
            totalRetargets += retargets[slot]; totalGates += gates[slot]; totalSnaps += snaps[slot]
        pw_destroy(handle)
        checkpoint "contract " & $contract & " seed " & $seed & " retargets " & $totalRetargets &
          " gates " & $totalGates & " snapped drops " & $snappedDrops & " snaps " & $totalSnaps
        # The rules actually ran, including snapped orders the gate kept and dropped.
        check totalRetargets > 100 and totalGates > 100 and snappedDrops > 0 and totalSnaps > 0
  test "options off are byte-identical to a fresh handle; toggling back off restores it":
    let plain = pw_create(2026, 600)
    let toggled = pw_create(2026, 600)
    require plain != nil and toggled != nil
    defer:
      pw_destroy(plain)
      pw_destroy(toggled)
    check pw_set_action_contract(plain, 2) == 0 and pw_set_action_contract(toggled, 2) == 0
    for slot in 0..<Seats:
      check pw_set_seat_aim_retarget(toggled, slot.cint, 1, 5250, 160000, 2500000) == 0
      check pw_set_seat_shot_gate(toggled, slot.cint, 5250) == 0
      check pw_set_seat_aim_retarget(toggled, slot.cint, 0, 0, 0, 0) == 0
      check pw_set_seat_shot_gate(toggled, slot.cint, 0) == 0
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

suite "Hosted neural seats and the native ABI take the same decoder path (aim retarget, shot gate)":
  configureRules(NativeRules)
  proc u32(s: var string, value: uint32) =
    for i in 0..3: s.add char((value shr (8*i)) and 255)
  proc zeroModel(): string =
    ## A valid contract-v2 actor whose logits are all zero: a sampled head is a uniform
    ## draw over its allowed candidates, so compass and identity aims and shoot orders are
    ## frequent.
    const h = 64
    const n = ObservationSize*h + 3*h*h + LogitSize*h
    result = "PWNET001"
    for x in [1,ObservationSize,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
    result.add ObservationContractHash
    result.add ActionContractV2Hash
    for x in ActionSizes: result.u32(x.uint32)
    result.add repeat('\0', n*4)
  proc neuralSeats(decoder: string): array[Seats, Bot] =
    let path = getTempDir()/"paintbot-native-retarget-gate-test.bas"
    writeFile(path, "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "paintbot_act(neuralLogits())\n")
    writeFile(path & ".model.bin", zeroModel())
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      ObservationContractHash & "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}, \"decoder\": " & decoder & "}")
    defer:
      removeFile(path); removeFile(path & ".model.bin"); removeFile(path & ".neural.json")
    loadBots(@[BotGroup(path: path, count: Seats)])
  let ticks = parseInt(getEnv("PW_RG_TICKS", "600"))
  let seeds = parseInt(getEnv("PW_RG_SEEDS", "8"))
  test "every hosted seat's world equals the ABI's, hash for hash, with matching counts, options on either side":
    # The options side runs the bundle's decoder; the other side is a plain sampling seat.
    type Config = tuple[decoder: string, full: bool, retarget: AimRetargetOptions, gate: ShotGateOptions]
    let configs: seq[Config] = @[
      ("{\"fire_hold_teammates\": true, \"forbid_objectives\": [9, 10], \"strafe_legs\": {}, " &
       "\"sampling\": {\"mode\": \"categorical\"}, \"aim_snap\": {\"max_angle_deg\": 22.5}, \"steady_shot\": {}, " &
       "\"aim_retarget\": {}, \"shot_gate\": {}}", true, aimRetargetOptions(), shotGateOptions()),
      ("{\"sampling\": {\"mode\": \"categorical\"}, \"aim_retarget\": {\"max_range\": 4000, \"hp_weight\": 0, " &
       "\"carry_weight\": 900000}, \"shot_gate\": {\"max_range\": 3000}}", false, aimRetargetOptions(4000, 0, 900000),
       shotGateOptions(3000))]
    let plainSeats = "{\"sampling\": {\"mode\": \"categorical\"}}"
    var matches = 0
    for ci, config in configs:
      var configRetargets = 0
      for seedIndex in 0..<seeds:
        let seed = int32(3 + seedIndex)
        for side in 0..1:
          let on = neuralSeats(config.decoder)
          let off = neuralSeats(plainSeats)
          var players: array[Seats, Bot]
          for slot in 0..<Seats: players[slot] = if team(slot) == side: on[slot] else: off[slot]
          var world = newWorld(seed, ticks.int32)
          let handle = pw_create(seed, ticks.int32)
          require handle != nil
          check pw_set_action_contract(handle, 2) == 0
          var river = [9'i32, 10]
          for slot in 0..<Seats:
            check pw_set_seat_sampling(handle, slot.cint, 1000, 0) == 0
            if team(slot) != side: continue
            check pw_set_seat_aim_retarget(handle, slot.cint, 1, config.retarget.maxRange, config.retarget.hpWeight,
              config.retarget.carryWeight) == 0
            check pw_set_seat_shot_gate(handle, slot.cint, config.gate.maxRange) == 0
            if config.full:
              check pw_set_seat_aim_snap(handle, slot.cint, 22500) == 0
              check pw_set_seat_steady_shot(handle, slot.cint, 1) == 0
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
          var retargets, gates = 0
          for slot in 0..<Seats:
            let seat = players[slot].neural
            var stats: array[3, int32]
            check pw_seat_aim_retarget_stats(handle, slot.cint, ibuf(stats)) == 0
            check stats[0] == seat.aimRetargets.int32
            check pw_seat_shot_gate_stats(handle, slot.cint, ibuf(stats)) == 0
            check stats[0] == seat.shotGates.int32
            check pw_seat_aim_snap_stats(handle, slot.cint, ibuf(stats)) == 0
            check stats[0] == seat.aimSnaps.int32
            check pw_seat_steady_stats(handle, slot.cint, ibuf(stats)) == 0
            check stats[0] == seat.steadyShots.int32 and stats[1] == seat.steadyTicks.int32
            check pw_seat_fire_held(handle, slot.cint) == seat.fireHolds.int32
            let line = seat.telemetry(10, steps)
            if team(slot) == side:
              check line.contains(" aim_retarget=r" & $config.retarget.maxRange & ",hp" & $config.retarget.hpWeight &
                ",carry" & $config.retarget.carryWeight & " aim_retargets=" & $seat.aimRetargets)
              check line.contains(" shot_gate=r" & $config.gate.maxRange & " shot_gates=" & $seat.shotGates)
              retargets += seat.aimRetargets
              gates += seat.shotGates
            else:
              check not line.contains("aim_retarget") and not line.contains("shot_gate")
              check seat.aimRetargets == 0 and seat.shotGates == 0
          checkpoint "config " & $ci & " seed " & $seed & " side " & $side & " steps " & $steps &
            " retargets " & $retargets & " gates " & $gates
          echo "  hosted==ABI config ", ci, " seed ", seed, " side ", side, " steps ", steps,
            " retargets ", retargets, " gates ", gates
          check steps > 100 and gates > 0
          configRetargets += retargets
          inc matches
          pw_destroy(handle)
      check configRetargets > 0
    check matches == configs.len * seeds * 2
