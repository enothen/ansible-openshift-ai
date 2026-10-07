#!/bin/bash

set -e

echo "=========================================="
echo "OpenShift AI Deployment Verification"
echo "=========================================="
echo

# Check if oc is available and connected
if ! oc whoami &> /dev/null; then
    echo "ERROR: Cannot connect to OpenShift cluster"
    echo "Please check your KUBECONFIG"
    exit 1
fi

echo "Connected to cluster as: $(oc whoami)"
echo

# Check operator installations
echo "=== Operator Status ==="
echo

# Print the status of a specific operator CSV, matched by name pattern within its
# home namespace. OLM copies AllNamespaces operators' CSVs into every namespace,
# so we grep for the specific operator rather than listing the whole namespace.
show_operator() {
    local label=$1 ns=$2 pattern=$3
    local line
    line=$(oc get csv -n "$ns" --no-headers 2>/dev/null | grep -E "$pattern" | head -1)
    if [ -n "$line" ]; then
        echo "  $label: $(echo "$line" | awk '{print $1}') ($(echo "$line" | awk '{print $NF}'))"
    else
        echo "  $label: Not found"
    fi
}

# Prerequisite operators
show_operator "cert-manager" "cert-manager" "cert-manager-operator"
show_operator "Service Mesh 3" "openshift-operators" "servicemeshoperator3"
show_operator "Serverless" "openshift-operators" "serverless-operator"

# DataScienceCluster dependency operators
show_operator "JobSet" "openshift-jobset-operator" "jobset-operator"
show_operator "Connectivity Link" "openshift-operators" "rhcl-operator"
show_operator "LeaderWorkerSet" "openshift-lws-operator" "leader-worker-set"

# OpenShift AI operator
show_operator "OpenShift AI" "redhat-ods-operator" "rhods-operator"

# Optional GPU operators
if oc get namespace nvidia-gpu-operator &> /dev/null; then
    show_operator "NFD" "openshift-nfd" "nfd"
    show_operator "NVIDIA GPU" "nvidia-gpu-operator" "gpu-operator"
fi

echo

# Check operand controllers managed by the dependency operators. Each of these
# operators only deploys its controller after a cluster-scoped operand CR named
# 'cluster' is created (see deploy.sh Step 4).
echo "=== Operand Status (operator-managed controllers) ==="

show_operand() {
    local label=$1 kind=$2
    local avail
    avail=$(oc get "$kind" cluster -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' 2>/dev/null)
    if [ -z "$avail" ]; then
        echo "  $label (cluster CR): Not found"
    elif [ "$avail" = "True" ]; then
        echo "  $label (cluster CR): Available"
    else
        echo "  $label (cluster CR): Not Available"
    fi
}

show_operand "JobSetOperator" "jobsetoperator"
show_operand "LeaderWorkerSetOperator" "leaderworkersetoperator"

echo

# Check DataScienceCluster
echo "=== DataScienceCluster Status ==="
if oc get datasciencecluster default-dsc &> /dev/null; then
    PHASE=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "Phase: $PHASE"
    echo
    echo "Conditions:"
    oc get datasciencecluster default-dsc -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}' 2>/dev/null | sed 's/^/  /' || echo "  No conditions available"
    echo
    echo "Component Status:"
    oc get datasciencecluster default-dsc -o json 2>/dev/null | jq -r '.spec.components | to_entries[] | "  \(.key): \(.value.managementState)"' || echo "  Unable to retrieve component status"
else
    echo "DataScienceCluster 'default-dsc' not found"
fi

echo

# Check key namespaces and pods
echo "=== Pod Status ==="
echo

NAMESPACES="redhat-ods-operator redhat-ods-applications redhat-ods-monitoring"

for ns in $NAMESPACES; do
    if oc get namespace "$ns" &> /dev/null; then
        POD_COUNT=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        RUNNING_COUNT=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep Running | wc -l)
        echo "$ns: $RUNNING_COUNT/$POD_COUNT pods running"

        NOT_RUNNING=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -v Running | grep -v Completed || true)
        if [ -n "$NOT_RUNNING" ]; then
            echo "$NOT_RUNNING" | sed 's/^/  ⚠ /'
        fi
    fi
done

echo

# Check dashboard route
echo "=== OpenShift AI Dashboard ==="
if oc get route rhods-dashboard -n redhat-ods-applications &> /dev/null; then
    DASHBOARD_URL=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')
    echo "Dashboard URL: https://$DASHBOARD_URL"
    echo
    echo "You can access the OpenShift AI dashboard at the above URL"
else
    echo "Dashboard route not found"
    echo "The dashboard may still be deploying. Wait a few minutes and run this script again."
fi

echo

# Check for common model serving namespaces
echo "=== Model Serving Status ==="
if oc get namespace knative-serving &> /dev/null; then
    echo "✓ Knative Serving namespace exists"
    KNATIVE_PODS=$(oc get pods -n knative-serving --no-headers 2>/dev/null | grep Running | wc -l)
    echo "  $KNATIVE_PODS pods running"
else
    echo "✗ Knative Serving not deployed"
fi

# KServe readiness is authoritative for model serving in RHOAI 3.4.
KSERVE_READY=$(oc get datasciencecluster default-dsc -o jsonpath='{range .status.conditions[?(@.type=="KserveReady")]}{.status}{end}' 2>/dev/null)
if [ "$KSERVE_READY" = "True" ]; then
    echo "✓ KServe component Ready"
else
    echo "⚠ KServe component not Ready (status: ${KSERVE_READY:-unknown})"
fi

# Istio/service mesh is optional and depends on the KServe deployment mode, so its
# absence is not an error.
if oc get namespace istio-system &> /dev/null; then
    ISTIO_PODS=$(oc get pods -n istio-system --no-headers 2>/dev/null | grep Running | wc -l)
    echo "  Istio service mesh: present ($ISTIO_PODS pods running)"
else
    echo "  Istio service mesh: not present (not required for this KServe mode)"
fi

echo

# Summary
echo "=========================================="
echo "Verification Complete"
echo "=========================================="
echo

if [ "$PHASE" = "Ready" ]; then
    echo "✓ OpenShift AI is deployed and ready!"
    echo
    echo "Next steps:"
    echo "  1. Access the dashboard using the URL above"
    echo "  2. Create a data science project"
    echo "  3. Launch a workbench or deploy a model"
else
    echo "⚠ OpenShift AI deployment is in progress or has issues"
    echo
    echo "Troubleshooting:"
    echo "  - Check operator logs: oc logs -n redhat-ods-operator deployment/rhods-operator"
    echo "  - Check DataScienceCluster: oc describe datasciencecluster default-dsc"
    echo "  - Check pod status in namespaces listed above"
fi

echo
