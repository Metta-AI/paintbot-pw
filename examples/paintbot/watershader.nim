## Paintbot's own water shader, installed in place of the engine's default.
##
## What is seen through the water is tinted toward its colour by a constant strength.
##
## The lake (and river) and the ocean have their own parameters: each is drawn on its
## own (its range in the engine's water mesh), with its own reflection pass mirrored at
## its own height.
##
## The water is a planar mirror: each frame the scene is rendered once more from the camera
## reflected in the water plane, into an offscreen texture, and the water samples that
## texture at its own screen position. How much it reflects follows Schlick's Fresnel
## approximation, with the reflectiveness as the reflectance looking straight down:
##
##   R(θ) = R0 + (1 − R0) · s · (1 − cos θ)^p
##
## where cos θ = dot(up, toward the camera), R0 is the reflectiveness, s the Fresnel
## strength (0 turns the effect off) and p its power (5 in Schlick's formula).
##
## The reflection pass draws the sky without its sun: a mirrored disc, cut up by the
## ripples' distortion, reads as a fragmented disc rather than light scattered by waves.
## The sun reaches the water only through the ripple normals. It lights the surface as a
## broad sheen: the view ray reflected off the water, compared with the direction toward
## the sun, weighted by that Fresnel:
##
##   sheen = sunColour · strength · R(θ) · pow(max(dot(reflect(view, up), sun), 0), sharpness)
##
## A low sharpness spreads it over the water on the sun's side, as glare does on
## slightly rough water; it is added as light, so it whitens without hiding the scene.
##
## Ripples: the surface's normal comes from a sum of travelling waves after afl_ext's
## "Very fast procedural ocean" (https://www.shadertoy.com/view/MdXyzX, MIT License,
## (c) 2017-2024 afl_ext). Each wave is exp(sin(x) - 1), sharp crests over flat troughs;
## each turns to a scattered direction, rises 1.18x in frequency and fades 20%, and its
## slope drags where the next one is sampled, so small ripples gather on larger ones.
## The normal tilts the reflection lookup (distortion), the Fresnel angle, the sheen and
## a sharp sun glint, and flattens with distance so far water does not shimmer.
##
## Refraction: drawPaintbotWater copies the scene's colour with its depth, and the water
## draws that copy itself, read at a spot the ripples push sideways. The push grows with
## the water's depth up to refractionDepth, so the shoreline seam stays closed while the
## bed just inside it wobbles; a push landing on something in front of the water (a cog,
## a tower) falls back to the straight lookup, so foreground objects never smear into it.
##
## Shorelines: each pixel marches outward across the water's surface in 8 directions,
## projecting each probe to the screen and comparing it with the copied depth: where the
## scene there stands just above the surface (by less than shoreHeight), it is land, or
## something standing in the water; higher things seen there (a canopy or roof hanging over
## the water) are not, so they get no foam halo.
## The nearest hit, refined by bisection, gives the distance to the shore; all the hits
## give the direction to it. Two effects use them:
##   foam: a tileable noise texture, in world metres at foamScale, flowing toward the
##         shore: every direction that reaches land pulls the flow toward it (weighted by
##         1 / distance^2, so it turns smoothly around bends and islands), and two copies
##         of the noise slide along it half a cycle apart, crossfading as each restarts
##         (the flow-map technique). It shows where it exceeds a threshold that falls from 1 at foamDistance
##         to 0 at the waterline, so foam thickens toward the shore and breaks up away
##         from it.
##   fade: the water, foam included, blends into the scene behind it as it nears the shore,
##         alpha = (distance / fadeDistance)^fadeCurve, smoothing where water meets land.

import std/[math, random, times]
import opengl, shady, vmath
import chroma
import polyworld/quadterrain
import topography, sky

const
  ShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop
  ReflectionUnit = 6 # drawWater uses units 0 and 1, the toon shadows 3 and 4
  SceneDepthUnit = 7
  SceneColorUnit = 5
  FoamNoiseUnit = 8
  ShoreDirections = 8 # directions the shore search marches in
  ShoreSteps = 6 # steps along each, before bisecting the nearest hit
  MaxShoreSearch = 12'f32 # metres; the search reaches the larger of foam and fade distance
  RiverSurface* = RiverWaterHeight.float32 / 100 # metres, where the river's mesh is baked
  SeaSurface* = -2.75'f32 # metres, where the ocean's mesh is baked
  MaxWaves* = 32

type WaterParams* = object
  ## The water shader's live parameters; the developer panel edits them.
  color*: Vec3 ## the water's own colour, tinting what is seen through it
  colorStrength*: float32 ## 0 clear water, 1 only the colour shows through
  height*: float32 ## the river's drawn surface; the sea moves with it (visual only)
  reflectiveness*: float32 ## reflectance looking straight down: 0 the scene below only, 1 a mirror
  fresnelStrength*: float32 ## 0 reflects the same at every angle, 1 is Schlick's Fresnel
  fresnelPower*: float32 ## how sharply reflection rises towards grazing angles
  sheenStrength*: float32 ## the sun's glare over the water; 0 turns it off
  sheenSharpness*: float32 ## low spreads the glare over the water, high narrows it to the sun
  waveHeight*: float32 ## metres from trough to crest of the summed ripples
  waveScale*: float32 ## metres per radian of the longest wave (its wavelength / 2π)
  waveSpeed*: float32 ## multiplies how fast the waves travel
  waveDrag*: float32 ## how much each wave's slope pulls the next; bunches ripples together
  waveCount*: float32 ## waves summed, 1 to MaxWaves; each adds shorter, fainter ripples
  rippleFade*: float32 ## metres from the camera at which ripples have flattened most
  distortion*: float32 ## how far the ripples bend the reflection, in screen fractions
  glintStrength*: float32 ## the sun's sharp sparkle on each ripple; 0 turns it off
  glintSharpness*: float32 ## higher makes glints smaller and tighter
  refraction*: float32 ## how far the ripples bend what is seen through the water, in screen fractions
  refractionDepth*: float32 ## metres of water at which the bending reaches full strength
  foamColor*: Vec3
  foamDistance*: float32 ## metres from the shore that foam reaches
  foamScale*: float32 ## metres across one tile of the foam's noise
  foamSpeed*: float32 ## metres per second the foam drifts toward the shore
  foamOpacity*: float32 ## 0 no foam, 1 solid foam colour
  foamSoftness*: float32 ## how soft the foam's edges are
  fadeDistance*: float32 ## metres from the shore over which the water fades in
  fadeCurve*: float32 ## 1 fades evenly; above 1 stays clear longer near the shore
  shoreHeight*: float32 ## metres above the water that still count as its shore (its banks);
                        ## higher things (canopies, roofs) seen over the water do not

const DefaultWaterParams* = WaterParams(color: vec3(0.03'f32, 0.16, 0.18), # blueish green
  colorStrength: 0.5, height: RiverSurface, reflectiveness: 0.2, fresnelStrength: 1,
  fresnelPower: 4, sheenStrength: 0.9, sheenSharpness: 24, waveHeight: 0.15,
  waveScale: 1.5, waveSpeed: 0.7, waveDrag: 0.46, waveCount: 12, rippleFade: 150,
  distortion: 0.5, glintStrength: 40, glintSharpness: 300, refraction: 0.25,
  refractionDepth: 0.12, foamColor: vec3(1'f32, 1, 1), foamDistance: 0.95,
  foamScale: 1.5, foamSpeed: 0.4, foamOpacity: 1, foamSoftness: 0.28,
  fadeDistance: 1.13, fadeCurve: 1, shoreHeight: 1)

const DefaultOceanParams* = WaterParams(color: vec3(0.03'f32, 0.152, 0.178),
  colorStrength: 0.5, height: SeaSurface, reflectiveness: 0.2, fresnelStrength: 1,
  fresnelPower: 4, sheenStrength: 0.9, sheenSharpness: 24, waveHeight: 2,
  waveScale: 2.74, waveSpeed: 0.7, waveDrag: 0.31, waveCount: 15, rippleFade: 150,
  distortion: 0.9, glintStrength: 40, glintSharpness: 2874, refraction: 0.25,
  refractionDepth: 0.12, foamColor: vec3(1'f32, 1, 1), foamDistance: 3.61,
  foamScale: 3.51, foamSpeed: 0.99, foamOpacity: 0.68, foamSoftness: 0.4,
  fadeDistance: 0.3, fadeCurve: 1.02, shoreHeight: 3.5)

var
  waterParams* = DefaultWaterParams ## the lake and river
  oceanParams* = DefaultOceanParams
  lakeLayer* = -1 ## the terrain layer index of the lake and river's water, if any
  oceanLayer* = -1 ## the terrain layer index of the ocean, if any

var
  mvp: Uniform[Mat4]
  reflectionTex: Uniform[Sampler2D]
  sceneDepthTex: Uniform[Sampler2D]
  sceneColorTex: Uniform[Sampler2D]
  foamNoise: Uniform[Sampler2D]
  inverseViewProjection: Uniform[Mat4]
  depthViewport: Uniform[Vec4] # the view's x, y, width, height as fractions of the window
  cameraPos: Uniform[Vec3] # drawWater sets it
  waterSunToward: Uniform[Vec3]
  sunColor: Uniform[Vec3]
  rippleClock: Uniform[float32] # wall-clock seconds, so ripples move even while the match is paused
  waterColor: Uniform[Vec3]
  waterLift: Uniform[float32] # metres added to the baked water mesh
  colorStrength, reflectiveness, fresnelStrength, fresnelPower: Uniform[float32]
  sheenStrength, sheenSharpness, glintStrength, glintSharpness: Uniform[float32]
  waveHeight, waveScale, waveSpeed, waveDrag, waveCount: Uniform[float32]
  rippleFade, distortion, refraction, refractionDepth: Uniform[float32]
  foamColor: Uniform[Vec3]
  foamDistance, foamScale, foamSpeed, foamOpacity, foamSoftness: Uniform[float32]
  fadeDistance, fadeCurve, shoreHeight: Uniform[float32]

proc paintbotWaterVert(gl_Position: var Vec4, vertPos: Vec3, worldPos: var Vec3,
    screenPos: var Vec4) =
  ## Lifts and projects the water mesh and hands its world and clip positions to the
  ## fragment; drawWater sets mvp.
  worldPos = vec3(vertPos.x, vertPos.y + waterLift, vertPos.z)
  gl_Position = mvp * vec4(worldPos.x, worldPos.y, worldPos.z, 1.0)
  screenPos = gl_Position

proc waveSum(position: Vec2, count, speed, drag: float32): float32 =
  ## The ripples' height at `position` (in wave units), from 0 (trough) to 1 (crest).
  var
    p = position
    angle = 0.0
    frequency = 1.0
    timeScale = 2.0
    weight = 1.0
    total = 0.0
    weights = 0.0
  let phaseShift = length(position) * 0.1 # keeps the waves from lining up everywhere
  for i in 0 ..< MaxWaves:
    if float32(i) >= count:
      break
    let
      direction = vec2(sin(angle), cos(angle))
      x = dot(direction, p) * frequency + rippleClock * speed * timeScale + phaseShift
      wave = exp(sin(x) - 1.0)
      slope = -wave * cos(x)
    p = p + direction * (slope * weight * drag)
    total = total + wave * weight
    weights = weights + weight
    weight = weight * 0.8
    frequency = frequency * 1.18
    timeScale = timeScale * 1.07
    angle = angle + 1232.399963
  result = total / weights

proc sceneHeight(uv: Vec2): float32 =
  ## The world height of the scene point seen at `uv` in the copied depth.
  let
    ndc = vec2(
      (uv.x - depthViewport.x) / depthViewport.z * 2.0 - 1.0,
      (uv.y - depthViewport.y) / depthViewport.w * 2.0 - 1.0)
    point = inverseViewProjection *
      vec4(ndc.x, ndc.y, texture(sceneDepthTex, uv).x * 2.0 - 1.0, 1.0)
  result = point.y / point.w

proc landAt(x, z, surface: float32): float32 =
  ## Whether the scene seen at world (x, surface, z) is the water's shore: just above the
  ## surface is 1 (land), anything else 0, and -1 off this view (unknown).
  let clip = mvp * vec4(x, surface, z, 1.0)
  if clip.w <= 0.0:
    return -1.0
  let uv = vec2(
    depthViewport.x + (clip.x / clip.w * 0.5 + 0.5) * depthViewport.z,
    depthViewport.y + (clip.y / clip.w * 0.5 + 0.5) * depthViewport.w)
  if uv.x < depthViewport.x or uv.y < depthViewport.y or
      uv.x >= depthViewport.x + depthViewport.z or uv.y >= depthViewport.y + depthViewport.w:
    return -1.0
  let height = sceneHeight(uv)
  if height > surface and height < surface + shoreHeight:
    return 1.0
  return 0.0

proc paintbotWaterFrag(fragColor: var Vec4, worldPos: Vec3, screenPos: Vec4) =
  ## Shows the scene behind this pixel, bent by the ripples, with the reflection, the
  ## sun's sheen and its glints over it.
  let
    ndc = vec2(screenPos.x / screenPos.w, screenPos.y / screenPos.w)
    depthUv = vec2(
      depthViewport.x + (ndc.x * 0.5 + 0.5) * depthViewport.z,
      depthViewport.y + (ndc.y * 0.5 + 0.5) * depthViewport.w)
    straightDepth = max(worldPos.y - sceneHeight(depthUv), 0.0)
    toCamera: Vec3 = normalize(cameraPos - worldPos)
    # The ripples' normal from three height samples a few centimetres apart, flattened
    # with distance so far water does not shimmer.
    e = 0.02
    xz = vec2(worldPos.x, worldPos.z)
    h = waveSum(xz / waveScale, waveCount, waveSpeed, waveDrag) * waveHeight
    hx = waveSum((xz + vec2(e, 0.0)) / waveScale, waveCount, waveSpeed, waveDrag) * waveHeight
    hz = waveSum((xz + vec2(0.0, e)) / waveScale, waveCount, waveSpeed, waveDrag) * waveHeight
    flatten = clamp(length(cameraPos - worldPos) / rippleFade, 0.0, 1.0) * 0.85
    normal: Vec3 = normalize(mix(normalize(vec3(h - hx, e, h - hz)), vec3(0.0, 1.0, 0.0),
      flatten))
    # Refraction: read the scene where the ripples push the view, more in deeper water.
    bentUv = depthUv + vec2(normal.x, normal.z) *
      (refraction * clamp(straightDepth / refractionDepth, 0.0, 1.0))
    bentHeight = sceneHeight(bentUv)
  # A push onto something in front of the water keeps the straight view.
  var seenUv = bentUv
  # A refracted ray outside an inset must not sample the main camera's pixels.
  if bentHeight > worldPos.y or bentUv.x < depthViewport.x or
      bentUv.y < depthViewport.y or bentUv.x >= depthViewport.x + depthViewport.z or
      bentUv.y >= depthViewport.y + depthViewport.w:
    seenUv = depthUv
  let
    seen: Vec3 = mix(texture(sceneColorTex, seenUv).xyz, waterColor, colorStrength)
    # The reflection pass is mirrored left to right (see reflectedCamera), so u runs
    # the other way; the ripples shift where it is read.
    reflection = texture(reflectionTex, vec2(0.5 - ndc.x * 0.5, 0.5 + ndc.y * 0.5) +
      vec2(normal.x, normal.z) * distortion).xyz
    # Schlick's Fresnel on the rippled surface: the reflectiveness looking straight down,
    # rising to 1 at grazing.
    cosTheta = clamp(dot(normal, toCamera), 0.0, 1.0)
    r = reflectiveness + (1.0 - reflectiveness) * fresnelStrength *
      pow(1.0 - cosTheta, fresnelPower)
    # The view ray mirrored off the rippled surface, against the sun direction: a broad
    # sheen and a sharp glint on each ripple facing the sun.
    mirrored: Vec3 = normal * (2.0 * dot(normal, toCamera)) - toCamera
    toSun = max(dot(mirrored, waterSunToward), 0.0)
    sheen: Vec3 = sunColor * (sheenStrength * r * pow(toSun, sheenSharpness))
    glint: Vec3 = sunColor * (glintStrength * r * pow(toSun, glintSharpness))
    # reflection * r + (the tinted, refracted scene) * (1 - r). The water draws the scene itself,
    # so it is opaque; sheen and glint can exceed 1 (the sun).
    color = seen * (1.0 - r) + reflection * r + sheen + glint
    searchRadius = min(max(foamDistance, fadeDistance), MaxShoreSearch)
  # The shore: march outward across the water's surface in every direction. Each
  # direction that reaches land pulls the direction to the shore toward it, weighted by
  # 1 / distance^2 so it turns smoothly; the nearest hit is bisected for the distance.
  var
    toShore = vec2(0.0, 0.0)
    nearestWater = 0.0
    nearestShore = searchRadius
    nearestDirection = vec2(0.0, 0.0)
  for d in 0 ..< ShoreDirections:
    let
      angle = float32(d) * (6.2831853 / float32(ShoreDirections))
      direction = vec2(cos(angle), sin(angle))
    var previous = 0.0
    for s in 1 .. ShoreSteps:
      let
        reach = searchRadius * float32(s) / float32(ShoreSteps)
        land = landAt(worldPos.x + direction.x * reach, worldPos.z + direction.y * reach,
          worldPos.y)
      if land < 0.0:
        break
      if land > 0.5:
        toShore = toShore + direction / max(reach * reach, 0.01)
        if reach < nearestShore:
          nearestShore = reach
          nearestWater = previous
          nearestDirection = direction
        break
      previous = reach
  if nearestShore < searchRadius:
    for b in 0 ..< 4:
      let middle = (nearestWater + nearestShore) * 0.5
      if landAt(worldPos.x + nearestDirection.x * middle,
          worldPos.z + nearestDirection.y * middle, worldPos.y) > 0.5:
        nearestShore = middle
      else:
        nearestWater = middle
  if length(toShore) > 0.0:
    toShore = normalize(toShore)
  let
    shoreDistance = nearestShore
    # Foam: two copies of the noise slide toward the shore, half a cycle apart, each
    # fading out as it restarts (with a fresh offset), so the motion never jumps or
    # smears; it shows above a threshold that falls to the waterline.
    nearShore = 1.0 - clamp(shoreDistance / max(foamDistance, 0.001), 0.0, 1.0)
    scale = max(foamScale, 0.01)
    cycle = rippleClock * foamSpeed / scale
    phase0 = fract(cycle)
    phase1 = fract(cycle + 0.5)
    uv0: Vec2 = (xz - toShore * (phase0 * scale)) / scale +
      vec2(0.37, 0.61) * floor(cycle)
    uv1: Vec2 = (xz - toShore * (phase1 * scale)) / scale +
      vec2(0.61, 0.37) * floor(cycle + 0.5)
    foamNoiseValue = mix(texture(foamNoise, uv0).x, texture(foamNoise, uv1).x,
      abs(phase0 - 0.5) * 2.0)
    # Away from the shore the threshold is 1, which the noise never passes.
    foam = smoothstep(1.0 - nearShore, 1.0 - nearShore + foamSoftness, foamNoiseValue) *
      foamOpacity
    # Fade: the water gives way to the scene behind it toward the shore.
    alpha = pow(clamp(shoreDistance / max(fadeDistance, 0.001), 0.0, 1.0), fadeCurve)
    straight = texture(sceneColorTex, depthUv).xyz
    # The foam rides on the water, so the fade takes both.
    shaded: Vec3 = mix(straight, mix(color, foamColor, foam), alpha)
  fragColor = vec4(shaded.x, shaded.y, shaded.z, 1.0)

let startTime = epochTime()

proc tileableNoise(size = 256): seq[uint8] =
  ## Fractal value noise that wraps at its edges: five octaves of a random lattice
  ## (8 to 128 cells across), each smoothly interpolated with wrapping, summed with
  ## halving weights and stretched to 0..255.
  var
    rng = initRand(2026)
    total = newSeq[float32](size * size)
    weight = 1'f32
    cells = 8
  for octave in 0 ..< 5:
    var lattice = newSeq[float32](cells * cells)
    for value in lattice.mitems: value = rng.rand(1.0).float32
    for y in 0 ..< size:
      for x in 0 ..< size:
        let
          fx = x.float32 * cells.float32 / size.float32
          fy = y.float32 * cells.float32 / size.float32
          x0 = fx.int mod cells
          y0 = fy.int mod cells
          x1 = (x0 + 1) mod cells
          y1 = (y0 + 1) mod cells
          tx = fx - floor(fx)
          ty = fy - floor(fy)
          sx = tx * tx * (3 - 2 * tx)
          sy = ty * ty * (3 - 2 * ty)
          top = lattice[y0 * cells + x0] * (1 - sx) + lattice[y0 * cells + x1] * sx
          bottom = lattice[y1 * cells + x0] * (1 - sx) + lattice[y1 * cells + x1] * sx
        total[y * size + x] += (top * (1 - sy) + bottom * sy) * weight
    weight *= 0.5
    cells *= 2
  let
    low = min(total)
    high = max(total)
  result = newSeq[uint8](size * size)
  for i, value in total:
    result[i] = uint8((value - low) / (high - low) * 255)

var
  reflectionFbo, reflectionColor, reflectionDepth, blankTexture: GLuint
  reflectionSize: IVec2
  depthCopyFbo, depthCopy, colorCopy, foamNoiseTexture: GLuint
  depthCopySize: IVec2

proc installPaintbotWater*() =
  ## Call before initTerrain, which compiles the water program.
  waterPremultipliedAlpha = true
  waterShaderOverride = (
    toShader(paintbotWaterVert, ShaderTarget, shaderVertex),
    toShader(paintbotWaterFrag, ShaderTarget, shaderFragment))

proc initPaintbotWater*() =
  ## Call after initTerrain: points the shader at the reflection's texture unit.
  glUseProgram(waterShaderProgram())
  glUniform1i(glGetUniformLocation(waterShaderProgram(), "reflectionTex"), ReflectionUnit)
  glUniform1i(glGetUniformLocation(waterShaderProgram(), "sceneDepthTex"), SceneDepthUnit)
  glUniform1i(glGetUniformLocation(waterShaderProgram(), "sceneColorTex"), SceneColorUnit)
  glUniform1i(glGetUniformLocation(waterShaderProgram(), "foamNoise"), FoamNoiseUnit)
  glUseProgram(0)
  glGenFramebuffers(1, depthCopyFbo.addr)
  glGenTextures(1, depthCopy.addr)
  glGenTextures(1, colorCopy.addr)
  var noise = tileableNoise()
  glGenTextures(1, foamNoiseTexture.addr)
  glBindTexture(GL_TEXTURE_2D, foamNoiseTexture)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_R8.GLint, 256, 256, 0, GL_RED, GL_UNSIGNED_BYTE,
    noise[0].addr)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glGenerateMipmap(GL_TEXTURE_2D)
  glBindTexture(GL_TEXTURE_2D, 0)
  glGenFramebuffers(1, reflectionFbo.addr)
  glGenTextures(1, reflectionColor.addr)
  glGenRenderbuffers(1, reflectionDepth.addr)
  # Bound for views without their own reflection pass (the first-person inset), which
  # draw with no reflectiveness.
  var white = [255'u8, 255, 255, 255]
  glGenTextures(1, blankTexture.addr)
  glBindTexture(GL_TEXTURE_2D, blankTexture)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, white[0].addr)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)

proc reflectedCamera*(eye: Vec3, view, projection: Mat4,
    height: float32): tuple[eye: Vec3, view, projection: Mat4] =
  ## The camera mirrored in the water plane y = height. Its projection's near plane is the
  ## water itself (Lengyel's oblique clipping), so nothing below the surface is reflected,
  ## and it flips x so the mirrored triangles keep their winding for back-face culling.
  let mirror = translate(vec3(0, height, 0)) * scale(vec3(1'f32, -1, 1)) *
    translate(vec3(0, -height, 0))
  result.eye = vec3(eye.x, 2*height-eye.y, eye.z)
  result.view = view * mirror
  let plane = transpose(inverse(result.view)) * vec4(0'f32, 1, 0, -height)
  var oblique = projection
  let q = inverse(projection) * vec4(sgn(plane.x).float32, sgn(plane.y).float32, 1, 1)
  let c = plane * (2'f32 / dot(plane, q))
  for column in 0..3: oblique[column, 2] = c[column] - oblique[column, 3]
  result.projection = scale(vec3(-1'f32, 1, 1)) * oblique

proc beginWaterReflection*(size: IVec2) =
  ## Starts rendering the reflection into its texture, at the window's size; draw the
  ## sky (see sky.nim) first.
  if size != reflectionSize:
    reflectionSize = size
    glBindTexture(GL_TEXTURE_2D, reflectionColor)
    # Half floats keep the sun brighter than white; WebGL 2 cannot render to them without
    # an extension, so the browser keeps 8 bits and a dimmer sun.
    when defined(emscripten):
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, size.x, size.y, 0, GL_RGBA,
        GL_UNSIGNED_BYTE, nil)
    else:
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F.GLint, size.x, size.y, 0, GL_RGBA,
        cGL_FLOAT, nil)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)
    glBindRenderbuffer(GL_RENDERBUFFER, reflectionDepth)
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, size.x, size.y)
    glBindRenderbuffer(GL_RENDERBUFFER, 0)
    glBindFramebuffer(GL_FRAMEBUFFER, reflectionFbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
      reflectionColor, 0)
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER,
      reflectionDepth)
    if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
      raise newException(ValueError, "Paintbot reflection framebuffer is incomplete")
  glBindFramebuffer(GL_FRAMEBUFFER, reflectionFbo)
  glViewport(0, 0, size.x, size.y)
  glClear(GL_DEPTH_BUFFER_BIT)

proc endWaterReflection*() =
  ## Returns to the window's framebuffer; the caller restores its viewport.
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc bindWaterReflection(reflected: bool) =
  ## The reflection just rendered, or plain white for a view without one.
  glActiveTexture(GLenum(GL_TEXTURE0.int + ReflectionUnit))
  glBindTexture(GL_TEXTURE_2D, if reflected: reflectionColor else: blankTexture)
  glActiveTexture(GL_TEXTURE0)

proc captureScene(size: IVec2) =
  ## Copies the window's colour and depth into colorCopy and depthCopy. The depth texture
  ## matches the window's 24-bit depth, 8-bit stencil format, which a depth blit requires.
  if size != depthCopySize:
    depthCopySize = size
    glBindTexture(GL_TEXTURE_2D, depthCopy)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8.GLint, size.x, size.y, 0,
      GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, nil)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindTexture(GL_TEXTURE_2D, colorCopy)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, size.x, size.y, 0, GL_RGBA,
      GL_UNSIGNED_BYTE, nil)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)
    glBindFramebuffer(GL_FRAMEBUFFER, depthCopyFbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
      colorCopy, 0)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D,
      depthCopy, 0)
    if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
      raise newException(ValueError, "Paintbot scene-copy framebuffer is incomplete")
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0)
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, depthCopyFbo)
  glBlitFramebuffer(0, 0, size.x, size.y, 0, 0, size.x, size.y,
    GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT, GL_NEAREST.GLenum)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc reflecting*(params: WaterParams): bool =
  ## Whether this water shows reflections, so it needs its reflection pass.
  params.reflectiveness > 0 or params.fresnelStrength > 0

proc captureWaterScene*(windowSize: IVec2) =
  ## Copies the scene the water draws over (and bends); call once per view, after the
  ## opaque scene and before drawPaintbotWater.
  captureScene(windowSize)

proc drawPaintbotWater*(params: WaterParams, surface: float32, vertices: Slice[int],
    viewProjection: Mat4, eye: Vec3, seconds: float32, windowSize: IVec2, sunColor: Color,
    viewport = ivec4(0, 0, 0, 0), reflected = false) =
  ## Draws one body of water (`vertices` of the engine's water mesh, baked at `surface`)
  ## with `params`, over the scene captured by captureWaterScene. `viewport` is the view's
  ## x, y, width, height in window pixels; zero means the window. `reflected` says the
  ## reflection texture holds this body's reflection, rendered for this view.
  if vertices.len == 0:
    return
  let rect = if viewport.z == 0: ivec4(0, 0, windowSize.x, windowSize.y) else: viewport
  glUseProgram(waterShaderProgram())
  var inverse = viewProjection.inverse
  glUniformMatrix4fv(glGetUniformLocation(waterShaderProgram(), "inverseViewProjection"),
    1, GL_FALSE, cast[ptr float32](inverse.addr))
  glUniform4f(glGetUniformLocation(waterShaderProgram(), "depthViewport"),
    rect.x / windowSize.x, rect.y / windowSize.y,
    rect.z / windowSize.x, rect.w / windowSize.y)
  let
    program = waterShaderProgram()
    sun = sunToward()
  template uniform(name: string, value: float32) =
    glUniform1f(glGetUniformLocation(program, name), value)
  glUniform3f(glGetUniformLocation(program, "waterColor"), params.color.x, params.color.y,
    params.color.z)
  glUniform3f(glGetUniformLocation(program, "sunColor"), sunColor.r, sunColor.g, sunColor.b)
  glUniform3f(glGetUniformLocation(program, "waterSunToward"), sun.x, sun.y, sun.z)
  uniform("waterLift", params.height - surface)
  # A view without its reflection pass reflects nothing at any angle.
  uniform("reflectiveness", if reflected: params.reflectiveness else: 0)
  uniform("fresnelStrength", if reflected: params.fresnelStrength else: 0)
  uniform("colorStrength", params.colorStrength)
  uniform("fresnelPower", params.fresnelPower)
  uniform("sheenStrength", params.sheenStrength)
  uniform("sheenSharpness", params.sheenSharpness)
  uniform("glintStrength", params.glintStrength)
  uniform("glintSharpness", params.glintSharpness)
  uniform("waveHeight", params.waveHeight)
  uniform("waveScale", params.waveScale)
  uniform("waveSpeed", params.waveSpeed)
  uniform("waveDrag", params.waveDrag)
  uniform("waveCount", params.waveCount)
  uniform("rippleFade", params.rippleFade)
  uniform("distortion", params.distortion)
  uniform("refraction", params.refraction)
  uniform("refractionDepth", max(params.refractionDepth, 0.001))
  glUniform3f(glGetUniformLocation(program, "foamColor"), params.foamColor.x,
    params.foamColor.y, params.foamColor.z)
  uniform("foamDistance", params.foamDistance)
  uniform("foamScale", params.foamScale)
  uniform("foamSpeed", params.foamSpeed)
  uniform("foamOpacity", params.foamOpacity)
  uniform("foamSoftness", params.foamSoftness)
  uniform("fadeDistance", params.fadeDistance)
  uniform("fadeCurve", params.fadeCurve)
  uniform("shoreHeight", params.shoreHeight)
  # Wrapped every 10,000 s to keep float32 precision; the jump is rare and brief.
  glUniform1f(glGetUniformLocation(program, "rippleClock"),
    float32((epochTime() - startTime) mod 10_000))
  glUseProgram(0)
  bindWaterReflection(reflected)
  glActiveTexture(GLenum(GL_TEXTURE0.int + SceneDepthUnit))
  glBindTexture(GL_TEXTURE_2D, depthCopy)
  glActiveTexture(GLenum(GL_TEXTURE0.int + SceneColorUnit))
  glBindTexture(GL_TEXTURE_2D, colorCopy)
  glActiveTexture(GLenum(GL_TEXTURE0.int + FoamNoiseUnit))
  glBindTexture(GL_TEXTURE_2D, foamNoiseTexture)
  glActiveTexture(GL_TEXTURE0)
  drawWater(viewProjection, eye, seconds, vertices.a, vertices.len)
