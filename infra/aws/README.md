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
                         │           │  managed node group │            │
                         │           │  + Karpenter        │            │
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
2. EKS cluster in the private subnets, with a small EKS managed node group for the
   cluster's own controllers.
3. Karpenter (`08-karpenter.tf`) and the AWS Load Balancer Controller
   (`09-load-balancer-controller.tf`) installed on that node group; from here on,
   application capacity is provisioned on demand by Karpenter.
4. Argo CD installed via Helm into the cluster.
5. Gateway API standard CRDs applied, then the kgateway CRDs and kgateway controller
   installed as Argo CD `Application` resources (`kubectl_manifest`).
6. An Argo CD `AppProject` and `Application` are created pointing at the `counter-api`
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
└── infra/aws/                         # (this directory)
    ├── providers.tf                   # Terraform/provider requirements (aws, kubernetes, kubectl, helm)
    ├── variables.tf                   # Input variables (region, naming, CIDRs, ArgoCD chart, ...)
    ├── locals.tf                      # Derived naming, CIDRs, AZs, and caller's public IP
    ├── data.tf                        # Data sources: caller identity, AZs, public IP, EKS auth, CRD docs
    ├── outputs.tf                     # Post-apply instructions (kubeconfig, ArgoCD login, app access, destroy)
    ├── 01-vpc.tf                      # VPC module (terraform-aws-modules/vpc)
    ├── 02-eks.tf                      # EKS module (terraform-aws-modules/eks) + managed node group + addons
    ├── 03-argocd.tf                   # Argo CD Helm release
    ├── 04-ingress-controller.tf       # Gateway API CRDs + kgateway (CRDs and controller) via ArgoCD manifests
    ├── 05-app-deployment.tf           # ArgoCD AppProject + Application for counter-api
    ├── 06-argocd-ingress.tf           # Optional kgateway Gateway/HTTPRoute exposing the Argo CD UI
    ├── 07-ecr.tf                      # ECR repository + lifecycle policy for the app image
    ├── 08-karpenter.tf                # Karpenter IAM/SQS, controller, EC2NodeClass + NodePool
    ├── 09-load-balancer-controller.tf # AWS Load Balancer Controller (IAM via Pod Identity + Helm)
    ├── 10-cluster-access.tf           # Human access: Identity Center permission sets + break-glass role
    ├── 11-monitoring.tf               # EBS CSI + gp3 StorageClass, VictoriaMetrics/Grafana, Grafana Gateway
    ├── 12-keda.tf                     # KEDA via ArgoCD: request-rate autoscaling for counter-api
    ├── policies/                      # Vendored upstream IAM policy documents
    ├── tests/                         # `terraform test` suite for this root (see Tests below)
    └── bootstrap/                     # Separate root: the two CI IAM users and their policies
        └── tests/                     # `terraform test` suite for the bootstrap root
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
- **EKS Auto Mode explicitly disabled** (`compute_config = { enabled = false }`).
  Its bundled, AWS-managed Karpenter would compete with the one we run ourselves,
  and the block is kept rather than deleted because that is what emits the API
  fields that turn Auto Mode — plus its ELB and block-storage integrations — back
  off on a cluster that already had them on.
- **Managed node group** `system` (`var.node_group_*`, default 2 × `t3.medium`
  on-demand, min 2 / max 3) running on AL2023. It exists because Karpenter cannot
  provision the node its own controller runs on: this group carries CoreDNS,
  Karpenter, the AWS Load Balancer Controller, Argo CD and kgateway, and nothing
  else is expected to stay on it.
- **Addons**, which Auto Mode used to supply implicitly: `vpc-cni`, `kube-proxy`
  and `eks-pod-identity-agent` with `before_compute = true` (nodes come up
  NotReady without CNI, and the Pod Identity agent is what backs the Karpenter
  and load-balancer-controller IAM roles), then `coredns` once nodes exist.
- **`karpenter.sh/discovery` tag** on the node security group, matching the one on
  the private subnets in `01-vpc.tf` — that pair is how Karpenter's `EC2NodeClass`
  finds where to put new nodes.
- Cluster creator is automatically granted admin permissions
  (`enable_cluster_creator_admin_permissions`).

### Compute autoscaling (`08-karpenter.tf`)
- **`module.karpenter`** (the `terraform-aws-modules/eks/aws//modules/karpenter`
  submodule) creates the AWS side: the controller IAM role wired through EKS Pod
  Identity, the node IAM role and instance profile, a cluster access entry so
  those nodes may join, and the SQS queue + EventBridge rules that let Karpenter
  drain an instance ahead of a spot interruption or scheduled maintenance.
- **Karpenter controller** installed from `oci://public.ecr.aws/karpenter/karpenter`
  (`var.karpenter_chart_version`), 2 replicas. The chart's default node affinity
  keeps it off Karpenter-provisioned nodes, so it always lands on the managed
  node group.
- **`EC2NodeClass`** — AL2023 (`var.karpenter_node_ami_alias`), private subnets and
  node security group selected by the `karpenter.sh/discovery` tag rather than by
  ID, 50 GiB encrypted gp3 root volume.
- **`NodePool`** — instance categories `c/m/r/t`, generation ≥ 3, amd64, spot with
  on-demand fallback, `WhenEmptyOrUnderutilized` consolidation, nodes replaced
  after `var.karpenter_node_expire_after` (30 days) so they pick up new AMIs, and
  a hard `limits.cpu` of `var.karpenter_node_cpu_limit` (32) vCPU — the cost
  guardrail that makes a runaway ReplicaSet leave pods `Pending` instead of
  growing the bill.

### Human access (`10-cluster-access.tf`)

Reaching the cluster is two separate grants, and both are needed: an IAM
principal to authenticate as, and an **EKS access entry** mapping that principal
to an AWS-managed access policy. A principal with only the first authenticates
fine and is then denied by RBAC on every call.

> This is deliberately **not** IRSA. IRSA binds an IAM role to a Kubernetes
> *service account* through the cluster's OIDC provider — it is how in-cluster
> workloads get AWS credentials (it is what `module.karpenter` and the load
> balancer controller use, via Pod Identity). A person running `kubectl` has no
> service account to bind, so the human path is an access entry instead.

**IAM Identity Center — the normal way in.** People sign in to the access
portal, pick a permission set, and the credentials they receive are already an
IAM role: `AWSReservedSSO_<permission set>_<hash>`. Nothing to assume by hand,
nothing long-lived, and granting or revoking a person is group membership in the
identity store rather than a `terraform apply`.

Terraform does **not** create or assign the permission sets — that happens
wherever Identity Center is administered, which is usually not this account.
What it does is look the provisioned roles up (`data.aws_iam_roles`, filtered by
`AWSReservedSSO_<name>_*` under `/aws-reserved/sso.amazonaws.com/`) and attach
an access entry to each, because the `_<hash>` suffix is assigned by Identity
Center and cannot be predicted here. So the order is: **assign the permission
set to this account first, then apply.** One that has never been assigned has no
role to point at, and a precondition fails the apply saying exactly that.

`var.sso_access_permission_sets` maps permission set name → access level:

| Key | `access_policy` | Grants |
|---|---|---|
| `EKSClusterAdmin` | `cluster-admin` | Full admin, cluster scope only |
| `EKSViewer` | `view` | Read-only |

`admin`, `admin-view` and `edit` are also available, and any of them except
`cluster-admin` can be narrowed to specific `namespaces`.

**The break-glass role.** An ordinary assumable IAM role with cluster-admin,
MFA-gated, deliberately independent of Identity Center — if the identity store
or the access portal is the thing that is broken, every SSO route into the
cluster is broken with it. It is not a second everyday door: its
`-break-glass-assume` managed policy is attached to nobody by default, you
attach it during an incident and detach it afterwards, and every `AssumeRole` on
it lands in CloudTrail under the human's own identity.

`var.additional_cluster_admin_arns` remains as a raw list of principals granted
cluster-admin directly. Reserve it for machine principals that can go through
neither path — for a human it is a standing grant that Identity Center's access
reviews cannot see.

### Load balancing (`09-load-balancer-controller.tf`)
- **AWS Load Balancer Controller**, installed from the `eks-charts` repo with an
  IAM role attached through EKS Pod Identity and the controller's own upstream
  IAM policy (vendored in `policies/aws-load-balancer-controller.json`).
- This is **not optional**: Auto Mode used to provide it, and without it every
  `service.beta.kubernetes.io/aws-load-balancer-*` annotation in this repo is
  inert — the kgateway Gateways would sit forever with no NLB and no external
  address.

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
- No pull credential is needed in the cluster: both node IAM roles — the managed node
  group's and the one Karpenter hands its nodes — carry an ECR read policy, so kubelet
  pulls with the node's own identity.
- `force_delete = true` so `terraform destroy` does not stall on a repository that still
  holds images.

### Application (`05-app-deployment.tf`)
- **AppProject** `go-counter-href-10-sites-project` scoping allowed source repos/destinations.
- **Application** `counter-api`, sourced from this same repo
  (`deploy/helm/counter-api`, branch `main`), deployed into the `counter-api` namespace
  with automated sync (`prune`, `selfHeal`, `CreateNamespace=true`).

### Monitoring (`11-monitoring.tf`)
- **EBS CSI driver** addon (Pod Identity role `<name>-ebs-csi-driver`) and a default
  encrypted **`gp3` StorageClass** -- without Auto Mode nothing else can provision volumes.
- **Application** `victoria-metrics-k8s-stack` (Argo CD, namespace `monitoring`):
  VictoriaMetrics operator, VMSingle (`monitoring_retention`, `monitoring_storage_size`
  on gp3), vmagent, node-exporter, kube-state-metrics and Grafana (5Gi gp3) with the
  default Kubernetes dashboards. Alertmanager and vmalert are off (no receivers yet);
  controller-manager/scheduler/etcd scrapes are off because EKS hides the control plane.
- **Grafana ingress**: a dedicated kgateway `Gateway` + NLB (plain HTTP), with the
  HTTPRoute rendered by the Grafana chart for `grafana_hostname`.
- **counter-api metrics**: the app serves Prometheus metrics on `:9090/metrics` (never
  routed by the Gateway); its chart adds a `VMServiceScrape` once the operator CRDs
  exist, and the `counter-api` dashboard ships from `deploy/monitoring/dashboards/`.

### Autoscaling (`12-keda.tf`)
- **Application** `keda` (Argo CD, namespace `keda`, chart `kedacore/keda`
  `keda_chart_version`): the operator, the admission webhooks, and the aggregated
  `external.metrics.k8s.io` apiserver that feeds request-rate metrics to the HPA.
- KEDA **does not replace the HPA**. The `ScaledObject` in the application chart
  creates `keda-hpa-counter-api`; KEDA only supplies its external metric. The
  gateway proxy keeps the plain CPU HPA kgateway builds from `GatewayParameters`.
- The metrics apiserver runs **two replicas with a PDB**: while it is unreachable
  every ScaledObject-backed HPA reports `unable to fetch metrics` and freezes its
  replica count, and with Karpenter on spot a single replica would mean that on
  every reclaim.
- `ignoreDifferences` covers the `caBundle` on the `keda-admission` webhooks and
  on the `v1beta1.external.metrics.k8s.io` APIService. The operator mints its own
  serving certificates and patches those in; the chart renders them empty, so
  without this `selfHeal` wipes them on every sync. `keda-admission` has **six**
  webhook entries, hence a `jqPathExpressions` over all of them rather than a
  `/webhooks/0` pointer.
- `time_sleep.wait_for_keda_crds` gates `05-app-deployment.tf`: the chart renders
  its `ScaledObject` only once `keda.sh/v1alpha1` is registered, and renders no
  plain HPA when KEDA is enabled — so syncing the application too early leaves the
  Deployment with no autoscaler at all. Same race as `kgateway_sync_wait`.
- The trigger queries VMSingle, so this also depends on `enable_monitoring`. With
  monitoring off only the CPU trigger reports and the `ScaledObject` sits failed.

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
edit that block directly; see [Remote state bootstrap](#1-remote-state-bootstrap) below to
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

**1. Configure kubectl** — through Identity Center, not with your own IAM keys:
```bash
aws configure sso --profile <project>-<env>-eks     # one-time
aws sso login --profile <project>-<env>-eks
aws eks update-kubeconfig --region <region> --name <cluster_name> \
  --profile <project>-<env>-eks

kubectl auth whoami        # what the cluster thinks you are
kubectl auth can-i --list  # what that gets you
```

If `kubectl` authenticates but is denied everything, the permission set has no
access entry: add its name to `var.sso_access_permission_sets` and re-apply.

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

It takes about three minutes longer than you would expect, on purpose.

**Why it needs care.** Two whole classes of AWS resource in this stack are
created from *inside* the cluster and belong to no Terraform resource at all.
Delete the EKS cluster without removing them first and they are simply orphaned
— still running, still billed, and still holding the ENIs that make the VPC
destroy fail with `DependencyViolation`.

### Karpenter's EC2 instances

Karpenter launches instances directly; they are in no Auto Scaling group and no
node group. The only thing that terminates them is Karpenter itself, draining
the `NodeClaim`s that own them. That is wired up deterministically, with no
guessing:

- `kubectl_manifest.karpenter_node_pool` sets `wait = true` and
  `delete_cascade = "Foreground"`. The provider then blocks until the NodePool
  object is really gone, and the Foreground cascade means it is not gone until
  every `NodeClaim` it owns is. A NodeClaim carries the
  `karpenter.sh/termination` finalizer, which Karpenter clears only after it has
  drained the node and terminated the instance. So the delete returns exactly
  when the last instance is gone.
- Both Argo CD `Application`s are ordered **ahead** of the NodePool. The
  counter-api chart ships a PodDisruptionBudget (`maxUnavailable: 25%`) and so
  does the gateway proxy (`minAvailable: 1`); a PDB cannot block the eviction of
  a pod that no longer exists, so the workloads go first and the drain has
  nothing to fight. The same edge gives the right order on the way up: the
  NodePool exists before the application is handed to Argo CD.

The resulting order is `workloads → NodePool (drains, terminates) → Karpenter
controller → cluster`.

### The EBS volumes

Same shape as the load balancers: the volumes behind the VMSingle and Grafana
PVCs belong to no Terraform resource. The EBS CSI driver creates them, and only
the EBS CSI driver deletes them — and it is an EKS addon *inside* `module.eks`,
so it disappears with the cluster.

The gp3 StorageClass already sets `reclaimPolicy: Delete`, so the policy was
never the problem. The ordering was: neither the monitoring `Application` nor
the namespace blocked on their deletes, so Terraform fired both and moved on
while the PVCs were still terminating. Two destroys leaked a 20Gi and a 5Gi
volume that way, left `available` and billed.

The chain, and what now blocks on each link:

```text
Application deleted  (wait: blocks on the Argo CD finalizer -> chart pruned,
                      Grafana's PVC with it)
  -> namespace deleted (wait: blocks on the namespace finalizer, which is not
                        cleared until every PVC inside is gone --
                        kubernetes.io/pvc-protection holds each one until no
                        pod uses it)
  -> the PV each PVC was bound to is released
  -> reclaimPolicy: Delete -> the CSI driver deletes the EBS volume
  -> 60s barrier (time_sleep.storage_teardown) keeps module.eks, the addon and
     its nodes alive across that last step
  -> module.eks
```

Only the last link is asynchronous, and `var.storage_teardown_wait` is the
margin around it. Raise it if a destroy still leaves `available` volumes.

### When an Application will not finish terminating

`wait = true` on an Argo CD `Application` turns a silent orphan into a visible
failure, which is the trade it is there to make — but it does mean a stuck
finalizer now fails the destroy:

```text
Error: victoria-metrics-k8s-stack failed to delete resource
```

An `Application` can carry more than the one finalizer this README talks about.
When the chart ships `PreDelete` hooks it also gets
`pre-delete-finalizer.argocd.argoproj.io` and `.../cleanup`, and Argo CD will
not clear them until those hooks have run:

```bash
kubectl get application <name> -n argocd -o jsonpath='{.metadata.finalizers}'
kubectl -n argocd logs argocd-application-controller-0 --tail=200 | grep -i 'pre-delete\|hook'
```

That is how the `victoria-metrics-k8s-stack` case was found: the parent chart
enables the operator's CRD cleanup hook, whose Job is named
`<release>-victoria-metrics-operator-cleanup-hook` — 65 characters at this
release name. Kubernetes copies a Job's name into its pod template's automatic
`job-name` label, a label value may not exceed 63 bytes, and the API server
rejects the Job. Argo CD retried the hook forever. `crds.cleanup.enabled` is
now `false` in `local.victoria_metrics_k8s_stack_values`.

### The instance profile Terraform never sees

An `EC2NodeClass` with `spec.role` does not use an instance profile you gave
it — it makes **Karpenter create one**, named `<cluster>_<hash>`, and manage it.
Terraform has no resource for it and cannot delete it. Only Karpenter does, and
only when the `EC2NodeClass` is deleted, so a teardown where Karpenter died
first leaves it behind.

That is a slow-acting trap, because `node_iam_role_use_name_prefix = false`
keeps the node role's name stable across rebuilds. The stale profile latches
onto the freshly created role, and the destroy *after that* fails on something
that names neither Karpenter nor the profile:

```text
Failed deleting role chamo-dev-karpenter-node.
Cannot delete entity, must remove roles from instance profile first.
```

`create_instance_profile = true` on the karpenter module plus
`spec.instanceProfile` on the `EC2NodeClass` moves ownership to Terraform:
Karpenter creates no shadow profile, and the real one is destroyed in order.

To clear one that is already stranded:

```bash
aws iam list-instance-profiles-for-role --role-name <cluster>-karpenter-node
aws iam remove-role-from-instance-profile \
  --instance-profile-name <name> --role-name <cluster>-karpenter-node
aws iam delete-instance-profile --instance-profile-name <name>
```

### When a controller's CRDs are deleted out from under it

The AWS Load Balancer Controller does not only reconcile `Service` objects. From
v3.5.0 it also starts informers for the Gateway API kinds — `ListenerSet`,
`TLSRoute`, `GRPCRoute`, `TCPRoute` in `gateway.networking.k8s.io`. Those CRDs
are `kubectl_manifest.kgateway_crds`, a Terraform resource, and nothing used to
stop Terraform deleting them while the controller was still running:

```
Failed to watch *v1.ListenerSet: the server could not find the requested
resource (get listenersets.gateway.networking.k8s.io)
```

controller-runtime will not start a manager whose caches cannot sync, so the
**Service reconciler never runs**. `service.k8s.aws/resources` is never cleared,
the three NLBs behind those Services are never deleted, and the destroy ends in
errors that point at the VPC rather than at the controller:

```text
Error: deleting EC2 Internet Gateway (...): DependencyViolation: Network
       vpc-... has some mapped public address(es)
Error: deleting EC2 Subnet (...): DependencyViolation
```

`helm_release.aws_load_balancer_controller` now `depends_on` the CRDs, which
puts them *after* it on destroy. It is the right order on create too: without
them present at startup the controller logs the same watch errors.

**The general rule, and it has now bitten three different ways in this stack:
whatever a controller needs in order to do its cleanup — its nodes, its CRDs,
its operator — has to be destroyed after it, and only an explicit `depends_on`
says so.** A reference to a module output does not.

To unwedge a cluster already in this state, put the CRDs back so the controller
can sync, then delete the Services and let it do its job:

```bash
kubectl apply --server-side -f deploy/argocd/kgateway/standard-install.yaml
kubectl -n kube-system rollout restart deploy/aws-load-balancer-controller
kubectl delete svc -n argocd argocd-gateway
kubectl delete svc -n counter-api public-nlb-gateway
kubectl delete svc -n monitoring grafana-gateway
```

If the controller cannot be revived, delete the load balancers through the AWS
API and strip `service.k8s.aws/resources` from the Services by hand — the NLBs
are what the VPC is actually waiting on.

### When an operator is pruned before the resources it finalizes

The other half of the same problem, and the one that produces the most
confusing error list. Argo CD's prune has **no ordering of its own**: it can
remove an operator's Deployment alongside the custom resources that operator is
supposed to finalize. Those CRs then delete forever, because nothing left in
the cluster can clear their finalizer.

```
$ kubectl get ns monitoring -o jsonpath='{.status.conditions[*].message}'
Some content in the namespace has finalizers remaining:
apps.victoriametrics.com/finalizer in 2 resource instances
```

From there it cascades into errors that name none of the above:

```text
Error: default failed to delete resource        # the Karpenter NodePool
Error: monitoring failed to delete resource     # the namespace
Error: deleting EC2 Internet Gateway (...): DependencyViolation: Network
       vpc-... has some mapped public address(es)
Error: deleting EC2 Subnet (...): DependencyViolation
```

The chain: the CRs hold the namespace in `Terminating`, the namespace holds the
Grafana `Service`, so the load balancer controller never deletes its NLB, the
still-mapped public addresses block the internet gateway detach, and the
subnets fail behind it.

`victoria-metrics-operator.annotations` now carries
`argocd.argoproj.io/sync-options: PruneLast=true`, which holds the operator
back until everything else is pruned — the window its finalizers need. **Any
operator-backed chart added here needs the same treatment**; the symptom is
always a namespace stuck on a finalizer whose controller is already gone.

To unwedge one that is already stuck, strip the finalizer from the custom
resources — the operator that would have done it is gone, and the namespace
delete removes the children it would have cleaned up anyway:

```bash
# kubectl patch takes no --all: feed it the names.
kubectl get vmsingle,vmagent -n monitoring -o name \
  | xargs -r -I{} kubectl patch {} -n monitoring \
      --type=merge -p '{"metadata":{"finalizers":null}}'
```

**To get out of an Application stuck on its own finalizers**, drop them and let
the namespace delete do the real cleanup — it cascades to the PVCs, which is what the EBS volumes hang off:

```bash
kubectl patch application <name> -n argocd --type=merge \
  -p '{"metadata":{"finalizers":null}}'
cd infra/aws && terraform destroy
```

Anything cluster-scoped the chart left behind (CRDs, ClusterRoles) goes with
the cluster a few minutes later.

### The compute has to outlive the controllers

Karpenter, the load balancer controller and Argo CD are all *pods*. Each one
has to still be running to clean up what it owns — the NodeClaims, the NLBs,
the Application cascade. So the managed node group they run on has to be one of
the last things to go.

Nothing expressed that. Every one of them references `module.eks.cluster_name`
or `module.eks.cluster_endpoint`, which builds an edge to the cluster and to
**nothing else**; the node group is a separate resource inside the module with
no edge to any of them. On destroy Terraform was therefore free to delete the
node group *in parallel* with them.

On 2026-09-20 it did exactly that, and the teardown deadlocked:

```text
14:12  NodePool deleted -> Karpenter taints its 3 nodes karpenter.sh/disrupted
       and starts draining; the NodeClaims get karpenter.sh/termination
 ~same  the managed node group is deleted in parallel -- the system nodes go
       away, and with them the Karpenter and load balancer controller pods
  then  those pods cannot reschedule: the only nodes left carry the taint
       their Deployment deliberately does not tolerate
```

Only Karpenter can clear `karpenter.sh/termination`, and Karpenter had nowhere
to run. The `wait = true` on the NodePool then blocked forever on a finalizer
nobody was left to remove, the three NLBs were never deleted, and the three
instances had to be terminated by hand.

The fix is a `depends_on = [module.eks]` on the three `helm_release`s — the
whole module, not one of its outputs, which is what pulls the node group in.
Everything else (the NodePool, the Applications) inherits it transitively.
Verify with the `terraform graph` recipe under
[What the tests can and cannot see](#what-the-tests-can-and-cannot-see).

### The load balancers

None of the three NLBs in this stack belong to Terraform.
Each one is created by the AWS Load Balancer Controller, from inside the
cluster, in response to a `Service` of type `LoadBalancer` that kgateway
provisions for a `Gateway`:

| NLB | Gateway | Owned by |
| --- | --- | --- |
| counter-api | `public-nlb-gateway` (ns `counter-api`) | Argo CD, via the Helm chart |
| Argo CD UI | `argocd-gateway` (ns `argocd`) | Terraform (`06-argocd-ingress.tf`) |
| Grafana | `grafana-gateway` (ns `monitoring`) | Terraform (`11-monitoring.tf`) |

All Terraform can do is delete the `Gateway` (or the Argo CD `Application` that
owns it) and let the rest of the chain run:

```text
Gateway/Application deleted
  -> kgateway deletes the Service
  -> the load balancer controller sees the Service's
     service.k8s.aws/resources finalizer
  -> it deletes the NLB
  -> only then does the Service actually go away
```

Every step there is asynchronous, so three things are wired in to keep the
destroy honest:

- The two Gateways Terraform *does* own use the same trick as the NodePool
  above (`wait = true`, `delete_cascade = "Foreground"`). kgateway creates each
  Gateway's Service with an ownerReference back to it, and that Service carries
  the controller's `service.k8s.aws/resources` finalizer — cleared only once the
  NLB is really deleted. So those two deletes block until their NLB is gone.

- The Argo CD `Application`s carry `resources-finalizer.argocd.argoproj.io`
  ([`deploy/argocd/application.yaml`](../../deploy/argocd/application.yaml) and
  the `victoria-metrics-k8s-stack` Application in `11-monitoring.tf`). Without
  it, deleting an Application removes only the Application object: the
  namespace, the Gateway, the Service and the NLB all survive, and so do
  Grafana's and VMSingle's gp3 volumes.

- **counter-api's NLB is the one Terraform owns least**, and it is handled
  through that finalizer. Terraform owns neither its Gateway nor its Service —
  the chart creates both — so the only thing it can block on is the
  `Application` itself. `kubectl_manifest.argocd_application` sets `wait = true`
  (`delete_cascade = "Foreground"`), and the provider's `wait` blocks on
  finalizers: Argo CD clears `resources-finalizer` only after it has pruned
  every resource the chart deployed, Gateway included. So the delete returns
  when the NLB is really gone.

  Before this, that delete returned as soon as the API server accepted it,
  while the cascade was still running — leaving only the timer below between a
  slow NLB delete and an orphaned load balancer. If the cascade ever wedges and
  the destroy hangs there, `kubectl patch application counter-api -n argocd
  --type=merge -p '{"metadata":{"finalizers":null}}'` releases it, at the cost
  of orphaning whatever had not been pruned.

- `time_sleep.load_balancer_teardown` (`09-load-balancer-controller.tf`) sits
  between those deletions and the controller, so the controller — and therefore
  the cluster — stays up for `var.load_balancer_teardown_wait` (default `180s`)
  after the last Gateway is deleted. With all three NLBs now blocking their own
  delete this is margin rather than mechanism, but it still covers anything
  still in flight — Terraform would otherwise remove the controller seconds
  later.

The resulting order is:

```text
Applications (cascade: pods, Gateways, Services, PVCs)
  -> Karpenter NodePool   (blocks until every instance is terminated)
  -> Applications         (block on the Argo CD finalizer: the counter-api
                           Gateway, its Service and its NLB are gone first;
                           the monitoring chart and Grafana's PVC likewise)
  -> monitoring namespace (blocks until every PVC in it is gone)
  -> 60s storage barrier  (the CSI driver deletes the EBS volumes)
  -> Gateways Terraform owns (block until their NLB is gone)
  -> 180s barrier         (margin for anything still in flight)
  -> Karpenter controller + load balancer controller
  -> Argo CD
  -> EKS (cluster AND its managed node group) -> VPC
```

Nothing about this affects `apply`: the barrier has no `create_duration`.

**Before the first clean destroy**, run one `terraform apply`. The finalizer
lives in a manifest, so an Application created before this change does not have
it and will not cascade.

**If a destroy still leaves load balancers behind**, raise
`var.load_balancer_teardown_wait` and re-run — Terraform is idempotent here.
Check what is left with:

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='<vpc-id>'].[LoadBalancerName,DNSName]" --output table
aws ec2 describe-instances --filters "Name=tag-key,Values=karpenter.sh/nodepool" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output table
```

**If a destroy hangs on the NodePool**, a node is failing to drain — almost
always a pod its PodDisruptionBudget will not let go of. Look first, then
release it:

```bash
kubectl get nodeclaims
kubectl get pdb -A
kubectl delete nodeclaims --all          # Karpenter still terminates the instances
```

If Karpenter itself is already gone, its finalizers have nobody to clear them;
strip them and terminate the instances yourself:

```bash
kubectl patch nodeclaim <name> --type=merge -p '{"metadata":{"finalizers":null}}'
aws ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=default" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

**If a destroy hangs on an Application**, the cascade is waiting for something
it cannot delete (usually because Argo CD or the controller is already gone).
Drop the finalizer by hand and re-run:

```bash
kubectl -n argocd patch application <name> \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

That leaves the NLB orphaned, so delete it yourself afterwards
(`aws elbv2 delete-load-balancer --load-balancer-arn ...`) before the VPC
destroy, which would otherwise fail with `DependencyViolation` on the private
subnets.

## Tests

```bash
cd infra/aws
terraform test
```

79 tests across seven files in [`tests/`](tests). **They need no AWS credentials
and touch nothing** — every provider is replaced by a `mock_provider`, so a run
never reaches an API, never reads or writes the S3 state, and never sees the
real cluster. A full run takes about three minutes.

| File | What it pins |
|---|---|
| `network_and_cluster.tftest.hcl` | Naming and the `<project>-<env>-*` prefix the CI apply user's IAM is scoped to; VPC CIDRs, AZ count, single NAT; the subnet tags Karpenter and the load balancer controller discover by; the addon set that replaces Auto Mode; the controller's Pod Identity wiring |
| `cluster_access.tftest.hcl` | Identity Center permission sets → EKS access entries (policy mapping, namespace scoping, path stripping); the break-glass role and its assume policy; `additional_cluster_admin_arns`; every variable validation |
| `argocd_ingress.tftest.hcl` | The Gateway create-vs-reuse logic, TLS termination at the NLB, listener and `parentRef` wiring, host matching, and the off switches |
| `karpenter_and_ecr.tftest.hcl` | NodePool requirements and the CPU ceiling, EC2NodeClass discovery tags, the spot service-linked role, ECR immutability and the lifecycle rules |
| `monitoring.tftest.hcl` | The gp3 StorageClass, VMSingle/Grafana storage, the components deliberately left off, and the Argo CD sync options the chart's quirks need |
| `keda.tftest.hcl` | The Argo CD Application's chart coordinates and sync options, the `caBundle` ignores that keep the webhooks working across a sync, the two-replica metrics apiserver and its PDB, and the barrier the application waits on |
| `lifecycle.tftest.hcl` | The orderings that only fail against a real cluster: on the way up, the wait for Argo CD to sync kgateway's CRDs and the disabled Service mutator webhook; on the way down, the cascade finalizers, the `wait`s that block on them, and the two teardown barriers (load balancers, storage) described under [Destroy](#destroy) |

Useful flags:

```bash
terraform test -filter=tests/argocd_ingress.tftest.hcl   # one file
terraform test -verbose                                  # show the plan behind a failure
terraform test -json                                     # machine-readable, for CI
```

In CI, `terraform init -backend=false` is enough — the tests never use the
backend:

```bash
cd infra/aws && terraform init -backend=false && terraform test
```

### Reading a failure

A failing `run` marks every later `run` **in the same file** as `skip`, because
Terraform aborts a test file at the first failure. `1 failed, 12 skipped` means
one real failure, not thirteen. Other files still run.

### What the tests can and cannot see

Worth knowing before adding to them:

- **Assertions reach a module's outputs, never its internal resources.**
  `module.eks.cluster_version` works; `module.eks.aws_eks_cluster.this[0]` does
  not. So the managed node group's launch template and the `compute_config`
  block are not asserted — they are not observable from a test. The addon set
  is, through `module.eks.cluster_addons`.
- **Values that come out of a provider are fake**, including
  `data.aws_iam_policy_document.*.json`. Assume-role policies are therefore not
  assertable in this root. The policies that *are* asserted — the ECR lifecycle
  rules, the break-glass assume policy — are built with `jsonencode()` in the
  configuration itself. (The bootstrap root does not have this limitation; see
  [`bootstrap/README.md`](bootstrap/README.md#tests).)
- **Dependency ordering is invisible to the tests.** `depends_on` is not an
  attribute, so no assertion can prove that one resource outlives another on
  destroy — the orderings in `lifecycle.tftest.hcl` assert the *attributes*
  that implement them (`wait`, `delete_cascade`, a finalizer in a manifest),
  never the graph edges. Check those with `terraform graph` instead:

  ```bash
  terraform graph > graph.dot
  # everything whose pods must outlive the compute they run on should reach
  # the node group; if one of these prints False, a destroy can deadlock
  grep -E '"(helm_release\.(karpenter|argocd|aws_load_balancer_controller))" ->' graph.dot
  ```

  This is not academic. See **The compute has to outlive the controllers**
  under [Destroy](#destroy).

- **`terraform test` loads `terraform.tfvars`.** A `run` block with no
  `variables` of its own is therefore testing the configuration *as actually
  deployed*, not the variable defaults.
- **Most runs use `command = apply`**, not `plan`, because the interesting
  values (rendered Helm values, manifest bodies that interpolate a cluster name)
  are only known once resources exist. With every provider mocked, an apply
  calls nothing.

## Continuous deployment

The repository has exactly two workflows: this one deploys the infrastructure,
and [`deploy.yml`](../../.github/workflows/deploy.yml) deploys the code. They
share no steps and use different IAM users — see
[3. GitHub repo configuration](#3-github-repo-configuration).

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

Automated in [`bootstrap/`](bootstrap/) — a separate Terraform root that creates
both users and their policies:

```bash
cd infra/aws/bootstrap
terraform init && terraform apply
```

It is separate from this stack on purpose: these users *are* the credentials
this stack runs with, so managing them from inside it would let an apply revoke
the permissions of the run performing it — and the first apply could never
happen at all, since the users must exist before anything can authenticate. It
runs once, by a human with administrator credentials, and keeps local state.
If the users already exist from the old manual setup, import them first; see
[bootstrap/README.md](bootstrap/README.md).

The workflow reads `TF_AWS_ACCESS_KEY_ID`/`TF_AWS_SECRET_ACCESS_KEY` from GitHub secrets.
The `TF_` prefix keeps them separate from the plain `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`
that [`deploy.yml`](../../.github/workflows/deploy.yml) uses to push images to ECR — that
credential needs write access to ECR, so it cannot be the read-only plan user.

GitHub resolves **environment** secrets before repo-level ones for any job bound to that
environment, so defining the same two names at both levels gives the two jobs different
privilege without any extra workflow logic:

| Secret scope | Used by | IAM user | Policies |
|---|---|---|---|
| Repo-level (Settings → Secrets and variables → Actions) | `plan-on-main` (automatic, every push) | `gha-counter-api-terraform-plan` | `ReadOnlyAccess` + `<project>-<env>-terraform-shared` |
| Environment-level, on `aws-eks` (Settings → Environments → aws-eks → secrets) | `dispatch` (manual `plan`/`apply`/`destroy`) | `gha-counter-api-terraform-apply` | the above + `<project>-<env>-terraform-apply` |

Two details in there are easy to get wrong, and both are handled in the shared
policy rather than left to whoever sets this up:

- **The state grant is not read-only, even for the plan user.**
  `use_lockfile = true` in [`providers.tf`](providers.tf) means a plan writes and
  deletes `terraform.tfstate.tflock`; without `s3:PutObject`/`s3:DeleteObject`
  every plan fails to acquire its lock.
- **`iam:ListRoles` is needed by both users.**
  [`10-cluster-access.tf`](10-cluster-access.tf) resolves the `AWSReservedSSO_*`
  roles Identity Center has provisioned in the account, and that lookup runs at
  *plan* time — so the read-only job fails just as hard without it as the apply
  job does.

Access keys are opt-in (`var.create_access_keys`, default `false`) because
Terraform stores the secret in state and this root's state is local. Left off,
create them out of band:

```bash
aws iam create-access-key --user-name gha-counter-api-terraform-plan
aws iam create-access-key --user-name gha-counter-api-terraform-apply
```

If you'd rather not maintain two IAM users, define `TF_AWS_ACCESS_KEY_ID`/
`TF_AWS_SECRET_ACCESS_KEY` only at the repo level with the apply user's key — simpler, at
the cost of the automatic `plan-on-main` job also holding write-capable credentials on
every push to `main`.

Reviewer approval is not in the workflow file: add it on the Environment itself
(Settings → Environments → `aws-eks` → **Required reviewers**). `apply` and `destroy`
additionally require typing the cluster name into the `confirm` input, so a mis-clicked
dropdown cannot delete the cluster on its own.

The apply policy is scoped by name for IAM (`<project>-<env>-*`, plus a
conditioned `CreateServiceLinkedRole` and the cluster's OIDC provider) and
guarded by explicit `Deny` statements so it cannot widen its own permissions,
but its non-IAM half is still service-level `ec2:*`/`eks:*`/… on `*`. Tightening
that to resource ARNs is the next step and needs the ARNs of a cluster that
already exists.

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
| `argocd_chart_version`  | Argo CD Helm chart version            | `10.9.1`            |
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
| `sso_access_permission_sets` | Identity Center permission sets → EKS access level | `EKSClusterAdmin` = `cluster-admin`, `EKSViewer` = `view` |
| `break_glass_role_enabled` | Create the emergency cluster-admin role | `true`           |
| `break_glass_trusted_principals` | Who may assume it; empty = account root (delegates to IAM) | `[]` |
| `break_glass_require_mfa` | Require MFA to assume it             | `true`              |
| `break_glass_max_session_duration` | Seconds before the session expires | `3600`      |
| `node_group_instance_types` | Instance types for the system managed node group | `["t3.medium"]` |
| `node_group_min_size` / `_desired_size` / `_max_size` | Size of that node group | `2` / `2` / `3` |
| `node_group_capacity_type` | Billing model for that node group  | `ON_DEMAND`         |
| `node_group_disk_size`  | Root EBS volume (GiB) for its nodes   | `30`                |
| `karpenter_chart_version` | Karpenter Helm chart version        | `1.14.0`            |
| `karpenter_namespace`   | Namespace the Karpenter controller runs in | `kube-system`  |
| `karpenter_node_instance_categories` | Instance categories Karpenter may pick (no burstable `t`) | `["c","m","r"]` |
| `karpenter_node_instance_generations_min` | Minimum instance generation | `3`            |
| `karpenter_node_architectures` | CPU architectures Karpenter may pick (image is amd64-only) | `["amd64"]` |
| `karpenter_node_capacity_types` | Capacity types Karpenter may provision | `["spot","on-demand"]` |
| `karpenter_node_cpu_limit` | Hard vCPU ceiling for the NodePool (cost guardrail) | `32` |
| `karpenter_node_expire_after` | Node lifetime before drain + replace | `720h`         |
| `karpenter_node_consolidation_after` | Idle time before consolidation  | `1m`          |
| `karpenter_node_ami_alias` | AMI alias nodes are resolved from  | `al2023@latest`     |
| `load_balancer_controller_chart_version` | aws-load-balancer-controller chart version | `3.5.0` |
| `load_balancer_controller_namespace` | Namespace it runs in       | `kube-system`       |
| `load_balancer_controller_service_account` | Its service account (bound to the Pod Identity association) | `aws-load-balancer-controller` |
| `load_balancer_teardown_wait` | How long `destroy` keeps the controller alive after the last Gateway is deleted, so it can finish deleting the NLBs ([Destroy](#destroy)) | `180s` |
| `kgateway_sync_wait` | How long to wait for Argo CD to sync the kgateway charts before creating the first `GatewayParameters` | `120s` |
| `enable_monitoring` | Install VictoriaMetrics + Grafana via Argo CD | `true` |
| `monitoring_namespace` | Namespace for the monitoring stack | `monitoring` |
| `victoria_metrics_k8s_stack_chart_version` | victoria-metrics-k8s-stack chart version | `0.92.1` |
| `monitoring_retention` | VMSingle retention | `15d` |
| `monitoring_storage_size` | VMSingle gp3 volume size | `20Gi` |
| `enable_grafana_route` | Publish Grafana through its own Gateway/NLB | `true` |
| `storage_teardown_wait` | How long to hold the EBS CSI driver alive after the monitoring namespace is gone, so it can delete the PVCs' volumes | `60s` |
| `enable_keda` | Install KEDA via Argo CD. Flip together with `autoscaling.keda.enabled` in the Helm values, or the app ends up with no autoscaler | `true` |
| `keda_namespace` | Namespace for the KEDA operator, adapter and webhooks | `keda` |
| `keda_chart_version` | kedacore/keda chart version (tracks appVersion) | `2.20.2` |
| `keda_sync_wait` | How long to wait for Argo CD to sync KEDA before creating the counter-api Application | `120s` |
| `grafana_hostname` | Hostname the Grafana HTTPRoute matches | `grafana.alvarolinarescabre.com` |

Naming is derived in [locals.tf](locals.tf) as `<project_name>-<environment>`, e.g.
`chamo-dev-vpc`, `chamo-dev-cluster`.

## Outputs

- `ecr_repository_url` — registry path the deploy workflow pushes to; must match
  `image.repository` in the Helm values.
- `cluster_access` — the Identity Center permission sets mapped to the cluster
  (with the role ARN each resolves to) and the break-glass role/assume-policy
  ARNs. See [10-cluster-access.tf](10-cluster-access.tf).
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
