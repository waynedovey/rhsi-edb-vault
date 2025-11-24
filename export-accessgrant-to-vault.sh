#!/usr/bin/env bash
set -euo pipefail

# Export Skupper AccessGrant credentials from the primary site into Vault so that
# the standby site can consume them via ExternalSecrets.
#
# Expected environment (override as needed):
#   CONTEXT           - kube context for the primary site (default: site-a)
#   NAMESPACE         - namespace where Skupper is installed (default: rhsi)
#   GRANT_NAME        - AccessGrant resource name (default: rhsi-standby-grant)
#   VAULT_PATH_SITE_A - Vault KV path for primary site token (default: rhsi/site-a/link-token)
#   VAULT_PATH_SITE_B - Vault KV path for standby site token (default: rhsi/site-b/link-token)

CONTEXT="${CONTEXT:-site-a}"
NAMESPACE="${NAMESPACE:-rhsi}"
GRANT_NAME="${GRANT_NAME:-rhsi-standby-grant}"
VAULT_PATH_SITE_A="${VAULT_PATH_SITE_A:-rhsi/site-a/link-token}"
VAULT_PATH_SITE_B="${VAULT_PATH_SITE_B:-rhsi/site-b/link-token}"

echo "Using kube context: ${CONTEXT}"
echo "Namespace:          ${NAMESPACE}"
echo "AccessGrant:        ${GRANT_NAME}"
echo "Vault path (site A): ${VAULT_PATH_SITE_A}"
echo "Vault path (site B): ${VAULT_PATH_SITE_B}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

echo "Fetching AccessGrant status from cluster..."
oc --context "${CONTEXT}" -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.ca}' > "${tmpdir}/grant-ca.pem"
CODE="$(oc --context "${CONTEXT}" -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.code}')"
URL="$(oc --context "${CONTEXT}" -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.url}')"

echo "Writing token data into Vault..."
vault kv put "${VAULT_PATH_SITE_A}"   ca=@"${tmpdir}/grant-ca.pem"   code="${CODE}"   url="${URL}"

vault kv put "${VAULT_PATH_SITE_B}"   ca=@"${tmpdir}/grant-ca.pem"   code="${CODE}"   url="${URL}"

echo "Done. Tokens written to:"
echo "  - ${VAULT_PATH_SITE_A}"
echo "  - ${VAULT_PATH_SITE_B}"
