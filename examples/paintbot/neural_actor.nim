## Restricted FP32 PufferLib actor, no training framework dependency.
## Equations match PufferLib 6ffa5b10 src/algo.cu (MIT); see neural_actor.md.
import std/[math, os]

type
  LayerKind* = enum
    ## PWNET002 layer type codes (the u32 `type` of a layer record).
    lkDense = 1, lkRmsNorm = 2, lkMinGru = 3, lkResidual = 4, lkEntityAttn = 5, lkConcatInput = 6
  AttnGroup = object
    offset, stride, count, width, valid: int  # valid = -1: every token of the group is valid
    weight: int                               # E_g [d, width] then e_g [d], offsets into weights
  NetLayer {.byref.} = object
    kind: LayerKind
    inWidth, outWidth: int
    weight, bias: int      # offsets into Net2Object.weights; bias -1 = none
    relu, highway: bool
    gates: int             # MINGRU: 3 with highway, 2 without
    eps: float32
    stateOffset: int       # MINGRU: this layer's slice of the recurrent state
    source: int            # RESIDUAL: the earlier layer added; CONCAT_INPUT: input offset
    length: int            # CONCAT_INPUT: slice length
    output: int            # scratch offset of this layer's output (outWidth floats)
    groups: seq[AttnGroup] # ENTITY_ATTN
    dModel, heads, blocks, ff, passOffset, passLength, tokens: int
    blockWeight: int       # offset of block 0's tensors (blocks are contiguous)
    operations: int64
  Net2Object = object
    layers: seq[NetLayer]
    weights: seq[float32]
    scratch: seq[float32]  # bounded per-model scratch, sized at load; inference never allocates
    nextState: int         # scratch offset where new recurrent state is staged before commit
    work: int              # scratch offset of the per-layer workspace (MINGRU gates, ENTITY_ATTN)
    stateSize, parameters: int
    operations: int64
  Net2* = ref Net2Object
  Actor* = ref object
    inputSize*, hiddenSize*, outputSize*: int
    headSizes*: seq[int]
    observationContract*, actionContract*: string
    encoder, recurrent, decoder: seq[float32]
    net: Net2  # PWNET002 layer stack (nil for PWNET001); see the PWNET002 section below.

const
  ActorMagic* = "PWNET001"
  MaxActorParameters* = 2_000_000

proc finite(x: float32): bool = classify(x) notin {fcNan, fcInf, fcNegInf}
proc readU32(data: string, pos: var int): uint32 =
  if pos + 4 > data.len: raise newException(ValueError, "truncated neural actor")
  for i in 0..3: result = result or (uint32(ord(data[pos+i])) shl (8*i))
  pos += 4

proc loadActor1(data: string): Actor =
  if data.len < 8 or data[0..<8] != ActorMagic:
    raise newException(ValueError, "invalid neural actor magic")
  var p = 8
  let version = readU32(data, p)
  let inputs = int(readU32(data, p))
  let hidden = int(readU32(data, p))
  let outputs = int(readU32(data, p))
  let heads = int(readU32(data, p))
  let parameters = int(readU32(data, p))
  if version != 1 or inputs notin 1..4096 or hidden notin [64,128,256] or
      outputs notin 2..1024 or heads notin 1..32:
    raise newException(ValueError, "unsupported neural actor dimensions/version")
  let expected = inputs*hidden + 3*hidden*hidden + outputs*hidden
  if parameters != expected or expected > MaxActorParameters or
      data.len != 32 + 128 + heads*4 + expected*4:
    raise newException(ValueError, "invalid neural actor length/parameter count")
  new(result)
  result.inputSize = inputs; result.hiddenSize = hidden; result.outputSize = outputs
  result.observationContract = data[p..<p+64]; p += 64
  result.actionContract = data[p..<p+64]; p += 64
  for hash in [result.observationContract, result.actionContract]:
    for c in hash:
      if c notin {'0'..'9', 'a'..'f'}:
        raise newException(ValueError, "invalid neural contract hash")
  var total = 0
  for i in 0..<heads:
    let size = int(readU32(data,p))
    if size notin 2..1024: raise newException(ValueError, "invalid categorical head")
    result.headSizes.add(size); total += size
  if total != outputs: raise newException(ValueError, "head/output mismatch")
  for dest in [addr result.encoder, addr result.recurrent, addr result.decoder]:
    let n = if dest == addr result.encoder: inputs*hidden
            elif dest == addr result.recurrent: 3*hidden*hidden
            else: outputs*hidden
    dest[].setLen(n)
    for i in 0..<n:
      let bits = readU32(data,p)
      let x = cast[float32](bits)
      if not finite(x): raise newException(ValueError, "nonfinite neural weight")
      dest[][i] = x

proc operationCount*(actor: Actor): int =
  if not actor.net.isNil: return int(actor.net.operations)
  2*(actor.encoder.len + actor.recurrent.len + actor.decoder.len) + 32*actor.hiddenSize

proc sigmoid(x: float32): float32 =
  # Same stable branches as the pinned GPU sigmoid and lerp kernels.
  let z = exp(-abs(x))
  if x >= 0: 1'f32 / (1'f32 + z) else: z / (1'f32 + z)

proc interpolate(a, b, weight: float32): float32 =
  let delta = b-a
  if abs(weight) < 0.5'f32: a + weight*delta
  else: b - delta*(1'f32-weight)

# ---------------------------------------------------------------------------------------
# PWNET002: the architecture is data. A layer stack from a fixed menu (DENSE, RMSNORM,
# MINGRU, RESIDUAL, ENTITY_ATTN, CONCAT_INPUT), FP32, fixed summation order, loaded and
# validated once, run with bounded per-model scratch sized at load (no inference
# allocation). The format, equations and the published operation-count formula are in
# neural_actor.md ("PWNET002"). The hosted seat and the native training library
# (pw_net_*) run this same code.

const
  Net2Magic* = "PWNET002"
  MaxNet2FileBytes* = 16*1024*1024  # the package's model.bin bound (neural_package.py)
  MaxNet2Parameters* = 4_194_304
  MaxNet2Layers* = 64
  MaxNet2Width* = 4096      # any vector between layers
  MaxNet2State* = 4096      # recurrent floats, all MINGRU layers together
  MaxMinGruHidden* = 1024
  MaxAttnGroups* = 8
  MaxAttnTokens* = 64
  MaxAttnModel* = 256
  MaxAttnBlocks* = 8
  MaxAttnFeedForward* = 1024
  AttnAlwaysValid* = 0xFFFF_FFFF'u32
  ## Published cost constants: a multiply-accumulate is 2 operations, an elementwise add,
  ## multiply, compare, max, relu or copy is 1, an exp, sqrt or division is 8, and a MINGRU
  ## unit's gates, interpolation and highway are 32 (PWNET001's 32 per hidden unit).
  TranscendentalOps* = 8
  MinGruUnitOps* = 32

type F32s = ptr UncheckedArray[float32]

template at(p: F32s, offset: int): F32s = cast[F32s](addr p[offset])

proc net2Error(message: string) {.noreturn.} =
  raise newException(ValueError, "invalid PWNET002 actor: " & message)

proc rmsNormOps*(d: int): int64 = int64(4*d + 2*TranscendentalOps)

proc attentionOps*(groups: openArray[tuple[count, width: int]], d, heads, blocks, ff,
    passLength: int): int64 =
  ## ENTITY_ATTN's published cost (neural_actor.md). Independent of which tokens are valid.
  var t = 0
  var embed = 0'i64
  for g in groups:
    t += g.count
    embed += int64(g.count)*int64(2*g.width*d + d)
  let T = int64(t)
  let D = int64(d)
  let H = int64(heads)
  let F = int64(ff)
  let perBlock = 2*T*rmsNormOps(d) +          # the two pre-norms
    T*(6*D*D + 3*D) +                          # q, k, v projections with bias
    T*T*(4*D + 13*H) + T*H*TranscendentalOps + # scores, scale, softmax, weighted values
    T*(2*D*D + D) + T*D +                      # output projection with bias, residual
    T*(2*D*F + 2*F) + T*(2*F*D + D) + T*D      # relu MLP with biases, residual
  embed + int64(blocks)*perBlock + T + 2*T*D + D + TranscendentalOps + int64(passLength)

proc readWeights(net: Net2, data: string, p: var int, n: int) =
  if n < 0 or net.weights.len + n > MaxNet2Parameters: net2Error("parameter count")
  if p + 4*n > data.len: raise newException(ValueError, "truncated neural actor")
  for i in 0..<n:
    let x = cast[float32](readU32(data, p))
    if not finite(x): raise newException(ValueError, "nonfinite neural weight")
    net.weights.add x

proc loadActor2(data: string): Actor =
  if data.len < 8 or data[0..<8] != Net2Magic:
    raise newException(ValueError, "invalid neural actor magic")
  var p = 8
  let version = readU32(data, p)
  let inputs = int(readU32(data, p))
  let outputs = int(readU32(data, p))
  let heads = int(readU32(data, p))
  if version != 2 or inputs notin 1..4096 or outputs notin 2..1024 or heads notin 1..32:
    raise newException(ValueError, "unsupported neural actor dimensions/version")
  new(result)
  result.inputSize = inputs; result.outputSize = outputs
  var total = 0
  for i in 0..<heads:
    let size = int(readU32(data, p))
    if size notin 2..1024: raise newException(ValueError, "invalid categorical head")
    result.headSizes.add(size); total += size
  if total != outputs: raise newException(ValueError, "head/output mismatch")
  if p + 128 > data.len: raise newException(ValueError, "truncated neural actor")
  result.observationContract = data[p..<p+64]; p += 64
  result.actionContract = data[p..<p+64]; p += 64
  for hash in [result.observationContract, result.actionContract]:
    for c in hash:
      if c notin {'0'..'9', 'a'..'f'}:
        raise newException(ValueError, "invalid neural contract hash")
  let count = int(readU32(data, p))
  if count notin 1..MaxNet2Layers: net2Error("layer count must be 1.." & $MaxNet2Layers)
  let net = Net2()
  var width = inputs  # the current vector: the observation before layer 0
  var scratch = 0     # layer outputs
  var work = 0        # the largest per-layer workspace (MINGRU gates, ENTITY_ATTN)
  for k in 0..<count:
    let code = readU32(data, p)
    var q: array[8, uint32]
    for j in 0..7: q[j] = readU32(data, p)
    let where = "layer " & $k & ": "
    template unused(first: int) =
      for j in first..7:
        if q[j] != 0: net2Error(where & "unused parameter " & $j & " must be 0")
    template flag(j: int): bool =
      if q[j] > 1: net2Error(where & "parameter " & $j & " must be 0 or 1")
      q[j] == 1
    template epsilon(j: int): float32 =
      let e = cast[float32](q[j])
      if not finite(e) or not (e > 0'f32): net2Error(where & "eps must be finite and positive")
      e
    var layer = NetLayer(inWidth: width, bias: -1)
    case code
    of lkDense.uint32:
      layer.kind = lkDense
      let o = int(q[1])
      if int(q[0]) != width: net2Error(where & "DENSE input " & $q[0] & " != width " & $width)
      if o notin 1..MaxNet2Width: net2Error(where & "DENSE output must be 1.." & $MaxNet2Width)
      let hasBias = flag(2)
      layer.relu = flag(3)
      unused(4)
      layer.weight = net.weights.len
      net.readWeights(data, p, width*o)
      if hasBias:
        layer.bias = net.weights.len
        net.readWeights(data, p, o)
      layer.outWidth = o
      layer.operations = int64(2*width*o) + (if hasBias: o else: 0) + (if layer.relu: o else: 0)
    of lkRmsNorm.uint32:
      layer.kind = lkRmsNorm
      if int(q[0]) != width: net2Error(where & "RMSNORM dim " & $q[0] & " != width " & $width)
      layer.eps = epsilon(1)
      unused(2)
      layer.weight = net.weights.len
      net.readWeights(data, p, width)
      layer.outWidth = width
      layer.operations = rmsNormOps(width)
    of lkMinGru.uint32:
      layer.kind = lkMinGru
      let h = int(q[1])
      if int(q[0]) != width: net2Error(where & "MINGRU input " & $q[0] & " != width " & $width)
      if h notin 1..MaxMinGruHidden: net2Error(where & "MINGRU hidden must be 1.." & $MaxMinGruHidden)
      layer.highway = flag(2)
      let hasBias = flag(3)
      unused(4)
      if layer.highway and width != h: net2Error(where & "MINGRU highway needs input == hidden")
      layer.gates = if layer.highway: 3 else: 2
      layer.weight = net.weights.len
      net.readWeights(data, p, layer.gates*h*width)
      if hasBias:
        layer.bias = net.weights.len
        net.readWeights(data, p, layer.gates*h)
      layer.stateOffset = net.stateSize
      net.stateSize += h
      if net.stateSize > MaxNet2State: net2Error(where & "recurrent state exceeds " & $MaxNet2State)
      layer.outWidth = h
      work = max(work, layer.gates*h)
      layer.operations = int64(2*width*layer.gates*h) + (if hasBias: layer.gates*h else: 0) +
        int64(MinGruUnitOps*h)
    of lkResidual.uint32:
      layer.kind = lkResidual
      layer.source = int(q[0])
      unused(1)
      if layer.source >= k: net2Error(where & "RESIDUAL start must name an earlier layer")
      if net.layers[layer.source].outWidth != width:
        net2Error(where & "RESIDUAL width " & $width & " != layer " & $layer.source & " output")
      layer.outWidth = width
      layer.operations = int64(width)
    of lkEntityAttn.uint32:
      layer.kind = lkEntityAttn
      let groups = int(q[0])
      layer.dModel = int(q[1]); layer.heads = int(q[2]); layer.blocks = int(q[3]); layer.ff = int(q[4])
      layer.passOffset = int(q[5]); layer.passLength = int(q[6])
      layer.eps = epsilon(7)
      let d = layer.dModel
      if groups notin 1..MaxAttnGroups: net2Error(where & "ENTITY_ATTN groups must be 1.." & $MaxAttnGroups)
      if d notin 1..MaxAttnModel: net2Error(where & "ENTITY_ATTN d_model must be 1.." & $MaxAttnModel)
      if layer.heads notin 1..d or d mod layer.heads != 0:
        net2Error(where & "ENTITY_ATTN heads must divide d_model")
      if layer.blocks notin 0..MaxAttnBlocks: net2Error(where & "ENTITY_ATTN blocks must be 0.." & $MaxAttnBlocks)
      if layer.ff notin 1..MaxAttnFeedForward: net2Error(where & "ENTITY_ATTN ff must be 1.." & $MaxAttnFeedForward)
      if layer.passOffset > inputs or layer.passLength > inputs - layer.passOffset:
        net2Error(where & "ENTITY_ATTN passthrough outside the input")
      var shapes: seq[tuple[count, width: int]]
      for g in 0..<groups:
        var group: AttnGroup
        group.offset = int(readU32(data, p)); group.stride = int(readU32(data, p))
        group.count = int(readU32(data, p)); group.width = int(readU32(data, p))
        let valid = readU32(data, p)
        if group.count notin 1..MaxAttnTokens or group.width notin 1..inputs or group.stride notin 1..inputs:
          net2Error(where & "ENTITY_ATTN group " & $g & " count/width/stride")
        if group.offset > inputs or (group.count-1)*group.stride + group.width > inputs - group.offset:
          net2Error(where & "ENTITY_ATTN group " & $g & " outside the input")
        if valid == AttnAlwaysValid: group.valid = -1
        elif int(valid) < group.width: group.valid = int(valid)
        else: net2Error(where & "ENTITY_ATTN group " & $g & " valid index outside the token")
        layer.tokens += group.count
        if layer.tokens > MaxAttnTokens: net2Error(where & "ENTITY_ATTN tokens exceed " & $MaxAttnTokens)
        layer.groups.add group
        shapes.add((group.count, group.width))
      for group in layer.groups.mitems:
        group.weight = net.weights.len
        net.readWeights(data, p, d*group.width + d)
      layer.blockWeight = net.weights.len
      let f = layer.ff
      for b in 0..<layer.blocks:
        net.readWeights(data, p, d + 3*d*d + 3*d + d*d + d + d + f*d + f + d*f + d)
      layer.outWidth = 2*d + layer.passLength
      if layer.outWidth > MaxNet2Width: net2Error(where & "ENTITY_ATTN output exceeds " & $MaxNet2Width)
      let t = layer.tokens
      work = max(work, 6*t*d + d + f + 2*t)
      layer.operations = attentionOps(shapes, d, layer.heads, layer.blocks, f, layer.passLength)
    of lkConcatInput.uint32:
      layer.kind = lkConcatInput
      layer.source = int(q[0]); layer.length = int(q[1])
      unused(2)
      if layer.length notin 1..MaxNet2Width or layer.source > inputs or layer.length > inputs - layer.source:
        net2Error(where & "CONCAT_INPUT slice outside the input")
      layer.outWidth = width + layer.length
      if layer.outWidth > MaxNet2Width: net2Error(where & "CONCAT_INPUT output exceeds " & $MaxNet2Width)
      layer.operations = int64(layer.length)
    else:
      net2Error(where & "unknown layer type " & $code)
    layer.output = scratch
    scratch += layer.outWidth
    width = layer.outWidth
    net.operations += layer.operations
    net.layers.add layer
  if p != data.len: net2Error("length: " & $(data.len - p) & " trailing bytes")
  if width != outputs: net2Error("last layer width " & $width & " != outputs " & $outputs)
  net.parameters = net.weights.len
  net.nextState = scratch
  net.work = scratch + net.stateSize
  net.scratch = newSeq[float32](scratch + net.stateSize + work)
  result.hiddenSize = net.stateSize
  result.net = net

proc stateSize*(actor: Actor): int =
  ## Recurrent floats a seat keeps for this actor (PWNET001: the hidden width).
  if actor.net.isNil: actor.hiddenSize else: actor.net.stateSize

proc actorFormat*(actor: Actor): int =
  if actor.net.isNil: 1 else: 2

proc layerCount*(actor: Actor): int =
  if actor.net.isNil: 3 else: actor.net.layers.len

proc parameterCount*(actor: Actor): int =
  if actor.net.isNil: actor.encoder.len + actor.recurrent.len + actor.decoder.len
  else: actor.net.parameters

proc modelTag*(actor: Actor): string =
  ## The telemetry's model field: `w<hidden>` for PWNET001 (unchanged), else
  ## `pwnet2-l<layers>-s<state floats>`.
  if actor.net.isNil: "w" & $actor.hiddenSize
  else: "pwnet2-l" & $actor.net.layers.len & "-s" & $actor.net.stateSize

proc loadActor*(data: string): Actor =
  if data.len >= 8 and data[0..<8] == Net2Magic: loadActor2(data)
  else: loadActor1(data)

proc loadActorFile*(path: string): Actor =
  var magic = newString(8)
  var file = open(path)
  let got = file.readChars(toOpenArray(magic, 0, 7))
  file.close()
  let limit = if got == 8 and magic == Net2Magic: int64(MaxNet2FileBytes)
              else: int64(32+128+128+MaxActorParameters*4)
  if getFileSize(path) > limit:
    raise newException(ValueError, "neural actor file too large")
  loadActor(readFile(path))

proc checkFinite(y: F32s, n: int) =
  for i in 0..<n:
    if not finite(y[i]): raise newException(ValueError, "nonfinite neural intermediate")

proc dense(x: F32s, n: int, w, bias: F32s, m: int, relu: bool, y: F32s) =
  ## y[o] = relu?(sum_i x[i]*w[o*n+i] (+ bias[o])), i ascending from 0.
  for o in 0..<m:
    var sum = 0'f32
    for i in 0..<n: sum += x[i]*w[o*n+i]
    if bias != nil: sum = sum + bias[o]
    if relu and not (sum > 0'f32): sum = 0'f32
    y[o] = sum

proc rmsNorm(x: F32s, n: int, gain: F32s, eps: float32, y: F32s) =
  var squares = 0'f32
  for i in 0..<n: squares += x[i]*x[i]
  let r = 1'f32 / sqrt(squares / float32(n) + eps)
  for i in 0..<n: y[i] = x[i]*r*gain[i]

proc minGru(layer: NetLayer, x, w, bias, state, combined, next, y: F32s) =
  ## PWNET001's cell (same expressions, same order), optionally with a gate bias and
  ## without the highway gate.
  let n = layer.inWidth
  let h = layer.outWidth
  for o in 0..<layer.gates*h:
    var sum = 0'f32
    for i in 0..<n: sum += x[i]*w[o*n+i]
    if bias != nil: sum = sum + bias[o]
    combined[o] = sum
  for i in 0..<h:
    let candidate = if combined[i] >= 0: combined[i]+0.5'f32 else: sigmoid(combined[i])
    let gate = sigmoid(combined[h+i])
    next[i] = interpolate(state[i], candidate, gate)
    if layer.highway:
      let highway = sigmoid(combined[2*h+i])
      y[i] = highway*next[i] + (1'f32-highway)*x[i]
    else:
      y[i] = next[i]
    if not finite(next[i]) or not finite(y[i]):
      raise newException(ValueError, "nonfinite neural intermediate")

proc entityAttention(layer: NetLayer, input, w, work, y: F32s) =
  let d = layer.dModel
  let t = layer.tokens
  let f = layer.ff
  let dh = d div layer.heads
  let hs = work              # token states [t, d]
  let normed = work.at(t*d)  # pre-norm outputs [t, d]
  let qkv = work.at(2*t*d)   # [t, 3d]: q | k | v
  let att = work.at(5*t*d)   # attention outputs, heads concatenated [t, d]
  let u = work.at(6*t*d)     # one token's projection [d]
  let hidden = u.at(d)       # one token's MLP hidden [f]
  let score = hidden.at(f)   # one query's scores / weights [t]
  let valid = score.at(t)    # 1 valid, 0 masked [t]
  var slot = 0
  var validCount = 0
  for group in layer.groups:
    for token in 0..<group.count:
      let start = group.offset + token*group.stride
      let ok = group.valid < 0 or input[start+group.valid] > 0.5'f32
      valid[slot] = if ok: 1'f32 else: 0'f32
      if ok: inc validCount
      dense(input.at(start), group.width, w.at(group.weight), w.at(group.weight + d*group.width),
        d, false, hs.at(slot*d))
      inc slot
  let scale = 1'f32 / sqrt(float32(dh))
  var off = layer.blockWeight
  for b in 0..<layer.blocks:
    let g1 = off
    let wqkv = g1 + d
    let bqkv = wqkv + 3*d*d
    let wo = bqkv + 3*d
    let bo = wo + d*d
    let g2 = bo + d
    let w1 = g2 + d
    let b1 = w1 + f*d
    let w2 = b1 + f
    let b2 = w2 + d*f
    off = b2 + d
    for n in 0..<t:
      rmsNorm(hs.at(n*d), d, w.at(g1), layer.eps, normed.at(n*d))
      dense(normed.at(n*d), d, w.at(wqkv), w.at(bqkv), 3*d, false, qkv.at(n*3*d))
    for n in 0..<t:
      for j in 0..<layer.heads:
        let o = att.at(n*d + j*dh)
        for c in 0..<dh: o[c] = 0'f32
        if validCount == 0: continue
        let q = qkv.at(n*3*d + j*dh)
        var top = 0'f32
        var first = true
        for m in 0..<t:
          if valid[m] == 0'f32: continue
          let k = qkv.at(m*3*d + d + j*dh)
          var dot = 0'f32
          for c in 0..<dh: dot += q[c]*k[c]
          let s = dot*scale
          score[m] = s
          if first or s > top:
            top = s
            first = false
        var total = 0'f32
        for m in 0..<t:
          if valid[m] == 0'f32: continue
          let e = exp(score[m] - top)
          score[m] = e
          total += e
        let inverse = 1'f32 / total
        for m in 0..<t:
          if valid[m] == 0'f32: continue
          let weight = score[m]*inverse
          let v = qkv.at(m*3*d + 2*d + j*dh)
          for c in 0..<dh: o[c] += weight*v[c]
    for n in 0..<t:
      let x = hs.at(n*d)
      dense(att.at(n*d), d, w.at(wo), w.at(bo), d, false, u)
      for c in 0..<d: x[c] = x[c] + u[c]
      rmsNorm(x, d, w.at(g2), layer.eps, normed.at(n*d))
      dense(normed.at(n*d), d, w.at(w1), w.at(b1), f, true, hidden)
      dense(hidden, f, w.at(w2), w.at(b2), d, false, u)
      for c in 0..<d: x[c] = x[c] + u[c]
  for c in 0..<2*d: y[c] = 0'f32
  if validCount > 0:
    let inverse = 1'f32 / float32(validCount)
    for c in 0..<d:
      var total = 0'f32
      var best = 0'f32
      var first = true
      for n in 0..<t:
        if valid[n] == 0'f32: continue
        let v = hs[n*d + c]
        total += v
        if first or v > best:
          best = v
          first = false
      y[c] = total*inverse
      y[d+c] = best
  for i in 0..<layer.passLength: y[2*d+i] = input[layer.passOffset+i]

proc inferNet2(actor: Actor, obs: openArray[float32], state: var seq[float32],
    logits: var seq[float32]) =
  let net = actor.net
  if obs.len != actor.inputSize or state.len != net.stateSize or
      logits.len != actor.outputSize:
    raise newException(ValueError, "neural buffer shape mismatch")
  for x in obs:
    if not finite(x): raise newException(ValueError, "nonfinite neural input")
  for x in state:
    if not finite(x): raise newException(ValueError, "nonfinite neural state")
  let input = cast[F32s](unsafeAddr obs[0])
  let w = if net.weights.len == 0: nil else: cast[F32s](addr net.weights[0])
  let scratch = cast[F32s](addr net.scratch[0])
  let oldState = if state.len == 0: nil else: cast[F32s](addr state[0])
  var x = input
  for k in 0..<net.layers.len:
    let layer = addr net.layers[k]
    let y = scratch.at(layer.output)
    case layer.kind
    of lkDense:
      let bias = if layer.bias < 0: nil else: w.at(layer.bias)
      dense(x, layer.inWidth, w.at(layer.weight), bias, layer.outWidth, layer.relu, y)
    of lkRmsNorm:
      rmsNorm(x, layer.inWidth, w.at(layer.weight), layer.eps, y)
    of lkMinGru:
      let bias = if layer.bias < 0: nil else: w.at(layer.bias)
      minGru(layer[], x, w.at(layer.weight), bias, oldState.at(layer.stateOffset),
        scratch.at(net.work), scratch.at(net.nextState + layer.stateOffset), y)
    of lkResidual:
      let skip = scratch.at(net.layers[layer.source].output)
      for i in 0..<layer.outWidth: y[i] = x[i] + skip[i]
    of lkEntityAttn:
      entityAttention(layer[], input, w, scratch.at(net.work), y)
    of lkConcatInput:
      for i in 0..<layer.inWidth: y[i] = x[i]
      for i in 0..<layer.length: y[layer.inWidth+i] = input[layer.source+i]
    checkFinite(y, layer.outWidth)
    x = y
  # Every result is validated before state or logits are committed.
  for i in 0..<actor.outputSize:
    if not finite(x[i]): raise newException(ValueError, "nonfinite neural output")
  for i in 0..<net.stateSize: state[i] = scratch[net.nextState+i]
  for i in 0..<actor.outputSize: logits[i] = x[i]

proc infer*(actor: Actor, obs: openArray[float32], state: var seq[float32],
    logits: var seq[float32]) =
  if not actor.net.isNil:
    actor.inferNet2(obs, state, logits)
    return
  if obs.len != actor.inputSize or state.len != actor.hiddenSize or
      logits.len != actor.outputSize:
    raise newException(ValueError, "neural buffer shape mismatch")
  for x in obs:
    if not finite(x): raise newException(ValueError, "nonfinite neural input")
  for x in state:
    if not finite(x): raise newException(ValueError, "nonfinite neural state")
  # Fixed bounded stack scratch: no inference allocations and no partial outputs.
  var x, next, y: array[256,float32]
  var combined: array[768,float32]
  var output: array[1024,float32]
  let h = actor.hiddenSize
  for o in 0..<h:
    var sum = 0'f32
    for i in 0..<obs.len: sum += obs[i]*actor.encoder[o*obs.len+i]
    x[o] = sum
  for o in 0..<3*h:
    var sum = 0'f32
    for i in 0..<h: sum += x[i]*actor.recurrent[o*h+i]
    combined[o] = sum
  for i in 0..<h:
    let candidate = if combined[i] >= 0: combined[i]+0.5'f32 else: sigmoid(combined[i])
    let gate = sigmoid(combined[h+i])
    next[i] = interpolate(state[i], candidate, gate)
    let highway = sigmoid(combined[2*h+i])
    y[i] = highway*next[i] + (1'f32-highway)*x[i]
    if not finite(next[i]) or not finite(y[i]):
      raise newException(ValueError, "nonfinite neural intermediate")
  for o in 0..<actor.outputSize:
    var sum = 0'f32
    for i in 0..<h: sum += y[i]*actor.decoder[o*h+i]
    if not finite(sum): raise newException(ValueError, "nonfinite neural output")
    output[o] = sum
  for i in 0..<h: state[i] = next[i]
  for i in 0..<actor.outputSize: logits[i] = output[i]
