#!/bin/sh
# (c) 2018 vbettag - msql backup for Kopano  script inspired by synology-wiki.de mods mysql backup section
# admins only plus set sudo for DSM 6 as root login is no longer possible
LOGIN=`whoami`
if [ $LOGIN != "root" ] && ! (grep administrators /etc/group | grep -q $LOGIN)
then 
	echo "admins only"
	exit 1
fi
MAJOR_VERSION=`grep majorversion /etc.defaults/VERSION | grep -o [0-9]`
if [ $MAJOR_VERSION -gt 5 ] && [ $LOGIN != "root" ]
then
	echo "Switching in sudo mode. You may need to provide root password at initial call.."
	SUDO="sudo"
else
	SUDO=""
fi

if [ -e /var/packages/Kopano4s/etc/package.cfg ] && [ "$1" != "legacy" ] && [ "$2" != "legacy" ] && [ "$3" != "legacy" ]
then
	. /var/packages/Kopano4s/etc/package.cfg
	MYSQL="/var/packages/MariaDB10/target/usr/local/mariadb10/bin/mysql"
	MYSQLDUMP="/var/packages/MariaDB10/target/usr/local/mariadb10/bin/mysqldump"
	LEGACY=0
else
	# legacy zarafa package
	MYSQL="/var/packages/MariaDB/target/usr/bin/mysql"
	MYSQLDUMP="/var/packages/MariaDB/target/usr/bin/mysqldump"
	if [ -e /etc/zarafa4h/server.cfg ] || [ -e /etc/zarafa/server.cfg ]
	then
		if [ -e /etc/zarafa4h/server.cfg ]
		then
			ETC=/etc/zarafa4h
		else
			ETC=/etc/zarafa
		fi
		LEGACY=1
		if [ -e /var/packages/Kopano4s/etc/package.cfg ]
		then
			. /var/packages/Kopano4s/etc/package.cfg
		else
			NOTIFYTARGET=$SYNOPKG_USERNAME
			if [ "_$NOTIFYTARGET" == "_" ] ; then NOTIFYTARGET=$SYNO_WEBAPI_USERNAME ; fi
			if [ "_$NOTIFYTARGET" == "_" ] ; then NOTIFYTARGET=$USERNAME ; fi
			if [ "_$NOTIFYTARGET" == "_" ] ; then NOTIFYTARGET=$USER ; fi
			if [ "_$NOTIFYTARGET" == "_" ] ||  [ "$NOTIFYTARGET" == "root" ] ; then NOTIFYTARGET="@administrators" ; fi
			KEEP_BACKUPS=4
			K_SHARE="/volume1/kopano"
		fi
		DB_NAME=`grep ^mysql_database $ETC/server.cfg | cut -f2 -d'=' | grep -o '[^\t ].*'`
		DB_USER=`grep ^mysql_user $ETC/server.cfg | cut -f2 -d'=' | grep -o '[^\t ].*'`
		DB_PASS=`grep ^mysql_password $ETC/server.cfg | cut -f2 -d'=' | grep -o '[^\t ].*'`
		# create directories if not exist (better have shared folder backup created first)
		test -e $K_SHARE || mkdir -p $K_SHARE 
		test -e $K_SHARE/backup || mkdir -p $K_SHARE/backup
	else
		echo "Kopano or legacy Zarafa not present to backup (no /etc/kopano or /etc/zarafa(4h) with server.cfg) exit now"
		exit 1
	fi
fi
if [ "_$NOTIFY" != "_ON" ]
then 
	NOTIFY=0
else
	NOTIFY=1
fi
if [ "_$BACKUP_PATH" != "_" ] && [ -e $BACKUP_PATH ]
then
	DUMP_PATH=$BACKUP_PATH
else
	DUMP_PATH="$K_SHARE/backup"
fi
ATTM_PATH="$K_SHARE/attachments"
DUMP_LOG="$DUMP_PATH/mySqlDump.log"
SQL_ERR="$DUMP_PATH/mySql.err"
DUMP_ARGS="--hex-blob --skip-lock-tables --single-transaction --log-error=$SQL_ERR"

if [ "$1" == "help" ]
then
	echo "kopano4s-backup (c) TosoBoso: script using mysqldump inspired by synology and zarafa wiki"
	echo "script will work with transaction locks as opposed to full table locks"
	echo "to restore provide the keyword and timestamp e.g. <kopano4s-backup.sh restore 201805151230"
	echo "to prevent failed restore due to big blobs (attachments) we set max_allowed_packet = 16M or more in </etc/mysql/my.cnf>"
	exit 0
fi
# set sudo for DSM 6 as root login is no longer possible
MAJOR_VERSION=`grep majorversion /etc.defaults/VERSION | grep -o [0-9]`
LOGIN=`whoami`
if [ "$SUDO" == "sudo" ]
then
	# temporarilly open acls to make commands work on files
	sudo chmod 777 $DUMP_PATH
	sudo touch $SQL_ERR
	sudo touch $DUMP_LOG
	sudo chown root.kopano $SQL_ERR
	sudo chown root.kopano $DUMP_LOG
	sudo chmod 666 $SQL_ERR
	sudo chmod 666 $DUMP_LOG
fi

if [ "$1" == "restore" ]
then
	if [ "$2" == "" ] || !(test -e $DUMP_PATH/dump-kopano-${2}.sql.gz)
	then
		TS=`ls -t1 $DUMP_PATH/dump-kopano-*.sql.gz | head -n 1 | grep -o [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]`
		if [ "$TS" == "" ]
		then
			TS="no files exist"
		fi
		echo "no valid restore argument was provided. Latest timestamp would be <$TS>"
		exit 1
	fi
	TSTAMP=$2
	test -e /var/packages/MariaDB10/etc/my.cnf || $SUDO touch /var/packages/MariaDB10/etc/my.cnf
	if [ "$SUDO" == "sudo" ]
	then
		# sudo echo or grep does not work so temporarily open the files for read
		sudo chmod 666 /var/packages/MariaDB10/etc/my.cnf
	fi
	if !(grep -q "max_allowed_packet" /var/packages/MariaDB10/etc/my.cnf)
	then
		if !(grep -q "[mysqld]" /var/packages/MariaDB10/etc/my.cnf)
		then
			echo -e "[mysqld]" >> /var/packages/MariaDB10/etc/my.cnf
		fi
		echo -e "max_allowed_packet = 16M" >> /var/packages/MariaDB10/etc/my.cnf
		echo "mysql max_allowed_packet had to be increased to prevent failed restore of big blobs; retry post restarting mysql.."
		if [ "$SUDO" == "sudo" ]
		then
			sudo chmod 600 /var/packages/MariaDB10/etc/my.cnf
			sudo chmod 750 $DUMP_PATH
			sudo chmod 640 $SQL_ERR
			sudo chmod 640 $DUMP_LOG
		fi
		$SUDO /var/packages/MariaDB10/scripts/start-stop-status restart
		exit 1
	fi
	# do not restore in active slave mode as it breaks replication and stop if msql read-only
	if [ "$K_REPLICATION" == "SLAVE" ] && ( ($SUDO kopano-replication | grep -q "running") || (grep -q "^read-only" /var/packages/MariaDB10/etc/my.cnf))
	then
		MSG="refuse restore: replication running or mysql read-only do zarafa-replication reset first"
		echo $MSG
		if [ $NOTIFY -gt 0 ]
		then
			/usr/syno/bin/synodsmnotify $NOTIFYTARGET Kopano "$MSG"
		fi
		if [ "$SUDO" == "sudo" ]
		then
			sudo chmod 600 /var/packages/MariaDB10/etc/my.cnf
			sudo chmod 750 $DUMP_PATH
			sudo chmod 640 $SQL_ERR
			sudo chmod 640 $DUMP_LOG
		fi
		exit 1
	fi
	if [ "$SUDO" == "sudo" ]
	then
		sudo chmod 600 /var/packages/MariaDB10/etc/my.cnf
	fi
	TS=$(date "+%Y.%m.%d-%H.%M.%S")
	MSG="stoping kopano and starting restore of $DB_NAME from dump-kopano-${TSTAMP}.sql.gz..."
	echo -e "$TS $MSG" >> $DUMP_LOG
	echo "$MSG"
	K_START=0
	if [ $LEGACY -gt 0 ]
	then
		if [ -e /var/packages/Zarafa/scripts/start-stop-status ] && $SUDO /var/packages/Zarafa/scripts/start-stop-status status
		then
			$SUDO /var/packages/Zarafa/scripts/start-stop-status stop
			K_START=1
		fi
		if [ -e /var/packages/Zarafa4home/scripts/start-stop-status ] && $SUDO /var/packages/Zarafa4home/scripts/start-stop-status status
		then
			$SUDO /var/packages/Zarafa4home/scripts/start-stop-status stop
			K_START=1
		fi
	else
		if $SUDO /var/packages/Kopano4s/scripts/start-stop-status status
		then
			$SUDO /var/packages/Kopano4s/scripts/start-stop-status stop
			K_START=1
		fi
	fi
	if [ "$SUDO" == "sudo" ]
	then
		sudo chmod +r $DUMP_PATH/dump-kopano-${TSTAMP}.sql.gz
	fi
	gunzip $DUMP_PATH/dump-kopano-${TSTAMP}.sql.gz
	STARTTIME=$(date +%s)
	$SUDO $MYSQL $DB_NAME -u$DB_USER -p$DB_PASS < $DUMP_PATH/dump-kopano-${TSTAMP}.sql >$SQL_ERR 2>&1
	$SUDO $MYSQL $DB_NAME -u$DB_USER -p$DB_PASS "drop table clientupdatestatus" >$SQL_ERR 2>&1
	# collect if available master-log-positon in in sql-dump
	ML=`head $DUMP_PATH/dump-kopano-${TSTAMP}.sql -n50 | grep "MASTER_LOG_POS" | cut -c 4-`
	$SUDO gzip -9 $DUMP_PATH/dump-kopano-${TSTAMP}.sql
	ENDTIME=$(date +%s)
	DIFFTIME=$(( $ENDTIME - $STARTTIME ))
	TASKTIME="$(($DIFFTIME / 60)) : $(($DIFFTIME % 60)) min:sec."
	TS=$(date "+%Y.%m.%d-%H.%M.%S")
	MSG="restore for $DB_NAME completed in $TASKTIME"
	echo -e "$TS $MSG" >> $DUMP_LOG
	echo "$MSG"
	if [ $NOTIFY -gt 0 ]
	then
		/usr/syno/bin/synodsmnotify $NOTIFYTARGET Kopano-Backup "$MSG"
	fi
	RET=`cat $SQL_ERR`
	if [ "$RET" != "" ]
	then
		echo -e $RET
	fi
	# add if string is not empty
	if [ ! -z "$ML" ]
	then
		echo -e "for replication or point in time recovery $ML"
		echo -e "for replication or point in time recovery $ML" >> $DUMP_LOG
		if [ -e $DUMP_PATH/master-logpos-* ] ; then rm $DUMP_PATH/master-logpos-* ; fi
		echo "$ML" > $DUMP_PATH/master-logpos-${TSTAMP}
	fi
	# set back acls when run from non root in sudo
	if [ "$SUDO" == "sudo" ]
	then
		sudo chmod 750 $DUMP_PATH
		sudo chmod 640 $SQL_ERR
		sudo chmod 640 $DUMP_LOG
		sudo chown root.kopano $DUMP_PATH/dump-kopano-${TSTAMP}.sql.gz
		sudo chmod 640 $DUMP_PATH/dump-kopano-${TSTAMP}.sql.gz
	fi
	if [ -e $DUMP_PATH/master-logpos-${TSTAMP} ]
	then 
		$SUDO chown root.kopano $DUMP_PATH/master-logpos-${TSTAMP}
		$SUDO chmod 640 $DUMP_PATH/master-logpos-${TSTAMP}
	fi
	# backup attachements if they exist
	if [ "$ATTACHMENT_ON_FS" == "ON" ] && [ -e $DUMP_PATH/attachments-${TSTAMP}.tgz ] 
	then
		MSG="restoring attachments linked to $DB_NAME..."
		TS=$(date "+%Y.%m.%d-%H.%M.%S")
		echo -e "$TS $MSG" >> $DUMP_LOG
		echo -e "$MSG"
		CUR_PATH=`pwd`
		cd $K_SHARE
		$SUDO mv attachments attachments.old
		$SUDO tar -zxvf $DUMP_PATH/attachments-${TSTAMP}.tgz attachments/
		$SUDO chown -R root.kopano attachments
		$SUDO chmod 770 attachments
		cd $CUR_PATH
	fi
	if [ $K_START -gt 0 ]
	then
		if [ $LEGACY -gt 0 ]
		then
			if [ -e /var/packages/Zarafa/scripts/start-stop-status ]
			then
				$SUDO /var/packages/Zarafa/scripts/start-stop-status start
			fi
			if [ -e /var/packages/Zarafa4home/scripts/start-stop-status ]
			then
				$SUDO /var/packages/Zarafa4home/scripts/start-stop-status start
			fi
		else
			$SUDO /var/packages/Kopano4s/scripts/start-stop-status start	
		fi
	fi
	exit 0
fi

MSG="starting mysql-dump of $DB_NAME to $DUMP_PATH..."
if [ "$1" == "master" ]
then
	# if "log-bin" found add master-date switch for point in time recovery / building
	if grep -q ^log-bin /var/packages/MariaDB10/etc/my.cnf
	then
		MSG="$MSG incl. master-log mode for replication"
		DUMP_ARGS="$DUMP_ARGS --master-data=2"
	else
		echo "warning: binary logging has to be enabled (my.cf with <log-bin> section)"
	fi
fi
TS=$(date "+%Y.%m.%d-%H.%M.%S")
echo -e "$TS $MSG" >> $DUMP_LOG
if [ "$1" == "" ]
then
	MSG="$MSG use help for details e.g. on restore"
fi
echo -e "$MSG"

# prevent unnoticed backup error when pipe is failing
set -o pipefail
# delete old dump files dependent on keep versions / retention
DBDUMPS=`$SUDO find $DUMP_PATH -name "dump-kopano-*.sql.gz" | wc -l | sed 's/\ //g'`
if [ "$DBDUMPS" == "" ]
then
	DBDUMPS=0
fi
while [ $DBDUMPS -ge $KEEP_BACKUPS ]
do
	$SUDO ls -tr1 $DUMP_PATH/dump-kopano-*.sql.gz | head -n 1 | xargs $SUDO rm -f 
	DBDUMPS=`expr $DBDUMPS - 1` 
done

TSTAMP=`date +%Y%m%d%H%M`
DUMP_FILE_RUN="$DUMP_PATH/.dump-kopano-${TSTAMP}.sql.gK_RUNNING"

# check for previous files and remove (2 grep lines) or stop processing (>2 processes)
if [ -e $DUMP_PATH/.dump-kopano-*.sql.gK_RUNNING ]
then
	if [ $MAJOR_VERSION -gt 5 ]
	then
		RET=`ps -f | grep zarafa-backup.sh | wc -l`
	else
		RET=`ps | grep zarafa-backup.sh | wc -l`
	fi
	if [ $RET -le 2 ]
	then
		$SUDO rm -f $DUMP_PATH/.dump-kopano-*.sql.gK_RUNNING
	else
		echo -e "terminating due to already running mysql dump process"
		echo -e "terminating due to already running mysql dump process"  >> $DUMP_LOG
		exit 1
	fi
fi
STARTTIME=$(date +%s)
# ** start mysql-dump logging to $SQL_ERR to compressed file during run time use suffix RUNNING
$MYSQLDUMP $DUMP_ARGS $DB_NAME -u$DB_USER -p$DB_PASS | gzip -c -9 > $DUMP_FILE_RUN

ENDTIME=$(date +%s)
DIFFTIME=$(( $ENDTIME - $STARTTIME ))
TASKTIME="$(($DIFFTIME / 60)) : $(($DIFFTIME % 60)) min:sec."

RET=`cat $SQL_ERR`
if [ "$RET" != "" ]
then
	echo -e $RET
	echo -e $RET >> $DUMP_LOG
	if [ $NOTIFY -gt 0 ]
	then
		$SUDO /usr/syno/bin/synodsmnotify $NOTIFYTARGET Zarafa-Backup-Error "$RET"
	fi
fi
$SUDO mv -f $DUMP_FILE_RUN $DUMP_PATH/dump-kopano-${TSTAMP}.sql.gz

TS=$(date "+%Y.%m.%d-%H.%M.%S")
MSG="dump for $DB_NAME completed in $TASKTIME"
echo -e "$TS $MSG" >> $DUMP_LOG
echo "$MSG"
if [ $NOTIFY -gt 0 ]
then
	$SUDO /usr/syno/bin/synodsmnotify $NOTIFYTARGET Zarafa-Backup "$MSG"
fi
# backup attachements if they exist
if [ "$ATTACHMENT_ON_FS" == "ON" ] && [ ! -d "ls -A $ATTM_PATH" ] 
then
	MSG="saving attachments linked to $DB_NAME..."
	TS=$(date "+%Y.%m.%d-%H.%M.%S")
	echo -e "$TS $MSG" >> $DUMP_LOG
	echo -e "$MSG"
	CUR_PATH=`pwd`
	cd $K_SHARE
	$SUDO tar cfz $DUMP_PATH/attachments-${TSTAMP}.tgz attachments/
	cd $CUR_PATH
fi
# set back acls when run from non root in sudo
if [ "$SUDO" == "sudo" ]
then
	sudo chmod 750 $DUMP_PATH
	sudo chmod 640 $SQL_ERR
	sudo chmod 640 $DUMP_LOG
	sudo chown root.root $DUMP_PATH/dump-kopano-${TSTAMP}.sql.gz
	sudo chmod 640 $DUMP_PATH/dump-kopano-${TSTAMP}.sql.gz
fi
exit 0