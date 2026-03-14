
# Create a cluster
These commands will create a cluster:
- AWS
- IPI
- dropin manifests that will install
  - gitops
  - ACM

## Steps

### Create ssh key and download clis
```
mkdir -p ~/ocp && cd ~/ocp
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_rsa
curl -L -O https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.20/openshift-client-linux-4.20.15.tar.gz
curl -L -O https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.20/openshift-install-linux.tar.gz
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
curl -L https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64 -o ocm
tar -xvf openshift-client-linux-4.20.15.tar.gz
tar -xvf openshift-install-linux.tar.gz
sudo dnf install unzip -y
unzip awscliv2.zip && rm awscliv2.zip
sudo ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update -y
sudo mv oc /usr/local/bin
sudo mv openshift-install /usr/local/bin
chmod +x ocm
sudo mv ocm /usr/local/bin/
rm kubectl
rm rm *gz
sudo dnf install jq -y
```
### Authenticate and download Red Hat pull-secret
```
# Login to Red Hat (follow instructions provided by the command)
ocm login --use-device-code
```

### Download pull-secret
```
# Retrieve offline token
## Extract the offline token from the OCM config
OFFLINE_TOKEN=$(jq -r '.refresh_token' ~/.config/ocm/ocm.json)

## Exchange the offline token for a temporary access token
ACCESS_TOKEN=$(curl -sX POST https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token \
    -d "grant_type=refresh_token" \
    -d "client_id=ocm-cli" \
    -d "refresh_token=$OFFLINE_TOKEN" | jq -r .access_token)

## Fetch the pull secret JSON payload
curl -sX POST -H "Authorization: Bearer $ACCESS_TOKEN" \
    https://api.openshift.com/api/accounts_mgmt/v1/access_token > /tmp/pull-secret.json

## Validate
jq -e '.auths' /tmp/pull-secret.json > /dev/null && echo "Pull secret is valid."
```

### Set environment variables and create folder
```
#!/bin/bash
# 1. Set environment variables
cd ~/ocp
export CLUSTER_NAME="acm-10"
export BASE_DOMAIN="sandbox2912.opentlc.com"
export AWS_REGION="us-east-2"
export PULL_SECRET=$(cat /tmp/pull-secret.json | tr -d '\n\r ')
export SSH_PUB_KEY=$(cat ~/.ssh/id_rsa.pub | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
export INSTALL_DIR="./$CLUSTER_NAME"
echo $CLUSTER_NAME
echo $BASE_DOMAIN
echo $AWS_REGION
echo $SSH_PUB_KEY
echo $PULL_SECRET

mkdir -p "$CLUSTER_NAME"
```

### --- GENERATE INSTALL-CONFIG.YAML ---
```
cat << EOF > "${INSTALL_DIR}/install-config.yaml"
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  aws:
    region: ${AWS_REGION}
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: m5.xlarge
compute:
- name: worker
  replicas: 3
  platform:
    aws:
      type: m5.xlarge
pullSecret: '${PULL_SECRET}'
sshKey: |
  ${SSH_PUB_KEY}
publish: External
EOF
```
### Validate yamls
```
# Strip non-ASCII/Hidden characters just in case
sed -i 's/[^[:print:]]//g' "${INSTALL_DIR}/install-config.yaml"
python3 -c 'import yaml, sys; print(yaml.safe_load(sys.stdin))' < "${INSTALL_DIR}/install-config.yaml"
```

### --- GENERATE BASE MANIFESTS---
```
openshift-install create manifests --dir="${INSTALL_DIR}"
```

# Create gitops yamls
```
cat <<EOF > "${INSTALL_DIR}/manifests/90_gitops_ns.yaml"
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-gitops
EOF

cat <<EOF > "${INSTALL_DIR}/manifests/99_gitops_sub.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: gitops-1.19
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

ls "${INSTALL_DIR}"/manifests/*_gitops*.yaml
```
### create acm yamls
```
cat <<EOF > "${INSTALL_DIR}/manifests/90_acm_ns.yaml"
apiVersion: v1
kind: Namespace
metadata:
  name: open-cluster-management
  labels:
    # Allows the installer job to run with necessary permissions
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
EOF

cat <<EOF > "${INSTALL_DIR}/manifests/91_acm_og.yaml"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: open-cluster-management
  namespace: open-cluster-management
spec:
  targetNamespaces:
    - open-cluster-management
EOF

cat <<EOF > "${INSTALL_DIR}/manifests/92_acm_subs.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  channel: release-2.16
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

cat <<EOF > "${INSTALL_DIR}/manifests/93_acm_sa.yaml"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: acm-installer-sa
  namespace: open-cluster-management
EOF

cat <<EOF > "${INSTALL_DIR}/manifests/94_acm_crb.yaml"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: acm-installer-admin
subjects:
- kind: ServiceAccount
  name: acm-installer-sa
  namespace: open-cluster-management
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

cat <<'EOF' > "${INSTALL_DIR}/manifests/99_acm_mch_job.yaml"
apiVersion: batch/v1
kind: Job
metadata:
  name: acm-hub-initializer
  namespace: open-cluster-management
spec:
  activeDeadlineSeconds: 4800
  ttlSecondsAfterFinished: 4800
  template:
    spec:
      serviceAccountName: acm-installer-sa
      restartPolicy: OnFailure
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: initializer
        image: quay.io/openshift/origin-cli:latest
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        command:
        - /bin/sh
        - -c
        - |
          set -e
          echo "Phase 1: Waiting for MultiClusterHub CRD..."
          until oc get crd multiclusterhubs.operator.open-cluster-management.io >/dev/null 2>&1; do
            echo "Waiting for CRD..."
            sleep 45
          done

          echo "Phase 2: Waiting for Webhook Service..."
          until oc get service multiclusterhub-operator-webhook -n open-cluster-management >/dev/null 2>&1; do
            echo "Waiting for Service..."
            sleep 45
          done

          echo "Phase 3: Waiting for Webhook Endpoints..."
          until oc get endpoints multiclusterhub-operator-webhook -n open-cluster-management -o jsonpath='{.subsets}' | grep -q "ip"; do
            echo "Webhook pod is not ready yet. Sleeping..."
            sleep 45
          done

          echo "Phase 4: Webhook is live. Applying MultiClusterHub..."
          # Using echo to avoid heredoc indentation issues
          echo "apiVersion: operator.open-cluster-management.io/v1
          kind: MultiClusterHub
          metadata:
            name: multiclusterhub
            namespace: open-cluster-management
          spec:
            availabilityConfig: High" | oc apply -f -

          echo "Installation manifest applied successfully."
EOF

ls "${INSTALL_DIR}"/manifests/*_acm*.yaml
```

### Backup the folder as it will be digested and removed
```
cp -r "${INSTALL_DIR}" "${INSTALL_DIR}-backup"
```

# --- DEPLOY ---
```
openshift-install create cluster --dir="${INSTALL_DIR}" --log-level=info
```

# Destroy
```
# openshift-install destroy cluster --dir="${INSTALL_DIR}" --log-level=info
# rm -rf "${INSTALL_DIR}"
# rm .openshift_install_state.json
# rm .openshift_install.log
```
