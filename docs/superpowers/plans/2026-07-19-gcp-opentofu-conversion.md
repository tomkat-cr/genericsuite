# GCP OpenTofu Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Sub-agent models:** When executing with subagent-driven-development, dispatch each task to a sub-agent with the model named in its "Suggested sub-agent" line: `haiku` (claude-haiku-4-5) for mechanical/boilerplate tasks, `sonnet` (claude-sonnet-5) for module/wrapper/doc authoring. The orchestrating session reviews between tasks.

**Goal:** Provide an OpenTofu implementation of the GenericSuite backend and frontend deployments on Google Cloud Platform in `genericsuite-be-scripts` and `genericsuite-fe-scripts`, with GCS remote state, mirroring the AWS OpenTofu conversion (GS-334) exactly — same wrapper contract, same module/stack layout — without touching the AWS path.

**Architecture:** Reusable modules under `scripts/gcp_tf/modules/`, thin root configs under `scripts/gcp_tf/stacks/`, and a generic bash wrapper (`run-tf-deployment.sh`) that loads the consuming app's `.env`, exports `TF_VAR_*`, bootstraps the GCS state bucket (and enables required GCP APIs), and runs `tofu init/validate/plan/apply/destroy/output`. Spec: `docs/superpowers/specs/2026-07-19-gcp-opentofu-conversion-design.md`. AWS reference implementation: `packages/genericsuite-be-scripts/scripts/aws_tf/` and `packages/genericsuite-fe-scripts/scripts/aws_tf/`.

**Tech Stack:** OpenTofu ≥ 1.10, Google provider `~> 6.0`, bash, `gcloud` CLI, `jq`.

## Global Constraints

- OpenTofu `required_version = ">= 1.10"`; Google provider `source = "hashicorp/google"`, `version = "~> 6.0"` — pinned in every `versions.tf` (modules and stacks).
- Never modify or delete anything under `scripts/aws_tf/`, any CloudFormation template, or any existing deploy script.
- Resource names match GenericSuite conventions: `{app}-{stage}-secrets`, `{app}-{stage}-envs`, `{service_base}-{stage}` (Cloud Run service), `genericsuite-keyring`/`genericsuite-key` (KMS), `{app_name_lowercase}` (Artifact Registry repo).
- State: GCS bucket `{app_name_lowercase}-tf-state-{gcp_project_id}`, prefix `{stage}/{stack}`. Backend config only via `tofu init -backend-config=...` (empty `backend "gcs" {}` block in every stack's `backend.tf`).
- Shell: `#!/bin/bash`, `set -euo pipefail`, quoted expansions (`"${var}"`), `read VAR < /dev/tty` for prompts, perl over sed (per `packages/genericsuite-be-scripts/docs/codeStyle.md`).
- Secrets: only via `TF_VAR_*` env vars marked `sensitive = true`; never written to `.tfvars` files on disk.
- Provider `default_labels` on every stack: `app`, `stage`, `managed_by = "opentofu"`, `ticket = "gs-40"`. GCP label values must be lowercase.
- Commits: inside each submodule (`packages/genericsuite-be-scripts`, `packages/genericsuite-fe-scripts`, `packages/genericsuite-basecamp`) on their current `develop` branch; message suffix `[GS-40]` and second `-m` line `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Test cycle for HCL tasks: `tofu fmt -recursive` on the `gcp_tf` tree, then `tofu init -backend=false -input=false` + `tofu validate` in each stack directory touched. For bash: `bash -n FILE`. No GCP credentials are needed for any validation step.
- Do NOT run `tofu apply`/`plan` against a real GCP project anywhere in this plan — real applies are a manual step for Carlos (Task 15, Step 3).

**Path shorthands used below:**
- `BE_TF` = `packages/genericsuite-be-scripts/scripts/gcp_tf`
- `FE_TF` = `packages/genericsuite-fe-scripts/scripts/gcp_tf`

**Files every stack shares (repeated verbatim in each stack task):** `backend.tf`, `versions.tf`, `providers.tf` differ only in nothing — they are identical byte-for-byte across stacks. They are still spelled out completely in every task so tasks can be executed independently.

---

### Task 1: Toolchain check (OpenTofu + gcloud)

**Suggested sub-agent:** haiku

**Files:** none (toolchain only)

**Interfaces:**
- Produces: `tofu` ≥ 1.10 and `gcloud` on PATH, used by every later task (`gcloud` is only *invoked* at deploy time; here we just confirm it exists for `bash -n`-level sanity).

- [ ] **Step 1: Check/install OpenTofu**

Run: `tofu version || brew install opentofu`
Expected: `OpenTofu v1.1x.x` (≥ 1.10).

- [ ] **Step 2: Check gcloud exists**

Run: `gcloud --version | head -1 || echo "MISSING"`
Expected: `Google Cloud SDK ...`. If it prints `MISSING`, run `brew install --cask google-cloud-sdk` and re-check. Do NOT run `gcloud auth login` — authentication is not needed for this plan.

---

### Task 2: Backend-scripts state bootstrap, generic wrapper, image build helper

**Suggested sub-agent:** sonnet

**Files:**
- Create: `BE_TF/bootstrap-tf-state.sh`
- Create: `BE_TF/run-tf-deployment.sh`
- Create: `BE_TF/build_push_image.sh`

**Interfaces:**
- Consumes: consuming app `.env` (`APP_NAME`, `GCP_REGION`, optional `GCP_PROJECT_ID`, `GCP_KMS_KEY_RING`, `GCP_KMS_KEY_NAME`, `GCP_CHATBOT_ATTACHMENTS_BUCKET_{STAGE}` — falls back to `AWS_S3_CHATBOT_ATTACHMENTS_BUCKET_{STAGE}` —, `GCP_CLOUD_RUN_SERVICE_NAME` — falls back to `AWS_LAMBDA_FUNCTION_NAME` —, `GCP_API_DOMAIN_NAME` with `[STAGE]` token, `GCP_DNS_ZONE_NAME`, `GCP_DOCKER_IMAGE_TAG` — falls back to `ECR_DOCKER_IMAGE_TAG` —, `GCP_MACHINE_TYPE`, `GCP_CONTAINER_PORT`, `GCP_DOCKERFILE_PATH`).
- Produces:
  - `bootstrap-tf-state.sh BUCKET PROJECT REGION` — idempotent state bucket creation + API enablement.
  - `run-tf-deployment.sh ACTION STAGE STACK [EXTRA...]` — ACTION ∈ `init|validate|plan|apply|destroy|output`; exports `TF_VAR_app_name` (lowercase), `TF_VAR_stage`, `TF_VAR_gcp_project_id`, `TF_VAR_gcp_region`, `TF_VAR_kms_key_ring`, `TF_VAR_kms_key_name`, `TF_VAR_chatbot_attachments_bucket_name`, `TF_VAR_cloud_run_service_name`, `TF_VAR_api_domain_name`, `TF_VAR_app_domain_name`, `TF_VAR_dns_zone_name`, `TF_VAR_image_tag`, `TF_VAR_machine_type`, `TF_VAR_container_port`, `TF_VAR_tf_state_bucket`; sources `stacks/${STACK}/build-tfvars.sh` when present.
  - `build_push_image.sh STAGE [DOCKERFILE_PATH]` — builds and pushes `{region}-docker.pkg.dev/{project}/{app_name_lowercase}/{service_name}:{tag}`.

- [ ] **Step 1: Write `BE_TF/bootstrap-tf-state.sh`**

```bash
#!/bin/bash
# scripts/gcp_tf/bootstrap-tf-state.sh
# Create/verify the GCS bucket that stores OpenTofu remote state, and enable
# the GCP APIs required by the GenericSuite stacks.
# GCP counterpart of scripts/aws_tf/bootstrap-tf-state.sh.
# 2026-07-19 | CR [GS-40]
# Usage: bash scripts/gcp_tf/bootstrap-tf-state.sh BUCKET_NAME GCP_PROJECT_ID GCP_REGION
set -euo pipefail

BUCKET_NAME="${1:-}"
GCP_PROJECT_ID="${2:-}"
GCP_REGION="${3:-}"

if [ "${BUCKET_NAME}" = "" ] || [ "${GCP_PROJECT_ID}" = "" ] || [ "${GCP_REGION}" = "" ]; then
    echo "Usage: $0 BUCKET_NAME GCP_PROJECT_ID GCP_REGION"
    exit 1
fi

# Enable the APIs used by the GenericSuite GCP stacks (idempotent)
gcloud services enable \
    storage.googleapis.com \
    cloudkms.googleapis.com \
    secretmanager.googleapis.com \
    artifactregistry.googleapis.com \
    run.googleapis.com \
    compute.googleapis.com \
    dns.googleapis.com \
    --project "${GCP_PROJECT_ID}"

if gcloud storage buckets describe "gs://${BUCKET_NAME}" --project "${GCP_PROJECT_ID}" >/dev/null 2>&1; then
    echo "TF state bucket 'gs://${BUCKET_NAME}' already exists."
    exit 0
fi

echo "Creating TF state bucket 'gs://${BUCKET_NAME}' in '${GCP_REGION}'..."
gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project "${GCP_PROJECT_ID}" \
    --location "${GCP_REGION}" \
    --uniform-bucket-level-access \
    --public-access-prevention

gcloud storage buckets update "gs://${BUCKET_NAME}" --versioning

echo "TF state bucket 'gs://${BUCKET_NAME}' created (versioned, private, uniform access)."
```

- [ ] **Step 2: Write `BE_TF/run-tf-deployment.sh`**

```bash
#!/bin/bash
# scripts/gcp_tf/run-tf-deployment.sh
# Generic OpenTofu deployment wrapper for GenericSuite backend stacks on GCP.
# GCP counterpart of scripts/aws_tf/run-tf-deployment.sh.
# 2026-07-19 | CR [GS-40]
#
# Usage:
#   bash scripts/gcp_tf/run-tf-deployment.sh ACTION STAGE STACK [EXTRA_TOFU_ARGS...]
#
# Parameters:
#   ACTION: init | validate | plan | apply | destroy | output
#   STAGE:  dev | qa | staging | demo | prod
#   STACK:  directory name under scripts/gcp_tf/stacks (gcs, kms, secrets, ar,
#           cloudrun, gce)
#
# Environment:
#   CICD_MODE=1        -> non-interactive (-auto-approve on apply/destroy)
#   TF_STATE_BUCKET    -> override state bucket name
set -euo pipefail

REPO_BASEDIR="$(pwd)"
SCRIPTS_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

ACTION="${1:-}"
STAGE="${2:-}"
STACK="${3:-}"
if [ $# -ge 3 ]; then shift 3; else shift $#; fi

usage_abort() {
    echo "ERROR: $1"
    echo "Usage: $0 ACTION STAGE STACK [EXTRA_TOFU_ARGS...]"
    echo "  ACTION: init | validate | plan | apply | destroy | output"
    echo "  STAGE:  dev | qa | staging | demo | prod"
    echo "  STACK:  one of: $(ls "${SCRIPTS_DIR}/stacks" | tr '\n' ' ')"
    exit 1
}

if [ "${ACTION}" = "" ]; then usage_abort "ACTION is not set"; fi
if [ "${STAGE}" = "" ]; then usage_abort "STAGE is not set"; fi
if [ "${STACK}" = "" ]; then usage_abort "STACK is not set"; fi
if [ ! -d "${SCRIPTS_DIR}/stacks/${STACK}" ]; then usage_abort "Unknown STACK '${STACK}'"; fi
case "${ACTION}" in
    init|validate|plan|apply|destroy|output) ;;
    *) usage_abort "Unknown ACTION '${ACTION}'" ;;
esac

case "${STAGE}" in
    dev|qa|staging|demo|prod) ;;
    *) usage_abort "Unknown STAGE '${STAGE}'" ;;
esac

CICD_MODE="${CICD_MODE:-0}"

# Load the consuming app's .env
if [ -f "${REPO_BASEDIR}/.env" ]; then
    set -o allexport
    # shellcheck disable=SC1091
    . "${REPO_BASEDIR}/.env"
    set +o allexport
else
    echo "WARNING: no .env file in ${REPO_BASEDIR}"
fi

: "${APP_NAME:?ERROR: APP_NAME is not set}"
: "${GCP_REGION:?ERROR: GCP_REGION is not set}"

STAGE_UPPERCASE="$(echo "${STAGE}" | tr '[:lower:]' '[:upper:]')"
APP_NAME_LOWERCASE="$(echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]')"

if [ "${GCP_PROJECT_ID:-}" = "" ]; then
    GCP_PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [ "${GCP_PROJECT_ID}" = "" ] || [ "${GCP_PROJECT_ID}" = "(unset)" ]; then
    echo "ERROR: GCP_PROJECT_ID could not be resolved. Set it in .env or run 'gcloud config set project PROJECT_ID'."
    exit 1
fi

TF_STATE_BUCKET="${TF_STATE_BUCKET:-${APP_NAME_LOWERCASE}-tf-state-${GCP_PROJECT_ID}}"
bash "${SCRIPTS_DIR}/bootstrap-tf-state.sh" "${TF_STATE_BUCKET}" "${GCP_PROJECT_ID}" "${GCP_REGION}"

# Common TF_VARs (every stack declares only the ones it needs)
export TF_VAR_app_name="${APP_NAME_LOWERCASE}"
export TF_VAR_stage="${STAGE}"
export TF_VAR_gcp_project_id="${GCP_PROJECT_ID}"
export TF_VAR_gcp_region="${GCP_REGION}"
export TF_VAR_kms_key_ring="${GCP_KMS_KEY_RING:-genericsuite-keyring}"
export TF_VAR_kms_key_name="${GCP_KMS_KEY_NAME:-genericsuite-key}"

chatbot_bucket_varname="GCP_CHATBOT_ATTACHMENTS_BUCKET_${STAGE_UPPERCASE}"
TF_VAR_chatbot_attachments_bucket_name="${!chatbot_bucket_varname:-}"
if [ "${TF_VAR_chatbot_attachments_bucket_name}" = "" ]; then
    chatbot_bucket_varname="AWS_S3_CHATBOT_ATTACHMENTS_BUCKET_${STAGE_UPPERCASE}"
    TF_VAR_chatbot_attachments_bucket_name="${!chatbot_bucket_varname:-}"
fi
export TF_VAR_chatbot_attachments_bucket_name

CLOUD_RUN_SERVICE_BASE="${GCP_CLOUD_RUN_SERVICE_NAME:-${AWS_LAMBDA_FUNCTION_NAME:-${APP_NAME_LOWERCASE}-backend}}"
TF_VAR_cloud_run_service_name="$(echo "${CLOUD_RUN_SERVICE_BASE}-${STAGE}" | tr '[:upper:]' '[:lower:]')"
export TF_VAR_cloud_run_service_name

TF_VAR_api_domain_name="$(echo "${GCP_API_DOMAIN_NAME:-}" | perl -pe "s/\[STAGE\]/${STAGE}/g")"
export TF_VAR_api_domain_name
export TF_VAR_app_domain_name="${APP_DOMAIN_NAME:-}"
export TF_VAR_dns_zone_name="${GCP_DNS_ZONE_NAME:-}"
export TF_VAR_image_tag="${GCP_DOCKER_IMAGE_TAG:-${ECR_DOCKER_IMAGE_TAG:-latest}}"
export TF_VAR_machine_type="${GCP_MACHINE_TYPE:-e2-small}"
export TF_VAR_container_port="${GCP_CONTAINER_PORT:-8080}"
export TF_VAR_tf_state_bucket="${TF_STATE_BUCKET}"

# Optional per-stack variable builder (e.g. secrets maps, runtime env vars)
if [ -f "${SCRIPTS_DIR}/stacks/${STACK}/build-tfvars.sh" ]; then
    # shellcheck disable=SC1090
    . "${SCRIPTS_DIR}/stacks/${STACK}/build-tfvars.sh"
fi

cd "${SCRIPTS_DIR}/stacks/${STACK}"

echo ""
echo "RUN-TF-DEPLOYMENT (GCP) | action=${ACTION} stage=${STAGE} stack=${STACK}"
echo "State: gs://${TF_STATE_BUCKET}/${STAGE}/${STACK}/default.tfstate"
echo ""

tofu init -reconfigure -input=false \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="prefix=${STAGE}/${STACK}"

APPROVE_ARG=""
if [ "${CICD_MODE}" = "1" ]; then
    APPROVE_ARG="-auto-approve"
fi

case "${ACTION}" in
    init)
        ;;
    validate)
        tofu validate "$@"
        ;;
    plan)
        tofu plan -input=false "$@"
        ;;
    apply)
        # shellcheck disable=SC2086
        tofu apply -input=false ${APPROVE_ARG} "$@"
        ;;
    destroy)
        # shellcheck disable=SC2086
        tofu destroy -input=false ${APPROVE_ARG} "$@"
        ;;
    output)
        tofu output "$@"
        ;;
esac

echo ""
echo "Done with '${ACTION}' over stack '${STACK}' (stage '${STAGE}')"
cd "${REPO_BASEDIR}"
```

- [ ] **Step 3: Write `BE_TF/build_push_image.sh`**

```bash
#!/bin/bash
# scripts/gcp_tf/build_push_image.sh
# Build the backend Docker image and push it to Artifact Registry.
# GCP counterpart of the ECR build/push flow (run-fastapi-ecr-creation.sh).
# 2026-07-19 | CR [GS-40]
#
# Usage:
#   bash scripts/gcp_tf/build_push_image.sh STAGE [DOCKERFILE_PATH]
set -euo pipefail

REPO_BASEDIR="$(pwd)"

STAGE="${1:-}"
DOCKERFILE_ARG="${2:-}"

if [ "${STAGE}" = "" ]; then
    echo "Usage: $0 STAGE [DOCKERFILE_PATH]"
    exit 1
fi

if [ -f "${REPO_BASEDIR}/.env" ]; then
    set -o allexport
    # shellcheck disable=SC1091
    . "${REPO_BASEDIR}/.env"
    set +o allexport
fi

: "${APP_NAME:?ERROR: APP_NAME is not set}"
: "${GCP_REGION:?ERROR: GCP_REGION is not set}"

APP_NAME_LOWERCASE="$(echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]')"
DOCKERFILE_PATH="${DOCKERFILE_ARG:-${GCP_DOCKERFILE_PATH:-Dockerfile}}"

if [ "${GCP_PROJECT_ID:-}" = "" ]; then
    GCP_PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [ "${GCP_PROJECT_ID}" = "" ] || [ "${GCP_PROJECT_ID}" = "(unset)" ]; then
    echo "ERROR: GCP_PROJECT_ID could not be resolved. Set it in .env or run 'gcloud config set project PROJECT_ID'."
    exit 1
fi

CLOUD_RUN_SERVICE_BASE="${GCP_CLOUD_RUN_SERVICE_NAME:-${AWS_LAMBDA_FUNCTION_NAME:-${APP_NAME_LOWERCASE}-backend}}"
SERVICE_NAME="$(echo "${CLOUD_RUN_SERVICE_BASE}-${STAGE}" | tr '[:upper:]' '[:lower:]')"
IMAGE_TAG="${GCP_DOCKER_IMAGE_TAG:-${ECR_DOCKER_IMAGE_TAG:-latest}}"
IMAGE_URI="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${APP_NAME_LOWERCASE}/${SERVICE_NAME}:${IMAGE_TAG}"

if [ ! -f "${DOCKERFILE_PATH}" ]; then
    echo "ERROR: Dockerfile not found at '${DOCKERFILE_PATH}'"
    exit 1
fi

echo "Building ${IMAGE_URI} from ${DOCKERFILE_PATH}..."
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet
docker build -t "${IMAGE_URI}" -f "${DOCKERFILE_PATH}" "${REPO_BASEDIR}"
docker push "${IMAGE_URI}"

echo ""
echo "Pushed: ${IMAGE_URI}"
```

- [ ] **Step 4: Syntax-check all three scripts**

Run:
```bash
bash -n packages/genericsuite-be-scripts/scripts/gcp_tf/bootstrap-tf-state.sh
bash -n packages/genericsuite-be-scripts/scripts/gcp_tf/run-tf-deployment.sh
bash -n packages/genericsuite-be-scripts/scripts/gcp_tf/build_push_image.sh
```
Expected: no output, exit 0 for each.

- [ ] **Step 5: Commit**

```bash
cd packages/genericsuite-be-scripts
git rev-parse --abbrev-ref HEAD   # Expected: develop. If not, run: git checkout develop
git add scripts/gcp_tf/bootstrap-tf-state.sh scripts/gcp_tf/run-tf-deployment.sh scripts/gcp_tf/build_push_image.sh
git commit -m "Add: GCP OpenTofu generic wrapper, GCS state bootstrap and Artifact Registry image build/push helper in scripts/gcp_tf [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 3: `gcs-bucket` module + `gcs` stack

**Suggested sub-agent:** sonnet

**Files:**
- Create: `BE_TF/modules/gcs-bucket/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`
- Create: `BE_TF/stacks/gcs/backend.tf`, `providers.tf`, `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`

**Interfaces:**
- Consumes: wrapper exports `TF_VAR_app_name`, `TF_VAR_stage`, `TF_VAR_gcp_project_id`, `TF_VAR_gcp_region`, `TF_VAR_chatbot_attachments_bucket_name` (Task 2).
- Produces: module `gcs-bucket` with inputs `bucket_name (string)`, `gcp_region (string)`, `app_name (string)`, `stage (string)`, `enable_public_read (bool, default false)`, `service_account_email (string, default "")` and outputs `bucket_name (string)`, `bucket_url (string)`. Stack `gcs` outputs `bucket_name`, `bucket_url`.

- [ ] **Step 1: Write `BE_TF/modules/gcs-bucket/main.tf`**

```hcl
resource "google_storage_bucket" "this" {
  name                        = var.bucket_name
  location                    = var.gcp_region
  uniform_bucket_level_access = true
  public_access_prevention    = var.enable_public_read ? "inherited" : "enforced"
  force_destroy               = false

  labels = {
    app   = var.app_name
    stage = var.stage
  }
}

resource "google_storage_bucket_iam_member" "public_read" {
  count  = var.enable_public_read ? 1 : 0
  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_iam_member" "rw" {
  count  = var.service_account_email != "" ? 1 : 0
  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.service_account_email}"
}
```

- [ ] **Step 2: Write `BE_TF/modules/gcs-bucket/variables.tf`**

```hcl
variable "bucket_name" {
  description = "GCS bucket name (globally unique)"
  type        = string
}

variable "gcp_region" {
  description = "GCP region (bucket location)"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "enable_public_read" {
  description = "Grant allUsers objectViewer (public read)"
  type        = bool
  default     = false
}

variable "service_account_email" {
  description = "Service account granted objectAdmin on the bucket; empty skips the grant"
  type        = string
  default     = ""
}
```

- [ ] **Step 3: Write `BE_TF/modules/gcs-bucket/outputs.tf`**

```hcl
output "bucket_name" {
  description = "Bucket name"
  value       = google_storage_bucket.this.name
}

output "bucket_url" {
  description = "Bucket gs:// URL"
  value       = google_storage_bucket.this.url
}
```

- [ ] **Step 4: Write `BE_TF/modules/gcs-bucket/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 5: Write `BE_TF/stacks/gcs/backend.tf`**

```hcl
terraform {
  backend "gcs" {}
}
```

- [ ] **Step 6: Write `BE_TF/stacks/gcs/providers.tf`**

```hcl
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region

  default_labels = {
    app        = var.app_name
    stage      = var.stage
    managed_by = "opentofu"
    ticket     = "gs-40"
  }
}
```

- [ ] **Step 7: Write `BE_TF/stacks/gcs/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 8: Write `BE_TF/stacks/gcs/variables.tf`**

```hcl
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "chatbot_attachments_bucket_name" {
  description = "Chatbot attachments bucket name"
  type        = string
}
```

- [ ] **Step 9: Write `BE_TF/stacks/gcs/main.tf`**

```hcl
module "chatbot_attachments_bucket" {
  source = "../../modules/gcs-bucket"

  bucket_name = var.chatbot_attachments_bucket_name
  gcp_region  = var.gcp_region
  app_name    = var.app_name
  stage       = var.stage
}
```

- [ ] **Step 10: Write `BE_TF/stacks/gcs/outputs.tf`**

```hcl
output "bucket_name" {
  description = "Chatbot attachments bucket name"
  value       = module.chatbot_attachments_bucket.bucket_name
}

output "bucket_url" {
  description = "Chatbot attachments bucket URL"
  value       = module.chatbot_attachments_bucket.bucket_url
}
```

- [ ] **Step 11: Format and validate**

Run:
```bash
tofu fmt -recursive packages/genericsuite-be-scripts/scripts/gcp_tf
cd packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/gcs
tofu init -backend=false -input=false
tofu validate
cd -
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 12: Commit**

```bash
cd packages/genericsuite-be-scripts
git add scripts/gcp_tf/modules/gcs-bucket scripts/gcp_tf/stacks/gcs
git commit -m "Add: GCP OpenTofu gcs-bucket module and gcs stack (chatbot attachments) [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 4: `kms-key` module + `kms` stack

**Suggested sub-agent:** sonnet

**Files:**
- Create: `BE_TF/modules/kms-key/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`
- Create: `BE_TF/stacks/kms/backend.tf`, `providers.tf`, `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`

**Interfaces:**
- Consumes: wrapper exports `TF_VAR_kms_key_ring` (default `genericsuite-keyring`), `TF_VAR_kms_key_name` (default `genericsuite-key`) plus the common vars (Task 2).
- Produces: module `kms-key` with inputs `key_ring_name (string)`, `key_name (string)`, `gcp_region (string)` and outputs `key_ring_id (string)`, `crypto_key_id (string)` — `crypto_key_id` has the form `projects/{p}/locations/{r}/keyRings/{ring}/cryptoKeys/{key}`, the exact string the `secrets` module (Task 5) expects as `kms_crypto_key_id`.

- [ ] **Step 1: Write `BE_TF/modules/kms-key/main.tf`**

```hcl
# NOTE: GCP KMS key rings can never be deleted. A `tofu destroy` only removes
# them from state; re-applying afterwards requires `tofu import` of the
# existing ring (see the Basecamp opentofu-gcp.md guide, "Migration notes").
resource "google_kms_key_ring" "this" {
  name     = var.key_ring_name
  location = var.gcp_region
}

resource "google_kms_crypto_key" "this" {
  name            = var.key_name
  key_ring        = google_kms_key_ring.this.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days
}
```

- [ ] **Step 2: Write `BE_TF/modules/kms-key/variables.tf`**

```hcl
variable "key_ring_name" {
  description = "Cloud KMS key ring name"
  type        = string
  default     = "genericsuite-keyring"
}

variable "key_name" {
  description = "Cloud KMS crypto key name"
  type        = string
  default     = "genericsuite-key"
}

variable "gcp_region" {
  description = "GCP region (key ring location)"
  type        = string
}
```

- [ ] **Step 3: Write `BE_TF/modules/kms-key/outputs.tf`**

```hcl
output "key_ring_id" {
  description = "Key ring resource id"
  value       = google_kms_key_ring.this.id
}

output "crypto_key_id" {
  description = "Crypto key resource id (projects/.../cryptoKeys/...)"
  value       = google_kms_crypto_key.this.id
}
```

- [ ] **Step 4: Write `BE_TF/modules/kms-key/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 5: Write `BE_TF/stacks/kms/backend.tf`**

```hcl
terraform {
  backend "gcs" {}
}
```

- [ ] **Step 6: Write `BE_TF/stacks/kms/providers.tf`**

```hcl
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region

  default_labels = {
    app        = var.app_name
    stage      = var.stage
    managed_by = "opentofu"
    ticket     = "gs-40"
  }
}
```

- [ ] **Step 7: Write `BE_TF/stacks/kms/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 8: Write `BE_TF/stacks/kms/variables.tf`**

```hcl
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "kms_key_ring" {
  description = "Cloud KMS key ring name"
  type        = string
  default     = "genericsuite-keyring"
}

variable "kms_key_name" {
  description = "Cloud KMS crypto key name"
  type        = string
  default     = "genericsuite-key"
}
```

- [ ] **Step 9: Write `BE_TF/stacks/kms/main.tf`**

```hcl
module "kms_key" {
  source = "../../modules/kms-key"

  key_ring_name = var.kms_key_ring
  key_name      = var.kms_key_name
  gcp_region    = var.gcp_region
}
```

- [ ] **Step 10: Write `BE_TF/stacks/kms/outputs.tf`**

```hcl
output "key_ring_id" {
  description = "Key ring resource id"
  value       = module.kms_key.key_ring_id
}

output "crypto_key_id" {
  description = "Crypto key resource id"
  value       = module.kms_key.crypto_key_id
}
```

- [ ] **Step 11: Format and validate**

Run:
```bash
tofu fmt -recursive packages/genericsuite-be-scripts/scripts/gcp_tf
cd packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/kms
tofu init -backend=false -input=false
tofu validate
cd -
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 12: Commit**

```bash
cd packages/genericsuite-be-scripts
git add scripts/gcp_tf/modules/kms-key scripts/gcp_tf/stacks/kms
git commit -m "Add: GCP OpenTofu kms-key module and kms stack (Cloud KMS ring + rotated crypto key) [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 5: `secrets` module + `secrets` stack (Secret Manager + CMEK)

**Suggested sub-agent:** sonnet

**Files:**
- Create: `BE_TF/modules/secrets/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`
- Create: `BE_TF/stacks/secrets/backend.tf`, `providers.tf`, `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `build-tfvars.sh`

**Interfaces:**
- Consumes: `TF_VAR_kms_key_ring`/`TF_VAR_kms_key_name` (Task 2 wrapper) to build the crypto key id `projects/{p}/locations/{r}/keyRings/{ring}/cryptoKeys/{key}` (format produced by Task 4). The `kms` stack must be applied before this one at deploy time (documented; not enforced here).
- Produces: Secret Manager secrets named `{app_name}-{stage}-secrets` (CMEK) and `{app_name}-{stage}-envs` (Google-managed encryption), each holding a JSON object payload. Stack outputs `secrets_secret_id`, `envs_secret_id`. Tasks 7 and 8 grant per-secret accessor roles using the secret ids `"${var.app_name}-${var.stage}-secrets"` / `"...-envs"`.

- [ ] **Step 1: Write `BE_TF/modules/secrets/main.tf`**

```hcl
locals {
  use_cmek = var.kms_crypto_key_id != ""
}

# Allow the Secret Manager service agent to use the CMEK key
resource "google_kms_crypto_key_iam_member" "sm_agent" {
  count         = local.use_cmek ? 1 : 0
  crypto_key_id = var.kms_crypto_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${var.sm_service_agent_email}"
}

resource "google_secret_manager_secret" "encrypted" {
  secret_id = "${var.app_name}-${var.stage}-secrets"

  labels = {
    app     = var.app_name
    stage   = var.stage
    content = "encrypted-secrets"
  }

  dynamic "replication" {
    for_each = local.use_cmek ? [1] : []
    content {
      user_managed {
        replicas {
          location = var.gcp_region
          customer_managed_encryption {
            kms_key_name = var.kms_crypto_key_id
          }
        }
      }
    }
  }

  dynamic "replication" {
    for_each = local.use_cmek ? [] : [1]
    content {
      auto {}
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.sm_agent]
}

resource "google_secret_manager_secret_version" "encrypted" {
  secret      = google_secret_manager_secret.encrypted.id
  secret_data = jsonencode(var.secrets_map)
}

resource "google_secret_manager_secret" "envs" {
  secret_id = "${var.app_name}-${var.stage}-envs"

  labels = {
    app     = var.app_name
    stage   = var.stage
    content = "environment-variables"
  }

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "envs" {
  secret      = google_secret_manager_secret.envs.id
  secret_data = jsonencode(var.envs_map)
}
```

- [ ] **Step 2: Write `BE_TF/modules/secrets/variables.tf`**

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "gcp_region" {
  description = "GCP region (replica location when CMEK is used)"
  type        = string
}

variable "secrets_map" {
  description = "Encrypted secrets key/value map (stored as one JSON payload)"
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "envs_map" {
  description = "Plain environment variables key/value map (stored as one JSON payload)"
  type        = map(string)
  default     = {}
}

variable "kms_crypto_key_id" {
  description = "Cloud KMS crypto key id for CMEK; empty uses Google-managed encryption"
  type        = string
  default     = ""
}

variable "sm_service_agent_email" {
  description = "Secret Manager service agent email (service-{project_number}@gcp-sa-secretmanager.iam.gserviceaccount.com); required when kms_crypto_key_id is set"
  type        = string
  default     = ""
}
```

- [ ] **Step 3: Write `BE_TF/modules/secrets/outputs.tf`**

```hcl
output "secrets_secret_id" {
  description = "Encrypted secrets resource id"
  value       = google_secret_manager_secret.encrypted.id
}

output "envs_secret_id" {
  description = "Envvars secret resource id"
  value       = google_secret_manager_secret.envs.id
}
```

- [ ] **Step 4: Write `BE_TF/modules/secrets/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 5: Write `BE_TF/stacks/secrets/backend.tf`**

```hcl
terraform {
  backend "gcs" {}
}
```

- [ ] **Step 6: Write `BE_TF/stacks/secrets/providers.tf`**

```hcl
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region

  default_labels = {
    app        = var.app_name
    stage      = var.stage
    managed_by = "opentofu"
    ticket     = "gs-40"
  }
}
```

- [ ] **Step 7: Write `BE_TF/stacks/secrets/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 8: Write `BE_TF/stacks/secrets/variables.tf`**

```hcl
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "kms_key_ring" {
  description = "Cloud KMS key ring name (must exist: apply the kms stack first)"
  type        = string
  default     = "genericsuite-keyring"
}

variable "kms_key_name" {
  description = "Cloud KMS crypto key name"
  type        = string
  default     = "genericsuite-key"
}

variable "enable_cmek" {
  description = "Encrypt {app}-{stage}-secrets with the Cloud KMS key"
  type        = bool
  default     = true
}

variable "secrets_map" {
  description = "Encrypted secrets key/value map"
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "envs_map" {
  description = "Plain environment variables key/value map"
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 9: Write `BE_TF/stacks/secrets/main.tf`**

```hcl
data "google_project" "this" {}

locals {
  kms_crypto_key_id      = var.enable_cmek ? "projects/${var.gcp_project_id}/locations/${var.gcp_region}/keyRings/${var.kms_key_ring}/cryptoKeys/${var.kms_key_name}" : ""
  sm_service_agent_email = "service-${data.google_project.this.number}@gcp-sa-secretmanager.iam.gserviceaccount.com"
}

module "secrets" {
  source = "../../modules/secrets"

  app_name               = var.app_name
  stage                  = var.stage
  gcp_region             = var.gcp_region
  secrets_map            = var.secrets_map
  envs_map               = var.envs_map
  kms_crypto_key_id      = local.kms_crypto_key_id
  sm_service_agent_email = local.sm_service_agent_email
}
```

- [ ] **Step 10: Write `BE_TF/stacks/secrets/outputs.tf`**

```hcl
output "secrets_secret_id" {
  description = "Encrypted secrets resource id"
  value       = module.secrets.secrets_secret_id
}

output "envs_secret_id" {
  description = "Envvars secret resource id"
  value       = module.secrets.envs_secret_id
}
```

- [ ] **Step 11: Write `BE_TF/stacks/secrets/build-tfvars.sh`**

This mirrors `scripts/aws_tf/stacks/secrets/build-tfvars.sh` with GCP-specific env lists. It is sourced by `run-tf-deployment.sh` (which defines `REPO_BASEDIR`, `STAGE`, `STAGE_UPPERCASE`, `APP_NAME_LOWERCASE`, `GCP_PROJECT_ID`, `GCP_REGION`).

```bash
#!/bin/bash
# stacks/secrets/build-tfvars.sh
# Sourced by run-tf-deployment.sh. Builds TF_VAR_secrets_map and
# TF_VAR_envs_map as JSON from the same variable lists used by
# scripts/aws_secrets/aws_secrets_manager.sh, adjusted for GCP.
# Also creates the Secret Manager service identity (needed for CMEK).
# 2026-07-19 | CR [GS-40]

# Ensure the Secret Manager service agent exists (idempotent; needed for CMEK)
gcloud beta services identity create --service=secretmanager.googleapis.com \
    --project="${GCP_PROJECT_ID}" >/dev/null 2>&1 || true

# Secrets (encrypted)
CORE_SECRETS="APP_SECRET_KEY APP_SUPERADMIN_EMAIL APP_DB_URI SMTP_USER SMTP_PASSWORD SMTP_DEFAULT_SENDER STORAGE_URL_SEED"
EXTENSION_SECRETS="OPENAI_API_KEY GOOGLE_API_KEY GOOGLE_CSE_ID GOOGLE_MAPS_API_KEY \
    ANTHROPIC_API_KEY LANGCHAIN_API_KEY HUGGINGFACE_API_KEY GROQ_API_KEY AIMLAPI_API_KEY \
    NVIDIA_API_KEY RHYMES_CHAT_API_KEY RHYMES_VIDEO_API_KEY IBM_WATSONX_API_KEY \
    IBM_WATSONX_PROJECT_ID OPENROUTER_API_KEY XAI_API_KEY TOGETHER_API_KEY"
APP_SECRETS="${APP_SECRETS:-}"

# Environment variables (plain)
CORE_ENVS="APP_NAME FLASK_APP APP_DEBUG APP_STAGE APP_CORS_ORIGIN APP_DB_ENGINE APP_DB_NAME CURRENT_FRAMEWORK DEFAULT_LANG GIT_SUBMODULE_URL GIT_SUBMODULE_LOCAL_PATH SMTP_SERVER SMTP_PORT SMTP_DEFAULT_SENDER APP_HOST_NAME CLOUD_PROVIDER GCP_PROJECT_ID GCP_REGION"
EXTENSION_ENVS="AI_ASSISTANT_NAME GCP_CHATBOT_ATTACHMENTS_BUCKET OPENAI_MODEL OPENAI_TEMPERATURE LANGCHAIN_PROJECT USER_AGENT HUGGINGFACE_DEFAULT_CHAT_MODEL"
APP_ENVS="${APP_ENVS:-}"

# App-specific additions hook (same contract as the AWS paths)
if [ -f "${REPO_BASEDIR}/scripts/aws/update_additional_envvars.sh" ]; then
    # shellcheck disable=SC1091
    . "${REPO_BASEDIR}/scripts/aws/update_additional_envvars.sh" "" "${REPO_BASEDIR}"
fi

# Resolve stage-dependent variables (VAR = VAR_${STAGE_UPPERCASE})
STAGE_DEPENDENT_VAR_LIST="${STAGE_DEPENDENT_VAR_LIST:-APP_DB_ENGINE APP_DB_NAME APP_DB_URI APP_CORS_ORIGIN GCP_CHATBOT_ATTACHMENTS_BUCKET}"
for base_name in ${STAGE_DEPENDENT_VAR_LIST}; do
    resolved_varname="${base_name}_${STAGE_UPPERCASE}"
    resolved="${!resolved_varname:-}"
    if [ "${resolved}" != "" ]; then
        printf -v "${base_name}" '%s' "${resolved}"
        export "${base_name}"
    fi
done

# Special envvars not in .env
export APP_STAGE="${STAGE}"
export USER_AGENT="${APP_NAME_LOWERCASE}-${STAGE}"
export CLOUD_PROVIDER="${CLOUD_PROVIDER:-gcp}"
APP_HOST_NAME="$(echo "${GCP_API_DOMAIN_NAME:-}" | perl -pe "s/\[STAGE\]/${STAGE}/g")"
export APP_HOST_NAME
if [ "${STAGE_UPPERCASE}" = "QA" ] && [ "${APP_CORS_ORIGIN_QA_CLOUD:-}" != "" ]; then
    export APP_CORS_ORIGIN="${APP_CORS_ORIGIN_QA_CLOUD}"
fi

# Build a JSON object {"VAR":"value",...} from a list of variable names
build_json_map() {
    local names="$1"
    local json="{}"
    local name value
    for name in ${names}; do
        value="${!name:-}"
        json="$(echo "${json}" | jq --arg k "${name}" --arg v "${value}" '. + {($k): $v}')"
    done
    echo "${json}"
}

TF_VAR_secrets_map="$(build_json_map "${CORE_SECRETS} ${EXTENSION_SECRETS} ${APP_SECRETS}")"
TF_VAR_envs_map="$(build_json_map "${CORE_ENVS} ${EXTENSION_ENVS} ${APP_ENVS}")"
export TF_VAR_secrets_map TF_VAR_envs_map

echo "Secrets/envs TF_VAR maps built ($(echo "${TF_VAR_envs_map}" | jq 'length') envs, $(echo "${TF_VAR_secrets_map}" | jq 'length') secrets)."
```

- [ ] **Step 12: Format and validate**

Run:
```bash
bash -n packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/secrets/build-tfvars.sh
tofu fmt -recursive packages/genericsuite-be-scripts/scripts/gcp_tf
cd packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/secrets
tofu init -backend=false -input=false
tofu validate
cd -
```
Expected: `Success! The configuration is valid.` (and no output from `bash -n`).

- [ ] **Step 13: Commit**

```bash
cd packages/genericsuite-be-scripts
git add scripts/gcp_tf/modules/secrets scripts/gcp_tf/stacks/secrets
git commit -m "Add: GCP OpenTofu secrets module and stack (Secret Manager with CMEK + env maps builder) [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 6: `artifact-registry` module + `ar` stack

**Suggested sub-agent:** haiku

**Files:**
- Create: `BE_TF/modules/artifact-registry/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`
- Create: `BE_TF/stacks/ar/backend.tf`, `providers.tf`, `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`

**Interfaces:**
- Consumes: common wrapper vars (Task 2).
- Produces: Docker repository named `{app_name}` at `{gcp_region}-docker.pkg.dev/{gcp_project_id}/{app_name}`. Module inputs: `repository_id (string)`, `gcp_region (string)`, `gcp_project_id (string)`, `images_to_keep (number, default 2)`. Module/stack output: `repository_url (string)` — the base URL Tasks 7/8 and `build_push_image.sh` (Task 2) build image URIs from.

- [ ] **Step 1: Write `BE_TF/modules/artifact-registry/main.tf`**

```hcl
resource "google_artifact_registry_repository" "this" {
  repository_id = var.repository_id
  location      = var.gcp_region
  format        = "DOCKER"
  description   = "GenericSuite backend images for ${var.repository_id}"

  docker_config {
    immutable_tags = false
  }

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.images_to_keep
    }
  }

  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s" # 30 days
    }
  }
}
```

- [ ] **Step 2: Write `BE_TF/modules/artifact-registry/variables.tf`**

```hcl
variable "repository_id" {
  description = "Artifact Registry repository id (lowercase)"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "images_to_keep" {
  description = "Tagged image versions to keep"
  type        = number
  default     = 2
}
```

- [ ] **Step 3: Write `BE_TF/modules/artifact-registry/outputs.tf`**

```hcl
output "repository_url" {
  description = "Docker repository base URL"
  value       = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${google_artifact_registry_repository.this.repository_id}"
}
```

- [ ] **Step 4: Write `BE_TF/modules/artifact-registry/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 5: Write `BE_TF/stacks/ar/backend.tf`**

```hcl
terraform {
  backend "gcs" {}
}
```

- [ ] **Step 6: Write `BE_TF/stacks/ar/providers.tf`**

```hcl
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region

  default_labels = {
    app        = var.app_name
    stage      = var.stage
    managed_by = "opentofu"
    ticket     = "gs-40"
  }
}
```

- [ ] **Step 7: Write `BE_TF/stacks/ar/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 8: Write `BE_TF/stacks/ar/variables.tf`**

```hcl
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "images_to_keep" {
  description = "Tagged image versions to keep"
  type        = number
  default     = 2
}
```

- [ ] **Step 9: Write `BE_TF/stacks/ar/main.tf`**

```hcl
module "artifact_registry" {
  source = "../../modules/artifact-registry"

  repository_id  = var.app_name
  gcp_region     = var.gcp_region
  gcp_project_id = var.gcp_project_id
  images_to_keep = var.images_to_keep
}
```

- [ ] **Step 10: Write `BE_TF/stacks/ar/outputs.tf`**

```hcl
output "repository_url" {
  description = "Docker repository base URL"
  value       = module.artifact_registry.repository_url
}
```

- [ ] **Step 11: Format and validate**

Run:
```bash
tofu fmt -recursive packages/genericsuite-be-scripts/scripts/gcp_tf
cd packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/ar
tofu init -backend=false -input=false
tofu validate
cd -
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 12: Commit**

```bash
cd packages/genericsuite-be-scripts
git add scripts/gcp_tf/modules/artifact-registry scripts/gcp_tf/stacks/ar
git commit -m "Add: GCP OpenTofu artifact-registry module and ar stack (Docker repo + cleanup policies) [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 7: `cloud-run-api` module + `cloudrun` stack

**Suggested sub-agent:** sonnet

**Files:**
- Create: `BE_TF/modules/cloud-run-api/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`
- Create: `BE_TF/stacks/cloudrun/backend.tf`, `providers.tf`, `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `build-tfvars.sh`

**Interfaces:**
- Consumes: wrapper exports `TF_VAR_cloud_run_service_name`, `TF_VAR_image_tag`, `TF_VAR_api_domain_name`, `TF_VAR_dns_zone_name`, `TF_VAR_chatbot_attachments_bucket_name`, `TF_VAR_container_port` (Task 2). Secrets `{app}-{stage}-secrets`/`{app}-{stage}-envs` must exist (Task 5 stack applied) — IAM grants reference them by secret id. Image must exist in the `ar` repo (Task 6 + `build_push_image.sh`).
- Produces: module `cloud-run-api` inputs: `service_name`, `app_name`, `stage`, `gcp_project_id`, `gcp_region`, `image_uri`, `container_port (number, 8080)`, `memory (string, "512Mi")`, `cpu (string, "1")`, `timeout (number, 180)`, `min_instances (0)`, `max_instances (10)`, `environment_variables (map(string), {})`, `chatbot_attachments_bucket_name (string, "")`, `allow_unauthenticated (bool, true)`, `deletion_protection (bool, false)`, `domain_name ("")`, `dns_zone_name ("")`. Outputs: `service_url`, `service_name`, `service_account_email`. Stack outputs the same.

- [ ] **Step 1: Write `BE_TF/modules/cloud-run-api/main.tf`**

```hcl
locals {
  sa_account_id     = substr(replace(var.service_name, "_", "-"), 0, 28)
  secrets_secret_id = "${var.app_name}-${var.stage}-secrets"
  envs_secret_id    = "${var.app_name}-${var.stage}-envs"
}

resource "google_service_account" "this" {
  account_id   = local.sa_account_id
  display_name = "GenericSuite Cloud Run SA for ${var.service_name}"
}

# Scoped, per-secret access (mirrors the GS-334 IAM scoping fix)
resource "google_secret_manager_secret_iam_member" "secrets" {
  secret_id = local.secrets_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this.email}"
}

resource "google_secret_manager_secret_iam_member" "envs" {
  secret_id = local.envs_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this.email}"
}

resource "google_storage_bucket_iam_member" "chatbot" {
  count  = var.chatbot_attachments_bucket_name != "" ? 1 : 0
  bucket = var.chatbot_attachments_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.this.email}"
}

resource "google_cloud_run_v2_service" "this" {
  name                = var.service_name
  location            = var.gcp_region
  deletion_protection = var.deletion_protection
  ingress             = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.this.email
    timeout         = "${var.timeout}s"

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      image = var.image_uri

      ports {
        container_port = var.container_port
      }

      resources {
        limits = {
          memory = var.memory
          cpu    = var.cpu
        }
      }

      dynamic "env" {
        for_each = var.environment_variables
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "invoker" {
  count    = var.allow_unauthenticated ? 1 : 0
  location = google_cloud_run_v2_service.this.location
  name     = google_cloud_run_v2_service.this.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Custom domain (use a subdomain, e.g. app-qa.example.com)
resource "google_cloud_run_domain_mapping" "this" {
  count    = var.domain_name != "" ? 1 : 0
  location = var.gcp_region
  name     = var.domain_name

  metadata {
    namespace = var.gcp_project_id
  }

  spec {
    route_name = google_cloud_run_v2_service.this.name
  }
}

resource "google_dns_record_set" "cname" {
  count        = var.domain_name != "" && var.dns_zone_name != "" ? 1 : 0
  managed_zone = var.dns_zone_name
  name         = "${var.domain_name}."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["ghs.googlehosted.com."]
}
```

- [ ] **Step 2: Write `BE_TF/modules/cloud-run-api/variables.tf`**

```hcl
variable "service_name" {
  description = "Cloud Run service name (e.g. myapp-backend-qa)"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "image_uri" {
  description = "Artifact Registry image URI with tag"
  type        = string
}

variable "container_port" {
  description = "Container listen port"
  type        = number
  default     = 8080
}

variable "memory" {
  description = "Memory limit (Cloud Run format, e.g. 512Mi)"
  type        = string
  default     = "512Mi"
}

variable "cpu" {
  description = "CPU limit"
  type        = string
  default     = "1"
}

variable "timeout" {
  description = "Request timeout (seconds)"
  type        = number
  default     = 180
}

variable "min_instances" {
  description = "Minimum instances"
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Maximum instances"
  type        = number
  default     = 10
}

variable "environment_variables" {
  description = "Container environment variables"
  type        = map(string)
  default     = {}
}

variable "chatbot_attachments_bucket_name" {
  description = "GCS bucket the service can read/write; empty skips the grant"
  type        = string
  default     = ""
}

variable "allow_unauthenticated" {
  description = "Allow public (unauthenticated) invocations"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Protect the service from tofu destroy"
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Custom API domain (subdomain); empty disables the custom domain"
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name for the CNAME record; empty skips the record"
  type        = string
  default     = ""
}
```

- [ ] **Step 3: Write `BE_TF/modules/cloud-run-api/outputs.tf`**

```hcl
output "service_url" {
  description = "Cloud Run service URL"
  value       = google_cloud_run_v2_service.this.uri
}

output "service_name" {
  description = "Cloud Run service name"
  value       = google_cloud_run_v2_service.this.name
}

output "service_account_email" {
  description = "Runtime service account email"
  value       = google_service_account.this.email
}
```

- [ ] **Step 4: Write `BE_TF/modules/cloud-run-api/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 5: Write `BE_TF/stacks/cloudrun/backend.tf`**

```hcl
terraform {
  backend "gcs" {}
}
```

- [ ] **Step 6: Write `BE_TF/stacks/cloudrun/providers.tf`**

```hcl
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region

  default_labels = {
    app        = var.app_name
    stage      = var.stage
    managed_by = "opentofu"
    ticket     = "gs-40"
  }
}
```

- [ ] **Step 7: Write `BE_TF/stacks/cloudrun/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 8: Write `BE_TF/stacks/cloudrun/variables.tf`**

```hcl
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "cloud_run_service_name" {
  description = "Cloud Run service name (e.g. myapp-backend-qa)"
  type        = string
}

variable "image_tag" {
  description = "Docker image tag"
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Container listen port"
  type        = number
  default     = 8080
}

variable "environment_variables" {
  description = "Container environment variables"
  type        = map(string)
  default     = {}
}

variable "chatbot_attachments_bucket_name" {
  description = "GCS bucket the service can read/write"
  type        = string
  default     = ""
}

variable "api_domain_name" {
  description = "Custom API domain (subdomain); empty disables it"
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name; empty skips the DNS record"
  type        = string
  default     = ""
}
```

- [ ] **Step 9: Write `BE_TF/stacks/cloudrun/main.tf`**

```hcl
module "cloud_run_api" {
  source = "../../modules/cloud-run-api"

  service_name                    = var.cloud_run_service_name
  app_name                        = var.app_name
  stage                           = var.stage
  gcp_project_id                  = var.gcp_project_id
  gcp_region                      = var.gcp_region
  image_uri                       = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.app_name}/${var.cloud_run_service_name}:${var.image_tag}"
  container_port                  = var.container_port
  environment_variables           = var.environment_variables
  chatbot_attachments_bucket_name = var.chatbot_attachments_bucket_name
  domain_name                     = var.api_domain_name
  dns_zone_name                   = var.dns_zone_name
}
```

- [ ] **Step 10: Write `BE_TF/stacks/cloudrun/outputs.tf`**

```hcl
output "service_url" {
  description = "Cloud Run service URL"
  value       = module.cloud_run_api.service_url
}

output "service_name" {
  description = "Cloud Run service name"
  value       = module.cloud_run_api.service_name
}

output "service_account_email" {
  description = "Runtime service account email"
  value       = module.cloud_run_api.service_account_email
}
```

- [ ] **Step 11: Write `BE_TF/stacks/cloudrun/build-tfvars.sh`**

Sourced by `run-tf-deployment.sh` (which defines `APP_NAME`, `STAGE`, `APP_NAME_LOWERCASE`, `GCP_PROJECT_ID`, `GCP_REGION`). Builds the minimal runtime env vars the container needs to locate its Secret Manager payloads.

```bash
#!/bin/bash
# stacks/cloudrun/build-tfvars.sh
# Sourced by run-tf-deployment.sh. Builds TF_VAR_environment_variables with
# the minimal runtime settings the backend container needs on GCP.
# 2026-07-19 | CR [GS-40]

TF_VAR_environment_variables="$(jq -n \
    --arg app_name "${APP_NAME}" \
    --arg app_name_lc "${APP_NAME_LOWERCASE}" \
    --arg stage "${STAGE}" \
    --arg project "${GCP_PROJECT_ID}" \
    --arg region "${GCP_REGION}" \
    '{
        APP_NAME: $app_name,
        APP_STAGE: $stage,
        CLOUD_PROVIDER: "gcp",
        GCP_PROJECT_ID: $project,
        GCP_REGION: $region,
        APP_SECRETS_NAME: ($app_name_lc + "-" + $stage + "-secrets"),
        APP_ENVS_NAME: ($app_name_lc + "-" + $stage + "-envs")
    }')"
export TF_VAR_environment_variables

echo "Cloud Run TF_VAR_environment_variables built ($(echo "${TF_VAR_environment_variables}" | jq 'length') vars)."
```

- [ ] **Step 12: Format and validate**

Run:
```bash
bash -n packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/cloudrun/build-tfvars.sh
tofu fmt -recursive packages/genericsuite-be-scripts/scripts/gcp_tf
cd packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/cloudrun
tofu init -backend=false -input=false
tofu validate
cd -
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 13: Commit**

```bash
cd packages/genericsuite-be-scripts
git add scripts/gcp_tf/modules/cloud-run-api scripts/gcp_tf/stacks/cloudrun
git commit -m "Add: GCP OpenTofu cloud-run-api module and cloudrun stack (Cloud Run v2 + scoped SA + domain mapping) [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 8: `gce-lb` module + `gce` stack

**Suggested sub-agent:** sonnet

**Files:**
- Create: `BE_TF/modules/gce-lb/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`
- Create: `BE_TF/stacks/gce/backend.tf`, `providers.tf`, `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `build-tfvars.sh`

**Interfaces:**
- Consumes: wrapper exports `TF_VAR_cloud_run_service_name` (reused as the image/service base name), `TF_VAR_image_tag`, `TF_VAR_machine_type`, `TF_VAR_container_port`, `TF_VAR_api_domain_name`, `TF_VAR_dns_zone_name`, `TF_VAR_chatbot_attachments_bucket_name` (Task 2); secrets from Task 5; image in the Task 6 repo.
- Produces: module `gce-lb` inputs: `app_name`, `stage`, `gcp_project_id`, `gcp_region`, `gcp_zone ("")` (defaults to `{region}-a`), `machine_type ("e2-small")`, `image_uri`, `container_port (8080)`, `environment_variables ({})`, `chatbot_attachments_bucket_name ("")`, `network ("default")`, `domain_name ("")`, `dns_zone_name ("")`, `health_check_path ("/")`. Outputs: `instance_name`, `lb_ip_address`, `url`.

- [ ] **Step 1: Write `BE_TF/modules/gce-lb/main.tf`**

```hcl
data "google_compute_image" "cos" {
  family  = "cos-stable"
  project = "cos-cloud"
}

locals {
  name_prefix       = "${var.app_name}-${var.stage}"
  sa_account_id     = substr(replace("${var.app_name}-${var.stage}-gce", "_", "-"), 0, 28)
  zone              = var.gcp_zone != "" ? var.gcp_zone : "${var.gcp_region}-a"
  secrets_secret_id = "${var.app_name}-${var.stage}-secrets"
  envs_secret_id    = "${var.app_name}-${var.stage}-envs"
  use_domain        = var.domain_name != ""
}

resource "google_service_account" "this" {
  account_id   = local.sa_account_id
  display_name = "GenericSuite GCE SA for ${local.name_prefix}"
}

resource "google_secret_manager_secret_iam_member" "secrets" {
  secret_id = local.secrets_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this.email}"
}

resource "google_secret_manager_secret_iam_member" "envs" {
  secret_id = local.envs_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this.email}"
}

resource "google_storage_bucket_iam_member" "chatbot" {
  count  = var.chatbot_attachments_bucket_name != "" ? 1 : 0
  bucket = var.chatbot_attachments_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.this.email}"
}

resource "google_project_iam_member" "logging" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.this.email}"
}

resource "google_project_iam_member" "monitoring" {
  project = var.gcp_project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.this.email}"
}

# Load balancer / health check ranges -> app port
resource "google_compute_firewall" "health_check" {
  name    = "${local.name_prefix}-allow-hc"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = [tostring(var.container_port)]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["${local.name_prefix}-be"]
}

# SSH only through IAP (no public port 22)
resource "google_compute_firewall" "iap_ssh" {
  name    = "${local.name_prefix}-allow-iap-ssh"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${local.name_prefix}-be"]
}

resource "google_compute_instance" "this" {
  name         = "${local.name_prefix}-instance"
  machine_type = var.machine_type
  zone         = local.zone
  tags         = ["${local.name_prefix}-be"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.cos.self_link
      size  = 20
    }
  }

  network_interface {
    network = var.network
    access_config {}
  }

  metadata = {
    gce-container-declaration = yamlencode({
      spec = {
        containers = [{
          name  = "${local.name_prefix}-app"
          image = var.image_uri
          env   = [for k, v in var.environment_variables : { name = k, value = v }]
          stdin = false
          tty   = false
        }]
        restartPolicy = "Always"
      }
    })
    google-logging-enabled = "true"
  }

  service_account {
    email  = google_service_account.this.email
    scopes = ["cloud-platform"]
  }

  labels = {
    app   = var.app_name
    stage = var.stage
  }
}

resource "google_compute_instance_group" "this" {
  name      = "${local.name_prefix}-ig"
  zone      = local.zone
  instances = [google_compute_instance.this.self_link]

  named_port {
    name = "http"
    port = var.container_port
  }
}

resource "google_compute_health_check" "this" {
  name = "${local.name_prefix}-hc"

  http_health_check {
    port         = var.container_port
    request_path = var.health_check_path
  }
}

resource "google_compute_backend_service" "this" {
  name          = "${local.name_prefix}-backend"
  protocol      = "HTTP"
  port_name     = "http"
  timeout_sec   = 60
  health_checks = [google_compute_health_check.this.id]

  backend {
    group = google_compute_instance_group.this.id
  }
}

resource "google_compute_url_map" "this" {
  name            = "${local.name_prefix}-url-map"
  default_service = google_compute_backend_service.this.id
}

resource "google_compute_managed_ssl_certificate" "this" {
  count = local.use_domain ? 1 : 0
  name  = "${local.name_prefix}-cert"

  managed {
    domains = [var.domain_name]
  }
}

resource "google_compute_target_https_proxy" "this" {
  count            = local.use_domain ? 1 : 0
  name             = "${local.name_prefix}-https-proxy"
  url_map          = google_compute_url_map.this.id
  ssl_certificates = [google_compute_managed_ssl_certificate.this[0].id]
}

resource "google_compute_url_map" "redirect" {
  count = local.use_domain ? 1 : 0
  name  = "${local.name_prefix}-https-redirect"

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "this" {
  name    = "${local.name_prefix}-http-proxy"
  url_map = local.use_domain ? google_compute_url_map.redirect[0].id : google_compute_url_map.this.id
}

resource "google_compute_global_address" "this" {
  name = "${local.name_prefix}-lb-ip"
}

resource "google_compute_global_forwarding_rule" "https" {
  count      = local.use_domain ? 1 : 0
  name       = "${local.name_prefix}-https-fr"
  target     = google_compute_target_https_proxy.this[0].id
  port_range = "443"
  ip_address = google_compute_global_address.this.address
}

resource "google_compute_global_forwarding_rule" "http" {
  name       = "${local.name_prefix}-http-fr"
  target     = google_compute_target_http_proxy.this.id
  port_range = "80"
  ip_address = google_compute_global_address.this.address
}

resource "google_dns_record_set" "a" {
  count        = local.use_domain && var.dns_zone_name != "" ? 1 : 0
  managed_zone = var.dns_zone_name
  name         = "${var.domain_name}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.this.address]
}
```

- [ ] **Step 2: Write `BE_TF/modules/gce-lb/variables.tf`**

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "gcp_zone" {
  description = "GCP zone; empty defaults to {region}-a"
  type        = string
  default     = ""
}

variable "machine_type" {
  description = "GCE machine type"
  type        = string
  default     = "e2-small"
}

variable "image_uri" {
  description = "Artifact Registry image URI with tag"
  type        = string
}

variable "container_port" {
  description = "Container listen port"
  type        = number
  default     = 8080
}

variable "environment_variables" {
  description = "Container environment variables"
  type        = map(string)
  default     = {}
}

variable "chatbot_attachments_bucket_name" {
  description = "GCS bucket the instance can read/write; empty skips the grant"
  type        = string
  default     = ""
}

variable "network" {
  description = "VPC network name"
  type        = string
  default     = "default"
}

variable "domain_name" {
  description = "Custom domain for the load balancer; empty disables HTTPS"
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name for the A record; empty skips the record"
  type        = string
  default     = ""
}

variable "health_check_path" {
  description = "HTTP health check request path"
  type        = string
  default     = "/"
}
```

- [ ] **Step 3: Write `BE_TF/modules/gce-lb/outputs.tf`**

```hcl
output "instance_name" {
  description = "GCE instance name"
  value       = google_compute_instance.this.name
}

output "lb_ip_address" {
  description = "Global load balancer IP address"
  value       = google_compute_global_address.this.address
}

output "url" {
  description = "Application URL"
  value       = local.use_domain ? "https://${var.domain_name}" : "http://${google_compute_global_address.this.address}"
}
```

- [ ] **Step 4: Write `BE_TF/modules/gce-lb/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 5: Write `BE_TF/stacks/gce/backend.tf`**

```hcl
terraform {
  backend "gcs" {}
}
```

- [ ] **Step 6: Write `BE_TF/stacks/gce/providers.tf`**

```hcl
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region

  default_labels = {
    app        = var.app_name
    stage      = var.stage
    managed_by = "opentofu"
    ticket     = "gs-40"
  }
}
```

- [ ] **Step 7: Write `BE_TF/stacks/gce/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 8: Write `BE_TF/stacks/gce/variables.tf`**

```hcl
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

# Reuses the wrapper's TF_VAR_cloud_run_service_name as image/base name
variable "cloud_run_service_name" {
  description = "Service base name used for the container image (e.g. myapp-backend-qa)"
  type        = string
}

variable "image_tag" {
  description = "Docker image tag"
  type        = string
  default     = "latest"
}

variable "machine_type" {
  description = "GCE machine type"
  type        = string
  default     = "e2-small"
}

variable "container_port" {
  description = "Container listen port"
  type        = number
  default     = 8080
}

variable "environment_variables" {
  description = "Container environment variables"
  type        = map(string)
  default     = {}
}

variable "chatbot_attachments_bucket_name" {
  description = "GCS bucket the instance can read/write"
  type        = string
  default     = ""
}

variable "api_domain_name" {
  description = "Custom domain for the load balancer; empty disables HTTPS"
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name; empty skips the DNS record"
  type        = string
  default     = ""
}
```

- [ ] **Step 9: Write `BE_TF/stacks/gce/main.tf`**

```hcl
module "gce_lb" {
  source = "../../modules/gce-lb"

  app_name                        = var.app_name
  stage                           = var.stage
  gcp_project_id                  = var.gcp_project_id
  gcp_region                      = var.gcp_region
  machine_type                    = var.machine_type
  image_uri                       = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.app_name}/${var.cloud_run_service_name}:${var.image_tag}"
  container_port                  = var.container_port
  environment_variables           = var.environment_variables
  chatbot_attachments_bucket_name = var.chatbot_attachments_bucket_name
  domain_name                     = var.api_domain_name
  dns_zone_name                   = var.dns_zone_name
}
```

- [ ] **Step 10: Write `BE_TF/stacks/gce/outputs.tf`**

```hcl
output "instance_name" {
  description = "GCE instance name"
  value       = module.gce_lb.instance_name
}

output "lb_ip_address" {
  description = "Global load balancer IP address"
  value       = module.gce_lb.lb_ip_address
}

output "url" {
  description = "Application URL"
  value       = module.gce_lb.url
}
```

- [ ] **Step 11: Write `BE_TF/stacks/gce/build-tfvars.sh`**

```bash
#!/bin/bash
# stacks/gce/build-tfvars.sh
# Sourced by run-tf-deployment.sh. Builds TF_VAR_environment_variables with
# the minimal runtime settings the backend container needs on GCP.
# 2026-07-19 | CR [GS-40]

TF_VAR_environment_variables="$(jq -n \
    --arg app_name "${APP_NAME}" \
    --arg app_name_lc "${APP_NAME_LOWERCASE}" \
    --arg stage "${STAGE}" \
    --arg project "${GCP_PROJECT_ID}" \
    --arg region "${GCP_REGION}" \
    '{
        APP_NAME: $app_name,
        APP_STAGE: $stage,
        CLOUD_PROVIDER: "gcp",
        GCP_PROJECT_ID: $project,
        GCP_REGION: $region,
        APP_SECRETS_NAME: ($app_name_lc + "-" + $stage + "-secrets"),
        APP_ENVS_NAME: ($app_name_lc + "-" + $stage + "-envs")
    }')"
export TF_VAR_environment_variables

echo "GCE TF_VAR_environment_variables built ($(echo "${TF_VAR_environment_variables}" | jq 'length') vars)."
```

- [ ] **Step 12: Format and validate**

Run:
```bash
bash -n packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/gce/build-tfvars.sh
tofu fmt -recursive packages/genericsuite-be-scripts/scripts/gcp_tf
cd packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/gce
tofu init -backend=false -input=false
tofu validate
cd -
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 13: Commit**

```bash
cd packages/genericsuite-be-scripts
git add scripts/gcp_tf/modules/gce-lb scripts/gcp_tf/stacks/gce
git commit -m "Add: GCP OpenTofu gce-lb module and gce stack (COS container + global HTTPS LB + IAP SSH) [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 9: Backend-scripts CHANGELOG + full validation sweep

**Suggested sub-agent:** haiku

**Files:**
- Modify: `packages/genericsuite-be-scripts/CHANGELOG.md` (the `## [Unreleased]` → `### Added` section at the top)

**Interfaces:**
- Consumes: everything from Tasks 2–8 present and committed.
- Produces: changelog entry with `[GS-40]`; all BE stacks proven valid.

- [ ] **Step 1: Add the CHANGELOG entry**

In `packages/genericsuite-be-scripts/CHANGELOG.md`, under `## [Unreleased] - YYYY-MM-DD` → `### Added` (currently empty), add this bullet:

```markdown
- OpenTofu (Terraform-compatible) IaC deployments for Google Cloud Platform in `scripts/gcp_tf`: generic wrapper (`run-tf-deployment.sh`), GCS remote state with native locking and GCP API enablement (`bootstrap-tf-state.sh`), Artifact Registry Docker build/push helper (`build_push_image.sh`), and modules/stacks for GCS buckets, Cloud KMS, Secret Manager (CMEK), Artifact Registry, Cloud Run, and GCE + global HTTPS Load Balancer — mirroring the AWS `scripts/aws_tf` layout, which remains unchanged [GS-40].
```

- [ ] **Step 2: Full BE validation sweep**

Run:
```bash
tofu fmt -check -recursive packages/genericsuite-be-scripts/scripts/gcp_tf
for stack in gcs kms secrets ar cloudrun gce; do
  echo "=== ${stack} ==="
  ( cd "packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/${stack}" \
    && tofu init -backend=false -input=false >/dev/null \
    && tofu validate )
done
for f in packages/genericsuite-be-scripts/scripts/gcp_tf/*.sh packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/*/build-tfvars.sh; do
  bash -n "$f"
done
```
Expected: `fmt -check` prints nothing; each stack prints `Success! The configuration is valid.`; `bash -n` prints nothing.

- [ ] **Step 3: Confirm the AWS path is untouched**

Run: `cd packages/genericsuite-be-scripts && git status --porcelain scripts/aws_tf scripts/aws scripts/aws_big_lambda scripts/aws_cf_processor scripts/aws_domains scripts/aws_dynamodb scripts/aws_ec2_elb scripts/aws_secrets && cd ../..`
Expected: no output (nothing modified).

- [ ] **Step 4: Commit**

```bash
cd packages/genericsuite-be-scripts
git add CHANGELOG.md
git commit -m "Change: CHANGELOG entry for GCP OpenTofu IaC deployments [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 10: Frontend-scripts state bootstrap + generic wrapper

**Suggested sub-agent:** sonnet

**Files:**
- Create: `FE_TF/bootstrap-tf-state.sh`
- Create: `FE_TF/run-tf-deployment.sh`

**Interfaces:**
- Consumes: consuming app `.env` (`APP_NAME`, `GCP_REGION`, optional `GCP_PROJECT_ID`, `GCP_BUCKET_NAME_FE` — falls back to `AWS_S3_BUCKET_NAME_FE`, supports `[STAGE]` token —, `APP_FE_URL`, `GCP_DNS_ZONE_NAME`; `VARIABLE_TYPE` env selects a different prefix, e.g. `WS`).
- Produces:
  - `bootstrap-tf-state.sh BUCKET PROJECT REGION` — idempotent state bucket creation + FE API enablement.
  - `run-tf-deployment.sh ACTION STAGE STACK [EXTRA...]` — exports `TF_VAR_app_name`, `TF_VAR_stage`, `TF_VAR_gcp_project_id`, `TF_VAR_gcp_region`, `TF_VAR_bucket_name`, `TF_VAR_domain_name` (host only, no scheme), `TF_VAR_dns_zone_name`.

- [ ] **Step 1: Write `FE_TF/bootstrap-tf-state.sh`**

```bash
#!/bin/bash
# scripts/gcp_tf/bootstrap-tf-state.sh
# Create/verify the GCS bucket that stores OpenTofu remote state, and enable
# the GCP APIs required by the GenericSuite frontend stack.
# GCP counterpart of scripts/aws_tf/bootstrap-tf-state.sh.
# 2026-07-19 | CR [GS-40]
# Usage: bash scripts/gcp_tf/bootstrap-tf-state.sh BUCKET_NAME GCP_PROJECT_ID GCP_REGION
set -euo pipefail

BUCKET_NAME="${1:-}"
GCP_PROJECT_ID="${2:-}"
GCP_REGION="${3:-}"

if [ "${BUCKET_NAME}" = "" ] || [ "${GCP_PROJECT_ID}" = "" ] || [ "${GCP_REGION}" = "" ]; then
    echo "Usage: $0 BUCKET_NAME GCP_PROJECT_ID GCP_REGION"
    exit 1
fi

# Enable the APIs used by the GenericSuite frontend stack (idempotent)
gcloud services enable \
    storage.googleapis.com \
    compute.googleapis.com \
    dns.googleapis.com \
    --project "${GCP_PROJECT_ID}"

if gcloud storage buckets describe "gs://${BUCKET_NAME}" --project "${GCP_PROJECT_ID}" >/dev/null 2>&1; then
    echo "TF state bucket 'gs://${BUCKET_NAME}' already exists."
    exit 0
fi

echo "Creating TF state bucket 'gs://${BUCKET_NAME}' in '${GCP_REGION}'..."
gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project "${GCP_PROJECT_ID}" \
    --location "${GCP_REGION}" \
    --uniform-bucket-level-access \
    --public-access-prevention

gcloud storage buckets update "gs://${BUCKET_NAME}" --versioning

echo "TF state bucket 'gs://${BUCKET_NAME}' created (versioned, private, uniform access)."
```

- [ ] **Step 2: Write `FE_TF/run-tf-deployment.sh`**

```bash
#!/bin/bash
# scripts/gcp_tf/run-tf-deployment.sh
# Generic OpenTofu deployment wrapper for GenericSuite frontend stacks on GCP.
# GCP counterpart of scripts/aws_tf/run-tf-deployment.sh.
# 2026-07-19 | CR [GS-40]
#
# Usage:
#   bash scripts/gcp_tf/run-tf-deployment.sh ACTION STAGE STACK [EXTRA_TOFU_ARGS...]
#
# Parameters:
#   ACTION: init | validate | plan | apply | destroy | output
#   STAGE:  dev | qa | staging | demo | prod
#   STACK:  directory name under scripts/gcp_tf/stacks (frontend)
#
# Environment:
#   CICD_MODE=1        -> non-interactive (-auto-approve on apply/destroy)
#   TF_STATE_BUCKET    -> override state bucket name
#   VARIABLE_TYPE      -> frontend variable prefix (default FE)
set -euo pipefail

REPO_BASEDIR="$(pwd)"
SCRIPTS_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

ACTION="${1:-}"
STAGE="${2:-}"
STACK="${3:-}"
if [ $# -ge 3 ]; then shift 3; else shift $#; fi

usage_abort() {
    echo "ERROR: $1"
    echo "Usage: $0 ACTION STAGE STACK [EXTRA_TOFU_ARGS...]"
    echo "  ACTION: init | validate | plan | apply | destroy | output"
    echo "  STAGE:  dev | qa | staging | demo | prod"
    echo "  STACK:  one of: $(ls "${SCRIPTS_DIR}/stacks" | tr '\n' ' ')"
    exit 1
}

if [ "${ACTION}" = "" ]; then usage_abort "ACTION is not set"; fi
if [ "${STAGE}" = "" ]; then usage_abort "STAGE is not set"; fi
if [ "${STACK}" = "" ]; then usage_abort "STACK is not set"; fi
if [ ! -d "${SCRIPTS_DIR}/stacks/${STACK}" ]; then usage_abort "Unknown STACK '${STACK}'"; fi
case "${ACTION}" in
    init|validate|plan|apply|destroy|output) ;;
    *) usage_abort "Unknown ACTION '${ACTION}'" ;;
esac

case "${STAGE}" in
    dev|qa|staging|demo|prod) ;;
    *) usage_abort "Unknown STAGE '${STAGE}'" ;;
esac

CICD_MODE="${CICD_MODE:-0}"

# Load the consuming app's .env
if [ -f "${REPO_BASEDIR}/.env" ]; then
    set -o allexport
    # shellcheck disable=SC1091
    . "${REPO_BASEDIR}/.env"
    set +o allexport
else
    echo "WARNING: no .env file in ${REPO_BASEDIR}"
fi

: "${APP_NAME:?ERROR: APP_NAME is not set}"
: "${GCP_REGION:?ERROR: GCP_REGION is not set}"

APP_NAME_LOWERCASE="$(echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]')"

if [ "${GCP_PROJECT_ID:-}" = "" ]; then
    GCP_PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [ "${GCP_PROJECT_ID}" = "" ] || [ "${GCP_PROJECT_ID}" = "(unset)" ]; then
    echo "ERROR: GCP_PROJECT_ID could not be resolved. Set it in .env or run 'gcloud config set project PROJECT_ID'."
    exit 1
fi

TF_STATE_BUCKET="${TF_STATE_BUCKET:-${APP_NAME_LOWERCASE}-tf-state-${GCP_PROJECT_ID}}"
bash "${SCRIPTS_DIR}/bootstrap-tf-state.sh" "${TF_STATE_BUCKET}" "${GCP_PROJECT_ID}" "${GCP_REGION}"

# Common TF_VARs
export TF_VAR_app_name="${APP_NAME_LOWERCASE}"
export TF_VAR_stage="${STAGE}"
export TF_VAR_gcp_project_id="${GCP_PROJECT_ID}"
export TF_VAR_gcp_region="${GCP_REGION}"

# Frontend variable type (FE by default; e.g. WS for a second frontend)
VARIABLE_TYPE="$(echo "${VARIABLE_TYPE:-FE}" | tr '[:lower:]' '[:upper:]')"
varname_bucket="GCP_BUCKET_NAME_${VARIABLE_TYPE}"
FE_BUCKET_NAME="${!varname_bucket:-}"
if [ "${FE_BUCKET_NAME}" = "" ]; then
    varname_bucket="AWS_S3_BUCKET_NAME_${VARIABLE_TYPE}"
    FE_BUCKET_NAME="${!varname_bucket:-}"
fi
# Replace [STAGE] token if present (parity with set_fe_cloudfront_domain.sh)
FE_BUCKET_NAME="$(echo "${FE_BUCKET_NAME}" | perl -pe "s/\[STAGE\]/${STAGE}/g")"
export TF_VAR_bucket_name="${FE_BUCKET_NAME}"

varname_app_url="APP_${VARIABLE_TYPE}_URL"
APP_URL_RAW="${!varname_app_url:-}"
APP_URL_CLEANED="$(echo "${APP_URL_RAW}" | perl -pe 's|^https?://||i; s|[:/].*||; s|\s+||g')"
export TF_VAR_domain_name="${APP_URL_CLEANED}"

export TF_VAR_dns_zone_name="${GCP_DNS_ZONE_NAME:-}"

cd "${SCRIPTS_DIR}/stacks/${STACK}"

echo ""
echo "RUN-TF-DEPLOYMENT (GCP) | action=${ACTION} stage=${STAGE} stack=${STACK}"
echo "State: gs://${TF_STATE_BUCKET}/${STAGE}/${STACK}/default.tfstate"
echo ""

tofu init -reconfigure -input=false \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="prefix=${STAGE}/${STACK}"

APPROVE_ARG=""
if [ "${CICD_MODE}" = "1" ]; then
    APPROVE_ARG="-auto-approve"
fi

case "${ACTION}" in
    init)
        ;;
    validate)
        tofu validate "$@"
        ;;
    plan)
        tofu plan -input=false "$@"
        ;;
    apply)
        # shellcheck disable=SC2086
        tofu apply -input=false ${APPROVE_ARG} "$@"
        ;;
    destroy)
        # shellcheck disable=SC2086
        tofu destroy -input=false ${APPROVE_ARG} "$@"
        ;;
    output)
        tofu output "$@"
        ;;
esac

echo ""
echo "Done with '${ACTION}' over stack '${STACK}' (stage '${STAGE}')"
cd "${REPO_BASEDIR}"
```

- [ ] **Step 3: Syntax-check both scripts**

Run:
```bash
bash -n packages/genericsuite-fe-scripts/scripts/gcp_tf/bootstrap-tf-state.sh
bash -n packages/genericsuite-fe-scripts/scripts/gcp_tf/run-tf-deployment.sh
```
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
cd packages/genericsuite-fe-scripts
git rev-parse --abbrev-ref HEAD   # Expected: develop. If not, run: git checkout develop
git add scripts/gcp_tf/bootstrap-tf-state.sh scripts/gcp_tf/run-tf-deployment.sh
git commit -m "Add: GCP OpenTofu generic wrapper and GCS state bootstrap in scripts/gcp_tf [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 11: `frontend-hosting` module + `frontend` stack

**Suggested sub-agent:** sonnet

**Files:**
- Create: `FE_TF/modules/frontend-hosting/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`
- Create: `FE_TF/stacks/frontend/backend.tf`, `providers.tf`, `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`

**Interfaces:**
- Consumes: `TF_VAR_bucket_name`, `TF_VAR_domain_name`, `TF_VAR_dns_zone_name` + common vars (Task 10).
- Produces: module `frontend-hosting` inputs: `bucket_name`, `app_name`, `stage`, `gcp_region`, `domain_name ("")`, `dns_zone_name ("")`. Outputs: `bucket_name (string)`, `url_map_name (string)` (needed by Task 12 for CDN invalidation), `lb_ip_address (string)`, `site_url (string)` (`https://{domain}` or `http://{ip}`). Stack outputs the same four values.

- [ ] **Step 1: Write `FE_TF/modules/frontend-hosting/main.tf`**

```hcl
locals {
  use_domain = var.domain_name != ""
  # LB resource names must be RFC1035; bucket names may contain dots
  res_prefix = replace(var.bucket_name, ".", "-")
}

resource "google_storage_bucket" "this" {
  name                        = var.bucket_name
  location                    = var.gcp_region
  uniform_bucket_level_access = true
  force_destroy               = false

  # SPA routing: unknown paths serve index.html (content with 404 status)
  website {
    main_page_suffix = "index.html"
    not_found_page   = "index.html"
  }

  labels = {
    app   = var.app_name
    stage = var.stage
  }
}

# Objects must be publicly readable to be served through the backend bucket
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_compute_backend_bucket" "this" {
  name        = "${local.res_prefix}-backend"
  bucket_name = google_storage_bucket.this.name
  enable_cdn  = true

  cdn_policy {
    cache_mode  = "CACHE_ALL_STATIC"
    client_ttl  = 3600
    default_ttl = 3600
    max_ttl     = 86400
  }
}

resource "google_compute_url_map" "this" {
  name            = "${local.res_prefix}-url-map"
  default_service = google_compute_backend_bucket.this.id
}

resource "google_compute_managed_ssl_certificate" "this" {
  count = local.use_domain ? 1 : 0
  name  = "${local.res_prefix}-cert"

  managed {
    domains = [var.domain_name]
  }
}

resource "google_compute_target_https_proxy" "this" {
  count            = local.use_domain ? 1 : 0
  name             = "${local.res_prefix}-https-proxy"
  url_map          = google_compute_url_map.this.id
  ssl_certificates = [google_compute_managed_ssl_certificate.this[0].id]
}

resource "google_compute_url_map" "redirect" {
  count = local.use_domain ? 1 : 0
  name  = "${local.res_prefix}-https-redirect"

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "this" {
  name    = "${local.res_prefix}-http-proxy"
  url_map = local.use_domain ? google_compute_url_map.redirect[0].id : google_compute_url_map.this.id
}

resource "google_compute_global_address" "this" {
  name = "${local.res_prefix}-lb-ip"
}

resource "google_compute_global_forwarding_rule" "https" {
  count      = local.use_domain ? 1 : 0
  name       = "${local.res_prefix}-https-fr"
  target     = google_compute_target_https_proxy.this[0].id
  port_range = "443"
  ip_address = google_compute_global_address.this.address
}

resource "google_compute_global_forwarding_rule" "http" {
  name       = "${local.res_prefix}-http-fr"
  target     = google_compute_target_http_proxy.this.id
  port_range = "80"
  ip_address = google_compute_global_address.this.address
}

resource "google_dns_record_set" "a" {
  count        = local.use_domain && var.dns_zone_name != "" ? 1 : 0
  managed_zone = var.dns_zone_name
  name         = "${var.domain_name}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.this.address]
}
```

- [ ] **Step 2: Write `FE_TF/modules/frontend-hosting/variables.tf`**

```hcl
variable "bucket_name" {
  description = "GCS bucket name for the frontend build"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "gcp_region" {
  description = "GCP region (bucket location)"
  type        = string
}

variable "domain_name" {
  description = "Frontend domain (host only); empty serves over HTTP on the LB IP"
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name for the A record; empty skips the record"
  type        = string
  default     = ""
}
```

- [ ] **Step 3: Write `FE_TF/modules/frontend-hosting/outputs.tf`**

```hcl
output "bucket_name" {
  description = "Frontend bucket name"
  value       = google_storage_bucket.this.name
}

output "url_map_name" {
  description = "URL map name (for CDN cache invalidation)"
  value       = google_compute_url_map.this.name
}

output "lb_ip_address" {
  description = "Global load balancer IP address"
  value       = google_compute_global_address.this.address
}

output "site_url" {
  description = "Site URL"
  value       = local.use_domain ? "https://${var.domain_name}" : "http://${google_compute_global_address.this.address}"
}
```

- [ ] **Step 4: Write `FE_TF/modules/frontend-hosting/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 5: Write `FE_TF/stacks/frontend/backend.tf`**

```hcl
terraform {
  backend "gcs" {}
}
```

- [ ] **Step 6: Write `FE_TF/stacks/frontend/providers.tf`**

```hcl
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region

  default_labels = {
    app        = var.app_name
    stage      = var.stage
    managed_by = "opentofu"
    ticket     = "gs-40"
  }
}
```

- [ ] **Step 7: Write `FE_TF/stacks/frontend/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 8: Write `FE_TF/stacks/frontend/variables.tf`**

```hcl
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "bucket_name" {
  description = "GCS bucket name for the frontend build"
  type        = string
}

variable "domain_name" {
  description = "Frontend domain (host only); empty serves over HTTP on the LB IP"
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name; empty skips the DNS record"
  type        = string
  default     = ""
}
```

- [ ] **Step 9: Write `FE_TF/stacks/frontend/main.tf`**

```hcl
module "frontend_hosting" {
  source = "../../modules/frontend-hosting"

  bucket_name   = var.bucket_name
  app_name      = var.app_name
  stage         = var.stage
  gcp_region    = var.gcp_region
  domain_name   = var.domain_name
  dns_zone_name = var.dns_zone_name
}
```

- [ ] **Step 10: Write `FE_TF/stacks/frontend/outputs.tf`**

```hcl
output "bucket_name" {
  description = "Frontend bucket name"
  value       = module.frontend_hosting.bucket_name
}

output "url_map_name" {
  description = "URL map name (for CDN cache invalidation)"
  value       = module.frontend_hosting.url_map_name
}

output "lb_ip_address" {
  description = "Global load balancer IP address"
  value       = module.frontend_hosting.lb_ip_address
}

output "site_url" {
  description = "Site URL"
  value       = module.frontend_hosting.site_url
}
```

- [ ] **Step 11: Format and validate**

Run:
```bash
tofu fmt -recursive packages/genericsuite-fe-scripts/scripts/gcp_tf
cd packages/genericsuite-fe-scripts/scripts/gcp_tf/stacks/frontend
tofu init -backend=false -input=false
tofu validate
cd -
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 12: Commit**

```bash
cd packages/genericsuite-fe-scripts
git add scripts/gcp_tf/modules/frontend-hosting scripts/gcp_tf/stacks/frontend
git commit -m "Add: GCP OpenTofu frontend-hosting module and frontend stack (GCS + Cloud CDN + HTTPS LB + managed SSL) [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 12: FE deploy pipeline (`gcp_tf_deploy_to_gcs.sh`) + FE CHANGELOG

**Suggested sub-agent:** sonnet

**Files:**
- Create: `FE_TF/gcp_tf_deploy_to_gcs.sh`
- Modify: `packages/genericsuite-fe-scripts/CHANGELOG.md` (the `## [Unreleased]` → `### Added` section)

**Interfaces:**
- Consumes: Task 10 wrapper (`run-tf-deployment.sh apply STAGE frontend`), Task 11 stack outputs `bucket_name`, `url_map_name`, `site_url`; existing FE helpers `run_method_dependency_manager.sh`, `run_symlinks_handler.sh`, `build_copy_images.sh` (already in `scripts/`).
- Produces: `gcp_tf_deploy_to_gcs.sh STAGE [VARIABLE_TYPE]` — full pipeline: tofu apply + app build + `gcloud storage rsync` + CDN cache invalidation.

- [ ] **Step 1: Write `FE_TF/gcp_tf_deploy_to_gcs.sh`**

```bash
#!/bin/bash
# scripts/gcp_tf/gcp_tf_deploy_to_gcs.sh
# OpenTofu-based frontend deployment to GCP: infra via tofu, app build + GCS
# rsync + Cloud CDN cache invalidation in bash. GCP counterpart of
# scripts/aws_tf/aws_tf_deploy_to_s3.sh (which remains untouched).
# 2026-07-19 | CR [GS-40]
#
# Usage:
#   bash node_modules/genericsuite-fe-scripts/scripts/gcp_tf/gcp_tf_deploy_to_gcs.sh STAGE [VARIABLE_TYPE]
#   STAGE: dev | qa | staging | demo | prod
#   VARIABLE_TYPE: FE (default) or another frontend variable prefix
set -euo pipefail

REPO_BASEDIR="$(pwd)"
SCRIPTS_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
FE_SCRIPTS_DIR="$(cd -- "${SCRIPTS_DIR}/.." >/dev/null 2>&1 && pwd -P)"

STAGE="${1:-}"
VARIABLE_TYPE="$(echo "${2:-FE}" | tr '[:lower:]' '[:upper:]')"
export VARIABLE_TYPE

if [ "${STAGE}" = "" ]; then
    echo "Usage: $0 STAGE [VARIABLE_TYPE]"
    exit 1
fi

if [ ! -f "${REPO_BASEDIR}/.env" ]; then
    echo "ERROR: .env file doesn't exist"
    exit 1
fi
set -o allexport
# shellcheck disable=SC1091
. "${REPO_BASEDIR}/.env"
set +o allexport

RUN_BUNDLER="${RUN_BUNDLER:-vite}"
UPDATE_BUILD="${UPDATE_BUILD:-1}"
BUILD_DIR="${BUILD_DIR:-build}"
REACT_APP_VERSION="$(cat "${REPO_BASEDIR}/version.txt")"
export REACT_APP_VERSION

if [ "${GCP_PROJECT_ID:-}" = "" ]; then
    GCP_PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [ "${GCP_PROJECT_ID}" = "" ] || [ "${GCP_PROJECT_ID}" = "(unset)" ]; then
    echo "ERROR: GCP_PROJECT_ID could not be resolved. Set it in .env or run 'gcloud config set project PROJECT_ID'."
    exit 1
fi

# 1) Infrastructure: GCS bucket + Cloud CDN + HTTPS LB via OpenTofu
bash "${SCRIPTS_DIR}/run-tf-deployment.sh" apply "${STAGE}" frontend

# 2) Read infra outputs
cd "${SCRIPTS_DIR}/stacks/frontend"
BUCKET_NAME="$(tofu output -raw bucket_name)"
URL_MAP_NAME="$(tofu output -raw url_map_name)"
SITE_URL="$(tofu output -raw site_url)"
cd "${REPO_BASEDIR}"
HOMEPAGE_DOMAIN="$(echo "${SITE_URL}" | perl -pe 's|^https?://||i; s|[:/].*||')"
echo ""
echo "Bucket: ${BUCKET_NAME} | URL map: ${URL_MAP_NAME} (${SITE_URL})"

# 3) Build the app (same flow as aws_tf_deploy_to_s3.sh)
if [ "${RUN_BUNDLER}" != "none" ] && [ "${UPDATE_BUILD}" = "1" ]; then
    sh "${FE_SCRIPTS_DIR}/run_method_dependency_manager.sh" install "${RUN_BUNDLER}"

    TSCONFIG_BASE_URL="$(perl -ne 'print $1 if /"baseUrl":\s*"([^"]*)"/' tsconfig.json)"
    PREV_HOME_PAGE="$(perl -ne 'print $1 if /"homepage":\s*"([^"]*)"/' package.json)"

    # Restore package.json / tsconfig.json even if the build below fails
    restore_pkg_files() {
        if [ "${PREV_HOME_PAGE:-}" != "" ]; then
            perl -i -pe "s|\"homepage\":.*|\"homepage\": \"${PREV_HOME_PAGE}\",|g" package.json || true
        fi
        perl -i -pe 's|"type1": "module"|"type": "module"|g' package.json || true
        if [ "${TSCONFIG_BASE_URL:-}" = "./src/lib" ]; then
            perl -i -pe 's|"baseUrl": "./src"|"baseUrl": "./src/lib"|g' tsconfig.json || true
        fi
    }
    trap restore_pkg_files EXIT

    if [ "${TSCONFIG_BASE_URL}" = "./src/lib" ]; then
        perl -i -pe 's|"baseUrl": "./src/lib"|"baseUrl": "./src"|g' tsconfig.json
    fi

    perl -i -pe "s|\"homepage\":.*|\"homepage\": \"https://${HOMEPAGE_DOMAIN}\",|g" package.json

    if [ "${PRESERVE_MODULE_TYPE:-0}" != "1" ]; then
        perl -i -pe 's|"type": "module"|"type1": "module"|g' package.json
    fi

    sh "${FE_SCRIPTS_DIR}/run_symlinks_handler.sh" remove

    echo "Building React app... (${RUN_BUNDLER})"
    if [ "${RUN_BUNDLER}" = "webpack" ]; then
        if [ "${STAGE}" = "prod" ]; then
            npx webpack --mode production
        else
            npx webpack --mode development
        fi
    elif [ "${RUN_BUNDLER}" = "vite" ]; then
        npx vite build
    else
        npx react-app-rewired build
    fi

    # shellcheck disable=SC1091
    source "${FE_SCRIPTS_DIR}/build_copy_images.sh" "" ""
fi

# 4) Sync to GCS
echo "Deploying to GCS..."
gcloud storage rsync "${BUILD_DIR}" "gs://${BUCKET_NAME}" \
    --recursive --delete-unmatched-destination-objects \
    --project "${GCP_PROJECT_ID}"

# 5) Invalidate Cloud CDN cache
echo "Invalidating Cloud CDN cache..."
gcloud compute url-maps invalidate-cdn-cache "${URL_MAP_NAME}" \
    --path "/*" --async --project "${GCP_PROJECT_ID}"

echo ""
echo "Deployment complete: ${SITE_URL}"
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n packages/genericsuite-fe-scripts/scripts/gcp_tf/gcp_tf_deploy_to_gcs.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Add the FE CHANGELOG entry**

In `packages/genericsuite-fe-scripts/CHANGELOG.md`, under `## [Unreleased] - YYYY-MM-DD` → `### Added` (currently empty), add:

```markdown
- OpenTofu (Terraform-compatible) IaC frontend deployment for Google Cloud Platform in `scripts/gcp_tf`: `frontend-hosting` module (GCS bucket + Cloud CDN backend bucket + global HTTPS Load Balancer + Google-managed SSL + Cloud DNS) and `gcp_tf_deploy_to_gcs.sh` full pipeline (tofu apply + build + `gcloud storage rsync` + CDN cache invalidation), with GCS remote state — mirroring `scripts/aws_tf`, which remains unchanged [GS-40].
```

- [ ] **Step 4: Confirm the AWS path is untouched**

Run: `cd packages/genericsuite-fe-scripts && git status --porcelain scripts/aws_tf scripts/aws_deploy_to_s3.sh scripts/aws_get_ssl_cert_arn.sh && cd ../..`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
cd packages/genericsuite-fe-scripts
git add scripts/gcp_tf/gcp_tf_deploy_to_gcs.sh CHANGELOG.md
git commit -m "Add: GCP OpenTofu frontend deploy pipeline gcp_tf_deploy_to_gcs.sh and CHANGELOG entry [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 13: Basecamp documentation (`opentofu-gcp.md` + nav + CHANGELOG)

**Suggested sub-agent:** sonnet

**Files:**
- Create: `packages/genericsuite-basecamp/mkdocs_root/en/Deployment-Guide/opentofu-gcp.md`
- Modify: `packages/genericsuite-basecamp/mkdocs.yml` (two nav locations)
- Modify: `packages/genericsuite-basecamp/CHANGELOG.md` (`## [Unreleased]` → `### Added`)

**Interfaces:**
- Consumes: the shipped layout/commands from Tasks 2–12 (documented, not imported).
- Produces: user-facing guide reachable from the mkdocs nav.

- [ ] **Step 1: Write `opentofu-gcp.md`**

Create `packages/genericsuite-basecamp/mkdocs_root/en/Deployment-Guide/opentofu-gcp.md` with exactly this content:

```markdown
# OpenTofu on GCP (Infrastructure as Code)

GenericSuite ships an [OpenTofu](https://opentofu.org/) (Terraform-compatible) implementation of the backend and frontend deployments on **Google Cloud Platform**, mirroring the [AWS OpenTofu implementation](./opentofu.md) exactly: same wrapper contract, same module/stack layout, same `.env`-driven configuration. If you know `scripts/aws_tf/`, you already know `scripts/gcp_tf/`.

- Frontend stacks: `genericsuite-fe-scripts/scripts/gcp_tf/`
- Backend stacks: `genericsuite-be-scripts/scripts/gcp_tf/`

## AWS → GCP service mapping

| AWS (aws_tf) | GCP (gcp_tf) |
|---|---|
| S3 remote state (`use_lockfile`) | GCS remote state (native locking) |
| S3 chatbot-attachments bucket | GCS bucket (`gcs` stack) |
| KMS key | Cloud KMS key ring + crypto key, 90-day rotation (`kms` stack) |
| Secrets Manager (`{app}-{stage}-secrets`/`-envs`) | Secret Manager, same names; `-secrets` is CMEK-encrypted (`secrets` stack) |
| ECR repository | Artifact Registry Docker repo + cleanup policies (`ar` stack) |
| Lambda + API Gateway | Cloud Run v2 service (`cloudrun` stack) |
| EC2 + ALB | GCE (Container-Optimized OS) + global HTTPS LB (`gce` stack) |
| ACM + Route53 validation | Google-managed SSL certificates (validate automatically) + Cloud DNS |
| CloudFront + S3 (OAC) | Cloud CDN + backend bucket + HTTPS LB (`frontend` stack) |
| DynamoDB tables | **Not converted** — use MongoDB Atlas or Cloud SQL (see Gaps) |

## Prerequisites

- **OpenTofu ≥ 1.10**
  ```bash
  brew install opentofu     # macOS
  tofu version              # confirm >= 1.10
  ```
- **gcloud CLI** authenticated against the target project:
  ```bash
  gcloud auth login
  gcloud auth application-default login   # credentials for the provider
  gcloud config set project YOUR_PROJECT_ID
  ```
- **`jq`** (used by the secrets variable builder).
- A GCP project with **billing enabled**. Required APIs are enabled automatically by the state bootstrap.
- A consuming application with a stage-specific `.env` file. Run the wrapper from the application's root directory.

## Environment variables (`.env`)

| Variable | Required | Notes |
|---|---|---|
| `APP_NAME` | yes | Same as AWS path |
| `GCP_REGION` | yes | e.g. `us-central1` |
| `GCP_PROJECT_ID` | no | Falls back to `gcloud config get-value project` |
| `GCP_KMS_KEY_RING` / `GCP_KMS_KEY_NAME` | no | Default `genericsuite-keyring` / `genericsuite-key` |
| `GCP_CHATBOT_ATTACHMENTS_BUCKET_{STAGE}` | no | Falls back to `AWS_S3_CHATBOT_ATTACHMENTS_BUCKET_{STAGE}` |
| `GCP_CLOUD_RUN_SERVICE_NAME` | no | Falls back to `AWS_LAMBDA_FUNCTION_NAME`, then `{app}-backend`; stage suffix is appended |
| `GCP_DOCKER_IMAGE_TAG` | no | Falls back to `ECR_DOCKER_IMAGE_TAG`, then `latest` |
| `GCP_API_DOMAIN_NAME` | no | Custom backend domain; supports the `[STAGE]` token (e.g. `app-[STAGE].example.com`); use subdomains |
| `GCP_DNS_ZONE_NAME` | no | Cloud DNS managed zone name; empty skips DNS records |
| `GCP_MACHINE_TYPE` / `GCP_CONTAINER_PORT` | no | GCE machine type (`e2-small`) / app port (`8080`) |
| `GCP_BUCKET_NAME_FE` | no (FE) | Falls back to `AWS_S3_BUCKET_NAME_FE`; supports `[STAGE]` |

## State management

- **Bucket:** `{app_name_lowercase}-tf-state-{gcp_project_id}`
- **Prefix:** `{stage}/{stack}` (state object `{stage}/{stack}/default.tfstate`)
- Versioned, uniform bucket-level access, public access prevention, GCS-native locking.

The bucket is created automatically the first time you run the wrapper (`bootstrap-tf-state.sh`), which also enables the required GCP APIs. Backend configuration is injected via `tofu init -backend-config=...` — never edited by hand.

## Backend deployments

```bash
bash node_modules/genericsuite-be-scripts/scripts/gcp_tf/run-tf-deployment.sh ACTION STAGE STACK
```

- **ACTION:** `init` | `validate` | `plan` | `apply` | `destroy` | `output`
- **STAGE:** `dev` | `qa` | `staging` | `demo` | `prod`
- **STACK:** one of `kms`, `secrets`, `gcs`, `ar`, `cloudrun`, `gce`

Set `CICD_MODE=1` for non-interactive runs (adds `-auto-approve` on `apply`/`destroy`).

### Typical backend flow

```bash
# 1. KMS key (required by secrets CMEK)
bash .../run-tf-deployment.sh apply qa kms
# 2. Secrets (reads CORE/EXTENSION/APP variable lists from .env)
bash .../run-tf-deployment.sh apply qa secrets
# 3. Chatbot attachments bucket
bash .../run-tf-deployment.sh apply qa gcs
# 4. Artifact Registry repo
bash .../run-tf-deployment.sh apply qa ar
# 5. Build & push the backend image
bash .../build_push_image.sh qa
# 6. Deploy compute: Cloud Run (recommended) or GCE + LB
bash .../run-tf-deployment.sh apply qa cloudrun
bash .../run-tf-deployment.sh output qa cloudrun   # -> service_url
```

The Cloud Run / GCE service account gets **per-secret** accessor grants on `{app}-{stage}-secrets` and `{app}-{stage}-envs`, plus `objectAdmin` on the chatbot bucket — never project-wide roles.

## Frontend deployment

One command builds the infra and the app, then syncs and invalidates:

```bash
bash node_modules/genericsuite-fe-scripts/scripts/gcp_tf/gcp_tf_deploy_to_gcs.sh qa
```

Pipeline: `tofu apply` on the `frontend` stack (GCS bucket + Cloud CDN backend bucket + HTTPS LB + Google-managed SSL + optional Cloud DNS A record) → bundler build (vite/webpack/react-app-rewired) → `gcloud storage rsync` → `gcloud compute url-maps invalidate-cdn-cache`.

Domain and bucket come from `APP_FE_URL` and `GCP_BUCKET_NAME_FE` (fallback `AWS_S3_BUCKET_NAME_FE`). With no domain configured, the site is served over HTTP on the load balancer IP.

**SPA routing note:** the bucket's `not_found_page` is `index.html`, so deep links load the app, but GCS returns them with HTTP 404 status (unlike CloudFront's 200 rewrite). Browsers render fine; SEO for deep links differs.

**Managed SSL note:** Google-managed certificates only become ACTIVE after DNS points the domain at the LB IP — provisioning can take up to ~1 hour on first deploy.

## Gaps / follow-ups

- **DynamoDB:** no GCP conversion — `genericsuite-be`'s `DbAbstractor` has no Firestore adapter. On GCP use MongoDB Atlas or Cloud SQL (set `APP_DB_ENGINE`/`APP_DB_URI` accordingly).
- **Cloud SQL module** (PostgreSQL/MySQL): follow-up, parity with the AWS `rds-database` follow-up.
- **Runtime secrets consumption:** `genericsuite-be` must read GCP Secret Manager when `CLOUD_PROVIDER=gcp` (separate ticket); the IaC publishes `APP_SECRETS_NAME`/`APP_ENVS_NAME` env vars to the container.
- **LocalStack-style emulation:** not available for the GCP path.

## Migration notes

- GCP **KMS key rings cannot be deleted**. `tofu destroy` on the `kms` stack removes them from state only; re-applying later requires importing: `tofu import module.kms_key.google_kms_key_ring.this projects/PROJECT/locations/REGION/keyRings/genericsuite-keyring`.
- Cloud Run domain mappings require **subdomains** (CNAME to `ghs.googlehosted.com.`); zone apex domains should use the `gce` or `frontend` LB pattern instead.
- The AWS scripts (`aws_tf`, CloudFormation, SAM) are untouched — both cloud paths can coexist in the same repository and `.env`.
```

- [ ] **Step 2: Add nav entries to `mkdocs.yml`**

In `packages/genericsuite-basecamp/mkdocs.yml` make two edits:

1. Find the line (around line 20):
```yaml
    - 'OpenTofu (IaC)': './Deployment-Guide/opentofu.md'
```
Insert directly below it, with identical indentation:
```yaml
    - 'OpenTofu on GCP (IaC)': './Deployment-Guide/opentofu-gcp.md'
```

2. Find the line (around line 120):
```yaml
            'OpenTofu (IaC)': 'OpenTofu (IaC)'
```
Insert directly below it, with identical indentation:
```yaml
            'OpenTofu on GCP (IaC)': 'OpenTofu on GCP (IaC)'
```

- [ ] **Step 3: Add the Basecamp CHANGELOG entry**

In `packages/genericsuite-basecamp/CHANGELOG.md`, under `## [Unreleased] - YYYY-MM-DD` → `### Added`, add:

```markdown
- GCP OpenTofu deployment guide (`Deployment-Guide/opentofu-gcp.md`) covering backend and frontend stacks, the AWS→GCP service mapping, prerequisites, state management, environment variables, and gaps [GS-40].
```

- [ ] **Step 4: Verify mkdocs config parses (if mkdocs is available)**

Run: `cd packages/genericsuite-basecamp && (command -v mkdocs >/dev/null && mkdocs build --quiet --site-dir /tmp/mkdocs-test-gs40 || python3 -c "import yaml,sys; yaml.safe_load(open('mkdocs.yml'))" 2>/dev/null || echo "SKIP: no yaml parser available") && cd ../..`
Expected: no errors (or `SKIP` line). If `mkdocs build` fails on the two new lines, fix the indentation to match the sibling entries exactly.

- [ ] **Step 5: Commit**

```bash
cd packages/genericsuite-basecamp
git rev-parse --abbrev-ref HEAD   # Expected: develop. If not, run: git checkout develop
git add mkdocs_root/en/Deployment-Guide/opentofu-gcp.md mkdocs.yml CHANGELOG.md
git commit -m "Add: GCP OpenTofu deployment guide, mkdocs nav entries and CHANGELOG entry [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../..
```

---

### Task 14: Superproject CHANGELOG + spec/plan commit

**Suggested sub-agent:** haiku

**Files:**
- Modify: `CHANGELOG.md` (superproject root, `## [Unreleased]` → `### Added`)
- Already created (commit only): `docs/superpowers/specs/2026-07-19-gcp-opentofu-conversion-design.md`, `docs/superpowers/plans/2026-07-19-gcp-opentofu-conversion.md`

**Interfaces:**
- Consumes: Tasks 2–13 committed inside their submodules.
- Produces: superproject-level record of the change.

- [ ] **Step 1: Add the superproject CHANGELOG entry**

In the superproject root `CHANGELOG.md`, under `## [Unreleased] - YYYY-MM-DD` → `### Added`, add:

```markdown
- GCP OpenTofu conversion: OpenTofu IaC deployments for Google Cloud Platform in genericsuite-be-scripts (`scripts/gcp_tf`: wrapper, GCS state, GCS/KMS/Secret Manager/Artifact Registry/Cloud Run/GCE+LB stacks) and genericsuite-fe-scripts (`scripts/gcp_tf`: frontend-hosting + `gcp_tf_deploy_to_gcs.sh`), with GS Basecamp guide, design spec and implementation plan (`docs/superpowers/specs/2026-07-19-gcp-opentofu-conversion-design.md`, `docs/superpowers/plans/2026-07-19-gcp-opentofu-conversion.md`) [GS-40].
```

- [ ] **Step 2: Commit (superproject — only these files)**

Do NOT stage `docs/activeContext.md` or the `packages/` submodule pointers unless Carlos asks for a submodule-pointer bump.

```bash
git rev-parse --abbrev-ref HEAD   # Expected: develop
git add CHANGELOG.md docs/superpowers/specs/2026-07-19-gcp-opentofu-conversion-design.md docs/superpowers/plans/2026-07-19-gcp-opentofu-conversion.md
git commit -m "Add: design spec and implementation plan for GCP OpenTofu conversion; CHANGELOG entry [GS-40]" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 15: Final verification sweep (+ manual real-apply gate)

**Suggested sub-agent:** haiku

**Files:** none

**Interfaces:**
- Consumes: everything above.
- Produces: evidence that all stacks validate and nothing pre-existing changed.

- [ ] **Step 1: Validate all seven stacks from scratch**

Run:
```bash
tofu fmt -check -recursive packages/genericsuite-be-scripts/scripts/gcp_tf packages/genericsuite-fe-scripts/scripts/gcp_tf
for d in packages/genericsuite-be-scripts/scripts/gcp_tf/stacks/*/ packages/genericsuite-fe-scripts/scripts/gcp_tf/stacks/*/; do
  echo "=== ${d} ==="
  ( cd "${d}" && rm -rf .terraform && tofu init -backend=false -input=false >/dev/null && tofu validate )
done
```
Expected: `fmt -check` prints nothing; each of the 7 stacks (`gcs`, `kms`, `secrets`, `ar`, `cloudrun`, `gce`, `frontend`) prints `Success! The configuration is valid.`

- [ ] **Step 2: Confirm clean status in all three submodules**

Run:
```bash
git -C packages/genericsuite-be-scripts status --porcelain
git -C packages/genericsuite-fe-scripts status --porcelain
git -C packages/genericsuite-basecamp status --porcelain
```
Expected: no output from each (untracked `.terraform`/`.terraform.lock.hcl` under `stacks/*` may appear — if so, they must NOT be committed; verify each package's `.gitignore` covers `.terraform` and add `**/.terraform*` to the package `.gitignore` + amend the last commit if it doesn't).

- [ ] **Step 3: STOP — manual real-apply verification (Carlos only)**

Do not perform this step automatically. Report to Carlos that the implementation is complete and validated, and that real-environment verification (mirroring GS-334 §6: dev-stage `apply` of `kms`, `secrets`, `gcs`, `ar` — and `frontend` on the FE side — from a consuming app with a real `.env` and an authenticated `gcloud`, keeping the resources; `plan`-only for prod) is pending his run, since it requires a GCP project with billing and his credentials.

---

## Execution order & parallelism

Sequential is safest. If using parallel sub-agents: Tasks 3–8 are independent of each other after Task 2 lands (same package, disjoint directories — merge risk is low but commits will interleave; prefer sequential within the BE package). Tasks 10–12 (FE) and Task 13 (Basecamp) are independent of the BE tasks. Task 14 requires 2–13; Task 15 runs last.
