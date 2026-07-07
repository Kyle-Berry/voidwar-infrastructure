#!/bin/bash

# backup_system.sh
# Broadcasts a maintenance warning, stops the Minecraft server,
# waits until the server process exits, creates a compressed backup archive,
# restarts the server, and removes backups older than the retention window.

set -euo pipefail

BACKUP_DIR="/home/blockboss/backups"
TARGET_DIR="/home/blockboss/minecraft_server"
RETENTION_DAYS=7
TMUX_SESSION="minecraft"

DATE_STAMP="$(date +%F)"
ARCHIVE_NAME="mcserver-${DATE_STAMP}.tar.gz"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"

server_was_stopped=false

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

trap restart_server EXIT

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
send_mc_command "say [Maintenance] Server backup will begin in 5 minutes. The server will restart automatically."
sleep 240

send_mc_command "say [Maintenance] Server backup will begin in 1 minute. Please finish any active tasks."
sleep 50

send_mc_command "say [Maintenance] Server restarting for backup in 10 seconds."
sleep 10

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
trap - EXIT

echo "[*] Removing backups older than ${RETENTION_DAYS} days..."

# With daily backups, -mtime +6 keeps roughly the most recent 7 daily backups.
find "$BACKUP_DIR" \
    -type f \
    -name "mcserver-*.tar.gz" \
    -mtime +6 \
    -print \
    -delete

echo "[+] Backup routine completed successfully."
exit 0
