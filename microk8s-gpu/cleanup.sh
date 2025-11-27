#!/bin/bash

# MicroK8s Cleanup Script
# Removes MicroK8s and all associated resources

echo "=========================================="
echo "MicroK8s Cleanup Script"
echo "=========================================="

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}WARNING: This will remove MicroK8s and all workloads!${NC}"
read -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

# Stop MicroK8s
echo "Stopping MicroK8s..."
microk8s stop || true

# Remove MicroK8s
echo "Removing MicroK8s..."
sudo snap remove microk8s --purge

# Remove user from group
echo "Removing user from microk8s group..."
sudo deluser $USER microk8s || true

# Clean up config files
echo "Cleaning up config files..."
rm -rf ~/.kube/config
rm -rf /var/snap/microk8s

# Remove aliases from bashrc
echo "Removing aliases from .bashrc..."
sed -i '/alias kubectl=.*microk8s/d' ~/.bashrc
sed -i '/alias helm=.*microk8s/d' ~/.bashrc

echo ""
echo -e "${GREEN}=========================================="
echo "MicroK8s cleanup complete!"
echo "==========================================${NC}"
echo ""
echo "You may need to log out and back in for group changes to take effect."
