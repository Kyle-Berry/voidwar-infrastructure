#!/bin/bash
# ==============================================================================
# VERSION 2.0: AUTOMATED REPLICATION ROUTINE WITH STORAGE RETENTION POLICY
# CONFIGURATION TARGET: SINGLE-THREADED ENGINE DIRECTLY TO NVMe CORE ARRAY
# LOGICAL UPGRADE: IMPLEMENTED FINOPS RESOURCE ROTATION TO PREVENT SATURATION
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

# Verify kernel execution return codes
if [ $? -eq 0 ]; then
    echo "[+] Structural storage backup successfully compiled: $ARCHIVE_NAME"
else
    echo "[-] CRITICAL FAULT: Storage archive compilation failure detected." >&2
    exit 1
fi

# FinOps Space Management: Automate retention policy to preserve storage margins
echo "[*] Auditing storage volume. Purging legacy archives exceeding 7-day threshold..."
find "$BACKUP_DIR" -type f -mtime +7 -name "mcserver-*.tar.gz" -delete

echo "[+] Infrastructure maintenance sequence fully executed."
exit 0
