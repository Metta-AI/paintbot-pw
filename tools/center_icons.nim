## Centers visible PNG content without scaling or resampling it.
##
## Run it from the repository root with an optional directory argument.
## The directory defaults to ../polyworld_data/icons. Pixels below AlphaThreshold are
## ignored when measuring, but are preserved when moved.

import
  std/[algorithm, os],
  pixie

const
  AlphaThreshold = 8'u8
  DefaultDirectory = "../polyworld_data/icons"

type
  PixelBounds = object
    xMin, yMin, xMax, yMax: int
    visible: bool

proc visibleBounds(image: Image): PixelBounds {.raises: [].} =
  ## Finds the bounds of pixels at or above AlphaThreshold.
  result.xMin = image.width
  result.yMin = image.height
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      if image.data[image.dataIndex(x, y)].a >= AlphaThreshold:
        result.xMin = min(result.xMin, x)
        result.yMin = min(result.yMin, y)
        result.xMax = max(result.xMax, x + 1)
        result.yMax = max(result.yMax, y + 1)
        result.visible = true

proc centerOffset(image: Image): tuple[x, y: int] {.raises: [].} =
  ## Computes the integer translation that centers visible pixel bounds.
  let bounds = image.visibleBounds
  if not bounds.visible:
    return
  let
    width = bounds.xMax - bounds.xMin
    height = bounds.yMax - bounds.yMin
  result.x = (image.width - width) div 2 - bounds.xMin
  result.y = (image.height - height) div 2 - bounds.yMin

proc shifted(
  image: Image,
  xOffset,
  yOffset: int
): Image {.raises: [PixieError].} =
  ## Translates an image without filtering and clips only outside its canvas.
  result = newImage(image.width, image.height)
  for sourceY in 0 ..< image.height:
    let targetY = sourceY + yOffset
    if targetY < 0 or targetY >= image.height:
      continue
    let
      sourceX = max(0, -xOffset)
      targetX = max(0, xOffset)
      count = min(image.width - sourceX, image.width - targetX)
    if count > 0:
      copyMem(
        result.data[result.dataIndex(targetX, targetY)].addr,
        image.data[image.dataIndex(sourceX, sourceY)].addr,
        count * sizeof(image.data[0])
      )

proc centerIcon(path: string): bool {.raises: [PixieError].} =
  ## Centers one PNG in place and returns whether it moved.
  let
    image = readImage(path)
    offset = image.centerOffset
  if offset.x == 0 and offset.y == 0:
    return false
  image.shifted(offset.x, offset.y).writeFile(path)
  echo path, ": shifted ", offset.x, ", ", offset.y
  true

let params = commandLineParams()
if params.len > 1:
  quit("Usage: center_icons [directory]", 1)

let directory =
  if params.len == 1:
    params[0]
  else:
    DefaultDirectory
if not dirExists(directory):
  quit("Icon directory does not exist: " & directory, 1)

var paths: seq[string]
for path in walkFiles(directory / "*.png"):
  paths.add(path)
paths.sort()

var moved = 0
for path in paths:
  if path.centerIcon:
    inc moved

echo "Centered ", moved, " of ", paths.len, " PNG files."
