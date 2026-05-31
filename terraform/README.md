# terraform/

Provisions the AWS-side infrastructure for the `ts.t11s.net` DNS service:

- 1 VPC per region (us-west-2, us-east-2), IPv6-only subnet, IGW, route table.
- 1 Route 53 private hosted zone (`ts.t11s.net`) associated with both VPCs.
- 1 reusable preauthorized Tailscale auth key, written to one SSM SecureString parameter per region.
- 1 IAM role allowing instances to read the SSM parameter.
- 1 `t4g.nano` per region with the Determinate NixOS AMI, IPv6-only, no public IPv4.

State is local. `terraform.tfstate` contains the tailscale key value; do not commit it. The repo `.gitignore` here excludes it.

## Required environment

Either:
- `TF_VAR_tailscale_oauth_client_id` + `TF_VAR_tailscale_oauth_client_secret` (recommended), **or**
- create a `secrets.auto.tfvars` (gitignored) with `tailscale_oauth_client_id` and `tailscale_oauth_client_secret`.

Plus standard AWS creds (env or `~/.aws/credentials`).

## Usage

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

After first apply, populate the Tailscale split-DNS UI with the two boxes' tailnet IPs (`terraform output dns_node_tailscale_ips` — populated after the boxes have joined).
