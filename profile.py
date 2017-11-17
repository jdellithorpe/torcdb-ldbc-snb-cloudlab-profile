"""
CloudLab profile for allocating a cluster of machines for running LDBC SNB
experiments against TorcDB running on RAMCloud. This profile is currently
written specifically for CloudLab Utah m510 machines, although may be extended
in the future to work on other hardware types as well. 

Since TorcDB uses RAMCloud as its storage engine, the cluster is setup as a
RAMCloud cluster. The "rcmaster" node is intended to be used for launching and
orchestrating RAMCloud instances and LDBC SNB workloads, and the "rcnfs" node
supports an NFS shared home directory for all users at /shome. The "rcnfs" node
also exports access to any CloudLab datasets that were specified at
configuration time. These datasets are mounted on /mnt/$dataset-name on all
nodes in the cluster. Lastly, the "rcXX" machines are intended for running
RAMCloud instances, workload clients, etc. 

During configuration, the user must specify their username as a parameter. All
software, including RAMCloud, TorcDB, and LDBC SNB are downloaded, compiled,
and configured for that specific user in their home directory. This is for the
user's convenience (versus installing all software system-wide), as this likely
matches the environment one would have when working in their own clusters. It's
also for experiment instantiation speed, since installing software for all
users would take too long and generally not needed.

Instructions:
To startup a RAMCloud cluster:
1) SSH into the "rcmaster" node.
2) First run `/local/repository/cluster-health-check.sh` to see if there are
   any problematic nodes in the cluster. If there are, jot these down.
3) cd ~/RAMCloud
4) If there are any failing nodes, open up `./scripts/localconfig.py` and
   remove those nodes from the `hosts` array.
5) Start up a RAMCloud cluster with whatever configuration parameters you
   desire. Here's an example for a cluster of 8 servers running basic+udp
   transport.
./scripts/cluster.py -s 8 -r 3 --transport=basic+udp --masterArgs="--totalMasterMemory 50000 --segmentFrames 20000" --verbose --shareHosts

TODO: Add instructions for running TorcDB and LDBC SNB.
"""

import re

import geni.aggregate.cloudlab as cloudlab
import geni.portal as portal
import geni.rspec.pg as pg
import geni.urn as urn

# Allows for general parameters like disk image to be passed in. Useful for
# setting up the cloudlab dashboard for this profile.
pc = portal.Context()

# The possible set of base disk-images that this cluster can be booted with.
# The second field of every tupule is what is displayed on the cloudlab
# dashboard.
images = [ ("UBUNTU14-64-STD", "Ubuntu 14.04") ]

# The possible set of node-types this cluster can be configured with. Currently 
# only m510 machines are supported.
hardware_types = [ ("m510", "m510 (CloudLab Utah, Intel Xeon-D)") ]

# Default the disk image to 64-bit Ubuntu 15.04
pc.defineParameter("image", "Disk Image",
        portal.ParameterType.IMAGE, images[0], images,
        "Specify the base disk image that all the nodes of the cluster " +\
        "should be booted with.")

pc.defineParameter("hardware_type", "Hardware Type",
                   portal.ParameterType.NODETYPE,
                   hardware_types[0], hardware_types)

pc.defineParameter("username", "Username", 
        portal.ParameterType.STRING, "", None,
        "Username for which all user-specific software will be configured.")

# Default the cluster size to 5 nodes (minimum requires to support a 
# replication factor of 3 and an independent coordinator). 
pc.defineParameter("num_rcnodes", "RAMCloud Cluster Size",
        portal.ParameterType.INTEGER, 5, [],
        "Specify the number of RAMCloud servers (rcXX machines). For a " +\
        "replication factor " +\
        "of 3 and without machine sharing enabled, the minimum number of " +\
        "RAMCloud servers is 5 (1 master " +\
        "+ 3 backups + 1 coordinator). Note that the total " +\
        "number of servers in the experiment will be this number + 2 (one " +\
        "additional server for rcmaster, and one for rcnfs). To check " +\
        "availability of nodes, visit " +\
        "\"https://www.cloudlab.us/cluster-graphs.php\"")

pc.defineParameter("dataset_urns", "Datasets", 
        portal.ParameterType.STRING, "", None,
        "Space separated list of datasets to mount. All datasets are " +\
        "first mounted on rcnfs at /remote, and then mounted via NFS " +\
        "on all other nodes at /mnt/dataset-name")

params = pc.bindParameters()

# Create a Request object to start building the RSpec.
request = pc.makeRequestRSpec()

# Create a local area network for the RAMCloud cluster.
rclan = request.LAN("rclan")
rclan.best_effort = True
rclan.vlan_tagging = True
rclan.link_multiplexing = True

# Create a special network for connecting datasets to rcnfs.
dslan = request.LAN("dslan")
dslan.best_effort = True
dslan.vlan_tagging = True
dslan.link_multiplexing = True

# Create array of the requested datasets
dataset_urns = params.dataset_urns.split(" ")

rcnfs_datasets_export_dir = "/remote"

for i in range(len(dataset_urns)):
    dataset_urn = dataset_urns[i]
    dataset_name = dataset_urn[dataset_urn.rfind("+") + 1:]
    rbs = request.RemoteBlockstore(
            "dataset%02d" % (i + 1), 
            rcnfs_datasets_export_dir + "/" + dataset_name, 
            "if1")
    rbs.dataset = dataset_urn
    dslan.addInterface(rbs.interface)

# Setup node names so that existing RAMCloud scripts can be used on the
# cluster.
hostnames = ["rcmaster", "rcnfs"]
for i in range(params.num_rcnodes):
    hostnames.append("rc%02d" % (i + 1))

rcnfs_sharedhome_export_dir = "/local/nfs"
rcxx_backup_dir = "/local/rcbackup"

# Setup the cluster one node at a time.
for host in hostnames:
    node = request.RawPC(host)
    node.hardware_type = params.hardware_type
    node.disk_image = urn.Image(cloudlab.Utah, "emulab-ops:%s" % params.image)

    node.addService(pg.Execute(shell="sh", 
        command="sudo /local/repository/setup.sh %s %s %s %s" % \
        (rcnfs_sharedhome_export_dir, rcnfs_datasets_export_dir, 
        rcxx_backup_dir, params.username)))

    # Add this node to the client LAN.
    rclan.addInterface(node.addInterface("if1"))

    if host == "rcnfs":
        # Ask for a 200GB file system to export via NFS
        nfs_bs = node.Blockstore(host + "nfs_bs", rcnfs_sharedhome_export_dir)
        nfs_bs.size = "200GB"
        # Add this node to the dataset blockstore LAN.
        dslan.addInterface(node.addInterface("if2"))

    pattern = re.compile("^rc[0-9][0-9]$")
    if pattern.match(host):
        # Ask for a 200GB file system for RAMCloud backups
        backup_bs = node.Blockstore(host + "backup_bs", rcxx_backup_dir)
        backup_bs.size = "200GB"

# Generate the RSpec
pc.printRequestRSpec(request)
