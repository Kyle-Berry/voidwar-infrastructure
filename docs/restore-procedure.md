
# Restore Procedure

This document explains how to restore the VoidWar Minecraft server from a compressed backup archive created by:

```text
scripts/backup_system.sh
```

The goal of this procedure is to restore the Minecraft server safely while avoiding accidental data loss, incomplete restores, or permission issues.

## Overview

The VoidWar backup strategy uses compressed `.tar.gz` archives containing the Minecraft server directory and, for backups created after the external-plugin backup fix, the separate `/srv/plugins` directory.

Backups are maintained in three locations:

- **Server-side GFS backups:** Automated daily, weekly, and monthly archives for fast local recovery.
- **AWS S3:** Automated offsite copies of retained GFS archives, providing recovery options if the OVHcloud server or its storage becomes unavailable.
- **Local workstation:** Additional archives downloaded manually from time to time.

The AWS S3 bucket, lifecycle policies, and restricted uploader permissions are managed through Terraform. Terraform provisions the backup infrastructure; it does not restore Minecraft data by itself.

## Backup Sources

### Server-Side Backups

Server-side backups are organized into Grandfather-Father-Son (GFS) retention tiers under:

```text
/home/blockboss/backups/daily
/home/blockboss/backups/weekly
/home/blockboss/backups/monthly
```

Backup files use a date-based naming format:

```text
mcserver-YYYY-MM-DD.tar.gz
```

Example:

```text
mcserver-2026-10-21.tar.gz
```

The local retention policy keeps up to 7 daily, 4 weekly, and 6 monthly archives.

### AWS S3 Offsite Backups

Completed local GFS backups are synchronized to the private S3 bucket:

```text
s3://voidwar-backups-9b494ddeae3a351192595c038d/
```

Objects are organized under:

```text
backups/daily/
backups/weekly/
backups/monthly/
```

The scheduled backup workflow calls `scripts/upload_s3_backups.sh` after the local backup completes. The uploader also supports `--sync-all` to retry missing uploads from the locally retained archives.

S3 versioning is enabled. Lifecycle rules expire current daily objects after 8 days, weekly objects after 35 days, and monthly objects after 190 days, measured from their S3 upload dates. Noncurrent object versions expire after 7 days under the configured lifecycle policy.

The production uploader's IAM credentials permit uploading and listing backup objects but **do not permit downloading or deleting backups**. Recovery requires a separate authorized AWS identity with `s3:GetObject` access, such as the administrator's AWS SSO profile on the workstation.

### Local Workstation Backups

Backup archives are also downloaded manually to a local workstation outside the server environment.

These copies provide an additional recovery option, but they are not continuously synchronized and may be older than the latest S3 backup.

The exact workstation backup path varies and is intentionally not documented in this public repository.


## Restore Safety Notes

Before restoring a backup, confirm the following:

- The Minecraft server is stopped.
- The selected backup archive exists and is the intended recovery point.
- The archive passes `tar` validation before any live files are replaced.
- The archive contains the actual external plugin files, not just the `plugins` symbolic link, if a complete plugin restore is required.
- Pre-restore safety copies of **both** the Minecraft directory and `/srv/plugins` are preserved when those directories already exist.

After restoring the backup, confirm the following:

- File ownership and permissions are correct.
- The server starts successfully and its logs are reviewed.

Do not restore over an actively running Minecraft server. Restoring while the server is running can cause file conflicts, world corruption, or inconsistent server state.

**Important:** The steps below assume a trusted VoidWar archive. Inspect the archive contents before extraction. Do not extract the entire archive directly into `/` or directly over the production Minecraft directory.

## Stop the Minecraft Server

Attach to the Minecraft `tmux` session:

```bash
tmux attach -t minecraft
```

In the Minecraft console, run:

```text
stop
```

Wait for the Minecraft server process to fully exit.

Detach from `tmux` if needed:

```text
Ctrl + B
D
```

Verify that the Minecraft Java process is no longer running:

```bash
pgrep -af "java.*minecraft_server|java.*paper|java.*spigot|java.*server.jar"
```

If the command returns no active Minecraft Java process, the server is stopped.

## Select a Backup Archive

List available server-side backups:

```bash
find /home/blockboss/backups \
    -type f \
    -name "mcserver-*.tar.gz" \
    -printf "%TY-%Tm-%Td %TH:%TM %p\n" | sort
```

Choose the backup archive that should be restored.

Example:

```text
/home/blockboss/backups/daily/mcserver-2026-10-21.tar.gz
```

Prefer a backup created after the external plugin directory was included in the archives. Older archives may contain only the `plugins` symlink, not the plugin files themselves.

## Restore From AWS S3

If server-side backups are missing or unusable, retrieve an offsite archive using an authorized AWS administrator or recovery identity.

The following commands are intended for the **administrator's WSL workstation**, where the AWS CLI and `voidwar-admin` SSO profile are configured. Do not copy administrator credentials to the production Minecraft server just to perform a restore.

Authenticate if the SSO session has expired:

```bash
aws sso login --profile voidwar-admin
```

List available daily backups:

```bash
aws s3 ls \
    s3://voidwar-backups-9b494ddeae3a351192595c038d/backups/daily/ \
    --region us-east-2 \
    --profile voidwar-admin
```

Weekly and monthly backups can be listed by replacing `daily` with `weekly` or `monthly`.

Download the chosen recovery point to the workstation (replace the example date with the selected date):

```bash
aws s3 cp \
    s3://voidwar-backups-9b494ddeae3a351192595c038d/backups/daily/mcserver-2026-10-21.tar.gz \
    ./mcserver-2026-10-21.tar.gz \
    --region us-east-2 \
    --profile voidwar-admin
```

Validate the downloaded archive:

```bash
tar -tzf ./mcserver-2026-10-21.tar.gz > /dev/null
```

Then transfer it to the Linux recovery host using WinSCP or an appropriately configured `scp` connection. For example:

```bash
scp -P <ssh_port> mcserver-2026-10-21.tar.gz \
    blockboss@server-address:/home/blockboss/backups/daily/
```

Use the actual SSH port, server address, and authentication key for the recovery host. The example uses placeholders intentionally.

S3 bucket versioning may preserve earlier versions of an overwritten object for a limited time. Retrieving a specific previous version requires an authorized identity and the appropriate version ID; the restricted production uploader cannot perform that operation.

## Restore From a Local Workstation Backup

If the server-side backup is missing or unusable, a manually downloaded workstation archive can also be copied back to the server.

Example using `scp` from the local workstation:

```bash
scp mcserver-YYYY-MM-DD.tar.gz blockboss@server-address:/home/blockboss/backups/daily/
```

If the production SSH port is non-standard, specify the port with `-P`:

```bash
scp -P <ssh_port> mcserver-YYYY-MM-DD.tar.gz blockboss@server-address:/home/blockboss/backups/daily/
```

This repository intentionally uses placeholders for server address and SSH port. WinSCP is an alternative for transferring the archive.

After copying the archive, verify that it exists on the server:

```bash
ls -lh /home/blockboss/backups/daily/mcserver-YYYY-MM-DD.tar.gz
```

## Inspect and Stage the Backup Archive

The current archive layout includes two separate paths:

```text
./                         Minecraft server directory contents
./plugins                  Symbolic link pointing to /srv/plugins
srv/plugins/               Actual external plugin files and directories
```

**Do not** extract the whole archive into `/home/blockboss/minecraft_server`. That would put the archived `srv/plugins` tree in the wrong place. Do not extract the whole archive into `/`, either, because that could overwrite production files.

On the recovery Linux server, set `ARCHIVE` to the actual selected archive path:

```bash
ARCHIVE="/home/blockboss/backups/daily/mcserver-2026-10-21.tar.gz"
```

Validate the archive and confirm the external plugin directory is included:

```bash
tar -tzf "$ARCHIVE" > /dev/null
tar -tzf "$ARCHIVE" | grep -E '^srv/plugins/' | sed -n '1,10p'
```

If the second command produces no plugin paths, **stop and select a newer complete backup** or plan a separate recovery of `/srv/plugins`. An archive containing only the `./plugins` symlink is not a complete plugin backup.

Create a temporary extraction directory under the administrator's home directory:

```bash
STAGING="$(mktemp -d /home/blockboss/voidwar-restore.XXXXXXXX)"
tar -xzf "$ARCHIVE" -C "$STAGING"
```

Confirm the expected files and paths exist before proceeding:

```bash
test -f "$STAGING/start.sh"
test -L "$STAGING/plugins"
test -d "$STAGING/srv/plugins"
readlink "$STAGING/plugins"
```

The `readlink` output should be `/srv/plugins`. If the checks fail, do not replace the live directories.

## Create a Pre-Restore Safety Copy

Before replacing the current Minecraft server directory, preserve the existing state. The external plugin directory must be protected separately because it is outside the Minecraft server directory.

Run the following **only after confirming Minecraft is stopped and the staged archive is valid**:

```bash
STAMP="$(date +%F-%H%M%S)"

if [ -e /home/blockboss/minecraft_server ]; then
    mv /home/blockboss/minecraft_server \
        "/home/blockboss/minecraft_server.pre-restore-${STAMP}"
fi

if [ -e /srv/plugins ]; then
    sudo mv /srv/plugins "/srv/plugins.pre-restore-${STAMP}"
fi
```

These commands preserve the existing directories instead of deleting them. Record the timestamp if a rollback might be needed.

On a replacement server with no existing Minecraft or plugin directories, there may be nothing to preserve.

## Recreate the Minecraft Server Directory

Move the extracted external plugin directory to its intended location, then remove the now-empty staging `srv` directory:

```bash
sudo mv "$STAGING/srv/plugins" /srv/plugins
rmdir "$STAGING/srv"
```

Move the staged Minecraft server files into place:

```bash
mv "$STAGING" /home/blockboss/minecraft_server
```

The restored `plugins` symlink should point from the Minecraft server directory to the separate `/srv/plugins` directory.

## Fix Ownership and Permissions

After restoration, verify ownership and permissions.

The production deployment uses the `blockboss` account and the `minecraft_admins` group for controlled plugin access. On a replacement host, recreate the required account and group before applying ownership.

```bash
sudo chown -R blockboss:blockboss /home/blockboss/minecraft_server
sudo chown -R blockboss:minecraft_admins /srv/plugins
sudo chmod 770 /srv/plugins
```

Ensure the server start script is executable:

```bash
chmod +x /home/blockboss/minecraft_server/start.sh
```

Verify the plugin link and destination:

```bash
ls -ld /home/blockboss/minecraft_server/plugins /srv/plugins
readlink -f /home/blockboss/minecraft_server/plugins
```

The resolved path should be `/srv/plugins`. Also confirm that the Minecraft process account has the required access to the plugin files.

## Start the Minecraft Server

Start or reattach to the Minecraft `tmux` session.

If the `minecraft` tmux session already exists:

```bash
tmux attach -t minecraft
```

Then run:

```bash
cd /home/blockboss/minecraft_server && ./start.sh
```

If the `minecraft` tmux session does not exist, create a new one:

```bash
tmux new-session -d -s minecraft "cd /home/blockboss/minecraft_server && ./start.sh"
```

Attach to the session if needed:

```bash
tmux attach -t minecraft
```

## Validate the Restore

After starting the server, validate that the restore succeeded.

Check that the Minecraft process is running:

```bash
pgrep -af "java.*minecraft_server|java.*paper|java.*spigot|java.*server.jar"
```

Check the server console through `tmux`:

```bash
tmux attach -t minecraft
```

Review recent logs:

```bash
tail -100 /home/blockboss/minecraft_server/logs/latest.log
```

Confirm the following:

- Server starts without major errors.
- World loads successfully.
- Plugins load as expected from `/srv/plugins`.
- The `plugins` symbolic link resolves correctly.
- Players can connect.
- Restored files match the intended backup date.
- No unexpected permission errors appear in logs.

Do not delete the pre-restore safety copies until the recovered environment has been verified.

## Rollback Option

If the restore fails or the wrong backup was selected, stop the Minecraft server again and restore the pre-restore safety copies.

Stop the server from the Minecraft console:

```text
stop
```

Move the failed restored directories aside, using a new timestamp:

```bash
ROLLBACK_STAMP="$(date +%F-%H%M%S)"
mv /home/blockboss/minecraft_server \
    "/home/blockboss/minecraft_server.failed-restore-${ROLLBACK_STAMP}"
sudo mv /srv/plugins "/srv/plugins.failed-restore-${ROLLBACK_STAMP}"
```

Restore **both** pre-restore directories, replacing the example timestamp with the value recorded earlier:

```bash
mv /home/blockboss/minecraft_server.pre-restore-YYYY-MM-DD-HHMMSS \
    /home/blockboss/minecraft_server

sudo mv /srv/plugins.pre-restore-YYYY-MM-DD-HHMMSS /srv/plugins
```

Verify the restored plugin symlink and permissions, then restart the server:

```bash
tmux new-session -d -s minecraft "cd /home/blockboss/minecraft_server && ./start.sh"
```

If no pre-restore copy existed (for example, during recovery onto a fresh host), rollback requires choosing another backup or rebuilding the affected directories rather than using the commands above.

## Disaster Recovery Notes

If the OVHcloud server is lost completely, an AWS S3 or manually downloaded workstation backup can be used to rebuild the Minecraft server on a fresh Linux host.

A full recovery would require:

- A replacement Linux server provisioned with sufficient storage and memory.
- SSH access, Linux users/groups, and required firewall rules configured.
- Java and `tmux` installed.
- An authorized AWS identity used to retrieve the selected S3 archive, or an existing workstation backup transferred to the new host.
- The archive validated and staged before restoration.
- Both the Minecraft server files and the external `/srv/plugins` directory restored.
- The `minecraft_server/plugins` symbolic link and ownership/permissions verified.
- The Minecraft server started and its world, plugins, logs, and connectivity checked.
- Supporting web and monitoring services restored separately if needed; these are not fully recreated by the Minecraft archive alone.

The S3 bucket is private, with versioning, encryption at rest, and lifecycle-based retention. The restricted upload identity cannot retrieve backup objects, so recovery access must be planned separately.

### Recovery Validation Status

The following operations have been tested:

- Local compressed backup creation and `tar` archive validation.
- Inclusion of actual `/srv/plugins` contents in the corrected backup format.
- Uploading retained GFS archives to S3 and checking uploaded objects.
- Downloading a corrected S3 archive to the administrator's WSL workstation and successfully validating its archive contents.
- Unattended nightly backup and S3 synchronization, confirmed by the October 21, 2026 backup log.

**Not yet tested:** A complete isolated restore onto a replacement Linux server followed by a successful Minecraft startup and player connectivity check. The procedure above is a recovery runbook, not a claim that full disaster recovery has already been proven end to end.

## Skills Demonstrated

This restore process demonstrates practical Linux administration and disaster recovery concepts, including:

- Backup archive restoration.
- Server-side, cloud offsite, and workstation backup strategy.
- AWS S3 recovery access and least-privilege IAM separation.
- Safe staged restore workflow.
- Pre-restore safety copies of multiple data directories.
- `tar` archive inspection and extraction.
- Symbolic-link-aware recovery of external application data.
- Ownership and permission correction.
- `tmux` process management.
- Minecraft server recovery and log-based validation.
- Rollback planning.
- Disaster recovery testing and documentation.

## Summary

The VoidWar restore process is designed to recover the Minecraft server from compressed backup archives while minimizing the risk of additional data loss.

Automated local GFS backups provide fast restore points, AWS S3 provides offsite recovery copies, and occasional manually downloaded workstation archives offer another recovery source.

The procedure stops the server, selects and validates a backup, stages its contents, preserves the current Minecraft and plugin directories, restores both data locations, fixes permissions, restarts the server, validates the result, and retains rollback options. A full isolated disaster recovery test remains a future validation task.
