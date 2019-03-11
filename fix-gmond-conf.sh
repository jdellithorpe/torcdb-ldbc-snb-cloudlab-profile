#!/bin/bash
sed "s/host = .*/host = $(ssh rcmaster hostname -i)/g" /local/repository/ganglia.conf/gmond.conf > /etc/ganglia/gmond.conf
service ganglia-monitor restart
