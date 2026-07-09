# Minecraft Backup and Restart Workflow

This document explains the automated backup workflow used for the VoidWar Minecraft server.

The workflow is implemented by:

```text
scripts/backup_system.sh
```

The goal of this workflow is to create consistent server backups while minimizing the risk of world corruption, incomplete archives, or unmanaged downtime.

## Problem

The original backup process created a compressed archive while the Minecraft server was still running.

This caused the following warning during backup creation:

```text
tar: ./world: file changed as we read it
```

This warning indicated that Minecraft world files were being modified while `tar` was reading them. Because the server was actively writing world data during the archive process, the resulting backup could be inconsistent.

For a live Minecraft server, this is not ideal. A backup should capture the server files in a stable state.

## Solution

The backup workflow was redesigned to avoid creating archives while the Minecraft server is actively writing world data.

If the Minecraft server is running when the backup begins, the script stops the server before creating the archive, waits for the Java process to fully exit, creates the backup, and then restarts the server.

If the Minecraft server is already stopped when the backup begins, the script creates the archive without starting the server afterward.

The current process follows this sequence:

```text
Detect whether the Minecraft server is currently running
If running, broadcast maintenance warnings to players
If running, stop the Minecraft server gracefully
If running, wait for the Minecraft Java process to fully exit
Create a compressed backup archive
If the server was running originally, restart it
If the server was already stopped originally, leave it stopped
Remove old backups outside the retention window
```

This ensures that world files are not changing while the backup archive is being created.

## Player Notifications

When the Minecraft server is running, the script sends in-game maintenance warnings to all online players using Minecraft `tellraw` commands.

Warnings are broadcast before the restart so players have time to finish active tasks.

Example messages include:

```text
[Maintenance] The scheduled server restart and backup will begin in 5 minutes.
[Maintenance] The scheduled server restart and backup will begin in 1 minute. Please finish any active tasks.
[Maintenance] The scheduled server restart and backup will begin in 10 seconds.
```

`tellraw` is used instead of the `say` command because `say` automatically prefixes messages with `[Server]`. Using `tellraw` allows the maintenance messages to appear cleanly with the intended `[Maintenance]` prefix.

If the Minecraft server is already stopped when the backup begins, the script skips player notifications because there are no active players to notify.

## Graceful Shutdown

When the Minecraft server is running, the script sends the normal Minecraft console command:

```text
stop
```

This allows the Minecraft server to shut down cleanly instead of forcefully killing the Java process.

Before sending the stop command, the script captures the Minecraft server process ID. After sending `stop`, it waits until that exact process exits before continuing.

This avoids relying on a fixed delay such as `sleep 30`.

## Process-Aware Waiting

The script waits for the Minecraft process to fully exit before backing up the server directory.

This is done by repeatedly checking whether the captured process ID still exists.

The backup does not begin until the Minecraft Java process has stopped.

This prevents the archive from being created while world files are still changing.

## Backup Creation

After the Minecraft server is confirmed to be stopped, or if the server was already stopped before the script began, the script creates a compressed `.tar.gz` archive of the server directory.

Backups are written to:

```text
/home/blockboss/backups
```

Backup files use a date-based naming format:

```text
mcserver-YYYY-MM-DD.tar.gz
```

For example:

```text
mcserver-2026-07-07.tar.gz
```

Because the Minecraft server is not actively running during archive creation, the backup captures a more stable version of the server files.

## Preserving Original Server State

The backup script preserves the Minecraft server's original runtime state.

If the Minecraft server is running when the backup begins, the script broadcasts maintenance warnings, stops the server, waits for the process to exit, creates the backup archive, and then restarts the server.

If the Minecraft server is already stopped when the backup begins, the script skips the player warning and shutdown steps, creates the backup archive, and leaves the server stopped.

This prevents the scheduled backup job from unexpectedly starting the Minecraft server during maintenance, debugging, plugin work, or intentional downtime.

## Automatic Restart

The script only restarts the Minecraft server if the server was running when the backup process began.

When a restart is needed, the server is started through the existing `start.sh` script inside the Minecraft server directory.

The script runs the restart command inside the configured `tmux` session, allowing the Minecraft console to remain available after the backup process completes.

If the Minecraft server was already stopped before the backup began, the script does not start it after the archive is created.

## Retention Policy

The backup workflow includes automatic cleanup of older backup files.

The script removes backup archives outside the configured retention window so the backup directory does not grow indefinitely.

The current retention behavior keeps roughly the most recent seven daily backup files.

## Cancellation Handling

The backup script includes cancellation handling for manual interruptions.

If the backup is cancelled before the Minecraft server shuts down, the script sends an in-game cancellation message:

```text
[Maintenance] The scheduled server restart and backup was manually cancelled. VoidWar will remain online.
```

If the script is interrupted after the Minecraft server has already stopped, the cleanup logic attempts to restart the Minecraft server automatically.

This prevents the server from being accidentally left offline after an interrupted backup process.

If the Minecraft server was already stopped before the script began, cancellation does not start the server.

## Cron Scheduling

The backup script is scheduled through `cron`.

The cron job runs `scripts/backup_system.sh` automatically and appends output to a backup log file.

Logging backup output makes it easier to review whether the backup completed successfully, whether old backups were deleted, and whether any errors occurred.

Example cron behavior:

```text
Run the backup script on a scheduled interval
Append stdout and stderr to a backup log
Review the log for successful archive creation or errors
```

## Skills Demonstrated

This workflow demonstrates practical Linux administration and operational scripting concepts, including:

- Bash scripting
- Cron-based automation
- Minecraft server administration
- `tmux` session control
- Graceful application shutdown
- Process ID detection and monitoring
- Compressed archive creation with `tar`
- Backup retention cleanup
- Log-based troubleshooting
- Player-facing maintenance notifications
- Failure and cancellation handling
- Preserving original service state during automation

## Summary

The VoidWar backup workflow was improved from a simple live-file archive into a safer operational backup process.

The current system detects whether the Minecraft server is running, notifies players when needed, gracefully stops the server if necessary, waits for the server process to exit, creates a compressed backup, preserves the server's original runtime state, and removes old backups according to the retention policy.
