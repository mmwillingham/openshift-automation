# Install keycloak standalone - this will allow jwt authorization from openshift to vault

## Create json that contains new realm and user
```
mkdir /home/lab-user/keycloak:wq

cat <<EOF > /home/lab-user/keycloak/customer-corp-realm.json
{
  "realm": "customer-corp",
  "enabled": true,
  "sslRequired": "none",
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
      "rootUrl": "http://bastion.2vccz.sandbox5190.opentlc.com:8200",
      "redirectUris": [
          "http://bastion.2vccz.sandbox5190.opentlc.com:8200/ui/vault/auth/oidc/oidc/callback",
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
  -e KC_HOSTNAME=bastion.2vccz.sandbox5190.opentlc.com \
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

<!-- # 
# Update vault stuff
```

```

## Update vault-auth.yaml
```
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: static-auth
  namespace: vso-system # Or your VSO namespace
spec:
  method: jwt           # CHANGED from kubernetes
  mount: jwt-oidc       # Matches the 'path' in seed-vault.sh
  vaultConnectionRef: vault-connection
  jwt:
    role: ocp-cluster-role
    tokenSource:
      serviceAccountToken:
        audiences: 
          - "vault-cluster-client" # Must match Keycloak Client ID
```

## remove unneeded prep
```
rm vault-auth-infra.yaml
``` -->
