#!/bin/sh

apt-get install mysql-server
mysql_secure_installation
cp mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf
