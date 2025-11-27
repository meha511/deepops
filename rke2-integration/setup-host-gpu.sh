#!/bin/bash
# Host GPU Setup Script for Ubuntu 24.04
# This script prepares the host machine with NVIDIA drivers and container runtime

set -e

echo "==================================="
echo "Host GPU Setup for RKE2 Integration"
echo "==================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root or with sudo"
    exit 1
fi

# Update system
echo "[1/6] Updating system packages..."
apt-get update
apt-get upgrade -y

# Install prerequisites
echo "[2/6] Installing prerequisites..."
apt-get install -y \
    build-essential \
    dkms \
    linux-headers-$(uname -r) \
    ubuntu-drivers-common \
    curl \
    gnupg \
    ca-certificates

# Install NVIDIA drivers
echo "[3/6] Installing NVIDIA drivers..."
ubuntu-drivers devices
echo "Installing recommended NVIDIA driver..."
ubuntu-drivers autoinstall

# Alternatively, install specific version (uncomment if needed):
# apt-get install -y nvidia-driver-525 nvidia-dkms-525

# Install Docker or containerd
echo "[4/6] Installing containerd..."
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Install NVIDIA Container Toolkit
echo "[5/6] Installing NVIDIA Container Toolkit..."
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y nvidia-container-toolkit

# Configure containerd for NVIDIA runtime
echo "[6/6] Configuring container runtime for GPU..."
nvidia-ctk runtime configure --runtime=containerd
systemctl restart containerd

echo ""
echo "==================================="
echo "Setup complete!"
echo "==================================="
echo ""
echo "⚠️  IMPORTANT: System reboot required for driver changes to take effect"
echo ""
echo "After reboot, verify installation with:"
echo "  nvidia-smi"
echo "  sudo ctr image pull docker.io/nvidia/cuda:11.8.0-base-ubuntu22.04"
echo "  sudo ctr run --rm --gpus 0 docker.io/nvidia/cuda:11.8.0-base-ubuntu22.04 test nvidia-smi"
echo ""
read -p "Reboot now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
fi
