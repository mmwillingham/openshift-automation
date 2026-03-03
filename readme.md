## NOTE: This configuration assumes a ArgoCD pull method. i.e. GitOps will be running on each cluster and pulling from repo.

### Prerequisites
```
1. Create cluster config folder with desired apps and overlays: ./clusters/<clustername>/
2. Import cluster into ACM. Some operators are deployed with OperatorPolicies instead of subscriptions. Operator Policies are part of open-cluster-management. To get these, the cluster needs to be an ACM hub or managed cluster.
```

### Steps
```
## Login to OpenShift from the target cluster
oc login...
## validate
oc whoami --show-server
```

#### Prepare environment file (prepare.env)
```
cat << EOF > prepare.env
# Used in argocd.yaml and root-applicationset.yaml
export CLUSTER_NAME=$(oc get ingress.config.openshift.io cluster --template={{.spec.domain}} | cut -d. -f2)
export CLUSTER_BASE_DOMAIN=$(oc get ingress.config.openshift.io cluster --template={{.spec.domain}} | cut -d. -f2-)
export PLATFORM_BASE_DOMAIN=$(oc get ingress.config.openshift.io cluster --template={{.spec.domain}} | cut -d. -f3-)
export GITOPS_REPO="https://github.com/mmwillingham/openshift-automation"
export GITOPS_REPO_PATH="openshift-automation"
EOF
source prepare.env
```

#### Validate variables and login
```
echo CLUSTER_NAME: ${CLUSTER_NAME}
echo CLUSTER_BASE_DOMAIN: ${CLUSTER_BASE_DOMAIN}
# CLUSTER_BASE_DOMAIN = <CLUSTER_NAME>.<PLATFORM_BASE_DOMAIN> 
echo PLATFORM_BASE_DOMAIN: ${PLATFORM_BASE_DOMAIN}
echo GITOPS_REPO: ${GITOPS_REPO}
echo GITOPS_REPO_PATH: ${GITOPS_REPO_PATH}
```

#### Clone repo
```
cd <your git folder>
git clone ${GITOPS_REPO}
cd ${GITOPS_REPO_PATH}
```

#### Install GitOps
```
# Make sure you have already created clusters/<clustername>
oc apply -f bootstrap/subscription.yaml
oc apply -f bootstrap/cluster-rolebinding.yaml
sleep 90
oc get pods -n openshift-gitops
oc get pods -n openshift-gitops-operator
oc get argocd -n openshift-gitops
# Don't proceed until the above are complete
```

#### Update argocd object
```
# Verify variables are replaced correctly, which are all at bottom of file
envsubst < bootstrap/argocd.yaml

# Run it
envsubst < bootstrap/argocd.yaml | oc apply -f -
```

#### Install root-application
```
envsubst < bootstrap/root-applicationset.yaml | oc apply -f -
```

#### Monitor
```
# GitOps Console (two options)
# OpenShift Console > tic-tac-toe grid in the top right > Select "Cluster ArgoCD"
# oc get route -n openshift-gitops openshift-gitops-server --template='https://{{.spec.host}}{{"\n"}}'

# CLI
oc get application -n openshift-gitops
```

### Steps for adding cluster / application
#### New cluster
##### Make changes in git repository
```
1) Copy/paste from similar cluster
2) Adjust clusters/<cluster-name>/kustomization.yaml with desired applications
3) Adjust overlay values if necessary
    # e.g. clusters/<cluster-name>/overlays/<component>
```

#### New Application
```
1) Will this application need patching? i.e. adjustments per cluster?
Yes>
    Copy/paste from similar application and adjust as necessary
        - components/<component>
        - apps/<component>
    Update
        - cluster/<cluster-name>/kustomization.yaml

No>
    Copy/paste from similar application and adjust as necessary
        - components/<component>
    Update
        - cluster/<cluster-name>/kustomization.yaml
```

