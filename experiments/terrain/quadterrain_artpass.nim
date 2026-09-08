## Painted art pass based on quadterrain_shadows.nim.
## F1 hides or restores the UI; F12 saves the current view.
## All scene textures and imported models come from Golden Valley and Meadow.
## Shadow-mapped variant of the blended quadterrain experiment: a steerable
## directional sun renders every caster (terrain, bridge, fort walls, props,
## trees) into a depth map, and the surface shaders darken the lighting
## wherever a fragment is hidden from the sun. Lighting uses the games'
## toon (cel) shading from src/polyworld/toon.nim: Lambert intensity times
## the shadow test, through the ramp, then a day-cycle palette; the games'
## gradient background replaces the void. The Shadow tab moves the sun
## (azimuth and elevation), picks the palette hour, controls shadow
## strength, softness, and bias, and toggles the sun's frustum wire box
## and a debug view of the depth map. A time-of-day clock can drive the
## whole atmosphere at once: sun path (moon at night), palette, cast-shadow
## strength, and how flat or directional the shading is.
## Textured base: instead of flat per-kind
## colors, tiles sample the two packs' painted ground materials
## from one GL texture array, height maps packed into the alpha channel.
## Each tile corner picks a material from the tiles sharing that corner (at
## matching height, so cliffs keep hard texture breaks), and the fragment
## shader blends the four corner materials. The blend is modulated by the
## material height maps: the taller detail pokes through first, so a
## grass/rock boundary breaks up into clumps and stones instead of a smooth
## crossfade. Skirts and cliff walls sample dirt/volcanic/stone materials
## with a wall-space projection.
## Terrain is drawn with plain OpenGL (shaders authored via shady), UI via silky.
## Run from the repo root: nim r experiments/terrain/quadterrain_artpass.nim

import
  std/[os, strformat, strutils, heapqueue, random],
  bumpy, vmath, chroma, noisy, shady, pixie, pixie/internal, gltf,
  silky,
  polyworld/toon

const
  GridTiles = 64
  HalfGrid = GridTiles.float32 / 2.0

## Atlas

let builder = newAtlasBuilder(1024, 4)
builder.addDir("../polyworld_data/themes/main/", "../polyworld_data/themes/main/")
builder.addFont("../polyworld_data/themes/main/IBMPlexSans-Regular.ttf", "H1", 32.0)
builder.addFont("../polyworld_data/themes/main/IBMPlexSans-Regular.ttf", "Default", 18.0)
builder.write("tmp/editor.atlas.png")

## Window

let window = newWindow(
  "Quad Terrain Art Pass",
  ivec2(1280, 800),
  msaa = msaa8x,
  vsync = false
)
makeContextCurrent(window)
loadExtensions()

let sk = newSilky(window, "tmp/editor.atlas.png")

## Terrain texture array
##
## One GL_TEXTURE_2D_ARRAY holds every ground material: rgb is the basecolor
## and alpha is the material's height map, so the blend shader gets both in
## a single sample. Layer order matches tile kinds 0..4; the trailing layers
## are skirt/cliff materials.

const TerrainMaterials = [
  "grass",       # 0: GrassTile (and TreeTile tops)
  "road",        # 1: Dirt and broken flagstones.
  "cliff",       # 2: RockTile
  "marsh",       # 3: MarshTile
  "stone",       # 4: StoneTile construction
  "dirt",        # 5: skirt under grass, road, and marsh
  "volcanic",    # 6: skirt under natural rock
  "underwater",  # 7: river and moat beds
  "dryGrass",    # 8: Worn grass patches.
  "forestFloor", # 9: Leaf litter beneath trees.
  "meadowGrass", # 10: Quiet grass between leafy patches.
]

const
  ValleyPath = "../polyworld_data/terrain/toon_golden_valley/"
  MeadowPath = "../polyworld_data/terrain/toon_enchanted_meadow/"
  TerrainSources = [
    ValleyPath & "terrain_grass_01d.png",
    MeadowPath & "terrain_dirt_01d.png",
    MeadowPath & "terrain_stone_02d.png",
    MeadowPath & "terrain_grass_01d.png",
    MeadowPath & "terrain_stone_01d.png",
    MeadowPath & "terrain_dirt_01d.png",
    ValleyPath & "terrain_stone_01d.png",
    MeadowPath & "terrain_dirt_01d.png",
    ValleyPath & "terrain_grass_02d.png",
    ValleyPath & "terrain_forest_floor_01d.png",
    MeadowPath & "terrain_grass_01d.png"
  ]
  TerrainTints = [
    vec3(1.55, 1.5, 1.5), vec3(1.8, 1.65, 1.55),
    vec3(1.3, 1.3, 1.3), vec3(1.4, 1.25, 0.75),
    vec3(1.65, 1.65, 1.65), vec3(1.8, 1.65, 1.55),
    vec3(1.4, 1.4, 1.4), vec3(1.1, 1.1, 1.1),
    vec3(1.2, 1.35, 1.0), vec3(0.9, 1.25, 1.5),
    vec3(2.0, 1.55, 0.62)
  ]
  PaintedTextures = [
    ValleyPath & "atlas_trees_1a.png",
    ValleyPath & "atlas_vegetation_1a.png",
    MeadowPath & "atlas_vegetation_1a.png",
    MeadowPath & "terrain_stone_02d.png",
    ValleyPath & "terrain_stone_01d.png"
  ]
  FoliageLayers = 3
  PaintedSize = 2048

proc mipChain(image: Image): seq[Image] =
  ## Full mip chain down to 1x1, box filtered in pixie's premultiplied space.
  result.add image
  while result[^1].width > 1:
    result.add result[^1].minifyBy2()

proc buildTextureArray(layers: seq[seq[Image]], wrap: GLint): GLuint =
  ## Uploads equally sized RGBA mip chains as one anisotropic
  ## GL_TEXTURE_2D_ARRAY, one chain per layer.
  let size = layers[0][0].width.GLsizei
  glGenTextures(1, result.addr)
  glBindTexture(GL_TEXTURE_2D_ARRAY, result)
  for level, mip in layers[0]:
    glTexImage3D(
      GL_TEXTURE_2D_ARRAY, level.GLint, GL_RGBA8.GLint,
      mip.width.GLsizei, mip.height.GLsizei,
      layers.len.GLsizei, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil
    )
  for layer, chain in layers:
    doAssert chain.len == layers[0].len
    for level, mip in chain:
      doAssert mip.width == layers[0][level].width
      glTexSubImage3D(
        GL_TEXTURE_2D_ARRAY, level.GLint, 0, 0, layer.GLint,
        mip.width.GLsizei, mip.height.GLsizei, 1,
        GL_RGBA, GL_UNSIGNED_BYTE, mip.data[0].addr
      )
  glTexParameteri(
    GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAX_LEVEL, (layers[0].len - 1).GLint)
  doAssert size > 0
  # Anisotropic filtering keeps the road and other near-horizontal surfaces
  # sharp at grazing angles instead of smearing into low mip levels.
  glTexParameterf(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAX_ANISOTROPY_EXT, 8.0)
  glTexParameteri(
    GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, wrap)
  glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, wrap)
  glBindTexture(GL_TEXTURE_2D_ARRAY, 0)

proc tintImage(image: Image, tint: Vec3) =
  ## Adjusts albedo exposure without changing source files or coverage.
  for c in image.data.mitems:
    c.r = uint8(clamp(c.r.float32 * tint.x, 0, 255))
    c.g = uint8(clamp(c.g.float32 * tint.y, 0, 255))
    c.b = uint8(clamp(c.b.float32 * tint.z, 0, 255))

proc layFlagstones(color, height, painting: Image) =
  ## Lays discrete beveled slabs over dirt with periodic jitter and missing stones.
  const Cells = 8
  let cellSize = color.width.float32 / Cells.float32
  var
    rng = initRand(607)
    centers: array[Cells * Cells, Vec2]
    tints: array[Cells * Cells, Vec3]
    present: array[Cells * Cells, bool]
  for y in 0 ..< Cells:
    for x in 0 ..< Cells:
      let
        i = y * Cells + x
        brightness = 0.84'f + rng.rand(0.3).float32
      centers[i] = vec2(
        x.float32 + 0.18'f + rng.rand(0.64).float32,
        y.float32 + 0.18'f + rng.rand(0.64).float32
      ) * cellSize
      tints[i] = vec3(165, 148, 126) * brightness
      present[i] = rng.rand(1.0) > 0.2
  for y in 0 ..< color.height:
    for x in 0 ..< color.width:
      let
        point = vec2(x.float32 + 0.5, y.float32 + 0.5)
        cellX = int(point.x / cellSize)
        cellY = int(point.y / cellSize)
      var
        best = float32.high
        second = float32.high
        nearest = 0
        firstCenter, secondCenter: Vec2
      for dy in -1 .. 1:
        for dx in -1 .. 1:
          let
            nx = cellX + dx
            ny = cellY + dy
            wrappedX = (nx + Cells) mod Cells
            wrappedY = (ny + Cells) mod Cells
            index = wrappedY * Cells + wrappedX
            candidate = centers[index] + vec2(
              (nx - wrappedX).float32, (ny - wrappedY).float32
            ) * cellSize
            distance = (candidate - point).lengthSq
          if distance < best:
            second = best
            secondCenter = firstCenter
            best = distance
            firstCenter = candidate
            nearest = index
          elif distance < second:
            second = distance
            secondCenter = candidate
      if not present[nearest]:
        continue
      let
        edge = (second - best) /
          (2 * max((secondCenter - firstCenter).length, 0.001))
        gap = cellSize * 0.06
        bevel = cellSize * 0.04
        mask = smoothstep(gap, gap + 1.0'f, edge)
        slope = 1 - smoothstep(gap, gap + bevel, edge)
        edgeNormal = normalize(firstCenter - secondCenter)
        light = dot(edgeNormal, normalize(vec2(-1, -1)))
        i = y * color.width + x
        brush = (painting.data[i].r.float32 - 95.0'f) * 0.012'f
        slab = tints[nearest] *
          (1 + brush + slope * light * 0.23'f)
        dirt = color.data[i]
        blended = vec3(dirt.r.float32, dirt.g.float32, dirt.b.float32) *
          (1 - mask) + slab * mask
        stoneHeight = uint8(64 + mask * (150 - slope * 25))
      color.data[i] = rgbx(
        uint8(clamp(blended.x, 0, 255)),
        uint8(clamp(blended.y, 0, 255)),
        uint8(clamp(blended.z, 0, 255)),
        255
      )
      height.data[i] = rgbx(stoneHeight, stoneHeight, stoneHeight, 255)

proc paintedMaterial(index: int): tuple[color, height: Image] =
  ## Derives blend relief from painted albedo, keeping dirt below grass detail.
  result.color = readImage(TerrainSources[index])
  result.height = newImage(result.color.width, result.color.height)
  var
    low = 255.0'f
    high = 0.0'f
  for c in result.color.data:
    let value = c.r.float32 * 0.3 + c.g.float32 * 0.59 + c.b.float32 * 0.11
    low = min(low, value)
    high = max(high, value)
  let span = max(high - low, 1.0'f)
  for i, c in result.color.data:
    let
      value = c.r.float32 * 0.3 + c.g.float32 * 0.59 + c.b.float32 * 0.11
      relief = (value - low) / span
      height =
        if index in [1, 5, 7]:
          uint8(45 + relief * 40)
        else:
          uint8(65 + relief * 150)
    result.height.data[i] = rgbx(height, height, height, 255)
  result.color.tintImage(TerrainTints[index])
  if index == 1:
    let stones = readImage(MeadowPath & "terrain_stone_01d.png")
    doAssert stones.width == result.color.width
    doAssert stones.height == result.color.height
    layFlagstones(result.color, result.height, stones)

proc loadTerrainMaterials(): seq[seq[Image]] =
  ## Each material's basecolor with its height map packed into alpha. The
  ## alpha isn't coverage here, so mips must not premultiply by it: build
  ## the chain from the opaque color and re-pack height per level.
  doAssert TerrainSources.len == TerrainMaterials.len
  doAssert TerrainTints.len == TerrainMaterials.len
  for index, name in TerrainMaterials:
    let
      material = paintedMaterial(index)
      colors = mipChain(material.color)
      heights = mipChain(material.height)
    doAssert heights.len == colors.len, name
    for level in 0 ..< colors.len:
      for i in 0 ..< colors[level].data.len:
        colors[level].data[i].a = heights[level].data[i].r
    result.add colors

let terrainTextureArray = buildTextureArray(loadTerrainMaterials(), GL_REPEAT)

## Tree paintings: every variant of a tree model shares its UV layout, so
## one texture array holds all of them and each planted tree picks a layer.
## Alpha is the foliage cutout.

const TreeAlphaCutoff = 0.5'f32

proc coverage(image: Image): float32 =
  ## Fraction of texels that pass the cutout test.
  var passing = 0
  for c in image.data:
    if c.a.float32 / 255 >= TreeAlphaCutoff:
      inc passing
  passing.float32 / image.data.len.float32

proc loadPaintedTextures(): seq[seq[Image]] =
  ## Preserves foliage cutouts while sharing full-resolution pack atlases.
  for layer, path in PaintedTextures:
    let
      source = readImage(path)
      square =
        if source.width == PaintedSize and source.height == PaintedSize:
          source
        else:
          source.resize(PaintedSize, PaintedSize)
      chain = mipChain(square)
      target = coverage(chain[0])
    for level, mip in chain:
      mip.data.toStraightAlpha()
      mip.tintImage(vec3(1.4, 1.4, 1.4))
      if level == 0 or layer >= FoliageLayers:
        continue
      var
        low = 1.0'f
        high = 8.0'f
      for step in 0 ..< 10:
        let middle = (low + high) / 2
        var passing = 0
        for c in mip.data:
          if min(c.a.float32 * middle / 255, 1.0) >= TreeAlphaCutoff:
            inc passing
        if passing.float32 / mip.data.len.float32 < target:
          low = middle
        else:
          high = middle
      let alphaScale = (low + high) / 2
      for c in mip.data.mitems:
        c.a = uint8(min(c.a.float32 * alphaScale, 255))
    result.add chain

let treeTextureArray = buildTextureArray(loadPaintedTextures(), GL_REPEAT)

window.runeInputEnabled = true
window.onRune = proc(rune: Rune) =
  sk.inputRunes.add(rune)

## Shaders

var
  mvp: Uniform[Mat4]
  borderWidth: Uniform[float32]
  heightScale: Uniform[float32]
  edgesEnabled: Uniform[float32]
  texScale: Uniform[float32]
  roadRepeat: Uniform[float32]
  blendDepth: Uniform[float32]
  heightBlend: Uniform[float32]
  terrainTextures: Uniform[Sampler2dArray]
  visibilityTex: Uniform[Sampler2D]
  visOffset: Uniform[float32]
  visScale: Uniform[float32]
  # Shadow mapping: the sun's view-projection, its depth map, and controls.
  # The lit shaders sample through a comparison sampler (hardware PCF, each
  # tap bilinearly filtered); the debug view reads the same texture as a
  # plain sampler with the compare mode temporarily off.
  lightMvp: Uniform[Mat4]
  shadowMap: Uniform[Sampler2D]
  shadowMapPcf: Uniform[Sampler2dShadow]
  shadowsEnabled: Uniform[float32]
  shadowStrength: Uniform[float32]
  shadowBias: Uniform[float32]
  shadowTexel: Uniform[float32]
  shadowSoftness: Uniform[float32]
  # How much directional light shapes the surface at all: 1 is full sun
  # shading, 0 is a flat overcast/night look with no lit or shadow side.
  shadingStrength: Uniform[float32]
  sunDir: Uniform[Vec3]
  # Toon banding, the technique from src/polyworld/toon.nim: Lambert
  # intensity through a ramp texture, then palette highlight/shadow colors.
  toonEnabled: Uniform[float32]
  toonRampTex: Uniform[Sampler2D]
  toonHighlight: Uniform[Vec3]
  toonShadow: Uniform[Vec3]

proc texture(buffer: Uniform[Sampler2dArray], pos: Vec3): Vec4 =
  ## CPU stub; shady passes texture() through to GLSL as a builtin.
  vec4(0, 0, 0, 0)

proc terrainSample(uv: Vec2, material: float32): Vec4 =
  ## Keeps road stones at their own scale while grass uses broader repeats.
  var sampleUv: Vec2 = uv
  if material > 0.5 and material < 1.5:
    sampleUv = uv * roadRepeat
  elif material > 8.5 and material < 9.5:
    sampleUv = uv * 2.5
  result = texture(terrainTextures, vec3(sampleUv.x, sampleUv.y, material))

proc terrainVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    edgeMask: float32,
    normal: Vec3,
    tileColor: Vec3,
    materials: Vec4,
    cornerWeight: Vec4,
    worldPos: var Vec3,
    vertEdgeMask: var float32,
    vertNormal: var Vec3,
    vertColor: var Vec3,
    vertMaterials: var Vec4,
    vertWeights: var Vec4,
    shadowCoord: var Vec4
) =
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  # Normal-offset shadows: sample the map slightly off the surface along
  # its normal, which suppresses self-shadow acne better than depth bias.
  shadowCoord = lightMvp * vec4(
    vertPos.x + normal.x * 0.08,
    vertPos.y + normal.y * 0.08,
    vertPos.z + normal.z * 0.08,
    1.0
  )
  worldPos = vertPos
  vertEdgeMask = edgeMask
  vertNormal = normal
  vertColor = tileColor
  vertMaterials = materials
  vertWeights = cornerWeight

proc terrainFrag(
    fragColor: var Vec4,
    worldPos: Vec3,
    vertEdgeMask: float32,
    vertNormal: Vec3,
    vertColor: Vec3,
    vertMaterials: Vec4,
    vertWeights: Vec4,
    shadowCoord: Vec4
) =
  let tilePos = vec2(worldPos.x, worldPos.z)
  let h = clamp(worldPos.y / max(heightScale, 0.001) * 0.5 + 0.5, 0.0, 1.0)
  # Planar projection: tops map from world xz; walls pick the vertical plane
  # facing their normal so the texture doesn't stretch down cliff faces.
  let absNormal = abs(vertNormal)
  var uv = vec2(worldPos.x, worldPos.z) * texScale
  if absNormal.y < 0.5:
    if absNormal.x > absNormal.z:
      uv = vec2(worldPos.z, -worldPos.y) * texScale
    else:
      uv = vec2(worldPos.x, -worldPos.y) * texScale
  # One material per tile corner (rgb basecolor, alpha the material's own
  # height map), bilinear corner weights interpolated across the tile.
  let
    s0 = terrainSample(uv, vertMaterials.x)
    s1 = terrainSample(uv, vertMaterials.y)
    s2 = terrainSample(uv, vertMaterials.z)
    s3 = terrainSample(uv, vertMaterials.w)
  # Height-modulated blending: each corner's weight is boosted by its
  # material height, then everything below the winner minus blendDepth is
  # cut. Tall detail (grass blades, rock slabs) pokes through the boundary
  # first, so transitions read as abrupt clumps instead of a linear fade.
  let
    b0 = vertWeights.x + s0.w * heightBlend
    b1 = vertWeights.y + s1.w * heightBlend
    b2 = vertWeights.z + s2.w * heightBlend
    b3 = vertWeights.w + s3.w * heightBlend
    cutoff = max(max(b0, b1), max(b2, b3)) - blendDepth
    w0 = max(b0 - cutoff, 0.0)
    w1 = max(b1 - cutoff, 0.0)
    w2 = max(b2 - cutoff, 0.0)
    w3 = max(b3 - cutoff, 0.0)
    blended = (s0.xyz * w0 + s1.xyz * w1 + s2.xyz * w2 + s3.xyz * w3) /
      (w0 + w1 + w2 + w3)
  # Per-kind tint (near white for textured kinds), brightened a little with
  # height. Impassable tiles keep their normal color; their blocked edges
  # show red when the edge display is on.
  var color = blended * vertColor * (0.75 + 0.5 * h)
  # Passability borders draw on upward faces only (walls sit exactly on
  # integer x/z, so the fract test would classify their every pixel as
  # border), and only while the edge display is toggled on. Each strip is
  # colored by its edge's passability: green connected, red blocked. The
  # mask packs the four edges as bits: east 1, south 2, west 4, north 8.
  if edgesEnabled > 0.5 and vertNormal.y > 0.3:
    let
      fx = tilePos.x - floor(tilePos.x)
      fy = tilePos.y - floor(tilePos.y)
      edge = min(min(fx, 1.0 - fx), min(fy, 1.0 - fy))
    if edge < borderWidth:
      var maskLeft = vertEdgeMask
      var northPass = 0.0'f32
      var westPass = 0.0'f32
      var southPass = 0.0'f32
      var eastPass = 0.0'f32
      if maskLeft >= 8.0:
        northPass = 1.0
        maskLeft = maskLeft - 8.0
      if maskLeft >= 4.0:
        westPass = 1.0
        maskLeft = maskLeft - 4.0
      if maskLeft >= 2.0:
        southPass = 1.0
        maskLeft = maskLeft - 2.0
      if maskLeft >= 1.0:
        eastPass = 1.0
      var passable = 0.0'f32
      if edge == fx:
        passable = westPass
      elif edge == 1.0 - fx:
        passable = eastPass
      elif edge == fy:
        passable = northPass
      else:
        passable = southPass
      if passable >= 0.5:
        color = vec3(0.10, 0.72, 0.22)
      else:
        color = vec3(0.88, 0.10, 0.08)
  # Shadow map test: project into the sun's depth map and take five taps
  # for a slightly soft edge. Shadow scales the directional term only, so
  # shadowed ground keeps the ambient floor.
  var shadow = 1.0'f32
  if shadowsEnabled > 0.5:
    let
      su = shadowCoord.x * 0.5 + 0.5
      sv = shadowCoord.y * 0.5 + 0.5
      sd = shadowCoord.z * 0.5 + 0.5 - shadowBias
    if su > 0.0 and su < 1.0 and sv > 0.0 and sv < 1.0 and sd < 1.0:
      # 3x3 grid of hardware-PCF taps, each bilinearly filtered by the
      # comparison sampler; spread widens the penumbra.
      let spread = shadowTexel * shadowSoftness
      var lit = 0.0'f32
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv + spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv + spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv + spread, sd))
      shadow = 1.0 - (1.0 - lit / 9.0) * shadowStrength
  if toonEnabled > 0.5:
    # Toon banding: one-light Lambert scaled by the shadow test, pushed
    # through the ramp, then the palette's highlight/shadow colors.
    # shadingStrength pulls the intensity toward full highlight, so a low
    # sun or nighttime flattens the surface instead of shading it.
    let
      lambert = max(dot(normalize(vertNormal), sunDir), 0.0) * shadow
      intensity = 1.0 - shadingStrength + lambert * shadingStrength
      band = texture(toonRampTex, vec2(intensity, 0.5)).x
    color = color * (toonShadow * (1.0 - band) + toonHighlight * band)
  else:
    # Half-lambert directional lighting: smooth vertex normals across
    # connected terrain, hard breaks at cliffs and walls. Shadow scales the
    # whole lighting term so full strength really goes to black.
    let
      light = clamp(
        dot(normalize(vertNormal), sunDir) * 0.5 + 0.5,
        0.0, 1.0)
      lighting = (0.45 + 0.7 * light) * shadow
    color = color * (1.0 - shadingStrength + lighting * shadingStrength)
  # Line-of-sight fade: terrain hidden from the start marker drains to a
  # dark monochrome. The visibility texture holds one value per tile,
  # blurred on the CPU and bilinearly sampled here, so the boundary rolls
  # off over a couple of tiles instead of snapping at tile edges.
  let
    visUv = vec2(
      (tilePos.x + visOffset) * visScale,
      (tilePos.y + visOffset) * visScale)
    vis = smoothstep(0.05, 0.95, texture(visibilityTex, visUv).x)
    gray = dot(color, vec3(0.30, 0.59, 0.11)) * 0.5
  color = color * vis + vec3(gray, gray, gray) * (1.0 - vis)
  fragColor = vec4(color.x, color.y, color.z, 1.0)

proc compileStage(kind: GLenum, source, label: string): GLuint =
  result = glCreateShader(kind)
  var sourceArray = allocCStringArray([source])
  defer: deallocCStringArray(sourceArray)
  glShaderSource(result, 1.GLsizei, sourceArray, nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    quit(label & " shader failed:\n" & log & "\nsource:\n" & source)

proc compileProgram(vertexSource, fragmentSource: string): GLuint =
  let
    vertexShader = compileStage(GL_VERTEX_SHADER, vertexSource, "terrain.vert")
    fragmentShader = compileStage(GL_FRAGMENT_SHADER, fragmentSource, "terrain.frag")
  result = glCreateProgram()
  glAttachShader(result, vertexShader)
  glAttachShader(result, fragmentShader)
  glLinkProgram(result)
  var ok: GLint
  glGetProgramiv(result, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result, length, nil, log.cstring)
    quit("terrain program failed:\n" & log)

let terrainProgram = compileProgram(
  toShader(terrainVert, glsl4Desktop, shaderVertex),
  toShader(terrainFrag, glsl4Desktop, shaderFragment)
)
let mvpLocation = glGetUniformLocation(terrainProgram, "mvp")
let borderWidthLocation = glGetUniformLocation(terrainProgram, "borderWidth")
let heightScaleLocation = glGetUniformLocation(terrainProgram, "heightScale")
let edgesEnabledLocation = glGetUniformLocation(terrainProgram, "edgesEnabled")
let texScaleLocation = glGetUniformLocation(terrainProgram, "texScale")
let roadRepeatLocation = glGetUniformLocation(terrainProgram, "roadRepeat")
let blendDepthLocation = glGetUniformLocation(terrainProgram, "blendDepth")
let heightBlendLocation = glGetUniformLocation(terrainProgram, "heightBlend")
let terrainTexturesLocation = glGetUniformLocation(terrainProgram, "terrainTextures")
let visibilityTexLocation = glGetUniformLocation(terrainProgram, "visibilityTex")
let visOffsetLocation = glGetUniformLocation(terrainProgram, "visOffset")
let visScaleLocation = glGetUniformLocation(terrainProgram, "visScale")
let terrainLightMvpLocation = glGetUniformLocation(terrainProgram, "lightMvp")
let terrainShadowMapLocation = glGetUniformLocation(terrainProgram, "shadowMapPcf")
let terrainShadowsEnabledLocation = glGetUniformLocation(terrainProgram, "shadowsEnabled")
let terrainShadowStrengthLocation = glGetUniformLocation(terrainProgram, "shadowStrength")
let terrainShadowBiasLocation = glGetUniformLocation(terrainProgram, "shadowBias")
let terrainShadowTexelLocation = glGetUniformLocation(terrainProgram, "shadowTexel")
let terrainShadowSoftnessLocation = glGetUniformLocation(terrainProgram, "shadowSoftness")
let terrainShadingStrengthLocation = glGetUniformLocation(terrainProgram, "shadingStrength")
let terrainSunDirLocation = glGetUniformLocation(terrainProgram, "sunDir")
let terrainToonEnabledLocation = glGetUniformLocation(terrainProgram, "toonEnabled")
let terrainToonRampLocation = glGetUniformLocation(terrainProgram, "toonRampTex")
let terrainToonHighlightLocation = glGetUniformLocation(terrainProgram, "toonHighlight")
let terrainToonShadowLocation = glGetUniformLocation(terrainProgram, "toonShadow")

## Solid-color shader for the start/finish spheres and the path ribbon.

var solidColor: Uniform[Vec3]

proc solidVert(gl_Position: var Vec4, vertPos: Vec3) =
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)

proc solidFrag(fragColor: var Vec4) =
  fragColor = vec4(solidColor.x, solidColor.y, solidColor.z, 1.0)

let solidProgram = compileProgram(
  toShader(solidVert, glsl4Desktop, shaderVertex),
  toShader(solidFrag, glsl4Desktop, shaderFragment)
)
let solidMvpLocation = glGetUniformLocation(solidProgram, "mvp")
let solidColorLocation = glGetUniformLocation(solidProgram, "solidColor")

## Water shader: transparent blue with a Blinn-Phong specular highlight.

var cameraPos: Uniform[Vec3]

proc waterVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    normal: Vec3,
    worldPos: var Vec3,
    waterNormal: var Vec3
) =
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  worldPos = vertPos
  waterNormal = normal

proc waterFrag(
    fragColor: var Vec4,
    worldPos: Vec3,
    waterNormal: Vec3
) =
  let specular = pow(
    max(dot(
      normalize(waterNormal),
      normalize(
        normalize(cameraPos - worldPos) + sunDir)
    ), 0.0),
    48.0)
  fragColor = vec4(
    0.13 + specular,
    0.34 + specular,
    0.58 + specular,
    clamp(0.55 + specular * 0.45, 0.0, 1.0)
  )

let waterProgram = compileProgram(
  toShader(waterVert, glsl4Desktop, shaderVertex),
  toShader(waterFrag, glsl4Desktop, shaderFragment)
)
let waterMvpLocation = glGetUniformLocation(waterProgram, "mvp")
let waterCameraLocation = glGetUniformLocation(waterProgram, "cameraPos")
let waterSunDirLocation = glGetUniformLocation(waterProgram, "sunDir")

## Painted pack models preserve their atlas detail and foliage cutouts.
## The vertex stream carries uv plus the texture array layer; the fragment
## shader discards transparent texels, lights cards from either side, and
## applies the same line-of-sight fade as the terrain.

var
  treeTextures: Uniform[Sampler2dArray]
  treeAlphaCutoff: Uniform[float32]

proc treeVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertUv: Vec3,
    normal: Vec3,
    fragUv: var Vec3,
    fragmentNormal: var Vec3,
    fragWorld: var Vec3,
    shadowCoord: var Vec4
) =
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  # Normal-offset shadows: sample the map slightly off the surface along
  # its normal, which suppresses self-shadow acne better than depth bias.
  shadowCoord = lightMvp * vec4(
    vertPos.x + normal.x * 0.08,
    vertPos.y + normal.y * 0.08,
    vertPos.z + normal.z * 0.08,
    1.0
  )
  fragUv = vertUv
  fragmentNormal = normal
  fragWorld = vertPos

proc treeFrag(
    fragColor: var Vec4,
    fragUv: Vec3,
    fragmentNormal: Vec3,
    fragWorld: Vec3,
    shadowCoord: Vec4
) =
  let texel = texture(treeTextures, fragUv)
  if texel.w < treeAlphaCutoff:
    discardFragment()
  var shadow = 1.0'f32
  if shadowsEnabled > 0.5:
    let
      su = shadowCoord.x * 0.5 + 0.5
      sv = shadowCoord.y * 0.5 + 0.5
      sd = shadowCoord.z * 0.5 + 0.5 - shadowBias
    if su > 0.0 and su < 1.0 and sv > 0.0 and sv < 1.0 and sd < 1.0:
      # 3x3 grid of hardware-PCF taps, each bilinearly filtered by the
      # comparison sampler; spread widens the penumbra.
      let spread = shadowTexel * shadowSoftness
      var lit = 0.0'f32
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv - spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv, sd))
      lit = lit + texture(shadowMapPcf, vec3(su - spread, sv + spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su, sv + spread, sd))
      lit = lit + texture(shadowMapPcf, vec3(su + spread, sv + spread, sd))
      shadow = 1.0 - (1.0 - lit / 9.0) * shadowStrength
  # Foliage cards light on both sides; opaque rocks use outward normals.
  var facing = dot(normalize(fragmentNormal), sunDir)
  if fragUv.z < FoliageLayers.float32 - 0.5:
    facing = abs(facing)
  var color = vec3(0.0, 0.0, 0.0)
  if toonEnabled > 0.5:
    let
      lambert = max(facing, 0.0) * shadow
      intensity = 1.0 - shadingStrength + lambert * shadingStrength
      band = texture(toonRampTex, vec2(intensity, 0.5)).x
    color = texel.xyz * (toonShadow * (1.0 - band) + toonHighlight * band)
  else:
    let
      light = clamp(
        facing * 0.5 + 0.5,
        0.0, 1.0)
      lighting = (0.5 + 0.65 * light) * shadow
    color = texel.xyz * (1.0 - shadingStrength + lighting * shadingStrength)
  let
    visUv = vec2(
      (fragWorld.x + visOffset) * visScale,
      (fragWorld.z + visOffset) * visScale)
    vis = smoothstep(0.05, 0.95, texture(visibilityTex, visUv).x)
    gray = dot(color, vec3(0.30, 0.59, 0.11)) * 0.5
  color = color * vis + vec3(gray, gray, gray) * (1.0 - vis)
  fragColor = vec4(color.x, color.y, color.z, 1.0)

let treeProgram = compileProgram(
  toShader(treeVert, glsl4Desktop, shaderVertex),
  toShader(treeFrag, glsl4Desktop, shaderFragment)
)
let treeMvpLocation = glGetUniformLocation(treeProgram, "mvp")
let treeTexturesLocation = glGetUniformLocation(treeProgram, "treeTextures")
let treeAlphaCutoffLocation = glGetUniformLocation(treeProgram, "treeAlphaCutoff")
let treeVisibilityTexLocation = glGetUniformLocation(treeProgram, "visibilityTex")
let treeVisOffsetLocation = glGetUniformLocation(treeProgram, "visOffset")
let treeVisScaleLocation = glGetUniformLocation(treeProgram, "visScale")
let treeLightMvpLocation = glGetUniformLocation(treeProgram, "lightMvp")
let treeShadowMapLocation = glGetUniformLocation(treeProgram, "shadowMapPcf")
let treeShadowsEnabledLocation = glGetUniformLocation(treeProgram, "shadowsEnabled")
let treeShadowStrengthLocation = glGetUniformLocation(treeProgram, "shadowStrength")
let treeShadowBiasLocation = glGetUniformLocation(treeProgram, "shadowBias")
let treeShadowTexelLocation = glGetUniformLocation(treeProgram, "shadowTexel")
let treeShadowSoftnessLocation = glGetUniformLocation(treeProgram, "shadowSoftness")
let treeShadingStrengthLocation = glGetUniformLocation(treeProgram, "shadingStrength")
let treeSunDirLocation = glGetUniformLocation(treeProgram, "sunDir")
let treeToonEnabledLocation = glGetUniformLocation(treeProgram, "toonEnabled")
let treeToonRampLocation = glGetUniformLocation(treeProgram, "toonRampTex")
let treeToonHighlightLocation = glGetUniformLocation(treeProgram, "toonHighlight")
let treeToonShadowLocation = glGetUniformLocation(treeProgram, "toonShadow")

## Shadow depth pass: everything that casts — terrain (bridge, walls, and
## overhangs included), props, and trees — rendered from the sun into a
## depth map. Trees keep their alpha cutout so foliage casts leafy shadows.

proc depthVert(gl_Position: var Vec4, vertPos: Vec3) =
  gl_Position = lightMvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)

proc depthFrag(fragColor: var Vec4) =
  fragColor = vec4(1.0, 1.0, 1.0, 1.0)

let depthProgram = compileProgram(
  toShader(depthVert, glsl4Desktop, shaderVertex),
  toShader(depthFrag, glsl4Desktop, shaderFragment)
)
let depthLightMvpLocation = glGetUniformLocation(depthProgram, "lightMvp")

proc treeDepthVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertUv: Vec3,
    fragUv: var Vec3
) =
  gl_Position = lightMvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  fragUv = vertUv

proc treeDepthFrag(fragColor: var Vec4, fragUv: Vec3) =
  let texel = texture(treeTextures, fragUv)
  if texel.w < treeAlphaCutoff:
    discardFragment()
  fragColor = vec4(1.0, 1.0, 1.0, 1.0)

let treeDepthProgram = compileProgram(
  toShader(treeDepthVert, glsl4Desktop, shaderVertex),
  toShader(treeDepthFrag, glsl4Desktop, shaderFragment)
)
let treeDepthLightMvpLocation = glGetUniformLocation(treeDepthProgram, "lightMvp")
let treeDepthTexturesLocation = glGetUniformLocation(treeDepthProgram, "treeTextures")
let treeDepthAlphaCutoffLocation = glGetUniformLocation(treeDepthProgram, "treeAlphaCutoff")

## Debug view: a screen-space quad showing the raw shadow depth map.

proc shadowViewVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertUv: Vec2,
    viewUv: var Vec2
) =
  gl_Position = vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  viewUv = vertUv

proc shadowViewFrag(fragColor: var Vec4, viewUv: Vec2) =
  let depth = texture(shadowMap, viewUv).x
  fragColor = vec4(depth, depth, depth, 1.0)

let shadowViewProgram = compileProgram(
  toShader(shadowViewVert, glsl4Desktop, shaderVertex),
  toShader(shadowViewFrag, glsl4Desktop, shaderFragment)
)
let shadowViewMapLocation = glGetUniformLocation(shadowViewProgram, "shadowMap")

type
  PaintedModel = object
    name: string
    height: float32
    weight: float32         # relative planting frequency
    vertices: seq[float32]  # x y z u v nx ny nz; pack-scaled, base at y 0
    textureLayer: int
  TreePlacement = object
    model: int
    position: Vec3
    rotation: float32
    scale: float32  # mild per-instance jitter around 1

var
  treeModels: seq[PaintedModel]
  grassModels: seq[PaintedModel]
  bushModels: seq[PaintedModel]
  rockModels: seq[PaintedModel]
  grassPlacements: seq[TreePlacement]
  rockPlacements: seq[TreePlacement]

proc collectTreeMesh(
    node: gltf.Node, parent: Mat4,
    points: var seq[Vec3], uvs: var seq[Vec2], normals: var seq[Vec3],
    textureLayer: int
) =
  ## Flattens a glb node tree into world-space triangle soup keeping UVs.
  let world = parent * (translate(node.pos) * node.rot.mat4 * scale(node.scale))
  if node.mesh != nil:
    let normalMatrix = world.inverse.transpose
    for primitive in node.mesh.primitives:
      doAssert primitive.material != nil
      doAssert primitive.material.baseColor != nil
      doAssert primitive.material.baseColorName ==
        PaintedTextures[textureLayer].extractFilename.changeFileExt(""),
        "Unexpected atlas on " & node.name
      doAssert primitive.uvs.len == primitive.points.len
      doAssert primitive.normals.len == primitive.points.len
      template addCorner(index: int) =
        points.add world * primitive.points[index]
        uvs.add primitive.uvs[index]
        let transformed = normalMatrix * vec4(
          primitive.normals[index].x, primitive.normals[index].y,
          primitive.normals[index].z, 0)
        normals.add normalize(vec3(transformed.x, transformed.y, transformed.z))
      if primitive.indices32.len > 0:
        for index in primitive.indices32:
          addCorner(index.int)
      else:
        for index in primitive.indices16:
          addCorner(index.int)
  for child in node.nodes:
    collectTreeMesh(child, world, points, uvs, normals, textureLayer)

proc loadPaintedModel(
    node: gltf.Node, parent: Mat4, textureLayer: int
): PaintedModel =
  ## Flattens textured geometry and centers its base without losing UVs.
  var
    points: seq[Vec3]
    uvs: seq[Vec2]
    normals: seq[Vec3]
  collectTreeMesh(node, parent, points, uvs, normals, textureLayer)
  doAssert points.len > 0, node.name
  var
    low = vec3(float32.high, float32.high, float32.high)
    high = vec3(float32.low, float32.low, float32.low)
  for point in points:
    low = min(low, point)
    high = max(high, point)
  let center = (low + high) / 2
  result = PaintedModel(
    name: node.name, height: high.y - low.y, weight: 1,
    textureLayer: textureLayer)
  for i, point in points:
    let p = point - vec3(center.x, low.y, center.z)
    result.vertices.add p.x
    result.vertices.add p.y
    result.vertices.add p.z
    result.vertices.add uvs[i].x
    result.vertices.add uvs[i].y
    result.vertices.add normals[i].x
    result.vertices.add normals[i].y
    result.vertices.add normals[i].z

proc collectPaintedModels(
    node: gltf.Node, parent: Mat4, textureLayer: int,
    names: openArray[string], models: var seq[PaintedModel],
    unitHeight = false
) =
  ## Selects models from a pack, preserving their UVs and authored proportions.
  if node.name in names:
    var model = loadPaintedModel(node, parent, textureLayer)
    if unitHeight:
      let factor = 1.0'f / max(model.height, 0.001)
      for i in countup(0, model.vertices.len - 8, 8):
        model.vertices[i] *= factor
        model.vertices[i + 1] *= factor
        model.vertices[i + 2] *= factor
      model.height = 1
    models.add model
    return
  let world = parent *
    (translate(node.pos) * node.rot.mat4 * scale(node.scale))
  for child in node.nodes:
    collectPaintedModels(
      child, world, textureLayer, names, models, unitHeight)

proc pickTreeModel(rng: var Rand): int =
  ## Weighted choice over the tree models.
  var total = 0.0'f32
  for model in treeModels:
    total += model.weight
  var roll = rng.rand(total.float)
  for i, model in treeModels:
    roll -= model.weight
    if roll <= 0:
      return i
  treeModels.high

proc scaleTrees(models: var seq[PaintedModel], targetTallest: float32) =
  ## Scales the whole tree pack by one factor so relative sizes hold.
  var tallest = 0.001'f32
  for model in models:
    tallest = max(tallest, model.height)
  let packScale = targetTallest / tallest
  for model in models.mitems:
    model.height *= packScale
    var i = 0
    while i < model.vertices.len:
      model.vertices[i] *= packScale
      model.vertices[i + 1] *= packScale
      model.vertices[i + 2] *= packScale
      i += 8

block:
  let
    valley = readGltfFile(ValleyPath & "vegetation.glb").root
    meadow = readGltfFile(MeadowPath & "vegetation.glb").root
  collectPaintedModels(
    valley, mat4(), 0,
    ["beech_tree_04a", "beech_tree_05a"], treeModels)
  collectPaintedModels(
    meadow, mat4(), 2, ["tree_05a"], treeModels)
  collectPaintedModels(
    valley, mat4(), 1,
    ["grass_patch_01a", "grass_patch_02a", "flowers_patch_02a"],
    grassModels)
  collectPaintedModels(
    meadow, mat4(), 2,
    ["grass_patch_03a", "grass_patch_05a", "flowers_patch_01a",
      "flowers_patch_03a"],
    grassModels)
  collectPaintedModels(valley, mat4(), 1, ["bush_01a"], bushModels)
  collectPaintedModels(meadow, mat4(), 2, ["bush_02a"], bushModels)
collectPaintedModels(
  readGltfFile(MeadowPath & "rocks.glb").root,
  mat4(),
  3,
  ["rock_large_02a", "rock_medium_01a"],
  rockModels,
  unitHeight = true
)
collectPaintedModels(
  readGltfFile(ValleyPath & "rocks.glb").root,
  mat4(),
  4,
  ["rock_large_02a", "rock_medium_01a"],
  rockModels,
  unitHeight = true
)
doAssert treeModels.len == 3
doAssert grassModels.len == 7
doAssert bushModels.len == 2
doAssert rockModels.len == 4

treeModels.scaleTrees(8.4)
grassModels.scaleTrees(0.55)
bushModels.scaleTrees(0.85)

## Terrain parameters (UI-driven)

var
  frequency = 0.115'f32
  amplitude = 2.91'f32
  octaves = 4
  gain = 0.5'f32
  lacunarity = 2.0'f32
  seed = 1988
  fortEnabled = true
  wallHeight = 2.3'f32
  grassCount = 220
  bridgeEnabled = true
  waterEnabled = true
  treesEnabled = true
  grassEnabled = true
  rocksEnabled = true
  rockCount = 30
  slopeLimit = 60.0'f32  # degrees; steeper top tiles are marked impassable
  losEnabled = true      # fade terrain hidden from the start marker to gray
  treeDensity = 0.9'f32       # chance of a tree at the forest map's peak
  treeHeight = 3.8'f          # Full crowns close the forest at tile scale.
  forestSharpness = 1.0'f32   # noise exponent; higher hollows out the fringe
  # The forest map is its own noise population, independent of the terrain.
  forestSeed = 4242
  forestFrequency = 0.05'f32  # lower is bigger woods
  forestOctaves = 2           # more octaves, raggeder forest lines
  forestGain = 0.5'f32
  forestLacunarity = 2.0'f32
borderWidth = 0.05
var textureSize = 10.0'f32  # world tiles one texture repeat spans
var roadSize = 5.0'f
blendDepth = 0.12    # blend band width; smaller is more abrupt
heightBlend = 1.2    # how strongly material height maps steer the blend
shadowStrength = 0.75  # how dark shadows get; 1 goes to pure black
shadowBias = 0.0012    # depth offset that hides self-shadow acne
shadowSoftness = 1.5   # PCF spread in shadow-map texels
shadingStrength = 1.0  # 1 full directional shading, 0 flat
var surfaceNoise = initSimplex(3881)
surfaceNoise.frequency = 0.045
surfaceNoise.octaves = 2
surfaceNoise.gain = 0.5
surfaceNoise.lacunarity = 2

## Quad layers

const HeightSteps = 8.0'f32  # heights quantize to 1/8 of a tile

proc pack(values: array[4, float32]): array[4, int16] =
  for i in 0 .. 3:
    result[i] = int16(round(values[i] * HeightSteps))

proc unpack(steps: array[4, int16]): array[4, float32] =
  for i in 0 .. 3:
    result[i] = steps[i].float32 / HeightSteps

const
  TileExists = 1'u32
  TileConnectedEast = 2'u32   # edge to (x+1, z); clear means a break
  TileConnectedSouth = 4'u32  # edge to (x, z+1)
  TileImpassable = 8'u32      # forced, e.g. ground squeezed under a bridge

  GrassTile = 0'u32
  RoadTile = 1'u32   # also the fort interior
  RockTile = 2'u32   # natural rocky ground; boulders scatter here
  MarshTile = 3'u32
  StoneTile = 4'u32  # stone construction (bridge, fort walls); no boulders
  TreeTile = 5'u32     # renders like grass; the tile itself carries a tree
  RiverbedTile = 6'u32 # bed beneath standing water, e.g. the moat floor

type TileStyle = object
  topMaterial: float32    # texture array layer for the top surface
  skirtMaterial: float32  # texture array layer for side walls and undersides
  skirtTint: Vec3         # darkens walls a little; tops are untinted so the
                          # smooth material blend never shows tile squares

# Tile style index: texture array layers per tile kind. Materials reference
# the TerrainMaterials order.
const TileStyleTable = [
  TileStyle(topMaterial: 0, skirtMaterial: 5, skirtTint: vec3(0.85, 0.85, 0.85)),  # grass over dirt
  TileStyle(
    topMaterial: 1,
    skirtMaterial: 5,
    skirtTint: vec3(0.85, 0.85, 0.85)
  ),  # Road and fort over dirt.
  TileStyle(
    topMaterial: 2,
    skirtMaterial: 6,
    skirtTint: vec3(0.9, 0.9, 0.9)
  ),  # Meadow tops, Valley rock sides.
  TileStyle(topMaterial: 3, skirtMaterial: 5, skirtTint: vec3(0.8, 0.8, 0.75)),    # marsh over dirt
  TileStyle(topMaterial: 4, skirtMaterial: 4, skirtTint: vec3(0.9, 0.9, 0.9)),     # stone throughout
  TileStyle(topMaterial: 0, skirtMaterial: 5, skirtTint: vec3(0.85, 0.85, 0.85)),  # tree tile, grass look
  TileStyle(
    topMaterial: 7,
    skirtMaterial: 5,
    skirtTint: vec3(0.85, 0.85, 0.85)
  ),  # Submerged dirt.
]

const TopTint = vec3(1, 1, 1)

# Blending priority per tile kind: the material a corner shows is the
# highest-priority kind among the tiles sharing that corner at the same
# height. Deliberate features (stone, roads) must win their corners, or a
# one-tile-wide road would average away under the surrounding grass.
# Priorities must be distinct: corner scans init to each tile's own kind, so
# a tie would resolve differently per tile and produce blend seams.
const KindPriority = [1, 5, 4, 2, 6, 0, 3]
  # grass, road, rock, marsh, stone, tree, riverbed

proc styleOf(kind: uint32): TileStyle =
  TileStyleTable[min(kind, TileStyleTable.high.uint32).int]

type
  Tile = object
    ## 24 bytes: corner heights in 1/8-tile integer steps, flag bits, and a
    ## game-specific tile kind (0 grass, 1 road, ...).
    tops: array[4, int16]     # top corners: [x0z0, x1z0, x0z1, x1z1]
    bottoms: array[4, int16]  # underside corners; only used by slab layers
    flags: uint32
    kind: uint32

  QuadLayer = object
    originX, originZ: int  # placement in world tile coordinates
    width, depth: int
    slab: bool   # slab layers close their sides and underside down to
                 # bottoms; the ground layer instead skirts to the floor
    water: bool  # flat transparent surface; never walkable, never connects
                 # to other layers, and renders in its own blended pass
    tiles: seq[Tile]

proc setFlag(tile: var Tile, flag: uint32, on: bool) =
  if on:
    tile.flags = tile.flags or flag
  else:
    tile.flags = tile.flags and not flag

proc exists(tile: Tile): bool = (tile.flags and TileExists) != 0
proc `exists=`(tile: var Tile, on: bool) = tile.setFlag(TileExists, on)
proc connectedEast(tile: Tile): bool = (tile.flags and TileConnectedEast) != 0
proc connectedSouth(tile: Tile): bool = (tile.flags and TileConnectedSouth) != 0
proc impassable(tile: Tile): bool = (tile.flags and TileImpassable) != 0
proc `impassable=`(tile: var Tile, on: bool) = tile.setFlag(TileImpassable, on)

var layers: seq[QuadLayer]

proc generateLayers() =
  var simplex = initSimplex(seed)
  simplex.frequency = frequency
  simplex.octaves = octaves
  simplex.gain = gain
  simplex.lacunarity = lacunarity

  const c = GridTiles div 2

  proc ground(cx, cz: int): float32 =
    simplex.value(cx.float32, cz.float32) * amplitude

  let plateau = ground(c, c)

  proc corner(cx, cz: int): float32 =
    ## Corner height as a pure function of the corner coordinate: tiles that
    ## share a corner always agree, so the surface has no accidental walls.
    result = ground(cx, cz)
    # A shallow river valley winds across the whole map and passes under the
    # bridge crest, leaving a clear walkable path beneath the deck.
    let
      riverCenter = 13.0'f32 + 1.5'f32 * sin((cz.float32 - 16.0'f32) * 0.25'f32)
      riverDist = abs(cx.float32 - riverCenter)
      riverBlend = clamp(1.0'f32 - (riverDist / 3.0'f32) * (riverDist / 3.0'f32), 0, 1)
    result -= 2.0'f32 * riverBlend
    if fortEnabled and cz >= c + 6:
      # The road runs south from the gate at plateau height and blends the
      # surrounding hills toward it, so everything connects with no gaps.
      let
        d = abs(cx.float32 - c.float32 - 0.5)
        w = clamp(1.0'f32 - (d - 1.5'f32) / 3.5'f32, 0, 1)
        smooth = w * w * (3.0'f32 - 2.0'f32 * w)
      result = result * (1 - smooth) + plateau * smooth

  var groundLayer = QuadLayer(
    originX: 0, originZ: 0,
    width: GridTiles, depth: GridTiles,
    slab: false,
    tiles: newSeq[Tile](GridTiles * GridTiles)
  )
  template gtile(x, z: int): var Tile = groundLayer.tiles[(z) * GridTiles + (x)]

  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        tops = [corner(x, z), corner(x + 1, z), corner(x, z + 1), corner(x + 1, z + 1)]
        average = (tops[0] + tops[1] + tops[2] + tops[3]) / 4
        # Rocky peaks up high, marsh in the low wet ground near the river.
        kind =
          if average > amplitude * 0.18: RockTile
          elif average < -amplitude * 0.5: MarshTile
          else: GrassTile
      gtile(x, z) = Tile(
        flags: TileExists or TileConnectedEast or TileConnectedSouth,
        kind: kind,
        tops: pack(tops)
      )

  if fortEnabled:
    let wallTop = plateau + wallHeight
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let
          r = max(abs(x - c), abs(z - c))
          gateColumn = x >= c - 1 and x <= c + 1 and z > c
        if r <= 8:
          # The fort interior is sand colored, same as the road.
          gtile(x, z).tops = pack([plateau, plateau, plateau, plateau])
          gtile(x, z).kind = RoadTile
        if gateColumn and z >= c + 6:
          gtile(x, z).kind = RoadTile
        if (r == 7 or r == 8) and not gateColumn:
          # Moat: a two-tile trench carved below the plateau, with a pale
          # sandy bed. The water layer floats above it.
          let moatFloor = plateau - 2.0'f32
          gtile(x, z).tops = pack([moatFloor, moatFloor, moatFloor, moatFloor])
          gtile(x, z).kind = RiverbedTile
        if r == 6 and not gateColumn:
          # Stone fort walls.
          gtile(x, z).tops = pack([wallTop, wallTop, wallTop, wallTop])
          gtile(x, z).kind = StoneTile
        if r <= 1:
          let keepTop = plateau + wallHeight * 1.6'f32
          gtile(x, z).tops = pack([keepTop, keepTop, keepTop, keepTop])

    # Ramp hugging the inside of the north wall: rises east over four tiles
    # from the courtyard up to wall-top height, then a flat landing whose
    # edges meet the north and east wall tops exactly, making the wall walkable.
    const RampLength = 4
    proc rampHeight(cx: int): float32 =
      let t = clamp((cx - (c + 1)).float32 / RampLength.float32, 0, 1)
      plateau + (wallTop - plateau) * t
    for x in c + 1 .. c + 5:
      gtile(x, c - 5).tops = pack([
        rampHeight(x), rampHeight(x + 1),
        rampHeight(x), rampHeight(x + 1)
      ])

  # Bridge: a second, smaller slab layer. It carries both top and bottom
  # heights, leaves the ground below intact, and only marks the ground tiles
  # it actually touches as impassable.
  const
    BridgeOriginX = 7
    BridgeOriginZ = 14
    BridgeLength = 12  # tiles along x
    BridgeSpan = 4     # tiles along z
    BridgeThickness = 1.0'f32
    BridgeArch = 2.5'f32
  var bridge = QuadLayer(
    originX: BridgeOriginX, originZ: BridgeOriginZ,
    width: BridgeLength, depth: BridgeSpan,
    slab: true,
    tiles: newSeq[Tile](BridgeLength * BridgeSpan)
  )
  let
    centerCz = BridgeOriginZ + BridgeSpan div 2
    startHeight = corner(BridgeOriginX, centerCz)
    endHeight = corner(BridgeOriginX + BridgeLength, centerCz)
  proc bridgeTop(cx, cz: int): float32 =
    ## Arch profile that lands exactly on the ground corners at both ends,
    ## connecting the bridge deck seamlessly to the terrain mesh.
    let
      t = (cx - BridgeOriginX).float32 / BridgeLength.float32
      arch = startHeight * (1 - t) + endHeight * t +
        BridgeArch * 4.0'f32 * t * (1 - t)
      endWeight = clamp(1.0'f32 - min(t, 1 - t) * 6.0'f32, 0, 1)
    arch * (1 - endWeight) + corner(cx, cz) * endWeight
  for z in 0 ..< BridgeSpan:
    for x in 0 ..< BridgeLength:
      let
        cx = BridgeOriginX + x
        cz = BridgeOriginZ + z
        tops = [bridgeTop(cx, cz), bridgeTop(cx + 1, cz),
                bridgeTop(cx, cz + 1), bridgeTop(cx + 1, cz + 1)]
      var bottoms: array[4, float32]
      for i in 0 .. 3:
        bottoms[i] = tops[i] - BridgeThickness
      bridge.tiles[z * BridgeLength + x] = Tile(
        flags: TileExists or TileConnectedEast or TileConnectedSouth,
        kind: StoneTile,  # a stone bridge
        tops: pack(tops),
        bottoms: pack(bottoms)
      )

  # Where the bridge touches (or digs into) the ground, the ground below
  # becomes impassable; elsewhere you can walk under the arch.
  for z in 0 ..< BridgeSpan:
    for x in 0 ..< BridgeLength:
      let bridgeBottoms = bridge.tiles[z * BridgeLength + x].bottoms.unpack
      if gtile(BridgeOriginX + x, BridgeOriginZ + z).exists:
        let groundTops = gtile(BridgeOriginX + x, BridgeOriginZ + z).tops.unpack
        var groundMax = groundTops[0]
        var bottomMin = bridgeBottoms[0]
        for i in 1 .. 3:
          groundMax = max(groundMax, groundTops[i])
          bottomMin = min(bottomMin, bridgeBottoms[i])
        if bottomMin <= groundMax + 0.15:
          gtile(BridgeOriginX + x, BridgeOriginZ + z).impassable = true

  # Mark tree tiles on open grass. The tile itself carries the tree: it
  # renders like grass, is impassable, and the tree mesh derives from the
  # tile data during mesh building. Trees grow in forests: a second,
  # low-frequency noise field is the forest map. Where it is negative no
  # tree grows at all; where positive, each grass tile sprouts a tree with
  # probability treeDensity * noise^forestSharpness, so woods thicken toward
  # the field's peaks and thin out to a natural forest line at zero.
  if treeModels.len > 0 and treesEnabled:
    var forest = initSimplex(forestSeed)
    forest.frequency = forestFrequency
    forest.octaves = forestOctaves
    forest.gain = forestGain
    forest.lacunarity = forestLacunarity
    var rng = initRand(seed * 7919 + 1)
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        if not gtile(x, z).exists or gtile(x, z).impassable or
            gtile(x, z).kind != GrassTile:
          continue
        if fortEnabled and max(abs(x - c), abs(z - c)) <= 9:
          continue
        if x >= BridgeOriginX - 1 and x <= BridgeOriginX + BridgeLength and
            z >= BridgeOriginZ - 1 and z <= BridgeOriginZ + BridgeSpan:
          continue
        let n = forest.value(x.float32, z.float32)  # roughly -1 .. 1
        # Draw the random number unconditionally so the forest shape only
        # changes with the forest sliders, not the tree pattern.
        let roll = rng.rand(1.0).float32
        if n <= 0:
          continue
        if roll > treeDensity * pow(min(n, 1.0'f32), forestSharpness):
          continue
        gtile(x, z).kind = TreeTile
        gtile(x, z).impassable = true

  # Grass puffs: walkable decoration scattered on plain grass tiles only,
  # jittered inside the tile so they don't look planted on a grid.
  grassPlacements.setLen(0)
  if grassModels.len > 0 and grassEnabled:
    var grassRng = initRand(seed * 31337 + 7)
    var attempts = 0
    var placed = 0
    while placed < grassCount and attempts < grassCount * 20:
      inc attempts
      let
        x = grassRng.rand(GridTiles - 1)
        z = grassRng.rand(GridTiles - 1)
      if not gtile(x, z).exists or gtile(x, z).impassable or
          gtile(x, z).kind != GrassTile:
        continue
      let
        h = gtile(x, z).tops.unpack
        offsetX = 0.15'f32 + grassRng.rand(0.7).float32
        offsetZ = 0.15'f32 + grassRng.rand(0.7).float32
        height = (h[0] * (1 - offsetX) + h[1] * offsetX) * (1 - offsetZ) +
          (h[2] * (1 - offsetX) + h[3] * offsetX) * offsetZ
      grassPlacements.add TreePlacement(
        model: grassRng.rand(grassModels.len - 1),
        position: vec3(
          x.float32 - HalfGrid + offsetX,
          height,
          z.float32 - HalfGrid + offsetZ
        ),
        rotation: grassRng.rand(2.0 * PI).float32,
        scale: 0.7'f32 + grassRng.rand(0.7).float32
      )
      inc placed

  # Painted rocks are 25% smaller and buried another 25% of their scaled
  # height on rocky peaks. They block the tile they sit on.
  rockPlacements.setLen(0)
  if rockModels.len > 0 and rocksEnabled:
    var rockRng = initRand(seed * 104729 + 3)
    var attempts = 0
    while rockPlacements.len < rockCount and attempts < rockCount * 40:
      inc attempts
      let
        x = rockRng.rand(GridTiles - 1)
        z = rockRng.rand(GridTiles - 1)
      if not gtile(x, z).exists or gtile(x, z).impassable or
          gtile(x, z).kind != RockTile:
        continue  # natural rock only; StoneTile construction gets none
      gtile(x, z).impassable = true
      let
        h = gtile(x, z).tops.unpack
        model = rockRng.rand(rockModels.len - 1)
        boulderScale = (1.1'f + rockRng.rand(1.1).float32) * 0.75'f
      rockPlacements.add TreePlacement(
        model: model,
        position: vec3(
          x.float32 - HalfGrid + 0.5,
          (h[0] + h[1] + h[2] + h[3]) / 4.0 -
            rockModels[model].height * boulderScale * 0.43'f,
          z.float32 - HalfGrid + 0.5
        ),
        rotation: rockRng.rand(2.0 * PI).float32,
        scale: boulderScale
      )

  # Water: a third quad layer, a flat transparent ring filling the moat.
  # It never connects to the ground tiles; it just sits at its own level.
  var water = QuadLayer(
    originX: c - 8, originZ: c - 8,
    width: 17, depth: 17,
    slab: true,
    water: true,
    tiles: newSeq[Tile](17 * 17)
  )
  if fortEnabled:
    let waterTop = plateau - 0.6'f32
    for z in 0 ..< water.depth:
      for x in 0 ..< water.width:
        let
          worldX = water.originX + x
          worldZ = water.originZ + z
          r = max(abs(worldX - c), abs(worldZ - c))
          gateColumn = worldX >= c - 1 and worldX <= c + 1 and worldZ > c
        if (r == 7 or r == 8) and not gateColumn:
          water.tiles[z * water.width + x] = Tile(
            flags: TileExists,
            tops: pack([waterTop, waterTop, waterTop, waterTop]),
            bottoms: pack([waterTop - 0.4'f32, waterTop - 0.4'f32,
                           waterTop - 0.4'f32, waterTop - 0.4'f32])
          )

  layers = @[groundLayer]
  if bridgeEnabled:
    layers.add bridge
  if waterEnabled:
    layers.add water

## Mesh

var
  vertexArray, vertexBuffer: GLuint
  mesh: seq[float32]
  meshVertexCount = 0
  treeVertexArray, treeVertexBuffer: GLuint
  treeMesh: seq[float32]   # x y z u v layer nx ny nz; textured trees
  waterVertexArray, waterVertexBuffer: GLuint
  waterMesh: seq[float32]  # x y z nx ny nz

proc bakeTree(
    model: PaintedModel, position: Vec3,
    rotation, instanceScale: float32
) =
  ## Bakes a textured tree or rock into the shared painted geometry stream.
  let
    rotationMatrix = rotateY(rotation)
    transform = translate(position) * rotationMatrix *
      scale(vec3(instanceScale, instanceScale, instanceScale))
  var i = 0
  while i < model.vertices.len:
    let
      point = transform * vec3(
        model.vertices[i], model.vertices[i + 1], model.vertices[i + 2])
      normal = rotationMatrix * vec3(
        model.vertices[i + 5], model.vertices[i + 6], model.vertices[i + 7])
    treeMesh.add point.x
    treeMesh.add point.y
    treeMesh.add point.z
    treeMesh.add model.vertices[i + 3]
    treeMesh.add model.vertices[i + 4]
    treeMesh.add model.textureLayer.float32
    treeMesh.add normal.x
    treeMesh.add normal.y
    treeMesh.add normal.z
    i += 8

proc bakeTreeTiles() =
  ## Tree tiles carry their tree in the tile data: which model, painting,
  ## rotation, and size all derive deterministically from the tile
  ## coordinates. Full broadleaf crowns and undergrowth close the forest edge.
  if treeModels.len == 0 or layers.len == 0:
    return
  let ground = layers[0]
  for z in 0 ..< ground.depth:
    for x in 0 ..< ground.width:
      let t = ground.tiles[z * ground.width + x]
      if not t.exists or t.kind != TreeTile:
        continue
      var rng = initRand(x * 73856093 + z * 19349663 + seed * 83492791 + 1)
      let
        h = t.tops.unpack
        model = pickTreeModel(rng)
        rotation = rng.rand(2.0 * PI).float32
        treeScale = (0.85'f32 + rng.rand(0.45).float32) * treeHeight / 8.4'f32
        position = vec3(
          x.float32 - HalfGrid + 0.5,
          (h[0] + h[1] + h[2] + h[3]) / 4.0,
          z.float32 - HalfGrid + 0.5
        )
      bakeTree(
        treeModels[model],
        position,
        rotation,
        treeScale
      )
      if bushModels.len > 0 and rng.rand(1.0) < 0.85:
        bakeTree(
          bushModels[rng.rand(bushModels.high)],
          position + vec3(0.15, -0.06, 0.12),
          rotation + 1.7,
          (0.8'f + rng.rand(0.4).float32) * treeHeight / 3.8'f
        )

proc rebuildTreeMesh() =
  ## Bakes every imported scene model with full textures and alpha cutouts.
  if treeVertexBuffer == 0:
    return  # buffers not created yet during the initial rebuild
  treeMesh.setLen(0)
  bakeTreeTiles()
  for placement in grassPlacements:
    bakeTree(
      grassModels[placement.model],
      placement.position,
      placement.rotation,
      placement.scale
    )
  for placement in rockPlacements:
    let model = rockModels[placement.model]
    bakeTree(
      model,
      placement.position,
      placement.rotation,
      placement.scale
    )
  if treeMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, treeVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      treeMesh.len * sizeof(float32),
      treeMesh[0].addr,
      GL_STATIC_DRAW
    )
let cornerWeights = [
  vec4(1, 0, 0, 0), vec4(0, 1, 0, 0), vec4(0, 0, 1, 0), vec4(0, 0, 0, 1)
]

proc addTriangle(
    a, b, c, normalA, normalB, normalC, tint: Vec3,
    materials: Vec4,
    weightA, weightB, weightC: Vec4,
    edgeMask = 0.0'f32
) =
  for (v, n, w) in [
    (a, normalA, weightA), (b, normalB, weightB), (c, normalC, weightC)
  ]:
    mesh.add v.x
    mesh.add v.y
    mesh.add v.z
    mesh.add edgeMask
    mesh.add n.x
    mesh.add n.y
    mesh.add n.z
    mesh.add tint.x
    mesh.add tint.y
    mesh.add tint.z
    mesh.add materials.x
    mesh.add materials.y
    mesh.add materials.z
    mesh.add materials.w
    mesh.add w.x
    mesh.add w.y
    mesh.add w.z
    mesh.add w.w

proc addWall(top0, top1, bottom0, bottom1, normal, tint: Vec3, material: float32) =
  ## Connects two edges; degenerates to a single triangle when a corner
  ## pair coincides (a partial "connection"). Walls take the owning tile's
  ## skirt material (no blending) and are flat-shaded by their face normal.
  let
    materials = vec4(material, material, material, material)
    weight = cornerWeights[0]
  addTriangle(
    top0, top1, bottom0, normal, normal, normal, tint,
    materials, weight, weight, weight)
  addTriangle(
    top1, bottom1, bottom0, normal, normal, normal, tint,
    materials, weight, weight, weight)

proc faceNormal(h: array[4, float32]): Vec3 =
  ## Gradient normal of one tile's bilinear top surface (unit tile size).
  let
    slopeX = ((h[1] + h[3]) - (h[0] + h[2])) * 0.5
    slopeZ = ((h[2] + h[3]) - (h[0] + h[1])) * 0.5
  normalize(vec3(-slopeX, 1, -slopeZ))

proc cornerNormal(
    layer: QuadLayer, faceNormals: seq[Vec3], x, z, cornerIndex: int
): Vec3 =
  ## Averages the face normals of the tiles sharing this corner, but only
  ## those whose corner height matches exactly — smooth shading across
  ## continuous terrain, hard breaks at cliffs and disconnections.
  let
    cornerX = x + (cornerIndex and 1)
    cornerZ = z + (cornerIndex shr 1)
    myHeight = layer.tiles[z * layer.width + x].tops[cornerIndex]
  var total: Vec3
  for (tileX, tileZ, corner) in [
    (cornerX - 1, cornerZ - 1, 3), (cornerX, cornerZ - 1, 2),
    (cornerX - 1, cornerZ, 1), (cornerX, cornerZ, 0)
  ]:
    if tileX < 0 or tileX >= layer.width or tileZ < 0 or tileZ >= layer.depth:
      continue
    let i = tileZ * layer.width + tileX
    if not layer.tiles[i].exists or layer.tiles[i].tops[corner] != myHeight:
      continue
    total = total + faceNormals[i]
  if total.length < 0.001:
    vec3(0, 1, 0)
  else:
    total.normalize

proc cornerMaterial(layer: QuadLayer, x, z, cornerIndex: int): float32 =
  ## Chooses the highest-priority surface at a shared corner, then its painting.
  ## Shared corners agree; cliffs keep separate materials at different heights.
  let
    cornerX = x + (cornerIndex and 1)
    cornerZ = z + (cornerIndex shr 1)
    myHeight = layer.tiles[z * layer.width + x].tops[cornerIndex]
  var
    best = layer.tiles[z * layer.width + x].kind
    treeCorners = 0
  for (tileX, tileZ, corner) in [
    (cornerX - 1, cornerZ - 1, 3), (cornerX, cornerZ - 1, 2),
    (cornerX - 1, cornerZ, 1), (cornerX, cornerZ, 0)
  ]:
    if tileX < 0 or tileX >= layer.width or tileZ < 0 or tileZ >= layer.depth:
      continue
    let i = tileZ * layer.width + tileX
    if not layer.tiles[i].exists or layer.tiles[i].tops[corner] != myHeight:
      continue
    let kind = layer.tiles[i].kind
    if kind == TreeTile:
      inc treeCorners
    if KindPriority[min(kind, KindPriority.high.uint32).int] >
        KindPriority[min(best, KindPriority.high.uint32).int]:
      best = kind
  if best in [GrassTile, TreeTile]:
    # Shared world coordinates give adjacent quads the same material choice.
    # Appearance varies independently of the tile's movement and blocking flags.
    let patch = surfaceNoise.value(
      (layer.originX + cornerX).float32,
      (layer.originZ + cornerZ).float32
    )
    if treeCorners >= 2 or (treeCorners > 0 and patch < 0.3):
      return 9
    if patch > 0.4:
      return 8
    if patch < -0.16:
      return 10
  result = styleOf(best).topMaterial

proc isSteep(a, b, c: Vec3, cosLimit: float32): bool =
  ## True when the triangle's surface is steeper than the slope limit.
  let normal = cross(b - a, c - a)
  let length = normal.length
  length > 0 and abs(normal.y) / length < cosLimit

var layerWalkable: seq[seq[bool]]  # parallel to layers; filled per rebuild

proc computeWalkable(layer: QuadLayer, cosLimit: float32): seq[bool] =
  ## A tile is walkable when it exists, isn't force-marked impassable, and
  ## neither of its top triangles exceeds the slope limit.
  result = newSeq[bool](layer.tiles.len)
  if layer.water:
    return  # water is never walkable and never links to other layers
  for i, t in layer.tiles:
    if not t.exists or t.impassable:
      continue
    let h = t.tops.unpack
    let steep = isSteep(
        vec3(0, h[0], 0), vec3(1, h[1], 0), vec3(0, h[2], 1), cosLimit) or
      isSteep(
        vec3(1, h[1], 0), vec3(1, h[3], 1), vec3(0, h[2], 1), cosLimit)
    result[i] = not steep

type EdgeLink = object
  open: bool
  layer, x, z: int  # target tile when open

proc edgeLink(layerIndex, x, z, direction: int): EdgeLink =
  ## The walkable connection across one edge of a tile: to the in-layer
  ## neighbor when it is walkable, connected, and matches both corner heights
  ## exactly, otherwise to a matching walkable tile in another layer (e.g. a
  ## bridge deck landing on the ground). Directions: 0 east, 1 south,
  ## 2 west, 3 north. Used by both the border shader mask and A*.
  let
    layer = layers[layerIndex]
    h = layer.tiles[z * layer.width + x].tops
  var
    myA, myB: int16
    indexA, indexB, dx, dz: int
  case direction
  of 0: myA = h[1]; myB = h[3]; indexA = 0; indexB = 2; dx = 1
  of 1: myA = h[2]; myB = h[3]; indexA = 0; indexB = 1; dz = 1
  of 2: myA = h[0]; myB = h[2]; indexA = 1; indexB = 3; dx = -1
  else: myA = h[0]; myB = h[1]; indexA = 2; indexB = 3; dz = -1

  let
    nx = x + dx
    nz = z + dz
  if nx >= 0 and nx < layer.width and nz >= 0 and nz < layer.depth:
    let
      i = z * layer.width + x
      ni = nz * layer.width + nx
      connected = case direction
        of 0: layer.tiles[i].connectedEast
        of 1: layer.tiles[i].connectedSouth
        of 2: layer.tiles[ni].connectedEast
        else: layer.tiles[ni].connectedSouth
    if layerWalkable[layerIndex][ni] and connected and
        myA == layer.tiles[ni].tops[indexA] and
        myB == layer.tiles[ni].tops[indexB]:
      return EdgeLink(open: true, layer: layerIndex, x: nx, z: nz)

  let
    worldX = layer.originX + x + dx
    worldZ = layer.originZ + z + dz
  for li in 0 ..< layers.len:
    if li == layerIndex:
      continue
    let
      other = layers[li]
      lx = worldX - other.originX
      lz = worldZ - other.originZ
    if lx < 0 or lx >= other.width or lz < 0 or lz >= other.depth:
      continue
    let i = lz * other.width + lx
    if layerWalkable[li][i] and
        myA == other.tiles[i].tops[indexA] and
        myB == other.tiles[i].tops[indexB]:
      return EdgeLink(open: true, layer: li, x: lx, z: lz)
  EdgeLink(open: false)

proc emitLayer(layerIndex: int, layer: QuadLayer, floorY: float32) =
  let w = layer.width
  var faceNormals = newSeq[Vec3](layer.tiles.len)
  for i, t in layer.tiles:
    if t.exists:
      faceNormals[i] = faceNormal(t.tops.unpack)
  for z in 0 ..< layer.depth:
    for x in 0 ..< w:
      let
        i = z * w + x
        t = layer.tiles[i]
      if not t.exists:
        continue
      let
        x0 = (layer.originX + x).float32 - HalfGrid
        x1 = x0 + 1
        z0 = (layer.originZ + z).float32 - HalfGrid
        z1 = z0 + 1
        h = t.tops.unpack
        b = t.bottoms.unpack
        v00 = vec3(x0, h[0], z0)
        v10 = vec3(x1, h[1], z0)
        v01 = vec3(x0, h[2], z1)
        v11 = vec3(x1, h[3], z1)
        tileWalkable = layerWalkable[layerIndex][i]

      # Edge passability mask for the border shader: an edge is connected
      # (green) when its neighbor — in this layer or another one — is
      # walkable, connected, and matches both corner heights exactly.
      # Bits: east 1, south 2, west 4, north 8.
      var edgeMask = 0.0'f32
      if tileWalkable:
        for direction in 0 .. 3:
          if edgeLink(layerIndex, x, z, direction).open:
            edgeMask += float32(1 shl direction)

      let
        style = styleOf(t.kind)
        materials = vec4(
          cornerMaterial(layer, x, z, 0), cornerMaterial(layer, x, z, 1),
          cornerMaterial(layer, x, z, 2), cornerMaterial(layer, x, z, 3))
        n0 = cornerNormal(layer, faceNormals, x, z, 0)
        n1 = cornerNormal(layer, faceNormals, x, z, 1)
        n2 = cornerNormal(layer, faceNormals, x, z, 2)
        n3 = cornerNormal(layer, faceNormals, x, z, 3)
      addTriangle(
        v00, v10, v01, n0, n1, n2, TopTint, materials,
        cornerWeights[0], cornerWeights[1], cornerWeights[2], edgeMask)
      addTriangle(
        v10, v11, v01, n1, n3, n2, TopTint, materials,
        cornerWeights[1], cornerWeights[3], cornerWeights[2], edgeMask)

      if layer.slab:
        # Underside of the slab; never walkable.
        let
          down = vec3(0, -1, 0)
          skirtMaterials = vec4(
            style.skirtMaterial, style.skirtMaterial,
            style.skirtMaterial, style.skirtMaterial)
        addTriangle(
          vec3(x0, b[0], z0), vec3(x1, b[1], z0), vec3(x0, b[2], z1),
          down, down, down, style.skirtTint, skirtMaterials,
          cornerWeights[0], cornerWeights[0], cornerWeights[0])
        addTriangle(
          vec3(x1, b[1], z0), vec3(x1, b[3], z1), vec3(x0, b[2], z1),
          down, down, down, style.skirtTint, skirtMaterials,
          cornerWeights[0], cornerWeights[0], cornerWeights[0])

      # East edge: side wall when open, connecting wall when heights differ.
      # Mismatch walls are emitted from the east/south side only, so each
      # shared edge produces exactly one wall.
      if x == w - 1 or not layer.tiles[z * w + x + 1].exists or not t.connectedEast:
        let
          y0 = if layer.slab: b[1] else: floorY
          y1 = if layer.slab: b[3] else: floorY
        addWall(
          v10, v11, vec3(x1, y0, z0), vec3(x1, y1, z1), vec3(1, 0, 0),
          style.skirtTint, style.skirtMaterial)
      else:
        let n = layer.tiles[z * w + x + 1]
        let nh = n.tops.unpack
        if h[1] != nh[0] or h[3] != nh[2]:
          # The cliff face belongs to the higher side; use its skirt style.
          let cliffStyle =
            if h[1] + h[3] >= nh[0] + nh[2]: style
            else: styleOf(n.kind)
          addWall(
            v10, v11, vec3(x1, nh[0], z0), vec3(x1, nh[2], z1), vec3(1, 0, 0),
            cliffStyle.skirtTint, cliffStyle.skirtMaterial)
        if layer.slab:
          let nb = n.bottoms.unpack
          if b[1] != nb[0] or b[3] != nb[2]:
            addWall(
              vec3(x1, b[1], z0), vec3(x1, b[3], z1),
              vec3(x1, nb[0], z0), vec3(x1, nb[2], z1), vec3(1, 0, 0),
              style.skirtTint, style.skirtMaterial)

      # South edge.
      if z == layer.depth - 1 or not layer.tiles[(z + 1) * w + x].exists or not t.connectedSouth:
        let
          y0 = if layer.slab: b[2] else: floorY
          y1 = if layer.slab: b[3] else: floorY
        addWall(
          v01, v11, vec3(x0, y0, z1), vec3(x1, y1, z1), vec3(0, 0, 1),
          style.skirtTint, style.skirtMaterial)
      else:
        let n = layer.tiles[(z + 1) * w + x]
        let nh = n.tops.unpack
        if h[2] != nh[0] or h[3] != nh[1]:
          let cliffStyle =
            if h[2] + h[3] >= nh[0] + nh[1]: style
            else: styleOf(n.kind)
          addWall(
            v01, v11, vec3(x0, nh[0], z1), vec3(x1, nh[1], z1), vec3(0, 0, 1),
            cliffStyle.skirtTint, cliffStyle.skirtMaterial)
        if layer.slab:
          let nb = n.bottoms.unpack
          if b[2] != nb[0] or b[3] != nb[1]:
            addWall(
              vec3(x0, b[2], z1), vec3(x1, b[3], z1),
              vec3(x0, nb[0], z1), vec3(x1, nb[1], z1), vec3(0, 0, 1),
              style.skirtTint, style.skirtMaterial)

      # West and north edges only need side walls when open (the neighbor,
      # if present and connected, already emitted any mismatch wall).
      if x == 0 or not layer.tiles[z * w + x - 1].exists or
          not layer.tiles[z * w + x - 1].connectedEast:
        let
          y0 = if layer.slab: b[0] else: floorY
          y1 = if layer.slab: b[2] else: floorY
        addWall(
          v00, v01, vec3(x0, y0, z0), vec3(x0, y1, z1), vec3(-1, 0, 0),
          style.skirtTint, style.skirtMaterial)
      if z == 0 or not layer.tiles[(z - 1) * w + x].exists or
          not layer.tiles[(z - 1) * w + x].connectedSouth:
        let
          y0 = if layer.slab: b[0] else: floorY
          y1 = if layer.slab: b[1] else: floorY
        addWall(
          v00, v10, vec3(x0, y0, z0), vec3(x1, y1, z0), vec3(0, 0, -1),
          style.skirtTint, style.skirtMaterial)

proc emitWaterLayer(layer: QuadLayer) =
  ## Flat water surface plus side faces where the water ends; drawn in its
  ## own transparent pass, so it goes to a separate mesh.
  proc addWaterTriangle(a, b, c, normal: Vec3) =
    for v in [a, b, c]:
      waterMesh.add v.x
      waterMesh.add v.y
      waterMesh.add v.z
      waterMesh.add normal.x
      waterMesh.add normal.y
      waterMesh.add normal.z
  let w = layer.width
  for z in 0 ..< layer.depth:
    for x in 0 ..< w:
      let t = layer.tiles[z * w + x]
      if not t.exists:
        continue
      # Boundary side faces sit inset from the tile edge: terrain walls live
      # exactly on integer x/z planes, and a coplanar transparent quad
      # z-fights them (stippled dark patches). The top face stays full size,
      # so the sliver above the inset face is still covered from above.
      const Inset = 0.01'f32
      let
        x0 = (layer.originX + x).float32 - HalfGrid
        x1 = x0 + 1
        z0 = (layer.originZ + z).float32 - HalfGrid
        z1 = z0 + 1
        xi0 = x0 + Inset
        xi1 = x1 - Inset
        zi0 = z0 + Inset
        zi1 = z1 - Inset
        top = t.tops.unpack[0]
        bottom = t.bottoms.unpack[0]
        up = vec3(0, 1, 0)
      addWaterTriangle(vec3(x0, top, z0), vec3(x1, top, z0), vec3(x0, top, z1), up)
      addWaterTriangle(vec3(x1, top, z0), vec3(x1, top, z1), vec3(x0, top, z1), up)
      # Side faces on water boundaries.
      if x == w - 1 or not layer.tiles[z * w + x + 1].exists:
        addWaterTriangle(vec3(xi1, top, z0), vec3(xi1, top, z1), vec3(xi1, bottom, z0), vec3(1, 0, 0))
        addWaterTriangle(vec3(xi1, top, z1), vec3(xi1, bottom, z1), vec3(xi1, bottom, z0), vec3(1, 0, 0))
      if x == 0 or not layer.tiles[z * w + x - 1].exists:
        addWaterTriangle(vec3(xi0, top, z0), vec3(xi0, top, z1), vec3(xi0, bottom, z0), vec3(-1, 0, 0))
        addWaterTriangle(vec3(xi0, top, z1), vec3(xi0, bottom, z1), vec3(xi0, bottom, z0), vec3(-1, 0, 0))
      if z == layer.depth - 1 or not layer.tiles[(z + 1) * w + x].exists:
        addWaterTriangle(vec3(x0, top, zi1), vec3(x1, top, zi1), vec3(x0, bottom, zi1), vec3(0, 0, 1))
        addWaterTriangle(vec3(x1, top, zi1), vec3(x1, bottom, zi1), vec3(x0, bottom, zi1), vec3(0, 0, 1))
      if z == 0 or not layer.tiles[(z - 1) * w + x].exists:
        addWaterTriangle(vec3(x0, top, zi0), vec3(x1, top, zi0), vec3(x0, bottom, zi0), vec3(0, 0, -1))
        addWaterTriangle(vec3(x1, top, zi0), vec3(x1, bottom, zi0), vec3(x0, bottom, zi0), vec3(0, 0, -1))

proc rebuildTerrain() =
  generateLayers()
  mesh.setLen(0)
  waterMesh.setLen(0)
  let
    floorY = -amplitude - 6
    cosLimit = cos(slopeLimit * PI.float32 / 180.0)
  layerWalkable.setLen(0)
  for layer in layers:
    layerWalkable.add computeWalkable(layer, cosLimit)
  for i in 0 ..< layers.len:
    if layers[i].water:
      emitWaterLayer(layers[i])
    else:
      emitLayer(i, layers[i], floorY)
  rebuildTreeMesh()
  if waterVertexBuffer != 0 and waterMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, waterVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      waterMesh.len * sizeof(float32),
      waterMesh[0].addr,
      GL_DYNAMIC_DRAW
    )

  meshVertexCount = mesh.len div 18
  glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    mesh.len * sizeof(float32),
    mesh[0].addr,
    GL_DYNAMIC_DRAW
  )

glGenVertexArrays(1, vertexArray.addr)
glBindVertexArray(vertexArray)
glGenBuffers(1, vertexBuffer.addr)
rebuildTerrain()

block:
  const stride = (18 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(terrainProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let edgeMaskLocation = glGetAttribLocation(terrainProgram, "edgeMask")
  doAssert edgeMaskLocation >= 0
  glEnableVertexAttribArray(edgeMaskLocation.GLuint)
  glVertexAttribPointer(
    edgeMaskLocation.GLuint, 1, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )
  let normalLocation = glGetAttribLocation(terrainProgram, "normal")
  doAssert normalLocation >= 0
  glEnableVertexAttribArray(normalLocation.GLuint)
  glVertexAttribPointer(
    normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](4 * sizeof(float32))
  )
  let tileColorLocation = glGetAttribLocation(terrainProgram, "tileColor")
  doAssert tileColorLocation >= 0
  glEnableVertexAttribArray(tileColorLocation.GLuint)
  glVertexAttribPointer(
    tileColorLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](7 * sizeof(float32))
  )
  let materialsLocation = glGetAttribLocation(terrainProgram, "materials")
  doAssert materialsLocation >= 0
  glEnableVertexAttribArray(materialsLocation.GLuint)
  glVertexAttribPointer(
    materialsLocation.GLuint, 4, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](10 * sizeof(float32))
  )
  let cornerWeightLocation = glGetAttribLocation(terrainProgram, "cornerWeight")
  doAssert cornerWeightLocation >= 0
  glEnableVertexAttribArray(cornerWeightLocation.GLuint)
  glVertexAttribPointer(
    cornerWeightLocation.GLuint, 4, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](14 * sizeof(float32))
  )

## Sphere and path geometry, drawn with the solid shader.

proc bindSolidPosition() =
  let location = glGetAttribLocation(solidProgram, "vertPos")
  doAssert location >= 0
  glEnableVertexAttribArray(location.GLuint)
  glVertexAttribPointer(location.GLuint, 3, cGL_FLOAT, GL_FALSE, 0, nil)

var sphereMesh: seq[float32]
block:
  const
    Stacks = 10
    Slices = 16
  proc spherePoint(stack, slice: int): Vec3 =
    let
      phi = PI.float32 * stack.float32 / Stacks.float32
      theta = 2.0'f32 * PI.float32 * slice.float32 / Slices.float32
    vec3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
  for stack in 0 ..< Stacks:
    for slice in 0 ..< Slices:
      let
        a = spherePoint(stack, slice)
        b = spherePoint(stack + 1, slice)
        c = spherePoint(stack, slice + 1)
        d = spherePoint(stack + 1, slice + 1)
      for v in [a, b, c, c, b, d]:
        sphereMesh.add v.x
        sphereMesh.add v.y
        sphereMesh.add v.z

var sphereVertexArray, sphereVertexBuffer: GLuint
glGenVertexArrays(1, sphereVertexArray.addr)
glBindVertexArray(sphereVertexArray)
glGenBuffers(1, sphereVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, sphereVertexBuffer)
glBufferData(
  GL_ARRAY_BUFFER,
  sphereMesh.len * sizeof(float32),
  sphereMesh[0].addr,
  GL_STATIC_DRAW
)
bindSolidPosition()

var
  pathVertexArray, pathVertexBuffer: GLuint
  pathMesh: seq[float32]
glGenVertexArrays(1, pathVertexArray.addr)
glBindVertexArray(pathVertexArray)
glGenBuffers(1, pathVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, pathVertexBuffer)
bindSolidPosition()

glGenVertexArrays(1, treeVertexArray.addr)
glBindVertexArray(treeVertexArray)
glGenBuffers(1, treeVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, treeVertexBuffer)
block:
  const stride = (9 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(treeProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let uvLocation = glGetAttribLocation(treeProgram, "vertUv")
  doAssert uvLocation >= 0
  glEnableVertexAttribArray(uvLocation.GLuint)
  glVertexAttribPointer(
    uvLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )
  let normalLocation = glGetAttribLocation(treeProgram, "normal")
  doAssert normalLocation >= 0
  glEnableVertexAttribArray(normalLocation.GLuint)
  glVertexAttribPointer(
    normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](6 * sizeof(float32))
  )
glGenVertexArrays(1, waterVertexArray.addr)
glBindVertexArray(waterVertexArray)
glGenBuffers(1, waterVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, waterVertexBuffer)
block:
  const stride = (6 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(waterProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let normalLocation = glGetAttribLocation(waterProgram, "normal")
  doAssert normalLocation >= 0
  glEnableVertexAttribArray(normalLocation.GLuint)
  glVertexAttribPointer(
    normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )
glBindVertexArray(0)
rebuildTreeMesh()
if waterMesh.len > 0:
  glBindBuffer(GL_ARRAY_BUFFER, waterVertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    waterMesh.len * sizeof(float32),
    waterMesh[0].addr,
    GL_DYNAMIC_DRAW
  )

## Shadow map

const ShadowMapSize = 4096

# Steerable sun: azimuth swings the shadow direction around the map,
# elevation is the time of day. Defaults match the old fixed light
# direction (0.45, 0.8, 0.4). The orthographic box always covers the whole
# grid plus the tallest features.
var
  sunAzimuth = 325.0'f    # Cross-light the road and forest edge.
  sunElevation = 50.0'f
  frustumMesh: seq[float32]
  frustumVertexArray, frustumVertexBuffer: GLuint

proc updateSun() =
  ## Recomputes the sun direction (shared by all lighting shaders), the
  ## light's view-projection, and the frustum wire box.
  const
    LightRadius = 52.0'f32
    LightDistance = 90.0'f32
  let
    azimuth = sunAzimuth * PI.float32 / 180.0
    elevation = sunElevation * PI.float32 / 180.0
  sunDir = vec3(
    cos(elevation) * sin(azimuth),
    sin(elevation),
    cos(elevation) * cos(azimuth)
  )
  let
    view = lookAt(sunDir * LightDistance, vec3(0, 0, 0), vec3(0, 1, 0))
    proj = ortho(
      -LightRadius, LightRadius, -LightRadius, LightRadius,
      LightDistance - LightRadius, LightDistance + LightRadius)
  lightMvp = proj * view
  # The frustum's ortho box corners come from unprojecting the NDC cube
  # through the inverse light matrix.
  frustumMesh.setLen(0)
  let invLight = inverse(lightMvp)
  var corners: array[8, Vec3]
  for i in 0 ..< 8:
    let p = invLight * vec4(
      if (i and 1) != 0: 1.0 else: -1.0,
      if (i and 2) != 0: 1.0 else: -1.0,
      if (i and 4) != 0: 1.0 else: -1.0,
      1.0
    )
    corners[i] = vec3(p.x, p.y, p.z) / p.w
  for (a, b) in [(0, 1), (2, 3), (4, 5), (6, 7),
                 (0, 2), (1, 3), (4, 6), (5, 7),
                 (0, 4), (1, 5), (2, 6), (3, 7)]:
    for corner in [corners[a], corners[b]]:
      frustumMesh.add corner.x
      frustumMesh.add corner.y
      frustumMesh.add corner.z
  if frustumVertexBuffer != 0:
    glBindBuffer(GL_ARRAY_BUFFER, frustumVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      frustumMesh.len * sizeof(float32),
      frustumMesh[0].addr,
      GL_DYNAMIC_DRAW
    )

updateSun()
shadowTexel = 1.0'f32 / ShadowMapSize.float32

var shadowTexture, shadowFramebuffer: GLuint
glGenTextures(1, shadowTexture.addr)
glBindTexture(GL_TEXTURE_2D, shadowTexture)
glTexImage2D(
  GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24.GLint,
  ShadowMapSize, ShadowMapSize, 0,
  GL_DEPTH_COMPONENT, cGL_FLOAT, nil
)
# Linear + compare mode turns each sampler2DShadow tap into a bilinearly
# filtered comparison (hardware PCF). The debug view flips the compare
# mode off for its plain reads and restores it.
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
glTexParameteri(
  GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_FUNC, GL_LEQUAL.GLint)
glBindTexture(GL_TEXTURE_2D, 0)
glGenFramebuffers(1, shadowFramebuffer.addr)
glBindFramebuffer(GL_FRAMEBUFFER, shadowFramebuffer)
glFramebufferTexture2D(
  GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, shadowTexture, 0)
glDrawBuffer(GL_NONE)
glReadBuffer(GL_NONE)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
glBindFramebuffer(GL_FRAMEBUFFER, 0)

# Depth-pass vertex arrays: the same vertex buffers, but only the position
# attribute (plus uv and layer for the tree cutout).
var terrainDepthVertexArray: GLuint
glGenVertexArrays(1, terrainDepthVertexArray.addr)
glBindVertexArray(terrainDepthVertexArray)
glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer)
block:
  const stride = (18 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(depthProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
var treeDepthVertexArray: GLuint
glGenVertexArrays(1, treeDepthVertexArray.addr)
glBindVertexArray(treeDepthVertexArray)
glBindBuffer(GL_ARRAY_BUFFER, treeVertexBuffer)
block:
  const stride = (9 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(treeDepthProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let uvLocation = glGetAttribLocation(treeDepthProgram, "vertUv")
  doAssert uvLocation >= 0
  glEnableVertexAttribArray(uvLocation.GLuint)
  glVertexAttribPointer(
    uvLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )

# The sun's frustum wire box, refilled by updateSun() whenever the sun moves.
glGenVertexArrays(1, frustumVertexArray.addr)
glBindVertexArray(frustumVertexArray)
glGenBuffers(1, frustumVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, frustumVertexBuffer)
glBufferData(
  GL_ARRAY_BUFFER,
  frustumMesh.len * sizeof(float32),
  frustumMesh[0].addr,
  GL_DYNAMIC_DRAW
)
bindSolidPosition()

# Debug quad for the shadow map view; positions rebuilt per frame in NDC so
# the view stays square in pixels.
var shadowViewVertexArray, shadowViewVertexBuffer: GLuint
glGenVertexArrays(1, shadowViewVertexArray.addr)
glBindVertexArray(shadowViewVertexArray)
glGenBuffers(1, shadowViewVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, shadowViewVertexBuffer)
block:
  const stride = (5 * sizeof(float32)).GLsizei
  let positionLocation = glGetAttribLocation(shadowViewProgram, "vertPos")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  let uvLocation = glGetAttribLocation(shadowViewProgram, "vertUv")
  doAssert uvLocation >= 0
  glEnableVertexAttribArray(uvLocation.GLuint)
  glVertexAttribPointer(
    uvLocation.GLuint, 2, cGL_FLOAT, GL_FALSE, stride,
    cast[pointer](3 * sizeof(float32))
  )
glBindVertexArray(0)

## Toon shading: the games' ramp and palettes (src/polyworld/toon.nim),
## plus their gradient background so the map doesn't float in a void.

var toonRampTexture: GLuint
glGenTextures(1, toonRampTexture.addr)
block:
  let ramp = rampImage()
  glBindTexture(GL_TEXTURE_2D, toonRampTexture)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA.GLint, ramp.width.GLint, ramp.height.GLint,
    0, GL_RGBA, GL_UNSIGNED_BYTE, ramp.data[0].addr
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)

let toonBackgroundProgram =
  compileProgram(ToonBackgroundVertSrc, ToonBackgroundFragSrc)
let toonSkyLocation =
  glGetUniformLocation(toonBackgroundProgram, "toonSkyColor")
let toonHorizonLocation =
  glGetUniformLocation(toonBackgroundProgram, "toonHorizonColor")
let toonGroundLocation =
  glGetUniformLocation(toonBackgroundProgram, "toonGroundColor")
let toonHorizonHeightLocation =
  glGetUniformLocation(toonBackgroundProgram, "toonHorizonHeight")
var toonBackgroundVertexArray, toonBackgroundVertexBuffer: GLuint
glGenVertexArrays(1, toonBackgroundVertexArray.addr)
glBindVertexArray(toonBackgroundVertexArray)
glGenBuffers(1, toonBackgroundVertexBuffer.addr)
glBindBuffer(GL_ARRAY_BUFFER, toonBackgroundVertexBuffer)
block:
  # One triangle covering clip space; the vertex shader reads only xy.
  var corners = [vec3(-1, -1, 0), vec3(3, -1, 0), vec3(-1, 3, 0)]
  glBufferData(
    GL_ARRAY_BUFFER, corners.len * sizeof(Vec3), corners[0].addr,
    GL_STATIC_DRAW
  )
  let positionLocation =
    glGetAttribLocation(toonBackgroundProgram, "vertexPosition")
  doAssert positionLocation >= 0
  glEnableVertexAttribArray(positionLocation.GLuint)
  glVertexAttribPointer(positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, 0, nil)
glBindVertexArray(0)

## Camera

var
  cameraYaw = 0.7'f32
  cameraPitch = 0.82'f
  cameraDistance = 28.0'f
  cameraTarget = vec3(0.5, 0, 17)
  rotating = false
  panning = false
  showPanel = true
  showEdges = false
  showShadows = true
  showLightFrustum = false
  showShadowMap = false
  showToon = true
  toonHour = 12.0'f32  # picks the palette from the games' day cycle
  cameraEye = vec3(0, 0, 0)

## Atmosphere: one clock that drives everything. With the tie enabled, the
## hour positions the sun (or the moon at night), picks the toon palette,
## and scales both cast shadows and directional shading, so noon is crisp,
## twilight goes soft, and night is nearly flat moonlight.

var
  timeOfDay = 12.0'f32
  tieToTime = false

proc applyTimeOfDay() =
  ## Sun 6:00-20:00 arcing east to west; the moon rides the same track
  ## through the night, low and dim. sunUp is 0 at night, 1 at noon.
  let hour = ((timeOfDay mod 24) + 24) mod 24
  var sunUp = 0.0'f32
  if hour >= 6 and hour <= 20:
    let t = (hour - 6) / 14
    sunUp = sin(t * PI.float32)
    sunAzimuth = 90 + t * 180
    sunElevation = max(sunUp * 70, 12)
  else:
    let sinceSunset = if hour > 20: hour - 20 else: hour + 4
    let t = sinceSunset / 10
    sunAzimuth = 90 + t * 180
    sunElevation = max(sin(t * PI.float32) * 45, 12)
  toonHour = timeOfDay
  # One strength for both cast shadows and directional shading: they fade
  # out together through twilight to faint flat moonlight. Two separate
  # curves made the shading pop visibly right at sunset.
  let strength = 0.15'f32 + 0.7'f32 * smoothstep(0.0'f32, 0.3'f32, sunUp)
  shadowStrength = strength
  shadingStrength = strength

proc mouseOverUi(): bool =
  ## Hidden controls never intercept camera input.
  if not showPanel:
    return false
  for state in subWindowStates.values:
    if state.visible and sk.mousePos.overlaps(rect(state.pos, state.size)):
      return true
  false

proc cameraMvp(): Mat4 =
  let
    eyeOffset = vec3(
      sin(cameraYaw) * cos(cameraPitch),
      sin(cameraPitch),
      cos(cameraYaw) * cos(cameraPitch)
    ) * cameraDistance
    view = lookAt(cameraTarget + eyeOffset, cameraTarget, vec3(0, 1, 0))
    aspect = window.size.x.float32 / max(window.size.y.float32, 1)
    proj = perspective(45.0'f32, aspect, 0.1'f32, 1000.0'f32)
  cameraEye = cameraTarget + eyeOffset
  proj * view

## Pathfinding

type
  PlaceMode = enum
    NoPlacement, PlacingStart, PlacingFinish
  DragTarget = enum
    NoDrag, DragStart, DragFinish

var
  placeMode = NoPlacement
  dragTarget = NoDrag
  hasStart = false
  hasFinish = false
  startLayer, startX, startZ: int
  finishLayer, finishX, finishZ: int
  pathPoints: seq[Vec3]
  pathStatus = "Use the buttons to place points."

proc tileCenter(layerIndex, x, z: int): Vec3 =
  let
    layer = layers[layerIndex]
    h = layer.tiles[z * layer.width + x].tops.unpack
  vec3(
    (layer.originX + x).float32 - HalfGrid + 0.5,
    (h[0] + h[1] + h[2] + h[3]) / 4.0,
    (layer.originZ + z).float32 - HalfGrid + 0.5
  )

proc rayTriangle(origin, dir, a, b, c: Vec3): float32 =
  ## Ray-triangle intersection distance, or -1 when there is no hit.
  let
    edge1 = b - a
    edge2 = c - a
    p = cross(dir, edge2)
    det = dot(edge1, p)
  if abs(det) < 1e-6:
    return -1
  let
    invDet = 1.0'f32 / det
    tv = origin - a
    u = dot(tv, p) * invDet
  if u < 0 or u > 1:
    return -1
  let
    q = cross(tv, edge1)
    v = dot(dir, q) * invDet
  if v < 0 or u + v > 1:
    return -1
  let distance = dot(edge2, q) * invDet
  if distance > 0: distance else: -1

proc pickTile(): tuple[hit: bool, layer, x, z: int] =
  ## Casts a ray from the mouse into the scene and returns the nearest
  ## walkable tile top it hits, across all layers.
  let
    ndcX = 2.0'f32 * window.mousePos.x.float32 / window.size.x.float32 - 1
    ndcY = 1.0'f32 - 2.0'f32 * window.mousePos.y.float32 / window.size.y.float32
    inv = inverse(cameraMvp())
  var
    nearPoint = inv * vec4(ndcX, ndcY, -1, 1)
    farPoint = inv * vec4(ndcX, ndcY, 1, 1)
  let
    origin = nearPoint.xyz / nearPoint.w
    farPos = farPoint.xyz / farPoint.w
    dir = normalize(farPos - origin)
  var best = float32.high
  for li in 0 ..< layers.len:
    let layer = layers[li]
    for z in 0 ..< layer.depth:
      for x in 0 ..< layer.width:
        let i = z * layer.width + x
        if not layerWalkable[li][i]:
          continue
        let
          h = layer.tiles[i].tops.unpack
          x0 = (layer.originX + x).float32 - HalfGrid
          z0 = (layer.originZ + z).float32 - HalfGrid
          v00 = vec3(x0, h[0], z0)
          v10 = vec3(x0 + 1, h[1], z0)
          v01 = vec3(x0, h[2], z0 + 1)
          v11 = vec3(x0 + 1, h[3], z0 + 1)
        for distance in [rayTriangle(origin, dir, v00, v10, v01),
            rayTriangle(origin, dir, v10, v11, v01)]:
          if distance > 0 and distance < best:
            best = distance
            result = (true, li, x, z)

proc nodeKey(layerIndex, x, z: int): int =
  (layerIndex * 4096 + z) * 4096 + x

proc findPath(): seq[Vec3] =
  ## A* over the edge-link graph between the start and finish tiles.
  if not (hasStart and hasFinish):
    return
  # Layers can disappear when toggled off; stale endpoints then have no path.
  if startLayer >= layers.len or finishLayer >= layers.len:
    return
  if not layerWalkable[startLayer][startZ * layers[startLayer].width + startX] or
      not layerWalkable[finishLayer][finishZ * layers[finishLayer].width + finishX]:
    return
  let
    startKey = nodeKey(startLayer, startX, startZ)
    goalKey = nodeKey(finishLayer, finishX, finishZ)
    goalCenter = tileCenter(finishLayer, finishX, finishZ)
  var
    frontier = initHeapQueue[(float32, int)]()
    cameFrom = initTable[int, int]()
    costSoFar = initTable[int, float32]()
  frontier.push((0.0'f32, startKey))
  costSoFar[startKey] = 0
  var found = false
  while frontier.len > 0:
    let (_, key) = frontier.pop()
    if key == goalKey:
      found = true
      break
    let
      x = key mod 4096
      z = (key div 4096) mod 4096
      li = key div (4096 * 4096)
      center = tileCenter(li, x, z)
    for direction in 0 .. 3:
      let link = edgeLink(li, x, z, direction)
      if not link.open:
        continue
      let
        nextKey = nodeKey(link.layer, link.x, link.z)
        nextCenter = tileCenter(link.layer, link.x, link.z)
        newCost = costSoFar[key] + dist(center, nextCenter)
      if nextKey notin costSoFar or newCost < costSoFar[nextKey]:
        costSoFar[nextKey] = newCost
        cameFrom[nextKey] = key
        frontier.push((newCost + dist(nextCenter, goalCenter), nextKey))
  if not found:
    return
  var key = goalKey
  while true:
    let
      x = key mod 4096
      z = (key div 4096) mod 4096
      li = key div (4096 * 4096)
    result.insert(tileCenter(li, x, z), 0)
    if key == startKey:
      break
    key = cameFrom[key]

proc rebuildPathMesh() =
  ## The path renders as a flat ribbon of quads through the tile centers,
  ## lifted a little so it doesn't z-fight the terrain.
  pathMesh.setLen(0)
  const
    HalfWidth = 0.12'f32
    Lift = 0.25'f32
  for i in 0 ..< max(0, pathPoints.len - 1):
    let
      a = pathPoints[i] + vec3(0, Lift, 0)
      b = pathPoints[i + 1] + vec3(0, Lift, 0)
      flat = vec3(b.x - a.x, 0, b.z - a.z)
      side = normalize(vec3(-flat.z, 0, flat.x)) * HalfWidth
    for v in [a - side, b - side, a + side, a + side, b - side, b + side]:
      pathMesh.add v.x
      pathMesh.add v.y
      pathMesh.add v.z
  if pathMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, pathVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      pathMesh.len * sizeof(float32),
      pathMesh[0].addr,
      GL_DYNAMIC_DRAW
    )

proc recomputePath() =
  pathPoints = findPath()
  if hasStart and hasFinish:
    if pathPoints.len > 0:
      pathStatus = &"Path found: {pathPoints.len} tiles."
    else:
      pathStatus = "No path: finish is unreachable."
  rebuildPathMesh()

## Line of sight
##
## The start marker is the observer. Every tile center gets a sight ray
## marched over the ground surface; the result is a one-value-per-tile
## visibility texture the terrain shader samples to fade hidden tiles to
## monochrome.

var
  visibilityTexture: GLuint
  visibilityData = newSeq[uint8](GridTiles * GridTiles)

proc groundSurfaceHeight(tx, tz: float32): float32 =
  ## Bilinear height of the ground layer's top surface at tile-space
  ## coordinates. Tree tiles are raised so forests block sight.
  let
    ix = clamp(int(tx), 0, GridTiles - 1)
    iz = clamp(int(tz), 0, GridTiles - 1)
    t = layers[0].tiles[iz * GridTiles + ix]
  if not t.exists:
    return -1000
  let
    h = t.tops.unpack
    fx = clamp(tx - ix.float32, 0, 1)
    fz = clamp(tz - iz.float32, 0, 1)
  result = (h[0] * (1 - fx) + h[1] * fx) * (1 - fz) +
    (h[2] * (1 - fx) + h[3] * fx) * fz
  if t.kind == TreeTile:
    result += 2.5

proc recomputeVisibility() =
  if visibilityTexture == 0:
    return  # texture not created yet during the initial rebuild
  var raw = newSeq[float32](GridTiles * GridTiles)
  if not losEnabled or not hasStart:
    for v in raw.mitems:
      v = 1.0
  else:
    let eye = tileCenter(startLayer, startX, startZ) + vec3(0, 1.7, 0)
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let
          tx = x.float32 + 0.5
          tz = z.float32 + 0.5
          target = vec3(
            tx - HalfGrid,
            groundSurfaceHeight(tx, tz) + 0.35,
            tz - HalfGrid
          )
          span = target - eye
          distance = span.length
        var visible = 1.0'f32
        # Skip both ray ends so neither the eye's own tile nor the target
        # tile's tree bump occludes the ray to itself.
        var s = 0.7'f32
        while s < distance - 0.9:
          let p = eye + span * (s / distance)
          if groundSurfaceHeight(p.x + HalfGrid, p.z + HalfGrid) > p.y:
            visible = 0.0
            break
          s += 0.4
        raw[z * GridTiles + x] = visible

  # A small box blur widens the visible/hidden boundary so the shader's
  # bilinear sample fades over about two tiles instead of one hard edge.
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      var total = 0.0'f32
      var count = 0
      for dz in -1 .. 1:
        for dx in -1 .. 1:
          let
            nx = x + dx
            nz = z + dz
          if nx < 0 or nx >= GridTiles or nz < 0 or nz >= GridTiles:
            continue
          total += raw[nz * GridTiles + nx]
          inc count
      visibilityData[z * GridTiles + x] =
        uint8(clamp(total / count.float32 * 255.0, 0.0, 255.0))
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glTexSubImage2D(
    GL_TEXTURE_2D, 0, 0, 0, GridTiles, GridTiles,
    GL_RED, GL_UNSIGNED_BYTE, visibilityData[0].addr
  )
  glBindTexture(GL_TEXTURE_2D, 0)

glGenTextures(1, visibilityTexture.addr)
glBindTexture(GL_TEXTURE_2D, visibilityTexture)
glTexImage2D(
  GL_TEXTURE_2D, 0, GL_R8.GLint, GridTiles, GridTiles, 0,
  GL_RED, GL_UNSIGNED_BYTE, nil
)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
glBindTexture(GL_TEXTURE_2D, 0)
recomputeVisibility()

## Input

proc updateCamera() =
  ## Handles camera gestures, marker placement, and the clean-view toggle.
  if window.buttonPressed[KeyF1]:
    showPanel = not showPanel
  let overUi = mouseOverUi()

  # Marker placement and dragging. The place buttons arm a one-shot
  # placement; once a marker exists, grabbing its tile drags it around with
  # the path (and the start's line-of-sight fade) updating live. Placing or
  # moving one marker never clears the other.
  var markerClick = false
  if window.buttonPressed[MouseLeft] and not overUi:
    let pick = pickTile()
    if pick.hit:
      case placeMode
      of PlacingStart:
        hasStart = true
        startLayer = pick.layer
        startX = pick.x
        startZ = pick.z
        dragTarget = DragStart
        placeMode = NoPlacement
        markerClick = true
        if not hasFinish:
          pathStatus = "Drag the start; place a finish for a path."
        recomputePath()
        recomputeVisibility()
      of PlacingFinish:
        hasFinish = true
        finishLayer = pick.layer
        finishX = pick.x
        finishZ = pick.z
        dragTarget = DragFinish
        placeMode = NoPlacement
        markerClick = true
        if not hasStart:
          pathStatus = "Drag the finish; place a start for a path."
        recomputePath()
      of NoPlacement:
        if hasStart and pick.layer == startLayer and
            pick.x == startX and pick.z == startZ:
          dragTarget = DragStart
          markerClick = true
        elif hasFinish and pick.layer == finishLayer and
            pick.x == finishX and pick.z == finishZ:
          dragTarget = DragFinish
          markerClick = true
  elif dragTarget != NoDrag and window.buttonDown[MouseLeft] and not overUi:
    let pick = pickTile()
    if pick.hit:
      if dragTarget == DragStart and (pick.layer != startLayer or
          pick.x != startX or pick.z != startZ):
        startLayer = pick.layer
        startX = pick.x
        startZ = pick.z
        recomputePath()
        recomputeVisibility()
      elif dragTarget == DragFinish and (pick.layer != finishLayer or
          pick.x != finishX or pick.z != finishZ):
        finishLayer = pick.layer
        finishX = pick.x
        finishZ = pick.z
        recomputePath()
  if not window.buttonDown[MouseLeft]:
    dragTarget = NoDrag

  if window.buttonPressed[MouseLeft] and not overUi and not markerClick:
    if window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]:
      panning = true
    else:
      rotating = true
  if window.buttonPressed[MouseRight] and not overUi:
    panning = true
  if not window.buttonDown[MouseLeft] and not window.buttonDown[MouseRight]:
    rotating = false
    panning = false

  let delta = window.mouseDelta.vec2
  if rotating:
    cameraYaw -= delta.x * 0.01
    cameraPitch = clamp(cameraPitch + delta.y * 0.01, 0.1, 1.55)
  if panning:
    let
      right = vec3(cos(cameraYaw), 0, -sin(cameraYaw))
      forward = vec3(-sin(cameraYaw), 0, -cos(cameraYaw))
      panSpeed = cameraDistance * 0.0015
    cameraTarget = cameraTarget - right * delta.x * panSpeed
    cameraTarget = cameraTarget + forward * delta.y * panSpeed
  if not overUi and window.scrollDelta.y != 0:
    cameraDistance = clamp(
      cameraDistance * pow(0.92'f32, window.scrollDelta.y), 5.0, 400.0)

## Frame

type PanelTab = enum
  TerrainTab, TexturesTab, ShadowTab, TreesTab, LayersTab, PathTab

var panelTab = TerrainTab

var lastParams = (frequency, amplitude, octaves, gain, lacunarity, seed,
  fortEnabled, wallHeight, slopeLimit, treeDensity, grassCount,
    bridgeEnabled, waterEnabled, treesEnabled, grassEnabled,
    rocksEnabled, rockCount, forestSharpness, forestSeed, forestFrequency,
    forestOctaves, forestGain, forestLacunarity, treeHeight)
var lastLosEnabled = losEnabled
var lastSunParams = (sunAzimuth, sunElevation)

proc saveScreenshot() =
  ## Saves the rendered frame before swapping, with its current UI visibility.
  let
    image = newImage(window.size.x, window.size.y)
    path = getEnv("SCREENSHOT_PATH", "tmp/quadterrain_artpass.png")
  glReadPixels(
    0,
    0,
    window.size.x,
    window.size.y,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    image.data[0].addr
  )
  # The window is already composited; coverage alpha is not PNG transparency.
  for c in image.data.mitems:
    c.a = 255
  image.flipVertical()
  if path.parentDir.len > 0:
    createDir(path.parentDir)
  image.writeFile(path)
  echo "Screenshot saved: ", path

if existsEnv("SHOW_UI"):
  showPanel = getEnv("SHOW_UI") != "0"

when defined(takeScreenshot):
  var screenshotFrame = 0
  # Optional camera overrides for scripted captures, e.g. CAM_YAW=3.1
  if existsEnv("CAM_YAW"): cameraYaw = getEnv("CAM_YAW").parseFloat.float32
  if existsEnv("CAM_PITCH"): cameraPitch = getEnv("CAM_PITCH").parseFloat.float32
  if existsEnv("CAM_DIST"): cameraDistance = getEnv("CAM_DIST").parseFloat.float32
  if existsEnv("CAM_X"): cameraTarget.x = getEnv("CAM_X").parseFloat.float32
  if existsEnv("CAM_Y"):
    cameraTarget.y = getEnv("CAM_Y").parseFloat.float32
  if existsEnv("CAM_Z"): cameraTarget.z = getEnv("CAM_Z").parseFloat.float32
  if existsEnv("SHOW_EDGES"): showEdges = getEnv("SHOW_EDGES") != "0"
  if existsEnv("PANEL_TAB"): panelTab = PanelTab(getEnv("PANEL_TAB").parseInt)
  if existsEnv("BRIDGE"): bridgeEnabled = getEnv("BRIDGE") != "0"
  if existsEnv("LOS"): losEnabled = getEnv("LOS") != "0"
  if existsEnv("WATER"): waterEnabled = getEnv("WATER") != "0"
  if existsEnv("TREES"): treesEnabled = getEnv("TREES") != "0"
  if existsEnv("GRASS"): grassEnabled = getEnv("GRASS") != "0"
  if existsEnv("TREE_HEIGHT"):
    treeHeight = getEnv("TREE_HEIGHT").parseFloat.float32
  if existsEnv("ROAD_SIZE"):
    roadSize = getEnv("ROAD_SIZE").parseFloat.float32
  if existsEnv("SHADOWS"): showShadows = getEnv("SHADOWS") != "0"
  if existsEnv("SUN_AZIMUTH"): sunAzimuth = getEnv("SUN_AZIMUTH").parseFloat.float32
  if existsEnv("SUN_ELEVATION"): sunElevation = getEnv("SUN_ELEVATION").parseFloat.float32
  if existsEnv("SHADOW_STRENGTH"): shadowStrength = getEnv("SHADOW_STRENGTH").parseFloat.float32
  if existsEnv("SHADOW_SOFTNESS"): shadowSoftness = getEnv("SHADOW_SOFTNESS").parseFloat.float32
  if existsEnv("TOON"): showToon = getEnv("TOON") != "0"
  if existsEnv("TOON_HOUR"): toonHour = getEnv("TOON_HOUR").parseFloat.float32
  if existsEnv("TIME_OF_DAY"): timeOfDay = getEnv("TIME_OF_DAY").parseFloat.float32
  if existsEnv("TIE_TIME"): tieToTime = getEnv("TIE_TIME") != "0"
  if existsEnv("SHADING_STRENGTH"): shadingStrength = getEnv("SHADING_STRENGTH").parseFloat.float32
  if existsEnv("SHADOW_FRUSTUM"): showLightFrustum = getEnv("SHADOW_FRUSTUM") != "0"
  if existsEnv("SHADOW_MAP_VIEW"): showShadowMap = getEnv("SHADOW_MAP_VIEW") != "0"
  # Scripted path test: PATH_START/PATH_FINISH as "layer,x,z".
  if existsEnv("PATH_START") and existsEnv("PATH_FINISH"):
    proc parseTile(s: string): array[3, int] =
      let parts = s.split(',')
      [parts[0].parseInt, parts[1].parseInt, parts[2].parseInt]
    let
      s = parseTile(getEnv("PATH_START"))
      f = parseTile(getEnv("PATH_FINISH"))
    hasStart = true
    startLayer = s[0]
    startX = s[1]
    startZ = s[2]
    hasFinish = true
    finishLayer = f[0]
    finishX = f[1]
    finishZ = f[2]
    recomputePath()
    recomputeVisibility()
  if existsEnv("DUMP_FORT"):
    for z in 24 .. 40:
      let t = layers[0].tiles[z * GridTiles + 26]
      echo "wall x26 z", z, " exists=", t.exists, " top=", t.tops.unpack[0]
    for x in 24 .. 40:
      let t = layers[0].tiles[26 * GridTiles + x]
      echo "wall z26 x", x, " exists=", t.exists, " top=", t.tops.unpack[0]
    var kindCounts: array[4, int]
    for t in layers[0].tiles:
      kindCounts[min(t.kind, 3'u32).int].inc
    echo "kinds grass/road/rock/marsh: ", kindCounts
    echo "path:"
    for p in pathPoints:
      echo "  ", p.x + HalfGrid, " ", p.z + HalfGrid, " y=", p.y

when defined(frameTimer):
  import std/[monotimes, times]
  var
    timerFrame = 0
    timerStart: MonoTime

window.onFrame = proc() =
  when defined(frameTimer):
    inc timerFrame
    if timerFrame == 30:
      timerStart = getMonoTime()
    if timerFrame == 230:
      let ms = (getMonoTime() - timerStart).inMicroseconds.float64 / 1000.0 / 200.0
      echo "avg frame ms: ", ms
      quit(0)
  updateCamera()

  let params = (frequency, amplitude, octaves, gain, lacunarity, seed,
    fortEnabled, wallHeight, slopeLimit, treeDensity, grassCount,
    bridgeEnabled, waterEnabled, treesEnabled, grassEnabled,
    rocksEnabled, rockCount, forestSharpness, forestSeed, forestFrequency,
    forestOctaves, forestGain, forestLacunarity, treeHeight)
  if params != lastParams:
    lastParams = params
    rebuildTerrain()
    recomputePath()
    recomputeVisibility()
  if losEnabled != lastLosEnabled:
    lastLosEnabled = losEnabled
    recomputeVisibility()
  if tieToTime:
    applyTimeOfDay()
  if (sunAzimuth, sunElevation) != lastSunParams:
    lastSunParams = (sunAzimuth, sunElevation)
    updateSun()

  # Shadow depth pass: the sun's view of every caster, rendered before the
  # main pass so the surface shaders can sample the finished depth map.
  if showShadows or showShadowMap:
    glBindFramebuffer(GL_FRAMEBUFFER, shadowFramebuffer)
    glViewport(0, 0, ShadowMapSize, ShadowMapSize)
    glClear(GL_DEPTH_BUFFER_BIT)
    glEnable(GL_DEPTH_TEST)
    glUseProgram(depthProgram)
    glUniformMatrix4fv(
      depthLightMvpLocation, 1, GL_FALSE, cast[ptr float32](lightMvp.addr))
    glBindVertexArray(terrainDepthVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, meshVertexCount.GLsizei)
    if treeMesh.len > 0:
      glUseProgram(treeDepthProgram)
      glUniformMatrix4fv(
        treeDepthLightMvpLocation, 1, GL_FALSE, cast[ptr float32](lightMvp.addr))
      glActiveTexture(GL_TEXTURE0)
      glBindTexture(GL_TEXTURE_2D_ARRAY, treeTextureArray)
      glUniform1i(treeDepthTexturesLocation, 0)
      glUniform1f(treeDepthAlphaCutoffLocation, TreeAlphaCutoff)
      glBindVertexArray(treeDepthVertexArray)
      glDrawArrays(GL_TRIANGLES, 0, (treeMesh.len div 9).GLsizei)
    glBindVertexArray(0)
    glUseProgram(0)
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    glViewport(0, 0, window.size.x, window.size.y)

  sk.beginUi(window, window.size)

  glClearColor(0.05, 0.06, 0.09, 1.0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glEnable(GL_DEPTH_TEST)

  # Toon palette for this frame, and the games' gradient background: the
  # horizon glows with the highlight, the sky cools toward the shadow
  # color, the ground below is the shadow color darkened a little.
  let toonPalette = paletteAtHour(toonHour)
  if showToon:
    let
      horizonColor = mix(toonPalette.highlight, toonPalette.shadow, 0.25)
      skyColor = mix(toonPalette.highlight, toonPalette.shadow, 0.8)
      groundColor = toonPalette.shadow * 0.8
    glUseProgram(toonBackgroundProgram)
    glUniform4f(toonSkyLocation, skyColor.r, skyColor.g, skyColor.b, 1)
    glUniform4f(
      toonHorizonLocation, horizonColor.r, horizonColor.g, horizonColor.b, 1)
    glUniform4f(
      toonGroundLocation, groundColor.r, groundColor.g, groundColor.b, 1)
    glUniform1f(toonHorizonHeightLocation, 0.42)
    glDisable(GL_DEPTH_TEST)
    glDepthMask(GL_FALSE)
    glBindVertexArray(toonBackgroundVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, 3)
    glBindVertexArray(0)
    glDepthMask(GL_TRUE)
    glEnable(GL_DEPTH_TEST)
    glUseProgram(0)

  glUseProgram(terrainProgram)
  mvp = cameraMvp()
  glUniformMatrix4fv(mvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
  glUniform1f(borderWidthLocation, borderWidth)
  glUniform1f(heightScaleLocation, amplitude)
  glUniform1f(edgesEnabledLocation, if showEdges: 1.0 else: 0.0)
  glUniform1f(texScaleLocation, 1.0'f32 / textureSize)
  glUniform1f(roadRepeatLocation, textureSize / roadSize)
  glUniform1f(blendDepthLocation, blendDepth)
  glUniform1f(heightBlendLocation, heightBlend)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glUniform1i(visibilityTexLocation, 1)
  glUniform1f(visOffsetLocation, HalfGrid)
  glUniform1f(visScaleLocation, 1.0'f32 / GridTiles.float32)
  glActiveTexture(GL_TEXTURE2)
  glBindTexture(GL_TEXTURE_2D, shadowTexture)
  glUniform1i(terrainShadowMapLocation, 2)
  glUniformMatrix4fv(
    terrainLightMvpLocation, 1, GL_FALSE, cast[ptr float32](lightMvp.addr))
  glUniform1f(terrainShadowsEnabledLocation, if showShadows: 1.0 else: 0.0)
  glUniform1f(terrainShadowStrengthLocation, shadowStrength)
  glUniform1f(terrainShadowBiasLocation, shadowBias)
  glUniform1f(terrainShadowTexelLocation, shadowTexel)
  glUniform1f(terrainShadowSoftnessLocation, shadowSoftness)
  glUniform1f(terrainShadingStrengthLocation, shadingStrength)
  glUniform3f(terrainSunDirLocation, sunDir.x, sunDir.y, sunDir.z)
  glUniform1f(terrainToonEnabledLocation, if showToon: 1.0 else: 0.0)
  glUniform3f(
    terrainToonHighlightLocation, toonPalette.highlight.r,
    toonPalette.highlight.g, toonPalette.highlight.b)
  glUniform3f(
    terrainToonShadowLocation, toonPalette.shadow.r,
    toonPalette.shadow.g, toonPalette.shadow.b)
  glActiveTexture(GL_TEXTURE3)
  glBindTexture(GL_TEXTURE_2D, toonRampTexture)
  glUniform1i(terrainToonRampLocation, 3)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D_ARRAY, terrainTextureArray)
  glUniform1i(terrainTexturesLocation, 0)
  glBindVertexArray(vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, meshVertexCount.GLsizei)
  glBindVertexArray(0)

  # Trees: textured, alpha-cutout foliage, drawn from both sides.
  if treeMesh.len > 0:
    glUseProgram(treeProgram)
    glUniformMatrix4fv(treeMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, visibilityTexture)
    glUniform1i(treeVisibilityTexLocation, 1)
    glUniform1f(treeVisOffsetLocation, HalfGrid)
    glUniform1f(treeVisScaleLocation, 1.0'f32 / GridTiles.float32)
    glActiveTexture(GL_TEXTURE2)
    glBindTexture(GL_TEXTURE_2D, shadowTexture)
    glUniform1i(treeShadowMapLocation, 2)
    glUniformMatrix4fv(
      treeLightMvpLocation, 1, GL_FALSE, cast[ptr float32](lightMvp.addr))
    glUniform1f(treeShadowsEnabledLocation, if showShadows: 1.0 else: 0.0)
    glUniform1f(treeShadowStrengthLocation, shadowStrength)
    glUniform1f(treeShadowBiasLocation, shadowBias)
    glUniform1f(treeShadowTexelLocation, shadowTexel)
    glUniform1f(treeShadowSoftnessLocation, shadowSoftness)
    glUniform1f(treeShadingStrengthLocation, shadingStrength)
    glUniform3f(treeSunDirLocation, sunDir.x, sunDir.y, sunDir.z)
    glUniform1f(treeToonEnabledLocation, if showToon: 1.0 else: 0.0)
    glUniform3f(
      treeToonHighlightLocation, toonPalette.highlight.r,
      toonPalette.highlight.g, toonPalette.highlight.b)
    glUniform3f(
      treeToonShadowLocation, toonPalette.shadow.r,
      toonPalette.shadow.g, toonPalette.shadow.b)
    glActiveTexture(GL_TEXTURE3)
    glBindTexture(GL_TEXTURE_2D, toonRampTexture)
    glUniform1i(treeToonRampLocation, 3)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D_ARRAY, treeTextureArray)
    glUniform1i(treeTexturesLocation, 0)
    glUniform1f(treeAlphaCutoffLocation, TreeAlphaCutoff)
    glDisable(GL_BLEND)
    glBindVertexArray(treeVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (treeMesh.len div 9).GLsizei)
    glBindVertexArray(0)

  # Start/finish spheres and the path ribbon.
  glUseProgram(solidProgram)
  let viewProjection = mvp
  if pathMesh.len > 0:
    glUniformMatrix4fv(solidMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(solidColorLocation, 1.0, 0.85, 0.2)
    glBindVertexArray(pathVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (pathMesh.len div 3).GLsizei)
  if hasStart:
    mvp = viewProjection *
      translate(tileCenter(startLayer, startX, startZ) + vec3(0, 0.45, 0)) *
      scale(vec3(0.4))
    glUniformMatrix4fv(solidMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(solidColorLocation, 1.0, 0.95, 0.15)
    glBindVertexArray(sphereVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (sphereMesh.len div 3).GLsizei)
  if hasFinish:
    mvp = viewProjection *
      translate(tileCenter(finishLayer, finishX, finishZ) + vec3(0, 0.45, 0)) *
      scale(vec3(0.4))
    glUniformMatrix4fv(solidMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(solidColorLocation, 0.9, 0.25, 0.9)
    glBindVertexArray(sphereVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (sphereMesh.len div 3).GLsizei)
  # The sun's orthographic frustum as a yellow wire box.
  if showPanel and showLightFrustum and frustumMesh.len > 0:
    mvp = viewProjection
    glUniformMatrix4fv(solidMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(solidColorLocation, 1.0, 0.8, 0.15)
    glBindVertexArray(frustumVertexArray)
    glDrawArrays(GL_LINES, 0, (frustumMesh.len div 3).GLsizei)
  glBindVertexArray(0)

  # Transparent water goes last, blended over everything opaque.
  if waterMesh.len > 0:
    glUseProgram(waterProgram)
    mvp = viewProjection
    glUniformMatrix4fv(waterMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(waterCameraLocation, cameraEye.x, cameraEye.y, cameraEye.z)
    glUniform3f(waterSunDirLocation, sunDir.x, sunDir.y, sunDir.z)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glDepthMask(GL_FALSE)
    glBindVertexArray(waterVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (waterMesh.len div 6).GLsizei)
    glBindVertexArray(0)
    glDepthMask(GL_TRUE)
    glDisable(GL_BLEND)
  glUseProgram(0)

  glDisable(GL_DEPTH_TEST)

  # Shadow map debug view: the raw depth map in the lower-right corner.
  if showPanel and showShadowMap:
    let
      viewSize = 300.0'f32
      margin = 12.0'f32
      x0 = 1.0'f32 - 2.0'f32 * (margin + viewSize) / window.size.x.float32
      x1 = 1.0'f32 - 2.0'f32 * margin / window.size.x.float32
      y0 = -1.0'f32 + 2.0'f32 * margin / window.size.y.float32
      y1 = -1.0'f32 + 2.0'f32 * (margin + viewSize) / window.size.y.float32
    var quad: seq[float32]
    for (x, y, u, v) in [
      (x0, y0, 0.0'f32, 0.0'f32), (x1, y0, 1.0'f32, 0.0'f32),
      (x0, y1, 0.0'f32, 1.0'f32), (x0, y1, 0.0'f32, 1.0'f32),
      (x1, y0, 1.0'f32, 0.0'f32), (x1, y1, 1.0'f32, 1.0'f32)
    ]:
      quad.add x
      quad.add y
      quad.add 0.0
      quad.add u
      quad.add v
    glUseProgram(shadowViewProgram)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, shadowTexture)
    # Plain depth reads need the comparison mode off for this draw.
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE.GLint)
    glUniform1i(shadowViewMapLocation, 0)
    glBindVertexArray(shadowViewVertexArray)
    glBindBuffer(GL_ARRAY_BUFFER, shadowViewVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      quad.len * sizeof(float32),
      quad[0].addr,
      GL_DYNAMIC_DRAW
    )
    glDrawArrays(GL_TRIANGLES, 0, 6)
    glBindVertexArray(0)
    glBindTexture(GL_TEXTURE_2D, shadowTexture)
    glTexParameteri(
      GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)
    glUseProgram(0)

  ui:
    subWindow("Quad Terrain Art Pass", showPanel, vec2(10, 10), vec2(340, 680)):
      text "capture help":
        characters "F1: toggle UI   F12: screenshot"
      group "tab row 1":
        box 310, 32
        layout LeftToRight
        itemSpacing 10
        radioButton "Terrain", panelTab, TerrainTab
        radioButton "Textures", panelTab, TexturesTab
        radioButton "Trees", panelTab, TreesTab
      group "tab row 2":
        box 310, 32
        layout LeftToRight
        itemSpacing 10
        radioButton "Shadow", panelTab, ShadowTab
        radioButton "Layers", panelTab, LayersTab
        radioButton "Path", panelTab, PathTab
      case panelTab
      of TerrainTab:
        text "noise title":
          characters "Noise"
        text "frequency label":
          characters &"Frequency: {frequency:0.3f}"
        scrubber "frequency", frequency, 0.005'f32, 0.5'f32, ""
        text "amplitude label":
          characters &"Amplitude: {amplitude:0.2f}"
        scrubber "amplitude", amplitude, 0.0'f32, 12.0'f32, ""
        text "octaves label":
          characters &"Octaves: {octaves}"
        scrubber "octaves", octaves, 1, 8, ""
        text "gain label":
          characters &"Gain: {gain:0.2f}"
        scrubber "gain", gain, 0.1'f32, 1.0'f32, ""
        text "lacunarity label":
          characters &"Lacunarity: {lacunarity:0.2f}"
        scrubber "lacunarity", lacunarity, 1.0'f32, 4.0'f32, ""
        text "seed label":
          characters &"Seed: {seed}"
        scrubber "seed", seed, 0, 9999, ""
        text "fort title":
          characters "Fort"
        checkBox "Fort walls and moat", fortEnabled
        text "wall label":
          characters &"Wall height: {wallHeight:0.1f}"
        scrubber "wallHeight", wallHeight, 0.0'f32, 12.0'f32, ""
        text "slope label":
          characters &"Max slope: {int(slopeLimit)} deg"
        scrubber "slopeLimit", slopeLimit, 10.0'f32, 85.0'f32, ""
        text "border label":
          characters &"Tile border: {borderWidth:0.3f}"
        scrubber "border", borderWidth, 0.0'f32, 0.25'f32, ""
      of TexturesTab:
        text "texture title":
          characters "Texture size"
        text "texSize label":
          characters &"One repeat spans: {textureSize:0.1f} tiles"
        scrubber "textureSize", textureSize, 1.0'f32, 32.0'f32, ""
        text "texSize hint":
          characters "Bigger: calmer, broader strokes"
        text "road size label":
          characters &"Road repeat: {roadSize:0.1f} tiles"
        scrubber "roadSize", roadSize, 2.0'f, 12.0'f, ""
        text "painted materials":
          characters "Golden Valley + Meadow: 11 materials"
        text "blend title":
          characters "Blending"
        text "blendDepth label":
          characters &"Blend depth: {blendDepth:0.2f}"
        scrubber "blendDepth", blendDepth, 0.02'f32, 1.0'f32, ""
        text "blendDepth hint":
          characters "Smaller: more abrupt borders"
        text "heightBlend label":
          characters &"Height blend: {heightBlend:0.2f}"
        scrubber "heightBlend", heightBlend, 0.0'f32, 2.0'f32, ""
        text "heightBlend hint":
          characters "Higher: clumpier borders"
      of ShadowTab:
        text "time title":
          characters "Time of day"
        text "time label":
          characters &"Hour: {timeOfDay:0.1f}"
        scrubber "timeOfDay", timeOfDay, 0.0'f32, 24.0'f32, ""
        checkBox "Tie everything to the hour", tieToTime
        text "tie hint":
          characters "Drives sun, palette, and strengths"
        text "sun title":
          characters "Sun"
        text "sun azimuth label":
          characters &"Azimuth: {int(round(sunAzimuth))} deg"
        scrubber "sunAzimuth", sunAzimuth, 0.0'f32, 360.0'f32, ""
        text "sun azimuth hint":
          characters "Swings shadows around the map"
        text "sun elevation label":
          characters &"Elevation: {int(round(sunElevation))} deg"
        scrubber "sunElevation", sunElevation, 10.0'f32, 85.0'f32, ""
        text "sun elevation hint":
          characters "Time of day; low is long shadows"
        text "toon title":
          characters "Toon"
        checkBox "Toon shading", showToon
        text "toon hour label":
          characters &"Palette hour: {toonHour:0.1f}"
        scrubber "toonHour", toonHour, 0.0'f32, 24.0'f32, ""
        text "toon hour hint":
          characters "Day-cycle palettes from the games"
        text "shadow title":
          characters "Shadows"
        checkBox "Cast shadows", showShadows
        text "shadow strength label":
          characters &"Strength: {shadowStrength:0.2f}"
        scrubber "shadowStrength", shadowStrength, 0.0'f32, 1.0'f32, ""
        text "shadow strength hint":
          characters "1: shadows go pure black"
        text "shading label":
          characters &"Shading: {shadingStrength:0.2f}"
        scrubber "shadingStrength", shadingStrength, 0.0'f32, 1.0'f32, ""
        text "shading hint":
          characters "0: flat, no directional light"
        text "shadow softness label":
          characters &"Softness: {shadowSoftness:0.1f}"
        scrubber "shadowSoftness", shadowSoftness, 0.0'f32, 4.0'f32, ""
        text "shadow softness hint":
          characters "Wider: blurrier shadow edges"
        text "shadow bias label":
          characters &"Bias: {shadowBias:0.4f}"
        scrubber "shadowBias", shadowBias, 0.0'f32, 0.01'f32, ""
        text "shadow bias hint":
          characters "Up: fixes acne. Down: fixes gaps"
        text "shadow debug title":
          characters "Debug"
        checkBox "Show sun frustum", showLightFrustum
        checkBox "Show shadow map", showShadowMap
      of LayersTab:
        text "display title":
          characters "Display"
        checkBox "Show edges", showEdges
        checkBox "Line of sight fade", losEnabled
        text "layers title":
          characters "Quad layers"
        checkBox "Bridge", bridgeEnabled
        checkBox "Moat water", waterEnabled
        text "props title":
          characters "Props"
        checkBox "Grass and flowers", grassEnabled
        text "grass label":
          characters &"Ground cover: {grassCount}"
        scrubber "grassCount", grassCount, 0, 500, ""
        checkBox "Rocks", rocksEnabled
        text "rocks label":
          characters &"Rocks: {rockCount}"
        scrubber "rockCount", rockCount, 0, 100, ""
      of TreesTab:
        checkBox "Trees", treesEnabled
        text "tree models":
          characters "Valley beech + Meadow broadleaf"
        text "tree height label":
          characters &"Tree height: {treeHeight:0.1f} tiles"
        scrubber "treeHeight", treeHeight, 2.0'f32, 12.0'f32, ""
        text "trees label":
          characters &"Tree density: {treeDensity:0.2f}"
        scrubber "treeDensity", treeDensity, 0.0'f32, 1.0'f32, ""
        text "trees hint":
          characters "Chance of a tree at a forest peak"
        text "sharpness label":
          characters &"Forest sharpness: {forestSharpness:0.2f}"
        scrubber "forestSharpness", forestSharpness, 0.25'f32, 4.0'f32, ""
        text "sharpness hint":
          characters "Higher: trees hug the deep woods"
        text "forest title":
          characters "Forest noise"
        text "forest hint":
          characters "Trees only grow where noise > 0"
        text "forest seed label":
          characters &"Seed: {forestSeed}"
        scrubber "forestSeed", forestSeed, 0, 9999, ""
        text "forest size label":
          characters &"Size: {int(round(1.0 / forestFrequency))} tiles"
        scrubber "forestFrequency", forestFrequency, 0.02'f32, 0.3'f32, ""
        text "forest octaves label":
          characters &"Octaves: {forestOctaves}"
        scrubber "forestOctaves", forestOctaves, 1, 6, ""
        text "forest gain label":
          characters &"Gain: {forestGain:0.2f}"
        scrubber "forestGain", forestGain, 0.1'f32, 1.0'f32, ""
        text "forest lacunarity label":
          characters &"Lacunarity: {forestLacunarity:0.2f}"
        scrubber "forestLacunarity", forestLacunarity, 1.0'f32, 4.0'f32, ""
      of PathTab:
        text "path title":
          characters "Pathfinding"
        button "Place Start":
          placeMode = PlacingStart
          pathStatus = "Click a tile to place the start."
        button "Place Finish":
          placeMode = PlacingFinish
          pathStatus = "Click a tile to place the finish."
        text "path status":
          characters pathStatus
        text "help markers":
          characters "Drag a placed sphere to move it"
        text "help drag":
          characters "Drag: rotate"
        text "help pan":
          characters "Right/shift drag: pan"
        text "help zoom":
          characters "Scroll: zoom"

  sk.endUi()

  if window.buttonPressed[KeyF12]:
    saveScreenshot()

  when defined(takeScreenshot):
    inc screenshotFrame
    if screenshotFrame == 30:
      saveScreenshot()
      quit(0)

  window.swapBuffers()

while not window.closeRequested:
  pollEvents()
