# Kubeadm Hybrid Cluster with Host GPU Worker Node

## Architecture Overview

**Hybrid Cluster Design:**
- **Control Plane**: VirtualBox VM (k8s-control @ 192.168.56.20)
- **GPU Worker Node**: Host machine (Ubuntu 24.04 with 2x RTX 3060)

This architecture solves the VirtualBox GPU passthrough limitation by running the GPU worker directly on the host while keeping cluster management in the VM.

```
┌─────────────────────────────────────────────────────────┐
│ Host Machine: Ubuntu 24.04                              │
│ • 2x NVIDIA RTX 3060 (12GB each)                        │
│ • Driver: 580.95.05                                     │
│ • Role: Kubernetes Worker (GPU Node)                    │
│ • IP: 192.168.56.1 (host-only network)                  │
│                                                         │
│  ┌─────────────────────────────────┐                   │
│  │ VirtualBox VM                   │                   │
│  │ • Hostname: k8s-control         │                   │
│  │ • IP: 192.168.56.20             │                   │
│  │ • Role: Control Plane           │                   │
│  │ • Resources: 4 CPU, 8GB RAM     │                   │
│  └─────────────────────────────────┘                   │
│                                                         │
│  Network: 192.168.56.0/24 (host-only)                   │
└─────────────────────────────────────────────────────────┘
```

---

## Prerequisites Status ✅

From your RKE2 setup, you already have:
- ✅ NVIDIA Driver 580.95.05 installed
- ✅ 2x RTX 3060 GPUs working
- ✅ Container GPU access verified
- ✅ Updated Vagrantfile for kubeadm

---

## Phase 1: Deploy Kubernetes Control Plane in VM

### 1.1 Start the Control VM

```bash
cd /home/server/Desktop/deepops/kubeadm
vagrant up control
```

This will:
- Create Ubuntu 24.04 VM (matching host OS)
- Install basic utilities
- Ready for manual Kubernetes v1.30 installation

### 1.2 Install Kubernetes v1.30 on Control VM

```bash
# SSH into control VM
vagrant ssh control

# Switch to root
sudo su -

# Disable swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Load kernel modules
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Configure sysctl
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Install containerd
apt-get update
apt-get install -y containerd

# Configure containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# Enable SystemdCgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Restart containerd
systemctl restart containerd
systemctl enable containerd

# Install kubeadm, kubelet, kubectl v1.30
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Enable kubelet
systemctl enable kubelet

# Initialize kubeadm with specific settings
kubeadm init \
  --apiserver-advertise-address=192.168.56.20 \
  --apiserver-cert-extra-sans=192.168.56.20,k8s-control \
  --node-name=k8s-control \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --control-plane-endpoint=192.168.56.20:6443

# IMPORTANT: Save the output!
# You'll see something like:
# kubeadm join 192.168.56.20:6443 --token <token> \
#     --discovery-token-ca-cert-hash sha256:<hash>
```

**Save the `kubeadm join` command!** You'll need it in Phase 2.

### 1.3 Configure kubectl on Control VM

```bash
# Still on control VM as root
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Also for vagrant user
mkdir -p /home/vagrant/.kube
cp -i /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config

# Verify cluster
kubectl get nodes
kubectl get pods -A
```

Expected output:
```
NAME          STATUS     ROLES           AGE   VERSION
k8s-control   NotReady   control-plane   1m    v1.30.x
```

Node is `NotReady` because we haven't installed a CNI yet.

### 1.4 Install Calico CNI

```bash
# Still on control VM
# Install Calico operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml

# Download custom resources
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/custom-resources.yaml

# Edit to match our pod CIDR
cat <<EOF > custom-resources.yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 10.244.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
  nodeAddressAutodetectionV4:
    interface: "enp0s8"
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

# Apply Calico
kubectl apply -f custom-resources.yaml

# Wait for Calico to be ready (2-3 minutes)
watch kubectl get pods -n calico-system

# Once all pods are Running, check node status
kubectl get nodes
```

Expected output:
```
NAME          STATUS   ROLES           AGE   VERSION
k8s-control   Ready    control-plane   5m    v1.30.x
```

### 1.5 Allow Workloads on Control Plane (Optional)

If you want to run some pods on control plane:

```bash
# Remove control-plane taint
kubectl taint nodes k8s-control node-role.kubernetes.io/control-plane:NoSchedule-
```

### 1.6 Generate Join Token (if needed later)

```bash
# If you lost the join command, generate a new one
kubeadm token create --print-join-command
```

---

## Phase 2: Join Host as GPU Worker Node

### 2.1 Prepare Host Machine

**Run on your HOST machine (Ubuntu 24.04):**

```bash
# Disable swap
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Load kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Configure sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# Install required packages
sudo apt-get update
sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  socat \
  conntrack \
  ipset
```

### 2.2 Install Containerd with GPU Support

```bash
# Install containerd
sudo apt-get install -y containerd

# Configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Enable SystemdCgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd
sudo systemctl enable containerd

# Configure NVIDIA Container Runtime
sudo nvidia-ctk runtime configure --runtime=containerd

# Restart containerd to apply GPU support
sudo systemctl restart containerd

# Verify GPU access via containerd
sudo ctr image pull docker.io/nvidia/cuda:11.8.0-base-ubuntu22.04
sudo ctr run --rm --gpus 0 docker.io/nvidia/cuda:11.8.0-base-ubuntu22.04 test-gpu nvidia-smi
```

### 2.3 Install Kubeadm, Kubelet, Kubectl

```bash
# Add Kubernetes v1.30 repository
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install Kubernetes components
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Enable kubelet
sudo systemctl enable kubelet
```

### 2.4 Configure Kubelet for GPU Node

```bash
# Create kubelet config directory
sudo mkdir -p /etc/default

# Configure kubelet with node labels
cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-labels=nvidia.com/gpu=true,gpu-node=true,workload-type=gpu-intensive
EOF

# Reload systemd
sudo systemctl daemon-reload
```

### 2.5 Create Calico Directory (Prevent Networking Issues)

```bash
# Create Calico directory with correct nodename (NO TRAILING NEWLINE!)
sudo mkdir -p /var/lib/calico
printf "k8s-gpu-worker" | sudo tee /var/lib/calico/nodename
sudo chmod 755 /var/lib/calico

# Verify no newline
cat /var/lib/calico/nodename | od -c
# Should show: k8s-gpu-worker with NO \n at the end
```

### 2.6 Join the Cluster

**Use the join command from Phase 1.2:**

```bash
# Replace with YOUR actual token and hash from Phase 1.2
sudo kubeadm join 192.168.56.20:6443 \
  --token <your-token> \
  --discovery-token-ca-cert-hash sha256:<your-hash> \
  --node-name k8s-gpu-worker

# Watch the join process
sudo journalctl -u kubelet -f
```

### 2.7 Verify Node Joined

**From control VM:**

```bash
vagrant ssh control

# Check nodes
kubectl get nodes -o wide

# Expected output:
# NAME             STATUS   ROLES           AGE   VERSION
# k8s-control      Ready    control-plane   15m   v1.30.x
# k8s-gpu-worker   Ready    <none>          2m    v1.30.x

# Verify labels
kubectl get node k8s-gpu-worker --show-labels

# Check node details
kubectl describe node k8s-gpu-worker
```

---

## Phase 3: Deploy NVIDIA GPU Operator

### 3.1 Setup kubectl on Host

**On host machine:**

```bash
# Copy kubeconfig from control VM
mkdir -p ~/.kube
vagrant ssh control -c "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config

# Update server address to control VM IP (should already be correct)
sed -i 's/127.0.0.1/192.168.56.20/g' ~/.kube/config

# Set permissions
chmod 600 ~/.kube/config

# Verify access
kubectl get nodes
```

### 3.2 Install Helm

```bash
# On host
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 3.3 Deploy GPU Operator

```bash
# Add NVIDIA Helm repo
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# Create namespace
kubectl create namespace gpu-operator

# Create GPU Operator values for hybrid setup
cat > /tmp/gpu-operator-kubeadm-values.yaml <<EOF
# GPU Operator configuration for Kubeadm hybrid cluster
# Driver and toolkit already on host

driver:
  enabled: false  # Driver already installed on host

toolkit:
  enabled: false  # NVIDIA Container Toolkit already configured

devicePlugin:
  enabled: true
  version: v0.14.1

dcgm:
  enabled: true

dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: false

gfd:
  enabled: true

migManager:
  enabled: false

nfd:
  enabled: true

operator:
  defaultRuntime: containerd
  # Run operator on control plane to avoid network issues
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule

# Device plugin should run on GPU worker
daemonsets:
  priorityClassName: system-node-critical
  tolerations:
    - operator: "Exists"
  nodeSelector:
    nvidia.com/gpu: "true"
EOF

# Install GPU Operator
helm install gpu-operator nvidia/gpu-operator \
  -n gpu-operator \
  --values /tmp/gpu-operator-kubeadm-values.yaml \
  --wait \
  --timeout 10m

# Watch deployment
kubectl get pods -n gpu-operator -w
```

### 3.4 Verify GPU Operator

```bash
# Check all GPU operator pods are running
kubectl get pods -n gpu-operator

# Check GPU capacity on nodes
kubectl get nodes -o json | \
  jq '.items[] | {name: .metadata.name, gpus: .status.capacity}'

# Should show:
# {
#   "name": "k8s-control",
#   "gpus": null
# }
# {
#   "name": "k8s-gpu-worker",
#   "gpus": {
#     "nvidia.com/gpu": "2"
#   }
# }

# Detailed node info
kubectl describe node k8s-gpu-worker | grep -A 10 "Capacity:\|Allocatable:"
```

Expected output should show:
```
Capacity:
  nvidia.com/gpu: 2
Allocatable:
  nvidia.com/gpu: 2
```

---

## Phase 4: Test GPU Functionality

### 4.1 Basic GPU Test

```bash
# Create a simple GPU test pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: OnFailure
  nodeSelector:
    nvidia.com/gpu: "true"
  containers:
  - name: cuda-container
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Wait for completion
kubectl wait --for=condition=Ready pod/gpu-test --timeout=120s

# Check logs
kubectl logs gpu-test

# Should show: "Test PASSED"

# Cleanup
kubectl delete pod gpu-test
```

### 4.2 NVIDIA SMI Test

```bash
# Run nvidia-smi in a pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi-test
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu: "true"
  containers:
  - name: nvidia-smi
    image: nvidia/cuda:11.8.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Wait and check logs
sleep 10
kubectl logs nvidia-smi-test

# Should show GPU information

# Cleanup
kubectl delete pod nvidia-smi-test
```

### 4.3 Multi-GPU Test

```bash
# Test both GPUs
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: multi-gpu-test
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu: "true"
  containers:
  - name: cuda-container
    image: nvidia/cuda:11.8.0-base-ubuntu22.04
    command: ["nvidia-smi", "-L"]
    resources:
      limits:
        nvidia.com/gpu: 2
EOF

# Check logs
sleep 10
kubectl logs multi-gpu-test

# Should list both GPUs:
# GPU 0: NVIDIA GeForce RTX 3060
# GPU 1: NVIDIA GeForce RTX 3060

# Cleanup
kubectl delete pod multi-gpu-test
```

---

## Phase 5: Deploy AI/ML Workloads

### 5.1 Deploy PyTorch Test

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pytorch-gpu-test
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu: "true"
  containers:
  - name: pytorch
    image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
    command:
      - python
      - -c
      - |
        import torch
        print(f"PyTorch version: {torch.__version__}")
        print(f"CUDA available: {torch.cuda.is_available()}")
        print(f"CUDA version: {torch.version.cuda}")
        print(f"GPU count: {torch.cuda.device_count()}")
        if torch.cuda.is_available():
            for i in range(torch.cuda.device_count()):
                print(f"GPU {i}: {torch.cuda.get_device_name(i)}")
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Check logs
sleep 15
kubectl logs pytorch-gpu-test

# Cleanup
kubectl delete pod pytorch-gpu-test
```

### 5.2 Deploy TensorFlow Test

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: tensorflow-gpu-test
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu: "true"
  containers:
  - name: tensorflow
    image: tensorflow/tensorflow:2.13.0-gpu
    command:
      - python
      - -c
      - |
        import tensorflow as tf
        print(f"TensorFlow version: {tf.__version__}")
        print(f"GPU devices: {tf.config.list_physical_devices('GPU')}")
        print(f"Built with CUDA: {tf.test.is_built_with_cuda()}")
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Check logs
sleep 20
kubectl logs tensorflow-gpu-test

# Cleanup
kubectl delete pod tensorflow-gpu-test
```

### 5.3 Deploy Jupyter Notebook with GPU

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: jupyter-gpu
  labels:
    app: jupyter
spec:
  nodeSelector:
    nvidia.com/gpu: "true"
  containers:
  - name: jupyter
    image: jupyter/tensorflow-notebook:latest
    ports:
    - containerPort: 8888
    resources:
      limits:
        nvidia.com/gpu: 1
        memory: "8Gi"
      requests:
        memory: "4Gi"
    env:
    - name: JUPYTER_ENABLE_LAB
      value: "yes"
---
apiVersion: v1
kind: Service
metadata:
  name: jupyter-gpu
spec:
  type: NodePort
  selector:
    app: jupyter
  ports:
  - port: 8888
    targetPort: 8888
    nodePort: 30888
EOF

# Get the token
sleep 30
kubectl logs jupyter-gpu | grep "token="

# Access at: http://192.168.56.1:30888
# Or from host: http://localhost:30888
```

---

## Phase 6: Deploy DeepOps Components (Optional)

### 6.1 Deploy Kubeflow

```bash
# Install kustomize
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/

# Clone Kubeflow manifests
cd /tmp
git clone https://github.com/kubeflow/manifests.git
cd manifests

# Deploy Kubeflow
while ! kustomize build example | kubectl apply -f -; do echo "Retrying..."; sleep 10; done

# Wait for all pods to be ready (this takes 10-15 minutes)
kubectl get pods -n kubeflow

# Access Kubeflow dashboard
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80 --address 0.0.0.0

# Access at: http://192.168.56.1:8080
# Default credentials: user@example.com / 12341234
```

### 6.2 Deploy Monitoring Stack

```bash
# Install Prometheus Operator
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false

# Access Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80 --address 0.0.0.0

# Access at: http://192.168.56.1:3000
# Default credentials: admin / prom-operator
```

### 6.3 Enable GPU Metrics in Prometheus

```bash
# Update GPU Operator to enable service monitor
helm upgrade gpu-operator nvidia/gpu-operator \
  -n gpu-operator \
  --reuse-values \
  --set dcgmExporter.serviceMonitor.enabled=true

# Verify DCGM metrics
kubectl get servicemonitor -n gpu-operator
```

---

## Troubleshooting

### Issue 1: Node Not Joining

**Symptoms:** `kubeadm join` fails, times out, or version mismatch errors

**Solutions:**
```bash
# Check versions match
kubeadm version  # On both control and worker

# If version mismatch, install matching version
# Example: Install v1.30.x on host to match control
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get remove -y kubeadm kubelet kubectl
sudo apt-get install -y kubeadm=1.30.x-1.1 kubelet=1.30.x-1.1 kubectl=1.30.x-1.1
sudo apt-mark hold kubeadm kubelet kubectl

# On host, check kubelet logs
sudo journalctl -u kubelet -f

# Verify connectivity to control plane
ping 192.168.56.20
nc -zv 192.168.56.20 6443

# Check firewall
sudo ufw status
sudo ufw disable  # Or allow specific ports

# Reset and retry
sudo kubeadm reset
sudo rm -rf /etc/cni/net.d/*
# Then retry join command
```

### Issue 2: Calico Networking Issues

**Symptoms:** Pods stuck in `ContainerCreating`, errors about calico/node

**Solutions:**
```bash
# On host, ensure nodename file is correct (NO NEWLINE!)
sudo rm -f /var/lib/calico/nodename
printf "k8s-gpu-worker" | sudo tee /var/lib/calico/nodename

# Verify
cat /var/lib/calico/nodename | od -c

# Restart kubelet
sudo systemctl restart kubelet

# Delete and recreate pod
kubectl delete pod <pod-name> -n <namespace>
```

### Issue 3: GPU Not Detected

**Symptoms:** `nvidia.com/gpu: 0` or GPU not showing in node capacity

**Solutions:**
```bash
# Check GPU operator pods
kubectl get pods -n gpu-operator

# Check device plugin logs
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset

# Verify containerd GPU config
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd
sudo systemctl restart kubelet

# Check host GPU access
sudo ctr run --rm --gpus 0 docker.io/nvidia/cuda:11.8.0-base-ubuntu22.04 test nvidia-smi
```

### Issue 4: Pods Can't Access GPUs

**Symptoms:** Pods scheduled but can't see GPUs

**Solutions:**
```bash
# Check if device plugin is running on worker
kubectl get pods -n gpu-operator -o wide | grep device-plugin

# Verify GPU resources
kubectl describe node k8s-gpu-worker | grep nvidia.com/gpu

# Check pod events
kubectl describe pod <pod-name>

# Verify containerd runtime
sudo crictl info | grep -A 5 nvidia
```

### Issue 5: Control Plane Pods Failing

**Symptoms:** Calico or other system pods on worker failing health checks

**Solutions:**
```bash
# Check if pods should be on control plane instead
kubectl get pods -n <namespace> -o wide

# Add tolerations or node selectors
# For GPU operator, ensure operator pod runs on control plane:
helm upgrade gpu-operator nvidia/gpu-operator \
  -n gpu-operator \
  --reuse-values \
  --set operator.nodeSelector."node-role\.kubernetes\.io/control-plane"=""
```

---

## Maintenance and Operations

### Regenerate Join Token

```bash
# On control VM
vagrant ssh control
sudo kubeadm token create --print-join-command
```

### Backup Cluster Configuration

```bash
# On control VM
sudo cp -r /etc/kubernetes /backup/kubernetes-$(date +%Y%m%d)

# Backup etcd
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /backup/etcd-snapshot-$(date +%Y%m%d).db
```

### Upgrade Kubernetes

```bash
# On control VM
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.31.x-1.1
sudo apt-mark hold kubeadm

sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.31.x

# Upgrade kubelet and kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.31.x-1.1 kubectl=1.31.x-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# On host worker
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get update
sudo apt-get install -y kubeadm=1.31.x-1.1 kubelet=1.31.x-1.1 kubectl=1.31.x-1.1
sudo apt-mark hold kubeadm kubelet kubectl

sudo kubeadm upgrade node
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

### Remove Worker Node

```bash
# Drain node
kubectl drain k8s-gpu-worker --ignore-daemonsets --delete-emptydir-data

# Delete node
kubectl delete node k8s-gpu-worker

# On host, reset
sudo kubeadm reset
sudo rm -rf /etc/cni/net.d/*
sudo rm -rf /var/lib/calico
```

---

## Performance Optimization

### 1. CPU Pinning for GPU Workloads

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-workload-optimized
spec:
  containers:
  - name: app
    image: your-gpu-app:latest
    resources:
      requests:
        cpu: "4"
        memory: "16Gi"
        nvidia.com/gpu: 1
      limits:
        cpu: "4"
        memory: "16Gi"
        nvidia.com/gpu: 1
  nodeSelector:
    nvidia.com/gpu: "true"
```

### 2. Enable GPU Time-Slicing (Optional)

```bash
# Create time-slicing config
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-plugin-config
  namespace: gpu-operator
data:
  any: |-
    version: v1
    sharing:
      timeSlicing:
        replicas: 4
EOF

# Update GPU operator
helm upgrade gpu-operator nvidia/gpu-operator \
  -n gpu-operator \
  --reuse-values \
  --set devicePlugin.config.name=device-plugin-config
```

### 3. NUMA Awareness

```bash
# On host, check NUMA topology
numactl --hardware

# Configure kubelet for topology manager
sudo mkdir -p /var/lib/kubelet
cat <<EOF | sudo tee /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
topologyManagerPolicy: best-effort
EOF

sudo systemctl restart kubelet
```

---

## Resource Quotas and Limits

### Create GPU Resource Quota

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

### Create LimitRange for GPU Pods

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: LimitRange
metadata:
  name: gpu-limit-range
  namespace: default
spec:
  limits:
  - max:
      nvidia.com/gpu: "2"
    min:
      nvidia.com/gpu: "0"
    type: Container
EOF
```

---

## Next Steps

1. **Deploy Your AI Models**: Use the GPU cluster for training and inference
2. **Set Up CI/CD**: Integrate with GitOps tools like ArgoCD or Flux
3. **Enable Monitoring**: Deploy full observability stack with Prometheus, Grafana, and GPU metrics
4. **Implement Autoscaling**: Configure HPA for GPU workloads
5. **Add Storage**: Deploy NFS provisioner or Rook-Ceph for persistent storage
6. **Security Hardening**: Implement RBAC, Pod Security Policies, and Network Policies

---

## Comparison: Kubeadm vs RKE2

| Feature | Kubeadm | RKE2 |
|---------|---------|------|
| Installation | Manual, more control | Automated, opinionated |
| CNI | Manual installation | Built-in (Canal/Calico) |
| Upgrades | Manual with kubeadm | Automated |
| Security | Manual hardening | CIS-compliant by default |
| Complexity | Higher learning curve | Easier for beginners |
| Flexibility | More customizable | Less customizable |
| Production Use | Industry standard | Rancher ecosystem |
| Version | v1.30.x | v1.28.x |

---

## Summary

You now have a fully functional Kubernetes v1.30 cluster with:
- ✅ Control plane in VirtualBox VM (Ubuntu 24.04)
- ✅ GPU worker node on host machine (Ubuntu 24.04)
- ✅ 2x RTX 3060 GPUs available to workloads
- ✅ NVIDIA GPU Operator deployed
- ✅ Calico networking
- ✅ Ready for AI/ML workloads

**Key Files:**
- Vagrantfile: `/home/server/Desktop/deepops/kubeadm/Vagrantfile`
- Kubeconfig: `~/.kube/config`
- GPU Operator values: `/tmp/gpu-operator-kubeadm-values.yaml`

**Useful Commands:**
```bash
# Check cluster status
kubectl get nodes
kubectl get pods -A

# Check GPU capacity
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, gpus: .status.capacity}'

# Test GPU
kubectl run gpu-test --rm -it --restart=Never --image=nvidia/cuda:11.8.0-base-ubuntu22.04 --limits=nvidia.com/gpu=1 -- nvidia-smi

# Access control VM
vagrant ssh control

# View GPU operator logs
kubectl logs -n gpu-operator -l app=gpu-operator
```
