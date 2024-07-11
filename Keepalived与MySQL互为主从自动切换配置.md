# Keepalived与MySQL互为主从自动切换配置          

为解决Mysql数据库单点问题，实现两台MySQL数据库互为主备，双向replication。当Master出现问题，则将Slave切换为Master继续工作。

| 配置信息       |                  |
| -------------- | ---------------- |
| 系统版本       | CentOS 7.9       |
| MySQL版本      | mysql 5.7.27     |
| keepalived版本 | Keepalived 1.3.5 |
| ansible版本    | ansible 2.9.6    |

| IP                               | 主机名       | 角色                      |
| -------------------------------- | ------------ | ------------------------- |
| 10.1.75.252                      | ansible      | ansible                   |
| 10.1.58.191<br />VIP 10.1.58.190 | mysql-master | mysql-master + keepalived |
| 10.1.58.192<br />VIP 10.1.58.190 | mysql-slave  | mysql-slave + keepalived  |

网络拓扑

![ansible-mysql-replication-keepalived](images\ansible-mysql-replication-keepalived.jpg)



# 安装前准备工作

## 配置时间同步

设置时区，在所有节点上执行

```
cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
```

在控制节点 controller 安装 chrony，将控制节点作为 NTP 服务端

```
yum -y install chrony
```

重启服务并设置开机自启动

```
systemctl restart chronyd.service
systemctl enable --now chronyd.service
```

验证时间同步，`Leap status`显示为`Normal`表示正常

\# chronyc tracking

```
Reference ID    : 6E2A628A (110.42.98.138)
Stratum         : 3
Ref time (UTC)  : Sun Jun 30 07:49:00 2024
System time     : 0.000367060 seconds slow of NTP time
Last offset     : -0.000100947 seconds
RMS offset      : 0.000551076 seconds
Frequency       : 72.088 ppm slow
Residual freq   : -0.001 ppm
Skew            : 0.195 ppm
Root delay      : 0.062848948 seconds
Root dispersion : 0.003252745 seconds
Update interval : 1024.5 seconds
Leap status     : Normal
```

## 双机互信配置ssh免密认证

配置mysql-master和mysql-slave互信

**在ansible机器操作**

生成root用户的私钥、公钥和authorized_keys文件

```
ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""
(umask 066 && cat /root/.ssh/id_rsa.pub >>/root/.ssh/authorized_keys)
```

分发root用户私钥、公钥和authorized_keys文件

```bash
for i in 10.1.58.191 10.1.58.192
do   
    rsync -az /root/.ssh/id_rsa root@$i:/root/.ssh/id_rsa
    rsync -az /root/.ssh/id_rsa.pub root@$i:/root/.ssh/id_rsa.pub
    rsync -az /root/.ssh/authorized_keys root@$i:/root/.ssh/authorized_keys
done
```

添加hostkey到known_hosts

```
for i in 10.1.58.191 10.1.58.192
do
    ssh -o StrictHostKeyChecking=no $i "hostname"
done

for i in 10.1.58.191 10.1.58.192
do
    rsync -az /root/.ssh/known_hosts $i:/root/.ssh/known_hosts
done
```

# 安装MySQL服务

## 安装mysql5.7二进制

在mysql-master和mysql-slave操作

```bash
# 安装依赖包
yum -y install libaio 

# 下载mysql软件包并解压
wget https://cdn.mysql.com/archives/mysql-5.7/mysql-5.7.42-linux-glibc2.12-x86_64.tar.gz -O - |tar -zxf - -C /usr/local/

# 创建mysql应用目录软连接
cd /usr/local/
ln -s mysql-5.7.42-linux-glibc2.12-x86_64 /usr/local/mysql
# mv mysql-5.7.42-linux-glibc2.12-x86_64 mysql

# 创建mysql用户和组
groupadd mysql
useradd mysql -s /sbin/nologin -M -g mysql

# 建立mysql数据文件目录
mkdir -p /data/mysql

# 初始化数据库并记住输出最后一行里mysql软件生成的临时密码
/usr/local/mysql/bin/mysqld --initialize --basedir=/usr/local/mysql/ --datadir=/data/mysql/
2024-06-29T08:51:57.760324Z 0 [Warning] TIMESTAMP with implicit DEFAULT value is deprecated. Please use --explicit_defaults_for_timestamp server option (see documentation for more details).
2024-06-29T08:51:59.337791Z 0 [Warning] InnoDB: New log files created, LSN=45790
2024-06-29T08:51:59.927279Z 0 [Warning] InnoDB: Creating foreign key constraint system tables.
2024-06-29T08:52:00.018250Z 0 [Warning] No existing UUID has been found, so we assume that this is the first time that this server has been started. Generating a new UUID: d8f7bffa-35f4-11ef-9d46-fa163e58a25a.
2024-06-29T08:52:00.022822Z 0 [Warning] Gtid table is not ready to be used. Table 'mysql.gtid_executed' cannot be opened.
2024-06-29T08:52:00.446845Z 0 [Warning] A deprecated TLS version TLSv1 is enabled. Please use TLSv1.2 or higher.
2024-06-29T08:52:00.446888Z 0 [Warning] A deprecated TLS version TLSv1.1 is enabled. Please use TLSv1.2 or higher.
2024-06-29T08:52:00.447729Z 0 [Warning] CA certificate ca.pem is self signed.
2024-06-29T08:52:00.689775Z 1 [Note] A temporary password is generated for root@localhost: -Hk1IgsgequF

# 授权mysql用户访问mysql的安装目录和数据文件目录
chown -R mysql.mysql /usr/local/mysql/; chown -R mysql.mysql /data/mysql/
```

> 2024-06-29T08:52:00.689775Z 1 [Note] A temporary password is generated for root@localhost: -Hk1IgsgequF    #记下临时密码 -Hk1IgsgequF

创建my.cnf配置文件
-------------------------------------------------------------------------------------------------------------------------------

在mysql-master节点的安装目录下创建my.cnf文件配置
```bash
cat >/usr/local/mysql/my.cnf <<EOF
[mysqld]
basedir=/usr/local/mysql
datadir=/data/mysql
socket=/data/mysql/mysql.sock
log_error=/data/mysql/mysql.log
pid-file=/data/mysql/mysql.pid
port=3306
server_id=1    #master的配置和slave的配置server-id不能一致
log-bin=mysql-bin
EOF
```

在mysql-slave节点的安装目录下创建my.cnf文件配置

```bash
cat >/usr/local/mysql/my.cnf <<EOF
[mysqld]
basedir=/usr/local/mysql
datadir=/data/mysql
socket=/data/mysql/mysql.sock
log_error=/data/mysql/mysql.log
pid-file=/data/mysql/mysql.pid
port=3306
server_id=2    #master的配置和slave的配置server-id不能一致
log-bin=mysql-bin
EOF
```

## 启动mysql服务

分别在mysql-master和mysql-slave节点上操作

```bash
# 创建systemd的MySQL配置文件
cat >/usr/lib/systemd/system/mysqld.service <<EOF
[Unit]
Description=MySQL Server
Documentation=man:mysqld(8)
Documentation=http://dev.mysql.com/doc/refman/en/using-systemd.html
After=network.target
After=syslog.target

[Install]
WantedBy=multi-user.target

[Service]
User=mysql
Group=mysql
ExecStart=/usr/local/mysql/bin/mysqld --defaults-file=/usr/local/mysql/my.cnf
LimitNOFILE = 5000
EOF

# 设置开机启动
systemctl enable mysqld.service

# 启动服务
systemctl start mysqld.service
```

## 添加mysql环境变量

分别在mysql-master和mysql-slave节点上操作

```bash
# 在/etc/profile后面追加以下内容
cat >> /etc/profile <<"EOF"

export MYSQL_HOME=/usr/local/mysql
export PATH=$MYSQL_HOME/bin:$PATH
EOF

# 加载环境变量
source /etc/profile
```

## 重新设置密码

```sql
mysql -S /data/mysql/mysql.sock -uroot -p
mysql> ALTER USER 'root'@'localhost' IDENTIFIED BY '123456';
```

> **注意：**生产环境需要使用复杂密码

## 创建远程root管理员帐号(可选)

```sql
mysql -S /data/mysql/mysql.sock -uroot -p
mysql> CREATE USER 'root'@'%' IDENTIFIED BY '123456';
mysql> GRANT ALL ON *.* TO 'root'@'%';
```

> **注意：**生产环境需要使用复杂密码

## 配置MySQL主从

```sql
# 登陆mysql-master节点的数据库
mysql -h 10.1.58.191 -uroot -p

# 创建复制用户并授权
mysql> GRANT REPLICATION SLAVE,REPLICATION CLIENT ON *.* TO replication@'%' IDENTIFIED BY 'replication';  
mysql> FLUSH PRIVILEGES;

# 获取主服务器状态并记录下Binlog文件名和位置点。在mysql-master节点操作，如下
mysql> show master status;
+------------------+----------+--------------+------------------+-------------------+
| File             | Position | Binlog_Do_DB | Binlog_Ignore_DB | Executed_Gtid_Set |
+------------------+----------+--------------+------------------+-------------------+
| mysql-bin.000001 |      997 |              |                  |                   |
+------------------+----------+--------------+------------------+-------------------+
1 row in set (0.00 sec)

#------------------
# 登陆mysql-slave节点的数据库
mysql -h 10.1.58.192 -uroot -p

# 配置从服务器以连接到主服务器并开始复制
mysql> change master to master_host='10.1.58.191',master_port=3306,master_user='replication',master_password='replication',master_log_file='mysql-bin.000001',master_log_pos=997;
mysql> start slave;
```

> 思考：生产环境添加从节点时是否要锁表

## 检查复制状态

在Slave主机上，查询同步状态“show slave status\G”，检查结果中`Slave_IO_Running: Yes`和`Slave_SQL_Running: Yes`，否则有异常。

```sql
 mysql >show slave status\G
*************************** 1. row ***************************
               Slave_IO_State: Waiting for master to send event
                  Master_Host: 10.1.58.191
                  Master_User: replica
                  Master_Port: 3306
                Connect_Retry: 60
              Master_Log_File: mysql-bin.000001
          Read_Master_Log_Pos: 997
               Relay_Log_File: mysql-slave-relay-bin.000002
                Relay_Log_Pos: 320
        Relay_Master_Log_File: mysql-bin.000001
             Slave_IO_Running: Yes    #yes表示slave已经连上master
            Slave_SQL_Running: Yes    #yes表示slave开启主从复制
              Replicate_Do_DB:
          Replicate_Ignore_DB:
           Replicate_Do_Table:
       Replicate_Ignore_Table:
      Replicate_Wild_Do_Table:
  Replicate_Wild_Ignore_Table:
                   Last_Errno: 0
                   Last_Error:
                 Skip_Counter: 0
          Exec_Master_Log_Pos: 997
              Relay_Log_Space: 533
              Until_Condition: None
               Until_Log_File:
                Until_Log_Pos: 0
           Master_SSL_Allowed: No
           Master_SSL_CA_File:
           Master_SSL_CA_Path:
              Master_SSL_Cert:
            Master_SSL_Cipher:
               Master_SSL_Key:
        Seconds_Behind_Master: 0
Master_SSL_Verify_Server_Cert: No
                Last_IO_Errno: 0
                Last_IO_Error:
               Last_SQL_Errno: 0
               Last_SQL_Error:
  Replicate_Ignore_Server_Ids:
             Master_Server_Id: 1
                  Master_UUID: d8f7bffa-35f4-11ef-9d46-fa163e58a25a
             Master_Info_File: /data/mysql/master.info
                    SQL_Delay: 0
          SQL_Remaining_Delay: NULL
      Slave_SQL_Running_State: Slave has read all relay log; waiting for more updates
           Master_Retry_Count: 86400
                  Master_Bind:
      Last_IO_Error_Timestamp:
     Last_SQL_Error_Timestamp:
               Master_SSL_Crl:
           Master_SSL_Crlpath:
           Retrieved_Gtid_Set:
            Executed_Gtid_Set:
                Auto_Position: 0
         Replicate_Rewrite_DB:
                 Channel_Name:
           Master_TLS_Version:
1 row in set (0.00 sec)
```

## 配置安全管理MySQL凭证

参考文档：https://blog.csdn.net/bxstephen/article/details/135083345

Mysql数据库使用mysql或mysqldump等相关命令时，需要在命令行界面输入密码，当使用脚本时，在脚本里填写密码显然不太安全，因此可以设置MySQL的访问凭证。

```bash
# 设置凭证
mysql_config_editor set --login-path=local --host=localhost --user=root --socket=/data/mysql/mysql.sock --password
Enter password:        #输入密码               

# 查看所有凭证
mysql_config_editor print --all
[local]
user = root
password = *****
host = localhost
port = 3306

# 使用凭证登录mysql
mysql --login-path=local
```

# 创建MySQL主从切换脚本

**使用脚本前提条件说明**

- 完成MySQL互为主从配置

- 主备机NTP时钟同步
- 双机互信配置ssh免密认证

**MySQL主从切换脚本规划**

将所有keepalive脚本放在`/etc/keepalived/`目录下,本次相关脚本说明如下：

| 脚本名          | 脚本说明                                                     |
| --------------- | ------------------------------------------------------------ |
| .mysqlenv       | mysql环境脚本(用于免密登录mysql)                             |
| mycheck.sh      | MySQL服务检查脚本。如果mysql运行正常，则正常退出脚本；如果mysql运行不正常，则关闭keepalived服务 |
| mymaster.sh     | 切换脚本(把从库变成主库)。先判断同步复制是否执行完成，如果未执行完成等待1分钟后，停止同步（stop slave;），并且记录切换后的binlog日志和Position值 |
| mybackup.sh     | 回切脚本（把原主库变成从库）。清空slave配置，重新获取远程binlog日志和Position值,并开启同步 |
| mystop.sh       | 设置参数保证数据不丢失，最后检查看是否还有写操作，最后1分钟退出 |
| logs目录        | 存储日志的文件目录                                           |
| syncposfile目录 | 每次切换后，存储master端最后一次binlog日志文件名的值和Position值。 |

创建脚本相关目录，在mysql-master和mysql-slave操作

```
mkdir -p /etc/keepalived/{logs,syncposfile}
```

## MySQL环境脚本(用于免密登录mysql)

在mysql-master端创建mysql环境脚本

```sh
cat >/etc/keepalived/.mysqlenv <<"EOF"
MYSQL=/usr/local/mysql/bin/mysql
MYSQL_CMD="--login-path=local -S /data/mysql/mysql.sock"

#mysql-slave端的IP地址
REMOTE_IP=10.1.58.192
export mysql="$MYSQL $MYSQL_CMD "
EOF
```

在mysql-slave端创建mysql环境脚本

```sh
cat >/etc/keepalived/.mysqlenv <<"EOF"
MYSQL=/usr/local/mysql/bin/mysql
MYSQL_CMD="--login-path=local -S /data/mysql/mysql.sock"

#mysql-master端的IP地址
REMOTE_IP=10.1.58.191
export mysql="$MYSQL $MYSQL_CMD "
EOF
```

## MySQL服务检查脚本

在mysql-master和mysql-slave操作

\# vim /etc/keepalived/mycheck.sh 

```bash
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
```

## 切换脚本(把从库变成主库)

在mysql-master和mysql-slave操作

\# vim /etc/keepalived/mymaster.sh

```bash
#!/bin/sh

##################################################
#File Name  : mymaster.sh
#Description: First determine whether synchronous
#             replication is performed, and if no
#             execution is completed, wait for 1
#             minutes. Log logs and POS after
#             switching, and record files synchronously.
##################################################

BASEPATH=/etc/keepalived
LOGSPATH=$BASEPATH/logs
source $BASEPATH/.mysqlenv

$mysql -e "show slave status\G" > $LOGSPATH/mysqlslave.states
Master_Log_File=`cat $LOGSPATH/mysqlslave.states | grep -w Master_Log_File | awk -F": " '{print $2}'`
Relay_Master_Log_File=`cat $LOGSPATH/mysqlslave.states | grep -w Relay_Master_Log_File | awk -F": " '{print $2}'`
Read_Master_Log_Pos=`cat $LOGSPATH/mysqlslave.states | grep -w Read_Master_Log_Pos | awk -F": " '{print $2}'`
Exec_Master_Log_Pos=`cat $LOGSPATH/mysqlslave.states | grep -w Exec_Master_Log_Pos | awk -F": " '{print $2}'`
i=1

while true
do
    if [ $Master_Log_File = $Relay_Master_Log_File ] && [ $Read_Master_Log_Pos -eq $Exec_Master_Log_Pos ];then
        echo "$(date "+%Y-%m-%d %H:%M:%S") The mymaster.sh, slave sync ok... " >> $LOGSPATH/mysql_switch.log
        break
    else
        sleep 1
        if [ $i -gt 60 ];then
            break
        fi
        continue
        let i++
    fi
done

$mysql -e "stop slave;"
$mysql -e "set global innodb_support_xa=0;"
$mysql -e "set global sync_binlog=0;"
$mysql -e "set global innodb_flush_log_at_trx_commit=0;"
$mysql -e "flush logs;GRANT ALL PRIVILEGES ON *.* TO 'replication'@'%' IDENTIFIED BY 'replication';flush privileges;"
$mysql -e "show master status;" > $LOGSPATH/master_status_$(date "+%y%m%d-%H%M").txt

# sync pos file
/usr/bin/scp $LOGSPATH/master_status_$(date "+%y%m%d-%H%M").txt root@$REMOTE_IP:$BASEPATH/syncposfile/backup_master.status
echo "$(date "+%Y-%m-%d %H:%M:%S") The mymaster.sh, Sync pos file sucess." >> $LOGSPATH/mysql_switch.log
```

## 回切脚本

在mysql-master和mysql-slave操作

\# vim /etc/keepalived/mybackup.sh

```bash
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
```

## 停止脚本

在mysql-master和mysql-slave操作

\# vim /etc/keepalived/mystop.sh

```sh
#!/bin/sh

##################################################
#File Name  : mystop.sh
#Description: Set parameters to ensure that the data
#             is not lost, and finally check to see
#             if there are still write operations,
#             the last 1 minutes to exit

##################################################

BASEPATH=/etc/keepalived
LOGSPATH=$BASEPATH/logs
source $BASEPATH/.mysqlenv

$mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'replication'@'%' IDENTIFIED BY 'replication';flush privileges;"
$mysql -e "set global innodb_support_xa=1;"
$mysql -e "set global sync_binlog=1;"
$mysql -e "set global innodb_flush_log_at_trx_commit=1;"
$mysql -e "show master status\G" > $LOGSPATH/mysqlmaster0.states
M_File1=`cat $LOGSPATH/mysqlmaster0.states | awk -F': ' '/File/{print $2}'`
M_Position1=`cat $LOGSPATH/mysqlmaster0.states | awk -F': ' '/Position/{print $2}'`
sleep 2
$mysql -e "show master status\G" > $LOGSPATH/mysqlmaster1.states
M_File2=`cat $LOGSPATH/mysqlmaster1.states | awk -F': ' '/File/{print $2}'`
M_Position2=`cat $LOGSPATH/mysqlmaster1.states | awk -F': ' '/Position/{print $2}'`

i=1

while true
do
    if [ $M_File1 = $M_File2 ] && [ $M_Position1 -eq $M_Position2 ];then
        echo "$(date "+%Y-%m-%d %H:%M:%S") The mystop.sh, master sync ok.." >> $LOGSPATH/mysql_switch.log
        exit 0
    else
        sleep 1
        if [$i -gt 60 ];then
            break
        fi
        continue
        let i++
    fi
done
echo "$(date "+%Y-%m-%d %H:%M:%S") The mystop.sh, master sync exceed one minutes..." >> $LOGSPATH/mysql_switch.log
```

## 设置脚本可执行权限

在mysql-master和mysql-slave操作

```
chmod a+x /etc/keepalived/*.sh
```

# keepalived

## 安装keepalived

在mysql-master和mysql-slave节点上操作

```
yum install -y keepalived
```

## 切换原理

Keepalived可实现将虚拟IP地址在实体物理机上来回漂移。Keepalived在转换状态时会依照状态来呼叫配置文件中内置的定义。
当进入Master状态时会呼叫notify_master定义的脚本
当进入Backup状态时会呼叫notify_backup定义的脚本
当keepalived程序终止时呼叫notify_stop定义的脚本

> **keepalived的一些其他功能**：
>
> ```
> 当本节点服务器成为某个角色的时候，我们去执行某个脚本
> 1、notify_master
> notify_master:当当前节点成为master时，通知脚本执行任务(一般用于启动某服务，比如nginx,haproxy等)
> 如：notify_master /mail/master.sh
> 
> 2、notify_backup        
> notify_backup:当当前节点成为backup时，通知脚本执行任务(一般用于关闭某服务，比如nginx,haproxy等)
> notify_backup /mail/backup.sh
> 
> 3、notify_stop
> notify_stop：指定当keepalived进入终止状态的时候要执行的脚本
> ```

切换的过程如下：

1. 在`mysql-master`主机上keepalived运行时执行mycheck.sh脚本不停的检查mysql的运行状态，当发现mysql停止后将keepalived进程杀掉。
2. 此时`mysql-slave`主机上会接管VIP IP地址，并调用notify_master定义的脚本。
3. 当原`mysql-master`主机上的mysql和keepalived进程恢复正常后，会调用notify_backup定义的脚本，此时数据库的主端还在`mysql-slave`主机上。
4. 回切，关闭`mysql-slave`端的keepavlied进程，会调用notify_stop脚本，同时Master主机上会调用notify_master定义的脚本。此时数据库的主端在回到`mysql-master`主机上。
5. 启动`mysql-slave`端的keepavlied进程，会调用notify_backup脚本，此时完成数据同步。 

 

## 配置keepalived

**特别注意**：**注意每个节点的IP和网卡（interface参数）eth0  根据自己实际改变---->使用ifconfig查看自己的网卡**

mysql-master端配置

\# vim /etc/keepalived/keepalived.conf

```bash
! Configuration File for keepalived
global_defs {
    router_id MySQL-HA
    script_user root
    enable_script_security
} 

vrrp_script check_run {
    script "/etc/keepalived/mycheck.sh"
    interval 10
}

vrrp_instance VI_1 {
    state MASTER
    #state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    #nopreempt
    authentication {
        auth_type PASS
        auth_pass 1234
    }
    track_script {
        check_run
    }
    notify_master /etc/keepalived/mymaster.sh
    notify_backup /etc/keepalived/mybackup.sh
    notify_stop /etc/keepalived/mystop.sh

    virtual_ipaddress {
        10.1.58.190
    }  
}
```

mysql-slave端配置

\# vim /etc/keepalived/keepalived.conf

```bash
! Configuration File for keepalived
global_defs {
    router_id MySQL-HA
    script_user root
    enable_script_security
} 

vrrp_script check_run {
    script "/etc/keepalived/mycheck.sh"
    interval 10
}

vrrp_instance VI_1 {
    state MASTER
    #state BACKUP
    interface eth0
    virtual_router_id 51
    priority 90
    advert_int 1
    #nopreempt
    authentication {
        auth_type PASS
        auth_pass 1234
    }
    track_script {
        check_run
    }
    notify_master /etc/keepalived/mymaster.sh
    notify_backup /etc/keepalived/mybackup.sh
    notify_stop /etc/keepalived/mystop.sh

    virtual_ipaddress {
        10.1.58.190
    }
}
```

##  启动keepalived服务

在mysql-master和mysql-slave端操作

启动keepalived服务

```
/usr/sbin/keepalived
```

> 注意使用：systemctl start keepalived启动服务脚本会不报错，具体以下的解决方法。
>
> https://github.com/acassen/keepalived/issues/1325

# 测试切换验证

- 保证两台主机上面keepalived、MySQL服务都是正常启动着的
- 停止主端

## 开始测试切换

模拟mysql-master故障，会执行以下两步

1. 在Master主机上keepalived运行时执行mycheck.sh脚本不停的检查mysql的运行状态，当发现mysql停止后将keepalived进程杀掉。
2. 此时Slave主机上会接管VIP IP地址，并调用notify_master定义的脚本。

停止mysql-master端mysql服务

```
systemctl stop mysqld
```

查看日志

```bash
# 查看mysql-master端脚本切换日志
tail -5 /etc/keepalived/logs/mysql_switch.log
2024-07-01 11:41:28 The mycheck.sh, mysql is running ...
2024-07-01 11:41:38 The mycheck.sh, mysql is running ...
2024-07-01 11:41:48 The mycheck.sh, mysql is down, after switch...
2024-07-01 11:41:50 The mystop.sh, master sync ok..

# 查看mysql-master端的keeplaived日志
tail -7 /var/log/messages
Jul  1 11:41:40 mysql-master systemd: Stopping MySQL Server...
Jul  1 11:41:48 mysql-master Keepalived_vrrp[22566]: VRRP_Instance(VI_1) sent 0 priority
Jul  1 11:41:48 mysql-master Keepalived[22564]: Stopping
Jul  1 11:41:48 mysql-master Keepalived_healthcheckers[22565]: Stopped
Jul  1 11:41:48 mysql-master Keepalived_vrrp[22566]: Stopped
Jul  1 11:41:48 mysql-master Keepalived[22564]: Stopped Keepalived v1.3.5 (03/19,2017), git commit v1.3.5-6-g6fa32f2
Jul  1 11:41:52 mysql-master systemd: Stopped MySQL Server.

# 查看mysql-slave端的keeplaived日志
tail /var/log/messages
...
...
Jul  1 11:41:49 mysql-slave Keepalived_vrrp[9655]: VRRP_Instance(VI_1) Transition to MASTER STATE
Jul  1 11:41:50 mysql-slave Keepalived_vrrp[9655]: VRRP_Instance(VI_1) Entering MASTER STATE

# 查看mysql-slave端脚本切换日志
tail /etc/keepalived/logs/mysql_switch.log
2024-07-01 11:41:11 The mycheck.sh, mysql is running ...
2024-07-01 11:41:21 The mycheck.sh, mysql is running ...
2024-07-01 11:41:31 The mycheck.sh, mysql is running ...
2024-07-01 11:41:41 The mycheck.sh, mysql is running ...
2024-07-01 11:41:50 The mymaster.sh, slave sync ok...
2024-07-01 11:41:51 The mycheck.sh, mysql is running ...
2024-07-01 11:41:59 The mymaster.sh, Sync pos file sucess.
2024-07-01 11:42:01 The mycheck.sh, mysql is running ...
2024-07-01 11:42:11 The mycheck.sh, mysql is running ...

# 查看mysql-slave端，mysql服务主从状态
mysql --login-path=local -S /data/mysql/mysql.sock -e 'show slave status\G'
*************************** 1. row ***************************
               Slave_IO_State:
                  Master_Host: 10.1.58.191
                  Master_User: replication
                  Master_Port: 3306
                Connect_Retry: 60
              Master_Log_File: mysql-bin.000005
          Read_Master_Log_Pos: 593
               Relay_Log_File: mysql-slave-relay-bin.000002
                Relay_Log_Pos: 320
        Relay_Master_Log_File: mysql-bin.000005
             Slave_IO_Running: No
            Slave_SQL_Running: No
            ....................
            ....................
```

## 恢复测试回切

1. 当原`mysql-master`主机上的mysql和keepalived进程恢复正常后，会调用notify_backup定义的脚本，此时数据库的主端还在`mysql-slave`主机上。
2. 回切，关闭`mysql-slave`端的keepavlied进程，会调用notify_stop脚本，同时Master主机上会调用notify_master定义的脚本。此时数据库的主端在回到`mysql-master`主机上。
3. 启动`mysql-slave`端的keepavlied进程，会调用notify_backup脚本，此时完成数据同步。 

```bash
# 启动mysql-master端mysql服务
systemctl start mysqld

# 启动mysql-master端keepalived服务
/usr/sbin/keepalived

#--------------

# 关闭mysql-slave端keepalived服务
pkill keepalived

# 启动mysql-slave端keepalived服务
/usr/sbin/keepalived

# 查看mysql-slave端mysql服务的复制状态
mysql --login-path=local -S /data/mysql/mysql.sock -e 'show slave status\G'
*************************** 1. row ***************************
               Slave_IO_State: Waiting for master to send event
                  Master_Host: 10.1.58.191
                  Master_User: replication
                  Master_Port: 3306
                Connect_Retry: 60
              Master_Log_File: mysql-bin.000007
          Read_Master_Log_Pos: 593
               Relay_Log_File: mysql-slave-relay-bin.000002
                Relay_Log_Pos: 320
        Relay_Master_Log_File: mysql-bin.000007
             Slave_IO_Running: Yes
            Slave_SQL_Running: Yes
```



