#!/bin/bash

# backup_system.sh
# Broadcasts maintenance warnings, stops the Minecraft server,
# waits until the server process exits, creates a compressed backup archive,
# restarts the Minecraft server, and removes backups older than the retention window.

set -euo pipefail

BACKUP_DIR="/home/blockboss/backups"
TARGET_DIR="/home/blockboss/minecraft_server"
RETENTION_DAYS=7
TMUX_SESSION="minecraft"

DATE_STAMP="$(date +%F)"
ARCHIVE_NAME="mcserver-${DATE_STAMP}.tar.gz"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"

server_was_stopped=false
backup_completed=false
warning_broadcasted=false
cleanup_ran=false
cancel_requested=false

find_minecraft_pid() {
    pgrep -f "java.*minecraft_server|java.*paper|java.*spigot|java.*server.jar" || true
}

send_mc_command() {
    local command="$1"
    tmux send-keys -t "$TMUX_SESSION" "$command" C-m
}

restart_server() {
    if [ "$server_was_stopped" = true ]; then
        echo "[*] Restarting Minecraft server..."

        if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            tmux send-keys -t "$TMUX_SESSION" "cd $TARGET_DIR && ./start.sh" C-m
        else
            tmux new-session -d -s "$TMUX_SESSION" "cd $TARGET_DIR && ./start.sh"
        fi

        server_was_stopped=false
    fi
}

cleanup() {
    if [ "$cleanup_ran" = true ]; then
        return
    fi

    cleanup_ran=true

    if [ "$backup_completed" = true ]; then
        return
    fi

    if [ "$server_was_stopped" = true ]; then
        echo "[*] Backup interrupted after Minecraft server stopped. Restarting Minecraft server..."
        restart_server
    elif [ "$warning_broadcasted" = true ] && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo "[*] Backup cancelled before shutdown. Notifying players..."
        send_mc_command 'tellraw @a {"text":"[Maintenance] The scheduled server restart and backup was manually cancelled. VoidWar will remain online.","color":"green"}'
    fi
}

request_cancel() {
    cancel_requested=true
    cleanup
    exit 130
}

interruptible_sleep() {
    local seconds="$1"

    for ((i = 0; i < seconds; i++)); do
        if [ "$cancel_requested" = true ]; then
            exit 130
        fi

        sleep 1
    done
}

trap cleanup EXIT
trap request_cancel INT TERM

echo "[*] Starting backup routine..."

if [ ! -d "$TARGET_DIR" ]; then
    echo "[-] Error: target directory does not exist: $TARGET_DIR" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[-] Error: tmux session not found: $TMUX_SESSION" >&2
    exit 1
fi

MINECRAFT_PID="$(find_minecraft_pid | head -n 1)"

if [ -z "$MINECRAFT_PID" ]; then
    echo "[-] Error: Minecraft server process was not found." >&2
    exit 1
fi

echo "[*] Minecraft server PID detected: $MINECRAFT_PID"

echo "[*] Broadcasting backup warning to players..."
send_mc_command 'tellraw @a {"text":"[Maintenance] The scheduled server restart and backup will begin in 5 minutes.","color":"gold"}'
warning_broadcasted=true

interruptible_sleep 240

send_mc_command 'tellraw @a {"text":"[Maintenance] The scheduled server restart and backup will begin in 1 minute. Please finish any active tasks.","color":"gold"}'

interruptible_sleep 50

send_mc_command 'tellraw @a {"text":"[Maintenance] The scheduled server restart and backup will begin in 10 seconds.","color":"red"}'

interruptible_sleep 10

echo "[*] Sending stop command to Minecraft server..."
send_mc_command "stop"
server_was_stopped=true

echo "[*] Waiting for Minecraft server process to stop..."

while kill -0 "$MINECRAFT_PID" 2>/dev/null; do
    sleep 2
done

echo "[+] Minecraft server has stopped."

echo "[*] Creating archive: $ARCHIVE_PATH"
tar -czf "$ARCHIVE_PATH" -C "$TARGET_DIR" .

echo "[+] Backup created successfully: $ARCHIVE_NAME"

restart_server

echo "[*] Removing backups older than ${RETENTION_DAYS} days..."

# With daily backups, -mtime +6 keeps roughly the most recent 7 daily backups.
find "$BACKUP_DIR" \
    -type f \
    -name "mcserver-*.tar.gz" \
    -mtime +6 \
    -print \
    -delete

backup_completed=true
trap - EXIT INT TERM

echo "[+] Backup routine completed successfully."
exit 0
