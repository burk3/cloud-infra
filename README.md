# cloud-infra

AWS DNS-node infrastructure for the `ts.t11s.net` tailnet zone.

Two `t4g.nano` boxes (`dns-usw2` in us-west-2, `dns-use2` in us-east-2) running NixOS + CoreDNS, forwarding `ts.t11s.net` queries from the tailnet to a Route 53 private hosted zone associated with both VPCs. Tailnet clients reach the boxes via Tailscale split-DNS pointing at their tailnet IPs.

Each host keeps a per-region EBS volume mounted at `/var/lib/tailscale`, so its Tailscale node identity (and therefore tailnet IP) survives instance replacements.

## Repo layout

| Path | Purpose |
|---|---|
| `flake.nix` | `nixosConfigurations.dns-{usw2,use2}` + operator devShell |
| `modules/dns-node.nix` | DNS role: CoreDNS, firewall, nameservers, S3 substituter |
| `modules/tailscale-aws-ssm.nix` | Reusable: tailscaled on AWS with EBS-persisted state, SSM-stored auth key, `tailscale-settled.target` |
| `terraform/` | VPC × 2 + Route 53 + IAM + SSM + S3 cache + EBS volumes + EC2 |
| `scripts/deploy-dns.sh` | Build via nixbuild.net → sign + push to S3 → `terraform apply` |
| `docs/manual-setup.md` | One-time out-of-band setup (AWS creds, Tailscale ACL/SSH/OAuth, nixbuild token, signing key) |

## Quick deploy

```sh
nix develop
# (terraform, awscli2, jq on PATH)

# First-time setup is in docs/manual-setup.md.

./scripts/deploy-dns.sh
```

For NixOS-only changes (no infra), faster path: build the new closure, push to S3, then live-deploy without recreating instances:

```sh
nix build .#nixosConfigurations.dns-usw2.config.system.build.toplevel
eval "$(aws configure export-credentials --format env)"   # SSO -> static creds for nix's S3 client
NEW=$(nix eval --raw .#nixosConfigurations.dns-usw2.config.system.build.toplevel)
nix copy --to "s3://burk3-dns-cache?region=us-west-2&secret-key=$HOME/.config/nix-cache/burk3-dns-cache.secret" "$NEW"
ssh root@<tailnet-ip> "
  nix --extra-experimental-features nix-command copy --from 's3://burk3-dns-cache?region=us-west-2&endpoint=s3.dualstack.us-west-2.amazonaws.com' $NEW &&
  nix-env --profile /nix/var/nix/profiles/system --set $NEW &&
  $NEW/bin/switch-to-configuration boot
"
ssh root@<tailnet-ip> 'nohup sh -c "sleep 2 && systemctl reboot" >/dev/null 2>&1 &'
```

EBS-mounted `/var/lib/tailscale` survives the reboot → same tailnet identity, same IP.

## Adding a new DNS node

The `tailscale-aws-ssm` module's contract is: provide a hostname + an attached EBS volume + an SSM auth key, and the box boots into the tailnet with a fresh identity on its first ever boot. No manual seeding.

1. Add a new `mkDnsNode "dns-<name>"` in `flake.nix`.
2. Add VPC + subnet + EBS volume + attachment + instance for the new region in `terraform/`.
3. `terraform apply`. New box comes up at a fresh tailnet IP.
4. Update Tailscale admin DNS to add the new nameserver IP for `ts.t11s.net`.

## Background

This repo was split out of [`all-the-nix`](https://github.com/burk3/all-the-nix) on 2026-05-30 to keep cloud cattle decoupled from at-home pets. See `docs/superpowers/plans/2026-05-30-split-from-all-the-nix.md` for the migration history.
