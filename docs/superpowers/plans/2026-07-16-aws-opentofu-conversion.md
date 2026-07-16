# AWS OpenTofu Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide an OpenTofu implementation of every AWS deployment currently done with CloudFormation/AWS CLI in `genericsuite-fe-scripts` and `genericsuite-be-scripts`, with S3 remote state, without touching the existing CloudFormation path.

**Architecture:** Reusable modules under `scripts/aws_tf/modules/`, thin root configs under `scripts/aws_tf/stacks/`, and a generic bash wrapper (`run-tf-deployment.sh`) that loads the consuming app's `.env`, exports `TF_VAR_*`, bootstraps the S3 state bucket, and runs `tofu init/validate/plan/apply/destroy/output`. Spec: `docs/superpowers/specs/2026-07-16-aws-opentofu-conversion-design.md`.

**Tech Stack:** OpenTofu ≥ 1.10, AWS provider `~> 6.0`, `hashicorp/tls` `~> 4.0` (key pairs), bash, Python 3 (DynamoDB tfvars generator).

## Global Constraints

- OpenTofu `required_version = ">= 1.10"`; AWS provider `version = "~> 6.0"` — pinned in every `versions.tf`.
- Never modify or delete existing CloudFormation templates or deploy scripts.
- Resource names must match current conventions: `{app}-{stage}-secrets`, `{app}-{stage}-envs`, `{app}_{stage}_{table}`, `{lambda_name}-{stage}`, `genericsuite-key`, etc. Exception: IAM helper roles from `cf-template-kms-key.yml` get a `{alias}-` prefix to avoid collision with live CF stacks.
- State: bucket `{app_name_lowercase}-tf-state-{account_id}`, key `{stage}/{stack}.tfstate`, `encrypt=true`, `use_lockfile=true`. Backend config only via `tofu init -backend-config=...` (empty `backend "s3" {}` in stacks).
- Shell: `#!/bin/bash`, `set -euo pipefail`, quoted expansions, `read VAR < /dev/tty` for prompts, perl over sed (per `packages/genericsuite-be-scripts/docs/codeStyle.md`).
- Secrets: only via `TF_VAR_*` env vars marked `sensitive = true`; never written to `.tfvars` files on disk.
- Default provider tags on every stack: `App`, `Stage`, `ManagedBy = "opentofu"`, `Ticket = "GS-334"`.
- Commits: inside each submodule (`packages/genericsuite-be-scripts`, `packages/genericsuite-fe-scripts`, `packages/genericsuite-basecamp`) on their current `develop` branch; message suffix `[GS-334]` and `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Test cycle for HCL tasks: `tofu fmt -check -recursive` then `tofu init -backend=false` + `tofu validate` in each stack. For bash: `bash -n`.

**Path shorthands used below:**
- `BE_TF` = `packages/genericsuite-be-scripts/scripts/aws_tf`
- `FE_TF` = `packages/genericsuite-fe-scripts/scripts/aws_tf`

---

### Task 1: Install OpenTofu

**Files:** none (toolchain only)

**Interfaces:**
- Produces: `tofu` binary ≥ 1.10 on PATH, used by every later task.

- [ ] **Step 1: Install**

Run: `brew install opentofu`
Expected: installs latest (≥ 1.10).

- [ ] **Step 2: Verify version**

Run: `tofu version`
Expected: `OpenTofu v1.1x.x` (must be ≥ 1.10 for `use_lockfile`).

---

### Task 2: Backend-scripts state bootstrap + generic wrapper

**Files:**
- Create: `BE_TF/bootstrap-tf-state.sh`
- Create: `BE_TF/run-tf-deployment.sh`

**Interfaces:**
- Consumes: consuming app `.env` (`APP_NAME`, `AWS_REGION`, optional `AWS_ACCOUNT_ID`, `KMS_KEY_ALIAS`, stage-suffixed vars).
- Produces:
  - `bootstrap-tf-state.sh BUCKET REGION` — idempotent state bucket creation.
  - `run-tf-deployment.sh ACTION STAGE STACK [EXTRA...]` — ACTION ∈ `init|validate|plan|apply|destroy|output`; exports `TF_VAR_app_name` (lowercase), `TF_VAR_stage`, `TF_VAR_aws_region`, `TF_VAR_aws_account_id`, `TF_VAR_kms_key_alias`, `TF_VAR_chatbot_attachments_bucket_name`, `TF_VAR_lambda_function_name`, `TF_VAR_app_domain_name`; sources `stacks/${STACK}/build-tfvars.sh` when present.

- [ ] **Step 1: Write `bootstrap-tf-state.sh`**

```bash
#!/bin/bash
# scripts/aws_tf/bootstrap-tf-state.sh
# Create/verify the S3 bucket that stores OpenTofu remote state.
# 2026-07-16 | CR [GS-334]
# Usage: bash scripts/aws_tf/bootstrap-tf-state.sh BUCKET_NAME AWS_REGION
set -euo pipefail

BUCKET_NAME="${1:-}"
AWS_REGION="${2:-}"

if [ "${BUCKET_NAME}" = "" ] || [ "${AWS_REGION}" = "" ]; then
    echo "Usage: $0 BUCKET_NAME AWS_REGION"
    exit 1
fi

if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
    echo "TF state bucket '${BUCKET_NAME}' already exists."
    exit 0
fi

echo "Creating TF state bucket '${BUCKET_NAME}' in '${AWS_REGION}'..."
if [ "${AWS_REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" --output text
else
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" \
        --create-bucket-configuration "LocationConstraint=${AWS_REGION}" --output text
fi

aws s3api put-bucket-versioning --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "TF state bucket '${BUCKET_NAME}' created (versioned, encrypted, private)."
```

- [ ] **Step 2: Write `run-tf-deployment.sh`**

```bash
#!/bin/bash
# scripts/aws_tf/run-tf-deployment.sh
# Generic OpenTofu deployment wrapper for GenericSuite backend stacks.
# OpenTofu counterpart of scripts/aws_cf_processor/run-cf-deployment.sh.
# 2026-07-16 | CR [GS-334]
#
# Usage:
#   bash scripts/aws_tf/run-tf-deployment.sh ACTION STAGE STACK [EXTRA_TOFU_ARGS...]
#
# Parameters:
#   ACTION: init | validate | plan | apply | destroy | output
#   STAGE:  dev | qa | staging | demo | prod
#   STACK:  directory name under scripts/aws_tf/stacks (s3, dynamodb, kms,
#           secrets, ecr, domain, ec2, lambda)
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
: "${AWS_REGION:?ERROR: AWS_REGION is not set}"

STAGE_UPPERCASE="$(echo "${STAGE}" | tr '[:lower:]' '[:upper:]')"
APP_NAME_LOWERCASE="$(echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]')"

if [ "${AWS_ACCOUNT_ID:-}" = "" ]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --output json --no-paginate | jq -r '.Account')"
fi
if [ "${AWS_ACCOUNT_ID}" = "" ] || [ "${AWS_ACCOUNT_ID}" = "null" ]; then
    echo "ERROR: AWS_ACCOUNT_ID could not be retrieved. Configure AWS credentials."
    exit 1
fi

TF_STATE_BUCKET="${TF_STATE_BUCKET:-${APP_NAME_LOWERCASE}-tf-state-${AWS_ACCOUNT_ID}}"
bash "${SCRIPTS_DIR}/bootstrap-tf-state.sh" "${TF_STATE_BUCKET}" "${AWS_REGION}"

# Common TF_VARs (every stack declares only the ones it needs)
export TF_VAR_app_name="${APP_NAME_LOWERCASE}"
export TF_VAR_stage="${STAGE}"
export TF_VAR_aws_region="${AWS_REGION}"
export TF_VAR_aws_account_id="${AWS_ACCOUNT_ID}"
export TF_VAR_kms_key_alias="${KMS_KEY_ALIAS:-genericsuite-key}"
TF_VAR_chatbot_attachments_bucket_name="$(eval echo "\${AWS_S3_CHATBOT_ATTACHMENTS_BUCKET_${STAGE_UPPERCASE}:-}")"
export TF_VAR_chatbot_attachments_bucket_name
if [ "${AWS_LAMBDA_FUNCTION_NAME:-}" != "" ]; then
    TF_VAR_lambda_function_name="$(echo "${AWS_LAMBDA_FUNCTION_NAME}-${STAGE}" | tr '[:upper:]' '[:lower:]')"
    export TF_VAR_lambda_function_name
fi
export TF_VAR_app_domain_name="${APP_DOMAIN_NAME:-}"

# Optional per-stack variable builder (e.g. secrets maps, dynamodb tables)
if [ -f "${SCRIPTS_DIR}/stacks/${STACK}/build-tfvars.sh" ]; then
    # shellcheck disable=SC1090
    . "${SCRIPTS_DIR}/stacks/${STACK}/build-tfvars.sh"
fi

cd "${SCRIPTS_DIR}/stacks/${STACK}"

echo ""
echo "RUN-TF-DEPLOYMENT | action=${ACTION} stage=${STAGE} stack=${STACK}"
echo "State: s3://${TF_STATE_BUCKET}/${STAGE}/${STACK}.tfstate"
echo ""

tofu init -reconfigure -input=false \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${STAGE}/${STACK}.tfstate" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true"

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

Run: `bash -n packages/genericsuite-be-scripts/scripts/aws_tf/bootstrap-tf-state.sh && bash -n packages/genericsuite-be-scripts/scripts/aws_tf/run-tf-deployment.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit (in `packages/genericsuite-be-scripts`)**

```bash
cd packages/genericsuite-be-scripts
git add scripts/aws_tf/bootstrap-tf-state.sh scripts/aws_tf/run-tf-deployment.sh
git commit -m "Add: OpenTofu generic deployment wrapper and S3 state bootstrap [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `s3-bucket` module + `s3` stack (backend)

**Files:**
- Create: `BE_TF/modules/s3-bucket/{versions.tf,variables.tf,main.tf,outputs.tf}`
- Create: `BE_TF/stacks/s3/{versions.tf,backend.tf,providers.tf,variables.tf,main.tf,outputs.tf}`

**Interfaces:**
- Produces module `s3-bucket`: inputs `bucket_name (string)`, `app_name`, `stage`, `enable_public_read (bool, default false)`, `lambda_execution_role_arn (string, default "")`; outputs `bucket_name`, `bucket_arn`. Replaces `create_s3_bucket.sh` / `create_chatbot_s3_bucket.sh` / `S3-Policy-app-chatbot-attachments-TEMPLATE.json`.

- [ ] **Step 1: Write module `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 2: Write module `variables.tf`**

```hcl
variable "bucket_name" {
  description = "S3 bucket name"
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
  description = "Allow public s3:GetObject (legacy parity; keep false)"
  type        = bool
  default     = false
}

variable "lambda_execution_role_arn" {
  description = "Lambda/EC2 execution role ARN granted read/write; empty to skip"
  type        = string
  default     = ""
}
```

- [ ] **Step 3: Write module `main.tf`**

```hcl
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  tags = {
    comment = "Created by OpenTofu in ${var.stage} environment."
  }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = !var.enable_public_read
  restrict_public_buckets = !var.enable_public_read
}

locals {
  principals = compact([
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
    var.lambda_execution_role_arn,
  ])
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid    = "Allow${var.app_name}${var.stage}ReadAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = local.principals
    }
    actions = [
      "s3:ListBucketMultipartUploads",
      "s3:ListBucket",
      "s3:GetObjectTagging",
      "s3:GetObjectAcl",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
  }

  statement {
    sid    = "Allow${var.app_name}${var.stage}WriteAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = local.principals
    }
    actions = [
      "s3:PutObjectAcl",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
  }

  dynamic "statement" {
    for_each = var.enable_public_read ? [1] : []
    content {
      sid    = "AllowPublicRead"
      effect = "Allow"
      principals {
        type        = "AWS"
        identifiers = ["*"]
      }
      actions   = ["s3:GetObject"]
      resources = ["${aws_s3_bucket.this.arn}/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}
```

- [ ] **Step 4: Write module `outputs.tf`**

```hcl
output "bucket_name" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.this.arn
}
```

- [ ] **Step 5: Write stack `s3` files**

`BE_TF/stacks/s3/versions.tf` — same content as module `versions.tf` (Step 1).

`BE_TF/stacks/s3/backend.tf`:

```hcl
terraform {
  backend "s3" {}
}
```

`BE_TF/stacks/s3/providers.tf`:

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      App       = var.app_name
      Stage     = var.stage
      ManagedBy = "opentofu"
      Ticket    = "GS-334"
    }
  }
}
```

`BE_TF/stacks/s3/variables.tf`:

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "chatbot_attachments_bucket_name" {
  description = "Chatbot attachments bucket name (stage-resolved by wrapper)"
  type        = string
}

variable "lambda_execution_role_arn" {
  description = "Execution role ARN granted access to the bucket; empty to skip"
  type        = string
  default     = ""
}

variable "enable_public_read" {
  description = "Allow public s3:GetObject on the bucket"
  type        = bool
  default     = false
}
```

`BE_TF/stacks/s3/main.tf`:

```hcl
module "chatbot_attachments_bucket" {
  source = "../../modules/s3-bucket"

  bucket_name               = var.chatbot_attachments_bucket_name
  app_name                  = var.app_name
  stage                     = var.stage
  enable_public_read        = var.enable_public_read
  lambda_execution_role_arn = var.lambda_execution_role_arn
}
```

`BE_TF/stacks/s3/outputs.tf`:

```hcl
output "bucket_name" {
  description = "Chatbot attachments bucket name"
  value       = module.chatbot_attachments_bucket.bucket_name
}

output "bucket_arn" {
  description = "Chatbot attachments bucket ARN"
  value       = module.chatbot_attachments_bucket.bucket_arn
}
```

- [ ] **Step 6: Format and validate**

Run:
```bash
cd packages/genericsuite-be-scripts/scripts/aws_tf
tofu fmt -recursive
cd stacks/s3 && tofu init -backend=false && tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Commit (in `packages/genericsuite-be-scripts`)**

```bash
git add scripts/aws_tf/modules/s3-bucket scripts/aws_tf/stacks/s3
git commit -m "Add: OpenTofu s3-bucket module and s3 stack [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `kms-key` module + `kms` stack (backend)

**Files:**
- Create: `BE_TF/modules/kms-key/{versions.tf,variables.tf,main.tf,outputs.tf}`
- Create: `BE_TF/stacks/kms/{versions.tf,backend.tf,providers.tf,variables.tf,main.tf,outputs.tf}`

**Interfaces:**
- Produces module `kms-key`: inputs `alias`, `app_name`, `stage`; outputs `key_arn`, `key_id`, `alias_arn`, `asg_role_arn`. Ports `cf-template-kms-key.yml`; helper role names prefixed with `${var.alias}-` to avoid clashing with the live CF stack's static `KeyAdminRole`/`UseKeyRole`/`AttachKeyRole` names.

- [ ] **Step 1: Write module `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 2: Write module `variables.tf`**

```hcl
variable "alias" {
  description = "KMS key alias (without the alias/ prefix)"
  type        = string
  default     = "genericsuite-key"
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

- [ ] **Step 3: Write module `main.tf`**

```hcl
data "aws_caller_identity" "current" {}

locals {
  ec2_assume_role = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  admin_actions = [
    "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*",
    "kms:Update*", "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*",
    "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:GenerateDataKey",
  ]
  use_actions = [
    "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
    "kms:GenerateDataKey*", "kms:DescribeKey",
  ]
  grant_actions = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
}

resource "aws_iam_role" "key_admin" {
  name               = "${var.alias}-key-admin-role"
  assume_role_policy = local.ec2_assume_role

  inline_policy {
    name = "KeyAdminPolicy"
    policy = jsonencode({
      Version   = "2012-10-17"
      Statement = [{ Effect = "Allow", Action = local.admin_actions, Resource = "*" }]
    })
  }
}

resource "aws_iam_role" "use_key" {
  name               = "${var.alias}-use-key-role"
  assume_role_policy = local.ec2_assume_role

  inline_policy {
    name = "UseKeyPolicy"
    policy = jsonencode({
      Version   = "2012-10-17"
      Statement = [{ Effect = "Allow", Action = local.use_actions, Resource = "*" }]
    })
  }
}

resource "aws_iam_role" "attach_key" {
  name               = "${var.alias}-attach-key-role"
  assume_role_policy = local.ec2_assume_role

  inline_policy {
    name = "AttachKeyPolicy"
    policy = jsonencode({
      Version   = "2012-10-17"
      Statement = [{ Effect = "Allow", Action = local.grant_actions, Resource = "*" }]
    })
  }
}

resource "aws_iam_role" "asg" {
  name = "${var.alias}-tf-asg-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "autoscaling.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_kms_key" "this" {
  description = "KMS key for encrypting Secrets Manager secrets and other resources"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Enable IAM User Permissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "Allow access for Key Administrators"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.key_admin.arn }
        Action    = local.admin_actions
        Resource  = "*"
      },
      {
        Sid       = "Allow use of the key"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.use_key.arn }
        Action    = local.use_actions
        Resource  = "*"
      },
      {
        Sid       = "Allow attachment of persistent resources"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.attach_key.arn }
        Action    = local.grant_actions
        Resource  = "*"
      },
      {
        Sid       = "Allow use of the key for EBS volumes"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = local.use_actions
        Resource  = "*"
      },
      {
        Sid       = "Allow EC2 attachment of persistent resources"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = local.grant_actions
        Resource  = "*"
        Condition = { Bool = { "kms:GrantIsForAWSResource" = true } }
      },
      {
        Sid       = "Allow use of the key for ASG"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.asg.arn }
        Action    = local.use_actions
        Resource  = "*"
      },
      {
        Sid       = "Allow attachment of persistent resources for ASG"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.asg.arn }
        Action    = local.grant_actions
        Resource  = "*"
        Condition = { Bool = { "kms:GrantIsForAWSResource" = true } }
      },
    ]
  })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.key_id
}
```

- [ ] **Step 4: Write module `outputs.tf`**

```hcl
output "key_arn" {
  description = "KMS key ARN"
  value       = aws_kms_key.this.arn
}

output "key_id" {
  description = "KMS key ID"
  value       = aws_kms_key.this.key_id
}

output "alias_arn" {
  description = "KMS alias ARN"
  value       = aws_kms_alias.this.arn
}

output "asg_role_arn" {
  description = "ASG role ARN"
  value       = aws_iam_role.asg.arn
}
```

- [ ] **Step 5: Write stack `kms`**

`versions.tf`, `backend.tf`, `providers.tf`: same content as Task 3 Step 5 stack files.

`BE_TF/stacks/kms/variables.tf`:

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "kms_key_alias" {
  description = "KMS key alias"
  type        = string
  default     = "genericsuite-key"
}
```

`BE_TF/stacks/kms/main.tf`:

```hcl
module "kms_key" {
  source = "../../modules/kms-key"

  alias    = var.kms_key_alias
  app_name = var.app_name
  stage    = var.stage
}
```

`BE_TF/stacks/kms/outputs.tf`:

```hcl
output "key_arn" {
  description = "KMS key ARN"
  value       = module.kms_key.key_arn
}

output "alias_arn" {
  description = "KMS alias ARN"
  value       = module.kms_key.alias_arn
}
```

- [ ] **Step 6: Format, validate**

Run:
```bash
cd packages/genericsuite-be-scripts/scripts/aws_tf
tofu fmt -recursive
cd stacks/kms && tofu init -backend=false && tofu validate
```
Expected: `Success! The configuration is valid.` (If `inline_policy` is rejected by AWS provider 6.x, replace each with a separate `aws_iam_role_policy` resource with the same name/policy and re-validate.)

- [ ] **Step 7: Commit**

```bash
git add scripts/aws_tf/modules/kms-key scripts/aws_tf/stacks/kms
git commit -m "Add: OpenTofu kms-key module and kms stack [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: `secrets` module + `secrets` stack + secrets map builder (backend)

**Files:**
- Create: `BE_TF/modules/secrets/{versions.tf,variables.tf,main.tf,outputs.tf}`
- Create: `BE_TF/stacks/secrets/{versions.tf,backend.tf,providers.tf,variables.tf,main.tf,outputs.tf,build-tfvars.sh}`

**Interfaces:**
- Consumes: `TF_VAR_secrets_map` / `TF_VAR_envs_map` JSON maps exported by `build-tfvars.sh` (sourced by the Task 2 wrapper when STACK=secrets).
- Produces module `secrets`: inputs `app_name`, `stage`, `kms_key_alias`, `secrets_map (map(string), sensitive)`, `envs_map (map(string))`; outputs `encrypted_secret_arn`, `envs_secret_arn`. Creates `{app}-{stage}-secrets` (KMS) + `{app}-{stage}-envs`. Ports `cf-template-secrets.yml` + the variable lists in `aws_secrets_manager.sh` — secrets travel as sensitive TF vars, never as stack parameters.

- [ ] **Step 1: Write module `versions.tf`** — same content as Task 3 Step 1.

- [ ] **Step 2: Write module `variables.tf`**

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "kms_key_alias" {
  description = "KMS key alias used to encrypt the secrets set"
  type        = string
  default     = "genericsuite-key"
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

- [ ] **Step 3: Write module `main.tf`**

```hcl
data "aws_kms_alias" "this" {
  name = "alias/${var.kms_key_alias}"
}

locals {
  stage_uppercase = upper(var.stage)
}

resource "aws_secretsmanager_secret" "encrypted" {
  name        = "${var.app_name}-${var.stage}-secrets"
  description = "Encrypted-Secrets-for-${var.app_name}-${local.stage_uppercase}"
  kms_key_id  = data.aws_kms_alias.this.target_key_arn
}

resource "aws_secretsmanager_secret_version" "encrypted" {
  secret_id     = aws_secretsmanager_secret.encrypted.id
  secret_string = jsonencode(var.secrets_map)
}

resource "aws_secretsmanager_secret" "envs" {
  name        = "${var.app_name}-${var.stage}-envs"
  description = "Environment-variables-for-${var.app_name}-${local.stage_uppercase}"
}

resource "aws_secretsmanager_secret_version" "envs" {
  secret_id     = aws_secretsmanager_secret.envs.id
  secret_string = jsonencode(var.envs_map)
}
```

- [ ] **Step 4: Write module `outputs.tf`**

```hcl
output "encrypted_secret_arn" {
  description = "ARN of the encrypted secrets set"
  value       = aws_secretsmanager_secret.encrypted.arn
}

output "envs_secret_arn" {
  description = "ARN of the plain envvars set"
  value       = aws_secretsmanager_secret.envs.arn
}
```

- [ ] **Step 5: Write stack `secrets`**

`versions.tf`, `backend.tf`, `providers.tf`: same content as Task 3 Step 5 stack files.

`BE_TF/stacks/secrets/variables.tf`:

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "kms_key_alias" {
  description = "KMS key alias"
  type        = string
  default     = "genericsuite-key"
}

variable "secrets_map" {
  description = "Encrypted secrets key/value map (built by build-tfvars.sh)"
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "envs_map" {
  description = "Plain envvars key/value map (built by build-tfvars.sh)"
  type        = map(string)
  default     = {}
}
```

`BE_TF/stacks/secrets/main.tf`:

```hcl
module "secrets" {
  source = "../../modules/secrets"

  app_name      = var.app_name
  stage         = var.stage
  kms_key_alias = var.kms_key_alias
  secrets_map   = var.secrets_map
  envs_map      = var.envs_map
}
```

`BE_TF/stacks/secrets/outputs.tf`:

```hcl
output "encrypted_secret_arn" {
  description = "ARN of the encrypted secrets set"
  value       = module.secrets.encrypted_secret_arn
}

output "envs_secret_arn" {
  description = "ARN of the plain envvars set"
  value       = module.secrets.envs_secret_arn
}
```

- [ ] **Step 6: Write `BE_TF/stacks/secrets/build-tfvars.sh`** (sourced by the wrapper; mirrors `aws_secrets_manager.sh` variable lists incl. `update_additional_envvars.sh` hook and stage-dependent resolution)

```bash
#!/bin/bash
# stacks/secrets/build-tfvars.sh
# Sourced by run-tf-deployment.sh. Builds TF_VAR_secrets_map and
# TF_VAR_envs_map as JSON from the same variable lists used by
# scripts/aws_secrets/aws_secrets_manager.sh.
# 2026-07-16 | CR [GS-334]

# Secrets (encrypted)
CORE_SECRETS="APP_SECRET_KEY APP_SUPERADMIN_EMAIL APP_DB_URI SMTP_USER SMTP_PASSWORD SMTP_DEFAULT_SENDER STORAGE_URL_SEED"
EXTENSION_SECRETS="OPENAI_API_KEY GOOGLE_API_KEY GOOGLE_CSE_ID GOOGLE_MAPS_API_KEY \
    ANTHROPIC_API_KEY LANGCHAIN_API_KEY HUGGINGFACE_API_KEY GROQ_API_KEY AIMLAPI_API_KEY \
    NVIDIA_API_KEY RHYMES_CHAT_API_KEY RHYMES_VIDEO_API_KEY IBM_WATSONX_API_KEY \
    IBM_WATSONX_PROJECT_ID OPENROUTER_API_KEY XAI_API_KEY TOGETHER_API_KEY"
APP_SECRETS="${APP_SECRETS:-}"

# Environment variables (plain)
CORE_ENVS="APP_NAME FLASK_APP APP_DEBUG APP_STAGE APP_CORS_ORIGIN APP_DB_ENGINE APP_DB_NAME CURRENT_FRAMEWORK DEFAULT_LANG GIT_SUBMODULE_URL GIT_SUBMODULE_LOCAL_PATH SMTP_SERVER SMTP_PORT SMTP_DEFAULT_SENDER APP_HOST_NAME CLOUD_PROVIDER AWS_REGION DYNAMDB_PREFIX"
EXTENSION_ENVS="AI_ASSISTANT_NAME AWS_S3_CHATBOT_ATTACHMENTS_BUCKET OPENAI_MODEL OPENAI_TEMPERATURE LANGCHAIN_PROJECT USER_AGENT HUGGINGFACE_DEFAULT_CHAT_MODEL"
APP_ENVS="${APP_ENVS:-}"

# App-specific additions hook (same contract as the CF path)
if [ -f "${REPO_BASEDIR}/scripts/aws/update_additional_envvars.sh" ]; then
    # shellcheck disable=SC1091
    . "${REPO_BASEDIR}/scripts/aws/update_additional_envvars.sh"
fi

# Resolve stage-dependent variables (VAR = VAR_${STAGE_UPPERCASE})
STAGE_DEPENDENT_VAR_LIST="${STAGE_DEPENDENT_VAR_LIST:-APP_DB_ENGINE APP_DB_NAME APP_DB_URI APP_CORS_ORIGIN AWS_S3_CHATBOT_ATTACHMENTS_BUCKET}"
for base_name in ${STAGE_DEPENDENT_VAR_LIST}; do
    resolved="$(eval echo "\${${base_name}_${STAGE_UPPERCASE}:-}")"
    if [ "${resolved}" != "" ]; then
        eval "export ${base_name}=\"\${resolved}\""
    fi
done

# Special envvars not in .env (same as aws_secrets_manager.sh prepare_envars)
export APP_STAGE="${STAGE}"
export USER_AGENT="${APP_NAME_LOWERCASE}-${STAGE}"
export DYNAMDB_PREFIX="${APP_NAME_LOWERCASE}_${STAGE}_"
AWS_DEPLOYMENT_TYPE="${AWS_DEPLOYMENT_TYPE:-lambda}"
if [ "${AWS_DEPLOYMENT_TYPE}" = "lambda" ]; then
    export APP_HOST_NAME="app-${STAGE}.${APP_DOMAIN_NAME:-}"
elif [ "${AWS_DEPLOYMENT_TYPE}" = "ec2" ]; then
    export APP_HOST_NAME="app-${STAGE}-2.${APP_DOMAIN_NAME:-}"
elif [ "${AWS_DEPLOYMENT_TYPE}" = "fargate" ]; then
    export APP_HOST_NAME="app-${STAGE}-3.${APP_DOMAIN_NAME:-}"
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
        value="$(eval echo "\${${name}:-}")"
        json="$(echo "${json}" | jq --arg k "${name}" --arg v "${value}" '. + {($k): $v}')"
    done
    echo "${json}"
}

TF_VAR_secrets_map="$(build_json_map "${CORE_SECRETS} ${EXTENSION_SECRETS} ${APP_SECRETS}")"
TF_VAR_envs_map="$(build_json_map "${CORE_ENVS} ${EXTENSION_ENVS} ${APP_ENVS}")"
export TF_VAR_secrets_map TF_VAR_envs_map

echo "Secrets/envs TF_VAR maps built ($(echo "${TF_VAR_envs_map}" | jq 'length') envs, $(echo "${TF_VAR_secrets_map}" | jq 'length') secrets)."
```

- [ ] **Step 7: Format, validate, syntax-check**

Run:
```bash
cd packages/genericsuite-be-scripts/scripts/aws_tf
tofu fmt -recursive
(cd stacks/secrets && tofu init -backend=false && tofu validate)
bash -n stacks/secrets/build-tfvars.sh && echo OK
```
Expected: `Success! The configuration is valid.` and `OK`.

- [ ] **Step 8: Commit**

```bash
git add scripts/aws_tf/modules/secrets scripts/aws_tf/stacks/secrets
git commit -m "Add: OpenTofu secrets module, stack and .env map builder [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: `dynamodb-tables` module + `dynamodb` stack + tfvars generator (backend)

**Files:**
- Create: `BE_TF/modules/dynamodb-tables/{versions.tf,variables.tf,main.tf,outputs.tf}`
- Create: `BE_TF/stacks/dynamodb/{versions.tf,backend.tf,providers.tf,variables.tf,main.tf,outputs.tf,build-tfvars.sh}`
- Create: `BE_TF/generate_dynamodb_tfvars.py`

**Interfaces:**
- Consumes: GenericSuite JSON config dir (same input as `generate_dynamodb_cf.py`: `<basedir>/frontend/*.json` merged with `<basedir>/backend/<same>.json`, keys `table_name` + `fieldElements[].type == "_id"`).
- Produces module `dynamodb-tables`: inputs `app_name`, `stage`, `tables (list(object({ name=string, hash_key=string, range_key=optional(string) })))`; output `table_names (map)`. Table name: `{app_name}_{stage}_{name}`, `PAY_PER_REQUEST` (improvement over 1 RCU/WCU provisioned).
- Produces `generate_dynamodb_tfvars.py BASE_CONFIG_PATH OUTPUT_JSON_PATH` writing `{"tables":[...]}`.

- [ ] **Step 1: Write module `versions.tf`** — same content as Task 3 Step 1.

- [ ] **Step 2: Write module `variables.tf`**

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "tables" {
  description = "DynamoDB table definitions from the GenericSuite JSON config"
  type = list(object({
    name      = string
    hash_key  = string
    range_key = optional(string)
  }))
}
```

- [ ] **Step 3: Write module `main.tf`**

```hcl
resource "aws_dynamodb_table" "this" {
  for_each = { for t in var.tables : t.name => t }

  name         = "${var.app_name}_${var.stage}_${each.value.name}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = each.value.hash_key
  range_key    = try(each.value.range_key, null)

  attribute {
    name = each.value.hash_key
    type = "S"
  }

  dynamic "attribute" {
    for_each = each.value.range_key != null ? [each.value.range_key] : []
    content {
      name = attribute.value
      type = "S"
    }
  }

  point_in_time_recovery {
    enabled = true
  }
}
```

- [ ] **Step 4: Write module `outputs.tf`**

```hcl
output "table_names" {
  description = "Map of logical table name to full DynamoDB table name"
  value       = { for k, t in aws_dynamodb_table.this : k => t.name }
}
```

- [ ] **Step 5: Write `BE_TF/generate_dynamodb_tfvars.py`**

```python
"""
Generates a dynamodb.auto.tfvars.json for the OpenTofu dynamodb stack from
the GenericSuite configuration .JSON files. Reads the same inputs as
scripts/aws_dynamodb/generate_dynamodb_cf/generate_dynamodb_cf.py.
2026-07-16 | CR [GS-334]
"""
import json
import os
import sys


def get_table_definition(config: dict) -> dict:
    """Extract {name, hash_key, range_key} from a GenericSuite config."""
    table_name = config.get('table_name')
    if not table_name:
        return {}
    partition_key = None
    sort_key = None
    for field in config.get('fieldElements', []):
        if field.get('type') == '_id':
            if not partition_key:
                if field.get('name') == 'id':
                    partition_key = '_id'
                else:
                    partition_key = field.get('name')
            else:
                sort_key = field.get('name')
    if not partition_key:
        return {}
    definition = {'name': table_name, 'hash_key': partition_key}
    if sort_key:
        definition['range_key'] = sort_key
    return definition


def generate_tables(basedir: str) -> list:
    tables = []
    dir_path = os.path.join(basedir, 'frontend')
    for root, _, files in os.walk(dir_path):
        for file in sorted(files):
            if not file.endswith('.json'):
                continue
            with open(os.path.join(root, file), 'r', encoding='utf-8') as f:
                config = json.load(f)
            backend_path = os.path.join(basedir, 'backend', file)
            if os.path.exists(backend_path):
                with open(backend_path, 'r', encoding='utf-8') as f:
                    config.update(json.load(f))
            definition = get_table_definition(config)
            if definition:
                tables.append(definition)
    return tables


def main():
    if len(sys.argv) < 3:
        print('Usage: python generate_dynamodb_tfvars.py'
              ' <base_config_path> <output_tfvars_json_path>')
        sys.exit(1)
    base_config_path = sys.argv[1]
    output_path = sys.argv[2]
    tables = generate_tables(base_config_path)
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump({'tables': tables}, f, indent=2)
    print(f'{len(tables)} DynamoDB table definitions written to {output_path}')


if __name__ == '__main__':
    main()
```

- [ ] **Step 6: Write stack `dynamodb`**

`versions.tf`, `backend.tf`, `providers.tf`: same content as Task 3 Step 5 stack files.

`BE_TF/stacks/dynamodb/variables.tf`:

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "tables" {
  description = "DynamoDB table definitions (generated into dynamodb.auto.tfvars.json)"
  type = list(object({
    name      = string
    hash_key  = string
    range_key = optional(string)
  }))
  default = []
}
```

`BE_TF/stacks/dynamodb/main.tf`:

```hcl
module "dynamodb_tables" {
  source = "../../modules/dynamodb-tables"

  app_name = var.app_name
  stage    = var.stage
  tables   = var.tables
}
```

`BE_TF/stacks/dynamodb/outputs.tf`:

```hcl
output "table_names" {
  description = "Created DynamoDB table names"
  value       = module.dynamodb_tables.table_names
}
```

`BE_TF/stacks/dynamodb/build-tfvars.sh`:

```bash
#!/bin/bash
# stacks/dynamodb/build-tfvars.sh
# Sourced by run-tf-deployment.sh. Generates dynamodb.auto.tfvars.json from
# the GenericSuite JSON config dir (GIT_SUBMODULE_LOCAL_PATH).
# 2026-07-16 | CR [GS-334]

if [ "${GIT_SUBMODULE_LOCAL_PATH:-}" = "" ]; then
    echo "ERROR: GIT_SUBMODULE_LOCAL_PATH is not set (needed to locate the JSON config dir)"
    exit 1
fi

DYNDB_CONFIG_DIR="${REPO_BASEDIR}/${GIT_SUBMODULE_LOCAL_PATH}"
if [ ! -d "${DYNDB_CONFIG_DIR}/frontend" ]; then
    echo "ERROR: '${DYNDB_CONFIG_DIR}/frontend' not found"
    exit 1
fi

python3 "${SCRIPTS_DIR}/generate_dynamodb_tfvars.py" \
    "${DYNDB_CONFIG_DIR}" \
    "${SCRIPTS_DIR}/stacks/dynamodb/dynamodb.auto.tfvars.json"
```

Also add `dynamodb.auto.tfvars.json` to `packages/genericsuite-be-scripts/.gitignore` (it is generated per consuming app):

```
# OpenTofu generated tfvars [GS-334]
scripts/aws_tf/stacks/dynamodb/dynamodb.auto.tfvars.json
```

- [ ] **Step 7: Test the generator against fastapitemplate config**

Run:
```bash
python3 packages/genericsuite-be-scripts/scripts/aws_tf/generate_dynamodb_tfvars.py \
  packages/genericsuite-basecamp/mkdocs_root/code/fastapitemplate/config_dbdef \
  /tmp/dynamodb.auto.tfvars.json && cat /tmp/dynamodb.auto.tfvars.json | jq '.tables | length'
```
Expected: a table count > 0 and valid JSON with `name`/`hash_key` keys.

- [ ] **Step 8: Format, validate**

Run:
```bash
cd packages/genericsuite-be-scripts/scripts/aws_tf
tofu fmt -recursive
(cd stacks/dynamodb && tofu init -backend=false && tofu validate)
bash -n stacks/dynamodb/build-tfvars.sh && echo OK
```
Expected: valid + `OK`.

- [ ] **Step 9: Commit**

```bash
git add scripts/aws_tf/modules/dynamodb-tables scripts/aws_tf/stacks/dynamodb scripts/aws_tf/generate_dynamodb_tfvars.py .gitignore
git commit -m "Add: OpenTofu dynamodb-tables module, stack and tfvars generator [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: `ecr-repository` module + `ecr` stack (backend)

**Files:**
- Create: `BE_TF/modules/ecr-repository/{versions.tf,variables.tf,main.tf,outputs.tf}`
- Create: `BE_TF/stacks/ecr/{versions.tf,backend.tf,providers.tf,variables.tf,main.tf,outputs.tf}`

**Interfaces:**
- Produces module `ecr-repository`: inputs `repository_name`, `images_to_keep (number, default 2)`; outputs `repository_url`, `repository_arn`. Replaces the `aws ecr create-repository` calls in `big_lambdas_manager.sh`/`run-fastapi-ecr-creation.sh` and the retention behavior of `clean_ecr_images.sh`. Stack creates two repos: `{lambda_function_name}` (Lambda images) and `{lambda_function_name}-ec2` (EC2 images).

- [ ] **Step 1: Write module `versions.tf`** — same content as Task 3 Step 1.

- [ ] **Step 2: Write module files**

`variables.tf`:

```hcl
variable "repository_name" {
  description = "ECR repository name"
  type        = string
}

variable "images_to_keep" {
  description = "How many most-recent images to keep (parity with clean_ecr_images.sh)"
  type        = number
  default     = 2
}
```

`main.tf`:

```hcl
resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${var.images_to_keep} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.images_to_keep
        }
        action = { type = "expire" }
      },
    ]
  })
}
```

`outputs.tf`:

```hcl
output "repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "ECR repository ARN"
  value       = aws_ecr_repository.this.arn
}
```

- [ ] **Step 3: Write stack `ecr`**

`versions.tf`, `backend.tf`, `providers.tf`: same content as Task 3 Step 5 stack files.

`variables.tf`:

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "lambda_function_name" {
  description = "Base resource name with stage (AWS_LAMBDA_FUNCTION_NAME-STAGE, lowercase)"
  type        = string
}

variable "images_to_keep" {
  description = "How many most-recent images to keep"
  type        = number
  default     = 2
}

variable "create_ec2_repository" {
  description = "Also create the -ec2 repository used by the EC2/ALB deployment"
  type        = bool
  default     = true
}
```

`main.tf`:

```hcl
module "lambda_repository" {
  source = "../../modules/ecr-repository"

  repository_name = var.lambda_function_name
  images_to_keep  = var.images_to_keep
}

module "ec2_repository" {
  source = "../../modules/ecr-repository"
  count  = var.create_ec2_repository ? 1 : 0

  repository_name = "${var.lambda_function_name}-ec2"
  images_to_keep  = var.images_to_keep
}
```

`outputs.tf`:

```hcl
output "lambda_repository_url" {
  description = "ECR repository URL for Lambda images"
  value       = module.lambda_repository.repository_url
}

output "ec2_repository_url" {
  description = "ECR repository URL for EC2 images"
  value       = var.create_ec2_repository ? module.ec2_repository[0].repository_url : ""
}
```

- [ ] **Step 4: Format, validate** — run the Task 3 Step 6 commands with `stacks/ecr`. Expected: valid.

- [ ] **Step 5: Commit**

```bash
git add scripts/aws_tf/modules/ecr-repository scripts/aws_tf/stacks/ecr
git commit -m "Add: OpenTofu ecr-repository module and ecr stack [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: `app-domain` module + `domain` stack (backend)

**Files:**
- Create: `BE_TF/modules/app-domain/{versions.tf,variables.tf,main.tf,outputs.tf}`
- Create: `BE_TF/stacks/domain/{versions.tf,backend.tf,providers.tf,variables.tf,main.tf,outputs.tf}`

**Interfaces:**
- Produces module `app-domain`: inputs `domain_name`, `hosted_zone_name` (zone looked up by name — replaces `get_hosted_zone_id()`), `app_name`, `stage`; outputs `certificate_arn` (validated), `hosted_zone_id`. Replaces `cf-template-ec2-domain.yml` including its two custom-resource Lambdas — native ACM DNS validation; no bogus 192.168.x.x A record.
- Stack `domain` computes the ALB API domain `api-{stage}-2.{app_domain_name}` (same rule as `run-ec2-cloud-deploy.sh`).

- [ ] **Step 1: Write module `versions.tf`** — same content as Task 3 Step 1.

- [ ] **Step 2: Write module files**

`variables.tf`:

```hcl
variable "domain_name" {
  description = "FQDN to create the certificate for (e.g. api-qa-2.example.com)"
  type        = string
}

variable "hosted_zone_name" {
  description = "Route53 hosted zone name (e.g. example.com)"
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

`main.tf`:

```hcl
data "aws_route53_zone" "this" {
  name = "${var.hosted_zone_name}."
}

resource "aws_acm_certificate" "this" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = {
    Name = "${var.app_name}-${var.stage}-ssl-certificate"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}
```

`outputs.tf`:

```hcl
output "certificate_arn" {
  description = "Validated ACM certificate ARN"
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "hosted_zone_id" {
  description = "Route53 hosted zone ID"
  value       = data.aws_route53_zone.this.zone_id
}
```

- [ ] **Step 3: Write stack `domain`**

`versions.tf`, `backend.tf`, `providers.tf`: same content as Task 3 Step 5 stack files.

`variables.tf`:

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "app_domain_name" {
  description = "Root application domain (APP_DOMAIN_NAME in .env)"
  type        = string
}

variable "api_domain_name" {
  description = "API FQDN override; empty computes api-{stage}-2.{app_domain_name}"
  type        = string
  default     = ""
}
```

`main.tf`:

```hcl
locals {
  api_domain_name = var.api_domain_name != "" ? var.api_domain_name : "api-${var.stage}-2.${var.app_domain_name}"
}

module "app_domain" {
  source = "../../modules/app-domain"

  domain_name      = local.api_domain_name
  hosted_zone_name = var.app_domain_name
  app_name         = var.app_name
  stage            = var.stage
}
```

`outputs.tf`:

```hcl
output "certificate_arn" {
  description = "Validated ACM certificate ARN"
  value       = module.app_domain.certificate_arn
}

output "hosted_zone_id" {
  description = "Route53 hosted zone ID"
  value       = module.app_domain.hosted_zone_id
}

output "domain_name" {
  description = "API FQDN"
  value       = local.api_domain_name
}
```

- [ ] **Step 4: Format, validate** — Task 3 Step 6 commands with `stacks/domain`. Expected: valid.

- [ ] **Step 5: Commit**

```bash
git add scripts/aws_tf/modules/app-domain scripts/aws_tf/stacks/domain
git commit -m "Add: OpenTofu app-domain module with native ACM DNS validation [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: `ec2-alb` module + `ec2` stack (backend)

**Files:**
- Create: `BE_TF/modules/ec2-alb/{versions.tf,variables.tf,main.tf,user-data.sh.tftpl,outputs.tf}`
- Create: `BE_TF/stacks/ec2/{versions.tf,backend.tf,providers.tf,variables.tf,main.tf,outputs.tf}`

**Interfaces:**
- Consumes: `certificate_arn` + `hosted_zone_id` from the `domain` stack (via `terraform_remote_state`), ECR repo from `ecr` stack conventions.
- Produces module `ec2-alb`: ports `cf-template-ec2-elb.yml` (VPC, 2 public subnets, IGW, routes, IAM instance role/profile, CloudWatch log group, SGs, launch template + user-data, ASG, ALB, target group, HTTPS listener, Route53 alias). Improvements: both subnets route-table-associated (CF only wired subnet 1), AMI via SSM parameter instead of hardcoded `ami-0195204d5dce06d99`, SSH ingress only when `ssh_ingress_cidr != ""`, Secrets Manager policy scoped to the two app secret ARNs, native `aws_route53_record` alias instead of the Lambda custom resource, key pair created with `tls_private_key` when `create_key_pair = true`.

- [ ] **Step 1: Write module `versions.tf`** (adds `tls` provider)

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}
```

- [ ] **Step 2: Write module `variables.tf`**

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "ecr_repository_name" {
  description = "ECR repository name holding the app image"
  type        = string
}

variable "ecr_image_uri" {
  description = "Full ECR image URI (without tag)"
  type        = string
}

variable "ecr_image_tag" {
  description = "ECR image tag to run"
  type        = string
  default     = "latest"
}

variable "domain_name" {
  description = "FQDN for the ALB (e.g. api-qa-2.example.com)"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID"
  type        = string
}

variable "certificate_arn" {
  description = "Validated ACM certificate ARN for the HTTPS listener"
  type        = string
}

variable "s3_bucket_name" {
  description = "App S3 bucket the instance can read/write"
  type        = string
}

variable "kms_key_alias" {
  description = "KMS key alias"
  type        = string
  default     = "genericsuite-key"
}

variable "asm_secrets_arn" {
  description = "Secrets Manager encrypted secrets ARN"
  type        = string
}

variable "asm_envs_arn" {
  description = "Secrets Manager envvars ARN"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "create_key_pair" {
  description = "Create the SSH key pair and write the .pem locally"
  type        = bool
  default     = true
}

variable "ssh_keys_directory" {
  description = "Local directory for the generated .pem file"
  type        = string
  default     = "~/.ssh"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH; empty disables SSH ingress (use SSM)"
  type        = string
  default     = ""
}

variable "asg_min_size" {
  description = "ASG minimum size"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "ASG maximum size"
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "ASG desired capacity"
  type        = number
  default     = 1
}
```

- [ ] **Step 3: Write module `user-data.sh.tftpl`**

```bash
#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
echo "Starting GS instance boot sequence..."

yum update -y
yum install aws-cli jq amazon-ssm-agent amazon-cloudwatch-agent -y

cat <<EOF > /opt/aws/amazon-cloudwatch-agent/bin/config.json
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "${log_group_name}",
            "log_stream_name": "{instance_id}-user-data-logs"
          },
          {
            "file_path": "/var/log/docker",
            "log_group_name": "${log_group_name}",
            "log_stream_name": "{instance_id}-docker-logs"
          }
        ]
      }
    }
  },
  "metrics": {
    "metrics_collected": {
      "disk": { "measurement": ["used_percent"], "metrics_collection_interval": 60, "resources": ["/"] },
      "mem": { "measurement": ["mem_used_percent"], "metrics_collection_interval": 60 }
    }
  }
}
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json

amazon-linux-extras install docker -y
systemctl start amazon-ssm-agent
systemctl start docker
systemctl enable docker

aws ecr get-login-password --region ${aws_region} | docker login --username AWS --password-stdin ${aws_account_id}.dkr.ecr.${aws_region}.amazonaws.com
docker pull ${ecr_image_uri}:${ecr_image_tag} > /dev/null 2>&1
docker run -d -p 80:80 --name gs_app_be -e CLOUD_PROVIDER=aws -e APP_NAME=${app_name} -e APP_STAGE=${stage} -e AWS_REGION=${aws_region} ${ecr_image_uri}:${ecr_image_tag}

if [ "$(docker ps -q -f name=gs_app_be)" ]; then
  echo "Container is running successfully."
else
  echo "Container failed to start. Check docker logs."
  docker logs gs_app_be
fi
echo "GS instance boot sequence finished"
```

- [ ] **Step 4: Write module `main.tf`**

```hcl
locals {
  name_prefix = "${var.app_name}-${var.stage}"
  key_name    = "${local.name_prefix}-ec2-keys"
}

# --- Networking ---

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = "10.0.${count.index + 1}.0/24"
  map_public_ip_on_launch = true

  tags = { Name = "${local.name_prefix}-subnet-${count.index + 1}" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name_prefix}-rt" }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.this.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.this.id
}

# --- SSH key pair ---

resource "tls_private_key" "this" {
  count     = var.create_key_pair ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "this" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = local.key_name
  public_key = tls_private_key.this[0].public_key_openssh
}

resource "local_sensitive_file" "pem" {
  count           = var.create_key_pair ? 1 : 0
  filename        = pathexpand("${var.ssh_keys_directory}/${local.key_name}.pem")
  content         = tls_private_key.this[0].private_key_pem
  file_permission = "0400"
}

# --- IAM ---

resource "aws_iam_role" "instance" {
  name = "${local.name_prefix}-tf-ec2-instance-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
  ]
}

resource "aws_iam_role_policy" "instance" {
  name = "${local.name_prefix}-tf-ec2-instance-policy"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:Describe*"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject", "s3:PutObjectAcl", "s3:GetObject",
          "s3:GetObjectAcl", "s3:DeleteObject",
        ]
        Resource = "arn:aws:s3:::${var.s3_bucket_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream",
          "logs:PutLogEvents", "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:${local.name_prefix}-ec2-logs:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.ecr_repository_name}"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.asm_secrets_arn, var.asm_envs_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:CreateGrant"]
        Resource = "arn:aws:kms:${var.aws_region}:${var.aws_account_id}:key/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${local.name_prefix}-tf-ec2-instance-profile"
  role = aws_iam_role.instance.name
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "${local.name_prefix}-ec2-logs"
  retention_in_days = 30
}

# --- Security groups ---

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-sg-lb"
  description = "Enable HTTPS access to the ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "instance" {
  name        = "${local.name_prefix}-sg-ec2"
  description = "Enable HTTP access from the ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.alb.id]
  }

  dynamic "ingress" {
    for_each = var.ssh_ingress_cidr != "" ? [var.ssh_ingress_cidr] : []
    content {
      protocol    = "tcp"
      from_port   = 22
      to_port     = 22
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Launch template + ASG ---

data "aws_ssm_parameter" "al2_ami" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

resource "aws_launch_template" "this" {
  name          = "${local.name_prefix}-launch-template"
  image_id      = data.aws_ssm_parameter.al2_ami.value
  instance_type = var.instance_type
  key_name      = var.create_key_pair ? aws_key_pair.this[0].key_name : local.key_name

  vpc_security_group_ids = [aws_security_group.instance.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp2"
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tftpl", {
    app_name       = var.app_name
    stage          = var.stage
    aws_region     = var.aws_region
    aws_account_id = var.aws_account_id
    ecr_image_uri  = var.ecr_image_uri
    ecr_image_tag  = var.ecr_image_tag
    log_group_name = aws_cloudwatch_log_group.this.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name_prefix}-instance" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name_prefix}-root-volume" }
  }
}

resource "aws_autoscaling_group" "this" {
  name                      = "${local.name_prefix}-asg"
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  vpc_zone_identifier       = aws_subnet.public[*].id
  target_group_arns         = [aws_lb_target_group.this.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 1200

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-instance"
    propagate_at_launch = true
  }
}

# --- ALB ---

resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "this" {
  name        = "${local.name_prefix}-tg"
  vpc_id      = aws_vpc.this.id
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"

  health_check {
    protocol = "HTTP"
    port     = "80"
    path     = "/"
    matcher  = "200"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# --- DNS (replaces the UpdateRoute53RecordSet Lambda custom resource) ---

resource "aws_route53_record" "alb" {
  zone_id         = var.hosted_zone_id
  name            = var.domain_name
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}
```

- [ ] **Step 5: Write module `outputs.tf`**

```hcl
output "load_balancer_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.this.dns_name
}

output "load_balancer_arn" {
  description = "ALB ARN"
  value       = aws_lb.this.arn
}

output "target_group_arn" {
  description = "Target group ARN"
  value       = aws_lb_target_group.this.arn
}

output "autoscaling_group_name" {
  description = "ASG name"
  value       = aws_autoscaling_group.this.name
}

output "app_url" {
  description = "Application URL"
  value       = "https://${var.domain_name}"
}
```

- [ ] **Step 6: Write stack `ec2`**

`versions.tf`: same as module Step 1 of this task (aws + tls + local). `backend.tf`, `providers.tf`: same content as Task 3 Step 5 stack files.

`variables.tf`:

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "app_domain_name" {
  description = "Root application domain"
  type        = string
}

variable "lambda_function_name" {
  description = "Base resource name with stage (AWS_LAMBDA_FUNCTION_NAME-STAGE, lowercase)"
  type        = string
}

variable "chatbot_attachments_bucket_name" {
  description = "App S3 bucket"
  type        = string
}

variable "kms_key_alias" {
  description = "KMS key alias"
  type        = string
  default     = "genericsuite-key"
}

variable "ecr_image_tag" {
  description = "ECR image tag to deploy (ECR_DOCKER_IMAGE_TAG)"
  type        = string
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH; empty disables SSH ingress"
  type        = string
  default     = ""
}

variable "tf_state_bucket" {
  description = "TF state bucket (to read the domain stack outputs)"
  type        = string
}
```

`main.tf`:

```hcl
data "terraform_remote_state" "domain" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = "${var.stage}/domain.tfstate"
    region = var.aws_region
  }
}

locals {
  ecr_repository_name = "${var.lambda_function_name}-ec2"
}

module "ec2_alb" {
  source = "../../modules/ec2-alb"

  app_name            = var.app_name
  stage               = var.stage
  aws_region          = var.aws_region
  aws_account_id      = var.aws_account_id
  ecr_repository_name = local.ecr_repository_name
  ecr_image_uri       = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.ecr_repository_name}"
  ecr_image_tag       = var.ecr_image_tag
  domain_name         = data.terraform_remote_state.domain.outputs.domain_name
  hosted_zone_id      = data.terraform_remote_state.domain.outputs.hosted_zone_id
  certificate_arn     = data.terraform_remote_state.domain.outputs.certificate_arn
  s3_bucket_name      = var.chatbot_attachments_bucket_name
  kms_key_alias       = var.kms_key_alias
  asm_secrets_arn     = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.app_name}-${var.stage}-secrets*"
  asm_envs_arn        = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.app_name}-${var.stage}-envs*"
  ssh_ingress_cidr    = var.ssh_ingress_cidr
}
```

`outputs.tf`:

```hcl
output "load_balancer_dns_name" {
  description = "ALB DNS name"
  value       = module.ec2_alb.load_balancer_dns_name
}

output "app_url" {
  description = "Application URL"
  value       = module.ec2_alb.app_url
}
```

Wrapper support: add these two exports to `run-tf-deployment.sh` right after the `TF_VAR_app_domain_name` export (Task 2 file):

```bash
export TF_VAR_tf_state_bucket="${TF_STATE_BUCKET}"
if [ "${ECR_DOCKER_IMAGE_TAG:-}" != "" ]; then
    export TF_VAR_ecr_image_tag="${ECR_DOCKER_IMAGE_TAG}"
fi
```

(Note: `TF_STATE_BUCKET` is computed before this point, so `TF_VAR_tf_state_bucket` goes after the bootstrap call.)

- [ ] **Step 7: Format, validate** — Task 3 Step 6 commands with `stacks/ec2`. Expected: valid. (If `managed_policy_arns` is rejected by AWS provider 6.x, replace with two `aws_iam_role_policy_attachment` resources and re-validate.)

- [ ] **Step 8: Commit**

```bash
git add scripts/aws_tf/modules/ec2-alb scripts/aws_tf/stacks/ec2 scripts/aws_tf/run-tf-deployment.sh
git commit -m "Add: OpenTofu ec2-alb module and ec2 stack [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: `lambda-api` module + `lambda` stack (backend)

**Files:**
- Create: `BE_TF/modules/lambda-api/{versions.tf,variables.tf,main.tf,outputs.tf}`
- Create: `BE_TF/stacks/lambda/{versions.tf,backend.tf,providers.tf,variables.tf,main.tf,outputs.tf}`

**Interfaces:**
- Produces module `lambda-api`: ports `template-sam.yml` — execution role, Lambda (`Image` or `Zip`), API Gateway REST API with root `ANY` + `{proxy+}` `ANY` `AWS_PROXY` integrations (replaces the enumerated OpenAPI paths — FastAPI/Flask/Chalice do their own routing), binary media types, deployment + stage `{stage}`, invoke permission, optional custom domain (EDGE) + base path mapping + Route53 alias. Inputs listed in `variables.tf` below; outputs `endpoint_url`, `function_arn`, `rest_api_id`, `custom_domain_url`.

- [ ] **Step 1: Write module `versions.tf`** — same content as Task 3 Step 1.

- [ ] **Step 2: Write module `variables.tf`**

```hcl
variable "function_name" {
  description = "Lambda function name (e.g. myapp-backend-qa)"
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

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "package_type" {
  description = "Lambda package type: Image or Zip"
  type        = string
  default     = "Image"
  validation {
    condition     = contains(["Image", "Zip"], var.package_type)
    error_message = "package_type must be Image or Zip."
  }
}

variable "image_uri" {
  description = "ECR image URI with tag (package_type = Image)"
  type        = string
  default     = ""
}

variable "zip_path" {
  description = "Path to deployment.zip (package_type = Zip)"
  type        = string
  default     = ""
}

variable "handler" {
  description = "Lambda handler (package_type = Zip)"
  type        = string
  default     = "main.handler"
}

variable "runtime" {
  description = "Python runtime (package_type = Zip)"
  type        = string
  default     = "python3.12"
}

variable "memory_size" {
  description = "Lambda memory (MB)"
  type        = number
  default     = 512
}

variable "timeout" {
  description = "Lambda timeout (seconds)"
  type        = number
  default     = 180
}

variable "environment_variables" {
  description = "Lambda environment variables"
  type        = map(string)
  default     = {}
}

variable "chatbot_attachments_bucket_name" {
  description = "S3 bucket the function can read/write"
  type        = string
}

variable "asm_secrets_arn" {
  description = "Secrets Manager encrypted secrets ARN pattern"
  type        = string
}

variable "asm_envs_arn" {
  description = "Secrets Manager envvars ARN pattern"
  type        = string
}

variable "domain_name" {
  description = "Custom API domain; empty disables the custom domain"
  type        = string
  default     = ""
}

variable "certificate_arn" {
  description = "ACM certificate ARN for the custom domain (us-east-1 for EDGE)"
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route53 zone for the custom domain record; empty skips the record"
  type        = string
  default     = ""
}

variable "binary_media_types" {
  description = "API Gateway binary media types"
  type        = list(string)
  default = [
    "multipart/form-data", "audio/basic", "audio/ogg", "audio/mp4",
    "audio/mpeg", "audio/wav", "audio/webm", "image/png", "image/jpg",
    "image/jpeg", "image/gif", "video/ogg", "video/mpeg", "video/webm",
    "application/octet-stream", "application/x-tar", "application/zip",
  ]
}
```

- [ ] **Step 3: Write module `main.tf`**

```hcl
locals {
  is_image = var.package_type == "Image"
}

resource "aws_iam_role" "lambda" {
  name = "${var.function_name}-tf-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.function_name}-tf-execution-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject", "s3:PutObjectAcl", "s3:GetObject",
          "s3:GetObjectAcl", "s3:DeleteObject",
        ]
        Resource = "arn:aws:s3:::${var.chatbot_attachments_bucket_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
        ]
        Resource = "arn:*:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.asm_secrets_arn, var.asm_envs_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:CreateGrant"]
        Resource = "arn:aws:kms:${var.aws_region}:${var.aws_account_id}:key/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
          "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan",
          "dynamodb:BatchGetItem", "dynamodb:BatchWriteItem",
          "dynamodb:DescribeTable", "dynamodb:ListTables",
        ]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${var.app_name}_${var.stage}_*"
      },
    ]
  })
}

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  description   = "${var.app_name}-backend-${var.stage}"
  role          = aws_iam_role.lambda.arn
  package_type  = var.package_type
  memory_size   = var.memory_size
  timeout       = var.timeout

  image_uri        = local.is_image ? var.image_uri : null
  filename         = local.is_image ? null : var.zip_path
  handler          = local.is_image ? null : var.handler
  runtime          = local.is_image ? null : var.runtime
  source_code_hash = local.is_image ? null : filebase64sha256(var.zip_path)

  environment {
    variables = var.environment_variables
  }

  tracing_config {
    mode = "PassThrough"
  }
}

resource "aws_api_gateway_rest_api" "this" {
  name = "${var.app_name}-backend-${var.stage}"

  endpoint_configuration {
    types = ["EDGE"]
  }

  binary_media_types = var.binary_media_types
}

resource "aws_api_gateway_method" "root" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_rest_api.this.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "root" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_rest_api.this.root_resource_id
  http_method             = aws_api_gateway_method.root.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.this.invoke_arn
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "proxy" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.this.invoke_arn
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.root.uri,
      aws_api_gateway_integration.proxy.uri,
      aws_api_gateway_resource.proxy.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.root,
    aws_api_gateway_integration.proxy,
  ]
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*"
}

# --- Optional custom domain ---

resource "aws_api_gateway_domain_name" "this" {
  count = var.domain_name != "" ? 1 : 0

  domain_name     = var.domain_name
  certificate_arn = var.certificate_arn

  endpoint_configuration {
    types = ["EDGE"]
  }
}

resource "aws_api_gateway_base_path_mapping" "this" {
  count = var.domain_name != "" ? 1 : 0

  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  domain_name = aws_api_gateway_domain_name.this[0].domain_name
}

resource "aws_route53_record" "this" {
  count = var.domain_name != "" && var.hosted_zone_id != "" ? 1 : 0

  zone_id         = var.hosted_zone_id
  name            = var.domain_name
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_api_gateway_domain_name.this[0].cloudfront_domain_name
    zone_id                = aws_api_gateway_domain_name.this[0].cloudfront_zone_id
    evaluate_target_health = false
  }
}
```

- [ ] **Step 4: Write module `outputs.tf`**

```hcl
output "endpoint_url" {
  description = "Default API Gateway invoke URL"
  value       = "https://${aws_api_gateway_rest_api.this.id}.execute-api.${var.aws_region}.amazonaws.com/${var.stage}"
}

output "function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.this.arn
}

output "rest_api_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.this.id
}

output "custom_domain_url" {
  description = "Custom domain URL (empty when no domain configured)"
  value       = var.domain_name != "" ? "https://${var.domain_name}" : ""
}
```

- [ ] **Step 5: Write stack `lambda`**

`versions.tf`, `backend.tf`, `providers.tf`: same content as Task 3 Step 5 stack files.

`variables.tf`:

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "lambda_function_name" {
  description = "Lambda function name with stage (lowercase)"
  type        = string
}

variable "chatbot_attachments_bucket_name" {
  description = "S3 bucket the function can read/write"
  type        = string
}

variable "package_type" {
  description = "Image or Zip"
  type        = string
  default     = "Image"
}

variable "ecr_image_tag" {
  description = "ECR image tag to deploy (Image type)"
  type        = string
  default     = "latest"
}

variable "zip_path" {
  description = "deployment.zip path (Zip type)"
  type        = string
  default     = ""
}

variable "handler" {
  description = "Lambda handler (Zip type)"
  type        = string
  default     = "main.handler"
}

variable "environment_variables" {
  description = "Lambda environment variables"
  type        = map(string)
  default     = {}
}

variable "api_domain_name" {
  description = "Custom API domain (e.g. app-qa.example.com); empty disables it"
  type        = string
  default     = ""
}

variable "certificate_arn" {
  description = "ACM certificate ARN for the custom domain"
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for the custom domain record"
  type        = string
  default     = ""
}
```

`main.tf`:

```hcl
module "lambda_api" {
  source = "../../modules/lambda-api"

  function_name                   = var.lambda_function_name
  app_name                        = var.app_name
  stage                           = var.stage
  aws_region                      = var.aws_region
  aws_account_id                  = var.aws_account_id
  package_type                    = var.package_type
  image_uri                       = var.package_type == "Image" ? "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.lambda_function_name}:${var.ecr_image_tag}" : ""
  zip_path                        = var.zip_path
  handler                         = var.handler
  environment_variables           = var.environment_variables
  chatbot_attachments_bucket_name = var.chatbot_attachments_bucket_name
  asm_secrets_arn                 = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.app_name}-${var.stage}-secrets*"
  asm_envs_arn                    = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.app_name}-${var.stage}-envs*"
  domain_name                     = var.api_domain_name
  certificate_arn                 = var.certificate_arn
  hosted_zone_id                  = var.hosted_zone_id
}
```

`outputs.tf`:

```hcl
output "endpoint_url" {
  description = "Default API Gateway invoke URL"
  value       = module.lambda_api.endpoint_url
}

output "function_arn" {
  description = "Lambda function ARN"
  value       = module.lambda_api.function_arn
}

output "custom_domain_url" {
  description = "Custom domain URL"
  value       = module.lambda_api.custom_domain_url
}
```

- [ ] **Step 6: Format, validate** — Task 3 Step 6 commands with `stacks/lambda`. Expected: valid.

- [ ] **Step 7: Commit**

```bash
git add scripts/aws_tf/modules/lambda-api scripts/aws_tf/stacks/lambda
git commit -m "Add: OpenTofu lambda-api module and lambda stack (SAM alternative) [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: Frontend package — `frontend-hosting` module, `frontend` stack, wrapper, deploy script

**Files:**
- Create: `FE_TF/modules/frontend-hosting/{versions.tf,variables.tf,main.tf,outputs.tf}`
- Create: `FE_TF/stacks/frontend/{versions.tf,backend.tf,providers.tf,variables.tf,main.tf,outputs.tf}`
- Create: `FE_TF/run-tf-deployment.sh`
- Create: `FE_TF/bootstrap-tf-state.sh`
- Create: `FE_TF/aws_tf_deploy_to_s3.sh`

**Interfaces:**
- Consumes: FE `.env` (`AWS_S3_BUCKET_NAME_FE`/`AWS_S3_BUCKET_NAME_${TYPE}`, `APP_FE_URL`/`APP_${TYPE}_URL`, `AWS_REGION`, `AWS_SSL_CERTIFICATE_ARN[_TYPE]`, `RUN_BUNDLER`, `BUILD_DIR`); build helpers `scripts/run_method_dependency_manager.sh`, `scripts/build_copy_images.sh`, `scripts/run_symlinks_handler.sh` (already in fe-scripts).
- Produces module `frontend-hosting`: inputs `bucket_name`, `app_name`, `stage`, `aliases (list(string))`, `acm_certificate_arn` (empty → lookup by alias domain; still empty → no alias/cert, CloudFront default cert), `hosted_zone_id` (optional Route53 alias); outputs `bucket_name`, `distribution_id`, `distribution_domain_name`, `website_url`.
- Produces `aws_tf_deploy_to_s3.sh STAGE [VARIABLE_TYPE]` — full pipeline: build → tofu apply → s3 sync → invalidation.

- [ ] **Step 1: Copy the wrapper + bootstrap**

`FE_TF/bootstrap-tf-state.sh`: identical content to Task 2 Step 1.

`FE_TF/run-tf-deployment.sh`: identical content to Task 2 Step 2 (incl. the Task 9 Step 6 wrapper additions), with two changes:
1. Header comment says "GenericSuite frontend stacks".
2. Replace the backend-specific export block (from `export TF_VAR_kms_key_alias=...` through `export TF_VAR_app_domain_name=...`) with:

```bash
# Frontend variable type (FE by default; e.g. WS for a second frontend)
VARIABLE_TYPE="$(echo "${VARIABLE_TYPE:-FE}" | tr '[:lower:]' '[:upper:]')"
FE_BUCKET_NAME="$(eval echo "\${AWS_S3_BUCKET_NAME_${VARIABLE_TYPE}:-}")"
# Replace [STAGE] token if present (parity with set_fe_cloudfront_domain.sh)
FE_BUCKET_NAME="$(echo "${FE_BUCKET_NAME}" | perl -pe "s/\[STAGE\]/${STAGE}/g")"
export TF_VAR_bucket_name="${FE_BUCKET_NAME}"

APP_URL_RAW="$(eval echo "\${APP_${VARIABLE_TYPE}_URL:-}")"
APP_URL_CLEANED="$(echo "${APP_URL_RAW}" | perl -pe 's|^https?://||i; s|[:/].*||; s|\s+||g')"
export TF_VAR_app_url="${APP_URL_CLEANED}"

TF_VAR_acm_certificate_arn="$(eval echo "\${AWS_SSL_CERTIFICATE_ARN_${VARIABLE_TYPE}:-}")"
if [ "${TF_VAR_acm_certificate_arn}" = "" ]; then
    TF_VAR_acm_certificate_arn="${AWS_SSL_CERTIFICATE_ARN:-}"
fi
export TF_VAR_acm_certificate_arn
```

- [ ] **Step 2: Write module `frontend-hosting`**

`versions.tf` — same content as Task 3 Step 1.

`variables.tf`:

```hcl
variable "bucket_name" {
  description = "Frontend S3 bucket name"
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

variable "aliases" {
  description = "CloudFront aliases (frontend FQDNs); empty list disables custom domain"
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN (us-east-1); empty tries lookup by first alias"
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route53 zone ID for alias records; empty skips DNS"
  type        = string
  default     = ""
}
```

`main.tf`:

```hcl
locals {
  use_aliases = length(var.aliases) > 0
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_acm_certificate" "lookup" {
  count    = local.use_aliases && var.acm_certificate_arn == "" ? 1 : 0
  provider = aws.us_east_1
  domain   = var.aliases[0]
  statuses = ["ISSUED"]
}

locals {
  certificate_arn = var.acm_certificate_arn != "" ? var.acm_certificate_arn : (
    local.use_aliases ? data.aws_acm_certificate.lookup[0].arn : ""
  )
}

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${var.bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  comment             = "CloudFront Distribution for '${var.bucket_name}'"
  enabled             = true
  default_root_object = "index.html"
  aliases             = var.aliases

  origin {
    origin_id                = aws_s3_bucket.this.bucket_regional_domain_name
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = aws_s3_bucket.this.bucket_regional_domain_name
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    min_ttl                = 0

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  # SPA routing: send S3 403/404 to index.html
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.certificate_arn == "" ? true : null
    acm_certificate_arn            = local.certificate_arn != "" ? local.certificate_arn : null
    ssl_support_method             = local.certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version       = local.certificate_arn != "" ? "TLSv1.2_2021" : null
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid    = "AllowCloudFrontOACAccess"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_route53_record" "alias" {
  for_each = var.hosted_zone_id != "" ? toset(var.aliases) : toset([])

  zone_id         = var.hosted_zone_id
  name            = each.value
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
```

`outputs.tf`:

```hcl
output "bucket_name" {
  description = "Frontend S3 bucket name"
  value       = aws_s3_bucket.this.bucket
}

output "distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_domain_name" {
  description = "CloudFront domain name (dxxxx.cloudfront.net)"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "website_url" {
  description = "Public URL"
  value       = length(var.aliases) > 0 ? "https://${var.aliases[0]}" : "https://${aws_cloudfront_distribution.this.domain_name}"
}
```

Note: the `provider "aws" { alias = "us_east_1" }` block cannot live in a shared module in strict style; if `tofu validate` rejects it, move that provider block plus the `data "aws_acm_certificate"` lookup into the stack (`stacks/frontend/providers.tf` + `main.tf`) and pass the resolved ARN into the module.

- [ ] **Step 3: Write stack `frontend`**

`versions.tf`, `backend.tf`: same content as Task 3 Step 5. `providers.tf`: same as Task 3 Step 5 plus the `us_east_1` aliased provider if moved out of the module (see note above).

`variables.tf`:

```hcl
variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "bucket_name" {
  description = "Frontend S3 bucket name (resolved by wrapper)"
  type        = string
}

variable "app_url" {
  description = "Frontend FQDN (cleaned, no protocol); empty disables custom domain"
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN; empty tries lookup by app_url"
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route53 zone ID; empty skips DNS records"
  type        = string
  default     = ""
}
```

`main.tf`:

```hcl
module "frontend_hosting" {
  source = "../../modules/frontend-hosting"

  bucket_name         = var.bucket_name
  app_name            = var.app_name
  stage               = var.stage
  aliases             = var.app_url != "" ? [var.app_url] : []
  acm_certificate_arn = var.acm_certificate_arn
  hosted_zone_id      = var.hosted_zone_id
}
```

`outputs.tf`:

```hcl
output "bucket_name" {
  description = "Frontend S3 bucket name"
  value       = module.frontend_hosting.bucket_name
}

output "distribution_id" {
  description = "CloudFront distribution ID"
  value       = module.frontend_hosting.distribution_id
}

output "distribution_domain_name" {
  description = "CloudFront domain name"
  value       = module.frontend_hosting.distribution_domain_name
}

output "website_url" {
  description = "Public URL"
  value       = module.frontend_hosting.website_url
}
```

- [ ] **Step 4: Write `FE_TF/aws_tf_deploy_to_s3.sh`**

```bash
#!/bin/bash
# scripts/aws_tf/aws_tf_deploy_to_s3.sh
# OpenTofu-based frontend deployment: infra via tofu, app build + S3 sync +
# CloudFront invalidation in bash. OpenTofu counterpart of
# scripts/aws_deploy_to_s3.sh (which remains untouched).
# 2026-07-16 | CR [GS-334]
#
# Usage:
#   bash node_modules/genericsuite-fe-scripts/scripts/aws_tf/aws_tf_deploy_to_s3.sh STAGE [VARIABLE_TYPE]
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

# 1) Infrastructure: S3 bucket + CloudFront (OAC) via OpenTofu
bash "${SCRIPTS_DIR}/run-tf-deployment.sh" apply "${STAGE}" frontend

# 2) Read infra outputs
cd "${SCRIPTS_DIR}/stacks/frontend"
BUCKET_NAME="$(tofu output -raw bucket_name)"
DIST_ID="$(tofu output -raw distribution_id)"
DOMAIN_NAME="$(tofu output -raw distribution_domain_name)"
cd "${REPO_BASEDIR}"
echo ""
echo "Bucket: ${BUCKET_NAME} | CloudFront: ${DIST_ID} (${DOMAIN_NAME})"

# 3) Build the app (same flow as aws_deploy_to_s3.sh)
if [ "${RUN_BUNDLER}" != "none" ] && [ "${UPDATE_BUILD}" = "1" ]; then
    sh "${FE_SCRIPTS_DIR}/run_method_dependency_manager.sh" install "${RUN_BUNDLER}"

    TSCONFIG_BASE_URL="$(perl -ne 'print $1 if /"baseUrl":\s*"([^"]*)"/' tsconfig.json)"
    if [ "${TSCONFIG_BASE_URL}" = "./src/lib" ]; then
        perl -i -pe 's|"baseUrl": "./src/lib"|"baseUrl": "./src"|g' tsconfig.json
    fi

    PREV_HOME_PAGE="$(perl -ne 'print $1 if /"homepage":\s*"([^"]*)"/' package.json)"
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

    # Restore package.json / tsconfig.json
    perl -i -pe "s|\"homepage\":.*|\"homepage\": \"${PREV_HOME_PAGE}\",|g" package.json
    perl -i -pe 's|"type1": "module"|"type": "module"|g' package.json
    if [ "${TSCONFIG_BASE_URL}" = "./src/lib" ]; then
        perl -i -pe 's|"baseUrl": "./src"|"baseUrl": "./src/lib"|g' tsconfig.json
    fi
fi

# 4) Sync to S3 (no ACLs: bucket is private, served through OAC)
echo "Deploying to AWS S3..."
aws s3 sync "${BUILD_DIR}" "s3://${BUCKET_NAME}" --delete --region "${AWS_REGION}"

# 5) Invalidate CloudFront cache
echo "Invalidating CloudFront cache..."
aws cloudfront create-invalidation --distribution-id "${DIST_ID}" --paths "/*"

echo ""
echo "Deployment complete: https://${DOMAIN_NAME}"
```

- [ ] **Step 5: Format, validate, syntax-check**

Run:
```bash
cd packages/genericsuite-fe-scripts/scripts/aws_tf
tofu fmt -recursive
(cd stacks/frontend && tofu init -backend=false && tofu validate)
bash -n run-tf-deployment.sh && bash -n bootstrap-tf-state.sh && bash -n aws_tf_deploy_to_s3.sh && echo OK
```
Expected: valid + `OK`. Apply the Step 2 note if the in-module aliased provider is rejected.

- [ ] **Step 6: Commit (in `packages/genericsuite-fe-scripts`)**

```bash
cd packages/genericsuite-fe-scripts
git add scripts/aws_tf
git commit -m "Add: OpenTofu frontend-hosting module, stack and deploy pipeline [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Full validation sweep (both packages)

**Files:** none (verification only; fix-ups allowed anywhere under `aws_tf/`)

- [ ] **Step 1: Sweep**

Run:
```bash
for dir in packages/genericsuite-be-scripts/scripts/aws_tf packages/genericsuite-fe-scripts/scripts/aws_tf; do
  tofu fmt -check -recursive "$dir"
  for stack in "$dir"/stacks/*/; do
    echo "== $stack"
    (cd "$stack" && tofu init -backend=false -input=false >/dev/null && tofu validate)
  done
done
```
Expected: `Success! The configuration is valid.` for all 9 stacks (8 backend + 1 frontend), no fmt diffs.

- [ ] **Step 2: Commit any fixes**

```bash
# in whichever submodule needed fixes
git add scripts/aws_tf && git commit -m "Change: OpenTofu validation fixes [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 13: Dev environment testing (real apply, fastapitemplate)

**Files:** none in repos (uses `packages/genericsuite-basecamp/mkdocs_root/code/fastapitemplate/server` and its existing `.env`)

**Interfaces:**
- Consumes: Task 2–7 stacks via `run-tf-deployment.sh`; fastapitemplate `.env` (real values). Resources are created in AWS account 071141316464, STAGE=dev, and **kept** afterwards.

- [ ] **Step 1: Wire the scripts into the test app**

Run (from superproject root):
```bash
cd packages/genericsuite-basecamp/mkdocs_root/code/fastapitemplate/server
BE_TF_ABS="$(cd ../../../../../genericsuite-be-scripts/scripts/aws_tf && pwd)"
echo "Using BE_TF at: ${BE_TF_ABS}"
```
Note: run the wrapper via its absolute path from this directory so it picks up this app's `.env` (`pwd` = REPO_BASEDIR).

- [ ] **Step 2: Bootstrap + apply `kms`** (skip gracefully if alias `genericsuite-key` already exists in the account — in that case `tofu plan` the stack, record the finding, and continue using the existing key)

Run:
```bash
CICD_MODE=1 bash "${BE_TF_ABS}/run-tf-deployment.sh" apply dev kms
```
Expected: state bucket created (`<app>-tf-state-071141316464`), apply succeeds or the pre-existing-alias finding is recorded.

- [ ] **Step 3: Apply `secrets`, `s3`, `dynamodb`, `ecr`**

Run:
```bash
CICD_MODE=1 bash "${BE_TF_ABS}/run-tf-deployment.sh" apply dev secrets
CICD_MODE=1 bash "${BE_TF_ABS}/run-tf-deployment.sh" apply dev s3
CICD_MODE=1 bash "${BE_TF_ABS}/run-tf-deployment.sh" apply dev dynamodb
CICD_MODE=1 bash "${BE_TF_ABS}/run-tf-deployment.sh" apply dev ecr
```
Expected: each ends `Apply complete!`. If a name collides with a live CF-managed resource (e.g. dev secrets already exist), record it, suffix cannot be changed (naming parity) — instead skip that stack's apply, keep its `plan` output as the test evidence, and note it in the final report.

- [ ] **Step 4: Verify created resources**

Run:
```bash
aws secretsmanager list-secrets --query "SecretList[?contains(Name, '-dev-')].Name" --output table
aws dynamodb list-tables --output table | grep "_dev_" || true
aws ecr describe-repositories --query "repositories[].repositoryName" --output table
aws s3api head-bucket --bucket "$(grep -E '^AWS_S3_CHATBOT_ATTACHMENTS_BUCKET_DEV=' .env | cut -d= -f2)" && echo "bucket OK"
```
Expected: the `{app}-dev-secrets`/`{app}-dev-envs` secrets, `{app}_dev_*` tables, the ECR repos, and the chatbot bucket all present.

- [ ] **Step 5: Verify state files in S3**

Run:
```bash
aws s3 ls "s3://$(echo "<app_name_lowercase>-tf-state-071141316464")/dev/" --recursive
```
Expected: `dev/kms.tfstate`, `dev/secrets.tfstate`, `dev/s3.tfstate`, `dev/dynamodb.tfstate`, `dev/ecr.tfstate`.

- [ ] **Step 6: Idempotency check**

Run: `CICD_MODE=1 bash "${BE_TF_ABS}/run-tf-deployment.sh" plan dev secrets`
Expected: `No changes.` (or only the secret_version if `.env` changed).

Resources are **kept** (per user decision). Do not run `destroy`.

---

### Task 14: Production plan-only checks

**Files:** none

- [ ] **Step 1: Plan every applicable backend stack against prod**

Run (from `fastapitemplate/server`, same wiring as Task 13):
```bash
bash "${BE_TF_ABS}/run-tf-deployment.sh" plan prod kms
bash "${BE_TF_ABS}/run-tf-deployment.sh" plan prod secrets
bash "${BE_TF_ABS}/run-tf-deployment.sh" plan prod s3
bash "${BE_TF_ABS}/run-tf-deployment.sh" plan prod dynamodb
bash "${BE_TF_ABS}/run-tf-deployment.sh" plan prod ecr
```
Expected: each produces a clean plan (resources to add), **no apply is executed**. Capture the plan summaries (e.g. `Plan: N to add, 0 to change, 0 to destroy`) for the final report.

- [ ] **Step 2: Confirm nothing was applied to prod**

Run: `aws s3 ls "s3://<app>-tf-state-071141316464/prod/" --recursive || echo "no prod applies (state objects may still exist from init) — verify no resources"`
Expected: plans leave no applied resources; report accordingly.

---

### Task 15: Basecamp documentation

**Files:**
- Create: `packages/genericsuite-basecamp/mkdocs_root/en/Deployment-Guide/opentofu.md`
- Modify: `packages/genericsuite-basecamp/mkdocs.yml` (nav)
- Modify: `packages/genericsuite-basecamp/CHANGELOG.md`

**Interfaces:**
- Consumes: everything built in Tasks 2–11 plus the gap list from the design spec §2.

- [ ] **Step 1: Write `opentofu.md`**

Single hands-on guide with these sections (write full prose, not stubs — source material is the design spec and the wrappers/modules built above):
1. **Overview** — why OpenTofu, coexistence with CloudFormation (CF stacks untouched), naming parity table.
2. **Prerequisites** — OpenTofu ≥ 1.10 (`brew install opentofu`), AWS CLI + credentials, `jq`, a consuming app `.env`.
3. **State management** — bucket `{app}-tf-state-{account}`, keys `{stage}/{stack}.tfstate`, native locking, `bootstrap-tf-state.sh`.
4. **Backend deployments** (`genericsuite-be-scripts/scripts/aws_tf`) — wrapper usage per stack (`kms`, `secrets`, `s3`, `dynamodb`, `ecr`, `domain`, `ec2`, `lambda`) with exact commands (`CICD_MODE=1 bash .../run-tf-deployment.sh apply qa secrets` etc.), required `.env` variables per stack, apply order (kms → secrets → s3 → dynamodb → ecr → domain → ec2/lambda).
5. **Frontend deployments** (`genericsuite-fe-scripts/scripts/aws_tf`) — `aws_tf_deploy_to_s3.sh STAGE`, what changed vs. the legacy script (OAC instead of OAI, private bucket, redirect-to-https, TLSv1.2_2021, SPA error responses).
6. **Migration notes** — running both paths side-by-side, importing existing resources with `tofu import` (example: `tofu import module.secrets.aws_secretsmanager_secret.encrypted <arn>`), differences table (CF vs TF behavior).
7. **Security improvements** — the design spec §3 list.
8. **Not yet covered** — RDS (`sql_db`), Chalice-native deploys, LocalStack path (design spec §2 gaps).

- [ ] **Step 2: Add nav entry in `mkdocs.yml`**

Locate the `nav:` section (near the existing `- 'Deployment': './Backend-Development/deployment.md'` entries, line ~29) and add a top-level entry after the Backend-Development group:

```yaml
  - 'Deployment Guide':
    - 'OpenTofu (IaC)': './Deployment-Guide/opentofu.md'
```

Also check the Spanish translations block (line ~114 has `'Deployment': 'Despliegue'`) and add `'Deployment Guide': 'Guía de Despliegue'` and `'OpenTofu (IaC)': 'OpenTofu (IaC)'` alongside.

- [ ] **Step 3: Add basecamp CHANGELOG entry**

Prepend under the unreleased/newest section of `packages/genericsuite-basecamp/CHANGELOG.md` following its existing format:

```markdown
### Add
- OpenTofu deployment guide covering genericsuite-fe-scripts and genericsuite-be-scripts IaC stacks [GS-334].
```

- [ ] **Step 4: Verify mkdocs build (if mkdocs available)**

Run: `cd packages/genericsuite-basecamp && (mkdocs build --strict 2>&1 | tail -5 || echo "mkdocs not installed - manual nav check done")`
Expected: build passes or graceful skip with the nav YAML visually verified.

- [ ] **Step 5: Commit (in `packages/genericsuite-basecamp`)**

```bash
git add mkdocs_root/en/Deployment-Guide/opentofu.md mkdocs.yml CHANGELOG.md
git commit -m "Add: OpenTofu deployment guide for FE/BE AWS deployments [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 16: CHANGELOG updates (fe-scripts + be-scripts)

**Files:**
- Modify: `packages/genericsuite-fe-scripts/CHANGELOG.md`
- Modify: `packages/genericsuite-be-scripts/CHANGELOG.md`

- [ ] **Step 1: Inspect each CHANGELOG's existing format** (`head -40`) and prepend a new unreleased section following it exactly.

be-scripts entry content:

```markdown
### Add
- OpenTofu (Terraform-compatible) IaC deployments in `scripts/aws_tf`: generic wrapper (`run-tf-deployment.sh`), S3 remote state with native locking (`bootstrap-tf-state.sh`), and modules/stacks for S3 buckets, DynamoDB tables, KMS, Secrets Manager, ECR, ACM/Route53 app domains, EC2+ALB, and Lambda+API Gateway — parallel to the existing CloudFormation scripts, which remain unchanged [GS-334].
- DynamoDB tfvars generator (`scripts/aws_tf/generate_dynamodb_tfvars.py`) reading the same GenericSuite JSON config as the CloudFormation generator [GS-334].
```

fe-scripts entry content:

```markdown
### Add
- OpenTofu (Terraform-compatible) IaC frontend deployment in `scripts/aws_tf`: `frontend-hosting` module (private S3 + CloudFront with Origin Access Control, redirect-to-https, TLSv1.2_2021, SPA error routing) and `aws_tf_deploy_to_s3.sh` full pipeline (tofu apply + build + S3 sync + CloudFront invalidation), with S3 remote state — parallel to the existing `aws_deploy_to_s3.sh`, which remains unchanged [GS-334].
```

- [ ] **Step 2: Commit both**

```bash
cd packages/genericsuite-be-scripts && git add CHANGELOG.md && git commit -m "Change: CHANGELOG entry for OpenTofu IaC deployments [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../genericsuite-fe-scripts && git add CHANGELOG.md && git commit -m "Change: CHANGELOG entry for OpenTofu IaC frontend deployment [GS-334]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Final report to user** — summarize: modules/stacks created, dev apply results (resources created/kept, any name-collision skips), prod plan summaries, doc location, CHANGELOG entries, and the follow-up gap list (RDS, Chalice, LocalStack).
