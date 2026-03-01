# Cluster GitOps Management Guide

This repository uses OpenShift GitOps (ArgoCD) and Kustomize to manage cluster configurations, operators, and policies.

## Prerequisites
* The managed cluster must be imported into Advanced Cluster Management (ACM).
* The policy-framework add-on must be healthy on the managed cluster to support OperatorPolicies.

## Repository Structure
* bootstrap/: Contains the manual starter manifest used to link a new cluster to this repository.
* components/: Generic versions of operators and policies. Do not edit directly.
* clusters/: Each folder represents a specific cluster configuration.
    * kustomization.yaml: Controls which applications are active.
    * appprojects.yaml: Defines security boundaries (default, virt, hub).

---

## Adding a New Application

### Option A: Using the Framework Script
1. Run: ./new-app-framework.sh <app-name>
2. Configure overlays in clusters/<cluster-name>/overlays/<app-name>
3. Add the app to clusters/<cluster-name>/kustomization.yaml
4. git commit and push.

### Option B: Manual Setup
1. Create Directory: Create clusters/<cluster-name>/<app-name>/.
2. Create Kustomization: Inside that folder, create a kustomization.yaml pointing to the base:
   resources:
     - ../../../../components/<app-name>
3. Define Application: In the cluster root (clusters/<cluster-name>/), create <app-name>-app.yaml.
   - Ensure path points to your new directory.
   - Ensure project is set correctly.
4. Register: Add - <app-name>-app.yaml to the resources list in clusters/<cluster-name>/kustomization.yaml.

---

## Adding a New Cluster

To onboard a brand new cluster to this framework:

1. ACM Registration: Import the cluster into ACM.
2. Create Directory: mkdir -p clusters/<new-cluster-name>
3. Initialize AppProjects: Copy appprojects.yaml from an existing cluster into the new folder.
4. Create Root Kustomization: Create clusters/<new-cluster-name>/kustomization.yaml:
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - appprojects.yaml
5. **CRITICAL STEP (Path Validation)**: If copying existing <app>-app.yaml files to the new cluster folder, you MUST update the 'spec.source.path' in each file to match the new cluster directory name.
6. Bootstrap GitOps:
   export CLUSTER_NAME="<new-cluster-name>"
   envsubst < bootstrap/root-application.yaml | oc apply -f -

---

## Troubleshooting

| Issue | Solution |
| :--- | :--- |
| OperatorPolicy not found | Cluster is not in ACM or Policy Add-on is not installed. |
| Sync Timeout / Namespace Error | DO NOT use a global namespace: in the app kustomization. |
| Patch not applying | Ensure namespace and kind in the patch match the component exactly. |
| App pulling wrong cluster's data | Check the 'spec.source.path' in the <app>-app.yaml manifest. |
| New tile not appearing | Ensure the -app.yaml file is listed in the cluster kustomization. |
## Troubleshooting Common Issues

### Issue: Operator stuck in 'NonCompliant' or CSV not found
If the OperatorPolicy reports that the ClusterServiceVersion is missing even after a sync, it is often due to a 'Manual' InstallPlan blocking the OLM.

**Fix:** Force ACM to recreate the subscription with 'Automatic' approval:
1. oc delete sub <subscription-name> -n <namespace>
2. oc delete installplan --all -n <namespace>

ACM will automatically recreate these objects within 30 seconds, triggering a fresh (and automatic) installation.

### Issue: Instance fails to sync (CRD not found)
This is expected if the Operator is still initializing.
- Check the 'Retry' status in the ArgoCD UI.
- The Application will self-heal and succeed once the Operator finishes deploying the required CRDs.