## Observation contract v2 (paintbot-pw.rules37.obs.v2.float506): v1's 448 floats
## unchanged, then the public terrain block (neural_contract.encodeTerrainBlock).
import std/[unittest, math]
import ../examples/paintbot/[sim, neural_contract]

const
  T = ObservationSize # first terrain column
  IdentityBlock = 24 + 10*8 # v1 column of apparent identity 0 (its visibility flag)

proc v2(w: World, slot: int): array[ObservationSizeV2, float32] =
  for i in 0..<result.len: result[i] = NaN.float32
  encodeObservation(w, slot, result, ocV2)

proc lonely(seed: int32, keep: openArray[int]): World =
  ## A rules-37 world where only the listed seats are alive (so only they can be seen).
  visionRulesVersion = 37
  result = newWorld(seed)
  for i in 0..<Seats:
    if i notin keep: result.cogs[i].hp = 0

suite "Observation contract v2 (terrain)":
  setup:
    visionRulesVersion = 37

  test "ids, sizes and hashes; v1 is unchanged":
    check ObservationSize == 448
    check ObservationContract == "paintbot-pw.rules37.obs.v1.float448"
    check ObservationContractHash == "ed5d16768e3144a04a28420ce227ff2d6a831be9f64f3633326b133a5335b7e2"
    check ObservationSizeV2 == 506 and TerrainBlockSize == 58
    check ObservationContractV2 == "paintbot-pw.rules37.obs.v2.float506"
    check observationSize(ocV1) == 448 and observationSize(ocV2) == 506
    check observationContractVersion(ObservationContractHash) == ocV1
    check observationContractVersion(ObservationContractV2Hash) == ocV2
    check observationContractHash(ocV2) == ObservationContractV2Hash
    check observationContractId(ocV2) == ObservationContractV2
    expect ValueError: discard observationContractVersion("0" & ObservationContractV2Hash[1..^1])
    let w = newWorld(3)
    var short: array[ObservationSize, float32]
    var long: array[ObservationSizeV2, float32]
    expect ValueError: encodeObservation(w, 0, short, ocV2)
    expect ValueError: encodeObservation(w, 0, long, ocV1)
    expect ValueError: encodeObservation(w, 0, long) # the v1 overload keeps its width
    expect ValueError: encodeObservation(w, Seats, long, ocV2)

  test "v2's first 448 floats equal v1 exactly on stepped worlds, every seat":
    # Worlds stepped by the level-2 training bot on both sides (it walks to hearts,
    # the river ones included, aims at visible identities and fires), compared every
    # 4th tick for all 16 seats; the v1 overload and the versioned v1 path agree too.
    var compared, wetSelf, wetIdentity = 0
    for seed in [1'i32, 2, 3, 4]:
      configureRules(37)
      var w = newWorld(seed, 2400)
      var actions: array[ActionSizes.len, int32]
      var commands: array[Seats, Command]
      var a, b: array[ObservationSize, float32]
      var c: array[ObservationSizeV2, float32]
      while w.winner == -1 and w.tick < w.endTick:
        if w.tick mod 4 == 0:
          for slot in 0..<Seats:
            for i in 0..<a.len: a[i] = NaN.float32
            for i in 0..<c.len: c[i] = -7'f32
            encodeObservation(w, slot, a)
            encodeObservation(w, slot, b, ocV1)
            encodeObservation(w, slot, c, ocV2)
            for i in 0..<ObservationSize:
              require a[i] == c[i]
              require a[i] == b[i]
            for i in ObservationSize..<ObservationSizeV2:
              require classify(c[i]) notin {fcNan, fcInf, fcNegInf}
              require c[i] >= -1.1'f32 and c[i] <= 1.1'f32
            if c[T] == 1: inc wetSelf
            for j in 0..<Seats:
              if j != slot and c[T+22+2*j] == 1: inc wetIdentity
            inc compared
        for slot in 0..<Seats:
          trainingBotActions(w, slot, 2, actions)
          commands[slot] = decodeActions(w, slot, actions)
        w.step(commands)
    check compared > 4000
    # The bots do wade (hearts 9 and 10 sit in the river), so the wet columns are exercised.
    check wetSelf > 0
    check wetIdentity > 0

  test "a seat in the river reads wet and the river-bed height; the bank above is a positive delta":
    var w = lonely(11, [0])
    let river = w.controlHearts[8].pos # heart 9 of the movement head: (3200, 1250), in the water
    let bank = w.controlHearts[0].pos  # (960, 2000), level dry ground
    check river == point(3200, 1250) and bank == point(960, 2000)
    check inWater(river) and not inWater(bank)
    w.cogs[0].pos = river
    var o = v2(w, 0)
    check o[T] == 1
    check o[T+1] == -200'f32/800
    check o[T+2+2*8] == 1 and o[T+3+2*8] == 0      # standing on heart 8: same height
    check o[T+2+2*9] == 1 and o[T+3+2*9] == 0      # heart 9 is the other river heart
    check o[T+2+2*0] == 0 and o[T+3+2*0] == 200'f32/800 # the bank heart is above: positive
    check o[T+22+2*0] == 1 and o[T+23+2*0] == 0    # own identity slot: wet, zero delta
    for k in 54..57: check o[T+k] == 0              # nobody else visible
    # The same seat on the bank: dry, height 0, and the river hearts are below it.
    w.cogs[0].pos = bank
    o = v2(w, 0)
    check o[T] == 0 and o[T+1] == 0
    check o[T+2+2*8] == 1 and o[T+3+2*8] == -200'f32/800
    check o[T+3+2*8] < 0
    check o[T+2+2*0] == 0 and o[T+3+2*0] == 0
    # A raised heart reads positive from the bank (hearts 2..7 stand on terraces).
    check o[T+3+2*2] == float32(w.elevation(w.controlHearts[2].pos))/800
    check o[T+3+2*2] > 0

  test "a visible enemy wading below the bank: wet, negative delta, counted wet":
    let wading = point(2000, 1600) # in the river's water near our bank, elevation -179
    var w = lonely(12, [0, 1])
    w.cogs[0].pos = point(960, 2000)
    w.cogs[0].aim = point(3200, 1250)
    w.cogs[1].pos = wading
    require inWater(wading) and w.elevation(wading) < 0
    require w.visible(0, 1)
    var o = v2(w, 0)
    let j = w.observedSeat(0, 1)
    check j == 1
    check o[IdentityBlock + 8*j] == 1 # v1's visibility flag for the same slot
    check o[T+22+2*j] == 1
    check o[T+23+2*j] == float32(w.elevation(wading))/800
    check o[T+23+2*j] < 0
    check o[T+54] == 1'f32/8 and o[T+55] == 0 and o[T+56] == 0 and o[T+57] == 0
    # Out of the water on the bank beside us: dry, level, counted dry.
    w.cogs[1].pos = point(1400, 1800)
    w.cogs[0].aim = point(3200, 1800)
    require w.visible(0, 1)
    o = v2(w, 0)
    check o[T+22+2*j] == 0 and o[T+23+2*j] == 0
    check o[T+54] == 0 and o[T+55] == 1'f32/8
    # A wading teammate counts in the teammate columns.
    w = lonely(12, [0, 2])
    w.cogs[0].pos = point(960, 2000)
    w.cogs[0].aim = point(3200, 1250)
    w.cogs[2].pos = wading
    require w.visible(0, 2)
    o = v2(w, 0)
    check o[T+22+2*2] == 1 and o[T+23+2*2] == float32(w.elevation(wading))/800
    check o[T+54] == 0 and o[T+55] == 0 and o[T+56] == 1'f32/8 and o[T+57] == 0

  test "fog: an unseen seat changes nothing, wet or dry, and its slot stays zero":
    var w = lonely(13, [0, 1])
    w.cogs[0].pos = point(960, 2000)
    w.cogs[0].aim = point(-3000, 2000) # facing away from the river
    w.cogs[1].pos = point(3200, 1250)
    require not w.visible(0, 1)
    let before = v2(w, 0)
    for k in 0..<2: check before[T+22+2*1+k] == 0
    for k in 54..57: check before[T+k] == 0
    w.cogs[1].pos = point(3200, 2750) # still wading, elsewhere
    require not w.visible(0, 1)
    check v2(w, 0) == before
    w.cogs[1].pos = point(5440, 2000) # dry on the far bank
    require not w.visible(0, 1)
    check v2(w, 0) == before

  test "uniforms: the block counts the apparent team at the apparent identity, as v1 shows it":
    var w = lonely(14, [0, 1])
    w.cogs[0].pos = point(960, 2000)
    w.cogs[0].aim = point(3200, 1250)
    w.cogs[1].pos = point(2000, 1600)
    w.uniforms[1] = true # enemy seat 1 disguised as a teammate
    require w.visible(0, 1)
    let j = w.observedSeat(0, 1)
    check j != 1
    let o = v2(w, 0)
    check o[IdentityBlock + 8*j] == 1 and o[IdentityBlock + 8*1] == 0
    check o[T+22+2*j] == 1 and o[T+22+2*1] == 0
    check o[T+54] == 0 and o[T+56] == 1'f32/8 # counted as a wet teammate, like v1's team flag

suite "Observation contract v3 (goal vector)":
  setup:
    visionRulesVersion = 39
  test "ids, sizes and hashes; v3's first 506 floats equal v2 bitwise on stepped worlds, then the goal":
    check ObservationContractV3 == "paintbot-pw.rules39.obs.v3.float514" and ObservationSizeV3 == 514 and GoalSize == 8
    check observationSize(ocV3) == 514 and observationContractHash(ocV3) == ObservationContractV3Hash
    check observationContractVersion(ObservationContractV3Hash) == ocV3 and observationContractId(ocV3) == ObservationContractV3
    let goal: GoalVector = [1'f32, 0.25, 0.1, 0.5, -0.25, 0.1, -0.5, 0]
    var w = newWorld(2026, 900)
    var compared = 0
    while w.winner == -1 and w.tick < 600:
      if w.tick mod 7 == 0:
        for slot in 0..<Seats:
          var v2: array[ObservationSizeV2, float32]
          var v3, v3zero: array[ObservationSizeV3, float32]
          let bodies = w.observedBodies(slot)
          w.encodeObservation(slot, v2, bodies, ocV2)
          w.encodeObservation(slot, v3, bodies, ocV3, goal)
          w.encodeObservation(slot, v3zero, ocV3)   # the default goal is zeros
          for i in 0..<ObservationSizeV2:
            check cast[uint32](v3[i]) == cast[uint32](v2[i])
            check cast[uint32](v3zero[i]) == cast[uint32](v2[i])
          for i in 0..<GoalSize:
            check v3[ObservationSizeV2 + i] == goal[i] and v3zero[ObservationSizeV2 + i] == 0
          inc compared
      var commands: array[Seats, Command]
      for slot in 0..<Seats:
        var heads: array[ActionSizes.len, int32]
        w.trainingBotActions(slot, 2, heads)
        commands[slot] = w.decodeActions(slot, heads)
      w.step(commands)
    check compared > 1000
  test "goal vectors: within [-1, 1], finite, w_reserved 0":
    check goalVectorError([1'f32, 0, 0, 0, 0, 0, 0, 0]) == ""
    check goalVectorError([-1'f32, 1, -1, 1, -1, 1, -1, 0]) == ""
    for bad in [[1.01'f32, 0, 0, 0, 0, 0, 0, 0], [0'f32, 0, 0, 0, 0, 0, -1.5, 0], [0'f32, 0, 0, 0, 0, 0, 0, 0.001],
                [NaN.float32, 0, 0, 0, 0, 0, 0, 0], [0'f32, NegInf.float32, 0, 0, 0, 0, 0, 0]]:
      check goalVectorError(bad) != ""
    check goalVectorError([1'f32, 0, 0]) != ""
