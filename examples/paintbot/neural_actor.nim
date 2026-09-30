## Restricted FP32 PufferLib actor, no training framework dependency.
## Equations match PufferLib 6ffa5b10 src/algo.cu (MIT); see neural_actor.md.
import std/[math, os]

type
  LayerKind* = enum
    ## PWNET002 layer type codes (the u32 `type` of a layer record).
    lkDense = 1, lkRmsNorm = 2, lkMinGru = 3, lkResidual = 4, lkEntityAttn = 5, lkConcatInput = 6,
    lkTokenMlp = 7, lkTokenMix = 8, lkPointer = 9, lkSegmentNear = 10, lkAttnPool = 11,
    lkPad = 12
  AttnGroup = object
    offset, stride, count, width, valid: int  # valid = -1: every token of the group is valid
    weight: int                               # E_g [d, width] then e_g [d], offsets into weights
  TokenSegment = object
    offset, stride, length: int               # token n reads input[offset + n*stride ..< +length]; stride 0 = shared
  SegmentNearSpec = object
    ## SEGMENT_NEAR: token n's floats start at input[base + n*stride]; column indices within the token (exclude -1 =
    ## none); the flags go to input[dstOffset + n*dstStride] of the view. Scales and radius are the record's FP32
    ## values widened to float64 (the layer computes in float64).
    base, stride, xIndex, zIndex, validIndex, excludeIndex, candidateIndex, dstOffset, dstStride: int
    scaleX, scaleZ, radius: float64
  NetLayer {.byref.} = object
    kind: LayerKind
    inWidth, outWidth: int
    weight, bias: int      # offsets into Net2Object.weights; bias -1 = none
    relu, highway: bool
    gates: int             # MINGRU: 3 with highway, 2 without
    eps: float32
    stateOffset: int       # MINGRU: this layer's slice of the recurrent state
    source: int            # RESIDUAL: the earlier layer added; CONCAT_INPUT: input offset;
                           # TOKEN_MIX / POINTER: the TOKEN_MLP / TOKEN_MIX layer read
    length: int            # CONCAT_INPUT: slice length; POINTER: the output offset of token 0
    output: int            # scratch offset of this layer's output (outWidth floats)
    groups: seq[AttnGroup] # ENTITY_ATTN
    dModel, heads, blocks, ff, passOffset, passLength, tokens: int
    blockWeight: int       # offset of block 0's tensors (blocks are contiguous)
    segments: seq[TokenSegment]  # TOKEN_MLP: the per-token gather, concatenated in order
    validSegment, validIndex: int  # TOKEN_MLP: the presence flag (validSegment -1 = every token valid)
    mlpWidths: seq[int]    # TOKEN_MLP: the shared MLP's layer widths (input width first)
    tokenWidth: int        # TOKEN_MLP / TOKEN_MIX: floats per token in this layer's token buffer
    tokenBuffer: int       # TOKEN_MLP / TOKEN_MIX: scratch offset of the per-token outputs (tokens*tokenWidth)
    validBuffer: int       # TOKEN_*/POINTER: scratch offset of the tokens' valid flags (1 / 0), written by TOKEN_MLP
    near: SegmentNearSpec  # SEGMENT_NEAR (tokens = its token count)
    exposeTokens: bool     # ENTITY_ATTN: a later layer reads its token rows (tokenBuffer / validBuffer)
    keyWidth, valueWidth: int  # ATTN_POOL: per-head key and value widths
    norm: bool             # TOKEN_MLP / TOKEN_MIX: LayerNorm (gain, shift) on each pre-activation row, eps = `eps`
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
  LayoutSection* = object
    offset*, rows*, width*: int  # where the section's rows lie in the observation
    target*: int                 # the logit offset of row 0's pointer target (-1: none)
  ActorLayout* = object
    ## The match layout a PWNET002 layout word resolves against (neural_actor.md, "Layout
    ## words"): the observation's sections (0 cogs, 1 control hearts, 2 great hearts, 3 the
    ## control and great hearts as one run), the observation width, the logit width and the
    ## action heads. `present` false: the model may hold no layout word.
    present*: bool
    inputs*, outputs*: int
    sections*: array[4, LayoutSection]
    heads*: seq[int]

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
# MINGRU, RESIDUAL, ENTITY_ATTN, CONCAT_INPUT, TOKEN_MLP, TOKEN_MIX (both with an optional pre-relu
# LayerNorm), POINTER, SEGMENT_NEAR, ATTN_POOL, PAD), FP32
# (SEGMENT_NEAR's geometry: float64), fixed summation order, loaded and validated once, run
# with bounded per-model scratch sized at load (no inference allocation). The format,
# equations and the published operation-count formula are in neural_actor.md ("PWNET002").
# The hosted seat and the native training library (pw_net_*) run this same code.

const
  Net2Magic* = "PWNET002"
  MaxNet2FileBytes* = 16*1024*1024  # the package's model.bin bound (neural_package.py)
  MaxNet2Parameters* = 4_194_304
  MaxNet2Layers* = 64
  MaxNet2Width* = 4096      # any vector between layers
  MaxNet2State* = 4096      # recurrent floats, all MINGRU layers together
  MaxMinGruHidden* = 1024
  MaxAttnGroups* = 8
  MaxAttnTokens* = 256
  MaxAttnModel* = 256
  MaxAttnBlocks* = 8
  MaxAttnFeedForward* = 1024
  AttnAlwaysValid* = 0xFFFF_FFFF'u32
  MaxTokenSegments* = 8
  MaxTokenInput* = 1024     # TOKEN_MLP: floats gathered per token
  MaxTokenModel* = 256      # TOKEN_MLP layer widths, TOKEN_MIX width
  MaxTokenMlpLayers* = 4
  MaxAttnPoolHeads* = 32
  MaxAttnPoolWidth* = 1024  # ATTN_POOL heads x key width, heads x value width
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

proc tokenPoolOps(t, d: int): int64 = int64(t + 2*t*d + d + TranscendentalOps)

proc layerNormOps*(d: int): int64 =
  ## One LayerNorm row of width d: the sum, the centred squares (a subtract and a multiply-accumulate), the
  ## centre, scale, gain and shift of every element (8 per element), and the two divisions by d, the sqrt and
  ## the reciprocal.
  int64(8*d + 4*TranscendentalOps)

proc tokenNormOps*(tokens: int, widths: openArray[int]): int64 =
  ## What a token layer's `norm` flag adds: one LayerNorm row per token (valid or not) for each normalised width
  ## (TOKEN_MLP: every layer's output width; TOKEN_MIX: z).
  for d in widths: result += int64(tokens)*layerNormOps(d)

proc tokenMlpOps*(tokens: int, widths: openArray[int]): int64 =
  ## TOKEN_MLP's published cost: the gather, a biased relu DENSE per token per layer, the pools.
  result = int64(tokens*widths[0])
  for l in 1..<widths.len: result += int64(tokens)*int64(2*widths[l-1]*widths[l] + 2*widths[l])
  result += tokenPoolOps(tokens, widths[^1])

proc tokenMixOps*(tokens, tokenIn, width, z: int): int64 =
  ## TOKEN_MIX's published cost: Uy x once, the copy of x, per token Ue e + b + u and relu, the pools.
  int64(2*width*z + width) + int64(tokens)*int64(2*tokenIn*z + 3*z) + tokenPoolOps(tokens, z)

proc pointerOps*(tokens, z, width: int): int64 =
  ## POINTER's published cost: the copy, per token a dot product, its bias and the add.
  int64(width) + int64(tokens)*int64(2*z + 2)

proc segmentNearOps*(inputs, tokens: int): int64 =
  ## SEGMENT_NEAR's published cost: the copy of the input, per token pair 12, per token 8.
  int64(inputs) + int64(tokens)*int64(tokens)*12 + int64(tokens)*8

proc attnPoolOps*(tokens, z, width, heads, keyWidth, valueWidth: int): int64 =
  ## ATTN_POOL's published cost: the copy of x, the query projection, then per token (valid
  ## or not, like ENTITY_ATTN) its key, its per-head scores, the softmax terms, its value and
  ## the weighted sum, and per head the normaliser.
  let W = int64(width)
  let T = int64(tokens)
  let Z = int64(z)
  let H = int64(heads)
  let K = int64(keyWidth)
  let V = int64(valueWidth)
  W + (2*W*H*K + H*K) +
    T*((2*Z*H*K + H*K) + H*(2*K + 1) + H*(TranscendentalOps + 3) + (2*Z*H*V + H*V) + 2*H*V) +
    H*(T + TranscendentalOps)

const
  LayoutWordBase* = 0xFFFE_0000'u32
  ## Layout words (neural_actor.md): a structural uint32 whose high 16 bits are 0xFFFE names
  ## a quantity of the match layout (no valid model had such a value before). Low 16 bits:
  ## section s (bits 12..15), field f (bits 8..11), addend a (bits 0..7). Sections 0..3
  ## (cogs, control hearts, great hearts, control + great hearts): f 0 rows, 1 offset,
  ## 2 row width, 3 logit offset of row 0's pointer target; the value is that plus a.
  ## s = 14: f 0 observation width + a, 1 logit width + a, 2 the size of head a, 3 the logit
  ## offset of head a.
  LayoutGlobal* = 14
proc isLayoutWord*(v: uint32): bool = (v and 0xFFFF_0000'u32) == LayoutWordBase
proc layoutWord*(section, field: int, addend = 0): uint32 =
  ## The layout word for (section, field, addend); see LayoutWordBase.
  LayoutWordBase or uint32((section shl 12) or (field shl 8) or addend)
proc resolveWord*(ctx: ActorLayout, v: uint32, where: string): uint32 =
  ## `v` itself unless it is a layout word; then its value in `ctx`.
  if not isLayoutWord(v): return v
  if not ctx.present: net2Error(where & "layout word 0x" & $v & " needs a match layout")
  let low = int(v and 0xFFFF'u32)
  let section = low shr 12
  let field = (low shr 8) and 0xF
  let addend = low and 0xFF
  var value = 0
  if section <= 3:
    let sec = ctx.sections[section]
    case field
    of 0: value = sec.rows + addend
    of 1: value = sec.offset + addend
    of 2: value = sec.width + addend
    of 3:
      if sec.target < 0: net2Error(where & "layout section " & $section & " has no pointer target")
      value = sec.target + addend
    else: net2Error(where & "unknown layout word field " & $field)
  elif section == LayoutGlobal:
    case field
    of 0: value = ctx.inputs + addend
    of 1: value = ctx.outputs + addend
    of 2, 3:
      if addend >= ctx.heads.len: net2Error(where & "layout word names head " & $addend)
      if field == 2: value = ctx.heads[addend]
      else:
        for h in 0..<addend: value += ctx.heads[h]
    else: net2Error(where & "unknown layout word field " & $field)
  else: net2Error(where & "unknown layout word section " & $section)
  if value < 0 or int64(value) >= int64(LayoutWordBase): net2Error(where & "layout word out of range")
  uint32(value)

proc readWeights(net: Net2, data: string, p: var int, n: int) =
  if n < 0 or net.weights.len + n > MaxNet2Parameters: net2Error("parameter count")
  if p + 4*n > data.len: raise newException(ValueError, "truncated neural actor")
  for i in 0..<n:
    let x = cast[float32](readU32(data, p))
    if not finite(x): raise newException(ValueError, "nonfinite neural weight")
    net.weights.add x

proc exposeTokens(net: Net2, source: int, scratch: var int) =
  ## A later layer reads `source`'s token rows. TOKEN_MLP and TOKEN_MIX keep them already; an
  ## ENTITY_ATTN layer gets a token buffer (its final token states [tokens, d] and the valid
  ## flags) the first time, and its cost grows by the copy (tokens*d + tokens).
  let src = addr net.layers[source]
  if src.kind != lkEntityAttn or src.exposeTokens: return
  src.exposeTokens = true
  src.tokenWidth = src.dModel
  src.tokenBuffer = scratch
  src.validBuffer = scratch + src.tokens*src.dModel
  scratch += src.tokens*src.dModel + src.tokens
  let copy = int64(src.tokens*src.dModel + src.tokens)
  src.operations += copy
  net.operations += copy

proc loadActor2(data: string, ctx: ActorLayout): Actor =
  if data.len < 8 or data[0..<8] != Net2Magic:
    raise newException(ValueError, "invalid neural actor magic")
  var p = 8
  template word(where: string): uint32 = ctx.resolveWord(readU32(data, p), where)
  let version = readU32(data, p)
  let inputs = int(word("header: "))
  let outputs = int(word("header: "))
  let heads = int(readU32(data, p))
  if version != 2 or inputs notin 1..4096 or outputs notin 2..1024 or heads notin 1..32:
    raise newException(ValueError, "unsupported neural actor dimensions/version")
  new(result)
  result.inputSize = inputs; result.outputSize = outputs
  var total = 0
  for i in 0..<heads:
    let size = int(word("header: "))
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
    let where = "layer " & $k & ": "
    var q: array[8, uint32]
    for j in 0..7:
      let raw = readU32(data, p)
      # FP32 parameters (RMSNORM eps, ENTITY_ATTN eps, the token layers' norm eps) are never layout words.
      let floatParam = (code == lkRmsNorm.uint32 and j == 1) or (code == lkEntityAttn.uint32 and j == 7) or
        (code in [lkTokenMlp.uint32, lkTokenMix.uint32] and j == 7)
      if floatParam and isLayoutWord(raw): net2Error(where & "parameter " & $j & " cannot be a layout word")
      q[j] = if floatParam: raw else: ctx.resolveWord(raw, where)
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
    template tokenNorm() =
      ## The token layers' params 6 (norm, 0 or 1) and 7 (its eps as FP32 bits; 0 without norm).
      layer.norm = flag(6)
      if layer.norm: layer.eps = epsilon(7)
      elif q[7] != 0: net2Error(where & "unused parameter 7 must be 0")
    var layer = NetLayer(inWidth: width, bias: -1)
    var tokenSpace = 0  # TOKEN_MLP / TOKEN_MIX: token buffer floats reserved before the output
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
        group.offset = int(word(where)); group.stride = int(word(where))
        group.count = int(word(where)); group.width = int(word(where))
        let valid = word(where)
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
    of lkTokenMlp.uint32:
      layer.kind = lkTokenMlp
      let t = int(q[0])
      let segments = int(q[1])
      let layers = int(q[4])
      if q[5] != 0: net2Error(where & "unused parameter 5 must be 0")
      tokenNorm()
      if t notin 1..MaxAttnTokens: net2Error(where & "TOKEN_MLP tokens must be 1.." & $MaxAttnTokens)
      if segments notin 1..MaxTokenSegments: net2Error(where & "TOKEN_MLP segments must be 1.." & $MaxTokenSegments)
      if layers notin 1..MaxTokenMlpLayers: net2Error(where & "TOKEN_MLP layers must be 1.." & $MaxTokenMlpLayers)
      layer.tokens = t
      var tokenIn = 0
      for g in 0..<segments:
        var s: TokenSegment
        s.offset = int(word(where)); s.stride = int(word(where)); s.length = int(word(where))
        if s.length notin 1..inputs or s.stride notin 0..inputs:
          net2Error(where & "TOKEN_MLP segment " & $g & " length/stride")
        if s.offset > inputs or (t-1)*s.stride + s.length > inputs - s.offset:
          net2Error(where & "TOKEN_MLP segment " & $g & " outside the input")
        tokenIn += s.length
        layer.segments.add s
      if tokenIn > MaxTokenInput: net2Error(where & "TOKEN_MLP token input exceeds " & $MaxTokenInput)
      if q[2] == AttnAlwaysValid:
        if q[3] != 0: net2Error(where & "TOKEN_MLP always-valid tokens need valid index 0")
        layer.validSegment = -1
      elif int(q[2]) < segments and int(q[3]) < layer.segments[int(q[2])].length:
        layer.validSegment = int(q[2]); layer.validIndex = int(q[3])
      else: net2Error(where & "TOKEN_MLP valid flag outside the token")
      layer.mlpWidths = @[tokenIn]
      for l in 0..<layers:
        let o = int(word(where))
        if o notin 1..MaxTokenModel: net2Error(where & "TOKEN_MLP widths must be 1.." & $MaxTokenModel)
        layer.mlpWidths.add o
      layer.weight = net.weights.len
      for l in 1..layers:
        net.readWeights(data, p, layer.mlpWidths[l]*layer.mlpWidths[l-1] + layer.mlpWidths[l])
        if layer.norm: net.readWeights(data, p, 2*layer.mlpWidths[l])  # gain, shift
      let d = layer.mlpWidths[^1]
      layer.tokenWidth = d
      tokenSpace = t*d + t
      layer.outWidth = 2*d
      var widest = 0
      for o in layer.mlpWidths: widest = max(widest, o)
      work = max(work, tokenIn + 2*widest)
      layer.operations = tokenMlpOps(t, layer.mlpWidths)
      if layer.norm: layer.operations += tokenNormOps(t, layer.mlpWidths[1..^1])
    of lkTokenMix.uint32:
      layer.kind = lkTokenMix
      layer.source = int(q[0])
      let z = int(q[1])
      for j in 2..5:
        if q[j] != 0: net2Error(where & "unused parameter " & $j & " must be 0")
      tokenNorm()
      if layer.source >= k or net.layers[layer.source].kind notin {lkTokenMlp, lkEntityAttn}:
        net2Error(where & "TOKEN_MIX source must name an earlier TOKEN_MLP or ENTITY_ATTN layer")
      if z notin 1..MaxTokenModel: net2Error(where & "TOKEN_MIX width must be 1.." & $MaxTokenModel)
      net.exposeTokens(layer.source, scratch)
      let src = net.layers[layer.source]
      layer.tokens = src.tokens
      layer.tokenWidth = z
      layer.weight = net.weights.len
      net.readWeights(data, p, z*src.tokenWidth + z + z*width)
      if layer.norm: net.readWeights(data, p, 2*z)  # gain, shift
      tokenSpace = layer.tokens*z
      layer.outWidth = width + 2*z
      if layer.outWidth > MaxNet2Width: net2Error(where & "TOKEN_MIX output exceeds " & $MaxNet2Width)
      work = max(work, z)
      layer.operations = tokenMixOps(layer.tokens, src.tokenWidth, width, z)
      if layer.norm: layer.operations += tokenNormOps(layer.tokens, [z])
    of lkPointer.uint32:
      layer.kind = lkPointer
      layer.source = int(q[0])
      layer.length = int(q[1])  # the logit offset of token 0
      unused(2)
      if layer.source >= k or net.layers[layer.source].kind notin {lkTokenMix, lkTokenMlp, lkEntityAttn}:
        net2Error(where & "POINTER source must name an earlier TOKEN_MIX, TOKEN_MLP or ENTITY_ATTN layer")
      net.exposeTokens(layer.source, scratch)
      let src = net.layers[layer.source]
      layer.tokens = src.tokens
      if layer.length > width or layer.tokens > width - layer.length:
        net2Error(where & "POINTER offset + tokens exceeds width " & $width)
      layer.weight = net.weights.len
      net.readWeights(data, p, src.tokenWidth + 1)
      layer.outWidth = width
      layer.operations = pointerOps(layer.tokens, src.tokenWidth, width)
    of lkSegmentNear.uint32:
      layer.kind = lkSegmentNear
      let t = int(q[0])
      var near = SegmentNearSpec(base: int(q[1]), stride: int(q[2]), xIndex: int(q[3]), zIndex: int(q[4]),
        validIndex: int(q[5]), excludeIndex: (if q[6] == AttnAlwaysValid: -1 else: int(q[6])),
        candidateIndex: int(q[7]))
      let scaleX = cast[float32](readU32(data, p))
      let scaleZ = cast[float32](readU32(data, p))
      let radius = cast[float32](readU32(data, p))
      near.dstOffset = int(word(where)); near.dstStride = int(word(where))
      if k != 0: net2Error(where & "SEGMENT_NEAR must be layer 0")
      if t notin 1..MaxAttnTokens: net2Error(where & "SEGMENT_NEAR tokens must be 1.." & $MaxAttnTokens)
      if near.stride notin 1..inputs: net2Error(where & "SEGMENT_NEAR stride must be 1.." & $inputs)
      if near.base > inputs or t*near.stride > inputs - near.base:
        net2Error(where & "SEGMENT_NEAR tokens outside the input")
      if near.xIndex >= near.stride or near.zIndex >= near.stride or near.validIndex >= near.stride or
          near.excludeIndex >= near.stride or near.candidateIndex >= near.stride:
        net2Error(where & "SEGMENT_NEAR index outside the token")
      if not finite(scaleX) or not (scaleX > 0'f32) or not finite(scaleZ) or not (scaleZ > 0'f32):
        net2Error(where & "SEGMENT_NEAR scales must be finite and positive")
      if not finite(radius) or not (radius >= 0'f32):
        net2Error(where & "SEGMENT_NEAR radius must be finite and >= 0")
      if near.dstStride notin (if t == 1: 0 else: 1)..inputs or near.dstOffset >= inputs or
          (t-1)*near.dstStride >= inputs - near.dstOffset:
        net2Error(where & "SEGMENT_NEAR flags outside the input")
      near.scaleX = float64(scaleX); near.scaleZ = float64(scaleZ); near.radius = float64(radius)
      layer.near = near
      layer.tokens = t
      layer.outWidth = inputs
      layer.operations = segmentNearOps(inputs, t)
    of lkPad.uint32:
      layer.kind = lkPad
      layer.source = int(q[0])   # where the zeros go
      layer.length = int(q[1])   # how many
      unused(2)
      if layer.source > width: net2Error(where & "PAD position beyond width " & $width)
      if layer.length notin 0..MaxNet2Width: net2Error(where & "PAD length must be 0.." & $MaxNet2Width)
      layer.outWidth = width + layer.length
      if layer.outWidth > MaxNet2Width: net2Error(where & "PAD output exceeds " & $MaxNet2Width)
      layer.operations = int64(layer.outWidth)
    of lkAttnPool.uint32:
      layer.kind = lkAttnPool
      layer.source = int(q[0])
      layer.heads = int(q[1]); layer.keyWidth = int(q[2]); layer.valueWidth = int(q[3])
      unused(4)
      if layer.source >= k or net.layers[layer.source].kind notin {lkTokenMlp, lkTokenMix, lkEntityAttn}:
        net2Error(where & "ATTN_POOL source must name an earlier TOKEN_MLP, TOKEN_MIX or ENTITY_ATTN layer")
      if layer.heads notin 1..MaxAttnPoolHeads: net2Error(where & "ATTN_POOL heads must be 1.." & $MaxAttnPoolHeads)
      if layer.keyWidth notin 1..MaxTokenModel or layer.valueWidth notin 1..MaxTokenModel:
        net2Error(where & "ATTN_POOL key and value widths must be 1.." & $MaxTokenModel)
      if layer.heads*layer.keyWidth > MaxAttnPoolWidth or layer.heads*layer.valueWidth > MaxAttnPoolWidth:
        net2Error(where & "ATTN_POOL heads x width must be at most " & $MaxAttnPoolWidth)
      net.exposeTokens(layer.source, scratch)
      let src = net.layers[layer.source]
      layer.tokens = src.tokens
      let hk = layer.heads*layer.keyWidth
      let hv = layer.heads*layer.valueWidth
      layer.weight = net.weights.len
      net.readWeights(data, p, hk*width + hk + hk*src.tokenWidth + hk + hv*src.tokenWidth + hv)
      layer.outWidth = width + hv
      if layer.outWidth > MaxNet2Width: net2Error(where & "ATTN_POOL output exceeds " & $MaxNet2Width)
      work = max(work, 2*hk + layer.tokens*layer.heads + hv)
      layer.operations = attnPoolOps(layer.tokens, src.tokenWidth, width, layer.heads, layer.keyWidth,
        layer.valueWidth)
    else:
      net2Error(where & "unknown layer type " & $code)
    if tokenSpace > 0:
      layer.tokenBuffer = scratch
      scratch += tokenSpace
    case layer.kind
    of lkTokenMlp: layer.validBuffer = layer.tokenBuffer + layer.tokens*layer.tokenWidth
    of lkTokenMix, lkPointer, lkAttnPool: layer.validBuffer = net.layers[layer.source].validBuffer
    else: discard
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

proc peekContracts*(data: string): (string, string) =
  ## The observation and action contract hashes a model.bin carries, read from its header
  ## without loading it ("" for both when the header is malformed or truncated).
  try:
    var p = 8
    if data.len >= 8 and data[0..<8] == ActorMagic:
      p = 8 + 6*4
    elif data.len >= 8 and data[0..<8] == Net2Magic:
      p = 8 + 3*4
      let heads = int(readU32(data, p))
      if heads notin 1..32: return ("", "")
      p += 4*heads
    else: return ("", "")
    if p + 128 > data.len: return ("", "")
    (data[p..<p+64], data[p+64..<p+128])
  except ValueError: ("", "")

proc readActorFile*(path: string): string =
  ## A model.bin's bytes, refused over the format's size bound (loadActorFile's check).
  var magic = newString(8)
  var file = open(path)
  let got = file.readChars(toOpenArray(magic, 0, 7))
  file.close()
  let limit = if got == 8 and magic == Net2Magic: int64(MaxNet2FileBytes)
              else: int64(32+128+128+MaxActorParameters*4)
  if getFileSize(path) > limit:
    raise newException(ValueError, "neural actor file too large")
  readFile(path)

proc loadActor*(data: string, layout: ActorLayout): Actor =
  ## A model.bin, its PWNET002 layout words (if any) resolved against `layout`.
  if data.len >= 8 and data[0..<8] == Net2Magic: loadActor2(data, layout)
  else: loadActor1(data)
proc loadActor*(data: string): Actor =
  ## A model.bin with no match layout: a layout word is an error.
  loadActor(data, ActorLayout())

proc loadActorFile*(path: string, layout = ActorLayout()): Actor =
  var magic = newString(8)
  var file = open(path)
  let got = file.readChars(toOpenArray(magic, 0, 7))
  file.close()
  let limit = if got == 8 and magic == Net2Magic: int64(MaxNet2FileBytes)
              else: int64(32+128+128+MaxActorParameters*4)
  if getFileSize(path) > limit:
    raise newException(ValueError, "neural actor file too large")
  loadActor(readFile(path), layout)

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

proc layerNorm(v: F32s, n: int, gain, shift: F32s, eps: float32) =
  ## In place: mu = sum/n, var = (sum of (v-mu)^2)/n, r = 1/sqrt(var + eps), v = ((v-mu)*r)*gain + shift.
  var total = 0'f32
  for i in 0..<n: total += v[i]
  let mean = total / float32(n)
  var squares = 0'f32
  for i in 0..<n:
    let c = v[i] - mean
    squares += c*c
  let r = 1'f32 / sqrt(squares / float32(n) + eps)
  for i in 0..<n:
    let c = v[i] - mean
    let scaled = c*r
    let gained = scaled*gain[i]
    v[i] = gained + shift[i]

proc reluInPlace(v: F32s, n: int) =
  for i in 0..<n:
    if not (v[i] > 0'f32): v[i] = 0'f32

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

proc entityAttention(layer: NetLayer, input, w, scratch, work, y: F32s) =
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
  if layer.exposeTokens:
    # The final token states and valid flags, for a later TOKEN_MIX / POINTER / ATTN_POOL.
    let tokens = scratch.at(layer.tokenBuffer)
    let flags = scratch.at(layer.validBuffer)
    for i in 0..<t*d: tokens[i] = hs[i]
    for n in 0..<t: flags[n] = valid[n]
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

proc tokenPools(buffer, valid: F32s, t, d: int, y: F32s) =
  ## [masked mean, masked max] over the valid tokens' rows of buffer [t, d] (ENTITY_ATTN's pools: the
  ## mean is sum * (1/count), the max takes the first valid token first; zeros with no valid token).
  var count = 0
  for n in 0..<t:
    if valid[n] != 0'f32: inc count
  for c in 0..<2*d: y[c] = 0'f32
  if count == 0: return
  let inverse = 1'f32 / float32(count)
  for c in 0..<d:
    var total = 0'f32
    var best = 0'f32
    var first = true
    for n in 0..<t:
      if valid[n] == 0'f32: continue
      let v = buffer[n*d + c]
      total += v
      if first or v > best:
        best = v
        first = false
    y[c] = total*inverse
    y[d+c] = best

proc tokenMlp(layer: NetLayer, input, w, scratch, work, y: F32s) =
  let t = layer.tokens
  let d = layer.tokenWidth
  let buffer = scratch.at(layer.tokenBuffer)
  let valid = scratch.at(layer.validBuffer)
  let gathered = work
  var widest = 0
  for o in layer.mlpWidths: widest = max(widest, o)
  let a = work.at(layer.mlpWidths[0])
  let b = a.at(widest)
  for n in 0..<t:
    var ok = true
    if layer.validSegment >= 0:
      let s = layer.segments[layer.validSegment]
      ok = input[s.offset + n*s.stride + layer.validIndex] > 0.5'f32
    valid[n] = if ok: 1'f32 else: 0'f32
    let row = buffer.at(n*d)
    if not ok:
      for c in 0..<d: row[c] = 0'f32
      continue
    var k = 0
    for s in layer.segments:
      let start = s.offset + n*s.stride
      for i in 0..<s.length:
        gathered[k] = input[start+i]
        inc k
    var x = gathered
    var off = layer.weight
    for l in 1..<layer.mlpWidths.len:
      let n0 = layer.mlpWidths[l-1]
      let n1 = layer.mlpWidths[l]
      let target = if l == layer.mlpWidths.len-1: row elif l mod 2 == 1: a else: b
      if layer.norm:
        dense(x, n0, w.at(off), w.at(off + n1*n0), n1, false, target)
        layerNorm(target, n1, w.at(off + n1*n0 + n1), w.at(off + n1*n0 + 2*n1), layer.eps)
        reluInPlace(target, n1)
        off += n1*n0 + 3*n1
      else:
        dense(x, n0, w.at(off), w.at(off + n1*n0), n1, true, target)
        off += n1*n0 + n1
      x = target
  checkFinite(buffer, t*d)
  tokenPools(buffer, valid, t, d, y)

proc tokenMix(layer: NetLayer, source: NetLayer, x, w, scratch, work, y: F32s) =
  let t = layer.tokens
  let z = layer.tokenWidth
  let d = source.tokenWidth
  let width = layer.inWidth
  let tokens = scratch.at(source.tokenBuffer)
  let valid = scratch.at(layer.validBuffer)
  let buffer = scratch.at(layer.tokenBuffer)
  let ue = w.at(layer.weight)
  let bias = ue.at(z*d)
  let uy = bias.at(z)
  let u = work
  dense(x, width, uy, nil, z, false, u)
  for n in 0..<t:
    let row = buffer.at(n*z)
    if valid[n] == 0'f32:
      for o in 0..<z: row[o] = 0'f32
      continue
    let e = tokens.at(n*d)
    for o in 0..<z:
      var sum = 0'f32
      for i in 0..<d: sum += e[i]*ue[o*d+i]
      sum = sum + bias[o]
      sum = sum + u[o]
      if layer.norm: row[o] = sum
      else: row[o] = if sum > 0'f32: sum else: 0'f32
    if layer.norm:
      let gain = uy.at(z*width)
      layerNorm(row, z, gain, gain.at(z), layer.eps)
      reluInPlace(row, z)
  checkFinite(buffer, t*z)
  for i in 0..<width: y[i] = x[i]
  tokenPools(buffer, valid, t, z, y.at(width))

proc pointerHead(layer: NetLayer, source: NetLayer, x, w, scratch, y: F32s) =
  let z = source.tokenWidth
  let buffer = scratch.at(source.tokenBuffer)
  let valid = scratch.at(layer.validBuffer)
  let v = w.at(layer.weight)
  let c = v[z]
  for i in 0..<layer.outWidth: y[i] = x[i]
  for n in 0..<layer.tokens:
    if valid[n] == 0'f32: continue
    var sum = 0'f32
    for i in 0..<z: sum += buffer[n*z+i]*v[i]
    y[layer.length+n] = y[layer.length+n] + (sum + c)

proc attnPool(layer: NetLayer, source: NetLayer, x, w, scratch, work, y: F32s) =
  ## Cross-attention pooling (neural_actor.md, ATTN_POOL): a query from the current vector,
  ## keys and values from the source's valid token rows, per head a softmax over the valid
  ## tokens in token order (ENTITY_ATTN's rules), y = [x, pooled values].
  let t = layer.tokens
  let z = source.tokenWidth
  let width = layer.inWidth
  let heads = layer.heads
  let kw = layer.keyWidth
  let vw = layer.valueWidth
  let hk = heads*kw
  let hv = heads*vw
  let tokens = scratch.at(source.tokenBuffer)
  let valid = scratch.at(layer.validBuffer)
  let wq = w.at(layer.weight)
  let bq = wq.at(hk*width)
  let wk = bq.at(hk)
  let bk = wk.at(hk*z)
  let wv = bk.at(hk)
  let bv = wv.at(hv*z)
  let q = work
  let key = q.at(hk)
  let score = key.at(hk)       # [t, heads]
  let value = score.at(t*heads)  # one token's values [hv]
  for i in 0..<width: y[i] = x[i]
  let pooled = y.at(width)
  for c in 0..<hv: pooled[c] = 0'f32
  var count = 0
  for n in 0..<t:
    if valid[n] != 0'f32: inc count
  if count == 0: return
  dense(x, width, wq, bq, hk, false, q)
  let scale = 1'f32 / sqrt(float32(kw))
  for n in 0..<t:
    if valid[n] == 0'f32: continue
    dense(tokens.at(n*z), z, wk, bk, hk, false, key)
    for j in 0..<heads:
      var dot = 0'f32
      for c in 0..<kw: dot += q[j*kw+c]*key[j*kw+c]
      score[n*heads+j] = dot*scale
  for j in 0..<heads:
    var top = 0'f32
    var first = true
    for n in 0..<t:
      if valid[n] == 0'f32: continue
      let s = score[n*heads+j]
      if first or s > top:
        top = s
        first = false
    var total = 0'f32
    for n in 0..<t:
      if valid[n] == 0'f32: continue
      let e = exp(score[n*heads+j] - top)
      score[n*heads+j] = e
      total += e
    let inverse = 1'f32 / total
    for n in 0..<t:
      if valid[n] == 0'f32: continue
      score[n*heads+j] = score[n*heads+j]*inverse
  for n in 0..<t:
    if valid[n] == 0'f32: continue
    dense(tokens.at(n*z), z, wv, bv, hv, false, value)
    for j in 0..<heads:
      let weight = score[n*heads+j]
      for c in 0..<vw: pooled[j*vw+c] += weight*value[j*vw+c]

proc segmentNear(layer: NetLayer, input, y: F32s) =
  ## The input view: y = input, then token n's flag at y[dstOffset + n*dstStride]. Geometry in float64, operation
  ## by operation as neural_actor.md writes it (one product or sum per statement, so no contraction).
  let s = layer.near
  let t = layer.tokens
  for i in 0..<layer.inWidth: y[i] = input[i]
  var valid, candidate: array[MaxAttnTokens, bool]
  var vx, vz: array[MaxAttnTokens, float64]
  for n in 0..<t:
    let at = s.base + n*s.stride
    var ok = input[at + s.validIndex] > 0.5'f32
    if ok and s.excludeIndex >= 0 and input[at + s.excludeIndex] > 0.5'f32: ok = false
    valid[n] = ok
    candidate[n] = ok and input[at + s.candidateIndex] > 0.5'f32
    vx[n] = float64(input[at + s.xIndex]) * s.scaleX
    vz[n] = float64(input[at + s.zIndex]) * s.scaleZ
  let r2 = s.radius * s.radius
  for n in 0..<t:
    var flag = false
    if valid[n]:
      let xx = vx[n] * vx[n]
      let zz = vz[n] * vz[n]
      let l2 = xx + zz
      if l2 > 0.0:
        for m in 0..<t:
          if not candidate[m]: continue
          let px = vx[m] * vx[n]
          let pz = vz[m] * vz[n]
          let d = px + pz
          if d < 0.0 or d > l2: continue
          let ex2 = vx[m] * vx[m]
          let ez2 = vz[m] * vz[m]
          let e2 = ex2 + ez2
          let dd = d * d
          let q = dd / l2
          let perp = e2 - q
          if perp <= r2:
            flag = true
            break
    y[s.dstOffset + n*s.dstStride] = if flag: 1'f32 else: 0'f32

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
  var input = cast[F32s](unsafeAddr obs[0])  # the observation, or SEGMENT_NEAR's view once layer 0 ran
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
      entityAttention(layer[], input, w, scratch, scratch.at(net.work), y)
    of lkConcatInput:
      for i in 0..<layer.inWidth: y[i] = x[i]
      for i in 0..<layer.length: y[layer.inWidth+i] = input[layer.source+i]
    of lkTokenMlp:
      tokenMlp(layer[], input, w, scratch, scratch.at(net.work), y)
    of lkTokenMix:
      tokenMix(layer[], net.layers[layer.source], x, w, scratch, scratch.at(net.work), y)
    of lkPointer:
      pointerHead(layer[], net.layers[layer.source], x, w, scratch, y)
    of lkSegmentNear:
      segmentNear(layer[], input, y)
    of lkAttnPool:
      attnPool(layer[], net.layers[layer.source], x, w, scratch, scratch.at(net.work), y)
    of lkPad:
      # y = x[0 ..< at], `length` zeros, x[at ..< width]: room for match-sized pointer heads.
      let at = layer.source
      for i in 0..<at: y[i] = x[i]
      for i in 0..<layer.length: y[at+i] = 0'f32
      for i in at..<layer.inWidth: y[layer.length+i] = x[i]
    checkFinite(y, layer.outWidth)
    x = y
    if layer.kind == lkSegmentNear: input = y  # every later layer that reads "the input" reads the view
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
