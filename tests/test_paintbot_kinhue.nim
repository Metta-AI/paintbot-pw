## FFA-kin viewer hues: siblings share a hue, loners have none, families are distinct, and
## cousin families sit closer on the wheel than unrelated ones.
import std/unittest
import ../examples/paintbot/[kinship, kinhue]

suite "FFA-kin family hues":
  test "siblings share a hue and loners are grey":
    for layout in KinLayout:
      for seed in 1'i32..20:
        let k = kinshipFor(layout, seed)
        let hues = familyHues(k)
        for i in 0..<KinSeats:
          check (hues[i] == LonerHue) == (k.family[i] < 0)
          if hues[i] != LonerHue: check hues[i] >= 0 and hues[i] < 360
          for j in 0..<KinSeats:
            if k.family[i] >= 0 and k.family[i] == k.family[j]: check hues[i] == hues[j]

  test "strangers are all loners":
    for hue in familyHues(kinshipFor(klStrangers, 3)): check hue == LonerHue

  test "different families are well separated":
    for layout in [klFours, klPairs, klTriosLoner, klCousins]:
      for seed in 1'i32..30:
        let k = kinshipFor(layout, seed)
        let hues = familyHues(k)
        for i in 0..<KinSeats:
          for j in 0..<KinSeats:
            if k.family[i] >= 0 and k.family[j] >= 0 and k.family[i] != k.family[j]:
              check hueGap(hues[i], hues[j]) >= 30

  test "cousin families are neighbours":
    for seed in 1'i32..30:
      let k = kinshipFor(klCousins, seed)
      let hues = familyHues(k)
      for i in 0..<KinSeats:
        for j in 0..<KinSeats:
          for m in 0..<KinSeats:
            let (fi, fj, fm) = (k.family[i], k.family[j], k.family[m])
            if fi == fj or fi == fm or fj == fm: continue
            if k.ibd[i][j] > 0 and k.ibd[i][m] == 0:
              check hueGap(hues[i], hues[j]) < hueGap(hues[i], hues[m])

  test "hues are deterministic":
    let k = sampleKinship(2026)
    check familyHues(k) == familyHues(k)
