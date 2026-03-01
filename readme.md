## NOTE: This configuration assumes a ArgoCD pull method. i.e. GitOps will be running on each cluster and pulling from repo.

### Prerequisites
```
1. Create cluster config folder with desired apps and overlays: ./clusters/<clustername>/
2. Import cluster into ACM. Some operators are deployed with OperatorPolicies instead of subscriptions. Operator Policies are part of open-cluster-management. To get these, the cluster needs to be an ACM hub or managed cluster.
```

### TL/DR steps
```

## Login to OpenShift from the target cluster
## validate
oc whoami --show-server

# Prepare environment file (prepare.env)
cat << EOF > prepare.env
# CLUSTER_NAME used in root-application.yaml and argocd.yaml
export CLUSTER_NAME=$(oc get ingress.config.openshift.io cluster --template={{.spec.domain}} | cut -d. -f2)
# The remaining used in argocd.yaml
export CLUSTER_BASE_DOMAIN=$(oc get ingress.config.openshift.io cluster --template={{.spec.domain}} | cut -d. -f2-)
export PLATFORM_BASE_DOMAIN=$(oc get ingress.config.openshift.io cluster --template={{.spec.domain}} | cut -d. -f3-)
export GITOPS_REPO="https://github.com/mmwillingham/openshift-automation"
export GITOPS_REPO_PATH="openshift-automation"
EOF
source prepare.env

# Validate variables and login
echo CLUSTER_NAME: ${CLUSTER_NAME}
echo CLUSTER_BASE_DOMAIN: ${CLUSTER_BASE_DOMAIN}
# CLUSTER_BASE_DOMAIN = <CLUSTER_NAME>.<PLATFORM_BASE_DOMAIN> 
echo PLATFORM_BASE_DOMAIN: ${PLATFORM_BASE_DOMAIN}
echo GITOPS_REPO: ${GITOPS_REPO}
echo GITOPS_REPO_PATH: ${GITOPS_REPO_PATH}

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

