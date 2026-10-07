#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENABLE_GPU="${ENABLE_GPU:-false}"
DSC_CONFIG="${DSC_CONFIG:-$SCRIPT_DIR/deploy/datasciencecluster/default-dsc.yaml}"
SKIP_PREREQ_CHECK="${SKIP_PREREQ_CHECK:-false}"

echo "=========================================="
echo "OpenShift AI 3.4 Deployment"
echo "=========================================="
echo
echo "Configuration:"
echo "  KUBECONFIG: $KUBECONFIG"
echo "  ENABLE_GPU: $ENABLE_GPU"
echo "  DSC_CONFIG: $DSC_CONFIG"
echo "  SKIP_PREREQ_CHECK: $SKIP_PREREQ_CHECK"
echo

# Function to approve pending install plans
approve_pending_installplans() {
    local namespace=$1

    # Check for unapproved install plans
    local pending_plans=$(oc get installplan -n "$namespace" -o json | jq -r '.items[] | select(.spec.approved==false) | .metadata.name' 2>/dev/null)

    if [ -n "$pending_plans" ]; then
        echo "  Approving pending install plans in $namespace..."
        for plan in $pending_plans; do
            echo "    Approving: $plan"
            oc patch installplan "$plan" -n "$namespace" --type merge -p '{"spec":{"approved":true}}' 2>/dev/null || true
        done
        sleep 5
    fi
}

# Function to wait for operator installation
wait_for_operator() {
    local name=$1
    local namespace=$2
    local timeout=600
    local elapsed=0

    echo "Waiting for operator '$name' in namespace '$namespace' to be ready..."

    while [ $elapsed -lt $timeout ]; do
        # Check and approve any pending install plans
        if [ $((elapsed % 30)) -eq 0 ]; then
            approve_pending_installplans "$namespace"
        fi

        if oc get csv -n "$namespace" 2>/dev/null | grep -q "$name.*Succeeded"; then
            echo "✓ Operator $name is ready"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))

        if [ $((elapsed % 30)) -eq 0 ]; then
            echo "  Still waiting for $name... (${elapsed}s elapsed)"
        fi
    done

    echo "ERROR: Operator $name did not become ready within ${timeout}s"
    echo "Current CSV status:"
    oc get csv -n "$namespace"
    return 1
}

# Function to wait for pods in namespace
wait_for_pods() {
    local namespace=$1
    local timeout=300
    local elapsed=0

    echo "Waiting for pods in namespace '$namespace' to be ready..."

    while [ $elapsed -lt $timeout ]; do
        local not_ready=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | grep -v -E "Running|Completed" | wc -l)

        if [ "$not_ready" -eq 0 ]; then
            echo "✓ All pods in $namespace are ready"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))

        if [ $((elapsed % 30)) -eq 0 ]; then
            echo "  Still waiting for pods in $namespace... (${elapsed}s elapsed)"
        fi
    done

    echo "WARNING: Some pods in $namespace are not ready after ${timeout}s"
    oc get pods -n "$namespace"
    return 0
}

# Function to wait for NFD node labeling
wait_for_nfd_labels() {
    local timeout=300
    local elapsed=0

    echo "Waiting for NFD to label nodes with GPU features..."

    while [ $elapsed -lt $timeout ]; do
        # Check if nodes have NFD PCI labels (indicates NFD has scanned the node)
        local labeled_nodes=$(oc get nodes -o json | jq -r '[.items[] | select(any(.metadata.labels | keys[]; startswith("feature.node.kubernetes.io/pci")))] | length' 2>/dev/null)
        local total_nodes=$(oc get nodes --no-headers 2>/dev/null | wc -l)

        if [ "$labeled_nodes" -eq "$total_nodes" ] && [ "$labeled_nodes" -gt 0 ]; then
            echo "✓ NFD has labeled all $total_nodes node(s)"

            # Show GPU-related labels if any
            local gpu_labels=$(oc get nodes -o json | jq -r '.items[] | .metadata.name as $node | .metadata.labels | to_entries[] | select(.key | contains("pci") and contains("10de")) | "  Node: \($node) - \(.key)"' 2>/dev/null | head -5)
            if [ -n "$gpu_labels" ]; then
                echo "  GPU PCI labels detected:"
                echo "$gpu_labels"
            fi
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))

        if [ $((elapsed % 30)) -eq 0 ]; then
            echo "  Still waiting for NFD labeling... ($labeled_nodes/$total_nodes nodes labeled, ${elapsed}s elapsed)"
        fi
    done

    echo "WARNING: NFD node labeling did not complete within ${timeout}s"
    echo "Current NFD-related labels:"
    oc get nodes -o json | jq -r '.items[] | .metadata.name as $node | .metadata.labels | to_entries[] | select(.key | startswith("feature.node.kubernetes.io")) | "  \($node): \(.key)"' | head -10
    return 0
}

# Run prerequisites check
if [ "$SKIP_PREREQ_CHECK" != "true" ]; then
    echo "=== Running Prerequisites Check ==="
    echo
    "$SCRIPT_DIR/deploy/prerequisites/check.sh"
    echo
    read -p "Press Enter to continue with deployment or Ctrl+C to cancel..."
    echo
fi

# Create namespaces
echo "=== Creating Namespaces ==="
oc apply -f "$SCRIPT_DIR/deploy/operators/base/namespaces.yaml"
echo "✓ Namespaces created"
echo

# Step 1: Install cert-manager operator
echo "=== Installing cert-manager Operator ==="
oc apply -k "$SCRIPT_DIR/deploy/operators/base/cert-manager"
wait_for_operator "cert-manager" "cert-manager"
wait_for_pods "cert-manager"
echo

# Step 2: Install Service Mesh 3 and Serverless operators
# Service Mesh 3 (servicemeshoperator3, sail-based) replaces the end-of-life
# Service Mesh 2 operator. RHOAI 3.4 does not use a ServiceMeshControlPlane; the
# KServe data-science-gateway is served by the OpenShift Gateway API (its own
# sail/Istio istiod managed by the Cluster Ingress Operator), so no SMCP/Istio CR
# is created here.
echo "=== Installing Service Mesh 3 and Serverless Operators ==="
oc apply -k "$SCRIPT_DIR/deploy/operators/base/servicemesh"
wait_for_operator "servicemeshoperator3" "openshift-operators"
wait_for_operator "serverless-operator" "openshift-operators"
wait_for_pods "openshift-serverless"
echo

# Step 3: Install OpenShift AI operator
echo "=== Installing OpenShift AI Operator (3.4) ==="
oc apply -k "$SCRIPT_DIR/deploy/operators/base/rhods"
wait_for_operator "rhods-operator" "redhat-ods-operator"
wait_for_pods "redhat-ods-operator"
echo

# Step 4: Install DataScienceCluster component dependencies
# - JobSet operator: required by the 'trainer' component (Kubeflow Trainer v2).
#   Without it the DSC blocks with "JobSet operator not installed".
#   Supports OwnNamespace only, so it uses a dedicated namespace/OperatorGroup.
# - Red Hat Connectivity Link: required by KServe LLMInferenceService.
#   Cluster-wide operator installed into openshift-operators.
# - LeaderWorkerSet operator: required by KServe LLMInferenceService Wide Expert
#   Parallelism. Supports OwnNamespace only, so it uses a dedicated namespace.
echo "=== Installing DataScienceCluster Dependencies ==="
echo

echo "--- Installing JobSet Operator (required by 'trainer' component) ---"
oc apply -k "$SCRIPT_DIR/deploy/operators/base/jobset"
wait_for_operator "jobset-operator" "openshift-jobset-operator"
wait_for_pods "openshift-jobset-operator"
# The operator needs its operand CR (named 'cluster') to deploy the JobSet
# controller; the DSC 'trainer' component blocks until it exists.
echo "Creating JobSetOperator 'cluster' CR..."
oc wait --for=condition=established crd/jobsetoperators.operator.openshift.io --timeout=120s
oc apply -f "$SCRIPT_DIR/deploy/operators/base/jobset/jobsetoperator.yaml"
echo

echo "--- Installing Red Hat Connectivity Link (required by KServe LLMInferenceService) ---"
oc apply -k "$SCRIPT_DIR/deploy/operators/base/connectivity-link"
wait_for_operator "rhcl-operator" "openshift-operators"
echo

echo "--- Installing LeaderWorkerSet Operator (required by KServe LLMInferenceService Wide EP) ---"
oc apply -k "$SCRIPT_DIR/deploy/operators/base/leaderworkerset"
wait_for_operator "leader-worker-set" "openshift-lws-operator"
wait_for_pods "openshift-lws-operator"
# The operator needs its operand CR (named 'cluster') to deploy the
# LeaderWorkerSet controller.
echo "Creating LeaderWorkerSetOperator 'cluster' CR..."
oc wait --for=condition=established crd/leaderworkersetoperators.operator.openshift.io --timeout=120s
oc apply -f "$SCRIPT_DIR/deploy/operators/base/leaderworkerset/leaderworkersetoperator.yaml"
echo

# Step 5: Optional GPU operators
if [ "$ENABLE_GPU" = "true" ]; then
    echo "=== Installing GPU Support ==="
    echo

    # Step 5a: Install NFD operator first
    echo "--- Installing Node Feature Discovery (NFD) Operator ---"
    oc apply -k "$SCRIPT_DIR/deploy/operators/overlays/gpu/nfd"
    wait_for_operator "nfd" "openshift-nfd"
    wait_for_pods "openshift-nfd"
    echo

    # Step 5b: Wait for NFD to label nodes (required for GPU operator)
    wait_for_nfd_labels
    echo

    # Step 5c: Install NVIDIA GPU operator
    echo "--- Installing NVIDIA GPU Operator ---"
    oc apply -k "$SCRIPT_DIR/deploy/operators/overlays/gpu/nvidia"
    wait_for_operator "gpu-operator-certified" "nvidia-gpu-operator"
    wait_for_pods "nvidia-gpu-operator"
    echo
fi

# Step 6: Create DataScienceCluster
echo "=== Creating DataScienceCluster ==="
if [ ! -f "$DSC_CONFIG" ]; then
    echo "ERROR: DataScienceCluster config not found: $DSC_CONFIG"
    exit 1
fi

echo "Using configuration: $DSC_CONFIG"
oc apply -f "$DSC_CONFIG"
echo "✓ DataScienceCluster created"
echo

# Wait for DataScienceCluster to be ready
echo "=== Waiting for DataScienceCluster to be Ready ==="
echo "This may take several minutes as components are deployed..."
echo

timeout=1200
elapsed=0

while [ $elapsed -lt $timeout ]; do
    phase=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    if [ "$phase" = "Ready" ]; then
        echo "✓ DataScienceCluster is Ready!"
        break
    fi

    sleep 10
    elapsed=$((elapsed + 10))

    if [ $((elapsed % 60)) -eq 0 ]; then
        echo "  Current phase: $phase (${elapsed}s elapsed)"
        conditions=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")
        if [ "$conditions" != "[]" ]; then
            echo "  Conditions:"
            oc get datasciencecluster default-dsc -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}' 2>/dev/null | sed 's/^/    /'
        fi
    fi
done

if [ "$phase" != "Ready" ]; then
    echo "WARNING: DataScienceCluster did not become Ready within ${timeout}s"
    echo "Current status:"
    oc get datasciencecluster default-dsc -o yaml
fi

echo
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo
echo "To verify the deployment, run:"
echo "  ./verify.sh"
echo
echo "To access the OpenShift AI dashboard:"
DASHBOARD_URL=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo "Not yet available")
if [ "$DASHBOARD_URL" != "Not yet available" ]; then
    echo "  https://$DASHBOARD_URL"
else
    echo "  Dashboard route not yet created. Run verify.sh to check status."
fi
echo
