# CI credentials bootstrap

Terraform for the two IAM users the GitHub Actions workflow authenticates as,
and the policies they carry. Previously these were `aws iam create-user` /
`attach-user-policy` commands in a README; this is the same thing as code.

## Why this is a separate Terraform root

These users **are** the credentials the main stack in `../` runs with. Managing
them from inside it would mean:

- an apply can revoke the permissions of the very run performing it — a plan
  that removes a statement the run still needs leaves you locked out mid-apply,
  with the state half-written; and
- the first apply could never happen. The users have to exist before anything
  can authenticate to create them.

So this root runs **once, by a human with administrator credentials**, and keeps
**local state** — it cannot depend on the S3 backend, because access to that
backend is one of the things it grants. `terraform.tfstate` here is covered by
the repo's `*.tfstate` ignore.

Losing that state file does not lose the users; re-adopting them just needs the
import commands below.

## Usage

```bash
cd infra/aws/bootstrap
terraform init
terraform apply
```

### Adopting users that already exist

If you created the users by hand from the old setup docs, import them first —
otherwise the apply fails with `EntityAlreadyExists`:

```bash
terraform import 'aws_iam_user.ci["plan"]'  gha-counter-api-terraform-plan
terraform import 'aws_iam_user.ci["apply"]' gha-counter-api-terraform-apply
terraform plan   # should now show only the policies being created
```

Terraform only manages the attachments it declares, so any policy you attached
by hand — `AdministratorAccess`, most likely — stays attached and keeps
overriding the scoping here. Detach it once the apply succeeds:

```bash
aws iam list-attached-user-policies --user-name gha-counter-api-terraform-apply
aws iam detach-user-policy --user-name gha-counter-api-terraform-apply \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

### Access keys

Off by default (`var.create_access_keys`). Terraform stores the secret key in
state in plain text, and this root's state is local — so turning it on puts both
CI secrets on whoever's laptop ran the apply.

- **Default (off):** `aws iam create-access-key --user-name <user>` for each,
  and the secret never touches a state file.
- **On:** `terraform output -json ci_access_keys`, copy into the GitHub secrets,
  then treat `terraform.tfstate` as a credential — or `terraform state rm
  'aws_iam_access_key.ci["plan"]'` (and `["apply"]`) once GitHub has them.

## Tests

```bash
cd infra/aws/bootstrap
terraform test
```

16 tests in [`tests/`](tests), split in two: `ci_users.tftest.hcl` covers the
users, their attachments and the access keys; `iam_policies.tftest.hcl` covers
the two policy documents. A run takes about two seconds and **needs no AWS
credentials**.

The provider is real but configured offline — dummy keys and every validation,
metadata and region check switched off — with only the two data sources that do
call AWS (`aws_caller_identity`, `aws_partition`) replaced by `override_data`.
That matters: `aws_iam_policy_document` is rendered locally by the provider, so
the tests assert against the **real** JSON rather than a mock, and every `run`
uses `command = plan`, so nothing is ever created.

What they pin down is the part of this root that is easy to widen by accident:

- The privilege split — the `plan` user never gets the write policy, whatever
  the users are renamed to.
- The scoping of `iam:*Role*`/`iam:*Policy*` to `<project>-<env>-*`, and that
  it is never granted on `*`.
- Both `Deny` statements: self-escalation (users, access keys, login profiles,
  groups) and any in-place edit of this root's own two policies.
- That `CreateServiceLinkedRole` on `*` keeps its `iam:AWSServiceName`
  condition, and that `spot.amazonaws.com` stays in the list — without it
  Karpenter cannot launch spot capacity.
- That the state grant includes `s3:PutObject`/`s3:DeleteObject`, since
  `use_lockfile = true` makes even a plan write the `.tflock` object.
- That nothing hardcodes the `aws` partition.
- The prefix contract with `../`: changing `project_name`/`environment` has to
  move the policy names *and* the IAM scoping together, or the apply user
  silently loses access to the resources it is meant to manage.

The main stack has its own, larger suite — see
[`../README.md`](../README.md#tests).

## What each user gets

| User | Policies | Used by |
|---|---|---|
| `…-terraform-plan` | `ReadOnlyAccess`, `<project>-<env>-terraform-shared` | The automatic `plan-on-main` job (repo-level secrets) |
| `…-terraform-apply` | `ReadOnlyAccess`, `…-terraform-shared`, `…-terraform-apply` | The manual `dispatch` job (`aws-eks` environment secrets) |

Both are read from the secrets `TF_AWS_ACCESS_KEY_ID` / `TF_AWS_SECRET_ACCESS_KEY` in
[`.github/workflows/terraform-aws.yml`](../../../.github/workflows/terraform-aws.yml).
The same two names at both levels is the whole mechanism: GitHub resolves an
environment's secrets first for a job bound to it, so the privilege split needs
no logic in the workflow. The `TF_` prefix keeps them clear of the plain
`AWS_*` secrets that `deploy.yml` uses to push to ECR.

**`…-terraform-shared`** — S3 state access and `iam:ListRoles`. Two things in it
are easy to get wrong:

- The state grant is **not** read-only even for the plan user.
  `use_lockfile = true` in `../providers.tf` means a plan writes and deletes
  `terraform.tfstate.tflock`; without `s3:PutObject`/`s3:DeleteObject` every
  plan fails to acquire its lock.
- `iam:ListRoles` is needed by **both** users, not just the apply one.
  `../10-cluster-access.tf` resolves the `AWSReservedSSO_*` roles that IAM
  Identity Center has provisioned in the account, and that lookup happens at
  *plan* time — so a read-only plan job fails just as hard without it.

**`ReadOnlyAccess`** — AWS's own managed policy rather than a hand-written
`Describe*`/`List*`/`Get*` list. A plan touches every service in the stack and a
missing read action doesn't degrade, it fails the run; AWS extends this policy
as services grow, where a hand-rolled equivalent silently rots.

**`…-terraform-apply`** — the write side. Service-level `ec2:*`, `eks:*`,
`elasticloadbalancing:*`, `autoscaling:*`, `ecr:*`, `sqs:*`, `events:*`,
`kms:*`, `logs:*` on `*`, because Terraform needs the delete half of all of them
for `destroy` to work at all. **This is broad** — tightening it to resource ARNs
is the next step and needs the ARNs of a cluster that already exists.

IAM is the exception: it's scoped by name to `<project>-<env>-*` roles, policies
and instance profiles, plus a conditioned `CreateServiceLinkedRole` (Karpenter's
spot instances need `AWSServiceRoleForEC2Spot`) and the cluster's OIDC provider.
Two explicit `Deny` statements stop the apply user from turning its own IAM
grants on the users and policies that define what it may do — without them the
scoping would be decorative, since it could simply widen itself.
