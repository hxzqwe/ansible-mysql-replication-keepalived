# Ansible 快速部署Keepalived与MySQL互为主从集群

本项目是根据 **`Keepalived与MySQL互为主从自动切换配置.md`**文档关于如何部署**`Keepalived与MySQL互为主从集群`**改造成的ansible项目



支持以下操作系统:

- CentOS 7
- RedHat 7

## 使用说明

下载本项目到ansible服务器

```bash
git clone https://github.com/hxzqwe/ansible-mysql-replication-keepalived.git
```

修改hosts.yaml配置文件

```yaml
[mysql]
10.1.75.11 master=true
10.1.75.12 slave=true
```

> **修改被控端mysql主服务和mysql从服务器的ip**

修改vars.yaml配置文件

```yaml
# mysql
mysql_pkg: mysql-5.7.42-linux-glibc2.12-x86_64.tar.gz
mysql_version: mysql-5.7.42-linux-glibc2.12-x86_64
mysql_install_path: /usr/local
data_path: /data
mysql_sock: /data/mysql/mysql.sock
mysql_port: 3306
mysql_root_passwd: 123456
repl_user: replication
repl_passwd: replication
log_error: mysql.log

master_ip: 10.1.75.11
slave_ip: 10.1.75.12

# keepalived
interface: eth0
vip: 10.1.75.10
```

> **根据自己实际情况修改以上的配置，如：数据库管理员密码、ip地址、网卡名等**

开始部署

```bash
cd ansible-mysql-replication-keepalived
ansible-playbook -i hosts playbook.yaml
```

