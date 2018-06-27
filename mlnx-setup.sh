#!/bin/bash

echo -e "\n===== INSTALLING MELLANOX OFED ====="
OS_VER="ubuntu`lsb_release -r | cut -d":" -f2 | xargs`"
MLNX_OFED="MLNX_OFED_LINUX-3.4-1.0.0.0-$OS_VER-x86_64"
axel -n 8 -q http://www.mellanox.com/downloads/ofed/MLNX_OFED-3.4-1.0.0.0/$MLNX_OFED.tgz
tar xzf $MLNX_OFED.tgz
./$MLNX_OFED/mlnxofedinstall --force --without-fw-update >> ./$MLNX_OFED/install.log
