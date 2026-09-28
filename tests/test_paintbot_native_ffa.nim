## Native training ABI for FFA-kin: observation contract ffa.v1 selection (version 101).
import std/unittest
import ../examples/paintbot/[sim, kinship, neural_contract, native_env]

proc fp(buffer: var openArray[float32]): ptr UncheckedArray[cfloat] =
  cast[ptr UncheckedArray[cfloat]](addr buffer[0])

suite "Native ffa.v1 observation selection":
  test "version 101 creates 810-float rows equal to the reference encoder; 3 stays unknown":
    check pw_observation_size_for(101) == 810
    check pw_observation_size_for(3) == -1 and pw_create_observation(1, 24, 3) == nil
    var text: array[65, char]
    let buffer = cast[ptr UncheckedArray[char]](addr text[0])
    check pw_observation_contract_hash(101, buffer, 65) == 0
    check $cast[cstring](addr text[0]) == ObservationContractFfaV1Hash
    let h = pw_create_observation(9, 48, 101)
    require h != nil
    check pw_observation_contract(h) == 101 and pw_handle_observation_size(h) == 810
    check pw_reset(h, 10, 48) == 0
    check pw_observation_contract(h) == 101
    var obs = newSeq[float32](Seats*ObservationSizeFfaV1)
    var resets: array[Seats, float32]
    check pw_observe(h, fp(obs), fp(resets)) == 0
    configureRules(NativeRules)
    let reference = newWorld(10, 48)
    var expected = newSeq[float32](ObservationSizeFfaV1)
    for slot in 0..<Seats:
      encodeObservation(reference, slot, expected, ocFfaV1)
      check obs[slot*ObservationSizeFfaV1 ..< (slot+1)*ObservationSizeFfaV1] == expected
    pw_destroy(h)
