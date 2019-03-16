#!/bin/sh

apt-get install mysql-server
mysql_secure_installation
systemctl stop mysql.service
cp mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl start mysql.service
