# Kubernetes Cluster Cleanup Guide

## Quick Cleanup

Use this script to completely remove Kubernetes and reset nodes to clean state.

### On Control VM

```bash
# SSH into control VM
vagrant ssh control

# Switch to root
sudo su -

# Download and run cleanup script
curl -O https://raw.githubusercontent.com/path/to/cleanup-kubernetes.sh
# Or copy from host
chmod +x cleanup-kubernetes.sh
./cleanup-kubernetes.sh

# Or run directly
sudo bash /vagrant/cleanup-kubernetes.sh
```

### On Host Worker Node

```bash
# On host machine
cd /home/server/Desktop/deepops/kubeadm
sudo bash cleanup-kubernetes.sh
```

## What the Script Does

The cleanup script performs these steps:

1. **Reset kubeadm** - Removes cluster configuration
2. **Stop services** - Stops kubelet, containerd, docker
3. **Remove packages** - Uninstalls kubeadm, kubectl, kubelet, kubernetes-cni
4. **Remove runtimes** - Removes containerd and docker
5. **Clean directories** - Deletes:
   - `/etc/kubernetes`
   - `/var/lib/kubelet`
   - `/var/lib/etcd`
   - `/etc/cni`, `/opt/cni`, `/var/lib/cni`
   - `/var/lib/containerd`, `/etc/containerd`
   - `/var/lib/calico`
   - `~/.kube`
6. **Remove network interfaces** - Deletes:
   - `cni0`
   - `flannel.1`
   - `weave`
   - `vxlan.calico`
   - All `veth*` interfaces
7. **Clean iptables** - Flushes all iptables rules
8. **Remove repositories** - Deletes Kubernetes apt sources
9. **Remove configs** - Deletes sysctl and module configs
10. **Update packages** - Runs `apt-get update`

## Manual Cleanup (Alternative)

If you prefer to run commands manually:

### Quick Reset

```bash
# Reset kubeadm
sudo kubeadm reset -f

# Remove packages
sudo apt-mark unhold kubelet kubeadm kubectl
sudo apt-get purge -y kubeadm kubectl kubelet kubernetes-cni containerd
sudo apt-get autoremove -y

# Clean directories
sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni /opt/cni /var/lib/cni
sudo rm -rf /var/lib/containerd /etc/containerd ~/.kube /var/lib/calico

# Remove network interfaces
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete weave 2>/dev/null || true
sudo ip link delete vxlan.calico 2>/dev/null || true

# Clean iptables
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# Remove repository
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Update
sudo apt-get update
```

### Deep Clean (Nuclear Option)

```bash
# Stop everything
sudo systemctl stop kubelet containerd docker || true

# Remove all Kubernetes and container runtime packages
sudo apt-get purge -y kube* kubectl kubelet kubeadm kubernetes-cni
sudo apt-get purge -y containerd* docker* cri-tools
sudo apt-get autoremove -y
sudo apt-get autoclean

# Remove ALL related directories
sudo rm -rf /etc/kubernetes
sudo rm -rf /var/lib/kubelet
sudo rm -rf /var/lib/etcd
sudo rm -rf /var/lib/containerd
sudo rm -rf /var/lib/docker
sudo rm -rf /var/lib/dockershim
sudo rm -rf /var/lib/cni
sudo rm -rf /var/lib/calico
sudo rm -rf /etc/cni
sudo rm -rf /opt/cni
sudo rm -rf /etc/containerd
sudo rm -rf /run/containerd
sudo rm -rf ~/.kube
sudo rm -rf /home/*/.kube

# Remove all virtual network interfaces
for iface in $(ip link show | grep -E 'cni|flannel|weave|veth|calico|docker' | awk '{print $2}' | cut -d@ -f1 | cut -d: -f1); do
    sudo ip link delete $iface 2>/dev/null || true
done

# Nuclear iptables reset
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X
sudo iptables -t mangle -F
sudo iptables -t mangle -X
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT

# Remove configs
sudo rm -f /etc/sysctl.d/99-k8s-cri.conf
sudo rm -f /etc/sysctl.d/k8s.conf
sudo rm -f /etc/modules-load.d/k8s.conf
sudo rm -f /etc/default/kubelet
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Reload sysctl
sudo sysctl --system

# Update package cache
sudo apt-get update

# Reboot recommended
sudo reboot
```

## After Cleanup

### Verify Clean State

```bash
# Check no Kubernetes processes
ps aux | grep -E 'kube|etcd|containerd'

# Check no Kubernetes packages
dpkg -l | grep -E 'kube|kubernetes'

# Check no network interfaces
ip link show | grep -E 'cni|flannel|weave|calico'

# Check directories removed
ls -la /etc/kubernetes 2>/dev/null || echo "Clean"
ls -la /var/lib/kubelet 2>/dev/null || echo "Clean"
ls -la /etc/cni 2>/dev/null || echo "Clean"
```

### Start Fresh

After cleanup, you can start fresh by following the setup guide from the beginning:

1. **On Control VM**: Follow Phase 1 in `KUBEADM_HYBRID_GPU_SETUP.md`
2. **On Host Worker**: Follow Phase 2 in `KUBEADM_HYBRID_GPU_SETUP.md`

## Troubleshooting

### Script Fails with "Device or resource busy"

```bash
# Unmount all Kubernetes volumes
sudo umount $(mount | grep '/var/lib/kubelet' | awk '{print $3}')

# Kill any remaining processes
sudo pkill -9 kubelet
sudo pkill -9 containerd
sudo pkill -9 dockerd

# Retry cleanup
sudo bash cleanup-kubernetes.sh
```

### Network interfaces won't delete

```bash
# Force delete with retry
for i in {1..3}; do
    sudo ip link delete cni0 2>/dev/null || true
    sudo ip link delete flannel.1 2>/dev/null || true
    sudo ip link delete weave 2>/dev/null || true
    sleep 2
done

# If still stuck, reboot
sudo reboot
```

### Packages won't uninstall

```bash
# Force remove with dpkg
sudo dpkg --purge --force-all kubeadm kubectl kubelet kubernetes-cni

# Clean dpkg database
sudo apt-get clean
sudo apt-get autoclean
sudo dpkg --configure -a
```

## Complete Cluster Reset Workflow

### 1. Clean Both Nodes

```bash
# On control VM
vagrant ssh control
sudo bash /vagrant/cleanup-kubernetes.sh

# On host
cd /home/server/Desktop/deepops/kubeadm
sudo bash cleanup-kubernetes.sh
```

### 2. Reboot Both Nodes

```bash
# Control VM
vagrant reload control

# Host
sudo reboot
```

### 3. Verify Clean State

```bash
# On both nodes
dpkg -l | grep kube
ip link show
ls /etc/kubernetes
```

### 4. Reinstall Fresh

Follow `KUBEADM_HYBRID_GPU_SETUP.md` from Phase 1.

---

## Quick Commands Reference

```bash
# Run cleanup script
sudo bash cleanup-kubernetes.sh

# Manual quick reset
sudo kubeadm reset -f && \
sudo apt-get purge -y kubeadm kubectl kubelet kubernetes-cni containerd && \
sudo rm -rf /etc/kubernetes /var/lib/kubelet /etc/cni /opt/cni ~/.kube

# Check if clean
dpkg -l | grep kube && echo "NOT CLEAN" || echo "CLEAN"

# Reboot
sudo reboot
```
