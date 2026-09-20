# go-counter-href-10-sites

A Go service that downloads multiple HTML pages and counts the words contained in
links whose `href` is an absolute `http://` or `https://` URL. The application
exposes an HTTP API with Gin and a Swagger interface.

The repository also contains the entire AWS execution platform:

- Amazon EKS for Kubernetes.
- Terraform for VPC, cluster, nodes, IAM, ECR, Karpenter, and controllers.
- Argo CD to synchronize Kubernetes from Git.
- Gateway API + kgateway to publish the application via an NLB.
- Helm to package the `counter-api` deployment.
- Two GitHub Actions workflows: one deploys the code, one deploys the
  infrastructure.
- VictoriaMetrics + Grafana for cluster and application metrics.
- KEDA scaling the application on the request rate it actually serves, and a
  plain CPU HPA for the gateway proxy, with zero-downtime rollouts.
- An in-cluster load test that exercises the public path (NLB -> gateway -> app).

## Architecture and deployment flow

```text
GitHub push to main
        |
        v
GitHub Actions -- build Docker -- push ECR -- update values.yaml
                                                   |
                                                   v
Git Repository <- Argo CD <- Application <- Helm chart
                                      |
                                      v
           Deployment + ScaledObject + Service + Gateway + HTTPRoute
                                      |
                                      v
             AWS NLB -> kgateway proxy (HPA) -> counter-api (KEDA)
                                                        |
                                                  :9090/metrics
                                                        |
                                                        v
                            vmagent -> VMSingle (EBS gp3) <- Grafana
                                           |
                                           +--> KEDA --> keda-hpa-counter-api
```

Terraform is used to create the platform and hand control to Argo CD.
After `terraform apply`, Terraform does not directly manage application objects:
Argo CD's `Application` observes `deploy/helm/counter-api` on the `main` branch
and applies its changes automatically.

## Repository structure

```text
apps/counter-api/              Go code, tests, Swagger, and Dockerfile
apps/counter-api/loadtest/     Load generators, stub origin, in-cluster Job
deploy/helm/counter-api/       Helm chart for the application
deploy/argocd/                 Application, AppProject, and kgateway
deploy/monitoring/dashboards/  Grafana dashboards shipped by Terraform
infra/aws/                     Terraform for AWS/EKS (11-monitoring.tf: metrics,
                               12-keda.tf: autoscaling)
infra/aws/tests/               `terraform test` suite for the AWS stack
infra/aws/bootstrap/           Initial IAM for GitHub Actions
infra/aws/bootstrap/tests/     `terraform test` suite for the bootstrap root
.github/workflows/deploy.yml         Code: build, push to ECR, GitOps promotion
.github/workflows/terraform-aws.yml  Infrastructure: validate, test, plan, apply
```

## Requirements

To run the application locally:

- Go 1.25 or newer.
- Docker, if you want to build the image locally.

To deploy on AWS:

- AWS account with permissions to create VPC, EKS, IAM, ECR, NLB, KMS, SQS,
  EventBridge, and CloudWatch Logs.
- Terraform 1.10 or newer. The backend uses native S3 locking via `use_lockfile`.
- AWS CLI v2.
- `kubectl`.
- Git and write access to the repository.
- Outbound internet access from the machine running Terraform. Terraform queries
  `https://checkip.amazonaws.com` to restrict the public EKS endpoint to the
  current IP.
- An AWS Identity Center identity assigned to the account, if you will use human
  access configured by `infra/aws/10-cluster-access.tf`.

## Local development

```bash
cd apps/counter-api
go mod download
go run .
```

The server listens on `http://localhost:8080`. Available variables:

| Variable | Default | Description |
|---|---:|---|
| `PORT` | `8080` | Server HTTP port |
| `METRICS_PORT` | `9090` | Port serving Prometheus metrics at `/metrics` |
| `TARGET_URLS` | 10 predefined sites | Comma-separated URLs |
| `HTTP_TIMEOUT_SECONDS` | `10` | Timeout for each fetch |
| `REFRESH_INTERVAL_SECONDS` | `60` | Cache refresh interval |

The request does not fetch pages. A background refresher fetches the configured
URLs and publishes an atomic snapshot in memory. That is why query routes read
the cache and respond without making outbound HTTP calls during the request.

Run tests:

```bash
cd apps/counter-api
go test ./...
```

Regenerate Swagger after modifying annotations:

```bash
cd apps/counter-api
go run github.com/swaggo/swag/cmd/swag@v1.16.4 init -g main.go -o docs
```

## API

| Method and route | Purpose |
|---|---|
| `GET /` | API navigation |
| `GET /healthcheck` | Health check |
| `GET /v1/tags` | Count for all configured URLs |
| `GET /v1/tags/{url_id}` | Count for a single URL |
| `GET /v1/cache/clear` | Force an out-of-band refresh |
| `GET /docs` | Redirect to Swagger UI |
| `GET /swagger/index.html` | Swagger UI |
| `GET :9090/metrics` | Prometheus metrics, on a separate port |

Metrics live on their own port on purpose: the HTTPRoute only targets the API
port, so `/metrics` is never reachable through the public Gateway.

## AWS deployment, step by step

The following steps must be executed from the repository root, unless otherwise
stated. Default values create resources in `eu-west-1`, with project `chamo` and
environment `dev`.

### 1. Configure and verify AWS credentials

Use an AWS profile or environment variables. For Identity Center:

```bash
aws configure sso --profile chamo-dev-eks
aws sso login --profile chamo-dev-eks
export AWS_PROFILE=chamo-dev-eks
aws sts get-caller-identity
```

The identity that runs the first `terraform apply` receives cluster admin
permissions via `enable_cluster_creator_admin_permissions`. For regular access,
the Identity Center permission set must be assigned to the AWS account
beforehand; Terraform looks for the `AWSReservedSSO_*` role that Identity
Center creates.

### 2. Create the remote Terraform bucket

The backend is defined literally in
[`infra/aws/providers.tf`](infra/aws/providers.tf): bucket
`chamo-terraform-state-2027`, region `eu-west-1`, key `terraform.tfstate`, and
locking via `terraform.tfstate.tflock`.

The bucket must exist before `terraform init`:

```bash
aws s3api create-bucket \
  --bucket chamo-terraform-state-2027 \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

aws s3api put-bucket-versioning \
  --bucket chamo-terraform-state-2027 \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket chamo-terraform-state-2027 \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

If you change the bucket or region, first edit the `backend "s3"` block in
`infra/aws/providers.tf`. Do not rely on CI variables for this backend: a
`terraform init` without the expected variable could create local state and
produce duplicate resources.

### 3. Prepare GitHub Actions IAM users (optional but necessary for CI)

This step runs once with admin credentials. The separate root creates two users:

- `gha-counter-api-terraform-plan`: read-only for automatic plans.
- `gha-counter-api-terraform-apply`: write for manual apply/destroy.

```bash
cd infra/aws/bootstrap
terraform init
terraform plan
terraform apply
```

By default, it does not create access keys to avoid storing secrets in local
state. Create keys outside Terraform:

```bash
aws iam create-access-key --user-name gha-counter-api-terraform-plan
aws iam create-access-key --user-name gha-counter-api-terraform-apply
```

Save the values once in GitHub and do not include them in the repository. If the
users already exist, import them before `apply`:

```bash
terraform import 'aws_iam_user.ci["plan"]' gha-counter-api-terraform-plan
terraform import 'aws_iam_user.ci["apply"]' gha-counter-api-terraform-apply
terraform apply
```

Permission and adoption details are in
[`infra/aws/bootstrap/README.md`](infra/aws/bootstrap/README.md).

### 4. Configure Identity Center and Terraform variables

Before the main apply:

1. Assign to this account the permission set you want to use for EKS.
2. Confirm that the `AWSReservedSSO_*` role exists in IAM.
3. Review `infra/aws/variables.tf` and create a local `terraform.tfvars` if you
   need different names, CIDRs, region, or certificates.

Minimal example:

```hcl
region      = "eu-west-1"
project_name = "chamo"
environment  = "dev"
argocd_hostname = "argocd.example.com"
enable_argocd_route = true
argocd_gateway_create = true
argocd_gateway_tls_certificate_arn = "arn:aws:acm:eu-west-1:ACCOUNT:certificate/ID"
```

The ACM certificate must exist in the same region as EKS and cover the hostname.
The application chart has its own hostname and certificate configuration in
[`deploy/helm/counter-api/values.yaml`](deploy/helm/counter-api/values.yaml).

### 5. Initialize Terraform and review the plan

```bash
cd infra/aws
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
```

Especially review region, CIDRs, names, and certificate ARN. The plan includes
VPC, subnets, NAT Gateway, EKS, node group, Karpenter, AWS Load Balancer
Controller, Argo CD, Gateway API, kgateway, ECR, the EBS CSI driver and
metrics-server addons, and the monitoring stack (VictoriaMetrics + Grafana).

The stack also ships a test suite, which is worth running before a first apply
and after any change to the Terraform:

```bash
terraform test                     # 63 tests, ~70s
cd bootstrap && terraform test     # 16 tests, ~2s
```

It needs no AWS credentials and touches nothing — every provider is mocked, so
a run never reaches an API, never reads or writes the S3 state, and never sees
the cluster. Details, including what the tests can and cannot see, are in
[`infra/aws/README.md`](infra/aws/README.md#tests) and
[`infra/aws/bootstrap/README.md`](infra/aws/bootstrap/README.md#tests).

### 6. Create the infrastructure

```bash
terraform apply tfplan
```

The operation may take several minutes. Terraform applies AWS resources and
Kubernetes/Helm providers that depend on the newly created cluster in a single
run.

When done, save these outputs:

```bash
terraform output ecr_repository_url
terraform output -raw instructions
```

The value of `ecr_repository_url` must match `image.repository` in
`deploy/helm/counter-api/values.yaml`. ECR uses immutable tags: each deployment
must have a unique tag, typically the commit SHA.

### 7. Configure `kubectl`

```bash
aws eks update-kubeconfig \
  --region eu-west-1 \
  --name chamo-dev-cluster \
  --profile chamo-dev-eks

kubectl auth whoami
kubectl auth can-i --list
kubectl get nodes
```

If `kubectl` authenticates but returns `forbidden`, usually the permission set is
not included in `sso_access_permission_sets` or was not assigned to the account.
Fix it and re-run `terraform apply`.

### 8. Publish the first image to ECR

The infrastructure creates the repository, but not an image. Before expecting
the Deployment to be healthy, you must publish an image.

The recommended way is to run the `Deploy` workflow from GitHub. To do it
manually:

```bash
export AWS_REGION=eu-west-1
export ECR_REPOSITORY=go-counter-href-10-sites
export IMAGE_TAG=$(git rev-parse HEAD)
export ECR_URL=$(terraform -chdir=infra/aws output -raw ecr_repository_url)
export ECR_REGISTRY=${ECR_URL%%/*}

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker build -t "$ECR_REPOSITORY:$IMAGE_TAG" \
  -f apps/counter-api/Dockerfile apps/counter-api
docker tag "$ECR_REPOSITORY:$IMAGE_TAG" "$ECR_URL:$IMAGE_TAG"
docker push "$ECR_URL:$IMAGE_TAG"
```

Then, update `image.tag` in `deploy/helm/counter-api/values.yaml` with the same
SHA and push to `main`. Argo CD will detect the commit and synchronize the
chart.

### 9. Verify Argo CD, kgateway, and the application

```bash
kubectl get applications -n argocd
kubectl get pods -n argocd
kubectl get pods -n counter-api
kubectl get gateway -A
kubectl get httproute -A
kubectl get svc -A
```

The `Application` has automatic synchronization with `prune`, `selfHeal`, and
`CreateNamespace=true`. If `ImagePullBackOff` appears, check that the tag exists
in ECR and that `image.repository` points to the correct account and region.

### 10. Get the public URL

```bash
kubectl get gateway public-nlb-gateway -n counter-api \
  -o jsonpath='{.status.addresses[0].value}{"\n"}'
```

Create a DNS `CNAME` record pointing to the NLB hostname and matching
`httpRoute.hostnames`. For local testing, you can use a temporary hostname in
`/etc/hosts`, though a CNAME is preferable because an NLB can change IPs.

Test the application:

```bash
curl -i https://counter-api.example.com/healthcheck
curl -i https://counter-api.example.com/v1/tags
```

HTTPS terminates TLS at the NLB using ACM; inside the cluster, the Gateway
listener receives plain HTTP. The ACM ARN must be in the same region.

### 11. Access Argo CD

By default, you can use port-forward:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Open `http://localhost:8080`, user `admin`. If `enable_argocd_route=true`, use
`argocd_hostname` and check the Gateway/NLB:

```bash
kubectl get httproute -n argocd
kubectl get gateway -n argocd
```

Argo CD is configured in `insecure` mode: TLS must terminate at the NLB, not at
the pod.

### 12. Access Grafana

```bash
terraform -chdir=infra/aws output -raw instructions   # "Monitoring" section

# NLB hostname of the Grafana Gateway; point grafana_hostname at it (CNAME)
kubectl -n monitoring get svc grafana-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'

# admin password
kubectl -n monitoring get secret victoria-metrics-k8s-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Open `http://<grafana_hostname>` with user `admin`. Without DNS, use
`kubectl -n monitoring port-forward svc/victoria-metrics-k8s-stack-grafana 3000:80`
and open `http://localhost:3000`. See [Monitoring](#monitoring) for details.

## Monitoring

Terraform ([`infra/aws/11-monitoring.tf`](infra/aws/11-monitoring.tf)) installs
[victoria-metrics-k8s-stack](https://docs.victoriametrics.com/helm/victoria-metrics-k8s-stack/)
as an Argo CD `Application` in the `monitoring` namespace.

| Component | Role |
|---|---|
| VictoriaMetrics operator | Turns `VMServiceScrape`/`VMNodeScrape` objects into scrape config |
| vmagent | Scrapes kubelet/cAdvisor, node-exporter, kube-state-metrics, CoreDNS, the API server, and `counter-api` |
| VMSingle | Stores samples on an encrypted EBS gp3 volume (`monitoring_retention`, `monitoring_storage_size`) |
| Grafana | Dashboards, 5Gi gp3 volume, published through its own Gateway/NLB (plain HTTP) |

Alertmanager and vmalert are disabled because no notification receivers are
configured yet; the alerting rules are still created. Controller-manager,
scheduler, and etcd are not scraped: EKS does not expose them.

Two prerequisites are part of the same Terraform:

- **EBS CSI driver addon** plus a default `gp3` StorageClass. Without EKS Auto
  Mode nothing else can provision the persistent volumes.
- **metrics-server addon**, needed by every HorizontalPodAutoscaler — including
  the one KEDA generates, whose CPU trigger reads from it.

### Application metrics

`counter-api` exposes these series on `:9090/metrics`, together with the Go
runtime and process collectors:

| Metric | Type | Labels |
|---|---|---|
| `counter_api_http_requests_total` | counter | `method`, `route`, `status` |
| `counter_api_http_request_duration_seconds` | histogram (50µs–1s) | `method`, `route` |
| `counter_api_refreshes_total` | counter | `result` (`completed`, `skipped`) |
| `counter_api_refresh_duration_seconds` | histogram | – |
| `counter_api_last_refresh_timestamp_seconds` | gauge | – |
| `counter_api_url_link_words` | gauge | `url` |
| `counter_api_url_fetch_duration_seconds` | gauge | `url` |

`route` is the Gin route template (`/v1/tags/:url_id`), not the raw path, so
the number of series stays bounded.

The chart creates a `VMServiceScrape` for the `metrics` Service port. It is only
rendered when the `operator.victoriametrics.com` CRDs exist, so the application
still syncs on a cluster without the monitoring stack. Toggle it with
`metrics.enabled` and `metrics.serviceScrape.enabled` in `values.yaml`.

### Dashboards

- **counter-api**
  ([`deploy/monitoring/dashboards/counter-api.json`](deploy/monitoring/dashboards/counter-api.json)):
  request rate, 5xx ratio, latency percentiles per route, refresh health, link
  words and fetch time per URL, and CPU/memory/goroutines per pod. Terraform
  ships it as a ConfigMap that the Grafana sidecar loads.
- The default Kubernetes dashboards that come with the chart (nodes, pods,
  workloads, API server, CoreDNS).

Check scrape targets directly in vmagent:

```bash
kubectl -n monitoring port-forward svc/vmagent-victoria-metrics-k8s-stack 8429
# open http://localhost:8429/targets
```

## Autoscaling and zero-downtime rollouts

The Helm chart configures both the application and the kgateway proxy that
fronts it:

| | `counter-api` | Gateway proxy (Envoy) |
|---|---|---|
| Autoscaling | KEDA 3–24 pods, on request rate + CPU | HPA 2–6 replicas, 50% CPU (created by kgateway from `GatewayParameters`) |
| Disruption budget | `maxUnavailable: 25%` | `minAvailable: 1` |
| Shutdown | `preStop` sleep 10s, then graceful HTTP shutdown | Envoy graceful drain 10s |
| Placement | Anywhere | Karpenter nodes only, spread across nodes |

- The Deployment uses `maxUnavailable: 0`, so new pods are Ready before old
  ones are removed.
- The `preStop` sleep keeps a terminating pod serving until the proxy has
  stopped routing to it; without it, every rollout produced 503s.
- The Deployment renders no `spec.replicas` while autoscaling is on. The Argo CD
  `Application` ignores `/spec/replicas` (`RespectIgnoreDifferences=true`), so a
  sync never resets the replica count chosen by the HPA.
- The proxy runs on Karpenter capacity because the managed system nodes are
  burstable `t3.medium`. Karpenter itself is limited to the `c`, `m`, and `r`
  families for the same reason.
- A kgateway `BackendConfigPolicy` closes idle proxy → app connections after
  30s, before the app's own 60s `IdleTimeout`. Otherwise Envoy can send a
  request on a connection the app is closing, and the request returns a 503.
- A kgateway `TrafficPolicy` retries once on `reset` or `connect-failure`. Every
  route is a `GET`, so the retry is safe.

### KEDA on the application

KEDA does **not** replace the HorizontalPodAutoscaler. A `ScaledObject` creates
one — `keda-hpa-counter-api` — and KEDA registers itself as the external metrics
API server that feeds it. What changes is the input.

The reason is in the numbers from the load test below: at 5000 rps the pods used
~0.1 core each against a 100m request, so CPU sits near 100% of request across
most of the useful range. It is a flat, late signal. `counter_api_http_requests_total`
is the direct one.

The `ScaledObject` carries two triggers:

| Trigger | Target | Source |
|---|---|---|
| `prometheus` | 210 rps per pod | `sum(rate(counter_api_http_requests_total[2m]))` against VMSingle |
| `cpu` | 70% of request | metrics-server, same as before |

- The HPA takes the **highest** replica count the two ask for, which is what
  makes CPU a safety net rather than a second opinion. If VictoriaMetrics stops
  answering, the request-rate metric goes unavailable and the HPA keeps scaling
  up on CPU alone — and refuses to scale *down* while a metric is missing.
- The 210 comes from the load test: 5000 rps across 24 pods is ~208 each, so
  that peak lands exactly on `maxReplicas` instead of permanently asking for one
  pod more than the ceiling allows.
- The query window is `[2m]` over a 30s scrape interval — four samples, so the
  rate survives one missed scrape. At `[1m]` it is two, and a single miss leaves
  the query with nothing to report.
- The `behavior` block (instant scale-up, 25%-per-minute scale-down over a 5
  minute window) is shared: KEDA passes it straight through to the HPA it
  generates, so flipping `autoscaling.keda.enabled` does not silently change how
  the app reacts.
- `templates/hpa.yaml` renders **only** when `autoscaling.keda.enabled` is
  `false`. Two HPAs on one Deployment overwrite each other's decisions every
  sync interval, so the chart makes them mutually exclusive.
- The gateway proxy keeps its own CPU HPA: kgateway creates it from
  `GatewayParameters`, and taking it over would mean fighting the controller for
  `spec.replicas`.

Controller install and its variables (`enable_keda`, `keda_chart_version`,
`keda_sync_wait`) are in [`infra/aws/12-keda.tf`](infra/aws/12-keda.tf).

**Rollout order matters.** The chart renders its `ScaledObject` only once
`keda.sh/v1alpha1` is a registered API, and with `autoscaling.keda.enabled` it
renders no plain HPA either. On a running cluster, `terraform apply` the KEDA
install *before* the chart change reaches `main` — otherwise Argo CD prunes the
old HPA, renders nothing in its place, and the Deployment sits with no
autoscaler until the next reconcile. On a cold apply the `depends_on` in
`05-app-deployment.tf` enforces the order for you.

All of this is configurable under `rollout`, `podDisruptionBudget`,
`autoscaling`, `gatewayParameters.proxy`, and `gatewayPolicies` in
[`values.yaml`](deploy/helm/counter-api/values.yaml).

## Automatic deployment with GitHub Actions

There are exactly two workflows, one per half of the system:

| Workflow | Deploys | Runs on |
|---|---|---|
| [`deploy.yml`](.github/workflows/deploy.yml) | The code | Push to `main` (except Markdown-only and `docs/`), or manual dispatch |
| [`terraform-aws.yml`](.github/workflows/terraform-aws.yml) | The infrastructure | PR and push to `main` for checks; `apply`/`destroy` by manual dispatch only |

`deploy.yml` registers the deployment in Port, obtains AWS credentials, builds
`apps/counter-api/Dockerfile`, publishes the image to ECR tagged with the commit
sha, bumps `image.tag` in the Helm values, and pushes. Argo CD detects that
commit and synchronizes the Deployment. It never talks to the cluster itself.
`terraform-aws.yml` is documented in
[`infra/aws/README.md`](infra/aws/README.md#continuous-deployment).

### Dispatching a deploy by hand

Three optional inputs, all aimed at one situation: `terraform destroy` brings
the ECR repository back **empty**, because `force_delete = true` in
[`07-ecr.tf`](infra/aws/07-ecr.tf) takes the images with it. The cluster then
asks for a tag that no longer resolves and the pods sit in `ImagePullBackOff`.

| Input | Default | What it does |
|---|---|---|
| `ref` | the dispatch branch | Commit, branch or tag to build |
| `image_tag` | sha of the built commit | Tag to publish |
| `update_gitops` | `true` | Whether to bump `image.tag`, i.e. whether to actually deploy it |

Dispatching with `ref` set to the commit the running Deployment references
republishes exactly the tag it is asking for, with no git commit needed. Setting
`update_gitops: false` republishes an image without moving what the cluster runs.

The repository is `IMMUTABLE`, so the workflow checks whether the tag is already
published and skips the build if it is — which makes re-running a finished run
an idempotent redeploy instead of a failed push after a full build.

Configure in GitHub:

- Secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` with permissions to
  log in and push to ECR.
- Secrets `PORT_CLIENT_ID` and `PORT_CLIENT_SECRET`, because the workflow
  updates the deployment in Port.
- Write permissions for `GITHUB_TOKEN`, needed for the commit that updates the
  Helm values.
- The GitHub repository name must match the ECR repository expected by
  `ECR_REPOSITORY`, or that variable must be updated in the workflow.

No `imagePullSecret` is used: the IAM roles of managed nodes and nodes created
by Karpenter have read permissions in ECR.

## Local Docker

```bash
docker build -t counter-api -f apps/counter-api/Dockerfile apps/counter-api
docker run --rm -p 8080:80 counter-api
curl http://localhost:8080/healthcheck
```

## Load test

The [`apps/counter-api/loadtest`](apps/counter-api/loadtest) folder includes:

- `loadgen`: a dependency-free, open-model (constant arrival rate) generator.
- k6 and Vegeta scripts.
- A deterministic stub origin and hot-path benchmarks for local runs.
- `k8s/`: a Job that runs `loadgen` inside EKS.

Its [README](apps/counter-api/loadtest/README.md) covers local runs.

### Run it inside EKS

Run load against the environment from inside AWS. From a home connection, the
uplink saturates first: in this project, it capped a laptop at ~2,300 rps with a
420 ms p50, while the cluster was almost idle.

```bash
apps/counter-api/loadtest/k8s/run.sh
```

The script:

1. Creates the `loadtest` namespace.
2. Mounts `loadgen/main.go` as a ConfigMap, so no image has to be built.
3. Starts a Job that compiles it and attacks the public URL in steps.
4. Streams the report.

The pod requests 3 CPUs, only runs on Karpenter nodes, and never shares a node
with the application or the gateway, so it does not steal CPU from what it
measures.

| Variable | Default | Description |
|---|---|---|
| `TARGET_URL` | `http://counter-api.alvarolinarescabre.com` | Base URL; `http://counter-api.counter-api.svc` skips the NLB and gateway |
| `STEPS` | `1000 2500 5000` | Requests per second for each step |
| `STEP_DURATION` | `2m` | Duration of each step |
| `WORKERS` | `1024` | Maximum in-flight requests |

```bash
STEPS="5000 10000 20000" STEP_DURATION=3m apps/counter-api/loadtest/k8s/run.sh
```

For each step, the report shows scheduled vs. completed requests, `dropped`,
the count of errors and each status code, and latency percentiles:

- `dropped` means the generator could not keep up with the schedule: the target
  was too slow, or there were too few workers.
- `loadgen` exits non-zero if anything was dropped or returned non-200.

Watch the **counter-api** Grafana dashboard during the run. Server-side latency
and pod/proxy CPU there tell you whether latency comes from the app, the
gateway, or the network.

Clean up afterwards; Karpenter then removes the empty node:

```bash
kubectl delete namespace loadtest
```

### Reference results

All results below come from the same test: `/v1/tags` plus 10% `/v1/tags/{id}`,
1000 → 2500 → 5000 rps, 2 minutes per step.

| Setup | 5000 rps achieved | Errors | p50 | p95 | p99 |
|---|---|---|---|---|---|
| From a laptop | 2,297 rps | 226 × 503 | 428 ms | 494 ms | 595 ms |
| In EKS, 12 fixed pods, 1 proxy | 5000 | 93 × 503 (rollout during the step) | 1.6 ms | 2.6 ms | 9.7 ms |
| In EKS, HPAs + zero-downtime rollouts | 5000 | 0 | 1.9 ms | 12.7 ms | 72.6 ms |
| In EKS, proxy on Karpenter nodes, no `t` instances | 5000 | 39 × 503 (keep-alive race) | 1.4 ms | 3.2 ms | 94.8 ms |

- **Application:** server-side latency (from the app's own histogram) stayed at
  p50 ≈ 25 µs and p99 ≈ 75 µs, using about 0.1 CPU per pod at 5000 rps.
- **Gateway:** the Envoy proxy is the busiest component, at ~0.85 CPU per 5000
  rps.
- **Third run:** its tail latency came from proxy replicas scheduled on the
  burstable system nodes, which is why the proxy is now pinned to Karpenter
  capacity.
- **Fourth run:** at 1000 and 2500 rps, p99 dropped to 5.5 ms and 4.1 ms. At
  5000 rps, p95 improved, but the p99 tail came from the proxy scaling out
  2 → 5 in the middle of the step. The 39 errors were Envoy reusing keep-alive
  connections the app had just closed for being idle
  (`upstream_cx_destroy_remote_with_active_rq`). The upstream idle timeout and
  retry policies described below were added as a result.

## Change application configuration

Edit [`deploy/helm/counter-api/values.yaml`](deploy/helm/counter-api/values.yaml)
to change autoscaling limits, resources, rollout settings, hostname, listeners,
or certificate. `replicaCount` is only used when `autoscaling.enabled` is
`false`. Validate the chart before pushing:

```bash
helm lint deploy/helm/counter-api
helm template counter-api deploy/helm/counter-api
```

Argo CD will apply the change once it reaches `main`. Code changes must generate
a new image with a new tag, because ECR is configured with immutable tags.

## Destroy the environment

Before destroying, confirm you want to remove the VPC, EKS, NLB, ECR, IAM, and
other resources:

```bash
cd infra/aws
terraform plan -destroy
terraform destroy
```

It takes roughly three minutes longer than the plan suggests, deliberately.

None of the three NLBs belong to Terraform: each is created by the AWS Load
Balancer Controller from inside the cluster, in response to a `Service` that
kgateway provisions for a `Gateway`. Terraform can only delete the `Gateway`
(or the Argo CD `Application` that owns it) and let the controller do the rest,
which is asynchronous. Two things keep that honest:

- the Argo CD `Application`s carry `resources-finalizer.argocd.argoproj.io`, so
  deleting one cascades to the namespace, Gateway, Service and PVCs it deployed
  instead of leaving them behind; and
- a teardown barrier (`var.load_balancer_teardown_wait`, default `180s`) holds
  the controller — and therefore the cluster — alive after the last Gateway is
  deleted, long enough for the NLBs to actually go.

Without those, the NLBs are orphaned mid-deletion, their ENIs keep holding the
private subnets, and the VPC destroy fails with `DependencyViolation`. The full
explanation, the resulting order, and what to do if a destroy still leaves
something behind or hangs on an `Application`, are in
[`infra/aws/README.md`](infra/aws/README.md#destroy).

Two things this does **not** remove:

- **The remote Terraform bucket** and its versions are not part of this stack.
  Delete it separately, and only if you no longer need the state history.
- **Anything orphaned by an earlier destroy.** The cascade only applies to
  Applications created with the finalizer, so run one `terraform apply` first if
  the stack predates it. Leftover NLBs, EBS volumes and namespaces stuck in
  `Terminating` have to be cleaned up by hand:

  ```bash
  aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='<vpc-id>'].[LoadBalancerName,DNSName]" --output table
  aws ec2 describe-volumes --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table
  ```

When the cascade does run, the VictoriaMetrics and Grafana volumes go with it —
their PVCs use `reclaimPolicy: Delete`, so the EBS CSI driver deletes them,
along with all stored metrics.

## Troubleshooting

**The EKS endpoint is no longer accessible.** The public API is restricted to the
IP detected during `terraform apply`. Changing networks requires re-running
`terraform apply` to update the rule.

**Pods are in `ImagePullBackOff`.** Check `image.repository`, `image.tag`, that
the image exists in ECR, and that the node has read permissions.

**The Gateway has no external address.** Check the Gateway, pods, and events:

```bash
kubectl get gateway -A
kubectl describe gateway public-nlb-gateway -n counter-api
kubectl -n kube-system get pods
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller
```

**The route returns 404 or does not route by hostname.** The `Host` header must
match `httpRoute.hostnames`; check that `HTTPRoute` is `Accepted=True` and
`ResolvedRefs=True`.

**Argo CD is not synchronizing.** Check the status and events:

```bash
kubectl get application -n argocd
kubectl describe application go-counter-href-10-sites -n argocd
```

**A Grafana dashboard shows "No Data".** Check that the target is `up` in vmagent
(`http://localhost:8429/targets`, see [Monitoring](#monitoring)) and that the
`VMServiceScrape` exists (`kubectl -n counter-api get vmservicescrape`). Changes
under `apps/` and `deploy/helm/` only reach the cluster after they are pushed to
`main`, CI has built the image, and Argo CD has synced.

**An HPA shows `cpu: <unknown>`.** metrics-server is missing or not ready, or
the target pods have no CPU request. Check `kubectl top pods -n counter-api`.

**The Deployment has no autoscaler at all.** Usually the rollout order above:
the chart change reached `main` before KEDA was installed, so Argo CD pruned the
old HPA and rendered nothing in its place. Check that the API exists and that
the object was created:

```bash
kubectl get scaledobject -n counter-api
kubectl get hpa -n counter-api            # expect keda-hpa-counter-api
kubectl get pods -n keda
```

**The `ScaledObject` shows `READY: False`.** KEDA cannot reach VictoriaMetrics
or the query returns nothing. The operator log names the failing trigger:

```bash
kubectl -n keda logs deploy/keda-operator | grep -i scaler
# verify the query by hand:
kubectl -n monitoring port-forward svc/vmsingle-victoria-metrics-k8s-stack 8428 &
curl -sG http://127.0.0.1:8428/prometheus/api/v1/query \
  --data-urlencode 'query=sum(rate(counter_api_http_requests_total[2m]))'
```

The CPU trigger keeps scaling the app up while this is broken, so it degrades
rather than fails.

**Argo CD fails with `.status.terminatingReplicas: field not declared in
schema`.** The Argo CD version is older than the cluster's Kubernetes version.
Raise `argocd_chart_version` (Argo CD 3.x for Kubernetes ≥ 1.33).

**Terraform cannot find the SSO role.** First assign the permission set to the
AWS account and verify that the `AWSReservedSSO_*` role exists; then re-run
`terraform plan`.

## License

This project is licensed under MIT.
