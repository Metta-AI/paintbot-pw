## Native training ABI for observation contract ffa.v2 (version 102) and N-seat handles:
## pw_set_seats, the per-match row width and section layout, the row -> entity map, and
## observe / step / scripts / raw commands / kin / scores / reward split / results at 16 and
## at 50 seats (the Heartland and Heartland Big configs).
import std/[unittest, os, importutils, random]
import ../examples/paintbot/[sim, kinship, neural_contract, native_env]
import paintbot_pwnet2_fixture
privateAccess(NativeEnv)

const Root = currentSourcePath().parentDir.parentDir
const HeartlandConfig = """{"seed": 2026, "max_ticks": 8640, "mode": "ffa_kin", "kin_layout": "cousins"}"""
const HeartlandBigConfig = """{"seed": 2026, "max_ticks": 8640, "mode": "ffa_kin", "map": "big-twin-mesas", "kin_layout": "tribes"}"""

proc fp(buffer: var seq[float32]): ptr UncheckedArray[cfloat] =
  cast[ptr UncheckedArray[cfloat]](addr buffer[0])
proc ip(buffer: var seq[int32]): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](addr buffer[0])
proc cp(text: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr text[0])
proc envOf(h: pointer): ptr NativeEnv = cast[ptr NativeEnv](h)

proc heartland(seats: int, config: string, ticks = 240'i32): pointer =
  result = pw_create_observation(7, 0, 102)
  doAssert result != nil
  doAssert pw_set_rules(result, LiveRules) == 0
  doAssert pw_set_config_json(result, cp(config), config.len.int32, nil, 0) == 0
  doAssert pw_set_seats(result, seats.int32) == 0
  doAssert pw_reset(result, 2026, ticks) == 0

proc scriptAll(h: pointer) =
  let source = readFile(Root / "coworld/heartland/players/ffa.bas")
  for seat in 0..<pw_seats(h):
    doAssert pw_set_seat_script(h, seat.cint, cp(source), source.len.int32) == 0

suite "Native ffa.v2 and N-seat handles":
  teardown:
    configureSeats(LegacySeats)

  test "version 102: per-match width, layout, hash; 16 seats unless pw_set_seats":
    var text: array[65, char]
    check pw_observation_contract_hash(102, cast[ptr UncheckedArray[char]](addr text[0]), 65) == 0
    check $cast[cstring](addr text[0]) == ObservationContractFfaV2Hash
    check pw_observation_size_for(102) == -1
    let h = heartland(16, HeartlandConfig)
    check pw_observation_contract(h) == 102 and pw_seats(h) == 16
    let l = ffaV2Layout(envOf(h).world)
    check pw_handle_observation_size(h) == l.size
    var layout = newSeq[int32](ObservationLayoutWords)
    check pw_observation_layout(h, ip(layout)) == 0
    check layout == @[l.size.int32, 24, 24, 15, 44, l.heartOffset.int32, l.heartRows.int32, 12,
      l.greatOffset.int32, 2, 12, 0, 16, l.heartRows.int32, 0, 0]
    pw_destroy(h)
    # Other contracts: no sections, 16 seats only.
    let v1 = pw_create_observation(7, 24, 1)
    check pw_observation_layout(v1, ip(layout)) == 0
    check layout[0] == 448 and layout[1] == 448 and layout[2] == 0 and layout[11] == -1 and layout[12] == 16
    check pw_set_seats(v1, 50) == -1 and pw_set_seats(v1, 16) == 0
    var rows = newSeq[int32](64)
    check pw_observation_rows(v1, 0, ip(rows), 64) == -1
    pw_destroy(v1)
    let f1 = pw_create_observation(7, 24, 101)
    check pw_set_seats(f1, 50) == -1
    pw_destroy(f1)
    let bad = pw_create_observation(7, 24, 102)
    check pw_set_seats(bad, 1) == -1 and pw_set_seats(bad, 257) == -1 and pw_set_seats(nil, 16) == -1
    check pw_set_seats(bad, 256) == 0 and pw_set_seats(bad, 2) == 0
    pw_destroy(bad)

  for (seats, config) in [(16, HeartlandConfig), (50, HeartlandBigConfig)]:
    test "observe at " & $seats & " seats equals the reference encoder; rows map the sections":
      let h = heartland(seats, config)
      let env = envOf(h)
      check pw_seats(h) == seats and env.world.cogs.len == seats
      if seats == 50:
        check env.world.controlHearts.len == 100 and env.kinship.layout == klTribes
      let n = pw_handle_observation_size(h).int
      let l = ffaV2Layout(env.world)
      check n == l.size
      var obs = newSeq[float32](seats*n)
      var resets = newSeq[float32](seats)
      check pw_observe(h, fp(obs), fp(resets)) == 0
      var expected = newSeq[float32](n)
      var rows = newSeq[int32](l.cogRows + l.heartRows + 2)
      check pw_observation_rows(h, 0, nil, 0) == rows.len
      for slot in 0..<seats:
        check resets[slot] == 1
        encodeFfaV2Observation(env.world, slot, expected, env.world.ffaV2Rows(slot), env.kinship)
        check obs[slot*n ..< (slot+1)*n] == expected
        check pw_observation_rows(h, slot.cint, ip(rows), rows.len.int32) == rows.len
        for k in 0..<l.cogRows:
          if rows[k] < 0: check obs[slot*n + l.cogOffset + k*FfaV2CogWidth] == 0
          else: check obs[slot*n + l.cogOffset + k*FfaV2CogWidth + 43] == float32(rows[k])/255
        for k in 0..<l.heartRows: check rows[l.cogRows+k] in 0'i32..<l.heartRows.int32
      pw_destroy(h)

    test "a scripted " & $seats & "-seat match plays to the end; kin, scores, split and results cover every seat":
      let h = heartland(seats, config, 240)
      h.scriptAll()
      let n = pw_handle_observation_size(h).int
      var obs = newSeq[float32](seats*n)
      var resets = newSeq[float32](seats)
      var actions = newSeq[int32](seats*ActionSizes.len)
      var rewards = newSeq[float32](seats)
      var terminals = newSeq[float32](seats)
      var total = newSeq[float64](seats)
      var steps = 0
      while true:
        check pw_observe(h, fp(obs), fp(resets)) == 0
        let code = pw_step(h, ip(actions), fp(rewards), fp(terminals))
        if code == -2: break
        check code == 0
        if code != 0: break
        inc steps
        for i in 0..<seats: total[i] += rewards[i]
      check steps == 240 and terminals[0] == 1
      var status = newSeq[char](256)
      for seat in 0..<seats:
        check pw_seat_script_status(h, seat.cint, cast[ptr UncheckedArray[char]](addr status[0]), 256) == 1
      var kin = newSeq[float32](seats*seats)
      check pw_kin(h, fp(kin)) == 0
      for i in 0..<seats:
        check kin[i*seats+i] == 1
        for j in 0..<seats: check kin[i*seats+j] == float32(envOf(h).kinship.r(i, j))
      var scores = newSeq[float32](seats)
      check pw_scores(h, fp(scores)) == 0
      var split = newSeq[float32](2*seats)
      check pw_reward_split(h, fp(split)) == 0
      for i in 0..<seats:
        # The dense reward sums to R_i / 4320 over the match.
        check abs(total[i] - scores[i].float64 / 4320.0) < 1e-3
      var results = newSeq[float32](8)
      check pw_results(h, fp(results)) == 0
      check results[0] == 240 and results[2] >= 0 and results[2] <= seats.float32
      var genes = newSeq[uint32](seats)
      check pw_genes(h, cast[ptr UncheckedArray[uint32]](addr genes[0])) == 0
      var stats = newSeq[int32](seats*8)
      check pw_seat_stats(h, ip(stats)) == 0
      pw_destroy(h)

  test "over 16 seats every seat needs a script or a raw command (-5), and raw commands step":
    let h = heartland(50, HeartlandBigConfig)
    var actions = newSeq[int32](50*ActionSizes.len)
    var rewards = newSeq[float32](50)
    var terminals = newSeq[float32](50)
    check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == -5
    let source = readFile(Root / "coworld/heartland/players/ffa.bas")
    for seat in 0..<49:
      check pw_set_seat_script(h, seat.cint, cp(source), source.len.int32) == 0
    check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == -5
    let before = envOf(h).world.cogs[49].pos
    let goal = Point(x: before.x + 500, z: before.z)
    var nine = @[1'i32, goal.x, goal.z, 0, 0, 0, 0, 0, 0]
    check pw_set_seat_command(h, 49, ip(nine)) == 0
    check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0
    check envOf(h).world.cogs[49].pos.x > before.x
    var orders = newSeq[int32](10)
    check pw_seat_orders(h, 49, ip(orders)) == 0
    check orders[0] == 1 and orders[1] == goal.x
    check pw_set_seat_script(h, 50, cp(source), source.len.int32) == -1
    check pw_action_candidates(h, 0, 0, 0, ip(actions), ip(actions)) == -1
    pw_destroy(h)

  test "a reset that changes the seat count re-creates the per-seat settings; one that keeps it keeps them":
    let h = heartland(16, HeartlandConfig)
    let source = readFile(Root / "coworld/heartland/players/ffa.bas")
    check pw_set_seat_script(h, 3, cp(source), source.len.int32) == 0
    check pw_set_seat_fire_period(h, 3, 4) == 0
    check pw_reset(h, 2027, 120) == 0
    check pw_seat_script_status(h, 3, nil, 0) == 1 and envOf(h).firePeriod[3] == 4
    check pw_set_seats(h, 50) == 0
    check pw_seats(h) == 16            # applied at the next reset
    check pw_reset(h, 2027, 120) == 0
    check pw_seats(h) == 50 and envOf(h).world.cogs.len == 50
    check pw_seat_script_status(h, 3, nil, 0) == 0 and envOf(h).firePeriod[3] == 1
    check envOf(h).resets.len == 50
    var pairs = newSeq[int32](50*50*PairStatCount)
    check pw_pair_stats(h, ip(pairs)) == 0
    check pw_set_seats(h, 16) == 0
    check pw_reset(h, 2027, 120) == 0
    check pw_seats(h) == 16 and envOf(h).world.cogs.len == 16
    pw_destroy(h)

  test "handles on one thread keep their own seat counts":
    let big = heartland(50, HeartlandBigConfig)
    let small = heartland(16, HeartlandConfig)
    var a = newSeq[float32](50*pw_handle_observation_size(big))
    var b = newSeq[float32](16*pw_handle_observation_size(small))
    var ra = newSeq[float32](50)
    var rb = newSeq[float32](16)
    check pw_observe(big, fp(a), fp(ra)) == 0
    check pw_observe(small, fp(b), fp(rb)) == 0
    check pw_observe(big, fp(a), fp(ra)) == 0
    check Seats == 50
    let v1 = pw_create_observation(7, 24, 1)
    var c = newSeq[float32](16*448)
    check pw_observe(v1, fp(c), fp(rb)) == 0
    check Seats == 16
    pw_destroy(v1)
    pw_destroy(small)
    pw_destroy(big)

  test "action contract ffa.v2 pointer: 50 seats step on the caller's heads, decoded through the rows":
    let h = heartland(50, HeartlandBigConfig, 240)
    check pw_set_action_contract(h, 3) == 0 and pw_action_contract(h) == 3
    var layout = newSeq[int32](8)
    check pw_action_layout(h, ip(layout)) == 0
    let l = ffaV2Layout(envOf(h).world)
    check layout == @[5'i32, int32(11 + l.heartRows), int32(8 + 50), 2, 2, 2,
      int32(11 + l.heartRows + 8 + 50 + 6), 0]
    var text: array[65, char]
    check pw_action_contract_hash(3, cast[ptr UncheckedArray[char]](addr text[0]), 65) == 0
    check $cast[cstring](addr text[0]) == ActionContractFfaV2PointerHash
    let v1 = pw_create_observation(7, 24, 1)
    check pw_set_action_contract(v1, 3) == -1
    pw_destroy(v1)
    var obs = newSeq[float32](50*pw_handle_observation_size(h))
    var resets = newSeq[float32](50)
    var actions = newSeq[int32](50*ActionSizes.len)
    var rewards = newSeq[float32](50)
    var terminals = newSeq[float32](50)
    var r = initRand(5)
    var memories = newSeq[PointerMemory](50)
    for m in memories.mitems: m.resetPointerMemory(50)
    for tick in 0..<24:
      check pw_observe(h, fp(obs), fp(resets)) == 0
      var reference = envOf(h).world
      var commands = newSeq[Command](50)
      for slot in 0..<50:
        let o = slot*ActionSizes.len
        actions[o] = int32(r.rand(layout[1]-1))
        actions[o+1] = int32(r.rand(layout[2]-1))
        actions[o+2] = int32(r.rand(1))
        actions[o+3] = 0
        actions[o+4] = int32(r.rand(1))
        let rows = reference.ffaV2Rows(slot)
        if reference.cogs[slot].hp <= 0: memories[slot].resetPointerMemory(50)
        commands[slot] = decodePointerActions(reference, slot, actions.toOpenArray(o, o+4), rows, memories[slot])
        memories[slot].recordPointerMemory(reference, rows)
      check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0
      reference.step(commands)
      check pw_state_hash(h) == reference.stateHash()
    actions[0] = int32(layout[1])
    check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == -1
    pw_destroy(h)

  test "one layout-word model.bin loads at 16 and 50 seats; a pointer policy seat steps on its logits":
    var r = initRand(6)
    let model = r.pointerModel()
    for (seats, config) in [(16, HeartlandConfig), (50, HeartlandBigConfig)]:
      let h = heartland(seats, config, 120)
      var message = newString(256)
      check pw_net_load_layout(h, unsafeAddr model[0], model.len.int64,
        cast[ptr UncheckedArray[char]](addr message[0]), 256) == nil   # contract 1: no pointer target
      check pw_set_action_contract(h, 3) == 0
      let net = pw_net_load_layout(h, unsafeAddr model[0], model.len.int64,
        cast[ptr UncheckedArray[char]](addr message[0]), 256)
      require net != nil
      let n = pw_handle_observation_size(h).int
      var layout = newSeq[int32](8)
      check pw_action_layout(h, ip(layout)) == 0
      let width = layout[6].int
      # Seat 0 is a policy seat on the bundle's manifest; every other seat runs ffa.bas.
      let manifest = """{"schema": "paintbot-neural-basic/1", "observation_contract": """" &
        ObservationContractFfaV2Hash & """", "action_contract": """" & ActionContractFfaV2PointerHash & """"}"""
      let script = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\npaintbot_act(neuralLogits())\n"
      check pw_set_seat_policy_script(h, 0, cp(script), script.len.int32, cp(manifest), manifest.len.int32) == 0
      let source = readFile(Root / "coworld/heartland/players/ffa.bas")
      for seat in 1..<seats: check pw_set_seat_script(h, seat.cint, cp(source), source.len.int32) == 0
      var obs = newSeq[float32](seats*n)
      var resets = newSeq[float32](seats)
      var actions = newSeq[int32](seats*ActionSizes.len)
      var logits = newSeq[float32](seats*width)
      var rewards = newSeq[float32](seats)
      var terminals = newSeq[float32](seats)
      var state = newSeq[float32](0)
      var steps = 0
      while true:
        check pw_observe(h, fp(obs), fp(resets)) == 0
        check pw_net_infer(net, cast[ptr UncheckedArray[float32]](addr obs[0]), nil,
          cast[ptr UncheckedArray[float32]](addr logits[0])) == 0
        let code = pw_step_logits(h, ip(actions), fp(logits), fp(rewards), fp(terminals))
        if code == -2: break
        check code == 0
        if code != 0: break
        inc steps
      check steps == 120
      check pw_seat_script_status(h, 0, nil, 0) == 1
      var choices = newSeq[int32](22)
      check pw_seat_policy_choices(h, 0, ip(choices)) == 0
      pw_net_destroy(net)
      pw_destroy(h)
