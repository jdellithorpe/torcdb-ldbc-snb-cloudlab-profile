"""
Allocate a cluster of CloudLab machines for running TorcDB on RAMCloud, 
specifically on CloudLab Utah m510 machines.

Instructions:
All machines will share an nfs filesystem mounted at /shome. This filesystem
is exported by a special node called `rcnfs'.

The RAMCloud repository is automatically cloned to /shome/RAMCloud, compiled,
and setup with a scripts/localconfig.py customized for the instantiated
experiment. 
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
        "Specify the number of RAMCloud servers. For a replication factor " +\
        "of 3 and without machine sharing enabled, the minimum number of " +\
        "RAMCloud servers is 5 (1 master " +\
        "+ 3 backups + 1 coordinator). Note that the total " +\
        "number of servers in the experiment will be this number + 2 (one " +\
        "additional server for rcmaster, and one for rcnfs). To check " +\
        "availability of nodes, visit " +\
        "\"https://www.cloudlab.us/cluster-graphs.php\"")

pc.defineParameter("dataset01_urn", "Dataset 01", 
        portal.ParameterType.STRING, "", None,
        "URN for a dataset to be mounted (optional). Datasets are " +\
        "mounted in /mnt/name-of-dataset")

pc.defineParameter("dataset02_urn", "Dataset 02",
        portal.ParameterType.STRING, "", None,
        "URN for a dataset to be mounted (optional). Datasets are " +\
        "mounted in /mnt/name-of-dataset")

pc.defineParameter("dataset03_urn", "Dataset 03",
        portal.ParameterType.STRING, "", None,
        "URN for a dataset to be mounted (optional). Datasets are " +\
        "mounted in /mnt/name-of-dataset")

pc.defineParameter("dataset04_urn", "Dataset 04",
        portal.ParameterType.STRING, "", None,
        "URN for a dataset to be mounted (optional). Datasets are " +\
        "mounted in /mnt/name-of-dataset")

pc.defineParameter("dataset05_urn", "Dataset 05",
        portal.ParameterType.STRING, "", None,
        "URN for a dataset to be mounted (optional). Datasets are " +\
        "mounted in /mnt/name-of-dataset")

params = pc.bindParameters()

# Create a Request object to start building the RSpec.
request = pc.makeRequestRSpec()

# Create a local area network.
rclan = request.LAN()
rclan.best_effort = True
rclan.vlan_tagging = True
rclan.link_multiplexing = True

# Create another network with which to attach the long term dataset storing the
# LDBC SNB dataset(s).
dslan = request.LAN()
dslan.best_effort = True
dslan.vlan_tagging = True
dslan.link_multiplexing = True

# Create array of the requested datasets
dataset_urns = [params.dataset01_urn, params.dataset02_urn, params.dataset03_urn,
        params.dataset04_urn, params.dataset_05_urn]

for i in range(len(dataset_urns)):
    if dataset_urns[i] != "":
        dataset_urn = dataset_urns[i]
        dataset_name = dataset_urn[dataset_urn.rfind("+") + 1:]
        rbs = request.RemoteBlockstore(
                dataset_name + "_bs", 
                "/mnt/" + dataset_name, 
                "if1")
        rbs.dataset = dataset_urn
        dslan.addInterface(rbs.interface)

# Setup node names so that existing RAMCloud scripts can be used on the
# cluster.
hostnames = ["rcmaster", "rcnfs"]
for i in range(params.num_rcnodes):
    hostnames.append("rc%02d" % (i + 1))

rcnfs_nfs_export_dir = "/local/nfs"
rcXX_backup_dir = "/local/rcbackup"

# Setup the cluster one node at a time.
for host in hostnames:
    node = request.RawPC(host)
    node.hardware_type = params.hardware_type
    node.disk_image = urn.Image(cloudlab.Utah, "emulab-ops:%s" % params.image)

    node.addService(pg.Execute(shell="sh", 
        command="sudo /local/repository/setup.sh %s %s %s" % \
        (rcnfs_nfs_export_dir, rcXX_backup_dir, params.username)))

    # Add this node to the client LAN.
    rclan.addInterface(node.addInterface("if1"))

    # Add this node to the dataset blockstore LAN.
    dslan.addInterface(node.addInterface("if2"))
        
    if host == "rcnfs":
        # Ask for a 200GB file system to export via NFS
        nfs_bs = node.Blockstore(host + "nfs_bs", rcnfs_nfs_export_dir)
        nfs_bs.size = "200GB"

    pattern = re.compile("^rc[0-9][0-9]$")
    if pattern.match(host):
        # Ask for a 200GB file system for RAMCloud backups
        backup_bs = node.Blockstore(host + "backup_bs", rcXX_backup_dir)
        backup_bs.size = "200GB"


# Generate the RSpec
pc.printRequestRSpec(request)
