# Minecraft Backup and Restart Workflow

This document explains the automated backup workflow used for the VoidWar Minecraft server.

The goal of this workflow is to create consistent server backups while minimizing the risk of world corruption, incomplete archives, or unmanaged downtime.

## Problem

The original backup process created a compressed archive while the Minecraft server was still running.

This caused the following warning during backup creation:

    tar: ./world: file changed as we read it

This warning indicated that Minecraft world files were being modified while `tar` was reading them. Because the server was actively writing world data during the archive process, the resulting backup could be inconsistent.

For a live Minecraft server, this is not ideal. A backup should capture the server files in a stable state.

## Solution

The backup workflow was redesigned to stop the Minecraft server before creating the archive.

The current process follows this sequence:

    Broadcast maintenance warnings
    Stop the Minecraft server gracefully
    Wait for the Minecraft Java process to fully exit
    Create a compressed backup archive
    Restart the Minecraft server
    Remove old backups outside the retention window

This ensures that the world files are no longer changing while the backup archive is being created.

## Player Notifications

Before the backup begins, the script sends in-game maintenance warnings to all online players using Minecraft `tellraw` commands.

Warnings are broadcast before the restart so players have time to finish active tasks.

Example messages include:

    [Maintenance] The scheduled server restart and backup will begin in 5 minutes.
    [Maintenance] The scheduled server restart and backup will begin in 1 minute. Please finish any active tasks.
    [Maintenance] The scheduled server restart and backup will begin in 10 seconds.

`tellraw` is used instead of the `say` command because `say` automatically prefixes messages with `[Server]`. Using `tellraw` allows the maintenance messages to appear cleanly with the intended `[Maintenance]` prefix.

## Graceful Shutdown

The script sends the normal Minecraft console command:

    stop

This allows the Minecraft server to shut down cleanly instead of forcefully killing the Java process.

Before sending the stop command, the script captures the Minecraft server process ID. After sending `stop`, it waits until that exact process exits before continuing.

This avoids relying on a fixed delay such as `sleep 30`.

## Process-Aware Waiting

The script waits for the Minecraft process to fully exit before backing up the server directory.

This is done by repeatedly checking whether the captured process ID still exists.

The backup does not begin until the Minecraft Java process has stopped.

This prevents the archive from being created while world files are still changing.

## Backup Creation

After the Minecraft server has stopped, the script creates a compressed `.tar.gz` archive of the server directory.

Backups are written to:

    /home/blockboss/backups

Backup files use a date-based naming format:

    mcserver-YYYY-MM-DD.tar.gz

For example:

    mcserver-2026-07-07.tar.gz

Because the Minecraft server is stopped before the archive is created, the backup captures a more stable version of the server files.

## Automatic Restart

After the backup archive is created successfully, the script restarts the Minecraft server.

The server is started through the existing `start.sh` script inside the Minecraft server directory.

The script runs the restart command inside the configured `tmux` session, allowing the Minecraft console to remain available after the backup process completes.

## Preserving Original Server State

The backup script preserves the Minecraft server's original state.

If the Minecraft server is running when the backup begins, the script broadcasts maintenance warnings, stops the server, waits for the process to exit, creates the backup archive, and then restarts the server.

If the Minecraft server is already stopped when the backup begins, the script skips the player warning and shutdown steps, creates the backup archive, and leaves the server stopped.

This prevents the scheduled backup job from unexpectedly starting the Minecraft server during maintenance, debugging, plugin work, or intentional downtime.

## Retention Policy

The backup workflow includes automatic cleanup of older backup files.

The script removes backup archives outside the configured retention window so the backup directory does not grow indefinitely.

The current retention behavior keeps roughly the most recent seven daily backup files.

## Cancellation Handling

The backup script includes cancellation handling for manual interruptions.

If the backup is cancelled before the Minecraft server shuts down, the script sends an in-game cancellation message:

    [Maintenance] The scheduled server restart and backup was manually cancelled. VoidWar will remain online.

If the script is interrupted after the Minecraft server has already stopped, the cleanup logic attempts to restart the Minecraft server automatically.

This prevents the server from being accidentally left offline after an interrupted backup process.

## Cron Scheduling

The backup script is scheduled through `cron`.

The cron job runs the backup script automatically and appends output to a backup log file.

Logging backup output makes it easier to review whether the backup completed successfully, whether old backups were deleted, and whether any errors occurred.

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

## Summary

The VoidWar backup workflow was improved from a simple live-file archive into a safer operational backup process.

The current system gracefully notifies players, stops the Minecraft server, waits for the server process to exit, creates a compressed backup, restarts the Minecraft server, and removes old backups according to the retention policy.
