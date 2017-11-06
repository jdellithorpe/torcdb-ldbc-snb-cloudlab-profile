#!/bin/bash

# === Parameters decided by profile.py ===
# RCNFS partition that will be exported to clients by the NFS server (rcnfs).
NFS_EXPORT_DIR=$1
# RC server partition that will be used for RAMCloud backups.
RC_BACKUP_DIR=$2

# === Paarameters decided by this script. ===
# Directory where the NFS partition will be mounted on NFS clients
SHARED_DIR=/shome

# Other variables
KERNEL_RELEASE=`uname -r`

# === Software dependencies that need to be installed. ===
# Common utilities
apt-get update
apt-get --assume-yes install mosh vim tmux pdsh tree axel
# NFS
apt-get --assume-yes install nfs-kernel-server nfs-common
# Java
apt-get --assume-yes install openjdk-8-jdk maven
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

# Set some environment variables
cat >> /etc/profile <<EOM

export JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk-amd64
export EDITOR=vim
EOM

# Disable user prompting for connecting to unseen hosts.
cat >> /etc/ssh/ssh_config <<EOM
    StrictHostKeyChecking no
EOM

# Setup password-less ssh between nodes
for user in $(ls /users/)
do
    ssh_dir=/users/$user/.ssh
    /usr/bin/geni-get key > $ssh_dir/id_rsa
    chmod 600 $ssh_dir/id_rsa
    chown $user: $ssh_dir/id_rsa
    ssh-keygen -y -f $ssh_dir/id_rsa > $ssh_dir/id_rsa.pub
    cat $ssh_dir/id_rsa.pub >> $ssh_dir/authorized_keys
    chmod 644 $ssh_dir/authorized_keys
done

# If this server is the RCNFS server, then NFS export the local partition and
# start the NFS server. Otherwise, wait for the RCNFS server to complete its
# setup and then mount the partition. 
if [ $(hostname --short) == "rcnfs" ]
then
  # Make the file system rwx by all.
  chmod 777 $NFS_EXPORT_DIR

  # Make the NFS exported file system readable and writeable by all hosts in the
  # system (/etc/exports is the access control list for NFS exported file
  # systems, see exports(5) for more information).
	echo "$NFS_EXPORT_DIR *(rw,sync,no_root_squash)" >> /etc/exports

  # Start the NFS service.
  /etc/init.d/nfs-kernel-server start

  # Give it a second to start-up
  sleep 2

  > /local/setup-nfs-done
else
  # Wait until nfs is properly set up
  while [ "$(ssh rcnfs "[ -f /local/setup-nfs-done ] && echo 1 || echo 0")" != "1" ]; do
      sleep 1
  done

	# NFS clients setup: use the publicly-routable IP addresses for both the
  # server and the clients to avoid interference with the experiment.
	rcnfs_ip=`ssh rcnfs "hostname -i"`
	mkdir $SHARED_DIR; mount -t nfs4 $rcnfs_ip:$NFS_EXPORT_DIR $SHARED_DIR
	echo "$rcnfs_ip:$NFS_EXPORT_DIR $SHARED_DIR nfs4 rw,sync,hard,intr,addr=`hostname -i` 0 0" >> /etc/fstab
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
  
  # Checkout TorcDB and LDBC SNB implementation
  cd /local
  git clone https://github.com/PlatformLab/TorcDB.git
  git clone https://github.com/PlatformLab/ldbc-snb-impls.git

  # Checkout and setup RAMCloud
  cd $SHARED_DIR
  git clone https://github.com/jdellithorpe/RAMCloud.git
  cd RAMCloud
  git submodule update --init --recursive
  ln -s ../../hooks/pre-commit .git/hooks/pre-commit

	# Construct localconfig.py for this cluster setup.
	cd scripts/
	> localconfig.py

  # Set the backup file location
  echo "default_disk1 = '-f /local/rcbackup/backup.log'" >> localconfig.py
	# First, collect rc server names and IPs in the cluster.
	while read -r ip linkin linkout hostname
	do 
		if [[ $hostname =~ ^rc[0-9]+$ ]] 
		then
			rcnames=("${rcnames[@]}" "$hostname") 
		fi 
	done < /etc/hosts
  IFS=$'\n' rcnames=($(sort <<<"${rcnames[*]}"))
  unset IFS

	echo -n "hosts = [" >> localconfig.py
	for i in $(seq ${#rcnames[@]})
	do
    hostname=${rcnames[$(( i - 1 ))]}
    ipaddress=`getent hosts $hostname | awk '{ print $1 }'`
    tuplestr="(\"$hostname\", \"$ipaddress\", $i)"
		if [[ $i == ${#rcnames[@]} ]]
		then
			echo "$tuplestr]" >> localconfig.py
    else 
			echo -n "$tuplestr, " >> localconfig.py
		fi
	done

  ## Make RAMCloud
  cd ../
  make -j8 DEBUG=no
fi

# Create backup.log file on each of the rc servers
if [[ $(hostname --short) =~ ^rc[0-9][0-9]$ ]]
then
  > $RC_BACKUP_DIR/backup.log
fi
