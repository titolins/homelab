# Home cluster setup

## About
I screwed up my old proxmox setup during upgrade, and since I don't really have backups or anything in place I've decided to organize things a bit.
The idea is to use something to automate the provisioning of my vm's. I had already a really basic ansible setup, but there were a lot of manual, undocumented steps involved.

Also, the idea this time around is to provision vm's and setup a k3s cluster instead of individual vms/lxc per app.

## Apps
My proxmox setup involves of a media box plus some other network utilities:
- Sonarr
- Radarr
- Jackett
- Deluge
- Jellyfin (with HW encoding)
- Unifi controller
---
Things to be added on top of that:
- home assistant
- pi-hole/adguard (might be installed directly on my opnsense box though)
- ...

## Requirements
- [sops](https://github.com/getsops/sops)
- [ansible](https://docs.ansible.com/ansible/latest/index.html)
- [task](https://taskfile.dev/)

## Ansible
- Running ansible will create a template based on the chosen cloud-init image and create the VM's
  provisioned in the pve host

### Configuration
- Some part of the configuration is encrypted using sops
- The entire structure can be found at `ansible/roles/vms/defaults/main.yaml`
- This is split into two host variables file (since for now I just need them for a single host):
    - `ansible/host_vars/pve.sops.yaml` <-- encrypted by sops, gets decrypted by ansible at runtime
    - `ansible/host_vars/pve.yaml`
- To edit the encrypted sops file on the fly, you can just do `sops ansible/host_vars/pve.sops.yaml`
    - This opens a temp vim buffer with fully decrypted values, which after saved gets encrypted before replacing the sops file

#### Sops
- To use stops, there's a few things that needed to be done:
    - Generate a key using [age](https://github.com/FiloSottile/age): `age-keygen -o ~/.config/sops/age/keys.txt`
    - Set `SOPS_AGE_KEY_FILE` to point to the path where you've saved the key (in the keygen command above)
    - Set `SOPS_AGE_RECIPIENT` to the public key value of the key generated above

### Running
- There's a provided task file just to make it a bit easier to run the playbook from the root dir
- After installing task, just run `task ansible-playbook` to start running it

## Manual steps (PVE)
- Some manual steps are still required for initial setup of the proxmox node

### VLAN
- Setup static ip interface for pve and bridge interface to be shared with vms
```
#/etc/network/interfaces

# 1. Add new interface with vlan (.100)
iface enp34s0.100 inet manual

## Create bridge interface for pve
auto vmbr0v100
iface vmbr0v100 inet static
        address 192.168.3.201/24
        gateway 192.168.3.1
        bridge-ports enp34s0.100
        bridge-stp off
        bridge-fd 0

# 2. Modify the existing vmbr0 interface
auto vmbr0
# a. Change from static to manual if required
iface vmbr0 inet manual
        # b. remove address and gateway in case they were added during install
        bridge-ports enp34s0
        bridge-stp off
        bridge-fd 0

## Doing the below actually leads to no connections on VMs - my guess is that this would be required for a trunk interface
        # c. add vlan related params below
        bridge-vlan-aware yes
        bridge-vids 2-4094
```

- Change root password (I just used the UI)
- Copy ssh key to server: `ssh-copy-id root@192.168.3.201`
- Configure repos
    - Disable enterprise repos:
        - `/etc/apt/sources.list.d/ceph.list`
        - `/etc/apt/sources.list.d/pve-enterprise.list`
    - Add `/etc/apt/sources.list.d/pve-no-subscription.list` if not already added
    ```
    deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
    ```

- Install `sudo` and update packages
```
apt update
apt install sudo
apt upgrade
```

- Setup privileged user
```
useradd -m -U -s /bin/bash -G root tl
passwd tl
echo "tl ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tl
mkdir /home/tl/.ssh
cp /root/.ssh/authorized_keys /home/tl/.ssh/
chown tl:tl /home/tl/.ssh/authorized_keys
```

- Added custom.conf under /etc/ssh/sshd_config.d/
```
Port 2453
PasswordAuthentication no
PermitRootLogin no
AllowUsers tl
```
- Restart `sshd`
```
systemctl restart sshd
```

- Now we should be all set to run ansible :)

#### TODO
- nvidia drivers
- cuda?
- Configure pcie-passthrough
    - https://forum.proxmox.com/threads/pci-gpu-passthrough-on-proxmox-ve-8-installation-and-configuration.130218/
    - add modules
        - `ansible/config/vfio.conf` -> `/etc/modules-load.d/`
        - update initramfs `sudo update-initramfs -u -k all`

- Use packer for template generation?

## Helpful articles
- [Considerations for a k3s node on proxmox](https://onedr0p.github.io/home-ops/notes/proxmox-considerations.html)
- [Creating a pve debian template](https://www.aidenwebb.com/posts/create-a-debian-cloud-init-template-on-proxmox/)
- [Another debian template example](https://gist.github.com/chriswayg/b6421dcc69cb3b7e41f2998f1150e1df#steps-for-creating-a-debian-10-cloud-template)
- [Creating a pve ubuntu template + installing packages on cloudinit image](https://cloudinit.readthedocs.io/en/latest/reference/examples.htmlrksie1988/proxmox-template-with-cloud-image-and-cloud-init-3660)
- [Proxmox Cloud-init image using ansible](https://www.timatlee.com/post/proxmox-cloudinit-image-ansible/)
- [Cloud Config Examples](https://cloudinit.readthedocs.io/en/latest/reference/examples.html)
- [How to use cloud config for your initial server setup](https://www.digitalocean.com/community/tutorials/how-to-use-cloud-config-for-your-initial-server-setup)
- [Gist for template image on ansible](https://gist.github.com/timatlee/855fab414c85a6881ee7b196476a9d60)
- [PVE Cloudinit ansible role](https://github.com/Gurdt55lol/Ansible_create_Ubuntu-CloudInit_with_Proxmox)
- [Remove proxmox subscription notice](https://johnscs.com/remove-proxmox51-subscription-notice/)
- [cloud-init docs](https://cloudinit.readthedocs.io/en/latest/howto/debug_user_data.html)
- [Proxmox: Use Custom Cloud-Init File](https://github.com/chris2k20/proxmox-cloud-init)
- [Ubuntu-CloudInit-Docs](https://github.com/UntouchedWagons/Ubuntu-CloudInit-Docs)
- [Proxmox Network Configuration](https://pve.proxmox.com/wiki/Network_Configuration)
- [cloud-init unable to run on Debian 11 cloud image](https://forum.proxmox.com/threads/cloud-init-unable-to-run-on-debian-11-cloud-image.126435/page-2)
- [cloud config examples](https://cloudinit.readthedocs.io/en/20.4.1/topics/examples.html)
- [cloud init network config format v2](https://cloudinit.readthedocs.io/en/latest/reference/network-config-format-v2.html)
- [cloud init network config format v1](https://cloudinit.readthedocs.io/en/20.4.1/topics/network-config-format-v1.html)
