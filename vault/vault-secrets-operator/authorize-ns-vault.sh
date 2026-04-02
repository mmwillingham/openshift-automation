# Authorize the Operator specified namespaces
export NAMESPACES='["vault-auth", "vso-demo-space"]'
# echo $NAMESPACES

export ROLE_PAYLOAD=$(jq -n \
    --argjson ns "$NAMESPACES" \
    '{
        bound_service_account_names: ["default"],
        bound_service_account_namespaces: $ns,
        token_policies: ["dev-policy"],
        token_ttl: "24h"
    }')

curl --request POST \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --data "$ROLE_PAYLOAD" \
    "$VAULT_ADDR/v1/auth/$CLUSTER_NAME/role/webapp-role"

# echo $ROLE_PAYLOAD

# Verify
# curl --header "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/auth/$CLUSTER_NAME/role/webapp-role" | jq
