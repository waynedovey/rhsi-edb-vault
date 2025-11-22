#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-rhsi}"
GRANT_NAME="${GRANT_NAME:-rhsi-primary-to-standby}"
VAULT_ADDR="${VAULT_ADDR:-https://vault-vault.apps.acm.sandbox2745.opentlc.com}"
VAULT_PATH="${VAULT_PATH:-rhsi/site-b/link-token}"

: "${VAULT_TOKEN:?VAULT_TOKEN must be set or 'vault login' used}"

echo "Waiting for AccessGrant ${GRANT_NAME} in namespace ${NAMESPACE}..."
kubectl -n "${NAMESPACE}" wait accessgrant/"${GRANT_NAME}"   --for=condition=Ready --timeout=300s

CODE=$(kubectl -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.code}')
URL=$(kubectl -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.url}')
CA=$(kubectl -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.ca}')

if [[ -z "${CODE}" || -z "${URL}" || -z "${CA}" ]]; then
  echo "ERROR: AccessGrant status is missing code/url/ca"
  exit 1
fi

echo "Writing AccessToken fields to Vault at path: ${VAULT_PATH}"
vault kv put "${VAULT_PATH}"   code="${CODE}"   url="${URL}"   ca="${CA}"

echo "Done."
