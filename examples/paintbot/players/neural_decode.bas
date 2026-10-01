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
' Its mode variant (16; neuralLayout(23) = 5, neuralLayout(24) = 12) adds two parameterisation
'   heads after contract 15's: head 7, the movement mode: 0 head 0 as above; 1 keep goal (the
'   goal this decoder issued last tick); 2 keep leg (that goal's vector from the seat's position
'   then, from where it is now, clamped); 3 / 4 strafe + / -: a 200-unit step (the compass step's
'   length) perpendicular to the identity head 1 chose, + = (-dz, dx), - = (dz, -dx), integer
'   math (isqrt); a mode that has nothing to act on (no goal known yet, head 1 not a visible
'   identity) stays. Head 8, the aim target: 0 head 1 as above (offsets included); 1 the visible
'   enemies' integer centroid; 2 + k control heart k; with none (no visible enemy, k >=
'   heartCount()) head 1's aim stands. Nothing here is a script constant: keep or switch is the
'   network's choice every tick.
' fire, grenade and sneak: 1 = on. "Keep" re-issues the aim this script last left the seat
' with (its last order, or its walking goal when it gave none), known from the second tick of
' a life on; with none known the seat is given no aim and a shot waits for one.
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

sub isqrt(v)
  ' floor(sqrt(v)) for v >= 0 (Newton on integers); 0 for v <= 0
  iq = 0
  if v > 0 then
    iqx = v
    iqy = (iqx + 1) / 2
    while iqy < iqx
      iqx = iqy
      iqy = (iqx + v / iqx) / 2
    wend
    iq = iqx
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
  goalKnown = 0
end if
lastTick = worldTick
flip = 1
if selfTeam = 1 then
  flip = -1
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
  clampToMap(selfX + flip * cdx(m - 43) * 200, selfY + flip * cdz(m - 43) * 200)
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
if neuralLayout(23) = 5 then
  mm = neuralChoice(7)
  if mm >= 1 then
    gx = selfX
    gy = selfY
  end if
  if mm = 1 and goalKnown = 1 then
    gx = lastGX
    gy = lastGY
  end if
  if mm = 2 and goalKnown = 1 then
    clampToMap(selfX + lastGX - lastPX, selfY + lastGY - lastPY)
    gx = cx
    gy = cy
  end if
  if mm >= 3 then
    sj = neuralChoice(1) - 1
    if sj >= 0 and sj <= 15 then
      if visible(sj) then
        sdx = playerX(sj) - selfX
        sdz = playerY(sj) - selfY
        isqrt(sdx * sdx + sdz * sdz)
        if iq > 0 then
          ss = 1
          if mm = 4 then
            ss = -1
          end if
          clampToMap(selfX + ss * (0 - sdz) * 200 / iq, selfY + ss * sdx * 200 / iq)
          gx = cx
          gy = cy
        end if
      end if
    end if
  end if
  lastGX = gx
  lastGY = gy
  lastPX = selfX
  lastPY = selfY
  goalKnown = 1
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
  end if
end if
if a >= 17 then
  clampToMap(selfX + flip * cdx(a - 17) * 5000, selfY + flip * cdz(a - 17) * 5000)
  ax = cx
  ay = cy
  have = 1
end if
if neuralLayout(24) = 12 then
  tg = neuralChoice(8)
  if tg = 1 then
    cn = 0
    csx = 0
    csy = 0
    cj = 0
    while cj < 16
      if cj mod 2 <> selfTeam then
        if visible(cj) then
          cn = cn + 1
          csx = csx + playerX(cj)
          csy = csy + playerY(cj)
        end if
      end if
      cj = cj + 1
    wend
    if cn > 0 then
      ax = csx / cn
      ay = csy / cn
      have = 1
    end if
  end if
  if tg >= 2 then
    if tg - 2 < heartCount() then
      ax = controlX(tg - 2)
      ay = controlY(tg - 2)
      have = 1
    end if
  end if
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
