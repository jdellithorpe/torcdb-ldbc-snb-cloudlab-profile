#!/bin/bash

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

