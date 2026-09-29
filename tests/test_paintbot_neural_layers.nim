## PWNET002 for variable-length entity sections (observation contract ffa.v2): token layers up
## to 256 tokens; layout words, which a model.bin uses for any count, offset or width of the
## match layout, so one file loads at 16 and at 50 seats; ENTITY_ATTN's token rows feeding
## TOKEN_MIX, POINTER and ATTN_POOL; and the ATTN_POOL layer itself. Models without these load
## and cost exactly as before (test_paintbot_neural_net2 and its published counts).
import std/[unittest, random, strutils]
import ../examples/paintbot/[neural_contract, neural_actor, neural_host]
import paintbot_pwnet2_fixture

proc rejects(data: string, fragment: string, layout = ActorLayout()): bool =
  try:
    discard loadActor(data, layout)
    false
  except ValueError as e:
    fragment in e.msg

proc observation(r: var Rand, n: int): seq[float32] =
  for i in 0..<n: result.add float32(r.rand(2.0) - 1.0)

proc dense32(x, w, b: openArray[float32], m: int, relu = false): seq[float32] =
  ## neural_actor's DENSE, term for term: a float32 sum from +0 over i ascending, then the bias.
  let n = x.len
  for o in 0..<m:
    var sum = 0'f32
    for i in 0..<n: sum += x[i]*w[o*n+i]
    sum = sum + b[o]
    if relu and not (sum > 0'f32): sum = 0'f32
    result.add sum

proc run(actor: Actor, obs: seq[float32]): seq[float32] =
  var state = newSeq[float32](actor.stateSize)
  result = newSeq[float32](actor.outputSize)
  actor.infer(obs, state, result)

suite "PWNET002 for entity sections":
  test "token layers take up to 256 tokens":
    var r = initRand(91)
    let mlp = loadActor(encode2(512, [2, 2, 2], [r.tokenMlp(256, [[0'u32, 2, 2]], 0, 0, [4]), r.dense(8, 6)]))
    var obs = r.observation(512)
    for n in 0..<256: obs[2*n] = float32(n mod 2)
    check mlp.run(obs).len == 6
    let attn = loadActor(encode2(512, [2, 2, 2], [r.attention([[0'u32, 2, 256, 2, 0]], 8, 2, 1, 8, 0, 0),
      r.dense(16, 6)]))
    check attn.run(obs).len == 6
    let near = loadActor(encode2(1300, [2, 2, 2], [segmentNear(256, 0, 4, 1, 2, 0, NoExclude, 3, 1, 1, 0.5,
      1024, 1), r.dense(1300, 6)]))
    check near.operationCount == 1300 + 12*256*256 + 8*256 + 2*1300*6
    check near.run(r.observation(1300)).len == 6

  test "ENTITY_ATTN token rows feed TOKEN_MIX, POINTER and ATTN_POOL; a masked token changes nothing":
    var r = initRand(92)
    # 8 tokens of 8 floats (flag at +0) in 64 inputs.
    let specs = @[r.attention([[0'u32, 8, 8, 8, 0]], 8, 2, 1, 8, 0, 0),   # 16
      r.tokenMix(0, 8, 16, 6),                                              # 16 + 12 = 28
      r.attnPool(0, 28, 8, 2, 4, 3),                                        # 28 + 6 = 34
      r.dense(34, 12),
      r.pointerHead(0, 4, 8)]                                               # the attention rows, logits 4..11
    let actor = loadActor(encode2(64, [4, 8], specs))
    check actor.operationCount == attentionOps([(8, 8)], 8, 2, 1, 8, 0) + (8*8 + 8) +
      tokenMixOps(8, 8, 16, 6) + attnPoolOps(8, 8, 28, 2, 4, 3) + 2*34*12 + pointerOps(8, 8, 12)
    var obs = r.observation(64)
    for n in 0..<8: obs[8*n] = 1
    obs[8*3] = 0  # token 3 masked
    let first = actor.run(obs)
    for c in 1..7: obs[8*3+c] = 9.5
    check actor.run(obs) == first
    # A POINTER over masked tokens adds nothing to their logits; every token masked still runs.
    for n in 0..<8: obs[8*n] = 0
    check actor.run(obs).len == 12
    check rejects(encode2(64, [4, 8], @[r.dense(64, 16), r.attnPool(0, 16, 8, 2, 4, 3), r.dense(22, 12)]),
      "ATTN_POOL source must name an earlier")
    check rejects(encode2(64, [4, 8], @[specs[0], r.attnPool(0, 16, 8, 33, 4, 3)]), "ATTN_POOL heads")
    check rejects(encode2(64, [4, 8], @[specs[0], r.attnPool(0, 16, 8, 2, 257, 3)]), "key and value widths")

  test "ATTN_POOL: one valid token's value comes through exactly, two equal tokens average to it":
    var r = initRand(93)
    let mlp = r.tokenMlp(4, [[0'u32, 8, 8]], 0, 0, [5])         # 4 tokens of 8 at stride 8, rows of 5
    let pool = r.attnPool(0, 10, 5, 1, 3, 4)                    # heads 1, key 3, value 4: [x (10), pooled (4)]
    let actor = loadActor(encode2(32, [7, 7], [mlp, pool]))
    var obs = r.observation(32)
    for n in 0..<4: obs[8*n] = 0
    obs[16] = 1  # only token 2
    let w1 = mlp.tensors[0 ..< 40]
    let b1 = mlp.tensors[40 ..< 45]
    let wv = pool.tensors[30+3+15+3 ..< 30+3+15+3+20]
    let bv = pool.tensors[30+3+15+3+20 ..< 30+3+15+3+24]
    let e2 = dense32(obs[16 ..< 24], w1, b1, 5, relu = true)
    let v = dense32(e2, wv, bv, 4)
    let one = actor.run(obs)
    check one[10 ..< 14] == v
    # Token 0 a copy of token 2: each weighs exactly 1/2, so the pool is v again.
    for c in 0..<8: obs[c] = obs[16+c]
    check actor.run(obs)[10 ..< 14] == v
    # No valid token: the pool is zero and x passes through.
    for n in 0..<4: obs[8*n] = 0
    let none = actor.run(obs)
    check none[10 ..< 14] == @[0'f32, 0, 0, 0]

  test "layout words: one model.bin loads and runs at 16 and at 50 seats":
    var r = initRand(94)
    let cogs = layoutWord(0, 0)
    let specs = @[r.tokenMlp(0, [[0'u32, 0, 44]], 0, 0, [8]),  # tokens and slice set below
      concat(0, 24),                                            # the header
      r.attnPool(0, 40, 8, 2, 4, 4),
      r.dense(48, 6)]
    var words = specs
    words[0].params[0] = cogs
    words[0].extra[0] = layoutWord(0, 1)
    words[0].extra[1] = layoutWord(0, 2)
    let model = encodeWords(layoutWord(LayoutGlobal, 0), 6, [2'u32, 2, 2], words, ObservationContractFfaV2Hash)
    check rejects(model, "needs a match layout")
    var sizes: seq[int]
    for (seats, hearts) in [(16, 10), (50, 100)]:
      let l = ffaV2Layout(seats, hearts)
      let actor = loadActor(model, actorLayout(l, [2, 2, 2]))
      check actor.inputSize == l.size and actor.outputSize == 6
      check actor.operationCount <= neuralOperationBudget(seats)
      var obs = newSeq[float32](l.size)
      for k in 0..<l.cogRows div 3: obs[l.cogOffset + k*FfaV2CogWidth] = 1   # a third of the cogs seen
      for i in 0..<l.size:
        if (i - l.cogOffset) mod FfaV2CogWidth != 0: obs[i] = float32(r.rand(2.0) - 1.0)
      check actor.run(obs).len == 6
      sizes.add actor.inputSize
    check sizes == @[24 + 15*44 + 10*12 + 24, 24 + 49*44 + 100*12 + 24]
    # Fields that name nothing, or name a pointer target the layout lacks, are rejected.
    var target = words
    target.add r.pointerHead(0, 0, 8)
    target[4].params[1] = layoutWord(0, 3)
    check rejects(encodeWords(layoutWord(LayoutGlobal, 0), 6, [2'u32, 2, 2], target, ObservationContractFfaV2Hash),
      "no pointer target", actorLayout(ffaV2Layout(16, 10), [2, 2, 2]))
    var bad = words
    bad[0].params[0] = layoutWord(9, 0)
    check rejects(encodeWords(layoutWord(LayoutGlobal, 0), 6, [2'u32, 2, 2], bad, ObservationContractFfaV2Hash),
      "unknown layout word section", actorLayout(ffaV2Layout(16, 10), [2, 2, 2]))
    let floatWord = encode2(8, [2, 2, 2], [Spec(code: 2, params: [8'u32, layoutWord(0, 0), 0, 0, 0, 0, 0, 0],
      tensors: newSeq[float32](8)), r.dense(8, 6)])
    check rejects(floatWord, "cannot be a layout word", actorLayout(ffaV2Layout(16, 10), [2, 2, 2]))
    check not isLayoutWord(AttnAlwaysValid) and isLayoutWord(LayoutWordBase)

  test "the neural budget scales with seats as BASIC's does":
    check neuralOperationBudget(16) == 4_000_000 and neuralOperationBudget(8) == 4_000_000
    check neuralOperationBudget(50) == 12_500_000 and neuralOperationBudget(256) == 64_000_000
