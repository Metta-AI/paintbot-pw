' neural_policy.bas: a complete neural policy.bas. The seat observes, runs its network and
' selects the heads; everything after neuralSample is players/neural_decode.bas verbatim, which
' turns the choices into BASIC verbs (docs/neural/seat-view.md: the model's output reaches the
' engine only through BASIC). Write your own rules (masks, temperatures, a spray gate, ...)
' around it.
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
neuralSample()
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
'   also adds ((dx - 11) * 40, (dz - 11) * 40), mirrored for team 1, to the movement goal
'   above (self for stay or an unseen pickup) and clamps it to the map, dx and dz the choices
'   of heads 7 and 8: a destination the network chooses, no goal computed here.
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

if lastTick <> worldTick - 1 then
  aimKnown = 0
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
  clampToMap(gx + (neuralChoice(7) - 11) * 40 * flip, gy + (neuralChoice(8) - 11) * 40 * flip)
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
  end if
end if
if a >= 17 then
  clampToMap(selfX + flip * cdx(a - 17) * 5000, selfY + flip * cdz(a - 17) * 5000)
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
