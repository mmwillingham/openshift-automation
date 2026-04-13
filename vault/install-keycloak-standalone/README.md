# Install keycloak standalone - this will allow jwt authorization from openshift to vault

## Create json that contains new realm and user
```
mkdir /home/lab-user/keycloak

# Set the hostname variable first (ensure this matches your current lab)
BASTION_HOST="bastion.t6mtb.sandbox2964.opentlc.com"

cat <<EOF > /home/lab-user/keycloak/customer-corp-realm.json
{
  "realm": "customer-corp",
  "enabled": true,
  "sslRequired": "none",
  "attributes": {
    "frontendUrl": "http://${BASTION_HOST}:8080/"
  },
  "users": [
    {
      "username": "admin-user",
      "enabled": true,
      "credentials": [
        {
          "type": "password",
          "value": "password123",
          "temporary": false
        }
      ],
      "realmRoles": ["admin"]
    }
  ],
  "roles": {
    "realm": [
      { "name": "admin" }
    ]
  },
  "clients": [
    {
      "clientId": "vault-cluster-client",
      "name": "Vault Cluster Authentication",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "ksNykkjsPmrLePd98NzvNynxSTCyEt2wP94ApbEXobU=",
      "serviceAccountsEnabled": true,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "rootUrl": "http://${BASTION_HOST}:8200",
      "redirectUris": [
          "http://${BASTION_HOST}:8200/ui/vault/auth/oidc/oidc/callback",
          "http://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback"
      ],
      "webOrigins": ["*"],
      "protocolMappers": [
          {
          "name": "audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "config": {
              "included.client.audience": "vault-cluster-client",
              "id.token.claim": "true",
              "access.token.claim": "true"
          }
          }
        ]
      }
  ]
}
EOF
```

## Create keycloak pod and import json
```
sudo podman stop keycloak && sudo podman rm keycloak
sudo podman run -d \
  --name keycloak \
  -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  -e KC_HOSTNAME=bastion.t6mtb.sandbox2964.opentlc.com \
  -e KC_HOSTNAME_STRICT=false \
  -e KC_HOSTNAME_STRICT_HTTPS=false \
  -e KC_HTTP_ENABLED=true \
  -v /home/lab-user/keycloak/customer-corp-realm.json:/opt/keycloak/data/import/customer-corp-realm.json:Z \
  quay.io/keycloak/keycloak:latest \
  start-dev --import-realm

# Wait 60 seconds for the engine to warm up, then fix the master SSL lockout
sleep 60
# Check logs
# sudo podman logs -f keycloak

sudo podman exec -it keycloak /bin/bash -c "
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master \
    --user admin --password admin && \
  /opt/keycloak/bin/kcadm.sh update realms/master -s sslRequired=NONE"
sudo podman exec -it keycloak /opt/keycloak/bin/kcadm.sh get realms/master | grep sslRequired
```

## Restart keycloak if necessary
```
sudo podman start keycloak
```

## Retrieve keycloak client_secret. This will be used in the VSO configuration
```
# Retrieve all client_ids
sudo podman exec -it keycloak /bin/bash -c "
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master \
    --user admin --password admin && \
  /opt/keycloak/bin/kcadm.sh get clients \
    -r customer-corp \
    --fields clientId,id"

# Retrieve client_id only for vault-cluster-client
sudo podman exec -it keycloak /bin/bash -c "
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master \
    --user admin --password admin && \
  /opt/keycloak/bin/kcadm.sh get clients \
    -r customer-corp \
    -q clientId=vault-cluster-client \
    --fields clientId,id"

# 1. Get the UUID and Secret in one flow
CLIENT_SECRET=$(sudo podman exec -it keycloak /bin/bash -c "
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master \
    --user admin --password admin > /dev/null && \
  CLIENT_UUID=\$(/opt/keycloak/bin/kcadm.sh get clients -r customer-corp -q clientId=vault-cluster-client --fields id --format csv --noquotes) && \
  /opt/keycloak/bin/kcadm.sh get clients/\$CLIENT_UUID/client-secret -r customer-corp --fields value --format csv --noquotes" | tr -d '\r')

# 2. Verify it worked
echo "Retrieved Secret: $CLIENT_SECRET"
Retrieved Secret: Logging into http://localhost:8080 as user admin of realm master

```


## Open AWS firewall
```
SG_ID=$(aws ec2 describe-instances --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
echo $SG_ID
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 8080 \
    --cidr 0.0.0.0/0

# Verify
aws ec2 describe-security-groups \
    --group-ids $SG_ID \
    --query "SecurityGroups[0].IpPermissions[?ToPort==\`8080\`]"
```
