## PWNET002 for variable-length entity sections (observation contract ffa.v2): token layers up
## to 256 tokens; layout words, which a model.bin uses for any count, offset or width of the
## match layout, so one file loads at 16 and at 50 seats; ENTITY_ATTN's token rows feeding
## TOKEN_MIX, POINTER and ATTN_POOL; and the ATTN_POOL layer itself. Models without these load
## and cost exactly as before (test_paintbot_neural_net2 and its published counts).
import std/[unittest, random, strutils, math]
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

proc layerNorm32(v: var seq[float32], gain, shift: openArray[float32], eps: float32) =
  ## neural_actor.md's LayerNorm, term for term: mu = sum/n, var = (sum of (v-mu)^2)/n, r = 1/sqrt(var + eps),
  ## v = ((v-mu)*r)*gain + shift.
  let n = v.len
  var total = 0'f32
  for x in v: total += x
  let mu = total / float32(n)
  var squares = 0'f32
  for x in v:
    let c = x - mu
    squares += c*c
  let r = 1'f32 / sqrt(squares / float32(n) + eps)
  for i in 0..<n:
    let c = v[i] - mu
    let scaled = c*r
    let gained = scaled*gain[i]
    v[i] = gained + shift[i]

proc relu32(v: var seq[float32]) =
  for x in v.mitems:
    if not (x > 0'f32): x = 0'f32

proc pools32(rows: seq[seq[float32]], valid: seq[bool], d: int): seq[float32] =
  result = newSeq[float32](2*d)
  var count = 0
  for ok in valid:
    if ok: inc count
  if count == 0: return
  let inverse = 1'f32 / float32(count)
  for c in 0..<d:
    var total = 0'f32
    var best = 0'f32
    var first = true
    for n in 0..<rows.len:
      if not valid[n]: continue
      total += rows[n][c]
      if first or rows[n][c] > best:
        best = rows[n][c]
        first = false
    result[c] = total*inverse
    result[d+c] = best

suite "PWNET002 token-layer LayerNorm (params 6 = norm, 7 = eps)":
  # 6 tokens of 8 floats (flag at +0) in 0..47, the seat's own 8 floats at 48..55 shared by every token.
  proc normSpecs(r: var Rand, mlpNorm, mixNorm: bool): seq[Spec] =
    @[r.tokenMlp(6, [[0'u32, 8, 8], [48'u32, 0, 8]], 0, 0, [10, 7], norm = mlpNorm, eps = 1e-4'f32),  # 14
      concat(48, 8),                                                                                  # 22
      r.dense(22, 12, bias = true, relu = true),                                                      # 12
      r.tokenMix(0, 7, 12, 5, norm = mixNorm, eps = 2e-5'f32),                                        # 22
      r.dense(22, 9, bias = true),                                                                    # 9
      r.pointerHead(3, 2, 5)]                                                                         # logits 2..7

  proc tokenObservation(r: var Rand): seq[float32] =
    result = r.observation(56)
    for n in 0..<6: result[8*n] = float32(n mod 3 != 1)  # tokens 1 and 4 masked

  test "the engine equals a float32 reimplementation of the equations, term for term":
    var r = initRand(95)
    let specs = r.normSpecs(true, true)
    let actor = loadActor(encode2(56, [4, 5], specs))
    let mlp = specs[0].tensors
    let mix = specs[3].tensors
    for trial in 0..<20:
      let obs = r.tokenObservation()
      # TOKEN_MLP: per layer W, b, gain, shift; LayerNorm before the relu.
      var rows: seq[seq[float32]]
      var valid: seq[bool]
      for n in 0..<6:
        valid.add obs[8*n] > 0.5
        if not valid[^1]:
          rows.add newSeq[float32](7)
          continue
        var x = obs[8*n ..< 8*n+8] & obs[48 ..< 56]
        var off = 0
        for (n0, n1) in [(16, 10), (10, 7)]:
          var y = dense32(x, mlp[off ..< off+n1*n0], mlp[off+n1*n0 ..< off+n1*n0+n1], n1)
          layerNorm32(y, mlp[off+n1*n0+n1 ..< off+n1*n0+2*n1], mlp[off+n1*n0+2*n1 ..< off+n1*n0+3*n1], 1e-4'f32)
          relu32(y)
          off += n1*n0 + 3*n1
          x = y
        rows.add x
      var h = pools32(rows, valid, 7) & obs[48 ..< 56]
      h = dense32(h, specs[2].tensors[0 ..< 22*12], specs[2].tensors[22*12 ..< 22*12+12], 12, relu = true)
      # TOKEN_MIX: Ue [5, 7], b [5], Uy [5, 12], gain [5], shift [5].
      let u = dense32(h, mix[40 ..< 100], newSeq[float32](5), 5)
      var zs: seq[seq[float32]]
      for n in 0..<6:
        if not valid[n]:
          zs.add newSeq[float32](5)
          continue
        var zrow = dense32(rows[n], mix[0 ..< 35], mix[35 ..< 40], 5)
        for o in 0..<5: zrow[o] = zrow[o] + u[o]
        layerNorm32(zrow, mix[100 ..< 105], mix[105 ..< 110], 2e-5'f32)
        relu32(zrow)
        zs.add zrow
      let mixed = h & pools32(zs, valid, 5)
      var logits = dense32(mixed, specs[4].tensors[0 ..< 22*9], specs[4].tensors[22*9 ..< 22*9+9], 9)
      let v = specs[5].tensors
      for n in 0..<6:
        if not valid[n]: continue
        var dot = 0'f32
        for i in 0..<5: dot += zs[n][i]*v[i]
        logits[2+n] = logits[2+n] + (dot + v[5])
      check actor.run(obs) == logits

  test "operation counts, masked tokens, and norm off is today's layer":
    var r = initRand(96)
    let both = r.normSpecs(true, true)
    var plain = both
    plain[0] = r.tokenMlp(6, [[0'u32, 8, 8], [48'u32, 0, 8]], 0, 0, [10, 7])
    plain[3] = r.tokenMix(0, 7, 12, 5)
    let base = loadActor(encode2(56, [4, 5], plain)).operationCount
    check layerNormOps(10) == 8*10 + 32
    check loadActor(encode2(56, [4, 5], both)).operationCount ==
      base + 6*(layerNormOps(10) + layerNormOps(7)) + 6*layerNormOps(5)
    check tokenNormOps(6, [10, 7]) == 6*(112 + 88)
    # A masked token's floats change nothing.
    let actor = loadActor(encode2(56, [4, 5], both))
    var obs = r.tokenObservation()
    let first = actor.run(obs)
    for c in 1..7: obs[8+c] = 7.5
    check actor.run(obs) == first
    # Constant pre-activations (every token row identical across its units) stay finite: var 0, r = 1/sqrt(eps).
    let flat = @[Spec(code: 7, params: [2'u32, 1, AttnAlwaysValid, 0, 1, 0, 1, cast[uint32](1e-5'f32)],
      extra: @[0'u32, 1, 1, 3], tensors: @[0'f32, 0, 0, 0.5, 0.5, 0.5, 1, 1, 1, 0.25, -1, 3]), r.dense(6, 4)]
    let flatActor = loadActor(encode2(4, [2, 2], flat))
    check flatActor.run(@[1'f32, 2, 3, 4]).len == 4

  test "the loader checks the norm flag, its eps, and the gain and shift":
    var r = initRand(97)
    let good = r.normSpecs(true, true)
    discard loadActor(encode2(56, [4, 5], good))
    proc with(specs: seq[Spec], k: int, change: proc (s: var Spec)): string =
      var v = specs
      change(v[k])
      encode2(56, [4, 5], v)
    for k in [0, 3]:
      check rejects(good.with(k, proc (s: var Spec) = s.params[6] = 2), "parameter 6 must be 0 or 1")
      check rejects(good.with(k, proc (s: var Spec) = s.params[7] = 0), "eps must be finite and positive")
      check rejects(good.with(k, proc (s: var Spec) = s.params[7] = cast[uint32](-1e-5'f32)), "eps must be")
      check rejects(good.with(k, proc (s: var Spec) = s.params[7] = cast[uint32](NaN.float32)), "eps must be")
      check rejects(good.with(k, proc (s: var Spec) = s.params[7] = layoutWord(0, 0)), "cannot be a layout word",
        actorLayout(ffaV2Layout(16, 10), [4, 5]))
      # Without norm the eps word stays 0; the gain and shift must be present with it (and absent without).
      check rejects(good.with(k, proc (s: var Spec) = s.params[6] = 0), "")
      check rejects(good.with(k, proc (s: var Spec) = s.tensors.setLen(s.tensors.len - 2)), "")
    var plain = r.normSpecs(false, false)
    for k in [0, 3]:
      check rejects(plain.with(k, proc (s: var Spec) = s.params[7] = cast[uint32](1e-5'f32)), "unused parameter 7")
    check rejects(plain.with(3, proc (s: var Spec) = s.params[2] = 1), "unused parameter 2")
    check rejects(plain.with(0, proc (s: var Spec) = s.params[5] = 1), "unused parameter 5")

suite "PWNET002 TOKEN_PAIR (layer 14): a learned pairwise token layer":
  # 6 tokens of 8 floats (flag +0, x +1, z +2) in 0..47, the seat's own 8 floats at 48..55.
  proc pairSpecs(r: var Rand, selfPairs = false): seq[Spec] =
    @[r.tokenMlp(6, [[0'u32, 8, 8], [48'u32, 0, 8]], 0, 0, [9]),     # 18, rows e (9)
      concat(48, 8),                                                  # 26
      r.tokenPair(0, 9, 4, 0, 8, 1, 2, selfPairs),                    # 26 + 2*(9 + 8) = 60, rows (17)
      r.tokenMix(2, 17, 60, 5),                                       # 70
      r.dense(70, 9, bias = true),                                    # 9
      r.pointerHead(3, 2, 5)]                                         # logits 2..7

  proc pairObservation(r: var Rand): seq[float32] =
    result = r.observation(56)
    for n in 0..<6: result[8*n] = float32(n != 1 and n != 4)

  test "the engine equals a float32 reimplementation, term for term":
    for selfPairs in [false, true]:
      var r = initRand(98)
      let specs = r.pairSpecs(selfPairs)
      let actor = loadActor(encode2(56, [4, 5], specs))
      let mlp = specs[0].tensors
      let pr = specs[2].tensors
      for trial in 0..<10:
        let obs = r.pairObservation()
        var rows: seq[seq[float32]]
        var valid: seq[bool]
        for n in 0..<6:
          valid.add obs[8*n] > 0.5
          rows.add(if valid[^1]: dense32(obs[8*n ..< 8*n+8] & obs[48 ..< 56], mlp[0 ..< 144], mlp[144 ..< 153], 9,
            relu = true) else: newSeq[float32](9))
        let x0 = pools32(rows, valid, 9) & obs[48 ..< 56]
        # TOKEN_PAIR: A [4, 9], B [4, 9], C [4, 10], b [4].
        var pairRows: seq[seq[float32]]
        for n in 0..<6:
          if not valid[n]:
            pairRows.add newSeq[float32](17)
            continue
          let an = dense32(rows[n], pr[0 ..< 36], newSeq[float32](4), 4)
          var mean = newSeq[float32](4)
          var best = newSeq[float32](4)
          var count = 0
          for m in 0..<6:
            if not valid[m] or (m == n and not selfPairs): continue
            let bm = dense32(rows[m], pr[36 ..< 72], newSeq[float32](4), 4)
            let (xn, zn, xm, zm) = (obs[8*n+1], obs[8*n+2], obs[8*m+1], obs[8*m+2])
            # One product or sum per statement (no FMA contraction), as the layer computes them.
            let (xx, zz, xz, zx, nx, nz, mx, mz) = (xn*xm, zn*zm, xn*zm, zn*xm, xn*xn, zn*zn, xm*xm, zm*zm)
            let g = @[xn, zn, xm, zm, xm - xn, zm - zn, xx + zz, xz - zx, nx + nz, mx + mz]
            let cg = dense32(g, pr[72 ..< 112], pr[112 ..< 116], 4)
            for o in 0..<4:
              var s = cg[o]
              s = s + an[o]
              s = s + bm[o]
              let h = if s > 0'f32: s else: 0'f32
              mean[o] = mean[o] + h
              if count == 0 or h > best[o]: best[o] = h
            inc count
          if count > 0:
            let inverse = 1'f32 / float32(count)
            for o in 0..<4: mean[o] = mean[o]*inverse
          pairRows.add rows[n] & mean & best
        let x1 = x0 & pools32(pairRows, valid, 17)
        let mix = specs[3].tensors
        let u = dense32(x1, mix[85+5 ..< 85+5+300], newSeq[float32](5), 5)
        var zs: seq[seq[float32]]
        for n in 0..<6:
          if not valid[n]:
            zs.add newSeq[float32](5)
            continue
          var z = dense32(pairRows[n], mix[0 ..< 85], mix[85 ..< 90], 5)
          for o in 0..<5:
            z[o] = z[o] + u[o]
            if not (z[o] > 0'f32): z[o] = 0'f32
          zs.add z
        let mixed = x1 & pools32(zs, valid, 5)
        var logits = dense32(mixed, specs[4].tensors[0 ..< 630], specs[4].tensors[630 ..< 639], 9)
        let v = specs[5].tensors
        for n in 0..<6:
          if not valid[n]: continue
          var dot = 0'f32
          for i in 0..<5: dot += zs[n][i]*v[i]
          logits[2+n] = logits[2+n] + (dot + v[5])
        check actor.run(obs) == logits

  test "cost, masked tokens, the loader's checks":
    var r = initRand(99)
    let specs = r.pairSpecs()
    let actor = loadActor(encode2(56, [4, 5], specs))
    check tokenPairOps(6, 9, 4, 26) == 26 + 6*(4*9*4 + 2 + 9) + 36*(18 + 80 + 24) + 6*(8 + 4) + (6 + 2*6*17 + 17 + 8)
    check actor.operationCount == tokenMlpOps(6, [16, 9]) + 8 + tokenPairOps(6, 9, 4, 26) +
      tokenMixOps(6, 17, 60, 5) + (2*70*9 + 9) + pointerOps(6, 5, 9)
    var obs = r.pairObservation()
    let first = actor.run(obs)
    for c in 1..7: obs[8+c] = 3.5   # token 1 is masked: its floats (and geometry) change nothing
    check actor.run(obs) == first
    obs[8*2+1] = obs[8*2+1] + 0.25   # a valid token's x moves its pairs
    check actor.run(obs) != first
    proc with(k: int, change: proc (s: var Spec)): string =
      var v = specs
      change(v[k])
      encode2(56, [4, 5], v)
    check rejects(with(2, proc (s: var Spec) = s.params[0] = 1), "TOKEN_PAIR source")
    check rejects(with(2, proc (s: var Spec) = s.params[1] = 0), "TOKEN_PAIR width")
    check rejects(with(2, proc (s: var Spec) = s.params[4] = 8), "geometry stride")
    check rejects(with(2, proc (s: var Spec) = s.params[2] = 16), "geometry outside the input")
    check rejects(with(2, proc (s: var Spec) = s.params[6] = 2), "parameter 6 must be 0 or 1")
    check rejects(with(2, proc (s: var Spec) = s.params[7] = 1), "unused parameter 7")
    check rejects(with(2, proc (s: var Spec) = s.tensors.setLen(s.tensors.len - 1)), "")
