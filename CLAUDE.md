# cloud-infra

Single-purpose flake hosting two AWS DNS nodes for the tailnet's `ts.t11s.net` zone. Plain nixpkgs flake (no snowfall — this repo is small enough that auto-discovery would be ceremony). One module (`modules/dns-node.nix`) brings up everything; both hosts use it with only `networking.hostName` differing.

Cloud cattle. Operator-driven deploys via `scripts/deploy-dns.sh`. Closures get signed locally and pushed to `s3://burk3-dns-cache`; the instances substitute via their IAM role's `s3:GetObject` permission and verify against `burk3-dns-cache:ZAWST40z…`.

Terraform state is local (`terraform/terraform.tfstate`, gitignored). The terraform-managed resources are the S3 cache bucket, two VPCs (us-west-2 + us-east-2, dual-stack so IMDS works), the Route 53 private hosted zone with the host records, the IAM role + instance profile + SSM parameter for the tailscale auth key, and the EC2 instances themselves with user-data that pulls the toplevel closure from S3 and activates it.

When making changes:
- Edit `modules/dns-node.nix` for box config; rebuild and re-deploy via `./scripts/deploy-dns.sh`
- Edit `terraform/*.tf` for infra; `terraform apply` directly or via `deploy-dns.sh`
- Manual setup (AWS creds, Tailscale ACL, signing key) lives in `docs/manual-setup.md`
