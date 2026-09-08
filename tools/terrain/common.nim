import
  std/[math, os],
  chroma, pixie/common, pixie/fileformats/png

export chroma, png

const
  MaxPixels* = 64 * 1024 * 1024
  SampleRoot* = currentSourcePath().parentDir.parentDir.parentDir /
    "tmp/terrain-samples"
  TerrainNames* = [
    "grass-1", "grass-2", "grass-3",
    "rocks-1", "rocks-2", "rocks-3",
    "path-1", "path-2", "path-3"
  ]

type
  TerrainError* = object of CatchableError

proc validateSize*(width, height: int) {.raises: [TerrainError].} =
  ## Rejects empty images and allocations beyond the pixel limit.
  if width <= 0 or height <= 0 or width > MaxPixels div height:
    raise newException(TerrainError, "Invalid or oversized image dimensions.")

proc validate*(image: Png) {.raises: [TerrainError].} =
  ## Checks dimensions and storage before accessing raw pixels.
  if image == nil:
    raise newException(TerrainError, "Image is nil.")
  validateSize(image.width, image.height)
  if image.data.len != image.width * image.height:
    raise newException(TerrainError, "Pixel count does not match dimensions.")

proc newPng*(width, height: int): Png {.raises: [TerrainError].} =
  ## Allocates straight RGBA pixels without premultiplied alpha conversion.
  validateSize(width, height)
  Png(
    width: width,
    height: height,
    channels: 4,
    data: newSeq[ColorRGBA](width * height)
  )

proc loadPng*(path: string): Png {.raises: [TerrainError].} =
  ## Decodes PNG pixels with Pixie while preserving straight RGBA values.
  try:
    let
      data = readFile(path)
      size = decodePngDimensions(data)
    validateSize(size.width, size.height)
    result = decodePng(data)
    result.validate()
  except IOError, PixieError:
    raise newException(
      TerrainError,
      "Cannot read " & path & ": " & getCurrentExceptionMsg(),
      getCurrentException()
    )

proc checkOutput*(path: string, force = false) {.raises: [TerrainError].} =
  ## Rejects existing destinations unless replacement was requested.
  if dirExists(path) or (fileExists(path) and not force):
    raise newException(
      TerrainError,
      "Output exists: " & path & ". Use --force."
    )

proc resolvedPath*(path: string): string {.raises: [TerrainError].} =
  ## Resolves a command-line path and maps filesystem failures.
  try:
    absolutePath(path)
  except OSError, ValueError:
    raise newException(TerrainError, "Cannot resolve path: " & path)

proc savePng*(
  image: Png,
  path: string,
  force = false
) {.raises: [TerrainError].} =
  ## Writes lossless straight RGBA pixels and creates the parent directory.
  image.validate()
  checkOutput(path, force)
  try:
    let directory = path.parentDir
    if directory.len > 0:
      createDir(directory)
    writeFile(path, image.encodePng())
  except IOError, OSError, PixieError:
    raise newException(
      TerrainError,
      "Cannot write " & path & ": " & getCurrentExceptionMsg(),
      getCurrentException()
    )

proc gridSize*(
  image: Png,
  columns, rows: int
): tuple[width, height: int] {.raises: [TerrainError].} =
  ## Requires equal cells without discarding partial rows or columns.
  image.validate()
  if columns <= 0 or rows <= 0 or
    image.width mod columns != 0 or image.height mod rows != 0:
      raise newException(TerrainError, "Image dimensions must divide the grid.")
  (image.width div columns, image.height div rows)

proc sameSize*(a, b: Png) {.raises: [TerrainError].} =
  ## Requires identical valid images without silently resampling either one.
  a.validate()
  b.validate()
  if a.width != b.width or a.height != b.height:
    raise newException(TerrainError, "Image dimensions do not match.")

proc toByte*(value: float32): uint8 {.raises: [].} =
  ## Rounds and clamps a finite channel value to a byte.
  round(clamp(value, 0.0'f, 255.0'f)).uint8

proc smooth*(value: float32): float32 {.raises: [].} =
  ## Returns a clamped smooth interpolation weight.
  let value = clamp(value, 0.0'f, 1.0'f)
  value * value * (3.0'f - 2.0'f * value)
