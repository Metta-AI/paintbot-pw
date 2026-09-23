## The decoder options forbid_objectives and strafe_legs through the native training ABI:
## arguments and reset semantics; pw_sample_actions never selects a forbidden objective
## (argmax or draw, the reference sampler on the hosted seat's stream) and pw_step refuses
## one from the caller without stepping; a strafe-on handle matches the reference engine
## applying neural_contract.strafeActions (on the hosted seat's strafe stream) before the
## shared decoder, hash for hash under both contracts and across a reset, with the leg
## counts and the executed movement reported; options off byte-identical to a fresh handle.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, strutils]
import polyworld/[rngs, cli]
import ../examples/paintbot/[sim, neural_contract, native_env, bots, neural_host]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

const River = [9'i32, 10]

proc logitsFor(seed: int): array[LogitSize, float32] =
  var x = uint32(seed)*2654435761'u32 + 12345
  for i in 0..<LogitSize:
    x = x*1664525'u32 + 1013904223'u32
    result[i] = float32(int((x shr 8) mod 6000) - 3000) / 1000'f32

proc riverMask(): ObjectiveMask =
  result[9] = true
  result[10] = true

proc mixedActions(w: World, actions: var array[Seats*ActionSizes.len, int32], seed: int, avoid: ObjectiveMask) =
  ## Heart objectives (never an avoided one), identity aim at the nearest apparent enemy
  ## else a changing compass aim, fire, grenade and sneak on schedules.
  for slot in 0..<Seats:
    let o = slot*ActionSizes.len
    var objective = int32(1+(slot div 2+seed+w.tick.int div 97) mod 10)
    while avoid[objective]: objective = objective mod 10 + 1
    actions[o] = objective
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
    actions[o+4] = int32(slot mod 5 == 0)

proc strafeDefaults(handle: pointer, seat: int): cint =
  pw_set_seat_strafe(handle, seat.cint, 5250, 3, 6, 6, 9, 800)

suite "Native decoder objective forbid":
  configureRules(NativeRules)
  test "arguments, read-back and reset semantics":
    let h = pw_create(1, 240)
    require h != nil
    defer: pw_destroy(h)
    var mask: array[ActionSizes[0], int32]
    check pw_seat_forbidden_objectives(h, 0, ibuf(mask)) == 0
    for v in mask: check v == 0
    var river = River
    var bad = [9'i32, 9]
    var outside = [51'i32]
    var negative = [-1'i32]
    var every: array[ActionSizes[0], int32]
    for i in 0..<ActionSizes[0]: every[i] = i.int32
    check pw_set_seat_forbid_objectives(nil, 0, ibuf(river), 2) == -1
    check pw_set_seat_forbid_objectives(h, -1, ibuf(river), 2) == -1
    check pw_set_seat_forbid_objectives(h, Seats.cint, ibuf(river), 2) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(river), -1) == -1
    check pw_set_seat_forbid_objectives(h, 0, nil, 2) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(bad), 2) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(outside), 1) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(negative), 1) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(every), ActionSizes[0].int32) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(every), ActionSizes[0].int32 - 1) == 0  # 50 left allowed
    check pw_seat_forbidden_objectives(h, 0, ibuf(mask)) == ActionSizes[0] - 1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(river), 2) == 0
    check pw_seat_forbidden_objectives(h, 0, ibuf(mask)) == 2
    for i, v in mask: check v == int32(i in [9, 10])
    check pw_seat_forbidden_objectives(h, 0, nil) == 2
    check pw_seat_forbidden_objectives(nil, 0, nil) == -1
    check pw_seat_forbidden_objectives(h, Seats.cint, nil) == -1
    # A failed call leaves the mask as it was; kept across reset; count 0 clears.
    check pw_set_seat_forbid_objectives(h, 0, ibuf(bad), 2) == -1
    check pw_seat_forbidden_objectives(h, 0, nil) == 2
    check pw_reset(h, 2, 240) == 0
    check pw_seat_forbidden_objectives(h, 0, nil) == 2
    check pw_set_seat_forbid_objectives(h, 0, nil, 0) == 0
    check pw_seat_forbidden_objectives(h, 0, nil) == 0
  test "pw_sample_actions never selects a forbidden objective, argmax or sampled on the hosted stream":
    let h = pw_create(7, 14400)
    require h != nil
    defer: pw_destroy(h)
    var river = River
    check pw_set_seat_forbid_objectives(h, 3, ibuf(river), 2) == 0
    for s in 0..<200:
      var logits = logitsFor(s)
      logits[9] = 20
      var picked: array[ActionSizes.len, int32]
      check pw_sample_actions(h, 3, fbuf(logits), ibuf(picked)) == 0
      check picked == argmaxActions(logits, riverMask())
      check picked[0] notin [9'i32, 10]
    check pw_set_seat_sampling(h, 3, 1000, 0) == 0
    var options: SamplingOptions
    options.enabled = true
    options.temperature = 1
    for head in 0..<ActionSizes.len: options.heads[head] = true
    var reference = samplingRng(7, 3)
    for s in 0..<500:
      var logits = logitsFor(s)
      logits[9] = 4; logits[10] = 4
      var picked: array[ActionSizes.len, int32]
      check pw_sample_actions(h, 3, fbuf(logits), ibuf(picked)) == 0
      check picked == sampleActions(logits, options, reference, riverMask())
      check picked[0] notin [9'i32, 10]
    check pw_seat_sample_draws(h, 3) == 500
  test "pw_step refuses a forbidden objective from the caller without stepping; scripted seats are exempt":
    let h = pw_create(11, 240)
    let plain = pw_create(11, 240)
    require h != nil and plain != nil
    defer:
      pw_destroy(h)
      pw_destroy(plain)
    var river = River
    check pw_set_seat_forbid_objectives(h, 4, ibuf(river), 2) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, cfloat]
    let before = pw_state_hash(h)
    actions[4*ActionSizes.len] = 10
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == -3
    check pw_state_hash(h) == before
    actions[4*ActionSizes.len] = 9
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == -3
    # Another seat may choose it; the forbidding seat choosing anything else steps exactly
    # like a handle without the forbid.
    actions[4*ActionSizes.len] = 3
    actions[5*ActionSizes.len] = 9
    for tick in 0..<60:
      check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step(plain, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_state_hash(h) == pw_state_hash(plain)
    # A seat driven by its script (override 0) ignores the caller's action, so it is not checked.
    var idle = "walkTo(selfX, selfY)\n"
    check pw_set_seat_script(h, 4, cast[ptr UncheckedArray[char]](addr idle[0]), idle.len.int32) == 0
    actions[4*ActionSizes.len] = 9
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_set_seat_override(h, 4, 1) == 0
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == -3
    # Dead seats (whose actions the decoder ignores) are exempt: the hosted-vs-ABI suite
    # below hands dead seats index 0, which it forbids, through every death in its matches.

suite "Native decoder strafe legs":
  configureRules(NativeRules)
  test "arguments, defaults and reset semantics":
    let h = pw_create(1, 240)
    require h != nil
    defer: pw_destroy(h)
    var stats: array[3, int32]
    check pw_seat_strafe_stats(h, 0, ibuf(stats)) == 0
    check stats == [0'i32, 0, -1]
    check pw_set_seat_strafe(nil, 0, 5250, 3, 6, 6, 9, 800) == -1
    check pw_set_seat_strafe(h, -1, 5250, 3, 6, 6, 9, 800) == -1
    check pw_set_seat_strafe(h, Seats.cint, 5250, 3, 6, 6, 9, 800) == -1
    check pw_set_seat_strafe(h, 0, -1, 3, 6, 6, 9, 800) == -1
    check pw_set_seat_strafe(h, 0, 20001, 3, 6, 6, 9, 800) == -1
    check pw_set_seat_strafe(h, 0, 5250, 0, 6, 6, 9, 800) == -1
    check pw_set_seat_strafe(h, 0, 5250, 7, 6, 6, 9, 800) == -1
    check pw_set_seat_strafe(h, 0, 5250, 3, 73, 6, 9, 800) == -1
    check pw_set_seat_strafe(h, 0, 5250, 3, 6, 5, 9, 800) == -1
    check pw_set_seat_strafe(h, 0, 5250, 3, 6, 10, 9, 800) == -1
    check pw_set_seat_strafe(h, 0, 5250, 3, 6, 6, 9, 1001) == -1
    check pw_set_seat_strafe(h, 0, 5250, 3, 6, 6, 9, -1) == -1
    check pw_seat_strafe_stats(nil, 0, ibuf(stats)) == -1
    check pw_seat_strafe_stats(h, 0, nil) == -1
    check strafeDefaults(h, 0) == 0
    check pw_set_seat_strafe(h, 0, 0, 0, 0, 0, 0, 0) == 0   # off
    check pw_set_seat_strafe(h, 0, 0, 99, -5, 0, 0, 7) == 0  # off: the rest is ignored
  test "a strafe-on handle matches the reference engine applying strafeActions before the shared decoder":
    for contract in [1'i32, 2]:
      for seed in [0'i32, 1]:
        let matchSeed = seed + 71
        var reference = newWorld(matchSeed, 900)
        let handle = pw_create(matchSeed, 900)
        require handle != nil
        check pw_set_action_contract(handle, contract) == 0
        let version = ActionContractVersion(contract)
        # Team 0 strafes (seat 0 with a forbid on the river hearts too), team 1 plain.
        for slot in countup(0, Seats-1, 2): check strafeDefaults(handle, slot) == 0
        var river = River
        check pw_set_seat_forbid_objectives(handle, 0, ibuf(river), 2) == 0
        var avoid: array[Seats, ObjectiveMask]
        avoid[0] = riverMask()
        var actions: array[Seats*ActionSizes.len, int32]
        var commands: array[Seats, Command]
        var rewards, terminals: array[Seats, float32]
        var states: array[Seats, StrafeState]
        var rngs: array[Seats, Rng]
        var memories: array[Seats, AimMemory]
        var totalLegs, replaced = 0
        for pass in 0..1:
          reference = newWorld(matchSeed, 900)
          if pass == 1: check pw_reset(handle, matchSeed, 900) == 0
          for slot in 0..<Seats:
            states[slot] = initStrafeState(slot)
            rngs[slot] = strafeRng(matchSeed, slot)
            memories[slot].resetAimMemory()
          while reference.winner == -1 and reference.tick < reference.endTick:
            mixedActions(reference, actions, seed.int, avoid[0])
            var executed: array[Seats, int32]
            for slot in 0..<Seats:
              let o = slot*ActionSizes.len
              var heads: array[ActionSizes.len, int32]
              for head in 0..<ActionSizes.len: heads[head] = actions[o+head]
              let bodies = reference.observedBodies(slot)
              executed[slot] = -1
              if slot mod 2 == 0 and reference.strafeActions(slot, heads, bodies, defaultStrafeOptions(),
                  states[slot], rngs[slot], avoid[slot]):
                executed[slot] = heads[0]
                inc replaced
              commands[slot] = reference.decodeActions(slot, heads, bodies, version, memories[slot])
              if version == acV2: memories[slot].recordAimMemory(reference, slot, bodies)
            reference.step(commands)
            require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
            require pw_state_hash(handle) == reference.stateHash()
            for slot in 0..<Seats:
              var stats: array[3, int32]
              check pw_seat_strafe_stats(handle, slot.cint, ibuf(stats)) == 0
              check stats == [states[slot].legs, states[slot].ticks, executed[slot]]
          for slot in countup(0, Seats-1, 2): totalLegs += states[slot].legs
        pw_destroy(handle)
        checkpoint "contract " & $contract & " seed " & $seed
        check totalLegs > 20 and replaced > 100   # the strafe actually ran
  test "strafe and forbid off are byte-identical to a fresh handle; toggling back off restores it":
    let plain = pw_create(2026, 600)
    let toggled = pw_create(2026, 600)
    require plain != nil and toggled != nil
    defer:
      pw_destroy(plain)
      pw_destroy(toggled)
    var river = River
    for slot in 0..<Seats:
      check strafeDefaults(toggled, slot) == 0
      check pw_set_seat_forbid_objectives(toggled, slot.cint, ibuf(river), 2) == 0
      check pw_set_seat_strafe(toggled, slot.cint, 0, 0, 0, 0, 0, 0) == 0
      check pw_set_seat_forbid_objectives(toggled, slot.cint, nil, 0) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, cfloat]
    var none: ObjectiveMask
    var w = newWorld(2026, 600)
    for tick in 0..<600:
      mixedActions(w, actions, 3, none)
      check pw_step(plain, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step(toggled, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_state_hash(plain) == pw_state_hash(toggled)
      var commands: array[Seats, Command]
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        commands[slot] = w.decodeActions(slot, actions.toOpenArray(o, o+ActionSizes.len-1), w.observedBodies(slot))
      w.step(commands)
      if terminals[0] != 0: break

suite "Hosted neural seats and the native ABI take the same decoder path":
  configureRules(NativeRules)
  proc u32(s: var string, value: uint32) =
    for i in 0..3: s.add char((value shr (8*i)) and 255)
  proc zeroModel(): string =
    ## A valid contract-v2 actor whose logits are all zero: argmax takes index 0 of every
    ## head, a sampled head is a uniform draw over its allowed candidates.
    const h = 64
    const n = ObservationSize*h + 3*h*h + LogitSize*h
    result = "PWNET001"
    for x in [1,ObservationSize,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
    result.add ObservationContractHash
    result.add ActionContractV2Hash
    for x in ActionSizes: result.u32(x.uint32)
    result.add repeat('\0', n*4)
  proc neuralSeats(decoder: string): array[Seats, Bot] =
    let path = getTempDir()/"paintbot-native-river-strafe-test.bas"
    writeFile(path, "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "paintbot_act(neuralLogits())\n")
    writeFile(path & ".model.bin", zeroModel())
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      ObservationContractHash & "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}, \"decoder\": " & decoder & "}")
    defer:
      removeFile(path); removeFile(path & ".model.bin"); removeFile(path & ".neural.json")
    loadBots(@[BotGroup(path: path, count: Seats)])
  test "forbid + sampling + strafe + hold: every hosted seat's world equals the ABI's, hash for hash":
    # Every seat runs the bundle; the ABI handle gets the same options on every seat and
    # the zero logits through pw_sample_actions, then pw_step.
    for (decoder, sampled) in [("{\"fire_hold_teammates\": true, \"forbid_objectives\": [0, 9, 10], \"strafe_legs\": {}, " &
                                "\"sampling\": {\"mode\": \"categorical\"}}", true),
                               ("{\"forbid_objectives\": [0, 9, 10], \"strafe_legs\": {\"legs\": [2, 4], \"reverse_permille\": 500}}", false)]:
      for seed in [3'i32, 4]:
        let players = neuralSeats(decoder)
        var world = newWorld(seed, 600)
        let handle = pw_create(seed, 600)
        require handle != nil
        check pw_set_action_contract(handle, 2) == 0
        var forbid = [0'i32, 9, 10]
        for slot in 0..<Seats:
          check pw_set_seat_forbid_objectives(handle, slot.cint, ibuf(forbid), 3) == 0
          if sampled:
            check strafeDefaults(handle, slot) == 0
            check pw_set_seat_sampling(handle, slot.cint, 1000, 0) == 0
            check pw_set_seat_fire_hold(handle, slot.cint, 1) == 0
          else:
            check pw_set_seat_strafe(handle, slot.cint, 5250, 2, 4, 6, 9, 500) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var rewards, terminals: array[Seats, float32]
        var zero: array[LogitSize, float32]
        var steps = 0
        var decisions: array[Seats, int]
        while world.winner == -1 and world.tick < world.endTick:
          # A hosted seat decides (and draws) only while alive on the pre-step world, so the
          # ABI caller selects actions for exactly those seats; a dead seat's are ignored.
          for slot in 0..<Seats:
            let o = slot*ActionSizes.len
            for head in 0..<ActionSizes.len: actions[o+head] = 0
            if world.cogs[slot].hp > 0:
              inc decisions[slot]
              require pw_sample_actions(handle, slot.cint, fbuf(zero), ibuf(actions.toOpenArray(o, o+ActionSizes.len-1))) == 0
          let commands = players.decide(world)
          for slot in 0..<Seats: require not players[slot].failed
          world.step(commands)
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == world.stateHash()
          inc steps
        var legs = 0
        for slot in 0..<Seats:
          var stats: array[3, int32]
          check pw_seat_strafe_stats(handle, slot.cint, ibuf(stats)) == 0
          check stats[0] == players[slot].neural.strafeState.legs and stats[1] == players[slot].neural.strafeState.ticks
          # Zero logits: the unmasked argmax objective is index 0, forbidden, on every decision.
          check players[slot].neural.telemetry(10, steps).contains(" forbid_objectives=0,9,10 forbid_hits=" & $decisions[slot])
          legs += stats[0]
          if sampled: check pw_seat_sample_draws(handle, slot.cint) == players[slot].neural.sampleDraws.cint
        checkpoint decoder & " seed " & $seed
        check steps > 100 and legs > 50
        pw_destroy(handle)
