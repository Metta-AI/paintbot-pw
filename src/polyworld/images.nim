import pixie, pixie/fileformats/png

proc loadTexturePng*(path: string): Image {.raises: [IOError, PixieError].} =
  ## Loads PNG textures without losing RGB behind transparent pixels.
  let decoded = decodePng(readFile(path))
  result = newImage(decoded.width, decoded.height)
  if decoded.data.len != result.data.len:
    raise newException(PixieError, "Expected an eight-bit PNG texture")
  copyMem(result.data[0].addr, decoded.data[0].addr, decoded.data.len * 4)
