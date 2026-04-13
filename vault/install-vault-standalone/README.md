# Install Vault on standalone RHEL in persistent mode
- For convenience but lower security, I added an unseal script with the unseal key within. Do not do in production.
- These steps will work for kuberneted and jwt/oidc auth

## Set vars
VAULT_ADDR="http://bastion.t6mtb.sandbox2964.opentlc.com:8200"

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
sudo chmod -R 750 /opt/vault/data
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
Description="HashiCorp Vault"
Requires=network-online.target
After=network-online.target

[Service]
User=vault
Group=vault
ProtectSystem=full
PrivateTmp=yes
PrivateDevices=yes
AmbientCapabilities=CAP_IPC_LOCK
Capabilities=CAP_IPC_LOCK+ep
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
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

# Wait for API readiness
for i in {1..30}; do
  if curl -s \$VAULT_ADDR/v1/sys/health > /dev/null; then break; fi
  sleep 1
done

# Check seal status and unseal if necessary
if vault status | grep -q "Sealed.*true"; then
  vault operator unseal PASTE_YOUR_KEY_HERE
fi
EOF

sudo chmod 700 /usr/local/bin/vault-unseal.sh
# Run it manually once to verify
sudo /usr/local/bin/vault-unseal.sh
```

## Enable and start vault
```
# Add the post-start trigger to the service file
sudo sed -i '/ExecStart=\/usr\/bin\/vault server/a ExecStartPost=-/usr/local/bin/vault-unseal.sh' /etc/systemd/system/vault.service

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

## Open AWS firewall
```
aws configure # Use information from Demo Platform
SG_ID=$(aws ec2 describe-instances --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
echo $SG_ID
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8200 --cidr 0.0.0.0/0
curl -v -m 5 $VAULT_ADDR/v1/sys/health

# Verify
aws ec2 describe-security-groups \
    --group-ids $SG_ID \
    --query "SecurityGroups[0].IpPermissions[?ToPort==\`8200\`]"


```

## For added security, only allow access from desired networks
```
# Allow the OpenShift API/Nodes subnet to access Vault
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.10.0/24" port protocol="tcp" port="8200" accept'
sudo firewall-cmd --reload
```
