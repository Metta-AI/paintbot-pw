# Heartland

Sixteen wheeled cogs, sixteen separate players, and hidden families. Heartland runs on the
Paintbot PW engine in FFA-kin mode: every cog plays for itself, but some cogs are related, and a
cog's score counts its relatives' points (the kin-weighted R, the sum of r times each cog's
points). It is a testbed for organic alignment: the incentives reward recognising kin and
cooperating with them, without any team label.

- **Leagues.** Heartland (`heartland` variant: Heartwick island, cousin-linked families of four)
  and Heartland Big (`heartland-big`: Big Twin Mesas, ten times the area with 100 control hearts,
  and 50 cogs in 10 tribes of 5 full siblings, `"kin_layout": "tribes"`).
- **Seats.** A match seats one cog per player in its config: 16 in Heartland, 50 in Heartland
  Big (any count from 2 to 256 works). `seatCount()` returns it, and `kin`, `gene`, `seatScore`,
  `seatAlive` take any seat below it. Neural policies need a 16-seat match, except bundles on
  observation contract ffa.v2 with action contract ffa.v2 pointer, which play at any seat count.
- **Rules in brief.** One life, 10 HP, 20 m guns, lone-cog heart captures, a territory boost on
  your own and your relatives' ground, and two great hearts that need three cogs at once.
  A match lasts 6:00. Fog of war (rules 48): you are never shown a cog out of view; `kin`,
  `gene`, `seatScore` and `seatAlive` read -1 for it, the neural observation zeroes its row, and
  only shouts carry past the line of sight. The full rules are under "FFA-kin mode (Heartland)"
  below.
- **Policies.** BASIC scripts, the same language and host API as Paintbot PW, plus the FFA-kin
  functions (`kin`, `gene`, `seatScore`, `seatAlive`, `heartOwner`, the great-heart and
  `territoryBoost` calls). The baseline is `players/ffa.bas`; `players/ffa_blind.bas` is the same
  bot with kin recognition switched off.

The rest of this page is the Paintbot PW engine guide, which Heartland shares.

