## Native training ABI, observation contract v2: chosen at create, rows of 506 floats,
## identical to the reference encoder; the world (and its hash) never depends on it.
import std/[unittest, os, strutils]
import ../examples/paintbot/[sim, neural_contract, native_env]

proc fp(buffer: var openArray[float32]): ptr UncheckedArray[cfloat] =
  cast[ptr UncheckedArray[cfloat]](addr buffer[0])
proc ip(buffer: var openArray[int32]): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](addr buffer[0])

suite "Native observation contract v2":
  test "version selection, sizes, hashes and invalid arguments":
    check pw_observation_size() == ObservationSize # the v1 constant stays for v1 callers
    check pw_observation_size_for(1) == 448
    check pw_observation_size_for(2) == 506
    check pw_observation_size_for(0) == -1 and pw_observation_size_for(3) == -1
    check pw_create_observation(1, 24, 0) == nil
    check pw_create_observation(1, 24, 3) == nil
    check pw_create_observation(1, HeartMeterMatchTicks+1, 2) == nil
    check pw_observation_contract(nil) == -1 and pw_handle_observation_size(nil) == -1
    var text: array[65, char]
    let buffer = cast[ptr UncheckedArray[char]](addr text[0])
    check pw_observation_contract_hash(2, buffer, 65) == 0
    check $cast[cstring](addr text[0]) == ObservationContractV2Hash
    check pw_observation_contract_hash(1, buffer, 65) == 0
    check $cast[cstring](addr text[0]) == ObservationContractHash
    check pw_observation_contract_hash(3, buffer, 65) == -1
    check pw_observation_contract_hash(2, buffer, 64) == -1
    let plain = pw_create(5, 24)
    let one = pw_create_observation(5, 24, 1)
    let two = pw_create_observation(5, 24, 2)
    check pw_observation_contract(plain) == 1 and pw_handle_observation_size(plain) == 448
    check pw_observation_contract(one) == 1 and pw_handle_observation_size(one) == 448
    check pw_observation_contract(two) == 2 and pw_handle_observation_size(two) == 506
    check pw_reset(two, 6, 24) == 0 # kept across reset
    check pw_observation_contract(two) == 2 and pw_handle_observation_size(two) == 506
    pw_destroy(plain); pw_destroy(one); pw_destroy(two)

  test "v2 rows equal the reference encoder; v1 and v2 handles step hash for hash":
    let seeds = parseInt(getEnv("PW_PARITY_SEEDS", "2"))
    let ticks = parseInt(getEnv("PW_PARITY_TICKS", "480"))
    for seed in 0..<seeds:
      configureRules(NativeRules)
      var reference = newWorld(int32(seed+31), ticks.int32)
      let v1 = pw_create(int32(seed+31), ticks.int32)
      let v2 = pw_create_observation(int32(seed+31), ticks.int32, 2)
      require v1 != nil and v2 != nil
      var actions: array[Seats*ActionSizes.len, int32]
      var commands: array[Seats, Command]
      var rewards, terminals, resets, resets2: array[Seats, float32]
      var obs1: array[Seats*ObservationSize, float32]
      var obs2: array[Seats*ObservationSizeV2, float32]
      var expected: array[ObservationSizeV2, float32]
      var rows = 0
      while reference.winner == -1 and reference.tick < reference.endTick:
        if reference.tick mod 16 == 0:
          require pw_observe(v1, fp(obs1), fp(resets)) == 0
          require pw_observe(v2, fp(obs2), fp(resets2)) == 0
          check resets == resets2
          for slot in 0..<Seats:
            encodeObservation(reference, slot, expected, ocV2)
            for i in 0..<ObservationSizeV2: require obs2[slot*ObservationSizeV2+i] == expected[i]
            for i in 0..<ObservationSize: require obs1[slot*ObservationSize+i] == expected[i]
            inc rows
        for slot in 0..<Seats:
          let offset = slot*ActionSizes.len
          trainingBotActions(reference, slot, 2, actions.toOpenArray(offset, offset+ActionSizes.len-1))
          commands[slot] = decodeActions(reference, slot, actions.toOpenArray(offset, offset+ActionSizes.len-1))
        reference.step(commands)
        require pw_step(v1, ip(actions), fp(rewards), fp(terminals)) == 0
        require pw_step(v2, ip(actions), fp(rewards), fp(terminals)) == 0
        require pw_state_hash(v1) == reference.stateHash()
        require pw_state_hash(v2) == reference.stateHash()
      check rows > 0
      pw_destroy(v1); pw_destroy(v2)

  test "pw_observe_seats writes only the chosen v2 rows":
    let handle = pw_create_observation(9, 24, 2)
    var obs: array[Seats*ObservationSizeV2, float32]
    var resets: array[Seats, float32]
    for i in 0..<obs.len: obs[i] = -9
    for i in 0..<resets.len: resets[i] = -9
    check pw_observe_seats(handle, (1'u32 shl 3) or (1'u32 shl 12), fp(obs), fp(resets)) == 0
    configureRules(NativeRules)
    let w = newWorld(9, 24)
    var expected: array[ObservationSizeV2, float32]
    for slot in 0..<Seats:
      if slot in [3, 12]:
        encodeObservation(w, slot, expected, ocV2)
        for i in 0..<ObservationSizeV2: check obs[slot*ObservationSizeV2+i] == expected[i]
        check resets[slot] == 1
      else:
        for i in 0..<ObservationSizeV2: check obs[slot*ObservationSizeV2+i] == -9
        check resets[slot] == -9
    pw_destroy(handle)
