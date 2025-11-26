#!/usr/bin/env bash
set -euo pipefail

SITE_A_CTX="${SITE_A_CTX:-site-a}"
NAMESPACE="${NAMESPACE:-rhsi}"
VAULT_PATH="${VAULT_PATH:-rhsi/site-b/link-token}"

echo ">>> Waiting for AccessGrant rhsi-standby-grant in namespace ${NAMESPACE} on context ${SITE_A_CTX}..."
oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" wait accessgrant rhsi-standby-grant   --for=condition=Ready --timeout=60s

echo ">>> Reading AccessGrant status fields..."
AG_URL=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant   -o jsonpath='{.status.url}')
AG_CODE=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant   -o jsonpath='{.status.code}')
AG_CA=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant   -o jsonpath='{.status.ca}')

echo ">>> AccessGrant values:"
echo "    URL : ${AG_URL}"
echo "    CODE: ${AG_CODE}"
echo "    CA  : written to ./skupper-grant-server-ca.pem"

echo "${AG_CA}" > ./skupper-grant-server-ca.pem

if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_TOKEN:-}" ]]; then
  echo "ERROR: VAULT_ADDR and VAULT_TOKEN must be set in the environment."
  exit 1
fi

echo ">>> Writing link token into Vault at path: ${VAULT_PATH}"
vault kv put "${VAULT_PATH}"   url="${AG_URL}"   code="${AG_CODE}"   ca="${AG_CA}"

echo ">>> Verifying from Vault..."
vault kv get "${VAULT_PATH}"

echo ">>> Done. Vault now holds the latest Skupper link token for site-b."
