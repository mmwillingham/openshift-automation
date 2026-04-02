#!/bin/bash
# --- AUTHORIZE NAMESPACES FOR JWT/OIDC ---
# Match these to your seed-vault.sh variables
VAULT_TOKEN="<ACTUAL VALUE>"
VAULT_ADDR="http://bastion.2vccz.sandbox5190.opentlc.com:8200"
MOUNT_PATH="jwt"
POLICY_NAME="vso-demo-policy"
CLIENT_ID="vault-cluster-client"
NAMESPACES=("vso-demo-space" "my-namespace")

echo "Starting Namespace Authorization on $VAULT_ADDR..."

for NS in "${NAMESPACES[@]}"; do
    echo "Processing authorization for: $NS"

    # Build the OIDC/JWT Role Payload
    # Note: Using $POLICY_NAME ensures the VSO pods have the right ACLs
    # Build the OIDC/JWT Role Payload
    ROLE_PAYLOAD=$(jq -n \
        --arg ns "$NS" \
        --arg policy "$POLICY_NAME" \
        --arg role "ocp-role-$NS" \
        '{
            "role_type": "jwt",
            "bound_audiences": ["https://kubernetes.default.svc", "vault-cluster-client", $role],
            "user_claim": "sub",
            "token_policies": [$policy, "default"],
            "token_ttl": "1h"
        }')

    # Push the Role to Vault
    # We use the $MOUNT_PATH variable for the API endpoint
    curl --request POST \
        --silent \
        --header "X-Vault-Token: $VAULT_TOKEN" \
        --data "$ROLE_PAYLOAD" \
        "$VAULT_ADDR/v1/auth/$MOUNT_PATH/role/ocp-role-$NS" | jq

    echo "Vault Role 'ocp-role-$NS' is now mapped to namespace '$NS' with policy '$POLICY_NAME'"
    echo "------------------------------------------------"
done

echo "Authorization Sync Complete."
