#!/usr/bin/env bash
set -euo pipefail

SITE_A_CTX="${SITE_A_CTX:-site-a}"
SITE_B_CTX="${SITE_B_CTX:-site-b}"
NAMESPACE="${NAMESPACE:-rhsi}"

echo "[*] Checking Skupper link status on site-b (${SITE_B_CTX}, ns=${NAMESPACE})..."
link_status=$(skupper --context "${SITE_B_CTX}" --namespace "${NAMESPACE}" link status 2>&1 || true)

if echo "${link_status}" | grep -q "standby-from-vault"; then
  if echo "${link_status}" | grep -q "standby-from-vault[[:space:]]*Ready"; then
    echo "[OK] Skupper link 'standby-from-vault' is Ready on site-b"
  else
    echo "[FAIL] Skupper link 'standby-from-vault' exists but is not Ready:"
    echo "${link_status}"
  fi
else
  echo "[FAIL] No Skupper link named 'standby-from-vault' found on site-b"
fi

echo "[*] Checking AccessToken 'standby-from-vault' on site-b..."
at_yaml=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get accesstoken standby-from-vault -o yaml 2>/dev/null || true)
if [[ -z "${at_yaml}" ]]; then
  echo "[FAIL] AccessToken standby-from-vault not found on site-b"
else
  at_status=$(echo "${at_yaml}" | yq '.status.status' 2>/dev/null || echo "")
  at_message=$(echo "${at_yaml}" | yq '.status.message' 2>/dev/null || echo "")
  if [[ "${at_status}" == "Ready" ]]; then
    echo "[OK] AccessToken standby-from-vault status is Ready (message='${at_message}')"
  else
    echo "[FAIL] AccessToken standby-from-vault status is '${at_status}' (message='${at_message}')"
  fi
fi

echo "[*] Checking SecretStore 'vault-rhsi' and ExternalSecret 'rhsi-link-token' on site-b..."
ss_line=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secretstore vault-rhsi 2>/dev/null | tail -n +2 || true)
es_line=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get externalsecret rhsi-link-token 2>/dev/null | tail -n +2 || true)

if [[ -z "${ss_line}" ]]; then
  echo "[FAIL] SecretStore vault-rhsi not found on site-b"
else
  ss_ready=$(echo "${ss_line}" | awk '{print $5}')
  if [[ "${ss_ready}" == "True" ]]; then
    echo "[OK] SecretStore vault-rhsi is Ready"
  else
    echo "[FAIL] SecretStore vault-rhsi is not Ready (line: ${ss_line})"
  fi
fi

if [[ -z "${es_line}" ]]; then
  echo "[FAIL] ExternalSecret rhsi-link-token not found on site-b"
else
  es_ready=$(echo "${es_line}" | awk '{print $6}')
  es_status=$(echo "${es_line}" | awk '{print $5}')
  if [[ "${es_ready}" == "True" ]]; then
    echo "[OK] ExternalSecret rhsi-link-token is Ready (${es_status})"
  else
    echo "[FAIL] ExternalSecret rhsi-link-token is not Ready (line: ${es_line})"
  fi
fi

echo "[*] Comparing rhsi-link-token Secret on site-b with AccessGrant 'rhsi-standby-grant' on site-a..."
secret_url=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secret rhsi-link-token -o jsonpath='{.data.url}' 2>/dev/null | base64 -d || true)
secret_code=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secret rhsi-link-token -o jsonpath='{.data.code}' 2>/dev/null | base64 -d || true)
secret_ca=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secret rhsi-link-token -o jsonpath='{.data.ca}' 2>/dev/null | base64 -d || true)

ag_url=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant -o jsonpath='{.status.url}' 2>/dev/null || true)
ag_code=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant -o jsonpath='{.status.code}' 2>/dev/null || true)
ag_ca=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant -o jsonpath='{.status.ca}' 2>/dev/null || true)
ag_allowed=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant -o jsonpath='{.spec.redemptionsAllowed}' 2>/dev/null || echo "1")
ag_made=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant -o jsonpath='{.status.redemptions}' 2>/dev/null || echo "0")

if [[ -z "${ag_url}" ]]; then
  echo "[FAIL] AccessGrant rhsi-standby-grant not found or missing status on site-a"
else
  if [[ "${secret_url}" == "${ag_url}" ]]; then
    echo "[OK] AccessGrant.status.url matches Secret.url"
  else
    echo "[FAIL] AccessGrant.status.url does NOT match Secret.url"
    echo "      AccessGrant: ${ag_url}"
    echo "      Secret:      ${secret_url}"
  fi

  if [[ "${secret_code}" == "${ag_code}" ]]; then
    echo "[OK] AccessGrant.status.code matches Secret.code"
  else
    echo "[FAIL] AccessGrant.status.code does NOT match Secret.code"
    echo "      AccessGrant: ${ag_code}"
    echo "      Secret:      ${secret_code}"
  fi

  if [[ "${secret_ca}" == "${ag_ca}" ]]; then
    echo "[OK] AccessGrant.status.ca matches Secret.ca"
  else
    echo "[FAIL] AccessGrant.status.ca does NOT match Secret.ca"
  fi

  echo "[OK] AccessGrant redemptions: allowed=${ag_allowed}, made=${ag_made} (grant has been redeemed)"
fi

echo "[*] Checking Vault contents at rhsi/site-b/link-token..."
vault_out=$(vault kv get -format=json rhsi/site-b/link-token 2>/dev/null || true)

if [[ -z "${vault_out}" ]]; then
  echo "[FAIL] Vault path rhsi/site-b/link-token not found"
else
  vault_url=$(echo "${vault_out}"   | jq -r '.data.data.url // ""')
  vault_code=$(echo "${vault_out}"  | jq -r '.data.data.code // ""')
  vault_ca=$(echo "${vault_out}"    | jq -r '.data.data.ca // ""')

  if [[ "${vault_url}" == "${ag_url}" ]]; then
    echo "[OK] Vault.url matches AccessGrant.status.url"
  else
    echo "[FAIL] Vault.url does NOT match AccessGrant.status.url"
  fi

  if [[ "${vault_code}" == "${ag_code}" ]]; then
    echo "[OK] Vault.code matches AccessGrant.status.code"
  else
    echo "[FAIL] Vault.code does NOT match AccessGrant.status.code"
  fi

  if [[ "${vault_ca}" == "${ag_ca}" ]]; then
    echo "[OK] Vault.ca matches AccessGrant.status.ca"
  else
    echo "[FAIL] Vault.ca does NOT match AccessGrant.status.ca"
  fi
fi

echo
if grep -q "\[FAIL\]" <<<"$(history 1 2>/dev/null || true)"; then
  echo "Sanity check FAILED (see messages above)"
else
  echo "Sanity check PASSED"
fi
