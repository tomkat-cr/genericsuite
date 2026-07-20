# GCP OpenTofu Conversion — Design Spec

- **Date:** 2026-07-19
- **Ticket:** GS-40
- **Packages affected:** `genericsuite-fe-scripts`, `genericsuite-be-scripts`, `genericsuite-basecamp`
- **Status:** Draft — pending approval by Carlos J. Ramirez
- **Reference:** `docs/superpowers/specs/2026-07-16-aws-opentofu-conversion-design.md` (GS-334) — the AWS OpenTofu conversion this design mirrors.

## 1. Goal

Provide an OpenTofu (Terraform-compatible) implementation of the GenericSuite backend and frontend deployments on **Google Cloud Platform**, using the exact same approach, directory layout, wrapper contract, and conventions as the AWS OpenTofu conversion (GS-334). Developers who know `scripts/aws_tf/` can use `scripts/gcp_tf/` with zero re-learning: same `run-tf-deployment.sh ACTION STAGE STACK` contract, same `.env`-driven `TF_VAR_*` export, same remote-state bootstrap, same module/stack split. Nothing in the AWS path is modified.

## 2. AWS → GCP service mapping

| AWS (aws_tf) | GCP (gcp_tf) | Notes |
|---|---|---|
| S3 state bucket + `use_lockfile` | GCS bucket (`gcs` backend) | GCS backend locks natively; versioning + uniform access + public access prevention |
| `s3-bucket` module (chatbot attachments) | `gcs-bucket` module | `google_storage_bucket` + IAM members |
| `dynamodb-tables` module | **Gap — not converted** | `DbAbstractor` has no Firestore adapter; on GCP use MongoDB Atlas or Cloud SQL (documented) |
| `kms-key` module | `kms-key` module | `google_kms_key_ring` + `google_kms_crypto_key` (90-day rotation — improvement over AWS) |
| `secrets` module (2 secrets, 1 KMS-encrypted) | `secrets` module | Secret Manager `{app}-{stage}-secrets` (CMEK) + `{app}-{stage}-envs` (Google-managed encryption), JSON payloads, same variable lists |
| `ecr-repository` module | `artifact-registry` module | Docker repo + cleanup policies (keep N, expire untagged) |
| `lambda-api` module (Lambda + API GW REST) | `cloud-run-api` module | Cloud Run v2 service (container), dedicated SA with scoped Secret/Storage access, optional domain mapping |
| `ec2-alb` module | `gce-lb` module | GCE instance on Container-Optimized OS (Konlet container declaration) + global external HTTPS LB + managed SSL cert + Cloud DNS record |
| `app-domain` module (ACM DNS validation) | **Not needed** | Google-managed SSL certs (`google_compute_managed_ssl_certificate`) validate automatically once DNS points at the LB; Cloud Run domain mappings auto-provision TLS |
| `frontend-hosting` module (S3 + CloudFront OAC) | `frontend-hosting` module | GCS bucket + backend bucket + Cloud CDN + HTTPS LB + managed cert + Cloud DNS; SPA fallback via `not_found_page = index.html` |
| `aws_tf_deploy_to_s3.sh` | `gcp_tf_deploy_to_gcs.sh` | Same build flow; `gcloud storage rsync` + `gcloud compute url-maps invalidate-cdn-cache` |
| ECR Docker build/push (existing bash) | `build_push_image.sh` (new) | GCP has no pre-existing build script, so a minimal build+push helper is included |

### Gaps / follow-ups (documented, not in this phase)

- DynamoDB-equivalent (Firestore) — requires a `DbAbstractor` adapter in `genericsuite-be` first.
- Cloud SQL (PostgreSQL/MySQL) module — parity with the AWS `rds-database` follow-up.
- `genericsuite-be` runtime support for reading GCP Secret Manager (`CLOUD_PROVIDER=gcp`) — the IaC creates the secrets; app-side consumption is a separate ticket.
- The FE backend-bucket path serves SPA fallback content with HTTP 404 status (GCS `not_found_page` behavior behind an LB); browsers render it fine, but deep-link SEO differs from CloudFront's 200 rewrite.

## 3. Design choices & improvements

**Security**
- All buckets: uniform bucket-level access; state + chatbot buckets have public access prevention enforced.
- Secret Manager accessor roles granted per-secret to the dedicated runtime service account only (never project-wide) — mirrors the scoped `secretsmanager:GetSecretValue` fix from GS-334.
- Cloud Run / GCE run under dedicated service accounts (never the Compute default SA).
- SSH to the GCE instance only through IAP (`35.235.240.0/20`); no public port 22.
- KMS crypto key gets 90-day automatic rotation (improvement over the AWS static key).
- HTTP→HTTPS redirect on both LBs when a domain is configured.

**Operability**
- Same wrapper contract and `CICD_MODE=1` non-interactive mode as `aws_tf`.
- State bucket bootstrap also enables the required GCP APIs idempotently (storage, kms, secretmanager, artifactregistry, run, compute, dns).
- `.env` variables fall back to their AWS names where sensible (`GCP_CHATBOT_ATTACHMENTS_BUCKET_*` → `AWS_S3_CHATBOT_ATTACHMENTS_BUCKET_*`, `GCP_BUCKET_NAME_FE` → `AWS_S3_BUCKET_NAME_FE`, `GCP_DOCKER_IMAGE_TAG` → `ECR_DOCKER_IMAGE_TAG`) so existing projects need minimal new configuration.

## 4. Architecture

### 4.1 Directory layout

```
packages/genericsuite-be-scripts/scripts/gcp_tf/
├── run-tf-deployment.sh          # generic wrapper: init|validate|plan|apply|destroy|output
├── bootstrap-tf-state.sh         # one-time state bucket creation + API enablement
├── build_push_image.sh           # Docker build + push to Artifact Registry
├── modules/
│   ├── gcs-bucket/
│   ├── kms-key/
│   ├── secrets/
│   ├── artifact-registry/
│   ├── cloud-run-api/
│   └── gce-lb/
└── stacks/
    ├── gcs/ ├── kms/ ├── secrets/ ├── ar/ ├── cloudrun/ └── gce/

packages/genericsuite-fe-scripts/scripts/gcp_tf/
├── run-tf-deployment.sh
├── bootstrap-tf-state.sh
├── gcp_tf_deploy_to_gcs.sh      # build + tofu apply + gcs rsync + CDN invalidation
├── modules/frontend-hosting/
└── stacks/frontend/
```

Each **module** contains `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`. Each **stack** adds `backend.tf` (empty `backend "gcs" {}`) and `providers.tf` (project + region + default labels `app`, `stage`, `managed_by=opentofu`, `ticket=gs-40` — GCP labels must be lowercase).

### 4.2 State backend

- Bucket: `{app_name_lowercase}-tf-state-{gcp_project_id}` — one per consuming app.
- Prefix: `{stage}/{stack}` (state object `{stage}/{stack}/default.tfstate`).
- Versioning + uniform bucket-level access + public access prevention; GCS-native state locking (built into the `gcs` backend — no extra flag needed).
- `bootstrap-tf-state.sh` creates/verifies the bucket and enables the required GCP APIs idempotently; the wrapper calls it before `tofu init`.
- Backend config injected via `tofu init -backend-config=bucket=... -backend-config=prefix=...` — no hardcoded bucket names in stacks.

### 4.3 Wrapper contract (`run-tf-deployment.sh`)

Identical to `aws_tf`:

```
run-tf-deployment.sh ACTION STAGE STACK [EXTRA_TF_ARGS]
# ACTION: init | validate | plan | apply | destroy | output
# STAGE:  dev | qa | staging | demo | prod
# STACK:  directory name under stacks/
```

- Reads the consuming app's `.env`, resolves `GCP_PROJECT_ID` (falls back to `gcloud config get-value project`), exports `TF_VAR_*`.
- `CICD_MODE=1` → `-auto-approve`; secrets only via `TF_VAR_*` env vars (`sensitive = true`), never written to disk.
- Per-stack `build-tfvars.sh` hook (secrets maps, runtime env vars) — same mechanism as `aws_tf`.
- New `.env` variables: `GCP_PROJECT_ID`, `GCP_REGION`, `GCP_KMS_KEY_RING`, `GCP_KMS_KEY_NAME`, `GCP_CHATBOT_ATTACHMENTS_BUCKET_{STAGE}`, `GCP_CLOUD_RUN_SERVICE_NAME`, `GCP_DOCKER_IMAGE_TAG`, `GCP_API_DOMAIN_NAME` (supports `[STAGE]` token), `GCP_DNS_ZONE_NAME`, `GCP_MACHINE_TYPE`, `GCP_CONTAINER_PORT`, `GCP_BUCKET_NAME_FE` (FE, supports `[STAGE]` token).

### 4.4 Module specs (inputs → resources → outputs)

- **`gcs-bucket`** — in: `bucket_name`, `gcp_region`, `app_name`, `stage`, `enable_public_read` (default false), `service_account_email` (optional). Resources: bucket (uniform access, PAP enforced unless public), optional `allUsers` objectViewer, optional SA objectAdmin. Out: bucket name/URL.
- **`kms-key`** — in: `key_ring_name` (default `genericsuite-keyring`), `key_name` (default `genericsuite-key`), `gcp_region`. Resources: key ring + crypto key (ENCRYPT_DECRYPT, 90-day rotation). Out: key ring id, crypto key id. Note: GCP key rings are undeletable; `destroy` removes them from state only.
- **`secrets`** — in: `app_name`, `stage`, `gcp_region`, `secrets_map` (sensitive), `envs_map`, `kms_crypto_key_id` (optional CMEK), `sm_service_agent_email`. Resources: `{app}-{stage}-secrets` (CMEK, user-managed replication in region) + `{app}-{stage}-envs` (auto replication), JSON payloads, KMS encrypter/decrypter grant to the Secret Manager service agent. Out: both secret ids. The stack's `build-tfvars.sh` reuses the CORE/EXTENSION/APP variable lists from `aws_secrets_manager.sh` (GCP-adjusted) and creates the SM service identity idempotently.
- **`artifact-registry`** — in: `repository_id`, `gcp_region`, `gcp_project_id`, `images_to_keep` (default 2). Resources: Docker repo + cleanup policies (keep N most recent, delete untagged > 30 days). Out: repository URL (`{region}-docker.pkg.dev/{project}/{repo}`).
- **`cloud-run-api`** — in: `service_name` (`{base}-{stage}`), `image_uri`, `memory` (512Mi), `cpu` (1), `timeout` (180), `min_instances` (0), `max_instances` (10), `container_port` (8080), env var map, `chatbot_attachments_bucket_name`, `domain_name` + `dns_zone_name` (optional), `allow_unauthenticated` (default true). Resources: dedicated SA, per-secret accessor grants, bucket objectAdmin grant, Cloud Run v2 service, public invoker binding, optional domain mapping + CNAME to `ghs.googlehosted.com.`. Out: service URL, service name, SA email.
- **`gce-lb`** — port of `ec2-alb`: in: machine type, image URI, domain/zone, bucket, secret names, container port, network (default `default`). Resources: dedicated SA (+ logging/monitoring writer), firewalls (LB/health-check ranges → container port; IAP-only SSH), COS instance running the container via Konlet declaration, unmanaged instance group with named port, health check, backend service, URL map, managed SSL cert, HTTPS + HTTP-redirect proxies, global IP, forwarding rules, Cloud DNS A record. Out: instance name, LB IP, URL.
- **`frontend-hosting`** (fe-scripts) — in: `bucket_name`, `domain_name` (from `APP_FE_URL`), `dns_zone_name`, `app_name`, `stage`, `gcp_region`. Resources: GCS bucket (website config `index.html`/`index.html`, public objectViewer — required for backend-bucket serving), backend bucket with Cloud CDN, URL map, managed cert, HTTPS + HTTP-redirect proxies, global IP, forwarding rules, optional DNS A record. Out: bucket name, URL map name (for CDN invalidation), LB IP, site URL.

### 4.5 What stays in bash

Same philosophy as GS-334: frontend bundler runs and `gcloud storage rsync` + CDN invalidation (`gcp_tf_deploy_to_gcs.sh`); Docker image build/tag/push (`build_push_image.sh`).

## 5. Versions & constraints

- OpenTofu `>= 1.10`; Google provider `~> 6.0` — pinned in every `versions.tf`.
- `gcloud` CLI authenticated (`gcloud auth login` + application-default credentials for the provider).
- Shell wrappers follow `be-scripts/docs/codeStyle.md` (bash shebang, `set -euo pipefail`, quoted expansions, perl over sed).

## 6. Testing plan

1. `tofu fmt -recursive` + `tofu init -backend=false` + `tofu validate` on every stack (CI-friendly, no credentials); `bash -n` on every shell script.
2. **Dev (real apply, manual/optional):** from a consuming app with a real `.env` and a GCP project with billing: bootstrap → apply `kms`, `secrets`, `gcs`, `ar` (and `frontend` from the FE side) → verify via `gcloud`. Requires human-provided GCP credentials; the executor skips it when `gcloud auth list` shows no active account.
3. **Prod:** `tofu plan` only.
4. The AWS path (`aws_tf`, CloudFormation) remains untouched throughout.

## 7. Documentation & changelog

- Basecamp guide: `packages/genericsuite-basecamp/mkdocs_root/en/Deployment-Guide/opentofu-gcp.md` (mirrors `opentofu.md`), plus `mkdocs.yml` nav entries.
- `CHANGELOG.md` entries with `[GS-40]` in `genericsuite-fe-scripts`, `genericsuite-be-scripts`, `genericsuite-basecamp`, and the superproject.

## 8. Out of scope

- Modifying anything under `scripts/aws_tf/`, the CloudFormation templates, or existing deploy scripts.
- Firestore/DynamoDB-equivalent, Cloud SQL module, GKE, LocalStack-style local emulation.
- `genericsuite-be` runtime changes for GCP Secret Manager consumption.
- CI pipeline definitions (wrappers are CI-ready via `CICD_MODE=1`).
