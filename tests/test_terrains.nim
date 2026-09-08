import
  std/[os, tempfiles],
  pixie/common, pixie/images,
  ../tools/terrain/[backgrounds, common, cuts, heights, stamps, textures, tiles]

template expectTerrainError(body: untyped) =
  ## Requires malformed inputs to raise the terrain-specific exception.
  block:
    var raised = false
    try:
      body
    except TerrainError:
      raised = true
    doAssert raised

proc patterned(width, height: int): Png {.raises: [TerrainError].} =
  ## Creates distinct straight RGBA pixels with opaque and faint samples.
  result = newPng(width, height)
  for i in 0 ..< result.data.len:
    result.data[i] = rgba(
      ((i * 31 + 213) mod 256).uint8,
      ((i * 17 + 109) mod 256).uint8,
      ((i * 7 + 53) mod 256).uint8,
      [0'u8, 1, 128, 255][i mod 4]
    )

echo "Testing exact terrain cuts and straight alpha PNG round trips"
block:
  let
    source = patterned(12, 12)
    images = source.split(3, 3)
    combined = images.assemble(3, 3)
    cropped = source.crop(2, 3, 4, 5)
    directory = createTempDir("polyworld-terrain-", "")
    path = directory / "cut.png"
  try:
    doAssert images.len == 9
    doAssert combined.data == source.data
    doAssert cropped.width == 4 and cropped.height == 5
    for y in 0 ..< 5:
      for x in 0 ..< 4:
        doAssert cropped.data[y * 4 + x] == source.data[(y + 3) * 12 + x + 2]
    cropped.savePng(path)
    doAssert loadPng(path).data == cropped.data
    expectTerrainError:
      source.savePng(path)
    doAssert loadPng(path).data == cropped.data
    source.savePng(path, force = true)
    doAssert loadPng(path).data == source.data
    writeFile(directory / "bad.png", "Not an image.")
    expectTerrainError:
      discard loadPng(directory / "bad.png")
    expectTerrainError:
      discard loadPng(directory / "missing.png")
  finally:
    removeDir(directory)
  expectTerrainError:
    discard source.split(0, 3)
  expectTerrainError:
    discard source.split(5, 3)
  expectTerrainError:
    discard source.crop(int.high, 0, 1, 1)
  expectTerrainError:
    discard source.crop(-1, 0, 1, 1)
  expectTerrainError:
    discard assemble(newSeq[Png](), 1, 1)
  expectTerrainError:
    discard newPng(int.high, 2)

echo "Testing per-cell wrapped offsets and repeating previews"
block:
  let
    source = patterned(12, 12)
    shifted = source.halfOffset(3, 3)
    repeated = source.repeatImage(2, 3)
  doAssert shifted.data[0] == source.data[2 * 12 + 2]
  doAssert shifted.data[4] == source.data[2 * 12 + 6]
  doAssert shifted.halfOffset(3, 3).data == source.data
  doAssert repeated.width == 24 and repeated.height == 36
  doAssert repeated.crop(12, 24, 12, 12).data == source.data
  expectTerrainError:
    discard patterned(9, 9).halfOffset(3, 3)
  expectTerrainError:
    discard source.repeatImage(-1, 3)

echo "Testing black, gray, and white matte edge recovery"
block:
  for matte in [rgba(0, 0, 0, 255), rgba(128, 128, 128, 255),
    rgba(255, 255, 255, 255)]:
      let
        source = newPng(9, 9)
        color = rgba(200, 60, 40, 255)
      for pixel in source.data.mitems:
        pixel = matte
      for y in 2 .. 6:
        for x in 2 .. 6:
          source.data[y * 9 + x] = color
      source.data[4 * 9 + 1] = rgba(
        ((matte.r.int + color.r.int) div 2).uint8,
        ((matte.g.int + color.g.int) div 2).uint8,
        ((matte.b.int + color.b.int) div 2).uint8,
        255
      )
      source.data[0] = rgba(231, 19, 171, 1)
      source.data[1] = rgba(17, 83, 251, 0)
      let
        removed = source.removeBackground(matte)
        edge = removed.data[4 * 9 + 1]
      doAssert removed.data[8].a == 0
      doAssert removed.data[4 * 9 + 4] == color
      doAssert abs(edge.a.int - 128) <= 3
      doAssert abs(edge.r.int - color.r.int) <= 3
      doAssert abs(edge.g.int - color.g.int) <= 3
      doAssert abs(edge.b.int - color.b.int) <= 3
      doAssert removed.data[0] == source.data[0]
      doAssert removed.data[1] == source.data[1]
  expectTerrainError:
    discard newPng(2, 2).removeBackground(threshold = 255)

echo "Testing seam masks and alpha-aware repair compositing"
block:
  let
    source = patterned(16, 16)
    guide = source.seamMask(2, 2)
    api = source.seamMask(2, 2, api = true)
    changed = newPng(16, 16)
  for color in changed.data.mitems:
    color = rgba(0, 255, 0, 255)
  doAssert guide.data[0] == rgba(0, 0, 0, 255)
  doAssert guide.data[3].r == 255
  for i, color in guide.data:
    doAssert api.data[i].a == 255 - color.r
  let blended = source.blendRepair(changed, guide)
  for i, color in guide.data:
    if color.r == 0:
      doAssert blended.data[i] == source.data[i]
    elif color.r == 255:
      doAssert blended.data[i] == changed.data[i]
  let
    hidden = newPng(1, 1)
    green = newPng(1, 1)
    half = newPng(1, 1)
  hidden.data[0] = rgba(255, 0, 255, 0)
  green.data[0] = rgba(0, 255, 0, 255)
  half.data[0] = rgba(128, 128, 128, 255)
  doAssert hidden.blendRepair(green, half).data[0] == rgba(0, 255, 0, 128)
  expectTerrainError:
    discard source.blendRepair(hidden, guide)
  expectTerrainError:
    discard source.blendRepair(changed, api)

echo "Testing periodic edges, preserved interiors, and grid isolation"
block:
  let source = patterned(32, 32)
  for color in source.data.mitems:
    color.a = 255
  let
    fixed = source.periodic(4)
    stats = fixed.inspect()
  doAssert stats.horizontal == 0 and stats.vertical == 0
  doAssert stats.opaque == 32 * 32
  doAssert fixed.crop(4, 4, 24, 24).data == source.crop(4, 4, 24, 24).data
  doAssert fixed.periodic(4).data == fixed.data
  let
    other = newPng(32, 32)
    atlas = assemble([source, other], 2, 1)
  expectTerrainError:
    discard atlas.periodicGrid(2, 1)
  for color in other.data.mitems:
    color = rgba(12, 24, 48, 255)
  let
    grid = assemble([source, other], 2, 1)
    cells = grid.periodicGrid(2, 1, 4).split(2, 1)
  doAssert cells[0].data == fixed.data
  doAssert cells[1].data == other.data

echo "Testing power-of-two exports, alpha filtering, and resized tile seams"
block:
  for size in [0, -1, 3, 255, 418, int.high]:
    expectTerrainError:
      validateTextureSize(size)
  let
    exact = patterned(8, 8)
    copied = exact.resizeTexture(8)
  doAssert copied.data == exact.data
  copied.data[0] = rgba(0, 0, 0, 0)
  doAssert copied.data != exact.data
  let stamp = newPng(8, 8)
  for y in 0 ..< 8:
    for x in 0 ..< 8:
      stamp.data[y * 8 + x] =
        if x mod 2 == 0:
          rgba(0, 255, 0, 255)
        else:
          rgba(255, 0, 255, 0)
  let filtered = stamp.resizeTexture(4)
  for color in filtered.data:
    doAssert color.r == 0 and color.b == 0
    doAssert color.g == 255 and abs(color.a.int - 128) <= 1
  doAssert stamp.data[1] == rgba(255, 0, 255, 0)
  let exported = filtered.resizeTexture()
  doAssert exported.width == 256 and exported.height == 256
  doAssert exported.inspect().partial > 0
  let source = patterned(418, 418)
  for color in source.data.mitems:
    color.a = 255
  let
    seamless = source.periodic()
    resized = seamless.resizeTexture()
    stats = resized.inspect()
  doAssert stats.opaque == 256 * 256
  doAssert stats.horizontal == 0 and stats.vertical == 0
  doAssert resized.resizeTexture().data == resized.data
  let small = newPng(4, 4)
  for color in small.data.mitems:
    color = rgba(20, 60, 120, 255)
  let enlarged = small.resizeTexture(16)
  for color in enlarged.data:
    doAssert color == small.data[0]
  let odd = newPng(33, 35)
  for color in odd.data.mitems:
    color = small.data[0]
  for color in odd.resizeTexture(4).data:
    doAssert color == small.data[0]
  var cells: seq[Png]
  for i in 0 ..< 9:
    let cell = newPng(6, 6)
    for color in cell.data.mitems:
      color = rgba((i * 25).uint8, (255 - i * 25).uint8, 50, 255)
    cells.add(cell)
  let grid = cells.assemble(3, 3).resizeGrid(3, 3, 8).split(3, 3)
  for i, cell in grid:
    doAssert cell.width == 8 and cell.height == 8
    for color in cell.data:
      doAssert color == cells[i].data[0]
  expectTerrainError:
    discard small.resizeGrid(0, 1)
  expectTerrainError:
    discard small.resizeGrid(4, 4, 8192)

echo "Testing height maps and height-based material transitions"
block:
  let source = patterned(32, 32)
  for color in source.data.mitems:
    color.a = 255
  let mapped = source.heightMap()
  doAssert mapped.width == source.width and mapped.height == source.height
  for color in mapped.data:
    doAssert color.r == color.g and color.g == color.b
    doAssert color.a == 255
  doAssert mapped.inspect().horizontal == 0
  doAssert mapped.inspect().vertical == 0
  expectTerrainError:
    discard newPng(8, 8).heightMap()
  doAssert heightAmount(0.8, 0.2, 0) == 0
  doAssert heightAmount(0.2, 0.8, 1) == 1
  doAssert heightAmount(0.5, 0.5, 0.5) == 0.5
  doAssert heightAmount(0.1, 0.9, 0.5) == 1
  doAssert heightAmount(0.9, 0.1, 0.5) == 0
  var previous = 0.0'f
  for i in 0 .. 100:
    let
      amount = i.float32 / 100
      value = heightAmount(0.2, 0.8, amount)
      reverse = heightAmount(0.8, 0.2, 1 - amount)
    doAssert value >= previous and value <= 1
    doAssert abs(value + reverse - 1) < 0.00001
    previous = value
  expectTerrainError:
    discard heightAmount(0, 1, -0.1)
  expectTerrainError:
    discard heightAmount(0, 1, 0.5, depth = 0)
  expectTerrainError:
    discard heightAmount(0, 1, 0.5, strength = -1)
  expectTerrainError:
    discard heightAmount(0, 1, 0.5, strength = Inf)
  expectTerrainError:
    discard heightAmount(0, 1, 0.5, depth = NaN)
  doAssert heightAmount(0.5, 0.5, 0.5, depth = 2e38'f) == 0.5

echo "Testing stamp height filtering at transparent edges"
block:
  let
    color = newPng(8, 8)
    height = newPng(8, 8)
  for y in 0 ..< 8:
    for x in 0 ..< 8:
      let alpha = if x < 3: 255'u8 elif x == 3: 128'u8 else: 0'u8
      color.data[y * 8 + x] = rgba(40, 80, 120, alpha)
      height.data[y * 8 + x] = rgba(200, 200, 200, 255)
  let
    stencil = height.stampStencil(color)
    exported = height.stampHeight(color, 4)
    coverage = color.resizeTexture(4)
  for i, value in stencil.data:
    doAssert value.a == color.data[i].a
  for i, value in exported.data:
    doAssert value.a == 255 and value.r == value.g and value.g == value.b
    if coverage.data[i].a == 0:
      doAssert value.r == 0
    else:
      doAssert abs(value.r.int - 200) <= 2
  doAssert exported.data[0].r != exported.data[3].r
  let grid = height.stampHeightGrid(color, 2, 1, 4).split(2, 1)
  doAssert grid.len == 2
  for value in grid[0].data:
    doAssert abs(value.r.int - 200) <= 2
  for value in grid[1].data:
    doAssert value == rgba(0, 0, 0, 255)
  expectTerrainError:
    discard height.stampHeight(newPng(4, 4))
  expectTerrainError:
    discard height.stampHeight(color, 255)
  expectTerrainError:
    discard height.stampHeightGrid(color, 8, 8, 8192)
  height.data[0].a = 0
  expectTerrainError:
    discard height.stampStencil(color)

echo "Testing stamp alpha limits and accumulated surface heights"
block:
  doAssert stampAmount(0, 1, 0, 1) == 0
  doAssert stampAmount(0, 1, 1, 0) == 0
  doAssert stampAmount(1, 0, 1, 1) == 1
  for i in 0 .. 100:
    let alpha = i.float32 / 100
    doAssert stampAmount(0, 1, alpha, 0.8) <= alpha
  expectTerrainError:
    discard stampAmount(0, 1, NaN, 1)
  expectTerrainError:
    discard stampAmount(0, 1, 1, 2)
  let
    ground = newImage(2, 1)
    groundHeight = newImage(2, 1)
    brush = newImage(2, 1)
    relief = newImage(2, 1)
  ground.data = @[rgbx(0, 0, 255, 255), rgbx(0, 0, 255, 255)]
  groundHeight.data = @[rgbx(64, 64, 64, 255), rgbx(64, 64, 64, 255)]
  brush.data = @[rgbx(255, 0, 0, 255), rgbx(0, 0, 0, 0)]
  relief.data = @[rgbx(224, 224, 224, 255), rgbx(0, 0, 0, 0)]
  var surface = newStampSurface(ground, groundHeight)
  surface.compositeStamp(brush, relief, [1.0'f, 1.0'f], 0, 0)
  doAssert surface.color.data[0] == brush.data[0]
  doAssert surface.color.data[1] == ground.data[1]
  doAssert abs(surface.heights[0] - 224.0'f / 255) < 0.00001
  doAssert surface.heights[1] == 64.0'f / 255
  brush.data[0] = rgbx(0, 255, 0, 255)
  relief.data[0] = rgbx(64, 64, 64, 255)
  surface.compositeStamp(brush, relief, [0.5'f, 0.5'f], 0, 0)
  doAssert surface.color.data[0] == rgbx(255, 0, 0, 255)
  doAssert abs(surface.heights[0] - 224.0'f / 255) < 0.00001
  surface.compositeStamp(brush, relief, [1.0'f, 1.0'f], 0, 0)
  doAssert surface.color.data[0] == brush.data[0]
  doAssert surface.heights[0] == 64.0'f / 255
  doAssert ground.data[0] == rgbx(0, 0, 255, 255)
  surface.compositeStamp(brush, relief, [1.0'f, 1.0'f], -1, 0)
  doAssert surface.color.data[0] == brush.data[0]
  brush.data[0] = rgbx(128, 0, 0, 128)
  relief.data[0] = rgbx(128, 128, 128, 128)
  surface = newStampSurface(ground, groundHeight)
  surface.compositeStamp(brush, relief, [1.0'f, 1.0'f], 0, 0)
  doAssert surface.color.data[0] == rgbx(128, 0, 127, 255)
  doAssert abs(surface.heights[0] - (64.0'f / 255 * 127 + 128) / 255) < 0.00001
  surface = newStampSurface(ground, groundHeight)
  surface.compositeStamp(brush, relief, [0.5'f, 0.5'f], 0, 0, AlphaStamp)
  doAssert surface.color.data[0] == rgbx(64, 0, 191, 255)
  let before = surface.color.copy()
  expectTerrainError:
    surface.compositeStamp(brush, relief, [0.5'f, NaN], 0, 0)
  doAssert surface.color.data == before.data
  relief.data[1].a = 255
  expectTerrainError:
    surface.compositeStamp(brush, relief, [1.0'f, 1.0'f], 0, 0)
  doAssert surface.color.data == before.data
  expectTerrainError:
    discard newStampSurface(ground, newImage(1, 1))

echo "Terrain tools tests passed"
