# Wind Waker water with original imagegen masks and scrolling foam layers.
# G compares generated and procedural textures, T shows the texture sheet.
# Keys 1-8 toggle layers, H toggles heave, Space pauses, drag orbits.
# See notes.md for running, capturing, texture prompts, and controls.

import
  std/[math, os, strutils, times],
  opengl, pixie, shady, vmath, windy,
  assets

const
  WindowSize = ivec2(1280, 800)
  SeaSize = 1400.0'f
  SeaQuads = 200
  LatticeTile = 28.0'f
    ## World units covered by one lattice repeat on the medium layer.
  SandRadius = 13.6'f
    ## Where sand meets water.
  ShoreWidth = 5.5'f
  ShoreRepeats = 12.0'f
  ShoreSegments = 160
  ShoreRings = 8
  DeepColor = vec3(0.035'f, 0.25'f, 0.78'f)
  FoamColor = vec3(0.96'f, 0.98'f, 1.0'f)
  SkyColor = (0.55'f, 0.72'f, 0.9'f)
  HorizonColor = vec3(SkyColor[0], SkyColor[1], SkyColor[2])
  ShallowColor = vec3(0.10'f, 0.55'f, 0.83'f)
  ShotPath = currentSourcePath.parentDir / "windwaker_water_generated.png"
  ShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop

type
  Mesh = object
    vertexArray: GLuint
    vertexBuffer: GLuint
    indexBuffer: GLuint
    indexCount: GLsizei
  Attribute = tuple[name: string, count: int]
  WaterTextures = array[TextureKind, GLuint]
  Lab = object
    window: Window
    waterProgram, solidProgram, shoreProgram, overlayProgram: GLuint
    sea, island, shore, quad: Mesh
    textures: array[TextureSource, WaterTextures]
    source: TextureSource
    layerMask: Vec3
    shoreLayers: Vec4
    warpOn: bool
    heaveOn: bool
    overlay: bool
    paused: bool
    time: float32
    lastWall: float64
    yaw, pitch, distance: float32
    frame: int
    maxFrames: int

var
  uViewProjection: Uniform[Mat4]
  uTime: Uniform[float32]
  uCamera: Uniform[Vec3]
  uSunDirection: Uniform[Vec3]
  uDeepColor: Uniform[Vec3]
  uFoamColor: Uniform[Vec3]
  uHorizonColor: Uniform[Vec3]
  uShallowColor: Uniform[Vec3]
  uLattice: Uniform[Sampler2D]
  uWarp: Uniform[Sampler2D]
  uWarpStrength: Uniform[float32]
  uLayerMask: Uniform[Vec3]
  uCalmRadius: Uniform[float32]
  uHeave: Uniform[float32]
  uShoreLattice: Uniform[Sampler2D]
  uCrest: Uniform[Sampler2D]
  uBand: Uniform[Sampler2D]
  uShoreFoam: Uniform[Sampler2D]
  uShoreMask: Uniform[Sampler2D]
  uShoreLayers: Uniform[Vec4]
  uLapCrest: Uniform[Vec2]
  uLapBand: Uniform[Vec2]
  uOverlayRect: Uniform[Vec4]
  uOverlayTexture: Uniform[Sampler2D]
  uOverlayTint: Uniform[int32]

proc waterVertex(
  gl_Position: var Vec4,
  vertPos: Vec3,
  fragWorld: var Vec3
) =
  ## Heaves the open sea gently, staying flat around the island so the
  ## shore ring can sit on it.
  var position: Vec3 = vertPos
  let
    radial = sqrt(vertPos.x * vertPos.x + vertPos.z * vertPos.z)
    calm = clamp((radial - uCalmRadius) * 0.04'f, 0.0'f, 1.0'f)
    swell = sin(vertPos.x * 0.21'f + uTime * 0.9'f) * 0.6'f +
      sin(vertPos.z * 0.17'f - uTime * 0.7'f) * 0.4'f +
      sin((vertPos.x + vertPos.z) * 0.09'f + uTime * 0.5'f) * 0.5'f
  position.y += swell * uHeave * calm
  fragWorld = position
  gl_Position = uViewProjection * vec4(position, 1.0'f)

proc waterFragment(fragWorld: Vec3, fragColor: var Vec4) =
  ## Dark broad cells sit beneath smaller white foam with scrolling warp.
  ## An optional fine foam layer demonstrates a denser variation.
  let
    base: Vec2 = vec2(fragWorld.x, fragWorld.z) * (1.0'f / LatticeTile)
    warpUv: Vec2 = base * 0.45'f + vec2(uTime * 0.011'f, uTime * 0.019'f)
    warpA = texture(uWarp, warpUv).x - 0.5'f
    warpB = texture(uWarp, warpUv + vec2(0.37'f, 0.61'f)).x - 0.5'f
    warp: Vec2 = vec2(warpA, warpB) * uWarpStrength
    coarseUv: Vec2 = base * 0.5'f - warp * 0.7'f +
      vec2(uTime * -0.007'f, uTime * 0.004'f)
    mediumUv: Vec2 = base + warp + vec2(uTime * 0.010'f, uTime * 0.006'f)
    fineUv: Vec2 = base * 2.1'f + warp * 1.3'f +
      vec2(uTime * 0.004'f, uTime * -0.013'f)
    coarse = texture(uLattice, coarseUv).x
    medium = texture(uLattice, mediumUv).x
    fine = texture(uLattice, fineUv).x
    toCamera: Vec3 = fragWorld - uCamera
    distance = sqrt(dot(toCamera, toCamera))
    fineFade = 1.0'f - smoothstep(50.0'f, 150.0'f, distance)
    mediumFade = 1.0'f - smoothstep(140.0'f, 320.0'f, distance)
    lines = max(
      medium * uLayerMask.y * mediumFade,
      fine * uLayerMask.z * fineFade * 0.6'f)
    radial = length(vec2(fragWorld.x, fragWorld.z))
    shoreFade = smoothstep(SandRadius + 1.0'f, SandRadius + 7.0'f, radial)
    foam = lines * shoreFade
    shadow = coarse * uLayerMask.x * shoreFade * mediumFade
    shallow = 1.0'f - smoothstep(SandRadius, SandRadius + 4.5'f, radial)
    haze = smoothstep(120.0'f, 520.0'f, distance)
    water: Vec3 = mix(uDeepColor, uShallowColor, shallow) *
      (1.0'f - shadow * 0.34'f)
  var color: Vec3 = mix(water, uFoamColor, foam)
  color = color * (1.0'f - haze) + uHorizonColor * haze
  fragColor = vec4(color, 1.0'f)

proc solidVertex(
  gl_Position: var Vec4,
  vertPos: Vec3,
  vertNormal: Vec3,
  vertColor: Vec3,
  fragNormal: var Vec3,
  fragTint: var Vec3
) =
  ## Flat-shaded island geometry.
  fragNormal = vertNormal
  fragTint = vertColor
  gl_Position = uViewProjection * vec4(vertPos, 1.0'f)

proc solidFragment(fragNormal: Vec3, fragTint: Vec3, fragColor: var Vec4) =
  ## Three broad bands keep the low island's slopes readable.
  let lit = max(dot(normalize(fragNormal), uSunDirection), 0.0'f)
  var band = 0.55'f
  if lit > 0.50'f:
    band = 0.78'f
  if lit > 0.82'f:
    band = 1.0'f
  fragColor = vec4(fragTint * band, 1.0'f)

proc shoreVertex(
  gl_Position: var Vec4,
  vertPos: Vec3,
  vertUv: Vec2,
  fragUv: var Vec2
) =
  ## The shore ring: u runs around the island, v from sand (0) to sea (1).
  fragUv = vertUv
  gl_Position = uViewProjection * vec4(vertPos, 1.0'f)

proc shoreFragment(fragUv: Vec2, fragColor: var Vec4) =
  ## Opposing scrolls lighten the crest and darken the receding foam.
  ## Whole mirrored repeats close the ring at every animation phase.
  let
    u = fragUv.x
    v = fragUv.y
    wobble = (texture(uWarp, vec2(u * 0.5'f + uTime * 0.01'f, v * 0.5'f)).x -
      0.5'f) * 0.06'f
    mask = texture(uShoreMask, vec2(u, v)).x
    lattice = texture(
      uShoreLattice, vec2(u * 0.5'f + uTime * 0.006'f + wobble, v)).x
    crestV = v - (1.0'f - uLapCrest.x) * 0.85'f
    crestA = texture(
      uCrest, vec2(u * 0.5'f + uTime * 0.025'f + wobble, crestV)).x
    crestB = texture(
      uCrest, vec2(u * 0.5'f - uTime * 0.019'f + 0.4'f, crestV)).x
    crest = max(crestA, crestB) * uLapCrest.y
    bandV = v - (1.0'f - uLapBand.x) * 0.7'f
    bandA = texture(
      uBand, vec2(u * 0.5'f + uTime * 0.015'f - wobble, bandV)).x
    bandB = texture(
      uBand, vec2(u * 0.5'f - uTime * 0.012'f + 0.5'f, bandV)).x
    band = max(bandA, bandB) * uLapBand.y
    ebbV = v + sin(uTime * 0.65'f) * 0.06'f
    sandA = texture(
      uShoreFoam, vec2(u * 0.5'f + uTime * 0.012'f - wobble, ebbV)).x
    sandB = texture(
      uShoreFoam, vec2(u * 0.5'f - uTime * 0.009'f + 0.2'f, ebbV)).x
    sandFoam = min(sandA, sandB)
    foam = max(
      max(lattice * 0.6'f * uShoreLayers.x, crest * uShoreLayers.y),
      max(band * uShoreLayers.z * 0.85'f, sandFoam * uShoreLayers.w)) * mask
  fragColor = vec4(uFoamColor, foam)

proc overlayVertex(gl_Position: var Vec4, vertPos: Vec2, fragUv: var Vec2) =
  ## A screen-space quad; uOverlayRect is x, y, width, height in clip space.
  fragUv = vertPos
  gl_Position = vec4(
    uOverlayRect.x + vertPos.x * uOverlayRect.z,
    uOverlayRect.y + vertPos.y * uOverlayRect.w,
    0.0'f, 1.0'f)

proc overlayFragment(fragUv: Vec2, fragColor: var Vec4) =
  ## Shows one texture, grayscale or tinted like the sea.
  let value = texture(uOverlayTexture, vec2(fragUv.x, 1.0'f - fragUv.y)).x
  var color: Vec3 = vec3(value, value, value)
  if uOverlayTint == 1'i32:
    color = uDeepColor * (1.0'f - value) + uFoamColor * value
  fragColor = vec4(color, 1.0'f)

proc compileStage(kind: GLenum, source, label: string): GLuint =
  ## Compiles one shader stage and reports the complete compiler log.
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
    raise newException(WaterError, label & " failed:\n" & log & "\n" & source)

proc buildProgram(vertexSource, fragmentSource, label: string): GLuint =
  ## Links a vertex and fragment shader into one program.
  let vertexShader = compileStage(
    GL_VERTEX_SHADER,
    vertexSource,
    label & " vertex"
  )
  defer:
    glDeleteShader(vertexShader)
  let fragmentShader = compileStage(
    GL_FRAGMENT_SHADER,
    fragmentSource,
    label & " fragment"
  )
  defer:
    glDeleteShader(fragmentShader)
  result = glCreateProgram()
  glAttachShader(result, vertexShader)
  glAttachShader(result, fragmentShader)
  glLinkProgram(result)
  var ok: GLint
  glGetProgramiv(result, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var logLength: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, logLength.addr)
    var log = newString(max(logLength.int, 1))
    glGetProgramInfoLog(result, logLength, nil, log.cstring)
    glDeleteProgram(result)
    raise newException(WaterError, label & " failed to link:\n" & log)

proc location(program: GLuint, name: string): GLint =
  ## Finds a named uniform in a linked program.
  glGetUniformLocation(program, name.cstring)

proc set(program: GLuint, name: string, value: float32) =
  ## Writes one uniform value to the active program.
  glUniform1f(program.location(name), value)

proc set(program: GLuint, name: string, value: int32) =
  ## Writes one uniform value to the active program.
  glUniform1i(program.location(name), value)

proc set(program: GLuint, name: string, value: Vec2) =
  ## Writes one uniform value to the active program.
  glUniform2f(program.location(name), value.x, value.y)

proc set(program: GLuint, name: string, value: Vec3) =
  ## Writes one uniform value to the active program.
  glUniform3f(program.location(name), value.x, value.y, value.z)

proc set(program: GLuint, name: string, value: Vec4) =
  ## Writes one uniform value to the active program.
  glUniform4f(program.location(name), value.x, value.y, value.z, value.w)

proc set(program: GLuint, name: string, value: Mat4) =
  ## Writes one uniform value to the active program.
  var matrix = value
  glUniformMatrix4fv(
    program.location(name), 1, GL_FALSE, cast[ptr float32](matrix.addr))

proc uploadMesh(
  program: GLuint,
  vertices: seq[float32],
  indices: seq[uint32],
  attributes: openArray[Attribute]
): Mesh =
  ## Interleaved float vertices bound to the program's attribute names.
  var stride = 0
  for attribute in attributes:
    stride += attribute.count
  glGenVertexArrays(1, result.vertexArray.addr)
  glGenBuffers(1, result.vertexBuffer.addr)
  glGenBuffers(1, result.indexBuffer.addr)
  glBindVertexArray(result.vertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER, vertices.len * sizeof(float32),
    vertices[0].unsafeAddr, GL_STATIC_DRAW)
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, result.indexBuffer)
  glBufferData(
    GL_ELEMENT_ARRAY_BUFFER, indices.len * sizeof(uint32),
    indices[0].unsafeAddr, GL_STATIC_DRAW)
  var offset = 0
  for attribute in attributes:
    let slot = glGetAttribLocation(program, attribute.name.cstring)
    if slot >= 0:
      glEnableVertexAttribArray(slot.GLuint)
      glVertexAttribPointer(
        slot.GLuint, attribute.count.GLint, cGL_FLOAT, GL_FALSE,
        GLsizei(stride * sizeof(float32)),
        cast[pointer](offset * sizeof(float32)))
    offset += attribute.count
  glBindVertexArray(0)
  result.indexCount = indices.len.GLsizei

proc draw(mesh: Mesh) =
  ## Draws the indexed triangles in one mesh.
  glBindVertexArray(mesh.vertexArray)
  glDrawElements(GL_TRIANGLES, mesh.indexCount, GL_UNSIGNED_INT, nil)
  glBindVertexArray(0)

proc makeTexture(image: Image, wrapS, wrapT: GLint): GLuint =
  ## Uploads a linear mask with mipmaps and explicit wrapping per axis.
  glGenTextures(1, result.addr)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA8.GLint, image.width.GLsizei,
    image.height.GLsizei, 0, GL_RGBA, GL_UNSIGNED_BYTE,
    image.data[0].unsafeAddr)
  glGenerateMipmap(GL_TEXTURE_2D)
  glTexParameteri(
    GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrapS)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrapT)
  glBindTexture(GL_TEXTURE_2D, 0)

proc bindTexture(program: GLuint, name: string, unit: int, texture: GLuint) =
  ## Binds a texture unit and assigns its sampler uniform.
  glActiveTexture(GLenum(GL_TEXTURE0.int + unit))
  glBindTexture(GL_TEXTURE_2D, texture)
  program.set(name, unit.int32)

proc seaMesh(program: GLuint): Mesh =
  ## A dense flat grid so the vertex heave has something to bend.
  var
    vertices: seq[float32]
    indices: seq[uint32]
  for row in 0 .. SeaQuads:
    for col in 0 .. SeaQuads:
      vertices.add (col.float32 / SeaQuads.float32 - 0.5'f) * SeaSize
      vertices.add 0.0'f
      vertices.add (row.float32 / SeaQuads.float32 - 0.5'f) * SeaSize
  for row in 0 ..< SeaQuads:
    for col in 0 ..< SeaQuads:
      let
        a = uint32(row * (SeaQuads + 1) + col)
        b = a + 1
        c = a + uint32(SeaQuads + 1)
        d = c + 1
      indices.add [a, c, b, b, c, d]
  program.uploadMesh(vertices, indices, [("vertPos", 3)])

proc islandHeight(radius, angle: float32): float32 =
  ## A grassy mound with a sand skirt that dips under the water line.
  let grassEdge = SandRadius - 2.4'f
  if radius < grassEdge:
    let t = 1.0'f - radius / grassEdge
    result = 0.8'f + 4.2'f * smoothstep(0.0'f, 1.0'f, t) +
      0.25'f * sin(angle * 5.0'f) * t * (1.0'f - t)
  elif radius < SandRadius:
    result = 0.8'f - 0.6'f * (radius - grassEdge) / (SandRadius - grassEdge)
  else:
    result = 0.2'f - 2.4'f * (radius - SandRadius)

proc islandColor(radius: float32): Vec3 =
  ## Chooses grass or sand for one radial island band.
  if radius < SandRadius - 2.4'f:
    vec3(0.42'f, 0.71'f, 0.27'f)
  else:
    vec3(0.94'f, 0.87'f, 0.64'f)

proc islandMesh(program: GLuint): Mesh =
  ## Unshared triangles with face normals for the flat-shaded look.
  const
    Rings = [0.0'f, 2.0, 4.0, 6.0, 8.0, 9.4, 10.6, 11.2, 12.0, 12.8,
      13.6, 14.4, 15.2]
    Segments = 48
  var
    vertices: seq[float32]
    indices: seq[uint32]
  proc point(radius, angle: float32): Vec3 =
    ## Places one island vertex on a radial height profile.
    vec3(cos(angle) * radius, islandHeight(radius, angle), sin(angle) * radius)
  proc triangle(a, b, c: Vec3, color: Vec3) =
    ## Appends one face with an outward normal and its material color.
    let normal = normalize(cross(b - a, c - a))
    for p in [a, b, c]:
      vertices.add [p.x, p.y, p.z, normal.x, normal.y, normal.z,
        color.r, color.g, color.b]
      indices.add uint32(indices.len)
  for ring in 0 ..< Rings.len - 1:
    let
      inner = Rings[ring]
      outer = Rings[ring + 1]
      color = islandColor((inner + outer) * 0.5'f)
    for segment in 0 ..< Segments:
      let
        angleA = segment.float32 / Segments.float32 * TAU.float32
        angleB = (segment + 1).float32 / Segments.float32 * TAU.float32
        a = point(inner, angleA)
        b = point(inner, angleB)
        c = point(outer, angleA)
        d = point(outer, angleB)
      if inner > 0.0'f:
        triangle(a, b, c, color)
      triangle(b, d, c, color)
  program.uploadMesh(vertices, indices,
    [("vertPos", 3), ("vertNormal", 3), ("vertColor", 3)])

proc shoreMesh(program: GLuint): Mesh =
  ## A ring hugging the sand just above the water line.
  var
    vertices: seq[float32]
    indices: seq[uint32]
  for ring in 0 .. ShoreRings:
    let
      v = ring.float32 / ShoreRings.float32
      radius = SandRadius - 0.6'f + v * ShoreWidth
    for segment in 0 .. ShoreSegments:
      let angle = segment.float32 / ShoreSegments.float32 * TAU.float32
      vertices.add [cos(angle) * radius, 0.06'f, sin(angle) * radius,
        segment.float32 / ShoreSegments.float32 * ShoreRepeats, v]
  for ring in 0 ..< ShoreRings:
    for segment in 0 ..< ShoreSegments:
      let
        a = uint32(ring * (ShoreSegments + 1) + segment)
        b = a + 1
        c = a + uint32(ShoreSegments + 1)
        d = c + 1
      indices.add [a, b, c, b, d, c]
  program.uploadMesh(vertices, indices, [("vertPos", 3), ("vertUv", 2)])

proc quadMesh(program: GLuint): Mesh =
  ## Builds the texture inspector quad.
  program.uploadMesh(
    @[0.0'f, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0],
    @[0'u32, 1, 2, 0, 2, 3],
    [("vertPos", 2)])

proc lapPhase(time, period, offset: float32): Vec2 =
  ## One lap cycle: ease in over the first 60%, then fade out in place.
  let
    t = fract(time / period + offset)
    travel = smoothstep(0.0'f, 0.6'f, t)
    fade = 1.0'f - smoothstep(0.55'f, 1.0'f, t)
  vec2(travel, fade * smoothstep(0.0'f, 0.1'f, t))

proc envFloat(name: string, fallback: float32): float32 =
  ## Reads a finite environment setting or uses its default.
  let text = getEnv(name)
  if text.len == 0:
    return fallback
  try:
    result = text.parseFloat.float32
  except ValueError:
    raise newException(WaterError, "Invalid number for " & name & ": " & text)
  if result.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(WaterError, "Expected a finite number for " & name)

proc viewProjection(lab: Lab): tuple[matrix: Mat4, eye: Vec3] =
  ## Builds the orbit camera and its perspective projection.
  let
    target = vec3(0.0'f, 1.5'f, 0.0'f)
    eye = target + vec3(
      cos(lab.yaw) * cos(lab.pitch) * lab.distance,
      sin(lab.pitch) * lab.distance,
      sin(lab.yaw) * cos(lab.pitch) * lab.distance)
    aspect = lab.window.size.x.float32 / max(lab.window.size.y.float32, 1.0'f)
    matrix = perspective(45.0'f, aspect, 0.5'f, 1200.0'f) *
      lookAt(eye, target, vec3(0.0'f, 1.0'f, 0.0'f))
  (matrix, eye)

proc drawOverlay(lab: Lab) =
  ## The texture sheet down the left edge, the way the video shows them.
  let
    maps = lab.textures[lab.source]
    sheet = [
      (maps[SeaLattice], 1'i32), (maps[SeaLattice], 0'i32),
      (maps[Warp], 0'i32), (maps[ShoreLace], 0'i32),
      (maps[Crest], 0'i32), (maps[Band], 0'i32),
      (maps[ContactFoam], 0'i32), (maps[Coverage], 0'i32)]
    aspect = lab.window.size.x.float32 / max(lab.window.size.y.float32, 1.0'f)
    height = 0.44'f
    width = height / aspect
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_BLEND)
  glUseProgram(lab.overlayProgram)
  lab.overlayProgram.set("uDeepColor", DeepColor)
  lab.overlayProgram.set("uFoamColor", FoamColor)
  for index, entry in sheet:
    let
      col = index mod 4
      row = index div 4
    lab.overlayProgram.set("uOverlayRect", vec4(
      -0.98'f + col.float32 * (width + 0.02'f),
      0.96'f - (row + 1).float32 * (height + 0.02'f),
      width, height))
    lab.overlayProgram.set("uOverlayTint", entry[1])
    lab.overlayProgram.bindTexture("uOverlayTexture", 0, entry[0])
    lab.quad.draw()
  glEnable(GL_DEPTH_TEST)

proc drawFrame(lab: var Lab) =
  ## Draws the island, sea, shoreline, and optional texture inspector.
  let
    (matrix, eye) = lab.viewProjection()
    maps = lab.textures[lab.source]
  glViewport(0, 0, lab.window.size.x, lab.window.size.y)
  glClearColor(SkyColor[0], SkyColor[1], SkyColor[2], 1.0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)
  glEnable(GL_CULL_FACE)
  glCullFace(GL_BACK)

  glUseProgram(lab.solidProgram)
  lab.solidProgram.set("uViewProjection", matrix)
  lab.solidProgram.set("uSunDirection", normalize(vec3(0.45'f, 0.8'f, 0.3'f)))
  lab.island.draw()

  glDisable(GL_CULL_FACE)
  glUseProgram(lab.waterProgram)
  lab.waterProgram.set("uViewProjection", matrix)
  lab.waterProgram.set("uTime", lab.time)
  lab.waterProgram.set("uCamera", eye)
  lab.waterProgram.set("uDeepColor", DeepColor)
  lab.waterProgram.set("uShallowColor", ShallowColor)
  lab.waterProgram.set("uFoamColor", FoamColor)
  lab.waterProgram.set("uHorizonColor", HorizonColor)
  lab.waterProgram.set("uWarpStrength", if lab.warpOn: 0.12'f else: 0.0'f)
  lab.waterProgram.set("uLayerMask", lab.layerMask)
  lab.waterProgram.set("uCalmRadius", SandRadius + ShoreWidth)
  lab.waterProgram.set("uHeave", if lab.heaveOn: 0.3'f else: 0.0'f)
  lab.waterProgram.bindTexture("uLattice", 0, maps[SeaLattice])
  lab.waterProgram.bindTexture("uWarp", 1, maps[Warp])
  lab.sea.draw()

  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glDepthMask(GL_FALSE)
  glUseProgram(lab.shoreProgram)
  lab.shoreProgram.set("uViewProjection", matrix)
  lab.shoreProgram.set("uTime", lab.time)
  lab.shoreProgram.set("uFoamColor", FoamColor)
  lab.shoreProgram.set("uShoreLayers", lab.shoreLayers)
  lab.shoreProgram.set("uLapCrest", lapPhase(lab.time, 7.0'f, 0.0'f))
  lab.shoreProgram.set("uLapBand", lapPhase(lab.time, 11.0'f, 0.45'f))
  lab.shoreProgram.bindTexture("uWarp", 0, maps[Warp])
  lab.shoreProgram.bindTexture("uShoreLattice", 1, maps[ShoreLace])
  lab.shoreProgram.bindTexture("uCrest", 2, maps[Crest])
  lab.shoreProgram.bindTexture("uBand", 3, maps[Band])
  lab.shoreProgram.bindTexture("uShoreFoam", 4, maps[ContactFoam])
  lab.shoreProgram.bindTexture("uShoreMask", 5, maps[Coverage])
  lab.shore.draw()
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)

  if lab.overlay:
    lab.drawOverlay()
  glActiveTexture(GL_TEXTURE0)

proc screenshot(lab: Lab) =
  ## Saves the current framebuffer to the configured PNG path.
  let image = newImage(lab.window.size.x, lab.window.size.y)
  glReadPixels(
    0, 0, lab.window.size.x, lab.window.size.y, GL_RGBA, GL_UNSIGNED_BYTE,
    image.data[0].addr)
  image.flipVertical()
  let path = getEnv("SCREENSHOT_PATH", ShotPath)
  image.writeFile(path)
  echo "wrote ", path

proc toggle(mask: var Vec3, index: int) =
  ## Switches one layer mask component between zero and one.
  mask[index] = if mask[index] > 0.5'f: 0.0'f else: 1.0'f

proc toggle(mask: var Vec4, index: int) =
  ## Switches one layer mask component between zero and one.
  mask[index] = if mask[index] > 0.5'f: 0.0'f else: 1.0'f

proc destroy(mesh: var Mesh) =
  ## Releases a mesh's buffers and vertex array.
  glDeleteBuffers(1, mesh.vertexBuffer.addr)
  glDeleteBuffers(1, mesh.indexBuffer.addr)
  glDeleteVertexArrays(1, mesh.vertexArray.addr)
  mesh = Mesh()

proc destroy(lab: var Lab) =
  ## Releases GPU resources before closing the window and its callbacks.
  lab.sea.destroy()
  lab.island.destroy()
  lab.shore.destroy()
  lab.quad.destroy()
  for source in TextureSource:
    for kind in TextureKind:
      glDeleteTextures(1, lab.textures[source][kind].addr)
  for program in [lab.waterProgram, lab.solidProgram, lab.shoreProgram,
      lab.overlayProgram]:
    if program != 0:
      glDeleteProgram(program)
  lab.window.close()

proc main() =
  ## Creates the lab and advances its input, animation, and draw phases.
  var
    maxFrames = 0
    source = Generated
  for argument in commandLineParams():
    if argument.startsWith("--frames="):
      try:
        maxFrames = argument["--frames=".len .. ^1].parseInt
      except ValueError:
        raise newException(WaterError, "Invalid frame count: " & argument)
      if maxFrames < 1:
        raise newException(WaterError, "Frame count must be positive")
    elif argument == "--procedural":
      source = Procedural
    else:
      raise newException(WaterError, "Unknown argument: " & argument)
  var lab = Lab(
    window: newWindow(
      "Wind Waker water - " & $source,
      WindowSize,
      visible = maxFrames == 0,
      vsync = maxFrames == 0
    ),
    layerMask: vec3(1.0'f, 1.0'f, 0.0'f),
    shoreLayers: vec4(1.0'f, 1.0'f, 1.0'f, 1.0'f),
    source: source,
    warpOn: true,
    heaveOn: true,
    overlay: getEnv("OVERLAY") == "1",
    yaw: envFloat("CAM_YAW", 0.75'f),
    pitch: envFloat("CAM_PITCH", 0.42'f),
    distance: envFloat("CAM_DIST", 62.0'f),
    lastWall: epochTime(),
    maxFrames: maxFrames)
  makeContextCurrent(lab.window)
  loadExtensions()
  defer:
    lab.destroy()

  lab.waterProgram = buildProgram(
    toShader(waterVertex, ShaderTarget, shaderVertex),
    toShader(waterFragment, ShaderTarget, shaderFragment), "water")
  lab.solidProgram = buildProgram(
    toShader(solidVertex, ShaderTarget, shaderVertex),
    toShader(solidFragment, ShaderTarget, shaderFragment), "solid")
  lab.shoreProgram = buildProgram(
    toShader(shoreVertex, ShaderTarget, shaderVertex),
    toShader(shoreFragment, ShaderTarget, shaderFragment), "shore")
  lab.overlayProgram = buildProgram(
    toShader(overlayVertex, ShaderTarget, shaderVertex),
    toShader(overlayFragment, ShaderTarget, shaderFragment), "overlay")

  lab.sea = seaMesh(lab.waterProgram)
  lab.island = islandMesh(lab.solidProgram)
  lab.shore = shoreMesh(lab.shoreProgram)
  lab.quad = quadMesh(lab.overlayProgram)

  let started = epochTime()
  for source in TextureSource:
    let
      images = loadImages(source)
      wrap =
        if source == Generated:
          GL_MIRRORED_REPEAT.GLint
        else:
          GL_REPEAT.GLint
    for kind in TextureKind:
      let wrapT =
        if kind in {SeaLattice, Warp}:
          wrap
        else:
          GL_CLAMP_TO_EDGE.GLint
      lab.textures[source][kind] = makeTexture(images[kind], wrap, wrapT)
  echo "loaded textures in ",
    formatFloat(epochTime() - started, ffDecimal, 2), "s"
  echo "Wind Waker water: G texture source, 1-3 lattice, 4 wobble, " &
    "5-8 shoreline, H heave, T textures, Space pause, drag orbit, wheel zoom"
  echo "texture source: ", lab.source

  lab.window.onButtonPress = proc(button: Button) =
    case button
    of Key1:
      lab.layerMask.toggle(0)
    of Key2:
      lab.layerMask.toggle(1)
    of Key3:
      lab.layerMask.toggle(2)
    of Key4:
      lab.warpOn = not lab.warpOn
    of Key5:
      lab.shoreLayers.toggle(0)
    of Key6:
      lab.shoreLayers.toggle(1)
    of Key7:
      lab.shoreLayers.toggle(2)
    of Key8:
      lab.shoreLayers.toggle(3)
    of KeyH:
      lab.heaveOn = not lab.heaveOn
    of KeyG:
      case lab.source
      of Generated:
        lab.source = Procedural
      of Procedural:
        lab.source = Generated
      lab.window.title = "Wind Waker water - " & $lab.source
      echo "texture source: ", lab.source
    of KeyT:
      lab.overlay = not lab.overlay
    of KeySpace:
      lab.paused = not lab.paused
    of KeyEscape:
      lab.window.closeRequested = true
    else:
      discard

  while not lab.window.closeRequested:
    pollEvents()
    let now = epochTime()
    var delta = clamp((now - lab.lastWall).float32, 0.0001'f, 0.1'f)
    when defined(takeScreenshot):
      delta = 1.0'f / 60.0'f
    lab.lastWall = now
    if not lab.paused:
      lab.time += delta
    if lab.window.buttonDown[MouseLeft]:
      lab.yaw += lab.window.mouseDelta.x.float32 * 0.005'f
      lab.pitch = clamp(
        lab.pitch + lab.window.mouseDelta.y.float32 * 0.005'f, 0.08'f, 1.5'f)
    if lab.window.scrollDelta.y != 0:
      lab.distance = clamp(
        lab.distance * pow(0.9'f, lab.window.scrollDelta.y), 10.0'f, 400.0'f)
    lab.drawFrame()
    inc lab.frame
    when defined(takeScreenshot):
      if lab.maxFrames > 0 and lab.frame == lab.maxFrames:
        lab.screenshot()
    if lab.maxFrames > 0 and lab.frame >= lab.maxFrames:
      lab.window.closeRequested = true
    lab.window.swapBuffers()

main()
