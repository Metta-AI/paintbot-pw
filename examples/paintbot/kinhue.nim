## FFA-kin viewer colours: one hue per family, read from the genomes, so siblings share a hue and
## cousin families sit next to each other on the colour wheel. Loners have no hue (grey).
## Viewer-only; nothing here touches World or its hash.
import std/[math, algorithm]
import kinship

const
  LonerHue* = -1'f32
  KinSaturation* = 80'f32 ## HSL percent; viewer.js/kinhud.js use the same hsl(h, 80%, 58%).
  KinLightness* = 58'f32
  # Fixed ±1 projection axes over the 32 loci (bits of two constants).
  ProjX = 0x9E3779B9'u32
  ProjY = 0x7F4A7C15'u32
  ClanSpread = 0.5 ## Families in one clan spread over this fraction of the clan's hue slot.

proc axis(mask: uint32, locus: int): float = (if (mask shr locus and 1) == 1: 1.0 else: -1.0)

proc angle(v: array[Loci, float]): float =
  ## Projects a mean ±1 genome onto the two fixed axes; degrees in [0, 360).
  var x, y: float
  for l in 0..<Loci:
    x += axis(ProjX, l)*v[l]
    y += axis(ProjY, l)*v[l]
  result = radToDeg(arctan2(y, x))
  if result < 0: result += 360

proc familyHues*(k: Kinship): array[KinSeats, float32] =
  ## Hue in degrees per seat, or LonerHue. Families linked by descent (cousins) form a clan;
  ## clans get evenly spaced hue slots in the circular order of their projected genomes, and a
  ## clan's families share its slot, so hues stay distinct and cousins stay adjacent.
  for i in 0..<KinSeats: result[i] = LonerHue
  var families: seq[int]
  for i in 0..<KinSeats:
    let f = k.family[i].int
    if f >= 0 and f notin families: families.add f
  if families.len == 0: return
  families.sort()
  # Mean ±1 genome per family: loci inherited by descent average to ±1, chance loci shrink.
  var vec = newSeq[array[Loci, float]](families.len)
  var members = newSeq[int](families.len)
  for i in 0..<KinSeats:
    let n = families.find(k.family[i].int)
    if n < 0: continue
    inc members[n]
    for l in 0..<Loci:
      vec[n][l] += (if (k.genes[i] shr l and 1) == 1: 1.0 else: -1.0)
  for n in 0..<families.len:
    for l in 0..<Loci: vec[n][l] /= members[n].float
  # Clans: families joined by any shared descent between their members.
  var clan = newSeq[int](families.len)
  for n in 0..<families.len: clan[n] = n
  proc root(n: int): int =
    result = n
    while clan[result] != result: result = clan[result]
  for i in 0..<KinSeats:
    for j in 0..<KinSeats:
      let a = families.find(k.family[i].int)
      let b = families.find(k.family[j].int)
      if a >= 0 and b >= 0 and a != b and k.ibd[i][j] > 0:
        clan[root(a)] = root(b)
  var clans: seq[seq[int]]
  var clanOf: seq[int]
  for n in 0..<families.len:
    let r = root(n)
    let c = clanOf.find(r)
    if c < 0:
      clanOf.add r
      clans.add @[n]
    else: clans[c].add n
  var clanAngle = newSeq[float](clans.len)
  for c, group in clans:
    var mean: array[Loci, float]
    for n in group:
      for l in 0..<Loci: mean[l] += vec[n][l]/group.len.float
    clanAngle[c] = angle(mean)
  var order = newSeq[int](clans.len)
  for c in 0..<clans.len: order[c] = c
  order.sort(proc(a, b: int): int = cmp(clanAngle[a], clanAngle[b]))
  let slot = 360.0/clans.len.float
  let start = clanAngle[order[0]]
  for rank, c in order:
    var group = clans[c]
    group.sort(proc(a, b: int): int = cmp(angle(vec[a]), angle(vec[b])))
    for m, n in group:
      let offset = ((m.float+0.5)/group.len.float-0.5)*slot*ClanSpread
      var hue = start+rank.float*slot+offset
      hue = hue mod 360
      if hue < 0: hue += 360
      for i in 0..<KinSeats:
        if k.family[i].int == families[n]: result[i] = hue.float32

proc hueGap*(a, b: float32): float32 =
  ## Circular distance between two hues in degrees.
  let d = abs(a-b) mod 360
  min(d, 360-d)
