# Home cluster setup

## About
I screwed up my old proxmox setup during upgrade, and since I don't really have backups or anything in place I've decided to organize things a bit.
The idea is to use something to automate the provisioning of my vm's. I had already a really basic ansible setup, but there were a lot of manual, undocumented steps involved.

Also, the idea this time around is to provision vm's and setup a k3s cluster instead of individual vms/lxc per app.

## Structure
I didn't want to use any templates since most of them aim to provide a lot of features and it can be hard doing actually following what's going on.
That being said, now that the basic setup of the nodes is done, I've started looking back at some templates that I had seen before for some inspiration.
Two sources for that at this point are:
 - [Truxnell's awesome home-cluster](https://github.com/truxnell/home-cluster/)
 - [onedr0p's flux-cluster-template](https://github.com/onedr0p/flux-cluster-template)

## Apps
My proxmox setup includes my media box applications plus some other utilities:
- Sonarr
- Radarr
- Bazarr
- Prowlarr
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
- [fluxcd](https://fluxcd.io)

## Ansible
- Running ansible will create a template based on the chosen cloud-init image and create the VM's
  provisioned in the pve host

- Please note that I'm not a devops/sysadmin and my focus is actually learning kubernetes, not ansible
    - Ansible is here just to help me automate the configuration
    - So yeah, the ansible code is a bit of a mess
    - I'll try to improve it at some point

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

### Requirements
- Before running, you should make sure all required ansible collections / roles are installed
- To do that, just run `task ansible-requirements`

### Running
- There's a provided task file just to make it a bit easier to run the playbook from the root dir
- After installing task, there's a couple of tasks to bootstrap everything
    - The main playbook contains all steps required (apart from initial manual steps ofc)
    - But since it takes some time for cloud-init to do it's thing, running it in one go doesn't really work
    - So running `task ansible-pve` will run the playbook for the pve node only
    - This will create a vm and a container templates and provision the containers/vms defined in the host config
    - One it's finished and we can access the containers/vms via ssh, we can configure them

Note: For the vm template to be created successfuly, there's a wait for connection instruction. But since it's a new host,
ssh will prompt for host key check. To make it work, add a respective section for the host on `~/.ssh/config`:
```sshconfig
Host lxc-template
  Hostname lxc-template.{{ domain }}
  User root
  Port 22
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking accept-new # <- that tells ssh to accept new keys if none exists (so if re-provisioning the template, you should delete the old key from `~/.ssh/known_hosts`
```

## k3s
- k3s was setup using the [xanmanning.k3s](https://galaxy.ansible.com/ui/standalone/roles/xanmanning/k3s/) role
- Run `task ansible-k3s` for configuring the k3s cluster

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

## Nvidia drivers and secure boot
- Secure boot was disabled on the vms template by setting the `efidisk.pre_enrolled_keys` param to 0
- The reason for that is that installing the nvidia drivers with secure is not possible to be fully automated
    - We need to generate a MOK key to sign the modules
    - Enrolling a key on mok, however, requires rebooting and manually inserting the key password during a boot prompt
    - We've added some relevant docs on that in the helpful articles section below

## TODO
- Proper hardening
    - [CIS Debian Hardening](https://github.com/ovh/debian-cis)
    - [ansible role](https://github.com/konstruktoid/ansible-role-hardening)
    - postgres

- Use packer for template generation?
- Use terraform for actual VMs/CTs?
- Improve ansible code
- Enable secureboot?
    - See section above

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
- [proxmox helpers fork](https://github.com/aitkar/vm-lxc-config-proxmox)
- [proxmox helpers](https://github.com/tteck/Proxmox)
- [Fix debian slow ssh login on lxc proxmox](https://gist.github.com/charlyie/76ff7d288165c7d42e5ef7d304245916)
- [Using ansible to provision LXC containers](https://rymnd.net/blog/2020/ansible-pve-lxc/)
- [SSH doesn't work as expected in lxc](https://forum.proxmox.com/threads/ssh-doesnt-work-as-expected-in-lxc.54691/page-2)
- [CUDA installation guide linux](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html)
- [How to install nvidia driver with secure boot enabled](https://askubuntu.com/questions/1023036/how-to-install-nvidia-driver-with-secure-boot-enabled)
- [nvidia driver updater](https://github.com/BdN3504/nvidia-driver-update)
- [PCI/GPU Passthrough on Proxmox VE 8](https://forum.proxmox.com/threads/pci-gpu-passthrough-on-proxmox-ve-8-installation-and-configuration.130218/)
- [jellyfin nvidia hardware acceleration](https://jellyfin.org/docs/general/administration/hardware-acceleration/nvidia/)
- [The Ultimate Beginner's Guide to GPU Passthrough](https://www.reddit.com/r/homelab/comments/b5xpua/the_ultimate_beginners_guide_to_gpu_passthrough/)
