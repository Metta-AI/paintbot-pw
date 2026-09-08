import
  std/os,
  pixie,
  common, heights, stamps

const
  DataRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
    "polyworld_data/terrain"
  OutputRoot = SampleRoot / "stamp-blends"
  Groups = [
    ["grass-1", "grass-2", "grass-3"],
    ["dirt-road-1", "cobble-road-1", "gravel-road-1"],
    ["forest-floor-1", "marsh-1", "grass-4"]
  ]
  Grounds = ["dirt-road-1", "grass-2", "grass-1"]
  PanelWidth = 768
  PanelHeight = 256
  RowHeight = 290
  Margin = 12
  PaintAmount = 0.62'f
  FontPath = "/System/Library/Fonts/Supplemental/Arial.ttf"

proc row(group: array[3, string], ground: string, mode: StampBlend): Image
  {.raises: [TerrainError, PixieError].} =
  ## Compares all three stamp variants over the same color and height ground.
  let
    tile = readImage(DataRoot / "tiles" / (ground & ".rgb.png"))
    tileHeight = readImage(DataRoot / "tiles" / (ground & ".height.png"))
    color = newImage(PanelWidth, PanelHeight)
    height = newImage(PanelWidth, PanelHeight)
  for i in 0 ..< 3:
    let transform = translate(vec2((i * 256).float32, 0))
    color.draw(tile, transform)
    height.draw(tileHeight, transform)
  var surface = newStampSurface(color, height)
  for i in 0 ..< 3:
    let
      name = group[i]
      stamp = loadPng(DataRoot / "stamps" / (name & ".rgb.png"))
      relief = loadPng(DataRoot / "stamps" / (name & ".height.png"))
      stencil = relief.stampStencil(stamp).newImage()
      patch = newImage(256, 256)
      heightPatch = newImage(256, 256)
      transform = translate(vec2(128, 128)) *
        rotate((i - 1).float32 * 0.14'f) * scale(vec2(0.87'f)) *
        translate(-vec2(128, 128))
    patch.draw(stamp.newImage(), transform)
    heightPatch.draw(stencil, transform)
    var amounts = newSeq[float32](256 * 256)
    for amount in amounts.mitems:
      amount = PaintAmount
    surface.compositeStamp(patch, heightPatch, amounts, i * 256, 0, mode)
  surface.color

proc generate() {.raises: [TerrainError, PixieError, IOError, OSError].} =
  ## Saves a labeled comparison of all nine alpha and height stamp blends.
  createDir(OutputRoot)
  let
    comparison = newImage(
      PanelWidth * 2 + Margin * 3,
      44 + RowHeight * Groups.len
    )
    font = readFont(FontPath)
  comparison.fill(rgba(28, 32, 36, 255))
  font.size = 19
  font.paint.color = color(0.94, 0.95, 0.96)
  for mode in StampBlend:
    let
      x = Margin + mode.ord * (PanelWidth + Margin)
      title =
        case mode
        of AlphaStamp:
          "Alpha stamps"
        of HeightStamp:
          "Height-blended stamps"
    comparison.fillText(font.typeset(title), translate(vec2(x.float32, 10)))
    for i, group in Groups:
      let
        y = 44 + i * RowHeight
        preview = row(group, Grounds[i], mode)
        label = group[0] & " / " & group[1] & " / " & group[2]
        suffix = if mode == AlphaStamp: "alpha" else: "height-blended"
      comparison.fillText(
        font.typeset(label),
        translate(vec2(x.float32, y.float32))
      )
      comparison.draw(preview, translate(vec2(x.float32, (y + 28).float32)))
      preview.writeFile(
        OutputRoot / ("group-" & $(i + 1) & "-" & suffix & ".rgb.png")
      )
  comparison.writeFile(OutputRoot / "comparison.png")
  comparison.subImage(0, 0, comparison.width, 44 + RowHeight * 2).writeFile(
    OutputRoot / "grass-roads-comparison.png"
  )
  echo OutputRoot / "comparison.png"

try:
  generate()
except TerrainError, PixieError, IOError, OSError:
  quit(getCurrentExceptionMsg(), 1)
