#!/usr/bin/bash

### This script creates a Proxmox template from a cloud image

### NOTE: This is kept just as a reference since that's how I've started the process
### This was transformed into a Ansible role, which is much more flexible and easier to maintain

# Set the VM ID to operate on
VMID=9000

# Choose a name for the VM
#TEMPLATE_NAME=UbuntuNobleCloudInit
TEMPLATE_NAME=Debian12CloudInit

# Choose the disk image to import
#IMAGE_DOWNLOAD_URI=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
IMAGE_DOWNLOAD_URI=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
DOWNLOAD_PATH=/home/tl/Downloads

#IMAGE=noble-server-cloudimg-amd64.img
IMAGE=debian-12-genericcloud-amd64.qcow2
IMAGE_PATH=$DOWNLOAD_PATH/$IMAGE

# Choose network interface
NET_IFACE=vmbr0v100

# If you're using ZFS, set this to true (otherwise fallbacks to lvm)
USE_ZFS=false

function disk() {
	[ $USE_ZFS = true ] && echo "local-zfs" || echo "local-lvm"
}

DISK=`disk`

[ ! -f $IMAGE_PATH ] && wget -P $DOWNLOAD_PATH $IMAGE_DOWNLOAD_URI

## Disabling this for now, as we can actually use cloudinit to install packages and enable qemu-guest-agent
#apt update -y && apt install libguestfs-tools -y
#virt-customize -a $IMAGE_PATH --install qemu-guest-agent --run-command 'systemctl enable qemu-guest-agent.service'

# Create the VM
qm create $VMID --memory 2048 --core 2 --name $TEMPLATE_NAME --net0 virtio,bridge=$NET_IFACE
# Set the OSType to Linux Kernel 6.x
qm set $VMID --ostype l26
# Import the disk
qm importdisk $VMID $IMAGE_PATH $DISK
# Attach disk to scsi bus
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $DISK:vm-$VMID-disk-0
# Set scsi disk as boot device
qm set $VMID --boot c --bootdisk scsi0
# Create and attach cloudinit drive
qm set $VMID --ide2 $DISK:cloudinit
# Set serial console, which is needed by OpenStack/Proxmox
qm set $VMID --serial0 socket --vga serial0
# Enable Qemu Guest Agent
qm set $VMID --agent enabled=1 # optional but recommened

# Start the VM at boot
qm set $VMID --onboot 1

## Should we add user/ssh config at this point?
## ssh-keys should be added on cloud-init config

# Convert into template
qm template $VMID

