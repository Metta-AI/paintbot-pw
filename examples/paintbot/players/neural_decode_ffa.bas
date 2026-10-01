' neural_decode_ffa.bas: the reference reading of the neural action heads, in BASIC.
' The model's output reaches the engine only through BASIC (docs/neural/seat-view.md): a
' policy.bas selects the heads (neuralSample) and turns the choices into walkTo / lookAt /
' shootAt / chargeGrenade / sneak with nothing but its SeatView builtins. This file is that
' decode for action contract ffa.view.1 pointer (neural_decode.bas is teams.view.1's), run
' by the native training ABI for every seat whose heads the caller gives to pw_step.
'
' Action contract ffa.view.1 pointer (heads 11+H, 9+C, 2, 2, 2; no mirroring):
'   objective 0 stay, 1..8 compass step, 9.. control heart row neuralRow(1, m-9), then the
'     great heart rows neuralRow(2, ...)
'   aim 0 keep, 1..8 compass, 9.. cog row: identity neuralRow(0, a-9) when visible (else keep)
' fire, grenade and sneak: 1 = on. "Keep" re-issues the aim this script last left the seat
' with (its last order, or its walking goal when it gave none), known from the second tick of
' a life on; with none known the seat is given no aim and a shot waits for one.
' Its shout variant ffa.view.1 pointer shout (heads 11+H, 9+C, 2, 2, 2, 3; neuralLayout(21) = 3)
' adds head 5: 0 says nothing, 1 shout("hurt"), 2 shout("at"), the FFA-kin baseline's
' (ffa.bas) whole vocabulary, said through the same BASIC verb.
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

if lastTick <> worldTick - 1 then
  aimKnown = 0
end if
lastTick = worldTick

m = neuralChoice(0)
gx = selfX
gy = selfY
if m >= 1 and m <= 8 then
  clampToMap(selfX + cdx(m - 1) * 200, selfY + cdz(m - 1) * 200)
  gx = cx
  gy = cy
end if
if m >= 9 then
  k = m - 9
  if k < neuralLayout(6) then
    gx = controlX(neuralRow(1, k))
    gy = controlY(neuralRow(1, k))
  else
    gx = greatHeartX(neuralRow(2, k - neuralLayout(6)))
    gy = greatHeartY(neuralRow(2, k - neuralLayout(6)))
  end if
end if
walkTo(gx, gy)

a = neuralChoice(1)
have = 0
if a >= 1 and a <= 8 then
  clampToMap(selfX + cdx(a - 1) * 5000, selfY + cdz(a - 1) * 5000)
  ax = cx
  ay = cy
  have = 1
end if
if a >= 9 then
  target = neuralRow(0, a - 9)
  if target >= 0 then
    if visible(target) then
      ax = playerX(target)
      ay = playerY(target)
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
if neuralLayout(21) = 3 then
  said = neuralChoice(5)
  if said = 1 then
    shout(strNew("hurt"))
  end if
  if said = 2 then
    shout(strNew("at"))
  end if
end if
