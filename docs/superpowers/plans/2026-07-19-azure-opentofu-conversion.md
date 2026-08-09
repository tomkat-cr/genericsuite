# Azure OpenTofu Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

- **Date:** 2026-07-19
- **Ticket:** GS-316
- **Reference design:** `docs/superpowers/specs/2026-07-16-aws-opentofu-conversion-design.md` (AWS counterpart, GS-334)
- **Packages affected:** `packages/genericsuite-be-scripts`, `packages/genericsuite-fe-scripts`, `packages/genericsuite-basecamp`, superproject root

**Goal:** Provide an OpenTofu implementation of the GenericSuite backend and frontend deployments on Microsoft Azure, mirroring the structure, wrapper contract, and conventions of the existing AWS OpenTofu path (`scripts/aws_tf`), as a new parallel `scripts/azure_tf` tree in both script packages. Nothing in `scripts/aws_tf` is modified.

**Architecture:** Same layered approach as AWS: a bash wrapper (`run-tf-deployment.sh ACTION STAGE STACK`) reads the consuming app's `.env`, resolves names, bootstraps remote state, exports `TF_VAR_*`, and drives `tofu` over per-concern **stacks** that compose reusable **modules**. Remote state lives in an Azure Storage account (blob-lease locking is native — no extra lock config). App build/packaging (bundlers, docker push, blob upload, CDN purge) stays in bash.

**Tech Stack:** OpenTofu >= 1.10, `hashicorp/azurerm` provider `~> 4.0`, Azure CLI (`az`), bash per `docs/codeStyle.md`.

## Recommended subagent models per task

When executing with subagent-driven development, dispatch:

| Tasks | Model | Why |
|---|---|---|
| 1, 2, 9, 10, 11, 12 | **sonnet** | Wrapper scripts and the two largest modules; multi-file integration |
| 3, 4, 5, 6, 7, 8, 13, 15 | **haiku** | Verbatim file creation from code given below + mechanical verification/commits |
| 14 | **sonnet** | Documentation writing with cross-references |

Every task's code is complete in this plan; a haiku subagent only needs to copy files, run the listed commands, compare output to the listed expectations, and commit.

## AWS → Azure service mapping (context, read once)

| AWS (aws_tf) | Azure (azure_tf) | Notes |
|---|---|---|
| S3 state bucket (`bootstrap-tf-state.sh`) | Resource group + Storage account + `tfstate` container | Blob lease = native locking |
| `s3-bucket` module / `s3` stack | `storage-blob` module / `storage` stack | Storage account + private blob container |
| `dynamodb-tables` module / `dynamodb` stack | `cosmosdb-mongo` module / `cosmosdb` stack | Cosmos DB (MongoDB API, serverless); reuses `aws_tf/generate_dynamodb_tfvars.py` |
| `kms-key` module / `kms` stack | `key-vault` module / `keyvault` stack | Key Vault (RBAC) + RSA key `genericsuite-key` |
| `secrets` module / `secrets` stack | `secrets` module / `secrets` stack | Two Key Vault secrets holding the same JSON blobs (`{app}-{stage}-secrets`, `{app}-{stage}-envs`) |
| `ecr-repository` module / `ecr` stack | `acr-registry` module / `acr` stack | ACR Basic; untagged-image retention needs Premium (documented gap) |
| `lambda-api` module / `lambda` stack | `container-api` module / `containerapp` stack | Azure Container Apps, scale-to-zero (`min_replicas = 0`) replicates Lambda |
| `ec2-alb` module / `ec2` stack | same `containerapp` stack with `CONTAINER_MIN_REPLICAS=1` | Container Apps with a warm replica replicates EC2+ALB (VM + App Gateway port documented as gap) |
| `app-domain` module / `domain` stack | folded into `container-api` and `frontend-hosting` | Azure managed certificates are provisioned per-service; no standalone ACM equivalent needed |
| (none) | `resource-group` module / `rg` stack | Azure requires a resource group per app+stage |
| `frontend-hosting` module / `frontend` stack (fe) | `frontend-hosting` module / `frontend` stack (fe) | Storage static website + Azure Front Door Standard (managed TLS, HTTPS redirect, SPA 404→index.html) |
| `aws_tf_deploy_to_s3.sh` (fe) | `azure_tf_deploy_to_storage.sh` (fe) | build + blob upload-batch + Front Door purge |

**Stack apply order (documented for users, enforced by remote-state reads):** `rg` → `keyvault` → `secrets` → `storage` → `cosmosdb` → `acr` → `containerapp`. FE `frontend` stack is independent.

## Global Constraints

- **Never modify anything under `scripts/aws_tf/`** in either package, nor any CloudFormation/SAM script. Azure is a parallel opt-in path.
- **OpenTofu:** `required_version = ">= 1.10"`; **provider:** `azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }` — pinned in a `versions.tf` in **every** module and stack.
- **Provider block (every stack):** `provider "azurerm" { subscription_id = var.azure_subscription_id; features {} }` — azurerm has no `default_tags`, so modules tag primary resources with `local.common_tags = { App, Stage, ManagedBy = "opentofu", Ticket = "GS-316" }`.
- **Shell:** `#!/bin/bash`, `set -euo pipefail`, quoted expansions, `perl` over `sed -i`, `read VAR < /dev/tty` (never `read -p`) — per each package's `docs/codeStyle.md`.
- **Stages:** `dev | qa | staging | demo | prod`. **Actions:** `init | validate | plan | apply | destroy | output`.
- **Wrapper contract:** `run-tf-deployment.sh ACTION STAGE STACK [EXTRA_TOFU_ARGS...]`, `CICD_MODE=1` → `-auto-approve`. Secrets travel only as `TF_VAR_*` env vars, never written to disk.
- **State:** RG `{app}-tfstate-rg`, storage account `{app_alnum≤14}tfst{sub_hash6}`, container `tfstate`, key `{stage}/{stack}.tfstate`.
- **Name derivations** (computed in wrappers, passed as TF_VARs — Azure name limits: storage accounts 3–24 lowercase alphanumerics, global; Key Vault 3–24, global; ACR 5–50 alphanumerics, global):
  - `APP_NAME_LOWERCASE="$(echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]')"`
  - `APP_NAME_ALNUM="$(echo "${APP_NAME_LOWERCASE}" | tr -cd 'a-z0-9')"`
  - `SUB_HASH="$(printf '%s' "${AZURE_SUBSCRIPTION_ID}" | shasum | cut -c1-6)"` and `SUB_HASH4="$(printf '%s' "${SUB_HASH}" | cut -c1-4)"` (`shasum` exists on macOS and Linux)
  - App RG: `${APP_NAME_LOWERCASE}-${STAGE}-rg` (override: `AZURE_RESOURCE_GROUP`)
  - Key Vault: `kv$(printf '%s' "${APP_NAME_ALNUM}" | cut -c1-8)${STAGE}${SUB_HASH4}` (override: `AZURE_KEY_VAULT_NAME`)
  - Data storage account: `$(printf '%s' "${APP_NAME_ALNUM}" | cut -c1-9)${STAGE}st${SUB_HASH4}` (override: `AZURE_STORAGE_ACCOUNT_NAME_${STAGE_UPPERCASE}`)
  - ACR: `acr$(printf '%s' "${APP_NAME_ALNUM}" | cut -c1-10)${STAGE}${SUB_HASH4}` (override: `AZURE_ACR_NAME`)
  - Cosmos account: `${APP_NAME_LOWERCASE}-${STAGE}-cosmos` (override: `AZURE_COSMOS_ACCOUNT_NAME`)
  - Container app: `$(printf '%s' "${APP_NAME_LOWERCASE}" | tr -cd 'a-z0-9-' | cut -c1-15)-be-${STAGE}` (override: `AZURE_CONTAINER_APP_NAME`)
- **New `.env` variables introduced** (document them in Task 14): `AZURE_REGION` (required, e.g. `eastus`), `AZURE_SUBSCRIPTION_ID` (optional, else `az account show`), `AZURE_DNS_ZONE_NAME` + `AZURE_DNS_ZONE_RESOURCE_GROUP` (optional, enable custom-domain DNS records), `AZURE_API_DOMAIN_NAME` (optional), `AZURE_ACR_IMAGE_TAG` (falls back to `ECR_DOCKER_IMAGE_TAG`, then `latest`), `CONTAINER_MIN_REPLICAS` (0 = Lambda parity, 1 = EC2 parity), `AZURE_DEPLOYMENT_TYPE` (default `containerapp`), plus the name overrides above. Existing vars are reused where they are cloud-neutral: `APP_NAME`, `APP_DOMAIN_NAME`, `AWS_S3_CHATBOT_ATTACHMENTS_BUCKET_${STAGE}` (as blob container name), `APP_DB_NAME_${STAGE}`, `APP_FE_URL`.
- **Container port:** default `80` (parity with the AWS EC2 user-data, which runs the container with `-p 80:80`); override via `AZURE_CONTAINER_PORT` only — `BACKEND_LOCAL_PORT` is the local dev port and must NOT be used for the container's listen port.
- **Verification per task:** `bash -n <script>` for every shell script; for every module and stack directory: `tofu fmt -check` and (stacks and modules alike) `tofu init -backend=false -input=false && tofu validate`. No cloud credentials are needed for validation. If `tofu` is not installed: `brew install opentofu` (macOS) — do this once in Task 0.
- **Commits:** made **inside each submodule** (`packages/genericsuite-be-scripts`, `packages/genericsuite-fe-scripts`, `packages/genericsuite-basecamp`) on branch `develop`, message style `Add: <what> [GS-316]` (match `git log --oneline` style of each repo). Do not run `git push` — the human partner pushes.
- **File header comment convention** for new bash scripts: path, one-line purpose, `2026-07-19 | CR [GS-316]`.
- **Do not create** a `domain` stack, `ec2`/`vm` stack, or Application Gateway resources — explicitly out of scope (documented as gaps in Task 14).

---

### Task 0: Setup — branches and toolchain

**Files:** none created.

- [ ] **Step 0.1:** In each of the three submodules, ensure branch `develop` is checked out and clean:

```bash
for p in genericsuite-be-scripts genericsuite-fe-scripts genericsuite-basecamp; do
  git -C "/Users/carlosramirez/desarrollo/genericsuite/packages/${p}" checkout develop
  git -C "/Users/carlosramirez/desarrollo/genericsuite/packages/${p}" status --short
done
```

Expected: each prints `Your branch is up to date...` or switches to `develop`; `status --short` output should be empty (if not, STOP and report — do not stash or discard anything).

- [ ] **Step 0.2:** Verify OpenTofu is available:

```bash
tofu version || brew install opentofu
tofu version
```

Expected: `OpenTofu v1.10.x` (any version >= 1.10).

---

### Task 1: BE state bootstrap script

**Files:**
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/bootstrap-tf-state.sh`

**Interfaces:**
- Produces: `bootstrap-tf-state.sh RESOURCE_GROUP STORAGE_ACCOUNT AZURE_REGION` — idempotently creates the state RG + storage account (versioned, TLS1.2, no public blob access) + `tfstate` container. Called by both wrappers (Task 2 and Task 10).

- [ ] **Step 1.1: Create the script** with exactly this content:

```bash
#!/bin/bash
# scripts/azure_tf/bootstrap-tf-state.sh
# Create/verify the Azure Storage account that stores OpenTofu remote state.
# Azure counterpart of scripts/aws_tf/bootstrap-tf-state.sh.
# 2026-07-19 | CR [GS-316]
# Usage: bash scripts/azure_tf/bootstrap-tf-state.sh RESOURCE_GROUP STORAGE_ACCOUNT AZURE_REGION
set -euo pipefail

RESOURCE_GROUP="${1:-}"
STORAGE_ACCOUNT="${2:-}"
AZURE_REGION="${3:-}"
CONTAINER_NAME="tfstate"

if [ "${RESOURCE_GROUP}" = "" ] || [ "${STORAGE_ACCOUNT}" = "" ] || [ "${AZURE_REGION}" = "" ]; then
    echo "Usage: $0 RESOURCE_GROUP STORAGE_ACCOUNT AZURE_REGION"
    exit 1
fi

if ! az group show --name "${RESOURCE_GROUP}" >/dev/null 2>&1; then
    echo "Creating TF state resource group '${RESOURCE_GROUP}' in '${AZURE_REGION}'..."
    az group create --name "${RESOURCE_GROUP}" --location "${AZURE_REGION}" --output none
fi

if az storage account show --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" >/dev/null 2>&1; then
    echo "TF state storage account '${STORAGE_ACCOUNT}' already exists."
else
    echo "Creating TF state storage account '${STORAGE_ACCOUNT}' in '${AZURE_REGION}'..."
    az storage account create \
        --name "${STORAGE_ACCOUNT}" \
        --resource-group "${RESOURCE_GROUP}" \
        --location "${AZURE_REGION}" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --min-tls-version TLS1_2 \
        --allow-blob-public-access false \
        --output none
    az storage account blob-service-properties update \
        --account-name "${STORAGE_ACCOUNT}" \
        --resource-group "${RESOURCE_GROUP}" \
        --enable-versioning true \
        --output none
fi

az storage container create \
    --name "${CONTAINER_NAME}" \
    --account-name "${STORAGE_ACCOUNT}" \
    --auth-mode key \
    --output none

echo "TF state ready: ${STORAGE_ACCOUNT}/${CONTAINER_NAME} (rg ${RESOURCE_GROUP}, versioned, private)."
```

- [ ] **Step 1.2: Verify syntax**

Run: `bash -n packages/genericsuite-be-scripts/scripts/azure_tf/bootstrap-tf-state.sh`
Expected: no output, exit code 0.

- [ ] **Step 1.3: Commit** (inside the submodule)

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts
git add scripts/azure_tf/bootstrap-tf-state.sh
git commit -m "Add: Azure OpenTofu remote-state bootstrap script (scripts/azure_tf/bootstrap-tf-state.sh) [GS-316]"
```

---

### Task 2: BE deployment wrapper

**Files:**
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/run-tf-deployment.sh`

**Interfaces:**
- Consumes: `bootstrap-tf-state.sh` from Task 1 (positional args `RG SA REGION`).
- Produces: `run-tf-deployment.sh ACTION STAGE STACK [EXTRA...]`. Exports these TF_VARs consumed by all BE stacks (Tasks 3–9): `TF_VAR_app_name`, `TF_VAR_stage`, `TF_VAR_azure_region`, `TF_VAR_azure_subscription_id`, `TF_VAR_resource_group_name`, `TF_VAR_key_vault_name`, `TF_VAR_key_name`, `TF_VAR_storage_account_name`, `TF_VAR_container_name`, `TF_VAR_acr_name`, `TF_VAR_cosmos_account_name`, `TF_VAR_container_app_name`, `TF_VAR_acr_image_tag`, `TF_VAR_container_port`, `TF_VAR_container_min_replicas`, `TF_VAR_app_domain_name`, `TF_VAR_api_domain_name`, `TF_VAR_dns_zone_name`, `TF_VAR_dns_zone_resource_group`, `TF_VAR_tf_state_resource_group`, `TF_VAR_tf_state_storage_account`. Also exports `ARM_SUBSCRIPTION_ID`, and shell vars used by `build-tfvars.sh` hooks: `REPO_BASEDIR`, `SCRIPTS_DIR`, `STAGE`, `STAGE_UPPERCASE`, `APP_NAME_LOWERCASE`.

- [ ] **Step 2.1: Create the script** with exactly this content:

```bash
#!/bin/bash
# scripts/azure_tf/run-tf-deployment.sh
# Generic OpenTofu deployment wrapper for GenericSuite backend Azure stacks.
# Azure counterpart of scripts/aws_tf/run-tf-deployment.sh.
# 2026-07-19 | CR [GS-316]
#
# Usage:
#   bash scripts/azure_tf/run-tf-deployment.sh ACTION STAGE STACK [EXTRA_TOFU_ARGS...]
#
# Parameters:
#   ACTION: init | validate | plan | apply | destroy | output
#   STAGE:  dev | qa | staging | demo | prod
#   STACK:  directory name under scripts/azure_tf/stacks (rg, storage,
#           keyvault, secrets, cosmosdb, acr, containerapp)
#
# Environment:
#   CICD_MODE=1               -> non-interactive (-auto-approve on apply/destroy)
#   TF_STATE_RESOURCE_GROUP   -> override state resource group name
#   TF_STATE_STORAGE_ACCOUNT  -> override state storage account name
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
: "${AZURE_REGION:?ERROR: AZURE_REGION is not set (e.g. eastus)}"

STAGE_UPPERCASE="$(echo "${STAGE}" | tr '[:lower:]' '[:upper:]')"
APP_NAME_LOWERCASE="$(echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]')"
APP_NAME_ALNUM="$(echo "${APP_NAME_LOWERCASE}" | tr -cd 'a-z0-9')"

if [ "${AZURE_SUBSCRIPTION_ID:-}" = "" ]; then
    AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
fi
if [ "${AZURE_SUBSCRIPTION_ID}" = "" ]; then
    echo "ERROR: AZURE_SUBSCRIPTION_ID could not be retrieved. Run 'az login' first."
    exit 1
fi
export ARM_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"

SUB_HASH="$(printf '%s' "${AZURE_SUBSCRIPTION_ID}" | shasum | cut -c1-6)"
SUB_HASH4="$(printf '%s' "${SUB_HASH}" | cut -c1-4)"

TF_STATE_RESOURCE_GROUP="${TF_STATE_RESOURCE_GROUP:-${APP_NAME_LOWERCASE}-tfstate-rg}"
TF_STATE_STORAGE_ACCOUNT="${TF_STATE_STORAGE_ACCOUNT:-$(printf '%s' "${APP_NAME_ALNUM}" | cut -c1-14)tfst${SUB_HASH}}"
TF_STATE_CONTAINER="tfstate"

bash "${SCRIPTS_DIR}/bootstrap-tf-state.sh" \
    "${TF_STATE_RESOURCE_GROUP}" "${TF_STATE_STORAGE_ACCOUNT}" "${AZURE_REGION}"

# Common TF_VARs (every stack declares only the ones it needs)
export TF_VAR_app_name="${APP_NAME_LOWERCASE}"
export TF_VAR_stage="${STAGE}"
export TF_VAR_azure_region="${AZURE_REGION}"
export TF_VAR_azure_subscription_id="${AZURE_SUBSCRIPTION_ID}"
export TF_VAR_resource_group_name="${AZURE_RESOURCE_GROUP:-${APP_NAME_LOWERCASE}-${STAGE}-rg}"
export TF_VAR_key_vault_name="${AZURE_KEY_VAULT_NAME:-kv$(printf '%s' "${APP_NAME_ALNUM}" | cut -c1-8)${STAGE}${SUB_HASH4}}"
export TF_VAR_key_name="${AZURE_KEY_NAME:-genericsuite-key}"

chatbot_bucket_varname="AWS_S3_CHATBOT_ATTACHMENTS_BUCKET_${STAGE_UPPERCASE}"
TF_VAR_container_name="${!chatbot_bucket_varname:-}"
export TF_VAR_container_name
storage_account_varname="AZURE_STORAGE_ACCOUNT_NAME_${STAGE_UPPERCASE}"
TF_VAR_storage_account_name="${!storage_account_varname:-$(printf '%s' "${APP_NAME_ALNUM}" | cut -c1-9)${STAGE}st${SUB_HASH4}}"
export TF_VAR_storage_account_name

export TF_VAR_acr_name="${AZURE_ACR_NAME:-acr$(printf '%s' "${APP_NAME_ALNUM}" | cut -c1-10)${STAGE}${SUB_HASH4}}"
export TF_VAR_cosmos_account_name="${AZURE_COSMOS_ACCOUNT_NAME:-${APP_NAME_LOWERCASE}-${STAGE}-cosmos}"

container_app_default="$(printf '%s' "${APP_NAME_LOWERCASE}" | tr -cd 'a-z0-9-' | cut -c1-15)-be-${STAGE}"
export TF_VAR_container_app_name="${AZURE_CONTAINER_APP_NAME:-${container_app_default}}"
export TF_VAR_acr_image_tag="${AZURE_ACR_IMAGE_TAG:-${ECR_DOCKER_IMAGE_TAG:-latest}}"
export TF_VAR_container_port="${AZURE_CONTAINER_PORT:-80}"
export TF_VAR_container_min_replicas="${CONTAINER_MIN_REPLICAS:-0}"
export TF_VAR_app_domain_name="${APP_DOMAIN_NAME:-}"
export TF_VAR_api_domain_name="${AZURE_API_DOMAIN_NAME:-}"
export TF_VAR_dns_zone_name="${AZURE_DNS_ZONE_NAME:-}"
export TF_VAR_dns_zone_resource_group="${AZURE_DNS_ZONE_RESOURCE_GROUP:-}"
export TF_VAR_tf_state_resource_group="${TF_STATE_RESOURCE_GROUP}"
export TF_VAR_tf_state_storage_account="${TF_STATE_STORAGE_ACCOUNT}"

# Optional per-stack variable builder (e.g. secrets maps, cosmosdb tables)
if [ -f "${SCRIPTS_DIR}/stacks/${STACK}/build-tfvars.sh" ]; then
    # shellcheck disable=SC1090
    . "${SCRIPTS_DIR}/stacks/${STACK}/build-tfvars.sh"
fi

cd "${SCRIPTS_DIR}/stacks/${STACK}"

echo ""
echo "RUN-TF-DEPLOYMENT (azure) | action=${ACTION} stage=${STAGE} stack=${STACK}"
echo "State: ${TF_STATE_STORAGE_ACCOUNT}/${TF_STATE_CONTAINER}/${STAGE}/${STACK}.tfstate (rg ${TF_STATE_RESOURCE_GROUP})"
echo ""

tofu init -reconfigure -input=false \
    -backend-config="resource_group_name=${TF_STATE_RESOURCE_GROUP}" \
    -backend-config="storage_account_name=${TF_STATE_STORAGE_ACCOUNT}" \
    -backend-config="container_name=${TF_STATE_CONTAINER}" \
    -backend-config="key=${STAGE}/${STACK}.tfstate"

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

- [ ] **Step 2.2: Verify syntax**

Run: `bash -n packages/genericsuite-be-scripts/scripts/azure_tf/run-tf-deployment.sh`
Expected: no output, exit code 0.

- [ ] **Step 2.3: Verify usage error path** (no Azure credentials needed)

Run: `cd /tmp && bash /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts/scripts/azure_tf/run-tf-deployment.sh 2>&1 | head -2; cd -`
Expected output starts with: `ERROR: ACTION is not set` (exit via usage; the `stacks` dir doesn't exist yet so the STACK list line may print an `ls` warning — that is acceptable at this task; it disappears after Task 3).

- [ ] **Step 2.4: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts
git add scripts/azure_tf/run-tf-deployment.sh
git commit -m "Add: Azure OpenTofu generic deployment wrapper (scripts/azure_tf/run-tf-deployment.sh) [GS-316]"
```

---

### Task 3: `resource-group` module + `rg` stack

**Files:**
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/modules/resource-group/{main.tf,variables.tf,outputs.tf,versions.tf}`
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/stacks/rg/{backend.tf,providers.tf,versions.tf,main.tf,variables.tf,outputs.tf}`

**Interfaces:**
- Consumes: wrapper TF_VARs `app_name`, `stage`, `azure_region`, `azure_subscription_id`, `resource_group_name`.
- Produces: the app+stage resource group. All other BE stacks receive the same `resource_group_name` string from the wrapper and reference it by name (no remote state needed for the RG). Stack outputs: `resource_group_name`, `resource_group_id`.

- [ ] **Step 3.1: Create `modules/resource-group/versions.tf`** (this exact `versions.tf` is reused VERBATIM in every module and stack of Tasks 3–9 — copy it each time it is referenced below):

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
```

- [ ] **Step 3.2: Create `modules/resource-group/main.tf`**

```hcl
locals {
  common_tags = {
    App       = var.app_name
    Stage     = var.stage
    ManagedBy = "opentofu"
    Ticket    = "GS-316"
  }
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.azure_region
  tags     = local.common_tags
}
```

- [ ] **Step 3.3: Create `modules/resource-group/variables.tf`**

```hcl
variable "resource_group_name" {
  description = "Resource group name (e.g. myapp-qa-rg)"
  type        = string
}

variable "azure_region" {
  description = "Azure region (location)"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage (dev, qa, staging, demo, prod)"
  type        = string
}
```

- [ ] **Step 3.4: Create `modules/resource-group/outputs.tf`**

```hcl
output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.this.name
}

output "resource_group_id" {
  description = "Resource group ID"
  value       = azurerm_resource_group.this.id
}
```

- [ ] **Step 3.5: Create `stacks/rg/backend.tf`** (this exact `backend.tf` is reused VERBATIM in every BE stack):

```hcl
terraform {
  backend "azurerm" {}
}
```

- [ ] **Step 3.6: Create `stacks/rg/providers.tf`** (this exact `providers.tf` is reused VERBATIM in every BE stack):

```hcl
provider "azurerm" {
  subscription_id = var.azure_subscription_id

  features {}
}
```

- [ ] **Step 3.7: Create `stacks/rg/versions.tf`** — same content as Step 3.1.

- [ ] **Step 3.8: Create `stacks/rg/main.tf`**

```hcl
module "resource_group" {
  source = "../../modules/resource-group"

  resource_group_name = var.resource_group_name
  azure_region        = var.azure_region
  app_name            = var.app_name
  stage               = var.stage
}
```

- [ ] **Step 3.9: Create `stacks/rg/variables.tf`** (these five variables are the "common stack variables"; other stacks add to them):

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "azure_region" {
  description = "Azure region (location)"
  type        = string
}

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "App resource group name (resolved by wrapper)"
  type        = string
}
```

- [ ] **Step 3.10: Create `stacks/rg/outputs.tf`**

```hcl
output "resource_group_name" {
  description = "Resource group name"
  value       = module.resource_group.resource_group_name
}

output "resource_group_id" {
  description = "Resource group ID"
  value       = module.resource_group.resource_group_id
}
```

- [ ] **Step 3.11: Validate**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts/scripts/azure_tf
tofu fmt -check -recursive modules/resource-group stacks/rg
( cd stacks/rg && tofu init -backend=false -input=false >/dev/null && tofu validate )
```

Expected: `fmt` prints nothing; validate prints `Success! The configuration is valid.`

- [ ] **Step 3.12: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts
git add scripts/azure_tf/modules/resource-group scripts/azure_tf/stacks/rg
git commit -m "Add: Azure OpenTofu resource-group module and rg stack [GS-316]"
```

---

### Task 4: `storage-blob` module + `storage` stack

**Files:**
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/modules/storage-blob/{main.tf,variables.tf,outputs.tf,versions.tf}`
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/stacks/storage/{backend.tf,providers.tf,versions.tf,main.tf,variables.tf,outputs.tf}`

**Interfaces:**
- Consumes: wrapper TF_VARs (common five) + `storage_account_name`, `container_name`.
- Produces: stack outputs `storage_account_name`, `storage_account_id`, `container_name`, `primary_blob_endpoint` — `storage_account_id` is read by the `containerapp` stack (Task 9) via remote state key `{stage}/storage.tfstate`.

- [ ] **Step 4.1: Create `modules/storage-blob/main.tf`**

```hcl
locals {
  common_tags = {
    App       = var.app_name
    Stage     = var.stage
    ManagedBy = "opentofu"
    Ticket    = "GS-316"
  }
}

resource "azurerm_storage_account" "this" {
  name                            = var.storage_account_name
  resource_group_name             = var.resource_group_name
  location                        = var.azure_region
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = var.enable_public_read

  tags = merge(local.common_tags, {
    comment = "Created by OpenTofu in ${var.stage} environment."
  })
}

resource "azurerm_storage_container" "this" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = var.enable_public_read ? "blob" : "private"
}
```

- [ ] **Step 4.2: Create `modules/storage-blob/variables.tf`**

```hcl
variable "storage_account_name" {
  description = "Storage account name (3-24 lowercase alphanumerics, globally unique)"
  type        = string
}

variable "container_name" {
  description = "Blob container name (parity with the AWS chatbot-attachments bucket name)"
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group name (created by the rg stack)"
  type        = string
}

variable "azure_region" {
  description = "Azure region (location)"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage (dev, qa, staging, demo, prod)"
  type        = string
}

variable "enable_public_read" {
  description = "Allow anonymous blob read (legacy parity; keep false)"
  type        = bool
  default     = false
}
```

- [ ] **Step 4.3: Create `modules/storage-blob/outputs.tf`**

```hcl
output "storage_account_name" {
  description = "Storage account name"
  value       = azurerm_storage_account.this.name
}

output "storage_account_id" {
  description = "Storage account resource ID"
  value       = azurerm_storage_account.this.id
}

output "container_name" {
  description = "Blob container name"
  value       = azurerm_storage_container.this.name
}

output "primary_blob_endpoint" {
  description = "Primary blob endpoint URL"
  value       = azurerm_storage_account.this.primary_blob_endpoint
}
```

- [ ] **Step 4.4: Create `modules/storage-blob/versions.tf`** — same content as Step 3.1.

- [ ] **Step 4.5: Create `stacks/storage/backend.tf`, `providers.tf`, `versions.tf`** — same content as Steps 3.5, 3.6, 3.1 respectively.

- [ ] **Step 4.6: Create `stacks/storage/main.tf`**

```hcl
module "chatbot_attachments_storage" {
  source = "../../modules/storage-blob"

  storage_account_name = var.storage_account_name
  container_name       = var.container_name
  resource_group_name  = var.resource_group_name
  azure_region         = var.azure_region
  app_name             = var.app_name
  stage                = var.stage
  enable_public_read   = var.enable_public_read
}
```

- [ ] **Step 4.7: Create `stacks/storage/variables.tf`** — the five common stack variables from Step 3.9 PLUS:

```hcl
variable "storage_account_name" {
  description = "Storage account name (resolved by wrapper)"
  type        = string
}

variable "container_name" {
  description = "Chatbot attachments blob container name (stage-resolved by wrapper)"
  type        = string
}

variable "enable_public_read" {
  description = "Allow anonymous blob read on the container"
  type        = bool
  default     = false
}
```

- [ ] **Step 4.8: Create `stacks/storage/outputs.tf`**

```hcl
output "storage_account_name" {
  description = "Chatbot attachments storage account name"
  value       = module.chatbot_attachments_storage.storage_account_name
}

output "storage_account_id" {
  description = "Chatbot attachments storage account resource ID"
  value       = module.chatbot_attachments_storage.storage_account_id
}

output "container_name" {
  description = "Chatbot attachments container name"
  value       = module.chatbot_attachments_storage.container_name
}

output "primary_blob_endpoint" {
  description = "Primary blob endpoint URL"
  value       = module.chatbot_attachments_storage.primary_blob_endpoint
}
```

- [ ] **Step 4.9: Validate** — same commands as Step 3.11 with `modules/storage-blob stacks/storage` and `cd stacks/storage`. Expected: `Success! The configuration is valid.`

- [ ] **Step 4.10: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts
git add scripts/azure_tf/modules/storage-blob scripts/azure_tf/stacks/storage
git commit -m "Add: Azure OpenTofu storage-blob module and storage stack [GS-316]"
```

---

### Task 5: `key-vault` module + `keyvault` stack

**Files:**
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/modules/key-vault/{main.tf,variables.tf,outputs.tf,versions.tf}`
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/stacks/keyvault/{backend.tf,providers.tf,versions.tf,main.tf,variables.tf,outputs.tf}`

**Interfaces:**
- Consumes: wrapper TF_VARs (common five) + `key_vault_name`, `key_name`.
- Produces: stack outputs `key_vault_id`, `key_vault_name`, `key_vault_uri`, `key_id` — `key_vault_id` is read by the `containerapp` stack (Task 9) via remote state key `{stage}/keyvault.tfstate`. The deployer gets the "Key Vault Administrator" role so the `secrets` stack (Task 6) can write secrets.

- [ ] **Step 5.1: Create `modules/key-vault/main.tf`**

```hcl
data "azurerm_client_config" "current" {}

locals {
  common_tags = {
    App       = var.app_name
    Stage     = var.stage
    ManagedBy = "opentofu"
    Ticket    = "GS-316"
  }
}

resource "azurerm_key_vault" "this" {
  name                       = var.key_vault_name
  location                   = var.azure_region
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

  tags = local.common_tags
}

resource "azurerm_role_assignment" "deployer_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_key" "this" {
  name         = var.key_name
  key_vault_id = azurerm_key_vault.this.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  depends_on = [azurerm_role_assignment.deployer_admin]
}
```

- [ ] **Step 5.2: Create `modules/key-vault/variables.tf`**

```hcl
variable "key_vault_name" {
  description = "Key Vault name (3-24 chars, globally unique)"
  type        = string
}

variable "key_name" {
  description = "Key name (parity with the AWS KMS alias)"
  type        = string
  default     = "genericsuite-key"
}

variable "resource_group_name" {
  description = "Existing resource group name (created by the rg stack)"
  type        = string
}

variable "azure_region" {
  description = "Azure region (location)"
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
```

- [ ] **Step 5.3: Create `modules/key-vault/outputs.tf`**

```hcl
output "key_vault_id" {
  description = "Key Vault resource ID"
  value       = azurerm_key_vault.this.id
}

output "key_vault_name" {
  description = "Key Vault name"
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.this.vault_uri
}

output "key_id" {
  description = "Key ID (genericsuite-key parity)"
  value       = azurerm_key_vault_key.this.id
}
```

- [ ] **Step 5.4: Create `modules/key-vault/versions.tf`** — same content as Step 3.1.

- [ ] **Step 5.5: Create `stacks/keyvault/backend.tf`, `providers.tf`, `versions.tf`** — same content as Steps 3.5, 3.6, 3.1.

- [ ] **Step 5.6: Create `stacks/keyvault/main.tf`**

```hcl
module "key_vault" {
  source = "../../modules/key-vault"

  key_vault_name      = var.key_vault_name
  key_name            = var.key_name
  resource_group_name = var.resource_group_name
  azure_region        = var.azure_region
  app_name            = var.app_name
  stage               = var.stage
}
```

- [ ] **Step 5.7: Create `stacks/keyvault/variables.tf`** — the five common stack variables from Step 3.9 PLUS:

```hcl
variable "key_vault_name" {
  description = "Key Vault name (resolved by wrapper)"
  type        = string
}

variable "key_name" {
  description = "Key name"
  type        = string
  default     = "genericsuite-key"
}
```

- [ ] **Step 5.8: Create `stacks/keyvault/outputs.tf`**

```hcl
output "key_vault_id" {
  description = "Key Vault resource ID"
  value       = module.key_vault.key_vault_id
}

output "key_vault_name" {
  description = "Key Vault name"
  value       = module.key_vault.key_vault_name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = module.key_vault.key_vault_uri
}

output "key_id" {
  description = "Key ID"
  value       = module.key_vault.key_id
}
```

- [ ] **Step 5.9: Validate** — same commands as Step 3.11 with `modules/key-vault stacks/keyvault` and `cd stacks/keyvault`. Expected: `Success! The configuration is valid.`

- [ ] **Step 5.10: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts
git add scripts/azure_tf/modules/key-vault scripts/azure_tf/stacks/keyvault
git commit -m "Add: Azure OpenTofu key-vault module and keyvault stack [GS-316]"
```

---

### Task 6: `secrets` module + `secrets` stack + build-tfvars

**Files:**
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/modules/secrets/{main.tf,variables.tf,outputs.tf,versions.tf}`
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/stacks/secrets/{backend.tf,providers.tf,versions.tf,main.tf,variables.tf,outputs.tf,build-tfvars.sh}`

**Interfaces:**
- Consumes: the Key Vault created in Task 5 (looked up by `key_vault_name` + `resource_group_name`); wrapper shell vars `REPO_BASEDIR`, `SCRIPTS_DIR`, `STAGE`, `STAGE_UPPERCASE`, `APP_NAME_LOWERCASE` inside `build-tfvars.sh`.
- Produces: Key Vault secrets `{app}-{stage}-secrets` and `{app}-{stage}-envs` (JSON blobs, same content contract as AWS Secrets Manager). Stack outputs `secrets_secret_uri`, `envs_secret_uri` (versionless URIs) — read by the `containerapp` stack (Task 9) via remote state key `{stage}/secrets.tfstate`.

- [ ] **Step 6.1: Create `modules/secrets/main.tf`**

```hcl
data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

locals {
  stage_uppercase = upper(var.stage)
}

resource "azurerm_key_vault_secret" "encrypted" {
  name         = "${var.app_name}-${var.stage}-secrets"
  key_vault_id = data.azurerm_key_vault.this.id
  value        = jsonencode(var.secrets_map)
  content_type = "application/json"

  tags = {
    description = "Encrypted-Secrets-for-${var.app_name}-${local.stage_uppercase}"
  }
}

resource "azurerm_key_vault_secret" "envs" {
  name         = "${var.app_name}-${var.stage}-envs"
  key_vault_id = data.azurerm_key_vault.this.id
  value        = jsonencode(var.envs_map)
  content_type = "application/json"

  tags = {
    description = "Environment-variables-for-${var.app_name}-${local.stage_uppercase}"
  }
}
```

- [ ] **Step 6.2: Create `modules/secrets/variables.tf`**

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "key_vault_name" {
  description = "Key Vault holding both secret sets (created by the keyvault stack)"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group of the Key Vault"
  type        = string
}

variable "secrets_map" {
  description = "Encrypted secrets key/value map"
  type        = map(string)
  sensitive   = true
}

variable "envs_map" {
  description = "Plain environment variables key/value map"
  type        = map(string)
}
```

- [ ] **Step 6.3: Create `modules/secrets/outputs.tf`**

```hcl
output "secrets_secret_uri" {
  description = "Versionless URI of the encrypted secrets set"
  value       = azurerm_key_vault_secret.encrypted.versionless_id
}

output "envs_secret_uri" {
  description = "Versionless URI of the plain envvars set"
  value       = azurerm_key_vault_secret.envs.versionless_id
}
```

- [ ] **Step 6.4: Create `modules/secrets/versions.tf`** — same content as Step 3.1.

- [ ] **Step 6.5: Create `stacks/secrets/backend.tf`, `providers.tf`, `versions.tf`** — same content as Steps 3.5, 3.6, 3.1.

- [ ] **Step 6.6: Create `stacks/secrets/main.tf`**

```hcl
module "secrets" {
  source = "../../modules/secrets"

  app_name            = var.app_name
  stage               = var.stage
  key_vault_name      = var.key_vault_name
  resource_group_name = var.resource_group_name
  secrets_map         = var.secrets_map
  envs_map            = var.envs_map
}
```

- [ ] **Step 6.7: Create `stacks/secrets/variables.tf`** — the five common stack variables from Step 3.9 PLUS:

```hcl
variable "key_vault_name" {
  description = "Key Vault name (resolved by wrapper)"
  type        = string
}

variable "secrets_map" {
  description = "Encrypted secrets key/value map (built by build-tfvars.sh)"
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "envs_map" {
  description = "Plain environment variables key/value map (built by build-tfvars.sh)"
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 6.8: Create `stacks/secrets/outputs.tf`**

```hcl
output "secrets_secret_uri" {
  description = "Versionless URI of the encrypted secrets set"
  value       = module.secrets.secrets_secret_uri
}

output "envs_secret_uri" {
  description = "Versionless URI of the plain envvars set"
  value       = module.secrets.envs_secret_uri
}
```

- [ ] **Step 6.9: Create `stacks/secrets/build-tfvars.sh`** — Azure port of `scripts/aws_tf/stacks/secrets/build-tfvars.sh`, with these deltas: `AZURE_REGION` added to CORE_ENVS, hostname suffix `-az`, and an Azure-first app hook. Exact content:

```bash
#!/bin/bash
# stacks/secrets/build-tfvars.sh
# Sourced by run-tf-deployment.sh. Builds TF_VAR_secrets_map and
# TF_VAR_envs_map as JSON from the same variable lists used by
# scripts/aws_secrets/aws_secrets_manager.sh and the aws_tf secrets stack.
# 2026-07-19 | CR [GS-316]

# Secrets (encrypted)
CORE_SECRETS="APP_SECRET_KEY APP_SUPERADMIN_EMAIL APP_DB_URI SMTP_USER SMTP_PASSWORD SMTP_DEFAULT_SENDER STORAGE_URL_SEED"
EXTENSION_SECRETS="OPENAI_API_KEY GOOGLE_API_KEY GOOGLE_CSE_ID GOOGLE_MAPS_API_KEY \
    ANTHROPIC_API_KEY LANGCHAIN_API_KEY HUGGINGFACE_API_KEY GROQ_API_KEY AIMLAPI_API_KEY \
    NVIDIA_API_KEY RHYMES_CHAT_API_KEY RHYMES_VIDEO_API_KEY IBM_WATSONX_API_KEY \
    IBM_WATSONX_PROJECT_ID OPENROUTER_API_KEY XAI_API_KEY TOGETHER_API_KEY"
APP_SECRETS="${APP_SECRETS:-}"

# Environment variables (plain)
CORE_ENVS="APP_NAME FLASK_APP APP_DEBUG APP_STAGE APP_CORS_ORIGIN APP_DB_ENGINE APP_DB_NAME CURRENT_FRAMEWORK DEFAULT_LANG GIT_SUBMODULE_URL GIT_SUBMODULE_LOCAL_PATH SMTP_SERVER SMTP_PORT SMTP_DEFAULT_SENDER APP_HOST_NAME CLOUD_PROVIDER AZURE_REGION AWS_REGION DYNAMDB_PREFIX"
EXTENSION_ENVS="AI_ASSISTANT_NAME AWS_S3_CHATBOT_ATTACHMENTS_BUCKET OPENAI_MODEL OPENAI_TEMPERATURE LANGCHAIN_PROJECT USER_AGENT HUGGINGFACE_DEFAULT_CHAT_MODEL"
APP_ENVS="${APP_ENVS:-}"

# App-specific additions hook (Azure-specific first, then the shared AWS-era hook)
if [ -f "${REPO_BASEDIR}/scripts/azure/update_additional_envvars.sh" ]; then
    # shellcheck disable=SC1091
    . "${REPO_BASEDIR}/scripts/azure/update_additional_envvars.sh" "" "${REPO_BASEDIR}"
elif [ -f "${REPO_BASEDIR}/scripts/aws/update_additional_envvars.sh" ]; then
    # shellcheck disable=SC1091
    . "${REPO_BASEDIR}/scripts/aws/update_additional_envvars.sh" "" "${REPO_BASEDIR}"
fi

# Resolve stage-dependent variables (VAR = VAR_${STAGE_UPPERCASE})
STAGE_DEPENDENT_VAR_LIST="${STAGE_DEPENDENT_VAR_LIST:-APP_DB_ENGINE APP_DB_NAME APP_DB_URI APP_CORS_ORIGIN AWS_S3_CHATBOT_ATTACHMENTS_BUCKET}"
for base_name in ${STAGE_DEPENDENT_VAR_LIST}; do
    resolved_varname="${base_name}_${STAGE_UPPERCASE}"
    resolved="${!resolved_varname:-}"
    if [ "${resolved}" != "" ]; then
        printf -v "${base_name}" '%s' "${resolved}"
        export "${base_name}"
    fi
done

# Special envvars not in .env (parity with aws_secrets_manager.sh prepare_envars)
export APP_STAGE="${STAGE}"
export USER_AGENT="${APP_NAME_LOWERCASE}-${STAGE}"
export DYNAMDB_PREFIX="${APP_NAME_LOWERCASE}_${STAGE}_"
AZURE_DEPLOYMENT_TYPE="${AZURE_DEPLOYMENT_TYPE:-containerapp}"
if [ "${AZURE_DEPLOYMENT_TYPE}" = "containerapp" ]; then
    export APP_HOST_NAME="app-${STAGE}-az.${APP_DOMAIN_NAME:-}"
fi
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

- [ ] **Step 6.10: Verify** — `bash -n` on `build-tfvars.sh` (expected: silent), then the Step 3.11 validate commands with `modules/secrets stacks/secrets` and `cd stacks/secrets`. Expected: `Success! The configuration is valid.`

- [ ] **Step 6.11: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts
git add scripts/azure_tf/modules/secrets scripts/azure_tf/stacks/secrets
git commit -m "Add: Azure OpenTofu Key Vault secrets module, stack and env map builder [GS-316]"
```

---

### Task 7: `cosmosdb-mongo` module + `cosmosdb` stack + build-tfvars + .gitignore

**Files:**
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/modules/cosmosdb-mongo/{main.tf,variables.tf,outputs.tf,versions.tf}`
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/stacks/cosmosdb/{backend.tf,providers.tf,versions.tf,main.tf,variables.tf,outputs.tf,build-tfvars.sh}`
- Modify: `packages/genericsuite-be-scripts/.gitignore` (append azure_tf entries)

**Interfaces:**
- Consumes: `scripts/aws_tf/generate_dynamodb_tfvars.py` (cloud-agnostic table extractor, reused as-is — it emits `{"tables": [{"name", "hash_key", "range_key"?}]}`); wrapper shell vars `REPO_BASEDIR`, `SCRIPTS_DIR`, `STAGE_UPPERCASE`, `APP_NAME_LOWERCASE`, `STAGE`, and .env vars `GIT_SUBMODULE_LOCAL_PATH`, `APP_DB_NAME_${STAGE}`.
- Produces: Cosmos DB account (MongoDB API, serverless), one Mongo database, one collection per GenericSuite table. Stack outputs: `cosmos_account_name`, `database_name`, `connection_string` (sensitive).

- [ ] **Step 7.1: Create `modules/cosmosdb-mongo/main.tf`**

```hcl
locals {
  common_tags = {
    App       = var.app_name
    Stage     = var.stage
    ManagedBy = "opentofu"
    Ticket    = "GS-316"
  }
}

resource "azurerm_cosmosdb_account" "this" {
  name                = var.account_name
  location            = var.azure_region
  resource_group_name = var.resource_group_name
  offer_type          = "Standard"
  kind                = "MongoDB"

  mongo_server_version = "4.2"

  capabilities {
    name = "EnableServerless"
  }

  capabilities {
    name = "EnableMongo"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.azure_region
    failover_priority = 0
  }

  tags = local.common_tags
}

resource "azurerm_cosmosdb_mongo_database" "this" {
  name                = var.database_name
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
}

resource "azurerm_cosmosdb_mongo_collection" "this" {
  for_each = { for t in var.tables : t.name => t }

  name                = each.value.name
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
  database_name       = azurerm_cosmosdb_mongo_database.this.name

  index {
    keys   = ["_id"]
    unique = true
  }
}
```

- [ ] **Step 7.2: Create `modules/cosmosdb-mongo/variables.tf`**

```hcl
variable "account_name" {
  description = "Cosmos DB account name (globally unique)"
  type        = string
}

variable "database_name" {
  description = "Mongo database name (parity with APP_DB_NAME)"
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group name (created by the rg stack)"
  type        = string
}

variable "azure_region" {
  description = "Azure region (location)"
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

variable "tables" {
  description = "Collection definitions from the GenericSuite JSON config"
  type = list(object({
    name      = string
    hash_key  = string
    range_key = optional(string)
  }))
}
```

- [ ] **Step 7.3: Create `modules/cosmosdb-mongo/outputs.tf`**

```hcl
output "cosmos_account_name" {
  description = "Cosmos DB account name"
  value       = azurerm_cosmosdb_account.this.name
}

output "database_name" {
  description = "Mongo database name"
  value       = azurerm_cosmosdb_mongo_database.this.name
}

output "connection_string" {
  description = "Primary MongoDB connection string (use as APP_DB_URI)"
  value       = azurerm_cosmosdb_account.this.primary_mongodb_connection_string
  sensitive   = true
}
```

- [ ] **Step 7.4: Create `modules/cosmosdb-mongo/versions.tf`** — same content as Step 3.1.

- [ ] **Step 7.5: Create `stacks/cosmosdb/backend.tf`, `providers.tf`, `versions.tf`** — same content as Steps 3.5, 3.6, 3.1.

- [ ] **Step 7.6: Create `stacks/cosmosdb/main.tf`**

```hcl
module "cosmosdb" {
  source = "../../modules/cosmosdb-mongo"

  account_name        = var.cosmos_account_name
  database_name       = var.database_name
  resource_group_name = var.resource_group_name
  azure_region        = var.azure_region
  app_name            = var.app_name
  stage               = var.stage
  tables              = var.tables
}
```

- [ ] **Step 7.7: Create `stacks/cosmosdb/variables.tf`** — the five common stack variables from Step 3.9 PLUS:

```hcl
variable "cosmos_account_name" {
  description = "Cosmos DB account name (resolved by wrapper)"
  type        = string
}

variable "database_name" {
  description = "Mongo database name (resolved by build-tfvars.sh)"
  type        = string
}

variable "tables" {
  description = "Collection definitions (generated into cosmosdb.auto.tfvars.json)"
  type = list(object({
    name      = string
    hash_key  = string
    range_key = optional(string)
  }))
  default = []
}
```

- [ ] **Step 7.8: Create `stacks/cosmosdb/outputs.tf`**

```hcl
output "cosmos_account_name" {
  description = "Cosmos DB account name"
  value       = module.cosmosdb.cosmos_account_name
}

output "database_name" {
  description = "Mongo database name"
  value       = module.cosmosdb.database_name
}

output "connection_string" {
  description = "Primary MongoDB connection string (use as APP_DB_URI)"
  value       = module.cosmosdb.connection_string
  sensitive   = true
}
```

- [ ] **Step 7.9: Create `stacks/cosmosdb/build-tfvars.sh`**

```bash
#!/bin/bash
# stacks/cosmosdb/build-tfvars.sh
# Sourced by run-tf-deployment.sh. Generates cosmosdb.auto.tfvars.json from
# the GenericSuite JSON config dir (GIT_SUBMODULE_LOCAL_PATH), reusing the
# cloud-agnostic table extractor from the aws_tf directory.
# 2026-07-19 | CR [GS-316]

if [ "${GIT_SUBMODULE_LOCAL_PATH:-}" = "" ]; then
    echo "ERROR: GIT_SUBMODULE_LOCAL_PATH is not set (needed to locate the JSON config dir)"
    exit 1
fi

COSMOS_CONFIG_DIR="${REPO_BASEDIR}/${GIT_SUBMODULE_LOCAL_PATH}"
if [ ! -d "${COSMOS_CONFIG_DIR}/frontend" ]; then
    echo "ERROR: '${COSMOS_CONFIG_DIR}/frontend' not found"
    exit 1
fi

python3 "${SCRIPTS_DIR}/../aws_tf/generate_dynamodb_tfvars.py" \
    "${COSMOS_CONFIG_DIR}" \
    "${SCRIPTS_DIR}/stacks/cosmosdb/cosmosdb.auto.tfvars.json"

db_name_varname="APP_DB_NAME_${STAGE_UPPERCASE}"
TF_VAR_database_name="${!db_name_varname:-${APP_NAME_LOWERCASE}_${STAGE}}"
export TF_VAR_database_name
```

- [ ] **Step 7.10: Append azure_tf entries to `.gitignore`** — first check what the aws_tf path ignores:

Run: `grep -n "aws_tf\|terraform\|tfstate\|tfvars" packages/genericsuite-be-scripts/.gitignore`

Then append (only the lines not already covered by an existing generic pattern — if a generic `**/.terraform/` style rule already matches, skip that line):

```
# Azure OpenTofu working files [GS-316]
scripts/azure_tf/**/.terraform/
scripts/azure_tf/**/.terraform.lock.hcl
scripts/azure_tf/**/*.tfstate
scripts/azure_tf/**/*.tfstate.*
scripts/azure_tf/stacks/cosmosdb/cosmosdb.auto.tfvars.json
```

- [ ] **Step 7.11: Verify** — `bash -n` on `build-tfvars.sh` (silent), then Step 3.11 validate commands with `modules/cosmosdb-mongo stacks/cosmosdb` and `cd stacks/cosmosdb`. Expected: `Success! The configuration is valid.`

- [ ] **Step 7.12: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts
git add scripts/azure_tf/modules/cosmosdb-mongo scripts/azure_tf/stacks/cosmosdb .gitignore
git commit -m "Add: Azure OpenTofu Cosmos DB (MongoDB API) module and cosmosdb stack reusing the GenericSuite table config generator [GS-316]"
```

---

### Task 8: `acr-registry` module + `acr` stack

**Files:**
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/modules/acr-registry/{main.tf,variables.tf,outputs.tf,versions.tf}`
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/stacks/acr/{backend.tf,providers.tf,versions.tf,main.tf,variables.tf,outputs.tf}`

**Interfaces:**
- Consumes: wrapper TF_VARs (common five) + `acr_name`.
- Produces: stack outputs `acr_id`, `acr_name`, `login_server` — read by the `containerapp` stack (Task 9) via remote state key `{stage}/acr.tfstate`. Docker build/push stays in bash (`az acr login --name <acr_name>` + `docker push <login_server>/<repo>:<tag>`).

- [ ] **Step 8.1: Create `modules/acr-registry/main.tf`**

```hcl
locals {
  common_tags = {
    App       = var.app_name
    Stage     = var.stage
    ManagedBy = "opentofu"
    Ticket    = "GS-316"
  }
}

resource "azurerm_container_registry" "this" {
  name                = var.registry_name
  resource_group_name = var.resource_group_name
  location            = var.azure_region
  sku                 = var.sku
  admin_enabled       = false

  tags = local.common_tags
}
```

- [ ] **Step 8.2: Create `modules/acr-registry/variables.tf`**

```hcl
variable "registry_name" {
  description = "ACR name (5-50 alphanumerics, globally unique)"
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group name (created by the rg stack)"
  type        = string
}

variable "azure_region" {
  description = "Azure region (location)"
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

variable "sku" {
  description = "ACR SKU; untagged-manifest retention policies require Premium"
  type        = string
  default     = "Basic"
}
```

- [ ] **Step 8.3: Create `modules/acr-registry/outputs.tf`**

```hcl
output "acr_id" {
  description = "Container registry resource ID"
  value       = azurerm_container_registry.this.id
}

output "acr_name" {
  description = "Container registry name"
  value       = azurerm_container_registry.this.name
}

output "login_server" {
  description = "Registry login server (e.g. myacr.azurecr.io)"
  value       = azurerm_container_registry.this.login_server
}
```

- [ ] **Step 8.4: Create `modules/acr-registry/versions.tf`** — same content as Step 3.1.

- [ ] **Step 8.5: Create `stacks/acr/backend.tf`, `providers.tf`, `versions.tf`** — same content as Steps 3.5, 3.6, 3.1.

- [ ] **Step 8.6: Create `stacks/acr/main.tf`**

```hcl
module "registry" {
  source = "../../modules/acr-registry"

  registry_name       = var.acr_name
  resource_group_name = var.resource_group_name
  azure_region        = var.azure_region
  app_name            = var.app_name
  stage               = var.stage
}
```

- [ ] **Step 8.7: Create `stacks/acr/variables.tf`** — the five common stack variables from Step 3.9 PLUS:

```hcl
variable "acr_name" {
  description = "Container registry name (resolved by wrapper)"
  type        = string
}
```

- [ ] **Step 8.8: Create `stacks/acr/outputs.tf`**

```hcl
output "acr_id" {
  description = "Container registry resource ID"
  value       = module.registry.acr_id
}

output "acr_name" {
  description = "Container registry name"
  value       = module.registry.acr_name
}

output "login_server" {
  description = "Registry login server"
  value       = module.registry.login_server
}
```

- [ ] **Step 8.9: Validate** — Step 3.11 commands with `modules/acr-registry stacks/acr` and `cd stacks/acr`. Expected: `Success! The configuration is valid.`

- [ ] **Step 8.10: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts
git add scripts/azure_tf/modules/acr-registry scripts/azure_tf/stacks/acr
git commit -m "Add: Azure OpenTofu container registry module and acr stack [GS-316]"
```

---

### Task 9: `container-api` module + `containerapp` stack

**Files:**
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/modules/container-api/{main.tf,variables.tf,outputs.tf,versions.tf}`
- Create: `packages/genericsuite-be-scripts/scripts/azure_tf/stacks/containerapp/{backend.tf,providers.tf,versions.tf,main.tf,variables.tf,outputs.tf}`

**Interfaces:**
- Consumes: remote-state outputs from earlier stacks — `acr` (`acr_id`, `login_server` from Task 8), `keyvault` (`key_vault_id` from Task 5), `secrets` (`secrets_secret_uri`, `envs_secret_uri` from Task 6), `storage` (`storage_account_id` from Task 4) — plus wrapper TF_VARs `container_app_name`, `acr_image_tag`, `container_port`, `container_min_replicas`, `api_domain_name`, `dns_zone_name`, `dns_zone_resource_group`, `tf_state_resource_group`, `tf_state_storage_account`.
- Produces: Log Analytics workspace, Container Apps environment, user-assigned identity (with AcrPull / Key Vault Secrets User / Storage Blob Data Contributor roles), the container app itself, and (optionally) Azure DNS records + custom domain binding. Stack outputs: `endpoint_url`, `container_app_fqdn`, `custom_domain_url`, `identity_principal_id`.
- Design note: a **user-assigned** identity (not system-assigned) is used so the AcrPull role exists BEFORE the app first pulls its image — this avoids the chicken-and-egg race a system identity has. `min_replicas = 0` replicates Lambda scale-to-zero; `CONTAINER_MIN_REPLICAS=1` replicates the EC2 always-on path. Managed TLS for the custom domain: the binding is created with `ignore_changes` on the certificate fields; after the first apply with a domain, run once: `az containerapp hostname bind --hostname <domain> -g <rg> -n <app>` to provision the managed certificate (documented in Task 14).

- [ ] **Step 9.1: Create `modules/container-api/main.tf`**

```hcl
locals {
  common_tags = {
    App       = var.app_name
    Stage     = var.stage
    ManagedBy = "opentofu"
    Ticket    = "GS-316"
  }
  use_custom_domain = var.api_domain_name != "" && var.dns_zone_name != "" && var.dns_zone_resource_group != ""
  record_name       = local.use_custom_domain ? replace(var.api_domain_name, ".${var.dns_zone_name}", "") : ""
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.app_name}-${var.stage}-log"
  location            = var.azure_region
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.common_tags
}

resource "azurerm_container_app_environment" "this" {
  name                       = "${var.app_name}-${var.stage}-cae"
  location                   = var.azure_region
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  tags = local.common_tags
}

resource "azurerm_user_assigned_identity" "this" {
  name                = "${var.container_app_name}-identity"
  location            = var.azure_region
  resource_group_name = var.resource_group_name

  tags = local.common_tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "kv_secrets" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "storage_blob" {
  count = var.storage_account_id != "" ? 1 : 0

  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_container_app" "this" {
  name                         = var.container_app_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  tags = local.common_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  registry {
    server   = var.acr_login_server
    identity = azurerm_user_assigned_identity.this.id
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "gs-app-be"
      image  = "${var.acr_login_server}/${var.image_repository}:${var.image_tag}"
      cpu    = var.cpu
      memory = var.memory

      env {
        name  = "CLOUD_PROVIDER"
        value = "azure"
      }
      env {
        name  = "APP_NAME"
        value = var.app_name
      }
      env {
        name  = "APP_STAGE"
        value = var.stage
      }
      env {
        name  = "AZURE_REGION"
        value = var.azure_region
      }
      env {
        name  = "AZURE_KEY_VAULT_SECRETS_URI"
        value = var.kv_secrets_uri
      }
      env {
        name  = "AZURE_KEY_VAULT_ENVS_URI"
        value = var.kv_envs_uri
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

  ingress {
    external_enabled = true
    target_port      = var.container_port
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull]
}

# --- Optional custom domain (requires an Azure DNS zone) ---

resource "azurerm_dns_txt_record" "asuid" {
  count = local.use_custom_domain ? 1 : 0

  name                = "asuid.${local.record_name}"
  zone_name           = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300

  record {
    value = azurerm_container_app.this.custom_domain_verification_id
  }
}

resource "azurerm_dns_cname_record" "api" {
  count = local.use_custom_domain ? 1 : 0

  name                = local.record_name
  zone_name           = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300
  record              = azurerm_container_app.this.ingress[0].fqdn
}

resource "azurerm_container_app_custom_domain" "this" {
  count = local.use_custom_domain ? 1 : 0

  name             = var.api_domain_name
  container_app_id = azurerm_container_app.this.id

  # Managed certificate is provisioned out-of-band (az containerapp hostname
  # bind); these fields are then owned by Azure, not by this configuration.
  lifecycle {
    ignore_changes = [certificate_binding_type, container_app_environment_certificate_id]
  }

  depends_on = [azurerm_dns_txt_record.asuid, azurerm_dns_cname_record.api]
}
```

- [ ] **Step 9.2: Create `modules/container-api/variables.tf`**

```hcl
variable "container_app_name" {
  description = "Container app name (e.g. myapp-be-qa)"
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

variable "azure_region" {
  description = "Azure region (location)"
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group name (created by the rg stack)"
  type        = string
}

variable "acr_id" {
  description = "Container registry resource ID (AcrPull scope)"
  type        = string
}

variable "acr_login_server" {
  description = "Registry login server (e.g. myacr.azurecr.io)"
  type        = string
}

variable "image_repository" {
  description = "Image repository name inside the registry"
  type        = string
}

variable "image_tag" {
  description = "Image tag to deploy"
  type        = string
  default     = "latest"
}

variable "key_vault_id" {
  description = "Key Vault resource ID (Secrets User scope)"
  type        = string
}

variable "kv_secrets_uri" {
  description = "Versionless URI of the encrypted secrets set"
  type        = string
}

variable "kv_envs_uri" {
  description = "Versionless URI of the plain envvars set"
  type        = string
}

variable "storage_account_id" {
  description = "Storage account resource ID for attachments; empty skips the role"
  type        = string
  default     = ""
}

variable "container_port" {
  description = "Port the container listens on (parity with the AWS EC2 user-data: 80)"
  type        = number
  default     = 80
}

variable "min_replicas" {
  description = "0 = serverless parity (Lambda); 1 = always-on parity (EC2+ALB)"
  type        = number
  default     = 0
}

variable "max_replicas" {
  description = "Maximum replicas"
  type        = number
  default     = 2
}

variable "cpu" {
  description = "vCPU per replica"
  type        = number
  default     = 0.5
}

variable "memory" {
  description = "Memory per replica"
  type        = string
  default     = "1Gi"
}

variable "environment_variables" {
  description = "Extra container environment variables"
  type        = map(string)
  default     = {}
}

variable "api_domain_name" {
  description = "Custom API domain; empty disables the custom domain"
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Azure DNS zone name (e.g. example.com); empty skips DNS records"
  type        = string
  default     = ""
}

variable "dns_zone_resource_group" {
  description = "Resource group of the Azure DNS zone"
  type        = string
  default     = ""
}
```

- [ ] **Step 9.3: Create `modules/container-api/outputs.tf`**

```hcl
output "endpoint_url" {
  description = "Default ingress URL"
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "container_app_fqdn" {
  description = "Default ingress FQDN"
  value       = azurerm_container_app.this.ingress[0].fqdn
}

output "custom_domain_url" {
  description = "Custom domain URL (empty when no domain configured)"
  value       = var.api_domain_name != "" ? "https://${var.api_domain_name}" : ""
}

output "identity_principal_id" {
  description = "Principal ID of the app's user-assigned identity"
  value       = azurerm_user_assigned_identity.this.principal_id
}
```

- [ ] **Step 9.4: Create `modules/container-api/versions.tf`** — same content as Step 3.1.

- [ ] **Step 9.5: Create `stacks/containerapp/backend.tf`, `providers.tf`, `versions.tf`** — same content as Steps 3.5, 3.6, 3.1.

- [ ] **Step 9.6: Create `stacks/containerapp/main.tf`**

```hcl
data "terraform_remote_state" "acr" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.tf_state_resource_group
    storage_account_name = var.tf_state_storage_account
    container_name       = "tfstate"
    key                  = "${var.stage}/acr.tfstate"
  }
}

data "terraform_remote_state" "keyvault" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.tf_state_resource_group
    storage_account_name = var.tf_state_storage_account
    container_name       = "tfstate"
    key                  = "${var.stage}/keyvault.tfstate"
  }
}

data "terraform_remote_state" "secrets" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.tf_state_resource_group
    storage_account_name = var.tf_state_storage_account
    container_name       = "tfstate"
    key                  = "${var.stage}/secrets.tfstate"
  }
}

data "terraform_remote_state" "storage" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.tf_state_resource_group
    storage_account_name = var.tf_state_storage_account
    container_name       = "tfstate"
    key                  = "${var.stage}/storage.tfstate"
  }
}

module "container_api" {
  source = "../../modules/container-api"

  container_app_name  = var.container_app_name
  app_name            = var.app_name
  stage               = var.stage
  azure_region        = var.azure_region
  resource_group_name = var.resource_group_name

  acr_id           = data.terraform_remote_state.acr.outputs.acr_id
  acr_login_server = data.terraform_remote_state.acr.outputs.login_server
  image_repository = var.container_app_name
  image_tag        = var.acr_image_tag

  key_vault_id       = data.terraform_remote_state.keyvault.outputs.key_vault_id
  kv_secrets_uri     = data.terraform_remote_state.secrets.outputs.secrets_secret_uri
  kv_envs_uri        = data.terraform_remote_state.secrets.outputs.envs_secret_uri
  storage_account_id = data.terraform_remote_state.storage.outputs.storage_account_id

  container_port        = var.container_port
  min_replicas          = var.container_min_replicas
  environment_variables = var.environment_variables

  api_domain_name         = var.api_domain_name
  dns_zone_name           = var.dns_zone_name
  dns_zone_resource_group = var.dns_zone_resource_group
}
```

- [ ] **Step 9.7: Create `stacks/containerapp/variables.tf`** — the five common stack variables from Step 3.9 PLUS:

```hcl
variable "container_app_name" {
  description = "Container app name with stage (resolved by wrapper)"
  type        = string
}

variable "acr_image_tag" {
  description = "Image tag to deploy"
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 80
}

variable "container_min_replicas" {
  description = "0 = serverless parity (Lambda); 1 = always-on parity (EC2+ALB)"
  type        = number
  default     = 0
}

variable "environment_variables" {
  description = "Extra container environment variables"
  type        = map(string)
  default     = {}
}

variable "api_domain_name" {
  description = "Custom API domain (e.g. app-qa-az.example.com); empty disables it"
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Azure DNS zone name; empty skips DNS records"
  type        = string
  default     = ""
}

variable "dns_zone_resource_group" {
  description = "Resource group of the Azure DNS zone"
  type        = string
  default     = ""
}

variable "tf_state_resource_group" {
  description = "Resource group of the TF state storage account"
  type        = string
}

variable "tf_state_storage_account" {
  description = "TF state storage account name"
  type        = string
}
```

- [ ] **Step 9.8: Create `stacks/containerapp/outputs.tf`**

```hcl
output "endpoint_url" {
  description = "Default ingress URL"
  value       = module.container_api.endpoint_url
}

output "container_app_fqdn" {
  description = "Default ingress FQDN"
  value       = module.container_api.container_app_fqdn
}

output "custom_domain_url" {
  description = "Custom domain URL (empty when no domain configured)"
  value       = module.container_api.custom_domain_url
}

output "identity_principal_id" {
  description = "Principal ID of the app's user-assigned identity"
  value       = module.container_api.identity_principal_id
}
```

- [ ] **Step 9.9: Validate** — Step 3.11 commands with `modules/container-api stacks/containerapp` and `cd stacks/containerapp`. Expected: `Success! The configuration is valid.`

- [ ] **Step 9.10: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts
git add scripts/azure_tf/modules/container-api scripts/azure_tf/stacks/containerapp
git commit -m "Add: Azure OpenTofu Container Apps module and containerapp stack (Lambda/EC2 parity via min_replicas) [GS-316]"
```

---

### Task 10: FE state bootstrap + deployment wrapper

**Files:**
- Create: `packages/genericsuite-fe-scripts/scripts/azure_tf/bootstrap-tf-state.sh`
- Create: `packages/genericsuite-fe-scripts/scripts/azure_tf/run-tf-deployment.sh`

**Interfaces:**
- Produces: FE wrapper with the identical `ACTION STAGE STACK` contract. Exports TF_VARs consumed by the `frontend` stack (Task 11): common five (with `TF_VAR_resource_group_name` defaulting to `${APP_NAME_LOWERCASE}-${STAGE}-fe-rg`) + `TF_VAR_storage_account_name`, `TF_VAR_endpoint_name`, `TF_VAR_app_url`, `TF_VAR_dns_zone_name`, `TF_VAR_dns_zone_resource_group`. Also exports `VARIABLE_TYPE` handling (`FE` default, e.g. `WS` for a second frontend), mirroring `aws_tf`.

- [ ] **Step 10.1: Create `packages/genericsuite-fe-scripts/scripts/azure_tf/bootstrap-tf-state.sh`** — EXACTLY the same content as Task 1 Step 1.1 (only the header path comment changes to `scripts/azure_tf/bootstrap-tf-state.sh` — it already says that; copy the file verbatim from the be-scripts version).

- [ ] **Step 10.2: Create `packages/genericsuite-fe-scripts/scripts/azure_tf/run-tf-deployment.sh`** with exactly this content:

```bash
#!/bin/bash
# scripts/azure_tf/run-tf-deployment.sh
# Generic OpenTofu deployment wrapper for GenericSuite frontend Azure stacks.
# Azure counterpart of scripts/aws_tf/run-tf-deployment.sh.
# 2026-07-19 | CR [GS-316]
#
# Usage:
#   bash scripts/azure_tf/run-tf-deployment.sh ACTION STAGE STACK [EXTRA_TOFU_ARGS...]
#
# Parameters:
#   ACTION: init | validate | plan | apply | destroy | output
#   STAGE:  dev | qa | staging | demo | prod
#   STACK:  directory name under scripts/azure_tf/stacks (frontend)
#
# Environment:
#   CICD_MODE=1               -> non-interactive (-auto-approve on apply/destroy)
#   TF_STATE_RESOURCE_GROUP   -> override state resource group name
#   TF_STATE_STORAGE_ACCOUNT  -> override state storage account name
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
: "${AZURE_REGION:?ERROR: AZURE_REGION is not set (e.g. eastus)}"

STAGE_UPPERCASE="$(echo "${STAGE}" | tr '[:lower:]' '[:upper:]')"
APP_NAME_LOWERCASE="$(echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]')"
APP_NAME_ALNUM="$(echo "${APP_NAME_LOWERCASE}" | tr -cd 'a-z0-9')"

if [ "${AZURE_SUBSCRIPTION_ID:-}" = "" ]; then
    AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
fi
if [ "${AZURE_SUBSCRIPTION_ID}" = "" ]; then
    echo "ERROR: AZURE_SUBSCRIPTION_ID could not be retrieved. Run 'az login' first."
    exit 1
fi
export ARM_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"

SUB_HASH="$(printf '%s' "${AZURE_SUBSCRIPTION_ID}" | shasum | cut -c1-6)"
SUB_HASH4="$(printf '%s' "${SUB_HASH}" | cut -c1-4)"

TF_STATE_RESOURCE_GROUP="${TF_STATE_RESOURCE_GROUP:-${APP_NAME_LOWERCASE}-tfstate-rg}"
TF_STATE_STORAGE_ACCOUNT="${TF_STATE_STORAGE_ACCOUNT:-$(printf '%s' "${APP_NAME_ALNUM}" | cut -c1-14)tfst${SUB_HASH}}"
TF_STATE_CONTAINER="tfstate"

bash "${SCRIPTS_DIR}/bootstrap-tf-state.sh" \
    "${TF_STATE_RESOURCE_GROUP}" "${TF_STATE_STORAGE_ACCOUNT}" "${AZURE_REGION}"

# Common TF_VARs (every stack declares only the ones it needs)
export TF_VAR_app_name="${APP_NAME_LOWERCASE}"
export TF_VAR_stage="${STAGE}"
export TF_VAR_azure_region="${AZURE_REGION}"
export TF_VAR_azure_subscription_id="${AZURE_SUBSCRIPTION_ID}"

# Frontend variable type (FE by default; e.g. WS for a second frontend)
VARIABLE_TYPE="$(echo "${VARIABLE_TYPE:-FE}" | tr '[:lower:]' '[:upper:]')"
VARIABLE_TYPE_LOWERCASE="$(echo "${VARIABLE_TYPE}" | tr '[:upper:]' '[:lower:]')"

export TF_VAR_resource_group_name="${AZURE_RESOURCE_GROUP_FE:-${APP_NAME_LOWERCASE}-${STAGE}-${VARIABLE_TYPE_LOWERCASE}-rg}"

storage_account_varname="AZURE_STORAGE_ACCOUNT_NAME_${VARIABLE_TYPE}_${STAGE_UPPERCASE}"
TF_VAR_storage_account_name="${!storage_account_varname:-$(printf '%s' "${APP_NAME_ALNUM}" | cut -c1-9)${VARIABLE_TYPE_LOWERCASE}${STAGE}${SUB_HASH4}}"
export TF_VAR_storage_account_name

export TF_VAR_endpoint_name="${AZURE_AFD_ENDPOINT_NAME:-$(printf '%s' "${APP_NAME_ALNUM}" | cut -c1-10)-${STAGE}-${SUB_HASH4}}"

varname_app_url="APP_${VARIABLE_TYPE}_URL"
APP_URL_RAW="${!varname_app_url:-}"
APP_URL_CLEANED="$(echo "${APP_URL_RAW}" | perl -pe 's|^https?://||i; s|[:/].*||; s|\s+||g')"
export TF_VAR_app_url="${APP_URL_CLEANED}"

export TF_VAR_dns_zone_name="${AZURE_DNS_ZONE_NAME:-}"
export TF_VAR_dns_zone_resource_group="${AZURE_DNS_ZONE_RESOURCE_GROUP:-}"

# Optional per-stack variable builder
if [ -f "${SCRIPTS_DIR}/stacks/${STACK}/build-tfvars.sh" ]; then
    # shellcheck disable=SC1090
    . "${SCRIPTS_DIR}/stacks/${STACK}/build-tfvars.sh"
fi

cd "${SCRIPTS_DIR}/stacks/${STACK}"

echo ""
echo "RUN-TF-DEPLOYMENT (azure) | action=${ACTION} stage=${STAGE} stack=${STACK}"
echo "State: ${TF_STATE_STORAGE_ACCOUNT}/${TF_STATE_CONTAINER}/${STAGE}/${STACK}.tfstate (rg ${TF_STATE_RESOURCE_GROUP})"
echo ""

tofu init -reconfigure -input=false \
    -backend-config="resource_group_name=${TF_STATE_RESOURCE_GROUP}" \
    -backend-config="storage_account_name=${TF_STATE_STORAGE_ACCOUNT}" \
    -backend-config="container_name=${TF_STATE_CONTAINER}" \
    -backend-config="key=${STAGE}/${STACK}.tfstate"

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

- [ ] **Step 10.3: Verify syntax**

Run: `bash -n packages/genericsuite-fe-scripts/scripts/azure_tf/bootstrap-tf-state.sh && bash -n packages/genericsuite-fe-scripts/scripts/azure_tf/run-tf-deployment.sh`
Expected: no output, exit code 0.

- [ ] **Step 10.4: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-fe-scripts
git add scripts/azure_tf/bootstrap-tf-state.sh scripts/azure_tf/run-tf-deployment.sh
git commit -m "Add: Azure OpenTofu state bootstrap and frontend deployment wrapper (scripts/azure_tf) [GS-316]"
```

---

### Task 11: FE `frontend-hosting` module + `frontend` stack

**Files:**
- Create: `packages/genericsuite-fe-scripts/scripts/azure_tf/modules/frontend-hosting/{main.tf,variables.tf,outputs.tf,versions.tf}`
- Create: `packages/genericsuite-fe-scripts/scripts/azure_tf/stacks/frontend/{backend.tf,providers.tf,versions.tf,main.tf,variables.tf,outputs.tf}`

**Interfaces:**
- Consumes: FE wrapper TF_VARs from Task 10: `app_name`, `stage`, `azure_region`, `azure_subscription_id`, `resource_group_name`, `storage_account_name`, `endpoint_name`, `app_url`, `dns_zone_name`, `dns_zone_resource_group`.
- Produces: RG + private Storage account with static website ($web, 404→index.html SPA routing) + Azure Front Door Standard (endpoint, origin group/origin over the static website host, HTTPS-redirect route) + optional custom domain with **managed TLS certificate** and Azure DNS validation records. Stack outputs consumed by `azure_tf_deploy_to_storage.sh` (Task 12): `storage_account_name`, `resource_group_name`, `afd_profile_name`, `afd_endpoint_name`, `website_hostname`, `website_url`.
- Security parity with the AWS version: private origin content (no anonymous blob listing), HTTPS redirect, managed TLS >= 1.2, SPA error routing — CloudFront-OAC equivalents on Azure. (Note: Azure static websites are served via the public `$web` endpoint; Front Door Premium + Private Link would fully lock the origin — documented as a gap in Task 14.)

- [ ] **Step 11.1: Create `modules/frontend-hosting/main.tf`**

```hcl
locals {
  common_tags = {
    App       = var.app_name
    Stage     = var.stage
    ManagedBy = "opentofu"
    Ticket    = "GS-316"
  }
  use_custom_domain = var.app_url != ""
  dns_managed       = local.use_custom_domain && var.dns_zone_name != "" && var.dns_zone_resource_group != ""
  record_name       = local.dns_managed ? replace(var.app_url, ".${var.dns_zone_name}", "") : ""
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.azure_region
  tags     = local.common_tags
}

resource "azurerm_storage_account" "this" {
  name                            = var.storage_account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = var.azure_region
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  tags = local.common_tags
}

# SPA routing: serve index.html for unknown paths (404 -> index.html)
resource "azurerm_storage_account_static_website" "this" {
  storage_account_id = azurerm_storage_account.this.id
  index_document     = "index.html"
  error_404_document = "index.html"
}

resource "azurerm_cdn_frontdoor_profile" "this" {
  name                = "${var.app_name}-${var.stage}-afd"
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard_AzureFrontDoor"

  tags = local.common_tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  name                     = var.endpoint_name
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  tags = local.common_tags
}

resource "azurerm_cdn_frontdoor_origin_group" "this" {
  name                     = "fe-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  load_balancing {}

  health_probe {
    protocol            = "Https"
    interval_in_seconds = 100
    path                = "/"
    request_type        = "HEAD"
  }
}

resource "azurerm_cdn_frontdoor_origin" "this" {
  name                          = "fe-origin"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id

  enabled                        = true
  host_name                      = azurerm_storage_account.this.primary_web_host
  origin_host_header             = azurerm_storage_account.this.primary_web_host
  http_port                      = 80
  https_port                     = 443
  certificate_name_check_enabled = true
}

resource "azurerm_cdn_frontdoor_custom_domain" "this" {
  count = local.use_custom_domain ? 1 : 0

  name                     = "fe-custom-domain"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  host_name                = var.app_url

  tls {
    certificate_type = "ManagedCertificate"
  }
}

resource "azurerm_cdn_frontdoor_route" "this" {
  name                          = "fe-route"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.this.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  link_to_default_domain = true

  cdn_frontdoor_custom_domain_ids = local.use_custom_domain ? [azurerm_cdn_frontdoor_custom_domain.this[0].id] : []
}

# Custom-domain validation + traffic records (only when the zone is in Azure DNS)
resource "azurerm_dns_txt_record" "dnsauth" {
  count = local.dns_managed ? 1 : 0

  name                = "_dnsauth.${local.record_name}"
  zone_name           = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300

  record {
    value = azurerm_cdn_frontdoor_custom_domain.this[0].validation_token
  }
}

resource "azurerm_dns_cname_record" "fe" {
  count = local.dns_managed ? 1 : 0

  name                = local.record_name
  zone_name           = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300
  record              = azurerm_cdn_frontdoor_endpoint.this.host_name
}
```

- [ ] **Step 11.2: Create `modules/frontend-hosting/variables.tf`**

```hcl
variable "resource_group_name" {
  description = "Frontend resource group name (created by this module)"
  type        = string
}

variable "storage_account_name" {
  description = "Storage account name (3-24 lowercase alphanumerics, globally unique)"
  type        = string
}

variable "endpoint_name" {
  description = "Front Door endpoint name (globally unique)"
  type        = string
}

variable "azure_region" {
  description = "Azure region (location)"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage (dev, qa, staging, demo, prod)"
  type        = string
}

variable "app_url" {
  description = "Frontend FQDN (cleaned, no protocol); empty disables custom domain"
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Azure DNS zone name; empty skips DNS records (create the _dnsauth TXT + CNAME manually at your DNS provider using the validation_token output)"
  type        = string
  default     = ""
}

variable "dns_zone_resource_group" {
  description = "Resource group of the Azure DNS zone"
  type        = string
  default     = ""
}
```

- [ ] **Step 11.3: Create `modules/frontend-hosting/outputs.tf`**

```hcl
output "storage_account_name" {
  description = "Frontend storage account name"
  value       = azurerm_storage_account.this.name
}

output "resource_group_name" {
  description = "Frontend resource group name"
  value       = azurerm_resource_group.this.name
}

output "afd_profile_name" {
  description = "Front Door profile name"
  value       = azurerm_cdn_frontdoor_profile.this.name
}

output "afd_endpoint_name" {
  description = "Front Door endpoint name"
  value       = azurerm_cdn_frontdoor_endpoint.this.name
}

output "afd_endpoint_hostname" {
  description = "Front Door endpoint hostname (e.g. myapp-qa-ab12.z01.azurefd.net)"
  value       = azurerm_cdn_frontdoor_endpoint.this.host_name
}

output "website_hostname" {
  description = "Public hostname (custom domain when set, else the Front Door endpoint)"
  value       = var.app_url != "" ? var.app_url : azurerm_cdn_frontdoor_endpoint.this.host_name
}

output "website_url" {
  description = "Public URL"
  value       = "https://${var.app_url != "" ? var.app_url : azurerm_cdn_frontdoor_endpoint.this.host_name}"
}

output "custom_domain_validation_token" {
  description = "TXT value for _dnsauth.<domain> when the DNS zone is NOT in Azure DNS"
  value       = var.app_url != "" ? azurerm_cdn_frontdoor_custom_domain.this[0].validation_token : ""
}
```

- [ ] **Step 11.4: Create `modules/frontend-hosting/versions.tf`** — same content as Step 3.1.

- [ ] **Step 11.5: Create `stacks/frontend/backend.tf`, `providers.tf`, `versions.tf`** — same content as Steps 3.5, 3.6, 3.1.

- [ ] **Step 11.6: Create `stacks/frontend/main.tf`**

```hcl
module "frontend_hosting" {
  source = "../../modules/frontend-hosting"

  resource_group_name     = var.resource_group_name
  storage_account_name    = var.storage_account_name
  endpoint_name           = var.endpoint_name
  azure_region            = var.azure_region
  app_name                = var.app_name
  stage                   = var.stage
  app_url                 = var.app_url
  dns_zone_name           = var.dns_zone_name
  dns_zone_resource_group = var.dns_zone_resource_group
}
```

- [ ] **Step 11.7: Create `stacks/frontend/variables.tf`** — the five common stack variables from Step 3.9 PLUS:

```hcl
variable "storage_account_name" {
  description = "Frontend storage account name (resolved by wrapper)"
  type        = string
}

variable "endpoint_name" {
  description = "Front Door endpoint name (resolved by wrapper)"
  type        = string
}

variable "app_url" {
  description = "Frontend FQDN (cleaned, no protocol); empty disables custom domain"
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Azure DNS zone name; empty skips DNS records"
  type        = string
  default     = ""
}

variable "dns_zone_resource_group" {
  description = "Resource group of the Azure DNS zone"
  type        = string
  default     = ""
}
```

- [ ] **Step 11.8: Create `stacks/frontend/outputs.tf`**

```hcl
output "storage_account_name" {
  description = "Frontend storage account name"
  value       = module.frontend_hosting.storage_account_name
}

output "resource_group_name" {
  description = "Frontend resource group name"
  value       = module.frontend_hosting.resource_group_name
}

output "afd_profile_name" {
  description = "Front Door profile name"
  value       = module.frontend_hosting.afd_profile_name
}

output "afd_endpoint_name" {
  description = "Front Door endpoint name"
  value       = module.frontend_hosting.afd_endpoint_name
}

output "website_hostname" {
  description = "Public hostname"
  value       = module.frontend_hosting.website_hostname
}

output "website_url" {
  description = "Public URL"
  value       = module.frontend_hosting.website_url
}

output "custom_domain_validation_token" {
  description = "TXT value for _dnsauth.<domain> for external DNS providers"
  value       = module.frontend_hosting.custom_domain_validation_token
}
```

- [ ] **Step 11.9: Validate**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-fe-scripts/scripts/azure_tf
tofu fmt -check -recursive modules/frontend-hosting stacks/frontend
( cd stacks/frontend && tofu init -backend=false -input=false >/dev/null && tofu validate )
```

Expected: `fmt` prints nothing; validate prints `Success! The configuration is valid.`

- [ ] **Step 11.10: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-fe-scripts
git add scripts/azure_tf/modules/frontend-hosting scripts/azure_tf/stacks/frontend
git commit -m "Add: Azure OpenTofu frontend-hosting module and frontend stack (static website + Front Door, managed TLS, SPA routing) [GS-316]"
```

---

### Task 12: FE full deployment pipeline script

**Files:**
- Create: `packages/genericsuite-fe-scripts/scripts/azure_tf/azure_tf_deploy_to_storage.sh`

**Interfaces:**
- Consumes: Task 10 wrapper (`run-tf-deployment.sh apply STAGE frontend`), Task 11 stack outputs (`storage_account_name`, `resource_group_name`, `afd_profile_name`, `afd_endpoint_name`, `website_hostname`), and the existing package helpers `run_method_dependency_manager.sh`, `run_symlinks_handler.sh`, `build_copy_images.sh` (unchanged, referenced from `scripts/`).
- Produces: end-to-end FE deploy — infra apply → app build (vite/webpack/react-app-rewired, same flow as `aws_tf_deploy_to_s3.sh`) → blob upload to `$web` → Front Door cache purge.

- [ ] **Step 12.1: Create the script** with exactly this content:

```bash
#!/bin/bash
# scripts/azure_tf/azure_tf_deploy_to_storage.sh
# OpenTofu-based frontend deployment on Azure: infra via tofu, app build +
# blob upload + Front Door cache purge in bash. Azure counterpart of
# scripts/aws_tf/aws_tf_deploy_to_s3.sh (which remains untouched).
# 2026-07-19 | CR [GS-316]
#
# Usage:
#   bash node_modules/genericsuite-fe-scripts/scripts/azure_tf/azure_tf_deploy_to_storage.sh STAGE [VARIABLE_TYPE]
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

# 1) Infrastructure: Storage static website + Front Door via OpenTofu
bash "${SCRIPTS_DIR}/run-tf-deployment.sh" apply "${STAGE}" frontend

# 2) Read infra outputs
cd "${SCRIPTS_DIR}/stacks/frontend"
STORAGE_ACCOUNT="$(tofu output -raw storage_account_name)"
RG_NAME="$(tofu output -raw resource_group_name)"
AFD_PROFILE="$(tofu output -raw afd_profile_name)"
AFD_ENDPOINT="$(tofu output -raw afd_endpoint_name)"
DOMAIN_NAME="$(tofu output -raw website_hostname)"
cd "${REPO_BASEDIR}"
echo ""
echo "Storage: ${STORAGE_ACCOUNT} | Front Door: ${AFD_PROFILE}/${AFD_ENDPOINT} (${DOMAIN_NAME})"

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

    perl -i -pe "s|\"homepage\":.*|\"homepage\": \"https://${DOMAIN_NAME}\",|g" package.json

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

# 4) Upload to the $web container (replaces the previous content)
echo "Deploying to Azure Storage static website..."
az storage blob delete-batch \
    --account-name "${STORAGE_ACCOUNT}" \
    --source '$web' \
    --auth-mode key
az storage blob upload-batch \
    --account-name "${STORAGE_ACCOUNT}" \
    --destination '$web' \
    --source "${BUILD_DIR}" \
    --overwrite \
    --auth-mode key

# 5) Purge the Front Door cache
echo "Purging Azure Front Door cache..."
az afd endpoint purge \
    --resource-group "${RG_NAME}" \
    --profile-name "${AFD_PROFILE}" \
    --endpoint-name "${AFD_ENDPOINT}" \
    --content-paths '/*'

echo ""
echo "Deployment complete: https://${DOMAIN_NAME}"
```

- [ ] **Step 12.2: Verify syntax**

Run: `bash -n packages/genericsuite-fe-scripts/scripts/azure_tf/azure_tf_deploy_to_storage.sh`
Expected: no output, exit code 0.

- [ ] **Step 12.3: Add azure_tf entries to the FE package `.gitignore`** — run `grep -n "aws_tf\|terraform" packages/genericsuite-fe-scripts/.gitignore`, then append (skipping lines already covered by an existing pattern):

```
# Azure OpenTofu working files [GS-316]
scripts/azure_tf/**/.terraform/
scripts/azure_tf/**/.terraform.lock.hcl
scripts/azure_tf/**/*.tfstate
scripts/azure_tf/**/*.tfstate.*
```

- [ ] **Step 12.4: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-fe-scripts
git add scripts/azure_tf/azure_tf_deploy_to_storage.sh .gitignore
git commit -m "Add: Azure OpenTofu full frontend deploy pipeline (azure_tf_deploy_to_storage.sh: tofu apply + build + blob upload + Front Door purge) [GS-316]"
```

---

### Task 13: Full validation sweep (both packages)

**Files:** none created — verification only.

- [ ] **Step 13.1: Validate every BE stack and module**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts/scripts/azure_tf
tofu fmt -check -recursive .
for d in stacks/rg stacks/storage stacks/keyvault stacks/secrets stacks/cosmosdb stacks/acr stacks/containerapp; do
  echo "== ${d} =="
  ( cd "${d}" && tofu init -backend=false -input=false >/dev/null && tofu validate )
done
for s in bootstrap-tf-state.sh run-tf-deployment.sh stacks/secrets/build-tfvars.sh stacks/cosmosdb/build-tfvars.sh; do
  bash -n "${s}"
done
```

Expected: `fmt` silent; seven `Success! The configuration is valid.` lines; `bash -n` silent.

- [ ] **Step 13.2: Validate the FE stack and scripts**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-fe-scripts/scripts/azure_tf
tofu fmt -check -recursive .
( cd stacks/frontend && tofu init -backend=false -input=false >/dev/null && tofu validate )
for s in bootstrap-tf-state.sh run-tf-deployment.sh azure_tf_deploy_to_storage.sh; do
  bash -n "${s}"
done
```

Expected: `fmt` silent; `Success! The configuration is valid.`; `bash -n` silent.

- [ ] **Step 13.3: Confirm nothing under `aws_tf` changed**

```bash
git -C /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts status --short scripts/aws_tf
git -C /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-fe-scripts status --short scripts/aws_tf
```

Expected: both empty. If not empty, STOP and report.

If any validate fails: fix formatting with `tofu fmt <dir>`, re-read the failing file against the code in this plan (the most common failure is a typo'd attribute name), amend the task's commit (`git commit --amend --no-edit`) after fixing, and re-run this task.

---

### Task 14: Basecamp documentation (Azure OpenTofu guide + nav)

**Files:**
- Create: `packages/genericsuite-basecamp/mkdocs_root/en/Deployment-Guide/azure-opentofu.md`
- Modify: `packages/genericsuite-basecamp/mkdocs.yml` (2 edits)

**Interfaces:**
- Consumes: everything built in Tasks 1–12 (referenced by path and command, no code).
- Produces: the user-facing deployment guide, linked from the mkdocs nav next to the AWS OpenTofu guide.

- [ ] **Step 14.1: Create `mkdocs_root/en/Deployment-Guide/azure-opentofu.md`** with this content (review the sibling `opentofu.md` first and match its heading style; keep all sections below, adjusting only cosmetic style):

````markdown
# Azure OpenTofu (IaC) Deployment

Deploy the GenericSuite backend and frontend to Microsoft Azure with
[OpenTofu](https://opentofu.org) (Terraform-compatible), mirroring the
[AWS OpenTofu path](./opentofu.md). The Azure path lives in
`scripts/azure_tf/` in both
[genericsuite-be-scripts](https://github.com/tomkat-cr/genericsuite-be-scripts)
and
[genericsuite-fe-scripts](https://github.com/tomkat-cr/genericsuite-fe-scripts),
and is a parallel, opt-in alternative — nothing in the AWS scripts changes.

## Service mapping

| GenericSuite concern | AWS (aws_tf) | Azure (azure_tf) |
|---|---|---|
| Remote TF state | S3 bucket | Storage account (blob-lease locking) |
| Attachments storage | S3 bucket | Storage account + blob container |
| Database | DynamoDB tables | Cosmos DB (MongoDB API, serverless) |
| Encryption keys | KMS key | Key Vault key |
| Secrets / env sets | Secrets Manager | Key Vault secrets (same JSON blobs) |
| Container registry | ECR | Azure Container Registry |
| Backend compute | Lambda + API Gateway / EC2 + ALB | Azure Container Apps (min replicas 0 / 1) |
| Frontend hosting | S3 + CloudFront (OAC) | Storage static website + Azure Front Door |
| DNS + TLS | Route53 + ACM | Azure DNS + managed certificates |

## Prerequisites

- OpenTofu >= 1.10 (`brew install opentofu`)
- Azure CLI (`brew install azure-cli`), logged in: `az login`
- `jq`, `python3`, and for the frontend: Node.js 26+ and your bundler
- A stage-specific `.env` in the consuming app (see variables below)

## Environment variables

Required:

- `APP_NAME` — application name (also drives all Azure resource names)
- `AZURE_REGION` — e.g. `eastus`

Optional (with defaults derived from `APP_NAME`, the stage, and a hash of
the subscription ID for globally-unique names):

- `AZURE_SUBSCRIPTION_ID` (default: `az account show`)
- `AZURE_RESOURCE_GROUP` (default: `{app}-{stage}-rg`)
- `AZURE_KEY_VAULT_NAME`, `AZURE_KEY_NAME` (default key: `genericsuite-key`)
- `AZURE_STORAGE_ACCOUNT_NAME_{STAGE}` — attachments storage account
- `AWS_S3_CHATBOT_ATTACHMENTS_BUCKET_{STAGE}` — reused as the blob container name
- `AZURE_ACR_NAME`, `AZURE_ACR_IMAGE_TAG` (falls back to `ECR_DOCKER_IMAGE_TAG`, then `latest`)
- `AZURE_COSMOS_ACCOUNT_NAME` (default `{app}-{stage}-cosmos`), `APP_DB_NAME_{STAGE}`
- `AZURE_CONTAINER_APP_NAME`, `AZURE_CONTAINER_PORT` (default 80)
- `CONTAINER_MIN_REPLICAS` — `0` (default) = serverless/Lambda parity; `1` = always-on/EC2 parity
- `AZURE_API_DOMAIN_NAME`, `AZURE_DNS_ZONE_NAME`, `AZURE_DNS_ZONE_RESOURCE_GROUP` — custom API domain
- Frontend: `APP_FE_URL`, `AZURE_STORAGE_ACCOUNT_NAME_FE_{STAGE}`, `AZURE_AFD_ENDPOINT_NAME`
- `CICD_MODE=1` — non-interactive applies
- `TF_STATE_RESOURCE_GROUP`, `TF_STATE_STORAGE_ACCOUNT` — state overrides

## Remote state

State is bootstrapped automatically on every run:
resource group `{app}-tfstate-rg`, a versioned/private storage account,
container `tfstate`, key `{stage}/{stack}.tfstate`. Locking is native via
blob leases — no extra lock table.

## Backend deployment

From the consuming backend app's root (with its `.env`):

```bash
BE_TF="node_modules/genericsuite-be-scripts/scripts/azure_tf/run-tf-deployment.sh"
bash "${BE_TF}" apply qa rg           # 1. resource group
bash "${BE_TF}" apply qa keyvault     # 2. Key Vault + genericsuite-key
bash "${BE_TF}" apply qa secrets      # 3. secrets + envs JSON sets
bash "${BE_TF}" apply qa storage      # 4. attachments storage
bash "${BE_TF}" apply qa cosmosdb     # 5. Cosmos DB collections (from the GS JSON config)
bash "${BE_TF}" apply qa acr          # 6. container registry
# Build & push the backend image (stays in bash, as on AWS):
az acr login --name "$(cd node_modules/genericsuite-be-scripts/scripts/azure_tf/stacks/acr && tofu output -raw acr_name)"
docker build -t <login_server>/<container_app_name>:latest .
docker push <login_server>/<container_app_name>:latest
bash "${BE_TF}" apply qa containerapp # 7. Container Apps API
```

Actions: `init | validate | plan | apply | destroy | output`.
Stages: `dev | qa | staging | demo | prod`.

After `containerapp`, get the API URL with
`bash "${BE_TF}" output qa containerapp`. Point the app's DB at Cosmos DB by
setting `APP_DB_URI_{STAGE}` to the `connection_string` output
(`tofu output -raw connection_string` inside the cosmosdb stack dir).

### Custom API domain

Set `AZURE_API_DOMAIN_NAME`, `AZURE_DNS_ZONE_NAME`, and
`AZURE_DNS_ZONE_RESOURCE_GROUP`, re-apply `containerapp`, then provision the
managed certificate once:

```bash
az containerapp hostname bind --hostname <api-domain> \
    -g <resource-group> -n <container-app-name>
```

## Frontend deployment

From the consuming frontend app's root:

```bash
bash node_modules/genericsuite-fe-scripts/scripts/azure_tf/azure_tf_deploy_to_storage.sh qa
```

This applies the `frontend` stack (Storage static website + Front Door
Standard with HTTPS redirect, managed TLS and SPA 404→`index.html` routing),
builds the app (`RUN_BUNDLER`: vite/webpack/react-app-rewired), uploads the
bundle to the `$web` container and purges the Front Door cache.

With `APP_FE_URL` set and the zone in Azure DNS, the `_dnsauth` TXT and
CNAME records are created automatically; with an external DNS provider,
create them manually using the `custom_domain_validation_token` output.

## Migration notes vs. AWS

- One resource group per app+stage replaces implicit AWS account scoping.
- Azure Container Apps covers both AWS compute paths: `CONTAINER_MIN_REPLICAS=0`
  behaves like Lambda (scale to zero), `1` like EC2+ALB (always warm).
- Key Vault stores both the encryption key (KMS parity) and the two JSON
  secret sets (Secrets Manager parity) — same secret names and content.
- Container Apps uses a user-assigned managed identity with AcrPull,
  Key Vault Secrets User, and Storage Blob Data Contributor roles — the
  IAM-role equivalent.
- Storage account / Key Vault / ACR names are globally unique and length
  limited; the wrappers derive safe names from `APP_NAME` + stage + a short
  subscription-ID hash. Override via the `AZURE_*` variables when needed.

## Gaps / follow-ups

- VM + Application Gateway path (closest EC2+ALB analog) — use
  `CONTAINER_MIN_REPLICAS=1` instead; a dedicated `vm-appgw` module is a
  possible follow-up.
- Zip-package deploys (Azure Functions/App Service) — the Azure path is
  container-only.
- ACR untagged-image retention requires the Premium SKU (module default is
  Basic); use `az acr` purge tasks meanwhile.
- Front Door Premium + Private Link origin (fully private `$web` endpoint).
- Azure SQL / PostgreSQL flexible server module (parity with the `sql_db`
  gap on AWS).
- LocalStack-style local emulation for the Azure path.
````

- [ ] **Step 14.2: Add the nav entry in `mkdocs.yml`** — Edit the line (currently line 20):

```yaml
    - 'OpenTofu (IaC)': './Deployment-Guide/opentofu.md'
```

to be followed by a new line:

```yaml
    - 'Azure OpenTofu (IaC)': './Deployment-Guide/azure-opentofu.md'
```

- [ ] **Step 14.3: Add the translation mapping in `mkdocs.yml`** — Edit the line (currently line 120):

```yaml
            'OpenTofu (IaC)': 'OpenTofu (IaC)'
```

to be followed by a new line (same indentation):

```yaml
            'Azure OpenTofu (IaC)': 'Azure OpenTofu (IaC)'
```

- [ ] **Step 14.4: Update Basecamp CHANGELOG** — in `packages/genericsuite-basecamp/CHANGELOG.md`, under `## [Unreleased] - YYYY-MM-DD` → `### Added`, add:

```markdown
- Azure OpenTofu deployment guide (`mkdocs_root/en/Deployment-Guide/azure-opentofu.md`) covering the genericsuite-fe-scripts and genericsuite-be-scripts Azure IaC stacks (Container Apps, Cosmos DB, Key Vault, ACR, Storage, Front Door), with a nav entry in `mkdocs.yml` [GS-316].
```

- [ ] **Step 14.5: Verify** — `python3 -c "import yaml,sys; yaml.safe_load(open('packages/genericsuite-basecamp/mkdocs.yml'))"` — if PyYAML is unavailable or the file uses custom tags, fall back to a visual check that the two new lines sit exactly beside their `OpenTofu (IaC)` siblings with identical indentation.

- [ ] **Step 14.6: Commit**

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-basecamp
git add mkdocs_root/en/Deployment-Guide/azure-opentofu.md mkdocs.yml CHANGELOG.md
git commit -m "Add: Azure OpenTofu deployment guide with mkdocs nav entry and changelog note [GS-316]"
```

---

### Task 15: Package changelogs + superproject wrap-up

**Files:**
- Modify: `packages/genericsuite-be-scripts/CHANGELOG.md`
- Modify: `packages/genericsuite-fe-scripts/CHANGELOG.md`
- Modify: `CHANGELOG.md` (superproject root)

- [ ] **Step 15.1: be-scripts changelog** — under `## [Unreleased] - YYYY-MM-DD` → `### Added`, add:

```markdown
- OpenTofu (Terraform-compatible) IaC deployments for Microsoft Azure in `scripts/azure_tf`: generic wrapper (`run-tf-deployment.sh`), Azure Blob Storage remote state with native blob-lease locking (`bootstrap-tf-state.sh`), and modules/stacks for resource groups, Storage accounts/containers, Cosmos DB for MongoDB collections (reusing the GenericSuite JSON table config), Key Vault (keys + secret/env JSON sets), Azure Container Registry, and Azure Container Apps with managed-identity RBAC and optional custom domains — Azure counterpart of `scripts/aws_tf`, which remains unchanged [GS-316].
```

Commit:

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-be-scripts
git add CHANGELOG.md
git commit -m "Add: CHANGELOG entry for the Azure OpenTofu IaC deployments [GS-316]"
```

- [ ] **Step 15.2: fe-scripts changelog** — under `## [Unreleased] - YYYY-MM-DD` → `### Added`, add:

```markdown
- OpenTofu IaC frontend deployment for Microsoft Azure in `scripts/azure_tf`: `frontend-hosting` module (Storage static website + Azure Front Door Standard with managed TLS, HTTPS redirect and SPA error routing) and `azure_tf_deploy_to_storage.sh` full pipeline (tofu apply + build + blob upload + Front Door cache purge), with Azure Blob Storage remote state — parallel to `scripts/aws_tf`, which remains unchanged [GS-316].
```

Commit:

```bash
cd /Users/carlosramirez/desarrollo/genericsuite/packages/genericsuite-fe-scripts
git add CHANGELOG.md
git commit -m "Add: CHANGELOG entry for the Azure OpenTofu frontend deployment [GS-316]"
```

- [ ] **Step 15.3: Superproject changelog** — in the root `CHANGELOG.md`, under `## [Unreleased] - YYYY-MM-DD` → `### Added`, add:

```markdown
- Microsoft Azure OpenTofu deployment path (`scripts/azure_tf`) in genericsuite-be-scripts and genericsuite-fe-scripts, mirroring the AWS OpenTofu conversion (Container Apps, Cosmos DB, Key Vault, ACR, Storage, Front Door), with a new Azure deployment guide in GS Basecamp [GS-316].
```

- [ ] **Step 15.4: Superproject commit** (plan file, changelog, and updated submodule pointers):

```bash
cd /Users/carlosramirez/desarrollo/genericsuite
git add CHANGELOG.md docs/superpowers/plans/2026-07-19-azure-opentofu-conversion.md \
    packages/genericsuite-be-scripts packages/genericsuite-fe-scripts packages/genericsuite-basecamp
git commit -m "Add: Azure OpenTofu conversion plan, changelog and submodule updates [GS-316]"
```

- [ ] **Step 15.5: Final report** — list the commits created (`git log --oneline -3` in each of the four repos) and restate: real-Azure smoke testing (`apply` on a dev subscription) was NOT part of this plan and remains a follow-up, matching the AWS testing plan's "dev apply" phase which requires credentials and a consuming app `.env`.

---

## Testing philosophy (mirror of the AWS design §6)

1. This plan's automated gate: `tofu fmt -check` + `tofu validate` on every module/stack and `bash -n` on every script — CI-friendly, no credentials.
2. **Dev (real apply)** — follow-up with a human: from `packages/genericsuite-basecamp/mkdocs_root/code/fastapitemplate/server` with a real `.env` and `az login`, STAGE=dev: `rg` → `keyvault` → `secrets` → `storage` → `cosmosdb` → `acr` → (push image) → `containerapp`, then the FE `frontend` stack; verify with `az resource list -g <app>-dev-rg`. Keep resources.
3. **Prod:** `plan` only, never `apply`.
4. The AWS path and all CloudFormation scripts remain untouched throughout (verified in Step 13.3).

## Self-review notes (already applied)

- Spec coverage: every aws_tf module/stack has an Azure counterpart or an explicit documented gap (domain→folded into consumers; ec2→`CONTAINER_MIN_REPLICAS=1`; zip-lambda/VM/AppGW/ACR-retention→gaps in the guide).
- Type consistency: stack output names consumed across tasks (`acr_id`, `login_server`, `key_vault_id`, `secrets_secret_uri`, `envs_secret_uri`, `storage_account_id`, `storage_account_name`, `resource_group_name`, `afd_profile_name`, `afd_endpoint_name`, `website_hostname`) match their producing `outputs.tf` definitions verbatim.
- The `versions.tf`/`backend.tf`/`providers.tf` blocks are intentionally identical everywhere; Steps reference 3.1/3.5/3.6 to avoid drift.
