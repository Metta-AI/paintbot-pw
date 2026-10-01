Bassy runtime benchmark evidence

Measured locally on macOS ARM64 with Nim 2.2.6 and release builds. The old
runtime is commit `537826a`. The new runtime includes the Bassy migration and
the observation binding changes in this branch. Native compilation is asserted
for every seat before timing. Runs alternate engine order and never overlap.

Each match has 16 seats, 240 warmup ticks, and 1,200 measured ticks. The table
shows medians of six runs per engine. Decision time excludes world simulation.

| Policy | Old decisions (ms) | JIT decisions (ms) | Speedup |
| --- | ---: | ---: | ---: |
| base | 2255.2 | 2054.5 | 1.098x |
| jev | 5452.0 | 4760.3 | 1.145x |

All 24 runs reached state hash `2770947189`. End-to-end decision plus
simulation speedups were base: 1.089x, jev: 1.139x.
One-time startup includes compilation and is slower with the JIT:
base: 9.2 ms old, 36.6 ms new, jev: 66.7 ms old, 257.5 ms new.
This final run includes the roster and loader ownership fixes. Its samples
contain substantial wall-clock variation: base decisions span 2.16-7.32 seconds
old and 2.04-3.23 seconds new, while Jev spans 2.28-6.99 seconds old and
2.08-5.59 seconds new. These are local median comparisons, not portable latency
guarantees. Every sample, including the slower runs, is saved in
`bassy-benchmarks.json`.

Run the same comparison from the repository root:

```sh
python3 tools/bench_paintbot_bassy.py --runs 6 --ticks 1200
```

The runner builds an isolated archive of the old revision and the current
working
tree against the same local dependencies. Its default output is
`tmp/bassy-benchmarks.json`. No Git checkout or remote operation is required.

The BASIC microbenchmark uses `tests/bench_basic.nim` with JIT enabled by
default.
Two passes of ten runs per workload were run for each engine in old/new/new/old
order. The following times average the two reported benchy means:

| Workload | Old (ms) | JIT (ms) | Speedup |
| --- | ---: | ---: | ---: |
| arithmetic | 18.605 | 0.784 | 23.75x |
| arrays | 28.690 | 1.844 | 15.56x |
| branches | 31.074 | 1.383 | 22.48x |
| sub calls | 17.629 | 2.697 | 6.54x |
| host data | 19.264 | 0.665 | 28.99x |
| host calls | 16.333 | 10.407 | 1.57x |
| string build | 9.849 | 9.897 | 1.00x |
| string parse | 5.018 | 4.719 | 1.06x |
| string find | 5.515 | 5.308 | 1.04x |

Legacy string building remains approximately the same speed. Arithmetic,
arrays,
branches, subroutine calls, and host data see the largest JIT gains. Game
decisions
also spend time in terrain and other host queries, so their overall gain is
smaller.
