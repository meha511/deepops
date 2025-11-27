#!/bin/bash
#
# Kubernetes Cluster Cleanup Script
# This script completely removes Kubernetes and resets the node to clean state
#
# Usage: sudo bash cleanup-kubernetes.sh
#

set -e

echo "=========================================="
echo "Kubernetes Cluster Cleanup Script"
echo "=========================================="
echo ""
echo "WARNING: This will completely remove Kubernetes from this node!"
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

echo ""
echo "[1/10] Resetting kubeadm..."
if command -v kubeadm &> /dev/null; then
    kubeadm reset -f || true
else
    echo "kubeadm not found, skipping..."
fi

echo ""
echo "[2/10] Stopping Kubernetes services..."
systemctl stop kubelet || true
systemctl stop containerd || true
systemctl stop docker || true

echo ""
echo "[3/10] Removing Kubernetes packages..."
apt-mark unhold kubelet kubeadm kubectl || true
apt-get purge -y kubeadm kubectl kubelet kubernetes-cni || true
apt-get autoremove -y

echo ""
echo "[4/10] Removing container runtimes..."
apt-get purge -y containerd docker.io docker-ce docker-ce-cli || true

echo ""
echo "[5/10] Cleaning up directories..."
rm -rf /etc/kubernetes
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf /etc/cni
rm -rf /opt/cni
rm -rf /var/lib/cni
rm -rf /var/run/kubernetes
rm -rf /var/lib/dockershim
rm -rf /var/lib/docker
rm -rf /var/lib/containerd
rm -rf /etc/containerd
rm -rf ~/.kube
rm -rf /home/vagrant/.kube || true

echo ""
echo "[6/10] Removing CNI and network configurations..."

# Stop NetworkManager from interfering
systemctl stop NetworkManager 2>/dev/null || true

# Remove all CNI network interfaces
echo "  - Removing CNI network interfaces..."
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
ip link delete flannel-v4 2>/dev/null || true
ip link delete flannel-v6 2>/dev/null || true
ip link delete weave 2>/dev/null || true
ip link delete datapath 2>/dev/null || true
ip link delete vxlan.calico 2>/dev/null || true
ip link delete vxlan-v4 2>/dev/null || true
ip link delete vxlan-v6 2>/dev/null || true
ip link delete tunl0 2>/dev/null || true
ip link delete kube-ipvs0 2>/dev/null || true
ip link delete kube-bridge 2>/dev/null || true
ip link delete docker0 2>/dev/null || true
ip link delete dummy0 2>/dev/null || true

# Remove all veth interfaces (pod network interfaces)
echo "  - Removing veth interfaces..."
for iface in $(ip link show | grep -E 'veth|vxlan' | awk '{print $2}' | cut -d@ -f1 | cut -d: -f1); do
    ip link delete $iface 2>/dev/null || true
done

# Remove CNI configuration files
echo "  - Removing CNI configuration files..."
rm -rf /etc/cni/net.d/*
rm -rf /var/lib/cni/*
rm -rf /run/cni/*

# Remove Calico configurations
echo "  - Removing Calico configurations..."
rm -rf /var/lib/calico
rm -rf /var/run/calico
rm -rf /etc/calico
rm -rf /opt/cni/bin/calico*
rm -rf /opt/cni/bin/install

# Remove Flannel configurations
echo "  - Removing Flannel configurations..."
rm -rf /var/lib/k8s.io/flannel
rm -rf /run/flannel
rm -rf /etc/kube-flannel

# Remove Weave configurations
echo "  - Removing Weave configurations..."
rm -rf /var/lib/weave
rm -rf /opt/cni/bin/weave*

# Remove Cilium configurations
echo "  - Removing Cilium configurations..."
rm -rf /var/run/cilium
rm -rf /sys/fs/bpf/cilium

# Clean up IP routes and rules
echo "  - Cleaning IP routes and rules..."
ip route flush proto bird 2>/dev/null || true
ip route flush table all 2>/dev/null || true

# Remove custom routing tables
for table in $(ip rule list | grep -oP '(?<=lookup )[0-9]+' | sort -u); do
    if [ "$table" != "255" ] && [ "$table" != "254" ] && [ "$table" != "253" ] && [ "$table" != "0" ]; then
        ip route flush table $table 2>/dev/null || true
    fi
done

# Remove custom IP rules
ip rule list | grep -v "from all lookup" | grep -v "from all lookup local" | while read rule; do
    ip rule delete $rule 2>/dev/null || true
done

# Restart NetworkManager
systemctl start NetworkManager 2>/dev/null || true

echo ""
echo "[7/10] Cleaning iptables and ipvs rules..."

# Flush iptables
echo "  - Flushing iptables rules..."
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -t raw -F
iptables -t filter -F
iptables -X
iptables -t nat -X
iptables -t mangle -X
iptables -t raw -X
iptables -t filter -X

# IPv6 iptables
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -t mangle -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ip6tables -t nat -X 2>/dev/null || true
ip6tables -t mangle -X 2>/dev/null || true

# Reset iptables policies to ACCEPT
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -P OUTPUT ACCEPT 2>/dev/null || true

# Clean IPVS rules
echo "  - Cleaning IPVS rules..."
if command -v ipvsadm &> /dev/null; then
    ipvsadm -C 2>/dev/null || true
fi

# Remove IPVS kernel modules
echo "  - Removing IPVS kernel modules..."
modprobe -r ip_vs_wrr 2>/dev/null || true
modprobe -r ip_vs_sh 2>/dev/null || true
modprobe -r ip_vs_rr 2>/dev/null || true
modprobe -r ip_vs 2>/dev/null || true

# Clean ebtables
echo "  - Cleaning ebtables..."
if command -v ebtables &> /dev/null; then
    ebtables -t filter -F 2>/dev/null || true
    ebtables -t nat -F 2>/dev/null || true
    ebtables -t broute -F 2>/dev/null || true
fi

echo ""
echo "[8/10] Removing Kubernetes repository..."
rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo ""
echo "[9/10] Removing configuration files..."
rm -f /etc/sysctl.d/99-k8s-cri.conf
rm -f /etc/sysctl.d/k8s.conf
rm -f /etc/modules-load.d/k8s.conf
rm -f /etc/default/kubelet
rm -rf /var/lib/calico

# Remove apparmor profiles
apparmor_parser -R /etc/apparmor.d/runc 2>/dev/null || true
apparmor_parser -R /etc/apparmor.d/crun 2>/dev/null || true
rm -f /etc/apparmor.d/disable/runc
rm -f /etc/apparmor.d/disable/crun

echo ""
echo "[10/10] Updating package cache..."
apt-get update

echo ""
echo "=========================================="
echo "Cleanup completed successfully!"
echo "=========================================="
echo ""
echo "The node has been reset to clean state."
echo "You can now reinstall Kubernetes from scratch."
echo ""
echo "Note: You may want to reboot the system to ensure"
echo "all kernel modules and network settings are reset."
echo ""
echo "Reboot now? (y/n)"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo "Please reboot manually when ready."
fi
