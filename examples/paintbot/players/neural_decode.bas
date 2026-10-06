' neural_decode.bas: the reference reading of the neural action heads, in BASIC.
' The model's output reaches the engine only through BASIC (docs/neural/seat-view.md): a
' policy.bas selects the heads (neuralSample) and turns the choices into walkTo / lookAt /
' shootAt / chargeGrenade / sneak with nothing but its SeatView builtins. This file is that
' decode for action contract teams.view.1 (neural_decode_ffa.bas is ffa.view.1 pointer's),
' shared by players/neural_policy.bas and by the native training ABI, which runs it for
' every seat whose heads the caller gives to pw_step.
'
' Action contract teams.view.1 (heads 51, 25, 2, 2, 2; team 1's compass is mirrored):
'   movement 0 stay, 1..10 control heart m-1, 11..42 pickup m-11 when visible (else stay),
'     43..50 compass step: self + 200 * Directions(m-43), clamped to the map
'   aim 0 keep, 1..16 identity a-1 when visible (else keep), 17..24 compass: self + 5000 *
'     Directions(a-17), clamped
' Its aim-offset variant (heads 51, 25, 2, 2, 2, 23, 23; neuralLayout(21) = 23) adds
'   ((ix - 11) * 28, (iz - 11) * 28), mirrored for team 1, to an identity aim point, ix and iz
'   the choices of heads 5 and 6: an offset the network chooses, no lead computed here.
' Its movement-offset variant (heads 51, 25, 2, 2, 2, 23, 23, 23, 23; neuralLayout(23) = 23)
'   also adds (moveOffset(dx), moveOffset(dz)), mirrored for team 1, to the movement goal
'   above (self for stay or an unseen pickup) and clamps it to the map, dx and dz the choices
'   of heads 7 and 8: a destination the network chooses, no goal computed here. moveOffset is
'   symmetric and log-spaced: bin 11 = 0, bin 11 +- j = +-(16, 28, 48, 84, 146, 253, 439, 763,
'   1326, 2303, 4000)(j), so one head covers short corrections and far destinations.
'   Its target-conditioned variant (15) decodes as the aim-offset variant (heads 5 / 6 are drawn
'   from the chosen identity's row; the decode is the same).
' Its raw variant (16; neuralLayout(21) = 63): heads 5 / 6 are 63 bins of 7 u (offset (b - 31) * 7,
'   mirrored for team 1, on an identity aim); a compass step (movement 43 .. 50) becomes the grid walk
'   self + flip * round(R * (cos, sin)(2 pi i / 256)), i = head 7, R = (50, 100, 150, 250, 500, 1000,
'   2000, 4000)(head 8), clamped; a compass aim (17 .. 24) becomes the look point self + flip *
'   round(5000 * (cos, sin)(2 pi k / 128)), k = head 9, clamped. cos / sin are integer tables x 10000
'   and every product is rounded half away from zero. Fixed grid points only: nothing is computed for
'   the network.
' Its self-destruct variant (17; heads 51, 25, 2, 2, 2, 2; neuralLayout(21) = 2): head 5 = 1 calls selfDestruct()
'   (the engine acts on it from rules 49, for a live cog that is not disarmed).
' fire, grenade and sneak: 1 = on. "Keep" re-issues the aim this script last left the seat
' with (its last order, or its walking goal when it gave none), known from the second tick of
' a life on; with none known the seat is given no aim and a shot waits for one.
dim rwc(256)
dim rws(256)
dim rwd(8)
dim cdx(8)
dim cdz(8)
cdx(0) = 1
cdz(0) = 0
cdx(1) = 1
cdz(1) = 1
cdx(2) = 0
cdz(2) = 1
cdx(3) = -1
cdz(3) = 1
cdx(4) = -1
cdz(4) = 0
cdx(5) = -1
cdz(5) = -1
cdx(6) = 0
cdz(6) = -1
cdx(7) = 1
cdz(7) = -1

sub clampToMap(px, py)
  cx = px
  cy = py
  if cx < mapMinX() then
    cx = mapMinX()
  end if
  if cx > mapMaxX() then
    cx = mapMaxX()
  end if
  if cy < mapMinY() then
    cy = mapMinY()
  end if
  if cy > mapMaxY() then
    cy = mapMaxY()
  end if
end sub

sub rnd10k(v)
  ' v / 10000 rounded half away from zero
  if v >= 0 then
    rq = (v + 5000) \ 10000
  else
    rq = 0 - ((0 - v + 5000) \ 10000)
  end if
end sub

sub moveOffset(b)
  mvj = b - 11
  mvs = 1
  if mvj < 0 then
    mvs = -1
    mvj = 0 - mvj
  end if
  mo = 0
  if mvj = 1 then
    mo = 16
  end if
  if mvj = 2 then
    mo = 28
  end if
  if mvj = 3 then
    mo = 48
  end if
  if mvj = 4 then
    mo = 84
  end if
  if mvj = 5 then
    mo = 146
  end if
  if mvj = 6 then
    mo = 253
  end if
  if mvj = 7 then
    mo = 439
  end if
  if mvj = 8 then
    mo = 763
  end if
  if mvj = 9 then
    mo = 1326
  end if
  if mvj = 10 then
    mo = 2303
  end if
  if mvj = 11 then
    mo = 4000
  end if
  mo = mo * mvs
end sub

if lastTick <> worldTick - 1 then
  aimKnown = 0
end if
lastTick = worldTick
flip = 1
if selfTeam = 1 then
  flip = -1
end if

rawc = 0
if neuralLayout(21) = 63 then
  rawc = 1
  if rawInit = 0 then
    rwc(0) = 10000
    rws(0) = 0
    rwc(1) = 9997
    rws(1) = 245
    rwc(2) = 9988
    rws(2) = 491
    rwc(3) = 9973
    rws(3) = 736
    rwc(4) = 9952
    rws(4) = 980
    rwc(5) = 9925
    rws(5) = 1224
    rwc(6) = 9892
    rws(6) = 1467
    rwc(7) = 9853
    rws(7) = 1710
    rwc(8) = 9808
    rws(8) = 1951
    rwc(9) = 9757
    rws(9) = 2191
    rwc(10) = 9700
    rws(10) = 2430
    rwc(11) = 9638
    rws(11) = 2667
    rwc(12) = 9569
    rws(12) = 2903
    rwc(13) = 9495
    rws(13) = 3137
    rwc(14) = 9415
    rws(14) = 3369
    rwc(15) = 9330
    rws(15) = 3599
    rwc(16) = 9239
    rws(16) = 3827
    rwc(17) = 9142
    rws(17) = 4052
    rwc(18) = 9040
    rws(18) = 4276
    rwc(19) = 8932
    rws(19) = 4496
    rwc(20) = 8819
    rws(20) = 4714
    rwc(21) = 8701
    rws(21) = 4929
    rwc(22) = 8577
    rws(22) = 5141
    rwc(23) = 8449
    rws(23) = 5350
    rwc(24) = 8315
    rws(24) = 5556
    rwc(25) = 8176
    rws(25) = 5758
    rwc(26) = 8032
    rws(26) = 5957
    rwc(27) = 7883
    rws(27) = 6152
    rwc(28) = 7730
    rws(28) = 6344
    rwc(29) = 7572
    rws(29) = 6532
    rwc(30) = 7410
    rws(30) = 6716
    rwc(31) = 7242
    rws(31) = 6895
    rwc(32) = 7071
    rws(32) = 7071
    rwc(33) = 6895
    rws(33) = 7242
    rwc(34) = 6716
    rws(34) = 7410
    rwc(35) = 6532
    rws(35) = 7572
    rwc(36) = 6344
    rws(36) = 7730
    rwc(37) = 6152
    rws(37) = 7883
    rwc(38) = 5957
    rws(38) = 8032
    rwc(39) = 5758
    rws(39) = 8176
    rwc(40) = 5556
    rws(40) = 8315
    rwc(41) = 5350
    rws(41) = 8449
    rwc(42) = 5141
    rws(42) = 8577
    rwc(43) = 4929
    rws(43) = 8701
    rwc(44) = 4714
    rws(44) = 8819
    rwc(45) = 4496
    rws(45) = 8932
    rwc(46) = 4276
    rws(46) = 9040
    rwc(47) = 4052
    rws(47) = 9142
    rwc(48) = 3827
    rws(48) = 9239
    rwc(49) = 3599
    rws(49) = 9330
    rwc(50) = 3369
    rws(50) = 9415
    rwc(51) = 3137
    rws(51) = 9495
    rwc(52) = 2903
    rws(52) = 9569
    rwc(53) = 2667
    rws(53) = 9638
    rwc(54) = 2430
    rws(54) = 9700
    rwc(55) = 2191
    rws(55) = 9757
    rwc(56) = 1951
    rws(56) = 9808
    rwc(57) = 1710
    rws(57) = 9853
    rwc(58) = 1467
    rws(58) = 9892
    rwc(59) = 1224
    rws(59) = 9925
    rwc(60) = 980
    rws(60) = 9952
    rwc(61) = 736
    rws(61) = 9973
    rwc(62) = 491
    rws(62) = 9988
    rwc(63) = 245
    rws(63) = 9997
    rwc(64) = 0
    rws(64) = 10000
    rwc(65) = -245
    rws(65) = 9997
    rwc(66) = -491
    rws(66) = 9988
    rwc(67) = -736
    rws(67) = 9973
    rwc(68) = -980
    rws(68) = 9952
    rwc(69) = -1224
    rws(69) = 9925
    rwc(70) = -1467
    rws(70) = 9892
    rwc(71) = -1710
    rws(71) = 9853
    rwc(72) = -1951
    rws(72) = 9808
    rwc(73) = -2191
    rws(73) = 9757
    rwc(74) = -2430
    rws(74) = 9700
    rwc(75) = -2667
    rws(75) = 9638
    rwc(76) = -2903
    rws(76) = 9569
    rwc(77) = -3137
    rws(77) = 9495
    rwc(78) = -3369
    rws(78) = 9415
    rwc(79) = -3599
    rws(79) = 9330
    rwc(80) = -3827
    rws(80) = 9239
    rwc(81) = -4052
    rws(81) = 9142
    rwc(82) = -4276
    rws(82) = 9040
    rwc(83) = -4496
    rws(83) = 8932
    rwc(84) = -4714
    rws(84) = 8819
    rwc(85) = -4929
    rws(85) = 8701
    rwc(86) = -5141
    rws(86) = 8577
    rwc(87) = -5350
    rws(87) = 8449
    rwc(88) = -5556
    rws(88) = 8315
    rwc(89) = -5758
    rws(89) = 8176
    rwc(90) = -5957
    rws(90) = 8032
    rwc(91) = -6152
    rws(91) = 7883
    rwc(92) = -6344
    rws(92) = 7730
    rwc(93) = -6532
    rws(93) = 7572
    rwc(94) = -6716
    rws(94) = 7410
    rwc(95) = -6895
    rws(95) = 7242
    rwc(96) = -7071
    rws(96) = 7071
    rwc(97) = -7242
    rws(97) = 6895
    rwc(98) = -7410
    rws(98) = 6716
    rwc(99) = -7572
    rws(99) = 6532
    rwc(100) = -7730
    rws(100) = 6344
    rwc(101) = -7883
    rws(101) = 6152
    rwc(102) = -8032
    rws(102) = 5957
    rwc(103) = -8176
    rws(103) = 5758
    rwc(104) = -8315
    rws(104) = 5556
    rwc(105) = -8449
    rws(105) = 5350
    rwc(106) = -8577
    rws(106) = 5141
    rwc(107) = -8701
    rws(107) = 4929
    rwc(108) = -8819
    rws(108) = 4714
    rwc(109) = -8932
    rws(109) = 4496
    rwc(110) = -9040
    rws(110) = 4276
    rwc(111) = -9142
    rws(111) = 4052
    rwc(112) = -9239
    rws(112) = 3827
    rwc(113) = -9330
    rws(113) = 3599
    rwc(114) = -9415
    rws(114) = 3369
    rwc(115) = -9495
    rws(115) = 3137
    rwc(116) = -9569
    rws(116) = 2903
    rwc(117) = -9638
    rws(117) = 2667
    rwc(118) = -9700
    rws(118) = 2430
    rwc(119) = -9757
    rws(119) = 2191
    rwc(120) = -9808
    rws(120) = 1951
    rwc(121) = -9853
    rws(121) = 1710
    rwc(122) = -9892
    rws(122) = 1467
    rwc(123) = -9925
    rws(123) = 1224
    rwc(124) = -9952
    rws(124) = 980
    rwc(125) = -9973
    rws(125) = 736
    rwc(126) = -9988
    rws(126) = 491
    rwc(127) = -9997
    rws(127) = 245
    rwc(128) = -10000
    rws(128) = 0
    rwc(129) = -9997
    rws(129) = -245
    rwc(130) = -9988
    rws(130) = -491
    rwc(131) = -9973
    rws(131) = -736
    rwc(132) = -9952
    rws(132) = -980
    rwc(133) = -9925
    rws(133) = -1224
    rwc(134) = -9892
    rws(134) = -1467
    rwc(135) = -9853
    rws(135) = -1710
    rwc(136) = -9808
    rws(136) = -1951
    rwc(137) = -9757
    rws(137) = -2191
    rwc(138) = -9700
    rws(138) = -2430
    rwc(139) = -9638
    rws(139) = -2667
    rwc(140) = -9569
    rws(140) = -2903
    rwc(141) = -9495
    rws(141) = -3137
    rwc(142) = -9415
    rws(142) = -3369
    rwc(143) = -9330
    rws(143) = -3599
    rwc(144) = -9239
    rws(144) = -3827
    rwc(145) = -9142
    rws(145) = -4052
    rwc(146) = -9040
    rws(146) = -4276
    rwc(147) = -8932
    rws(147) = -4496
    rwc(148) = -8819
    rws(148) = -4714
    rwc(149) = -8701
    rws(149) = -4929
    rwc(150) = -8577
    rws(150) = -5141
    rwc(151) = -8449
    rws(151) = -5350
    rwc(152) = -8315
    rws(152) = -5556
    rwc(153) = -8176
    rws(153) = -5758
    rwc(154) = -8032
    rws(154) = -5957
    rwc(155) = -7883
    rws(155) = -6152
    rwc(156) = -7730
    rws(156) = -6344
    rwc(157) = -7572
    rws(157) = -6532
    rwc(158) = -7410
    rws(158) = -6716
    rwc(159) = -7242
    rws(159) = -6895
    rwc(160) = -7071
    rws(160) = -7071
    rwc(161) = -6895
    rws(161) = -7242
    rwc(162) = -6716
    rws(162) = -7410
    rwc(163) = -6532
    rws(163) = -7572
    rwc(164) = -6344
    rws(164) = -7730
    rwc(165) = -6152
    rws(165) = -7883
    rwc(166) = -5957
    rws(166) = -8032
    rwc(167) = -5758
    rws(167) = -8176
    rwc(168) = -5556
    rws(168) = -8315
    rwc(169) = -5350
    rws(169) = -8449
    rwc(170) = -5141
    rws(170) = -8577
    rwc(171) = -4929
    rws(171) = -8701
    rwc(172) = -4714
    rws(172) = -8819
    rwc(173) = -4496
    rws(173) = -8932
    rwc(174) = -4276
    rws(174) = -9040
    rwc(175) = -4052
    rws(175) = -9142
    rwc(176) = -3827
    rws(176) = -9239
    rwc(177) = -3599
    rws(177) = -9330
    rwc(178) = -3369
    rws(178) = -9415
    rwc(179) = -3137
    rws(179) = -9495
    rwc(180) = -2903
    rws(180) = -9569
    rwc(181) = -2667
    rws(181) = -9638
    rwc(182) = -2430
    rws(182) = -9700
    rwc(183) = -2191
    rws(183) = -9757
    rwc(184) = -1951
    rws(184) = -9808
    rwc(185) = -1710
    rws(185) = -9853
    rwc(186) = -1467
    rws(186) = -9892
    rwc(187) = -1224
    rws(187) = -9925
    rwc(188) = -980
    rws(188) = -9952
    rwc(189) = -736
    rws(189) = -9973
    rwc(190) = -491
    rws(190) = -9988
    rwc(191) = -245
    rws(191) = -9997
    rwc(192) = 0
    rws(192) = -10000
    rwc(193) = 245
    rws(193) = -9997
    rwc(194) = 491
    rws(194) = -9988
    rwc(195) = 736
    rws(195) = -9973
    rwc(196) = 980
    rws(196) = -9952
    rwc(197) = 1224
    rws(197) = -9925
    rwc(198) = 1467
    rws(198) = -9892
    rwc(199) = 1710
    rws(199) = -9853
    rwc(200) = 1951
    rws(200) = -9808
    rwc(201) = 2191
    rws(201) = -9757
    rwc(202) = 2430
    rws(202) = -9700
    rwc(203) = 2667
    rws(203) = -9638
    rwc(204) = 2903
    rws(204) = -9569
    rwc(205) = 3137
    rws(205) = -9495
    rwc(206) = 3369
    rws(206) = -9415
    rwc(207) = 3599
    rws(207) = -9330
    rwc(208) = 3827
    rws(208) = -9239
    rwc(209) = 4052
    rws(209) = -9142
    rwc(210) = 4276
    rws(210) = -9040
    rwc(211) = 4496
    rws(211) = -8932
    rwc(212) = 4714
    rws(212) = -8819
    rwc(213) = 4929
    rws(213) = -8701
    rwc(214) = 5141
    rws(214) = -8577
    rwc(215) = 5350
    rws(215) = -8449
    rwc(216) = 5556
    rws(216) = -8315
    rwc(217) = 5758
    rws(217) = -8176
    rwc(218) = 5957
    rws(218) = -8032
    rwc(219) = 6152
    rws(219) = -7883
    rwc(220) = 6344
    rws(220) = -7730
    rwc(221) = 6532
    rws(221) = -7572
    rwc(222) = 6716
    rws(222) = -7410
    rwc(223) = 6895
    rws(223) = -7242
    rwc(224) = 7071
    rws(224) = -7071
    rwc(225) = 7242
    rws(225) = -6895
    rwc(226) = 7410
    rws(226) = -6716
    rwc(227) = 7572
    rws(227) = -6532
    rwc(228) = 7730
    rws(228) = -6344
    rwc(229) = 7883
    rws(229) = -6152
    rwc(230) = 8032
    rws(230) = -5957
    rwc(231) = 8176
    rws(231) = -5758
    rwc(232) = 8315
    rws(232) = -5556
    rwc(233) = 8449
    rws(233) = -5350
    rwc(234) = 8577
    rws(234) = -5141
    rwc(235) = 8701
    rws(235) = -4929
    rwc(236) = 8819
    rws(236) = -4714
    rwc(237) = 8932
    rws(237) = -4496
    rwc(238) = 9040
    rws(238) = -4276
    rwc(239) = 9142
    rws(239) = -4052
    rwc(240) = 9239
    rws(240) = -3827
    rwc(241) = 9330
    rws(241) = -3599
    rwc(242) = 9415
    rws(242) = -3369
    rwc(243) = 9495
    rws(243) = -3137
    rwc(244) = 9569
    rws(244) = -2903
    rwc(245) = 9638
    rws(245) = -2667
    rwc(246) = 9700
    rws(246) = -2430
    rwc(247) = 9757
    rws(247) = -2191
    rwc(248) = 9808
    rws(248) = -1951
    rwc(249) = 9853
    rws(249) = -1710
    rwc(250) = 9892
    rws(250) = -1467
    rwc(251) = 9925
    rws(251) = -1224
    rwc(252) = 9952
    rws(252) = -980
    rwc(253) = 9973
    rws(253) = -736
    rwc(254) = 9988
    rws(254) = -491
    rwc(255) = 9997
    rws(255) = -245
    rwd(0) = 50
    rwd(1) = 100
    rwd(2) = 150
    rwd(3) = 250
    rwd(4) = 500
    rwd(5) = 1000
    rwd(6) = 2000
    rwd(7) = 4000
    rawInit = 1
  end if
end if

m = neuralChoice(0)
gx = selfX
gy = selfY
if m >= 1 and m <= 10 then
  if m - 1 < heartCount() then
    gx = controlX(m - 1)
    gy = controlY(m - 1)
  end if
end if
if m >= 11 and m <= 42 then
  if pickupVisible(m - 11) then
    gx = pickupX(m - 11)
    gy = pickupY(m - 11)
  end if
end if
if m >= 43 then
  if rawc = 1 then
    rwi = neuralChoice(7)
    rwr = rwd(neuralChoice(8))
    rnd10k(rwr * rwc(rwi))
    rgx = rq
    rnd10k(rwr * rws(rwi))
    clampToMap(selfX + flip * rgx, selfY + flip * rq)
  else
    clampToMap(selfX + flip * cdx(m - 43) * 200, selfY + flip * cdz(m - 43) * 200)
  end if
  gx = cx
  gy = cy
end if
if neuralLayout(23) = 23 then
  moveOffset(neuralChoice(7))
  mox = mo
  moveOffset(neuralChoice(8))
  clampToMap(gx + mox * flip, gy + mo * flip)
  gx = cx
  gy = cy
end if
walkTo(gx, gy)

a = neuralChoice(1)
have = 0
if a >= 1 and a <= 16 then
  if visible(a - 1) then
    ax = playerX(a - 1)
    ay = playerY(a - 1)
    have = 1
    if neuralLayout(21) = 23 then
      ax = ax + (neuralChoice(5) - 11) * 28 * flip
      ay = ay + (neuralChoice(6) - 11) * 28 * flip
    end if
    if rawc = 1 then
      ax = ax + (neuralChoice(5) - 31) * 7 * flip
      ay = ay + (neuralChoice(6) - 31) * 7 * flip
    end if
  end if
end if
if a >= 17 then
  if rawc = 1 then
    rli = neuralChoice(9) * 2
    rnd10k(5000 * rwc(rli))
    rlx = rq
    rnd10k(5000 * rws(rli))
    clampToMap(selfX + flip * rlx, selfY + flip * rq)
  else
    clampToMap(selfX + flip * cdx(a - 17) * 5000, selfY + flip * cdz(a - 17) * 5000)
  end if
  ax = cx
  ay = cy
  have = 1
end if
if have = 0 and aimKnown = 1 then
  ax = keptX
  ay = keptY
  have = 1
end if
if have = 1 then
  if neuralChoice(2) = 1 then
    shootAt(ax, ay)
  else
    lookAt(ax, ay)
  end if
  clampToMap(ax, ay)
  keptX = cx
  keptY = cy
  aimKnown = 1
else
  if gx <> selfX or gy <> selfY then
    keptX = gx
    keptY = gy
    aimKnown = 1
  end if
end if
chargeGrenade(neuralChoice(3))
sneak(neuralChoice(4))
' Action contract 17 (teams.view.1 self-destruct; neuralLayout(21) = 2): head 5 = 1 orders a self-destruct.
if neuralLayout(21) = 2 then
  if neuralChoice(5) = 1 then
    selfDestruct()
  end if
end if
