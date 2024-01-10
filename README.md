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
- To check available ansible tasks just run `task`
- The tasks prefixed with `an` are responsible for bootstrapping proxmox/k3s
    - Right now, VMs are used as k3s nodes as running k3s on LXC containers is still not properly supported
    - There's also one LXC container that gets created for hosting our postgres DB used by k3s and in the future others (e.g. homeassistant)

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
- The playbooks used to bootstrap proxmox are located in `infra/ansible/playbooks`
    - `task an:prep-pve` will install do the base steps for getting the PVE node - this includes:
        - Installing required packages/pip packages
        - Removing subscription prompt
        - Creating snippets directory for uploading the cloud-init files
        - Mount any disks configured for the node
        - Execute steps required to enable GPU passthrough
        - Download base cloudinit and LXC images and create the templates to be cloned
    - `task an:create-vms` will create and perform basic configuration of the VMs
    - `task an:create-cts` will create and perform basic configuration of the containers
    - `task an:prep-pg` will install and perform basic configuration of postgres in the created container
    - `task an:prep-nodes` will prepare the k3s nodes by - e.g. installing GPU drivers and updating packages
    - `task an:inst-k3s` will perform a barebones installation of k3s
    - `task an:prep-k3s` will perform basic configuration of k3s (i.e. install cilium and bootstrap flux)
    - `task an:uninst-k3s` will uninstall k3s (used for easily reprovisioning the cluster to test different configuration)

Note: To make ansible bootstrapping simpler, it's recommended to add the following to `.ssh/config` to the created nodes
```
StrictHostKeyChecking accept-new # <- that tells ssh to accept new keys if none exists (so if re-provisioning the template, you should delete the old key from `~/.ssh/known_hosts`
```
- This is done to ensure that ansible doesn't prompt the user to confirm the host ssh key
- Note that if you delete the VMs or containers and try to recreate it, the confirmation will fail
    - To fix that, you should remove the old VMs/containers keys from `.ssh/known_hosts`

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

## Manual steps (k3s)
- Install and configure cilium to use BGP
```bash
cilium install
cilium status --wait # wait for cilium to be ready
cilium config view | grep -i bgp # check if bgp is enabled
cilium config set enable-bgp-control-plane true
cilium config view | grep -i bgp # now it should be enabled
k delete pod -n kube-system cilium-operator-6798dd5bb9-vzqcj # cycle pod to refresh configuration and create missing resources
k logs -n kube-system cilium-operator-6798dd5bb9-jn87t | grep CRD # check new pod logs to make sure new CRD was created
k api-resources | grep -i ciliumBGP # check api-resources to see it there
k apply -f kubernetes/kube-system/cilium-bgp-policy.yaml # apply bgp policy to expose services
## label all worker nodes with bgp-policy=a
#k label nodes k3s-worker-01 bgp-policy=a ## added on provision by ansible role
#k label nodes k3s-worker-02 bgp-policy=a
k create -f kubernetes/kube-system/cilium-ippool.yaml # create cilium ippool for load balancers
cilium bgp peers # check bgp peers - should have session as active
## Once router configuration is done
cilium bgp peers # check bgp peers - should have session as established
```

- Enable hubble on cilium
```bash
cilium hubble enable
cilium status # check it was enabled successfully
```

- Install hubble cli
```bash
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
HUBBLE_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then HUBBLE_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/hubble/releases/download/$HUBBLE_VERSION/hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}
sha256sum --check hubble-linux-${HUBBLE_ARCH}.tar.gz.sha256sum
sudo tar xzvfC hubble-linux-${HUBBLE_ARCH}.tar.gz /usr/local/bin
rm hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}
```

- Validate Hubble API Access
```bash
cilium hubble port-forward&
hubble status
hubble observe -f # for live check
```

- Bootstrap flux
```bash
flux bootstrap github \
    --branch=main \
    --owner=ttlins \
    --repository=homelab \
    --path=kubernetes/home \
    --components-extra=image-reflector-controller,image-automation-controller  \
    --personal
```

- Accessing traefik's dashboard
```bash
k -n kube-system port-forward $(k get pods -n kube-system -l "app.kubernetes.io/name=traefik" --output=name) 9000:9000
```

- Go to http://127.0.0.1:9000/dashboard/

## Nvidia drivers and secure boot
- Secure boot was disabled on the vms template by setting the `efidisk.pre_enrolled_keys` param to 0
- The reason for that is that installing the nvidia drivers with secure is not possible to be fully automated
    - We need to generate a MOK key to sign the modules
    - Enrolling a key on mok, however, requires rebooting and manually inserting the key password during a boot prompt
    - We've added some relevant docs on that in the helpful articles section below

## TODO
- Check how to install flux extra components after bootstrap
    - image-reflector-controller
    - image-automation-controller
- Add coredns


- Proper hardening
    - [CIS Debian Hardening](https://github.com/ovh/debian-cis)
    - [ansible role](https://github.com/konstruktoid/ansible-role-hardening)
    - postgres

- Use packer for template generation?
- Use terraform for actual VMs/CTs?
- Enable secureboot?
    - See section above

- Use proper roles for installing cilium and flux
    - not sure if we want to automate that with ansible
    - maybe not

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
- [k3s server fails to start without postgres DB access](https://github.com/k3s-io/k3s/issues/9033)
- [kubernetes loadbalance service using cilium bgp control plane](https://medium.com/@valentin.hristev/kubernetes-loadbalance-service-using-cilium-bgp-control-plane-8a5ad416546a)
- [using bgp to integrate cilium with opnsense](https://dickingwithdocker.com/posts/using-bgp-to-integrate-cilium-with-opnsense/)
- [traefik helm chart examples](https://github.com/traefik/traefik-helm-chart/blob/master/EXAMPLES.md)
- [deploy traefik proxy using flux and gitops](https://traefik.io/blog/deploy-traefik-proxy-using-flux-and-gitops/)
- [Setting up Hubble observability](https://docs.cilium.io/en/stable/gettingstarted/hubble_setup/)
