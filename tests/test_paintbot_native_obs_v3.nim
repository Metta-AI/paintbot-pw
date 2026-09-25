## Observation contract v3 (PLAN-gcrl-spray G1): v2's 506 floats unchanged, then the seat's
## 8-float goal vector. Through the native training ABI: version selection, sizes, hashes,
## pw_set_seat_goal's validation, read-back and reset semantics; a v3 handle's rows equal a
## v2 handle's rows bitwise in columns 0..505 (all seats, stepping hash for hash) and carry
## each seat's goal in 506..513; a goal changes nothing on v1/v2 handles. Then hosted neural
## seats of a v3 bundle (a small deterministic non-zero actor, so the goal columns move its
## logits) with a different goal per team equal the ABI: every seat's observation bitwise,
## every tick's world hash. PW_V3_SEEDS (default 2 / 8 for the hosted test) and PW_V3_TICKS
## (default 480 / 600) size the runs. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, strutils, math]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots, neural_host, neural_actor]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

proc fp(buffer: var openArray[float32]): ptr UncheckedArray[cfloat] =
  cast[ptr UncheckedArray[cfloat]](addr buffer[0])
proc ip(buffer: var openArray[int32]): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](addr buffer[0])
proc bits(x: float32): uint32 = cast[uint32](x)

const
  PureWin: GoalVector = [1'f32, 0, 0, 0, 0, 0, 0, 0]
  Mixed: GoalVector = [1'f32, 0.25, 0.1, 0.5, -0.25, 0.1, -0.5, 0]

suite "Native observation contract v3 (goal vector)":
  configureRules(NativeRules)
  test "version selection, sizes, hashes, goal validation, read-back and reset":
    check pw_observation_size_for(3) == 514 and pw_observation_size_for(4) == -1
    check pw_create_observation(1, 24, 4) == nil
    var text: array[65, char]
    let buffer = cast[ptr UncheckedArray[char]](addr text[0])
    check pw_observation_contract_hash(3, buffer, 65) == 0
    check $cast[cstring](addr text[0]) == ObservationContractV3Hash
    let h = pw_create_observation(5, 24, 3)
    require h != nil
    defer: pw_destroy(h)
    check pw_observation_contract(h) == 3 and pw_handle_observation_size(h) == 514
    var g: array[GoalSize, float32]
    check pw_seat_goal(h, 0, fp(g)) == 0 and g == default(GoalVector)   # zeros until set
    var mixed = Mixed
    check pw_set_seat_goal(h, 3, fp(mixed)) == 0
    check pw_seat_goal(h, 3, fp(g)) == 0 and g == Mixed
    for bad in [[1.5'f32, 0, 0, 0, 0, 0, 0, 0], [0'f32, -1.01, 0, 0, 0, 0, 0, 0], [1'f32, 0, 0, 0, 0, 0, 0, 0.5],
                [NaN.float32, 0, 0, 0, 0, 0, 0, 0], [Inf.float32, 0, 0, 0, 0, 0, 0, 0]]:
      var b = bad
      check pw_set_seat_goal(h, 3, fp(b)) == -1
    check pw_seat_goal(h, 3, fp(g)) == 0 and g == Mixed   # unchanged by the refusals
    check pw_set_seat_goal(nil, 0, fp(mixed)) == -1 and pw_set_seat_goal(h, Seats.cint, fp(mixed)) == -1
    check pw_set_seat_goal(h, 0, nil) == -1 and pw_seat_goal(h, -1, fp(g)) == -1
    var edge = [1'f32, -1, 1, -1, 1, -1, 1, 0]
    check pw_set_seat_goal(h, 4, fp(edge)) == 0
    check pw_reset(h, 6, 24) == 0
    check pw_observation_contract(h) == 3
    check pw_seat_goal(h, 3, fp(g)) == 0 and g == Mixed   # kept across reset
    check goalVectorError(Mixed) == "" and goalVectorError(PureWin) == ""
    check goalVectorError([1'f32, 0, 0, 0, 0, 0, 0, 0.1]) != "" and goalVectorError([2'f32, 0, 0, 0, 0, 0, 0, 0]) != ""
  test "v3 rows equal v2 rows bitwise in columns 0..505 and carry the goal; v1/v2/v3 step hash for hash; goals never touch v1/v2":
    let seeds = parseInt(getEnv("PW_V3_SEEDS", "2"))
    let ticks = parseInt(getEnv("PW_V3_TICKS", "480"))
    var compared = 0
    for seed in 0..<seeds:
      let s = int32(seed + 71)
      let v1 = pw_create(s, ticks.int32)
      let v2 = pw_create_observation(s, ticks.int32, 2)
      let v2g = pw_create_observation(s, ticks.int32, 2)
      let v3 = pw_create_observation(s, ticks.int32, 3)
      require v1 != nil and v2 != nil and v2g != nil and v3 != nil
      var goals: array[Seats, GoalVector]
      for slot in 0..<Seats:
        goals[slot] = if slot mod 3 == 0: PureWin else: Mixed
        goals[slot][1] = float32(slot) / 16
        check pw_set_seat_goal(v3, slot.cint, fp(goals[slot])) == 0
        check pw_set_seat_goal(v2g, slot.cint, fp(goals[slot])) == 0   # a v2 handle never reads it
      var actions: array[Seats*ActionSizes.len, int32]
      var rewards, terminals, r1, r2, r3, r4: array[Seats, float32]
      var obs1: array[Seats*ObservationSize, float32]
      var obs2, obs2g: array[Seats*ObservationSizeV2, float32]
      var obs3: array[Seats*ObservationSizeV3, float32]
      var w = newWorld(s, ticks.int32)
      while w.winner == -1 and w.tick < w.endTick:
        require pw_observe(v1, fp(obs1), fp(r1)) == 0
        require pw_observe(v2, fp(obs2), fp(r2)) == 0
        require pw_observe(v2g, fp(obs2g), fp(r3)) == 0
        require pw_observe(v3, fp(obs3), fp(r4)) == 0
        require r1 == r2 and r2 == r3 and r3 == r4
        for slot in 0..<Seats:
          for i in 0..<ObservationSizeV2:
            require bits(obs3[slot*ObservationSizeV3+i]) == bits(obs2[slot*ObservationSizeV2+i])
            require bits(obs2g[slot*ObservationSizeV2+i]) == bits(obs2[slot*ObservationSizeV2+i])
          for i in 0..<ObservationSize:
            require bits(obs1[slot*ObservationSize+i]) == bits(obs2[slot*ObservationSizeV2+i])
          for i in 0..<GoalSize:
            require bits(obs3[slot*ObservationSizeV3+ObservationSizeV2+i]) == bits(goals[slot][i])
          inc compared
        for slot in 0..<Seats:
          let o = slot*ActionSizes.len
          actions[o] = int32(1 + (slot + w.tick.int div 40) mod 10)
          actions[o+1] = int32(17 + (w.tick.int div 9 + slot) mod 8)
          actions[o+2] = int32(w.tick mod 3 == 0)
        var commands: array[Seats, Command]
        for slot in 0..<Seats:
          let o = slot*ActionSizes.len
          commands[slot] = w.decodeActions(slot, actions.toOpenArray(o, o+ActionSizes.len-1))
        w.step(commands)
        for h in [v1, v2, v2g, v3]:
          require pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0
          require pw_state_hash(h) == w.stateHash()
      for h in [v1, v2, v2g, v3]: pw_destroy(h)
    checkpoint $compared
    check compared > 1000

suite "Hosted neural seats of a v3 bundle and the native ABI see the same observation (goal by team)":
  configureRules(NativeRules)
  proc u32(s: var string, value: uint32) =
    for i in 0..3: s.add char((value shr (8*i)) and 255)
  proc smallModel(): string =
    ## A valid v3 / contract-v2 actor with small deterministic non-zero weights, including
    ## on the goal columns, so the goal changes the logits and a wrong column would show.
    const h = 64
    const n = ObservationSizeV3*h + 3*h*h + LogitSize*h
    result = "PWNET001"
    for x in [1,ObservationSizeV3,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
    result.add ObservationContractV3Hash
    result.add ActionContractV2Hash
    for x in ActionSizes: result.u32(x.uint32)
    for i in 0..<n:
      let v = float32(((i * 2654435761) mod 2001) - 1000) / 20000'f32
      result.u32(cast[uint32](v))
  proc v3Seats(goal: string): array[Seats, Bot] =
    let path = getTempDir()/"paintbot-native-obs-v3-test.bas"
    writeFile(path, "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "paintbot_act(neuralLogits())\n")
    writeFile(path & ".model.bin", smallModel())
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      ObservationContractV3Hash & "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}, " &
      "\"decoder\": {\"sampling\": {\"mode\": \"categorical\"}}, \"goal\": " & goal & "}")
    defer:
      removeFile(path); removeFile(path & ".model.bin"); removeFile(path & ".neural.json")
    loadBots(@[BotGroup(path: path, count: Seats)])
  test "every seat's observation bitwise and every tick's world equal, goals differing by team":
    let seeds = parseInt(getEnv("PW_V3_SEEDS", "8"))
    let ticks = parseInt(getEnv("PW_V3_TICKS", "600"))
    let red: GoalVector = [1'f32, 0.25, 0.1, 0.5, -0.25, 0.1, -0.5, 0]
    let blue: GoalVector = [1'f32, 0, 0, 0, -0.1, 0.5, -0.25, 0]
    let goalJson = "{\"red\": [1, 0.25, 0.1, 0.5, -0.25, 0.1, -0.5, 0], \"blue\": [1, 0, 0, 0, -0.1, 0.5, -0.25, 0]}"
    var matches, observed = 0
    for seedIndex in 0..<seeds:
      let seed = int32(3 + seedIndex)
      let players = v3Seats(goalJson)
      for slot in 0..<Seats:
        require not players[slot].failed
        check players[slot].neural.goal == (if team(slot) == 0: red else: blue)
      let actor = loadActor(smallModel())
      var world = newWorld(seed, ticks.int32)
      let handle = pw_create_observation(seed, ticks.int32, 3)
      require handle != nil
      check pw_set_action_contract(handle, 2) == 0
      var states: array[Seats, seq[float32]]
      var logits = newSeq[float32](LogitSize)
      for slot in 0..<Seats:
        check pw_set_seat_sampling(handle, slot.cint, 1000, 0) == 0
        var g = if team(slot) == 0: red else: blue
        check pw_set_seat_goal(handle, slot.cint, fp(g)) == 0
        states[slot] = newSeq[float32](actor.hiddenSize)
      var actions: array[Seats*ActionSizes.len, int32]
      var rewards, terminals, resets: array[Seats, float32]
      var obs: array[Seats*ObservationSizeV3, float32]
      var alivePrev: array[Seats, bool]
      var steps = 0
      while world.winner == -1 and world.tick < world.endTick:
        require pw_observe(handle, fp(obs), fp(resets)) == 0
        let pre = world
        let commands = players.decide(world)
        for slot in 0..<Seats: require not players[slot].failed
        for slot in 0..<Seats:
          let o = slot*ActionSizes.len
          for head in 0..<ActionSizes.len: actions[o+head] = 0
          let alive = pre.cogs[slot].hp > 0
          # The hosted seat's recurrence resets on death and respawn (neural_host.beginTick).
          if not alive or not alivePrev[slot]:
            for i in 0..<actor.hiddenSize: states[slot][i] = 0
          alivePrev[slot] = alive
          if not alive: continue
          let seat = players[slot].neural
          for i in 0..<ObservationSizeV3:
            require bits(seat.observation[i]) == bits(obs[slot*ObservationSizeV3+i])
          inc observed
          actor.infer(obs.toOpenArray(slot*ObservationSizeV3, (slot+1)*ObservationSizeV3-1), states[slot], logits)
          require pw_sample_actions(handle, slot.cint, fp(logits), ip(actions.toOpenArray(o, o+ActionSizes.len-1))) == 0
        world.step(commands)
        require pw_step(handle, ip(actions), fp(rewards), fp(terminals)) == 0
        require pw_state_hash(handle) == world.stateHash()
        inc steps
      echo "  hosted==ABI v3 seed ", seed, " steps ", steps
      check steps > 100
      inc matches
      pw_destroy(handle)
    checkpoint $observed
    check matches == seeds and observed > 1000
