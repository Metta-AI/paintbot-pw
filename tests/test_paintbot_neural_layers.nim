## PWNET002 for variable-length entity sections (observation contract ffa.view.1): token layers up
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
    let model = encodeWords(layoutWord(LayoutGlobal, 0), 6, [2'u32, 2, 2], words, ObservationContractFfaView1Hash)
    check rejects(model, "needs a match layout")
    var sizes: seq[int]
    for (seats, hearts) in [(16, 10), (50, 100)]:
      let l = ffaViewLayout(seats, hearts)
      let actor = loadActor(model, actorLayout(l, [2, 2, 2]))
      check actor.inputSize == l.size and actor.outputSize == 6
      check actor.operationCount <= neuralOperationBudget(seats)
      var obs = newSeq[float32](l.size)
      for k in 0..<l.cogRows div 3: obs[l.cogOffset + k*FfaCogWidth] = 1   # a third of the cogs seen
      for i in 0..<l.size:
        if (i - l.cogOffset) mod FfaCogWidth != 0: obs[i] = float32(r.rand(2.0) - 1.0)
      check actor.run(obs).len == 6
      sizes.add actor.inputSize
    check sizes == @[24 + 15*44 + 10*12 + 24, 24 + 49*44 + 100*12 + 24]
    # Fields that name nothing, or name a pointer target the layout lacks, are rejected.
    var target = words
    target.add r.pointerHead(0, 0, 8)
    target[4].params[1] = layoutWord(0, 3)
    check rejects(encodeWords(layoutWord(LayoutGlobal, 0), 6, [2'u32, 2, 2], target, ObservationContractFfaView1Hash),
      "no pointer target", actorLayout(ffaViewLayout(16, 10), [2, 2, 2]))
    var bad = words
    bad[0].params[0] = layoutWord(9, 0)
    check rejects(encodeWords(layoutWord(LayoutGlobal, 0), 6, [2'u32, 2, 2], bad, ObservationContractFfaView1Hash),
      "unknown layout word section", actorLayout(ffaViewLayout(16, 10), [2, 2, 2]))
    let floatWord = encode2(8, [2, 2, 2], [Spec(code: 2, params: [8'u32, layoutWord(0, 0), 0, 0, 0, 0, 0, 0],
      tensors: newSeq[float32](8)), r.dense(8, 6)])
    check rejects(floatWord, "cannot be a layout word", actorLayout(ffaViewLayout(16, 10), [2, 2, 2]))
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
        actorLayout(ffaViewLayout(16, 10), [4, 5]))
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

proc sparse32(x: openArray[float32], s: Spec): seq[float32] =
  ## neural_actor.md's SPARSE_DENSE straight from the spec's words: per row, a float32 sum from +0 over the stored
  ## entries in order, then the bias, then the act.
  let outputs = s.params[1].int
  let nnz = s.params[4].int
  for o in 0..<outputs:
    var sum = 0'f32
    for e in s.extra[o].int ..< s.extra[o+1].int:
      sum += x[s.extra[outputs + 1 + e].int]*s.tensors[e]
    if s.params[2] == 1: sum = sum + s.tensors[nnz + o]
    if s.params[3] == 1 and not (sum > 0'f32): sum = 0'f32
    result.add sum

proc patternCsr(inputs, outputs: int): (seq[uint32], seq[uint32]) =
  ## A fixed sparsity pattern (mirrored in test_neural_package.py): row o stores the columns i with
  ## (i + 2*o) mod 5 == 0, except that rows with o mod 7 == 6 store nothing.
  var starts = @[0'u32]
  var cols: seq[uint32]
  for o in 0..<outputs:
    if o mod 7 != 6:
      for i in 0..<inputs:
        if (i + 2*o) mod 5 == 0: cols.add i.uint32
    starts.add cols.len.uint32
  (starts, cols)

proc patternSparse(r: var Rand, inputs, outputs: int, bias, relu: bool): Spec =
  let (starts, cols) = patternCsr(inputs, outputs)
  sparseDenseCsr(inputs, outputs, starts, cols, r.weights(cols.len, 0.5), (if bias: r.weights(outputs, 0.1) else: @[]),
    relu)

proc wideObservation(r: var Rand, n: int): seq[float32] =
  ## Mixed signs, exact zeros (so DENSE's absent columns multiply into -0 and +0), and a wide magnitude range.
  for i in 0..<n:
    result.add(case r.rand(4)
      of 0: 0'f32
      of 1: -0'f32
      of 2: float32(r.rand(2.0) - 1.0)
      of 3: float32(r.rand(2000.0) - 1000.0)
      else: float32(r.rand(2.0e-3) - 1.0e-3))

suite "PWNET002 SPARSE_DENSE (layer 17): DENSE over a CSR matrix":
  test "the engine equals a float32 reimplementation, term for term (empty rows, nnz 0, bias, relu)":
    var r = initRand(171)
    var trials, emptyRowsSeen, zeroNnz = 0
    for density in [0.0, 0.01, 0.1, 0.5, 1.0]:
      for bias in [false, true]:
        for relu in [false, true]:
          for k in 0..<3:
            let inputs = 1 + r.rand(299)
            let outputs = 2 + r.rand(198)
            let s = r.sparseDense(inputs, outputs, density, bias, relu, emptyRows = [0.0, 0.3, 1.0][k])
            if s.params[4] == 0: inc zeroNnz
            for o in 0..<outputs:
              if s.extra[o] == s.extra[o+1]: inc emptyRowsSeen
            let actor = loadActor(encode2(inputs, [outputs], [s]))
            check actor.operationCount == sparseDenseOps(outputs, s.params[4].int, bias, relu)
            check actor.parameterCount == s.params[4].int + (if bias: outputs else: 0)
            for t in 0..<4:
              let obs = r.wideObservation(inputs)
              check bits(actor.run(obs)) == bits(sparse32(obs, s))
            inc trials
    check trials == 60 and zeroNnz >= 12 and emptyRowsSeen > 100
    # A row with no entries is act(b) (0 without bias); a layer with nnz 0 is act(b) everywhere.
    let empty = sparseDenseCsr(5, 3, @[0'u32, 0, 0, 0], @[], @[], @[0.5'f32, -0.25, 2], relu = true)
    check loadActor(encode2(5, [3], [empty])).run(@[1'f32, 2, 3, 4, 5]) == @[0.5'f32, 0, 2]
    let none = sparseDenseCsr(5, 2, @[0'u32, 0, 0], @[], @[])
    check bits(loadActor(encode2(5, [2], [none])).run(@[1'f32, -2, 3, 4, 5])) == @[0'u32, 0]
    # Two in a row, the second reading the first's relu output.
    let a = r.sparseDense(40, 30, 0.2, bias = true, relu = true, emptyRows = 0.2)
    let b = r.sparseDense(30, 6, 0.5, bias = true)
    let chain = loadActor(encode2(40, [3, 3], [a, b]))
    for t in 0..<10:
      let obs = r.wideObservation(40)
      check bits(chain.run(obs)) == bits(sparse32(sparse32(obs, a), b))

  test "SPARSE_DENSE equals the DENSE with the same nonzeros, bit for bit":
    # SPARSE_DENSE sums its stored entries in ascending column order: DENSE's order with the absent columns left out.
    # In DENSE those columns add x*0 = +-0 (x finite) to a sum that starts at +0.0, which never changes an FP32 sum:
    check bits([0'f32 + -0'f32, 0'f32 + 0'f32]) == @[0'u32, 0]
    for s in [1.5'f32, -1.5, 1e-38, -3e38]:
      check bits([s + -0'f32, s + 0'f32]) == bits([s, s])
    var r = initRand(172)
    var zeroTerms = 0
    for trial in 0..<40:
      let inputs = 1 + r.rand(255)
      let outputs = 2 + r.rand(126)
      let s = r.sparseDense(inputs, outputs, [0.0, 0.05, 0.3, 0.9, 1.0][trial mod 5], r.rand(1) == 1, r.rand(1) == 1,
        emptyRows = 0.1)
      let d = denseOf(s)
      zeroTerms += inputs*outputs - s.params[4].int
      let sparseActor = loadActor(encode2(inputs, [outputs], [s]))
      let denseActor = loadActor(encode2(inputs, [outputs], [d]))
      # The cost: DENSE's count for the same widths, or (fully stored) DENSE's plus one per row.
      check sparseActor.operationCount ==
        denseActor.operationCount - 2*int64(inputs*outputs) + 2*int64(s.params[4]) + int64(outputs)
      for t in 0..<5:
        let obs = r.wideObservation(inputs)
        check bits(sparseActor.run(obs)) == bits(denseActor.run(obs))
    check zeroTerms > 100_000
    # Inside a recurrent stack the state agrees too, tick after tick.
    let s1 = r.sparseDense(64, 32, 0.15, bias = true, relu = true)
    let s2 = r.sparseDense(32, 9, 0.4, bias = true)
    let g = r.mingru(32, 32, highway = true)
    let sparseNet = loadActor(encode2(64, [4, 5], [s1, g, s2]))
    let denseNet = loadActor(encode2(64, [4, 5], [denseOf(s1), g, denseOf(s2)]))
    var sa = newSeq[float32](sparseNet.stateSize)
    var sb = newSeq[float32](denseNet.stateSize)
    var la, lb = newSeq[float32](9)
    for t in 0..<50:
      let obs = r.wideObservation(64)
      sparseNet.infer(obs, sa, la)
      denseNet.infer(obs, sb, lb)
      check bits(la) == bits(lb) and bits(sa) == bits(sb)

  test "a model mixing SPARSE_DENSE with token, recurrent and delay layers: loads, runs, costs the published count":
    # The same shape as test_neural_package.py's test_sparse_dense_cost_and_structure (staging's count).
    var r = initRand(173)
    let specs = @[r.tokenMlp(6, [[0'u32, 8, 8], [48'u32, 0, 8]], 0, 0, [10]),   # 0: 20
      concat(48, 8),                                                            # 1: 28
      r.patternSparse(28, 24, bias = true, relu = true),                         # 2: 24
      r.mingru(24, 16, highway = false, bias = true),                           # 3: 16
      delay(0, 4, r.weights(4, 0.1)),                                           # 4: 20
      r.patternSparse(20, 9, bias = true, relu = false),                        # 5: 9
      r.pointerHead(0, 2, 10)]                                                  # 6: logits 2..7
    let (_, cols1) = patternCsr(28, 24)
    let (_, cols2) = patternCsr(20, 9)
    check (cols1.len, cols2.len) == (118, 32)
    let actor = loadActor(encode2(56, [4, 5], specs))
    let published = tokenMlpOps(6, [16, 10]) + 8 + sparseDenseOps(24, 118, true, true) +
      (2*24*2*16 + 2*16 + 32*16) + 4 + sparseDenseOps(9, 32, true, false) + pointerOps(6, 10, 9)
    check sparseDenseOps(24, 118, true, true) == 2*118 + 3*24
    check actor.operationCount == published
    check actor.operationCount == 4_903   # test_neural_package.py asserts the same count from staging
    check actor.stateSize == 16 + 5
    var state = newSeq[float32](actor.stateSize)
    var logits = newSeq[float32](9)
    for t in 0..<20:
      var obs = r.wideObservation(56)
      for n in 0..<6: obs[8*n] = float32(n != 2)
      actor.infer(obs, state, logits)
      for x in logits: check x == x

  test "the loader checks SPARSE_DENSE's params and CSR structure":
    let good = sparseDenseCsr(6, 3, @[0'u32, 2, 2, 5], @[1'u32, 4, 0, 2, 5], @[1'f32, 2, 3, 4, 5], @[0.1'f32, 0.2, 0.3])
    discard loadActor(encode2(6, [3], [good]))
    proc with(change: proc (s: var Spec)): string =
      var s = good
      change(s)
      encode2(6, [3], [s])
    check rejects(with(proc (s: var Spec) = s.extra[0] = 1), "rowStart[0] must be 0")
    check rejects(with(proc (s: var Spec) = s.extra[2] = 1), "rowStart must not decrease")
    check rejects(with(proc (s: var Spec) = s.extra[3] = 4), "rowStart[out] 4 != nnz 5")
    check rejects(with(proc (s: var Spec) = s.extra[3] = 6), "rowStart 3 exceeds nnz 5")
    check rejects(with(proc (s: var Spec) = s.extra[4 + 1] = 6), "column 6 outside the input width 6")
    check rejects(with(proc (s: var Spec) = s.extra[4 + 1] = 1), "columns must strictly increase within row 0")
    check rejects(with(proc (s: var Spec) = s.extra[4 + 3] = 0), "columns must strictly increase within row 2")
    check rejects(with(proc (s: var Spec) = s.tensors[1] = Inf.float32), "nonfinite neural weight")
    check rejects(with(proc (s: var Spec) = s.tensors[6] = NaN.float32), "nonfinite neural weight")
    check rejects(with(proc (s: var Spec) = s.params[0] = 5), "SPARSE_DENSE input 5 != width 6")
    check rejects(with(proc (s: var Spec) = s.params[1] = 0), "SPARSE_DENSE output must be")
    check rejects(with(proc (s: var Spec) = s.params[2] = 2), "parameter 2 must be 0 or 1")
    check rejects(with(proc (s: var Spec) = s.params[3] = 2), "parameter 3 must be 0 or 1")
    check rejects(with(proc (s: var Spec) = s.params[4] = 4_194_305), "SPARSE_DENSE nnz must be 0..4194304")
    check rejects(with(proc (s: var Spec) = s.params[5] = 1), "unused parameter 5")
    check rejects(with(proc (s: var Spec) = s.params[7] = 1), "unused parameter 7")
    check rejects(with(proc (s: var Spec) = s.params[4] = 6), "")      # the payload no longer matches nnz
    check rejects(with(proc (s: var Spec) = s.tensors.setLen(7)), "truncated")
    check rejects(encode2(6, [3], [good]) & "\0\0\0\0", "trailing bytes")
    check rejects(with(proc (s: var Spec) = s.extra.setLen(3)), "")

type RefSlot = object
  ## The reference's state for one DELAY or RECALL layer: the stored slice and the primed flag.
  m: seq[float32]
  primed: bool

proc refRun(specs: openArray[Spec], obs: seq[float32], slots: var seq[RefSlot]): seq[float32] =
  ## neural_actor.md's SPARSE_DENSE, DELAY and RECALL straight from the spec's words. A DELAY or RECALL layer
  ## outputs [x, prev], prev = init unless primed, else the stored slice. DELAY stores its own input's slice; a
  ## RECALL's slice [y_source[offset ..< offset+len], 1] is stored when layer `source` runs. Staged, then committed.
  if slots.len == 0: slots = newSeq[RefSlot](specs.len)
  var staged = slots
  var outs: seq[seq[float32]]
  var x = obs
  for k, s in specs:
    var y: seq[float32]
    case s.code
    of 17: y = sparse32(x, s)
    of 16, 18:
      let n = (if s.code == 16: s.params[1].int else: s.params[2].int)
      y = x
      for i in 0..<n: y.add(if slots[k].primed: slots[k].m[i] else: s.tensors[i])
      if s.code == 16:
        staged[k] = RefSlot(m: x[s.params[0].int ..< s.params[0].int + n], primed: true)
    else: doAssert false, "reference: unsupported layer " & $s.code
    outs.add y
    for j, other in specs:
      if other.code == 18 and other.params[0].int == k:
        let off = other.params[1].int
        staged[j] = RefSlot(m: y[off ..< off + other.params[2].int], primed: true)
    x = y
  slots = staged
  x

proc refState(specs: openArray[Spec], slots: seq[RefSlot]): seq[float32] =
  ## The engine's state layout: each DELAY / RECALL slice in layer order, m then the primed flag.
  for k, s in specs:
    if s.code in [16'u32, 18]:
      let n = (if s.code == 16: s.params[1].int else: s.params[2].int)
      for i in 0..<n: result.add(if slots[k].primed: slots[k].m[i] else: 0'f32)
      result.add(if slots[k].primed: 1'f32 else: 0'f32)

suite "PWNET002 RECALL (layer 18): the previous inference's slice of a later layer":
  test "the engine equals a float32 reimplementation, bit for bit, over ticks with resets":
    var r = initRand(181)
    # A: SPARSE_DENSE -> RECALL (1 later) -> SPARSE_DENSE -> RECALL (3 later) -> SPARSE_DENSE -> RECALL (1 later,
    #    the same source as layer 3) -> SPARSE_DENSE (the source: the logits).
    let a = @[r.sparseDense(12, 10, 0.5, bias = true, relu = true),       # 0: 10
      recall(2, 3, 4, r.weights(4, 0.5)),                                 # 1: 14, reads layer 2 [3 ..< 7]
      r.sparseDense(14, 16, 0.4, bias = true, relu = true),               # 2: 16
      recall(6, 0, 5, r.weights(5, 0.5)),                                 # 3: 21, reads layer 6 [0 ..< 5]
      r.sparseDense(21, 18, 0.4, bias = true, relu = true),               # 4: 18
      recall(6, 2, 7, r.weights(7, 0.5)),                                 # 5: 25, reads layer 6 [2 ..< 9]
      r.sparseDense(25, 9, 0.5, bias = true)]                             # 6: logits 9
    # B: RECALL as layer 0 reading the last layer (the compiled-program shape: state read first, written last),
    #    a DELAY between (its state interleaves in layer order) and a RECALL of the DELAY layer itself.
    let b = @[recall(5, 1, 6, r.weights(6, 0.5)),                         # 0: 8 + 6 = 14, reads layer 5 [1 ..< 7]
      r.sparseDense(14, 12, 0.5, bias = true, relu = true),               # 1: 12
      delay(2, 3, r.weights(3, 0.5)),                                     # 2: 15
      recall(4, 0, 15, r.weights(15, 0.5)),                               # 3: 30, reads layer 4 (all of it)
      r.sparseDense(30, 20, 0.3, bias = true, relu = true),               # 4: 20
      r.sparseDense(20, 9, 0.5, bias = true)]                             # 5: logits 9
    for (inputs, specs) in [(12, a), (8, b)]:
      let actor = loadActor(encode2(inputs, [4, 5], specs))
      var expectState = 0
      for s in specs:
        if s.code == 16: expectState += s.params[1].int + 1
        if s.code == 18: expectState += s.params[2].int + 1
      check actor.stateSize == expectState
      var state = newSeq[float32](actor.stateSize)
      var logits = newSeq[float32](9)
      var slots: seq[RefSlot]
      var ticks = 0
      for t in 0..<120:
        if t mod 17 == 0:
          for v in state.mitems: v = 0'f32   # the host's reset: zero the whole state
          slots = @[]
        let obs = r.observation(inputs)
        actor.infer(obs, state, logits)
        let want = refRun(specs, obs, slots)
        check bits(logits) == bits(want)
        check bits(state) == bits(refState(specs, slots))
        inc ticks
      check ticks == 120

  test "RECALL carries a late value to an early layer: a counter, and prev = init after a reset":
    # Layer 1 (SPARSE_DENSE, the source) outputs [x0, x1, prev0 + 1, 2*prev1]; layer 0 RECALLs its [2 ..< 4].
    # Tick t after a reset (t = 1, 2, ...): prev = (t - 1, 2^(t-1)), so the logits are [x0, x1, t, 2^t].
    let sd = sparseDenseCsr(4, 4, @[0'u32, 1, 2, 3, 4], @[0'u32, 1, 2, 3], @[1'f32, 1, 1, 2], @[0'f32, 0, 1, 0])
    let actor = loadActor(encode2(2, [2, 2], [recall(1, 2, 2, @[0'f32, 1]), sd]))
    check actor.stateSize == 3 and actor.operationCount == 2 + sparseDenseOps(4, 4, true, false)
    var state = newSeq[float32](3)
    var logits = newSeq[float32](4)
    for round in 0..<2:
      for t in 1..6:
        actor.infer(@[0.25'f32, -3], state, logits)
        check logits == @[0.25'f32, -3, float32(t), float32(1 shl t)]
        check state == @[float32(t), float32(1 shl t), 1]
      for v in state.mitems: v = 0'f32   # reset: the next tick reads init again
    # The recalled value feeds the next SPARSE_DENSE, so it changes the logits: same observation, different prev.
    var r = initRand(182)
    let specs = @[r.sparseDense(6, 8, 0.6, bias = true, relu = true), recall(3, 0, 4, @[0'f32, 0, 0, 0]),
      r.sparseDense(12, 10, 0.6, bias = true, relu = true), r.sparseDense(10, 4, 0.8, bias = true)]
    let net = loadActor(encode2(6, [2, 2], specs))
    var st = newSeq[float32](net.stateSize)
    var first, second = newSeq[float32](4)
    let obs = r.observation(6)
    net.infer(obs, st, first)
    check st[4] == 1'f32 and st[0 ..< 4] == first
    net.infer(obs, st, second)
    check bits(first) != bits(second)
    for v in st.mitems: v = 0'f32
    net.infer(obs, st, second)
    check bits(first) == bits(second)

  test "a failed inference commits no RECALL state":
    let sd = sparseDenseCsr(4, 4, @[0'u32, 1, 2, 3, 4], @[0'u32, 1, 2, 3], @[1'f32, 1, 1, 2], @[0'f32, 0, 1, 0])
    let actor = loadActor(encode2(2, [2, 2], [recall(1, 2, 2, @[0'f32, 1]), sd]))
    var state = @[5'f32, 3e38, 1]   # 2*prev1 overflows to +Inf in layer 1
    var logits = @[7'f32, 7, 7, 7]
    expect ValueError: actor.infer(@[1'f32, 1], state, logits)
    check state == @[5'f32, 3e38, 1] and logits == @[7'f32, 7, 7, 7]

  test "a model mixing RECALL with sparse, recurrent and delay layers costs the published count":
    # The same shape as test_neural_package.py's test_recall_cost_and_structure (staging's count).
    var r = initRand(183)
    let specs = @[r.patternSparse(20, 16, bias = true, relu = true),   # 0: 16
      recall(5, 1, 6, r.weights(6, 0.1)),                              # 1: 22
      r.mingru(22, 12, highway = false, bias = true),                  # 2: 12
      recall(4, 0, 2, r.weights(2, 0.1)),                              # 3: 14, reads the DELAY layer
      delay(0, 4, r.weights(4, 0.1)),                                  # 4: 18
      r.patternSparse(18, 9, bias = true, relu = false)]               # 5: logits 9
    let (_, cols1) = patternCsr(20, 16)
    let (_, cols2) = patternCsr(18, 9)
    let actor = loadActor(encode2(20, [4, 5], specs))
    let published = sparseDenseOps(16, cols1.len, true, true) + 6 + (2*22*2*12 + 2*12 + 32*12) + 2 + 4 +
      sparseDenseOps(9, cols2.len, true, false)
    check (cols1.len, cols2.len) == (56, 29)
    check actor.operationCount == published
    check actor.operationCount == 1_712   # test_neural_package.py asserts the same count from staging
    check actor.stateSize == 7 + 12 + 3 + 5
    check actor.parameterCount == cols1.len + 16 + 6 + (2*12*22 + 2*12) + 2 + 4 + cols2.len + 9
    var state = newSeq[float32](actor.stateSize)
    var logits = newSeq[float32](9)
    for t in 0..<20:
      actor.infer(r.observation(20), state, logits)
      for x in logits: check x == x

  test "the loader checks RECALL's source, slice, len, params, state and width":
    var r = initRand(184)
    let d0 = r.dense(6, 6, bias = true)
    let d2 = r.dense(10, 5)
    let good = @[d0, recall(2, 1, 4, @[1'f32, 2, 3, 4]), d2]   # 6 -> 6 -> 10 -> 5
    discard loadActor(encode2(6, [2, 3], good))
    proc with(change: proc (s: var Spec)): string =
      var specs = good
      change(specs[1])
      encode2(6, [2, 3], specs)
    check rejects(with(proc (s: var Spec) = s.params[0] = 1), "RECALL source 1 must be a later layer (2..2)")
    check rejects(with(proc (s: var Spec) = s.params[0] = 0), "RECALL source 0 must be a later layer")
    check rejects(with(proc (s: var Spec) = s.params[0] = 3), "RECALL source 3 must be a later layer")
    check rejects(with(proc (s: var Spec) = s.params[0] = 4_000_000_000'u32), "must be a later layer")
    check rejects(with(proc (s: var Spec) = s.params[1] = 2), "RECALL slice outside the source's width 5")
    check rejects(with(proc (s: var Spec) = s.params[1] = 6), "RECALL slice outside the source's width 5")
    check rejects(with(proc (s: var Spec) = s.params[1] = 0xF000_0000'u32), "RECALL slice outside")
    check rejects(with(proc (s: var Spec) = (s.params[2] = 0; s.tensors = @[])), "RECALL len must be 1..4096")
    check rejects(with(proc (s: var Spec) = s.params[3] = 1), "unused parameter 3")
    check rejects(with(proc (s: var Spec) = s.params[7] = 1), "unused parameter 7")
    check rejects(with(proc (s: var Spec) = s.tensors[2] = NaN.float32), "nonfinite neural weight")
    check rejects(with(proc (s: var Spec) = s.tensors[0] = Inf.float32), "nonfinite neural weight")
    check rejects(with(proc (s: var Spec) = s.tensors.setLen(3)), "")   # the payload no longer matches len
    check rejects(encode2(6, [2, 3], good) & "\0\0\0\0", "trailing bytes")
    # State: len 4096 needs 4097 floats; with a DELAY's 101, len 3995 needs 4097 too.
    check rejects(encode2(6, [2, 2], [recall(1, 0, 4096, newSeq[float32](4096)), r.dense(4102, 4)]),
      "recurrent state exceeds 4096")
    check rejects(encode2(101, [2, 2], [delay(0, 100, newSeq[float32](100)),
      recall(2, 0, 3995, newSeq[float32](3995)), r.dense(4196, 4)]), "recurrent state exceeds 4096")
    # Output: state 4001 is fine, but 100 + 4000 > 4096.
    check rejects(encode2(100, [2, 2], [recall(1, 0, 4000, newSeq[float32](4000)), r.dense(4100, 4)]),
      "RECALL output exceeds 4096")
    discard loadActor(encode2(96, [2, 2], [recall(1, 0, 4, newSeq[float32](4)), r.dense(100, 4)]))
    # The source must not be a COND_HEAD (it would be the stack's last layer, a pass-through declaration).
    check rejects(encode2(4, [2, 2], [recall(2, 0, 2, @[0'f32, 0]), r.dense(6, 4), condHead(0, 1, newSeq[float32](4))]),
      "RECALL source 2 is a COND_HEAD")
    discard loadActor(encode2(4, [2, 2], [recall(1, 0, 2, @[0'f32, 0]), r.dense(6, 4), condHead(0, 1, newSeq[float32](4))]))
