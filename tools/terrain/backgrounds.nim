import common

proc distance(color, background: ColorRGBA): int {.raises: [].} =
  ## Measures the largest channel difference from the flat background.
  max(
    abs(color.r.int - background.r.int),
    max(
      abs(color.g.int - background.g.int),
      abs(color.b.int - background.b.int)
    )
  )

proc removeBackground*(
  image: Png,
  background = rgba(0, 0, 0, 255),
  threshold = 10
): Png {.raises: [TerrainError].} =
  ## Removes a solid matte and recovers foreground colors at soft edges.
  image.validate()
  if threshold < 0 or threshold > 254 or background.a != 255:
    raise newException(
      TerrainError,
      "Use an opaque matte and threshold from 0 to 254."
    )
  var
    visible = newSeq[bool](image.data.len)
    cores = newSeq[bool](image.data.len)
  for i, color in image.data:
    visible[i] = color.a > 0 and color.distance(background) > threshold
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let index = y * image.width + x
      if not visible[index]:
        continue
      cores[index] = true
      block neighborhood:
        for j in max(0, y - 2) .. min(image.height - 1, y + 2):
          for i in max(0, x - 2) .. min(image.width - 1, x + 2):
            if not visible[j * image.width + i]:
              cores[index] = false
              break neighborhood
  result = newPng(image.width, image.height)
  let matte = [background.r.float32, background.g.float32, background.b.float32]
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let
        index = y * image.width + x
        color = image.data[index]
      if color.a < 255 or cores[index]:
        result.data[index] = color
        continue
      if not visible[index]:
        continue
      var
        foreground: array[3, float32]
        count = 0
        strongest = color
      for j in max(0, y - 3) .. min(image.height - 1, y + 3):
        for i in max(0, x - 3) .. min(image.width - 1, x + 3):
          let
            neighbor = j * image.width + i
            sample = image.data[neighbor]
          if sample.a == 0:
            continue
          if sample.distance(background) > strongest.distance(background):
            strongest = sample
          if cores[neighbor]:
            foreground[0] += sample.r.float32
            foreground[1] += sample.g.float32
            foreground[2] += sample.b.float32
            inc count
      if count > 0:
        for i in 0 .. 2:
          foreground[i] /= count.float32
      else:
        foreground = [
          strongest.r.float32,
          strongest.g.float32,
          strongest.b.float32
        ]
      let channels = [color.r.float32, color.g.float32, color.b.float32]
      var
        numerator = 0.0'f
        denominator = 0.0'f
      for i in 0 .. 2:
        let delta = foreground[i] - matte[i]
        numerator += (channels[i] - matte[i]) * delta
        denominator += delta * delta
      let alpha = clamp(numerator / max(denominator, 1.0'f), 0.0'f, 1.0'f)
      if alpha <= 0:
        continue
      var recovered: array[3, uint8]
      for i in 0 .. 2:
        recovered[i] = toByte(matte[i] + (channels[i] - matte[i]) / alpha)
      result.data[index] = rgba(
        recovered[0],
        recovered[1],
        recovered[2],
        toByte(alpha * 255.0'f)
      )
