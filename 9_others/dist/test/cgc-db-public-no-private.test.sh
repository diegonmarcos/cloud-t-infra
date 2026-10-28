#!/usr/bin/env bash
# Guard: the PUBLIC cgc-db matrix never contains a private repo (private_repos).
# Extracts the real matrix jq filter from the workflow source and runs it on a fixture.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WF="$ROOT/1_cicd/src/cicd/cgc-db-index.yml"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok - $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL - $1"; }
F=$(grep -o "jq -c '(\.runtime\.octocode\.private_repos.*' \"\$BJ\"" "$WF" | head -1 | sed "s/^jq -c '//; s/' \"\$BJ\"\$//")
[ -n "$F" ] && ok "matrix filter found in workflow source" || { no "matrix filter found"; exit 1; }
FIX='{"runtime":{"octocode":{"index_repos":["pub-a","priv-b","pub-c","priv-d"],"private_repos":["priv-b","priv-d"]}}}'
OUT=$(printf '%s' "$FIX" | jq -c "$F")
[ "$OUT" = '["pub-a","pub-c"]' ] && ok "private repos removed, order kept" || no "got $OUT"
OUT=$(printf '%s' '{"runtime":{"octocode":{"index_repos":["a"]}}}' | jq -c "$F")
[ "$OUT" = '["a"]' ] && ok "no private_repos key keeps all" || no "got $OUT"
UP="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
G=$(grep -o "jq -r --arg inc .*\"\$BJ\" | while" "$UP" | head -1 | sed "s/^jq -r --arg inc \"[^\"]*\" '//; s/' \"\$BJ\" | while\$//")
[ -n "$G" ] && ok "clone-loop filter found in update script" || no "clone-loop filter found"
FX='{"runtime":{"octocode":{"private_repos":["priv"],"repo_map":{"pub":"pub","priv":"priv"}}}}'
O=$(printf '%s' "$FX" | jq -r --arg inc 0 "$G" | tr '\n' ',')
[ "$O" = "pub pub," ] && ok "public clone set excludes private" || no "public clone got $O"
O=$(printf '%s' "$FX" | jq -r --arg inc 1 "$G" | wc -l)
[ "$O" = 2 ] && ok "CGC_INCLUDE_PRIVATE=1 keeps private" || no "pvt clone got $O"
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
