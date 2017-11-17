#!/bin/bash
# Script for setting up the cluster after initial booting and configuration by
# CloudLab.

# Get the absolute path of this script on the system.
SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

# === Parameters decided by profile.py ===
# RCNFS partition that will be exported via NFS and used as a shared home
# directory for cluster users.
RCNFS_SHAREDHOME_EXPORT_DIR=$1
# RCNFS directory where remote blockstore datasets are mounted and exported via
# NFS to be shared by all nodes in the cluster.
RCNFS_DATASETS_EXPORT_DIR=$2
# RCXX partition that will be used for RAMCloud backups.
RCXX_BACKUP_DIR=$3
# Account in which various software should be setup.
USERNAME=$4

# === Paarameters decided by this script. ===
# Directory where the NFS partition will be mounted on NFS clients
SHAREDHOME_DIR=/shome
# Directory where NFS shared datasets will be mounted on NFS clients
DATASETS_DIR=/datasets

# Other variables
KERNEL_RELEASE=`uname -r`

# === Software dependencies that need to be installed. ===
# Common utilities
apt-get update
apt-get --assume-yes install mosh vim tmux pdsh tree axel htop ctags
# NFS
apt-get --assume-yes install nfs-kernel-server nfs-common
# Java
apt-get install --assume-yes software-properties-common
add-apt-repository --yes ppa:webupd8team/java
apt-get update
echo oracle-java8-installer shared/accepted-oracle-license-v1-1 select true | sudo /usr/bin/debconf-set-selections
apt-get install --assume-yes oracle-java8-installer
apt-get --assume-yes install maven
# cpupower, hugepages, msr-tools (for rdmsr), i7z
apt-get --assume-yes install linux-tools-common linux-tools-${KERNEL_RELEASE} \
        hugepages cpuset msr-tools i7z
# Dependencies to build the Linux perf tool
apt-get --assume-yes install systemtap-sdt-dev libunwind-dev libaudit-dev \
        libgtk2.0-dev libperl-dev binutils-dev liblzma-dev libiberty-dev
# Install RAMCloud dependencies
apt-get --assume-yes install build-essential git-core doxygen libpcre3-dev \
        protobuf-compiler libprotobuf-dev libcrypto++-dev libevent-dev \
        libboost-all-dev libgtest-dev libzookeeper-mt-dev zookeeper \
        libssl-dev default-jdk ccache

# Configure some environment variables for all users.
cat >> /etc/profile <<EOM

export JAVA_HOME=/usr/lib/jvm/java-8-oracle
export EDITOR=vim
EOM

# Disable user prompting for connecting to new hosts.
cat >> /etc/ssh/ssh_config <<EOM
    StrictHostKeyChecking no
EOM

# Set unlimited size for locked-in pages to allow RAMCloud to lock-in as much
# memory as it wants (to prevent the OS from swapping pages to disk and
# impairing performance).
cat >> /etc/security/limits.conf <<EOM
* soft memlock unlimited
* hard memlock unlimited
EOM

# If this server is the RCNFS server, then configure NFS to export the
# appropriate directories, including RCNFS_SHAREDHOME_EXPORT_DIR (used as a
# shared home directory for all users), and also RCNFS_DATASETS_EXPORT_DIR
# (mount point for CloudLab datasets to which cluster nodes need shared
# access). 
if [ $(hostname --short) == "rcnfs" ]
then
  # Make the file system rwx by all.
  chmod 777 $RCNFS_SHAREDHOME_EXPORT_DIR
  chmod 777 $RCNFS_DATASETS_EXPORT_DIR

  # Make the NFS exported file system readable and writeable by all hosts in
  # the system (/etc/exports is the access control list for NFS exported file
  # systems, see exports(5) for more information).
	echo "$RCNFS_SHAREDHOME_EXPORT_DIR *(rw,sync,no_root_squash)" >> /etc/exports
	echo "$RCNFS_DATASETS_EXPORT_DIR *(rw,sync,no_root_squash)" >> /etc/exports
  for dataset in $(ls $RCNFS_DATASETS_EXPORT_DIR)
  do
    echo "$RCNFS_DATASETS_EXPORT_DIR/$dataset *(rw,sync,no_root_squash)" >> /etc/exports
  done

  # Start the NFS service.
  /etc/init.d/nfs-kernel-server start

  # Give it a second to start-up
  sleep 5

  > /local/setup-nfs-done
fi

# Wait until nfs is properly set up. 
while [ "$(ssh rcnfs "[ -f /local/setup-nfs-done ] && echo 1 || echo 0")" != "1" ]; do
    sleep 1
done

# NFS clients setup: use the publicly-routable IP addresses for both the
# server and the clients to avoid interference with the experiment.
rcnfs_ip=`ssh rcnfs "hostname -i"`
mkdir $SHAREDHOME_DIR; mount -t nfs4 $rcnfs_ip:$RCNFS_SHAREDHOME_EXPORT_DIR $SHAREDHOME_DIR
echo "$rcnfs_ip:$RCNFS_SHAREDHOME_EXPORT_DIR $SHAREDHOME_DIR nfs4 rw,sync,hard,intr,addr=`hostname -i` 0 0" >> /etc/fstab

mkdir $DATASETS_DIR; mount -t nfs4 $rcnfs_ip:$RCNFS_DATASETS_EXPORT_DIR $DATASETS_DIR
echo "$rcnfs_ip:$RCNFS_DATASETS_EXPORT_DIR $DATASETS_DIR nfs4 rw,sync,hard,intr,addr=`hostname -i` 0 0" >> /etc/fstab

# Move user accounts onto the shared directory. rcmaster is responsible for
# physically moving user files to shared folder. All other nodes just change
# the home directory in /etc/passwd. This avoids the problem of all servers
# trying to move files to the same place at the same time.
if [ $(hostname --short) == "rcmaster" ]
then
  for user in $(ls /users/)
  do
    usermod --move-home --home $SHAREDHOME_DIR/$user $user
  done
else
  for user in $(ls /users/)
  do
    usermod --home $SHAREDHOME_DIR/$user $user
  done
fi

# Setup password-less ssh between nodes
if [ $(hostname --short) == "rcmaster" ]
then
  for user in $(ls $SHAREDHOME_DIR)
  do
      ssh_dir=$SHAREDHOME_DIR/$user/.ssh
      /usr/bin/geni-get key > $ssh_dir/id_rsa
      chmod 600 $ssh_dir/id_rsa
      chown $user: $ssh_dir/id_rsa
      ssh-keygen -y -f $ssh_dir/id_rsa > $ssh_dir/id_rsa.pub
      cat $ssh_dir/id_rsa.pub >> $ssh_dir/authorized_keys
      chmod 644 $ssh_dir/authorized_keys
  done
fi

# Do some specific rcmaster setup here
if [ $(hostname --short) == "rcmaster" ]
then
  # Make tmux start automatically when logging into rcmaster
  cat >> etc/profile <<EOM

if [[ -z "\$TMUX" ]] && [ "\$SSH_CONNECTION" != "" ]
then
  tmux attach-session -t ssh_tmux || tmux new-session -s ssh_tmux
fi
EOM
fi

# Create backup.log file on each of the rc servers
if [[ $(hostname --short) =~ ^rc[0-9][0-9]$ ]]
then
  chmod g=u $RCXX_BACKUP_DIR
  > $RCXX_BACKUP_DIR/backup.log
  chmod g=u $RCXX_BACKUP_DIR/backup.log
fi

# Do user-specific setup here only on rcmaster (since user's home folder is on
# a shared filesystem.
if [ $(hostname --short) == "rcmaster" ]
then
  sudo --login -u $USERNAME $SCRIPTPATH/user-setup.sh $RCXX_BACKUP_DIR
fi
