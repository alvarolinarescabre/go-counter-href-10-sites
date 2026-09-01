# Counter API

A Go service that counts words inside HTML links with absolute HTTP(S) hrefs.
It uses Gin for HTTP routing and Swaggo for an interactive OpenAPI UI.

## Monorepo Layout

- `apps/counter-api/` - Go/Gin application, tests, generated Swagger docs, and Dockerfile
- `deploy/helm/counter-api/` - Helm chart for Kubernetes
- `deploy/argocd/` - ArgoCD AppProject/Application for `counter-api`, plus the kgateway
  bootstrap manifests (Gateway API CRDs, kgateway CRDs/controller, `GatewayParameters`)
- `infra/aws/` - Terraform that provisions the EKS cluster and bootstraps Argo CD; see
  [infra/aws/README.md](infra/aws/README.md)
- `.github/workflows/` - tests and image publishing to GHCR (`docker-publish.yml`), GitOps
  promotion (same workflow), and the Terraform AWS deployment pipeline
  (`terraform-aws.yml`)

## Local Development

Requires Go 1.24 or newer.

```bash
cd apps/counter-api
go mod download
go run .
```

The server listens on `http://localhost:8080` by default. Configure it with:

- `PORT`: HTTP port, default `8080`
- `TARGET_URLS`: comma-separated URLs, default is the ten configured sites
- `HTTP_TIMEOUT_SECONDS`: HTTP request timeout, default `10`

Run tests with:

```bash
cd apps/counter-api
go test ./...
```

## API

- `GET /` - API navigation
- `GET /healthcheck` - health check
- `GET /v1/tags` - count links for all configured URLs
- `GET /v1/tags/{url_id}` - count links for one configured URL
- `GET /v1/cache/clear` - clear cache response compatibility endpoint
- `GET /docs` - redirects directly to the interactive Swagger UI
- `GET /swagger/index.html` - interactive Swagger UI

## kgateway Gateway and HTTPRoute

The Helm chart deploys a `Gateway` and an `HTTPRoute` by default. The Gateway
uses the `kgateway` GatewayClass and listens on HTTP port 80. The HTTPRoute
routes `counter-api.chamo.local/*` to the application Service. Configure the
hostname and Gateway reference in `deploy/helm/counter-api/values.yaml` before
deploying:

```yaml
httpRoute:
  enabled: true
  gateway:
    name: kgateway
    sectionName: http
  hostnames:
    - api.example.com
```

The Gateway API CRDs and the `kgateway` GatewayClass must already exist in the
cluster. kgateway provisions an external address for the Gateway; create a DNS
`A` or `CNAME` record for the configured hostname pointing to that address.
ArgoCD applies the Gateway and HTTPRoute together with the Helm release.

Swagger is generated from annotations in `apps/counter-api/main.go`:

```bash
cd apps/counter-api
go run github.com/swaggo/swag/cmd/swag@v1.16.4 init -g main.go -o docs
```

## Docker

```bash
docker build -t counter-api -f apps/counter-api/Dockerfile apps/counter-api
docker run --rm -p 8080:80 counter-api
curl http://localhost:8080/healthcheck
```

## Kubernetes and ArgoCD

Apply the ArgoCD AppProject and Application:

```bash
kubectl apply -f deploy/argocd/app-project.yaml
kubectl apply -f deploy/argocd/application.yaml
```

A push to `main` runs `go test ./...`, builds and publishes
`ghcr.io/alvarolinarescabre/go-counter-href-10-sites`, and commits the
immutable `sha-<commit>` tag to the Helm values file. ArgoCD detects that Git
change and synchronizes the chart. Configure an `imagePullSecret` in the
`counter-api` namespace if the GHCR package is private.

## Infrastructure (EKS + ArgoCD bootstrap)

`infra/aws/` contains the Terraform that provisions the AWS EKS cluster this app
runs on and bootstraps it end to end: VPC, EKS, an Argo CD `helm_release`, the
Gateway API CRDs, kgateway (as the Gateway API implementation, exposed via an AWS
NLB), and the `AppProject`/`Application` from `deploy/argocd/` that point Argo CD
back at `deploy/helm/counter-api` in this same repo. See
[infra/aws/README.md](infra/aws/README.md) for architecture, prerequisites, and
deployment steps.

`.github/workflows/terraform-aws.yml` validates that Terraform on every PR
(`fmt`/`validate`, no AWS access needed), runs a read-only `plan` automatically
on every push to `main`, and — on a manual `workflow_dispatch` gated by the
`aws-eks` GitHub Environment — plans/applies/destroys it against the real AWS
account using a static AWS access key stored as a GitHub secret. The S3 state
backend (bucket/key/region, native locking) is pinned as literal values in
[infra/aws/providers.tf](infra/aws/providers.tf), not driven by GitHub
variables — see that file's comment for why. See
[infra/aws/README.md#continuous-deployment](infra/aws/README.md#continuous-deployment)
for the one-time setup (IAM user(s)/access key(s), state bucket, repo
secrets/variables).

### What you need to set up in AWS/GitHub before this runs

Until these exist, `plan-on-main` skips itself with a job-summary notice instead
of failing, and the manual `workflow_dispatch` will error on `configure-aws-credentials`.
Full commands and rationale in
[infra/aws/README.md#continuous-deployment](infra/aws/README.md#continuous-deployment).

1. **Remote state**: the S3 bucket named in
   [infra/aws/providers.tf](infra/aws/providers.tf)'s backend block (versioned,
   encrypted). No DynamoDB table — state locking is native to the S3 backend
   (`use_lockfile`).
2. **IAM user(s) + access key(s)**: one read-only user for the automatic
   `plan-on-main` job, and one read/write user for the manual apply/destroy job
   (or a single read/write user for both, if you'd rather skip the split).
3. **GitHub Environment** `aws-eks` (Settings → Environments) with required
   reviewers, so a human approves every `apply`/`destroy`.
4. **GitHub secrets**:
   - Repo-level `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — the read-only
     user's key.
   - `aws-eks` environment-level `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
     (same names) — the read/write user's key; overrides the repo-level ones
     only for the manual job.
5. **GitHub variable** (optional): `AWS_REGION` — defaults to `eu-west-1`.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
