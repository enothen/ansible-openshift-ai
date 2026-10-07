# GPU Support Installation

This overlay installs GPU support for OpenShift AI via two operators:

1. **Node Feature Discovery (NFD)** - Detects hardware features and labels nodes
2. **NVIDIA GPU Operator** - Manages NVIDIA GPU drivers and device plugins

## Installation Order

**CRITICAL**: These operators must be installed **sequentially**, not in parallel.

### Why Sequential Installation?

The NVIDIA GPU Operator relies on NFD labels to identify nodes with GPU hardware. If the GPU operator starts before NFD completes node labeling, it may not properly detect GPUs.

### Installation Steps

The `deploy.sh` script handles this automatically when `ENABLE_GPU=true`:

1. **Install NFD Operator** (`deploy/operators/overlays/gpu/nfd/`)
   - Creates NFD subscription
   - Creates NodeFeatureDiscovery instance
   - Waits for operator to be ready
   - Waits for NFD pods to be running

2. **Wait for NFD Node Labeling** (new wait function)
   - Waits up to 5 minutes for NFD to label all nodes
   - Checks for `feature.node.kubernetes.io/pci-*` labels
   - Confirms GPU PCI labels are present (e.g., `pci-10de.present=true` for NVIDIA)

3. **Install NVIDIA GPU Operator** (`deploy/operators/overlays/gpu/nvidia/`)
   - Creates GPU operator subscription
   - Waits for operator to be ready
   - Waits for GPU operator pods to be running

## Verification

After installation, verify NFD labels:

```bash
# Check for NFD PCI labels
oc get nodes -o json | jq '.items[].metadata.labels | with_entries(select(.key | startswith("feature.node.kubernetes.io/pci")))'

# Check for NVIDIA GPU labels (10de = NVIDIA vendor ID)
oc get nodes -o json | jq '.items[].metadata.labels | with_entries(select(.key | contains("10de")))'
```

Expected labels for NVIDIA GPUs:
- `feature.node.kubernetes.io/pci-10de.present=true`
- `feature.node.kubernetes.io/pci-<device-id>.present=true`

## Manual Installation

If installing manually, follow this order:

```bash
# 1. Install NFD
oc apply -k deploy/operators/overlays/gpu/nfd

# 2. Wait for NFD operator
oc wait --for=condition=Available --timeout=600s \
  csv -l operators.coreos.com/nfd.openshift-nfd -n openshift-nfd

# 3. Wait for NFD to label nodes (check every 10 seconds)
while [ $(oc get nodes -o json | jq '[.items[] | select(.metadata.labels | keys[] | startswith("feature.node.kubernetes.io/pci"))] | length') -eq 0 ]; do
  echo "Waiting for NFD to label nodes..."
  sleep 10
done

# 4. Install NVIDIA GPU Operator
oc apply -k deploy/operators/overlays/gpu/nvidia

# 5. Wait for GPU operator
oc wait --for=condition=Available --timeout=600s \
  csv -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator -n nvidia-gpu-operator
```

## Troubleshooting

### NFD Not Labeling Nodes

Check NFD pods:
```bash
oc get pods -n openshift-nfd
oc logs -n openshift-nfd -l app=nfd-master
```

Check NodeFeatureDiscovery instance:
```bash
oc get nodefeaturediscovery -n openshift-nfd nfd-instance -o yaml
```

### GPU Operator Not Detecting GPUs

If the GPU operator was installed before NFD labeling completed:
```bash
# Restart GPU operator pods to re-trigger node detection
oc delete pods -n nvidia-gpu-operator -l app=gpu-operator
```

## Directory Structure

```
gpu/
├── README.md                            # This file
├── nfd/
│   ├── kustomization.yaml               # NFD-only overlay
│   ├── nfd-subscription.yaml            # NFD operator subscription
│   └── nfd-instance.yaml                # NodeFeatureDiscovery CR
└── nvidia/
    ├── kustomization.yaml               # GPU operator-only overlay
    └── gpu-operator-subscription.yaml   # NVIDIA GPU operator subscription
```

## References

- [NFD Operator Documentation](https://docs.openshift.com/container-platform/latest/hardware_enablement/psap-node-feature-discovery-operator.html)
- [NVIDIA GPU Operator Documentation](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/openshift/contents.html)
