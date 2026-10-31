#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/vault-publish-encrypted.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# #994: 1_cicd/src/scripts/vault-publish-encrypted.sh (used by sso-oidc-issue / sso-oidc-deliver).
#   - a changed file sops does not report as encrypted (or carrying a PEM key / pbkdf2 digest) is refused,
#     nothing is pushed and nothing is handed back;
#   - with VAULT_WRITE_DEPLOY_KEY set the commit is pushed to the vault remote;
#   - without it nothing is pushed and ONLY the changed ciphertext files land in $GITHUB_WORKSPACE/vault-out.
# sops is stubbed: `sops filestatus F` reports encrypted iff F holds the marker ENC[ (the real sops answers
# from the file's sops metadata the same way). A local bare repo stands in for cloud-me-pvt-vault.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$ROOT/1_cicd/src/scripts/vault-publish-encrypted.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/sops" <<'S'
#!/bin/sh
[ "$1" = filestatus ] || exit 2
if grep -q 'ENC\[' "$2"; then echo '{"encrypted":true}'; else echo '{"encrypted":false}'; fi
S
chmod +x "$T/bin/sops"; export PATH="$T/bin:$PATH"
fail=0; ok(){ echo "  ok   $*"; }; bad(){ echo "  FAIL $*"; fail=1; }

setup() {
  rm -rf "$T/remote.git" "$T/pvt" "$T/ws"; mkdir -p "$T/ws"
  git init -q --bare -b main "$T/remote.git"
  git clone -q "$T/remote.git" "$T/pvt" 2>/dev/null
  ( cd "$T/pvt" && git checkout -q -b main && mkdir -p Identity/sso-oidc Other && echo 'old: ENC[x]' > Identity/sso-oidc/b.sops.json \
    && echo keep > Other/untouched.yaml && git add -A && git -c user.name=t -c user.email=t@t commit -q -m init && git push -q origin main 2>/dev/null )
}
remote_head() { git --git-dir="$T/remote.git" rev-parse main; }

# 1. plaintext refused
setup; before="$(remote_head)"
echo '{"secret": "plain"}' > "$T/pvt/Identity/sso-oidc/b.sops.json"
GITHUB_WORKSPACE="$T/ws" VAULT_WRITE_DEPLOY_KEY=k bash "$H" "$T/pvt" msg Identity/sso-oidc >/dev/null 2>&1 \
  && bad "plaintext file accepted" || { [ "$(remote_head)" = "$before" ] && [ ! -e "$T/ws/vault-out" ] && ok "plaintext file refused, nothing pushed or handed back" || bad "plaintext refused but side effects"; }

# 2. encrypted file carrying a PEM key refused
setup
printf 'ENC[x]\n-----BEGIN PRIVATE KEY-----\n' > "$T/pvt/Identity/sso-oidc/b.sops.json"
GITHUB_WORKSPACE="$T/ws" bash "$H" "$T/pvt" msg Identity/sso-oidc >/dev/null 2>&1 && bad "PEM key accepted" || ok "file with a PEM key refused"

# 3. write key -> pushed
setup; before="$(remote_head)"
echo 'new: ENC[y]' > "$T/pvt/Identity/sso-oidc/b.sops.json"; echo 'readme' > "$T/pvt/Identity/sso-oidc/README.txt"
GITHUB_WORKSPACE="$T/ws" VAULT_WRITE_DEPLOY_KEY=k bash "$H" "$T/pvt" msg Identity/sso-oidc >/dev/null 2>&1 \
  && [ "$(remote_head)" != "$before" ] && [ ! -e "$T/ws/vault-out" ] && ok "write key: pushed, no hand-back" || bad "write key path"

# 4. no write key -> hand-back of changed ciphertext only, nothing pushed
setup; before="$(remote_head)"
echo 'new: ENC[z]' > "$T/pvt/Identity/sso-oidc/b.sops.json"
GITHUB_WORKSPACE="$T/ws" VAULT_WRITE_DEPLOY_KEY= bash "$H" "$T/pvt" "the msg" Identity/sso-oidc Other >/dev/null 2>&1; rc=$?
files="$(cd "$T/ws/vault-out" 2>/dev/null && find . -type f ! -name '.*' | sort | tr '\n' ' ')"
[ "$rc" -eq 0 ] && [ "$(remote_head)" = "$before" ] && [ "$files" = "./Identity/sso-oidc/b.sops.json " ] \
  && grep -q 'ENC\[z\]' "$T/ws/vault-out/Identity/sso-oidc/b.sops.json" && grep -qx 'the msg' "$T/ws/vault-out/.commit-msg" \
  && ok "no write key: only the changed ciphertext handed back, nothing pushed" || bad "hand-back path (rc=$rc files=$files)"

# 5. nothing changed -> no-op
setup
GITHUB_WORKSPACE="$T/ws" bash "$H" "$T/pvt" msg Identity/sso-oidc 2>/dev/null | grep -q 'nothing changed' && [ ! -e "$T/ws/vault-out" ] && ok "no change: no-op" || bad "no-op path"
exit "$fail"
