#!/bin/bash
# Script for setting up the cluster after initial booting and configuration by
# CloudLab.

# Get the absolute path of this script on the system.
SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

# Echo all the args so we can see how this script was invoked in the logs.
echo -e "\n===== SCRIPT PARAMETERS ====="
echo $@
echo

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
# Whether or not to install additional software beyond the basics.
INSTALL_SOFTWARE=$5
# Number of RCXX machines in the cluster.
NUM_RCNODES=$6
# Hardware type that we're running on.
HARDWARE_TYPE=$7
# Whether or not to install DPDK on the machine
INSTALL_DPDK=$8

echo "RCNFS_SHAREDHOME_EXPORT_DIR: $RCNFS_SHAREDHOME_EXPORT_DIR" >> /local/parameters.cfg
echo "RCNFS_DATASETS_EXPORT_DIR: $RCNFS_DATASETS_EXPORT_DIR" >> /local/parameters.cfg
echo "RCXX_BACKUP_DIR: $RCXX_BACKUP_DIR" >> /local/parameters.cfg
echo "USERNAME: $USERNAME" >> /local/parameters.cfg
echo "INSTALL_SOFTWARE: $INSTALL_SOFTWARE" >> /local/parameters.cfg
echo "NUM_RCNODES: $NUM_RCNODES" >> /local/parameters.cfg
echo "HARDWARE_TYPE: $HARDWARE_TYPE" >> /local/parameters.cfg
echo "INSTALL_DPDK: $INSTALL_DPDK" >> /local/parameters.cfg

# === Paarameters decided by this script. ===
# Directory where the NFS partition will be mounted on NFS clients
SHAREDHOME_DIR=/shome
# Directory where NFS shared datasets will be mounted on NFS clients
DATASETS_DIR=/datasets

# Other variables
KERNEL_RELEASE=`uname -r`
UBUNTU_RELEASE=`lsb_release --release | awk '{print $2}'`

# === Here goes configuration that's performed on every boot. ===
if [[ $(hostname --short) =~ ^rc[0-9][0-9]$ ]]
then
  echo -e "\n===== DISABLE HYPERTHREADING ====="
  # Disabled hyperthreading by forcing cores 8 .. 15 offline. This is a
  # performance optimization for RAMCloud. It is not necessary to do this to run
  # RAMCloud.
  NUM_CPUS=$(lscpu | grep '^CPU(s):' | awk '{print $2}') 
  for N in $(seq $((NUM_CPUS/2)) $((NUM_CPUS-1))); do
    echo 0 > /sys/devices/system/cpu/cpu$N/online
  done

  echo -e "\n===== CHANGE CPU POWER GOVERNOR ====="
  # Set CPU scaling governor to "performance"
  cpupower frequency-set -g performance
fi

# Check if we've already complete setup before. If so, the buck stops here.
# Everything above will be executed on every boot. Everything below this will be
# executed on the first boot only. Therefore any soft state that's reset after a
# reboot should be set above. If the soft state can only be set after setup,
# then it should go inside this if statement.
if [ -f /local/setup_done ]
then
  # Post-restart configuration to do for rc machines.
  if [[ $(hostname --short) =~ ^rc[0-9][0-9]$ ]]
  then
    echo -e "\n===== MOUNT HUGEPAGES ====="
    # Mount hugepages, disable THP(Transparent Hugepages) daemon
    # I believe this must be done only after setting the hugepagesz kernel
    # parameter and rebooting.
    hugeadm --create-mounts --thp-never
  fi

  exit 0
fi

# === Here goes configuration that happens once on the first boot. ===

# === Software dependencies that need to be installed. ===
# Common utilities
echo -e "\n===== INSTALLING COMMON UTILITIES ====="
apt-get update
apt-get --assume-yes install mosh vim tmux pdsh tree axel htop ctags cscope cmake clang gnuplot python-pip
# NFS
echo -e "\n===== INSTALLING NFS PACKAGES ====="
apt-get --assume-yes install nfs-kernel-server nfs-common
# Maven
echo -e "\n===== INSTALLING MAVEN PACKAGES ====="
apt-get --assume-yes install maven

if [ "$INSTALL_SOFTWARE" == "True" ]
then
  # Java
  echo -e "\n===== INSTALLING JAVA ====="
  if [ "$UBUNTU_RELEASE" == "14.04" ]
  then
    apt-get install --assume-yes software-properties-common
    add-apt-repository --yes ppa:webupd8team/java
    apt-get update
    echo oracle-java8-installer shared/accepted-oracle-license-v1-1 select true | sudo /usr/bin/debconf-set-selections
    apt-get install --assume-yes oracle-java8-installer
  elif [ "$UBUNTU_RELEASE" == "16.04" ]
  then
    # This works with Ubuntu 16.04.
    apt-get --assume-yes install default-jre
  fi

  echo -e "\n===== INSTALLING VARIOUS OTHER SOFTWARE ====="
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
  # Mellanox OFED (Note: Reboot required after installing this).
  apt-get --assume-yes install tk8.4 chrpath graphviz tcl8.4 libgfortran3 dkms \
        tcl pkg-config gfortran curl libnl1 quilt dpatch swig tk python-libxml2

  if [ "$INSTALL_DPDK" == "True" ]
  then
    echo -e "\n===== INSTALLING MELLANOX OFED ====="
    OS_VER="ubuntu`lsb_release -r | cut -d":" -f2 | xargs`"
    MLNX_OFED="MLNX_OFED_LINUX-3.4-1.0.0.0-$OS_VER-x86_64"
    axel -n 8 -q http://www.mellanox.com/downloads/ofed/MLNX_OFED-3.4-1.0.0.0/$MLNX_OFED.tgz
    tar xzf $MLNX_OFED.tgz
    ./$MLNX_OFED/mlnxofedinstall --force --without-fw-update >> ./$MLNX_OFED/install.log
  fi
fi

# === Configuration settings for all machines ===
# Make vim the default editor.
cat >> /etc/profile.d/etc.sh <<EOM
export EDITOR=vim
EOM
chmod ugo+x /etc/profile.d/etc.sh

# Disable user prompting for sshing to new hosts.
cat >> /etc/ssh/ssh_config <<EOM
    StrictHostKeyChecking no
EOM

# RCNFS specific setup here. RCNFS exports RCNFS_SHAREDHOME_EXPORT_DIR (used as
# a shared home directory for all users), and also RCNFS_DATASETS_EXPORT_DIR
# (mount point for CloudLab datasets to which cluster nodes need shared access). 
if [ $(hostname --short) == "rcnfs" ]
then
  echo -e "\n===== SETTING UP NFS EXPORTS ON RCNFS ====="
  # Make the file system rwx by all.
  chmod 777 $RCNFS_SHAREDHOME_EXPORT_DIR
  
  # The datasets directory only exists if the user is mounting remote datasets.
  if [ ! -e "$RCNFS_DATASETS_EXPORT_DIR" ]
  then
    echo -e "\nNOTICE: Creating directory $RCNFS_DATASETS_EXPORT_DIR"
    mkdir $RCNFS_DATASETS_EXPORT_DIR
  fi

  chmod 777 $RCNFS_DATASETS_EXPORT_DIR

  # Remove the lost+found folder in the shared home directory
  #rm -rf $RCNFS_SHAREDHOME_EXPORT_DIR/*

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

  # Use the existence of this file as a flag for other servers to know that
  # RCNFS is finished with its setup.
  > /local/setup-nfs-done
fi

# Wait until nfs is properly set up. 
echo -e "\n===== WAITING FOR NFS SERVER TO COMPLETE SETUP ====="
while [ "$(ssh rcnfs "[ -f /local/setup-nfs-done ] && echo 1 || echo 0")" != "1" ]; do
  sleep 1
done

# NFS clients setup (all servers are NFS clients).
echo -e "\n===== SETTING UP NFS CLIENT ====="
#rcnfs_rclan_ip=`grep "rcnfs-rclan" /etc/hosts | cut -d$'\t' -f1`
#my_rclan_ip=`grep "$(hostname --short)-rclan" /etc/hosts | cut -d$'\t' -f1`
#mkdir $SHAREDHOME_DIR; mount -t nfs4 $rcnfs_rclan_ip:$RCNFS_SHAREDHOME_EXPORT_DIR $SHAREDHOME_DIR
#echo "$rcnfs_rclan_ip:$RCNFS_SHAREDHOME_EXPORT_DIR $SHAREDHOME_DIR nfs4 rw,sync,hard,intr,addr=$my_rclan_ip 0 0" >> /etc/fstab
#mkdir $DATASETS_DIR; mount -t nfs4 $rcnfs_rclan_ip:$RCNFS_DATASETS_EXPORT_DIR $DATASETS_DIR
#echo "$rcnfs_rclan_ip:$RCNFS_DATASETS_EXPORT_DIR $DATASETS_DIR nfs4 rw,sync,hard,intr,addr=$my_rclan_ip 0 0" >> /etc/fstab

rcnfs_ctrl_ip=`ssh rcnfs "hostname -i"` 
my_ctrl_ip=`hostname -i` 
mkdir $SHAREDHOME_DIR; mount -t nfs4 $rcnfs_ctrl_ip:$RCNFS_SHAREDHOME_EXPORT_DIR $SHAREDHOME_DIR
echo "$rcnfs_ctrl_ip:$RCNFS_SHAREDHOME_EXPORT_DIR $SHAREDHOME_DIR nfs4 rw,sync,hard,intr,addr=$my_ctrl_ip 0 0" >> /etc/fstab
mkdir $DATASETS_DIR; mount -t nfs4 $rcnfs_ctrl_ip:$RCNFS_DATASETS_EXPORT_DIR $DATASETS_DIR
echo "$rcnfs_ctrl_ip:$RCNFS_DATASETS_EXPORT_DIR $DATASETS_DIR nfs4 rw,sync,hard,intr,addr=$my_ctrl_ip 0 0" >> /etc/fstab

# Change default shell to bash for all users on all machines
echo -e "\n===== CHANGE USERS SHELL TO BASH ====="
for user in $(ls /users/)
do
  chsh -s /bin/bash $user
done

# Move user accounts onto the shared directory. rcmaster is responsible for
# physically moving user files to shared folder. All other nodes just change
# the home directory in /etc/passwd. This avoids the problem of all servers
# trying to move files to the same place at the same time.
if [ $(hostname --short) == "rcnfs" ]
then
  echo -e "\n===== MOVING USERS HOME DIRECTORY TO NFS HOME ====="
  for user in $(ls /users/)
  do
    # Ensure that no processes by that user are running.
    pkill -u $user
    usermod --move-home --home $SHAREDHOME_DIR/$user $user
  done
else
  echo -e "\n===== SETTING USERS HOME DIRECTORY TO NFS HOME ====="
  for user in $(ls /users/)
  do
    # Ensure that no processes by that user are running.
    pkill -u $user
    usermod --home $SHAREDHOME_DIR/$user $user
  done
fi

# Setup password-less ssh between nodes
if [ $(hostname --short) == "rcnfs" ]
then
  echo -e "\n===== SETTING UP SSH BETWEEN NODES ====="
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

# Add machines on control network to /etc/hosts
echo -e "\n===== ADDING CONTROL NETWORK HOSTS TO /ETC/HOSTS ====="
hostArray=("rcmaster" "rcnfs")
for i in $(seq 1 $NUM_RCNODES)
do
  host=$(printf "rc%02d" $i)
  hostArray=("${hostArray[@]}" "$host")
done

for host in ${hostArray[@]}
do
  while ! ssh $host "hostname -i"
  do
    sleep 1
    echo "Waiting for $host to come up..."
  done
  echo $(ssh $host "hostname -i")" "$host-ctrl >> /etc/hosts
done

# RCMaster specific configuration.
if [ $(hostname --short) == "rcmaster" ]
then
  echo -e "\n===== SETTING UP AUTOMATIC TMUX ON RCMASTER ====="
  # Make tmux start automatically when logging into rcmaster
  cat >> /etc/profile.d/etc.sh <<EOM

if [[ -z "\$TMUX" ]] && [ "\$SSH_CONNECTION" != "" ]
then
  tmux attach-session -t ssh_tmux || tmux new-session -s ssh_tmux
fi
EOM
fi

# RCNFS specific configuration.
if [ $(hostname --short) == "rcnfs" ]
then
  if [ "$INSTALL_SOFTWARE" == "True" ]
  then
    echo -e "\n===== RUNNING USER-SETUP SCRIPT ====="
    # Execute all user-specific setup in user's shared folder using rcnfs.
    # This is to try and reduce network traffic during builds.
    sudo --login -u $USERNAME $SCRIPTPATH/user-setup.sh $RCXX_BACKUP_DIR $HARDWARE_TYPE $INSTALL_DPDK
  fi
fi

# RCXX machines specific configuration.
if [[ $(hostname --short) =~ ^rc[0-9][0-9]$ ]]
then
  echo -e "\n===== CREATING BACKUP.LOG ====="
  # Create backup.log file on each of the rc machines (used by RAMCloud backups
  # to store recovery segments).
  chmod g=u $RCXX_BACKUP_DIR
  > $RCXX_BACKUP_DIR/backup.log
  chmod g=u $RCXX_BACKUP_DIR/backup.log

  # Set unlimited size for locked-in pages to allow RAMCloud to lock-in as much
  # memory as it needs (to prevent the OS from swapping pages to disk and
  # impairing performance). This is required when running RAMCloud master
  # servers with large amounts of allocated memory (approaching the memory
  # limits of the machines).
  cat >> /etc/security/limits.conf <<EOM
* soft memlock unlimited
* hard memlock unlimited
EOM

  if [ "$INSTALL_SOFTWARE" == "True" ] && [ "$INSTALL_DPDK" == "True" ]
  then
    # Enable cpuset functionality on rc machines. This is also optional, RAMCloud
    # will work without this. TODO: Check whether or not this is actually
    # necessary after installing the cpuset package on these machines.
    echo -e "\n===== ENABLE CPUSETS ====="
    if [ ! -d "/sys/fs/cgroup/cpuset" ]; then
      mount -t tmpfs cgroup_root /sys/fs/cgroup
      mkdir /sys/fs/cgroup/cpuset
      mount -t cgroup cpuset -o cpuset /sys/fs/cgroup/cpuset/
    fi

    echo -e "\n===== SET KERNEL BOOT PARAMETERS ====="
    # Enable hugepage support for DPDK: 
    # http://dpdk.org/doc/guides/linux_gsg/sys_reqs.html
    # The changes will take effects after reboot. m510 is not a NUMA machine.
    # Reserve 1GB hugepages via kernel boot parameters
    kernel_boot_params="default_hugepagesz=1G hugepagesz=1G hugepages=8"

    # Disable intel_idle driver to gain control over C-states (this driver will
    # most ignore any other BIOS setting and kernel parameters). Then limit
    # available C-states to C1 by "idle=halt". Or more aggressively, keep
    # processors in C0 even when they are idle by "idle=poll".
    kernel_boot_params+=" intel_idle.max_cstate=0 idle=poll"

    # Isolate certain cpus from kernel scheduling and put them into full
    # dynticks mode (need reboot to take effect)
    #isolcpus="2"
    #kernel_boot_params+=" isolcpus=$isolcpus nohz_full=$isolcpus rcu_nocbs=$isolcpus"

    # Enable perf taken branch stack sampling (i.e. "perf record -b ...")
    #kernel_boot_params+=" lapic"

    # Update GRUB with our kernel boot parameters
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$kernel_boot_params /" /etc/default/grub
    update-grub
    # TODO: Verify that these options actually work as expected.
    # http://www.breakage.org/2013/11/15/nohz_fullgodmode/

    # Note: We will reboot the rc machines at the end of this script so that the
    # kernel parameter changes can take effect.
  fi
fi

# Mark that setup has finished. This script is actually run again after a
# reboot, so we need to mark that we've already setup this machine and catch
# this flag after a reboot to prevent ourselves from re-running everything.
> /local/setup_done

# Reboot required on rc machines for kernel parameter changes to take effect.
if [[ $(hostname --short) =~ ^rc[0-9][0-9]$ ]]
then
  if [ "$INSTALL_SOFTWARE" == "True" ] && [ "$INSTALL_DPDK" == "True" ]
  then
    echo -e "\n===== REBOOTING ====="
    reboot
  fi
fi
