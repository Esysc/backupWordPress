#!/usr/bin/env bash
### Backup script to backup a wordpress site hosted somewhere on Time capsule  ###
#
#
SITE="<yoursite dns name>"
FTP_SITE_PASSWD="<ftp password for site>"
FTP_SITE_USER="ftp user for site"

# Mount timecapsule
TIMECAPSULE=""
BACKUP=""

# Local time capsule 
TIMECAPSULE_IP="xxx.xxx.xxx.xxx"                         
TIMECAPSULE_VOLUME="/Data"       
TIMECAPSULE_PASSWORD="your_password"   
MOUNT_POINT=/mnt/time     
TIMECAPSULE_PATH="//$TIMECAPSULE_IP$TIMECAPSULE_VOLUME"


TIMECAPSULE=$(mount | grep /mnt/time)
if  [[  "$TIMECAPSULE" == "" ]]; then
        echo "Mounting time capsule...."
         mkdir -p $MOUNT_POINT
         echo "mount.cifs $TIMECAPSULE_PATH $MOUNT_POINT -o pass=$TIMECAPSULE_PASSWORD,file_mode=0777,dir_mode=0777,sec=ntlm" | /bin/bash
        if [ $? -ne 0 ]; then
                echo "ERROR: Couldn't mount time capsule"
                exit 1;
        fi
fi
# Mount $SITE
BACKUP=$(mount | grep /mnt/$SITE)
if [[  "$BACKUP" == "" ]]; then
        echo "mounting the remote site"
        FTP_PASSWD="$FTP_SITE_PASSWD"
        /usr/bin/curlftpfs  $SITE /mnt/yoursite/ -o user=$FTP_SITE_USER:$FTP_SITE_PASSWD -o auto_unmount
        if [ $? -ne 0 ]; then
                echo "ERROR: Couldn't mount remote site"
                exit 1;
        fi
fi
# Check the directory structure of your site
WP_FOLDER="/mnt/$SITE/httpdocs/"
BACKUP_FOLDER=/mnt/time/$SITE/backups/

if [ -z ${WP_FOLDER} ] || [ -z ${BACKUP_FOLDER} ]; then
        echo "USAGE: ${0} <PATH_WP_INSTALLATION> <BACKUP_FOLDER>"
        exit 1;
fi

mkdir -p ${BACKUP_FOLDER}/{db,wp}

# check if it looks like wordpress installation
WP_CONFIG="${WP_FOLDER}/wp-config.php"

if ! test -f ${WP_CONFIG}; then
        echo "ERROR: Cannot detect wordpress installation here... Exiting"
        exit 1;
fi
echo "Dumping mysql database...."
# get the database connection

DB_NAME=$(grep -E "^define\('DB_NAME'" ${WP_CONFIG} | cut -d"'" -f4)
DB_USER=$(grep -E "^define\('DB_USER'" ${WP_CONFIG} | cut -d"'" -f4)
DB_PASSWORD=$(grep -E "^define\('DB_PASSWORD'" ${WP_CONFIG} | cut -d"'" -f4)
DB_HOST="$SITE"
# doing the backup
mysqldump ${DB_NAME} -u${DB_USER} -p${DB_PASSWORD} -h${DB_HOST} | gzip > ${BACKUP_FOLDER}/db/$(date +%Y%m%d_%H%M)_${DB_NAME}.gz;

if [ $? -ne 0 ]; then
        echo "ERROR: Couldn't dump your database. Check your permissions"
        exit 1;
fi
echo "Creating archive of site files..."
tar zcfvv ${BACKUP_FOLDER}/wp/$(date +%Y%m%d_%H%M).tar.gz  ${WP_FOLDER}/  # >/dev/null 2>&1
# Umount the dirs...

if [ $? -ne 0 ]; then
        echo "ERROR: Couldn't backup your wordpress directory..."
        exit 1;
fi

