#!/usr/bin/env bash
# Ticket #1104/#1100: no shipped MCP config or client hook may depend on the legacy
# hosts api.diegonmarcos.com / mcp.diegonmarcos.com. Public fallback is
# https://c3-pvt.diegonmarcos.com/<container>/... (cookie or bearer). The deriver
# may name the legacy MCP host once, only to rewrite it.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
bad=0
for f in 0_apps/src/root/mcp.json 0_apps/src/root/mcp.optin.json .mcp.json 0_apps/dist/dotfiles/root/mcp.json \
         1_cloud-configs/dist/mcp.json 1_cloud-configs/dist/mcp.project.json 1_cloud-configs/dist/mcp.optin.json \
         .claude/hooks/c3/ai-usage-post.sh 0_apps/src/claude/hooks/c3/ai-usage-post.sh 0_apps/dist/dotfiles/claude/hooks/c3/ai-usage-post.sh; do
  [ -f "$ROOT/$f" ] || continue
  if grep -nE '(^|[^a-z0-9-])(api|mcp)\.diegonmarcos\.com' "$ROOT/$f"; then echo "FAIL $f: legacy host"; bad=1; fi
done
D="$ROOT/1_cloud-configs/src/derive/derive-mcp-json.ts"
n=$(grep -c "mcp\.diegonmarcos\.com" "$D" || true)
[ "$n" = 1 ] || { echo "FAIL derive-mcp-json.ts names the legacy host $n times (want exactly the one rewrite constant)"; bad=1; }
grep -q "PVT_HOST *= *'c3-pvt.diegonmarcos.com'" "$D" || { echo "FAIL deriver lost the c3-pvt host"; bad=1; }
[ "$bad" = 0 ] && echo "ok: no legacy api./mcp. host in shipped MCP config or hooks"
exit $bad
