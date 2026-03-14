# backupWordPress

Script to back up a remote WordPress site to a configurable backup destination.

## Supported backup destinations

| `BACKUP_TYPE` | Description |
|---|---|
| `local` | Any directory already on the filesystem — local disk, external USB drive, a NAS share mounted by fstab/automount, a cloud storage provider mounted by the OS (Google Drive FS, Dropbox, etc.) |
| `smb` | SMB/CIFS share — NAS, Time Capsule, Windows share, etc. |
| `nfs` | NFS share |
| `rclone` | Any [rclone](https://rclone.org/) remote — S3, GCS, Backblaze B2, Dropbox, OneDrive, and many more |

## How it works

1. Mounts the backup destination (unless `BACKUP_TYPE=local`).
2. Mounts the remote WordPress site via `curlftpfs` (FTP).
3. Reads the database credentials from `wp-config.php`.
4. Dumps the MySQL database with `mysqldump` → compressed with `gzip`.
5. Creates a `tar.gz` archive of the site files (excluding cache directories).
6. Unmounts both the remote FTP site and the backup destination on exit (even on error).

Backups are written to `${BACKUP_MOUNT_POINT}/${SITE}/backups/{db,wp}/`.

## Dependencies

| Tool | Package (Debian/Ubuntu) | When required |
|------|------------------------|---------------|
| `curlftpfs` | `curlftpfs` | always |
| `mysqldump` | `default-mysql-client` | always |
| `mount.cifs` | `cifs-utils` | `BACKUP_TYPE=smb` |
| `mount` (nfs) | `nfs-common` | `BACKUP_TYPE=nfs` |
| `rclone` | [rclone.org](https://rclone.org/install/) | `BACKUP_TYPE=rclone` |

## Setup

```bash
# 1. Copy and edit the configuration file
cp backupSite.conf.example backupSite.conf
$EDITOR backupSite.conf   # set BACKUP_TYPE and fill in the matching variables

# 2. Run the backup (as root or a user with mount privileges)
sudo bash backupSite.sh
```

You can also pass the config path explicitly:

```bash
sudo bash backupSite.sh /path/to/custom.conf
```

### Example: back up to a Synology NAS via SMB

```bash
BACKUP_TYPE="smb"
BACKUP_MOUNT_POINT="/mnt/backup"
SMB_HOST="192.168.1.10"
SMB_SHARE="/backups"
SMB_USER="backup-user"
SMB_PASSWORD="secret"
```

### Example: back up to Amazon S3 via rclone

```bash
# First, configure the remote: rclone config
BACKUP_TYPE="rclone"
BACKUP_MOUNT_POINT="/mnt/backup"
RCLONE_REMOTE="s3:mybucket/wp-backups"
```

### Example: back up to a local external drive

```bash
BACKUP_TYPE="local"
BACKUP_MOUNT_POINT="/media/my-usb-drive/backups"
```

## ⚠️ Security notices

- `curlftpfs` transmits FTP credentials **in clear text**.  For sensitive environments consider replacing it with an SFTP/rsync-based approach.
- `backupSite.conf` contains credentials and is excluded from version control via `.gitignore`.  **Never commit it.**
