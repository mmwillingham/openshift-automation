# Vault Secrets Operator (VSO) on OpenShift: Engineering Journal


This document details the successful integration of HashiCorp Vault with an OpenShift cluster using the Vault Secrets Operator (VSO).

The initial attempt to sync secrets failed due to a handshake mismatch between OpenShift's ServiceAccount tokens and Vault's expectations.

### Phase 1: Identifying the Failure
* **Error:** `400 Bad Request: claim "/kubernetes.io/serviceaccount/namespace" is missing`
* **Cause:** Vault was attempting to validate a nested JSON claim that did not match the structure of the OpenShift-provided JWT.
* **Secondary Error:** `403 Forbidden: auth/token/renew-self`
* **Cause:** The Operator authenticated successfully but lacked the specific permissions to maintain its own session.

### Phase 2: The Working Solution
To resolve, moved to a **JWT Auth Method** with a "Zero-Footprint" claim strategy.

#### Updated Policy (`vso-demo-policy`)
Added lifecycle permissions to the Vault policy so the Operator could renew its lease.
```hcl
# Allow VSO to manage its own token lifecycle
path "auth/token/renew-self" {
    capabilities = ["update"]
}
path "auth/token/lookup-self" {
    capabilities = ["read"]
}

# Access to the actual secrets
path "prod/metadata/cluster-2vccz/vso-demo-space/*" {
    capabilities = ["read", "list"]
}
path "prod/data/cluster-2vccz/vso-demo-space/*" {
    capabilities = ["read", "list"]
}

## Updated Authorization Role
We broadened the bound_audiences to ensure the token was accepted regardless of the issuer's string.

```
ROLE_PAYLOAD=$(jq -n \
    --arg role "ocp-role-vso-demo-space" \
    '{
        "role_type": "jwt",
        "bound_audiences": ["[https://kubernetes.default.svc](https://kubernetes.default.svc)", "vault-cluster-client", $role],
        "user_claim": "sub",
        "token_policies": ["vso-demo-policy", "default"],
        "token_ttl": "1h"
    }')
```

## Current State
seed-vault.sh (Core Infrastructure)
This script wipes the environment and re-seeds the JWT mount and Secret Engine.

Key Action: Fetches the OpenShift public signing key via oc get cm and pushes it to Vault.

Key Action: Creates the prod KV-v2 engine.

authorize-ns-vault.sh (Namespace Mapping)
This script maps specific OpenShift namespaces to Vault roles.

Key Action: Creates a unique role for each namespace (ocp-role-vso-demo-space).

## 4. Production Hardening Guide
While the sandbox uses wide-open claims and HTTP for speed, a real customer environment requires the following four pillars of hardening.

Strict Claim Validation
Goal: Prevent unauthorized pods from assuming the Operator's role.
Action: Re-enable bound_claims in the JWT role.

End-to-End TLS
Goal: Protect secrets from network sniffing.
Action: Enable TLS on the Vault bastion.
Logic: Update the VaultAuth resource in OpenShift to include the caBundle for certificate verification.

Path Isolation
Goal: Limit the "blast radius" of a security breach.
Action: Scope policies to specific application paths.
Logic: Use prod/data/apps/{{app_name}}/* instead of broad wildcards.

Governance & Audit
Goal: Create a forensic trail of secret access.
Action: Enable Vault Audit Devices.

## 5. Comparison: Sandbox vs. Production
Feature	Sandbox (Current)	Production (Target)
Protocol	HTTP (Unencrypted)	HTTPS (TLS 1.2/1.3)
Authentication	JWT (Loose Claims)	JWT (Strict Claim Validation)
Authorization	Shared Policy Scopes	Isolated Path Scopes