## Real reference-engine replay parity, not an ABI self-consistency check. The reference is
## the engine driven by the reference decoder script (players/neural_decode.bas) through each
## seat's SeatView, exactly as pw_step decodes a caller-driven seat's heads.
import std/[unittest, os, strutils]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots, training_labels, contract_hash]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const
  Root = currentSourcePath().parentDir.parentDir
  Base = Root / "coworld/paintbot/players/base.bas"
  DecoderSource = staticRead("../examples/paintbot/players/neural_decode.bas")
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] =
  (if s.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr s[0]) else: nil)

proc decoderSeats(contract = acTeamsView1): seq[Bot] =
  ## One reference decoder seat per slot, as pw_step builds them for a new match.
  for slot in 0..<Seats: result.add loadDecoderBot(DecoderSource, slot, ObservationContractTeamsView1Hash, contract)

proc decoded(seats: seq[Bot], w: World, actions: openArray[int32], heads = ActionSizes.len): seq[Command] =
  ## The commands the reference decoder script issues for every seat's heads on `w` (`heads`
  ## per seat: 5, or 7 under the aim-offset contract).
  for slot in 0..<Seats:
    for head in 0..<heads:
      let choice = actions[slot*heads+head]
      if head < ActionSizes.len: seats[slot].neural.fedChoices[head] = choice
      else: seats[slot].neural.fedOffsetChoices[head-ActionSizes.len] = choice
    seats[slot].neural.choicesFed = true
  decideSeats(seats, w)

proc hashText(f: proc(output: ptr UncheckedArray[char]): cint): (cint, string) =
  var text: array[65, char]
  let code = f(cast[ptr UncheckedArray[char]](addr text[0]))
  (code, (if code == 0: $cast[cstring](addr text[0]) else: ""))

proc setConfig(handle: pointer, json: string): (cint, string) =
  var message: array[256, char]
  let code = pw_set_config_json(handle, cbuf(json), json.len.int32,
    cast[ptr UncheckedArray[char]](addr message[0]), 256)
  (code, $cast[cstring](addr message[0]))

suite "Native training environment":
  test "versioned dimensions and invalid allocation":
    check pw_env_version() == 1
    check pw_observation_size() == TeamsViewSize
    check pw_action_count() == ActionSizes.len
    check pw_create(0,HeartMeterMatchTicks+1) == nil
    check pw_reset(nil,0,0) == -1

  test "contract selection: teams.view.1 (201) and ffa.view.1 (202); the retired versions are refused":
    check pw_observation_size_for(201) == TeamsViewSize
    for version in [0'i32, 1, 2, 3, 101, 102, 202, 203]: check pw_observation_size_for(version) == -1
    for version in [0'i32, 1, 2, 3, 101, 102, 203]: check pw_create_observation(1, 24, version) == nil
    check pw_create_observation(1, HeartMeterMatchTicks+1, 201) == nil
    check pw_observation_contract(nil) == -1 and pw_handle_observation_size(nil) == -1
    check pw_action_contract(nil) == -1
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_observation_contract_hash(201, o, 65)) ==
      (0.cint, ObservationContractTeamsView1Hash)
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_observation_contract_hash(202, o, 65)) ==
      (0.cint, ObservationContractFfaView1Hash)
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_observation_contract_hash(201, o, 64))[0] == -1
    for version in [1'i32, 2, 3, 101, 102]:
      check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_observation_contract_hash(version, o, 65))[0] == -1
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_action_contract_hash(11, o, 65)) ==
      (0.cint, ActionContractTeamsView1Hash)
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_action_contract_hash(12, o, 65)) ==
      (0.cint, ActionContractFfaView1PointerHash)
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_action_contract_hash(11, o, 64))[0] == -1
    for version in [0'i32, 1, 2, 3]:
      check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_action_contract_hash(version, o, 65))[0] == -1
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_action_contract_hash(13, o, 65)) ==
      (0.cint, ActionContractTeamsView1OffsetHash)
    check ActionContractTeamsView1OffsetHash == sha256Hex("paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23")
    let plain = pw_create(5, 24)
    let teams = pw_create_observation(5, 24, 201)
    let ffa = pw_create_observation(5, 24, 202)
    require plain != nil and teams != nil and ffa != nil
    for h in [plain, teams]:
      check pw_observation_contract(h) == 201 and pw_handle_observation_size(h) == TeamsViewSize
      check pw_action_contract(h) == 11 and pw_handle_user_inputs(h) == 0
      check pw_reset(h, 6, 24) == 0 # kept across reset
      check pw_observation_contract(h) == 201 and pw_action_contract(h) == 11
    check pw_observation_contract(ffa) == 202 and pw_action_contract(ffa) == 12
    # pw_set_action_contract selects between teams.view.1's four action contracts (the five
    # heads, the aim-offset seven, the movement-offset nine, or the target-conditioned seven); ffa.view.1 has only its pointer
    # contract; every retired or native-decoder contract is refused.
    var layout: array[10, int32]
    check pw_set_action_contract(nil, 11) == -1
    for version in [0'i32, 1, 2, 3, 12, 16, 101]: check pw_set_action_contract(teams, version) == -1
    for version in [0'i32, 1, 2, 11, 13, 14, 15]: check pw_set_action_contract(ffa, version) == -1
    check pw_set_action_contract(ffa, 12) == 0 and pw_action_contract(ffa) == 12
    check pw_action_layout(teams, ibuf(layout)) == 0 and layout[0..7] == @[5'i32, 51, 25, 2, 2, 2, 82, 0]
    check pw_action_layout_ext(teams, ibuf(layout)) == 0 and layout == [5'i32, 51, 25, 2, 2, 2, 0, 0, 82, 0]
    check pw_set_action_contract(teams, 13) == 0 and pw_action_contract(teams) == 13
    check pw_action_layout(teams, ibuf(layout)) == -1   # seven heads: the _ext form only
    check pw_action_layout_ext(teams, ibuf(layout)) == 0 and layout == [7'i32, 51, 25, 2, 2, 2, 23, 23, 128, 0]
    check pw_reset(teams, 7, 24) == 0 and pw_action_contract(teams) == 13   # kept across reset
    check pw_set_action_contract(teams, 15) == 0 and pw_action_contract(teams) == 15   # target-conditioned offsets
    check pw_action_layout_ext(teams, ibuf(layout)) == 0 and layout == [7'i32, 51, 25, 2, 2, 2, 23, 23, 818, 0]
    check pw_set_action_contract(teams, 11) == 0 and pw_action_contract(teams) == 11
    # teams.view.1 is the teams game's: FFA-kin (mode or config) and other seat counts are refused.
    check pw_set_game_mode(teams, 1) == -1
    check pw_set_game_mode(teams, 0) == 0
    check pw_set_seats(teams, 20) == -1 and pw_set_seats(teams, 16) == 0
    check teams.setConfig("""{"mode": "ffa_kin"}""") == (-2.cint, "observation contract teams.view.1 is for the teams game only")
    check pw_reset(teams, 5, 24) == 0 and pw_game_mode(teams) == 0
    check pw_set_game_mode(ffa, 1) == 0
    check ffa.setConfig("""{"mode": "ffa_kin"}""") == (0.cint, "")
    check pw_set_seats(ffa, 20) == 0
    pw_destroy(plain); pw_destroy(teams); pw_destroy(ffa)

  test "teams.view.1u<K> handles and hashes":
    check pw_create_observation_inputs(1, 100, -1) == nil and pw_create_observation_inputs(1, 100, 257) == nil
    # (202 = ffa.view.1u<K>: tests/test_paintbot_native_ffa_v2.nim.)
    for (v, k) in [(1'i32, 3'i32), (2'i32, 3'i32), (3'i32, 3'i32), (203'i32, 3'i32), (201'i32, 257'i32),
        (201'i32, -1'i32), (202'i32, 257'i32), (202'i32, -1'i32)]:
      check pw_create_observation_inputs_v(1, 100, v, k) == nil
    check pw_create_observation_inputs_v(1, HeartMeterMatchTicks+1, 201, 3) == nil
    for k in [1'i32, 3, 32, 64, 65, 128]:
      let a = pw_create_observation_inputs(1, 100, k)
      let b = pw_create_observation_inputs_v(1, 100, 201, k)
      require a != nil and b != nil
      for h in [a, b]:
        check pw_observation_contract(h) == 201 and pw_handle_user_inputs(h) == k
        check pw_handle_observation_size(h) == TeamsViewSize + k
        check pw_set_game_mode(h, 1) == -1
      check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash(k, o, 65)) ==
        (0.cint, userInputsContractHash(k.int))
      check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash_v(201, k, o, 65)) ==
        (0.cint, userInputsContractHash(k.int))
      check userInputsContractHash(k.int) == sha256Hex("paintbot-pw.teams.view.1u" & $k)
      pw_destroy(a); pw_destroy(b)
    for (v, k) in [(201'i32, 0'i32), (201'i32, 257'i32), (202'i32, 0'i32), (202'i32, 257'i32), (203'i32, 3'i32),
        (2'i32, 3'i32), (3'i32, 3'i32)]:
      check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash_v(v, k, o, 65))[0] == -1
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash(3, o, 64))[0] == -1
    let zero = pw_create_observation_inputs(1, 100, 0)
    check pw_observation_contract(zero) == 201 and pw_handle_observation_size(zero) == TeamsViewSize and
      pw_handle_user_inputs(zero) == 0
    pw_destroy(zero)

  test "full reference worlds (the reference decoder script) match every accepted-action state hash, both teams contracts":
    let seeds = parseInt(getEnv("PW_PARITY_SEEDS","2"))
    let ticks = parseInt(getEnv("PW_PARITY_TICKS","240"))
    for contract in [acTeamsView1, acTeamsView1Offset]:
      let heads = actionHeadSizes(contract).len
      for seed in 0..<seeds:
        checkpoint "contract " & $contract & " seed " & $seed
        configureRules(NativeRules)
        var reference = newWorld(int32(seed+13),ticks.int32)
        let seats = decoderSeats(contract)
        let handle = pw_create(int32(seed+13),ticks.int32)
        let inputs = pw_create_observation_inputs(int32(seed+13),ticks.int32, 3)
        require handle != nil and inputs != nil
        if contract == acTeamsView1Offset:
          check pw_set_action_contract(handle, 13) == 0 and pw_set_action_contract(inputs, 13) == 0
        var actions = newSeq[int32](Seats*heads)
        var rewards,terminals,resets,resetsU: array[LegacySeats,float32]
        var observations = newSeq[float32](Seats*TeamsViewSize)
        var observationsU = newSeq[float32](Seats*(TeamsViewSize+3))
        var expected: array[TeamsViewSize,float32]
        check pw_observe(handle,fbuf(observations),fbuf(resets)) == 0
        for value in resets: check value == 1
        var rows, offsetAims = 0
        while reference.winner == -1 and reference.tick < reference.endTick:
          beginViews(reference)
          for slot in 0..<Seats:
            # Hearts, then the training bot's identity aims at visible enemies (else a compass
            # heading); every third tick the aim head keeps; mirrored seats included; under the
            # aim-offset contract changing offsets on both axes.
            let offset = slot*heads
            trainingBotActions(seatView(slot), 2, actions.toOpenArray(offset, offset+ActionSizes.len-1))
            if actions[offset] == 0: actions[offset] = int32(1+(slot div 2+seed) mod 10)
            if (reference.tick.int + slot) mod 3 == 0: actions[offset+1] = 0
            actions[offset+2] = int32(actions[offset+2] == 1 or reference.tick mod 3 == 0)
            actions[offset+3] = int32(reference.tick mod 48 < 12)
            actions[offset+4] = int32(slot mod 3 == 0)
            if heads > ActionSizes.len:
              actions[offset+5] = int32((reference.tick.int + 3*slot) mod AimOffsetBins)
              actions[offset+6] = int32((reference.tick.int div 7 + slot) mod AimOffsetBins)
          let commands = decoded(seats, reference, actions, heads)
          if heads > ActionSizes.len:
            # The documented offset: an identity aim point plus ((ix - 11) * 28, (iz - 11) * 28),
            # mirrored for team 1 (then clamped to the map, as lookAt / shootAt clamp).
            beginViews(reference)
            for slot in 0..<Seats:
              let o = slot*heads
              let a = actions[o+1]
              let v = seatView(slot)
              if reference.cogs[slot].hp <= 0 or a notin 1'i32..16'i32 or v.visible(a-1) == 0: continue
              let flip = int32(mapFlip(slot))
              let x = v.playerX(a-1) + (actions[o+5] - AimOffsetCentre)*AimOffsetStep*flip
              let z = v.playerY(a-1) + (actions[o+6] - AimOffsetCentre)*AimOffsetStep*flip
              check commands[slot].aim == Point(x: clamp(x, minX().int32, maxX().int32), z: clamp(z, minZ().int32, maxZ().int32))
              inc offsetAims
          reference.step(commands)
          require pw_step(handle,ibuf(actions),fbuf(rewards),fbuf(terminals)) == 0
          require pw_step(inputs,ibuf(actions),fbuf(rewards),fbuf(terminals)) == 0
          require pw_state_hash(handle) == reference.stateHash()
          require pw_state_hash(inputs) == reference.stateHash()
          if reference.tick mod 16 == 0:
            require pw_observe(handle,fbuf(observations),fbuf(resets)) == 0
            require pw_observe(inputs,fbuf(observationsU),fbuf(resetsU)) == 0
            check resets == resetsU
            beginViews(reference)
            for slot in 0..<Seats:
              encodeObservation(seatView(slot), ocTeamsView1, expected)
              for i,value in expected:
                require observations[slot*TeamsViewSize+i] == value
                require observationsU[slot*(TeamsViewSize+3)+i] == value
              for i in 0..<3: require observationsU[slot*(TeamsViewSize+3)+TeamsViewSize+i] == 0
              inc rows
        check rows > 0
        if heads > ActionSizes.len: check offsetAims > 0
        for slot in 0..<Seats:
          check terminals[slot] == 1
          check rewards[slot] == float32(reference.glory[team(slot)])/1000
        check pw_step(handle,ibuf(actions),fbuf(rewards),fbuf(terminals)) == -2
        check pw_reset(handle,99,24) == 0
        configureRules(NativeRules)
        check pw_state_hash(handle) == newWorld(99,24).stateHash()
        pw_destroy(handle)
        pw_destroy(inputs)

  test "aim keep: the decoder re-issues the aim it last left; a life's first tick has none":
    # Documented decode (players/neural_decode.bas): "keep" (0) re-issues the aim the script
    # last left the seat with (its last aim, or its walking goal when it gave none); on the
    # first tick of a life nothing is known, so the seat gets no aim order and the world
    # faces its walk goal.
    configureRules(NativeRules)
    let handle = pw_create(21, 600)
    require handle != nil
    var reference = newWorld(21, 600)
    let seats = decoderSeats()
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    var labels: array[PrivilegedLabelCount, float32]
    var firstGoal, lastGoal, compassAim: array[LegacySeats, Point]
    for tick in 0..<40:
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        actions[o] = 43                                   # a compass step every tick
        actions[o+1] = if tick == 5: 17'i32 else: 0'i32   # one compass aim, else keep
      let commands = decoded(seats, reference, actions)
      for slot in 0..<Seats:
        require reference.cogs[slot].hp > 0               # nobody fires: one life each
        let c = commands[slot]
        check c.walk and not c.shoot
        if tick == 0: check c.aim == Point()              # a life's first tick: no aim order
        elif tick < 5: check c.aim == firstGoal[slot]     # keep = the goal of the aimless tick 0, re-issued
        elif tick == 5:
          check c.aim != Point() and c.aim != lastGoal[slot]
          compassAim[slot] = c.aim
        else: check c.aim == compassAim[slot]             # keep = the tick-5 compass point
        if tick == 0: firstGoal[slot] = c.goal
        lastGoal[slot] = c.goal
      reference.step(commands)
      require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_state_hash(handle) == reference.stateHash()
      for slot in 0..<Seats:
        # The world's aim after the step: the order's, else the walk goal.
        let aim = if commands[slot].aim != Point(): commands[slot].aim else: commands[slot].goal
        check pw_seat_privileged_labels(handle, slot.cint, fbuf(labels)) == 0
        check labels[5] == float32(aim.x) and labels[6] == float32(aim.z)
    pw_destroy(handle)

  test "pw_seat_privileged_labels: the world's own fields, the lead and the probes; a pure read":
    configureRules(NativeRules)
    var labels: array[PrivilegedLabelCount, float32]
    check PrivilegedLabelCount == 21
    check pw_seat_privileged_labels(nil, 0, fbuf(labels)) == -1
    let source = readFile(Base)
    for seed in [3'i32, 4]:
      resetOracle()
      var w = newWorld(seed, 1500)
      let players = loadBots(@[BotGroup(path: Base, count: Seats)])
      let handle = pw_create(seed, 1500)
      require handle != nil
      check pw_seat_privileged_labels(handle, -1, fbuf(labels)) == -1
      check pw_seat_privileged_labels(handle, Seats.cint, fbuf(labels)) == -1
      check pw_seat_privileged_labels(handle, 0, nil) == -1
      for slot in 0..<Seats: check pw_set_seat_script(handle, slot.cint, cbuf(source), source.len.int32) == 0
      var memory: LabelMemory
      memory.resetLabelMemory()
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var rewards, terminals: array[LegacySeats, float32]
      var seen: array[PrivilegedLabelCount, int]   # ticks x seats each label was non-zero
      var leads, probesOff = 0
      while w.winner == -1 and w.tick < w.endTick:
        for slot in 0..<Seats:
          require pw_seat_privileged_labels(handle, slot.cint, fbuf(labels)) == 0
          let me = w.cogs[slot]
          let gear = w.equipment[slot]
          require labels[0] == me.cooldown.float32 and labels[1] == gear.windup.float32
          require labels[2] == gear.sprayCooldown.float32 and labels[3] == me.shield.float32
          require labels[4] == me.respawn.float32
          require labels[5] == me.aim.x.float32 and labels[6] == me.aim.z.float32
          require labels[7] == w.scoreTicks[team(slot)].float32
          require labels[8] == w.scoreTicks[1-team(slot)].float32
          # Lead: valid exactly when the seat is alive and sees an enemy body; the point is
          # the nearest such body led by its last-step displacement (at most 60 per axis, 6
          # moves) less 5 of the seat's own planned steps.
          var target = -1
          var best = high(int64)
          for body in 0..<Seats:
            if body == slot or team(body) == team(slot) or not w.visible(slot, body): continue
            let d = distance2(me.pos, w.cogs[body].pos)
            if d < best: (best, target) = (d, body)
          require labels[9] == float32(me.hp > 0 and target >= 0)
          if labels[9] == 1:
            inc leads
            let p = w.cogs[target].pos
            require abs(labels[10] - p.x.float32) <= float32(6*60 + 15*MoveSpeed)
            require abs(labels[11] - p.z.float32) <= float32(6*60 + 15*MoveSpeed)
          else:
            require labels[10] == 0 and labels[11] == 0
          let expected = privilegedLabels(w, slot, memory)
          for i in 0..<PrivilegedLabelCount: require labels[i] == expected[i]
          # Probes: self and the 8 compass points 200 out (mirrored for team 1): inside the
          # map, not blocked, traversable from the seat.
          let flip = if team(slot) == 0: 1 else: -1
          for k in 0..8:
            let d = if k == 0: (0, 0) else: Directions[k-1]
            let q = point(me.pos.x.int + flip*d[0]*200, me.pos.z.int + flip*d[1]*200)
            let open = q.x.int >= minX() and q.x.int <= maxX() and q.z.int >= minZ() and q.z.int <= maxZ() and
              not w.blocked(q) and w.traversable(me.pos, q)
            require labels[12+k] == float32(open.int)
            if not open: inc probesOff
          for i in 0..<PrivilegedLabelCount:
            if labels[i] != 0: inc seen[i]
        let commands = players.decide(w)
        deliverSpeech(w)
        memory.recordLabelMemory(w)
        w.step(commands)
        require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(handle) == w.stateHash()   # reading labels changes nothing
      checkpoint "seed " & $seed & " leads " & $leads & " closed probes " & $probesOff & " non-zero " & $seen
      for i in [0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]: check seen[i] > 0
      check probesOff > 0
      # pw_reset clears the lead's memory: the first labels of the new match use none.
      check pw_reset(handle, seed, 1500) == 0
      memory.resetLabelMemory()
      let fresh = newWorld(seed, 1500)
      for slot in 0..<Seats:
        require pw_seat_privileged_labels(handle, slot.cint, fbuf(labels)) == 0
        let expected = privilegedLabels(fresh, slot, memory)
        for i in 0..<PrivilegedLabelCount: check labels[i] == expected[i]
      pw_destroy(handle)

  test "pw_observe_seats writes only the chosen rows, the same bytes as pw_observe":
    let handle = pw_create(9, 24)
    require handle != nil
    var obs = newSeq[float32](Seats*TeamsViewSize)
    var all = newSeq[float32](Seats*TeamsViewSize)
    var resets, allResets: array[LegacySeats, float32]
    for i in 0..<obs.len: obs[i] = -9
    for i in 0..<resets.len: resets[i] = -9
    check pw_observe_seats(nil, 1, fbuf(obs), fbuf(resets)) == -1
    check pw_observe_seats(handle, (1'u32 shl 3) or (1'u32 shl 12), fbuf(obs), fbuf(resets)) == 0
    check pw_observe(handle, fbuf(all), fbuf(allResets)) == 0
    configureRules(NativeRules)
    let w = newWorld(9, 24)
    beginViews(w)
    var expected: array[TeamsViewSize, float32]
    for slot in 0..<Seats:
      if slot in [3, 12]:
        encodeObservation(seatView(slot), ocTeamsView1, expected)
        for i in 0..<TeamsViewSize:
          check obs[slot*TeamsViewSize+i] == expected[i]
          check all[slot*TeamsViewSize+i] == expected[i]
        check resets[slot] == 1
      else:
        for i in 0..<TeamsViewSize: check obs[slot*TeamsViewSize+i] == -9
        check resets[slot] == -9
    pw_destroy(handle)

  test "terrain prewarm and shared cache files":
    check pw_terrain_prewarm(nil) == -1
    check pw_terrain_cache_save(nil, "x") == -1 and pw_terrain_cache_load(nil, "x") == -1
    let handle = pw_create(5, 24)
    require handle != nil
    let before = pw_state_hash(handle)
    check pw_terrain_prewarm(handle) > 0
    check pw_state_hash(handle) == before # prewarming changes no world state
    let path = getTempDir() / "paintbot-native-terrain-" & $getCurrentProcessId() & ".bin"
    check pw_terrain_cache_save(handle, path.cstring) >= pw_terrain_prewarm(handle)
    check pw_terrain_cache_load(handle, path.cstring) == 0 # already resident
    check pw_terrain_cache_load(handle, (path & ".missing").cstring) == -1
    check pw_set_map(handle, 0) == 0 and pw_reset(handle, 5, 24) == 0
    check pw_terrain_prewarm(handle) == 0 # generated maps are read from their grid
    check pw_terrain_cache_load(handle, path.cstring) == 0
    removeFile(path)
    pw_destroy(handle)
