# MicroK8s GPU Deployment for Single Node

Simple, production-ready MicroK8s setup with GPU support - perfect for single-node AI/ML workloads.

## Why MicroK8s?

✅ **Simple** - No complex multi-node configuration  
✅ **Fast** - Up and running in minutes  
✅ **Lightweight** - Minimal resource overhead  
✅ **Production-ready** - Full Kubernetes features  
✅ **GPU-enabled** - Built-in GPU addon  
✅ **Single-node optimized** - Perfect for your use case  

## Quick Start

### Prerequisites
- Ubuntu 20.04/22.04/24.04
- NVIDIA GPU
- 4GB+ RAM
- Sudo privileges

### Installation (5 minutes)

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

# 4. Enable GPU support
microk8s enable dns storage gpu

# 5. Verify
microk8s kubectl get nodes
```

### Test GPU Access

```bash
# Apply test workload
microk8s kubectl apply -f example-gpu-workload.yaml

# Check logs
microk8s kubectl logs gpu-test-pod
```

## Documentation

📖 **[Complete Setup Guide](MICROK8S_GPU_SETUP.md)** - Detailed step-by-step instructions

## What's Included

### Configuration Files
- `example-gpu-workload.yaml` - Simple GPU test pods and deployments
- `pytorch-gpu-test.yaml` - PyTorch and TensorFlow GPU tests
- `jupyter-gpu.yaml` - Jupyter Lab with GPU support

### Scripts (Optional)
- `install-microk8s.sh` - Automated installation
- `verify-gpu-setup.sh` - Verification script
- `cleanup.sh` - Complete removal

### Documentation
- `MICROK8S_GPU_SETUP.md` - Complete manual setup guide
- `README.md` - This file

## Example Workloads

### 1. Simple GPU Test
```bash
microk8s kubectl apply -f example-gpu-workload.yaml
microk8s kubectl logs gpu-test-pod
```

### 2. PyTorch Test
```bash
microk8s kubectl apply -f pytorch-gpu-test.yaml
microk8s kubectl logs job/pytorch-gpu-test
```

### 3. Jupyter Notebook
```bash
microk8s kubectl apply -f jupyter-gpu.yaml
microk8s kubectl port-forward svc/jupyter-gpu 8888:8888
# Open http://localhost:8888
```

## Common Commands

```bash
# Cluster status
microk8s status

# List all pods
microk8s kubectl get pods -A

# Check GPU allocation
microk8s kubectl describe node | grep -i gpu

# View logs
microk8s kubectl logs <pod-name>

# Access pod shell
microk8s kubectl exec -it <pod-name> -- bash
```

## Troubleshooting

### GPU not detected?
```bash
# Check host GPU
nvidia-smi

# Check device plugin
microk8s kubectl get pods -n kube-system | grep nvidia

# Restart GPU addon
microk8s disable gpu
microk8s enable gpu
```

### Permission issues?
```bash
sudo usermod -a -G microk8s $USER
newgrp microk8s
```

See [MICROK8s_GPU_SETUP.md](MICROK8S_GPU_SETUP.md#troubleshooting) for more troubleshooting steps.

## Advantages Over RKE2/Kubeadm

| Feature | MicroK8s | RKE2 | Kubeadm |
|---------|----------|------|---------|
| Single-node setup | ✅ Optimized | ⚠️ Complex | ⚠️ Complex |
| Installation time | 5 min | 30+ min | 30+ min |
| GPU addon | ✅ Built-in | ❌ Manual | ❌ Manual |
| Resource overhead | Low | Medium | Medium |
| Configuration | Minimal | Extensive | Extensive |
| Updates | `snap refresh` | Manual | Manual |

## Architecture

```
┌─────────────────────────────────────┐
│         Host Machine                │
│  Ubuntu 24.04 + NVIDIA Drivers      │
│                                     │
│  ┌───────────────────────────────┐ │
│  │       MicroK8s Cluster        │ │
│  │                               │ │
│  │  ┌─────────────────────────┐ │ │
│  │  │   GPU Device Plugin     │ │ │
│  │  └─────────────────────────┘ │ │
│  │                               │ │
│  │  ┌─────────────────────────┐ │ │
│  │  │   Your GPU Workloads    │ │ │
│  │  │   - PyTorch             │ │ │
│  │  │   - TensorFlow          │ │ │
│  │  │   - Jupyter             │ │ │
│  │  └─────────────────────────┘ │ │
│  │                               │ │
│  └───────────────────────────────┘ │
│              ↓                      │
│  ┌───────────────────────────────┐ │
│  │    NVIDIA GPU (RTX 2x)        │ │
│  └───────────────────────────────┘ │
└─────────────────────────────────────┘
```

## Next Steps

1. ✅ Follow [MICROK8S_GPU_SETUP.md](MICROK8S_GPU_SETUP.md) for installation
2. ✅ Deploy test workloads to verify GPU access
3. ✅ Deploy your AI/ML applications
4. ✅ Monitor with `microk8s kubectl top nodes` (enable metrics-server)
5. ✅ Add dashboard: `microk8s enable dashboard`

## Additional Addons

```bash
# Monitoring
microk8s enable metrics-server
microk8s enable prometheus

# Dashboard
microk8s enable dashboard

# Ingress (for external access)
microk8s enable ingress

# Registry (for custom images)
microk8s enable registry
```

## Support

- **MicroK8s Docs**: https://microk8s.io/docs
- **NVIDIA GPU Operator**: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/
- **DeepOps**: https://github.com/NVIDIA/deepops

## License

This configuration is part of the DeepOps project.

---

**Ready to deploy? Start with [MICROK8S_GPU_SETUP.md](MICROK8S_GPU_SETUP.md)!** 🚀
