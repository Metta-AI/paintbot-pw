#!/bin/zsh
cd /tmp/claude-501/pw-xp
for i in $(seq 1 60); do
  out=$(coworld xp-request create dist/jev-xp/a7-echo-odd.json --json 2>&1)
  xid=$(echo "$out" | grep -oE 'xreq_[0-9a-f-]{36}' | head -1)
  if [ -n "$xid" ]; then
    python3 - "$xid" <<'PY'
import json, sys, pathlib
p = pathlib.Path("/tmp/claude-501/pw-xp/dist/jev-xp/requests.json")
m = json.loads(p.read_text())
m[sys.argv[1]] = {"arm": "a7-echo", "candidate_even": False}
p.write_text(json.dumps(m, indent=2) + "\n")
print(f"manifest now has {len(m)} requests")
PY
    echo "a7-echo-odd created: $xid"
    exit 0
  fi
  sleep 120
done
echo "a7-echo-odd STILL FAILING after 60 attempts: $(echo "$out" | head -2)"
exit 1
