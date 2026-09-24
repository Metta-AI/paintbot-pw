## The fire hold's radius (decoder.fire_hold_teammates {"radius": r}) through the native
## training ABI: arguments, read-back and reset semantics; a handle holding at radius 150
## on one team and 55 on the other matches the reference engine applying
## neural_contract.holdFire with those radii, hash for hash and hold for hold; radius 0 and
## 55 are byte-identical to the default hold, and a radius without the hold changes
## nothing; and hosted neural seats with {"radius": 150} on either side (the boolean form on
## the other) equal the ABI, hash for hash. PW_FH_TICKS (default 600) and PW_FH_SEEDS
## (default 8) size the hosted matches. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, strutils]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots, neural_host]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc mixedActions(w: World, actions: var array[Seats*ActionSizes.len, int32], seed: int) =
  ## Identity aims at the nearest apparent enemy, else a changing compass aim; heart
  ## objectives; fire, grenade and sneak on schedules (the fire-hold suite's policy).
  for slot in 0..<Seats:
    let o = slot*ActionSizes.len
    actions[o] = int32(1+(slot div 2+seed) mod 10)
    actions[o+1] = int32(17+(w.tick.int div 24+slot) mod 8)
    let bodies = w.observedBodies(slot)
    var best = high(int64)
    for identity, body in bodies:
      if body < 0 or w.observedTeam(slot, body) == team(slot): continue
      let d = distance2(w.cogs[slot].pos, w.cogs[body].pos)
      if d < best:
        best = d
        actions[o+1] = int32(identity+1)
    actions[o+2] = int32(w.tick mod 3 == 0)
    actions[o+3] = int32(w.tick mod 48 < 12)
    actions[o+4] = int32(slot mod 3 == 0)

suite "Native decoder fire hold radius":
  configureRules(NativeRules)
  test "arguments, defaults, read-back and reset semantics":
    let h = pw_create(1, 240)
    require h != nil
    defer: pw_destroy(h)
    for slot in 0..<Seats: check pw_seat_fire_hold_radius(h, slot.cint) == 55
    for (seat, r) in [(-1, 150'i32), (Seats, 150'i32), (0, -1'i32), (0, 2001'i32)]:
      check pw_set_seat_fire_hold_radius(h, seat.cint, r) == -1
    check pw_set_seat_fire_hold_radius(nil, 0, 150) == -1
    check pw_seat_fire_hold_radius(nil, 0) == -1
    check pw_seat_fire_hold_radius(h, Seats.cint) == -1
    check pw_set_seat_fire_hold_radius(h, 0, 150) == 0 and pw_seat_fire_hold_radius(h, 0) == 150
    check pw_set_seat_fire_hold_radius(h, 0, 1) == 0 and pw_seat_fire_hold_radius(h, 0) == 1
    check pw_set_seat_fire_hold_radius(h, 0, 2000) == 0 and pw_seat_fire_hold_radius(h, 0) == 2000
    check pw_set_seat_fire_hold_radius(h, 0, 0) == 0 and pw_seat_fire_hold_radius(h, 0) == 55   # 0 = the default
    check pw_set_seat_fire_hold_radius(h, 3, 150) == 0
    check pw_reset(h, 2, 240) == 0
    check pw_seat_fire_hold_radius(h, 3) == 150   # kept across reset
  test "radius 150 on one team and 55 on the other match the reference engine's holdFire with those radii":
    var total150, total55 = 0
    for contract in [1'i32, 2]:
      for seed in [0'i32, 1, 2]:
        let matchSeed = seed + 61
        var reference = newWorld(matchSeed, 720)
        let handle = pw_create(matchSeed, 720)
        require handle != nil
        check pw_set_action_contract(handle, contract) == 0
        let version = ActionContractVersion(contract)
        for slot in 0..<Seats:
          check pw_set_seat_fire_hold(handle, slot.cint, 1) == 0
          if slot mod 2 == 0: check pw_set_seat_fire_hold_radius(handle, slot.cint, 150) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var commands: array[Seats, Command]
        var rewards, terminals: array[Seats, float32]
        var memories: array[Seats, AimMemory]
        var held: array[Seats, int]
        for pass in 0..1:
          reference = newWorld(matchSeed, 720)
          if pass == 1: check pw_reset(handle, matchSeed, 720) == 0
          for slot in 0..<Seats:
            memories[slot].resetAimMemory()
            held[slot] = 0
          while reference.winner == -1 and reference.tick < reference.endTick:
            mixedActions(reference, actions, seed.int)
            for slot in 0..<Seats:
              let o = slot*ActionSizes.len
              let bodies = reference.observedBodies(slot)
              commands[slot] = reference.decodeActions(slot, actions.toOpenArray(o, o+ActionSizes.len-1), bodies,
                version, memories[slot])
              if version == acV2: memories[slot].recordAimMemory(reference, slot, bodies)
              if reference.holdFire(slot, commands[slot], if slot mod 2 == 0: 150'i32 else: FireHoldRadius.int32):
                inc held[slot]
            reference.step(commands)
            require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
            require pw_state_hash(handle) == reference.stateHash()
          for slot in 0..<Seats:
            check pw_seat_fire_held(handle, slot.cint) == held[slot].cint
            if slot mod 2 == 0: total150 += held[slot] else: total55 += held[slot]
        pw_destroy(handle)
    checkpoint "held at 150: " & $total150 & ", at 55: " & $total55
    check total150 > total55 and total55 > 0
  test "radius 0 and 55 are byte-identical to the default hold; a radius without the hold changes nothing":
    let plain = pw_create(9, 600)
    let r55 = pw_create(9, 600)
    let r0 = pw_create(9, 600)
    let noHold = pw_create(9, 600)
    let bare = pw_create(9, 600)
    require plain != nil and r55 != nil and r0 != nil and noHold != nil and bare != nil
    for slot in 0..<Seats:
      for h in [plain, r55, r0]: check pw_set_seat_fire_hold(h, slot.cint, 1) == 0
      check pw_set_seat_fire_hold_radius(r55, slot.cint, 55) == 0
      check pw_set_seat_fire_hold_radius(r0, slot.cint, 150) == 0
      check pw_set_seat_fire_hold_radius(r0, slot.cint, 0) == 0
      check pw_set_seat_fire_hold_radius(noHold, slot.cint, 150) == 0
    var reference = newWorld(9, 600)
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    while reference.winner == -1 and reference.tick < reference.endTick:
      mixedActions(reference, actions, 9)
      for h in [plain, r55, r0, noHold, bare]: require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_state_hash(r55) == pw_state_hash(plain) and pw_state_hash(r0) == pw_state_hash(plain)
      require pw_state_hash(noHold) == pw_state_hash(bare)
      var commands: array[Seats, Command]
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        commands[slot] = reference.decodeActions(slot, actions.toOpenArray(o, o+ActionSizes.len-1),
          reference.observedBodies(slot))
      reference.step(commands)
      require pw_state_hash(bare) == reference.stateHash()
    for slot in 0..<Seats:
      check pw_seat_fire_held(r55, slot.cint) == pw_seat_fire_held(plain, slot.cint)
      check pw_seat_fire_held(noHold, slot.cint) == 0
    var any = 0
    for slot in 0..<Seats: any += pw_seat_fire_held(plain, slot.cint)
    check any > 0
    for h in [plain, r55, r0, noHold, bare]: pw_destroy(h)

suite "Hosted neural seats and the native ABI take the same fire hold (radius)":
  configureRules(NativeRules)
  proc u32(s: var string, value: uint32) =
    for i in 0..3: s.add char((value shr (8*i)) and 255)
  proc zeroModel(): string =
    ## A valid contract-v2 actor whose logits are all zero: every sampled head is a
    ## uniform draw, so shoot orders with teammates near the line are frequent.
    const h = 64
    const n = ObservationSize*h + 3*h*h + LogitSize*h
    result = "PWNET001"
    for x in [1,ObservationSize,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
    result.add ObservationContractHash
    result.add ActionContractV2Hash
    for x in ActionSizes: result.u32(x.uint32)
    result.add repeat('\0', n*4)
  proc neuralSeats(decoder: string): array[Seats, Bot] =
    let path = getTempDir()/"paintbot-native-fire-hold-radius-test.bas"
    writeFile(path, "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "paintbot_act(neuralLogits())\n")
    writeFile(path & ".model.bin", zeroModel())
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      ObservationContractHash & "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}, \"decoder\": " & decoder & "}")
    defer:
      removeFile(path); removeFile(path & ".model.bin"); removeFile(path & ".neural.json")
    loadBots(@[BotGroup(path: path, count: Seats)])
  let ticks = parseInt(getEnv("PW_FH_TICKS", "600"))
  let seeds = parseInt(getEnv("PW_FH_SEEDS", "8"))
  test "radius 150 on either side, the boolean form on the other: every tick's world equals the ABI's, holds equal":
    var matches, held150, held55 = 0
    for seedIndex in 0..<seeds:
      let seed = int32(21 + seedIndex)
      for side in 0..1:
        let wide = neuralSeats("{\"fire_hold_teammates\": {\"radius\": 150}, \"sampling\": {\"mode\": \"categorical\"}}")
        let plain = neuralSeats("{\"fire_hold_teammates\": true, \"sampling\": {\"mode\": \"categorical\"}}")
        var players: array[Seats, Bot]
        for slot in 0..<Seats: players[slot] = if team(slot) == side: wide[slot] else: plain[slot]
        var world = newWorld(seed, ticks.int32)
        let handle = pw_create(seed, ticks.int32)
        require handle != nil
        check pw_set_action_contract(handle, 2) == 0
        for slot in 0..<Seats:
          check pw_set_seat_sampling(handle, slot.cint, 1000, 0) == 0
          check pw_set_seat_fire_hold(handle, slot.cint, 1) == 0
          if team(slot) == side: check pw_set_seat_fire_hold_radius(handle, slot.cint, 150) == 0
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
        var h150, h55 = 0
        for slot in 0..<Seats:
          let seat = players[slot].neural
          check pw_seat_fire_held(handle, slot.cint) == seat.fireHolds.int32
          let line = seat.telemetry(10, steps)
          if team(slot) == side:
            check seat.fireHoldRadius == 150
            check line.contains(" fire_holds=" & $seat.fireHolds & " fire_hold_radius=150")
            h150 += seat.fireHolds
          else:
            check seat.fireHoldRadius == 55
            check line.contains(" fire_holds=" & $seat.fireHolds) and not line.contains("fire_hold_radius")
            h55 += seat.fireHolds
        echo "  hosted==ABI seed ", seed, " side ", side, " steps ", steps, " holds r150 ", h150, " r55 ", h55
        check steps > 100
        held150 += h150; held55 += h55
        inc matches
        pw_destroy(handle)
    check matches == seeds * 2 and held150 > held55 and held55 > 0
