#!/usr/bin/env bash
# Map-size x agent-count sweep for tests/bench_paintbot_maps.nim. Runs inside the Nim image
# with the repo at the working directory; writes tmp/scale/results.jsonl.
set -uo pipefail
TICKS=${BENCH_TICKS:-2400}
PAR=${BENCH_PAR:-8}
SEATS="${BENCH_SEATS:-16 32 64 128}"
mkdir -p tmp/scale/bin tmp/scale/runs
for n in $SEATS; do
  sed -E "s/^dim (oldX|oldY|lastSeen)\(16\)/dim \1($n)/; s/while (i|e) < 16\$/while \1 < $n/" \
    coworld/paintbot/players/base.bas > tmp/scale/base$n.bas
  nim c --hints:off --warnings:off -d:release -d:pwBench -d:pwBenchMaps -d:pwSeats=$n \
    --nimcache:/tmp/nc-$n -o:tmp/scale/bin/bench$n tests/bench_paintbot_maps.nim || exit 1
done
echo BUILT
jobs=()
for map in twin-mesas deep-forest; do
  for area in 1 2p5 5 10 20; do
    name=$map; [ $area != 1 ] && name=a$area-$map
    for n in $SEATS; do jobs+=("$n $name $area $map"); done
  done
done
run() {
  set -- $1
  local n=$1 name=$2 area=$3 family=$4 out=tmp/scale/runs/$2-$1.txt
  local t0=$(date +%s.%N)
  BENCH_TICKS=$TICKS timeout 2400 tmp/scale/bin/bench$n --map:$name --seed 2026 \
    --bot tmp/scale/base$n.bas:$n > $out 2>&1
  local rc=$? t1=$(date +%s.%N)
  python3 - "$out" "$n" "$name" "$area" "$family" "$rc" "$t0" "$t1" <<'PY' >> tmp/scale/results.jsonl
import sys, re, json
out, n, name, area, family, rc, t0, t1 = sys.argv[1:]
t = open(out).read()
d = dict(re.findall(r"(\w+)=(\S+)", t.split("\n")[0])) if t.startswith("map=") else {}
d2 = dict(re.findall(r"(\w+)=(\S+)", next((l for l in t.split("\n") if l.startswith("seats=")), "")))
probes = {}
for line in t.split("\n"):
    m = re.match(r"(\w+)\s+([\d.]+) ms total\s+([\d.]+) ms/tick\s+(\d+) calls\s+([\d.]+) us/call", line)
    if m: probes[m.group(1)] = dict(ms_tick=float(m.group(3)), calls=int(m.group(4)), us_call=float(m.group(5)))
print(json.dumps(dict(seats=int(n), map=name, family=family, area=float(area.replace("p", ".")), rc=int(rc),
  wall_s=float(t1)-float(t0), line=d, extra=d2, probes=probes,
  tail=t[-400:] if int(rc) != 0 or not d else "")))
PY
  echo "done seats=$n map=$name rc=$rc"
}
export -f run; export TICKS
printf '%s\n' "${jobs[@]}" | xargs -P $PAR -I{} bash -c 'run "{}"'
echo ALLDONE
