## Quad terrain experiment: 64x64 grid of tile columns with per-corner heights.
## Neighboring corners usually match, giving smooth rolling hills; where they
## differ, wall quads connect the edges and mark them impassable (red).
## Missing columns leave gaps with skirt walls down to a floor level, and
## extra slab layers (with top and bottom heights) float above the ground.
## Terrain is drawn with plain OpenGL (shaders authored via shady), UI via silky.
## Run from the repo root: nim r experiments/terrain/quadterrain.nim

import
  std/[strformat, strutils, heapqueue, random],
  bumpy, vmath, chroma, noisy, shady, pixie, gltf,
  silky

const
  GridTiles = 64
  HalfGrid = GridTiles.float32 / 2.0

## Atlas

let builder = newAtlasBuilder(1024, 4)
builder.addDir("../polyworld_data/themes/editor/", "../polyworld_data/themes/editor/")
builder.addFont("../polyworld_data/themes/editor/IBMPlexSans-Regular.ttf", "H1", 32.0)
builder.addFont("../polyworld_data/themes/editor/IBMPlexSans-Regular.ttf", "Default", 18.0)
builder.write("tmp/editor.atlas.png")

## Window

let window = newWindow(
  "Quad Terrain",
  ivec2(1280, 800),
  vsync = false
)
makeContextCurrent(window)
loadExtensions()

let sk = newSilky(window, "tmp/editor.atlas.png")

window.runeInputEnabled = true
window.onRune = proc(rune: Rune) =
  sk.inputRunes.add(rune)

## Shaders

var
  mvp: Uniform[Mat4]
  borderWidth: Uniform[float32]
  heightScale: Uniform[float32]
  edgesEnabled: Uniform[float32]

proc terrainVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    edgeMask: float32,
    normal: Vec3,
    tileColor: Vec3,
    tilePos: var Vec2,
    tileHeight: var float32,
    vertEdgeMask: var float32,
    vertNormal: var Vec3,
    vertColor: var Vec3
) =
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  tilePos = vec2(vertPos.x, vertPos.z)
  tileHeight = vertPos.y
  vertEdgeMask = edgeMask
  vertNormal = normal
  vertColor = tileColor

proc terrainFrag(
    fragColor: var Vec4,
    tilePos: Vec2,
    tileHeight: float32,
    vertEdgeMask: float32,
    vertNormal: Vec3,
    vertColor: Vec3
) =
  let h = clamp(tileHeight / max(heightScale, 0.001) * 0.5 + 0.5, 0.0, 1.0)
  # Per-kind tile color (tops and skirts baked per vertex), brightened a
  # little with height. Impassable tiles keep their normal color; their
  # blocked edges show red when the edge display is on.
  var color = vertColor * (0.75 + 0.5 * h)
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
  # Half-lambert directional lighting: smooth vertex normals across
  # connected terrain, hard breaks at cliffs and walls.
  let light = clamp(
    dot(normalize(vertNormal), normalize(vec3(0.45, 0.8, 0.4))) * 0.5 + 0.5,
    0.0, 1.0)
  color = color * (0.45 + 0.7 * light)
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
        normalize(cameraPos - worldPos) + normalize(vec3(0.45, 0.8, 0.4)))
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

## Low-poly tree props: loaded with the gltf library, the palette texture
## baked into per-vertex colors, each model normalized to unit height with
## its trunk base at the origin.

proc treeVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertColor: Vec3,
    normal: Vec3,
    fragmentColor: var Vec3,
    fragmentNormal: var Vec3
) =
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  fragmentColor = vertColor
  fragmentNormal = normal

proc treeFrag(
    fragColor: var Vec4,
    fragmentColor: Vec3,
    fragmentNormal: Vec3
) =
  let light = clamp(
    dot(normalize(fragmentNormal), normalize(vec3(0.45, 0.8, 0.4))) * 0.5 + 0.5,
    0.0, 1.0)
  fragColor = vec4(
    fragmentColor.x * (0.45 + 0.7 * light),
    fragmentColor.y * (0.45 + 0.7 * light),
    fragmentColor.z * (0.45 + 0.7 * light),
    1.0
  )

let treeProgram = compileProgram(
  toShader(treeVert, glsl4Desktop, shaderVertex),
  toShader(treeFrag, glsl4Desktop, shaderFragment)
)
let treeMvpLocation = glGetUniformLocation(treeProgram, "mvp")

type
  PropModel = object
    name: string
    height: float32         # model height before pack scaling
    vertices: seq[float32]  # x y z r g b nx ny nz; pack-scaled, base at y 0
  TreePlacement = object
    model: int
    position: Vec3
    rotation: float32
    scale: float32  # mild per-instance jitter around 1

var
  propModels: seq[PropModel]   # trees; occupy a tile and block it
  grassModels: seq[PropModel]  # grass puffs; walkable decoration
  rockModels: seq[PropModel]   # boulders; half-buried on rock tiles
  grassPlacements: seq[TreePlacement]
  rockPlacements: seq[TreePlacement]

proc collectPropModels(
    node: gltf.Node, parent: Mat4, models: var seq[PropModel],
    skipPrefix = ""
) =
  let world = parent * (translate(node.pos) * node.rot.mat4 * scale(node.scale))
  if node.mesh != nil and
      (skipPrefix.len == 0 or not node.name.startsWith(skipPrefix)):
    var
      points: seq[Vec3]
      colors: seq[Vec3]
      sourceNormals: seq[Vec3]
      low = vec3(float32.high, float32.high, float32.high)
      high = vec3(float32.low, float32.low, float32.low)
    # Normals need the inverse transpose: node scales can be wildly
    # non-uniform (the rock pack), which distorts rotated normals.
    let normalMatrix = world.inverse.transpose
    for primitive in node.mesh.primitives:
      let image =
        if primitive.material != nil: primitive.material.baseColor else: nil
      template addCorner(index: int) =
        let point = world * primitive.points[index]
        low = min(low, point)
        high = max(high, point)
        points.add point
        if index < primitive.normals.len:
          let transformed = normalMatrix * vec4(
            primitive.normals[index].x,
            primitive.normals[index].y,
            primitive.normals[index].z,
            0
          )
          sourceNormals.add normalize(vec3(transformed.x, transformed.y, transformed.z))
        else:
          sourceNormals.add vec3(0, 0, 0)
        if image != nil and index < primitive.uvs.len:
          let
            uv = primitive.uvs[index]
            px = clamp(int(uv.x * image.width.float32), 0, image.width - 1)
            py = clamp(int(uv.y * image.height.float32), 0, image.height - 1)
            sample = image[px, py]
          colors.add vec3(
            sample.r.float32 / 255 * primitive.material.baseColorFactor.r,
            sample.g.float32 / 255 * primitive.material.baseColorFactor.g,
            sample.b.float32 / 255 * primitive.material.baseColorFactor.b
          )
        elif primitive.material != nil:
          # No UVs (e.g. the grass pack): flat material color.
          colors.add vec3(
            primitive.material.baseColorFactor.r,
            primitive.material.baseColorFactor.g,
            primitive.material.baseColorFactor.b
          )
        else:
          colors.add vec3(0.5, 0.5, 0.5)
      if primitive.indices32.len > 0:
        for index in primitive.indices32:
          addCorner(index.int)
      elif primitive.indices16.len > 0:
        for index in primitive.indices16:
          addCorner(index.int)
    if points.len > 0:
      let
        height = max(high.y - low.y, 0.001'f32)
        center = (low + high) / 2
      var model = PropModel(name: node.name, height: height)
      for t in countup(0, points.len - 3, 3):
        # Authored normals when the model has them; otherwise flat facet
        # normals from the triangle.
        var facet = cross(
          points[t + 1] - points[t], points[t + 2] - points[t])
        if facet.length > 0:
          facet = facet.normalize
        else:
          facet = vec3(0, 1, 0)
        for i in t .. t + 2:
          let
            point = points[i] - vec3(center.x, low.y, center.z)
            normal =
              if sourceNormals[i].length > 0.5: sourceNormals[i]
              else: facet
          model.vertices.add point.x
          model.vertices.add point.y
          model.vertices.add point.z
          model.vertices.add colors[i].x
          model.vertices.add colors[i].y
          model.vertices.add colors[i].z
          model.vertices.add normal.x
          model.vertices.add normal.y
          model.vertices.add normal.z
      models.add model
  for child in node.nodes:
    collectPropModels(child, world, models, skipPrefix)

proc scalePack(models: var seq[PropModel], targetTallest: float32) =
  ## Scales a whole pack by one factor (tallest model becomes targetTallest
  ## tiles) so relative sizes within the pack are preserved.
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
      i += 9

collectPropModels(
  readGltfFile("../polyworld_data/terrain/low_poly_trees.glb").root, mat4(), propModels,
  skipPrefix = "rock")
collectPropModels(readGltfFile("../polyworld_data/terrain/low_poly_grass.glb").root, mat4(), grassModels)
collectPropModels(readGltfFile("../polyworld_data/terrain/low_poly_rocks.glb").root, mat4(), rockModels)

proc normalizeModels(models: var seq[PropModel]) =
  ## Scales each model independently to unit height — for packs whose
  ## showroom sizes vary wildly and carry no meaningful relative scale.
  for model in models.mitems:
    let factor = 1.0'f32 / max(model.height, 0.001)
    model.height = 1.0
    var i = 0
    while i < model.vertices.len:
      model.vertices[i] *= factor
      model.vertices[i + 1] *= factor
      model.vertices[i + 2] *= factor
      i += 9

proc brighten(models: var seq[PropModel], factor: float32) =
  ## Scales the baked vertex colors; some packs are authored very dark.
  for model in models.mitems:
    var i = 0
    while i < model.vertices.len:
      model.vertices[i + 3] = min(model.vertices[i + 3] * factor, 1.0)
      model.vertices[i + 4] = min(model.vertices[i + 4] * factor, 1.0)
      model.vertices[i + 5] = min(model.vertices[i + 5] * factor, 1.0)
      i += 9

propModels.scalePack(8.4)
grassModels.scalePack(0.7)
rockModels.normalizeModels()
rockModels.brighten(2.4)

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
  treeCount = 60
  grassCount = 220
  bridgeEnabled = true
  waterEnabled = true
  treesEnabled = true
  grassEnabled = true
  rocksEnabled = true
  rockCount = 30
  slopeLimit = 60.0'f32  # degrees; steeper top tiles are marked impassable
borderWidth = 0.05

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
  TreeTile = 5'u32   # renders like grass; the tile itself carries a tree

type TileColor = object
  top: Vec3
  skirt: Vec3

# Tile color index: top surface and skirt (side wall) color per tile kind.
const TileColorTable = [
  TileColor(top: vec3(0.32, 0.56, 0.26), skirt: vec3(0.45, 0.32, 0.19)),  # grass, dirt skirt
  TileColor(top: vec3(0.80, 0.72, 0.48), skirt: vec3(0.66, 0.57, 0.35)),  # road + fort, sand
  TileColor(top: vec3(0.56, 0.56, 0.60), skirt: vec3(0.36, 0.36, 0.40)),  # rock, darker gray skirt
  TileColor(top: vec3(0.44, 0.46, 0.22), skirt: vec3(0.32, 0.31, 0.17)),  # marsh, dirty green
  TileColor(top: vec3(0.64, 0.65, 0.70), skirt: vec3(0.44, 0.45, 0.50)),  # stone construction
  TileColor(top: vec3(0.32, 0.56, 0.26), skirt: vec3(0.45, 0.32, 0.19)),  # tree tile, grass look
]

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
          # Moat: a two-tile trench carved below the plateau, with a muddy
          # bottom. The water layer floats above it.
          let moatFloor = plateau - 2.0'f32
          gtile(x, z).tops = pack([moatFloor, moatFloor, moatFloor, moatFloor])
          gtile(x, z).kind = MarshTile
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
  # tile data during mesh building.
  if propModels.len > 0 and treesEnabled:
    var rng = initRand(seed * 7919 + 1)
    var attempts = 0
    var planted = 0
    while planted < treeCount and attempts < treeCount * 30:
      inc attempts
      let
        x = rng.rand(GridTiles - 1)
        z = rng.rand(GridTiles - 1)
      if not gtile(x, z).exists or gtile(x, z).impassable or
          gtile(x, z).kind != GrassTile:
        continue
      if fortEnabled and max(abs(x - c), abs(z - c)) <= 9:
        continue
      if x >= BridgeOriginX - 1 and x <= BridgeOriginX + BridgeLength and
          z >= BridgeOriginZ - 1 and z <= BridgeOriginZ + BridgeSpan:
        continue
      gtile(x, z).kind = TreeTile
      gtile(x, z).impassable = true
      inc planted

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

  # Boulders: half-buried rocks scattered on rocky peaks. They block the
  # tile they sit on.
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
        boulderScale = 0.9'f32 + rockRng.rand(1.1).float32
      rockPlacements.add TreePlacement(
        model: model,
        position: vec3(
          x.float32 - HalfGrid + 0.5,
          (h[0] + h[1] + h[2] + h[3]) / 4.0 -
            rockModels[model].height * boulderScale * 0.45,
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
  treeMesh: seq[float32]
  waterVertexArray, waterVertexBuffer: GLuint
  waterMesh: seq[float32]  # x y z nx ny nz

proc bakeInstance(model: PropModel, position: Vec3, rotation, instanceScale: float32) =
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
        model.vertices[i + 6], model.vertices[i + 7], model.vertices[i + 8])
    treeMesh.add point.x
    treeMesh.add point.y
    treeMesh.add point.z
    treeMesh.add model.vertices[i + 3]
    treeMesh.add model.vertices[i + 4]
    treeMesh.add model.vertices[i + 5]
    treeMesh.add normal.x
    treeMesh.add normal.y
    treeMesh.add normal.z
    i += 9

proc bakePlacements(models: seq[PropModel], placements: seq[TreePlacement]) =
  for placement in placements:
    bakeInstance(
      models[placement.model], placement.position,
      placement.rotation, placement.scale)

proc bakeTreeTiles() =
  ## Tree tiles carry their tree in the tile data: which model, rotation,
  ## and size all derive deterministically from the tile coordinates.
  if propModels.len == 0 or layers.len == 0:
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
        model = rng.rand(propModels.len - 1)
        rotation = rng.rand(2.0 * PI).float32
        treeScale = 0.85'f32 + rng.rand(0.45).float32
      bakeInstance(
        propModels[model],
        vec3(
          x.float32 - HalfGrid + 0.5,
          (h[0] + h[1] + h[2] + h[3]) / 4.0,
          z.float32 - HalfGrid + 0.5
        ),
        rotation,
        treeScale
      )

proc rebuildTreeMesh() =
  ## Bakes tree tiles, grass puffs, and boulders into one world-space
  ## colored triangle list.
  if treeVertexBuffer == 0:
    return  # buffers not created yet during the initial rebuild
  treeMesh.setLen(0)
  bakeTreeTiles()
  bakePlacements(grassModels, grassPlacements)
  bakePlacements(rockModels, rockPlacements)
  if treeMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, treeVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      treeMesh.len * sizeof(float32),
      treeMesh[0].addr,
      GL_STATIC_DRAW
    )

proc addTriangle(
    a, b, c, normalA, normalB, normalC, color: Vec3,
    edgeMask = 0.0'f32
) =
  for (v, n) in [(a, normalA), (b, normalB), (c, normalC)]:
    mesh.add v.x
    mesh.add v.y
    mesh.add v.z
    mesh.add edgeMask
    mesh.add n.x
    mesh.add n.y
    mesh.add n.z
    mesh.add color.x
    mesh.add color.y
    mesh.add color.z

proc addWall(top0, top1, bottom0, bottom1, normal, color: Vec3) =
  ## Connects two edges; degenerates to a single triangle when a corner
  ## pair coincides (a partial "connection"). Walls take the owning tile's
  ## skirt color and are flat-shaded by their face normal.
  addTriangle(top0, top1, bottom0, normal, normal, normal, color)
  addTriangle(top1, bottom1, bottom0, normal, normal, normal, color)

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
        tileColors = TileColorTable[min(t.kind, TileColorTable.high.uint32).int]
        n0 = cornerNormal(layer, faceNormals, x, z, 0)
        n1 = cornerNormal(layer, faceNormals, x, z, 1)
        n2 = cornerNormal(layer, faceNormals, x, z, 2)
        n3 = cornerNormal(layer, faceNormals, x, z, 3)
      addTriangle(v00, v10, v01, n0, n1, n2, tileColors.top, edgeMask)
      addTriangle(v10, v11, v01, n1, n3, n2, tileColors.top, edgeMask)

      if layer.slab:
        # Underside of the slab; never walkable.
        let down = vec3(0, -1, 0)
        addTriangle(
          vec3(x0, b[0], z0), vec3(x1, b[1], z0), vec3(x0, b[2], z1),
          down, down, down, tileColors.skirt)
        addTriangle(
          vec3(x1, b[1], z0), vec3(x1, b[3], z1), vec3(x0, b[2], z1),
          down, down, down, tileColors.skirt)

      # East edge: side wall when open, connecting wall when heights differ.
      # Mismatch walls are emitted from the east/south side only, so each
      # shared edge produces exactly one wall.
      if x == w - 1 or not layer.tiles[z * w + x + 1].exists or not t.connectedEast:
        let
          y0 = if layer.slab: b[1] else: floorY
          y1 = if layer.slab: b[3] else: floorY
        addWall(v10, v11, vec3(x1, y0, z0), vec3(x1, y1, z1), vec3(1, 0, 0), tileColors.skirt)
      else:
        let n = layer.tiles[z * w + x + 1]
        let nh = n.tops.unpack
        if h[1] != nh[0] or h[3] != nh[2]:
          # The cliff face belongs to the higher side; use its skirt color.
          let cliffColor =
            if h[1] + h[3] >= nh[0] + nh[2]: tileColors.skirt
            else: TileColorTable[min(n.kind, TileColorTable.high.uint32).int].skirt
          addWall(v10, v11, vec3(x1, nh[0], z0), vec3(x1, nh[2], z1), vec3(1, 0, 0), cliffColor)
        if layer.slab:
          let nb = n.bottoms.unpack
          if b[1] != nb[0] or b[3] != nb[2]:
            addWall(
              vec3(x1, b[1], z0), vec3(x1, b[3], z1),
              vec3(x1, nb[0], z0), vec3(x1, nb[2], z1), vec3(1, 0, 0),
              tileColors.skirt)

      # South edge.
      if z == layer.depth - 1 or not layer.tiles[(z + 1) * w + x].exists or not t.connectedSouth:
        let
          y0 = if layer.slab: b[2] else: floorY
          y1 = if layer.slab: b[3] else: floorY
        addWall(v01, v11, vec3(x0, y0, z1), vec3(x1, y1, z1), vec3(0, 0, 1), tileColors.skirt)
      else:
        let n = layer.tiles[(z + 1) * w + x]
        let nh = n.tops.unpack
        if h[2] != nh[0] or h[3] != nh[1]:
          let cliffColor =
            if h[2] + h[3] >= nh[0] + nh[1]: tileColors.skirt
            else: TileColorTable[min(n.kind, TileColorTable.high.uint32).int].skirt
          addWall(v01, v11, vec3(x0, nh[0], z1), vec3(x1, nh[1], z1), vec3(0, 0, 1), cliffColor)
        if layer.slab:
          let nb = n.bottoms.unpack
          if b[2] != nb[0] or b[3] != nb[1]:
            addWall(
              vec3(x0, b[2], z1), vec3(x1, b[3], z1),
              vec3(x0, nb[0], z1), vec3(x1, nb[1], z1), vec3(0, 0, 1),
              tileColors.skirt)

      # West and north edges only need side walls when open (the neighbor,
      # if present and connected, already emitted any mismatch wall).
      if x == 0 or not layer.tiles[z * w + x - 1].exists or
          not layer.tiles[z * w + x - 1].connectedEast:
        let
          y0 = if layer.slab: b[0] else: floorY
          y1 = if layer.slab: b[2] else: floorY
        addWall(v00, v01, vec3(x0, y0, z0), vec3(x0, y1, z1), vec3(-1, 0, 0), tileColors.skirt)
      if z == 0 or not layer.tiles[(z - 1) * w + x].exists or
          not layer.tiles[(z - 1) * w + x].connectedSouth:
        let
          y0 = if layer.slab: b[0] else: floorY
          y1 = if layer.slab: b[1] else: floorY
        addWall(v00, v10, vec3(x0, y0, z0), vec3(x1, y1, z0), vec3(0, 0, -1), tileColors.skirt)

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
      let
        x0 = (layer.originX + x).float32 - HalfGrid
        x1 = x0 + 1
        z0 = (layer.originZ + z).float32 - HalfGrid
        z1 = z0 + 1
        top = t.tops.unpack[0]
        bottom = t.bottoms.unpack[0]
        up = vec3(0, 1, 0)
      addWaterTriangle(vec3(x0, top, z0), vec3(x1, top, z0), vec3(x0, top, z1), up)
      addWaterTriangle(vec3(x1, top, z0), vec3(x1, top, z1), vec3(x0, top, z1), up)
      # Side faces on water boundaries.
      if x == w - 1 or not layer.tiles[z * w + x + 1].exists:
        addWaterTriangle(vec3(x1, top, z0), vec3(x1, top, z1), vec3(x1, bottom, z0), vec3(1, 0, 0))
        addWaterTriangle(vec3(x1, top, z1), vec3(x1, bottom, z1), vec3(x1, bottom, z0), vec3(1, 0, 0))
      if x == 0 or not layer.tiles[z * w + x - 1].exists:
        addWaterTriangle(vec3(x0, top, z0), vec3(x0, top, z1), vec3(x0, bottom, z0), vec3(-1, 0, 0))
        addWaterTriangle(vec3(x0, top, z1), vec3(x0, bottom, z1), vec3(x0, bottom, z0), vec3(-1, 0, 0))
      if z == layer.depth - 1 or not layer.tiles[(z + 1) * w + x].exists:
        addWaterTriangle(vec3(x0, top, z1), vec3(x1, top, z1), vec3(x0, bottom, z1), vec3(0, 0, 1))
        addWaterTriangle(vec3(x1, top, z1), vec3(x1, bottom, z1), vec3(x0, bottom, z1), vec3(0, 0, 1))
      if z == 0 or not layer.tiles[(z - 1) * w + x].exists:
        addWaterTriangle(vec3(x0, top, z0), vec3(x1, top, z0), vec3(x0, bottom, z0), vec3(0, 0, -1))
        addWaterTriangle(vec3(x1, top, z0), vec3(x1, bottom, z0), vec3(x0, bottom, z0), vec3(0, 0, -1))

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

  meshVertexCount = mesh.len div 10
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
  const stride = (10 * sizeof(float32)).GLsizei
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
  let colorLocation = glGetAttribLocation(treeProgram, "vertColor")
  doAssert colorLocation >= 0
  glEnableVertexAttribArray(colorLocation.GLuint)
  glVertexAttribPointer(
    colorLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
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

## Camera

var
  cameraYaw = 0.7'f32
  cameraPitch = 0.9'f32
  cameraDistance = 90.0'f32
  cameraTarget = vec3(0, 0, 0)
  rotating = false
  panning = false
  showPanel = true
  showEdges = false
  cameraEye = vec3(0, 0, 0)

proc mouseOverUi(): bool =
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

type PlaceMode = enum
  NoPlacement, PlacingStart, PlacingFinish

var
  placeMode = NoPlacement
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

## Input

proc updateCamera() =
  let overUi = mouseOverUi()

  let placingClick = placeMode != NoPlacement and
    window.buttonPressed[MouseLeft] and not overUi
  if placingClick:
    let pick = pickTile()
    if pick.hit:
      case placeMode
      of PlacingStart:
        hasStart = true
        startLayer = pick.layer
        startX = pick.x
        startZ = pick.z
        hasFinish = false
        pathPoints.setLen(0)
        pathMesh.setLen(0)
        placeMode = PlacingFinish
        pathStatus = "Click a tile to place the finish."
      of PlacingFinish:
        hasFinish = true
        finishLayer = pick.layer
        finishX = pick.x
        finishZ = pick.z
        placeMode = NoPlacement
        recomputePath()
      of NoPlacement:
        discard

  if window.buttonPressed[MouseLeft] and not overUi and not placingClick:
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
  TerrainTab, LayersTab, PathTab

var panelTab = TerrainTab

var lastParams = (frequency, amplitude, octaves, gain, lacunarity, seed,
  fortEnabled, wallHeight, slopeLimit, treeCount, grassCount,
    bridgeEnabled, waterEnabled, treesEnabled, grassEnabled,
    rocksEnabled, rockCount)

when defined(takeScreenshot):
  import pixie, std/os, std/strutils
  var screenshotFrame = 0
  # Optional camera overrides for scripted captures, e.g. CAM_YAW=3.1
  if existsEnv("CAM_YAW"): cameraYaw = getEnv("CAM_YAW").parseFloat.float32
  if existsEnv("CAM_PITCH"): cameraPitch = getEnv("CAM_PITCH").parseFloat.float32
  if existsEnv("CAM_DIST"): cameraDistance = getEnv("CAM_DIST").parseFloat.float32
  if existsEnv("CAM_X"): cameraTarget.x = getEnv("CAM_X").parseFloat.float32
  if existsEnv("CAM_Z"): cameraTarget.z = getEnv("CAM_Z").parseFloat.float32
  if existsEnv("SHOW_EDGES"): showEdges = getEnv("SHOW_EDGES") != "0"
  if existsEnv("PANEL_TAB"): panelTab = PanelTab(getEnv("PANEL_TAB").parseInt)
  if existsEnv("BRIDGE"): bridgeEnabled = getEnv("BRIDGE") != "0"
  if existsEnv("WATER"): waterEnabled = getEnv("WATER") != "0"
  if existsEnv("TREES"): treesEnabled = getEnv("TREES") != "0"
  if existsEnv("GRASS"): grassEnabled = getEnv("GRASS") != "0"
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

window.onFrame = proc() =
  updateCamera()

  let params = (frequency, amplitude, octaves, gain, lacunarity, seed,
    fortEnabled, wallHeight, slopeLimit, treeCount, grassCount,
    bridgeEnabled, waterEnabled, treesEnabled, grassEnabled,
    rocksEnabled, rockCount)
  if params != lastParams:
    lastParams = params
    rebuildTerrain()
    recomputePath()

  sk.beginUi(window, window.size)

  glClearColor(0.05, 0.06, 0.09, 1.0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glEnable(GL_DEPTH_TEST)

  glUseProgram(terrainProgram)
  mvp = cameraMvp()
  glUniformMatrix4fv(mvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
  glUniform1f(borderWidthLocation, borderWidth)
  glUniform1f(heightScaleLocation, amplitude)
  glUniform1f(edgesEnabledLocation, if showEdges: 1.0 else: 0.0)
  glBindVertexArray(vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, meshVertexCount.GLsizei)
  glBindVertexArray(0)

  # Trees.
  if treeMesh.len > 0:
    glUseProgram(treeProgram)
    glUniformMatrix4fv(treeMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
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
  glBindVertexArray(0)

  # Transparent water goes last, blended over everything opaque.
  if waterMesh.len > 0:
    glUseProgram(waterProgram)
    mvp = viewProjection
    glUniformMatrix4fv(waterMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
    glUniform3f(waterCameraLocation, cameraEye.x, cameraEye.y, cameraEye.z)
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

  ui:
    subWindow("Quad Terrain", showPanel, vec2(10, 10), vec2(310, 680)):
      group "tab row":
        box 280, 32
        layout LeftToRight
        itemSpacing 10
        radioButton "Terrain", panelTab, TerrainTab
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
      of LayersTab:
        text "display title":
          characters "Display"
        checkBox "Show edges", showEdges
        text "layers title":
          characters "Quad layers"
        checkBox "Bridge", bridgeEnabled
        checkBox "Moat water", waterEnabled
        text "props title":
          characters "Props"
        checkBox "Trees", treesEnabled
        text "trees label":
          characters &"Trees: {treeCount}"
        scrubber "treeCount", treeCount, 0, 200, ""
        checkBox "Grass puffs", grassEnabled
        text "grass label":
          characters &"Grass puffs: {grassCount}"
        scrubber "grassCount", grassCount, 0, 500, ""
        checkBox "Rocks", rocksEnabled
        text "rocks label":
          characters &"Rocks: {rockCount}"
        scrubber "rockCount", rockCount, 0, 100, ""
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
        text "help drag":
          characters "Drag: rotate"
        text "help pan":
          characters "Right/shift drag: pan"
        text "help zoom":
          characters "Scroll: zoom"

  sk.endUi()

  when defined(takeScreenshot):
    inc screenshotFrame
    if screenshotFrame == 30:
      let image = newImage(window.size.x, window.size.y)
      glReadPixels(
        0, 0, window.size.x, window.size.y,
        GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr
      )
      image.flipVertical()
      image.writeFile("quadterrain_shot.png")
      quit(0)

  window.swapBuffers()

while not window.closeRequested:
  pollEvents()
