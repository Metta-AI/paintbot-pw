import
  std/[math, os, random, strutils, times],
  jsony, pixie,
  common, heights, stamps

const
  GridSize = 64
  TextureSize = 1024
  TileSize = TextureSize div GridSize
  DefaultSeed = 20260908
  DataRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
    "polyworld_data/terrain"
  DefaultOutput = SampleRoot / "path-64-stamp-height"
  Usage = "Usage: gen_sample [outputDirectory] [seed]"
  SampleNames = [
    "grass-1", "grass-2", "grass-3",
    "gravel-road-1", "cobble-road-1", "gravel-road-1",
    "dirt-road-1", "cobble-road-1", "gravel-road-1"
  ]
  Waypoints = [
    [-5.0'f, 55.0'f], [10.0'f, 51.0'f], [23.0'f, 40.0'f],
    [28.0'f, 29.0'f], [39.0'f, 23.0'f], [53.0'f, 13.0'f],
    [65.0'f, -5.0'f]
  ]
  RockPatches = [
    [10.0'f, 13.0'f, 5.0'f, 3.4'f],
    [6.0'f, 34.0'f, 3.2'f, 5.0'f],
    [17.0'f, 44.0'f, 3.2'f, 2.3'f],
    [30.0'f, 49.0'f, 4.2'f, 3.0'f],
    [35.0'f, 12.0'f, 4.0'f, 3.0'f],
    [41.0'f, 31.0'f, 3.3'f, 2.4'f],
    [54.0'f, 27.0'f, 4.5'f, 3.5'f],
    [49.0'f, 51.0'f, 5.5'f, 4.0'f],
    [60.0'f, 56.0'f, 2.8'f, 3.4'f],
    [51.0'f, 5.0'f, 2.7'f, 2.0'f]
  ]

type
  Material = enum
    Grass, Rocks, Path
  Cell = object
    weights: array[9, float32]
    shade: float32
  Stamp = object
    source: int
    position: Vec2
    size, angle, opacity: float32
  Recipe = object
    seed: int
    gridSize, tileSize, textureSize: int
    heightStrength, blendDepth: float32
    stamps: seq[Stamp]

proc lattice(x, y, seed: int): float32 {.raises: [].} =
  ## Hashes a lattice coordinate into a deterministic unit value.
  var value = cast[uint32](x) * 0x9E3779B9'u32 xor
    cast[uint32](y) * 0x85EBCA6B'u32 xor cast[uint32](seed)
  value = (value xor (value shr 16)) * 0x7FEB352D'u32
  value = (value xor (value shr 15)) * 0x846CA68B'u32
  value = value xor (value shr 16)
  (value and 0xFFFFFF'u32).float32 / 0xFFFFFF.float32

proc noise(x, y: float32, seed: int): float32 {.raises: [].} =
  ## Interpolates a smooth spatial field without consuming random state.
  let
    ix = floor(x).int
    iy = floor(y).int
    fx = common.smooth(x - ix.float32)
    fy = common.smooth(y - iy.float32)
    a = lattice(ix, iy, seed)
    b = lattice(ix + 1, iy, seed)
    c = lattice(ix, iy + 1, seed)
    d = lattice(ix + 1, iy + 1, seed)
  (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy

proc pathPoints(): seq[Vec2] {.raises: [].} =
  ## Samples a smooth route running from the southwest to the northeast.
  for i in 0 ..< Waypoints.len - 1:
    let
      a = vec2(Waypoints[max(0, i - 1)][0], Waypoints[max(0, i - 1)][1])
      b = vec2(Waypoints[i][0], Waypoints[i][1])
      c = vec2(Waypoints[i + 1][0], Waypoints[i + 1][1])
      d = vec2(
        Waypoints[min(Waypoints.high, i + 2)][0],
        Waypoints[min(Waypoints.high, i + 2)][1]
      )
    for j in 0 ..< 24:
      let
        t = j.float32 / 24.0'f
        t2 = t * t
        t3 = t2 * t
      result.add (b * 2 + (c - a) * t +
        (a * 2 - b * 5 + c * 4 - d) * t2 +
        (-a + b * 3 - c * 3 + d) * t3) * 0.5'f
  result.add vec2(Waypoints[^1][0], Waypoints[^1][1])

proc pathDistance(point: Vec2, points: seq[Vec2]): float32 {.raises: [].} =
  ## Measures distance to the route's nearest sampled line segment.
  result = 1000
  for i in 1 ..< points.len:
    let
      start = points[i - 1]
      delta = points[i] - start
      along = clamp(dot(point - start, delta) / dot(delta, delta), 0.0'f, 1.0'f)
    result = min(result, length(point - (start + delta * along)))

proc layout(seed: int): array[GridSize * GridSize, Cell] {.raises: [].} =
  ## Assigns nine terrain weights across a 64x64 cell map.
  let points = pathPoints()
  for y in 0 ..< GridSize:
    for x in 0 ..< GridSize:
      let
        point = vec2(x.float32 + 0.5'f, y.float32 + 0.5'f)
        broad = noise(point.x * 0.1'f, point.y * 0.1'f, seed)
        detail = noise(point.x * 0.55'f, point.y * 0.55'f, seed + 31)
        distance = pathDistance(point, points)
        width = 2.7'f + broad * 1.2'f
        path = 1.0'f - common.smooth(
          (distance - width + 0.65'f + (detail - 0.5'f) * 1.3'f) / 1.7'f
        )
        center = 1.0'f - common.smooth(distance / max(width, 1.0'f))
      var rock = 0.0'f
      for patch in RockPatches:
        let
          dx = (point.x - patch[0]) / patch[2]
          dy = (point.y - patch[1]) / patch[3]
          radius = sqrt(dx * dx + dy * dy)
          coverage = 1 - common.smooth(
            (radius - 0.35'f + (detail - 0.5'f) * 0.45'f) / 0.85'f
          )
        rock = max(rock, coverage)
      rock *= (1 - path) * 0.92'f
      let
        grass = max(0.0'f, 1 - path - rock)
        lush = noise(point.x * 0.16'f + 43, point.y * 0.16'f, seed + 7)
        dry = noise(point.x * 0.19'f, point.y * 0.19'f + 21, seed + 13)
        slate = noise(point.x * 0.26'f, point.y * 0.26'f, seed + 17)
        grassMix = [0.65'f, lush * lush * 1.4'f, dry * dry * 0.55'f]
        rockMix = [0.5'f, 0.5'f + slate, 0.25'f + broad * broad]
        pathMix = [
          0.35'f + (1 - center) * 1.5'f,
          0.45'f + center * 1.5'f,
          center * broad * 1.3'f
        ]
        mixtures = [grassMix, rockMix, pathMix]
        amounts = [grass, rock, path]
      var cell: Cell
      for material in Material:
        let
          group = mixtures[material.ord]
          total = group[0] + group[1] + group[2]
        for i in 0 .. 2:
          cell.weights[material.ord * 3 + i] =
            amounts[material.ord] * group[i] / total
      cell.shade = 0.96'f + broad * 0.08'f
      result[y * GridSize + x] = cell

proc weightsAt(
  cells: array[GridSize * GridSize, Cell],
  point: Vec2
): Cell {.raises: [].} =
  ## Bilinearly blends neighboring cells for continuous material transitions.
  let
    px = clamp(point.x - 0.5'f, 0.0'f, (GridSize - 1).float32)
    py = clamp(point.y - 0.5'f, 0.0'f, (GridSize - 1).float32)
    x = px.int
    y = py.int
    fx = px - x.float32
    fy = py - y.float32
    indices = [
      y * GridSize + x,
      y * GridSize + min(x + 1, GridSize - 1),
      min(y + 1, GridSize - 1) * GridSize + x,
      min(y + 1, GridSize - 1) * GridSize + min(x + 1, GridSize - 1)
    ]
    amounts = [(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy]
  for i in 0 .. 3:
    for j in 0 .. 8:
      result.weights[j] += cells[indices[i]].weights[j] * amounts[i]
    result.shade += cells[indices[i]].shade * amounts[i]

proc renderTiles(
  images: array[9, Image],
  cells: array[GridSize * GridSize, Cell],
  blend: bool,
  shading = true
): Image {.raises: [PixieError].} =
  ## Lays 4096 tile cells, optionally blending their material weights per pixel.
  result = newImage(TextureSize, TextureSize)
  for y in 0 ..< TextureSize:
    for x in 0 ..< TextureSize:
      let
        cell =
          if blend:
            weightsAt(cells, vec2(x.float32 + 0.5'f, y.float32 + 0.5'f) /
              TileSize.float32)
          else:
            cells[(y div TileSize) * GridSize + x div TileSize]
        texel = (y mod TileSize) * TileSize + x mod TileSize
      var channels: array[3, float32]
      if blend:
        for i, weight in cell.weights:
          let color = images[i].data[texel]
          channels[0] += color.r.float32 * weight
          channels[1] += color.g.float32 * weight
          channels[2] += color.b.float32 * weight
      else:
        var selected = 0
        for i in 1 .. 8:
          if cell.weights[i] > cell.weights[selected]:
            selected = i
        let color = images[selected].data[texel]
        channels = [color.r.float32, color.g.float32, color.b.float32]
      let shade = if shading: cell.shade else: 1.0'f
      result.data[y * TextureSize + x] = rgbx(
        toByte(channels[0] * shade),
        toByte(channels[1] * shade),
        toByte(channels[2] * shade),
        255
      )

proc average(image: Image): array[3, float32] {.raises: [].} =
  ## Measures straight foreground colors from the opaque portion of an image.
  var count = 0
  for color in image.data:
    if color.a > 230:
      let straight = color.rgba()
      result[0] += straight.r.float32
      result[1] += straight.g.float32
      result[2] += straight.b.float32
      inc count
  for i in 0 .. 2:
    result[i] /= max(count, 1).float32

proc prepareStamp(stamp, tile: Image): Image {.raises: [PixieError].} =
  ## Matches the stamp palette to its tile and caches it at a practical size.
  let
    source = stamp.average()
    target = tile.average()
  result = stamp.resize(80, 80)
  for color in result.data.mitems:
    color.r = min(
      color.a,
      toByte(color.r.float32 * target[0] / max(source[0], 1))
    )
    color.g = min(
      color.a,
      toByte(color.g.float32 * target[1] / max(source[1], 1))
    )
    color.b = min(
      color.a,
      toByte(color.b.float32 * target[2] / max(source[2], 1))
    )

proc placements(
  cells: array[GridSize * GridSize, Cell],
  seed: int
): seq[Stamp] {.raises: [].} =
  ## Places varied path, rock, and grass accents with extra coverage at edges.
  var rng = initRand(seed)
  for material in [Path, Rocks, Grass]:
    let attempts =
      case material
      of Path: 2000
      of Rocks: 2300
      of Grass: 4400
    for i in 0 ..< attempts:
      let
        point = vec2(rand(rng, 64.0).float32, rand(rng, 64.0).float32)
        cell = weightsAt(cells, point)
        grass = cell.weights[0] + cell.weights[1] + cell.weights[2]
        rock = cell.weights[3] + cell.weights[4] + cell.weights[5]
        path = cell.weights[6] + cell.weights[7] + cell.weights[8]
        edge = 4 * path * (1 - path)
        probability =
          case material
          of Grass:
            let growth = noise(point.x * 0.2'f, point.y * 0.2'f, seed + 57)
            grass * (0.12'f + growth * 0.65'f) + edge * 0.85'f + rock * 0.2'f
          of Rocks: rock * 0.9'f + grass * 0.014'f
          of Path: path * 0.72'f
      if rand(rng, 1.0) > probability.float:
        continue
      let
        index =
          if material == Grass:
            let choice = rand(rng, 19)
            if choice < 13:
              0
            elif choice < 19:
              1
            else:
              2
          else:
            rand(rng, 2)
        size =
          case material
          of Grass: 19.0'f + rand(rng, 32.0).float32
          of Rocks: 22.0'f + rand(rng, 48.0).float32
          of Path: 22.0'f + rand(rng, 29.0).float32
      result.add Stamp(
        source: material.ord * 3 + index,
        position: point * TileSize.float32,
        size: size,
        angle: (rand(rng, 1.0).float32 - 0.5'f) * 0.8'f,
        opacity: 0.5'f + rand(rng, 0.35).float32
      )
  let points = pathPoints()
  for i in countup(1, points.high - 1, 2):
    let
      point = points[i]
      tangent = normalize(points[i + 1] - points[i - 1])
      normal = vec2(-tangent.y, tangent.x)
      broad = noise(point.x * 0.1'f, point.y * 0.1'f, seed)
    for side in [-1.0'f, 1.0'f]:
      let position = point + normal * side *
        (3.3'f + broad * 1.2'f + rand(rng, 0.6).float32)
      result.add Stamp(
        source: rand(rng, 1),
        position: position * TileSize.float32,
        size: 35.0'f + rand(rng, 26.0).float32,
        angle: (rand(rng, 1.0).float32 - 0.5'f) * 0.8'f,
        opacity: 0.7'f + rand(rng, 0.25).float32
      )

proc renderStamps(
  ground, groundHeight: Image,
  images, heightImages: array[9, Image],
  cells: array[GridSize * GridSize, Cell],
  recipe: Recipe,
  mode: StampBlend
): StampSurface {.raises: [PixieError, TerrainError].} =
  ## Applies identical brush transforms and paint masks with either blend mode.
  result = newStampSurface(ground, groundHeight)
  for stamp in recipe.stamps:
    let
      side = ceil(stamp.size * 1.5'f).int + 4
      patch = newImage(side, side)
      heightPatch = newImage(side, side)
      origin = vec2(
        floor(stamp.position.x - side.float32 / 2),
        floor(stamp.position.y - side.float32 / 2)
      )
      center = stamp.position - origin
      image = images[stamp.source]
      transform = translate(center) * rotate(stamp.angle) *
        scale(vec2(stamp.size / image.width.float32)) *
        translate(-vec2(image.width.float32, image.height.float32) / 2)
    patch.draw(image, transform)
    heightPatch.draw(heightImages[stamp.source], transform)
    var amounts = newSeq[float32](side * side)
    for y in 0 ..< side:
      for x in 0 ..< side:
        let index = y * side + x
        if patch.data[index].a == 0:
          continue
        let
          position = origin + vec2(x.float32 + 0.5'f, y.float32 + 0.5'f)
          cell = weightsAt(cells, position / TileSize.float32)
          path = cell.weights[6] + cell.weights[7] + cell.weights[8]
          mask =
            case Material(stamp.source div 3)
            of Grass:
              1.0'f - common.smooth((path - 0.25'f) / 0.7'f)
            of Rocks:
              1.0'f - common.smooth((path - 0.12'f) / 0.55'f)
            of Path:
              common.smooth(path / 0.6'f)
        amounts[index] = mask * stamp.opacity
    result.compositeStamp(
      patch,
      heightPatch,
      amounts,
      origin.x.int,
      origin.y.int,
      mode,
      recipe.heightStrength,
      recipe.blendDepth
    )

proc generate(directory: string, seed: int)
  {.raises: [PixieError, TerrainError, IOError, OSError].} =
  ## Saves matched alpha and height stamp bakes with the complete recipe.
  let started = cpuTime()
  createDir(directory)
  var
    tiles: array[9, Image]
    stamps: array[9, Image]
    tileHeights: array[9, Image]
    stampHeights: array[9, Image]
  for i, name in SampleNames:
    let
      tile = readImage(DataRoot / "tiles" / (name & ".rgb.png"))
      stamp = loadPng(DataRoot / "stamps" / (name & ".rgb.png"))
      height = loadPng(DataRoot / "stamps" / (name & ".height.png"))
    tiles[i] = tile.resize(TileSize, TileSize)
    stamps[i] = prepareStamp(stamp.newImage(), tile)
    tileHeights[i] = readImage(
      DataRoot / "tiles" / (name & ".height.png")
    ).resize(TileSize, TileSize)
    stampHeights[i] = height.stampStencil(stamp).newImage().resize(80, 80)
  let
    cells = layout(seed)
    tiled = renderTiles(tiles, cells, false)
    blended = renderTiles(tiles, cells, true)
    groundHeight = renderTiles(tileHeights, cells, true, shading = false)
    recipe = Recipe(
      seed: seed,
      gridSize: GridSize,
      tileSize: TileSize,
      textureSize: TextureSize,
      heightStrength: 1.2'f,
      blendDepth: 0.12'f,
      stamps: placements(cells, seed)
    )
    ordinary = renderStamps(
      blended,
      groundHeight,
      stamps,
      stampHeights,
      cells,
      recipe,
      AlphaStamp
    )
    final = renderStamps(
      blended,
      groundHeight,
      stamps,
      stampHeights,
      cells,
      recipe,
      HeightStamp
    )
    comparison = newImage(TextureSize * 2, TextureSize)
  doAssert final.color.width == 1024 and final.color.height == 1024
  doAssert final.color.isOpaque()
  tiled.writeFile(directory / "01-tiles.rgb.png")
  blended.writeFile(directory / "02-ground.rgb.png")
  groundHeight.writeFile(directory / "02-ground.height.png")
  ordinary.color.writeFile(directory / "03-alpha-stamps.rgb.png")
  final.color.writeFile(directory / "terrain.rgb.png")
  final.heightImage().writeFile(directory / "terrain.height.png")
  for i, image in [ordinary.color, final.color]:
    comparison.draw(image, translate(vec2((i * TextureSize).float32, 0)))
  comparison.writeFile(directory / "comparison.png")
  writeFile(directory / "recipe.json", recipe.toJson() & "\n")
  let elapsed = formatFloat(cpuTime() - started, ffDecimal, 3)
  echo "Rendered ", GridSize * GridSize, " cells and ", recipe.stamps.len,
    " stamps in ", elapsed, " CPU seconds."
  echo directory / "terrain.rgb.png"

proc main() {.raises: [TerrainError].} =
  ## Reads optional output and seed arguments for a reproducible sample.
  let args = commandLineParams()
  if args.len == 1 and args[0] in ["--help", "-h"]:
    echo Usage
    return
  if args.len > 2:
    raise newException(TerrainError, Usage)
  try:
    let
      directory = if args.len > 0: args[0] else: DefaultOutput
      seed = if args.len > 1: parseInt(args[1]) else: DefaultSeed
    if seed < 0 or seed > 2_147_483_000:
      raise newException(TerrainError, "Seed must be from 0 to 2147483000.")
    generate(directory, seed)
  except IOError, OSError, PixieError, ValueError:
    raise newException(TerrainError, getCurrentExceptionMsg())

try:
  main()
except TerrainError as error:
  quit(error.msg, 1)
