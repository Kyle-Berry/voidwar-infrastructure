#!/bin/bash
# ==============================================================================
# VERSION 1.0: AUTOMATED REPLICATION ROUTINE FOR MINECRAFT PRODUCTION CONTAINER
# CONFIGURATION TARGET: SINGLE-THREADED ENGINE DIRECTLY TO NVMe CORE ARRAY
# ==============================================================================

BACKUP_DIR="/home/blockboss/backups"
TARGET_DIR="/home/blockboss/minecraft_server"
DATE_STAMP=$(date +%F)
ARCHIVE_NAME="mcserver-${DATE_STAMP}.tar.gz"

echo "[*] Launching system backup sequence..."

# Enforce target boundary parameter check
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
fi

# Stream compression natively on-the-fly to optimize IOPS and bypass folder copy
echo "[*] Archiving $TARGET_DIR directly to $BACKUP_DIR/$ARCHIVE_NAME..."
tar -czf "$BACKUP_DIR/$ARCHIVE_NAME" -C "$TARGET_DIR" .

echo "[+] Execution completed successfully."
exit 0
