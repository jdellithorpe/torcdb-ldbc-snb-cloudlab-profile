#!/bin/bash
# Script for setting up software development environment for a specific user.

# Get the absolute path of this script on the system.
SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

# RC server partition that will be used for RAMCloud backups.
RCXX_BACKUP_DIR=$1
# Hardware type that we're running on.
HARDWARE_TYPE=$2
# Whether or not to install DPDK on the machine
INSTALL_DPDK=$3

# Checkout TorcDB, RAMCloud, and related repositories
echo -e "\n===== CLONING REPOSITORIES ====="
git clone https://github.com/jdellithorpe/RAMCloud.git
git clone https://github.com/PlatformLab/TorcDB.git
git clone https://github.com/jdellithorpe/TorcDB2.git
git clone https://github.com/ldbc/ldbc_snb_driver.git
git clone https://github.com/PlatformLab/ldbc-snb-impls.git
git clone https://github.com/jdellithorpe/ldbc-snb-tools.git
git clone https://github.com/jdellithorpe/RAMCloudUtils.git
git clone https://github.com/jdellithorpe/rcperf.git
git clone https://github.com/apache/tinkerpop.git
git clone https://github.com/jdellithorpe/config.git
git clone https://github.com/jdellithorpe/scripts.git
git clone https://github.com/jdellithorpe/torcdb-cloudlab-scripts.git
git clone https://github.com/jdellithorpe/torcdb-ldbc-snb-cloudlab-profile.git

# Compile and configure RAMCloud
echo -e "\n===== COMPILE AND CONFIGURE RAMCLOUD ====="
cd RAMCloud
git checkout torcdb-experiments
git submodule update --init --recursive
#ln -s ../../hooks/pre-commit .git/hooks/pre-commit

# Build DPDK libraries
if [ "$INSTALL_DPDK" == "True" ]; then
  if [ "$HARDWARE_TYPE" == "m510" ] || [ "$HARDWARE_TYPE" == "xl170" ]; then
    # Generate private makefile configuration
    mkdir private
    cat >>private/MakefragPrivateTop <<EOL
DEBUG := no

CCACHE := yes
LINKER := gold
DEBUG_OPT := yes

GLIBCXX_USE_CXX11_ABI := yes

DPDK := yes
DPDK_DIR := dpdk
DPDK_SHARED := no
EOL
    MLNX_DPDK=y scripts/dpdkBuild.sh
  elif [ "$HARDWARE_TYPE" == "d430" ]; then
    # Generate private makefile configuration
    mkdir private
    cat >>private/MakefragPrivateTop <<EOL
DEBUG := no

CCACHE := yes
LINKER := gold
DEBUG_OPT := yes

GLIBCXX_USE_CXX11_ABI := yes

DPDK := yes
DPDK_DIR := dpdk
DPDK_SHARED := no
EOL
    scripts/dpdkBuild.sh
  fi
else
  # Generate private makefile configuration
  mkdir private
  cat >>private/MakefragPrivateTop <<EOL
DEBUG := no
GLIBCXX_USE_CXX11_ABI := yes
EOL
fi

make -j8

# Add path to libramcloud.so to dynamic library search path
cat >> $HOME/.bashrc <<EOM

export RAMCLOUD_HOME=$HOME/RAMCloud
export NEO4J_HOME=/local/rcbackup/neo4j-enterprise-3.5.3

export LD_LIBRARY_PATH=\${RAMCLOUD_HOME}/obj.torcdb-experiments
EOM

cd bindings/java
echo -e "\n===== COMPILE AND CONFIGURE RAMCLOUD JAVA BINDINGS ====="
./gradlew

mvn install:install-file -Dfile=$HOME/RAMCloud/bindings/java/build/libs/ramcloud.jar -DgroupId=edu.stanford -DartifactId=ramcloud -Dversion=1.0 -Dpackaging=jar

# Construct localconfig.py for this cluster setup.
cd $HOME/RAMCloud/scripts
> localconfig.py

# Set the backup file location
echo "default_disks = '-f $RCXX_BACKUP_DIR/backup.log'" >> localconfig.py

# Construct localconfig hosts array
echo -e "\n===== SETUP RAMCLOUD LOCALCONFIG.PY ====="
while read -r ip hostname alias1 alias2 alias3
do 
  if [[ $hostname =~ ^rc[0-9]+-ctrl$ ]] 
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
#  ipaddress=`ssh $hostname "hostname -i"`
  tuplestr="(\"$hostname\", \"$ipaddress\", $i)"
  if [[ $i == ${#rcnames[@]} ]]
  then
    echo "$tuplestr]" >> localconfig.py
  else 
    echo -n "$tuplestr, " >> localconfig.py
  fi
done

# Build TorcDB
echo -e "\n===== BUILD TORCDB ====="
cd $HOME/TorcDB
mvn install -DskipTests

# Build TorcDB2
echo -e "\n===== BUILD TORCDB2 ====="
cd $HOME/TorcDB2
mvn install -DskipTests

# Build the LDBC SNB driver
echo -e "\n===== BUILD LDBC SNB DRIVER ====="
cd $HOME/ldbc_snb_driver
mvn install -DskipTests

# Configure the LDBC SNB driver
cp -R /local/repository/ldbc_snb_driver.conf/configuration $HOME/ldbc_snb_driver/

# Build the LDBC SNB implementation for TorcDB
echo -e "\n===== BUILD LDBC SNB IMPLS ====="
cd $HOME/ldbc-snb-impls
mvn install -DskipTests

cd $HOME/ldbc-snb-impls
cp $HOME/torcdb-cloudlab-scripts/run-query-tester.sh ./snb-interactive-tools
cp $HOME/torcdb-cloudlab-scripts/collect-query-results.sh ./snb-interactive-tools
cp $HOME/torcdb-cloudlab-scripts/parse-neo4j-run-query-tester-output.awk ./snb-interactive-tools
cp $HOME/torcdb-cloudlab-scripts/parse-torcdb-run-query-tester-output.awk ./snb-interactive-tools
cd snb-interactive-tools
mvn compile -DskipTests
cd ..
cp -r snb-interactive-tools snb-interactive-tools-neo4j-sf0001
cd snb-interactive-tools-neo4j-sf0001
sed -i "s/^dataset=.*/dataset=\"ldbc_snb_sf0001\"/g" run-query-tester.sh
sed -i "s/^dataset=.*/dataset=\"ldbc_snb_sf0001\"/g" collect-query-results.sh
sed -i "s/^db=.*/db=neo4j/g" config/querytester.properties
cd ..
cp -r snb-interactive-tools snb-interactive-tools-neo4j-sf0010
cd snb-interactive-tools-neo4j-sf0010
sed -i "s/^dataset=.*/dataset=\"ldbc_snb_sf0010\"/g" run-query-tester.sh
sed -i "s/^dataset=.*/dataset=\"ldbc_snb_sf0010\"/g" collect-query-results.sh
sed -i "s/^db=.*/db=neo4j/g" config/querytester.properties
cd ..
cp -r snb-interactive-tools snb-interactive-tools-neo4j-sf0100
cd snb-interactive-tools-neo4j-sf0100
sed -i "s/^dataset=.*/dataset=\"ldbc_snb_sf0100\"/g" run-query-tester.sh
sed -i "s/^dataset=.*/dataset=\"ldbc_snb_sf0100\"/g" collect-query-results.sh
sed -i "s/^db=.*/db=neo4j/g" config/querytester.properties
cd ..

# Build the gremlin-console for TinkerPop
echo -e "\n===== BUILD GREMLIN CONSOLE ====="
cd $HOME/tinkerpop/gremlin-console
mvn install -DskipTests

cd $HOME/ldbc-snb-impls
cp snb-interactive-torc/target/*.jar $HOME/tinkerpop/gremlin-console/target/apache-tinkerpop-gremlin-console-*-SNAPSHOT-standalone/lib
cp snb-interactive-tools/target/*.jar $HOME/tinkerpop/gremlin-console/target/apache-tinkerpop-gremlin-console-*-SNAPSHOT-standalone/lib
cp snb-interactive-core/target/*.jar $HOME/tinkerpop/gremlin-console/target/apache-tinkerpop-gremlin-console-*-SNAPSHOT-standalone/lib
cp snb-interactive-torc/scripts/ExampleGremlinSetup.sh $HOME/tinkerpop/gremlin-console/target/apache-tinkerpop-gremlin-console-*-SNAPSHOT-standalone

# Configure the machine with my personal settings
echo -e "\n===== SETUP USER CONFIG SETTINGS ====="
cd $HOME/config
git submodule update --init --recursive
./cloudlab/setup.sh

# Create cscope database *.out files for c++ source files, but also generate
# file list for java files
echo -e "\n===== CREATE CSCOPE DB FILES FOR C++ SOURCES ====="
cd $HOME
find -type l -prune -o -regex '.*\.\(cc\|h\)' -exec readlink -f {} \; > cscope.c.files
find -type l -prune -o -regex '.*\.\(java\)' -exec readlink -f {} \; > cscope.java.files
cscope -b -i cscope.c.files
