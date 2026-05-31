# Split cloud-infra from all-the-nix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all AWS DNS-node infrastructure (NixOS module, host configs, terraform, deploy script, manual-setup docs) out of `~/src/all-the-nix` (worktree: `feature/aws-dns`) into `~/src/cloud-infra` as a self-contained plain-flake repo, so changes to laptop/workstation modules can't affect cloud-host closures and vice versa.

**Architecture:** Two independent flakes. `all-the-nix` keeps the at-home pets (laptops, workstations, WSL) with the existing `t11s.*` snowfall conventions. `cloud-infra` is a plain `nixpkgs.lib.nixosSystem`-based flake (no snowfall) with a single self-contained `dns-node` module that brings up CoreDNS, tailscale, openssh, the S3 substituter, and the SSM-backed tailscale-bootstrap. No `t11s.*` dependencies, no internal CA, no determinate-nix module on the cattle. Terraform state moves with the directory (it's local-only, gitignored). Operator deploys via `scripts/deploy-dns.sh` invoked from `cloud-infra/` root; the script does `nix build` → S3 push → `terraform apply` in the new location with no path changes needed (it uses `git rev-parse --show-toplevel`).

**Tech Stack:** NixOS (aarch64-linux on t4g.nano) · plain nixpkgs flake (no snowfall) · Terraform (local state) · AWS (Route 53 + EC2 + VPC + IAM + SSM + S3) · Tailscale · nixbuild.net as remote builder.

---

## File Structure

**cloud-infra (new home — created/expanded)**

- Modify: `~/src/cloud-infra/flake.nix` — augment the `nix flake init` template with `nixosConfigurations.dns-{usw2,use2}` + the operator devShell (terraform/awscli2/jq).
- Create: `~/src/cloud-infra/modules/dns-node.nix` — single self-contained module: CoreDNS + tailscale + tailscale-bootstrap + S3 substituter + nameservers + openssh + operator authorized key. No `t11s.*` references.
- Create: `~/src/cloud-infra/terraform/` — full directory moved from `all-the-nix/.worktrees/aws-dns/terraform/` (including local state, lockfile, .gitignore, README, and all .tf files).
- Create: `~/src/cloud-infra/scripts/deploy-dns.sh` — moved verbatim (already uses `git rev-parse --show-toplevel`, so paths work from the new repo root).
- Create: `~/src/cloud-infra/docs/manual-setup.md` — renamed from `aws-dns-manual-steps.md`.
- Create: `~/src/cloud-infra/README.md` — top-level intro: what the repo does, how to deploy.
- Create: `~/src/cloud-infra/CLAUDE.md` — short note for future Claude sessions on the architecture.

**all-the-nix (cleanup — drop the branch entirely)**

- Delete the `feature/aws-dns` branch and `.worktrees/aws-dns` worktree.
- Delete the published `v0.0.1`..`v0.0.8` tags (local + remote).
- Master stays in its pre-DNS state. The base-module fixes (catppuccin/fwupd on `hasScreen`) were created to unblock the server systemType; without server hosts in all-the-nix they're dead-code-but-correct, not worth carrying forward.

---

## Phase A: Bootstrap cloud-infra (modules + flake)

This phase makes `nix build .#nixosConfigurations.dns-{usw2,use2}.config.system.build.toplevel` succeed inside `~/src/cloud-infra/` without copying anything from all-the-nix yet. Land it first to prove the self-contained module evaluates and builds before touching terraform.

### Task A1: Replace `nix flake init` template with our actual flake

**Files:**
- Modify: `~/src/cloud-infra/flake.nix`

- [ ] **Step 1: Overwrite `flake.nix` with the cloud-infra flake**

```nix
{
  description = "AWS DNS-node infrastructure for ts.t11s.net";

  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";

  outputs =
    { self, nixpkgs }:
    let
      mkDnsNode =
        hostName:
        nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"
            ./modules/dns-node.nix
            {
              networking.hostName = hostName;
              system.stateVersion = "25.11";
            }
          ];
        };

      forSystem =
        system: f:
        f {
          inherit system;
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        };
    in
    {
      nixosConfigurations = {
        dns-usw2 = mkDnsNode "dns-usw2";
        dns-use2 = mkDnsNode "dns-use2";
      };

      devShells.x86_64-linux.default = forSystem "x86_64-linux" (
        { pkgs, ... }:
        pkgs.mkShellNoCC {
          packages = with pkgs; [
            terraform
            awscli2
            jq
          ];
        }
      );

      formatter.x86_64-linux = forSystem "x86_64-linux" ({ pkgs, ... }: pkgs.nixfmt-rfc-style);
    };
}
```

- [ ] **Step 2: Stage the change** (so `lazy-trees = true` Nix sees the new file)

```bash
cd ~/src/cloud-infra
git add flake.nix
```

- [ ] **Step 3: Commit**

```bash
git commit -m "flake: replace template with dns-usw2/use2 nixosConfigurations + dev shell"
```

(`flake.lock` will be regenerated by the first eval; commit it later in Task A4.)

---

### Task A2: Write the self-contained `dns-node` module

**Files:**
- Create: `~/src/cloud-infra/modules/dns-node.nix`

- [ ] **Step 1: Create the module**

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cloud.dnsNode;
in
{
  options.cloud.dnsNode = {
    zone = lib.mkOption {
      type = lib.types.str;
      default = "ts.t11s.net";
      description = "DNS zone served by this node.";
    };

    tailscaleAuthKeyParam = lib.mkOption {
      type = lib.types.str;
      default = "/dns-nodes/tailscale-authkey";
      description = "SSM Parameter Store path containing the tailscale auth key (SecureString).";
    };

    cacheUrl = lib.mkOption {
      type = lib.types.str;
      default = "s3://burk3-dns-cache?region=us-west-2&endpoint=s3.dualstack.us-west-2.amazonaws.com";
      description = ''
        S3 binary cache URL where the operator pushes signed closures. The
        instance role grants `s3:GetObject` on the bucket; signatures are
        verified against `cachePublicKey`. Uses the dual-stack endpoint so
        IPv6-only instances can reach it.
      '';
    };

    cachePublicKey = lib.mkOption {
      type = lib.types.str;
      default = "burk3-dns-cache:ZAWST40z9ARFmzxrLHyLHKzqpD+FzM7hxkCkPbrc4Bs=";
      description = "Public half of the signing keypair used to verify closures from `cacheUrl`.";
    };

  };

  config = {
    time.timeZone = "UTC";

    # The S3 substituter for the operator-managed closure cache.
    nix.settings.extra-substituters = [ cfg.cacheUrl ];
    nix.settings.trusted-public-keys = [ cfg.cachePublicKey ];

    # systemd-resolved's default fallback is Cloudflare (1.0.0.1) over IPv4,
    # which is unreachable on our IPv6-only public network. Point at the AWS
    # VPC resolver (link-local, reachable from inside the VPC).
    networking.nameservers = [
      "fd00:ec2::253"
      "169.254.169.253"
    ];

    # Break-glass SSH (pre-tailscale). AWS injects the operator pubkey via
    # cloud-init from the aws_key_pair declared in terraform — we just need
    # the daemon. Tailscale SSH covers normal access once the node joins.
    services.openssh.enable = true;

    services.tailscale.enable = true;

    services.coredns = {
      enable = true;
      config = ''
        ${cfg.zone} {
          bind tailscale0
          forward . 169.254.169.253 fd00:ec2::253
          cache 60
          log
          errors
        }
      '';
    };

    networking.firewall.interfaces.tailscale0 = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = [ 53 ];
    };

    systemd.services.tailscale-bootstrap = {
      description = "Join tailnet using auth key from SSM Parameter Store";
      wantedBy = [ "multi-user.target" ];
      after = [
        "tailscaled.service"
        "network-online.target"
      ];
      wants = [
        "tailscaled.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "5s";
      };
      # The default SSM endpoint (ssm.<region>.amazonaws.com) is IPv4-only;
      # the dual-stack endpoint (ssm.<region>.api.aws) has AAAA records.
      # AWS_USE_DUALSTACK_ENDPOINT=true makes awscli rewrite the URL.
      environment.AWS_USE_DUALSTACK_ENDPOINT = "true";
      path = [
        pkgs.awscli2
        pkgs.tailscale
      ];
      script = ''
        set -euo pipefail
        if tailscale status --json 2>/dev/null | ${pkgs.jq}/bin/jq -e '.BackendState == "Running"' >/dev/null; then
          echo "tailscale already running; nothing to do"
          exit 0
        fi
        AUTH_KEY=$(aws ssm get-parameter \
          --name ${cfg.tailscaleAuthKeyParam} \
          --with-decryption \
          --query 'Parameter.Value' --output text)
        if [ -z "$AUTH_KEY" ] || [ "$AUTH_KEY" = "None" ]; then
          echo "ERROR: SSM parameter returned empty or null auth key" >&2
          exit 1
        fi
        tailscale up \
          --authkey "$AUTH_KEY" \
          --hostname "${config.networking.hostName}" \
          --advertise-tags=tag:dns-node \
          --ssh
      '';
    };

    # Ensure CoreDNS waits for tailscale0 to exist (the bind directive
    # requires the interface to be up).
    systemd.services.coredns = {
      after = [ "tailscale-bootstrap.service" ];
      wants = [ "tailscale-bootstrap.service" ];
    };
  };
}
```

- [ ] **Step 2: Stage the new file**

```bash
cd ~/src/cloud-infra
git add modules/dns-node.nix
```

- [ ] **Step 3: Verify Nix parses it**

```bash
nix-instantiate --parse modules/dns-node.nix > /dev/null
```

Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git commit -m "modules: add self-contained dns-node module"
```

---

### Task A3: Write the cloud-infra README and CLAUDE.md

**Files:**
- Create: `~/src/cloud-infra/README.md`
- Create: `~/src/cloud-infra/CLAUDE.md`

- [ ] **Step 1: Write `README.md`**

```markdown
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
```

- [ ] **Step 2: Write `CLAUDE.md`**

```markdown
# cloud-infra

Single-purpose flake hosting two AWS DNS nodes for the tailnet's `ts.t11s.net` zone. Plain nixpkgs flake (no snowfall — this repo is small enough that auto-discovery would be ceremony). One module (`modules/dns-node.nix`) brings up everything; both hosts use it with only `networking.hostName` differing.

Cloud cattle. Operator-driven deploys via `scripts/deploy-dns.sh`. Closures get signed locally and pushed to `s3://burk3-dns-cache`; the instances substitute via their IAM role's `s3:GetObject` permission and verify against `burk3-dns-cache:ZAWST40z…`.

Terraform state is local (`terraform/terraform.tfstate`, gitignored). The terraform-managed resources are the S3 cache bucket, two VPCs (us-west-2 + us-east-2, dual-stack so IMDS works), the Route 53 private hosted zone with the host records, the IAM role + instance profile + SSM parameter for the tailscale auth key, and the EC2 instances themselves with user-data that pulls the toplevel closure from S3 and activates it.

When making changes:
- Edit `modules/dns-node.nix` for box config; rebuild and re-deploy via `./scripts/deploy-dns.sh`
- Edit `terraform/*.tf` for infra; `terraform apply` directly or via `deploy-dns.sh`
- Manual setup (AWS creds, Tailscale ACL, signing key) lives in `docs/manual-setup.md`
```

- [ ] **Step 3: Stage and commit**

```bash
cd ~/src/cloud-infra
git add README.md CLAUDE.md
git commit -m "docs: README and CLAUDE.md"
```

---

### Task A4: Build both hosts to verify the flake evaluates

**Files:**
- (no source changes; will write `flake.lock` as a side-effect)

- [ ] **Step 1: Build the dns-usw2 toplevel**

```bash
cd ~/src/cloud-infra
nix build --no-link --print-build-logs .#nixosConfigurations.dns-usw2.config.system.build.toplevel
```

Expected: succeeds. nixbuild.net dispatches the aarch64-linux build (the operator workstation has it as a remote builder per `5ddf0de` in all-the-nix).

- [ ] **Step 2: Build the dns-use2 toplevel**

```bash
nix build --no-link --print-build-logs .#nixosConfigurations.dns-use2.config.system.build.toplevel
```

Expected: succeeds. Builds are mostly cache hits.

- [ ] **Step 3: Sanity-check the closures contain CoreDNS, tailscale, awscli, openssh**

```bash
nix path-info -r $(nix eval --raw .#nixosConfigurations.dns-usw2.config.system.build.toplevel) \
  | grep -E '/[^-]*-(coredns|tailscale|awscli|openssh)' | sort -u
```

Expected: prints store paths for each of those tools.

- [ ] **Step 4: Commit the flake.lock**

```bash
cd ~/src/cloud-infra
git add flake.lock
git commit -m "flake: lock nixpkgs to release-25.11 (initial)"
```

---

## Phase B: Migrate terraform directory

Move the entire `terraform/` directory (including local state, lockfile, and gitignored vars files) so we keep continuity with the AWS resources already deployed. terraform will see no diff after the move.

### Task B1: Move the terraform directory from the worktree to cloud-infra

**Files:**
- Move: `~/src/all-the-nix/.worktrees/aws-dns/terraform/` → `~/src/cloud-infra/terraform/`

- [ ] **Step 1: Confirm there's no in-progress terraform run**

```bash
ls ~/src/all-the-nix/.worktrees/aws-dns/terraform/.terraform.tfstate.lock.info 2>/dev/null
```

Expected: file does NOT exist (no lock).

- [ ] **Step 2: Move the entire directory**

```bash
mv ~/src/all-the-nix/.worktrees/aws-dns/terraform ~/src/cloud-infra/terraform
```

- [ ] **Step 3: Verify the move kept state**

```bash
ls -la ~/src/cloud-infra/terraform/terraform.tfstate ~/src/cloud-infra/terraform/secrets.auto.tfvars ~/src/cloud-infra/terraform/paths.auto.tfvars
```

Expected: all three files present (the `.tfstate` records live AWS resources; `secrets.auto.tfvars` has the Tailscale OAuth client + turing/juicy-j IPs; `paths.auto.tfvars` was written by the last `deploy-dns.sh` run).

- [ ] **Step 4: Run `terraform init` in the new location**

```bash
cd ~/src/cloud-infra/terraform
AWS_PROFILE=tactilecactus nix develop ../ --command terraform init
```

Expected: "Terraform has been successfully initialized!" (re-downloads provider plugins into the new `.terraform/` since that's gitignored and wasn't moved... or was moved, in which case init is a no-op).

- [ ] **Step 5: Run `terraform plan` to confirm zero changes**

```bash
AWS_PROFILE=tactilecactus nix develop ../ --command terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.` (Any drift means the state-to-config mapping broke; investigate before continuing.)

- [ ] **Step 6: Stage and commit the committed terraform files**

```bash
cd ~/src/cloud-infra
git add terraform/.gitignore terraform/README.md terraform/*.tf terraform/.terraform.lock.hcl
git commit -m "terraform: import full tree from all-the-nix (state preserved out-of-band)"
```

(Gitignored files — `terraform.tfstate*`, `secrets.auto.tfvars`, `paths.auto.tfvars`, `.terraform/`, `tf.plan` — remain on disk but are correctly absent from the commit.)

---

## Phase C: Migrate deploy script + docs

### Task C1: Move `scripts/deploy-dns.sh`

**Files:**
- Move: `~/src/all-the-nix/.worktrees/aws-dns/scripts/deploy-dns.sh` → `~/src/cloud-infra/scripts/deploy-dns.sh`

- [ ] **Step 1: Move the script and verify executable bit survives**

```bash
mkdir -p ~/src/cloud-infra/scripts
mv ~/src/all-the-nix/.worktrees/aws-dns/scripts/deploy-dns.sh ~/src/cloud-infra/scripts/deploy-dns.sh
test -x ~/src/cloud-infra/scripts/deploy-dns.sh && echo OK || echo MISSING-EXEC-BIT
```

Expected: `OK`. If `MISSING-EXEC-BIT`, run `chmod +x ~/src/cloud-infra/scripts/deploy-dns.sh`.

- [ ] **Step 2: Confirm the script's `REPO_ROOT` discovery still works from cloud-infra**

The script uses `git rev-parse --show-toplevel`, which is repo-relative. Verify:

```bash
cd ~/src/cloud-infra
(cd scripts && git rev-parse --show-toplevel)
```

Expected: `/home/burke/src/cloud-infra`. (Not all-the-nix, not the worktree.)

- [ ] **Step 3: Stage and commit**

```bash
cd ~/src/cloud-infra
git add scripts/deploy-dns.sh
git commit -m "scripts: import deploy-dns.sh (no path changes needed)"
```

---

### Task C2: Move and rename the manual-setup doc

**Files:**
- Move: `~/src/all-the-nix/.worktrees/aws-dns/docs/aws-dns-manual-steps.md` → `~/src/cloud-infra/docs/manual-setup.md`

- [ ] **Step 1: Move and rename**

```bash
mkdir -p ~/src/cloud-infra/docs
mv ~/src/all-the-nix/.worktrees/aws-dns/docs/aws-dns-manual-steps.md ~/src/cloud-infra/docs/manual-setup.md
```

- [ ] **Step 2: Fix the internal references inside the doc**

The doc was written assuming `docs/superpowers/plans/2026-05-30-aws-authoritative-dns.md` lives in the same repo. After the split, the plan stays in all-the-nix (until cleanup deletes it) and this doc lives in cloud-infra. Edit the file to remove or update the plan reference.

Edit `~/src/cloud-infra/docs/manual-setup.md`:

Find:
```markdown
This file lists every step that requires a browser, a dashboard, or interactive auth. The implementation plan in `docs/superpowers/plans/2026-05-30-aws-authoritative-dns.md` assumes the **"Do before execution"** section here is done before subagent-driven execution begins, and the **"Do after instances are up"** section is done once Phase B has applied successfully.
```

Replace with:
```markdown
This file lists every step that requires a browser, a dashboard, or interactive auth — the things `scripts/deploy-dns.sh` can't do on its own.
```

Also fix the FlakeHub OIDC-trust step (step 3) — it referenced publishing to FlakeHub via the workflow, which no longer lives in this repo. Update step 3 from:

```markdown
### 3. FlakeHub: registration + OIDC trust
…
```

To:

```markdown
### 3. (Optional) FlakeHub publish for the source flake

This repo doesn't push to FlakeHub Cache — closures live in `s3://burk3-dns-cache` and the instances substitute from there directly. If you want a public/unlisted release of the source flake on FlakeHub anyway (for discoverability), keep a tag-driven publish workflow similar to the one in `all-the-nix/.github/workflows/`. Not required for deploys.
```

- [ ] **Step 3: Stage and commit**

```bash
cd ~/src/cloud-infra
git add docs/manual-setup.md
git commit -m "docs: import manual-setup.md from all-the-nix and trim FlakeHub-publish references"
```

---

### Task C3: Move this plan doc into cloud-infra's history

**Files:**
- Already present: `~/src/cloud-infra/docs/superpowers/plans/2026-05-30-split-from-all-the-nix.md` (this file)
- Move: `~/src/all-the-nix/.worktrees/aws-dns/docs/superpowers/plans/2026-05-30-aws-authoritative-dns.md` → `~/src/cloud-infra/docs/superpowers/plans/2026-05-30-aws-authoritative-dns.md`

- [ ] **Step 1: Move the original plan doc for historical record**

```bash
mv ~/src/all-the-nix/.worktrees/aws-dns/docs/superpowers/plans/2026-05-30-aws-authoritative-dns.md \
   ~/src/cloud-infra/docs/superpowers/plans/2026-05-30-aws-authoritative-dns.md
```

- [ ] **Step 2: Stage and commit both plan docs**

```bash
cd ~/src/cloud-infra
git add docs/superpowers/plans/
git commit -m "docs: import implementation-plan history from all-the-nix"
```

---

## Phase D: End-to-end verification from cloud-infra

Prove the new repo can deploy without depending on anything in all-the-nix.

### Task D1: Run a dry deploy (build + push, skip terraform)

**Files:**
- (no source changes)

- [ ] **Step 1: From the new repo, build + sign + push closures only**

```bash
cd ~/src/cloud-infra
AWS_PROFILE=tactilecactus nix develop --command ./scripts/deploy-dns.sh --skip-apply
```

Expected: builds both toplevels, signs and pushes to `s3://burk3-dns-cache`, writes `terraform/paths.auto.tfvars` with the new paths, exits before `terraform apply`.

- [ ] **Step 2: Confirm `paths.auto.tfvars` was written with cloud-infra's toplevel paths**

```bash
cat ~/src/cloud-infra/terraform/paths.auto.tfvars
```

Expected: two lines, `dns_usw2_toplevel_path = "/nix/store/…"` and `dns_use2_toplevel_path = "/nix/store/…"`. Compare against what `nix eval --raw .#nixosConfigurations.dns-usw2.config.system.build.toplevel` returns from cloud-infra (should match).

- [ ] **Step 3: Confirm S3 has the new objects**

```bash
NEW_USW2=$(awk -F'"' '/dns_usw2_toplevel_path/ {print $2}' ~/src/cloud-infra/terraform/paths.auto.tfvars)
HASH_USW2=${NEW_USW2#/nix/store/}
HASH_USW2=${HASH_USW2%%-*}
AWS_PROFILE=tactilecactus nix develop --command aws --region us-west-2 s3 ls "s3://burk3-dns-cache/${HASH_USW2}.narinfo"
```

Expected: the .narinfo entry exists in the bucket.

---

### Task D2: Verify the running boxes still resolve queries

**Files:**
- (no source changes)

- [ ] **Step 1: Query both boxes directly over the tailnet**

```bash
dig +short +time=3 @100.95.23.20 turing.ts.t11s.net A juicy-j.ts.t11s.net A
dig +short +time=3 @100.104.14.126 turing.ts.t11s.net A juicy-j.ts.t11s.net A
```

Expected: both return `100.67.67.97` (turing) and `100.115.165.14` (juicy-j).

- [ ] **Step 2: Query via Tailscale split-DNS (no `@server`)**

```bash
dig +short turing.ts.t11s.net A
dig +short juicy-j.ts.t11s.net AAAA
```

Expected: same answers, routed through the split-DNS rule.

(No commit — verification only.)

---

### Task D3: Full apply path verification (optional smoke test)

The boxes are currently on a generation built from the all-the-nix worktree closure. After Phase C, cloud-infra builds a structurally-similar but-not-identical-by-hash closure (the dns-node module's option defaults are unchanged, but module path / module file content changes the toplevel hash). Verify a full apply with cloud-infra-built closures runs end to end.

**Files:**
- (no source changes)

- [ ] **Step 1: Run the full deploy (build + push + terraform apply)**

```bash
cd ~/src/cloud-infra
AWS_PROFILE=tactilecactus nix develop --command ./scripts/deploy-dns.sh
```

Expected: `terraform apply` triggers instance replacement (since `user_data` changed: new toplevel store path). Two instances destroyed + two added.

- [ ] **Step 2: Wait for the new boxes to come up and join the tailnet**

```bash
USW2_V6=$(cd terraform && AWS_PROFILE=tactilecactus nix develop ../ --command terraform output -raw dns_usw2_ipv6_addresses 2>&1 | grep -oE '2600:[^"]+' | head -1)
echo "dns-usw2 v6: $USW2_V6"
# Wait until tailscale-bootstrap finishes (it sets up tailscale and joins
# the tailnet; should take ~2 min after instance creation).
until tailscale status 2>/dev/null | grep -q '^[0-9].* dns-usw2 '; do sleep 15; done
echo "dns-usw2 joined tailnet"
until tailscale status 2>/dev/null | grep -q '^[0-9].* dns-use2 '; do sleep 15; done
echo "dns-use2 joined tailnet"
```

Expected: both hosts appear in the tailnet within ~3 min.

- [ ] **Step 3: Verify resolution still works on the new instances**

```bash
# Get the new tailnet IPs
USW2_TS=$(tailscale status 2>/dev/null | awk '$2=="dns-usw2" {print $1}')
USE2_TS=$(tailscale status 2>/dev/null | awk '$2=="dns-use2" {print $1}')
dig +short +time=3 @$USW2_TS turing.ts.t11s.net A
dig +short +time=3 @$USE2_TS turing.ts.t11s.net A
```

Expected: both return `100.67.67.97`.

(No commit — verification only.)

---

## Phase E: Initial cloud-infra release

### Task E1: Push cloud-infra to its remote, optional initial tag

- [ ] **Step 1: Push the cloud-infra branch to its remote**

If a remote isn't configured, create the repo on GitHub first, then:

```bash
cd ~/src/cloud-infra
git remote add origin git@github.com:burk3/cloud-infra.git    # adjust to actual URL
git push -u origin master
```

If a remote already exists, just `git push`.

- [ ] **Step 2: Tag an initial release (optional)**

```bash
git tag v0.1.0
git push origin v0.1.0
```

Purely cosmetic — the deploy path doesn't depend on tags.

---

## Phase F: MANUAL — all-the-nix cleanup

> **Not part of automated plan execution.** Operator handles this when ready. The relevant commands are documented here for reference; do not run them as part of subagent-driven or inline plan execution.

After Phases A–E have landed and `cloud-infra` is verified working end-to-end, the `feature/aws-dns` branch and `.worktrees/aws-dns` worktree in `~/src/all-the-nix` are no longer needed. Master is untouched and stays in its pre-DNS state.

When ready to nuke them:

```bash
# 1. Sanity-check there's nothing left in the worktree you care about
ls ~/src/all-the-nix/.worktrees/aws-dns/
cd ~/src/all-the-nix/.worktrees/aws-dns && git status --short

# 2. Remove the worktree
cd ~/src/all-the-nix
git worktree remove --force .worktrees/aws-dns

# 3. Delete the local + remote branch
git branch -D feature/aws-dns
git push origin --delete feature/aws-dns

# 4. Delete the published iteration tags (v0.0.1 through v0.0.8)
for tag in v0.0.1 v0.0.2 v0.0.3 v0.0.4 v0.0.5 v0.0.6 v0.0.7 v0.0.8; do
  git tag -d "$tag" 2>/dev/null || true
  git push origin --delete "$tag" 2>/dev/null || true
done
```

FlakeHub releases corresponding to those tags will linger on flakehub.com — harmless, they don't actively serve anything. Unpublish via the FlakeHub UI if desired.

---

## Verification checklist (after Phases A–E)

- [ ] `cd ~/src/cloud-infra && nix build .#nixosConfigurations.dns-usw2.config.system.build.toplevel` succeeds.
- [ ] `cd ~/src/cloud-infra/terraform && terraform plan` reports `No changes`.
- [ ] `dig +short turing.ts.t11s.net A` returns `100.67.67.97` from any tailnet client (via split-DNS).
- [ ] `~/src/all-the-nix` master builds: `nix eval --raw .#nixosConfigurations.juicy-j.config.system.build.toplevel.drvPath` succeeds.
- [ ] `cloud-infra` is a self-contained working flake with no reference to `all-the-nix`.
- [ ] (Phase F, manual) `.worktrees/aws-dns/` no longer exists; `feature/aws-dns` branch gone.

---

## Open questions worth confirming during execution

- **GitHub remote for cloud-infra**: The plan assumes `git@github.com:burk3/cloud-infra.git`. If the remote name/path differs, adjust Task E1. If the repo doesn't exist on GitHub yet, create it before pushing (private vs public is your call — the closures aren't there, so public is reasonable).
- **`secrets.auto.tfvars` and signing key path**: After Phase B, `secrets.auto.tfvars` is in the new location. The signing key (`~/.config/nix-cache/burk3-dns-cache.secret`) is referenced by `deploy-dns.sh` and is path-independent. No changes needed unless you move the key.
