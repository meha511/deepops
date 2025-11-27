# MicroK8s GPU Setup Guide - Single Node Deployment

Complete step-by-step guide for setting up MicroK8s with GPU support on a single Ubuntu node.

## Table of Contents
- [Prerequisites](#prerequisites)
- [Step 1: Install NVIDIA Drivers](#step-1-install-nvidia-drivers)
- [Step 2: Install NVIDIA Container Toolkit](#step-2-install-nvidia-container-toolkit)
- [Step 3: Install MicroK8s](#step-3-install-microk8s)
- [Step 4: Configure MicroK8s](#step-4-configure-microk8s)
- [Step 5: Enable GPU Support](#step-5-enable-gpu-support)
- [Step 6: Verify GPU Setup](#step-6-verify-gpu-setup)
- [Step 7: Deploy Test Workloads](#step-7-deploy-test-workloads)
- [Troubleshooting](#troubleshooting)
- [Useful Commands](#useful-commands)

---

## Prerequisites

### System Requirements
- **OS**: Ubuntu 20.04 or 22.04 (recommended) or 24.04
- **GPU**: NVIDIA GPU (any model)
- **RAM**: Minimum 4GB (8GB+ recommended)
- **Disk**: 20GB free space
- **User**: Non-root user with sudo privileges

### Check Your GPU
```bash
lspci | grep -i nvidia
```

You should see your NVIDIA GPU listed.

---

## Step 1: Install NVIDIA Drivers

### 1.1 Update System
```bash
sudo apt update
sudo apt upgrade -y
```

### 1.2 Check Available Drivers
```bash
sudo apt install -y ubuntu-drivers-common
ubuntu-drivers devices
```

### 1.3 Install NVIDIA Drivers

**Option A: Automatic Installation (Recommended)**
```bash
sudo ubuntu-drivers autoinstall
```

**Option B: Install Specific Version**
```bash
# For example, driver version 535
sudo apt install -y nvidia-driver-535
```

### 1.4 Reboot System
```bash
sudo reboot
```

### 1.5 Verify Driver Installation
After reboot:
```bash
nvidia-smi
```

You should see your GPU information displayed.

---

## Step 2: Install NVIDIA Container Toolkit

The NVIDIA Container Toolkit allows containers to access GPU resources.

### 2.1 Add NVIDIA Package Repository
```bash
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
```

### 2.2 Install NVIDIA Container Toolkit
```bash
sudo apt update
sudo apt install -y nvidia-container-toolkit
```

### 2.3 Verify Installation
```bash
nvidia-ctk --version
```

---

## Step 3: Install MicroK8s

### 3.1 Install MicroK8s via Snap
```bash
sudo snap install microk8s --classic --channel=1.28/stable
```

**Note**: You can use different channels:
- `1.28/stable` - Kubernetes 1.28 (recommended)
- `1.29/stable` - Kubernetes 1.29
- `latest/stable` - Latest stable version

### 3.2 Add User to MicroK8s Group
```bash
sudo usermod -a -G microk8s $USER
sudo chown -f -R $USER ~/.kube
```

### 3.3 Apply Group Changes
**Option A: Re-login**
```bash
# Log out and log back in
```

**Option B: Use newgrp (temporary)**
```bash
newgrp microk8s
```

### 3.4 Verify MicroK8s Installation
```bash
microk8s status --wait-ready
```

---

## Step 4: Configure MicroK8s

### 4.1 Enable Core Addons
```bash
# DNS for service discovery
microk8s enable dns

# Storage for persistent volumes
microk8s enable storage

# Helm package manager
microk8s enable helm3
```

### 4.2 Setup kubectl Access

**Create kubectl alias:**
```bash
echo "alias kubectl='microk8s kubectl'" >> ~/.bashrc
echo "alias helm='microk8s helm3'" >> ~/.bashrc
source ~/.bashrc
```

**Or create kubeconfig:**
```bash
mkdir -p ~/.kube
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config
```

### 4.3 Verify Cluster
```bash
microk8s kubectl get nodes
microk8s kubectl get pods -A
```

---

## Step 5: Enable GPU Support

### 5.1 Enable GPU Addon
```bash
microk8s enable gpu
```

This addon will:
- Install NVIDIA device plugin
- Configure containerd for GPU support
- Set up runtime classes

### 5.2 Wait for GPU Operator Components
```bash
# Wait for all pods to be ready (may take 2-5 minutes)
watch microk8s kubectl get pods -n kube-system
```

Press `Ctrl+C` when all pods show `Running` or `Completed` status.

### 5.3 Check GPU Device Plugin
```bash
microk8s kubectl get pods -n kube-system | grep nvidia
```

You should see `nvidia-device-plugin-daemonset` running.

---

## Step 6: Verify GPU Setup

### 6.1 Check Node GPU Capacity
```bash
microk8s kubectl get nodes -o json | jq '.items[].status.capacity'
```

Look for `nvidia.com/gpu` in the output. It should show the number of GPUs.

**Alternative without jq:**
```bash
microk8s kubectl describe node | grep -A 5 "Capacity:"
```

### 6.2 Verify GPU Allocatable Resources
```bash
microk8s kubectl describe node | grep -i gpu
```

You should see:
```
nvidia.com/gpu:     1  (or your GPU count)
```

### 6.3 Check All Components
```bash
# Check all system pods
microk8s kubectl get pods -n kube-system

# Check for GPU-related pods
microk8s kubectl get pods -A | grep -i nvidia

# Check node details
microk8s kubectl get nodes -o wide
```

---

## Step 7: Deploy Test Workloads

### 7.1 Simple GPU Test Pod

Create a file `gpu-test-pod.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test-pod
spec:
  restartPolicy: OnFailure
  containers:
  - name: cuda-container
    image: nvidia/cuda:12.2.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
```

Deploy and check:
```bash
microk8s kubectl apply -f gpu-test-pod.yaml
microk8s kubectl wait --for=condition=Ready pod/gpu-test-pod --timeout=60s
microk8s kubectl logs gpu-test-pod
```

You should see `nvidia-smi` output showing your GPU.

### 7.2 GPU Test Job

Create `gpu-test-job.yaml`:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: gpu-test-job
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: cuda-test
        image: nvidia/cuda:12.2.0-base-ubuntu22.04
        command:
          - /bin/bash
          - -c
          - |
            echo "=== GPU Test Starting ==="
            nvidia-smi
            echo "=== GPU Details ==="
            nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
            echo "=== Test Complete ==="
        resources:
          limits:
            nvidia.com/gpu: 1
  backoffLimit: 4
```

Deploy and check:
```bash
microk8s kubectl apply -f gpu-test-job.yaml
microk8s kubectl wait --for=condition=complete job/gpu-test-job --timeout=120s
microk8s kubectl logs job/gpu-test-job
```

### 7.3 PyTorch GPU Test

Create `pytorch-test.yaml`:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pytorch-gpu-test
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: pytorch
        image: pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
        command:
          - python3
          - -c
          - |
            import torch
            print("PyTorch version:", torch.__version__)
            print("CUDA available:", torch.cuda.is_available())
            if torch.cuda.is_available():
                print("GPU count:", torch.cuda.device_count())
                print("GPU name:", torch.cuda.get_device_name(0))
                x = torch.rand(5, 3).cuda()
                print("Tensor on GPU:", x.device)
                print("✓ Test successful!")
            else:
                print("✗ CUDA not available!")
                exit(1)
        resources:
          limits:
            nvidia.com/gpu: 1
```

Deploy and check:
```bash
microk8s kubectl apply -f pytorch-test.yaml
microk8s kubectl wait --for=condition=complete job/pytorch-gpu-test --timeout=180s
microk8s kubectl logs job/pytorch-gpu-test
```

### 7.4 Deploy Jupyter Notebook with GPU

Create `jupyter-gpu.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jupyter-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jupyter-gpu
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jupyter-gpu
  template:
    metadata:
      labels:
        app: jupyter-gpu
    spec:
      containers:
      - name: jupyter
        image: pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
        command: ["/bin/bash"]
        args:
          - -c
          - |
            pip install jupyter jupyterlab matplotlib numpy pandas
            jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --NotebookApp.token='' --NotebookApp.password=''
        ports:
        - containerPort: 8888
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: "8Gi"
        volumeMounts:
        - name: data
          mountPath: /workspace
        workingDir: /workspace
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: jupyter-data
---
apiVersion: v1
kind: Service
metadata:
  name: jupyter-gpu
spec:
  selector:
    app: jupyter-gpu
  ports:
  - port: 8888
    targetPort: 8888
  type: ClusterIP
```

Deploy:
```bash
microk8s kubectl apply -f jupyter-gpu.yaml
```

Access Jupyter:
```bash
# Port forward to access locally
microk8s kubectl port-forward svc/jupyter-gpu 8888:8888
```

Open browser: http://localhost:8888

---

## Troubleshooting

### GPU Not Detected in Cluster

**Check NVIDIA drivers on host:**
```bash
nvidia-smi
```

**Check containerd configuration:**
```bash
microk8s kubectl get pods -n kube-system | grep nvidia-device-plugin
microk8s kubectl logs -n kube-system -l name=nvidia-device-plugin-ds
```

**Restart MicroK8s:**
```bash
microk8s stop
microk8s start
microk8s status --wait-ready
```

### GPU Addon Not Enabling

**Check addon status:**
```bash
microk8s status
```

**Manually check device plugin:**
```bash
microk8s kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset
```

**Re-enable GPU addon:**
```bash
microk8s disable gpu
microk8s enable gpu
```

### Pods Stuck in Pending

**Check pod events:**
```bash
microk8s kubectl describe pod <pod-name>
```

**Check node resources:**
```bash
microk8s kubectl describe node
```

**Common issues:**
- GPU already allocated to another pod
- Insufficient memory/CPU
- Image pull errors

### Container Runtime Issues

**Check containerd:**
```bash
microk8s ctr version
```

**Restart containerd:**
```bash
microk8s stop
sudo systemctl restart snap.microk8s.daemon-containerd
microk8s start
```

### Permission Issues

**Fix permissions:**
```bash
sudo usermod -a -G microk8s $USER
sudo chown -f -R $USER ~/.kube
newgrp microk8s
```

### DNS Not Working

**Enable DNS addon:**
```bash
microk8s enable dns
```

**Check CoreDNS:**
```bash
microk8s kubectl get pods -n kube-system -l k8s-app=kube-dns
```

---

## Useful Commands

### Cluster Management
```bash
# Check cluster status
microk8s status

# Stop cluster
microk8s stop

# Start cluster
microk8s start

# Inspect cluster configuration
microk8s inspect

# Reset cluster (WARNING: destroys all data)
microk8s reset
```

### Pod Management
```bash
# List all pods
microk8s kubectl get pods -A

# Watch pods
watch microk8s kubectl get pods -A

# Get pod logs
microk8s kubectl logs <pod-name>

# Follow pod logs
microk8s kubectl logs -f <pod-name>

# Describe pod
microk8s kubectl describe pod <pod-name>

# Execute command in pod
microk8s kubectl exec -it <pod-name> -- bash
```

### GPU Monitoring
```bash
# Check GPU allocation
microk8s kubectl get nodes -o json | jq '.items[].status.allocatable'

# Watch GPU pods
watch microk8s kubectl get pods -A -o wide

# Check device plugin logs
microk8s kubectl logs -n kube-system -l name=nvidia-device-plugin-ds -f
```

### Cleanup
```bash
# Delete specific resources
microk8s kubectl delete pod <pod-name>
microk8s kubectl delete job <job-name>
microk8s kubectl delete deployment <deployment-name>

# Delete all jobs
microk8s kubectl delete jobs --all

# Delete all pods in namespace
microk8s kubectl delete pods --all -n default
```

### Complete Uninstall
```bash
# Stop MicroK8s
microk8s stop

# Remove MicroK8s
sudo snap remove microk8s --purge

# Remove user from group
sudo deluser $USER microk8s

# Clean up config
rm -rf ~/.kube/config
```

---

## Additional Resources

### Enable More Addons
```bash
# Dashboard
microk8s enable dashboard

# Ingress
microk8s enable ingress

# Metrics server
microk8s enable metrics-server

# Prometheus
microk8s enable prometheus

# Registry
microk8s enable registry
```

### Access Dashboard
```bash
microk8s enable dashboard
microk8s kubectl port-forward -n kube-system service/kubernetes-dashboard 10443:443
```

Access: https://localhost:10443

Get token:
```bash
microk8s kubectl create token default
```

### Resource Limits
```bash
# Set default resource limits
microk8s kubectl create namespace gpu-workloads
microk8s kubectl create quota gpu-quota --hard=requests.nvidia.com/gpu=1 -n gpu-workloads
```

---

## Best Practices

1. **Always specify GPU limits** in pod specs to avoid resource conflicts
2. **Use namespaces** to organize workloads
3. **Monitor GPU usage** with `nvidia-smi` on the host
4. **Set resource requests and limits** for CPU and memory
5. **Use persistent volumes** for important data
6. **Regular backups** of configurations and data
7. **Keep MicroK8s updated**: `sudo snap refresh microk8s`

---

## Quick Start Summary

```bash
# 1. Install NVIDIA drivers
sudo ubuntu-drivers autoinstall
sudo reboot

# 2. Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit

# 3. Install MicroK8s
sudo snap install microk8s --classic --channel=1.28/stable
sudo usermod -a -G microk8s $USER
newgrp microk8s

# 4. Enable addons
microk8s enable dns storage helm3 gpu

# 5. Verify
microk8s kubectl get nodes
microk8s kubectl get pods -A

# 6. Test GPU
cat <<EOF | microk8s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: OnFailure
  containers:
  - name: cuda
    image: nvidia/cuda:12.2.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

microk8s kubectl logs gpu-test
```

---

**Setup complete! Your single-node MicroK8s cluster with GPU support is ready for AI/ML workloads.**
