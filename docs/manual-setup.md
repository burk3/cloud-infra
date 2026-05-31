# Manual / out-of-band setup for the AWS DNS work

This file lists every step that requires a browser, a dashboard, or interactive auth — the things `scripts/deploy-dns.sh` can't do on its own.

---

## Do before execution

### 1. AWS account credentials on the operator machine

Confirm `aws sts get-caller-identity` works in this dev shell. If it doesn't:

- Either set `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` + `AWS_DEFAULT_REGION` in the environment.
- Or configure a profile in `~/.aws/credentials` and export `AWS_PROFILE=<name>`.

The IAM principal needs permissions for VPC + subnet + IGW + route tables, EC2, IAM (create roles + policies + instance profiles), Route 53 (private hosted zones + records), and SSM Parameter Store (SecureString create/read). For a personal account, `AdministratorAccess` on a user is the path of least resistance.

### 2. nixbuild.net builder configured locally

The operator's workstation needs nixbuild.net configured as a remote builder for `aarch64-linux` (since `scripts/deploy-dns.sh` builds the toplevels via `nix build`, which dispatches arm64 work to nixbuild). Log in at <https://nixbuild.net>, set up the SSH key per their docs, and confirm `nix build --no-link nixpkgs#legacyPackages.aarch64-linux.hello` succeeds locally.

This is operator-side only; the deployed instances don't talk to nixbuild.net.

### 3. Terraform state bucket

The S3 backend bucket (`burk3-cloud-infra-tfstate` in us-west-2) holds Terraform state and its native lockfile. Can't be managed inside the state file it stores, so it's one-time bootstrap via awscli:

```sh
BUCKET=burk3-cloud-infra-tfstate
REGION=us-west-2
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

After the bucket exists, `terraform init` in `terraform/` connects to it automatically — no further setup needed.

### 4. Tailscale ACL: declare `tag:dns-node`

The Terraform-managed Tailscale auth key uses `tag:dns-node`, which must exist in the tailnet ACL before the API will let any client (including Terraform) issue keys tagged with it.

1. Open <https://login.tailscale.com/admin/acls/file>.
2. In the policy, ensure `tagOwners` includes `tag:dns-node`. Add (or merge into existing) `tagOwners`:

   ```json
   "tagOwners": {
     "tag:dns-node": ["autogroup:admin"]
   }
   ```

3. Save the policy.

`autogroup:admin` is the simplest correct owner — tighten later if you want a dedicated user/group.

### 5. Tailscale OAuth client for Terraform

The `tailscale` Terraform provider uses an OAuth client (not a personal API token) to issue tagged auth keys.

1. Open <https://login.tailscale.com/admin/settings/oauth>.
2. Click **Generate OAuth client**.
3. Scope: **`auth_keys` (write)**. When the UI asks for a tag scope, set it to `tag:dns-node`. (The ACL from step 4 must already declare this tag, or the UI will reject it.)
4. Copy the client ID and client secret.
5. They'll be placed into `terraform/secrets.auto.tfvars` during plan execution (Task B3) — keep them somewhere safe (e.g. password manager) until then. The file is gitignored; never commit it.

---

## Do after instances are up

### 6. Tailscale split-DNS pointing at the two boxes

Once `terraform apply` (Phase B) has succeeded and both `dns-usw2` and `dns-use2` are visible at <https://login.tailscale.com/admin/machines>, point the tailnet at them for `ts.t11s.net` resolution.

1. Open <https://login.tailscale.com/admin/dns>.
2. Under **Nameservers**, click **Add nameserver** → **Custom**.
3. Enter `dns-usw2`'s tailscale IP (`100.x.y.z`, visible on the machines page).
4. Toggle **Restrict to domain** → enter `ts.t11s.net`.
5. Save.
6. Repeat for `dns-use2`.
7. Confirm **Override local DNS** is OFF (so non-`ts.t11s.net` queries continue using each client's system DNS).

After this, every tailnet client resolves `*.ts.t11s.net` via your two boxes. Verification is in plan Task C3.

---

## Reference: future Tailscale-via-Terraform automation

Step 6 (split-DNS pointing) and the ACL editing in step 4 are both possible to manage via the same `tailscale` Terraform provider used for the auth key (`tailscale_dns_nameservers`, `tailscale_dns_split_nameservers`, `tailscale_acl`). Not done in the current plan — punt to a follow-up if you want to fully eliminate clickops.
