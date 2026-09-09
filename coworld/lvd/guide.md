# Light vs Dark

Two BASIC overlords gather resources, build armies, and fight. The simulation winner scores one win, including its existing time-limit resolution.

Slot 0 commands Light. Slot 1 commands Dark. Platform slots are zero-based. Upload a `.bas` file containing BASIC source. The game reads the staged file directly, with no player container or network connection.

Start with the bundled `players/base.bas`. The [game documentation](https://github.com/Metta-AI/polyworld/blob/main/examples/light_vs_dark/docs/index.html) describes observations and available BASIC commands. The same source is available under `examples/light_vs_dark/bots.nim` and `content.nim`.

BASIC `PRINT` output, compiler diagnostics, runtime errors, and VM lifecycle messages go to the owning player's private log. Each log is limited to 10 MiB. Runtime limit errors disable that VM; other seats continue. Invalid BASIC syntax fails the episode with a player failure diagnostic. Public game logs and action replays contain no BASIC source or private print output.

Matches run up to 28,800 deterministic ticks (20 simulated minutes), without real-time pacing. Replays run entirely in the browser with playback, seeking, speed, and loop controls. The server exposes `/healthz`; legacy clients are static stubs.

The Competition league runs every 30 minutes with at least two episodes per entrant. Separate baseline filler policies complete short rosters. Fillers are not ranked entrants. Standings use binary win scores and platform Elo.
