## Real reference-engine replay parity, not an ABI self-consistency check.
import std/[unittest, os, strutils]
import ../examples/paintbot/[sim, neural_contract, native_env]

suite "Native training environment":
  test "versioned dimensions and invalid allocation":
    check pw_env_version() == 1
    check pw_observation_size() == ObservationSize
    check pw_action_count() == ActionSizes.len
    check pw_create(0,HeartMeterMatchTicks+1) == nil
    check pw_reset(nil,0,0) == -1
  test "full reference worlds match every accepted-action state hash":
    let seeds = parseInt(getEnv("PW_PARITY_SEEDS","2"))
    let ticks = parseInt(getEnv("PW_PARITY_TICKS","240"))
    for seed in 0..<seeds:
      configureRules(NativeRules)
      var reference = newWorld(int32(seed+13),ticks.int32)
      let handle = pw_create(int32(seed+13),ticks.int32)
      require handle != nil
      var actions: array[LegacySeats*ActionSizes.len,int32]
      var commands: array[LegacySeats,Command]
      var rewards,terminals,resets: array[LegacySeats,float32]
      var observations: array[LegacySeats*ObservationSize,float32]
      var expected: array[ObservationSize,float32]
      check pw_observe(handle,cast[ptr UncheckedArray[cfloat]](addr observations[0]),
        cast[ptr UncheckedArray[cfloat]](addr resets[0])) == 0
      for value in resets: check value == 1
      while reference.winner == -1 and reference.tick < reference.endTick:
        for slot in 0..<Seats:
          # Stable objective, changing aim/fire/charge; includes mirrored seats.
          let offset = slot*ActionSizes.len
          actions[offset] = int32(1+(slot div 2+seed) mod 10)
          actions[offset+1] = int32(17+(reference.tick.int div 24+slot) mod 8)
          actions[offset+2] = int32(reference.tick mod 3 == 0)
          actions[offset+3] = int32(reference.tick mod 48 < 12)
          actions[offset+4] = int32(slot mod 3 == 0)
          commands[slot] = decodeActions(reference,slot,actions.toOpenArray(offset,offset+4))
        reference.step(commands)
        require pw_step(handle,cast[ptr UncheckedArray[int32]](addr actions[0]),
          cast[ptr UncheckedArray[cfloat]](addr rewards[0]),
          cast[ptr UncheckedArray[cfloat]](addr terminals[0])) == 0
        require pw_state_hash(handle) == reference.stateHash()
        if reference.tick mod 64 == 0:
          require pw_observe(handle,cast[ptr UncheckedArray[cfloat]](addr observations[0]),
            cast[ptr UncheckedArray[cfloat]](addr resets[0])) == 0
          for slot in 0..<Seats:
            encodeObservation(reference,slot,expected)
            for i,value in expected: require observations[slot*ObservationSize+i] == value
      for slot in 0..<Seats:
        check terminals[slot] == 1
        check rewards[slot] == float32(reference.glory[team(slot)])/1000
      check pw_step(handle,cast[ptr UncheckedArray[int32]](addr actions[0]),
        cast[ptr UncheckedArray[cfloat]](addr rewards[0]),
        cast[ptr UncheckedArray[cfloat]](addr terminals[0])) == -2
      check pw_reset(handle,99,24) == 0
      configureRules(NativeRules)
      check pw_state_hash(handle) == newWorld(99,24).stateHash()
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
