
# Minecraft Backup and Restart Workflow

This document explains the automated backup and recovery workflow used for the VoidWar Minecraft server.

The workflow is implemented by:

```text
scripts/backup_system.sh
scripts/upload_s3_backups.sh
```

The goal of this workflow is to create consistent, validated backups while minimizing the risk of world corruption, incomplete archives, unmanaged downtime, or accidental data loss.

The system combines local Grandfather-Father-Son (GFS) retention with automated offsite backup synchronization to Amazon S3.

## Design Considerations

The backup workflow was designed around several operational requirements:

- **Data consistency:** Minecraft continuously modifies world files while running. Creating archives during active writes can result in inconsistent backups.
- **Service availability:** Backups should minimize unnecessary downtime and preserve the Minecraft server's original running or stopped state.
- **Backup integrity:** Archives should be validated before being finalized and retained.
- **Recovery flexibility:** Multiple retention tiers should provide recovery points spanning days, weeks, and months.
- **Disaster recovery:** Backups should be stored offsite so that a hardware failure or loss of the dedicated server does not also destroy every recovery point.
- **Security:** The production server should have only the AWS permissions required to upload backups, not permissions to download or delete them.
- **Operational reliability:** Scheduled backups should prevent concurrent execution, handle interruptions, log failures, and retry missed offsite uploads.

An earlier version of the workflow created archives while the Minecraft server was running. This produced warnings such as:

```text
tar: ./world: file changed as we read it
```

The warning demonstrated the risk of archiving actively modified world files and motivated the implementation of a graceful shutdown and process-aware backup sequence.

The current design addresses these considerations through coordinated server shutdown and restart, archive validation, local GFS retention, and automated AWS S3 synchronization.

## Backup Workflow

The backup system coordinates Minecraft server operations, archive creation, validation, local retention, and offsite synchronization through two Bash scripts:

- `backup_system.sh` — Manages server shutdown and restart, backup creation, archive validation, and local GFS retention.
- `upload_s3_backups.sh` — Synchronizes retained local backup archives to Amazon S3.

The workflow preserves the Minecraft server's original runtime state. If the server is running, players receive maintenance warnings before a graceful shutdown, and the server is restarted after archive creation. If the server is already stopped, the backup proceeds without starting it.

The automated workflow follows this sequence:

```text
Detect whether the Minecraft server is running
If running, broadcast maintenance warnings
If running, gracefully stop the Minecraft server
Wait for the Java process to exit completely
Create a temporary compressed backup archive
Include the Minecraft server directory and external plugin data
Restore the original server runtime state
Validate the temporary archive
Finalize the validated daily backup
Promote validated backups into GFS retention tiers when applicable
Enforce local retention policies
Synchronize retained daily, weekly, and monthly archives to AWS S3
Log synchronization results and report failures
```

By separating archive creation from active Minecraft writes, the workflow protects backup consistency while minimizing service downtime. Archive validation, GFS retention, and offsite synchronization provide additional safeguards for data integrity and disaster recovery.

The following sections document each component of this workflow in greater detail.

## Player Notifications

When the Minecraft server is running, the script sends in-game maintenance warnings using Minecraft `tellraw` commands.

Warnings are broadcast before shutdown so players have time to safely finish active tasks.

Example messages include:

```text
[Maintenance] The scheduled server restart and backup will begin in 5 minutes.
[Maintenance] The scheduled server restart and backup will begin in 1 minute. Please finish any active tasks.
[Maintenance] The scheduled server restart and backup will begin in 10 seconds.
```

`tellraw` is used instead of the `say` command because `say` automatically prefixes messages with `[Server]`. Using `tellraw` allows maintenance messages to appear with the intended `[Maintenance]` prefix.

If the Minecraft server is already stopped when the backup begins, player notifications are skipped because there are no connected players.

## Graceful Shutdown

When the Minecraft server is running, the script issues the standard Minecraft console command:

```text
stop
```

This allows the server to save world data and shut down cleanly rather than terminating the Java process abruptly.

Before sending the stop command, the script records the Minecraft server process ID. After shutdown begins, it waits until that exact Java process has exited before continuing.

This avoids relying on arbitrary delays such as:

```text
sleep 30
```

and ensures that the original Minecraft process has exited before the archive is created.

## Process-Aware Waiting

The backup workflow continuously checks whether the captured Minecraft Java process is still running.

The backup archive is not created until the original process has completely exited.

This prevents the backup process from reading world files while the Minecraft server is actively modifying them.

## Backup Creation

After the Minecraft server has stopped, or if it was already stopped before the backup began, the script creates a compressed `.tar.gz` archive.

Backups are organized into separate retention tiers:

```text
/home/blockboss/backups/daily
/home/blockboss/backups/weekly
/home/blockboss/backups/monthly
```

Backup files use a date-based naming convention:

```text
mcserver-YYYY-MM-DD.tar.gz
```

For example:

```text
mcserver-2026-10-21.tar.gz
```

Because the Minecraft server is not actively writing files during archive creation, the resulting backup captures a consistent snapshot of the server files.

### External Plugin Directory

The Minecraft server's plugin data is stored outside the main server directory:

```text
/srv/plugins
```

The Minecraft server directory contains a symbolic link:

```text
/home/blockboss/minecraft_server/plugins -> /srv/plugins
```

Archiving only `/home/blockboss/minecraft_server` would preserve the symbolic link but not the actual plugin files.

The backup script therefore includes both the Minecraft server directory and the external plugin directory.

The relevant archive command is:

```bash
tar -czf "$DAILY_TEMP_PATH" \
    -C "$TARGET_DIR" . \
    -C / srv/plugins
```

This produces an archive containing:

```text
./                       Minecraft server files
./plugins                Symbolic link to /srv/plugins
srv/plugins/             Actual external plugin data
```

This ensures that the plugin files and their configuration data are included in the backup rather than relying on the symbolic link alone.

Backups created before this correction may not contain the actual external plugin files. Those older archives should not be assumed to support a complete plugin restoration.

For the corresponding recovery procedure, see [`restore-procedure.md`](restore-procedure.md).

## Backup Validation

The backup workflow validates every newly created archive before it becomes part of the retention system.

After the temporary archive has been created and the Minecraft server has been restored to its original runtime state, validation is performed using:

```bash
tar -tzf
```

Only archives that successfully pass validation are finalized as daily backups and become eligible for promotion into the weekly and monthly retention tiers.

This reduces the likelihood of retaining incomplete or corrupted backup files.

Archive validation checks whether `tar` can read the compressed archive successfully. It does not, by itself, prove that every application file is correct or that a complete Minecraft restoration will succeed.

## Preserving Original Server State

The backup script preserves the Minecraft server's original runtime state.

If the Minecraft server was running when the backup began, the script:

- broadcasts maintenance warnings
- gracefully shuts down the server
- creates a temporary backup archive
- restores the server to its original running state
- validates the temporary archive
- finalizes the validated backup

If the Minecraft server was already stopped before the backup began, the script:

- skips player notifications
- skips shutdown
- creates and validates the backup
- leaves the server stopped

This prevents scheduled backups from unintentionally starting the Minecraft server during maintenance, debugging, plugin development, or intentional downtime.

## Automatic Restart

The Minecraft server is restarted only if it was running before the backup began.

When a restart is required, the script launches the existing:

```text
start.sh
```

inside the configured `tmux` session.

After issuing the restart command, the script verifies that a new Minecraft Java process appears before continuing.

If the Minecraft server was already stopped before the backup began, the script does not start it afterward.

Offsite S3 synchronization occurs after the local backup and restart workflow, so uploading backup archives does not require additional Minecraft downtime.

## Grandfather-Father-Son (GFS) Retention Strategy

The backup workflow implements a Grandfather-Father-Son (GFS) retention strategy.

Backups are organized into three independent retention tiers:

```text
daily/
weekly/
monthly/
```

Current local retention policy:

```text
Daily:   7 backups
Weekly:  4 backups
Monthly: 6 backups
```

Every successful backup is first written into the daily tier.

If the backup occurs on Sunday, the validated daily archive is promoted into the weekly tier.

If the backup occurs on the first day of the month, the validated daily archive is also promoted into the monthly tier.

Each retention tier is managed independently.

Older backup archives exceeding the configured retention limits are automatically removed from local storage.

Using multiple retention tiers provides significantly longer recovery windows than retaining only recent daily backups while maintaining predictable storage utilization.

## AWS S3 Offsite Backups

To protect against loss of the dedicated OVHcloud server or its local storage, retained GFS archives are automatically synchronized to Amazon S3.

The S3 backup infrastructure is provisioned through Terraform.

The private bucket is located in the AWS `us-east-2` region:

```text
s3://voidwar-backups-9b494ddeae3a351192595c038d/
```

The bucket stores backup archives under separate prefixes:

```text
backups/
├── daily/
├── weekly/
└── monthly/
```

The S3 bucket is configured with:

- Block Public Access enabled
- Server-side encryption using SSE-S3 (AES-256)
- S3 bucket versioning enabled
- Bucket-owner-enforced object ownership
- Lifecycle rules for automated retention management

The Terraform configuration is stored under:

```text
terraform/aws/
```

The backup bucket and its security and lifecycle settings are managed through the `s3-backups` Terraform module.

### Automated S3 Synchronization

The offsite backup uploader is implemented by:

```text
scripts/upload_s3_backups.sh
```

On the production server, the backup workflow invokes the uploader after the local backup and retention operations complete.

The uploader synchronizes retained archives from:

```text
/home/blockboss/backups/daily
/home/blockboss/backups/weekly
/home/blockboss/backups/monthly
```

to the corresponding S3 prefixes.

The uploader supports:

```bash
./upload_s3_backups.sh --sync-all
```

This checks the locally retained archives across all three tiers and uploads objects that are missing or have a different size in S3.

For each archive, the uploader checks the corresponding S3 object before uploading it.

If an object already exists with the same key and file size, the upload is skipped.

If the object is missing or its size differs, the local archive is uploaded.

The size comparison avoids unnecessary repeat uploads, but it is not a cryptographic checksum comparison and does not independently prove that two same-sized archives have identical contents.

### Recovery From Interrupted Uploads

The uploader does not depend solely on the most recently created daily archive.

Each scheduled synchronization checks all locally retained GFS archives.

This allows the next successful run to retry backups that were not uploaded during an earlier failed or interrupted synchronization, provided those archives are still present locally.

The synchronization process does not delete S3 objects when their corresponding local files are removed.

Remote retention is managed independently through S3 lifecycle rules.

### Least-Privilege IAM Permissions

The production server uses a dedicated IAM identity:

```text
voidwar-backup-uploader
```

Its permissions are restricted to the backup bucket and the `backups/` object prefix.

The uploader is permitted to perform the S3 operations required for listing and uploading backup archives, including multipart upload operations.

It is not granted permission to:

- Download backup objects using `s3:GetObject`
- Delete backup objects using `s3:DeleteObject`
- Administer the S3 bucket
- Modify bucket lifecycle or security settings

This separates the production server's backup-upload responsibilities from administrative and recovery access.

The IAM configuration is managed through the Terraform module:

```text
terraform/aws/modules/iam-backup-uploader
```

The production AWS access credentials are stored outside the Git repository and are not included in the public project.

An authorized administrator or recovery identity is required to download S3 archives for restoration.

### S3 Lifecycle Retention

S3 retention is managed through lifecycle policies rather than through the local Bash GFS pruning logic.

The configured lifecycle rules are:

```text
Daily objects:             8 days
Weekly objects:           35 days
Monthly objects:         190 days
Noncurrent versions:       7 days
Incomplete multipart uploads: 7 days
```

Current objects are eligible for expiration based on their age in S3.

This is different from the local GFS policy, which retains a fixed maximum number of archives in each tier.

S3 versioning provides additional protection when an object is overwritten, while lifecycle rules limit how long previous versions are retained.

The S3 retention policy helps control long-term storage usage without requiring the production server to have object-deletion permissions.

## Backup Failure Handling

The local backup and offsite synchronization stages have separate responsibilities.

The local backup script handles:

- Minecraft shutdown and restart
- Archive creation and validation
- Local GFS promotion and retention

The S3 uploader handles:

- Checking existing offsite objects
- Uploading missing or changed archives
- Reporting upload failures

If an S3 synchronization fails after the local backup has completed, the validated local archive remains available.

The workflow reports the offsite synchronization failure rather than silently treating the entire process as successful.

Because retained archives are checked again on subsequent runs, a later successful synchronization can retry eligible missing uploads.

An S3 upload failure does not require the Minecraft server to remain stopped.

## Concurrency Protection

The backup workflow prevents multiple backup processes from executing simultaneously.

A lock file is used together with `flock` to ensure that only one instance of the main backup script can run at a time.

This prevents conflicts caused by accidental manual execution while a scheduled backup is already in progress.

## Cancellation Handling

The backup workflow includes cleanup logic for interrupted executions.

If the backup is cancelled before the Minecraft server shuts down, the script sends an in-game cancellation message:

```text
[Maintenance] The scheduled server restart and backup was manually cancelled. VoidWar will remain online.
```

If the backup is interrupted after the Minecraft server has already stopped, cleanup logic attempts to restore the server to its original running state.

If the Minecraft server was already stopped before the backup began, cancellation does not start the server.

These safeguards reduce the risk of accidentally leaving the Minecraft server offline after an interrupted backup operation.

## Cron Scheduling

The backup workflow is executed automatically through `cron`.

The scheduled job runs daily at midnight using the production server's local time:

```cron
0 0 * * * /home/blockboss/backup_system.sh >> /home/blockboss/backups/backup.log 2>&1
```

The main backup script invokes the S3 uploader as part of the same scheduled workflow.

Standard output and error output are appended to a dedicated backup log:

```text
/home/blockboss/backups/backup.log
```

Logging backup activity simplifies troubleshooting by providing a history of:

- backup execution
- archive validation
- retention cleanup
- restart operations
- S3 object checks and uploads
- offsite synchronization results
- error messages

## Backup Verification

The backup workflow can be checked using the production server's backup log.

Review recent output:

```bash
tail -100 /home/blockboss/backups/backup.log
```

List locally retained archives:

```bash
ls -lh /home/blockboss/backups/daily
ls -lh /home/blockboss/backups/weekly
ls -lh /home/blockboss/backups/monthly
```

The log should show successful archive creation and validation, the expected Minecraft restart behavior, and the outcome of offsite synchronization.

The automated backup workflow has been verified through successful unattended cron execution. Production logs confirm archive creation and validation, Minecraft server restart, local GFS retention processing, and successful offsite synchronization to Amazon S3.

### Offsite Recovery Validation

The offsite backup workflow has also been tested by downloading a corrected backup archive from S3 using a separate AWS administrator identity.

The downloaded archive was successfully validated using:

```bash
tar -tzf backup.tar.gz > /dev/null
```

Its contents were inspected to confirm the presence of Minecraft world data and the external plugin files.

These tests confirm that a backup archive could be uploaded, retrieved, and read successfully.

A complete isolated restore onto a replacement server, including Minecraft startup and player connectivity, has not yet been performed.

For the recovery runbook, see [`restore-procedure.md`](restore-procedure.md).

## Skills Demonstrated

This workflow demonstrates practical Linux systems administration and cloud infrastructure concepts including:

- Bash scripting
- Cron-based automation
- Linux process management
- Minecraft server administration
- `tmux` session management
- Graceful application shutdown
- Process ID detection and monitoring
- Compressed archive creation using `tar`
- Archive validation
- Backup of external application data and symbolic links
- Grandfather-Father-Son (GFS) backup strategy
- Automated local retention management
- AWS S3 offsite backup synchronization
- Terraform-managed cloud infrastructure
- Least-privilege AWS IAM permissions
- S3 lifecycle and versioning policies
- Concurrency control using `flock`
- Player-facing maintenance notifications
- Failure and cancellation handling
- Preserving original service state during automation
- Disaster recovery validation
- Operational documentation

## Summary

The VoidWar backup workflow evolved from a simple live-file archive into a documented local and offsite backup system.

The current implementation detects the Minecraft server's runtime state, gracefully notifies players when required, safely shuts down the server, waits for the original Java process to exit, creates and validates compressed backup archives containing both the Minecraft server and external plugin data, and preserves the server's original runtime state.

Validated archives are organized using a Grandfather-Father-Son (GFS) retention strategy and automatically synchronized to a private Amazon S3 bucket.

Terraform manages the cloud backup infrastructure, including S3 security settings, lifecycle retention, versioning, and least-privilege IAM permissions.

The result is an automated backup system with multiple recovery points, offsite disaster recovery copies, controlled storage retention, and documented validation and recovery procedures.
