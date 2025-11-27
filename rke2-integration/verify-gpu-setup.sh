#!/bin/bash
# Comprehensive GPU Setup Verification Script

set -e

echo "=========================================="
echo "GPU Cluster Verification"
echo "=========================================="

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_passed=0
check_failed=0

check() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ PASS${NC}: $1"
        ((check_passed++))
    else
        echo -e "${RED}✗ FAIL${NC}: $1"
        ((check_failed++))
    fi
}

# 1. Check kubectl access
echo ""
echo "[1/10] Checking Kubernetes access..."
kubectl get nodes > /dev/null 2>&1
check "Kubernetes cluster accessible"

# 2. Check nodes status
echo ""
echo "[2/10] Checking node status..."
READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready")
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
echo "Ready nodes: $READY_NODES/$TOTAL_NODES"
[ "$READY_NODES" -eq "$TOTAL_NODES" ]
check "All nodes are Ready"

# 3. Check GPU Operator namespace
echo ""
echo "[3/10] Checking GPU Operator namespace..."
kubectl get namespace gpu-operator > /dev/null 2>&1
check "GPU Operator namespace exists"

# 4. Check GPU Operator pods
echo ""
echo "[4/10] Checking GPU Operator pods..."
GPU_OPERATOR_PODS=$(kubectl get pods -n gpu-operator --no-headers 2>/dev/null | wc -l)
echo "GPU Operator pods found: $GPU_OPERATOR_PODS"
[ "$GPU_OPERATOR_PODS" -gt 0 ]
check "GPU Operator pods deployed"

# 5. Check GPU Operator pod status
echo ""
echo "[5/10] Checking GPU Operator pod status..."
kubectl get pods -n gpu-operator
NOT_RUNNING=$(kubectl get pods -n gpu-operator --no-headers 2>/dev/null | grep -cv "Running\|Completed")
[ "$NOT_RUNNING" -eq 0 ]
check "All GPU Operator pods are Running"

# 6. Check device plugin
echo ""
echo "[6/10] Checking NVIDIA Device Plugin..."
kubectl get daemonset -n gpu-operator nvidia-device-plugin-daemonset > /dev/null 2>&1
check "NVIDIA Device Plugin DaemonSet exists"

# 7. Check GPU capacity on nodes
echo ""
echo "[7/10] Checking GPU capacity on nodes..."
echo "Node GPU capacity:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity."nvidia\.com/gpu"
GPU_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.capacity."nvidia.com/gpu" != null) | .metadata.name' | wc -l)
echo "Nodes with GPU capacity: $GPU_NODES"
[ "$GPU_NODES" -gt 0 ]
check "At least one node has GPU capacity"

# 8. Check allocatable GPUs
echo ""
echo "[8/10] Checking allocatable GPUs..."
TOTAL_GPUS=$(kubectl get nodes -o json | jq '[.items[].status.capacity."nvidia.com/gpu" // "0" | tonumber] | add')
echo "Total GPUs in cluster: $TOTAL_GPUS"
[ "$TOTAL_GPUS" -gt 0 ]
check "GPUs are allocatable"

# 9. Run GPU test pod
echo ""
echo "[9/10] Running GPU test pod..."
cat <<EOF | kubectl apply -f - > /dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: gpu-verify-test
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: nvidia/cuda:11.8.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Wait for pod to complete
echo "Waiting for test pod to complete..."
kubectl wait --for=condition=Ready pod/gpu-verify-test --timeout=120s > /dev/null 2>&1 || true
sleep 5

# Check logs
POD_STATUS=$(kubectl get pod gpu-verify-test -o jsonpath='{.status.phase}')
if [ "$POD_STATUS" = "Succeeded" ] || [ "$POD_STATUS" = "Running" ]; then
    echo "Test pod logs:"
    kubectl logs gpu-verify-test 2>/dev/null || true
    check "GPU test pod executed successfully"
else
    echo "Test pod status: $POD_STATUS"
    kubectl describe pod gpu-verify-test | tail -20
    false
    check "GPU test pod executed successfully"
fi

# Cleanup
kubectl delete pod gpu-verify-test --ignore-not-found=true > /dev/null 2>&1

# 10. Check monitoring (optional)
echo ""
echo "[10/10] Checking GPU monitoring..."
kubectl get servicemonitor -n gpu-operator > /dev/null 2>&1
check "GPU monitoring components present"

# Summary
echo ""
echo "=========================================="
echo "Verification Summary"
echo "=========================================="
echo -e "${GREEN}Passed: $check_passed${NC}"
echo -e "${RED}Failed: $check_failed${NC}"
echo ""

if [ $check_failed -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed! GPU cluster is ready.${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Deploy AI workloads: kubectl apply -f rke2-integration/example-gpu-workloads.yaml"
    echo "2. Deploy Kubeflow: cd /home/server/Desktop/deepops && ./scripts/k8s/deploy_kubeflow.sh"
    echo "3. Deploy monitoring: cd /home/server/Desktop/deepops && ./scripts/k8s/deploy_monitoring.sh"
    exit 0
else
    echo -e "${RED}✗ Some checks failed. Review the output above.${NC}"
    echo ""
    echo "Common troubleshooting:"
    echo "1. Check GPU Operator logs: kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset"
    echo "2. Check node labels: kubectl describe nodes"
    echo "3. Verify driver on host (VirtualBox): nvidia-smi"
    echo "4. Review installation: kubectl get all -n gpu-operator"
    exit 1
fi
