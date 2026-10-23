
# AWS Infrastructure with Terraform

This document describes the AWS infrastructure used for VoidWar offsite backups, including Terraform provisioning, S3 storage configuration, IAM access controls, and operational procedures.

VoidWar's production services run on an OVHcloud bare-metal Ubuntu server. AWS is used exclusively for offsite backup storage, not for hosting the Minecraft server or monitoring stack.

For the overall infrastructure design, see [Architecture](architecture.md).

## Overview

Terraform provisions two AWS components:

- **Amazon S3:** Private, encrypted, versioned storage for offsite backup archives.
- **AWS IAM:** A dedicated uploader identity with permissions limited to the designated backup bucket and prefix.

The infrastructure is deployed in AWS region `us-east-2` (US East, Ohio).

Terraform manages the AWS resources, while Bash scripts and the AWS CLI handle backup uploads separately.

## Repository Structure

```text
terraform/aws/
├── environments/
│   └── dev/
│       ├── .terraform.lock.hcl
│       ├── main.tf
│       └── versions.tf
└── modules/
    ├── s3-backups/
    │   ├── main.tf
    │   └── outputs.tf
    └── iam-backup-uploader/
        ├── main.tf
        └── variables.tf
```

The `dev` environment is the Terraform root module used for the deployed backup resources.

Its `main.tf` connects the two modules by passing the S3 bucket ARN to the IAM uploader module.

## Terraform Configuration

The root configuration specifies:

| Setting | Value |
|---|---|
| Terraform version | `>= 1.10.0` |
| AWS provider | `hashicorp/aws`, `~> 6.0` |
| AWS region | `us-east-2` |
| Environment directory | `terraform/aws/environments/dev` |

The `.terraform.lock.hcl` file records selected provider versions and checksums for reproducible initialization.

The configuration uses the default Terraform state backend; no remote state backend is defined.

Terraform state must be protected because it can contain infrastructure metadata and potentially sensitive values.

## S3 Backup Storage

The `s3-backups` module provisions an S3 bucket with the generated name prefix:

`voidwar-backups-`

A generated suffix provides a globally unique bucket name.

### Security Configuration

The module implements:

- S3 Block Public Access with all four settings enabled
- Server-side encryption using SSE-S3 (`AES256`)
- Bucket versioning
- Bucket-owner-enforced object ownership
- `force_destroy = false` to prevent Terraform from automatically deleting a nonempty bucket during destruction

The bucket is tagged with project, environment, purpose, and Terraform management metadata.

These controls help protect backup storage against accidental public exposure and unintended data loss.

### Lifecycle Policies

S3 lifecycle rules manage backup retention by object prefix.

| Backup category | S3 prefix | Current object expiration |
|---|---|---|
| Daily | `backups/daily/` | 8 days |
| Weekly | `backups/weekly/` | 35 days |
| Monthly | `backups/monthly/` | 190 days |

Noncurrent object versions expire after 7 days under each backup category's lifecycle rule.

A separate lifecycle rule aborts incomplete multipart uploads after 7 days.

These policies manage offsite retention independently of the server's local backup rotation.

S3 lifecycle expiration is asynchronous; objects are not guaranteed to disappear at the exact expiration time.

## IAM Backup Uploader

The `iam-backup-uploader` module provisions a dedicated IAM user:

`voidwar-backup-uploader`

It also creates and attaches a custom IAM policy named:

`voidwar-backup-upload`

### Allowed Permissions

The uploader can perform the following object-level operations under `backups/*`:

- `s3:PutObject`
- `s3:AbortMultipartUpload`
- `s3:ListMultipartUploadParts`

The policy also allows `s3:ListBucket` on the designated bucket when the requested prefix matches `backups/*`.

The bucket ARN is passed from the S3 module into the IAM module, keeping the permissions scoped to the provisioned bucket.

### Restricted Permissions

The uploader policy does not grant:

- `s3:GetObject`
- `s3:DeleteObject`
- `s3:DeleteBucket`
- General administrative access to S3 or other AWS services

This follows the principle of least privilege: the server can upload backups without receiving permissions to retrieve or delete stored archives.

The Terraform configuration creates the IAM user and policy but does not create or publish IAM access keys. Credential provisioning and storage are handled separately.

## Provisioning Workflow

Terraform administration is performed from an administrative workstation rather than the production server.

The workflow uses the AWS CLI, Terraform, and an AWS administrative profile.

### Authenticate to AWS

For the configured AWS IAM Identity Center profile:

```bash
aws sso login --profile voidwar-admin
```

Select the profile for Terraform commands:

```bash
export AWS_PROFILE=voidwar-admin
```

### Initialize Terraform

From the repository root:

```bash
cd terraform/aws/environments/dev
terraform init
```

Initialization installs the required provider and modules.

### Validate and Plan

```bash
terraform fmt -check -recursive
terraform validate
terraform plan
```

Review the plan before applying changes, especially modifications involving IAM permissions, bucket settings, or lifecycle policies.

### Apply Changes

```bash
terraform apply
```

Terraform creates or updates the resources defined in the configuration.

The S3 module exposes the bucket ARN as an output for use by the IAM module.

### Operational Precautions

- Review Terraform plans before applying changes.
- Protect Terraform state and AWS authentication credentials.
- Do not commit local state files or provider cache directories.
- Avoid manually changing Terraform-managed resources without reconciling configuration and state.
- Treat destructive changes to backup storage as high risk.

The public repository tracks infrastructure code and the provider lock file, not Terraform state or credentials.

## Backup Upload Integration

Backup archives are generated on the OVHcloud server by:

`scripts/backup_system.sh`

Offsite uploads are handled by:

`scripts/upload_s3_backups.sh`

The upload script uses the dedicated AWS uploader profile and stores archives under:

```text
backups/daily/
backups/weekly/
backups/monthly/
```

It supports uploading archives for a specified date or synchronizing retained local archives using `--sync-all`.

The script checks existing object names and sizes to avoid unnecessary uploads. This is not equivalent to cryptographic integrity verification.

Terraform does not schedule backup jobs or perform uploads itself.

For backup scheduling, retention, upload procedures, and recovery testing, see:

- [Backup Workflow](backup-workflow.md)
- [Restore Procedure](restore-procedure.md)

## Verification

Check Terraform formatting and configuration validity:

```bash
terraform fmt -check -recursive
terraform validate
```

Inspect the current plan:

```bash
terraform plan
```

A plan with no changes indicates that Terraform detects no configuration drift within the resources and attributes it manages.

S3 settings, IAM permissions, and uploaded backup objects can also be inspected through the AWS CLI or AWS Console using an appropriately authorized administrative identity.

Backup retrieval and archive integrity have been tested. A complete bare-metal disaster recovery exercise has not been performed.

## Summary

VoidWar uses Terraform to provision AWS S3 backup storage and a dedicated least-privilege IAM uploader.

The infrastructure provides private, encrypted, versioned offsite storage with automated lifecycle retention, while the production workload remains on the OVHcloud bare-metal server.

The separation between Terraform provisioning and Bash-based backup operations keeps infrastructure management reproducible and backup execution independently maintainable.
