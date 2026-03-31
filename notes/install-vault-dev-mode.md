# Install Vault Dev
#### Note: This is insecure. Use for dev testing only.
#### Docs: https://developer.hashicorp.com/vault/install

## Install
```
# CentOS/RHEL
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum -y install vault
vault -version
```

## Run
```
vault server -dev -dev-listen-address="0.0.0.0:8200"
# Capture the values on the screen, especially
## Cluster Address
## Unseal Key
## Root Token
# Note: the process will remain in foreground. Leave it there.
```

## Test
```
# In another window:
## export the cluster address:
export VAULT_ADDR='http://0.0.0.0:8200'
## export root token. Get value from server screen
export VAULT_DEV_ROOT_TOKEN=<YOUR VALUE>
## Verify connectivity
$ vault status
# Sample output:
## Key             Value
## ---             -----
## Seal Type       shamir
## Initialized     true
## Sealed          false
## Total Shares    1
## Threshold       1
## Version         1.21.4
## Build Date      2026-03-04T17:40:05Z
## Storage Type    inmem
## Cluster Name    vault-cluster-837e600d
## Cluster ID      72c95501-d869-4ec5-5493-56c963cf11f1
## HA Enabled      false
```

## Authenticate
```
vault login
# For password, use the value for "Root Token" provided earlier
# Sample output
## Token (will be hidden): 
## Success! You are now authenticated. The token information displayed below
## is already stored in the token helper. You do NOT need to run "vault login"
## again. Future Vault requests will automatically use this token.

## Key                  Value
## ---                  -----
## token                <redacted>
## token_accessor       OudZtBDdbiv6fOLp69z57Tr4
## token_duration       ∞
## token_renewable      false
## token_policies       ["root"]
## identity_policies    []
## policies             ["root"]
```
## Enable kubernetes auth method
```
vault auth enable kubernetes
or
vault auth enable -path demo-auth-mount kubernetes
```

## Connect to UI
```
# Vault is running on a bastion. Here are the steps for connecting from my laptop
## From laptop
ssh -4 -L 8200:127.0.0.1:8200 lab-user@bastion.2vccz.sandbox5190.opentlc.com
## From laptop's browser
http://127.0.0.1:8200
## in UI, login with different methods:
- token (use root token or one of those created above)
```
## Create Secrets Engine (UI)
```
# Secrets Engine > Enable New Engine > KV (generic)
## kv/org # user-defined
```
## Create Secret (UI)
```
# DEV
# Secrets Engine > kv/org > Create Secret
## Path: dev
## Secret Data: <key> <value>
## Save
## Optionally add a new version

# PROD
# Secrets Engine > kv/org > Create Secret
## Path: prod
## Secret Data: <key> <value>
## Save
```

## Tokens
```
# Accesssor
## Token accessors can be used to perform actions such as renewing or revoking a token, but does not provide access to Vault.
vault token lookup -accessor # get value from above
# Create
vault token create -policy="default" -period=1m -explicit-max-ttl=2m
# Renew
vault token renew -accessor <accessor>
# Revoke
vault token revoke <token value>
```

## Policies
```
https://developer.hashicorp.com/vault/tutorials/get-started/introduction-policies
```

## Roles
```
https://developer.hashicorp.com/vault/tutorials/get-started/introduction-roles
# Example
# Create token
vault token create -policy="default" -period=1m -explicit-max-ttl=2m
# Create Role
vault auth enable kubernetes
vault write auth/kubernetes/config \
    token_reviewer_jwt="$K8S_SERVICE_ACCOUNT_TOKEN" \
    kubernetes_host=https://192.168.99.100:443 \
    kubernetes_ca_cert=@ca.crt
vault write auth/kubernetes/role/hashicupsApp \
     bound_service_account_names=k8sHashicupsAppSA \
     bound_service_account_namespaces=k8sDevNamespace \
     policies=default,dev-secrets \
     ttl=1h \
     explicit-max-ttl=2h
```

## Stop vault server
```
pkill vault # Or CTRL-C in server window
VAULT_ADDR
unset VAULT_DEV_ROOT_TOKEN
```


