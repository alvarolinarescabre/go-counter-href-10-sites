# EKS + ArgoCD GitOps Platform

Terraform project that provisions an Amazon EKS cluster on AWS and bootstraps it with
[Argo CD](https://argo-cd.readthedocs.io/) for GitOps-driven delivery. Argo CD, in turn,
installs the [Gateway API](https://gateway-api.sigs.k8s.io/) CRDs, [kgateway](https://kgateway.dev/)
as the Gateway API implementation (exposed via an AWS Network Load Balancer), and the
`counter-api` sample application.

Everything after the EKS cluster is created is managed declaratively through Argo CD
`Application`/`AppProject` manifests — Terraform only applies the initial bootstrap
manifests and then hands off control to Argo CD's own sync loop.

> This directory lives inside the `go-counter-href-10-sites` monorepo. The Argo CD
> manifests it applies (`app-project.yaml`, `application.yaml`, `kgateway/`) live under
> [`../../deploy/argocd`](../../deploy/argocd), alongside the Helm chart
> ([`../../deploy/helm/counter-api`](../../deploy/helm/counter-api)) and the application
> source ([`../../apps/counter-api`](../../apps/counter-api)) they deploy — everything the
> platform needs is now versioned together instead of split across repositories.

## Architecture

```
                         ┌──────────────────────────────────────────────┐
                         │                 AWS Account                  │
                         │                                              │
                         │   ┌───────────────── VPC ──────────────────┐ │
                         │   │  Public subnets   Private subnets      │ │
                         │   │  (NAT GW, NLB)     (EKS nodes)         │ │
                         │   └────────────────────────────────────────┘ │
                         │                     │                        │
                         │           ┌─────────▼───────────┐            │
                         │           │   EKS Cluster       │            │
                         │           │  (EKS Auto Mode /   │            │
                         │           │  compute_config)    │            │
                         │           │                     │            │
                         │           │  ┌───────────────┐  │            │
                         │           │  │   Argo CD     │  │            │
                         │           │  │ (helm_release)│  │            │
                         │           │  └───────┬───────┘  │            │
                         │           │          │ manages  │            │
                         │           │  ┌───────▼────────┐ │            │
                         │           │  │ Gateway API    │ │            │
                         │           │  │ CRDs + kgateway│ │            │
                         │           │  │ (Argo apps)    │ │            │
                         │           │  └───────┬────────┘ │            │
                         │           │          │ routes   │            │
                         │           │  ┌───────▼────────┐ │            │
                         │           │  │ counter-api    │ │            │
                         │           │  │ (Argo app, from│ │            │
                         │           │  │ external repo) │ │            │
                         │           │  └────────────────┘ │            │
                         │           └─────────────────────┘            │
                         └──────────────────────────────────────────────┘
```

**Bootstrap flow (Terraform):**

1. VPC (public + private subnets, single NAT Gateway).
2. EKS cluster in the private subnets, using EKS's managed `compute_config` (Auto Mode
   style, `general-purpose` node pool).
3. Argo CD installed via Helm into the cluster.
4. Gateway API standard CRDs applied, then the kgateway CRDs and kgateway controller
   installed as Argo CD `Application` resources (`kubectl_manifest`).
5. An Argo CD `AppProject` and `Application` are created pointing at the `counter-api`
   Helm chart in this same monorepo; from this point on, Argo CD syncs and reconciles the
   application itself (GitOps hand-off).

## Repository structure

```
.
├── apps/counter-api/                  # Go/Gin application (source of the deployed image)
├── deploy/
│   ├── helm/counter-api/              # Helm chart applied by the ArgoCD Application below
│   └── argocd/
│       ├── app-project.yaml           # ArgoCD AppProject: go-counter-href-10-sites-project
│       ├── application.yaml           # ArgoCD Application: counter-api
│       └── kgateway/
│           ├── standard-install.yaml  # Upstream Gateway API "standard" channel CRDs
│           ├── crds-helm.yaml         # ArgoCD Application installing the kgateway-crds Helm chart
│           ├── helm.yaml              # ArgoCD Application installing the kgateway controller Helm chart
│           └── parameters.yaml        # GatewayParameters: public-facing AWS NLB configuration
└── infra/eks/                         # (this directory)
    ├── providers.tf                   # Terraform/provider requirements (aws, kubernetes, kubectl, helm)
    ├── variables.tf                   # Input variables (region, naming, CIDRs, ArgoCD chart, ...)
    ├── locals.tf                      # Derived naming, CIDRs, AZs, and caller's public IP
    ├── data.tf                        # Data sources: caller identity, AZs, public IP, EKS auth, CRD docs
    ├── outputs.tf                     # Post-apply instructions (kubeconfig, ArgoCD login, app access, destroy)
    ├── 01-vpc.tf                      # VPC module (terraform-aws-modules/vpc)
    ├── 02-eks.tf                      # EKS module (terraform-aws-modules/eks)
    ├── 03-argocd.tf                   # Argo CD Helm release
    ├── 04-ingress-controller.tf       # Gateway API CRDs + kgateway (CRDs and controller) via ArgoCD manifests
    ├── 05-app-deployment.tf           # ArgoCD AppProject + Application for counter-api
    ├── 06-argocd-ingress.tf           # Optional kgateway Gateway/HTTPRoute exposing the Argo CD UI
    └── 07-ecr.tf                      # ECR repository + lifecycle policy for the app image
```

## Resources deployed

### Networking (`01-vpc.tf`)
- **VPC** (module `terraform-aws-modules/vpc/aws ~> 5`) with 3 public and 3 private
  subnets spread across 3 Availability Zones.
- Single **NAT Gateway** for outbound traffic from private subnets.
- DNS hostnames/support enabled.
- Subnets tagged for Kubernetes/ELB auto-discovery
  (`kubernetes.io/cluster/<cluster>`, `kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`).

### EKS cluster (`02-eks.tf`)
- **EKS cluster** (module `terraform-aws-modules/eks/aws ~> 21.3`) deployed into the
  private subnets.
- Public API endpoint access restricted to the operator's current public IP
  (`data.http.my_ip`).
- `compute_config` enabled with the `general-purpose` node pool (EKS-managed compute,
  no self-managed node groups to maintain).
- Cluster creator is automatically granted admin permissions
  (`enable_cluster_creator_admin_permissions`).

### GitOps controller (`03-argocd.tf`)
- **Argo CD** installed via the official Helm chart (`argo-cd`, `argoproj.github.io/argo-helm`)
  into the `argocd` namespace.
- Single-replica configuration for `controller`, `server`, `repoServer`, and
  `applicationSet`; `redis-ha` disabled (suitable for dev/demo, not HA production use).
- Server runs in `insecure` mode (TLS termination expected to happen at the
  Gateway/Load Balancer, not at the Argo CD server pod).

### Ingress / Gateway API (`04-ingress-controller.tf`)
- Upstream **Gateway API standard-channel CRDs** applied directly to the cluster.
- **kgateway CRDs** and **kgateway controller** installed as Argo CD `Application`
  resources (chart source: `cr.kgateway.dev/kgateway-dev/charts`, version `v2.4.3`),
  each with automated `prune`/`selfHeal` sync policies.
- `parameters.yaml` (`GatewayParameters`) provisions the Gateway's Kubernetes `Service`
  as an internet-facing **AWS Network Load Balancer** (`aws-load-balancer-type: external`,
  `nlb-target-type: ip`).
- The NLB serves HTTP on port 80, and HTTPS on port 443 once an ACM certificate is
  configured — `gatewayParameters.tls.certificateArn` + `gateway.https.enabled` in
  [`../../deploy/helm/counter-api/values.yaml`](../../deploy/helm/counter-api/values.yaml)
  for the application Gateway, `argocd_gateway_tls_certificate_arn` for a dedicated Argo CD
  one. TLS terminates **at the load balancer**: the extra Gateway listener speaks plain
  HTTP because the NLB hands it an already-decrypted stream.

### Container registry (`07-ecr.tf`)
- **ECR repository** (`var.ecr_repository_name`, default `counter-api`) holding the
  application image, with `scan_on_push` and `IMMUTABLE` tags — the pipeline only ever
  pushes `sha-<commit>`, so an overwrite is always a mistake and the registry rejects it.
- **Lifecycle policy**: expires untagged images after `var.ecr_untagged_expiry_days` and
  keeps the newest `var.ecr_keep_last_images` `sha-` builds.
- No pull credential is needed in the cluster: EKS Auto Mode's node IAM role carries
  `AmazonEC2ContainerRegistryPullOnly`, so kubelet pulls with the node's own identity.
- `force_delete = true` so `terraform destroy` does not stall on a repository that still
  holds images.

### Application (`05-app-deployment.tf`)
- **AppProject** `go-counter-href-10-sites-project` scoping allowed source repos/destinations.
- **Application** `counter-api`, sourced from this same repo
  (`deploy/helm/counter-api`, branch `main`), deployed into the `counter-api` namespace
  with automated sync (`prune`, `selfHeal`, `CreateNamespace=true`).

### Argo CD ingress (`06-argocd-ingress.tf`, optional)

Off by default — Argo CD ships no Ingress/Gateway of its own, so out of the box the UI is
only reachable through `kubectl port-forward`. Set `enable_argocd_route = true` to publish
it through kgateway:

- **HTTPRoute** `argocd-server` in the `argocd` namespace, matching
  `var.argocd_hostname` and forwarding to the `argocd-server` Service on **plain HTTP
  port 80** — Argo CD runs with `server.insecure = true` (see `03-argocd.tf`), so TLS, if
  any, terminates at the Gateway/NLB rather than at the pod.
- The Gateway it attaches to depends on `argocd_gateway_create`:
  - `false` (default) — reuse an existing Gateway (`argocd_gateway_name` /
    `argocd_gateway_namespace`, by default the `public-nlb-gateway` the counter-api chart
    creates), so Argo CD and the application share one NLB. That Gateway must accept
    routes from other namespaces; the chart's does (`allowedRoutes.namespaces.from: All`).
  - `true` — also create a dedicated **Gateway** `argocd-gateway` plus a
    **GatewayParameters** `argocd-nlb-params` in the `argocd` namespace, which makes
    kgateway provision a **second, Argo-CD-only NLB** (extra AWS cost, but keeps the
    control plane off the application load balancer).

**TLS.** `argocd_gateway_tls_certificate_arn` (dedicated Gateway only) adds a second
listener on port 443 and the `aws-load-balancer-ssl-*` annotations, so the NLB terminates
TLS with your ACM certificate and forwards plain HTTP inwards — the listener protocol stays
`HTTP` and no certificate ever enters the cluster. The HTTPRoute then attaches to both
listeners automatically. When *reusing* the counter-api Gateway instead, TLS comes from
that chart (`gatewayParameters.tls.certificateArn`); set
`argocd_gateway_section_name = "https"` so Argo CD only answers on the encrypted port.

kgateway routes on the `Host` header, so `var.argocd_hostname` has to resolve to the
Gateway's NLB address — a DNS record, or an `/etc/hosts` entry for a `.local` name.

### No domain? You don't need one

Route 53 registration is not required — nothing here uses Route 53, and the Gateway's NLB
already has a working DNS name of its own (`k8s-….elb.amazonaws.com`). Three ways to reach
the services without buying anything:

1. **Drop the hostname.** `argocd_hostname = ""` (Terraform) or `httpRoute.hostnames: []`
   (chart) omits `hostnames` from the HTTPRoute, so it matches any `Host` and you just open
   the NLB DNS name. Only one hostname-less route can sensibly own `/` per listener, so if
   both Argo CD and the app go hostname-less, give Argo CD its own Gateway
   (`argocd_gateway_create = true`) — and note the warning on `argocd_hostname`: on the
   shared, internet-facing Gateway a hostname-less route makes the unencrypted admin UI the
   default backend.
2. **Wildcard DNS.** `sslip.io`/`nip.io` resolve `<anything>.<ip>.sslip.io` to `<ip>`, so
   `argocd.<nlb-ip>.sslip.io` gives you a real, distinct hostname for free. Resolve the NLB
   name to an IP first (`dig +short <nlb-dns>`); those IPs can change over the NLB's life,
   so re-check if it stops resolving.
3. **`/etc/hosts`.** Map any invented name (`argocd.chamo.local`) to a current NLB IP. Works
   from your machine only.

If you do want a real domain, register it anywhere — the DNS provider is independent of
AWS. Cloudflare Registrar or Porkbun sell them at cost (~10 USD/year), and
[freedns.afraid.org](https://freedns.afraid.org) hands out free subdomains that support
`CNAME` records, which is what you need to point at an NLB DNS name (an NLB has no stable
IP, so `A`-record-only providers like DuckDNS are a poor fit). Then just `CNAME` the
hostname at the NLB and set `argocd_hostname` / `httpRoute.hostnames` to it.

In the reuse case, the shared Gateway is created by Argo CD syncing the chart, not by
Terraform, so the HTTPRoute can be applied before its parent exists. That is not an apply
error: the route stays `Accepted=False` until kgateway sees the Gateway and reconciles it.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) `>= 1.5` (providers pin `aws ~> 6`, `kubernetes ~> 2`, `kubectl ~> 2.1.3`, `helm ~> 2`)
- An AWS account and credentials configured (env vars, `~/.aws/credentials`, or SSO) with
  permissions to create VPC, EKS, IAM, and ELB/NLB resources.
- [`aws` CLI](https://docs.aws.amazon.com/cli/) v2, used for `eks get-token` auth by the
  Kubernetes/kubectl/Helm providers and for `update-kubeconfig`.
- `kubectl` to interact with the cluster once it is up.
- Outbound internet access from where you run Terraform (used to detect your public IP
  via `https://checkip.amazonaws.com` for restricting the EKS API endpoint).

## Deployment

State is stored remotely in S3, with native S3 state locking (`use_lockfile` — no
DynamoDB table involved). The bucket/key/region are literal values in
[`providers.tf`](providers.tf)'s `backend "s3" {}` block, not passed in at `terraform
init` time — see the comment on that block for why (a config that depends on a variable
being set correctly at init time silently falls back to local state if that variable is
ever missing, which caused a real incident once). If you need a different bucket/region,
edit that block directly; see [Remote state bootstrap](#remote-state-bootstrap) below to
create it.

```bash
# 1. Initialize providers, modules, and the S3 backend
terraform init

# 2. Review the plan
terraform plan

# 3. Apply (creates VPC, EKS, Argo CD, Gateway API/kgateway, and the ArgoCD Application)
terraform apply
```

> The EKS/kubectl/kubernetes/helm providers depend on the cluster created by
> `module.eks`, so `terraform apply` builds everything in a single run — no need for a
> two-phase apply.

### Post-deploy

On success, the `instructions` output prints the exact commands to run. Summarized:

**1. Configure kubectl:**
```bash
aws eks update-kubeconfig --region <region> --name <cluster_name>
```

**2. Log in to Argo CD:**
```bash
# initial 'admin' password (either way)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# enable_argocd_route = false (default): no external address, tunnel to it
kubectl port-forward svc/argocd-server -n argocd 8080:80   # then http://localhost:8080

# enable_argocd_route = true: resolve var.argocd_hostname to the Gateway's NLB
kubectl get svc <gateway-name> -n <gateway-namespace> \
  -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
```

The `instructions` output prints whichever of the two applies to your configuration.

**3. Reach the sample application:**
```bash
kubectl get httproutes.gateway.networking.k8s.io -n counter-api
# map the returned HOSTNAME(s) to the NLB address in your /etc/hosts
```

### Destroy

```bash
terraform destroy
```

## Continuous deployment

[`.github/workflows/terraform-aws.yml`](../../.github/workflows/terraform-aws.yml) runs
Terraform against AWS from GitHub Actions:

- **Every PR** touching `infra/aws/**` runs `terraform fmt -check` and `terraform validate`
  (no AWS credentials involved — safe for PRs from forks).
- **Every push to `main`** touching `infra/aws/**` runs a read-only `terraform plan`
  automatically and posts it to the job summary + as a build artifact — so the real drift
  against AWS is visible right after a merge, with no clicks and nothing mutated.
- **`plan` / `apply` / `destroy` against the real AWS account** only run from a manual
  [`workflow_dispatch`](https://github.com/alvarolinarescabre/go-counter-href-10-sites/actions/workflows/terraform-aws.yml),
  gated by the `aws-eks` GitHub Environment. The plan is always shown and uploaded as a
  build artifact; `apply`/`destroy` apply that same saved plan.

Authentication uses a static AWS access key stored as a GitHub secret (simpler to set up
than OIDC, at the cost of a long-lived credential living in GitHub — rotate it
periodically). One-time setup, before the workflow can run:

### 1. Remote state bootstrap

The S3 bucket that holds Terraform state can't be created by the same Terraform config
that will use it, so create it once out of band — name and region must match
[`providers.tf`](providers.tf)'s `backend "s3" {}` block:

```bash
aws s3api create-bucket --bucket chamo-terraform-state-2027 \
  --region eu-west-1 --create-bucket-configuration LocationConstraint=eu-west-1
aws s3api put-bucket-versioning --bucket chamo-terraform-state-2027 \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket chamo-terraform-state-2027 \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

State locking uses Terraform's native S3 locking (`use_lockfile = true`, Terraform >=
1.10) — no DynamoDB table needed. (If you bootstrapped one before this changed, it's safe
to delete: `aws dynamodb delete-table --table-name <your-old-tf-lock-table>`.)

### 2. IAM user(s) and access key(s)

The workflow reads `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` from GitHub secrets. GitHub
resolves **environment** secrets before repo-level ones for any job bound to that
environment, so defining the same secret names at both levels gives the two jobs
different privilege without any extra workflow logic:

| Secret scope | Used by | IAM user permissions |
|---|---|---|
| Repo-level (Settings → Secrets and variables → Actions) | `plan-on-main` (automatic, every push) | **Read-only**: `Describe*`/`List*`/`Get*` on VPC, EKS, IAM, ELB, plus read on the state bucket |
| Environment-level, on `aws-eks` (Settings → Environments → aws-eks → secrets) | `terraform` (manual, reviewer-gated) | **Read/write**: everything the read-only user has, plus create/update/delete on VPC, EKS, IAM (for the EKS/IRSA roles the modules create), ELB/NLB, and read/write on the state bucket |

If you'd rather not maintain two IAM users, define `AWS_ACCESS_KEY_ID`/
`AWS_SECRET_ACCESS_KEY` only at the repo level with the read/write policy — simpler, at
the cost of the automatic `plan-on-main` job also holding write-capable credentials on
every push to `main`.

Create the user(s) and key(s):

```bash
aws iam create-user --user-name gha-counter-api-terraform-plan   # read-only
aws iam create-user --user-name gha-counter-api-terraform-apply  # read/write
aws iam attach-user-policy --user-name gha-counter-api-terraform-plan  --policy-arn <read-only-policy-arn>
aws iam attach-user-policy --user-name gha-counter-api-terraform-apply --policy-arn <read-write-policy-arn>
aws iam create-access-key --user-name gha-counter-api-terraform-plan
aws iam create-access-key --user-name gha-counter-api-terraform-apply
```

Scope the attached policies down from `AdministratorAccess` once the exact resource ARNs
are known; avoid AWS managed `PowerUserAccess`/`AdministratorAccess` for the long term.

### 3. GitHub repo configuration

- **Environment** `aws-eks` (Settings → Environments) with required reviewers, so a human
  approves every `apply`/`destroy` run.
- **Repo secrets** `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — the read-only user's key
  from step 2 (used by the automatic `plan-on-main` job).
- **Environment secrets** on `aws-eks`, same names `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` — the read/write user's key from step 2 (used only by the manual
  `terraform` job; overrides the repo-level ones for that job).
- **Variable** `AWS_REGION` (optional — defaults to `eu-west-1`, matching
  [`providers.tf`](providers.tf)'s backend block). No `TF_STATE_*` variables needed
  anymore: bucket/key/region/locking are literal in the backend block itself.

## Variables

| Name                    | Description                          | Default            |
|--------------------------|---------------------------------------|---------------------|
| `region`                | AWS region to deploy resources        | `eu-west-1`         |
| `environment`           | Environment name                      | `dev`               |
| `project_name`          | Project name prefix (naming)          | `chamo`             |
| `cluster_version`       | Kubernetes version for EKS            | `1.35`              |
| `vpc_cidr`              | VPC CIDR block                        | `10.0.0.0/16`       |
| `private_subnets`       | Private subnet CIDR blocks            | `10.0.1.0/24`, `10.0.2.0/24`, `10.0.3.0/24` |
| `public_subnets`        | Public subnet CIDR blocks             | `10.0.101.0/24`, `10.0.102.0/24`, `10.0.103.0/24` |
| `argocd_namespace`      | Namespace for Argo CD                 | `argocd`            |
| `argocd_chart_version`  | Argo CD Helm chart version            | `7.8.2`             |
| `enable_argocd_route`   | Expose the Argo CD UI through kgateway | `false`            |
| `argocd_hostname`       | Hostname matched by the Argo CD HTTPRoute | `argocd.chamo.local` |
| `argocd_gateway_create` | Create a dedicated Gateway (+ its own NLB) for Argo CD instead of reusing an existing one | `false` |
| `argocd_gateway_name`   | Existing Gateway to attach the Argo CD route to | `public-nlb-gateway` |
| `argocd_gateway_namespace` | Namespace of that existing Gateway | `counter-api`    |
| `argocd_gateway_section_name` | Listener on that Gateway            | `http`        |
| `argocd_gateway_class_name` | GatewayClass for the dedicated Gateway | `kgateway`   |
| `argocd_gateway_annotations` | Service annotations for the dedicated Gateway's NLB | internet-facing NLB, `target-type: ip` |
| `argocd_gateway_https_section_name` | Name of the TLS-fronted listener on the dedicated Gateway | `https` |
| `argocd_gateway_tls_certificate_arn` | ACM certificate ARN; enables port 443 on the dedicated NLB | `""` (no TLS) |
| `argocd_gateway_tls_port`  | Frontend port that terminates TLS      | `443`               |
| `argocd_gateway_tls_negotiation_policy` | ELB security policy for that listener | `ELBSecurityPolicy-TLS13-1-2-2021-06` |
| `ecr_repository_name`   | ECR repository holding the app image  | `counter-api`       |
| `ecr_untagged_expiry_days` | Days before untagged images expire | `1`                |
| `ecr_keep_last_images`  | How many `sha-` images to keep        | `20`                |

Naming is derived in [locals.tf](locals.tf) as `<project_name>-<environment>`, e.g.
`chamo-dev-vpc`, `chamo-dev-cluster`.

## Outputs

- `ecr_repository_url` — registry path the deploy workflow pushes to; must match
  `image.repository` in the Helm values.
- `instructions` — post-apply cheat sheet with the exact `kubectl`/`aws` commands for
  configuring kubeconfig, retrieving the Argo CD admin password, and reaching the sample
  app through the Gateway/NLB. See [outputs.tf](outputs.tf).

## Notes & considerations

- The EKS API endpoint is restricted to the machine's public IP at apply time
  (`data.http.my_ip`); re-run `terraform apply` if your IP changes and you lose access.
- This setup is intended for **dev/demo** use: Argo CD runs single-replica with Redis HA
  disabled, and the Argo CD server is exposed `insecure` (no TLS) behind the gateway.
- Terraform does not manage the `counter-api` Kubernetes manifests directly — only the
  Argo CD `Application`/`AppProject` pointing at [`deploy/helm/counter-api`](../../deploy/helm/counter-api);
  Argo CD syncs the chart from this repo on every push to `main`.
- The Argo CD route is off by default, so nothing publishes the Argo CD UI unless you set
  `enable_argocd_route = true`. Argo CD itself runs without TLS (`server.insecure = true`),
  so publish it only behind the NLB's TLS port — an ACM certificate plus
  `argocd_gateway_section_name = "https"` (reused Gateway) or
  `argocd_gateway_tls_certificate_arn` (dedicated one). Port 80 stays open alongside 443;
  nothing redirects it yet, so treat the HTTP port as reachable.
- ACM certificates are regional: the one referenced here must live in `var.region`, the same
  region as the cluster and its NLB, and cover the hostnames the HTTPRoutes match.
- kgateway's public NLB is `internet-facing`; adjust
  [`../../deploy/argocd/kgateway/parameters.yaml`](../../deploy/argocd/kgateway/parameters.yaml)
  if an internal-only load balancer is required.
