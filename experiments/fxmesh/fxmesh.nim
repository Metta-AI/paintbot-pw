## FX mesh laboratory. The mesh builder and shader live in
## `polyworld/fxmeshes`. This file is the editor: presets, camera, and the
## control panel. Run from the polyworld root:
## `nim r experiments/fxmesh/fxmesh.nim`

import
  std/[math, os, strformat, strutils, tables, times],
  bumpy, opengl, silky, vmath,
  polyworld/fxmeshes

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
    PresetDirectory / "tornado.json",
    PresetDirectory / "nova.json",
    PresetDirectory / "castline.json",
    PresetDirectory / "conecast.json",
    PresetDirectory / "groundswipe.json"
  ]

type
  PanelTab = enum
    ShapeTab
    BuildTab
    AnimTab
    LookTab
    ColorTab
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

## Application

type FxApp = object
  sk: Silky
  renderer: FxRenderer
  presets: seq[FxSettings]
  settings: FxSettings
  builtKey: typeof(fxGeometryKey(FxSettings()))
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

proc lifeFraction(app: FxApp): float32 =
  ## Where the current effect sits inside its duration.
  fxLife(
    max(app.simTime - app.effectStart, 0.0'f32),
    app.settings.duration,
    app.settings.loop
  )

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

proc loadPresets(): seq[FxSettings] =
  ## Loads the stable ordered list displayed in the control panel.
  for path in PresetPaths:
    result.add loadFxSettings(path)

proc drawMesh(app: var FxApp, window: Window) =
  ## Clears the lab view and draws the current fx mesh.
  glViewport(0, 0, window.size.x, window.size.y)
  glClearColor(0.025'f, 0.032'f, 0.052'f, 1.0'f)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  drawFxMesh(
    app.renderer,
    app.settings,
    app.camera.viewProjection(window.size),
    fxModel(app.settings.axis),
    app.simTime,
    app.lifeFraction(),
    app.wireframe
  )

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
  text("Ground AoE")
  group "shape row six":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("AoE Circle", s.shape, AoeCircleShape)
    radioButton("AoE Line", s.shape, AoeLineShape)
  group "shape row seven":
    box 310, 32
    layout LeftToRight
    itemSpacing 6
    radioButton("AoE Cone", s.shape, AoeConeShape)
    radioButton("AoE Capsule", s.shape, AoeCapsuleShape)
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
  of AoeCircleShape:
    scrubFloat("radius", "Radius", s.radius, 0.05'f, 8.0'f)
    scrubFloat("innerRadius", "Inner radius", s.innerRadius, 0.0'f, 8.0'f)
    scrubInt("radialSegments", "Resolution", s.radialSegments, 3, 128)
    scrubInt("widthSegments", "Rings", s.widthSegments, 1, 64)
  of AoeLineShape:
    scrubFloat("width", "Width", s.width, 0.05'f, 6.0'f)
    scrubFloat("length", "Length", s.length, 0.05'f, 12.0'f)
    scrubFloat("angleOffset", "Facing degrees", s.angleOffset, -180.0'f, 180.0'f)
    scrubInt("widthSegments", "Width segments", s.widthSegments, 1, 32)
    scrubInt("lengthSegments", "Length segments", s.lengthSegments, 1, 128)
  of AoeConeShape:
    scrubFloat("radius", "Length", s.radius, 0.05'f, 8.0'f)
    scrubFloat("innerRadius", "Inner radius", s.innerRadius, 0.0'f, 8.0'f)
    scrubFloat("arcDegrees", "Cone degrees", s.arcDegrees, -360.0'f, 360.0'f)
    scrubFloat("angleOffset", "Facing degrees", s.angleOffset, -180.0'f, 180.0'f)
    scrubInt("radialSegments", "Resolution", s.radialSegments, 3, 128)
    scrubInt("widthSegments", "Rings", s.widthSegments, 1, 64)
  of AoeCapsuleShape:
    scrubFloat("width", "Width", s.width, 0.05'f, 6.0'f)
    scrubFloat("length", "Length", s.length, 0.05'f, 12.0'f)
    scrubFloat("angleOffset", "Facing degrees", s.angleOffset, -180.0'f, 180.0'f)
    scrubInt("radialSegments", "Cap segments", s.radialSegments, 3, 64)
    scrubInt("widthSegments", "Width segments", s.widthSegments, 1, 32)
    scrubInt("lengthSegments", "Length segments", s.lengthSegments, 1, 128)

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
      var presetRowStart = 0
      while presetRowStart < app.presets.len:
        group "preset row " & $presetRowStart:
          box 310, 32
          layout LeftToRight
          itemSpacing 6
          for i in presetRowStart ..< min(presetRowStart + 3, app.presets.len):
            button(app.presets[i].name):
              app.selectPreset(i)
        presetRowStart += 3
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
  let key = fxGeometryKey(app.settings)
  if key != app.builtKey:
    app.renderer.uploadFxMesh(app.settings)
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
  atlasBuilder.write("tmp/editor.atlas.png")

  let maxFrames = maxFramesFromArgs()
  let window = newWindow(
    "FX Mesh",
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
  var app = FxApp(
    sk: sk,
    renderer: initFxRenderer(),
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
  app.renderer.uploadFxMesh(app.settings)
  app.builtKey = fxGeometryKey(app.settings)

  echo "FX mesh controls: right drag orbits, scroll zooms, Space pauses, " &
    "R restarts the effect, W toggles wireframe."
  while not window.closeRequested:
    pollEvents()
    app.tick(window)
    window.swapBuffers()

  closeFxRenderer(app.renderer)
  window.close()

main()
