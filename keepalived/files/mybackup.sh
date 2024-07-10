#!/bin/sh

##################################################
#File Name  : mybackup.sh
#Description: Empty the slave configuration, retrieve
#             the remote log file and Pos, and open
#             the synchronization
##################################################

BASEPATH=/etc/keepalived
LOGSPATH=$BASEPATH/logs
source $BASEPATH/.mysqlenv

$mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'replication'@'%' IDENTIFIED BY 'replication';flush privileges;"
$mysql -e "set global innodb_support_xa=0;"
$mysql -e "set global sync_binlog=0;"
$mysql -e "set global innodb_flush_log_at_trx_commit=0;"
$mysql -e "flush logs;"
$mysql -e "reset slave all;"

if [ -f $BASEPATH/syncposfile/backup_master.status ];then
        New_ReM_File=`cat $BASEPATH/syncposfile/backup_master.status | grep -v File |awk '{print $1}'`
        New_ReM_Position=`cat $BASEPATH/syncposfile/backup_master.status | grep -v File |awk '{print $2}'`
        echo "$(date "+%Y-%m-%d %H:%M:%S") This mybackup.sh, New_ReM_File:$New_ReM_File,New_ReM_Position:$New_ReM_Position" >> $LOGSPATH/mysql_switch.log
        $mysql -e "change master to master_host='$REMOTE_IP',master_port=3306,master_user='replication',master_password='replication',master_log_file='$New_ReM_File',master_log_pos=$New_ReM_Position;"
        $mysql -e "start slave;"
        $mysql -e "show slave status\G;" > $LOGSPATH/slave_status_$(date "+%y%m%d-%H%M").txt
        cat $LOGSPATH/slave_status_$(date "+%y%m%d-%H%M").txt >> $LOGSPATH/mysql_switch.log
        rm -f $BASEPATH/syncposfile/backup_master.status
else
    echo "$(date "+%Y-%m-%d %H:%M:%S") The scripts mybackup.sh running error..." >> $LOGSPATH/mysql_switch.log
fi
