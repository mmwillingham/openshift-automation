# Configure Vault Secrets Operator using jwt/oidc authorization
## Prerequisites
- Vault server running externally
- Keycloak or other provider running externally

## Bootstrap VSO
- Creates VSO subscription
- for automating during cluster builds, add this to drop-in manifests
```
oc apply -f vso-subscription.yaml
```

## Allow vault to trust cluster
- This can be run manually or from CI-CD (assuming CI-CD has VAULT_TOKEN with "write" access)
```
seed-vault.sh
```

## Define the Vault Role for desired namespaces
- This could be combined with previous command but keeping separate because namespaces might be added.
- This can be run manually or from CI-CD (assuming CI-CD has VAULT_TOKEN with "write" access)
```
authorize-ns-vault.sh
```

## Create VSO CRs (connection and auth)
- Cluster name is hardcoded. Patch with kustomize.
```
oc apply -f vso-auth.yaml

# Note: If your Vault instance uses TLS, create a Kubernetes secret named vault-ca-cert containing your ca.crt, then uncomment the caCertSecretRef section in vso-auth.yaml.
```

# These steps are optional - used for testing
## Create VaultStaticSecret
- Cluster name is hardcoded. Patch with kustomize.
```
oc apply -f vso-secret.yaml
oc describe VaultStaticSecret vault-kv-app-secret -n vso-demo-space
oc get secret k8s-app-secret -n vso-demo-space -o yaml
oc extract secret/k8s-app-secret -n vso-demo-space --to=-
```

## Create test pod
```
oc apply -f test-pod.yaml
oc logs vault-test-app -n vso-demo-space
```
