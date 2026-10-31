#!/usr/bin/env bash
# #1147: the sso-oidc-issue workflow must generate the JWKS key and the client secrets ONLY on the runner and
# publish them ONLY sops-encrypted to the private data repo. Static checks on the source workflow:
#   - sops-encrypts the bundle and verifies the output carries no PRIVATE KEY;
#   - writes to cloud-me-pvt-vault (Identity/sso-oidc), with the vault write deploy key, and nowhere in this public repo;
#   - masks every generated secret, uploads no artifact, echoes no secret material;
#   - refuses to overwrite an existing bundle unless rotate=true;
#   - reads client_id/secret_var from the public oidc-clients.json (no secret list duplicated here).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$ROOT/1_cicd/src/cicd/sso-oidc-issue.yml"
fail=0; ok(){ echo "  ok   $*"; }; bad(){ echo "  FAIL $*"; fail=1; }
[ -f "$WF" ] || { echo "FAIL: $WF missing"; exit 1; }
grep -q 'sops --encrypt' "$WF" && ok "sops-encrypts the bundle" || bad "no sops --encrypt"
grep -q "grep -q 'PRIVATE KEY' sso-oidc.sops.json" "$WF" && ok "checks the sops file for plaintext keys" || bad "no plaintext-key check"
grep -q 'cloud-me-pvt-vault' "$WF" && grep -q 'VAULT_WRITE_DEPLOY_KEY' "$WF" && ok "publishes to the private vault repo with the deploy key" || bad "private repo / deploy key missing"
grep -q '^permissions:' "$WF" && grep -A1 '^permissions:' "$WF" | grep -q 'contents: read' && ok "workflow token is read-only (nothing is committed to the public repo)" || bad "permissions must be contents: read"
# #994: the only artifact allowed is the ciphertext hand-back (no vault write key): vault-out, 1 day, behind the
# helper that refuses any changed file sops does not report as encrypted.
HELPER="$ROOT/1_cicd/src/scripts/vault-publish-encrypted.sh"
n_art="$(grep -c 'upload-artifact' "$WF")"
if [ "$n_art" -eq 0 ]; then ok "uploads no artifact"
elif [ "$n_art" -eq 1 ] && grep -q 'name: vault-out' "$WF" && grep -q 'retention-days: 1' "$WF" && grep -q 'vault-publish-encrypted.sh' "$WF" \
     && grep -q 'sops filestatus' "$HELPER" && grep -q 'not sops-encrypted; refusing' "$HELPER"; then ok "only artifact = vault-out ciphertext hand-back (1 day, sops filestatus enforced)"
else bad "unexpected artifact upload"; fi
grep -q 'add-mask' "$WF" && ok "masks generated secrets" || bad "secrets not masked"
grep -Eq 'echo .*\$\{?(pw|VAULT_WRITE_DEPLOY_KEY)|echo .*(jwks\.key|plain\.json)' "$WF" && bad "echoes secret material" || ok "echoes no secret material"
grep -E 'print\(' "$WF" | grep -v 'add-mask' | grep -Eq 'pw|jwks_key_pem|secret' && bad "prints secret material" || ok "prints only masks"
grep -q 'ROTATE" != "true"' "$WF" && ok "refuses to overwrite without rotate=true" || bad "no rotate guard"
grep -q 'oidc-clients.json' "$WF" && ok "client list comes from the public oidc-clients.json" || bad "client list not read from oidc-clients.json"
grep -q 'pbkdf2-sha512' "$WF" && ok "emits the Authelia pbkdf2-sha512 digest" || bad "no digest"
# the public repo must hold no bundle
leak="$(cd "$ROOT" && git ls-files 2>/dev/null | grep -Ei 'sso-oidc.*\.(json|pem|key)$|oidc[-_]?jwks.*\.(pem|key)$' | grep -v '\.sops\.' || true)"
[ -z "$leak" ] && ok "no SSO key/secret file tracked in this repo" || bad "tracked: $leak"
exit "$fail"
