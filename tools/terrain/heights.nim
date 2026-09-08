import common, cuts, textures, tiles

proc stampStencil*(height, stamp: Png): Png {.raises: [TerrainError].} =
  ## Couples grayscale relief to stamp coverage for filtering and transforms.
  height.sameSize(stamp)
  result = newPng(height.width, height.height)
  for i, color in height.data:
    if color.a != 255:
      raise newException(TerrainError, "Height data must be opaque.")
    let value = ((color.r.int + color.g.int + color.b.int + 1) div 3).uint8
    result.data[i] = rgba(value, value, value, stamp.data[i].a)

proc stampHeight*(height, stamp: Png, size = TextureSize): Png
  {.raises: [TerrainError].} =
  ## Exports height filtered inside the stamp footprint without seam repair.
  result = height.stampStencil(stamp).resizeTexture(size, preserveEdges = false)
  for color in result.data.mitems:
    let value = if color.a == 0: 0'u8 else: color.r
    color = rgba(value, value, value, 255)

proc stampHeightGrid*(
  height, stamp: Png,
  columns = 1, rows = 1, size = TextureSize
): Png {.raises: [TerrainError].} =
  ## Exports each aligned stamp height independently at the final texture size.
  height.sameSize(stamp)
  validateTextureSize(size)
  discard height.gridSize(columns, rows)
  if columns > MaxPixels div size or rows > MaxPixels div size:
    raise newException(TerrainError, "Stamp height atlas is too large.")
  validateSize(columns * size, rows * size)
  let
    heightCells = height.split(columns, rows)
    stampCells = stamp.split(columns, rows)
  var outputs: seq[Png]
  for i in 0 ..< heightCells.len:
    outputs.add heightCells[i].stampHeight(stampCells[i], size)
  outputs.assemble(columns, rows)

proc heightMap*(image: Png, columns = 1, rows = 1, band = 8): Png
  {.raises: [TerrainError].} =
  ## Makes a generated height atlas strictly grayscale with periodic edges.
  image.validate()
  result = newPng(image.width, image.height)
  for i, color in image.data:
    if color.a != 255:
      raise newException(TerrainError, "Height maps must be opaque.")
    let value = ((color.r.int + color.g.int + color.b.int + 1) div 3).uint8
    result.data[i] = rgba(value, value, value, 255)
  result = result.periodicGrid(columns, rows, band)

proc heightAmount*(
  heightA, heightB, amount: float32,
  strength = 1.2'f,
  depth = 0.12'f
): float32 {.raises: [TerrainError].} =
  ## Adjusts a two-material paint weight using their local surface heights.
  if not (heightA >= 0 and heightA <= 1 and
    heightB >= 0 and heightB <= 1 and amount >= 0 and amount <= 1):
      raise newException(TerrainError, "Heights and weight must be in 0..1.")
  if not (strength >= 0 and strength < Inf and depth > 0 and depth < Inf):
    raise newException(TerrainError, "Invalid height blend strength or depth.")
  if amount == 0 or amount == 1:
    return amount
  let difference = 2 * amount - 1 + (heightB - heightA) * strength
  if difference >= depth:
    return 1
  if difference <= -depth:
    return 0
  let
    ratio = difference / depth
    weightA = 1 - max(ratio, 0)
    weightB = 1 + min(ratio, 0)
  weightB / (weightA + weightB)
