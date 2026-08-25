## FX mesh laboratory: procedural VFX meshes driven by one fx shader.
## The CPU builds shapes (rings, arcs, shells, ribbons, helices...) with
## VFX-friendly polyflow, shape-default UVs, and packed per-vertex animation
## coordinates (along-axis, radial distance, angle, random). A single shader
## pair then animates and shades every effect: UV scroll, dissolve with edge
## glow, twist, wave, ripple, pulse, spin, and expand over the effect life.
## Shape topology and UV layout are ported from PudinKiller's VFXMeshLab
## (MIT, https://github.com/PudinKiller/VFXMeshLab).
## Run from the polyworld root: nim r experiments/fxmesh/fxmesh.nim

import
  std/[math, os, strformat, strutils, tables, times],
  bumpy, jsony, shady, silky, vmath

when defined(takeScreenshot):
  import pixie

const
  WindowSize = ivec2(1280, 800)
  PanelPosition = vec2(10.0'f, 10.0'f)
  PanelSize = vec2(350.0'f, 760.0'f)
  FxDirectory = "experiments/fxmesh"
  PresetDirectory = FxDirectory / "presets"
  PresetPaths = [
    PresetDirectory / "shockwave.json",
    PresetDirectory / "slash.json",
    PresetDirectory / "portal.json",
    PresetDirectory / "beam.json",
    PresetDirectory / "shield.json",
    PresetDirectory / "tornado.json"
  ]
  MinimumDimension = 0.0001'f
  FullArcThreshold = 359.999'f
  MaximumSegments = 128
  TextureSize = 256
  Tau = 6.28318530718'f

type
  FxError = object of CatchableError

  FxShape = enum
    QuadShape
    DiscShape
    RingShape
    ArcShape
    ConeShape
    CylinderShape
    TubeShape
    SphereShape
    HemisphereShape
    TorusShape
    BoxShape
    RibbonShape
    CrossPlanesShape
    HelixShape

  FxAxis = enum
    XAxis
    YAxis
    ZAxis

  FxPivot = enum
    CenterPivot
    StartPivot
    EndPivot

  ArcOrigin = enum
    InnerOrigin
    MiddleOrigin
    OuterOrigin

  FxTexture = enum
    SoftTexture
    NoiseTexture
    StreakTexture
    CellTexture
    CheckerTexture

  GradientSource = enum
    LifeGradient
    AxisGradient
    RadialGradient
    AngleGradient

  SweepSource = enum
    SweepU
    SweepV
    SweepAxis
    SweepRadial
    SweepAngle

  BlendMode = enum
    AlphaBlend
    AdditiveBlend

  PanelTab = enum
    ShapeTab
    BuildTab
    AnimTab
    LookTab
    ColorTab

  FxUniform = enum
    ViewProjectionUniform
    ModelUniform
    TimeUniform
    LifeUniform
    AlphaUniform
    DissolveUniform
    DissolveEdgeUniform
    SpinSpeedUniform
    TwistAngleUniform
    WaveAmpUniform
    WaveFreqUniform
    WaveSpeedUniform
    RippleAmpUniform
    RippleFreqUniform
    RippleSpeedUniform
    InflateUniform
    PulseAmpUniform
    PulseSpeedUniform
    ExpandStartUniform
    ExpandEndUniform
    ExpandPowerUniform
    SweepSourceUniform
    SweepBandUniform
    SweepSoftUniform
    UvScaleUniform
    ScrollUniform
    NoiseScaleUniform
    GradientSourceUniform
    StartColorUniform
    EndColorUniform
    EdgeColorUniform
    PatternUniform
    NoiseUniform

  FxSettings = object
    name: string
    ## Shape topology.
    shape: FxShape
    axis: FxAxis
    pivot: FxPivot
    radius: float32
    innerRadius: float32
    topRadius: float32
    thickness: float32
    width: float32
    length: float32
    height: float32
    size: Vec3
    arcDegrees: float32
    angleOffset: float32
    turns: float32
    pitch: float32
    planeCount: int
    radialSegments: int
    heightSegments: int
    widthSegments: int
    lengthSegments: int
    capStart: bool
    capEnd: bool
    widthStart: float32
    widthEnd: float32
    widthPower: float32
    arcCrescent: float32
    arcPower: float32
    arcOrigin: ArcOrigin
    ## Static build modifiers, applied taper, bend, noise, spherize, flatten.
    taper: float32
    bend: float32
    noiseAmp: float32
    noiseFreq: float32
    noiseSeed: int
    spherize: float32
    flatten: float32
    falloffPower: float32
    ## Shader animation.
    duration: float32
    loop: bool
    spinSpeed: float32
    twistAngle: float32
    waveAmp: float32
    waveFreq: float32
    waveSpeed: float32
    rippleAmp: float32
    rippleFreq: float32
    rippleSpeed: float32
    inflate: float32
    pulseAmp: float32
    pulseSpeed: float32
    expandStart: float32
    expandEnd: float32
    expandPower: float32
    sweepSource: SweepSource
    sweepBand: float32
    sweepSoft: float32
    ## Look.
    texture: FxTexture
    blendMode: BlendMode
    gradientSource: GradientSource
    uvScale: Vec2
    scroll: Vec2
    noiseScale: float32
    startColor: Vec4
    endColor: Vec4
    edgeColor: Vec4
    fadeIn: float32
    fadeOut: float32
    dissolveIn: float32
    dissolveOut: float32
    dissolveEdge: float32

  MeshDraft = object
    positions: seq[Vec3]
    uvs: seq[Vec2]
    triangles: seq[int]

  FxRenderer = object
    program: GLuint
    locations: array[FxUniform, GLint]
    vertexArray: GLuint
    vertexBuffer: GLuint
    indexBuffer: GLuint
    patternTextures: array[FxTexture, GLuint]
    indexCount: int
    vertexCount: int

  CameraState = object
    yaw: float32
    pitch: float32
    distance: float32
    target: Vec3
    eye: Vec3
    right: Vec3
    up: Vec3
    forward: Vec3
    rotating: bool
    panning: bool

const UniformNames: array[FxUniform, string] = [
  "uViewProjection",
  "uModel",
  "uTime",
  "uLifeT",
  "uAlpha",
  "uDissolve",
  "uDissolveEdge",
  "uSpinSpeed",
  "uTwistAngle",
  "uWaveAmp",
  "uWaveFreq",
  "uWaveSpeed",
  "uRippleAmp",
  "uRippleFreq",
  "uRippleSpeed",
  "uInflate",
  "uPulseAmp",
  "uPulseSpeed",
  "uExpandStart",
  "uExpandEnd",
  "uExpandPower",
  "uSweepSource",
  "uSweepBand",
  "uSweepSoft",
  "uUvScale",
  "uScroll",
  "uNoiseScale",
  "uGradientSource",
  "uStartColor",
  "uEndColor",
  "uEdgeColor",
  "uPattern",
  "uNoise"
]

## Preset serialization

proc parseHook(source: string, index: var int, value: var Vec2) =
  ## Deserializes a two-component vector from a JSON array.
  var components: array[2, float32]
  source.parseHook(index, components)
  value = vec2(components[0], components[1])

proc parseHook(source: string, index: var int, value: var Vec3) =
  ## Deserializes a three-component vector from a JSON array.
  var components: array[3, float32]
  source.parseHook(index, components)
  value = vec3(components[0], components[1], components[2])

proc parseHook(source: string, index: var int, value: var Vec4) =
  ## Deserializes a four-component vector from a JSON array.
  var components: array[4, float32]
  source.parseHook(index, components)
  value = vec4(components[0], components[1], components[2], components[3])

proc dumpHook(json: var string, value: Vec2) {.used.} =
  ## Serializes a two-component vector as a JSON array.
  json.dumpHook([value.x, value.y])

proc dumpHook(json: var string, value: Vec3) {.used.} =
  ## Serializes a three-component vector as a JSON array.
  json.dumpHook([value.x, value.y, value.z])

proc dumpHook(json: var string, value: Vec4) {.used.} =
  ## Serializes a four-component vector as a JSON array.
  json.dumpHook([value.x, value.y, value.z, value.w])

proc loadPreset(path: string): FxSettings {.raises: [FxError].} =
  ## Deserializes one complete JSON fx definition with jsony.
  var source: string
  try:
    source = readFile(path)
  except IOError as error:
    raise newException(FxError, "Unable to read " & path & ": " & error.msg)
  try:
    result = source.fromJson(FxSettings)
  except ValueError as error:
    raise newException(FxError, path & ": " & error.msg)
  if result.name.len == 0:
    raise newException(FxError, path & ": name cannot be empty")

proc loadPresets(): seq[FxSettings] {.raises: [FxError].} =
  ## Loads the stable ordered list displayed in the control panel.
  for path in PresetPaths:
    result.add loadPreset(path)

## Shape math helpers

proc finite(value, fallback: float32): float32 =
  ## Replaces NaN or infinite values with a safe fallback.
  if value != value or abs(value) == Inf:
    fallback
  else:
    value

proc positive(value: float32): float32 =
  ## Clamps a dimension to a small positive magnitude.
  max(MinimumDimension, abs(finite(value, 1.0'f)))

proc nonNegative(value: float32): float32 =
  ## Clamps a dimension to zero or above.
  max(0.0'f, abs(finite(value, 0.0'f)))

proc segmentCount(value, minimum: int): int =
  ## Clamps a resolution control to its topological minimum and global cap.
  clamp(value, minimum, MaximumSegments)

proc sanitizeArcDegrees(value: float32): float32 =
  ## Keeps arc sweeps inside one full turn and away from zero.
  result = clamp(finite(value, 360.0'f), -360.0'f, 360.0'f)
  if abs(result) < MinimumDimension:
    result = if result < 0.0'f: -MinimumDimension else: MinimumDimension

proc degreesToRadians(value: float32): float32 =
  ## Converts degrees to radians with a finite fallback.
  finite(value, 0.0'f) * PI / 180.0'f

proc evaluateWidth(s: FxSettings, t: float32): float32 =
  ## Evaluates the parametric width profile along the main axis.
  let
    power = max(finite(s.widthPower, 1.0'f), 0.01'f)
    value = mix(s.widthStart, s.widthEnd, pow(clamp(t, 0.0'f, 1.0'f), power))
  max(MinimumDimension, abs(finite(value, 1.0'f)))

proc evaluateWidthProfileU(u, widthScale: float32): float32 =
  ## Preserve-texel-density U so tapered rows keep one affine mapping.
  0.5'f + (u - 0.5'f) * widthScale

proc evaluateArcWidth(s: FxSettings, t: float32): float32 =
  ## Evaluates the angular width profile that makes crescents and slashes.
  let
    power = max(finite(s.arcPower, 1.0'f), 0.01'f)
    curved = pow(max(sin(PI * clamp(t, 0.0'f, 1.0'f)), 0.0'f), power)
  clamp(mix(1.0'f, curved, clamp(s.arcCrescent, 0.0'f, 1.0'f)), 0.0'f, 1.0'f)

proc arcOrigin01(origin: ArcOrigin): float32 =
  ## Maps the crescent collapse origin to an inner-to-outer fraction.
  case origin
  of InnerOrigin: 0.0'f
  of MiddleOrigin: 0.5'f
  of OuterOrigin: 1.0'f

proc stableRandom(index: int): float32 =
  ## Produces a repeatable zero-to-one random value per vertex index.
  var value = cast[uint32](index) + 0x9E3779B9'u32
  value = value xor (value shr 16)
  value = value * 0x7FEB352D'u32
  value = value xor (value shr 15)
  value = value * 0x846CA68B'u32
  value = value xor (value shr 16)
  (value and 0x00FFFFFF'u32).float32 / 16777215.0'f

proc hashNoise(x, y, z, seed: int): float32 =
  ## Hashes a lattice point to a repeatable minus-one-to-one value.
  var hash = cast[uint32](seed)
  hash = hash xor cast[uint32](x) * 0x8DA6B343'u32
  hash = hash xor cast[uint32](y) * 0xD8163841'u32
  hash = hash xor cast[uint32](z) * 0xCB1AB31F'u32
  hash = hash xor (hash shr 16)
  hash = hash * 0x7FEB352D'u32
  hash = hash xor (hash shr 15)
  hash = hash * 0x846CA68B'u32
  hash = hash xor (hash shr 16)
  (hash and 0x00FFFFFF'u32).float32 / 8388607.5'f - 1.0'f

proc smoothCurve(value: float32): float32 =
  ## Cubic smoothstep interpolation weight.
  value * value * (3.0'f - 2.0'f * value)

proc valueNoise(position: Vec3, seed: int): float32 =
  ## Trilinearly interpolated lattice value noise.
  let
    x0 = floor(position.x).int
    y0 = floor(position.y).int
    z0 = floor(position.z).int
    tx = smoothCurve(position.x - x0.float32)
    ty = smoothCurve(position.y - y0.float32)
    tz = smoothCurve(position.z - z0.float32)
    x00 = mix(hashNoise(x0, y0, z0, seed), hashNoise(x0 + 1, y0, z0, seed), tx)
    x10 = mix(
      hashNoise(x0, y0 + 1, z0, seed),
      hashNoise(x0 + 1, y0 + 1, z0, seed),
      tx
    )
    x01 = mix(
      hashNoise(x0, y0, z0 + 1, seed),
      hashNoise(x0 + 1, y0, z0 + 1, seed),
      tx
    )
    x11 = mix(
      hashNoise(x0, y0 + 1, z0 + 1, seed),
      hashNoise(x0 + 1, y0 + 1, z0 + 1, seed),
      tx
    )
  mix(mix(x00, x10, ty), mix(x01, x11, ty), tz)

proc fractalNoise(position: Vec3, frequency: float32, seed: int): float32 =
  ## Four-octave deterministic fractal value noise.
  var
    octaveFrequency = max(frequency, 0.01'f)
    amplitude = 1.0'f
    total = 0.0'f
    weight = 0.0'f
  for octave in 0 ..< 4:
    let offset = vec3(
      octave.float32 * 19.19'f,
      octave.float32 * -7.73'f,
      octave.float32 * 13.17'f
    )
    total += valueNoise(
      position * octaveFrequency + offset,
      seed + octave * 1013
    ) * amplitude
    weight += amplitude
    octaveFrequency *= 2.0'f
    amplitude *= 0.5'f
  total / weight

## Mesh draft

proc addVertex(draft: var MeshDraft, position: Vec3, uv: Vec2): int =
  ## Appends one vertex with its shape-default UV and returns its index.
  result = draft.positions.len
  draft.positions.add position
  draft.uvs.add uv

proc addTriangle(draft: var MeshDraft, a, b, c: int) =
  ## Appends one triangle by vertex indices.
  draft.triangles.add a
  draft.triangles.add b
  draft.triangles.add c

proc bounds(draft: MeshDraft): tuple[low, high: Vec3] =
  ## Returns the axis-aligned bounds of the draft positions.
  result.low = vec3(float32.high, float32.high, float32.high)
  result.high = vec3(float32.low, float32.low, float32.low)
  for position in draft.positions:
    result.low = min(result.low, position)
    result.high = max(result.high, position)
  if draft.positions.len == 0:
    result.low = vec3(0.0'f)
    result.high = vec3(0.0'f)

## Shape generators. All shapes are authored around a canonical Y axis; the
## selected main axis becomes a model-matrix rotation at draw time so the
## shader can animate in one consistent space.

proc addRadialStrip(
  draft: var MeshDraft,
  innerStart, outerStart, radialSegments: int,
  positiveWinding: bool
) =
  ## Connects two concentric vertex rings with a quad strip.
  for segment in 0 ..< radialSegments:
    let
      a = innerStart + segment
      b = outerStart + segment
      c = a + 1
      d = b + 1
    if positiveWinding:
      draft.addTriangle(a, c, b)
      draft.addTriangle(b, c, d)
    else:
      draft.addTriangle(a, b, c)
      draft.addTriangle(b, d, c)

proc generateQuad(s: FxSettings, draft: var MeshDraft) =
  ## Flat subdivided card in the XZ plane with a width profile along Z.
  let
    width = positive(s.width)
    length = positive(s.length)
    widthSegments = segmentCount(s.widthSegments, 1)
    lengthSegments = segmentCount(s.lengthSegments, 1)
  for y in 0 .. lengthSegments:
    let
      v = y.float32 / lengthSegments.float32
      z = mix(-length * 0.5'f, length * 0.5'f, v)
      widthScale = evaluateWidth(s, v)
      rowWidth = width * widthScale
    for x in 0 .. widthSegments:
      let u = x.float32 / widthSegments.float32
      discard draft.addVertex(
        vec3(mix(-rowWidth * 0.5'f, rowWidth * 0.5'f, u), 0.0'f, z),
        vec2(evaluateWidthProfileU(u, widthScale), v)
      )
  let stride = widthSegments + 1
  for y in 0 ..< lengthSegments:
    for x in 0 ..< widthSegments:
      let
        a = y * stride + x
        b = a + 1
        c = a + stride
        d = c + 1
      draft.addTriangle(a, c, b)
      draft.addTriangle(b, c, d)

proc generateDisc(
  s: FxSettings,
  draft: var MeshDraft,
  requestedArcDegrees: float32
) =
  ## Filled fan of concentric rings with planar-polar UVs.
  let
    radialSegments = segmentCount(s.radialSegments, 3)
    radiusSegments = segmentCount(s.widthSegments, 1)
    radius = positive(s.radius)
    arcDegrees = sanitizeArcDegrees(requestedArcDegrees)
    angleOffset = degreesToRadians(s.angleOffset)
    arcRadians = degreesToRadians(arcDegrees)
    positiveWinding = arcRadians >= 0.0'f
    center = draft.addVertex(vec3(0.0'f), vec2(0.5'f, 0.5'f))
  var previousRing = -1
  for ring in 1 .. radiusSegments:
    let
      radialT = ring.float32 / radiusSegments.float32
      ringRadius = radius * radialT
      ringStart = draft.positions.len
    for segment in 0 .. radialSegments:
      let
        angularT = segment.float32 / radialSegments.float32
        angle = angleOffset + arcRadians * angularT
        cosine = cos(angle)
        sine = sin(angle)
      discard draft.addVertex(
        vec3(cosine * ringRadius, 0.0'f, sine * ringRadius),
        vec2(0.5'f + cosine * radialT * 0.5'f, 0.5'f + sine * radialT * 0.5'f)
      )
    if ring == 1:
      for segment in 0 ..< radialSegments:
        let
          current = ringStart + segment
          next = current + 1
        if positiveWinding:
          draft.addTriangle(center, next, current)
        else:
          draft.addTriangle(center, current, next)
    else:
      draft.addRadialStrip(
        previousRing,
        ringStart,
        radialSegments,
        positiveWinding
      )
    previousRing = ringStart

proc generateRing(s: FxSettings, draft: var MeshDraft, partialArc: bool) =
  ## Flat annulus with angular U and inner-to-outer radial V.
  let
    radialSegments = segmentCount(s.radialSegments, 3)
    radiusSegments = segmentCount(s.widthSegments, 1)
    firstRadius = nonNegative(s.innerRadius)
    secondRadius = positive(s.radius)
    innerRadius = min(firstRadius, secondRadius)
    arcDegrees = if partialArc: sanitizeArcDegrees(s.arcDegrees) else: 360.0'f
  var outerRadius = max(firstRadius, secondRadius)
  if outerRadius - innerRadius < MinimumDimension:
    outerRadius = innerRadius + MinimumDimension
  if innerRadius < MinimumDimension:
    generateDisc(s, draft, arcDegrees)
    return
  let
    arcRadians = degreesToRadians(arcDegrees)
    angleOffset = degreesToRadians(s.angleOffset)
    positiveWinding = arcRadians >= 0.0'f
    stride = radialSegments + 1
  for ring in 0 .. radiusSegments:
    let
      radialT = ring.float32 / radiusSegments.float32
      ringRadius = mix(innerRadius, outerRadius, radialT)
    for segment in 0 .. radialSegments:
      let
        angularT = segment.float32 / radialSegments.float32
        angle = angleOffset + arcRadians * angularT
      discard draft.addVertex(
        vec3(cos(angle) * ringRadius, 0.0'f, sin(angle) * ringRadius),
        vec2(angularT, radialT)
      )
  for ring in 0 ..< radiusSegments:
    draft.addRadialStrip(
      ring * stride,
      (ring + 1) * stride,
      radialSegments,
      positiveWinding
    )

proc addVariableArcStrip(
  draft: var MeshDraft,
  currentStart: int,
  currentCollapsed: bool,
  nextStart: int,
  nextCollapsed: bool,
  radiusSegments: int,
  positiveWinding: bool
) =
  ## Connects two arc columns, fanning where a column collapses to a point.
  if currentCollapsed and nextCollapsed:
    return
  for ring in 0 ..< radiusSegments:
    if currentCollapsed:
      if positiveWinding:
        draft.addTriangle(currentStart, nextStart + ring, nextStart + ring + 1)
      else:
        draft.addTriangle(currentStart, nextStart + ring + 1, nextStart + ring)
    elif nextCollapsed:
      if positiveWinding:
        draft.addTriangle(currentStart + ring, nextStart, currentStart + ring + 1)
      else:
        draft.addTriangle(currentStart + ring, currentStart + ring + 1, nextStart)
    else:
      let
        a = currentStart + ring
        b = a + 1
        c = nextStart + ring
        d = c + 1
      if positiveWinding:
        draft.addTriangle(a, c, b)
        draft.addTriangle(b, c, d)
      else:
        draft.addTriangle(a, b, c)
        draft.addTriangle(b, d, c)

proc generateArc(s: FxSettings, draft: var MeshDraft) =
  ## Partial annulus, optionally tapering to crescent points along its sweep.
  if s.arcCrescent <= MinimumDimension:
    generateRing(s, draft, true)
    return
  let
    angularSegments = segmentCount(s.radialSegments, 3)
    radiusSegments = segmentCount(s.widthSegments, 1)
    firstRadius = max(nonNegative(s.innerRadius), MinimumDimension)
    secondRadius = positive(s.radius)
    innerRadius = min(firstRadius, secondRadius)
  var outerRadius = max(firstRadius, secondRadius)
  if outerRadius - innerRadius < MinimumDimension:
    outerRadius = innerRadius + MinimumDimension
  let
    widthOriginRadius = mix(innerRadius, outerRadius, arcOrigin01(s.arcOrigin))
    arcRadians = degreesToRadians(sanitizeArcDegrees(s.arcDegrees))
    angleOffset = degreesToRadians(s.angleOffset)
    positiveWinding = arcRadians >= 0.0'f
  var
    starts = newSeq[int](angularSegments + 1)
    collapsed = newSeq[bool](angularSegments + 1)
  for segment in 0 .. angularSegments:
    let
      angularT = segment.float32 / angularSegments.float32
      widthFactor = evaluateArcWidth(s, angularT)
      angle = angleOffset + arcRadians * angularT
      cosine = cos(angle)
      sine = sin(angle)
    starts[segment] = draft.positions.len
    collapsed[segment] = widthFactor <= MinimumDimension
    if collapsed[segment]:
      discard draft.addVertex(
        vec3(cosine * widthOriginRadius, 0.0'f, sine * widthOriginRadius),
        vec2(angularT, 0.5'f)
      )
      continue
    for ring in 0 .. radiusSegments:
      let
        radialT = ring.float32 / radiusSegments.float32
        baseRadius = mix(innerRadius, outerRadius, radialT)
        ringRadius = mix(widthOriginRadius, baseRadius, widthFactor)
      discard draft.addVertex(
        vec3(cosine * ringRadius, 0.0'f, sine * ringRadius),
        vec2(angularT, radialT)
      )
  for segment in 0 ..< angularSegments:
    draft.addVariableArcStrip(
      starts[segment],
      collapsed[segment],
      starts[segment + 1],
      collapsed[segment + 1],
      radiusSegments,
      positiveWinding
    )

proc addCircleCap(
  draft: var MeshDraft,
  y, radius: float32,
  radialSegments: int,
  angleOffset, arcRadians: float32,
  facesUp: bool
) =
  ## Adds one triangle-fan cap with planar-polar UVs.
  let center = draft.addVertex(vec3(0.0'f, y, 0.0'f), vec2(0.5'f, 0.5'f))
  let ringStart = draft.positions.len
  for segment in 0 .. radialSegments:
    let
      u = segment.float32 / radialSegments.float32
      angle = angleOffset + u * arcRadians
      cosine = cos(angle)
      sine = sin(angle)
    discard draft.addVertex(
      vec3(cosine * radius, y, sine * radius),
      vec2(0.5'f + cosine * 0.5'f, 0.5'f + sine * 0.5'f)
    )
  for segment in 0 ..< radialSegments:
    let
      current = ringStart + segment
      next = current + 1
    if facesUp == (arcRadians >= 0.0'f):
      draft.addTriangle(center, next, current)
    else:
      draft.addTriangle(center, current, next)

proc generateFrustum(
  s: FxSettings,
  draft: var MeshDraft,
  bottomRadius, topRadius: float32
) =
  ## Cone or cylinder shell with cylindrical UVs, caps, and a width profile.
  let
    radialSegments = segmentCount(s.radialSegments, 3)
    heightSegments = segmentCount(s.heightSegments, 1)
    height = positive(s.height)
    angleOffset = degreesToRadians(s.angleOffset)
    arcRadians = degreesToRadians(sanitizeArcDegrees(s.arcDegrees))
    positiveWinding = arcRadians >= 0.0'f
    stride = radialSegments + 1
  var rowRadii = newSeq[float32](heightSegments + 1)
  for row in 0 .. heightSegments:
    let
      v = row.float32 / heightSegments.float32
      y = mix(-height * 0.5'f, height * 0.5'f, v)
      radius = mix(bottomRadius, topRadius, v) * evaluateWidth(s, v)
    rowRadii[row] = radius
    for segment in 0 .. radialSegments:
      let
        u = segment.float32 / radialSegments.float32
        angle = angleOffset + u * arcRadians
      discard draft.addVertex(
        vec3(cos(angle) * radius, y, sin(angle) * radius),
        vec2(u, v)
      )
  for row in 0 ..< heightSegments:
    let
      lowerRadius = rowRadii[row]
      upperRadius = rowRadii[row + 1]
    for segment in 0 ..< radialSegments:
      let
        a = row * stride + segment
        b = a + 1
        c = a + stride
        d = c + 1
      if lowerRadius < MinimumDimension and upperRadius < MinimumDimension:
        continue
      if lowerRadius < MinimumDimension:
        if positiveWinding:
          draft.addTriangle(a, c, d)
        else:
          draft.addTriangle(a, d, c)
      elif upperRadius < MinimumDimension:
        if positiveWinding:
          draft.addTriangle(a, c, b)
        else:
          draft.addTriangle(a, b, c)
      elif positiveWinding:
        draft.addTriangle(a, c, b)
        draft.addTriangle(b, c, d)
      else:
        draft.addTriangle(a, b, c)
        draft.addTriangle(b, d, c)
  if s.capStart and rowRadii[0] >= MinimumDimension:
    draft.addCircleCap(
      -height * 0.5'f,
      rowRadii[0],
      radialSegments,
      angleOffset,
      arcRadians,
      false
    )
  if s.capEnd and rowRadii[heightSegments] >= MinimumDimension:
    draft.addCircleCap(
      height * 0.5'f,
      rowRadii[heightSegments],
      radialSegments,
      angleOffset,
      arcRadians,
      true
    )

proc addTubeRing(
  draft: var MeshDraft,
  radius, y: float32,
  radialSegments: int,
  angleOffset, arcRadians, v: float32,
  inner: bool
) =
  ## Adds one tube wall ring; inner walls mirror U so texture flow matches.
  for segment in 0 .. radialSegments:
    let
      angularT = segment.float32 / radialSegments.float32
      angle = angleOffset + angularT * arcRadians
    discard draft.addVertex(
      vec3(cos(angle) * radius, y, sin(angle) * radius),
      vec2(if inner: 1.0'f - angularT else: angularT, v)
    )

proc addAnnulusCap(
  draft: var MeshDraft,
  y, innerRadius, outerRadius: float32,
  radialSegments: int,
  angleOffset, arcRadians: float32,
  facesUp: bool
) =
  ## Adds one flat ring cap between the tube walls.
  let innerStart = draft.positions.len
  for segment in 0 .. radialSegments:
    let
      angularT = segment.float32 / radialSegments.float32
      angle = angleOffset + angularT * arcRadians
      cosine = cos(angle)
      sine = sin(angle)
    discard draft.addVertex(
      vec3(cosine * innerRadius, y, sine * innerRadius),
      vec2(
        0.5'f + cosine * innerRadius / outerRadius * 0.5'f,
        0.5'f + sine * innerRadius / outerRadius * 0.5'f
      )
    )
  let outerStart = draft.positions.len
  for segment in 0 .. radialSegments:
    let
      angularT = segment.float32 / radialSegments.float32
      angle = angleOffset + angularT * arcRadians
      cosine = cos(angle)
      sine = sin(angle)
    discard draft.addVertex(
      vec3(cosine * outerRadius, y, sine * outerRadius),
      vec2(0.5'f + cosine * 0.5'f, 0.5'f + sine * 0.5'f)
    )
  for segment in 0 ..< radialSegments:
    let
      a = innerStart + segment
      b = outerStart + segment
      c = a + 1
      d = b + 1
    if facesUp == (arcRadians >= 0.0'f):
      draft.addTriangle(a, c, b)
      draft.addTriangle(b, c, d)
    else:
      draft.addTriangle(a, b, c)
      draft.addTriangle(b, d, c)

proc generateTube(s: FxSettings, draft: var MeshDraft) =
  ## Hollow cylinder: outer wall, inner wall, and optional annulus caps.
  let
    radialSegments = segmentCount(s.radialSegments, 3)
    heightSegments = segmentCount(s.heightSegments, 1)
    height = positive(s.height)
    firstRadius = nonNegative(s.innerRadius)
    secondRadius = positive(s.radius)
    innerRadius = min(firstRadius, secondRadius)
  var outerRadius = max(firstRadius, secondRadius)
  if outerRadius - innerRadius < MinimumDimension:
    outerRadius = innerRadius + MinimumDimension
  if innerRadius < MinimumDimension:
    generateFrustum(s, draft, outerRadius, outerRadius)
    return
  let
    angleOffset = degreesToRadians(s.angleOffset)
    arcRadians = degreesToRadians(sanitizeArcDegrees(s.arcDegrees))
    positiveWinding = arcRadians >= 0.0'f
  var
    outerStarts = newSeq[int](heightSegments + 1)
    innerStarts = newSeq[int](heightSegments + 1)
    outerRadii = newSeq[float32](heightSegments + 1)
    innerRadii = newSeq[float32](heightSegments + 1)
  for row in 0 .. heightSegments:
    let
      v = row.float32 / heightSegments.float32
      y = mix(-height * 0.5'f, height * 0.5'f, v)
      widthFactor = evaluateWidth(s, v)
    outerRadii[row] = outerRadius * widthFactor
    innerRadii[row] = innerRadius * widthFactor
    outerStarts[row] = draft.positions.len
    draft.addTubeRing(
      outerRadii[row], y, radialSegments, angleOffset, arcRadians, v, false
    )
    innerStarts[row] = draft.positions.len
    draft.addTubeRing(
      innerRadii[row], y, radialSegments, angleOffset, arcRadians, v, true
    )
  for row in 0 ..< heightSegments:
    for segment in 0 ..< radialSegments:
      var
        a = outerStarts[row] + segment
        b = a + 1
        c = outerStarts[row + 1] + segment
        d = c + 1
      if positiveWinding:
        draft.addTriangle(a, c, b)
        draft.addTriangle(b, c, d)
      else:
        draft.addTriangle(a, b, c)
        draft.addTriangle(b, d, c)
      a = innerStarts[row] + segment
      b = a + 1
      c = innerStarts[row + 1] + segment
      d = c + 1
      if positiveWinding:
        draft.addTriangle(a, b, c)
        draft.addTriangle(b, d, c)
      else:
        draft.addTriangle(a, c, b)
        draft.addTriangle(b, c, d)
  if s.capStart:
    draft.addAnnulusCap(
      -height * 0.5'f,
      innerRadii[0],
      outerRadii[0],
      radialSegments,
      angleOffset,
      arcRadians,
      false
    )
  if s.capEnd:
    draft.addAnnulusCap(
      height * 0.5'f,
      innerRadii[heightSegments],
      outerRadii[heightSegments],
      radialSegments,
      angleOffset,
      arcRadians,
      true
    )

proc addSphereStrip(
  draft: var MeshDraft,
  lowerStart, upperStart, longitudeSegments: int
) =
  ## Connects two latitude rings with a quad strip.
  for longitude in 0 ..< longitudeSegments:
    let
      a = lowerStart + longitude
      b = a + 1
      c = upperStart + longitude
      d = c + 1
    draft.addTriangle(a, c, b)
    draft.addTriangle(b, c, d)

proc generateSphere(s: FxSettings, draft: var MeshDraft) =
  ## Latitude-longitude sphere with a radial profile scale per latitude.
  let
    longitudeSegments = segmentCount(s.radialSegments, 3)
    latitudeSegments = segmentCount(s.heightSegments, 2)
    radius = positive(s.radius)
    angleOffset = degreesToRadians(s.angleOffset)
    bottomPole = draft.addVertex(vec3(0.0'f, -radius, 0.0'f), vec2(0.5'f, 0.0'f))
  var
    firstRing = -1
    previousRing = -1
  for latitude in 1 ..< latitudeSegments:
    let
      v = latitude.float32 / latitudeSegments.float32
      phi = -PI * 0.5'f + PI * v
      y = sin(phi) * radius
      ringRadius = cos(phi) * radius * evaluateWidth(s, v)
      ringStart = draft.positions.len
    for longitude in 0 .. longitudeSegments:
      let
        u = longitude.float32 / longitudeSegments.float32
        theta = angleOffset + u * Tau
      discard draft.addVertex(
        vec3(cos(theta) * ringRadius, y, sin(theta) * ringRadius),
        vec2(u, v)
      )
    if firstRing < 0:
      firstRing = ringStart
    if previousRing >= 0:
      draft.addSphereStrip(previousRing, ringStart, longitudeSegments)
    previousRing = ringStart
  let topPole = draft.addVertex(vec3(0.0'f, radius, 0.0'f), vec2(0.5'f, 1.0'f))
  for longitude in 0 ..< longitudeSegments:
    draft.addTriangle(bottomPole, firstRing + longitude, firstRing + longitude + 1)
    draft.addTriangle(previousRing + longitude, topPole, previousRing + longitude + 1)

proc generateHemisphere(s: FxSettings, draft: var MeshDraft) =
  ## Upper half sphere from the equator with an optional equator cap.
  let
    longitudeSegments = segmentCount(s.radialSegments, 3)
    latitudeSegments = segmentCount(s.heightSegments, 1)
    radius = positive(s.radius)
    angleOffset = degreesToRadians(s.angleOffset)
  var previousRing = -1
  for latitude in 0 ..< latitudeSegments:
    let
      v = latitude.float32 / latitudeSegments.float32
      phi = PI * 0.5'f * v
      y = sin(phi) * radius
      ringRadius = cos(phi) * radius * evaluateWidth(s, v)
      ringStart = draft.positions.len
    for longitude in 0 .. longitudeSegments:
      let
        u = longitude.float32 / longitudeSegments.float32
        theta = angleOffset + u * Tau
      discard draft.addVertex(
        vec3(cos(theta) * ringRadius, y, sin(theta) * ringRadius),
        vec2(u, v)
      )
    if previousRing >= 0:
      draft.addSphereStrip(previousRing, ringStart, longitudeSegments)
    previousRing = ringStart
  let topPole = draft.addVertex(vec3(0.0'f, radius, 0.0'f), vec2(0.5'f, 1.0'f))
  for longitude in 0 ..< longitudeSegments:
    draft.addTriangle(previousRing + longitude, topPole, previousRing + longitude + 1)
  if s.capEnd:
    draft.addCircleCap(
      0.0'f,
      radius * evaluateWidth(s, 0.0'f),
      longitudeSegments,
      angleOffset,
      Tau,
      false
    )

proc addTorusCap(
  draft: var MeshDraft,
  theta, majorRadius, tubeRadius: float32,
  tubeSegments: int,
  normalAlongTangent: float32
) =
  ## Seals one open end of a partial torus sweep with a fan.
  let
    radial = vec3(cos(theta), 0.0'f, sin(theta))
    centerPosition = radial * majorRadius
    center = draft.addVertex(centerPosition, vec2(0.5'f, 0.5'f))
    ringStart = draft.positions.len
  for tube in 0 .. tubeSegments:
    let
      v = tube.float32 / tubeSegments.float32
      phi = v * Tau
      cosine = cos(phi)
      sine = sin(phi)
    discard draft.addVertex(
      centerPosition + radial * (cosine * tubeRadius) +
        vec3(0.0'f, sine * tubeRadius, 0.0'f),
      vec2(0.5'f + cosine * 0.5'f, 0.5'f + sine * 0.5'f)
    )
  for tube in 0 ..< tubeSegments:
    let
      current = ringStart + tube
      next = current + 1
    if normalAlongTangent > 0.0'f:
      draft.addTriangle(center, current, next)
    else:
      draft.addTriangle(center, next, current)

proc generateTorus(s: FxSettings, draft: var MeshDraft) =
  ## Torus with a tube profile scale along the sweep and optional end caps.
  let
    majorSegments = segmentCount(s.radialSegments, 3)
    tubeSegments = segmentCount(s.heightSegments, 3)
    majorRadius = positive(s.radius)
    tubeRadius = positive(s.thickness)
    arcDegrees = sanitizeArcDegrees(s.arcDegrees)
    arcRadians = degreesToRadians(arcDegrees)
    angleOffset = degreesToRadians(s.angleOffset)
    positiveWinding = arcRadians >= 0.0'f
    tubeStride = tubeSegments + 1
  for major in 0 .. majorSegments:
    let
      u = major.float32 / majorSegments.float32
      theta = angleOffset + arcRadians * u
      radial = vec3(cos(theta), 0.0'f, sin(theta))
      center = radial * majorRadius
      profileU =
        if abs(arcDegrees) >= FullArcThreshold and major == majorSegments:
          0.0'f
        else:
          u
      currentTubeRadius = tubeRadius * evaluateWidth(s, profileU)
    for tube in 0 .. tubeSegments:
      let
        v = tube.float32 / tubeSegments.float32
        phi = v * Tau
      discard draft.addVertex(
        center + radial * (cos(phi) * currentTubeRadius) +
          vec3(0.0'f, sin(phi) * currentTubeRadius, 0.0'f),
        vec2(u, v)
      )
  for major in 0 ..< majorSegments:
    for tube in 0 ..< tubeSegments:
      let
        a = major * tubeStride + tube
        b = a + 1
        c = a + tubeStride
        d = c + 1
      if positiveWinding:
        draft.addTriangle(a, b, c)
        draft.addTriangle(b, d, c)
      else:
        draft.addTriangle(a, c, b)
        draft.addTriangle(b, c, d)
  if abs(arcDegrees) < FullArcThreshold:
    if s.capStart:
      draft.addTorusCap(
        angleOffset,
        majorRadius,
        tubeRadius * evaluateWidth(s, 0.0'f),
        tubeSegments,
        -sign(arcRadians)
      )
    if s.capEnd:
      draft.addTorusCap(
        angleOffset + arcRadians,
        majorRadius,
        tubeRadius * evaluateWidth(s, 1.0'f),
        tubeSegments,
        sign(arcRadians)
      )

proc addBoxFace(
  draft: var MeshDraft,
  origin, uVector, vVector: Vec3,
  uSegments, vSegments: int
) =
  ## Adds one subdivided box face with planar UVs.
  let
    start = draft.positions.len
    stride = uSegments + 1
  for vIndex in 0 .. vSegments:
    let v = vIndex.float32 / vSegments.float32
    for uIndex in 0 .. uSegments:
      let u = uIndex.float32 / uSegments.float32
      discard draft.addVertex(origin + uVector * u + vVector * v, vec2(u, v))
  for vIndex in 0 ..< vSegments:
    for uIndex in 0 ..< uSegments:
      let
        a = start + vIndex * stride + uIndex
        b = a + 1
        c = a + stride
        d = c + 1
      draft.addTriangle(a, b, c)
      draft.addTriangle(b, d, c)

proc generateBox(s: FxSettings, draft: var MeshDraft) =
  ## Subdivided box with a cross-section scale profile along its height.
  let
    size = vec3(positive(s.size.x), positive(s.size.y), positive(s.size.z))
    half = size * 0.5'f
    xSegments = segmentCount(s.widthSegments, 1)
    ySegments = segmentCount(s.heightSegments, 1)
    zSegments = segmentCount(s.lengthSegments, 1)
  draft.addBoxFace(
    vec3(half.x, -half.y, -half.z),
    vec3(0.0'f, size.y, 0.0'f),
    vec3(0.0'f, 0.0'f, size.z),
    ySegments,
    zSegments
  )
  draft.addBoxFace(
    vec3(-half.x, -half.y, half.z),
    vec3(0.0'f, size.y, 0.0'f),
    vec3(0.0'f, 0.0'f, -size.z),
    ySegments,
    zSegments
  )
  draft.addBoxFace(
    vec3(-half.x, half.y, half.z),
    vec3(size.x, 0.0'f, 0.0'f),
    vec3(0.0'f, 0.0'f, -size.z),
    xSegments,
    zSegments
  )
  draft.addBoxFace(
    vec3(-half.x, -half.y, -half.z),
    vec3(size.x, 0.0'f, 0.0'f),
    vec3(0.0'f, 0.0'f, size.z),
    xSegments,
    zSegments
  )
  draft.addBoxFace(
    vec3(-half.x, -half.y, half.z),
    vec3(size.x, 0.0'f, 0.0'f),
    vec3(0.0'f, size.y, 0.0'f),
    xSegments,
    ySegments
  )
  draft.addBoxFace(
    vec3(half.x, -half.y, -half.z),
    vec3(-size.x, 0.0'f, 0.0'f),
    vec3(0.0'f, size.y, 0.0'f),
    xSegments,
    ySegments
  )
  for vertex in 0 ..< draft.positions.len:
    var position = draft.positions[vertex]
    let
      heightT = clamp(
        (position.y + half.y) / max(size.y, MinimumDimension),
        0.0'f,
        1.0'f
      )
      crossSectionScale = evaluateWidth(s, heightT)
    position.x *= crossSectionScale
    position.z *= crossSectionScale
    draft.positions[vertex] = position

proc addAxialPlane(
  s: FxSettings,
  draft: var MeshDraft,
  widthDirection: Vec3,
  width, length: float32,
  widthSegments, lengthSegments: int
) =
  ## Adds one strip standing along Y with a width profile per row.
  let
    start = draft.positions.len
    stride = widthSegments + 1
  for row in 0 .. lengthSegments:
    let
      v = row.float32 / lengthSegments.float32
      y = mix(-length * 0.5'f, length * 0.5'f, v)
      widthScale = evaluateWidth(s, v)
      rowWidth = width * widthScale
    for column in 0 .. widthSegments:
      let
        u = column.float32 / widthSegments.float32
        across = mix(-rowWidth * 0.5'f, rowWidth * 0.5'f, u)
      discard draft.addVertex(
        widthDirection * across + vec3(0.0'f, y, 0.0'f),
        vec2(evaluateWidthProfileU(u, widthScale), v)
      )
  for row in 0 ..< lengthSegments:
    for column in 0 ..< widthSegments:
      let
        a = start + row * stride + column
        b = a + 1
        c = a + stride
        d = c + 1
      draft.addTriangle(a, b, c)
      draft.addTriangle(b, d, c)

proc generateRibbon(s: FxSettings, draft: var MeshDraft) =
  ## Single tapered strip for trails and streaks.
  addAxialPlane(
    s,
    draft,
    vec3(1.0'f, 0.0'f, 0.0'f),
    positive(s.width),
    positive(s.length),
    segmentCount(s.widthSegments, 1),
    segmentCount(s.lengthSegments, 1)
  )

proc generateCrossPlanes(s: FxSettings, draft: var MeshDraft) =
  ## Several strips rotated around the axis for volumetric cards.
  let
    planeCount = segmentCount(s.planeCount, 2)
    angleOffset = degreesToRadians(s.angleOffset)
    width = positive(s.width)
    length = positive(s.length)
    widthSegments = segmentCount(s.widthSegments, 1)
    lengthSegments = segmentCount(s.lengthSegments, 1)
  for plane in 0 ..< planeCount:
    let angle = angleOffset + PI * plane.float32 / planeCount.float32
    addAxialPlane(
      s,
      draft,
      vec3(cos(angle), 0.0'f, sin(angle)),
      width,
      length,
      widthSegments,
      lengthSegments
    )

proc generateHelix(s: FxSettings, draft: var MeshDraft) =
  ## Spiraling strip with along-length V for coils and energy trails.
  var turns = finite(s.turns, 1.0'f)
  if abs(turns) < MinimumDimension:
    turns = MinimumDimension
  let
    turnsForDensity = max(1, ceil(abs(turns)).int)
    lengthSegments = segmentCount(s.lengthSegments, 3) * turnsForDensity
    widthSegments = segmentCount(s.widthSegments, 1)
    radius = positive(s.radius)
    width = positive(s.width)
    pitch = finite(s.pitch, 0.25'f)
    angleOffset = degreesToRadians(s.angleOffset)
    totalAngle = turns * Tau
    totalHeight = abs(turns) * pitch
    stride = widthSegments + 1
  for row in 0 .. lengthSegments:
    let
      v = row.float32 / lengthSegments.float32
      angle = angleOffset + totalAngle * v
      radial = vec3(cos(angle), 0.0'f, sin(angle))
      center = radial * radius +
        vec3(0.0'f, mix(-totalHeight * 0.5'f, totalHeight * 0.5'f, v), 0.0'f)
      widthScale = evaluateWidth(s, v)
      rowWidth = width * widthScale
    for column in 0 .. widthSegments:
      let
        u = column.float32 / widthSegments.float32
        across = mix(-rowWidth * 0.5'f, rowWidth * 0.5'f, u)
      discard draft.addVertex(
        center + radial * across,
        vec2(evaluateWidthProfileU(u, widthScale), v)
      )
  let positiveWinding = totalAngle >= 0.0'f
  for row in 0 ..< lengthSegments:
    for column in 0 ..< widthSegments:
      let
        a = row * stride + column
        b = a + 1
        c = a + stride
        d = c + 1
      if positiveWinding:
        draft.addTriangle(a, c, b)
        draft.addTriangle(b, c, d)
      else:
        draft.addTriangle(a, b, c)
        draft.addTriangle(b, d, c)

proc applyPivot(s: FxSettings, draft: var MeshDraft) =
  ## Moves the pivot to the bounds center, start, or end of the main axis.
  if draft.positions.len == 0:
    return
  let
    box = draft.bounds()
    center = (box.low + box.high) * 0.5'f
  var pivotPoint = center
  case s.pivot
  of CenterPivot:
    discard
  of StartPivot:
    pivotPoint.y = box.low.y
  of EndPivot:
    pivotPoint.y = box.high.y
  for i in 0 ..< draft.positions.len:
    draft.positions[i] -= pivotPoint

## Static build modifiers, evaluated taper, bend, noise, spherize, flatten.

proc falloffWeight(
  s: FxSettings,
  position: Vec3,
  low, high: Vec3,
  maximumRadius: float32
): float32 =
  ## Weights a modifier along the main axis, or radially for flat shapes.
  let axisExtent = high.y - low.y
  var t: float32
  if axisExtent > MinimumDimension:
    t = (position.y - low.y) / axisExtent
  else:
    let
      center = (low + high) * 0.5'f
      radial = length(vec2(position.x - center.x, position.z - center.z))
    t =
      if maximumRadius <= MinimumDimension: 0.0'f
      else: radial / maximumRadius
  pow(clamp(t, 0.0'f, 1.0'f), max(finite(s.falloffPower, 1.0'f), 0.01'f))

proc maximumRadius(draft: MeshDraft, center: Vec3): float32 =
  ## Largest distance from the axis over all vertices.
  for position in draft.positions:
    result = max(
      result,
      length(vec2(position.x - center.x, position.z - center.z))
    )

proc applyModifiers(s: FxSettings, draft: var MeshDraft) =
  ## Applies the enabled static deformations in a fixed order.
  if draft.positions.len == 0:
    return

  template modifierSetup(body: untyped) =
    ## Recomputes bounds shared by one modifier pass, then runs it.
    block:
      let
        box {.inject.} = draft.bounds()
        center {.inject.} = (box.low + box.high) * 0.5'f
        radiusLimit {.inject.} = draft.maximumRadius(center)
      body

  if abs(s.taper) > MinimumDimension:
    modifierSetup:
      for i in 0 ..< draft.positions.len:
        let
          position = draft.positions[i]
          weight = falloffWeight(s, position, box.low, box.high, radiusLimit)
          scale = 1.0'f + s.taper * weight
        draft.positions[i] = vec3(
          center.x + (position.x - center.x) * scale,
          position.y,
          center.z + (position.z - center.z) * scale
        )

  if abs(s.bend) > MinimumDimension:
    modifierSetup:
      let
        axisLength = box.high.y - box.low.y
        totalRadians = degreesToRadians(s.bend)
      if axisLength > MinimumDimension:
        let baseCenter = vec3(center.x, box.low.y, center.z)
        for i in 0 ..< draft.positions.len:
          let
            position = draft.positions[i]
            weight = falloffWeight(s, position, box.low, box.high, radiusLimit)
            fromBase = position - baseCenter
            curvature = totalRadians * weight / axisLength
          if abs(curvature) <= MinimumDimension:
            continue
          let
            radius = 1.0'f / curvature
            theta = fromBase.y * curvature
            curvedAxis = (radius + fromBase.x) * sin(theta)
            curvedRadial = (radius + fromBase.x) * cos(theta) - radius
          draft.positions[i] = baseCenter +
            vec3(curvedRadial, curvedAxis, fromBase.z)

  if abs(s.noiseAmp) > MinimumDimension:
    modifierSetup:
      for i in 0 ..< draft.positions.len:
        let
          position = draft.positions[i]
          weight = falloffWeight(s, position, box.low, box.high, radiusLimit)
          noise = fractalNoise(position, s.noiseFreq, s.noiseSeed)
          radial = vec3(position.x - center.x, 0.0'f, position.z - center.z)
          radialLength = length(radial)
          direction =
            if radialLength > MinimumDimension: radial / radialLength
            else: vec3(1.0'f, 0.0'f, 0.0'f)
        draft.positions[i] = position +
          direction * (noise * s.noiseAmp * weight)

  if abs(s.spherize) > MinimumDimension:
    modifierSetup:
      let extents = (box.high - box.low) * 0.5'f
      let sphereRadius = max(extents.x, max(extents.y, extents.z))
      if sphereRadius > MinimumDimension:
        for i in 0 ..< draft.positions.len:
          let
            position = draft.positions[i]
            direction = position - center
            directionLength = length(direction)
          if directionLength <= MinimumDimension:
            continue
          let
            target = center + direction / directionLength * sphereRadius
            weight = falloffWeight(s, position, box.low, box.high, radiusLimit)
          draft.positions[i] = mix(position, target, s.spherize * weight)

  if abs(s.flatten) > MinimumDimension:
    modifierSetup:
      for i in 0 ..< draft.positions.len:
        let
          position = draft.positions[i]
          weight = falloffWeight(s, position, box.low, box.high, radiusLimit)
        draft.positions[i] = vec3(
          position.x,
          mix(position.y, center.y, s.flatten * weight),
          position.z
        )

proc weldKey(position: Vec3): (int, int, int) =
  ## Quantizes a position so coincident seam vertices share one key.
  (
    int(round(position.x * 8192.0'f)),
    int(round(position.y * 8192.0'f)),
    int(round(position.z * 8192.0'f))
  )

proc computeNormals(draft: MeshDraft): seq[Vec3] =
  ## Area-weighted smooth vertex normals, welded across coincident seam
  ## vertices so inflate and pulse never split UV seams, with an upward
  ## fallback for degenerate vertices.
  result = newSeq[Vec3](draft.positions.len)
  var welded: Table[(int, int, int), Vec3]
  var i = 0
  while i + 2 < draft.triangles.len:
    let
      a = draft.triangles[i]
      b = draft.triangles[i + 1]
      c = draft.triangles[i + 2]
      normal = cross(
        draft.positions[b] - draft.positions[a],
        draft.positions[c] - draft.positions[a]
      )
    if dot(normal, normal) > MinimumDimension * MinimumDimension:
      welded.mgetOrPut(weldKey(draft.positions[a]), vec3(0.0'f)) += normal
      welded.mgetOrPut(weldKey(draft.positions[b]), vec3(0.0'f)) += normal
      welded.mgetOrPut(weldKey(draft.positions[c]), vec3(0.0'f)) += normal
    i += 3
  for index in 0 ..< result.len:
    let accumulated = welded.getOrDefault(
      weldKey(draft.positions[index]),
      vec3(0.0'f)
    )
    let normalLength = length(accumulated)
    result[index] =
      if normalLength > MinimumDimension: accumulated / normalLength
      else: vec3(0.0'f, 1.0'f, 0.0'f)

proc buildMesh(s: FxSettings): tuple[
  vertices: seq[float32],
  indices: seq[uint32]
] =
  ## Generates, deforms, and packs the complete interleaved fx mesh.
  ## Layout per vertex: position 3, normal 3, uv 2, fx data 4.
  var draft: MeshDraft
  case s.shape
  of QuadShape: generateQuad(s, draft)
  of DiscShape: generateDisc(s, draft, s.arcDegrees)
  of RingShape: generateRing(s, draft, false)
  of ArcShape: generateArc(s, draft)
  of ConeShape:
    generateFrustum(s, draft, positive(s.radius), nonNegative(s.topRadius))
  of CylinderShape:
    generateFrustum(s, draft, positive(s.radius), positive(s.radius))
  of TubeShape: generateTube(s, draft)
  of SphereShape: generateSphere(s, draft)
  of HemisphereShape: generateHemisphere(s, draft)
  of TorusShape: generateTorus(s, draft)
  of BoxShape: generateBox(s, draft)
  of RibbonShape: generateRibbon(s, draft)
  of CrossPlanesShape: generateCrossPlanes(s, draft)
  of HelixShape: generateHelix(s, draft)

  applyModifiers(s, draft)
  applyPivot(s, draft)

  ## Packed animation coordinates are normalized against the final bounds,
  ## so later deformations stretch the data instead of reprojecting it.
  let
    normals = draft.computeNormals()
    box = draft.bounds()
    center = (box.low + box.high) * 0.5'f
    axisExtent = box.high.y - box.low.y
    radiusLimit = draft.maximumRadius(center)
  result.vertices = newSeqOfCap[float32](draft.positions.len * 12)
  for i in 0 ..< draft.positions.len:
    let
      position = draft.positions[i]
      alongAxis =
        if axisExtent > MinimumDimension:
          clamp((position.y - box.low.y) / axisExtent, 0.0'f, 1.0'f)
        else:
          0.5'f
      radial = length(vec2(position.x - center.x, position.z - center.z))
      radialT =
        if radiusLimit > MinimumDimension:
          clamp(radial / radiusLimit, 0.0'f, 1.0'f)
        else:
          0.0'f
      angular = arctan2(position.z - center.z, position.x - center.x) / Tau + 0.5'f
    result.vertices.add position.x
    result.vertices.add position.y
    result.vertices.add position.z
    result.vertices.add normals[i].x
    result.vertices.add normals[i].y
    result.vertices.add normals[i].z
    result.vertices.add draft.uvs[i].x
    result.vertices.add draft.uvs[i].y
    result.vertices.add alongAxis
    result.vertices.add radialT
    result.vertices.add angular
    result.vertices.add stableRandom(i)
  result.indices = newSeqOfCap[uint32](draft.triangles.len)
  for index in draft.triangles:
    result.indices.add index.uint32

proc geometryKey(s: FxSettings): auto =
  ## Every field that requires a mesh rebuild when it changes.
  (
    s.shape, s.axis, s.pivot, s.radius, s.innerRadius, s.topRadius,
    s.thickness, s.width, s.length, s.height, s.size, s.arcDegrees,
    s.angleOffset, s.turns, s.pitch, s.planeCount, s.radialSegments,
    s.heightSegments, s.widthSegments, s.lengthSegments, s.capStart,
    s.capEnd, s.widthStart, s.widthEnd, s.widthPower, s.arcCrescent,
    s.arcPower, s.arcOrigin, s.taper, s.bend, s.noiseAmp, s.noiseFreq,
    s.noiseSeed, s.spherize, s.flatten, s.falloffPower
  )

## The single fx shader pair, authored with Shady.

var
  uViewProjection: Uniform[Mat4]
  uModel: Uniform[Mat4]
  uTime: Uniform[float32]
  uLifeT: Uniform[float32]
  uAlpha: Uniform[float32]
  uDissolve: Uniform[float32]
  uDissolveEdge: Uniform[float32]
  uSpinSpeed: Uniform[float32]
  uTwistAngle: Uniform[float32]
  uWaveAmp: Uniform[float32]
  uWaveFreq: Uniform[float32]
  uWaveSpeed: Uniform[float32]
  uRippleAmp: Uniform[float32]
  uRippleFreq: Uniform[float32]
  uRippleSpeed: Uniform[float32]
  uInflate: Uniform[float32]
  uPulseAmp: Uniform[float32]
  uPulseSpeed: Uniform[float32]
  uExpandStart: Uniform[float32]
  uExpandEnd: Uniform[float32]
  uExpandPower: Uniform[float32]
  uSweepSource: Uniform[int32]
  uSweepBand: Uniform[float32]
  uSweepSoft: Uniform[float32]
  uUvScale: Uniform[Vec2]
  uScroll: Uniform[Vec2]
  uNoiseScale: Uniform[float32]
  uGradientSource: Uniform[int32]
  uStartColor: Uniform[Vec4]
  uEndColor: Uniform[Vec4]
  uEdgeColor: Uniform[Vec4]
  uPattern: Uniform[Sampler2D]
  uNoise: Uniform[Sampler2D]

proc fxVertex(
  gl_Position: var Vec4,
  vertPos: Vec3,
  vertNormal: Vec3,
  vertUv: Vec2,
  vertData: Vec4,
  fragmentUv: var Vec2,
  fragmentData: var Vec4
) =
  ## Animates one vertex in the canonical Y-axis space, then orients it.
  ## vertData packs along-axis, radial distance, angle, and a random value.
  fragmentUv = vertUv
  fragmentData = vertData
  var position: Vec3 = vertPos
  let axisT = vertData.x
  ## Inflate and pulse push along the authored normal. The pulse phase is
  ## shared by every vertex so duplicated seam vertices stay welded.
  let push = uInflate + uPulseAmp * sin(uTime * uPulseSpeed)
  position += vertNormal * push
  ## Wave displaces sideways, phased along the main axis.
  position.x += sin(
    axisT * uWaveFreq * 6.2831853'f + uTime * uWaveSpeed
  ) * uWaveAmp
  ## Radial ripple displaces along the axis, phased by radial distance.
  position.y += sin(
    vertData.y * uRippleFreq * 6.2831853'f - uTime * uRippleSpeed
  ) * uRippleAmp
  ## Twist rotates progressively along the axis while spin turns everything.
  let
    angle = 0.0174533'f * uTwistAngle * (axisT - 0.5'f) + uSpinSpeed * uTime
    cosine = cos(angle)
    sine = sin(angle)
  position = vec3(
    position.x * cosine - position.z * sine,
    position.y,
    position.x * sine + position.z * cosine
  )
  ## Expand scales the whole mesh over the effect life.
  let expand = mix(
    uExpandStart,
    uExpandEnd,
    pow(clamp(uLifeT, 0.0'f, 1.0'f), max(uExpandPower, 0.01'f))
  )
  position = position * expand
  gl_Position = uViewProjection * (uModel * vec4(position, 1.0'f))

proc fxFragment(
  fragmentUv: Vec2,
  fragmentData: Vec4,
  fragColor: var Vec4
) =
  ## Shades every effect: scrolled pattern, gradient, dissolve, edge glow.
  let
    uv: Vec2 = fragmentUv * uUvScale + uScroll * uTime
    pattern = texture(uPattern, uv).x
    noiseUv: Vec2 = fragmentUv * uNoiseScale +
      vec2(uScroll.y, uScroll.x) * (uTime * 0.31'f)
    noiseValue = texture(uNoise, noiseUv).x
  var gradientT = uLifeT
  if uGradientSource == 1'i32:
    gradientT = fragmentData.x
  if uGradientSource == 2'i32:
    gradientT = fragmentData.y
  if uGradientSource == 3'i32:
    gradientT = fragmentData.z
  let color: Vec4 = mix(
    uStartColor,
    uEndColor,
    clamp(gradientT, 0.0'f, 1.0'f)
  )
  var
    rgb: Vec3 = color.xyz
    alpha = color.w * pattern * uAlpha
  ## Sweep reveal: a band travels from coordinate zero to one over the
  ## effect life, with a feathered leading edge in the dissolve edge color
  ## and a trail that fades out over the band length behind it.
  if uSweepBand > 0.0001'f:
    var sweepCoord = fragmentUv.x
    if uSweepSource == 1'i32:
      sweepCoord = fragmentUv.y
    if uSweepSource == 2'i32:
      sweepCoord = fragmentData.x
    if uSweepSource == 3'i32:
      sweepCoord = fragmentData.y
    if uSweepSource == 4'i32:
      sweepCoord = fragmentData.z
    let
      soft = max(uSweepSoft, 0.0001'f)
      head = uLifeT * (1.0'f + uSweepBand + soft)
      age = head - sweepCoord
      edgeIn = clamp(age / (soft * 2.0'f), 0.0'f, 1.0'f)
    ## The leading edge ignores the pattern texture so the blade front is a
    ## solid hot line that trails off into the textured band behind it.
    alpha = mix(color.w * uAlpha, alpha, edgeIn) *
      smoothstep(0.0'f, soft, age) *
      clamp(1.0'f - age / uSweepBand, 0.0'f, 1.0'f)
    rgb = mix(uEdgeColor.xyz, rgb, edgeIn)
  if uDissolve > 0.0001'f:
    if noiseValue < uDissolve:
      discardFragment()
    let edge = smoothstep(
      uDissolve,
      uDissolve + max(uDissolveEdge, 0.0001'f),
      noiseValue
    )
    rgb = mix(uEdgeColor.xyz, rgb, edge)
    alpha = mix(uEdgeColor.w * uAlpha, alpha, edge)
  if alpha < 0.003'f:
    discardFragment()
  fragColor = vec4(rgb, alpha)

## Procedural pattern textures

proc tileableNoise(u, v: float32, periodX, periodY, seed: int): float32 =
  ## Bilinear lattice noise that wraps seamlessly at the texture edges.
  let
    x = u * periodX.float32
    y = v * periodY.float32
    x0 = floor(x).int
    y0 = floor(y).int
    tx = smoothCurve(x - x0.float32)
    ty = smoothCurve(y - y0.float32)
  template wrapped(px, py: int): float32 =
    hashNoise(((px) mod periodX + periodX) mod periodX,
      ((py) mod periodY + periodY) mod periodY, 0, seed)
  let
    a = mix(wrapped(x0, y0), wrapped(x0 + 1, y0), tx)
    b = mix(wrapped(x0, y0 + 1), wrapped(x0 + 1, y0 + 1), tx)
  mix(a, b, ty) * 0.5'f + 0.5'f

proc tileableFbm(u, v: float32, periodX, periodY, seed: int): float32 =
  ## Four-octave tileable fractal noise in the zero-to-one range.
  var
    total = 0.0'f
    weight = 0.0'f
    amplitude = 1.0'f
    px = periodX
    py = periodY
  for octave in 0 ..< 4:
    total += tileableNoise(u, v, px, py, seed + octave * 1013) * amplitude
    weight += amplitude
    amplitude *= 0.5'f
    px *= 2
    py *= 2
  total / weight

proc cellPattern(u, v: float32, grid, seed: int): float32 =
  ## Tileable Worley-style cellular pattern, bright at feature points.
  let
    px = u * grid.float32
    py = v * grid.float32
    cx = floor(px).int
    cy = floor(py).int
  var best = 8.0'f
  for oy in -1 .. 1:
    for ox in -1 .. 1:
      let
        cellX = cx + ox
        cellY = cy + oy
        wrapX = ((cellX mod grid) + grid) mod grid
        wrapY = ((cellY mod grid) + grid) mod grid
        jitterX = hashNoise(wrapX, wrapY, 1, seed) * 0.5'f + 0.5'f
        jitterY = hashNoise(wrapX, wrapY, 2, seed) * 0.5'f + 0.5'f
        featureX = cellX.float32 + jitterX
        featureY = cellY.float32 + jitterY
        distance = length(vec2(px - featureX, py - featureY))
      best = min(best, distance)
  let value = clamp(1.0'f - best, 0.0'f, 1.0'f)
  value * value

proc patternValue(kind: FxTexture, u, v: float32): float32 =
  ## Evaluates one procedural pattern at a texture coordinate.
  case kind
  of SoftTexture:
    let d = length(vec2(u - 0.5'f, v - 0.5'f)) * 2.0'f
    smoothCurve(clamp(1.0'f - d, 0.0'f, 1.0'f))
  of NoiseTexture:
    tileableFbm(u, v, 6, 6, 1234)
  of StreakTexture:
    pow(tileableFbm(u, v, 24, 3, 777), 1.5'f)
  of CellTexture:
    cellPattern(u, v, 8, 5150)
  of CheckerTexture:
    let
      cellX = int(u * 8.0'f) mod 8
      cellY = int(v * 8.0'f) mod 8
    if (cellX + cellY) mod 2 == 0: 0.9'f else: 0.35'f

proc makePatternTexture(kind: FxTexture): GLuint =
  ## Builds one repeating mipmapped grayscale pattern texture.
  var pixels = newSeq[uint8](TextureSize * TextureSize * 4)
  for y in 0 ..< TextureSize:
    for x in 0 ..< TextureSize:
      let
        u = (x.float32 + 0.5'f) / TextureSize.float32
        v = (y.float32 + 0.5'f) / TextureSize.float32
        value = uint8(clamp(patternValue(kind, u, v), 0.0'f, 1.0'f) * 255.0'f)
        offset = (y * TextureSize + x) * 4
      pixels[offset] = value
      pixels[offset + 1] = value
      pixels[offset + 2] = value
      pixels[offset + 3] = value
  glGenTextures(1, result.addr)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_RGBA8.GLint,
    TextureSize,
    TextureSize,
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    pixels[0].addr
  )
  glGenerateMipmap(GL_TEXTURE_2D)
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MIN_FILTER,
    GL_LINEAR_MIPMAP_LINEAR.GLint
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT)
  glBindTexture(GL_TEXTURE_2D, 0)

## Renderer

proc compileStage(
  kind: GLenum,
  source, label: string
): GLuint {.raises: [FxError].} =
  ## Compiles a shader stage or raises an fx-specific error.
  result = glCreateShader(kind)
  var sources = allocCStringArray([source])
  defer: deallocCStringArray(sources)
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var logLength: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, logLength.addr)
    var log = newString(max(logLength.int, 1))
    glGetShaderInfoLog(result, logLength, nil, log.cstring)
    glDeleteShader(result)
    let message = label & " failed:\n" & log.strip(chars = {'\0'}) &
      "\nExpanded source:\n" & source
    echo message
    raise newException(FxError, message)

proc newFxRenderer(): FxRenderer {.raises: [FxError].} =
  ## Compiles the single fx program and creates every GPU resource.
  let
    vertexShader = compileStage(
      GL_VERTEX_SHADER,
      toShader(fxVertex, glsl4Desktop, shaderVertex),
      "Shady fx vertex"
    )
    fragmentShader = compileStage(
      GL_FRAGMENT_SHADER,
      toShader(fxFragment, glsl4Desktop, shaderFragment),
      "Shady fx fragment"
    )
  result.program = glCreateProgram()
  glAttachShader(result.program, vertexShader)
  glAttachShader(result.program, fragmentShader)
  glLinkProgram(result.program)
  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)
  var ok: GLint
  glGetProgramiv(result.program, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var logLength: GLint
    glGetProgramiv(result.program, GL_INFO_LOG_LENGTH, logLength.addr)
    var log = newString(max(logLength.int, 1))
    glGetProgramInfoLog(result.program, logLength, nil, log.cstring)
    glDeleteProgram(result.program)
    raise newException(FxError, "fx program failed to link:\n" & log)
  for uniform in FxUniform:
    result.locations[uniform] = glGetUniformLocation(
      result.program,
      UniformNames[uniform].cstring
    )

  glGenVertexArrays(1, result.vertexArray.addr)
  glGenBuffers(1, result.vertexBuffer.addr)
  glGenBuffers(1, result.indexBuffer.addr)
  glBindVertexArray(result.vertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, result.indexBuffer)
  let stride = GLsizei(12 * sizeof(float32))
  let
    positionLocation = glGetAttribLocation(result.program, "vertPos")
    normalLocation = glGetAttribLocation(result.program, "vertNormal")
    uvLocation = glGetAttribLocation(result.program, "vertUv")
    dataLocation = glGetAttribLocation(result.program, "vertData")
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(
    positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil
  )
  glEnableVertexAttribArray(normalLocation.GLuint)
  glVertexAttribPointer(
    normalLocation.GLuint,
    3,
    cGL_FLOAT,
    GL_FALSE,
    stride,
    cast[pointer](3 * sizeof(float32))
  )
  glEnableVertexAttribArray(uvLocation.GLuint)
  glVertexAttribPointer(
    uvLocation.GLuint,
    2,
    cGL_FLOAT,
    GL_FALSE,
    stride,
    cast[pointer](6 * sizeof(float32))
  )
  glEnableVertexAttribArray(dataLocation.GLuint)
  glVertexAttribPointer(
    dataLocation.GLuint,
    4,
    cGL_FLOAT,
    GL_FALSE,
    stride,
    cast[pointer](8 * sizeof(float32))
  )
  glBindVertexArray(0)

  for kind in FxTexture:
    result.patternTextures[kind] = makePatternTexture(kind)

proc uploadMesh(renderer: var FxRenderer, s: FxSettings) =
  ## Rebuilds the current shape and uploads it to the GPU buffers.
  let mesh = buildMesh(s)
  renderer.vertexCount = mesh.vertices.len div 12
  renderer.indexCount = mesh.indices.len
  glBindVertexArray(renderer.vertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, renderer.vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    mesh.vertices.len * sizeof(float32),
    if mesh.vertices.len > 0: cast[pointer](mesh.vertices[0].addr) else: nil,
    GL_STATIC_DRAW
  )
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, renderer.indexBuffer)
  glBufferData(
    GL_ELEMENT_ARRAY_BUFFER,
    mesh.indices.len * sizeof(uint32),
    if mesh.indices.len > 0: cast[pointer](mesh.indices[0].addr) else: nil,
    GL_STATIC_DRAW
  )
  glBindVertexArray(0)

proc close(renderer: var FxRenderer) =
  ## Releases the fx program, buffers, and pattern textures.
  if renderer.program != 0:
    glDeleteProgram(renderer.program)
  if renderer.vertexArray != 0:
    glDeleteVertexArrays(1, renderer.vertexArray.addr)
  if renderer.vertexBuffer != 0:
    glDeleteBuffers(1, renderer.vertexBuffer.addr)
  if renderer.indexBuffer != 0:
    glDeleteBuffers(1, renderer.indexBuffer.addr)
  for kind in FxTexture:
    if renderer.patternTextures[kind] != 0:
      glDeleteTextures(1, renderer.patternTextures[kind].addr)
  renderer = FxRenderer()

## Application

type FxApp = object
  sk: Silky
  renderer: FxRenderer
  presets: seq[FxSettings]
  settings: FxSettings
  builtKey: typeof(geometryKey(FxSettings()))
  camera: CameraState
  activePreset: int
  panelTab: PanelTab
  showPanel: bool
  paused: bool
  wireframe: bool
  simTime: float32
  effectStart: float32
  timeScale: float32
  lastWallTime: float64
  fps: float32
  frameCount: int
  maxFrames: int

proc viewProjection(camera: var CameraState, size: IVec2): Mat4 =
  ## Updates camera basis vectors and returns its view-projection matrix.
  let eyeOffset = vec3(
    sin(camera.yaw) * cos(camera.pitch),
    sin(camera.pitch),
    cos(camera.yaw) * cos(camera.pitch)
  ) * camera.distance
  camera.eye = camera.target + eyeOffset
  camera.forward = normalize(camera.target - camera.eye)
  camera.right = normalize(cross(camera.forward, vec3(0.0'f, 1.0'f, 0.0'f)))
  camera.up = normalize(cross(camera.right, camera.forward))
  let
    view = lookAt(camera.eye, camera.target, vec3(0.0'f, 1.0'f, 0.0'f))
    aspect = size.x.float32 / max(size.y.float32, 1.0'f)
    projection = perspective(45.0'f, aspect, 0.05'f, 500.0'f)
  projection * view

proc modelMatrix(axis: FxAxis): Mat4 =
  ## Rotates the canonical Y-axis mesh onto the selected main axis.
  case axis
  of YAxis: mat4()
  of XAxis: rotateZ(-PI.float32 * 0.5'f)
  of ZAxis: rotateX(PI.float32 * 0.5'f)

proc smoothstepValue(edge0, edge1, value: float32): float32 =
  ## CPU smoothstep matching the shader function.
  let t = clamp((value - edge0) / max(edge1 - edge0, 0.0001'f), 0.0'f, 1.0'f)
  t * t * (3.0'f - 2.0'f * t)

proc lifeFraction(app: FxApp): float32 =
  ## Where the current effect sits inside its duration.
  let
    duration = max(app.settings.duration, 0.01'f)
    elapsed = max(app.simTime - app.effectStart, 0.0'f)
  if app.settings.loop:
    (elapsed / duration) - floor(elapsed / duration)
  else:
    clamp(elapsed / duration, 0.0'f, 1.0'f)

proc mouseOverUi(app: FxApp, window: Window): bool =
  ## Returns whether the pointer is over a visible Silky subwindow.
  if not app.showPanel:
    return false
  let mousePosition = window.mousePos.vec2
  for state in subWindowStates.values:
    if state.visible and mousePosition.overlaps(rect(state.pos, state.size)):
      return true
  mousePosition.overlaps(rect(PanelPosition, PanelSize))

proc restart(app: var FxApp) =
  ## Restarts the effect life without touching the camera or settings.
  app.effectStart = app.simTime

proc selectPreset(app: var FxApp, index: int) =
  ## Selects one loaded preset and restarts its effect.
  if index < 0 or index >= app.presets.len:
    return
  app.activePreset = index
  app.settings = app.presets[index]
  app.restart()

proc handleInput(app: var FxApp, window: Window) =
  ## Handles camera movement and keyboard shortcuts.
  if window.buttonPressed[KeyEscape]:
    window.closeRequested = true
  if window.buttonPressed[KeyTab]:
    app.showPanel = not app.showPanel
  if window.buttonPressed[KeySpace]:
    app.paused = not app.paused
  if window.buttonPressed[KeyR]:
    app.restart()
  if window.buttonPressed[KeyW]:
    app.wireframe = not app.wireframe

  discard app.camera.viewProjection(window.size)
  let overUi = app.mouseOverUi(window)
  if window.buttonPressed[MouseRight] and not overUi:
    if window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]:
      app.camera.panning = true
    else:
      app.camera.rotating = true
  if window.buttonPressed[MouseMiddle] and not overUi:
    app.camera.panning = true
  if not window.buttonDown[MouseRight] and not window.buttonDown[MouseMiddle]:
    app.camera.rotating = false
    app.camera.panning = false

  let mouseDelta = window.mouseDelta.vec2
  if app.camera.rotating:
    app.camera.yaw -= mouseDelta.x * 0.01'f
    app.camera.pitch = clamp(
      app.camera.pitch + mouseDelta.y * 0.01'f,
      -1.48'f,
      1.48'f
    )
  if app.camera.panning:
    let
      panSpeed = app.camera.distance * 0.0015'f
    app.camera.target -= app.camera.right * mouseDelta.x * panSpeed
    app.camera.target += app.camera.up * mouseDelta.y * panSpeed
  if not overUi and window.scrollDelta.y != 0.0'f:
    app.camera.distance = clamp(
      app.camera.distance * pow(0.92'f, window.scrollDelta.y),
      1.0'f,
      60.0'f
    )

proc uploadUniforms(app: var FxApp, window: Window) =
  ## Uploads every per-frame uniform to the single fx program.
  template location(uniform: FxUniform): GLint =
    app.renderer.locations[uniform]

  let s = app.settings
  var
    viewProjectionMatrix = app.camera.viewProjection(window.size)
    modelValue = modelMatrix(s.axis)
    lifeT = app.lifeFraction()
  glUniformMatrix4fv(
    location(ViewProjectionUniform),
    1,
    GL_FALSE,
    cast[ptr float32](viewProjectionMatrix.addr)
  )
  glUniformMatrix4fv(
    location(ModelUniform),
    1,
    GL_FALSE,
    cast[ptr float32](modelValue.addr)
  )
  glUniform1f(location(TimeUniform), app.simTime)
  glUniform1f(location(LifeUniform), lifeT)

  var alpha = 1.0'f
  if s.fadeIn > 0.0001'f:
    alpha *= smoothstepValue(0.0'f, s.fadeIn, lifeT)
  if s.fadeOut > 0.0001'f:
    alpha *= 1.0'f - smoothstepValue(1.0'f - s.fadeOut, 1.0'f, lifeT)
  glUniform1f(location(AlphaUniform), alpha)

  var dissolve = 0.0'f
  if s.dissolveIn > 0.001'f:
    dissolve = max(dissolve, 1.0'f - lifeT / s.dissolveIn)
  if s.dissolveOut > 0.001'f:
    dissolve = max(dissolve, (lifeT - (1.0'f - s.dissolveOut)) / s.dissolveOut)
  glUniform1f(location(DissolveUniform), clamp(dissolve, 0.0'f, 1.0'f))
  glUniform1f(location(DissolveEdgeUniform), s.dissolveEdge)

  glUniform1f(location(SpinSpeedUniform), s.spinSpeed)
  glUniform1f(location(TwistAngleUniform), s.twistAngle)
  glUniform1f(location(WaveAmpUniform), s.waveAmp)
  glUniform1f(location(WaveFreqUniform), s.waveFreq)
  glUniform1f(location(WaveSpeedUniform), s.waveSpeed)
  glUniform1f(location(RippleAmpUniform), s.rippleAmp)
  glUniform1f(location(RippleFreqUniform), s.rippleFreq)
  glUniform1f(location(RippleSpeedUniform), s.rippleSpeed)
  glUniform1f(location(InflateUniform), s.inflate)
  glUniform1f(location(PulseAmpUniform), s.pulseAmp)
  glUniform1f(location(PulseSpeedUniform), s.pulseSpeed)
  glUniform1f(location(ExpandStartUniform), s.expandStart)
  glUniform1f(location(ExpandEndUniform), s.expandEnd)
  glUniform1f(location(ExpandPowerUniform), s.expandPower)
  glUniform1i(location(SweepSourceUniform), s.sweepSource.ord.GLint)
  glUniform1f(location(SweepBandUniform), s.sweepBand)
  glUniform1f(location(SweepSoftUniform), s.sweepSoft)
  glUniform2f(location(UvScaleUniform), s.uvScale.x, s.uvScale.y)
  glUniform2f(location(ScrollUniform), s.scroll.x, s.scroll.y)
  glUniform1f(location(NoiseScaleUniform), s.noiseScale)
  glUniform1i(location(GradientSourceUniform), s.gradientSource.ord.GLint)
  glUniform4f(
    location(StartColorUniform),
    s.startColor.x,
    s.startColor.y,
    s.startColor.z,
    s.startColor.w
  )
  glUniform4f(
    location(EndColorUniform),
    s.endColor.x,
    s.endColor.y,
    s.endColor.z,
    s.endColor.w
  )
  glUniform4f(
    location(EdgeColorUniform),
    s.edgeColor.x,
    s.edgeColor.y,
    s.edgeColor.z,
    s.edgeColor.w
  )
  glUniform1i(location(PatternUniform), 0)
  glUniform1i(location(NoiseUniform), 1)

proc drawMesh(app: var FxApp, window: Window) =
  ## Draws the fx mesh with the current blend mode, both sides visible.
  glViewport(0, 0, window.size.x, window.size.y)
  glClearColor(0.025'f, 0.032'f, 0.052'f, 1.0'f)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  if app.renderer.indexCount == 0:
    return
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  case app.settings.blendMode
  of AlphaBlend:
    glBlendFuncSeparate(
      GL_SRC_ALPHA,
      GL_ONE_MINUS_SRC_ALPHA,
      GL_ONE,
      GL_ONE_MINUS_SRC_ALPHA
    )
  of AdditiveBlend:
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE, GL_ZERO, GL_ONE)

  glUseProgram(app.renderer.program)
  app.uploadUniforms(window)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(
    GL_TEXTURE_2D,
    app.renderer.patternTextures[app.settings.texture]
  )
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, app.renderer.patternTextures[NoiseTexture])
  glActiveTexture(GL_TEXTURE0)
  if app.wireframe:
    glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
  glBindVertexArray(app.renderer.vertexArray)
  glDrawElements(
    GL_TRIANGLES,
    app.renderer.indexCount.GLsizei,
    GL_UNSIGNED_INT,
    nil
  )
  glBindVertexArray(0)
  if app.wireframe:
    glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
  glUseProgram(0)
  glDepthMask(GL_TRUE)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_BLEND)

## Control panel

template scrubFloat(
  id, caption: string,
  target: var float32,
  low, high: float32
) =
  ## Draws a labeled floating-point fx control.
  text(caption & ": " & target.formatFloat(ffDecimal, 2))
  scrubber(id, target, low, high, "")

template scrubInt(
  id, caption: string,
  target: var int,
  low, high: int
) =
  ## Draws a labeled integer fx control.
  text(caption & ": " & $target)
  scrubber(id, target, low, high, "")

proc drawShapeTab(app: var FxApp, window: Window) =
  ## Shape selection plus the controls relevant to the active shape.
  let sk = app.sk
  template s: FxSettings = app.settings
  text("Shape")
  group "shape row one":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Quad", s.shape, QuadShape)
    radioButton("Disc", s.shape, DiscShape)
    radioButton("Ring", s.shape, RingShape)
  group "shape row two":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Arc", s.shape, ArcShape)
    radioButton("Cone", s.shape, ConeShape)
    radioButton("Cylinder", s.shape, CylinderShape)
  group "shape row three":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Tube", s.shape, TubeShape)
    radioButton("Sphere", s.shape, SphereShape)
    radioButton("Dome", s.shape, HemisphereShape)
  group "shape row four":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Torus", s.shape, TorusShape)
    radioButton("Box", s.shape, BoxShape)
    radioButton("Ribbon", s.shape, RibbonShape)
  group "shape row five":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Cross", s.shape, CrossPlanesShape)
    radioButton("Helix", s.shape, HelixShape)
  text("Main axis")
  group "axis row":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("X", s.axis, XAxis)
    radioButton("Y", s.axis, YAxis)
    radioButton("Z", s.axis, ZAxis)

  case s.shape
  of QuadShape, RibbonShape:
    scrubFloat("width", "Width", s.width, 0.05'f, 6.0'f)
    scrubFloat("length", "Length", s.length, 0.05'f, 8.0'f)
    scrubInt("widthSegments", "Width segments", s.widthSegments, 1, 64)
    scrubInt("lengthSegments", "Length segments", s.lengthSegments, 1, 128)
  of DiscShape:
    scrubFloat("radius", "Radius", s.radius, 0.05'f, 5.0'f)
    scrubFloat("arcDegrees", "Sweep degrees", s.arcDegrees, -360.0'f, 360.0'f)
    scrubFloat("angleOffset", "Angle offset", s.angleOffset, -180.0'f, 180.0'f)
    scrubInt("radialSegments", "Resolution", s.radialSegments, 3, 128)
    scrubInt("widthSegments", "Rings", s.widthSegments, 1, 64)
  of RingShape:
    scrubFloat("radius", "Outer radius", s.radius, 0.05'f, 5.0'f)
    scrubFloat("innerRadius", "Inner radius", s.innerRadius, 0.0'f, 5.0'f)
    scrubInt("radialSegments", "Resolution", s.radialSegments, 3, 128)
    scrubInt("widthSegments", "Rings", s.widthSegments, 1, 64)
  of ArcShape:
    scrubFloat("radius", "Outer radius", s.radius, 0.05'f, 5.0'f)
    scrubFloat("innerRadius", "Inner radius", s.innerRadius, 0.0'f, 5.0'f)
    scrubFloat("arcDegrees", "Sweep degrees", s.arcDegrees, -360.0'f, 360.0'f)
    scrubFloat("angleOffset", "Angle offset", s.angleOffset, -180.0'f, 180.0'f)
    scrubFloat("arcCrescent", "Crescent", s.arcCrescent, 0.0'f, 1.0'f)
    scrubFloat("arcPower", "Crescent power", s.arcPower, 0.1'f, 4.0'f)
    text("Crescent origin")
    group "arc origin row":
      box 310, 32
      layout LeftToRight
      itemSpacing 6
      radioButton("Inner", s.arcOrigin, InnerOrigin)
      radioButton("Middle", s.arcOrigin, MiddleOrigin)
      radioButton("Outer", s.arcOrigin, OuterOrigin)
    scrubInt("radialSegments", "Resolution", s.radialSegments, 3, 128)
    scrubInt("widthSegments", "Rings", s.widthSegments, 1, 64)
  of ConeShape:
    scrubFloat("radius", "Bottom radius", s.radius, 0.0'f, 5.0'f)
    scrubFloat("topRadius", "Top radius", s.topRadius, 0.0'f, 5.0'f)
    scrubFloat("height", "Height", s.height, 0.05'f, 8.0'f)
    scrubFloat("arcDegrees", "Sweep degrees", s.arcDegrees, -360.0'f, 360.0'f)
    scrubInt("radialSegments", "Segments", s.radialSegments, 3, 128)
    scrubInt("heightSegments", "Height segments", s.heightSegments, 1, 64)
  of CylinderShape:
    scrubFloat("radius", "Radius", s.radius, 0.05'f, 5.0'f)
    scrubFloat("height", "Height", s.height, 0.05'f, 8.0'f)
    scrubFloat("arcDegrees", "Sweep degrees", s.arcDegrees, -360.0'f, 360.0'f)
    scrubInt("radialSegments", "Segments", s.radialSegments, 3, 128)
    scrubInt("heightSegments", "Height segments", s.heightSegments, 1, 64)
  of TubeShape:
    scrubFloat("radius", "Outer radius", s.radius, 0.05'f, 5.0'f)
    scrubFloat("innerRadius", "Inner radius", s.innerRadius, 0.0'f, 5.0'f)
    scrubFloat("height", "Height", s.height, 0.05'f, 8.0'f)
    scrubInt("radialSegments", "Segments", s.radialSegments, 3, 128)
    scrubInt("heightSegments", "Height segments", s.heightSegments, 1, 64)
  of SphereShape:
    scrubFloat("radius", "Radius", s.radius, 0.05'f, 5.0'f)
    scrubInt("radialSegments", "Longitude", s.radialSegments, 3, 128)
    scrubInt("heightSegments", "Latitude", s.heightSegments, 2, 64)
  of HemisphereShape:
    scrubFloat("radius", "Radius", s.radius, 0.05'f, 5.0'f)
    scrubInt("radialSegments", "Longitude", s.radialSegments, 3, 128)
    scrubInt("heightSegments", "Latitude", s.heightSegments, 1, 64)
  of TorusShape:
    scrubFloat("radius", "Major radius", s.radius, 0.05'f, 5.0'f)
    scrubFloat("thickness", "Tube radius", s.thickness, 0.01'f, 2.0'f)
    scrubFloat("arcDegrees", "Sweep degrees", s.arcDegrees, -360.0'f, 360.0'f)
    scrubInt("radialSegments", "Ring segments", s.radialSegments, 3, 128)
    scrubInt("heightSegments", "Tube segments", s.heightSegments, 3, 64)
  of BoxShape:
    scrubFloat("sizeX", "Size X", s.size.x, 0.05'f, 6.0'f)
    scrubFloat("sizeY", "Size Y", s.size.y, 0.05'f, 6.0'f)
    scrubFloat("sizeZ", "Size Z", s.size.z, 0.05'f, 6.0'f)
    scrubInt("widthSegments", "X segments", s.widthSegments, 1, 32)
    scrubInt("heightSegments", "Y segments", s.heightSegments, 1, 32)
    scrubInt("lengthSegments", "Z segments", s.lengthSegments, 1, 32)
  of CrossPlanesShape:
    scrubFloat("width", "Width", s.width, 0.05'f, 6.0'f)
    scrubFloat("length", "Height", s.length, 0.05'f, 8.0'f)
    scrubInt("planeCount", "Planes", s.planeCount, 2, 12)
    scrubFloat("angleOffset", "Angle offset", s.angleOffset, -180.0'f, 180.0'f)
    scrubInt("widthSegments", "Width segments", s.widthSegments, 1, 32)
    scrubInt("lengthSegments", "Length segments", s.lengthSegments, 1, 64)
  of HelixShape:
    scrubFloat("radius", "Radius", s.radius, 0.05'f, 5.0'f)
    scrubFloat("width", "Strip width", s.width, 0.02'f, 3.0'f)
    scrubFloat("turns", "Turns", s.turns, -8.0'f, 8.0'f)
    scrubFloat("pitch", "Pitch", s.pitch, 0.0'f, 3.0'f)
    scrubInt("lengthSegments", "Segments per turn", s.lengthSegments, 3, 64)
    scrubInt("widthSegments", "Width segments", s.widthSegments, 1, 16)

  if s.shape in {ConeShape, CylinderShape, TubeShape, HemisphereShape,
      TorusShape}:
    group "caps row":
      box 310, 32
      layout LeftToRight
      itemSpacing 6
      button(if s.capStart: "Cap start: on" else: "Cap start: off"):
        s.capStart = not s.capStart
      button(if s.capEnd: "Cap end: on" else: "Cap end: off"):
        s.capEnd = not s.capEnd

proc drawBuildTab(app: var FxApp, window: Window) =
  ## Width profile, pivot, and static build modifiers.
  let sk = app.sk
  template s: FxSettings = app.settings
  text("Width profile along axis")
  scrubFloat("widthStart", "Width start", s.widthStart, 0.0'f, 3.0'f)
  scrubFloat("widthEnd", "Width end", s.widthEnd, 0.0'f, 3.0'f)
  scrubFloat("widthPower", "Width power", s.widthPower, 0.1'f, 6.0'f)
  text("Pivot")
  group "pivot row":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Center", s.pivot, CenterPivot)
    radioButton("Start", s.pivot, StartPivot)
    radioButton("End", s.pivot, EndPivot)
  text("Modifiers, applied top to bottom")
  scrubFloat("taper", "Taper", s.taper, -1.0'f, 3.0'f)
  scrubFloat("bend", "Bend degrees", s.bend, -360.0'f, 360.0'f)
  scrubFloat("noiseAmp", "Noise amount", s.noiseAmp, 0.0'f, 1.5'f)
  scrubFloat("noiseFreq", "Noise frequency", s.noiseFreq, 0.1'f, 8.0'f)
  scrubInt("noiseSeed", "Noise seed", s.noiseSeed, 0, 9999)
  scrubFloat("spherize", "Spherize", s.spherize, 0.0'f, 1.0'f)
  scrubFloat("flatten", "Flatten", s.flatten, 0.0'f, 1.0'f)
  scrubFloat("falloffPower", "Falloff power", s.falloffPower, 0.1'f, 6.0'f)

proc drawAnimTab(app: var FxApp, window: Window) =
  ## Effect life and every shader-driven vertex animation.
  let sk = app.sk
  template s: FxSettings = app.settings
  scrubFloat("duration", "Duration", s.duration, 0.1'f, 10.0'f)
  group "loop row":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    button(if s.loop: "Loop: on" else: "Loop: off"):
      s.loop = not s.loop
    button("Restart"):
      app.restart()
  scrubFloat("timeScale", "Time scale", app.timeScale, 0.0'f, 3.0'f)
  scrubFloat("spinSpeed", "Spin speed", s.spinSpeed, -12.0'f, 12.0'f)
  scrubFloat("twistAngle", "Twist degrees", s.twistAngle, -720.0'f, 720.0'f)
  scrubFloat("waveAmp", "Wave amount", s.waveAmp, 0.0'f, 1.0'f)
  scrubFloat("waveFreq", "Wave frequency", s.waveFreq, 0.0'f, 8.0'f)
  scrubFloat("waveSpeed", "Wave speed", s.waveSpeed, -12.0'f, 12.0'f)
  scrubFloat("rippleAmp", "Ripple amount", s.rippleAmp, 0.0'f, 1.0'f)
  scrubFloat("rippleFreq", "Ripple frequency", s.rippleFreq, 0.0'f, 12.0'f)
  scrubFloat("rippleSpeed", "Ripple speed", s.rippleSpeed, -20.0'f, 20.0'f)
  scrubFloat("inflate", "Inflate", s.inflate, -0.5'f, 0.5'f)
  scrubFloat("pulseAmp", "Pulse amount", s.pulseAmp, 0.0'f, 0.5'f)
  scrubFloat("pulseSpeed", "Pulse speed", s.pulseSpeed, 0.0'f, 20.0'f)
  scrubFloat("expandStart", "Expand start", s.expandStart, 0.0'f, 3.0'f)
  scrubFloat("expandEnd", "Expand end", s.expandEnd, 0.0'f, 3.0'f)
  scrubFloat("expandPower", "Expand power", s.expandPower, 0.1'f, 4.0'f)
  text("Sweep reveal, zero band disables")
  group "sweep row one":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("U", s.sweepSource, SweepU)
    radioButton("V", s.sweepSource, SweepV)
    radioButton("Axis", s.sweepSource, SweepAxis)
  group "sweep row two":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Radial", s.sweepSource, SweepRadial)
    radioButton("Angle", s.sweepSource, SweepAngle)
  scrubFloat("sweepBand", "Sweep trail", s.sweepBand, 0.0'f, 2.0'f)
  scrubFloat("sweepSoft", "Sweep edge", s.sweepSoft, 0.0'f, 0.3'f)

proc drawLookTab(app: var FxApp, window: Window) =
  ## Texture, blending, UV flow, and dissolve controls.
  let sk = app.sk
  template s: FxSettings = app.settings
  text("Texture")
  group "texture row one":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Soft", s.texture, SoftTexture)
    radioButton("Noise", s.texture, NoiseTexture)
    radioButton("Streak", s.texture, StreakTexture)
  group "texture row two":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Cells", s.texture, CellTexture)
    radioButton("Checker", s.texture, CheckerTexture)
  text("Blending")
  group "blend row":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Alpha", s.blendMode, AlphaBlend)
    radioButton("Additive", s.blendMode, AdditiveBlend)
  scrubFloat("uvScaleX", "UV scale U", s.uvScale.x, -8.0'f, 8.0'f)
  scrubFloat("uvScaleY", "UV scale V", s.uvScale.y, -8.0'f, 8.0'f)
  scrubFloat("scrollX", "Scroll U", s.scroll.x, -4.0'f, 4.0'f)
  scrubFloat("scrollY", "Scroll V", s.scroll.y, -4.0'f, 4.0'f)
  scrubFloat("noiseScale", "Dissolve noise scale", s.noiseScale, 0.2'f, 8.0'f)
  scrubFloat("fadeIn", "Fade in", s.fadeIn, 0.0'f, 1.0'f)
  scrubFloat("fadeOut", "Fade out", s.fadeOut, 0.0'f, 1.0'f)
  scrubFloat("dissolveIn", "Dissolve in", s.dissolveIn, 0.0'f, 1.0'f)
  scrubFloat("dissolveOut", "Dissolve out", s.dissolveOut, 0.0'f, 1.0'f)
  scrubFloat("dissolveEdge", "Dissolve edge", s.dissolveEdge, 0.0'f, 0.5'f)

proc drawColorTab(app: var FxApp, window: Window) =
  ## Gradient source and the start, end, and dissolve-edge colors.
  let sk = app.sk
  template s: FxSettings = app.settings
  text("Gradient source")
  group "gradient row":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Life", s.gradientSource, LifeGradient)
    radioButton("Axis", s.gradientSource, AxisGradient)
  group "gradient row two":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("Radial", s.gradientSource, RadialGradient)
    radioButton("Angle", s.gradientSource, AngleGradient)
  scrubFloat("startRed", "Start red", s.startColor.x, 0.0'f, 1.0'f)
  scrubFloat("startGreen", "Start green", s.startColor.y, 0.0'f, 1.0'f)
  scrubFloat("startBlue", "Start blue", s.startColor.z, 0.0'f, 1.0'f)
  scrubFloat("startAlpha", "Start alpha", s.startColor.w, 0.0'f, 1.0'f)
  scrubFloat("endRed", "End red", s.endColor.x, 0.0'f, 1.0'f)
  scrubFloat("endGreen", "End green", s.endColor.y, 0.0'f, 1.0'f)
  scrubFloat("endBlue", "End blue", s.endColor.z, 0.0'f, 1.0'f)
  scrubFloat("endAlpha", "End alpha", s.endColor.w, 0.0'f, 1.0'f)
  scrubFloat("edgeRed", "Edge red", s.edgeColor.x, 0.0'f, 1.0'f)
  scrubFloat("edgeGreen", "Edge green", s.edgeColor.y, 0.0'f, 1.0'f)
  scrubFloat("edgeBlue", "Edge blue", s.edgeColor.z, 0.0'f, 1.0'f)
  scrubFloat("edgeAlpha", "Edge alpha", s.edgeColor.w, 0.0'f, 1.0'f)

proc drawUi(app: var FxApp, window: Window) =
  ## Draws preset selection, parameter tabs, and interaction help.
  let sk = app.sk
  sk.beginUi(window, window.size)
  if app.showPanel:
    subWindow("FX Mesh", app.showPanel, PanelPosition, PanelSize):
      text(&"{app.settings.name}  {app.fps:>4.0f} fps")
      text(
        &"{app.renderer.vertexCount} verts  " &
        &"{app.renderer.indexCount div 3} tris  " &
        &"life {app.lifeFraction():.2f}"
      )
      group "transport row":
        box 310, 32
        layout LeftToRight
        itemSpacing 6
        button(if app.paused: "Resume" else: "Pause"):
          app.paused = not app.paused
        button("Restart"):
          app.restart()
        button(if app.wireframe: "Shaded" else: "Wireframe"):
          app.wireframe = not app.wireframe
      text("Presets")
      group "preset row one":
        box 310, 32
        layout LeftToRight
        itemSpacing 6
        for i in 0 ..< min(3, app.presets.len):
          button(app.presets[i].name):
            app.selectPreset(i)
      group "preset row two":
        box 310, 32
        layout LeftToRight
        itemSpacing 6
        for i in 3 ..< app.presets.len:
          button(app.presets[i].name):
            app.selectPreset(i)
      group "tab row one":
        box 310, 32
        layout LeftToRight
        itemSpacing 8
        radioButton("Shape", app.panelTab, ShapeTab)
        radioButton("Build", app.panelTab, BuildTab)
        radioButton("Anim", app.panelTab, AnimTab)
      group "tab row two":
        box 310, 32
        layout LeftToRight
        itemSpacing 8
        radioButton("Look", app.panelTab, LookTab)
        radioButton("Color", app.panelTab, ColorTab)

      case app.panelTab
      of ShapeTab: app.drawShapeTab(window)
      of BuildTab: app.drawBuildTab(window)
      of AnimTab: app.drawAnimTab(window)
      of LookTab: app.drawLookTab(window)
      of ColorTab: app.drawColorTab(window)

      text("Right drag orbit, middle drag pan")
      text("Scroll zoom, Space pause, R restart")
      text("W wireframe, Tab toggles panel")
  sk.endUi()

## Frame loop

proc maxFramesFromArgs(): int =
  ## Returns a bounded frame count used by automated smoke runs.
  for argument in commandLineParams():
    if argument == "--smoke":
      return 4
    if argument.startsWith("--frames="):
      return argument["--frames=".len .. ^1].parseInt
  0

proc presetFromArgs(presetCount: int): int =
  ## Returns an optional zero-based preset index for scripted runs.
  for argument in commandLineParams():
    if argument.startsWith("--preset="):
      return clamp(
        argument["--preset=".len .. ^1].parseInt,
        0,
        max(presetCount - 1, 0)
      )
  0

proc tick(app: var FxApp, window: Window) =
  ## Advances time, rebuilds the mesh when needed, and renders one frame.
  let now = epochTime()
  var delta = clamp((now - app.lastWallTime).float32, 0.0001'f, 0.1'f)
  when defined(takeScreenshot):
    delta = 1.0'f / 60.0'f
  app.lastWallTime = now
  app.fps = app.fps * 0.92'f + (1.0'f / delta) * 0.08'f
  app.handleInput(window)
  if not app.paused:
    app.simTime += delta * app.timeScale
  let key = geometryKey(app.settings)
  if key != app.builtKey:
    app.renderer.uploadMesh(app.settings)
    app.builtKey = key
  app.drawMesh(window)
  app.drawUi(window)
  inc app.frameCount
  when defined(takeScreenshot):
    if app.maxFrames > 0 and app.frameCount == app.maxFrames:
      let image = newImage(window.size.x, window.size.y)
      glReadPixels(
        0,
        0,
        window.size.x,
        window.size.y,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        image.data[0].addr
      )
      image.flipVertical()
      image.writeFile("/tmp/polyworld_fxmesh.png")
  if app.maxFrames > 0 and app.frameCount >= app.maxFrames:
    window.closeRequested = true

proc main() =
  ## Creates and runs the standalone fx mesh experiment.
  let atlasBuilder = newAtlasBuilder(1024, 4)
  atlasBuilder.addDir("../polyworld_data/themes/editor/", "../polyworld_data/themes/editor/")
  atlasBuilder.addFont(
    "../polyworld_data/themes/editor/IBMPlexSans-Regular.ttf",
    "H1",
    32.0'f
  )
  atlasBuilder.addFont(
    "../polyworld_data/themes/editor/IBMPlexSans-Regular.ttf",
    "Default",
    18.0'f
  )
  atlasBuilder.write("../polyworld_data/themes/editor.atlas.png")

  let maxFrames = maxFramesFromArgs()
  let window = newWindow(
    "FX Mesh",
    WindowSize,
    visible = maxFrames == 0,
    vsync = false
  )
  makeContextCurrent(window)
  loadExtensions()
  let sk = newSilky(window, "../polyworld_data/themes/editor.atlas.png")
  window.runeInputEnabled = true
  window.onRune = proc(rune: Rune) =
    sk.inputRunes.add rune

  let presets = loadPresets()
  let presetIndex = presetFromArgs(presets.len)
  var app = FxApp(
    sk: sk,
    renderer: newFxRenderer(),
    presets: presets,
    settings: presets[presetIndex],
    camera: CameraState(
      yaw: 0.62'f,
      pitch: 0.38'f,
      distance: 6.0'f,
      target: vec3(0.0'f, 0.6'f, 0.0'f)
    ),
    activePreset: presetIndex,
    panelTab: ShapeTab,
    showPanel: true,
    timeScale: 1.0'f,
    lastWallTime: epochTime(),
    maxFrames: maxFrames
  )
  app.renderer.uploadMesh(app.settings)
  app.builtKey = geometryKey(app.settings)

  echo "FX mesh controls: right drag orbits, scroll zooms, Space pauses, " &
    "R restarts the effect, W toggles wireframe."
  while not window.closeRequested:
    pollEvents()
    app.tick(window)
    window.swapBuffers()

  app.renderer.close()
  window.close()

main()
