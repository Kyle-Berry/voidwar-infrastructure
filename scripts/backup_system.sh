#!/bin/bash

# backup_system.sh
# Creates and validates compressed Minecraft server backups.
#
# The script preserves the Minecraft server's original runtime state:
#   - If running, Minecraft is stopped gracefully and restarted afterward.
#   - If already stopped, Minecraft remains stopped afterward.
#
# Grandfather-Father-Son retention:
#   - Daily backups:  keep 7
#   - Weekly backups: keep 4
#   - Monthly backups: keep 6
#
# Weekly promotion occurs on Sunday.
# Monthly promotion occurs on the first day of the month.

set -Eeuo pipefail

BACKUP_ROOT="/home/blockboss/backups"
DAILY_DIR="${BACKUP_ROOT}/daily"
WEEKLY_DIR="${BACKUP_ROOT}/weekly"
MONTHLY_DIR="${BACKUP_ROOT}/monthly"

TARGET_DIR="/home/blockboss/minecraft_server"
TMUX_SESSION="minecraft"

DAILY_RETENTION=7
WEEKLY_RETENTION=4
MONTHLY_RETENTION=6

# These environment-variable overrides make testing possible without
# editing the production values in this script.
WARNING_5_MIN_DELAY="${WARNING_5_MIN_DELAY:-240}"
WARNING_1_MIN_DELAY="${WARNING_1_MIN_DELAY:-50}"
WARNING_10_SEC_DELAY="${WARNING_10_SEC_DELAY:-10}"

DAY_OF_WEEK="${DAY_OF_WEEK_OVERRIDE:-$(date +%u)}"
DAY_OF_MONTH="${DAY_OF_MONTH_OVERRIDE:-$(date +%d)}"

DATE_STAMP="$(date +%F)"
ARCHIVE_NAME="mcserver-${DATE_STAMP}.tar.gz"

DAILY_ARCHIVE_PATH="${DAILY_DIR}/${ARCHIVE_NAME}"
WEEKLY_ARCHIVE_PATH="${WEEKLY_DIR}/${ARCHIVE_NAME}"
MONTHLY_ARCHIVE_PATH="${MONTHLY_DIR}/${ARCHIVE_NAME}"

DAILY_TEMP_PATH="${DAILY_DIR}/.${ARCHIVE_NAME}.partial.$$"
WEEKLY_TEMP_PATH="${WEEKLY_DIR}/.${ARCHIVE_NAME}.partial.$$"
MONTHLY_TEMP_PATH="${MONTHLY_DIR}/.${ARCHIVE_NAME}.partial.$$"

LOCK_FILE="${BACKUP_ROOT}/backup_system.lock"

MINECRAFT_PID=""

server_was_running=false
stop_requested=false
server_restored=false
warning_broadcasted=false
cleanup_ran=false

find_minecraft_pid() {
    pgrep -f 'java.*-jar paper-.*\.jar.*nogui' || true
}

minecraft_is_running() {
    pgrep -f 'java.*-jar paper-.*\.jar.*nogui' >/dev/null 2>&1
}

send_mc_command() {
    local command="$1"
    tmux send-keys -t "$TMUX_SESSION" "$command" C-m
}

wait_for_pid_exit() {
    local pid="$1"

    while kill -0 "$pid" 2>/dev/null; do
        sleep 2
    done
}

restart_server() {
    echo "[*] Restarting Minecraft server..."

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux send-keys -t "$TMUX_SESSION" \
            "cd $TARGET_DIR && ./start.sh" C-m
    else
        tmux new-session -d -s "$TMUX_SESSION" \
            "cd $TARGET_DIR && ./start.sh"
    fi

    echo "[*] Waiting for Minecraft process to appear..."

    for ((i = 0; i < 30; i++)); do
        if minecraft_is_running; then
            server_restored=true
            echo "[+] Minecraft server process detected after restart."
            return 0
        fi

        sleep 1
    done

    echo "[-] Error: Minecraft process was not detected after restart." >&2
    return 1
}

cleanup() {
    if [ "$cleanup_ran" = true ]; then
        return
    fi

    cleanup_ran=true
    set +e

    rm -f -- \
        "$DAILY_TEMP_PATH" \
        "$WEEKLY_TEMP_PATH" \
        "$MONTHLY_TEMP_PATH"

    if [ "$server_was_running" = true ] &&
       [ "$server_restored" = false ]; then

        if [ "$stop_requested" = true ]; then
            echo "[*] Backup interrupted after Minecraft shutdown began."

            if kill -0 "$MINECRAFT_PID" 2>/dev/null; then
                echo "[*] Waiting for the original Minecraft process to exit..."
                wait_for_pid_exit "$MINECRAFT_PID"
            fi

            restart_server
        elif [ "$warning_broadcasted" = true ] &&
             tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            echo "[*] Backup cancelled before shutdown. Notifying players..."

            send_mc_command \
                'tellraw @a {"text":"[Maintenance] The scheduled server restart and backup was manually cancelled. VoidWar will remain online.","color":"green"}'
        fi
    fi
}

request_cancel() {
    exit 130
}

interruptible_sleep() {
    local seconds="$1"

    for ((i = 0; i < seconds; i++)); do
        sleep 1
    done
}

promote_archive() {
    local source_path="$1"
    local temporary_path="$2"
    local destination_path="$3"
    local tier_name="$4"

    echo "[*] Promoting archive to ${tier_name} tier..."

    cp -p -- "$source_path" "$temporary_path"
    mv -f -- "$temporary_path" "$destination_path"

    echo "[+] ${tier_name^} backup created: $(basename "$destination_path")"
}

prune_backup_tier() {
    local directory="$1"
    local retention_count="$2"
    local tier_name="$3"
    local -a backups=()

    mapfile -t backups < <(
        find "$directory" \
            -maxdepth 1 \
            -type f \
            -name "mcserver-*.tar.gz" \
            -printf '%T@ %p\n' |
        sort -nr |
        cut -d' ' -f2-
    )

    echo "[*] ${tier_name^} tier contains ${#backups[@]} backup(s)."
    echo "[*] ${tier_name^} retention limit: ${retention_count}."

    if [ "${#backups[@]}" -le "$retention_count" ]; then
        return
    fi

    for ((i = retention_count; i < ${#backups[@]}; i++)); do
        echo "[*] Removing expired ${tier_name} backup: ${backups[$i]}"
        rm -- "${backups[$i]}"
    done
}

trap cleanup EXIT
trap request_cancel INT TERM

echo "[*] Starting GFS backup routine..."

if [ ! -d "$TARGET_DIR" ]; then
    echo "[-] Error: target directory does not exist: $TARGET_DIR" >&2
    exit 1
fi

# mkdir -p creates missing directories and leaves existing directories intact.
mkdir -p "$DAILY_DIR" "$WEEKLY_DIR" "$MONTHLY_DIR"

# Prevent cron and manual executions from running concurrently.
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    echo "[-] Error: another backup process is already running." >&2
    exit 1
fi

MINECRAFT_PID="$(find_minecraft_pid | head -n 1)"

if [ -n "$MINECRAFT_PID" ]; then
    server_was_running=true
    echo "[*] Minecraft server PID detected: $MINECRAFT_PID"
else
    echo "[*] Minecraft server process was not found."
    echo "[*] Assuming Minecraft is already stopped."
    echo "[*] Minecraft will remain stopped after the backup."
fi

if [ "$server_was_running" = true ]; then
    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo "[-] Error: tmux session not found: $TMUX_SESSION" >&2
        exit 1
    fi

    echo "[*] Broadcasting backup warning to players..."

    send_mc_command \
        'tellraw @a {"text":"[Maintenance] The scheduled server restart and backup will begin in 5 minutes.","color":"gold"}'

    warning_broadcasted=true

    interruptible_sleep "$WARNING_5_MIN_DELAY"

    send_mc_command \
        'tellraw @a {"text":"[Maintenance] The scheduled server restart and backup will begin in 1 minute. Please finish any active tasks.","color":"gold"}'

    interruptible_sleep "$WARNING_1_MIN_DELAY"

    send_mc_command \
        'tellraw @a {"text":"[Maintenance] The scheduled server restart and backup will begin in 10 seconds.","color":"red"}'

    interruptible_sleep "$WARNING_10_SEC_DELAY"

    echo "[*] Sending stop command to Minecraft server..."
    send_mc_command "stop"
    stop_requested=true

    echo "[*] Waiting for Minecraft server process to stop..."
    wait_for_pid_exit "$MINECRAFT_PID"

    echo "[+] Minecraft server has stopped."
fi

# Write to a hidden temporary file first. A failed or interrupted archive
# will not appear as a normal completed backup.
rm -f -- "$DAILY_TEMP_PATH"

echo "[*] Creating temporary daily archive: $DAILY_TEMP_PATH"

tar -czf "$DAILY_TEMP_PATH" \
    -C "$TARGET_DIR" .

echo "[+] Archive creation completed."

# Restore the original running state as soon as archive creation finishes.
if [ "$server_was_running" = true ]; then
    restart_server
else
    echo "[*] Minecraft was already stopped. Leaving it stopped."
fi

echo "[*] Validating temporary backup archive..."

if ! tar -tzf "$DAILY_TEMP_PATH" >/dev/null; then
    echo "[-] Error: backup archive validation failed." >&2
    exit 1
fi

echo "[+] Backup archive validation passed."

# Replace the same day's daily archive only after the new archive validates.
mv -f -- "$DAILY_TEMP_PATH" "$DAILY_ARCHIVE_PATH"

echo "[+] Daily backup finalized: $DAILY_ARCHIVE_PATH"

# Sunday is 7 according to date +%u.
if [ "$DAY_OF_WEEK" = "7" ]; then
    promote_archive \
        "$DAILY_ARCHIVE_PATH" \
        "$WEEKLY_TEMP_PATH" \
        "$WEEKLY_ARCHIVE_PATH" \
        "weekly"
fi

# The first day of the month is 01 according to date +%d.
if [ "$DAY_OF_MONTH" = "01" ]; then
    promote_archive \
        "$DAILY_ARCHIVE_PATH" \
        "$MONTHLY_TEMP_PATH" \
        "$MONTHLY_ARCHIVE_PATH" \
        "monthly"
fi

prune_backup_tier "$DAILY_DIR" "$DAILY_RETENTION" "daily"
prune_backup_tier "$WEEKLY_DIR" "$WEEKLY_RETENTION" "weekly"
prune_backup_tier "$MONTHLY_DIR" "$MONTHLY_RETENTION" "monthly"

trap - EXIT INT TERM

echo "[+] GFS backup routine completed successfully."
echo "[+] Daily archive: $DAILY_ARCHIVE_PATH"

exit 0
