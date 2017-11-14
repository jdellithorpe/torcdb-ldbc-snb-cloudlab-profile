#!/bin/bash

# cluster-health-check.sh <NUM_RCNODES> <NUM_DATASETS>
#   NUM_RCNODES: Number of rcXX nodes expected in the cluster
#   NUM_DATASETS: Number of expected mounted datasets in /mnt
#
# A simple script to do a quick check on the rcXX nodes in the cluster.
# Currently only checks:
# 1. Can you SSH into the machine?
# 2. Does the machine have the right number of mounted datasets?
# Script will report if a node fails to pass one of the tests above.

# Number of rcXX nodes there should be
NUM_RCNODES=$1
# Number of datasets that should be mounted on each machine
NUM_DATASETS=$2

for host in $(seq -f "rc%02g" 1 $NUM_RCNODES)
do
  OUTPUT=$(ssh $host "ls /mnt/ | wc -l" 2>/dev/null)

  if [[ $? != 0 ]]
  then
    echo "$host not ssh'able"
  else
    if [[ $OUTPUT != $NUM_DATASETS ]]
    then
      echo "$host has only $OUTPUT out of $NUM_DATASETS datasets mounted"
    fi
  fi
done
