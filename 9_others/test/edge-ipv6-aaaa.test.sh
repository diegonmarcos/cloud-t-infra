#!/usr/bin/env bash
# edge-ipv6-aaaa.test.sh — the public edge is reachable from an IPv6-only uplink.
#
# #519: on IPv6-only WiFi the phone could reach nothing in the fleet. Every
# public name resolved to the v4-only 129.151.228.66 while oci-analytics had a
# routable v6 all along; there was no AAAA, and the OCI security list dropped
# v6 tcp/443 at the VNIC (host ip6 filter counter: 0 packets).
#
# Asserts, reading the PUBLISHED values (Cloudflare DoH) — not the declaration:
#   1. every a_record that points at the edge (no per-record `ip` override)
#      publishes an AAAA equal to its `ip6`, else the global `proxy_ip6`, and
#      its A still equals proxy_ip (the AAAA must be a twin, not a replacement)
#      A record declared `proxied: true` (c3-pub, the ONLY orange-cloud name,
#      #1104) publishes Cloudflare anycast addresses, never the origin: it must
#      resolve to Cloudflare ranges on BOTH A and AAAA, and must NOT leak the
#      origin proxy_ip / proxy_ip6 (that would defeat the proxy).
#   2. the OCI security list admits ::/0 on every tcp port it admits 0.0.0.0/0
#      for HTTPS (443) — an AAAA to a closed port is worse than none: happy
#      eyeballs clients stall on it before falling back.
# The live v6 connect itself cannot be tested here: GitHub-hosted runners have
# no IPv6. Verify that with `curl -6` from a mesh host.
set -euo pipefail

# Upward search, not ../.. — build.sh also renders this file to 9_others/dist/test/.
ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
CF="${CF_JSON:-$ROOT/c_vps/ba-clo_cloudflare/src/terraform.json}"
OCI="${OCI_JSON:-$ROOT/c_vps/vps_oci/src/terraform.json}"
DOH="${DOH_URL:-https://cloudflare-dns.com/dns-query}"

fail=0
bad() { echo "FAIL: $*"; fail=1; }

domain=$(jq -r .domain "$CF")
v4=$(jq -r .proxy_ip "$CF")
v6=$(jq -r '.proxy_ip6 // empty' "$CF")
[ -n "$v6" ] || bad "proxy_ip6 is not declared in ${CF#$ROOT/}"

resolve() { # name type -> sorted answers of that type
  local code; code=$([ "$2" = A ] && echo 1 || echo 28)
  curl -fsS -m 10 -H 'accept: application/dns-json' "$DOH?name=$1&type=$2" \
    | jq -r --argjson t "$code" '[.Answer[]? | select(.type == $t) | .data] | sort | .[]'
}

# Cloudflare anycast: v6 2606:4700::/32 + 2a06:98c1::/32; v4 104.16/12, 172.64/13, 162.158/15, 188.114.96/20
CF_V4='^(104\.(1[6-9]|2[0-9]|3[01])|172\.(6[4-9]|7[01])|162\.15[89]|188\.114\.(9[6-9]|1[01][0-9]))\.'
CF_V6='^(2606:4700:|2a06:98c1:)'

checked=0
while IFS=$'\t' read -r name proxied ip6; do
  case "$name" in
    "$domain") fqdn="$domain" ;;
    "*")       fqdn="aaaa-probe-$RANDOM.$domain" ;;   # the wildcard, via a label nothing else claims
    *)         fqdn="$name.$domain" ;;
  esac
  want6="${ip6:-$v6}"
  got6=$(resolve "$fqdn" AAAA | tr '\n' ' ')
  got4=$(resolve "$fqdn" A | tr '\n' ' ')
  if [ "$proxied" = true ]; then
    [ -n "$got6" ] && ! grep -Evq "$CF_V6" < <(tr ' ' '\n' <<<"$got6" | sed '/^$/d')  || bad "$fqdn is proxied: AAAA = [${got6% }], want only Cloudflare 2606:4700::/32 | 2a06:98c1::/32"
    [ -n "$got4" ] && ! grep -Evq "$CF_V4" < <(tr ' ' '\n' <<<"$got4" | sed '/^$/d')  || bad "$fqdn is proxied: A = [${got4% }], want only Cloudflare anycast ranges"
    [[ " $got4$got6" != *" $v4 "* && " $got4$got6" != *" $v6 "* ]] || bad "$fqdn is proxied but publishes the origin address"
    checked=$((checked + 1))
    continue
  fi
  [[ " $got6" == *" $want6 "* ]] || bad "$fqdn AAAA = [${got6% }], want $want6"
  [[ " $got4" == *" $v4 "* ]]    || bad "$fqdn A = [${got4% }], want $v4 (AAAA must not replace A)"
  checked=$((checked + 1))
done < <(jq -r '.dns_records.a_records[] | select(has("ip") | not) | [.name, (.proxied // false), (.ip6 // "")] | @tsv' "$CF")
[ "$checked" -gt 0 ] || bad "no edge a_records found in ${CF#$ROOT/} — nothing was checked"

twins=$(jq -r '.security_rules.ingress as $r
  | [$r[] | select(.source == "0.0.0.0/0" and .protocol == "6" and .port == 443)] | length as $v4
  | [$r[] | select(.source == "::/0"      and .protocol == "6" and .port == 443)] | length as $v6
  | "\($v4) \($v6)"' "$OCI")
read -r n4 n6 <<<"$twins"
[ "$n4" -gt 0 ] || bad "no 0.0.0.0/0 tcp/443 ingress in ${OCI#$ROOT/} — edge rule moved? update this tester"
[ "$n6" -gt 0 ] || bad "${OCI#$ROOT/} admits tcp/443 from 0.0.0.0/0 but not from ::/0 — the AAAA points at a closed port"

[ "$fail" -eq 0 ] && echo "OK: $checked edge names publish AAAA $v6 beside A $v4; OCI admits ::/0 tcp/443"
exit "$fail"
