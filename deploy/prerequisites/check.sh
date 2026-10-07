#!/bin/bash

set -e

echo "=== OpenShift AI Prerequisites Check ==="
echo

# Check KUBECONFIG
if [ -z "$KUBECONFIG" ]; then
    echo "ERROR: KUBECONFIG environment variable is not set"
    exit 1
fi

if [ ! -f "$KUBECONFIG" ]; then
    echo "ERROR: KUBECONFIG file not found: $KUBECONFIG"
    exit 1
fi

echo "✓ KUBECONFIG found: $KUBECONFIG"

# Check cluster connectivity
if ! oc whoami &> /dev/null; then
    echo "ERROR: Cannot connect to OpenShift cluster"
    echo "Please check your KUBECONFIG and cluster connectivity"
    exit 1
fi

echo "✓ Connected to cluster as: $(oc whoami)"

# Check cluster-admin permissions
if ! oc auth can-i '*' '*' --all-namespaces &> /dev/null; then
    echo "ERROR: User does not have cluster-admin permissions"
    echo "OpenShift AI installation requires cluster-admin access"
    exit 1
fi

echo "✓ Cluster-admin permissions verified"

# Check OpenShift version
OCP_VERSION=$(oc version -o json | jq -r '.openshiftVersion' 2>/dev/null || echo "unknown")
OCP_MAJOR=$(echo "$OCP_VERSION" | cut -d. -f1)
OCP_MINOR=$(echo "$OCP_VERSION" | cut -d. -f2)

echo "✓ OpenShift version: $OCP_VERSION"

if [ "$OCP_MAJOR" -lt 4 ] || ([ "$OCP_MAJOR" -eq 4 ] && [ "$OCP_MINOR" -lt 19 ]); then
    echo "WARNING: OpenShift AI 3.4 requires OpenShift 4.19 or later"
    echo "Current version: $OCP_VERSION"
    echo "Proceeding anyway, but installation may fail"
fi

# Check worker nodes
WORKER_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l)
echo "✓ Worker nodes found: $WORKER_COUNT"

if [ "$WORKER_COUNT" -lt 2 ]; then
    echo "WARNING: OpenShift AI recommends at least 2 worker nodes"
    echo "Current count: $WORKER_COUNT"
fi

# Check node resources (CPUs and memory)
echo
echo "Checking worker node resources..."
oc get nodes -l node-role.kubernetes.io/worker -o json | jq -r '
  .items[] |
  "  Node: \(.metadata.name)\n" +
  "    CPUs: \(.status.capacity.cpu)\n" +
  "    Memory: \(.status.capacity.memory)"
'

# Check for storage classes
STORAGE_CLASSES=$(oc get storageclass --no-headers 2>/dev/null | wc -l)
if [ "$STORAGE_CLASSES" -eq 0 ]; then
    echo "WARNING: No storage classes found"
    echo "OpenShift AI components require persistent storage"
else
    echo "✓ Storage classes available: $STORAGE_CLASSES"
    DEFAULT_SC=$(oc get storageclass -o json | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name' | head -1)
    if [ -n "$DEFAULT_SC" ]; then
        echo "  Default storage class: $DEFAULT_SC"
    fi
fi

# Check for GPU support
echo
echo "Checking for GPU support..."

# First check if GPU resources are already exposed in node capacity (operator installed)
GPU_CAPACITY=$(oc get nodes -o json | jq -r '.items[] | .metadata.name as $node | .status.capacity | to_entries[] | select(.key | contains("nvidia")) | "  Node: \($node)\n    \(.key): \(.value)"' 2>/dev/null)

# If not in capacity, check for physical GPU hardware via lspci
GPU_HARDWARE=""
if [ -z "$GPU_CAPACITY" ]; then
    echo "  Checking for physical GPU hardware on nodes..."
    for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
        GPU_DEVICES=$(oc debug node/"$node" -- chroot /host lspci -nn 2>/dev/null | grep -i nvidia || true)
        if [ -n "$GPU_DEVICES" ]; then
            GPU_COUNT=$(echo "$GPU_DEVICES" | wc -l)
            # Extract model names from brackets (e.g., "AD102GL [L40S]" -> "L40S")
            GPU_MODELS=$(echo "$GPU_DEVICES" | sed -n 's/.*\[\([^]]*\)\] \[.*/\1/p' | sort -u | paste -sd ", " -)
            GPU_HARDWARE="${GPU_HARDWARE}  Node: $node\n    GPUs: $GPU_COUNT x NVIDIA $GPU_MODELS\n"
        fi
    done
fi

if [ -n "$GPU_CAPACITY" ]; then
    echo "✓ GPU resources available in cluster"
    echo "$GPU_CAPACITY"
    echo "  (GPU Operator appears to be installed)"
elif [ -n "$GPU_HARDWARE" ]; then
    echo "✓ Physical GPU hardware detected"
    echo -e "$GPU_HARDWARE"
    echo "  Note: GPU resources not yet exposed to Kubernetes"
    echo "  To deploy with GPU support, use: ENABLE_GPU=true ./deploy.sh"
else
    echo "  No GPU hardware detected"
    echo "  GPU support (NFD + NVIDIA Operator) will be skipped unless ENABLE_GPU=true"
fi

# Check required operator packages are available in the catalog
echo
echo "Checking required operator packages in catalog..."

check_operator_package() {
    local pkg=$1
    local desc=$2
    if oc get packagemanifest "$pkg" -n openshift-marketplace &> /dev/null; then
        echo "✓ Operator package available: $pkg ($desc)"
    else
        echo "WARNING: Operator package '$pkg' not found in catalog ($desc)"
        echo "  The DataScienceCluster may not become Ready without it."
    fi
}

# JobSet is required by the 'trainer' component (Kubeflow Trainer v2).
check_operator_package "job-set" "required by DSC 'trainer' component"
# Red Hat Connectivity Link is required by KServe LLMInferenceService.
check_operator_package "rhcl-operator" "required by KServe LLMInferenceService"
# LeaderWorkerSet is required by KServe LLMInferenceService Wide Expert Parallelism.
check_operator_package "leader-worker-set" "required by KServe LLMInferenceService Wide EP"

echo
echo "=== Prerequisites Check Complete ==="
echo "Note: OpenShift AI 3.4 is Early Access (EA2) - not production-ready"
echo
