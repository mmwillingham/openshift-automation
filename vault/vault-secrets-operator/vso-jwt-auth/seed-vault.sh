#!/bin/bash
# --- FINAL REVISED VERSION ---

# 1. INTERNAL CONFIGURATION
VAULT_TOKEN="<ACTUAL VALUE>"
CLIENT_SECRET="<ACTUAL VALUE>"
VAULT_ADDR="http://bastion.2vccz.sandbox5190.opentlc.com:8200"
KEYCLOAK_URL="http://bastion.2vccz.sandbox5190.opentlc.com:8080"
REALM="customer-corp"
CLIENT_ID="vault-cluster-client"
MOUNT_PATH="oidc"
JWT_MOUNT="jwt"
OCP_DISCOVERY_URL="https://api.cluster-2vccz.2vccz.sandbox5190.opentlc.com:6443"
OCP_ISSUER="https://kubernetes.default.svc"
SECRET_ENGINE="prod"
CLUSTER_ID="cluster-2vccz"
WORKSPACE="vso-demo-space"
ROLE_NAME="admin"
POLICY_NAME="vso-demo-policy"
DATA_PATH="$SECRET_ENGINE/data/$CLUSTER_ID/$WORKSPACE"
METADATA_PATH="$SECRET_ENGINE/metadata/$CLUSTER_ID/$WORKSPACE"
OCP_CA=$(echo | openssl s_client -showcerts -connect api.cluster-2vccz.2vccz.sandbox5190.opentlc.com:6443 2>/dev/null | openssl x509)


# 2. TEARDOWN existing vault data
CLEAN_START=true
if [ "$CLEAN_START" = true ]; then
    echo "Wiping existing configurations for a clean start..."
    # Wipe Auth Mounts
    curl -s --request DELETE --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/auth/$MOUNT_PATH"
    curl -s --request DELETE --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/auth/$JWT_MOUNT"
    
    # NEW: Wipe the Secret Engine (the "prod" path)
    curl -s --request DELETE --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/mounts/$SECRET_ENGINE"
fi

echo "Syncing Vault configuration..."

# 3. CONFIGURE MOUNT 1: OIDC (For Keycloak/Browser)
curl -s --request POST --header "X-Vault-Token: $VAULT_TOKEN" \
    --data '{"type": "oidc"}' "$VAULT_ADDR/v1/sys/auth/$MOUNT_PATH"

OIDC_CONFIG=$(jq -n --arg url "$KEYCLOAK_URL/realms/$REALM" \
    --arg id "$CLIENT_ID" --arg secret "$CLIENT_SECRET" --arg role "$ROLE_NAME" \
    '{oidc_discovery_url: $url, oidc_client_id: $id, oidc_client_secret: $secret, default_role: $role}')

curl -s --request POST --header "X-Vault-Token: $VAULT_TOKEN" \
    --data "$OIDC_CONFIG" "$VAULT_ADDR/v1/auth/$MOUNT_PATH/config"

# 4. CONFIGURE MOUNT 2: JWT (For OpenShift/VSO)
echo "Configuring JWT Mount with PEM Public Key..."

# Fetch the specific signing key PEM
OCP_PUB_KEY=$(oc get cm -n openshift-kube-apiserver bound-sa-token-signing-certs -o jsonpath='{.data.service-account-001\.pub}')

# Enable the JWT auth method
curl -s --request POST --header "X-Vault-Token: $VAULT_TOKEN" \
    --data '{"type": "jwt"}' "$VAULT_ADDR/v1/sys/auth/$JWT_MOUNT" || true

# Push the PEM key into the config
JWT_CONFIG=$(jq -n --arg key "$OCP_PUB_KEY" --arg issuer "$OCP_ISSUER" \
    '{
        jwt_validation_pubkeys: [$key],
        jwt_supported_algs: ["RS256"],
        bound_issuer: $issuer
    }')

curl -s --request POST --header "X-Vault-Token: $VAULT_TOKEN" \
    --data "$JWT_CONFIG" "$VAULT_ADDR/v1/auth/$JWT_MOUNT/config"

# 5. DEFINE ADMIN ROLE (OIDC Mount)
ROLE_PAYLOAD=$(jq -n --arg id "$CLIENT_ID" \
    --arg redirect "$VAULT_ADDR/ui/vault/auth/oidc/oidc/callback" \
    --arg policy "$POLICY_NAME" \
    '{
        user_claim: "sub",
        allowed_redirect_uris: [$redirect, "http://localhost:8250/oidc/callback"],
        bound_audiences: [$id],
        role_type: "oidc",
        token_policies: [$policy, "default"],
        ttl: "1h"
    }')
curl -s --request POST --header "X-Vault-Token: $VAULT_TOKEN" \
    --data "$ROLE_PAYLOAD" "$VAULT_ADDR/v1/auth/$MOUNT_PATH/role/$ROLE_NAME"

# 6. UPDATE POLICIES
POLICY_HCL="
# Allow VSO to manage its own token
path \"auth/token/renew-self\" {
    capabilities = [\"update\"]
}
path \"auth/token/lookup-self\" {
    capabilities = [\"read\"]
}

# Access to the actual secrets
path \"$METADATA_PATH/*\" { 
    capabilities = [\"read\", \"list\"] 
}
path \"$DATA_PATH/*\" { 
    capabilities = [\"read\", \"list\"] 
}"

# Note the change to the API path: /v1/sys/policy/ (singular) is standard
curl -s --request POST --header "X-Vault-Token: $VAULT_TOKEN" \
    --data "$(jq -n --arg hcl "$POLICY_HCL" '{policy: $hcl}')" \
    "$VAULT_ADDR/v1/sys/policy/$POLICY_NAME"

# 7. SEED DATA
curl -s --request POST --header "X-Vault-Token: $VAULT_TOKEN" \
    --data '{"type": "kv-v2"}' "$VAULT_ADDR/v1/sys/mounts/$SECRET_ENGINE" || true

curl -s --request POST --header "X-Vault-Token: $VAULT_TOKEN" \
    --data '{"data": {"test-api-key": "oidc-verified-secret-999", "password": "MyP@ssword1sJust0K"}}' \
    "$VAULT_ADDR/v1/$DATA_PATH/test-secret"

echo "Success: Vault configuration synced."

if [ -f "./authorize-ns-vault.sh" ]; then
    ./authorize-ns-vault.sh
fi
