## Kinship for the FFA-kin mode: families, genes and relatedness drawn from the match seed on a
## private stream. Relatedness counts loci shared by descent only, never chance matches.
import std/[unittest, bitops]
import ../examples/paintbot/kinship

proc linkedCousins(fa, fb: int): bool =
  ## The cousins layout links families 0-1 and 2-3.
  fa >= 0 and fb >= 0 and fa != fb and fa div 2 == fb div 2

proc familySizes(k: Kinship): seq[int] =
  var sizes = newSeq[int](KinSeats)
  var loners = 0
  for i in 0..<KinSeats:
    if k.family[i] < 0: inc loners else: inc sizes[k.family[i]]
  for s in sizes:
    if s > 0: result.add s
  for i in 0..<loners: result.add 0

suite "kinship":
  test "the same seed gives the same kinship":
    for seed in [0'i32, 1, 7, 2026, -5]:
      check sampleKinship(seed) == sampleKinship(seed)
      for layout in KinLayout:
        check kinshipFor(layout, seed) == kinshipFor(layout, seed)
    check sampleKinship(1).genes != sampleKinship(2).genes

  test "r is symmetric with r(i,i) = 1":
    for seed in 0'i32..<50:
      let k = sampleKinship(seed)
      for i in 0..<KinSeats:
        check k.r(i, i) == 1.0
        check k.rPercent(i, i) == 100
        for j in 0..<KinSeats:
          check k.ibd[i][j] == k.ibd[j][i]
          check k.r(i, j) == k.r(j, i)

  test "each layout has its family shapes and exact relatedness":
    for seed in 0'i32..<200:
      for layout in KinLayout:
        let k = kinshipFor(layout, seed)
        check k.layout == layout
        let sizes = k.familySizes
        case layout
        of klFours, klCousins: check sizes == @[4, 4, 4, 4]
        of klPairs: check sizes == @[2, 2, 2, 2, 2, 2, 2, 2]
        of klTriosLoner: check sizes == @[3, 3, 3, 3, 3, 0]
        of klStrangers: check sizes == newSeq[int](KinSeats)
        of klClones: check sizes == @[16]
        for i in 0..<KinSeats:
          for j in 0..<KinSeats:
            if i == j: continue
            let fi = k.family[i].int
            let fj = k.family[j].int
            let expected =
              if layout == klClones: 32
              elif fi >= 0 and fi == fj: 16
              elif layout == klCousins and linkedCousins(fi, fj): 8
              else: 0
            check k.ibd[i][j] == expected
            check k.rPercent(i, j) == int32(expected * 100 div Loci)

  test "siblings are r = 0.5, cousins 0.25, strangers 0, clones 1":
    let fours = kinshipFor(klFours, 3)
    for i in 0..<KinSeats:
      for j in 0..<KinSeats:
        if i != j and fours.family[i] == fours.family[j]: check fours.r(i, j) == 0.5
    let cousins = kinshipFor(klCousins, 3)
    var cousinPairs = 0
    for i in 0..<KinSeats:
      for j in 0..<KinSeats:
        if linkedCousins(cousins.family[i], cousins.family[j]):
          check cousins.r(i, j) == 0.25
          inc cousinPairs
    check cousinPairs == 2 * 2 * 4 * 4
    let strangers = kinshipFor(klStrangers, 3)
    let clones = kinshipFor(klClones, 3)
    for i in 0..<KinSeats:
      for j in 0..<KinSeats:
        if i != j:
          check strangers.r(i, j) == 0.0
          check clones.r(i, j) == 1.0
      check clones.genes[i] == clones.genes[0]

  test "seats are shuffled into families":
    var seatOneWithZero = 0
    for seed in 0'i32..<50:
      let k = kinshipFor(klPairs, seed)
      if k.family[0] == k.family[1]: inc seatOneWithZero
    check seatOneWithZero < 50

  test "every layout appears over seeds 0..999":
    var seen: set[KinLayout]
    var counts: array[KinLayout, int]
    for seed in 0'i32..<1000:
      let k = sampleKinship(seed)
      seen.incl k.layout
      inc counts[k.layout]
    check seen == {KinLayout.low..KinLayout.high}
    # Weights 25/25/20/20/5/5: the rare layouts stay rare.
    check counts[klStrangers] < counts[klFours]
    check counts[klClones] < counts[klPairs]

  test "genes agree on every locus shared by descent":
    for seed in 0'i32..<200:
      for layout in KinLayout:
        let k = kinshipFor(layout, seed)
        for i in 0..<KinSeats:
          for j in 0..<KinSeats:
            let agree = Loci - popcount(k.genes[i] xor k.genes[j])
            check agree >= k.ibd[i][j].int
