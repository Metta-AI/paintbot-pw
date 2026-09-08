import
  std/[math, os, strutils],
  jsony, pixie,
  common, heights

const
  DataRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
    "polyworld_data/terrain"
  DefaultOutput = SampleRoot / "height-blend"
  PanelWidth = 512
  PanelHeight = 256
  Pairs = [
    ["grass-2", "cobble-road-1"],
    ["dirt-road-1", "grass-1"],
    ["dirt-road-1", "gravel-road-1"],
    ["marsh-1", "grass-3"]
  ]
  FontPath = "/System/Library/Fonts/Supplemental/Arial.ttf"
  Usage = "Usage: gen_blends [outputDirectory] [strength] [depth]"

type
  MaterialBlend = enum
    LinearMaterial, HeightMaterial
  Settings = object
    strength, depth: float32
    panelWidth, panelHeight: int

proc render(
  a, b, heightA, heightB: Png,
  mode: MaterialBlend,
  settings: Settings
): Png {.raises: [TerrainError].} =
  ## Compares identical texture coordinates and paint masks for both methods.
  a.sameSize(b)
  a.sameSize(heightA)
  a.sameSize(heightB)
  result = newPng(PanelWidth, PanelHeight)
  for y in 0 ..< PanelHeight:
    let wobble = sin(y.float32 * 0.025'f) * 0.06'f +
      sin(y.float32 * 0.087'f + 1.2'f) * 0.025'f
    for x in 0 ..< PanelWidth:
      let
        index = (y mod a.height) * a.width + x mod a.width
        paint = common.smooth(
          (x.float32 / (PanelWidth - 1).float32 - 0.16'f + wobble) / 0.68'f
        )
        amount =
          case mode
          of LinearMaterial:
            paint
          of HeightMaterial:
            heightAmount(
              heightA.data[index].r.float32 / 255,
              heightB.data[index].r.float32 / 255,
              paint,
              settings.strength,
              settings.depth
            )
        left = a.data[index]
        right = b.data[index]
      result.data[y * PanelWidth + x] = rgba(
        toByte(left.r.float32 * (1 - amount) + right.r.float32 * amount),
        toByte(left.g.float32 * (1 - amount) + right.g.float32 * amount),
        toByte(left.b.float32 * (1 - amount) + right.b.float32 * amount),
        255
      )

proc label(image: Image, font: Font, value: string, x, y: int)
  {.raises: [PixieError].} =
  ## Places a readable label on a comparison preview.
  image.fillText(
    font.typeset(value, vec2(PanelWidth.float32, 30)),
    translate(vec2(x.float32, y.float32))
  )

proc generate(directory: string, settings: Settings)
  {.raises: [TerrainError, PixieError, IOError, OSError].} =
  ## Saves a labeled comparison plus individual blend strips and settings.
  createDir(directory)
  let
    font = readFont(FontPath)
    comparison = newImage(PanelWidth * 2 + 36, 48 + Pairs.len * 288)
  font.size = 18
  font.paint.color = color(0.92, 0.94, 0.96)
  comparison.fill(rgba(28, 32, 36, 255))
  comparison.label(font, "Ordinary color blend", 12, 10)
  comparison.label(font, "Height-based blend", PanelWidth + 24, 10)
  for i, names in Pairs:
    let
      a = loadPng(DataRoot / "tiles" / (names[0] & ".rgb.png"))
      b = loadPng(DataRoot / "tiles" / (names[1] & ".rgb.png"))
      heightA = loadPng(DataRoot / "tiles" / (names[0] & ".height.png"))
      heightB = loadPng(DataRoot / "tiles" / (names[1] & ".height.png"))
      title = names[0] & " + " & names[1]
      y = 44 + i * 288
    for mode in MaterialBlend:
      let
        image = render(a, b, heightA, heightB, mode, settings)
        suffix = if mode == LinearMaterial: "linear" else: "height"
        x = 12 + mode.ord * (PanelWidth + 12)
      image.savePng(
        directory / (names[0] & "-" & names[1] & "-" & suffix & ".png"),
        force = true
      )
      comparison.label(font, title, x, y)
      comparison.draw(
        image.newImage(),
        translate(vec2(x.float32, (y + 26).float32))
      )
  comparison.writeFile(directory / "comparison.png")
  writeFile(directory / "settings.json", settings.toJson() & "\n")
  echo directory / "comparison.png"

proc main() {.raises: [TerrainError].} =
  ## Reads optional output, height influence, and transition width arguments.
  let args = commandLineParams()
  if args.len == 1 and args[0] in ["--help", "-h"]:
    echo Usage
    return
  if args.len > 3:
    raise newException(TerrainError, Usage)
  try:
    let
      directory = if args.len > 0: args[0] else: DefaultOutput
      settings = Settings(
        strength: if args.len > 1: parseFloat(args[1]).float32 else: 1.2'f,
        depth: if args.len > 2: parseFloat(args[2]).float32 else: 0.12'f,
        panelWidth: PanelWidth,
        panelHeight: PanelHeight
      )
    discard heightAmount(0, 0, 0.5, settings.strength, settings.depth)
    generate(directory, settings)
  except IOError, OSError, ValueError, PixieError:
    raise newException(TerrainError, getCurrentExceptionMsg())

try:
  main()
except TerrainError as error:
  quit(error.msg, 1)
