# Configure Vault Secrets Operator

# FYI
- running vault on an AWS bastion in a different network is a major pain.
- I'm swiching to running vault in openshift.

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

# For future pod restarts, you only have to unseal
### Notice that vault-keys.json is required
```
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' vault-keys.json)
oc exec vault-0 -n vault-system -- vault operator unseal $UNSEAL_KEY
```

# Enable and configure kubernetes auth
```
# 1. Login with your Root Token
ROOT_TOKEN=$(jq -r '.root_token' vault-keys.json)
oc exec vault-0 -n vault-system -- vault login $ROOT_TOKEN

# 2. Enable the Kubernetes auth method
oc exec vault-0 -n vault-system -- vault auth enable kubernetes

# 3. Configure Vault to talk to the OpenShift API
# In OpenShift, 'kubernetes.default.svc' is the internal address of the API server.
oc exec vault-0 -n vault-system -- vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc"
```

## Create namespace for workload testing
```
oc new-project my-namespace
```

## Configure vault to trust my-namespace
```
oc exec vault-0 -n vault-system -- vault write auth/kubernetes/role/webapp-role \
    bound_service_account_names=default \
    bound_service_account_namespaces=my-namespace \
    policies=default \
    ttl=24h
```

## Configure the "Dev" Engine and Auth
```
# Enable the custom engine
oc exec vault-0 -n vault-system -- vault secrets enable -path=dev kv-v2

# Enable K8s Auth
oc exec vault-0 -n vault-system -- vault auth enable kubernetes
oc exec vault-0 -n vault-system -- vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"

# Create the Policy (Piped directly, no tar needed)
echo 'path "dev/data/my-project/*" { capabilities = ["read"] }' | oc exec -i vault-0 -n vault-system -- vault policy write dev-policy -

# Create the Role for the Spoke
oc exec vault-0 -n vault-system -- vault write auth/kubernetes/role/webapp-role \
    bound_service_account_names=default \
    bound_service_account_namespaces=my-namespace \
    policies="dev-policy" \
    ttl=24h
```

## Create and Verify secret
```
oc exec vault-0 -n vault-system -- vault kv put dev/my-project/database username="db-admin" password="password123"
oc exec vault-0 -n vault-system -- vault kv get dev/my-project/database
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

# Configure Vault Secrets Operator
```
# OCP > Operator Hub > Vault Secrets Operator > (take defaults)
```

# Configure CRs
## Create new namespace
```
oc new-project vso-demo-space
```

## Update role with new namespace
```
oc exec vault-0 -n vault-system -- vault write auth/kubernetes/role/webapp-role \
    bound_service_account_names=default \
    bound_service_account_namespaces="my-namespace,vso-demo-space" \
    policies="dev-policy" \
    ttl=24h

# Verify namespaces are listed
oc exec vault-0 -n vault-system -- vault read auth/kubernetes/role/webapp-role

# Verify default SA has read access
oc adm policy add-role-to-user view system:serviceaccount:vso-demo-space:default -n vso-demo-space
```

## Create Vault Connection
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

## Create Vault Auth
```
cat <<EOF | oc apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
  namespace: vso-demo-space
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: webapp-role
    serviceAccount: default
  vaultConnectionRef: vault-connection
EOF
```

## Create Vault Static Secret
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

## Verify
```
oc get secret synced-db-secret -n vso-demo-space
oc extract secret/synced-db-secret -n vso-demo-space --to=-
```

## Test changing a secret
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

## Will app pickup the change?
```
1. No. If your Pod is configured like this: (Kubernetes only reads that value at the moment the Pod starts)
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: synced-db-secret
        key: password

Restart pod to take effect

2. Eventually (but with a 60-90sec delay). If you mounted the secret as a file:
volumeMounts:
- name: config
  mountPath: "/etc/config"
  readOnly: true
volumes:
- name: config
  secret:
    secretName: synced-db-secret

3. Immediately if yoiu configure app to restart anytime a secret changes
Add this to your VaultStaticSecret definition:
spec:
  # ... other fields ...
  destination:
    name: synced-db-secret
    create: true
    # This is the "Magic" flag:
    transformation:
      templates:
        # (Advanced: helps format the secret for the app)
  # Link it to your Deployment
  rolloutRestartTargets:
    - kind: Deployment
      name: my-app-deployment

# Verify in demo
# If you used the Sidecar (the 'database' file):
oc exec vault-final-test -n my-namespace -c alpine -- cat /vault/secrets/database

# If you are checking the VSO synced secret manually:
oc extract secret/synced-db-secret -n vso-demo-space --to=-
