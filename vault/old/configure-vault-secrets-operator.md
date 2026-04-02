# Configure Vault Secrets Operator

# FYI
- I'm running vault in openshift.
- These steps are divided into three parts
-- Vault Client / VSO: create creds necessary for vault to talk to OCP
-- Vault Server: create auth and secrets
-- Vault Client / VSO: consumers of the secrets and can be automated through git

# On VSO cluster (secret consumer), create a namespace, SA, secret, and token
- for automating during cluster builds, add this to drop-in manifests
```
cat << EOF > vso-bootstrap.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: vault-auth
---    
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-reviewer
  namespace: vault-auth
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-reviewer-token
  namespace: vault-auth
  annotations:
    kubernetes.io/service-account.name: vault-reviewer
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-reviewer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-reviewer
  namespace: vault-auth
EOF
oc apply -f vso-bootstrap.yaml
```

# Provide this to vault server admins: (used below)
- for automation, use ansible/terriform/etc to capture and consume this information. The flow can go something like this
-- CI/CD creates Cluster A
-- CI/CD logs into the External Vault (using its own existing credentials).
-- CI/CD generates a Short-Lived Token (TTL: 15m).
-- CI/CD uses oc to grab the Cluster A CA cert and Reviewer token.
-- CI/CD calls the Vault API (via curl) to "Seed" the connection.
-- CI/CD Deploys the VSO manifests.
-- For example:

-- RUN INSIDE YOUR CI/CD PIPELINE ---
-- 1. Get Cluster A Credentials
```
OCP_API=$(oc whoami --show-server)
CA_CERT=$(oc get secret vault-reviewer-token -n vault-auth -o jsonpath='{.data.ca\.crt}')
REVIEWER_TOKEN=$(oc get secret vault-reviewer-token -n vault-auth -o jsonpath='{.data.token}' | base64 -d)
export VAULT_ADDR="https://vault.external-domain.com:8200"
```
# Get a Short-Lived Token from Vault
# (Assuming your CI/CD runner is already authenticated to Vault)
```
TEMP_VAULT_TOKEN=$(vault token create -policy="provisioner-policy" -ttl=15m -field=token)
```
# Seed the External Vault via cURL (The "Handshake")
```
curl --request POST \
    --header "X-Vault-Token: $TEMP_VAULT_TOKEN" \
    --data "{
        \"type\": \"kubernetes\",
        \"description\": \"Auth for Cluster A\"
    }" \
    "$VAULT_ADDR/v1/sys/auth/cluster-a-path"

# 4. Configure the Trust
curl --request POST \
    --header "X-Vault-Token: $TEMP_VAULT_TOKEN" \
    --data "{
        \"kubernetes_host\": \"$OCP_API:6443\",
        \"kubernetes_ca_cert\": \"$(echo $CA_CERT | base64 -d)\",
        \"token_reviewer_jwt\": \"$REVIEWER_TOKEN\",
        \"disable_local_ca_jwt\": true
    }" \
    "$VAULT_ADDR/v1/auth/cluster-a-path/config"
```

# Vault Server Steps
## Install Vault Server on Openshift
```
oc new-project vault-system
# Allow the Vault Server and Injector to run with the required privileges
oc adm policy add-scc-to-user privileged -z vault -n vault-system
oc adm policy add-scc-to-user privileged -z vault-agent-injector -n vault-system

# Install vault helm chart
helm install vault hashicorp/vault \
  --namespace vault-system \
  --set "server.image.repository=registry.connect.redhat.com/hashicorp/vault" \
  --set "server.image.tag=1.15.2-ubi" \
  --set "server.dev.enabled=false" \
  --set "server.dataStorage.enabled=true" \
  --set "server.dataStorage.size=10Gi" \
  --set "server.ui.enabled=true" \
  --set "injector.enabled=true" \
  --set "injector.image.repository=registry.connect.redhat.com/hashicorp/vault-k8s" \
  --set "injector.image.tag=1.7.2-ubi" \
  --set "injector.agentImage.repository=registry.connect.redhat.com/hashicorp/vault" \
  --set "injector.agentImage.tag=1.15.2-ubi"

# Verify pods started
oc get pods -n vault-system

# Note: vault-0 will remain 0/1 READY because it's sealed
```

## One-time vault initialization (Generates Unseal Keys and Root Token)
```
oc exec vault-0 -n vault-system -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-keys.json

# **IMPORTANT** You must save vault-keys.json somewhere. Without it, you can never unseal the secrets

# Unseal the Vault (Use the key from the file we just made)
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' vault-keys.json)
oc exec vault-0 -n vault-system -- vault operator unseal $UNSEAL_KEY

# pods should now be ready
$ oc get pods -n vault-system
NAME                                   READY   STATUS    RESTARTS   AGE
vault-0                                1/1     Running   0          8m47s
vault-agent-injector-db9bc95df-x7c42   1/1     Running   0          8m47s

# Confirm Sealed=false
oc exec vault-0 -n vault-system -- vault status
```

## For future pod restarts, you only have to unseal
- Notice that vault-keys.json is required
```
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' vault-keys.json)
oc exec vault-0 -n vault-system -- vault operator unseal $UNSEAL_KEY
```

## Enable and configure kubernetes auth
```
# Login with your Root Token
ROOT_TOKEN=$(jq -r '.root_token' vault-keys.json)
oc exec vault-0 -n vault-system -- vault login $ROOT_TOKEN

# Enable the Kubernetes auth method
oc exec vault-0 -n vault-system -- vault auth enable -path=<CLUSTER_NAME> kubernetes
```

## Configure Vault to talk to the OpenShift API
```
# Vault running locally
oc exec vault-0 -n vault-system -- vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc"

# Vault running externally
# Get values from step 1 above:
## OCP_API_URL
## CA_CRT
## SA_TOKEN
vault write auth/<CLUSTER_NAME>/config \
    kubernetes_host="https://<OCP_API_URL>" \
    kubernetes_ca_cert=@<CA_CRT file> \
    token_reviewer_jwt="<SA_TOKEN>" \
    disable_local_ca_jwt=true
```

## Configure the "Dev" Engine and Auth
```
# Create "dev" secrets engine
oc exec vault-0 -n vault-system -- vault secrets enable -path=dev kv-v2

# Create the Policy (Piped directly, no tar needed)
echo 'path "dev/data/my-project/*" { capabilities = ["read"] }' | oc exec -i vault-0 -n vault-system -- vault policy write dev-policy -

# Create the Role for the Spoke
oc exec vault-0 -n vault-system -- vault write auth/kubernetes/role/webapp-role \
    bound_service_account_names=default \
    bound_service_account_namespaces=vault-auth,my-namespace \
    policies="dev-policy" \
    ttl=24h
```

## Create and Verify secret
```
oc exec vault-0 -n vault-system -- vault kv put dev/my-project/database username="db-admin" password="password123"
oc exec vault-0 -n vault-system -- vault kv get dev/my-project/database
```

# Access secrets without Vault Secrets Operator
## Create namespace for workload testing
```
oc new-project my-namespace
```

## Create pod
```
oc new-project my-namespace

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: vault-final-test
  namespace: my-namespace
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "webapp-role"
    vault.hashicorp.com/agent-inject-secret-database: "dev/my-project/database"
    vault.hashicorp.com/addr: "http://vault.vault-system.svc:8200"
spec:
  serviceAccountName: default
  containers:
  - name: alpine
    image: alpine
    command: ["sh", "-c", "while true; do sleep 30; done"]
EOF

# Check pods
oc get pods
```

## Verify pod can see secret
```
oc exec vault-final-test -n my-namespace -c alpine -- cat /vault/secrets/database
```

## Create Openshift route
```
oc create route edge vault-ui \
    --service=vault \
    --port=http \
    --hostname=vault-ui-vault-system.apps.cluster-2vccz.2vccz.sandbox5190.opentlc.com \
    -n vault-system

# View route url
oc get route vault-ui -n vault-system -o jsonpath='{.spec.host}'

# Retrieve root token
jq -r '.root_token' vault-keys.json
```

# Access secrets using Vault Secrets Operator
```
# OCP > Operator Hub > Vault Secrets Operator > (take defaults)
```

## Configure CRs
### Create new namespace
```
oc new-project vso-demo-space
```

### Update role with new namespace
```
oc exec vault-0 -n vault-system -- vault write auth/<CLUSTER_NAME>/kubernetes/role/webapp-role \
    bound_service_account_names=default \
    bound_service_account_namespaces="vault-auth,my-namespace,vso-demo-space" \
    policies="dev-policy" \
    ttl=24h

# Verify namespaces are listed
oc exec vault-0 -n vault-system -- vault read auth/kubernetes/role/webapp-role

# Verify default SA has read access
oc adm policy add-role-to-user view system:serviceaccount:vso-demo-space:default -n vso-demo-space
```

### Create Vault Connection
```
cat <<EOF | oc apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault-connection
  namespace: vso-demo-space
spec:
  address: http://vault.vault-system.svc:8200
EOF

```

### Create Vault Auth
```
cat <<EOF | oc apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
  namespace: vso-demo-space
spec:
  method: kubernetes
  mount: <CLUSTER_NAME> # Must match path used in "vault write auth"
  kubernetes:
    role: webapp-role
    serviceAccount: default
  vaultConnectionRef: vault-connection
EOF
```

### Create Vault Static Secret
```
cat <<EOF | oc apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: vault-db-sync
  namespace: vso-demo-space
spec:
  vaultAuthRef: vault-auth
  mount: dev
  type: kv-v2
  path: my-project/database
  destination:
    name: synced-db-secret
    create: true
  refreshAfter: 30s
EOF
```

### Verify
```
oc get secret synced-db-secret -n vso-demo-space
oc extract secret/synced-db-secret -n vso-demo-space --to=-
```

### Test changing a secret
```
# In one window, keep watching secret
oc get secret synced-db-secret -n vso-demo-space -w

# Change the password
## from UI by creating a new version
## from cli:
oc exec vault-0 -n vault-system -- vault kv put dev/my-project/database \
    username="db-admin" \
    password="NewStrongPassword2026"

# Check oc get secrets. A new item will be created
oc get secret synced-db-secret -n vso-demo-space -w
NAME               TYPE     DATA   AGE
synced-db-secret   Opaque   3      5m12s
synced-db-secret   Opaque   3      8m59s

oc extract secret/synced-db-secret -n vso-demo-space --to=-

```

### Will app pickup the change?
```
1. No. If your Pod is configured like this: (Kubernetes only reads that value at the moment the Pod starts)
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: synced-db-secret
        key: password

Restart pod to take effect

2. Eventually (but with a 60-90 sec delay). If you mounted the secret as a file:
volumeMounts:
- name: config
  mountPath: "/etc/config"
  readOnly: true
volumes:
- name: config
  secret:
    secretName: synced-db-secret

3. Almost immediately if you configure app to restart anytime a secret changes. This requires knowing your app's template. See below
Add this to your VaultStaticSecret definition:
spec:
  # ... other fields ...
  destination:
    name: synced-db-secret
    create: true
    # This is the "Magic" flag:
    transformation:
      templates:
        # This creates a NEW key in the K8s secret called 'db_url'
        db_url:
          text: "postgresql://{{ .username }}:{{ .password }}@db.example.com:5432/mydb"
  # Link it to your Deployment
  rolloutRestartTargets:
    - kind: Deployment
      name: my-app-deployment

# Verify in demo
# If you used the Sidecar (the 'database' file):
oc exec vault-final-test -n my-namespace -c alpine -- cat /vault/secrets/database

# If you are checking the VSO synced secret manually:
oc extract secret/synced-db-secret -n vso-demo-space --to=-
```
