## PWNET002 (neural_actor.nim): loader validation, the published operation count, the
## PWNET001 identity (a PWNET001 actor re-encoded as DENSE -> MINGRU highway -> DENSE runs
## bit for bit the same), every layer type, no allocation during inference, and the hosted
## seat running a PWNET002 package. Synthetic weights only.
import std/[unittest, os, random, strutils, math, sequtils]
import polyworld/cli
import ../examples/paintbot/[bots, sim, neural_contract, neural_host, neural_actor]
import paintbot_pwnet2_fixture

proc rejects(data: string, fragment = ""): bool =
  try:
    discard loadActor(data)
    false
  except ValueError as e:
    fragment.len == 0 or fragment in e.msg

suite "PWNET002 actor":
  test "a PWNET001 actor re-encoded as DENSE -> MINGRU highway -> DENSE is bit-identical":
    var r = initRand(20260925)
    for (inputs, hidden) in [(448, 64), (506, 128), (448, 256), (17, 64)]:
      let (v1, e, rec, dec) = r.pwnet001(inputs, hidden)
      let v2 = encode2(inputs, ActionSizes, [
        Spec(code: 1, params: [inputs.uint32, hidden.uint32, 0, 0, 0, 0, 0, 0], tensors: e),
        Spec(code: 3, params: [hidden.uint32, hidden.uint32, 1, 0, 0, 0, 0, 0], tensors: rec),
        Spec(code: 1, params: [hidden.uint32, LogitSize.uint32, 0, 0, 0, 0, 0, 0], tensors: dec)])
      let a = loadActor(v1)
      let b = loadActor(v2)
      check a.actorFormat == 1 and b.actorFormat == 2
      check a.operationCount == b.operationCount
      check b.stateSize == hidden and b.modelTag == "pwnet2-l3-s" & $hidden and a.modelTag == "w" & $hidden
      var sa = newSeq[float32](hidden)
      var sb = newSeq[float32](hidden)
      var la = newSeq[float32](LogitSize)
      var lb = newSeq[float32](LogitSize)
      for step in 0..<200:
        if step mod 37 == 0:
          for i in 0..<hidden:
            sa[i] = 0; sb[i] = 0
        let obs = r.observation(inputs)
        a.infer(obs, sa, la)
        b.infer(obs, sb, lb)
        check bits(la) == bits(lb)
        check bits(sa) == bits(sb)

  test "the published operation count":
    var r = initRand(7)
    let net = loadActor(encode2(506, ActionSizes, [
      r.dense(506, 64, bias = true, relu = true),           # 2*506*64 + 64 + 64
      r.rmsnorm(64),                                        # 4*64 + 16
      r.mingru(64, 64, highway = true, bias = true),        # 2*64*192 + 192 + 32*64
      r.mingru(64, 32, highway = false),                    # 2*64*64 + 32*32
      concat(0, 24),                                      # 24
      r.dense(56, 56),                                      # 2*56*56
      residual(5),                                          # 56
      r.dense(56, LogitSize)]))                             # 2*56*82
    let expected = 2*506*64 + 64 + 64 + 4*64 + 16 + 2*64*192 + 192 + 32*64 + 2*64*64 + 32*32 + 24 +
      2*56*56 + 56 + 2*56*82
    check net.operationCount == expected
    check net.stateSize == 96
    # ENTITY_ATTN: T tokens, d, h heads, F, P passthrough (neural_actor.md).
    let (T, d, h, F, P) = (26, 64, 4, 64, 24)
    let attn = r.attention([[24'u32, 8, 10, 8, 0], [104'u32, 8, 16, 8, 0]], d, h, 2, F, 0, P)
    let tnet = loadActor(encode2(506, ActionSizes, [attn, r.dense(2*d+P, LogitSize)]))
    let embed = 26*(2*8*d + d)
    let perBlock = 2*T*(4*d + 16) + T*(6*d*d + 3*d) + T*T*(4*d + 13*h) + 8*h*T + T*(2*d*d + d) + T*d +
      T*(2*d*F + 2*F) + T*(2*F*d + d) + T*d
    let pool = T + 2*T*d + d + 8 + P
    check tnet.operationCount == embed + 2*perBlock + pool + 2*(2*d+P)*LogitSize
    # The documented example (neural_actor.md): 3,307,774 operations.
    let example = loadActor(encode2(506, ActionSizes, [attn, concat(232, 274),
      r.mingru(426, 128, highway = false, bias = true), r.dense(128, LogitSize, bias = true)]))
    check example.operationCount == 3_307_774

  test "every layer type runs, recurrent state is all MINGRU states in layer order":
    var r = initRand(99)
    let actor = loadActor(encode2(506, ActionSizes, [
      r.attention([[104'u32, 8, 16, 8, 0], [24'u32, 8, 10, 8, AttnAlwaysValid]], 32, 4, 1, 48, 0, 24),
      concat(448, 58),
      r.dense(2*32+24+58, 96, bias = true, relu = true),
      r.rmsnorm(96),
      r.mingru(96, 96, highway = true, bias = true),
      residual(3),
      r.mingru(96, 40, highway = false),
      r.dense(40, LogitSize, bias = true)]))
    check actor.stateSize == 136 and actor.layerCount == 8
    var state = newSeq[float32](136)
    var logits = newSeq[float32](LogitSize)
    for step in 0..<50:
      actor.infer(r.observation(506), state, logits)
      for x in logits: check classify(x) notin {fcNan, fcInf, fcNegInf}
    check state.anyIt(it != 0)

  test "attention masks invalid tokens and pools zeros when none is valid":
    var r = initRand(5)
    let actor = loadActor(encode2(64, [2, 2, 2], [
      r.attention([[0'u32, 8, 8, 8, 0]], 8, 2, 1, 16, 0, 0), r.dense(16, 6)]))
    var state: seq[float32]
    var a, b = newSeq[float32](6)
    var obs = newSeq[float32](64)
    actor.infer(obs, state, a)           # no valid token: pooled zeros, logits zero
    check a == newSeq[float32](6)
    for i in 0..<64: obs[i] = float32(r.rand(2.0) - 1.0)
    for t in 0..<8: obs[8*t] = 0
    obs[8*3] = 1
    actor.infer(obs, state, a)
    # Changing only masked tokens' features changes nothing.
    for t in [0, 1, 2, 4, 5, 6, 7]:
      for c in 1..7: obs[8*t+c] = float32(r.rand(2.0) - 1.0)
    actor.infer(obs, state, b)
    check bits(a) == bits(b)

  test "inference does not allocate":
    var r = initRand(3)
    let actor = loadActor(encode2(506, ActionSizes, [
      r.attention([[104'u32, 8, 16, 8, 0]], 32, 4, 1, 32, 0, 24),
      r.mingru(88, 64, highway = false, bias = true), r.dense(64, LogitSize)]))
    var state = newSeq[float32](64)
    var logits = newSeq[float32](LogitSize)
    let obs = r.observation(506)
    actor.infer(obs, state, logits)
    let before = getOccupiedMem()
    for i in 0..<20: actor.infer(obs, state, logits)
    check getOccupiedMem() == before

  test "loader rejects malformed files cleanly":
    var r = initRand(11)
    let good = encode2(64, [2, 2, 2], [r.dense(64, 16, bias = true), r.mingru(16, 16, true), r.dense(16, 6)])
    discard loadActor(good)
    check rejects(good[0..^2], "truncated")
    check rejects(good & "\0\0\0\0", "trailing")
    for cut in [8, 12, 20, 24, 40, 100, 160, 175, 200]:
      check rejects(good[0..<cut])
    # Header fields.
    var bad = good
    bad[8] = '\3'
    check rejects(bad, "version")
    check rejects(encode2(64, [2, 2, 2], [r.dense(64, 7)]), "last layer width")
    check rejects(encode2(64, [2, 2, 2], [r.dense(63, 6)]), "DENSE input")
    check rejects(encode2(64, [2, 2, 2], []), "layer count")
    var flagged = r.dense(64, 6)
    flagged.params[2] = 2
    check rejects(encode2(64, [2, 2, 2], [flagged]), "must be 0 or 1")
    var unusedSet = r.dense(64, 6)
    unusedSet.params[7] = 1
    check rejects(encode2(64, [2, 2, 2], [unusedSet]), "unused parameter")
    check rejects(encode2(64, [2, 2, 2], [Spec(code: 99)]), "unknown layer type")
    check rejects(encode2(64, [2, 2, 2], [r.mingru(64, 32, highway = true), r.dense(32, 6)]), "highway")
    check rejects(encode2(64, [2, 2, 2], [r.dense(64, 6), residual(1)]), "earlier layer")
    check rejects(encode2(64, [2, 2, 2], [r.dense(64, 5), residual(0)]), "last layer width")
    check rejects(encode2(64, [2, 2, 2], [r.dense(64, 2), concat(60, 5)]), "outside the input")
    check rejects(encode2(64, [2, 2, 2], [r.rmsnorm(64, 0'f32), r.dense(64, 6)]), "eps")
    check rejects(encode2(64, [2, 2, 2], [r.rmsnorm(64, NaN.float32), r.dense(64, 6)]), "eps")
    check rejects(encode2(64, [2, 2, 2], [r.attention([[60'u32, 8, 1, 8, 0]], 8, 2, 1, 8, 0, 0), r.dense(16, 6)]),
      "outside the input")
    check rejects(encode2(64, [2, 2, 2], [r.attention([[0'u32, 8, 8, 8, 8]], 8, 2, 1, 8, 0, 0), r.dense(16, 6)]),
      "valid index")
    check rejects(encode2(64, [2, 2, 2], [r.attention([[0'u32, 8, 8, 8, 0]], 8, 3, 1, 8, 0, 0), r.dense(16, 6)]),
      "heads")
    check rejects(encode2(300, [2, 2, 2], [r.attention([[0'u32, 1, 200, 4, 0], [0'u32, 1, 57, 4, 0]], 8, 2, 1, 8, 0, 0),
      r.dense(16, 6)]), "tokens exceed 256")
    var nonfinite = r.dense(64, 6)
    nonfinite.tensors[5] = Inf.float32
    check rejects(encode2(64, [2, 2, 2], [nonfinite]), "nonfinite")
    check rejects(encode2(64, [2, 2, 2], [r.dense(64, 6)], observationContract = repeat('G', 64)), "contract")
    # Fuzz: random truncations and byte flips either load or raise ValueError, never crash.
    var loaded = 0
    for trial in 0..<3000:
      var data = good
      case trial mod 3
      of 0: data = data[0..<r.rand(data.len-1)]
      of 1:
        for flips in 0..<1+r.rand(3): data[r.rand(data.len-1)] = char(r.rand(255))
      else:
        let at = 8 + 4*r.rand(40)
        if at + 4 <= data.len:
          for i in 0..3: data[at+i] = char(r.rand(255))
      try:
        let a = loadActor(data)
        inc loaded
        var state = newSeq[float32](a.stateSize)
        var logits = newSeq[float32](a.outputSize)
        try: a.infer(newSeq[float32](a.inputSize), state, logits)
        except ValueError: discard
      except ValueError: discard
    check loaded > 0

proc tokenReference(specs: seq[Spec], inputs: int, obs: seq[float32]): seq[float64] =
  ## A float64 reference for TOKEN_MLP -> TOKEN_MIX -> DENSE -> POINTER (layers 0..3), straight from the specs'
  ## words and tensors (neural_actor.md's equations), independent of neural_actor.nim.
  let mlp = specs[0]
  let t = mlp.params[0].int
  let nseg = mlp.params[1].int
  var segs: seq[array[3, int]]
  for g in 0..<nseg: segs.add [mlp.extra[3*g].int, mlp.extra[3*g+1].int, mlp.extra[3*g+2].int]
  var widths = @[0]
  for s in segs: widths[0] += s[2]
  for l in 0..<mlp.params[4].int: widths.add mlp.extra[3*nseg+l].int
  let d = widths[^1]
  var valid = newSeq[bool](t)
  var e = newSeq[seq[float64]](t)
  for n in 0..<t:
    let vs = segs[mlp.params[2].int]
    valid[n] = obs[vs[0] + n*vs[1] + mlp.params[3].int] > 0.5
    var x: seq[float64]
    for s in segs:
      for i in 0..<s[2]: x.add obs[s[0] + n*s[1] + i].float64
    var off = 0
    for l in 1..<widths.len:
      var y = newSeq[float64](widths[l])
      for o in 0..<widths[l]:
        var sum = 0.0
        for i in 0..<widths[l-1]: sum += x[i]*mlp.tensors[off + o*widths[l-1] + i].float64
        y[o] = max(0.0, sum + mlp.tensors[off + widths[l]*widths[l-1] + o].float64)
      off += widths[l]*widths[l-1] + widths[l]
      x = y
    e[n] = if valid[n]: x else: newSeq[float64](d)
  proc pools(rows: seq[seq[float64]], width: int): seq[float64] =
    result = newSeq[float64](2*width)
    var count = 0
    for n in 0..<t:
      if valid[n]: inc count
    if count == 0: return
    for c in 0..<width:
      var total = 0.0
      var best = -Inf
      for n in 0..<t:
        if valid[n]:
          total += rows[n][c]; best = max(best, rows[n][c])
      result[c] = total / count.float64
      result[width+c] = best
  var x = pools(e, d)
  let mix = specs[1]
  let z = mix.params[1].int
  let width = x.len
  var zs = newSeq[seq[float64]](t)
  for n in 0..<t:
    zs[n] = newSeq[float64](z)
    if not valid[n]: continue
    for o in 0..<z:
      var sum = mix.tensors[z*d + o].float64
      for i in 0..<d: sum += e[n][i]*mix.tensors[o*d+i].float64
      for i in 0..<width: sum += x[i]*mix.tensors[z*d + z + o*width + i].float64
      zs[n][o] = max(0.0, sum)
  x = x & pools(zs, z)
  let den = specs[2]
  let o2 = den.params[1].int
  var y = newSeq[float64](o2)
  for o in 0..<o2:
    var sum = den.tensors[o2*x.len + o].float64
    for i in 0..<x.len: sum += x[i]*den.tensors[o*x.len+i].float64
    y[o] = sum
  let ptrSpec = specs[3]
  let offset = ptrSpec.params[1].int
  for n in 0..<t:
    if not valid[n]: continue
    var sum = ptrSpec.tensors[z].float64
    for i in 0..<z: sum += zs[n][i]*ptrSpec.tensors[i].float64
    y[offset+n] += sum
  y

suite "PWNET002 token layers (TOKEN_MLP, TOKEN_MIX, POINTER)":
  proc small(r: var Rand): seq[Spec] =
    ## 64 inputs: 5 tokens of 6 floats at stride 8 (flag at +0) plus a shared 3-float slice; heads [2, 2, 2, 3].
    @[r.tokenMlp(5, [[0'u32, 8, 6], [50'u32, 0, 3]], 0, 0, [8, 5]),
      r.tokenMix(0, 5, 10, 4),
      r.dense(18, 9, bias = true),
      r.pointerHead(1, 3, 4)]

  test "the published operation count (an entity-factored actor: 1,327,278)":
    var r = initRand(71)
    let a = loadActor(encode2(538, ActionSizes, r.entityFactored()))
    let (T, din, d, z, H, I) = (16, 38, 128, 64, 128, 538)
    let tokenMlp = T*din + T*(2*din*d + 2*d) + T*(2*d*d + 2*d) + (T + 2*T*d + d + 8)
    let tokenMix = 2*H*z + H + T*(2*d*z + 3*z) + (T + 2*T*z + z + 8)
    let pointerOps = LogitSize + T*(2*z + 2)
    let expected = tokenMlp + I + 2*(2*d + I)*H + (2*H*3*H + 32*H) + tokenMix + (2*(H + 2*z)*LogitSize + LogitSize) +
      pointerOps
    check a.operationCount == expected
    check expected == 1_327_278
    check a.stateSize == 128 and a.layerCount == 7 and a.modelTag == "pwnet2-l7-s128"

  test "token layers equal a float64 reference, masked tokens included":
    var r = initRand(72)
    for trial in 0..<40:
      let specs = r.small()
      let actor = loadActor(encode2(64, [2, 2, 2, 3], specs))
      var state: seq[float32]
      var logits = newSeq[float32](9)
      var obs = r.observation(64)
      for n in 0..<5: obs[8*n] = float32(r.rand(1))
      if trial == 0:
        for n in 0..<5: obs[8*n] = 0      # no valid token
      actor.infer(obs, state, logits)
      let want = tokenReference(specs, 64, obs)
      for i in 0..<9: check abs(logits[i].float64 - want[i]) <= 1e-5 * max(1.0, abs(want[i]))

  test "a masked token's features change nothing; the shared slice reaches every token":
    var r = initRand(73)
    let actor = loadActor(encode2(64, [2, 2, 2, 3], r.small()))
    var state: seq[float32]
    var a, b = newSeq[float32](9)
    var obs = r.observation(64)
    for n in 0..<5: obs[8*n] = 0
    actor.infer(obs, state, a)
    # No valid token: the pools are zero and the pointer adds nothing, so only the DENSE bias remains.
    var none = newSeq[float32](64)
    actor.infer(none, state, b)
    check bits(a) == bits(b)
    obs[8*2] = 1
    actor.infer(obs, state, a)
    for n in [0, 1, 3, 4]:
      for c in 1..5: obs[8*n+c] = float32(r.rand(2.0) - 1.0)
    obs[60] = 0.25                        # outside every segment
    actor.infer(obs, state, b)
    check bits(a) == bits(b)
    obs[51] = obs[51] + 0.5               # the shared slice
    actor.infer(obs, state, b)
    check bits(a) != bits(b)

  test "an entity-factored actor runs recurrently and does not allocate":
    var r = initRand(74)
    let actor = loadActor(encode2(538, ActionSizes, r.entityFactored()))
    var state = newSeq[float32](128)
    var logits = newSeq[float32](LogitSize)
    var obs = r.observation(538)
    for step in 0..<30:
      obs = r.observation(538)
      actor.infer(obs, state, logits)
      for x in logits: check classify(x) notin {fcNan, fcInf, fcNegInf}
    check state.anyIt(it != 0)
    let before = getOccupiedMem()
    for i in 0..<20: actor.infer(obs, state, logits)
    check getOccupiedMem() == before

  test "loader rejects malformed token layers":
    var r = initRand(75)
    let good = r.small()
    discard loadActor(encode2(64, [2, 2, 2, 3], good))
    proc with(specs: seq[Spec], k: int, change: proc (s: var Spec)): string =
      var v = specs
      change(v[k])
      encode2(64, [2, 2, 2, 3], v)
    check rejects(good.with(0, proc (s: var Spec) = s.params[0] = 0), "tokens")
    check rejects(good.with(0, proc (s: var Spec) = s.params[0] = 257), "tokens")
    check rejects(good.with(0, proc (s: var Spec) = s.params[0] = 9), "outside the input")
    check rejects(good.with(0, proc (s: var Spec) = s.params[2] = 2), "valid flag")
    check rejects(good.with(0, proc (s: var Spec) = s.params[3] = 6), "valid flag")
    check rejects(good.with(0, proc (s: var Spec) = (s.params[2] = AttnAlwaysValid; s.params[3] = 1)), "valid index 0")
    check rejects(good.with(0, proc (s: var Spec) = s.params[5] = 1), "unused parameter")
    check rejects(good.with(0, proc (s: var Spec) = s.extra[2] = 0), "length/stride")
    check rejects(good.with(0, proc (s: var Spec) = s.extra[1] = 65), "length/stride")
    check rejects(good.with(0, proc (s: var Spec) = s.extra[6] = 300), "widths")
    check rejects(encode2(200, [2, 2, 2, 3], @[r.tokenMlp(1, [[0'u32, 0, 200], [0'u32, 0, 200], [0'u32, 0, 200],
      [0'u32, 0, 200], [0'u32, 0, 200], [0'u32, 0, 200]], 0, 0, [4]), r.dense(8, 9)]), "token input")
    check rejects(good.with(1, proc (s: var Spec) = s.params[0] = 1), "earlier TOKEN_MLP")
    check rejects(good.with(1, proc (s: var Spec) = s.params[1] = 0), "TOKEN_MIX width")
    check rejects(good.with(3, proc (s: var Spec) = s.params[0] = 2), "earlier TOKEN_MIX")
    check rejects(good.with(3, proc (s: var Spec) = s.params[1] = 5), "exceeds width")
    check rejects(encode2(64, [2, 2, 2, 3], @[r.dense(64, 18), r.tokenMix(0, 5, 18, 4), r.dense(26, 9)]),
      "earlier TOKEN_MLP")
    var short = good
    short[3].tensors.setLen(3)
    check rejects(encode2(64, [2, 2, 2, 3], short))
    # Fuzz: corrupted token-layer files load or raise ValueError, never crash.
    let data = encode2(64, [2, 2, 2, 3], good)
    for trial in 0..<2000:
      var d = data
      if trial mod 2 == 0: d = d[0..<r.rand(d.len-1)]
      else:
        let at = 8 + 4*r.rand(min(120, (d.len-12) div 4))
        for i in 0..3: d[at+i] = char(r.rand(255))
      try:
        let a = loadActor(d)
        var state = newSeq[float32](a.stateSize)
        var logits = newSeq[float32](a.outputSize)
        try: a.infer(newSeq[float32](a.inputSize), state, logits)
        except ValueError: discard
      except ValueError: discard

suite "PWNET002 SEGMENT_NEAR (the input view)":
  # A 40-input stack whose only layer is SEGMENT_NEAR: the logits are the view itself. Four tokens of 8 floats at 0
  # (valid +0, x +1, z +2, candidate +3, exclude +6), scale_x 2, scale_z 4 (vx = 2x, vz = 4z, exact), radius 1,
  # flags at 32, 34, 36, 38.
  proc near40(radius = 1'f32, tokens = 4, dst = 32, dstStride = 2): Spec =
    segmentNear(tokens, 0, 8, 1, 2, 0, 6, 3, 2, 4, radius, dst, dstStride)
  type Tok = tuple[valid, x, z, cand, excl: float32]
  proc scene(tokens: openArray[Tok]): seq[float32] =
    result = newSeq[float32](40)
    for i in 0..<40: result[i] = 0.375                     # every other float, dst included
    for n, t in tokens:
      result[8*n] = t.valid; result[8*n+1] = t.x; result[8*n+2] = t.z
      result[8*n+3] = t.cand; result[8*n+6] = t.excl
  proc view(spec: Spec, obs: seq[float32]): seq[float32] =
    let actor = loadActor(encode2(40, [20, 20], [spec]))
    var state: seq[float32]
    result = newSeq[float32](40)
    actor.infer(obs, state, result)
  proc flags(spec: Spec, obs: seq[float32]): seq[float32] =
    let y = view(spec, obs)
    for i in 0..<40:
      if i notin [32, 34, 36, 38]: doAssert cast[uint32](y[i]) == cast[uint32](obs[i]), "copy at " & $i
    @[y[32], y[34], y[36], y[38]]
  const
    Off: Tok = (0'f32, 0'f32, 0'f32, 0'f32, 0'f32)
    Target: Tok = (1'f32, 4'f32, 0'f32, 0'f32, 0'f32)     # vx 8, vz 0: L2 = 64

  test "the published operation count: I + 12*T*T + 8*T":
    check loadActor(encode2(40, [20, 20], [near40()])).operationCount == 40 + 12*16 + 8*4
    check segmentNearOps(538, 16) == 3738
    var r = initRand(81)
    let base = r.entityFactored()
    let a = loadActor(encode2(538, ActionSizes, base))
    let b = loadActor(encode2(538, ActionSizes, base.shifted(identityNear(522))))
    check a.operationCount == 1_327_278
    check b.operationCount == 1_331_016 and b.operationCount - a.operationCount == 538 + 12*16*16 + 8*16
    check b.layerCount == 8 and b.stateSize == 128 and b.modelTag == "pwnet2-l8-s128"

  test "hand-computed geometry: d = 0, d = L2, distance = radius, behind, beyond":
    let s = near40()
    # A candidate beside the origin (d = 0) at exactly the radius; a candidate's own flag is 1 (m = n).
    check flags(s, scene([Target, (1'f32, 0'f32, 0.25'f32, 1'f32, 0'f32), Off, Off])) == @[1'f32, 1, 0, 0]
    # Beside the target (d = L2) at exactly the radius, and halfway along at exactly the radius.
    check flags(s, scene([Target, (1'f32, 4'f32, 0.25'f32, 1'f32, 0'f32), Off, Off])) == @[1'f32, 1, 0, 0]
    check flags(s, scene([Target, (1'f32, 2'f32, 0.25'f32, 1'f32, 0'f32), Off, Off])) == @[1'f32, 1, 0, 0]
    # Just past the radius, beyond the target (d > L2), behind the origin (d < 0).
    check flags(s, scene([Target, (1'f32, 2'f32, 0.3125'f32, 1'f32, 0'f32), Off, Off])) == @[0'f32, 1, 0, 0]
    check flags(s, scene([Target, (1'f32, 4.25'f32, 0'f32, 1'f32, 0'f32), Off, Off])) == @[0'f32, 1, 0, 0]
    check flags(s, scene([Target, (1'f32, -0.25'f32, 0'f32, 1'f32, 0'f32), Off, Off])) == @[0'f32, 1, 0, 0]
    # A candidate at the origin is on every segment; the negative quadrant; the last candidate decides.
    check flags(s, scene([Target, (1'f32, 0'f32, 0'f32, 1'f32, 0'f32), Off, Off])) == @[1'f32, 0, 0, 0]
    check flags(s, scene([(1'f32, -3'f32, -1.5'f32, 0'f32, 0'f32), (1'f32, -1.5'f32, -0.75'f32, 1'f32, 0'f32), Off,
      Off])) == @[1'f32, 1, 0, 0]
    check flags(s, scene([Target, (1'f32, 0'f32, 2'f32, 1'f32, 0'f32), (1'f32, 3'f32, -0.25'f32, 1'f32, 0'f32),
      (1'f32, 1'f32, 1'f32, 0'f32, 0'f32)])) == @[1'f32, 1, 1, 0]

  test "invalid and excluded tokens, a target at the origin, radius 0":
    let s = near40()
    let onSegment: Tok = (1'f32, 2'f32, 0'f32, 1'f32, 0'f32)
    check flags(s, scene([Target, (1'f32, 2'f32, 0'f32, 0'f32, 0'f32), Off, Off])) == @[0'f32, 0, 0, 0]  # not a candidate
    check flags(s, scene([Target, (0'f32, 2'f32, 0'f32, 1'f32, 0'f32), Off, Off])) == @[0'f32, 0, 0, 0]  # invalid candidate
    check flags(s, scene([Target, (1'f32, 2'f32, 0'f32, 1'f32, 1'f32), Off, Off])) == @[0'f32, 0, 0, 0]  # excluded candidate
    check flags(s, scene([(1'f32, 4'f32, 0'f32, 0'f32, 1'f32), onSegment, Off, Off])) == @[0'f32, 1, 0, 0]  # excluded target
    check flags(s, scene([(0'f32, 4'f32, 0'f32, 0'f32, 0'f32), onSegment, Off, Off])) == @[0'f32, 1, 0, 0]  # invalid target
    check flags(s, scene([(1'f32, 0'f32, 0'f32, 1'f32, 0'f32), (1'f32, 0'f32, 0'f32, 1'f32, 0'f32), Off, Off])) ==
      @[0'f32, 0, 0, 0]                                   # L2 = 0: never flagged
    check flags(s, scene([Target, onSegment, Off, Off])) == @[1'f32, 1, 0, 0]
    let exact = near40(radius = 0)
    check flags(exact, scene([Target, onSegment, Off, Off])) == @[1'f32, 1, 0, 0]
    check flags(exact, scene([Target, (1'f32, 2'f32, 0.0078125'f32, 1'f32, 0'f32), Off, Off])) == @[0'f32, 1, 0, 0]
    # exclude = none: the "exclude" column is an ordinary float.
    let noExclude = segmentNear(4, 0, 8, 1, 2, 0, NoExclude, 3, 2, 4, 1, 32, 2)
    check flags(noExclude, scene([(1'f32, 4'f32, 0'f32, 0'f32, 1'f32), onSegment, Off, Off])) == @[1'f32, 1, 0, 0]
    # One token with dst_stride 0.
    let one = segmentNear(1, 8, 8, 1, 2, 0, 6, 3, 2, 4, 1, 39, 0)
    let y = view(one, scene([Off, (1'f32, 2'f32, 0'f32, 1'f32, 0'f32), Off, Off]))
    check y[39] == 1 and y[32] == 0.375

  test "equals a float64 reference on lattice scenes (exact ties included)":
    var r = initRand(82)
    var positives = 0
    for trial in 0..<3000:
      let radius = [0'f32, 0.5, 1, 2, 3, 8][trial mod 6]
      let s = segmentNear(4, 0, 8, 1, 2, 0, 6, 3, 2, 4, radius, 32, 2)
      var obs = r.observation(40)
      for n in 0..<4:
        obs[8*n] = float32(r.rand(9) < 7)
        obs[8*n+1] = float32(r.rand(16) - 8) / 4
        obs[8*n+2] = float32(r.rand(16) - 8) / 8
        obs[8*n+3] = float32(r.rand(1))
        obs[8*n+6] = float32(r.rand(9) == 0)
      let got = flags(s, obs)
      check got == nearFlagsReference(s, obs)
      for f in got: positives += int(f)
    check positives > 1000 and positives < 3*4000

  test "every later layer reads the view: TOKEN_MLP, CONCAT_INPUT, ENTITY_ATTN, and the current vector":
    var r = initRand(83)
    let near = identityNear(392, radius = 2000)
    let stacks = @[
      @[r.tokenMlp(16, [[104'u32, 8, 8], [392'u32, 1, 1]], 0, 0, [8]), concat(392, 16), r.dense(32, LogitSize)],
      @[r.attention([[104'u32, 8, 16, 8, 0], [392'u32, 1, 16, 1, AttnAlwaysValid]], 8, 2, 1, 8, 390, 20),
        r.dense(36, LogitSize, bias = true)],
      @[r.dense(TeamsViewSize, LogitSize)]]
    for specs in stacks:
      let withView = loadActor(encode2(TeamsViewSize, ActionSizes, specs.shifted(near)))
      let raw = loadActor(encode2(TeamsViewSize, ActionSizes, specs))
      check withView.operationCount == raw.operationCount + segmentNearOps(TeamsViewSize, 16)
      var state: seq[float32]
      var a, b, c = newSeq[float32](LogitSize)
      var differs, positives = 0
      for trial in 0..<200:
        var obs = r.observation(TeamsViewSize)
        r.nearScene(obs)
        let viewed = near.withNearFlags(obs)
        for n in 0..<16: positives += int(viewed[392+n])
        withView.infer(obs, state, a)
        raw.infer(viewed, state, b)
        check bits(a) == bits(b)                          # the view is exactly the reference-flagged observation
        raw.infer(obs, state, c)
        if bits(a) != bits(c): inc differs
      checkpoint "differs " & $differs & " positives " & $positives
      check differs > 150 and positives > 200 and positives < 200*16

  test "loader accepts the edges and rejects malformed SEGMENT_NEAR":
    var r = initRand(84)
    proc net(s: Spec): string = encode2(40, [20, 20], [s])
    proc with(change: proc (s: var Spec)): string =
      var s = near40()
      change(s)
      net(s)
    discard loadActor(net(near40()))
    discard loadActor(net(segmentNear(4, 8, 8, 1, 2, 0, 6, 3, 2, 4, 1, 0, 1)))           # the block ends at I
    discard loadActor(net(near40(dst = 33)))                                            # the last flag at 39
    discard loadActor(net(near40(radius = 0)))
    discard loadActor(with(proc (s: var Spec) = s.params[6] = NoExclude))
    check rejects(encode2(40, [20, 20], [r.dense(40, 40), near40()]), "SEGMENT_NEAR must be layer 0")
    check rejects(encode2(40, [20, 20], [near40(), near40()]), "layer 1: SEGMENT_NEAR must be layer 0")
    check rejects(with(proc (s: var Spec) = s.params[0] = 0), "SEGMENT_NEAR tokens must be 1..256")
    check rejects(encode2(600, [300, 300], [segmentNear(257, 0, 8, 1, 2, 0, 6, 3, 2, 4, 1, 0, 1)]), "tokens must be")
    check rejects(with(proc (s: var Spec) = s.params[2] = 0), "SEGMENT_NEAR stride")
    check rejects(with(proc (s: var Spec) = s.params[1] = 9), "SEGMENT_NEAR tokens outside the input")
    check rejects(with(proc (s: var Spec) = s.params[1] = 41), "outside the input")
    check rejects(with(proc (s: var Spec) = s.params[2] = 11), "outside the input")
    for j in 3..7:
      var s = near40()
      s.params[j] = 8
      check rejects(net(s), "SEGMENT_NEAR index outside the token")
    check rejects(with(proc (s: var Spec) = s.params[6] = 0xFFFF_FFFE'u32), "index outside the token")
    for bad in [0'f32, -1, NaN, Inf, -Inf, -0'f32]:
      for j in 0..1:
        var s = near40()
        s.extra[j] = cast[uint32](bad)
        check rejects(net(s), "SEGMENT_NEAR scales must be finite and positive")
    for bad in [-1'f32, NaN, Inf, -Inf, -1e-30]:
      var s = near40()
      s.extra[2] = cast[uint32](bad)
      check rejects(net(s), "SEGMENT_NEAR radius must be finite and >= 0")
    discard loadActor(with(proc (s: var Spec) = s.extra[2] = cast[uint32](-0'f32)))   # -0 >= 0
    check rejects(net(near40(dst = 34)), "SEGMENT_NEAR flags outside the input")
    check rejects(net(near40(dst = 40)), "flags outside the input")
    check rejects(net(near40(dstStride = 0)), "flags outside the input")
    check rejects(net(near40(dstStride = 41)), "flags outside the input")
    check rejects(net(segmentNear(1, 0, 8, 1, 2, 0, 6, 3, 2, 4, 1, 40, 0)), "flags outside the input")
    let data = net(near40())
    check rejects(data[0..^5], "truncated")
    check rejects(data & "\0\0\0\0", "trailing bytes")
    # Fuzz: corrupted SEGMENT_NEAR files load or raise ValueError, never crash.
    for trial in 0..<2000:
      var d = data
      if trial mod 2 == 0: d = d[0..<r.rand(d.len-1)]
      else:
        let at = d.len - 56 + 4*r.rand(13)
        for i in 0..3: d[at+i] = char(r.rand(255))
      try:
        let a = loadActor(d)
        var state = newSeq[float32](a.stateSize)
        var logits = newSeq[float32](a.outputSize)
        a.infer(r.observation(a.inputSize), state, logits)
      except ValueError: discard

  test "SEGMENT_NEAR in front of an entity-factored actor does not allocate":
    var r = initRand(85)
    let actor = loadActor(encode2(538, ActionSizes, r.entityFactored().shifted(identityNear(522))))
    var state = newSeq[float32](128)
    var logits = newSeq[float32](LogitSize)
    var obs = r.observation(538)
    r.nearScene(obs)
    actor.infer(obs, state, logits)
    let before = getOccupiedMem()
    for i in 0..<20: actor.infer(obs, state, logits)
    check getOccupiedMem() == before

# The reference BASIC decode of the heads (the policy selects them with neuralSample first).
const Decode = staticRead("../examples/paintbot/players/neural_decode.bas")
const NeuralSource = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
neuralSample()
""" & Decode

proc seatFixture(model: string): seq[Bot] =
  let path = getTempDir()/"paintbot-neural-net2-test.bas"
  writeFile(path, NeuralSource)
  writeFile(path & ".model.bin", model)
  defer:
    removeFile(path)
    removeFile(path & ".model.bin")
  loadBots(@[BotGroup(path: path, count: Seats)])

suite "PWNET002 hosted seat":
  test "a PWNET002 package plays, its telemetry names the model, state resets like PWNET001":
    var r = initRand(42)
    let model = encode2(TeamsViewSize, ActionSizes, [
      r.attention([[104'u32, 8, 16, 8, 0], [24'u32, 8, 10, 8, 0]], 32, 4, 1, 32, 0, 24),
      r.mingru(88, 64, highway = false, bias = true),
      r.dense(64, LogitSize, bias = true)])
    let players = seatFixture(model)
    var w = newWorld(2026)
    for tick in 0..<40:
      discard players.decide(w)
      check not players[0].failed
      w.step(default(array[LegacySeats, Command]))
    let actor = loadActor(model)
    check players[0].neural.state.len == 64
    check players[0].neural.nativeWork == actor.operationCount
    check players[0].neural.telemetry(actor.operationCount, 40) ==
      "neural: peak_ops=" & $actor.operationCount & " budget=4000000 model=pwnet2-l3-s64 ticks=40"

  test "an entity-factored package (token layers) plays on the hosted seat":
    var r = initRand(44)
    let model = encode2(TeamsViewSize, ActionSizes,
      r.entityFactored(inputs = TeamsViewSize, segments = [[104'u32, 8, 8], [0'u32, 0, 24]]))
    let players = seatFixture(model)
    var w = newWorld(2027)
    for tick in 0..<40:
      discard players.decide(w)
      check not players[0].failed
      w.step(default(array[LegacySeats, Command]))
    let actor = loadActor(model)
    check players[0].neural.state.len == 128
    check players[0].neural.telemetry(actor.operationCount, 40) ==
      "neural: peak_ops=" & $actor.operationCount & " budget=4000000 model=pwnet2-l7-s128 ticks=40"

  test "SEGMENT_NEAR in front of an entity-factored actor plays on the hosted seat":
    var r = initRand(45)
    let model = encode2(TeamsViewSize, ActionSizes, r.entityFactored(inputs = TeamsViewSize,
      segments = [[104'u32, 8, 8], [392'u32, 1, 1], [0'u32, 0, 24]]).shifted(identityNear(392)))
    let players = seatFixture(model)
    var w = newWorld(2028)
    for tick in 0..<40:
      discard players.decide(w)
      check not players[0].failed
      w.step(default(array[LegacySeats, Command]))
    let actor = loadActor(model)
    check players[0].neural.state.len == 128
    check players[0].neural.telemetry(actor.operationCount, 40) ==
      "neural: peak_ops=" & $actor.operationCount & " budget=4000000 model=pwnet2-l8-s128 ticks=40"

  test "an over-budget PWNET002 model is rejected at load with its cost":
    var r = initRand(43)
    let model = encode2(TeamsViewSize, ActionSizes, [
      r.attention([[104'u32, 8, 16, 8, 0], [24'u32, 8, 10, 8, 0], [232'u32, 5, 32, 5, 0]], 128, 4, 2, 256, 0, 24),
      r.dense(280, LogitSize)])
    let actor = loadActor(model)
    check actor.operationCount > 4_000_000
    let path = getTempDir()/"paintbot-neural-net2-budget.bas"
    writeFile(path, NeuralSource)
    writeFile(path & ".model.bin", model)
    defer:
      removeFile(path)
      removeFile(path & ".model.bin")
    try:
      discard loadNeuralSeat(path, 0)
      check false
    except NeuralBudgetError as e:
      check e.operations == actor.operationCount
      check e.model == "pwnet2-l2-s0"
      check neuralTelemetry(e.operations, e.model, 0) ==
        "neural: peak_ops=" & $actor.operationCount & " budget=4000000 model=pwnet2-l2-s0 ticks=0"

suite "PWNET002 with user inputs (observation contract teams.view.1u<K>)":
  proc userInputNet(k: int, contract: string, inputs = TeamsViewSize + k): string =
    ## DENSE(inputs -> 8) picking the K user-input columns (512..) into y[0..K-1], then
    ## DENSE(8 -> 82) copying y[0..K-1] to logits[0..K-1]: the logits read the user inputs.
    var w1 = newSeq[float32](8*inputs)
    for j in 0..<min(k, 8):
      if TeamsViewSize + j < inputs: w1[j*inputs + TeamsViewSize + j] = 1
    var w2 = newSeq[float32](LogitSize*8)
    for j in 0..<min(k, 8): w2[j*8 + j] = 1
    encode2(inputs, ActionSizes, [
      Spec(code: 1, params: [inputs.uint32, 8, 0, 0, 0, 0, 0, 0], tensors: w1),
      Spec(code: 1, params: [8, LogitSize.uint32, 0, 0, 0, 0, 0, 0], tensors: w2)],
      observationContract = contract, actionContract = ActionContractTeamsView1Hash)
  proc inputsBundle(source, model: string, count: int, contract: string): seq[Bot] =
    let path = getTempDir()/("paintbot-neural-net2-inputs-" & $getCurrentProcessId() & ".bas")
    writeFile(path, source)
    writeFile(path & ".model.bin", model)
    var init: seq[string]
    for i in 0..<count: init.add $(5*(i+1))
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      contract & "\", \"action_contract\": \"" & ActionContractTeamsView1Hash & "\", \"sha256\": {}, " &
      "\"user_inputs\": {\"count\": " & $count & ", \"init\": [" & init.join(", ") & "]}}")
    defer:
      for suffix in ["", ".model.bin", ".neural.json"]: removeFile(path & suffix)
    loadBots(@[BotGroup(path: path, count: Seats)])
  const Source = """
neuralInput(0, worldTick * 10)
neuralInput(2, -worldTick)
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
neuralSample()
""" & Decode

  test "a PWNET002 teams.view.1u3 bundle loads, costs its 515 inputs, and its net reads the inputs one tick later":
    const k = 3
    let contract = userInputsContractHash(k)
    let model = userInputNet(k, contract)
    let actor = loadActor(model)
    check actor.inputSize == TeamsViewSize + k
    check actor.operationCount == 2*(TeamsViewSize + k)*8 + 2*8*LogitSize
    let players = inputsBundle(Source, model, k, contract)
    check not players[0].failed
    check players[0].neural.observation.len == TeamsViewSize + k
    var world = newWorld(33)
    var ranBefore: array[LegacySeats, bool]
    for tick in 0..<60:
      let commands = players.decide(world)
      for slot in 0..<Seats: require not players[slot].failed
      # Every seat that ran this tick: logits[j] = the user input j it set on the tick before
      # (the manifest's init on the match's first tick), divided by 1000.
      for slot in 0..<Seats:
        let ran = world.cogs[slot].hp > 0
        defer: ranBefore[slot] = ran
        if not ran or (tick > 0 and not ranBefore[slot]): continue
        let lg = players[slot].neural.logits
        if tick == 0:
          check lg[0] == 0.005'f32 and lg[1] == 0.010'f32 and lg[2] == 0.015'f32
        else:
          check lg[0] == float32((tick-1)*10) / 1000'f32
          check lg[1] == 0.010'f32
          check lg[2] == float32(-(tick-1)) / 1000'f32
      world.step(commands)
    check players[0].neural.telemetry(actor.operationCount, 60) ==
      "neural: peak_ops=" & $actor.operationCount & " budget=4000000 model=pwnet2-l2-s0 ticks=60"

  test "a mismatched K, contract or width is rejected":
    let k3 = userInputsContractHash(3)
    let k2 = userInputsContractHash(2)
    check not inputsBundle(Source, userInputNet(3, k3), 3, k3)[0].failed
    check inputsBundle(Source, userInputNet(3, k3), 2, k3)[0].failed                 # manifest K 2, contract teams.view.1u3
    check inputsBundle(Source, userInputNet(3, k2, TeamsViewSize + 3), 3, k3)[0].failed  # actor names teams.view.1u2
    check inputsBundle(Source, userInputNet(3, k2, TeamsViewSize + 3), 2, k2)[0].failed  # teams.view.1u2 with 515 inputs
    check inputsBundle(Source, userInputNet(3, k3, TeamsViewSize), 3, k3)[0].failed      # teams.view.1u3 with 512 inputs
