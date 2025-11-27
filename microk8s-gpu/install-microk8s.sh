#!/bin/bash
set -e

# MicroK8s Installation Script for Single-Node GPU Cluster
# This script installs and configures MicroK8s with GPU support

echo "=========================================="
echo "MicroK8s GPU Installation Script"
echo "=========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    echo -e "${RED}Please do not run as root. Run as regular user with sudo privileges.${NC}"
    exit 1
fi

# Check for NVIDIA GPU
echo -e "${YELLOW}Checking for NVIDIA GPU...${NC}"
if ! lspci | grep -i nvidia > /dev/null; then
    echo -e "${RED}No NVIDIA GPU detected. This script is for GPU-enabled systems.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ NVIDIA GPU detected${NC}"

# Check for NVIDIA drivers
echo -e "${YELLOW}Checking for NVIDIA drivers...${NC}"
if ! command -v nvidia-smi &> /dev/null; then
    echo -e "${RED}NVIDIA drivers not found. Please install NVIDIA drivers first.${NC}"
    echo "Run: sudo ubuntu-drivers autoinstall"
    exit 1
fi
echo -e "${GREEN}✓ NVIDIA drivers installed${NC}"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader

# Install MicroK8s
echo -e "${YELLOW}Installing MicroK8s...${NC}"
if ! command -v microk8s &> /dev/null; then
    sudo snap install microk8s --classic --channel=1.28/stable
    echo -e "${GREEN}✓ MicroK8s installed${NC}"
else
    echo -e "${GREEN}✓ MicroK8s already installed${NC}"
fi

# Add user to microk8s group
echo -e "${YELLOW}Adding user to microk8s group...${NC}"
sudo usermod -a -G microk8s $USER
sudo chown -f -R $USER ~/.kube || true

# Wait for MicroK8s to be ready
echo -e "${YELLOW}Waiting for MicroK8s to be ready...${NC}"
microk8s status --wait-ready

# Enable required addons
echo -e "${YELLOW}Enabling MicroK8s addons...${NC}"
microk8s enable dns
microk8s enable storage
microk8s enable helm3
microk8s enable gpu

echo -e "${GREEN}✓ Core addons enabled${NC}"

# Wait for GPU operator to be ready
echo -e "${YELLOW}Waiting for GPU operator to be ready (this may take a few minutes)...${NC}"
sleep 30

# Setup kubectl alias
echo -e "${YELLOW}Setting up kubectl alias...${NC}"
if ! grep -q "alias kubectl='microk8s kubectl'" ~/.bashrc; then
    echo "alias kubectl='microk8s kubectl'" >> ~/.bashrc
    echo "alias helm='microk8s helm3'" >> ~/.bashrc
fi

# Create kubeconfig
echo -e "${YELLOW}Creating kubeconfig...${NC}"
mkdir -p ~/.kube
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config

echo ""
echo -e "${GREEN}=========================================="
echo "MicroK8s Installation Complete!"
echo "==========================================${NC}"
echo ""
echo "Next steps:"
echo "1. Log out and log back in (or run: newgrp microk8s)"
echo "2. Verify installation: ./verify-gpu-setup.sh"
echo "3. Deploy test workload: kubectl apply -f example-gpu-workload.yaml"
echo ""
echo "Useful commands:"
echo "  microk8s status          - Check cluster status"
echo "  microk8s kubectl get pods -A  - List all pods"
echo "  microk8s kubectl get nodes    - Check node status"
echo ""
