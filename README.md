# OpenShift AI 3.4 Deployment

Automated deployment process for Red Hat OpenShift AI 3.4 (Early Access) on existing OpenShift clusters.

## Overview

This repository provides scripts and manifests to deploy OpenShift AI 3.4 on OpenShift Container Platform 4.19 or later. The deployment includes all required operators and dependencies.

**Note:** OpenShift AI 3.4 is currently in Early Access (EA2) status and is not production-ready. Use for testing and development purposes.

## Prerequisites

### Cluster Requirements

- **OpenShift version:** 4.19 or later (tested with 4.21)
- **Worker nodes:** Minimum 2 worker nodes
- **Resources per node:** At least 8 CPUs and 32 GiB RAM
- **Storage:** Storage class available for persistent volumes
- **Access:** cluster-admin permissions required

### Local Requirements

- `oc` CLI installed and configured
- `KUBECONFIG` environment variable set
- `jq` command-line tool (for prerequisites check)

## Quick Start

### 1. Check Prerequisites

```bash
./deploy/prerequisites/check.sh
```

This validates your cluster meets the requirements for OpenShift AI.

### 2. Deploy OpenShift AI

```bash
./deploy.sh
```

This will:
- Create required namespaces
- Install cert-manager operator
- Install Service Mesh and Serverless operators
- Install OpenShift AI operator (3.4 via fast-3.x channel)
- Install DataScienceCluster dependencies (JobSet, Red Hat Connectivity Link, LeaderWorkerSet)
- Create a DataScienceCluster with all components enabled

### 3. Verify Deployment

```bash
./verify.sh
```

This checks operator status, DataScienceCluster readiness, and displays the dashboard URL.

## Configuration Options

### Environment Variables

- `KUBECONFIG` - Path to kubeconfig file (required)
- `ENABLE_GPU` - Set to `true` to install GPU support (default: `false`)
- `DSC_CONFIG` - Path to custom DataScienceCluster YAML (default: `deploy/datasciencecluster/default-dsc.yaml`)
- `SKIP_PREREQ_CHECK` - Set to `true` to skip prerequisite validation (not recommended)

### Examples

**Deploy with GPU support:**
```bash
ENABLE_GPU=true ./deploy.sh
```

**Deploy with minimal configuration:**
```bash
DSC_CONFIG=deploy/datasciencecluster/minimal-dsc.yaml ./deploy.sh
```

**Skip prerequisites check:**
```bash
SKIP_PREREQ_CHECK=true ./deploy.sh
```

## DataScienceCluster Configurations

### Default Configuration

Located at `deploy/datasciencecluster/default-dsc.yaml`, includes all components:
- Dashboard
- Workbenches
- Data Science Pipelines
- Model serving (KServe and ModelMesh)
- Distributed workloads (CodeFlare, Ray, Kueue)
- Training Operator
- TrustyAI

### Minimal Configuration

Located at `deploy/datasciencecluster/minimal-dsc.yaml`, includes only:
- Dashboard
- Workbenches

Use this for testing or when you only need notebook environments.

## Directory Structure

```
.
├── deploy.sh                      # Main deployment script
├── verify.sh                      # Deployment verification script
├── deploy/
│   ├── prerequisites/
│   │   └── check.sh              # Prerequisites validation
│   ├── operators/
│   │   ├── base/
│   │   │   ├── namespaces.yaml       # Required namespaces
│   │   │   ├── cert-manager/         # cert-manager operator
│   │   │   ├── servicemesh/          # Service Mesh + Serverless
│   │   │   ├── rhods/                # OpenShift AI operator
│   │   │   ├── jobset/               # JobSet operator (trainer dependency)
│   │   │   ├── connectivity-link/    # Red Hat Connectivity Link (KServe LLM dependency)
│   │   │   └── leaderworkerset/      # LeaderWorkerSet operator (KServe LLM Wide EP dependency)
│   │   └── overlays/
│   │       └── gpu/                  # GPU support (NFD + NVIDIA)
│   └── datasciencecluster/
│       ├── default-dsc.yaml      # Full configuration
│       └── minimal-dsc.yaml      # Minimal configuration
```

## Deployment Process

The deployment follows this sequence:

1. **Prerequisites Check** - Validates cluster readiness
2. **Namespace Creation** - Creates required namespaces
3. **cert-manager** - Installs cert-manager operator
4. **Service Mesh Stack** - Installs Service Mesh and Serverless operators
5. **OpenShift AI Operator** - Installs rhods-operator (3.4)
6. **DataScienceCluster Dependencies** - Installs JobSet, Red Hat Connectivity Link, and LeaderWorkerSet operators
7. **GPU Support** (optional) - Installs NFD and NVIDIA GPU Operator
8. **DataScienceCluster** - Creates DSC instance to deploy components

Each operator installation waits for the previous one to reach "Succeeded" state before proceeding.

## Accessing OpenShift AI

After successful deployment:

1. Get the dashboard URL:
   ```bash
   oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}'
   ```

2. Open the URL in your browser (use https://)

3. Log in with your OpenShift credentials

## Troubleshooting

### Check Operator Status

```bash
# cert-manager
oc get csv -n cert-manager

# Service Mesh and Serverless
oc get csv -n openshift-operators

# OpenShift AI
oc get csv -n redhat-ods-operator
```

### Check DataScienceCluster Status

```bash
oc get datasciencecluster default-dsc
oc describe datasciencecluster default-dsc
```

### Check Component Pods

```bash
oc get pods -n redhat-ods-operator
oc get pods -n redhat-ods-applications
oc get pods -n redhat-ods-monitoring
```

### View Operator Logs

```bash
oc logs -n redhat-ods-operator deployment/rhods-operator
```

### Common Issues

**DataScienceCluster stuck in "Progressing":**
- Check individual component status in the DSC
- Review pod status in redhat-ods-applications namespace
- Check operator logs for errors

**Dashboard route not accessible:**
- Verify the route exists: `oc get route -n redhat-ods-applications`
- Check dashboard pod is running: `oc get pods -n redhat-ods-applications`

**GPU support not working:**
- Ensure nodes have GPU hardware
- Check NFD has discovered GPUs: `oc get nodes -o json | jq '.items[].metadata.labels' | grep nvidia`
- Verify NVIDIA operator pods are running

## Uninstallation

To remove OpenShift AI:

```bash
# Delete DataScienceCluster
oc delete datasciencecluster default-dsc

# Uninstall operators (delete subscriptions)
oc delete subscription rhods-operator -n redhat-ods-operator
oc delete subscription openshift-jobset-operator -n openshift-jobset-operator
oc delete subscription rhcl-operator -n openshift-operators
oc delete subscription openshift-lws-operator -n openshift-lws-operator
oc delete subscription serverless-operator -n openshift-operators
oc delete subscription servicemeshoperator3 -n openshift-operators
oc delete subscription openshift-cert-manager-operator -n cert-manager

# If GPU support was installed
oc delete subscription gpu-operator-certified -n nvidia-gpu-operator
oc delete subscription nfd -n openshift-nfd

# Clean up namespaces
oc delete namespace redhat-ods-operator redhat-ods-applications redhat-ods-monitoring
```

## References

- [OpenShift AI 3.4 Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4)
- [OpenShift AI 3.4 Release Notes](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/release_notes/index)
- [OpenShift AI 3.x Supported Configurations](https://access.redhat.com/articles/rhoai-supported-configs-3.x)
- [Managing OpenShift AI Dependencies with Kustomize](https://developers.redhat.com/articles/2026/03/13/manage-openshift-ai-dependencies-kustomize-argo-cd)

## License

This deployment automation is provided as-is for use with Red Hat OpenShift AI.
