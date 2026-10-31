#!/usr/bin/env bash
# Publish sops-encrypted files from a runner clone of cloud-me-pvt-vault (#994).
#
#   vault-publish-encrypted.sh <vault-clone> <commit-msg> <path>...
#
# Stages <path>... in the clone and commits. Then:
#   - VAULT_WRITE_DEPLOY_KEY set (the clone was made with it): push to main.
#   - otherwise (only the read-only VAULT_DEPLOY_KEY exists): copy the changed files, CIPHERTEXT ONLY,
#     to $GITHUB_WORKSPACE/vault-out/<same path> for the workflow's 1-day artifact; an operator commits
#     them to the vault. Every changed file except *.txt must pass `sops filestatus` as encrypted and
#     must not contain a PEM key or a pbkdf2 digest, else nothing is handed back and the run fails.
# Prints paths and counts only.
set -euo pipefail
PVT="$1"; MSG="$2"; shift 2
cd "$PVT"
git config user.name "Claude"; git config user.email "noreply@anthropic.com"
git add -- "$@"
if git diff --cached --quiet; then echo "vault: nothing changed"; exit 0; fi
mapfile -t CHANGED < <(git diff --cached --name-only --diff-filter=AM)
mapfile -t DELETED < <(git diff --cached --name-only --diff-filter=D)
for f in "${CHANGED[@]}"; do
  case "$f" in *.txt) continue ;; esac
  sops filestatus "$f" | grep -q '"encrypted":true' || { echo "::error::$f is not sops-encrypted; refusing"; exit 1; }
  if grep -qE 'PRIVATE KEY|pbkdf2-sha512' "$f"; then echo "::error::plaintext secret material in $f; refusing"; exit 1; fi
done
git commit -q -m "$MSG"
if [ -n "${VAULT_WRITE_DEPLOY_KEY:-}" ]; then
  git push -q origin HEAD:main
  echo "vault: pushed ${#CHANGED[@]} changed, ${#DELETED[@]} deleted file(s) to cloud-me-pvt-vault main"
  exit 0
fi
OUT="${GITHUB_WORKSPACE:?}/vault-out"
rm -rf "$OUT"; mkdir -p "$OUT"
for f in "${CHANGED[@]}"; do mkdir -p "$OUT/$(dirname "$f")"; cp "$f" "$OUT/$f"; done
printf '%s\n' "${DELETED[@]}" > "$OUT/.deleted"
printf '%s\n' "$MSG" > "$OUT/.commit-msg"
echo "vault: no write key; ${#CHANGED[@]} encrypted file(s) (+${#DELETED[@]} deletion(s)) handed back as artifact vault-out for an operator commit"
