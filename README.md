# backupWordPress

Script to back up a remote WordPress site to a locally mounted Time Capsule (SMB share).

## How it works

1. Mounts a Time Capsule SMB share via `mount.cifs`.
2. Mounts the remote WordPress site via `curlftpfs` (FTP).
3. Reads the database credentials from `wp-config.php`.
4. Dumps the MySQL database with `mysqldump` → compressed with `gzip`.
5. Creates a `tar.gz` archive of the site files (excluding cache directories).
6. Unmounts both the remote FTP site and the Time Capsule on exit (even on error).

## Dependencies

| Tool | Package (Debian/Ubuntu) |
|------|------------------------|
| `mount.cifs` | `cifs-utils` |
| `curlftpfs` | `curlftpfs` |
| `mysqldump` | `default-mysql-client` |

## Setup

```bash
# 1. Copy and edit the configuration file
cp backupSite.conf.example backupSite.conf
$EDITOR backupSite.conf   # fill in SITE, FTP credentials, Time Capsule details

# 2. Run the backup (as root or a user with mount privileges)
sudo bash backupSite.sh
```

You can also pass the config path explicitly:

```bash
sudo bash backupSite.sh /path/to/custom.conf
```

## ⚠️ Security notice

`curlftpfs` transmits FTP credentials **in clear text**.  For sensitive
environments consider replacing it with an SFTP/rsync-based approach.

`backupSite.conf` contains credentials and is excluded from version control
via `.gitignore`.  **Never commit it.**
