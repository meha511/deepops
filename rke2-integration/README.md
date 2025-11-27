# RKE2 GPU Integration - Quick Start Guide

This directory contains configuration files and scripts to help you integrate GPU capabilities into your existing RKE2 cluster using DeepOps tools.

## 📁 Files Overview

| File | Purpose |
|------|---------|
| `setup-host-gpu.sh` | Installs NVIDIA drivers and container toolkit on Ubuntu 24.04 host |
| `deploy-gpu-operator.sh` | Deploys NVIDIA GPU Operator to RKE2 cluster via Helm |
| `verify-gpu-setup.sh` | Comprehensive verification script to test GPU integration |
| `ansible-inventory-example.ini` | Example Ansible inventory for DeepOps automation |
| `gpu-operator-values.yaml` | Helm values for GPU Operator customization |
| `example-gpu-workloads.yaml` | Sample GPU workloads for testing |

## 🚀 Quick Start (3 Steps)

### Step 1: Setup Host GPU (Ubuntu 24.04)
```bash
cd /home/server/Desktop/deepops/rke2-integration
sudo ./setup-host-gpu.sh
# Reboot after completion
sudo reboot
```

After reboot, verify:
```bash
nvidia-smi
```

### Step 2: Deploy GPU Operator to RKE2
```bash
# Set kubeconfig for RKE2
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
# Or from your Vagrant VM: vagrant ssh control -c "sudo cat /etc/rancher/rke2/rke2.yaml" > kubeconfig

# Deploy GPU Operator
cd /home/server/Desktop/deepops/rke2-integration
./deploy-gpu-operator.sh
```

### Step 3: Verify GPU Setup
```bash
./verify-gpu-setup.sh
```

## 📊 Test GPU Workloads

Deploy example workloads:
```bash
kubectl apply -f example-gpu-workloads.yaml

# Check basic GPU test
kubectl logs gpu-test-basic

# Check NVIDIA SMI output
kubectl logs nvidia-smi-check

# Check PyTorch GPU detection
kubectl logs pytorch-gpu-test

# Access Jupyter notebook
kubectl get svc jupyter-gpu
# Access: http://<node-ip>:30888
```

## 🔧 Advanced Configuration

### Use DeepOps Ansible Automation

1. Copy inventory template:
```bash
cp rke2-integration/ansible-inventory-example.ini config/inventory
```

2. Edit with your cluster details:
```bash
vi config/inventory
```

3. Run DeepOps playbooks:
```bash
# Deploy monitoring
cd /home/server/Desktop/deepops
./scripts/k8s/deploy_monitoring.sh

# Deploy Kubeflow
./scripts/k8s/deploy_kubeflow.sh
```

### Customize GPU Operator

Edit `gpu-operator-values.yaml` and redeploy:
```bash
helm upgrade gpu-operator nvidia/gpu-operator \
  -n gpu-operator \
  --values rke2-integration/gpu-operator-values.yaml
```

## 🐛 Troubleshooting

### No GPUs detected
```bash
# Check GPU Operator pods
kubectl get pods -n gpu-operator

# Check device plugin logs
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset

# For VirtualBox: Verify driver on HOST
nvidia-smi
```

### Pods stuck in Pending
```bash
# Check GPU capacity
kubectl get nodes -o json | jq '.items[].status.capacity'

# Check pod events
kubectl describe pod <pod-name>
```

### Driver issues
```bash
# On host machine
nvidia-smi
sudo dmesg | grep -i nvidia

# Check container runtime
sudo ctr image pull docker.io/nvidia/cuda:11.8.0-base-ubuntu22.04
sudo ctr run --rm --gpus 0 docker.io/nvidia/cuda:11.8.0-base-ubuntu22.04 test nvidia-smi
```

## 📚 Next Steps

After successful GPU integration:

1. **Deploy DeepOps Monitoring**
   - Prometheus + Grafana with GPU metrics
   - Command: `./scripts/k8s/deploy_monitoring.sh`
   - Access Grafana: http://\<master\>:30200

2. **Deploy Kubeflow**
   - Full ML platform with Jupyter notebooks
   - Command: `./scripts/k8s/deploy_kubeflow.sh`
   - Access: http://\<master\>:31380

3. **Setup Persistent Storage**
   - Required for ML workloads
   - Command: `ansible-playbook playbooks/k8s-cluster/nfs-client-provisioner.yml`

4. **Deploy Model Serving**
   - NVIDIA Triton Inference Server
   - See examples in `example-gpu-workloads.yaml`

## 📖 Documentation

- Main Plan: `../RKE2_GPU_INTEGRATION_PLAN.md`
- DeepOps K8s Guide: `../docs/k8s-cluster/README.md`
- GPU Operator Docs: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/
- Kubeflow Guide: `../docs/k8s-cluster/kubeflow.md`

## ⚠️ Important Notes

**VirtualBox Limitation**: VirtualBox does not support GPU passthrough. The scripts configure GPU access at the HOST level with container-based GPU sharing. For true VM-level GPU passthrough, consider migrating to KVM/Libvirt.

**RKE2 Compatibility**: These scripts are designed for RKE2 using containerd runtime. Ensure your RKE2 cluster is using containerd (default).

**Resource Requirements**: GPU workloads require significant resources. Ensure your VMs have adequate CPU and memory (recommended: 4+ CPUs, 8+ GB RAM per worker).

## 🆘 Support

For issues:
1. Run verification script: `./verify-gpu-setup.sh`
2. Check GPU Operator logs: `kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset`
3. Review main plan: `../RKE2_GPU_INTEGRATION_PLAN.md`
4. Check DeepOps docs: `../docs/`
