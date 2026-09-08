import common, cuts

type
  TileStats* = object
    transparent*, partial*, opaque*: int
    horizontal*, vertical*: int

proc halfOffset*(image: Png, columns = 1, rows = 1): Png
  {.raises: [TerrainError].} =
  ## Wraps each cell by half its size without moving pixels between cells.
  let size = image.gridSize(columns, rows)
  if size.width mod 2 != 0 or size.height mod 2 != 0:
    raise newException(
      TerrainError,
      "Half-offset requires even cell dimensions."
    )
  result = newPng(image.width, image.height)
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let
        sourceX = (x div size.width) * size.width +
          (x mod size.width + size.width div 2) mod size.width
        sourceY = (y div size.height) * size.height +
          (y mod size.height + size.height div 2) mod size.height
      result.data[y * image.width + x] =
        image.data[sourceY * image.width + sourceX]

proc seamMask*(
  image: Png,
  columns = 1,
  rows = 1,
  inner = 0.07'f,
  outer = 0.16'f,
  api = false
): Png {.raises: [TerrainError].} =
  ## Marks each cell's center cross for repair with feathered strip edges.
  let size = image.gridSize(columns, rows)
  if not (inner >= 0 and inner < outer and outer < 0.5'f):
    raise newException(
      TerrainError,
      "Mask widths must satisfy 0 <= inner < outer < 0.5."
    )
  result = newPng(image.width, image.height)
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let
        dx = abs((x mod size.width).float32 - (size.width - 1).float32 / 2) /
          size.width.float32
        dy = abs((y mod size.height).float32 - (size.height - 1).float32 / 2) /
          size.height.float32
        weight = 1.0'f - smooth((min(dx, dy) - inner) / (outer - inner))
        value = toByte(weight * 255.0'f)
      result.data[y * image.width + x] =
        if api:
          rgba(255, 255, 255, 255 - value)
        else:
          rgba(value, value, value, 255)

proc blendRepair*(source, repaired, mask: Png): Png
  {.raises: [TerrainError].} =
  ## Applies a grayscale repair mask with interpolation in premultiplied space.
  source.sameSize(repaired)
  source.sameSize(mask)
  for color in mask.data:
    if color.r != color.g or color.r != color.b or color.a != 255:
      raise newException(TerrainError, "Use an opaque grayscale guide mask.")
  result = newPng(source.width, source.height)
  for i, a in source.data:
    let
      b = repaired.data[i]
      amount = mask.data[i].r
    if amount == 0:
      result.data[i] = a
      continue
    if amount == 255:
      result.data[i] = b
      continue
    let
      weight = amount.float32 / 255.0'f
      left = a.a.float32 * (1.0'f - weight)
      right = b.a.float32 * weight
      alpha = left + right
    if alpha > 0:
      result.data[i] = rgba(
        toByte((a.r.float32 * left + b.r.float32 * right) / alpha),
        toByte((a.g.float32 * left + b.g.float32 * right) / alpha),
        toByte((a.b.float32 * left + b.b.float32 * right) / alpha),
        toByte(alpha)
      )

proc periodic*(image: Png, band = 24): Png {.raises: [TerrainError].} =
  ## Matches opposite boundary colors with a smooth correction inside each edge.
  image.validate()
  let width = min(band, min(image.width, image.height) div 2)
  if width < 2:
    raise newException(
      TerrainError,
      "Periodic correction needs a band of at least 2."
    )
  var colors = newSeq[array[3, float32]](image.data.len)
  for i, color in image.data:
    if color.a != 255:
      raise newException(
        TerrainError,
        "Periodic correction requires opaque tiles."
      )
    colors[i] = [color.r.float32, color.g.float32, color.b.float32]
  for y in 0 ..< image.height:
    let
      start = y * image.width
      left = colors[start]
      right = colors[start + image.width - 1]
    for x in 0 ..< width:
      let weight = 1.0'f - smooth(x.float32 / (width - 1).float32)
      for i in 0 .. 2:
        let target = (left[i] + right[i]) / 2
        colors[start + x][i] += (target - left[i]) * weight
        colors[start + image.width - 1 - x][i] += (target - right[i]) * weight
  for x in 0 ..< image.width:
    let
      top = colors[x]
      bottom = colors[(image.height - 1) * image.width + x]
    for y in 0 ..< width:
      let weight = 1.0'f - smooth(y.float32 / (width - 1).float32)
      for i in 0 .. 2:
        let target = (top[i] + bottom[i]) / 2
        colors[y * image.width + x][i] += (target - top[i]) * weight
        colors[(image.height - 1 - y) * image.width + x][i] +=
          (target - bottom[i]) * weight
  result = newPng(image.width, image.height)
  for i, color in colors:
    result.data[i] = rgba(
      toByte(color[0]),
      toByte(color[1]),
      toByte(color[2]),
      255
    )
  for y in 0 ..< image.height:
    let
      left = y * image.width
      right = left + image.width - 1
      a = result.data[left]
      b = result.data[right]
      color = rgba(
        ((a.r.int + b.r.int) div 2).uint8,
        ((a.g.int + b.g.int) div 2).uint8,
        ((a.b.int + b.b.int) div 2).uint8,
        255
      )
    result.data[left] = color
    result.data[right] = color
  for x in 0 ..< image.width:
    let
      bottom = (image.height - 1) * image.width + x
      a = result.data[x]
      b = result.data[bottom]
      color = rgba(
        ((a.r.int + b.r.int) div 2).uint8,
        ((a.g.int + b.g.int) div 2).uint8,
        ((a.b.int + b.b.int) div 2).uint8,
        255
      )
    result.data[x] = color
    result.data[bottom] = color

proc periodicGrid*(image: Png, columns = 1, rows = 1, band = 24): Png
  {.raises: [TerrainError].} =
  ## Applies edge correction independently to every atlas cell.
  var images = image.split(columns, rows)
  for image in images.mitems:
    image = image.periodic(band)
  images.assemble(columns, rows)

proc repeatImage*(image: Png, columns = 3, rows = 3): Png
  {.raises: [TerrainError].} =
  ## Builds an unfiltered repeating preview of one texture.
  image.validate()
  if columns <= 0 or rows <= 0 or
    columns > MaxPixels div image.width or rows > MaxPixels div image.height:
      raise newException(TerrainError, "Invalid repeat counts.")
  result = newPng(image.width * columns, image.height * rows)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      result.data[y * result.width + x] =
        image.data[(y mod image.height) * image.width + x mod image.width]

proc inspect*(image: Png): TileStats {.raises: [TerrainError].} =
  ## Counts alpha coverage and pixels that differ at opposite boundaries.
  image.validate()
  for color in image.data:
    case color.a
    of 0:
      inc result.transparent
    of 255:
      inc result.opaque
    else:
      inc result.partial
  for y in 0 ..< image.height:
    let start = y * image.width
    if image.data[start] != image.data[start + image.width - 1]:
      inc result.horizontal
  for x in 0 ..< image.width:
    if image.data[x] != image.data[(image.height - 1) * image.width + x]:
      inc result.vertical
