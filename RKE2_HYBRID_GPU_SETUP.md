# RKE2 Hybrid Cluster with Host GPU Worker Node

## Architecture Overview

**Hybrid Cluster Design:**
- **Control Plane**: VirtualBox VM (rke2-control @ 192.168.56.10)
- **GPU Worker Node**: Host machine (Ubuntu 24.04 with 2x RTX 3060)

This architecture solves the VirtualBox GPU passthrough limitation by running the GPU worker directly on the host while keeping cluster management in the VM.

```
┌─────────────────────────────────────────────────────────┐
│ Host Machine: Ubuntu 24.04                              │
│ • 2x NVIDIA RTX 3060 (12GB each)                        │
│ • Driver: 580.95.05                                     │
│ • Role: RKE2 Agent (GPU Worker)                         │
│ • IP: 192.168.56.1 (host-only network)                  │
│                                                         │
│  ┌─────────────────────────────────┐                   │
│  │ VirtualBox VM                   │                   │
│  │ • Hostname: rke2-control        │                   │
│  │ • IP: 192.168.56.10             │                   │
│  │ • Role: RKE2 Server (Control)   │                   │
│  │ • Resources: 4 CPU, 8GB RAM     │                   │
│  └─────────────────────────────────┘                   │
│                                                         │
│  Network: 192.168.56.0/24 (host-only)                   │
└─────────────────────────────────────────────────────────┘
```

---

## Prerequisites Status ✅

From your output, you already have:
- ✅ NVIDIA Driver 580.95.05 installed
- ✅ 2x RTX 3060 GPUs working
- ✅ Container GPU access verified (`ctr run --gpus 0` successful)
- ✅ Modified Vagrantfile (workers removed)

---

## Phase 1: Deploy RKE2 Control Plane in VM

### 1.1 Start the Control VM

```bash
cd /home/server/Desktop/deepops
vagrant up control
```

### 1.2 Install RKE2 Server on Control VM

```bash
# SSH into control VM
vagrant ssh control

# Switch to root
sudo su -

# Install RKE2 server
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="server" sh -

# Create config directory
mkdir -p /etc/rancher/rke2

# Create RKE2 config
cat <<EOF > /etc/rancher/rke2/config.yaml
# Bind to all interfaces so host can connect
tls-san:
  - 192.168.56.10
  - rke2-control
node-ip: 192.168.56.10
advertise-address: 192.168.56.10

# Use Calico or Flannel CNI
cni:
  - calico

# Disable components we don't need on control
disable:
  - rke2-ingress-nginx

# Container runtime
container-runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
EOF

# Enable and start RKE2 server
systemctl enable rke2-server.service
systemctl start rke2-server.service

# Wait for RKE2 to start (may take 2-3 minutes)
systemctl status rke2-server

# Check node status
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
kubectl get nodes

# Get the node token (SAVE THIS - needed for joining host)
cat /var/lib/rancher/rke2/server/node-token
```

**Save the node token output!** You'll need it in Phase 2.

### 1.3 Configure kubectl on Control VM

```bash
# Still on control VM as root
mkdir -p ~/.kube
cp /etc/rancher/rke2/rke2.yaml ~/.kube/config

# Add kubectl to PATH permanently
echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> ~/.bashrc
echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> ~/.bashrc
source ~/.bashrc

# Verify cluster
kubectl get nodes
kubectl get pods -A
```

Expected output:
```
NAME           STATUS   ROLES                       AGE   VERSION
rke2-control   Ready    control-plane,etcd,master   2m    v1.28.x+rke2
```

---

## Phase 2: Join Host as GPU Worker Node

### 2.1 Install RKE2 Agent on Host

**Run on your HOST machine (Ubuntu 24.04):**

```bash
# Install RKE2 agent
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -

# Create config directory
sudo mkdir -p /etc/rancher/rke2
```

### 2.2 Configure RKE2 Agent

**Important:** Replace `<NODE_TOKEN>` with the token from Phase 1.3

```bash
# Create agent config
sudo tee /etc/rancher/rke2/config.yaml <<EOF
server: https://192.168.56.10:9345
token: <NODE_TOKEN>
node-ip: 192.168.56.1
node-name: rke2-gpu-worker
node-label:
  - "nvidia.com/gpu=true"
  - "gpu-node=true"
  - "workload-type=gpu-intensive"

# Use systemd-resolved for DNS
resolv-conf: /run/systemd/resolve/resolv.conf

# Container runtime
container-runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
EOF
```

### 2.3 Configure Containerd for GPU Support

```bash
# Backup existing containerd config if exists
sudo cp /var/lib/rancher/rke2/agent/etc/containerd/config.toml \
     /var/lib/rancher/rke2/agent/etc/containerd/config.toml.backup 2>/dev/null || true

# RKE2 will create containerd config, we'll modify it after first start
```

### 2.4 Start RKE2 Agent

```bash
# Enable and start RKE2 agent
sudo systemctl enable rke2-agent.service
sudo systemctl start rke2-agent.service

# Check status
sudo systemctl status rke2-agent

# Watch logs (Ctrl+C to exit)
sudo journalctl -u rke2-agent -f
```

### 2.5 Configure NVIDIA Container Runtime for RKE2

After RKE2 agent starts, configure GPU support:

```bash
# Wait for containerd socket to be created
sleep 10

# Configure NVIDIA runtime for RKE2's containerd
sudo /usr/bin/nvidia-ctk runtime configure \
  --runtime=containerd \
  --config=/var/lib/rancher/rke2/agent/etc/containerd/config.toml

# Restart RKE2 agent to apply changes
sudo systemctl restart rke2-agent

# Verify it started successfully
sudo systemctl status rke2-agent
```

### 2.6 Verify Node Joined

**From control VM:**

```bash
vagrant ssh control
sudo su -
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

# Check nodes
kubectl get nodes -o wide

# Expected output:
# NAME              STATUS   ROLES                       AGE   VERSION
# rke2-control      Ready    control-plane,etcd,master   10m   v1.28.x+rke2
# rke2-gpu-worker   Ready    <none>                      2m    v1.28.x+rke2

# Verify labels
kubectl get node rke2-gpu-worker --show-labels

# Check node details
kubectl describe node rke2-gpu-worker
```

---

## Phase 3: Deploy NVIDIA GPU Operator

### 3.1 Setup kubectl on Host

**On host machine:**

```bash
# Copy kubeconfig from control VM
vagrant ssh control -c "sudo cat /etc/rancher/rke2/rke2.yaml" > /tmp/rke2-kubeconfig

# Update server address to control VM IP
sed -i 's/127.0.0.1/192.168.56.10/g' /tmp/rke2-kubeconfig

# Set KUBECONFIG
export KUBECONFIG=/tmp/rke2-kubeconfig

# Add to bashrc for persistence
echo "export KUBECONFIG=/tmp/rke2-kubeconfig" >> ~/.bashrc

# Verify access
kubectl get nodes
```

### 3.2 Install Helm (if not already installed)

```bash
# On host
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 3.3 Deploy GPU Operator

```bash
cd /home/server/Desktop/deepops/rke2-integration

# Add NVIDIA Helm repo
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# Create GPU Operator values for hybrid setup
cat > gpu-operator-hybrid-values.yaml <<EOF
# GPU Operator configuration for RKE2 hybrid cluster
# Driver and toolkit already on host, just need device plugin

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
    enabled: false  # Enable if you deploy Prometheus

gfd:
  enabled: true

migManager:
  enabled: false

nfd:
  enabled: true

operator:
  defaultRuntime: containerd

# Only deploy on GPU worker node
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
  --create-namespace \
  --values gpu-operator-hybrid-values.yaml \
  --wait \
  --timeout 10m

# Check deployment
kubectl get pods -n gpu-operator
```

### 3.4 Verify GPU Operator Installation

```bash
# Wait for all pods to be running
kubectl get pods -n gpu-operator --watch

# Check device plugin specifically
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset

# Verify GPU capacity on worker node
kubectl get nodes "-o=custom-columns=NAME:.metadata.name,GPUs:.status.capacity.nvidia\.com/gpu"

# Expected output:
# NAME              GPUs
# rke2-control      <none>
# rke2-gpu-worker   2
```

---

## Phase 4: Test GPU Functionality

### 4.1 Run Basic GPU Test

```bash
# Deploy simple GPU test
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu: "true"
  containers:
  - name: cuda-test
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Wait for completion
kubectl wait --for=condition=Ready pod/gpu-test --timeout=120s

# Check logs
kubectl logs gpu-test

# Expected output: "Test PASSED"

# Cleanup
kubectl delete pod gpu-test
```

### 4.2 Run NVIDIA SMI in Cluster

```bash
kubectl apply -f - <<EOF
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

# Wait and check
sleep 10
kubectl logs nvidia-smi-test

# Should show your RTX 3060 details

# Cleanup
kubectl delete pod nvidia-smi-test
```

### 4.3 Test Multi-GPU Access

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: multi-gpu-test
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu: "true"
  containers:
  - name: pytorch
    image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
    command: ["/bin/bash", "-c"]
    args:
      - |
        python <<PYTHON
        import torch
        print(f"PyTorch version: {torch.__version__}")
        print(f"CUDA available: {torch.cuda.is_available()}")
        print(f"GPU count: {torch.cuda.device_count()}")
        for i in range(torch.cuda.device_count()):
            print(f"GPU {i}: {torch.cuda.get_device_name(i)}")
        PYTHON
    resources:
      limits:
        nvidia.com/gpu: 2  # Request both GPUs
EOF

# Check logs
sleep 15
kubectl logs multi-gpu-test

# Should show both RTX 3060 GPUs

# Cleanup
kubectl delete pod multi-gpu-test
```

### 4.4 Comprehensive Verification

```bash
cd /home/server/Desktop/deepops/rke2-integration
./verify-gpu-setup.sh
```

---

## Phase 5: Deploy DeepOps Components

### 5.1 Setup DeepOps Ansible Inventory

```bash
cd /home/server/Desktop/deepops

# Create inventory for hybrid cluster
cat > config/inventory <<EOF
[all]
rke2-control   ansible_host=192.168.56.10 ansible_user=vagrant ansible_password=vagrant
rke2-gpu-worker ansible_host=192.168.56.1 ansible_connection=local

[kube-master]
rke2-control

[etcd]
rke2-control

[kube-node]
rke2-gpu-worker

[gpu-nodes]
rke2-gpu-worker

[k8s-cluster:children]
kube-master
kube-node

[all:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_become=yes
EOF
```

### 5.2 Deploy Monitoring (Prometheus + Grafana)

```bash
cd /home/server/Desktop/deepops

# Deploy monitoring stack
./scripts/k8s/deploy_monitoring.sh

# Wait for pods to be ready
kubectl get pods -n monitoring --watch

# Access points (from host browser):
# Grafana: http://192.168.56.10:30200 (admin/admin)
# Prometheus: http://192.168.56.10:30500
# Alertmanager: http://192.168.56.10:30400

# GPU dashboards will show metrics from your RTX 3060 GPUs
```

### 5.3 Deploy Persistent Storage

```bash
# Option 1: NFS (simple, good for single node)
ansible-playbook playbooks/k8s-cluster/nfs-client-provisioner.yml

# Option 2: Local storage (better performance for GPU workloads)
ansible-playbook playbooks/k8s-cluster/local-volume-provisioner.yml

# Verify storage class
kubectl get storageclass
```

### 5.4 Deploy Kubeflow (AI/ML Platform)

```bash
cd /home/server/Desktop/deepops

# Deploy Kubeflow
./scripts/k8s/deploy_kubeflow.sh

# This may take 10-15 minutes
# Monitor progress
kubectl get pods -n kubeflow --watch

# Access Kubeflow
# URL: http://192.168.56.10:31380
# Default credentials: deepops@example.com / deepops
```

---

## Phase 6: Deploy AI Workloads

### 6.1 Deploy GPU-Enabled Jupyter Notebook

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jupyter-workspace
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
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
      nodeSelector:
        nvidia.com/gpu: "true"
      containers:
      - name: jupyter
        image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
        command: ["/bin/bash", "-c"]
        args:
          - |
            pip install jupyter jupyterlab matplotlib numpy pandas scikit-learn
            jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
              --NotebookApp.token='' --NotebookApp.password=''
        ports:
        - containerPort: 8888
        volumeMounts:
        - name: workspace
          mountPath: /workspace
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: "16Gi"
            cpu: "4"
          requests:
            memory: "8Gi"
            cpu: "2"
      volumes:
      - name: workspace
        persistentVolumeClaim:
          claimName: jupyter-workspace
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
    nodePort: 30888
  type: NodePort
EOF

# Access Jupyter: http://192.168.56.10:30888
```

### 6.2 Deploy Model Training Job

```bash
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: pytorch-training-demo
spec:
  template:
    spec:
      nodeSelector:
        nvidia.com/gpu: "true"
      restartPolicy: Never
      containers:
      - name: training
        image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
        command: ["/bin/bash", "-c"]
        args:
          - |
            pip install torchvision
            python <<PYTHON
            import torch
            import torch.nn as nn
            import torchvision
            
            print(f"PyTorch version: {torch.__version__}")
            print(f"CUDA available: {torch.cuda.is_available()}")
            print(f"GPU: {torch.cuda.get_device_name(0)}")
            
            # Simple training loop
            device = torch.device("cuda")
            model = torchvision.models.resnet50().to(device)
            criterion = nn.CrossEntropyLoss()
            optimizer = torch.optim.Adam(model.parameters())
            
            print("Training on GPU...")
            for epoch in range(5):
                inputs = torch.randn(32, 3, 224, 224).to(device)
                targets = torch.randint(0, 1000, (32,)).to(device)
                
                outputs = model(inputs)
                loss = criterion(outputs, targets)
                
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()
                
                print(f"Epoch {epoch+1}, Loss: {loss.item():.4f}")
            
            print("Training complete!")
            PYTHON
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: "8Gi"
          requests:
            memory: "4Gi"
EOF

# Monitor training
kubectl logs -f job/pytorch-training-demo
```

### 6.3 Deploy NVIDIA Triton Inference Server

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton-inference
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
      nodeSelector:
        nvidia.com/gpu: "true"
      containers:
      - name: triton
        image: nvcr.io/nvidia/tritonserver:23.08-py3
        args:
          - tritonserver
          - --model-repository=/models
          - --strict-model-config=false
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
  name: triton-inference
spec:
  selector:
    app: triton
  ports:
  - name: http
    port: 8000
    nodePort: 30800
  - name: grpc
    port: 8001
    nodePort: 30801
  - name: metrics
    port: 8002
    nodePort: 30802
  type: NodePort
EOF

# Access Triton: http://192.168.56.10:30800/v2/health/ready
```

---

## Cluster Management

### Accessing the Cluster

**From Host:**
```bash
export KUBECONFIG=/tmp/rke2-kubeconfig
kubectl get nodes
kubectl get pods -A
```

**From Control VM:**
```bash
vagrant ssh control
sudo su -
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
kubectl get nodes
```

### Starting/Stopping Cluster

**Stop Cluster:**
```bash
# Stop host worker
sudo systemctl stop rke2-agent

# Stop control VM
vagrant halt control
```

**Start Cluster:**
```bash
# Start control VM
vagrant up control

# Start host worker
sudo systemctl start rke2-agent

# Verify
kubectl get nodes
```

### Monitoring GPU Usage

```bash
# From host (direct GPU access)
watch -n 1 nvidia-smi

# From Kubernetes
kubectl exec -it <pod-name> -- nvidia-smi

# Via Grafana dashboards
# http://192.168.56.10:30200
```

---

## Troubleshooting

### Worker Node Not Joining

```bash
# On host, check agent logs
sudo journalctl -u rke2-agent -f

# Check network connectivity to control
ping 192.168.56.10
curl -k https://192.168.56.10:9345

# Verify token
sudo cat /etc/rancher/rke2/config.yaml

# Restart agent
sudo systemctl restart rke2-agent
```

### GPU Not Detected in Cluster

```bash
# Check GPU Operator pods
kubectl get pods -n gpu-operator

# Check device plugin logs
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset

# Verify containerd config
sudo cat /var/lib/rancher/rke2/agent/etc/containerd/config.toml | grep -A 10 nvidia

# Reconfigure if needed
sudo /usr/bin/nvidia-ctk runtime configure \
  --runtime=containerd \
  --config=/var/lib/rancher/rke2/agent/etc/containerd/config.toml
sudo systemctl restart rke2-agent
```

### Pods Not Scheduling on GPU Node

```bash
# Check node labels
kubectl get node rke2-gpu-worker --show-labels

# Check node conditions
kubectl describe node rke2-gpu-worker

# Check GPU capacity
kubectl get node rke2-gpu-worker -o json | jq '.status.capacity'

# Verify nodeSelector in pod spec
kubectl get pod <pod-name> -o yaml | grep -A 5 nodeSelector
```

---

## Resource Quotas and Limits

### Set GPU Quotas per Namespace

```bash
kubectl create namespace ml-workloads

kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: ml-workloads
spec:
  hard:
    requests.nvidia.com/gpu: "2"
    limits.nvidia.com/gpu: "2"
EOF
```

### Limit GPU Time per User

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: gpu-limits
  namespace: ml-workloads
spec:
  limits:
  - max:
      nvidia.com/gpu: "1"
    min:
      nvidia.com/gpu: "0"
    type: Container
EOF
```

---

## Performance Optimization

### Enable GPU Persistence Mode

```bash
# On host machine
sudo nvidia-smi -pm 1

# Verify
nvidia-smi -q | grep "Persistence Mode"
```

### Set GPU Clock Speeds

```bash
# On host - set maximum performance
sudo nvidia-smi -lgc 1777  # Adjust based on your GPU
```

### Enable MPS (Multi-Process Service)

For better GPU sharing between containers:

```bash
# On host
sudo nvidia-smi -c EXCLUSIVE_PROCESS
```

---

## Backup and Recovery

### Backup Cluster State

```bash
# Backup RKE2 data
vagrant ssh control -c "sudo tar czf /tmp/rke2-backup.tar.gz /var/lib/rancher/rke2"
vagrant scp control:/tmp/rke2-backup.tar.gz ./backups/

# Backup etcd
kubectl get all -A -o yaml > cluster-backup.yaml
```

---

## Next Steps

1. ✅ **Verify current setup** - Run verification script
2. 🚀 **Deploy your AI models** - Use Jupyter or training jobs
3. 📊 **Monitor GPU usage** - Check Grafana dashboards
4. 🔄 **Scale workloads** - Add more GPU pods as needed
5. 🛡️ **Implement security** - Network policies, RBAC

---

## Quick Reference

| Component | Access URL | Credentials |
|-----------|------------|-------------|
| Kubernetes API | https://192.168.56.10:6443 | Via kubeconfig |
| Grafana | http://192.168.56.10:30200 | admin/admin |
| Prometheus | http://192.168.56.10:30500 | - |
| Kubeflow | http://192.168.56.10:31380 | deepops@example.com / deepops |
| Jupyter | http://192.168.56.10:30888 | No auth |
| Triton | http://192.168.56.10:30800 | - |

## System Commands

```bash
# Cluster status
kubectl get nodes
kubectl get pods -A

# GPU status
nvidia-smi
kubectl get nodes -o json | jq '.items[].status.capacity'

# Control VM
vagrant status
vagrant ssh control
vagrant halt/up control

# Host worker
sudo systemctl status rke2-agent
sudo systemctl start/stop/restart rke2-agent
sudo journalctl -u rke2-agent -f

# Logs
kubectl logs -f <pod-name>
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset
```

---

**Architecture Benefits:**
- ✅ Direct GPU access without VirtualBox limitations
- ✅ Full GPU driver control on host
- ✅ Flexible scaling (can add more VMs as CPU-only workers if needed)
- ✅ Easy debugging (direct nvidia-smi access from host)
- ✅ Better performance (no virtualization overhead for GPU)
