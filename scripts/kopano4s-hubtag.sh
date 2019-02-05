#!/bin/sh
# (c) 2018 vbettag - script to collect lates tag on docker hub
# admins only plus set sudo for DSM 6 as root login is no longer possible
LOGIN=`whoami`
if [ $LOGIN != "root" ] && ! (grep administrators /etc/group | grep -q $LOGIN)
then 
	echo "admins only"
	exit 1
fi
. "$(dirname $0)"/common
. /var/packages/Kopano4s/etc/package.cfg
GET_VER_TAG
echo "$VER_TAG"
