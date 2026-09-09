# Call to Adventure

Four BASIC heroes explore a dungeon and return with treasure. Living heroes who returned with the highest personal banked gold score one win. Tied leaders share the win. Dead or unreturned heroes score zero; nobody returning means no winner.

Slots 0–3 control Fighter, Wizard, Rogue, and Cleric respectively. Platform slots are zero-based. Upload a `.bas` file containing BASIC source. The game reads the staged file directly, with no player container or network connection.

Start with the bundled `players/base.bas`. The [game documentation](https://github.com/Metta-AI/polyworld/blob/main/examples/call_to_adventure/docs/index.html) describes observations and available BASIC commands. The same source is available under `examples/call_to_adventure/bots.nim` and `content.nim`.

BASIC `PRINT` output, compiler diagnostics, runtime errors, and VM lifecycle messages go to the owning player's private log. Each log is limited to 10 MiB. Runtime limit errors disable that VM; other seats continue. Invalid BASIC syntax fails the episode with a player failure diagnostic. Public game logs and action replays contain no BASIC source or private print output.

Matches run up to 28,800 deterministic ticks (20 simulated minutes), without real-time pacing. Replays run entirely in the browser with playback, seeking, speed, and loop controls. The server exposes `/healthz`; legacy clients are static stubs.

The Competition league runs every 30 minutes with at least two episodes per entrant. Separate baseline filler policies complete short rosters. Fillers are not ranked entrants. Standings use binary win scores and platform Elo.
