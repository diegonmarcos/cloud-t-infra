# HSTS at the Cloudflare edge for every proxied hostname (#1215).
# Access (auth-cf, spec-zt) answers its own login redirects and the tunnel origins do not add the header,
# so the only layer that covers all of these responses is a response-header transform rule.
# Host list is derived, not retyped: proxied A/CNAME records from terraform.json plus the Zero Trust
# hostnames (only when the Zero Trust resources exist). max-age from terraform.json edge_hsts.
# No includeSubDomains (grey wildcard hosts are not all HTTPS-only), no preload.
locals {
  hsts_hosts = distinct(concat(
    [for r in local.config.dns_records.a_records : "${r.name}.diegonmarcos.com" if try(r.proxied, false)],
    [for r in local.config.dns_records.cname_records : "${r.name}.diegonmarcos.com" if try(r.proxied, false)],
    local.zt_on ? [local.zt.pilot_app.hostname, local.zt.broker_app.hostname] : [],
  ))
}

resource "cloudflare_ruleset" "edge_hsts" {
  zone_id     = var.cloudflare_zone_id
  name        = "edge HSTS"
  description = "Strict-Transport-Security on every Cloudflare-proxied hostname (#1215)."
  kind        = "zone"
  phase       = "http_response_headers_transform"

  rules {
    action      = "rewrite"
    description = "HSTS max-age ${local.config.edge_hsts.max_age} on proxied hosts (no includeSubDomains, no preload)"
    enabled     = true
    expression  = "(http.host in {${join(" ", [for h in local.hsts_hosts : "\"${h}\""])}})"
    action_parameters {
      headers {
        name      = "Strict-Transport-Security"
        operation = "set"
        value     = "max-age=${local.config.edge_hsts.max_age}"
      }
    }
  }
}
