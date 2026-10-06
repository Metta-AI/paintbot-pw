## Native training ABI for observation contract ffa.view.1 (version 202) and N-seat handles:
## pw_set_seats, the per-match row width and section layout, the row -> entity map, and
## observe / step / scripts / raw commands / kin / scores / reward split / results at 16 and
## at 50 seats (the Heartland and Heartland Big configs).
import std/[unittest, os, importutils, random, strutils]
import ../examples/paintbot/[sim, kinship, neural_contract, native_env, seat_view, bots, neural_host, contract_hash]
import paintbot_pwnet2_fixture
privateAccess(NativeEnv)

const Root = currentSourcePath().parentDir.parentDir
const DecoderFfa = staticRead("../examples/paintbot/players/neural_decode_ffa.bas")
const PolicyFfa = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), " &
  "neuralLogits(), neuralState())\nneuralSample()\n" & DecoderFfa
const PointerManifest = """{"schema": "paintbot-neural-basic/1", "observation_contract": """" &
  ObservationContractFfaView1Hash & """", "action_contract": """" & ActionContractFfaView1PointerHash & """"}"""
const HeartlandConfig = """{"seed": 2026, "max_ticks": 8640, "mode": "ffa_kin", "kin_layout": "cousins"}"""
const HeartlandBigConfig = """{"seed": 2026, "max_ticks": 8640, "mode": "ffa_kin", "map": "big-twin-mesas", "kin_layout": "tribes"}"""

proc fp(buffer: var seq[float32]): ptr UncheckedArray[cfloat] =
  cast[ptr UncheckedArray[cfloat]](addr buffer[0])
proc ip(buffer: var seq[int32]): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](addr buffer[0])
proc cp(text: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr text[0])
proc envOf(h: pointer): ptr NativeEnv = cast[ptr NativeEnv](h)

proc heartland(seats: int, config: string, ticks = 240'i32, userInputs = 0'i32): pointer =
  result = if userInputs == 0: pw_create_observation(7, 0, ocFfaView1.int32)
           else: pw_create_observation_inputs_v(7, 0, ocFfaView1.int32, userInputs)
  doAssert result != nil
  doAssert pw_set_rules(result, LiveRules) == 0
  doAssert pw_set_config_json(result, cp(config), config.len.int32, nil, 0) == 0
  doAssert pw_set_seats(result, seats.int32) == 0
  doAssert pw_reset(result, 2026, ticks) == 0

proc scriptAll(h: pointer) =
  let source = readFile(Root / "coworld/heartland/players/ffa.bas")
  for seat in 0..<pw_seats(h):
    doAssert pw_set_seat_script(h, seat.cint, cp(source), source.len.int32) == 0

proc layoutOf(h: pointer): FfaViewLayout = ffaViewLayout(pw_seats(h).int, envOf(h).world.controlHearts.len)

suite "Native ffa.view.1 and N-seat handles":
  teardown:
    configureSeats(LegacySeats)

  test "version 202: per-match width, layout, hash; 16 seats unless pw_set_seats":
    var text: array[65, char]
    check pw_observation_contract_hash(202, cast[ptr UncheckedArray[char]](addr text[0]), 65) == 0
    check $cast[cstring](addr text[0]) == ObservationContractFfaView1Hash
    check pw_observation_size_for(202) == -1
    let h = heartland(16, HeartlandConfig)
    check pw_observation_contract(h) == 202 and pw_seats(h) == 16
    let l = h.layoutOf
    check l.cogRows == 15 # min(seats - 1, 64)
    check pw_handle_observation_size(h) == l.size
    var layout = newSeq[int32](ObservationLayoutWords)
    check pw_observation_layout(h, ip(layout)) == 0
    check layout == @[l.size.int32, 24, 24, 15, 44, l.heartOffset.int32, l.heartRows.int32, 12,
      l.greatOffset.int32, 2, 12, 0, 16, l.heartRows.int32, 0, 0]
    pw_destroy(h)
    # teams.view.1: no sections, 16 seats only.
    let v1 = pw_create_observation(7, 24, ocTeamsView1.int32)
    check pw_observation_layout(v1, ip(layout)) == 0
    check layout[0] == 512 and layout[1] == 512 and layout[2] == 0 and layout[11] == -1 and layout[12] == 16
    check pw_set_seats(v1, 50) == -1 and pw_set_seats(v1, 16) == 0
    var rows = newSeq[int32](64)
    check pw_observation_rows(v1, 0, ip(rows), 64) == -1
    pw_destroy(v1)
    check pw_create_observation(7, 24, 101) == nil and pw_create_observation(7, 24, 102) == nil # retired
    let bad = pw_create_observation(7, 24, ocFfaView1.int32)
    check pw_set_seats(bad, 1) == -1 and pw_set_seats(bad, 257) == -1 and pw_set_seats(nil, 16) == -1
    check pw_set_seats(bad, 256) == 0 and pw_set_seats(bad, 2) == 0
    pw_destroy(bad)

  test "cog rows are min(seats - 1, 64): 64 at 100 seats":
    let h = heartland(100, HeartlandBigConfig, 24)
    check h.layoutOf.cogRows == 64
    var layout = newSeq[int32](ObservationLayoutWords)
    check pw_observation_layout(h, ip(layout)) == 0
    check layout[3] == 64 and layout[12] == 100 and layout[0] == h.layoutOf.size.int32
    var heads = newSeq[int32](8)
    check pw_action_layout(h, ip(heads)) == 0
    check heads[2] == 9 + 64
    pw_destroy(h)

  for (seats, config) in [(16, HeartlandConfig), (50, HeartlandBigConfig)]:
    test "observe at " & $seats & " seats equals the reference encoder; rows map the sections":
      let h = heartland(seats, config)
      let env = envOf(h)
      check pw_seats(h) == seats and env.world.cogs.len == seats
      if seats == 50:
        check env.world.controlHearts.len == 100 and env.kinship.layout == klTribes
      let n = pw_handle_observation_size(h).int
      let l = h.layoutOf
      check n == l.size and l.cogRows == min(seats - 1, 64)
      var obs = newSeq[float32](seats*n)
      var resets = newSeq[float32](seats)
      var rows = newSeq[int32](l.cogRows + l.heartRows + 2)
      check pw_observation_rows(h, 0, nil, 0) == rows.len
      var seen = 0
      var actions = newSeq[int32](seats*ActionSizes.len)
      var rewards = newSeq[float32](seats)
      var terminals = newSeq[float32](seats)
      h.scriptAll()
      for tick in 0..<2:
        check pw_observe(h, fp(obs), fp(resets)) == 0
        for slot in 0..<seats:
          check resets[slot] == float32(tick == 0)
          check pw_observation_rows(h, slot.cint, ip(rows), rows.len.int32) == rows.len
          beginViews(env.world)
          let view = seatView(slot)
          var expected = newSeq[float32](n)
          encodeFfaView(view, expected, ffaViewRows(view))
          check obs[slot*n ..< (slot+1)*n] == expected
          # The cog rows are nearAgents(20000)'s identities in its order, then -1.
          let near = view.agentsNear(NearMaxRadius)
          check near.len <= l.cogRows
          for k in 0..<l.cogRows:
            let o = slot*n + l.cogOffset + k*FfaCogWidth
            if k < near.len:
              check rows[k] == near[k].identity and obs[o] == 1
              check obs[o + 43] == float32(rows[k])/255
              inc seen
            else:
              check rows[k] == -1 and obs[o] == 0
          for k in 0..<l.heartRows: check rows[l.cogRows+k] in 0'i32..<l.heartRows.int32
          for k in 0..<2: check rows[l.cogRows+l.heartRows+k] in 0'i32..1'i32
        check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0
      check seen > 0
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

  test "raw commands step a 50-seat world; seat 50 is out of range":
    let h = heartland(50, HeartlandBigConfig)
    var actions = newSeq[int32](50*ActionSizes.len)
    var rewards = newSeq[float32](50)
    var terminals = newSeq[float32](50)
    let source = readFile(Root / "coworld/heartland/players/ffa.bas")
    for seat in 0..<49:
      check pw_set_seat_script(h, seat.cint, cp(source), source.len.int32) == 0
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
    check pw_set_seat_command(h, 50, ip(nine)) == -1
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
    let v1 = pw_create_observation(7, 24, ocTeamsView1.int32)
    var c = newSeq[float32](16*512)
    check pw_observe(v1, fp(c), fp(rb)) == 0
    check Seats == 16
    pw_destroy(v1)
    pw_destroy(small)
    pw_destroy(big)

  test "action contract ffa.view.1 pointer: 50 seats step on the caller's heads, decoded by neural_decode_ffa.bas":
    let h = heartland(50, HeartlandBigConfig, 240)
    check pw_action_contract(h) == acFfaView1Pointer.cint
    var layout = newSeq[int32](8)
    check pw_action_layout(h, ip(layout)) == 0
    let l = h.layoutOf
    check layout == @[5'i32, int32(11 + l.heartRows), int32(9 + 49), 2, 2, 2,
      int32(11 + l.heartRows + 9 + 49 + 6), 0]
    check pointerHeads(l) == @[11 + l.heartRows, 9 + 49, 2, 2, 2]
    var text: array[65, char]
    check pw_action_contract_hash(12, cast[ptr UncheckedArray[char]](addr text[0]), 65) == 0
    check $cast[cstring](addr text[0]) == ActionContractFfaView1PointerHash
    check pw_action_contract_hash(3, cast[ptr UncheckedArray[char]](addr text[0]), 65) == -1 # ffa.v2 retired
    check pw_set_action_contract(h, acTeamsView1.int32) == -1 and pw_set_action_contract(h, acFfaView1Pointer.int32) == 0
    let v1 = pw_create_observation(7, 24, ocTeamsView1.int32)
    check pw_action_contract(v1) == acTeamsView1.cint
    check pw_set_action_contract(v1, acFfaView1Pointer.int32) == -1
    pw_destroy(v1)
    var obs = newSeq[float32](50*pw_handle_observation_size(h))
    var resets = newSeq[float32](50)
    var actions = newSeq[int32](50*ActionSizes.len)
    var rewards = newSeq[float32](50)
    var terminals = newSeq[float32](50)
    var r = initRand(5)
    # The reference: the same choices as one-hot logits to hosted-style policy seats running
    # neuralSample + the reference decode, stepping a copy of the world.
    check pw_observe(h, fp(obs), fp(resets)) == 0 # installs the handle's rules, seats and kinship
    var reference = envOf(h).world
    var policies = newSeq[Bot](50)
    for slot in 0..<50: policies[slot] = loadPolicyBot(PolicyFfa, PointerManifest, slot, ObservationContractFfaView1Hash)
    let width = layout[6].int
    var aimed, sampled = 0
    for tick in 0..<24:
      check pw_observe(h, fp(obs), fp(resets)) == 0
      for slot in 0..<50:
        let o = slot*ActionSizes.len
        actions[o] = int32(r.rand(layout[1]-1))
        actions[o+1] = int32(r.rand(layout[2]-1))
        actions[o+2] = int32(r.rand(1))
        actions[o+3] = 0
        actions[o+4] = int32(r.rand(1))
        if actions[o+1] >= PointerAimFirstRow: inc aimed
        let bot = policies[slot]
        for i in 0..<width: bot.neural.fedLogits[i] = 0
        var offset = 0
        for head in 0..<5:
          bot.neural.fedLogits[offset + actions[o+head].int] = 1
          offset += layout[1+head].int
        bot.neural.logitsFed = true
      let commands = decide(policies, reference)
      check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0
      reference.step(commands)
      check pw_state_hash(h) == reference.stateHash()
      for slot in 0..<50:
        if policies[slot].neural.sampled: inc sampled
        if policies[slot].neural.sampled: check @(policies[slot].neural.choices) == actions[slot*5 ..< slot*5+5]
    check aimed > 0 and sampled > 0
    actions[0] = int32(layout[1])
    check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == -1
    pw_destroy(h)

  test "one layout-word model.bin loads at 16 and 50 seats; a pointer policy seat steps on its logits":
    var r = initRand(6)
    let model = r.pointerModel()
    for (seats, config) in [(16, HeartlandConfig), (50, HeartlandBigConfig)]:
      let h = heartland(seats, config, 120)
      var message = newString(256)
      let teams = pw_create_observation(7, 24, ocTeamsView1.int32)
      check pw_net_load_layout(teams, unsafeAddr model[0], model.len.int64,
        cast[ptr UncheckedArray[char]](addr message[0]), 256) == nil   # not an ffa.view.1 handle
      pw_destroy(teams)
      let net = pw_net_load_layout(h, unsafeAddr model[0], model.len.int64,
        cast[ptr UncheckedArray[char]](addr message[0]), 256)
      require net != nil
      let n = pw_handle_observation_size(h).int
      var layout = newSeq[int32](8)
      check pw_action_layout(h, ip(layout)) == 0
      let width = layout[6].int
      # Seat 0 is a policy seat on the bundle's manifest; every other seat runs ffa.bas.
      check pw_set_seat_policy_script(h, 0, cp(PolicyFfa), PolicyFfa.len.int32, cp(PointerManifest),
        PointerManifest.len.int32) == 0
      let source = readFile(Root / "coworld/heartland/players/ffa.bas")
      for seat in 1..<seats: check pw_set_seat_script(h, seat.cint, cp(source), source.len.int32) == 0
      var obs = newSeq[float32](seats*n)
      var resets = newSeq[float32](seats)
      var actions = newSeq[int32](seats*ActionSizes.len)
      var logits = newSeq[float32](seats*width)
      var rewards = newSeq[float32](seats)
      var terminals = newSeq[float32](seats)
      var steps = 0
      var decided = 0
      while true:
        check pw_observe(h, fp(obs), fp(resets)) == 0
        check pw_net_infer(net, cast[ptr UncheckedArray[float32]](addr obs[0]), nil,
          cast[ptr UncheckedArray[float32]](addr logits[0])) == 0
        let code = pw_step_logits(h, ip(actions), fp(logits), fp(rewards), fp(terminals))
        if code == -2: break
        check code == 0
        if code != 0: break
        inc steps
        var choices = newSeq[int32](22)
        check pw_seat_policy_choices(h, 0, ip(choices)) == 0
        if choices[0] == 1:
          inc decided
          # The selection is the argmax of the seat's logits, head by head.
          var offset = 0
          for head in 0..<5:
            var best = 0
            for i in 0..<layout[1+head].int:
              if logits[offset+i] > logits[offset+best]: best = i
            check choices[1+head] == best.int32 and choices[6+head] == best.int32
            offset += layout[1+head].int
      check steps == 120 and decided > 0
      check pw_seat_script_status(h, 0, nil, 0) == 1
      pw_net_destroy(net)
      pw_destroy(h)

  test "ffa.view.1u<K> (202 + K): handles, hashes, widths, layout words; rows are ffa.view.1's bytes + the policy seat's inputs":
    var text: array[65, char]
    template hashV(v, k: int32): cint = pw_user_inputs_contract_hash_v(v, k, cast[ptr UncheckedArray[char]](addr text[0]), 65)
    for k in [1'i32, 5, 64, 128, 256]:
      check hashV(202, k) == 0 and $cast[cstring](addr text[0]) == userInputsContractHash(k.int, ocFfaView1)
      check $cast[cstring](addr text[0]) == sha256Hex("paintbot-pw.ffa.view.1u" & $k)
      check hashV(201, k) == 0 and $cast[cstring](addr text[0]) == userInputsContractHash(k.int)
    for (v, k) in [(202'i32, 0'i32), (202'i32, 257'i32), (208'i32, 5'i32)]: check hashV(v, k) == -1
    check pw_user_inputs_contract_hash_v(202, 5, cast[ptr UncheckedArray[char]](addr text[0]), 64) == -1
    for (v, k) in [(202'i32, -1'i32), (202'i32, 257'i32), (208'i32, 5'i32)]:
      check pw_create_observation_inputs_v(7, 0, v, k) == nil
    check pw_create_observation_inputs_v(7, HeartMeterMatchTicks+1, 202, 5) == nil
    # K = 0 is a plain 202 handle.
    let zero = pw_create_observation_inputs_v(7, 0, 202, 0)
    check pw_observation_contract(zero) == 202 and pw_handle_user_inputs(zero) == 0
    pw_destroy(zero)
    for (seats, config) in [(16, HeartlandConfig), (50, HeartlandBigConfig)]:
      for k in [1'i32, 5, 16, 256]:
        let h = heartland(seats, config, 24, k)
        let b = heartland(seats, config, 24)
        check pw_observation_contract(h) == 202 and pw_handle_user_inputs(h) == k and pw_seats(h) == seats.int32
        let l = h.layoutOf
        check pw_handle_observation_size(h) == l.size + k and pw_handle_observation_size(b) == l.size
        var words, baseWords = newSeq[int32](ObservationLayoutWords)
        check pw_observation_layout(h, ip(words)) == 0 and pw_observation_layout(b, ip(baseWords)) == 0
        check words[0] == int32(l.size) + k and words[1 .. ^1] == baseWords[1 .. ^1]
        var actions = newSeq[int32](8)
        var baseActions = newSeq[int32](8)
        check pw_action_layout(h, ip(actions)) == 0 and pw_action_layout(b, ip(baseActions)) == 0
        check actions == baseActions
        pw_destroy(h); pw_destroy(b)

  test "ffa.view.1u5 and u16 in lockstep with ffa.view.1: same worlds, same row bytes, the policy seat's inputs one tick later":
    for K in [5, 16]:
      let contract = userInputsContractHash(K, ocFfaView1)
      var init: seq[int32]
      for j in 0..<K: init.add int32((j + 1) * (if j mod 2 == 0: 37 else: -37))
      let manifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": """" & contract &
        """", "action_contract": """" & ActionContractFfaView1PointerHash &
        """", "user_inputs": {"count": """ & $K & """, "init": [""" & init.join(", ") & """]}}"""
      let writes = "neuralInput(0, worldTick)\nneuralInput(1, selfX)\nneuralInput(2, 0 - selfY)\n" &
        "neuralInput(3, 2000000)\n"
      let policyU = writes & PolicyFfa
      var r = initRand(17)
      let model = r.pointerModel(contract)
      for (seats, config) in [(16, HeartlandConfig), (50, HeartlandBigConfig)]:
        let h = heartland(seats, config, 120, K.int32)
        let b = heartland(seats, config, 120)
        # The mismatched manifests are rejected (2): the handle's contract governs.
        check pw_set_seat_policy_script(h, 0, cp(PolicyFfa), PolicyFfa.len.int32, cp(PointerManifest),
          PointerManifest.len.int32) == 2
        check pw_set_seat_policy_script(b, 0, cp(policyU), policyU.len.int32, cp(manifest), manifest.len.int32) == 2
        check pw_set_seat_policy_script(h, 0, cp(policyU), policyU.len.int32, cp(manifest), manifest.len.int32) == 0
        check pw_set_seat_policy_script(b, 0, cp(PolicyFfa), PolicyFfa.len.int32, cp(PointerManifest),
          PointerManifest.len.int32) == 0
        let source = readFile(Root / "coworld/heartland/players/ffa.bas")
        for seat in 1..<seats:
          check pw_set_seat_script(h, seat.cint, cp(source), source.len.int32) == 0
          check pw_set_seat_script(b, seat.cint, cp(source), source.len.int32) == 0
        let l = h.layoutOf
        let n = pw_handle_observation_size(h).int
        let nb = pw_handle_observation_size(b).int
        check n == l.size + K and nb == l.size
        # A layout-word model loads on the handle with the input count + K and infers on its rows.
        var message = newString(256)
        let net = pw_net_load_layout(h, unsafeAddr model[0], model.len.int64,
          cast[ptr UncheckedArray[char]](addr message[0]), 256)
        require net != nil
        var layout = newSeq[int32](8)
        check pw_action_layout(h, ip(layout)) == 0
        let width = layout[6].int
        var obs = newSeq[float32](seats*n)
        var baseObs = newSeq[float32](seats*nb)
        var resets = newSeq[float32](seats)
        var actions = newSeq[int32](seats*ActionSizes.len)
        var logits = newSeq[float32](seats*width)
        var rewards = newSeq[float32](seats)
        var terminals = newSeq[float32](seats)
        var previous = init
        var steps, fresh = 0
        while true:
          check pw_observe(h, fp(obs), fp(resets)) == 0
          check pw_observe(b, fp(baseObs), fp(resets)) == 0
          for s in 0..<seats:
            for i in 0..<l.size: require cast[uint32](obs[s*n+i]) == cast[uint32](baseObs[s*nb+i])
            for j in 0..<K:
              let want = if s == 0: userInputFeature(previous[j]) else: 0'f32
              require obs[s*n+l.size+j] == want
          check pw_net_infer(net, cast[ptr UncheckedArray[float32]](addr obs[0]), nil,
            cast[ptr UncheckedArray[float32]](addr logits[0])) == 0
          let code = pw_step_logits(h, ip(actions), fp(logits), fp(rewards), fp(terminals))
          check pw_step_logits(b, ip(actions), fp(logits), fp(rewards), fp(terminals)) == code
          if code != 0: break
          inc steps
          check pw_state_hash(h) == pw_state_hash(b)
          let seat = h.envOf.scriptBots[0].neural
          if seat.userInputs[0] == int32(steps - 1): inc fresh
          previous = seat.userInputs
          check previous[3] == UserInputLimit
        check steps == 120 and fresh > 10
        check pw_seat_script_status(h, 0, nil, 0) == 1 and pw_seat_script_status(b, 0, nil, 0) == 1
        pw_net_destroy(net)
        pw_destroy(h); pw_destroy(b)
