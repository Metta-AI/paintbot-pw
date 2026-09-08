import
  pixie/common, pixie/images,
  common, heights

type
  StampBlend* = enum
    AlphaStamp, HeightStamp
  StampSurface* = object
    color*: Image
    heights*: seq[float32]

proc newStampSurface*(color, height: Image): StampSurface
  {.raises: [TerrainError].} =
  ## Copies an opaque color canvas and its aligned grayscale surface heights.
  if color == nil or height == nil:
    raise newException(TerrainError, "Stamp surface images are missing.")
  validateSize(color.width, color.height)
  if color.width != height.width or color.height != height.height or
    color.data.len != color.width * color.height or
    height.data.len != color.data.len:
      raise newException(TerrainError, "Stamp surface dimensions differ.")
  result.color = color.copy()
  result.heights = newSeq[float32](color.data.len)
  for i, value in height.data:
    if color.data[i].a != 255 or value.a != 255 or
      value.r != value.g or value.g != value.b:
        raise newException(
          TerrainError,
          "Surface needs opaque color and height."
        )
    result.heights[i] = value.r.float32 / 255

proc stampAmount*(
  baseHeight, brushHeight, alpha, amount: float32,
  strength = 1.2'f, depth = 0.12'f
): float32 {.raises: [TerrainError].} =
  ## Uses height to adjust paint coverage while retaining the alpha silhouette.
  if not (alpha >= 0 and alpha <= 1 and amount >= 0 and amount <= 1):
    raise newException(TerrainError, "Stamp alpha and amount must be in 0..1.")
  min(alpha, heightAmount(
    baseHeight,
    brushHeight,
    alpha * amount,
    strength,
    depth
  ))

proc compositeStamp*(
  surface: var StampSurface,
  color, height: Image,
  amounts: openArray[float32],
  x, y: int,
  mode = HeightStamp,
  strength = 1.2'f, depth = 0.12'f
) {.raises: [TerrainError].} =
  ## Composites a transformed brush and updates color and height together.
  if surface.color == nil or color == nil or height == nil:
    raise newException(TerrainError, "Stamp images are missing.")
  validateSize(color.width, color.height)
  if color.width != height.width or color.height != height.height or
    color.data.len != color.width * color.height or
    height.data.len != color.data.len or amounts.len != color.data.len or
    surface.heights.len != surface.color.data.len:
      raise newException(TerrainError, "Stamp buffers have different sizes.")
  discard heightAmount(0, 0, 0, strength, depth)
  for i, value in color.data:
    if not (amounts[i] >= 0 and amounts[i] <= 1):
      raise newException(TerrainError, "Stamp paint amount must be in 0..1.")
    if value.a != height.data[i].a:
      raise newException(TerrainError, "Color and height coverage differ.")
  for py in 0 ..< color.height:
    let dy = y + py
    if dy < 0 or dy >= surface.color.height:
      continue
    for px in 0 ..< color.width:
      let dx = x + px
      if dx < 0 or dx >= surface.color.width:
        continue
      let
        source = py * color.width + px
        pixel = color.data[source]
      if pixel.a == 0 or amounts[source] == 0:
        continue
      let
        destination = dy * surface.color.width + dx
        alpha = pixel.a.float32 / 255
        brushHeight = height.data[source].r.float32 /
          height.data[source].a.float32
        baseHeight = surface.heights[destination]
        amount =
          case mode
          of AlphaStamp:
            alpha * amounts[source]
          of HeightStamp:
            stampAmount(
              baseHeight,
              brushHeight,
              alpha,
              amounts[source],
              strength,
              depth
            )
        base = surface.color.data[destination]
      surface.color.data[destination] = rgbx(
        toByte(
          base.r.float32 * (1 - amount) + pixel.r.float32 / alpha * amount
        ),
        toByte(
          base.g.float32 * (1 - amount) + pixel.g.float32 / alpha * amount
        ),
        toByte(
          base.b.float32 * (1 - amount) + pixel.b.float32 / alpha * amount
        ),
        255
      )
      surface.heights[destination] =
        baseHeight * (1 - amount) + brushHeight * amount

proc heightImage*(surface: StampSurface): Image {.raises: [PixieError].} =
  ## Encodes the current height buffer for inspection or a later bake stage.
  result = newImage(surface.color.width, surface.color.height)
  for i, height in surface.heights:
    let value = toByte(height * 255)
    result.data[i] = rgbx(value, value, value, 255)
