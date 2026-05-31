variable "tailnet" {
  description = "Tailscale tailnet (e.g. dab-ling.ts.net)"
  type        = string
  default     = "dab-ling.ts.net"
}

variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth client ID (scope: auth_keys, tagOwner of tag:dns-node)"
  type        = string
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Tailscale OAuth client secret"
  type        = string
  sensitive   = true
}

variable "ts_dns_zone" {
  description = "Private DNS zone served on the tailnet"
  type        = string
  default     = "ts.t11s.net"
}

variable "turing_addr_v4" {
  description = "Tailscale v4 100.x address for turing"
  type        = string
}

variable "turing_addr_v6" {
  description = "Tailscale v6 fd7a:115c:… address for turing"
  type        = string
}

variable "juicy_j_addr_v4" {
  description = "Tailscale v4 100.x address for juicy-j"
  type        = string
}

variable "juicy_j_addr_v6" {
  description = "Tailscale v6 fd7a:115c:… address for juicy-j"
  type        = string
}

variable "dns_usw2_toplevel_path" {
  description = "Store path of the dns-usw2 system toplevel, signed and uploaded to s3://burk3-dns-cache by scripts/deploy-dns.sh"
  type        = string
}

variable "dns_use2_toplevel_path" {
  description = "Store path of the dns-use2 system toplevel, signed and uploaded to s3://burk3-dns-cache by scripts/deploy-dns.sh"
  type        = string
}

variable "dns_cache_public_key" {
  description = "Public half of the closure signing keypair (matches t11s.dnsServer.cachePublicKey in the dns-server module)"
  type        = string
  default     = "burk3-dns-cache:ZAWST40z9ARFmzxrLHyLHKzqpD+FzM7hxkCkPbrc4Bs="
}

variable "dns_cache_url" {
  description = "S3 substituter URL for the closure cache (matches t11s.dnsServer.cacheUrl in the dns-server module)"
  type        = string
  default     = "s3://burk3-dns-cache?region=us-west-2&endpoint=s3.dualstack.us-west-2.amazonaws.com"
}
