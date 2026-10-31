#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/sso-oidc-bundle-add.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# #994: sso-oidc-issue mode=add must APPEND secrets for newly declared clients and keep everything else.
# Behavioural test of 1_cicd/src/scripts/sso-oidc-bundle.py on synthetic data (no real secret is used):
#   1. every existing client entry (secret, digest, secret_var) and the JWKS key are byte-identical;
#   2. a client in the bundle but no longer declared is kept (add never removes);
#   3. each missing declared client gets a fresh secret whose digest verifies (Authelia pbkdf2-sha512);
#   4. new secrets are masked (::add-mask::) and no secret appears in any other output line;
#   5. nothing missing -> exit 3 and no output file (the workflow then commits nothing).
# Then MUTATIONS of the script (overwrite existing, rotate the key, drop undeclared, wrong digest, no mask,
# write on no-op) must each make the checks fail; a surviving mutant fails this test.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/1_cicd/src/scripts/sso-oidc-bundle.py"
WF="$ROOT/1_cicd/src/cicd/sso-oidc-issue.yml"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

cat > "$T/clients.json" <<'J'
{"clients": [
 {"client_id": "a", "secret_var": "VAR_A"},
 {"client_id": "b", "secret_var": "VAR_B"},
 {"client_id": "new1", "secret_var": "VAR_NEW1"},
 {"client_id": "new2", "secret_var": "VAR_NEW2"}]}
J
cat > "$T/old.json" <<'J'
{"issued": "2026-01-01T00:00:00Z", "jwks_key_pem": "FAKE-JWKS-KEY-FIXTURE",
 "clients": {
  "a": {"secret_var": "VAR_A", "secret": "fixture-secret-a", "digest": "fixture-digest-a"},
  "b": {"secret_var": "VAR_B", "secret": "fixture-secret-b", "digest": "fixture-digest-b"},
  "gone": {"secret_var": "VAR_GONE", "secret": "fixture-secret-gone", "digest": "fixture-digest-gone"}}}
J
cat > "$T/full.json" <<'J'
{"clients": [{"client_id": "a", "secret_var": "VAR_A"}, {"client_id": "b", "secret_var": "VAR_B"}]}
J

check() { # check <script> -> 0 when every property holds
  local s="$1" rc out
  rm -f "$T/out.json" "$T/noop.json"
  out="$(python3 -I "$s" add "$T/clients.json" "$T/old.json" "$T/out.json" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "    add rc=$rc"; return 1; }
  python3 -I - "$T/old.json" "$T/out.json" "$out" <<'PY' || return 1
import base64, hashlib, json, sys
old, new, out = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
def die(m): print("    " + m); sys.exit(1)
if new.get("jwks_key_pem") != old["jwks_key_pem"]: die("JWKS key changed")
if new.get("issued") != old["issued"]: die("issued changed")
for cid, c in old["clients"].items():
    if new["clients"].get(cid) != c: die("existing client %s changed or dropped" % cid)
masks = {l[len("::add-mask::"):] for l in out.splitlines() if l.startswith("::add-mask::")}
for cid in ("new1", "new2"):
    c = new["clients"].get(cid)
    if not c: die("missing client %s not added" % cid)
    if c["secret_var"] != "VAR_" + cid.upper(): die("wrong secret_var for " + cid)
    if len(c["secret"]) < 40: die("secret too short for " + cid)
    p = c["digest"].split("$")
    if p[1:3] != ["pbkdf2-sha512", "310000"]: die("digest format for " + cid)
    unb = lambda x: base64.b64decode(x.replace(".", "+") + "=" * (-len(x) % 4))
    if hashlib.pbkdf2_hmac("sha512", c["secret"].encode(), unb(p[3]), 310000, 64) != unb(p[4]): die("digest does not verify for " + cid)
    if c["secret"] not in masks: die("new secret not masked: " + cid)
if new["clients"]["new1"]["secret"] == new["clients"]["new2"]["secret"]: die("secrets reused")
for l in out.splitlines():
    if l.startswith("::add-mask::"): continue
    for c in new["clients"].values():
        if c["secret"] in l or c["digest"] in l: die("secret material printed")
if set(new["clients"]) != {"a", "b", "gone", "new1", "new2"}: die("unexpected client set")
PY
  python3 -I "$s" add "$T/full.json" "$T/old.json" "$T/noop.json" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || { echo "    no-op rc=$rc (want 3)"; return 1; }
  [ ! -e "$T/noop.json" ] || { echo "    no-op wrote a bundle"; return 1; }
  return 0
}

fail=0
if check "$SCRIPT"; then echo "  ok   add-only keeps key + existing secrets, adds verified secrets, no-op exits 3"; else echo "  FAIL add-only properties"; fail=1; fi

mutate() { # mutate <name> <python-replace-from> <to>
  local m="$T/mut.py"
  python3 -I - "$SCRIPT" "$m" "$2" "$3" <<'PY' || { echo "  FAIL mutation '$1' did not apply"; fail=1; return; }
import sys
s = open(sys.argv[1]).read(); a, b = sys.argv[3], sys.argv[4]
if a not in s: sys.exit(1)
open(sys.argv[2], "w").write(s.replace(a, b, 1))
PY
  if check "$m" >/dev/null 2>&1; then echo "  FAIL mutant survived: $1"; fail=1; else echo "  ok   mutant killed: $1"; fi
}
mutate "overwrite existing"   'if cid in b["clients"]:'                'if False:'
mutate "rotate JWKS key"      'b.setdefault("added", [])'              'b.__setitem__("jwks_key_pem", "x"); b.setdefault("added", [])'
mutate "drop undeclared"      'b.setdefault("added", [])'              'b["clients"].pop("gone", None); b.setdefault("added", [])'
mutate "wrong digest"         'adapt(salt) + "$" + adapt(dk)'          'adapt(salt) + "$" + adapt(salt)'
mutate "no mask"              'print("::add-mask::" + pw, flush=True)' 'pass'
mutate "write on no-op"       '    if not added:'                      '    json.dump(b, open(out_path, "w"))
    if not added:'
mutate "no-op exit 0"         'return 3'                               'return 0'

grep -q 'BUNDLE_PY" add' "$WF" && grep -q '"\$rc" -eq 3' "$WF" && echo "  ok   workflow mode=add runs the script and commits nothing on exit 3" || { echo "  FAIL workflow add wiring"; fail=1; }
grep -q 'BUNDLE_PY" new' "$WF" && grep -q 'ROTATE" != "true"' "$WF" && echo "  ok   workflow mode=new keeps the rotate guard" || { echo "  FAIL workflow new wiring"; fail=1; }
exit "$fail"
