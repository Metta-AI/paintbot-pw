## FFA-kin relatedness: families, 32-locus genomes and loci shared by descent, drawn from the
## match seed on a private stream. Kinship lives outside World and never touches its RNG; the
## engine reads only the family grouping (for spawn placement), and scoring, reward,
## observations and the viewer read the rest. r(i,j) = loci shared by descent / 32; chance
## matches between independent random bits never count.
import std/[math, options]
export options
import polyworld/rngs

const
  KinSeats* = 16 # Seats in sim.nim; kept separate so sim can import this module.
  Loci* = 32
  SiblingLoci = 16 # r = 1/2
  CousinLoci = 8 # r = 1/4
  KinSalt = 0x6B696E'i32 # "kin"

type
  KinLayout* = enum
    klFours, klPairs, klTriosLoner, klCousins, klStrangers, klClones
  Kinship* = object
    layout*: KinLayout
    family*: array[KinSeats, int8] # family id per seat, -1 = loner
    genes*: array[KinSeats, uint32] # 32 loci as bits
    ibd*: array[KinSeats, array[KinSeats, int8]] # loci shared by descent, 0..32

const LayoutWeights: array[KinLayout, int32] = [25'i32, 25, 20, 20, 5, 5]
static: doAssert LayoutWeights.sum == 100

when defined(pwTraining):
  var activeKinship* {.threadvar.}: Kinship
  var kinshipOverride* {.threadvar.}: Option[Kinship]
else:
  var activeKinship*: Kinship ## Set at world creation in FFA; unused in the teams game.
  ## When set, FFA worlds use this kinship instead of sampling one from the seed (training
  ## overrides, tests, and replays whose kinship is recorded).
  var kinshipOverride*: Option[Kinship]

proc r*(k: Kinship, i, j: int): float =
  ## Relatedness as a float, for scoring and reward only. Engine and hashed code must use
  ## ibd or rPercent, which are integers.
  k.ibd[i][j].float / Loci.float
proc rPercent*(k: Kinship, i, j: int): int32 =
  ## round(100 r) in integers; ibd is at most 32, so this is exact for 0, 1/4, 1/2 and 1.
  int32((k.ibd[i][j].int * 100 + Loci div 2) div Loci)

proc randomGenome(rng: var Rng): uint32 = uint32(rng.next() and 0xFFFF_FFFF'u64)

proc shuffled(rng: var Rng, n: int): seq[int] =
  result = newSeq[int](n)
  for i in 0..<n: result[i] = i
  for i in countdown(n-1, 1):
    let j = rng.below(int32(i+1)).int
    swap(result[i], result[j])

proc lociMask(positions: openArray[int]): uint32 =
  for p in positions: result = result or (1'u32 shl p)

proc build(layout: KinLayout, rng: var Rng): Kinship =
  result.layout = layout
  let sizes = case layout
    of klFours, klCousins: @[4, 4, 4, 4]
    of klPairs: @[2, 2, 2, 2, 2, 2, 2, 2]
    of klTriosLoner: @[3, 3, 3, 3, 3]
    of klStrangers: newSeq[int]()
    of klClones: @[16]
  # Seats join families in shuffled order; whoever is left over is a loner.
  let order = rng.shuffled(KinSeats)
  for i in 0..<KinSeats: result.family[i] = -1
  var next = 0
  for f, size in sizes:
    for unused in 0..<size:
      result.family[order[next]] = int8(f)
      inc next
  # Every locus starts as an independent random bit; descent overwrites some of them.
  for i in 0..<KinSeats: result.genes[i] = rng.randomGenome()
  # descent[f] marks the loci each member of family f takes from its ancestor ancestor[f].
  var descent = newSeq[uint32](sizes.len)
  var ancestor = newSeq[uint32](sizes.len)
  if layout == klClones:
    descent[0] = high(uint32)
    ancestor[0] = rng.randomGenome()
  elif layout == klCousins:
    # Families 0-1 and 2-3 are linked through a grandparent G: both ancestors carry G's values
    # on a common 8-locus set C, and each family's 16 inherited loci contain C. Two cousins
    # therefore share exactly C by descent; their families' other inherited loci come from
    # different ancestors and count as chance matches, not descent.
    for link in 0..1:
      let grandparent = rng.randomGenome()
      let loci = rng.shuffled(Loci)
      let common = lociMask(loci[0..<CousinLoci])
      for side in 0..1:
        let f = link*2 + side
        let rest = rng.shuffled(Loci - CousinLoci)
        var own: seq[int]
        for p in rest[0..<SiblingLoci-CousinLoci]: own.add loci[CousinLoci + p]
        descent[f] = common or lociMask(own)
        ancestor[f] = (rng.randomGenome() and not common) or (grandparent and common)
  else:
    for f in 0..<sizes.len:
      descent[f] = lociMask(rng.shuffled(Loci)[0..<SiblingLoci])
      ancestor[f] = rng.randomGenome()
  for i in 0..<KinSeats:
    let f = result.family[i]
    if f >= 0:
      result.genes[i] = (result.genes[i] and not descent[f]) or (ancestor[f] and descent[f])
  for i in 0..<KinSeats:
    for j in 0..<KinSeats:
      let fi = result.family[i]
      let fj = result.family[j]
      result.ibd[i][j] =
        if i == j: Loci.int8
        elif fi >= 0 and fi == fj: (if layout == klClones: Loci.int8 else: SiblingLoci.int8)
        elif layout == klCousins and fi >= 0 and fj >= 0 and fi div 2 == fj div 2: CousinLoci.int8
        else: 0'i8

proc kinshipFor*(layout: KinLayout, seed: int32): Kinship =
  ## A fixed layout (training overrides, tests); families and genes still come from the seed.
  ## It does not reproduce sampleKinship's families for the same seed: sampleKinship spends a
  ## draw on the layout first, so the rest of the stream is shifted.
  var rng = initRng(seed xor KinSalt)
  build(layout, rng)

proc sampleKinship*(seed: int32): Kinship =
  ## The match's kinship: layout drawn by weight, then families and genes, all from the seed.
  var rng = initRng(seed xor KinSalt)
  var roll = rng.below(100)
  var layout = klFours
  for candidate in KinLayout:
    if roll < LayoutWeights[candidate]:
      layout = candidate
      break
    roll -= LayoutWeights[candidate]
  build(layout, rng)

proc matchKinship*(seed: int32): Kinship =
  ## The kinship an FFA world created with this seed plays: the override, else the sample.
  if kinshipOverride.isSome: kinshipOverride.get else: sampleKinship(seed)
