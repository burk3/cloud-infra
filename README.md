# cloud-infra

AWS DNS-node infrastructure for the `ts.t11s.net` tailnet zone.

Two `t4g.nano` boxes (`dns-usw2` in us-west-2, `dns-use2` in us-east-2) running NixOS + CoreDNS, forwarding `ts.t11s.net` queries from the tailnet to a Route 53 private hosted zone associated with both VPCs. Tailnet clients reach the boxes via Tailscale split-DNS pointing at their tailnet IPs.

## Repo layout

| Path | Purpose |
|---|---|
| `flake.nix` | `nixosConfigurations.dns-{usw2,use2}` + operator devShell |
| `modules/dns-node.nix` | Self-contained role module: CoreDNS, tailscale, openssh, S3 substituter, tailscale-bootstrap |
| `terraform/` | Per-region VPC + Route 53 + IAM + SSM + S3 cache bucket + EC2 instances |
| `scripts/deploy-dns.sh` | Operator entry point: build via nixbuild.net → sign + push to S3 → `terraform apply` |
| `docs/manual-setup.md` | One-time out-of-band setup (AWS creds, Tailscale ACL/OAuth, nixbuild token, signing key) |

## Quick deploy

```sh
nix develop
# (terraform, awscli2, jq on PATH)

# First-time setup is in docs/manual-setup.md.

./scripts/deploy-dns.sh
```

## Background

This repo was split out of [`all-the-nix`](https://github.com/burk3/all-the-nix) on 2026-05-30 to keep cloud cattle decoupled from at-home pets. See `docs/superpowers/plans/2026-05-30-split-from-all-the-nix.md` for the migration history.
