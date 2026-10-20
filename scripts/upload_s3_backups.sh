#!/usr/bin/env bash

# upload_s3_backups.sh
# Uploads completed VoidWar Minecraft backups to AWS S3.
#
# Runs separately from the local backup routine.
# Uses the restricted voidwar-backup-uploader IAM profile.

set -Eeuo pipefail

# Local backup directories
BACKUP_ROOT="/home/blockboss/backups"

DAILY_DIR="${BACKUP_ROOT}/daily"
WEEKLY_DIR="${BACKUP_ROOT}/weekly"
MONTHLY_DIR="${BACKUP_ROOT}/monthly"

# AWS configuration
S3_BUCKET="voidwar-backups-9b494ddeae3a351192595c038d"
AWS_REGION="us-east-2"
AWS_PROFILE_NAME="voidwar-backup-uploader"

# S3 destination prefixes
S3_DAILY_PREFIX="backups/daily"
S3_WEEKLY_PREFIX="backups/weekly"
S3_MONTHLY_PREFIX="backups/monthly"

# Upload one completed backup archive to S3.
upload_backup() {
    local source_file="$1"
    local s3_prefix="$2"
    local filename
    local destination

    filename="$(basename "$source_file")"
    destination="s3://${S3_BUCKET}/${s3_prefix}/${filename}"

    if [ ! -f "$source_file" ]; then
        echo "[-] Error: backup file not found: $source_file" >&2
        return 1
    fi

    # Check whether an object with the same name and size already exists.
    local local_size
    local remote_size
    local object_key="${s3_prefix}/${filename}"

    local_size="$(stat -c '%s' "$source_file")"

    if remote_size="$(aws s3api list-objects-v2 \
        --bucket "$S3_BUCKET" \
        --prefix "$object_key" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE_NAME" \
        --query "Contents[?Key=='${object_key}'].Size | [0]" \
        --output text)"; then

        if [[ "$remote_size" == "$local_size" ]]; then
            echo "[=] Backup already exists in S3 with matching size. Skipping: ${filename}"
            return 0
        fi
    else
        echo "[-] Error: Unable to check existing S3 backups." >&2
        return 1
    fi

    echo "[*] Uploading ${filename} to ${destination}..."

    if aws s3 cp "$source_file" "$destination" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE_NAME" \
        --only-show-errors; then

        echo "[+] S3 upload completed: ${destination}"
    else
        echo "[-] Error: S3 upload failed: ${destination}" >&2
        return 1
    fi
}

# Upload the completed backups for a given date.
upload_gfs_backups() {
    local backup_date="$1"
    local archive_name="mcserver-${backup_date}.tar.gz"
    local failed=0

    local daily_archive="${DAILY_DIR}/${archive_name}"
    local weekly_archive="${WEEKLY_DIR}/${archive_name}"
    local monthly_archive="${MONTHLY_DIR}/${archive_name}"

    echo "[*] Starting S3 backup uploads for ${backup_date}..."

    # Every successful backup run must produce a daily archive.
    if [ ! -f "$daily_archive" ]; then
        echo "[-] Error: daily backup missing: $daily_archive" >&2
        return 1
    fi

    upload_backup "$daily_archive" "$S3_DAILY_PREFIX" || failed=1

    # Weekly archives exist only on promotion days.
    if [ -f "$weekly_archive" ]; then
        upload_backup "$weekly_archive" "$S3_WEEKLY_PREFIX" || failed=1
    fi

    # Monthly archives exist only on promotion days.
    if [ -f "$monthly_archive" ]; then
        upload_backup "$monthly_archive" "$S3_MONTHLY_PREFIX" || failed=1
    fi

    if [ "$failed" -ne 0 ]; then
        echo "[-] One or more S3 uploads failed." >&2
        return 1
    fi

    echo "[+] All selected S3 backups uploaded successfully."
}

# Synchronize all currently retained local GFS backups to S3.
sync_all_backups() {
    local failed=0
    local source_file

    echo "[*] Synchronizing retained GFS backups to S3..."

    for source_file in "$DAILY_DIR"/mcserver-*.tar.gz; do
        [ -f "$source_file" ] || continue
        upload_backup "$source_file" "$S3_DAILY_PREFIX" || failed=1
    done

    for source_file in "$WEEKLY_DIR"/mcserver-*.tar.gz; do
        [ -f "$source_file" ] || continue
        upload_backup "$source_file" "$S3_WEEKLY_PREFIX" || failed=1
    done

    for source_file in "$MONTHLY_DIR"/mcserver-*.tar.gz; do
        [ -f "$source_file" ] || continue
        upload_backup "$source_file" "$S3_MONTHLY_PREFIX" || failed=1
    done

    if [ "$failed" -ne 0 ]; then
        echo "[-] One or more S3 backup synchronization operations failed." >&2
        return 1
    fi

    echo "[+] GFS backup synchronization completed successfully."
}

# Main entry point
main() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: $0 YYYY-MM-DD | --sync-all" >&2
        return 2
    fi

    # Synchronize every locally retained GFS archive.
    if [ "$1" = "--sync-all" ]; then
        sync_all_backups
        return $?
    fi

    local backup_date="$1"

    # Validate the backup date.
    if [[ ! "$backup_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
       [ "$(date -d "$backup_date" +%F 2>/dev/null)" != "$backup_date" ]; then
        echo "[-] Error: invalid backup date: $backup_date" >&2
        return 2
    fi

    upload_gfs_backups "$backup_date"
}

main "$@"
