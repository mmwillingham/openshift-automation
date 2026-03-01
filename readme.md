# This repo has been simplified to use only kustomize.
## NOTE: This configuration assumes a ArgoCD pull method. i.e. GitOps will be running on each cluster and pulling from repo.

### Prerequisites
```
1. Create cluster config folder: ./clusters/<clustername>/kustomization.yaml
2. Import cluster into ACM. Some operators are deployed with OperatorPolicies instead of subscriptions. Operator Policies are part of open-cluster-management. To get these, the cluster needs to be an ACM hub or managed cluster.
```

### TL/DR steps
```

# Prepare environment file (prepare.env)
cat << EOF > prepare.env
# Replace with your values
export CLUSTER_NAME=
export PLATFORM_BASE_DOMAIN=
export CLUSTER_BASE_DOMAIN=<CLUSTER_NAME.PLATFORM_BASE_DOMAIN>
export USERNAME="kubeadmin"
export PASSWORD="<redacted>"
export GITOPS_REPO="https://github.com/mmwillingham/gitops-standards-repo"
export GITOPS_REPO_PATH="gitops-standards-repo"
EOF
cat prepare.env

# Adjust environment file and execute
source prepare.env

# Validate variables and login
echo CLUSTER_NAME: ${CLUSTER_NAME}
echo PLATFORM_BASE_DOMAIN: ${PLATFORM_BASE_DOMAIN}
echo CLUSTER_BASE_DOMAIN: ${CLUSTER_BASE_DOMAIN}
echo USERNAME: ${USERNAME}
echo PASSWORD: ${PASSWORD}
echo GITOPS_REPO: ${GITOPS_REPO}
echo GITOPS_REPO_PATH: ${GITOPS_REPO_PATH}


# Validate login
oc login -u ${USERNAME} -p ${PASSWORD} https://api.${CLUSTER_BASE_DOMAIN}:6443
oc whoami

# Clone repo
git clone ${GITOPS_REPO}
cd ${GITOPS_REPO_PATH}

# Install GitOps
# Make sure you have already created clusters/<clustername>
oc apply -f bootstrap/subscription.yaml
oc apply -f bootstrap/cluster-rolebinding.yaml
sleep 90
oc get pods -n openshift-gitops
oc get pods -n openshift-gitops-operator
oc get argocd -n openshift-gitops
# Don't proceed until the above are complete
envsubst < bootstrap/argocd.yaml | oc apply -f -

# Install root-application
envsubst < bootstrap/root-application.yaml | oc apply -f -

```
####
New App Checklist for the Customer
To  add a new application (e.g., logging-operator), follow these 3 steps:

Check for Base: Does components/logging-operator exist? If not, create the base YAML there.

Decide on Patching:
No Patch? Create clusters/cluster-hqnl9/logging-app.yaml pointing to components/logging-operator.

Need a Patch? Create a folder clusters/cluster-hqnl9/logging-operator/, add a kustomization.yaml and a overlays/ folder, then create the logging-app.yaml pointing to that local folder.

Update Shopping List: Add - logging-app.yaml to the resources list in clusters/cluster-hqnl9/kustomization.yaml.

Git Push: Once pushed, ArgoCD will automatically spawn the new tile.

