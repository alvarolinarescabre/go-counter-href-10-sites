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
- GitHub Actions to build the image, publish it to ECR, and update the tag
  that Argo CD synchronizes.

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
                         Deployment + Service + Gateway + HTTPRoute
                                      |
                                      v
                              AWS NLB -> counter-api
```

Terraform is used to create the platform and hand control to Argo CD.
After `terraform apply`, Terraform does not directly manage application objects:
Argo CD's `Application` observes `deploy/helm/counter-api` on the `main` branch
and applies its changes automatically.

## Repository structure

```text
apps/counter-api/              Go code, tests, Swagger, and Dockerfile
deploy/helm/counter-api/       Helm chart for the application
deploy/argocd/                 Application, AppProject, and kgateway
infra/aws/                     Terraform for AWS/EKS
infra/aws/bootstrap/           Initial IAM for GitHub Actions
.github/workflows/deploy.yml   Build, push to ECR, and GitOps promotion
```

## Requirements

To run the application locally:

- Go 1.24 or newer.
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
Controller, Argo CD, Gateway API, kgateway, and ECR.

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

## Automatic deployment with GitHub Actions

The workflow [`deploy.yml`](.github/workflows/deploy.yml) runs on push to `main`
except for changes affecting only Markdown or `docs/`, and also supports
`workflow_dispatch`.

The workflow registers the deployment in Port, obtains AWS credentials, builds
`apps/counter-api/Dockerfile`, publishes the image to ECR with tag `${GITHUB_SHA}`,
updates `image.tag`, and pushes the change. Argo CD detects that commit and
synchronizes the Deployment.

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

The [`apps/counter-api/loadtest`](apps/counter-api/loadtest) folder includes k6
scenarios, Vegeta, a deterministic origin, and hot-path benchmarks. Consult its
README before running load against a public environment.

## Change application configuration

Edit [`deploy/helm/counter-api/values.yaml`](deploy/helm/counter-api/values.yaml)
to change replicas, resources, hostname, listeners, or certificate. Validate the
chart before pushing:

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

The remote Terraform bucket and its versions are not part of this stack and
should be deleted separately only if you no longer need the state history.

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

**Terraform cannot find the SSO role.** First assign the permission set to the
AWS account and verify that the `AWSReservedSSO_*` role exists; then re-run
`terraform plan`.

## License

This project is licensed under MIT.
