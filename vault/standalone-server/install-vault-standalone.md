# Install Vault on standalone RHEL in persistent mode
# For convenience but lower security, I added an unseal script with the unseal key within. Do not do in production.
#### Docs: https://developer.hashicorp.com/vault/install

## Install
```
# CentOS/RHEL
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum -y install vault
vault -version
```

## Create persistent storage directories
```
sudo mkdir -p /opt/vault/data
sudo mkdir -p /etc/vault.d
```

## Set ownership
```
sudo chown -R vault:vault /opt/vault
sudo chown -R vault:vault /etc/vault.d
```

## Configure HCL file
```
cat <<EOF | sudo tee /etc/vault.d/vault.hcl
storage "file" {
  path = "/opt/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui = true
disable_mlock = true
EOF
```

## Create systemd service
```
cat <<EOF | sudo tee /etc/systemd/system/vault.service
[Unit]
Description="HashiCorp Vault - A tool for managing secrets"
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
Capabilities=CAP_IPC_LOCK+ep
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now vault

# Check status. Should be active but report that seal is not initialized
sudo systemctl status vault
```

## One-time initialization
```
export VAULT_ADDR="http://127.0.0.1:8200"

# Initialize with 1 key share
vault operator init -key-shares=1 -key-threshold=1

# CRITICAL: Copy the Unseal Key 1 and the Initial Root Token to a notepad. You need them for the next step.
```

## Create unseal script
```
cat <<EOF | sudo tee /usr/local/bin/vault-unseal.sh
#!/bin/bash
export VAULT_ADDR="http://127.0.0.1:8200"
until curl -s \$VAULT_ADDR/v1/sys/health > /dev/null; do
  sleep 1
done
# REPLACE THE KEY BELOW
vault operator unseal PASTE_YOUR_UNSEAL_KEY_HERE
EOF

sudo chown vault:vault /usr/local/bin/vault-unseal.sh
sudo chmod 700 /usr/local/bin/vault-unseal.sh
```

## Enable and start vault
```
# Add the post-start trigger to the service file
sudo sed -i '/ExecStart=\/usr\/bin\/vault server/a ExecStartPost=/usr/local/bin/vault-unseal.sh' /etc/systemd/system/vault.service

sudo systemctl daemon-reload
sudo systemctl restart vault

# Check status
sudo systemctl status vault
```

## Verify Unseal (Look for "Sealed: false")
```
export VAULT_ADDR="http://127.0.0.1:8200"
vault status
```

## For added security, only allow access from desired networks
```
# Allow the OpenShift API/Nodes subnet to access Vault
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.10.0/24" port protocol="tcp" port="8200" accept'
sudo firewall-cmd --reload
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

## Connect to UI
```
# Vault is running on a bastion. Here are the steps for connecting from my laptop
## In AWS, add 8200 and http to bastion SG
## Access from laptop's browser
http://bastion.2vccz.sandbox5190.opentlc.com:8200
## in UI, login with different methods:
- token (use root token)
```

## Create Secrets Engine (UI)
```
# Secrets Engine > Enable New Engine > KV (generic)
## kv/dev # user-defined
```

## Create Secret (UI)
```
# DEV
# Secrets Engine > kv/dev > Create Secret
## Path: cluster01
## Secret Data: <key> <value>
## Save
## Optionally add a new version

# PROD
# Secrets Engine > kv/dev > Create Secret
## Path: cluster02
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


