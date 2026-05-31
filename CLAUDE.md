# cloud-infra

Single-purpose flake hosting two AWS DNS nodes for the tailnet's `ts.t11s.net` zone. Plain nixpkgs flake (no snowfall — too small to justify auto-discovery ceremony).

Two modules:
- `modules/dns-node.nix` — role: CoreDNS + firewall + nameservers + S3 substituter
- `modules/tailscale-aws-ssm.nix` — reusable: tailscaled on AWS with EBS-persisted state + SSM-stored auth key

Per-host config is just `networking.hostName` + `cloud.tailscaleAwsSsm = { enable = true; tags = ["tag:dns-node"]; }` (set inside `dns-node.nix`, which imports the tailscale module).

## Tailscale identity model

Each host has a per-region EBS volume (terraform-managed) mounted at `/var/lib/tailscale`. That volume carries `tailscaled.state` (machine key + node key + prefs) across instance replacements, so Tailscale sees one continuous device per host. Boot chain:

```
mount-tsdata.service   wait for EBS attach, format on first use, mount /var/lib/tailscale
  -> tailscaled.service   reads state from EBS
  -> tailscale-join.service   `tailscale up --authkey` only if NoState/NeedsLogin
  -> tailscale-wait-settled.service   block until BackendState=Running
  -> tailscale-settled.target   activated; downstream units gate on this
       -> coredns.service
```

`tailscale-settled.target` is the ordering primitive — anything that needs a working tailnet uses `after = wants = [ "tailscale-settled.target" ]`. SSM is read-only for these boxes: just the shared auth key at `/dns-nodes/tailscale-authkey`.

A brand-new host (new region/AZ, fresh hostname) gets its identity from `tailscale-join`'s authkey branch on first boot of its (empty) EBS volume. No SSM-state seeding involved.

## Deploy model

Operator-driven via `scripts/deploy-dns.sh`. Closures get signed locally and pushed to `s3://burk3-dns-cache`; instances substitute via their IAM role's `s3:GetObject` and verify against `burk3-dns-cache:ZAWST40z…`. Terraform state lives in `s3://burk3-cloud-infra-tfstate/cloud-infra.tfstate` with native S3 locking (`use_lockfile = true`); the bucket is bootstrapped out-of-band (see `docs/manual-setup.md`).

Terraform owns: VPCs (us-west-2 + us-east-2, dual-stack for IMDS), Route 53 private hosted zone + records, IAM role/profile + SSM auth-key parameter, S3 cache bucket, per-host EBS volume + attachment, EC2 instances with user-data that pulls + activates.

## When making changes

- **NixOS module**: edit `modules/dns-node.nix` (role bits) or `modules/tailscale-aws-ssm.nix` (tailscale bits). Rebuild + redeploy via `./scripts/deploy-dns.sh` (full apply, recreates instances) OR live-deploy via SSH + `nix copy --from s3://… + switch-to-configuration boot + reboot` (faster, no instance recreate, EBS state persists).
- **Infra**: edit `terraform/*.tf`. `terraform apply` directly or via `deploy-dns.sh`.
- **Manual setup**: AWS creds, Tailscale ACL/SSH rules, signing key — `docs/manual-setup.md`.

## Operator-side AWS credential gotcha

Nix's S3 substituter doesn't speak SSO. `aws sts get-caller-identity` works fine with `AWS_PROFILE=tactilecactus`, but `nix copy --to s3://…` will 403. Workaround:

```sh
eval "$(aws configure export-credentials --format env)"
```

before running the push. Worth patching into `deploy-dns.sh` eventually.
