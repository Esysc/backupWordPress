#!/usr/bin/env bash
# Backup a remote WordPress site to a configurable backup destination.
#
# Supported backup destination types (BACKUP_TYPE):
#   local  — a directory already accessible on the filesystem (local disk,
#             pre-mounted NAS, cloud-fuse mount managed by the OS, etc.)
#   smb    — SMB/CIFS share (NAS, Time Capsule, Windows share …)
#   nfs    — NFS share
#   rclone — any rclone remote (S3, GCS, Backblaze B2, Dropbox, OneDrive …)
#
# Usage: backupSite.sh [config-file]
#   config-file defaults to backupSite.conf in the same directory as this script.
#
# Dependencies: curlftpfs, mysql-client (mysqldump), gzip, tar
#   + cifs-utils  when BACKUP_TYPE=smb
#   + nfs-common  when BACKUP_TYPE=nfs
#   + rclone      when BACKUP_TYPE=rclone
# Note: curlftpfs transmits FTP credentials in clear text.  Consider an SFTP/rsync
#       alternative for sensitive environments.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-"${SCRIPT_DIR}/backupSite.conf"}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}" >&2
    echo "       Copy backupSite.conf.example to backupSite.conf and fill in your values." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Validate common required configuration variables
REQUIRED_VARS=(SITE FTP_SITE_USER FTP_SITE_PASSWD BACKUP_TYPE BACKUP_MOUNT_POINT)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required variable '${var}' is not set in ${CONFIG_FILE}" >&2
        exit 1
    fi
done

# Validate type-specific required variables
case "${BACKUP_TYPE}" in
    local)
        ;;
    smb)
        for var in SMB_HOST SMB_SHARE SMB_PASSWORD; do
            if [[ -z "${!var:-}" ]]; then
                echo "ERROR: BACKUP_TYPE=smb requires '${var}' to be set in ${CONFIG_FILE}" >&2
                exit 1
            fi
        done
        ;;
    nfs)
        for var in NFS_HOST NFS_EXPORT; do
            if [[ -z "${!var:-}" ]]; then
                echo "ERROR: BACKUP_TYPE=nfs requires '${var}' to be set in ${CONFIG_FILE}" >&2
                exit 1
            fi
        done
        ;;
    rclone)
        if [[ -z "${RCLONE_REMOTE:-}" ]]; then
            echo "ERROR: BACKUP_TYPE=rclone requires 'RCLONE_REMOTE' to be set in ${CONFIG_FILE}" >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: Unknown BACKUP_TYPE '${BACKUP_TYPE}'. Must be one of: local, smb, nfs, rclone" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Derived paths (not meant to be overridden in the config)
# ---------------------------------------------------------------------------
readonly SITE_MOUNT="/mnt/${SITE}"
readonly WP_FOLDER="${SITE_MOUNT}/httpdocs"
readonly WP_CONFIG="${WP_FOLDER}/wp-config.php"
readonly BACKUP_FOLDER="${BACKUP_MOUNT_POINT}/${SITE}/backups"

# Track whether this script mounted the backup destination so cleanup knows
# whether to unmount it.
_BACKUP_MOUNTED=false

# ---------------------------------------------------------------------------
# Cleanup: unmount everything on exit (success or error)
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?

    if mount | grep -q "${SITE_MOUNT}"; then
        echo "Unmounting remote FTP site..."
        fusermount -u "${SITE_MOUNT}" || true
    fi

    if [[ "${_BACKUP_MOUNTED}" == "true" ]] && mount | grep -q "${BACKUP_MOUNT_POINT}"; then
        echo "Unmounting backup destination (${BACKUP_TYPE})..."
        if [[ "${BACKUP_TYPE}" == "rclone" ]]; then
            fusermount -u "${BACKUP_MOUNT_POINT}" || true
        else
            umount "${BACKUP_MOUNT_POINT}" || true
        fi
    fi

    exit "${exit_code}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Mount backup destination
# ---------------------------------------------------------------------------
mount_backup_destination() {
    mkdir -p "${BACKUP_MOUNT_POINT}"

    case "${BACKUP_TYPE}" in
        local)
            echo "Using local backup destination: ${BACKUP_MOUNT_POINT}"
            ;;
        smb)
            if ! mount | grep -q "${BACKUP_MOUNT_POINT}"; then
                local smb_path="//${SMB_HOST}${SMB_SHARE}"
                # SC2153: SMB_PASSWORD is a distinct config var, not a misspelling of DB_PASSWORD
                # shellcheck disable=SC2153
                local smb_opts="pass=${SMB_PASSWORD},file_mode=0770,dir_mode=0770,sec=ntlm"
                if [[ -n "${SMB_USER:-}" ]]; then
                    smb_opts="user=${SMB_USER},${smb_opts}"
                fi
                echo "Mounting SMB share (${smb_path} -> ${BACKUP_MOUNT_POINT})..."
                mount.cifs "${smb_path}" "${BACKUP_MOUNT_POINT}" -o "${smb_opts}" \
                    || { echo "ERROR: Could not mount SMB share" >&2; exit 1; }
                _BACKUP_MOUNTED=true
            fi
            ;;
        nfs)
            if ! mount | grep -q "${BACKUP_MOUNT_POINT}"; then
                local nfs_path="${NFS_HOST}:${NFS_EXPORT}"
                local nfs_opts="${NFS_MOUNT_OPTS:-defaults}"
                echo "Mounting NFS share (${nfs_path} -> ${BACKUP_MOUNT_POINT})..."
                mount -t nfs "${nfs_path}" "${BACKUP_MOUNT_POINT}" -o "${nfs_opts}" \
                    || { echo "ERROR: Could not mount NFS share" >&2; exit 1; }
                _BACKUP_MOUNTED=true
            fi
            ;;
        rclone)
            if ! mount | grep -q "${BACKUP_MOUNT_POINT}"; then
                local rclone_opts="${RCLONE_MOUNT_OPTS:---allow-other --vfs-cache-mode writes}"
                echo "Mounting rclone remote (${RCLONE_REMOTE} -> ${BACKUP_MOUNT_POINT})..."
                # SC2086: intentional word-splitting of rclone_opts flags
                # shellcheck disable=SC2086
                rclone mount ${rclone_opts} "${RCLONE_REMOTE}" "${BACKUP_MOUNT_POINT}" --daemon \
                    || { echo "ERROR: Could not start rclone mount" >&2; exit 1; }
                # Wait up to 30 s for the FUSE mount to become available
                local i=0
                until mount | grep -q "${BACKUP_MOUNT_POINT}"; do
                    if (( i >= 30 )); then
                        echo "ERROR: rclone mount did not become ready after 30 seconds" >&2
                        exit 1
                    fi
                    sleep 1
                    (( i++ )) || true
                done
                _BACKUP_MOUNTED=true
            fi
            ;;
    esac
}

mount_backup_destination

# ---------------------------------------------------------------------------
# Mount remote WordPress site via FTP
# ---------------------------------------------------------------------------
if ! mount | grep -q "${SITE_MOUNT}"; then
    echo "Mounting remote site (${SITE} -> ${SITE_MOUNT})..."
    mkdir -p "${SITE_MOUNT}"
    curlftpfs "${SITE}" "${SITE_MOUNT}/" \
        -o "user=${FTP_SITE_USER}:${FTP_SITE_PASSWD}" \
        -o auto_unmount \
        || { echo "ERROR: Could not mount remote site" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [[ ! -f "${WP_CONFIG}" ]]; then
    echo "ERROR: Cannot detect WordPress installation (missing ${WP_CONFIG})" >&2
    exit 1
fi

mkdir -p "${BACKUP_FOLDER}/db" "${BACKUP_FOLDER}/wp"

# ---------------------------------------------------------------------------
# Read database credentials from wp-config.php
# ---------------------------------------------------------------------------
DB_NAME=$(grep -E "^\s*define\(\s*'DB_NAME'" "${WP_CONFIG}"     | cut -d"'" -f4)
DB_USER=$(grep -E "^\s*define\(\s*'DB_USER'" "${WP_CONFIG}"     | cut -d"'" -f4)
DB_PASSWORD=$(grep -E "^\s*define\(\s*'DB_PASSWORD'" "${WP_CONFIG}" | cut -d"'" -f4)
readonly DB_NAME DB_USER DB_PASSWORD
readonly DB_HOST="${SITE}"

if [[ -z "${DB_NAME}" || -z "${DB_USER}" || -z "${DB_PASSWORD}" ]]; then
    echo "ERROR: Could not read database credentials from ${WP_CONFIG}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Database dump
# ---------------------------------------------------------------------------
TIMESTAMP="$(date +%Y%m%d_%H%M)"
DB_DUMP="${BACKUP_FOLDER}/db/${TIMESTAMP}_${DB_NAME}.gz"

echo "Dumping MySQL database '${DB_NAME}'..."
# MYSQL_PWD avoids passing the password on the command line (visible in `ps`)
MYSQL_PWD="${DB_PASSWORD}" mysqldump \
    --host="${DB_HOST}" \
    --user="${DB_USER}" \
    "${DB_NAME}" \
    | gzip > "${DB_DUMP}" \
    || { echo "ERROR: Database dump failed. Check credentials and permissions." >&2; exit 1; }
echo "Database dump saved to ${DB_DUMP}"

# ---------------------------------------------------------------------------
# Archive WordPress files
# ---------------------------------------------------------------------------
WP_ARCHIVE="${BACKUP_FOLDER}/wp/${TIMESTAMP}.tar.gz"

echo "Creating archive of site files..."
tar --create --gzip --verbose \
    --file="${WP_ARCHIVE}" \
    --exclude='*cache*' \
    "${WP_FOLDER}/" \
    || { echo "ERROR: Could not archive WordPress directory." >&2; exit 1; }
echo "Site archive saved to ${WP_ARCHIVE}"

echo "Backup complete."
