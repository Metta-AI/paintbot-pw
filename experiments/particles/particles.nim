## GPU particle laboratory with data-driven emitters and instanced billboards.
## The CPU supplies emitter parameters and a short mouse path. Particle birth,
## movement, color, size, and billboard geometry are evaluated in the shaders.
## Run from the polyworld root: nim r experiments/particles/particles.nim

import
  std/[math, os, strformat, strutils, times],
  bumpy, jsony, silky, vmath,
  shaders/sources

when defined(takeScreenshot):
  import pixie

const
  MaxPathSamples = 125
  PathSampleRate = 30.0'f
  WindowSize = ivec2(1280, 800)
  PanelPosition = vec2(10.0'f, 10.0'f)
  PanelSize = vec2(350.0'f, 760.0'f)
  ParticleDirectory = "experiments/particles"
  PresetDirectory = ParticleDirectory / "presets"
  PresetPaths = [
    PresetDirectory / "fire.json",
    PresetDirectory / "smoke.json",
    PresetDirectory / "sparks.json",
    PresetDirectory / "magic.json",
    PresetDirectory / "snow.json",
    PresetDirectory / "trail.json"
  ]

type
  ParticleError = object of CatchableError

  SpawnShape = enum
    PointSpawn
    SphereSpawn
    BoxSpawn
    DiscSpawn
    ConeSpawn
    PathSpawn

  MotionMode = enum
    BallisticMotion
    RadialMotion
    OrbitMotion
    VortexMotion
    PathMotion

  BillboardMode = enum
    CameraBillboard
    VerticalBillboard
    VelocityBillboard

  BlendMode = enum
    AlphaBlend
    AdditiveBlend

  PanelTab = enum
    EmitterTab
    MotionTab
    LookTab

  GeometryKind = enum
    RegularGeometry
    StretchedGeometry

  ParticleUniform = enum
    ViewProjectionUniform
    CameraRightUniform
    CameraUpUniform
    CameraForwardUniform
    TimeUniform
    StartTimeUniform
    ParticleCountUniform
    SeedUniform
    EmissionRateUniform
    LifetimeUniform
    LifetimeJitterUniform
    SpawnShapeUniform
    EmitterPositionUniform
    SpawnSizeUniform
    SpawnRadiusUniform
    SpreadUniform
    MotionModeUniform
    DirectionUniform
    SpeedUniform
    SpeedJitterUniform
    AccelerationUniform
    DragUniform
    TurbulenceUniform
    FrequencyUniform
    OrbitSpeedUniform
    StartSizeUniform
    EndSizeUniform
    SizeJitterUniform
    StretchUniform
    StartColorUniform
    EndColorUniform
    FadeInUniform
    FadeOutUniform
    BillboardModeUniform
    PathCountUniform
    PathTextureUniform

  ParticleEmitter = object
    name: string
    seed: uint32
    particleCount: int
    emissionRate: float32
    lifetime: float32
    lifetimeJitter: float32
    spawnShape: SpawnShape
    spawnSize: Vec3
    spawnRadius: float32
    spread: float32
    motionMode: MotionMode
    direction: Vec3
    speed: float32
    speedJitter: float32
    acceleration: Vec3
    drag: float32
    turbulence: float32
    frequency: float32
    orbitSpeed: float32
    startSize: float32
    endSize: float32
    sizeJitter: float32
    stretch: float32
    startColor: Vec4
    endColor: Vec4
    fadeIn: float32
    fadeOut: float32
    billboardMode: BillboardMode
    blendMode: BlendMode

  ParticleProgram = object
    id: GLuint
    locations: array[ParticleUniform, GLint]

  ParticleRenderer = object
    programs: array[GeometryKind, array[BlendMode, ParticleProgram]]
    vertexArray: GLuint
    pathTexture: GLuint

  PathSample = object
    position: Vec3
    time: float32

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

  ParticleApp = object
    sk: Silky
    renderer: ParticleRenderer
    presets: seq[ParticleEmitter]
    emitter: ParticleEmitter
    camera: CameraState
    path: seq[PathSample]
    emitterPosition: Vec3
    activePreset: int
    panelTab: PanelTab
    showPanel: bool
    paused: bool
    simTime: float32
    effectStart: float32
    nextPathTime: float32
    timeScale: float32
    lastWallTime: float64
    fps: float32
    frameCount: int
    maxFrames: int

const UniformNames: array[ParticleUniform, string] = [
  "uViewProjection",
  "uCameraRight",
  "uCameraUp",
  "uCameraForward",
  "uTime",
  "uStartTime",
  "uParticleCount",
  "uSeed",
  "uEmissionRate",
  "uLifetime",
  "uLifetimeJitter",
  "uSpawnShape",
  "uEmitterPosition",
  "uSpawnSize",
  "uSpawnRadius",
  "uSpread",
  "uMotionMode",
  "uDirection",
  "uSpeed",
  "uSpeedJitter",
  "uAcceleration",
  "uDrag",
  "uTurbulence",
  "uFrequency",
  "uOrbitSpeed",
  "uStartSize",
  "uEndSize",
  "uSizeJitter",
  "uStretch",
  "uStartColor",
  "uEndColor",
  "uFadeIn",
  "uFadeOut",
  "uBillboardMode",
  "uPathCount",
  "uPathTexture"
]

proc parseHook(source: string, index: var int, value: var Vec3) =
  ## Deserializes a three-component vector from a JSON array.
  var components: array[3, float32]
  source.parseHook(index, components)
  value = vec3(components[0], components[1], components[2])

proc parseHook(source: string, index: var int, value: var Vec4) =
  ## Deserializes a four-component vector from a JSON array.
  var components: array[4, float32]
  source.parseHook(index, components)
  value = vec4(
    components[0],
    components[1],
    components[2],
    components[3]
  )

proc dumpHook(json: var string, value: Vec3) {.used.} =
  ## Serializes a three-component vector as a JSON array.
  json.dumpHook([value.x, value.y, value.z])

proc dumpHook(json: var string, value: Vec4) {.used.} =
  ## Serializes a four-component vector as a JSON array.
  json.dumpHook([value.x, value.y, value.z, value.w])

proc loadPreset(path: string): ParticleEmitter {.raises: [ParticleError].} =
  ## Deserializes one complete JSON particle definition with jsony.
  var source: string
  try:
    source = readFile(path)
  except IOError as error:
    raise newException(
      ParticleError,
      "Unable to read " & path & ": " & error.msg
    )
  try:
    result = source.fromJson(ParticleEmitter)
  except ValueError as error:
    raise newException(ParticleError, path & ": " & error.msg)
  if result.name.len == 0:
    raise newException(ParticleError, path & ": name cannot be empty")

proc loadPresets(): seq[ParticleEmitter] {.raises: [ParticleError].} =
  ## Loads the stable ordered list displayed in the control panel.
  for i, path in PresetPaths:
    var preset = loadPreset(path)
    preset.seed = preset.seed xor uint32(i + 1) * 0x9e3779b9'u32
    result.add preset
  when defined(validateParticleJson):
    for preset in result:
      try:
        let serialized = preset.toJson()
        let roundTrip = serialized.fromJson(ParticleEmitter)
        doAssert roundTrip.toJson() == serialized
      except ValueError as error:
        raise newException(
          ParticleError,
          preset.name & " JSON round trip failed: " & error.msg
        )

proc compileStage(
  kind: GLenum,
  source, label: string
): GLuint {.raises: [ParticleError].} =
  ## Compiles a shader stage or raises a particle-specific error.
  result = glCreateShader(kind)
  var sources = allocCStringArray([source])
  defer: deallocCStringArray(sources)
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(max(length.int, 1))
    glGetShaderInfoLog(result, length, nil, log.cstring)
    glDeleteShader(result)
    let message = label & " failed:\n" & log.strip(chars = {'\0'}) &
      "\nExpanded source:\n" & source
    echo message
    raise newException(ParticleError, message)

proc compileProgram(
  vertexSource, fragmentSource: string,
  vertexLabel, fragmentLabel: string
): ParticleProgram {.raises: [ParticleError].} =
  ## Compiles and links one pair of Shady-generated OpenGL shader stages.
  let
    vertexShader = compileStage(
      GL_VERTEX_SHADER,
      vertexSource,
      vertexLabel
    )
    fragmentShader = compileStage(
      GL_FRAGMENT_SHADER,
      fragmentSource,
      fragmentLabel
    )
  result.id = glCreateProgram()
  glAttachShader(result.id, vertexShader)
  glAttachShader(result.id, fragmentShader)
  glLinkProgram(result.id)
  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)
  var ok: GLint
  glGetProgramiv(result.id, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetProgramiv(result.id, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(max(length.int, 1))
    glGetProgramInfoLog(result.id, length, nil, log.cstring)
    glDeleteProgram(result.id)
    raise newException(
      ParticleError,
      vertexLabel & " + " & fragmentLabel & " failed to link:\n" & log
    )
  for uniform in ParticleUniform:
    result.locations[uniform] = glGetUniformLocation(
      result.id,
      UniformNames[uniform].cstring
    )

proc newParticleRenderer(): ParticleRenderer {.raises: [ParticleError].} =
  ## Builds the Shady-generated shader family and shared path texture.
  when defined(emscripten):
    const
      BillboardSource = BillboardWeb
      StretchedSource = StretchedWeb
      AlphaSource = AlphaWeb
      AdditiveSource = AdditiveWeb
  else:
    const
      BillboardSource = BillboardDesktop
      StretchedSource = StretchedDesktop
      AlphaSource = AlphaDesktop
      AdditiveSource = AdditiveDesktop
  result.programs[RegularGeometry][AlphaBlend] = compileProgram(
    BillboardSource,
    AlphaSource,
    "Shady billboard vertex",
    "Shady soft alpha fragment"
  )
  result.programs[RegularGeometry][AdditiveBlend] = compileProgram(
    BillboardSource,
    AdditiveSource,
    "Shady billboard vertex",
    "Shady soft additive fragment"
  )
  result.programs[StretchedGeometry][AlphaBlend] = compileProgram(
    StretchedSource,
    AlphaSource,
    "Shady stretched vertex",
    "Shady soft alpha fragment"
  )
  result.programs[StretchedGeometry][AdditiveBlend] = compileProgram(
    StretchedSource,
    AdditiveSource,
    "Shady stretched vertex",
    "Shady soft additive fragment"
  )
  glGenVertexArrays(1, result.vertexArray.addr)
  glGenTextures(1, result.pathTexture.addr)
  glBindTexture(GL_TEXTURE_2D, result.pathTexture)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_RGBA32F.GLint,
    MaxPathSamples,
    1,
    0,
    GL_RGBA,
    cGL_FLOAT,
    nil
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MIN_FILTER,
    GL_NEAREST.GLint
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MAG_FILTER,
    GL_NEAREST.GLint
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_WRAP_S,
    GL_CLAMP_TO_EDGE
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_WRAP_T,
    GL_CLAMP_TO_EDGE
  )
  glBindTexture(GL_TEXTURE_2D, 0)

proc close(renderer: var ParticleRenderer) =
  ## Releases particle programs, path texture, and the empty vertex array.
  for geometry in GeometryKind:
    for blend in BlendMode:
      if renderer.programs[geometry][blend].id != 0:
        glDeleteProgram(renderer.programs[geometry][blend].id)
  if renderer.vertexArray != 0:
    glDeleteVertexArrays(1, renderer.vertexArray.addr)
  if renderer.pathTexture != 0:
    glDeleteTextures(1, renderer.pathTexture.addr)
  renderer = ParticleRenderer()

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

proc mouseOverUi(app: ParticleApp, window: Window): bool =
  ## Returns whether the pointer is over a visible Silky subwindow.
  if not app.showPanel:
    return false
  let mousePosition = window.mousePos.vec2
  for state in subWindowStates.values:
    if state.visible and mousePosition.overlaps(rect(state.pos, state.size)):
      return true
  mousePosition.overlaps(rect(PanelPosition, PanelSize))

proc mouseInScene(app: var ParticleApp, window: Window): tuple[
    hit: bool,
    position: Vec3
  ] =
  ## Intersects the pointer ray with a camera-facing plane through the target.
  let
    width = max(window.size.x.float32, 1.0'f)
    height = max(window.size.y.float32, 1.0'f)
    ndcX = 2.0'f * window.mousePos.x.float32 / width - 1.0'f
    ndcY = 1.0'f - 2.0'f * window.mousePos.y.float32 / height
    inverseViewProjection = inverse(app.camera.viewProjection(window.size))
  var
    nearPoint = inverseViewProjection * vec4(ndcX, ndcY, -1.0'f, 1.0'f)
    farPoint = inverseViewProjection * vec4(ndcX, ndcY, 1.0'f, 1.0'f)
  nearPoint = nearPoint / nearPoint.w
  farPoint = farPoint / farPoint.w
  let
    direction = normalize(farPoint.xyz - nearPoint.xyz)
    denominator = dot(direction, app.camera.forward)
  if abs(denominator) < 0.0001'f:
    return
  let distance = dot(
    app.camera.target - nearPoint.xyz,
    app.camera.forward
  ) / denominator
  if distance <= 0.0'f:
    return
  let position = nearPoint.xyz + direction * distance
  if length(position - app.camera.target) > 35.0'f:
    return
  (true, position)

proc addPathSample(app: var ParticleApp, position: Vec3, time: float32) =
  ## Appends one chronological path sample and keeps the history bounded.
  if app.path.len > 0 and time <= app.path[^1].time:
    app.path[^1] = PathSample(position: position, time: time)
    return
  app.path.add PathSample(position: position, time: time)
  if app.path.len > MaxPathSamples:
    app.path.delete(0)

proc resetPath(app: var ParticleApp) =
  ## Clears path history and anchors it at the current emitter position.
  app.path.setLen(0)
  app.addPathSample(app.emitterPosition, app.simTime)
  app.nextPathTime = app.simTime + 1.0'f / PathSampleRate

proc samplePath(app: var ParticleApp) =
  ## Samples the mouse-driven emitter at a stable rate for the shader array.
  let interval = 1.0'f / PathSampleRate
  while app.nextPathTime <= app.simTime:
    app.addPathSample(app.emitterPosition, app.nextPathTime)
    app.nextPathTime += interval

proc restart(app: var ParticleApp) =
  ## Restarts particle birth sequencing without discarding the mouse path.
  app.effectStart = app.simTime

proc selectPreset(app: var ParticleApp, index: int) =
  ## Selects one loaded preset and restarts its particles.
  if index < 0 or index >= app.presets.len:
    return
  app.activePreset = index
  app.emitter = app.presets[index]
  app.restart()

proc handleInput(app: var ParticleApp, window: Window) =
  ## Handles camera movement, shortcuts, and mouse-to-world emitter movement.
  if window.buttonPressed[KeyEscape]:
    window.closeRequested = true
  if window.buttonPressed[KeyTab]:
    app.showPanel = not app.showPanel
  if window.buttonPressed[KeySpace]:
    app.paused = not app.paused
  if window.buttonPressed[KeyR]:
    app.restart()
  if window.buttonPressed[KeyC]:
    app.resetPath()

  discard app.camera.viewProjection(window.size)
  let overUi = app.mouseOverUi(window)
  if window.buttonPressed[MouseRight] and not overUi:
    if window.buttonDown[KeyLeftShift] or
      window.buttonDown[KeyRightShift]:
        app.camera.panning = true
    else:
      app.camera.rotating = true
  if window.buttonPressed[MouseMiddle] and not overUi:
    app.camera.panning = true
  if not window.buttonDown[MouseRight] and
    not window.buttonDown[MouseMiddle]:
      app.camera.rotating = false
      app.camera.panning = false

  let mouseDelta = window.mouseDelta.vec2
  if app.camera.rotating:
    app.camera.yaw -= mouseDelta.x * 0.01'f
    app.camera.pitch = clamp(
      app.camera.pitch + mouseDelta.y * 0.01'f,
      0.08'f,
      1.48'f
    )
  if app.camera.panning:
    let
      flatRight = normalize(vec3(
        app.camera.right.x,
        0.0'f,
        app.camera.right.z
      ))
      flatForward = normalize(vec3(
        app.camera.forward.x,
        0.0'f,
        app.camera.forward.z
      ))
      panSpeed = app.camera.distance * 0.0015'f
    app.camera.target -= flatRight * mouseDelta.x * panSpeed
    app.camera.target += flatForward * mouseDelta.y * panSpeed
  if not overUi and window.scrollDelta.y != 0.0'f:
    app.camera.distance = clamp(
      app.camera.distance * pow(0.92'f, window.scrollDelta.y),
      2.0'f,
      60.0'f
    )

  if app.maxFrames == 0 and
    not overUi and
    not app.camera.rotating and
    not app.camera.panning:
      let scenePosition = app.mouseInScene(window)
      if scenePosition.hit:
        app.emitterPosition = scenePosition.position

proc uploadPath(
  renderer: ParticleRenderer,
  path: seq[PathSample]
): int =
  ## Uploads the bounded timestamped mouse path as a float texture.
  result = min(path.len, MaxPathSamples)
  if result <= 0:
    return
  var samples: array[MaxPathSamples, Vec4]
  let first = path.len - result
  for i in 0 ..< result:
    let sample = path[first + i]
    samples[i] = vec4(
      sample.position.x,
      sample.position.y,
      sample.position.z,
      sample.time
    )
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, renderer.pathTexture)
  glTexSubImage2D(
    GL_TEXTURE_2D,
    0,
    0,
    0,
    result.GLsizei,
    1,
    GL_RGBA,
    cGL_FLOAT,
    cast[pointer](samples[0].addr)
  )

proc upload(
  program: ParticleProgram,
  emitter: ParticleEmitter,
  camera: CameraState,
  viewProjection: var Mat4,
  pathCount: int,
  emitterPosition: Vec3,
  time, startTime: float32
) =
  ## Uploads one emitter and its render state to a particle shader program.
  template location(uniform: ParticleUniform): GLint =
    program.locations[uniform]

  glUniformMatrix4fv(
    location(ViewProjectionUniform),
    1,
    GL_FALSE,
    cast[ptr float32](viewProjection.addr)
  )
  glUniform3f(
    location(CameraRightUniform),
    camera.right.x,
    camera.right.y,
    camera.right.z
  )
  glUniform3f(
    location(CameraUpUniform),
    camera.up.x,
    camera.up.y,
    camera.up.z
  )
  glUniform3f(
    location(CameraForwardUniform),
    camera.forward.x,
    camera.forward.y,
    camera.forward.z
  )
  glUniform1f(location(TimeUniform), time)
  glUniform1f(location(StartTimeUniform), startTime)
  glUniform1i(location(ParticleCountUniform), emitter.particleCount.GLint)
  glUniform1f(
    location(SeedUniform),
    (emitter.seed mod 65_521'u32).float32
  )
  glUniform1f(location(EmissionRateUniform), emitter.emissionRate)
  glUniform1f(location(LifetimeUniform), emitter.lifetime)
  glUniform1f(location(LifetimeJitterUniform), emitter.lifetimeJitter)
  glUniform1i(location(SpawnShapeUniform), emitter.spawnShape.ord.GLint)
  glUniform3f(
    location(EmitterPositionUniform),
    emitterPosition.x,
    emitterPosition.y,
    emitterPosition.z
  )
  glUniform3f(
    location(SpawnSizeUniform),
    emitter.spawnSize.x,
    emitter.spawnSize.y,
    emitter.spawnSize.z
  )
  glUniform1f(location(SpawnRadiusUniform), emitter.spawnRadius)
  glUniform1f(location(SpreadUniform), emitter.spread)
  glUniform1i(location(MotionModeUniform), emitter.motionMode.ord.GLint)
  glUniform3f(
    location(DirectionUniform),
    emitter.direction.x,
    emitter.direction.y,
    emitter.direction.z
  )
  glUniform1f(location(SpeedUniform), emitter.speed)
  glUniform1f(location(SpeedJitterUniform), emitter.speedJitter)
  glUniform3f(
    location(AccelerationUniform),
    emitter.acceleration.x,
    emitter.acceleration.y,
    emitter.acceleration.z
  )
  glUniform1f(location(DragUniform), emitter.drag)
  glUniform1f(location(TurbulenceUniform), emitter.turbulence)
  glUniform1f(location(FrequencyUniform), emitter.frequency)
  glUniform1f(location(OrbitSpeedUniform), emitter.orbitSpeed)
  glUniform1f(location(StartSizeUniform), emitter.startSize)
  glUniform1f(location(EndSizeUniform), emitter.endSize)
  glUniform1f(location(SizeJitterUniform), emitter.sizeJitter)
  glUniform1f(location(StretchUniform), emitter.stretch)
  glUniform4f(
    location(StartColorUniform),
    emitter.startColor.x,
    emitter.startColor.y,
    emitter.startColor.z,
    emitter.startColor.w
  )
  glUniform4f(
    location(EndColorUniform),
    emitter.endColor.x,
    emitter.endColor.y,
    emitter.endColor.z,
    emitter.endColor.w
  )
  glUniform1f(location(FadeInUniform), emitter.fadeIn)
  glUniform1f(location(FadeOutUniform), emitter.fadeOut)
  glUniform1i(
    location(BillboardModeUniform),
    emitter.billboardMode.ord.GLint
  )
  glUniform1i(location(PathCountUniform), pathCount.GLint)
  glUniform1i(location(PathTextureUniform), 0)

proc drawParticles(app: var ParticleApp, window: Window) =
  ## Draws the entire emitter with one instanced four-vertex call.
  let geometry =
    if app.emitter.billboardMode == VelocityBillboard:
      StretchedGeometry
    else:
      RegularGeometry
  let program = app.renderer.programs[geometry][app.emitter.blendMode]
  var viewProjection = app.camera.viewProjection(window.size)

  glViewport(0, 0, window.size.x, window.size.y)
  glClearColor(0.025'f, 0.032'f, 0.052'f, 1.0'f)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glEnable(GL_BLEND)
  case app.emitter.blendMode
  of AlphaBlend:
    glBlendFuncSeparate(
      GL_SRC_ALPHA,
      GL_ONE_MINUS_SRC_ALPHA,
      GL_ONE,
      GL_ONE_MINUS_SRC_ALPHA
    )
  of AdditiveBlend:
    glBlendFuncSeparate(
      GL_SRC_ALPHA,
      GL_ONE,
      GL_ZERO,
      GL_ONE
    )

  glUseProgram(program.id)
  let pathCount = app.renderer.uploadPath(app.path)
  program.upload(
    app.emitter,
    app.camera,
    viewProjection,
    pathCount,
    app.emitterPosition,
    app.simTime,
    app.effectStart
  )
  glBindVertexArray(app.renderer.vertexArray)
  glDrawArraysInstanced(
    GL_TRIANGLE_STRIP,
    0,
    4,
    max(app.emitter.particleCount, 1).GLsizei
  )
  glBindVertexArray(0)
  glUseProgram(0)
  glDepthMask(GL_TRUE)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_BLEND)

template scrubFloat(
  id, caption: string,
  target: var float32,
  low, high: float32
) =
  ## Draws a labeled floating-point particle control.
  text(caption & ": " & target.formatFloat(ffDecimal, 2))
  scrubber(id, target, low, high, "")

template scrubInt(
  id, caption: string,
  target: var int,
  low, high: int
) =
  ## Draws a labeled integer particle control.
  text(caption & ": " & $target)
  scrubber(id, target, low, high, "")

proc drawUi(app: var ParticleApp, window: Window) =
  ## Draws preset selection, parameter tabs, and interaction help.
  let sk = app.sk
  sk.beginUi(window, window.size)
  if app.showPanel:
    subWindow(
      "GPU Particles",
      app.showPanel,
      PanelPosition,
      PanelSize
    ):
      text(&"{app.emitter.name}  {app.fps:>4.0f} fps")
      group "transport row":
        box 310, 32
        layout LeftToRight
        itemSpacing 6
        button(if app.paused: "Resume" else: "Pause"):
          app.paused = not app.paused
        button("Restart"):
          app.restart()
        button("Clear Path"):
          app.resetPath()
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
      group "tab row":
        box 310, 32
        layout LeftToRight
        itemSpacing 8
        radioButton("Emitter", app.panelTab, EmitterTab)
        radioButton("Motion", app.panelTab, MotionTab)
        radioButton("Look", app.panelTab, LookTab)

      case app.panelTab
      of EmitterTab:
        scrubInt(
          "particleCount",
          "Particle count",
          app.emitter.particleCount,
          64,
          30000
        )
        scrubFloat(
          "emissionRate",
          "Emission rate",
          app.emitter.emissionRate,
          1.0'f,
          3000.0'f
        )
        scrubFloat(
          "lifetime",
          "Lifetime",
          app.emitter.lifetime,
          0.05'f,
          10.0'f
        )
        scrubFloat(
          "lifetimeJitter",
          "Lifetime jitter",
          app.emitter.lifetimeJitter,
          0.0'f,
          0.95'f
        )
        text("Spawn shape")
        group "spawn row one":
          box 310, 32
          layout LeftToRight
          itemSpacing 6
          radioButton("Point", app.emitter.spawnShape, PointSpawn)
          radioButton("Sphere", app.emitter.spawnShape, SphereSpawn)
          radioButton("Box", app.emitter.spawnShape, BoxSpawn)
        group "spawn row two":
          box 310, 32
          layout LeftToRight
          itemSpacing 6
          radioButton("Disc", app.emitter.spawnShape, DiscSpawn)
          radioButton("Cone", app.emitter.spawnShape, ConeSpawn)
          radioButton("Path", app.emitter.spawnShape, PathSpawn)
        scrubFloat(
          "spawnRadius",
          "Spawn radius",
          app.emitter.spawnRadius,
          0.0'f,
          6.0'f
        )
        if app.emitter.spawnShape == BoxSpawn:
          scrubFloat(
            "spawnSizeX",
            "Box half-size X",
            app.emitter.spawnSize.x,
            0.0'f,
            8.0'f
          )
          scrubFloat(
            "spawnSizeY",
            "Box half-size Y",
            app.emitter.spawnSize.y,
            0.0'f,
            8.0'f
          )
          scrubFloat(
            "spawnSizeZ",
            "Box half-size Z",
            app.emitter.spawnSize.z,
            0.0'f,
            8.0'f
          )
        scrubFloat(
          "spread",
          "Cone spread",
          app.emitter.spread,
          0.0'f,
          85.0'f
        )
        scrubFloat(
          "timeScale",
          "Time scale",
          app.timeScale,
          0.0'f,
          3.0'f
        )
      of MotionTab:
        text("Motion mode")
        group "motion row one":
          box 310, 32
          layout LeftToRight
          itemSpacing 6
          radioButton("Ballistic", app.emitter.motionMode, BallisticMotion)
          radioButton("Radial", app.emitter.motionMode, RadialMotion)
        group "motion row two":
          box 310, 32
          layout LeftToRight
          itemSpacing 6
          radioButton("Orbit", app.emitter.motionMode, OrbitMotion)
          radioButton("Vortex", app.emitter.motionMode, VortexMotion)
          radioButton("Path", app.emitter.motionMode, PathMotion)
        scrubFloat(
          "speed",
          "Speed",
          app.emitter.speed,
          0.0'f,
          12.0'f
        )
        scrubFloat(
          "speedJitter",
          "Speed jitter",
          app.emitter.speedJitter,
          0.0'f,
          1.0'f
        )
        scrubFloat(
          "directionX",
          "Direction X",
          app.emitter.direction.x,
          -1.0'f,
          1.0'f
        )
        scrubFloat(
          "directionY",
          "Direction Y",
          app.emitter.direction.y,
          -1.0'f,
          1.0'f
        )
        scrubFloat(
          "directionZ",
          "Direction Z",
          app.emitter.direction.z,
          -1.0'f,
          1.0'f
        )
        scrubFloat(
          "accelerationX",
          "Acceleration X",
          app.emitter.acceleration.x,
          -12.0'f,
          12.0'f
        )
        scrubFloat(
          "accelerationY",
          "Acceleration Y",
          app.emitter.acceleration.y,
          -12.0'f,
          12.0'f
        )
        scrubFloat(
          "accelerationZ",
          "Acceleration Z",
          app.emitter.acceleration.z,
          -12.0'f,
          12.0'f
        )
        scrubFloat("drag", "Drag", app.emitter.drag, 0.0'f, 4.0'f)
        scrubFloat(
          "turbulence",
          "Turbulence",
          app.emitter.turbulence,
          0.0'f,
          2.0'f
        )
        scrubFloat(
          "frequency",
          "Noise frequency",
          app.emitter.frequency,
          0.1'f,
          15.0'f
        )
        scrubFloat(
          "orbitSpeed",
          "Orbit speed",
          app.emitter.orbitSpeed,
          -8.0'f,
          8.0'f
        )
      of LookTab:
        text("Billboard")
        group "billboard row":
          box 310, 32
          layout LeftToRight
          itemSpacing 6
          radioButton("Camera", app.emitter.billboardMode, CameraBillboard)
          radioButton("Vertical", app.emitter.billboardMode, VerticalBillboard)
          radioButton("Velocity", app.emitter.billboardMode, VelocityBillboard)
        text("Blending")
        group "blend row":
          box 310, 32
          layout LeftToRight
          itemSpacing 6
          radioButton("Alpha", app.emitter.blendMode, AlphaBlend)
          radioButton("Additive", app.emitter.blendMode, AdditiveBlend)
        scrubFloat(
          "startSize",
          "Start size",
          app.emitter.startSize,
          0.005'f,
          2.5'f
        )
        scrubFloat(
          "endSize",
          "End size",
          app.emitter.endSize,
          0.005'f,
          3.0'f
        )
        scrubFloat(
          "sizeJitter",
          "Size jitter",
          app.emitter.sizeJitter,
          0.0'f,
          0.95'f
        )
        scrubFloat(
          "stretch",
          "Velocity stretch",
          app.emitter.stretch,
          0.0'f,
          0.8'f
        )
        scrubFloat(
          "startRed",
          "Start red",
          app.emitter.startColor.x,
          0.0'f,
          1.0'f
        )
        scrubFloat(
          "startGreen",
          "Start green",
          app.emitter.startColor.y,
          0.0'f,
          1.0'f
        )
        scrubFloat(
          "startBlue",
          "Start blue",
          app.emitter.startColor.z,
          0.0'f,
          1.0'f
        )
        scrubFloat(
          "startAlpha",
          "Start alpha",
          app.emitter.startColor.w,
          0.0'f,
          1.0'f
        )
        scrubFloat(
          "endRed",
          "End red",
          app.emitter.endColor.x,
          0.0'f,
          1.0'f
        )
        scrubFloat(
          "endGreen",
          "End green",
          app.emitter.endColor.y,
          0.0'f,
          1.0'f
        )
        scrubFloat(
          "endBlue",
          "End blue",
          app.emitter.endColor.z,
          0.0'f,
          1.0'f
        )
        scrubFloat(
          "endAlpha",
          "End alpha",
          app.emitter.endColor.w,
          0.0'f,
          1.0'f
        )
        scrubFloat(
          "fadeIn",
          "Fade in",
          app.emitter.fadeIn,
          0.0'f,
          1.0'f
        )
        scrubFloat(
          "fadeOut",
          "Fade out",
          app.emitter.fadeOut,
          0.0'f,
          1.0'f
        )
      text(&"Path: {app.path.len}/{MaxPathSamples} samples")
      text("Mouse moves emitter")
      text("Right drag orbit, middle drag pan")
      text("Scroll zoom, Space pause, R restart")
      text("Tab toggles panel")
  sk.endUi()

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

proc tick(app: var ParticleApp, window: Window) =
  ## Advances time, updates the path, and renders one complete frame.
  let now = epochTime()
  var delta = clamp((now - app.lastWallTime).float32, 0.0001'f, 0.1'f)
  when defined(takeScreenshot):
    delta = 1.0'f / 60.0'f
  app.lastWallTime = now
  app.fps = app.fps * 0.92'f + (1.0'f / delta) * 0.08'f
  app.handleInput(window)
  if not app.paused:
    app.simTime += delta * app.timeScale
  app.samplePath()
  app.drawParticles(window)
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
      image.writeFile("/tmp/polyworld_particles.png")
  if app.maxFrames > 0 and app.frameCount >= app.maxFrames:
    window.closeRequested = true

proc main() =
  ## Creates and runs the standalone GPU particle experiment.
  let atlasBuilder = newAtlasBuilder(1024, 4)
  atlasBuilder.addDir("../polyworld_data/themes/main/", "../polyworld_data/themes/main/")
  atlasBuilder.addFont(
    "../polyworld_data/themes/main/IBMPlexSans-Regular.ttf",
    "H1",
    32.0'f
  )
  atlasBuilder.addFont(
    "../polyworld_data/themes/main/IBMPlexSans-Regular.ttf",
    "Default",
    18.0'f
  )
  atlasBuilder.write("tmp/editor.atlas.png")

  let maxFrames = maxFramesFromArgs()
  let window = newWindow(
    "GPU Particles",
    WindowSize,
    visible = maxFrames == 0,
    vsync = false
  )
  makeContextCurrent(window)
  loadExtensions()
  let sk = newSilky(window, "tmp/editor.atlas.png")
  window.runeInputEnabled = true
  window.onRune = proc(rune: Rune) =
    sk.inputRunes.add rune

  let presets = loadPresets()
  let presetIndex = presetFromArgs(presets.len)
  var app = ParticleApp(
    sk: sk,
    renderer: newParticleRenderer(),
    presets: presets,
    emitter: presets[presetIndex],
    camera: CameraState(
      yaw: 0.62'f,
      pitch: 0.38'f,
      distance: 10.0'f,
      target: vec3(0.0'f, 1.0'f, 0.0'f)
    ),
    emitterPosition: vec3(0.0'f),
    activePreset: presetIndex,
    panelTab: EmitterTab,
    showPanel: true,
    timeScale: 1.0'f,
    lastWallTime: epochTime(),
    maxFrames: maxFrames
  )
  app.resetPath()

  echo "GPU particle controls: move the mouse over the scene to move the " &
    "emitter. Right drag orbits, scroll zooms, Space pauses, R restarts."
  while not window.closeRequested:
    pollEvents()
    app.tick(window)
    window.swapBuffers()

  app.renderer.close()
  window.close()

main()
