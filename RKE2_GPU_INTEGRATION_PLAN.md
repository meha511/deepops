# RKE2 GPU Cluster Integration Plan with DeepOps

## Overview
This plan guides you through integrating GPU capabilities into your existing RKE2 cluster running on VirtualBox VMs, leveraging DeepOps capabilities for GPU workload management and AI model deployment.

**Current Setup:**
- Host: Ubuntu 24.04 with 2x RTX GPUs
- VMs: 3 nodes (1 control, 2 workers) via Vagrant + VirtualBox
- Cluster: RKE2 manually deployed (not using DeepOps deployment)
- Goal: Transform into GPU-enabled cluster for AI workloads

---

## ⚠️ CRITICAL: VirtualBox GPU Limitation

**IMPORTANT:** VirtualBox does **NOT** support GPU passthrough in the traditional sense. You have two options:

### Option A: Recommended - Use KVM/Libvirt Instead
- Migrate to KVM/Libvirt which supports proper GPU passthrough (VFIO)
- DeepOps virtual environment uses Libvirt by default
- Follow DeepOps virtual setup: `/home/server/Desktop/deepops/virtual/README.md`

### Option B: Current Setup - Host-Level GPU Access
- Keep VirtualBox but run GPU workloads on **host machine**
- Use RKE2 cluster for orchestration only
- Deploy GPU containers on host using `containerd` runtime
- More limited but works with current VirtualBox setup

**This plan covers BOTH options** - choose based on your requirements.

---

## Phase 1: Prerequisites and Host Preparation

### 1.1 Host GPU Setup (Ubuntu 24.04)

#### Install NVIDIA Drivers on Host
```bash
# Check GPU availability
lspci | grep -i nvidia

# Install NVIDIA drivers (525+ recommended for DeepOps)
sudo apt-get update
sudo apt-get install -y ubuntu-drivers-common
sudo ubuntu-drivers devices
sudo ubuntu-drivers autoinstall

# Or install specific version
sudo apt-get install -y nvidia-driver-525 nvidia-dkms-525

# Reboot
sudo reboot

# Verify installation
nvidia-smi
```

#### Install Container Runtime with GPU Support
```bash
# Install containerd
sudo apt-get install -y containerd

# Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# Configure containerd for NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd

# Test GPU access in container
sudo ctr image pull docker.io/nvidia/cuda:11.8.0-base-ubuntu22.04
sudo ctr run --rm --gpus 0 docker.io/nvidia/cuda:11.8.0-base-ubuntu22.04 test nvidia-smi
```

### 1.2 Setup DeepOps Provisioning Environment

```bash
cd /home/server/Desktop/deepops

# Run setup script to install Ansible and dependencies
./scripts/setup.sh

# This installs:
# - Ansible
# - Python dependencies
# - Kubectl
# - Helm
# - Other required tools
```

---

## Phase 2: GPU Integration Options

### Option A: Migrate to KVM/Libvirt (Recommended)

This provides true GPU passthrough to VMs.

#### 2A.1 Enable Virtualization and VFIO on Host

```bash
# Verify virtualization support
grep -oE 'svm|vmx' /proc/cpuinfo | uniq

# Enable VFIO modules
sudo tee /etc/modules-load.d/vfio.conf <<EOF
pci_stub
vfio
vfio_iommu_type1
vfio_pci
kvm
kvm_intel
EOF

# Update GRUB for IOMMU
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_iommu=on vfio_iommu_type1.allow_unsafe_interrupts=1 iommu=pt"/' /etc/default/grub
sudo update-grub

# Get GPU PCI IDs
lspci -nn | grep NVIDIA

# Example output:
# 07:00.0 VGA compatible controller [0300]: NVIDIA Corporation [10de:xxxx]

# Blacklist GPUs for host, reserve for passthrough
# Replace 10de:xxxx with your GPU device IDs
sudo tee /etc/modprobe.d/vfio.conf <<EOF
options vfio-pci ids=10de:xxxx
EOF

sudo update-initramfs -u
sudo reboot
```

#### 2A.2 Deploy DeepOps Virtual Cluster with GPU Passthrough

```bash
cd /home/server/Desktop/deepops/virtual

# Configure GPU passthrough in Vagrantfile
# Edit the BUS address for your GPU (found via lspci)
vi Vagrantfile

# Uncomment and update the line:
# v.pci :bus => '0x07', :slot => '0x00', :function => '0x0'

# Start virtual cluster
./vagrant_startup.sh

# Deploy Kubernetes with GPU support
./cluster_up.sh
```

### Option B: Keep VirtualBox, Host-Level GPU Access

This approach treats the host as a GPU worker node.

#### 2B.1 Configure RKE2 to Access Host Resources

You'll need to register your host as a GPU-capable node or run GPU workloads via external node registration.

**Note:** This is more complex and less elegant than Option A, but works with VirtualBox.

---

## Phase 3: Deploy NVIDIA GPU Operator (Choose Based on Option)

### Option A Path: GPU Operator in KVM Cluster

```bash
cd /home/server/Desktop/deepops

# Configure GPU Operator settings
vi config/group_vars/k8s-cluster.yml

# Enable the following:
# deepops_gpu_operator_enabled: true
# gpu_operator_preinstalled_nvidia_software: false  # Use driver containers

# Deploy GPU Operator
ansible-playbook -l k8s-cluster playbooks/k8s-cluster/nvidia-gpu-operator.yml
```

### Option B Path: Manual GPU Operator on RKE2

Since your RKE2 cluster exists, deploy GPU Operator directly using Helm:

```bash
# Access your RKE2 cluster
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
# Or copy kubectl from one of your VMs

# Add NVIDIA Helm repository
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# Install GPU Operator
helm install --wait --generate-name \
  -n gpu-operator --create-namespace \
  nvidia/gpu-operator \
  --set driver.enabled=false \
  --set toolkit.enabled=false

# Note: driver.enabled=false because drivers are on HOST, not in VMs
```

### 3.1 Configure Node Labeling

Label nodes that should run GPU workloads:

```bash
# For actual GPU nodes (if using KVM passthrough)
kubectl label nodes <node-name> nvidia.com/gpu=true

# For host machine access (VirtualBox scenario)
# You might need node affinity or external scheduling
```

---

## Phase 4: Install DeepOps Components

### 4.1 Deploy Monitoring (Prometheus + Grafana with GPU Metrics)

```bash
cd /home/server/Desktop/deepops

# Deploy monitoring stack
./scripts/k8s/deploy_monitoring.sh

# Access points:
# Grafana: http://<kube-master>:30200
# Prometheus: http://<kube-master>:30500

# GPU dashboards are pre-configured in DeepOps
```

### 4.2 Setup Persistent Storage (Required for AI workloads)

```bash
# Option 1: NFS (simplest for virtual setup)
ansible-playbook playbooks/k8s-cluster/nfs-client-provisioner.yml

# Option 2: Local storage provisioner
# Edit config if needed
ansible-playbook playbooks/k8s-cluster/local-volume-provisioner.yml

# Verify storage class
kubectl get storageclass
```

### 4.3 Deploy Kubeflow (AI/ML Platform)

```bash
cd /home/server/Desktop/deepops

# Deploy Kubeflow
./scripts/k8s/deploy_kubeflow.sh

# Access: http://<kube-master>:31380
# Default credentials: deepops@example.com / deepops

# Wait for all pods to be ready
kubectl get pods -n kubeflow --watch
```

### 4.4 Optional: Deploy Container Registry

```bash
ansible-playbook --tags container-registry \
  playbooks/k8s-cluster/container-registry.yml

# Access: registry.local or specify custom hostname
```

---

## Phase 5: GPU Verification and Testing

### 5.1 Verify GPU Operator Components

```bash
# Check GPU Operator pods
kubectl get pods -n gpu-operator

# Expected pods:
# - gpu-operator-*
# - nvidia-device-plugin-daemonset-*
# - nvidia-dcgm-exporter-* (if enabled)
# - gpu-feature-discovery-*

# Check node GPU capacity
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity."nvidia\.com/gpu"
```

### 5.2 Run GPU Test Workload

```bash
# Create test namespace
kubectl create namespace gpu-test

# Deploy GPU test pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
  namespace: gpu-test
spec:
  restartPolicy: OnFailure
  containers:
  - name: cuda-container
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Check logs
kubectl logs -n gpu-test gpu-test

# Expected output: "Test PASSED"

# Cleanup
kubectl delete namespace gpu-test
```

### 5.3 Run NVIDIA SMI in Cluster

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi
spec:
  restartPolicy: OnFailure
  containers:
  - name: nvidia-smi
    image: nvidia/cuda:11.8.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Check output
kubectl logs nvidia-smi

# Cleanup
kubectl delete pod nvidia-smi
```

---

## Phase 6: Deploy AI Models and Workloads

### 6.1 Example: Deploy Jupyter Notebook with GPU

```bash
cd /home/server/Desktop/deepops/workloads/examples/k8s

# Review available examples
ls -la

# Deploy GPU-enabled Jupyter
kubectl apply -f jupyter-notebook/jupyter-gpu.yaml

# Access via port-forward
kubectl port-forward -n default svc/jupyter 8888:8888
# Access: http://localhost:8888
```

### 6.2 Example: Deploy TensorFlow Training Job

```bash
cd /home/server/Desktop/deepops/workloads/examples/k8s

# Examine TensorFlow example
cat tensorflow/tensorflow-gpu.yaml

# Deploy
kubectl apply -f tensorflow/tensorflow-gpu.yaml

# Monitor job
kubectl get pods -w
kubectl logs <pod-name>
```

### 6.3 Example: Deploy PyTorch with Multi-GPU

```bash
# Create PyTorch training job
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pytorch-training
spec:
  containers:
  - name: pytorch
    image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
    command: ["python", "-c"]
    args:
      - |
        import torch
        print(f"CUDA available: {torch.cuda.is_available()}")
        print(f"GPU count: {torch.cuda.device_count()}")
        print(f"GPU name: {torch.cuda.get_device_name(0)}")
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

kubectl logs pytorch-training
```

### 6.4 Deploy Model Serving (Triton Inference Server)

```bash
# Example Triton deployment
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton-inference-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: triton
  template:
    metadata:
      labels:
        app: triton
    spec:
      containers:
      - name: triton
        image: nvcr.io/nvidia/tritonserver:23.08-py3
        ports:
        - containerPort: 8000
          name: http
        - containerPort: 8001
          name: grpc
        - containerPort: 8002
          name: metrics
        resources:
          limits:
            nvidia.com/gpu: 1
---
apiVersion: v1
kind: Service
metadata:
  name: triton-inference-server
spec:
  selector:
    app: triton
  ports:
  - name: http
    port: 8000
  - name: grpc
    port: 8001
  - name: metrics
    port: 8002
  type: NodePort
EOF

# Access Triton
kubectl get svc triton-inference-server
```

---

## Phase 7: Advanced DeepOps Features

### 7.1 Enable DCGM Exporter for GPU Metrics

```bash
# Edit GPU Operator config to enable DCGM
vi /home/server/Desktop/deepops/config/group_vars/k8s-cluster.yml

# Set: gpu_operator_enable_dcgm: true

# Redeploy GPU Operator
ansible-playbook playbooks/k8s-cluster/nvidia-gpu-operator.yml

# DCGM metrics will be available in Prometheus
```

### 7.2 Configure MIG (Multi-Instance GPU) - For A100/H100

```bash
# If you have supported GPUs
vi /home/server/Desktop/deepops/config/group_vars/k8s-cluster.yml

# Configure MIG strategy: mixed, single, or none
# k8s_gpu_mig_strategy: "mixed"

# Apply MIG configuration
ansible-playbook playbooks/nvidia-software/nvidia-mig.yml
```

### 7.3 Deploy MPI Operator for Multi-Node Training

```bash
# MPI Operator is included with Kubeflow
# Check installation
kubectl get crd mpijobs.kubeflow.org

# Example MPI job
cat <<EOF | kubectl apply -f -
apiVersion: kubeflow.org/v1
kind: MPIJob
metadata:
  name: tensorflow-mnist
spec:
  slotsPerWorker: 1
  runPolicy:
    cleanPodPolicy: Running
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          containers:
          - image: horovod/horovod:0.27.0-tf2.12.0-torch2.0.0-mxnet1.9.1-py3.10-gpu
            name: mpi-launcher
            command:
            - mpirun
            - python
            - /examples/tensorflow2/tensorflow2_mnist.py
    Worker:
      replicas: 2
      template:
        spec:
          containers:
          - image: horovod/horovod:0.27.0-tf2.12.0-torch2.0.0-mxnet1.9.1-py3.10-gpu
            name: mpi-worker
            resources:
              limits:
                nvidia.com/gpu: 1
EOF
```

---

## Phase 8: Production Hardening

### 8.1 Configure Resource Quotas

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: default
spec:
  hard:
    requests.nvidia.com/gpu: "2"
    limits.nvidia.com/gpu: "2"
EOF
```

### 8.2 Setup Network Policies

```bash
# Review DeepOps network policy examples
ls /home/server/Desktop/deepops/playbooks/k8s-cluster/

# Apply security policies as needed
```

### 8.3 Enable Cluster Backup

```bash
# Install Velero or similar backup solution
# DeepOps includes configurations in workloads/services/
```

---

## Configuration Files Reference

### Key Files to Customize

1. **Ansible Inventory**: `config/inventory`
   - Add your RKE2 nodes if using DeepOps Ansible automation

2. **K8s Cluster Variables**: `config/group_vars/k8s-cluster.yml`
   ```yaml
   # GPU Operator
   deepops_gpu_operator_enabled: true
   gpu_operator_preinstalled_nvidia_software: false
   gpu_operator_enable_dcgm: true
   
   # Storage
   k8s_nfs_client_provisioner: true
   k8s_nfs_server: "192.168.56.10"
   k8s_nfs_export_path: "/export"
   ```

3. **GPU Operator Settings**: `roles/nvidia-gpu-operator/defaults/main.yml`
   - Driver version
   - Component toggles
   - Registry settings

4. **Kubeflow Config**: `config/files/kubeflow/dex-config-map.yaml`
   - User credentials
   - Authentication settings

---

## Troubleshooting Guide

### Issue: No GPUs Detected

**VirtualBox Users:**
```bash
# VirtualBox doesn't support GPU passthrough
# Verify driver on HOST:
nvidia-smi

# Option 1: Switch to KVM/Libvirt
# Option 2: Run GPU containers on host with RKE2 orchestration
```

**KVM/Libvirt Users:**
```bash
# Check VFIO binding
lspci -nnk -d 10de:
# Should show: Kernel driver in use: vfio-pci

# Check VM GPU visibility
virsh nodedev-list | grep pci

# Check in VM
nvidia-smi  # Should show GPU
```

### Issue: GPU Operator Pods Failing

```bash
# Check logs
kubectl logs -n gpu-operator <pod-name>

# Common fixes:
# 1. Ensure container runtime supports GPU
# 2. Check driver installation
# 3. Verify node labels
kubectl describe node <node-name>
```

### Issue: AI Workload Can't Find GPU

```bash
# Verify device plugin is running
kubectl get pods -n gpu-operator | grep device-plugin

# Check node allocatable GPUs
kubectl get nodes -o json | jq '.items[].status.allocatable'

# Check pod resource requests
kubectl describe pod <pod-name>
```

---

## Best Practices

1. **Resource Management**
   - Always set GPU resource limits in pod specs
   - Use resource quotas per namespace
   - Monitor GPU utilization via Grafana

2. **Container Images**
   - Use NVIDIA NGC catalog images for optimized performance
   - Build custom images with specific CUDA versions
   - Use multi-stage builds to reduce image size

3. **Data Management**
   - Use persistent volumes for datasets
   - Consider NFS or distributed storage for multi-node access
   - Implement data versioning for reproducibility

4. **Security**
   - Don't run GPU workloads as root
   - Use network policies to isolate namespaces
   - Regularly update GPU drivers and operators

---

## Next Steps

1. **Choose your path**: KVM (Option A) or VirtualBox host-level (Option B)
2. **Complete Phase 1**: Install drivers and setup DeepOps environment
3. **Complete Phase 2-3**: GPU integration and operator deployment
4. **Complete Phase 4**: Deploy DeepOps components (monitoring, storage, Kubeflow)
5. **Complete Phase 5**: Verify GPU functionality
6. **Complete Phase 6**: Deploy your first AI workloads
7. **Complete Phase 7-8**: Enable advanced features and harden for production

---

## Additional Resources

- **DeepOps Documentation**: `/home/server/Desktop/deepops/docs/`
- **Kubernetes Guide**: `/home/server/Desktop/deepops/docs/k8s-cluster/README.md`
- **Example Workloads**: `/home/server/Desktop/deepops/workloads/examples/k8s/`
- **GPU Operator Docs**: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/
- **Kubeflow Docs**: https://www.kubeflow.org/docs/
- **NVIDIA NGC Catalog**: https://catalog.ngc.nvidia.com/

---

## Quick Reference Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get pods --all-namespaces

# Check GPU availability
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity."nvidia\.com/gpu"

# View GPU Operator status
kubectl get pods -n gpu-operator

# Access Grafana
# http://<master-node>:30200

# Access Kubeflow
# http://<master-node>:31380

# View cluster resources
kubectl top nodes
kubectl top pods --all-namespaces

# DeepOps verify GPU script
cd /home/server/Desktop/deepops
export CLUSTER_VERIFY_EXPECTED_PODS=2  # Number of GPUs
./scripts/k8s/verify_gpu.sh
```
