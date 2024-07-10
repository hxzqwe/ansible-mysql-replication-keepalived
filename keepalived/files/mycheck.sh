#!/bin/sh

##################################################
#File Name  : mycheck.sh
#Description: mysql is working MYSQL_OK is 1
#             mysql is down MYSQL_OK is 0
##################################################

BASEPATH=/etc/keepalived
LOGSPATH=$BASEPATH/logs
source $BASEPATH/.mysqlenv

CHECK_TIME=3
MYSQL_OK=1
##################################################################
function check_mysql_helth (){
  $mysql -e "show status;" >/dev/null 2>&1
  if [ $? == 0 ] 
  then 
    MYSQL_OK=1
  else
    MYSQL_OK=0
    #systemctl status keepalived
 fi
 return $MYSQL_OK
}

#check_mysql_helth
while [ $CHECK_TIME -ne 0 ]
do
    let "CHECK_TIME -= 1"
    check_mysql_helth
    if [ $MYSQL_OK = 1 ]; then
       CHECK_TIME=0
       echo "$(date "+%Y-%m-%d %H:%M:%S") The mycheck.sh, mysql is running ..." >> $LOGSPATH/mysql_switch.log
       exit 0
    fi
    if [ $MYSQL_OK -eq 0 ] && [ $CHECK_TIME -eq 0 ]; then
       echo "$(date "+%Y-%m-%d %H:%M:%S") The mycheck.sh, mysql is down, after switch..." >> $LOGSPATH/mysql_switch.log
       pkill keepalived
       exit 1
    fi
    sleep 1
done
