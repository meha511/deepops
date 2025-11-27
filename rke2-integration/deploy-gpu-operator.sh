#!/bin/bash
# Deploy NVIDIA GPU Operator to existing RKE2 cluster

set -e

echo "=========================================="
echo "NVIDIA GPU Operator Deployment for RKE2"
echo "=========================================="

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl first."
    echo "For RKE2, typically located at: /var/lib/rancher/rke2/bin/kubectl"
    exit 1
fi

# Check if helm is available
if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Check cluster access
echo "[1/5] Checking cluster access..."
if ! kubectl get nodes &> /dev/null; then
    echo "❌ Cannot access Kubernetes cluster."
    echo "For RKE2, set KUBECONFIG:"
    echo "  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml"
    exit 1
fi

echo "✓ Cluster access confirmed"
kubectl get nodes

# Add NVIDIA Helm repo
echo "[2/5] Adding NVIDIA Helm repository..."
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || true
helm repo update

# Create namespace
echo "[3/5] Creating gpu-operator namespace..."
kubectl create namespace gpu-operator --dry-run=client -o yaml | kubectl apply -f -

# Determine deployment type
echo ""
echo "Select GPU Operator deployment type:"
echo "1) VirtualBox setup (no drivers in VMs - drivers on host)"
echo "2) KVM/Libvirt setup (with GPU passthrough - install drivers in VMs)"
read -p "Enter choice (1 or 2): " choice

VALUES_FILE="/tmp/gpu-operator-values.yaml"

if [ "$choice" = "1" ]; then
    echo "[4/5] Configuring for VirtualBox (host-level drivers)..."
    cat > $VALUES_FILE <<EOF
driver:
  enabled: false
toolkit:
  enabled: false
devicePlugin:
  enabled: true
dcgm:
  enabled: true
dcgmExporter:
  enabled: true
gfd:
  enabled: true
migManager:
  enabled: false
nfd:
  enabled: true
operator:
  defaultRuntime: containerd
EOF
elif [ "$choice" = "2" ]; then
    echo "[4/5] Configuring for KVM/Libvirt (VM-level drivers)..."
    cat > $VALUES_FILE <<EOF
driver:
  enabled: true
  version: "525.105.17"
toolkit:
  enabled: true
devicePlugin:
  enabled: true
dcgm:
  enabled: true
dcgmExporter:
  enabled: true
gfd:
  enabled: true
migManager:
  enabled: false
nfd:
  enabled: true
operator:
  defaultRuntime: containerd
EOF
else
    echo "Invalid choice. Exiting."
    exit 1
fi

# Install GPU Operator
echo "[5/5] Installing NVIDIA GPU Operator..."
helm install gpu-operator nvidia/gpu-operator \
    -n gpu-operator \
    --create-namespace \
    --values $VALUES_FILE \
    --wait

echo ""
echo "=========================================="
echo "✓ GPU Operator deployed successfully!"
echo "=========================================="
echo ""
echo "Verify installation:"
echo "  kubectl get pods -n gpu-operator"
echo ""
echo "Check GPU availability on nodes:"
echo "  kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity.\"nvidia\.com/gpu\""
echo ""
echo "Run test workload:"
echo "  kubectl apply -f rke2-integration/example-gpu-workloads.yaml"
echo "  kubectl logs gpu-test-basic"
echo ""
