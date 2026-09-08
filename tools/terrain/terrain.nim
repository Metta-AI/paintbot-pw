import
  std/[os, strutils],
  backgrounds, common, cuts, heights, textures, tiles

const Usage = """Terrain PNG tools using Nim and Pixie.
  cut input directory [columns rows [prefix]]
  crop input output x y width height
  resize input output [columns rows]
  background input output [black|gray|white|RRGGBB [threshold]]
  offset input output [columns rows]
  mask input guideOutput apiOutput [columns rows]
  blend source repaired guideMask output
  tile input output [columns rows [band]]
  height input output [columns rows [band]]
  stamp-height generated stampColor output [columns rows]
  repeat input output [columns rows]
  inspect input [columns rows]
  check input [columns rows]

cut defaults to 3x3, named grass-1..3, rocks-1..3, path-1..3.
Other grids use tile-N names unless a filename prefix is supplied.
offset, mask, tile, height, inspect, and check default to one texture.
cut and resize export 256x256 cells by default.
stamp-height exports 256x256 height cells using the original stamp alpha.
cut writes .rgb.png files; use --channel height for .height.png files.
Use --size N for another power of two (at least 4), also for check.
Resizing preserves stamp alpha and restores already matching tile edges.
Crops, backgrounds, masks, offsets, blends, and tile repair stay unscaled.
height prepares an AI-generated height atlas at full source resolution.
repeat defaults to 3x3 repeats.
check requires the target size, opacity, and matching opposite edges.
Outputs must be new unless --force is supplied.
"""

type TextureChannel = enum
  RgbChannel, HeightChannel

proc textureChannel(value: string): TextureChannel {.raises: [TerrainError].} =
  ## Parses the filename channel for exported atlas cells.
  case value
  of "rgb":
    RgbChannel
  of "height":
    HeightChannel
  else:
    raise newException(TerrainError, "Channel must be rgb or height.")

proc number(value: string): int {.raises: [TerrainError].} =
  ## Maps invalid command-line integers to the terrain error type.
  try:
    parseInt(value)
  except ValueError as error:
    raise newException(TerrainError, "Invalid integer: " & value, error)

proc backgroundColor(value: string): ColorRGBA {.raises: [TerrainError].} =
  ## Parses a named neutral background or an opaque hexadecimal color.
  case value.toLowerAscii()
  of "black":
    return rgba(0, 0, 0, 255)
  of "gray", "grey":
    return rgba(128, 128, 128, 255)
  of "white":
    return rgba(255, 255, 255, 255)
  else:
    discard
  let hex =
    if value.startsWith("#"):
      value[1 .. ^1]
    else:
      value
  if hex.len != 6:
    raise newException(TerrainError, "Background must be a name or RRGGBB.")
  for c in hex:
    if c notin HexDigits:
      raise newException(TerrainError, "Invalid background color: " & value)
  try:
    let color = parseHexInt(hex)
    rgba(
      ((color shr 16) and 255).uint8,
      ((color shr 8) and 255).uint8,
      (color and 255).uint8,
      255
    )
  except ValueError as error:
    raise newException(
      TerrainError,
      "Invalid background color: " & value,
      error
    )

proc requireCount(args: seq[string], counts: openArray[int])
  {.raises: [TerrainError].} =
  ## Rejects missing and unused command arguments.
  if args.len notin counts:
    raise newException(TerrainError, Usage)

proc cutFiles(
  args: seq[string], force: bool, size: int, channel: TextureChannel
) {.raises: [TerrainError].} =
  ## Preflights every destination before saving independent atlas cells.
  args.requireCount([3, 5, 6])
  let
    columns = if args.len >= 5: number(args[3]) else: 3
    rows = if args.len >= 5: number(args[4]) else: 3
    images = loadPng(args[1]).split(columns, rows)
    prefix = if args.len == 6: args[5] else: "tile"
    suffix =
      case channel
      of RgbChannel:
        ".rgb.png"
      of HeightChannel:
        ".height.png"
  if prefix.len == 0 or '/' in prefix or '\\' in prefix:
    raise newException(TerrainError, "Prefix must be a filename, not a path.")
  var paths: seq[string]
  for i in 0 ..< images.len:
    let name =
      if columns == 3 and rows == 3 and args.len < 6:
        TerrainNames[i]
      else:
        prefix & "-" & $(i + 1)
    let path = args[2] / (name & suffix)
    checkOutput(path, force)
    paths.add(path)
  for i, image in images:
    image.resizeTexture(size).savePng(paths[i], force)
    echo paths[i], " (", size, "x", size, ")"

proc main() {.raises: [TerrainError].} =
  ## Dispatches terrain preprocessing commands over explicit pixel buffers.
  var
    args: seq[string]
    force = false
    size = TextureSize
    sizeSpecified = false
    needsSize = false
    channel = RgbChannel
    channelSpecified = false
    needsChannel = false
  for value in commandLineParams():
    if needsSize:
      size = number(value)
      validateTextureSize(size)
      needsSize = false
    elif needsChannel:
      channel = textureChannel(value)
      needsChannel = false
    elif value == "--size":
      if sizeSpecified:
        raise newException(TerrainError, "Supply --size only once.")
      sizeSpecified = true
      needsSize = true
    elif value == "--channel":
      if channelSpecified:
        raise newException(TerrainError, "Supply --channel only once.")
      channelSpecified = true
      needsChannel = true
    elif value == "--force":
      force = true
    else:
      args.add(value)
  if needsSize:
    raise newException(TerrainError, "Missing value after --size.")
  if needsChannel:
    raise newException(TerrainError, "Missing value after --channel.")
  if args.len == 0 or args[0] in ["help", "--help", "-h"]:
    echo Usage
    return
  if sizeSpecified and args[0] notin ["cut", "resize", "stamp-height", "check"]:
    raise newException(
      TerrainError,
      "--size applies only to cut, resize, stamp-height, and check."
    )
  if channelSpecified and args[0] != "cut":
    raise newException(TerrainError, "--channel applies only to cut.")
  case args[0]
  of "cut":
    cutFiles(args, force, size, channel)
  of "stamp-height":
    args.requireCount([4, 6])
    let
      columns = if args.len == 6: number(args[4]) else: 1
      rows = if args.len == 6: number(args[5]) else: 1
      image = stampHeightGrid(
        loadPng(args[1]), loadPng(args[2]), columns, rows, size
      )
    image.savePng(args[3], force)
  of "crop":
    args.requireCount([7])
    let image = loadPng(args[1]).crop(
      number(args[3]),
      number(args[4]),
      number(args[5]),
      number(args[6])
    )
    image.savePng(args[2], force)
  of "background":
    args.requireCount([3, 4, 5])
    let
      matte =
        if args.len >= 4:
          backgroundColor(args[3])
        else:
          rgba(0, 0, 0, 255)
      threshold = if args.len == 5: number(args[4]) else: 10
      image = loadPng(args[1]).removeBackground(matte, threshold)
    image.savePng(args[2], force)
  of "offset", "tile", "height", "repeat", "resize":
    if args[0] in ["tile", "height"]:
      args.requireCount([3, 5, 6])
    else:
      args.requireCount([3, 5])
    let
      defaultCount = if args[0] == "repeat": 3 else: 1
      columns = if args.len >= 5: number(args[3]) else: defaultCount
      rows = if args.len >= 5: number(args[4]) else: defaultCount
      source = loadPng(args[1])
    let image =
      case args[0]
      of "offset":
        source.halfOffset(columns, rows)
      of "tile":
        let band = if args.len == 6: number(args[5]) else: 24
        source.periodicGrid(columns, rows, band)
      of "height":
        let band = if args.len == 6: number(args[5]) else: 8
        source.heightMap(columns, rows, band)
      of "resize":
        source.resizeGrid(columns, rows, size)
      else:
        source.repeatImage(columns, rows)
    image.savePng(args[2], force)
  of "mask":
    args.requireCount([4, 6])
    let
      source = loadPng(args[1])
      columns = if args.len == 6: number(args[4]) else: 1
      rows = if args.len == 6: number(args[5]) else: 1
      guide = source.seamMask(columns, rows)
      api = source.seamMask(columns, rows, api = true)
    if resolvedPath(args[2]) == resolvedPath(args[3]):
      raise newException(
        TerrainError,
        "Guide and API masks need separate files."
      )
    checkOutput(args[2], force)
    checkOutput(args[3], force)
    guide.savePng(args[2], force)
    api.savePng(args[3], force)
  of "blend":
    args.requireCount([5])
    let image = blendRepair(
      loadPng(args[1]),
      loadPng(args[2]),
      loadPng(args[3])
    )
    image.savePng(args[4], force)
  of "inspect", "check":
    args.requireCount([2, 4])
    let
      columns = if args.len == 4: number(args[2]) else: 1
      rows = if args.len == 4: number(args[3]) else: 1
      images = loadPng(args[1]).split(columns, rows)
    for i, image in images:
      let stats = image.inspect()
      echo "Cell ", i + 1, ": ", image.width, "x", image.height, " ", stats
      if args[0] == "check" and
        (image.width != size or image.height != size or
        stats.horizontal != 0 or stats.vertical != 0 or
        stats.transparent != 0 or stats.partial != 0):
          raise newException(
            TerrainError,
            "Cell must be " & $size & "x" & $size &
              ", opaque, and edge-matched."
          )
  else:
    raise newException(TerrainError, "Unknown terrain command: " & args[0])

try:
  main()
except TerrainError as error:
  quit(error.msg, 1)
