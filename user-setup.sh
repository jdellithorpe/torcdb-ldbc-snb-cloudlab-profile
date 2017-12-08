#!/bin/bash
# Script for setting up software development environment for a specific user.

# Get the absolute path of this script on the system.
SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

# RC server partition that will be used for RAMCloud backups.
RCXX_BACKUP_DIR=$1

# Checkout TorcDB, RAMCloud, and related repositories
git clone https://github.com/jdellithorpe/RAMCloud.git
git clone https://github.com/PlatformLab/TorcDB.git
git clone https://github.com/ldbc/ldbc_snb_driver.git
git clone https://github.com/PlatformLab/ldbc-snb-impls.git
git clone https://github.com/PlatformLab/ldbc-snb-tools.git
git clone https://github.com/jdellithorpe/RAMCloudUtils.git
git clone https://github.com/apache/tinkerpop.git

# Compile and configure RAMCloud
cd RAMCloud
git submodule update --init --recursive
ln -s ../../hooks/pre-commit .git/hooks/pre-commit
git checkout java-transactions

make -j8 DEBUG=no

# Add path to libramcloud.so to dynamic library search path
cat >> $HOME/.bashrc <<EOM

export LD_LIBRARY_PATH=$HOME/RAMCloud/obj.java-transactions
EOM

cd bindings/java
./gradlew

mvn install:install-file -Dfile=$HOME/RAMCloud/bindings/java/build/libs/ramcloud.jar -DgroupId=edu.stanford -DartifactId=ramcloud -Dversion=1.0 -Dpackaging=jar

# Construct localconfig.py for this cluster setup.
cd $HOME/RAMCloud/scripts
> localconfig.py

# Set the backup file location
echo "default_disk1 = '-f $RCXX_BACKUP_DIR/backup.log'" >> localconfig.py

# Construct localconfig hosts array
while read -r ip hostname alias1 alias2 alias3
do 
  if [[ $hostname =~ ^rc[0-9]+-rclan$ ]] 
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

# Build TorcDB
cd $HOME/TorcDB
mvn install -DskipTests

# Build the LDBC SNB driver
cd $HOME/ldbc_snb_driver
mvn install -DskipTests

# Build the LDBC SNB implementation for TorcDB
cd $HOME/ldbc-snb-impls
mvn install -DskipTests
cd snb-interactive-torc
mvn compile assembly:single

# Build the gremlin-console for TinkerPop
cd $HOME/tinkerpop/gremlin-console
mvn install -DskipTests
