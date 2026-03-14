#!/usr/bin/env bash
# Backup a remote WordPress site to a locally mounted Time Capsule (SMB share).
#
# Usage: backupSite.sh [config-file]
#   config-file defaults to backupSite.conf in the same directory as this script.
#
# Dependencies: cifs-utils (mount.cifs), curlftpfs, mysql-client (mysqldump), gzip, tar
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

# Validate required configuration variables
REQUIRED_VARS=(SITE FTP_SITE_USER FTP_SITE_PASSWD TIMECAPSULE_IP TIMECAPSULE_PASSWORD)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required variable '${var}' is not set in ${CONFIG_FILE}" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Derived paths (not meant to be overridden in the config)
# ---------------------------------------------------------------------------
readonly TIMECAPSULE_VOLUME="${TIMECAPSULE_VOLUME:-/Data}"
readonly TIMECAPSULE_PATH="//${TIMECAPSULE_IP}${TIMECAPSULE_VOLUME}"
readonly MOUNT_POINT="${MOUNT_POINT:-/mnt/time}"
readonly SITE_MOUNT="/mnt/${SITE}"
readonly WP_FOLDER="${SITE_MOUNT}/httpdocs"
readonly WP_CONFIG="${WP_FOLDER}/wp-config.php"
readonly BACKUP_FOLDER="${MOUNT_POINT}/${SITE}/backups"

# ---------------------------------------------------------------------------
# Cleanup: unmount everything on exit (success or error)
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?

    if mount | grep -q "${SITE_MOUNT}"; then
        echo "Unmounting remote FTP site..."
        fusermount -u "${SITE_MOUNT}" || true
    fi

    if mount | grep -q "${MOUNT_POINT}"; then
        echo "Unmounting Time Capsule..."
        umount "${MOUNT_POINT}" || true
    fi

    exit "${exit_code}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Mount Time Capsule (SMB/CIFS)
# ---------------------------------------------------------------------------
if ! mount | grep -q "${MOUNT_POINT}"; then
    echo "Mounting Time Capsule (${TIMECAPSULE_PATH} -> ${MOUNT_POINT})..."
    mkdir -p "${MOUNT_POINT}"
    mount.cifs "${TIMECAPSULE_PATH}" "${MOUNT_POINT}" \
        -o "pass=${TIMECAPSULE_PASSWORD},file_mode=0770,dir_mode=0770,sec=ntlm" \
        || { echo "ERROR: Could not mount Time Capsule" >&2; exit 1; }
fi

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
