# AWS OpenTofu Conversion — Design Spec

- **Date:** 2026-07-16
- **Ticket:** GS-334
- **Packages affected:** `genericsuite-fe-scripts`, `genericsuite-be-scripts`, `genericsuite-basecamp`
- **Status:** Approved by Carlos J. Ramirez (2026-07-16)

## 1. Goal

Provide an OpenTofu (Terraform-compatible) implementation of every AWS deployment currently done with CloudFormation templates and raw AWS CLI calls, so the DevOps, security, and infrastructure teams share a single IaC toolchain. The existing CloudFormation/CLI scripts are **not** removed or modified; OpenTofu is a parallel, opt-in path. Resource names match the current conventions so both worlds can coexist in the same AWS account.

## 2. Current deployments reviewed

| Script / template | What it deploys | OpenTofu replacement |
|---|---|---|
| `fe-scripts/scripts/aws_deploy_to_s3.sh` | FE S3 bucket, CloudFront + OAI, ACM lookup, bucket policy, build+sync+invalidation | `frontend-hosting` module + `aws_tf_deploy_to_s3.sh` wrapper |
| `fe-scripts/scripts/aws_get_ssl_cert_arn.sh` | ACM cert ARN lookup | `data aws_acm_certificate` in modules |
| `be-scripts/scripts/aws/create_s3_bucket.sh` + `create_chatbot_s3_bucket.sh` + `S3-Policy-...-TEMPLATE.json` | Generic / chatbot-attachments S3 buckets + policies | `s3-bucket` module |
| `be-scripts/scripts/aws/get_lambda_url.sh` | Lambda/API Gateway URL lookup | `lambda-api` stack outputs |
| `be-scripts/scripts/aws/set_fe_cloudfront_domain.sh` | Reads CloudFront domain, updates `.env` CORS | `frontend` stack output + small wrapper helper |
| `be-scripts/scripts/aws_big_lambda/big_lambdas_manager.sh` + `template-sam.yml` | Lambda (container/zip) + API Gateway REST + custom domain + IAM role (SAM) | `lambda-api` module (infra); Docker build/ECR push stays in bash |
| `be-scripts/scripts/aws_cf_processor/run-cf-deployment.sh` | Generic CF stack processor (validate/run/destroy/output, LocalStack) | `run-tf-deployment.sh` generic wrapper |
| `be-scripts/scripts/aws_domains/cf-template-ec2-domain.yml` | Route53 record + ACM cert + 2 Lambda custom resources for DNS validation | `app-domain` module (native ACM DNS validation) |
| `be-scripts/scripts/aws_dynamodb/run-dynamodb-deploy.sh` | DynamoDB tables via generated CF | `dynamodb-tables` module |
| `be-scripts/scripts/aws_ec2_elb/run-create-key-pair.sh` | EC2 key pair + local `.pem` | `ec2-alb` module (`aws_key_pair` + `tls_private_key`, or import existing) |
| `be-scripts/scripts/aws_ec2_elb/run-ec2-cloud-deploy.sh` + `cf-template-ec2-elb.yml` | EC2 + ALB + SGs + IAM + domain wiring | `ec2-alb` module |
| `be-scripts/scripts/aws_ec2_elb/run-fastapi-ecr-creation.sh` | ECR repo + Docker build/push | `ecr-repository` module (repo + lifecycle); build/push stays in bash |
| `be-scripts/scripts/aws_secrets/aws_secrets_manager.sh` + `cf-template-secrets.yml` + `cf-template-kms-key.yml` | Secrets Manager (encrypted + plain) + KMS key | `secrets` + `kms-key` modules |

### Deployments NOT covered by the listed scripts (documented as gaps; not in this phase)

- `be-scripts/scripts/sql_db/run_sql_db_deploy.sh` — RDS PostgreSQL/MySQL via generated CF (suggested follow-up module `rds-database`).
- `be-scripts/scripts/aws/run_aws.sh` — Chalice-native deploys (superseded by `lambda-api` for SAM-style deploys).
- ACM certificate *creation* for the frontend (today lookup-only) — covered by reusing `app-domain`.
- Route53 alias record for the CloudFront distribution (today a manual console step) — covered in `frontend-hosting` (optional).
- ECR image retention (`clean_ecr_images.sh`) — covered by `aws_ecr_lifecycle_policy` in `ecr-repository`.
- The TF state bucket itself — covered by `bootstrap-tf-state.sh`.

## 3. Improvements applied in the OpenTofu version

**Security**
- CloudFront: OAI + public-read bucket → **Origin Access Control (OAC)** with a fully private bucket; drop all public ACL grants (`put-object-acl` to AllUsers).
- `MinimumProtocolVersion` `TLSv1.2_2019` → `TLSv1.2_2021`; `ViewerProtocolPolicy` `allow-all` → `redirect-to-https`.
- Secrets are **not** passed as CloudFormation parameters (visible in console/CloudTrail); they become `sensitive = true` TF variables read from `.env` at plan time, stored in Secrets Manager.
- IAM policies scoped: `secretsmanager:GetSecretValue` restricted to the two app secrets ARNs instead of `*`.
- ECR: `scan_on_push` kept; state bucket blocks all public access, SSE enabled.

**Correctness (bugs in the bash/CF versions, fixed by design in TF)**
- `run-create-key-pair.sh` `#!/bin/bvash` shebang typo.
- `create_s3_bucket.sh` checks `$?` after `echo` (always 0) — errors silently ignored.
- `create_chatbot_s3_bucket.sh` uses wrong path `${SCRIPTS_DIR}/aws/create_s3_bucket.sh` for prod/demo stages.
- `cf-template-ec2-domain.yml` creates a bogus A record (192.168.0.1/2) and needs two Lambda-backed custom resources for ACM DNS validation — replaced by native `aws_acm_certificate` + `aws_route53_record` validation.
- "Rollback → delete stack → retry" flow in `run-cf-deployment.sh` replaced by idempotent `tofu apply`.

**Operability**
- Drift detection via `tofu plan`; no perl-placeholder templating of templates.
- Remote state with locking enables team-shared deployments (DevOps/security/infra).

## 4. Architecture

### 4.1 Directory layout

```
packages/genericsuite-be-scripts/scripts/aws_tf/
├── run-tf-deployment.sh          # generic wrapper: init|validate|plan|apply|destroy|output
├── bootstrap-tf-state.sh         # one-time state bucket creation
├── modules/
│   ├── s3-bucket/
│   ├── dynamodb-tables/
│   ├── kms-key/
│   ├── secrets/
│   ├── ecr-repository/
│   ├── ec2-alb/
│   ├── app-domain/
│   └── lambda-api/
└── stacks/
    ├── s3/ ├── dynamodb/ ├── kms/ ├── secrets/ ├── ecr/ ├── ec2/ ├── domain/ └── lambda/

packages/genericsuite-fe-scripts/scripts/aws_tf/
├── run-tf-deployment.sh
├── aws_tf_deploy_to_s3.sh        # build (vite/webpack/react-app-rewired) + tofu apply + s3 sync + invalidation
├── modules/frontend-hosting/
└── stacks/frontend/
```

Each **module** contains `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`. Each **stack** (root config) adds `backend.tf` (empty `backend "s3" {}` block, configured by the wrapper) and `providers.tf` (region + default tags `App`, `Stage`, `ManagedBy=opentofu`, `Ticket=GS-334`).

### 4.2 State backend

- Bucket: `{app_name_lowercase}-tf-state-{aws_account_id}` — one per consuming app.
- Key: `{stage}/{stack}.tfstate` (e.g. `dev/frontend.tfstate`, `prod/dynamodb.tfstate`).
- Versioning + SSE-S3 encryption + public access block + **S3-native locking** (`use_lockfile = true`, OpenTofu ≥ 1.10). No DynamoDB lock table.
- `bootstrap-tf-state.sh` creates/verifies the bucket idempotently; `run-tf-deployment.sh` calls it before `tofu init`.
- The wrapper injects backend config via `tofu init -backend-config=...` so stacks contain no hardcoded bucket names.

### 4.3 Wrapper contract (`run-tf-deployment.sh`)

Mirrors `run-cf-deployment.sh` conventions:

```
run-tf-deployment.sh ACTION STAGE STACK [EXTRA_TF_ARGS]
# ACTION: init | validate | plan | apply | destroy | output
# STAGE:  dev | qa | staging | demo | prod
# STACK:  directory name under stacks/
```

- Reads the consuming app's `.env` (`set -o allexport; . .env`), resolves stage-suffixed variables (`AWS_S3_CHATBOT_ATTACHMENTS_BUCKET_${STAGE}` etc.) and exports them as `TF_VAR_*`.
- `CICD_MODE=1` → `-auto-approve` on apply; `CICD_MODE=0` (default) → interactive confirmation.
- `bash`, `set -euo pipefail`, quoted expansions, `read < /dev/tty` per `docs/codeStyle.md`.
- Secrets are exported as `TF_VAR_...` env vars (never written to disk or `.tfvars` files).

### 4.4 Module specs (inputs → resources → outputs)

- **`s3-bucket`** — in: `bucket_name`, `enable_public_read` (default false), `lambda_execution_role_arn` (optional), `app_name`, `stage`. Resources: bucket, ownership controls, public access block, tags (creation date/environment), optional policy replicating `S3-Policy-app-chatbot-attachments-TEMPLATE.json` (root + lambda role read/write; public read only if explicitly enabled). Out: bucket ARN/name.
- **`dynamodb-tables`** — in: `app_name`, `stage`, `tables` (list of objects: name, hash_key, range_key, GSIs — generated from the same JSON config `generate_dynamodb_cf.py` consumes). Resources: `aws_dynamodb_table` per entry, `PAY_PER_REQUEST`. Out: table names/ARNs. Table naming: `{app_name_lowercase}_{stage}_{table}`.
- **`kms-key`** — in: `alias` (default `genericsuite-key`). Resources: key + alias + account-root policy (mirrors `cf-template-kms-key.yml`). Out: key ARN, alias ARN.
- **`secrets`** — in: `app_name`, `stage`, `kms_key_alias`, `secrets_map` (sensitive map), `envs_map` (map). Resources: `{app}-{stage}-secrets` (KMS-encrypted) + `{app}-{stage}-envs` (default encryption) with `secret_string = jsonencode(...)`. Out: both secret ARNs. The wrapper builds the maps from the same CORE/EXTENSION/APP variable lists as `aws_secrets_manager.sh`, including `update_additional_envvars.sh` hooks.
- **`ecr-repository`** — in: `repository_name`, `images_to_keep` (default 2). Resources: repo (scan on push, mutable tags) + lifecycle policy expiring untagged/old images. Out: repository URL.
- **`app-domain`** — in: `domain_name`, `hosted_zone_id` (or lookup by `app_domain_name`), `app_name`, `stage`. Resources: `aws_acm_certificate` (DNS method) + `aws_route53_record` for validation + `aws_acm_certificate_validation`. Out: validated certificate ARN. Replaces both the EC2-domain CF template and the FE cert-lookup gap.
- **`ec2-alb`** — port of `cf-template-ec2-elb.yml`: in: key name, ECR image URI/tag, domain/cert ARN (from `app-domain`), S3 bucket, KMS alias, secret names, instance type. Resources: SGs (ALB 80/443 → EC2 app port; SSH restricted), IAM role+instance profile (S3/Secrets/KMS access), EC2 instance with user-data running the ECR container, ALB + target group + HTTP→HTTPS listeners, Route53 alias to ALB. Optional `create_key_pair` with `tls_private_key` writing the `.pem` locally (0400). Out: instance ID, ALB DNS, URL.
- **`lambda-api`** — port of `template-sam.yml`: in: `function_name` (`{lambda}-{stage}`), `package_type` (`Image`|`Zip`), `image_uri` or `zip_path`, `memory_size` (512), `timeout` (180), env var map, `domain_name` + `certificate_arn` (optional), `binary_media_types`, `stage_name`. Resources: execution role (logs, scoped S3/Secrets/KMS), `aws_lambda_function`, API Gateway REST API (`aws_api_gateway_rest_api` with `{proxy+}` ANY + root ANY proxy integration — replaces the enumerated OpenAPI paths, matching FastAPI/Flask routing), deployment + stage, Lambda invoke permission, optional custom domain + base path mapping + Route53 record. Out: invoke URL, function ARN, rest API id.
- **`frontend-hosting`** (fe-scripts) — in: `bucket_name`, `aliases` (app URL), `acm_certificate_arn` (or lookup via `app-domain`/data source), `hosted_zone_id` (optional). Resources: private S3 bucket, CloudFront distribution with **OAC**, default root object `index.html`, `redirect-to-https`, TLSv1.2_2021, SPA-friendly 403/404 → `/index.html` custom error responses, bucket policy allowing only the distribution, optional Route53 alias. Out: distribution ID, CloudFront domain name, bucket name (consumed by `aws_tf_deploy_to_s3.sh` for sync + invalidation, and by `set_fe_cloudfront_domain` equivalents for CORS).

### 4.5 What stays in bash

App build/packaging is not IaC and remains in wrappers: frontend bundler runs and `aws s3 sync` + `create-invalidation` (`aws_tf_deploy_to_s3.sh`); Docker image build/tag/push to ECR (existing scripts, pointed at the `ecr-repository` module's output); `deployment.zip` builds for zip-type Lambdas.

## 5. Versions & constraints

- OpenTofu `>= 1.10` (S3-native state locking), AWS provider `~> 6.0`.
- `versions.tf` in every module/stack pins both.
- Shell wrappers follow `be-scripts/docs/codeStyle.md` (bash shebang, `set -euo pipefail`, quoted expansions, perl over sed).

## 6. Testing plan

1. `tofu fmt -check` + `tofu validate` on every module and stack (CI-friendly, no credentials).
2. **Dev (real apply):** from `packages/genericsuite-basecamp/mkdocs_root/code/fastapitemplate/server` (has a real `.env`), STAGE=dev, account 071141316464: bootstrap state bucket → apply `kms`, `secrets`, `s3`, `dynamodb`, `ecr` stacks (and `frontend` from the FE side if the template's FE config allows) → verify resources exist via AWS CLI. Resources are **kept** (not destroyed).
3. **Prod:** `tofu plan` only — no apply.
4. Existing CloudFormation stacks remain untouched throughout.

## 7. Documentation & changelog

- Basecamp guide: `packages/genericsuite-basecamp/mkdocs_root/en/Deployment-Guide/opentofu.md` — single hands-on guide covering both packages (concepts, prerequisites, state bootstrap, per-stack usage, migration notes vs. CloudFormation, gap list from §2). Add nav entry in `mkdocs.yml`.
- `CHANGELOG.md` entries with `[GS-334]` in `genericsuite-fe-scripts`, `genericsuite-be-scripts`, and `genericsuite-basecamp`.

## 8. Out of scope

- Deleting/altering any CloudFormation template or existing deploy script.
- RDS (`sql_db`) module, Chalice-native deploys, LocalStack support for the TF path (documented as follow-ups).
- CI pipeline definitions (wrappers are CI-ready via `CICD_MODE=1`).
