import
  pixie/common, pixie/images,
  common, cuts, tiles

const TextureSize* = 256

proc validateTextureSize*(size: int) {.raises: [TerrainError].} =
  ## Requires a supported square power-of-two texture size.
  if size < 4 or (size and (size - 1)) != 0:
    raise newException(
      TerrainError,
      "Texture size must be a power of two >= 4."
    )
  validateSize(size, size)

proc minifyClamped(image: Image): Image {.raises: [PixieError].} =
  ## Halves with Pixie while extending odd edges instead of adding transparency.
  result = image.minifyBy2()
  if image.width mod 2 != 0:
    for y in 0 ..< result.height:
      result.data[y * result.width + result.width - 1] = image.getRgbaSmooth(
        (image.width - 1).float32,
        min(y.float32 * 2 + 0.5'f, (image.height - 1).float32)
      )
  if image.height mod 2 != 0:
    for x in 0 ..< result.width:
      result.data[(result.height - 1) * result.width + x] =
        image.getRgbaSmooth(
          min(x.float32 * 2 + 0.5'f, (image.width - 1).float32),
          (image.height - 1).float32
        )

proc resizeTexture*(
  image: Png, size = TextureSize, preserveEdges = true
): Png {.raises: [TerrainError].} =
  ## Resamples RGBA with Pixie and preserves already matching tile edges.
  image.validate()
  validateTextureSize(size)
  if image.width == size and image.height == size:
    return image.crop(0, 0, size, size)
  let stats = image.inspect()
  try:
    var source = image.newImage()
    while source.width >= size * 2 and source.height >= size * 2:
      source = source.minifyClamped()
    result = newPng(size, size)
    for y in 0 ..< size:
      let sy = clamp(
        (y.float32 + 0.5'f) * source.height.float32 / size.float32 - 0.5'f,
        0.0'f,
        (source.height - 1).float32
      )
      for x in 0 ..< size:
        let sx = clamp(
          (x.float32 + 0.5'f) * source.width.float32 / size.float32 - 0.5'f,
          0.0'f,
          (source.width - 1).float32
        )
        result.data[y * size + x] = source.getRgbaSmooth(sx, sy).rgba()
  except PixieError as error:
    raise newException(
      TerrainError,
      "Cannot resize texture: " & error.msg,
      error
    )
  if preserveEdges and stats.opaque == image.data.len and
    stats.horizontal == 0 and stats.vertical == 0:
      result = result.periodic(min(24, max(2, size div 16)))

proc resizeGrid*(image: Png, columns = 1, rows = 1, size = TextureSize): Png
  {.raises: [TerrainError].} =
  ## Resizes each cell independently so atlas neighbors never bleed together.
  validateTextureSize(size)
  discard image.gridSize(columns, rows)
  if columns > MaxPixels div size or rows > MaxPixels div size:
    raise newException(TerrainError, "Resized atlas is too large.")
  validateSize(columns * size, rows * size)
  var images = image.split(columns, rows)
  for image in images.mitems:
    image = image.resizeTexture(size)
  images.assemble(columns, rows)
