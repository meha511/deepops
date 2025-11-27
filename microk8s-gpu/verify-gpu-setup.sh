#!/bin/bash

# MicroK8s GPU Verification Script
# Verifies that GPU support is properly configured

echo "=========================================="
echo "MicroK8s GPU Setup Verification"
echo "=========================================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

FAILED=0

# Check MicroK8s status
echo -e "\n${YELLOW}1. Checking MicroK8s status...${NC}"
if microk8s status --wait-ready; then
    echo -e "${GREEN}✓ MicroK8s is running${NC}"
else
    echo -e "${RED}✗ MicroK8s is not running${NC}"
    FAILED=1
fi

# Check GPU addon
echo -e "\n${YELLOW}2. Checking GPU addon status...${NC}"
if microk8s status | grep -q "gpu: enabled"; then
    echo -e "${GREEN}✓ GPU addon is enabled${NC}"
else
    echo -e "${RED}✗ GPU addon is not enabled${NC}"
    echo "Run: microk8s enable gpu"
    FAILED=1
fi

# Check NVIDIA device plugin
echo -e "\n${YELLOW}3. Checking NVIDIA device plugin...${NC}"
if microk8s kubectl get pods -n kube-system | grep -q "nvidia-device-plugin"; then
    echo -e "${GREEN}✓ NVIDIA device plugin is running${NC}"
    microk8s kubectl get pods -n kube-system | grep nvidia-device-plugin
else
    echo -e "${RED}✗ NVIDIA device plugin not found${NC}"
    FAILED=1
fi

# Check GPU operator (if installed)
echo -e "\n${YELLOW}4. Checking GPU operator...${NC}"
if microk8s kubectl get pods -n gpu-operator-resources 2>/dev/null | grep -q "nvidia"; then
    echo -e "${GREEN}✓ GPU operator is running${NC}"
    microk8s kubectl get pods -n gpu-operator-resources
else
    echo -e "${YELLOW}! GPU operator not found (optional)${NC}"
fi

# Check node GPU capacity
echo -e "\n${YELLOW}5. Checking node GPU capacity...${NC}"
GPU_COUNT=$(microk8s kubectl get nodes -o json | jq -r '.items[].status.capacity["nvidia.com/gpu"]' 2>/dev/null)
if [ ! -z "$GPU_COUNT" ] && [ "$GPU_COUNT" != "null" ]; then
    echo -e "${GREEN}✓ Node reports $GPU_COUNT GPU(s)${NC}"
    microk8s kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity."nvidia\.com/gpu"
else
    echo -e "${RED}✗ No GPUs detected on node${NC}"
    FAILED=1
fi

# Check NVIDIA runtime
echo -e "\n${YELLOW}6. Checking NVIDIA container runtime...${NC}"
if microk8s ctr version &>/dev/null; then
    echo -e "${GREEN}✓ Container runtime is accessible${NC}"
else
    echo -e "${YELLOW}! Could not verify container runtime${NC}"
fi

# Host GPU check
echo -e "\n${YELLOW}7. Checking host GPU with nvidia-smi...${NC}"
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv
    echo -e "${GREEN}✓ Host GPU accessible${NC}"
else
    echo -e "${RED}✗ nvidia-smi not available on host${NC}"
    FAILED=1
fi

# Summary
echo -e "\n=========================================="
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed!${NC}"
    echo -e "${GREEN}Your MicroK8s cluster is ready for GPU workloads.${NC}"
else
    echo -e "${RED}✗ Some checks failed.${NC}"
    echo "Please review the errors above and fix them."
fi
echo "=========================================="

exit $FAILED
