import common

proc crop*(
  image: Png,
  x, y, width, height: int
): Png {.raises: [TerrainError].} =
  ## Copies a rectangle exactly, including RGB values under transparency.
  image.validate()
  validateSize(width, height)
  if x < 0 or y < 0 or
    width > image.width or height > image.height or
    x > image.width - width or y > image.height - height:
      raise newException(TerrainError, "Crop rectangle is outside the image.")
  result = newPng(width, height)
  for j in 0 ..< height:
    for i in 0 ..< width:
      result.data[j * width + i] = image.data[(y + j) * image.width + x + i]

proc split*(image: Png, columns, rows: int): seq[Png]
  {.raises: [TerrainError].} =
  ## Cuts equal grid cells in row order without filtering or trimming.
  let size = image.gridSize(columns, rows)
  for y in 0 ..< rows:
    for x in 0 ..< columns:
      result.add image.crop(
        x * size.width,
        y * size.height,
        size.width,
        size.height
      )

proc assemble*(images: openArray[Png], columns, rows: int): Png
  {.raises: [TerrainError].} =
  ## Combines equal cells without spacing or changes to their pixels.
  if columns <= 0 or rows <= 0 or
    columns > images.len div rows or columns * rows != images.len:
      raise newException(TerrainError, "Image count does not match the grid.")
  images[0].validate()
  let
    width = images[0].width
    height = images[0].height
  if columns > MaxPixels div width or rows > MaxPixels div height:
    raise newException(TerrainError, "Combined image is too large.")
  result = newPng(width * columns, height * rows)
  for i, image in images:
    image.sameSize(images[0])
    for y in 0 ..< height:
      for x in 0 ..< width:
        let target =
          ((i div columns) * height + y) * result.width +
          (i mod columns) * width + x
        result.data[target] = image.data[y * width + x]
