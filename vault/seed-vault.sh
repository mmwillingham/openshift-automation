#!/bin/bash
# --- RUN INSIDE CI/CD PIPELINE ---

# Prerequisites if running manually. When automating, these values should be stored in CI/CD secrets/variables
# export VAULT_TOKEN=<MY TOKEN>
# export VAULT_ADDR="http://bastion.2vccz.sandbox5190.opentlc.com:8200"

# Capture Cluster Credentials (using 'oc')
# We need the CA cert (to trust the API) and the Reviewer Token (to verify pods)
export OCP_API=$(oc whoami --show-server)
export CLUSTER_NAME=$(oc whoami --show-server | awk -F. '{print $2}')
export CA_CERT_B64=$(oc get secret vault-reviewer-token -n vault-auth -o jsonpath='{.data.ca\.crt}')
export REVIEWER_TOKEN=$(oc get secret vault-reviewer-token -n vault-auth -o jsonpath='{.data.token}' | base64 -d)
# echo $VAULT_ADDR
# echo $VAULT_TOKEN
# echo $VAULT_ADDR
# echo $OCP_API
# echo $CLUSTER_NAME
# echo $CA_CERT_B64
# echo $REVIEWER_TOKEN

# Enable the Kubernetes Auth Path on External Vault
# We use a unique path so Vault can handle multiple clusters
curl --request POST \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --data "{\"type\": \"kubernetes\", \"description\": \"Auth for $CLUSTER_NAME\"}" \
    "$VAULT_ADDR/v1/sys/auth/$CLUSTER_NAME"

# Build the Configuration Payload
# jq handles the newline escaping for the CA certificate
export PAYLOAD=$(jq -n \
    --arg host "$OCP_API" \
    --arg cacert "$(echo $CA_CERT_B64 | base64 -d)" \
    --arg jwt "$REVIEWER_TOKEN" \
    '{
        kubernetes_host: $host,
        kubernetes_ca_cert: $cacert,
        token_reviewer_jwt: $jwt,
        disable_local_ca_jwt: true
    }')

# echo $PAYLOAD

# Push configuration to Vault
curl --request POST \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --data "$PAYLOAD" \
    "$VAULT_ADDR/v1/auth/$CLUSTER_NAME/config"

echo "Handshake complete. $CLUSTER_NAME is now trusted by Vault."

# Define the policy rules
# Note the /data/ segment required for KV-V2 engines
POLICY_HCL=$(cat <<EOF
path "sandbox/data/cluster-2vccz/my-project/*" {
  capabilities = ["read", "list"]
}
EOF
)

# echo $POLICY_HCL

# Push policy to Vault
# We use jq to stringify the HCL so it fits in a JSON payload
curl --request PUT \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --data "$(jq -n --arg hcl "$POLICY_HCL" '{policy: $hcl}')" \
    "$VAULT_ADDR/v1/sys/policies/acl/dev-policy"

# These steps can be handled by other methods.
## Create Secrets Engine for sandbox environment

curl --request POST \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --data '{"type": "kv-v2"}' \
    "$VAULT_ADDR/v1/sys/mounts/sandbox"

## Create a test secret in sandbox/$CLUSTER_NAME/my-project/test-secret
curl --request POST \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --data '{
        "data": {
            "username": "admin-user",
            "password": "super-secret-password-123"
        }
    }' \
    "$VAULT_ADDR/v1/sandbox/data/$CLUSTER_NAME/my-project/test-secret"
