#!/usr/bin/env bash
set -euo pipefail

SITE_A_CTX="${SITE_A_CTX:-site-a}"
SITE_B_CTX="${SITE_B_CTX:-site-b}"
NAMESPACE="${NAMESPACE:-rhsi}"
VAULT_PATH="${VAULT_PATH:-rhsi/site-b/link-token}"

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }

ok()   { green "[OK] $*"; }
fail() { red   "[FAIL] $*"; }

echo "[*] Checking Skupper link status on site-b (${SITE_B_CTX}, ns=${NAMESPACE})..."
if oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get site rhsi-standby >/dev/null 2>&1; then
  LINE=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get site rhsi-standby -o jsonpath='{.status.message}')
  if [[ "${LINE}" == "OK" ]]; then
    ok "Skupper site rhsi-standby is OK"
  else
    fail "Skupper site rhsi-standby message: ${LINE}"
  fi
else
  fail "Skupper site rhsi-standby not found"
fi

echo "[*] Checking AccessToken 'standby-from-vault' on site-b..."
if oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get accesstoken standby-from-vault >/dev/null 2>&1; then
  MSG=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get accesstoken standby-from-vault -o jsonpath='{.status.message}')
  if [[ -z "${MSG}" || "${MSG}" == "OK" ]]; then
    ok "AccessToken standby-from-vault present (status.message='${MSG:-<empty>}')"
  else
    fail "AccessToken standby-from-vault status is 'Error' (message='${MSG}')"
  fi
else
  fail "AccessToken standby-from-vault not found on site-b"
fi

echo "[*] Checking SecretStore 'vault-rhsi' and ExternalSecret 'rhsi-link-token' on site-b..."
if oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secretstore vault-rhsi >/dev/null 2>&1; then
  LINE=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secretstore vault-rhsi)
  echo "    ${LINE}"
  if echo "${LINE}" | grep -q "True"; then
    ok "SecretStore vault-rhsi is Ready"
  else
    fail "SecretStore vault-rhsi is not Ready (line: ${LINE})"
  fi
else
  fail "SecretStore vault-rhsi not found"
fi

if oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get externalsecret rhsi-link-token >/dev/null 2>&1; then
  LINE=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get externalsecret rhsi-link-token)
  echo "    ${LINE}"
  if echo "${LINE}" | grep -q "True"; then
    ok "ExternalSecret rhsi-link-token is Ready"
  else
    fail "ExternalSecret rhsi-link-token is not Ready (line: ${LINE})"
  fi
else
  fail "ExternalSecret rhsi-link-token not found"
fi

echo "[*] Comparing rhsi-link-token Secret on site-b with AccessGrant 'rhsi-standby-grant' on site-a..."
AG_URL=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant -o jsonpath='{.status.url}')
AG_CODE=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant -o jsonpath='{.status.code}')
AG_CA=$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant rhsi-standby-grant -o jsonpath='{.status.ca}')

SECRET_URL=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secret rhsi-link-token -o jsonpath='{.data.url}' | base64 -d)
SECRET_CODE=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secret rhsi-link-token -o jsonpath='{.data.code}' | base64 -d)
SECRET_CA=$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secret rhsi-link-token -o jsonpath='{.data.ca}' | base64 -d)

if [[ "${AG_URL}" == "${SECRET_URL}" ]]; then
  ok "AccessGrant.status.url matches Secret.url"
else
  fail "AccessGrant.status.url does NOT match Secret.url"
fi

if [[ "${AG_CODE}" == "${SECRET_CODE}" ]]; then
  ok "AccessGrant.status.code matches Secret.code"
else
  fail "AccessGrant.status.code does NOT match Secret.code"
fi

if [[ "${AG_CA}" == "${SECRET_CA}" ]]; then
  ok "AccessGrant.status.ca matches Secret.ca"
else
  fail "AccessGrant.status.ca does NOT match Secret.ca"
fi

echo "[*] Checking Vault contents at ${VAULT_PATH}..."
if [[ -n "${VAULT_ADDR:-}" && -n "${VAULT_TOKEN:-}" ]]; then
  VAULT_JSON=$(vault kv get -format=json "${VAULT_PATH}" 2>/dev/null || echo "")
  if [[ -n "${VAULT_JSON}" ]]; then
    V_URL=$(echo "${VAULT_JSON}" | jq -r '.data.data.url')
    V_CODE=$(echo "${VAULT_JSON}" | jq -r '.data.data.code')
    V_CA=$(echo "${VAULT_JSON}" | jq -r '.data.data.ca')

    if [[ "${V_URL}" == "${AG_URL}" ]]; then
      ok "Vault.url matches AccessGrant.status.url"
    else
      fail "Vault.url does NOT match AccessGrant.status.url"
    fi

    if [[ "${V_CODE}" == "${AG_CODE}" ]]; then
      ok "Vault.code matches AccessGrant.status.code"
    else
      fail "Vault.code does NOT match AccessGrant.status.code"
    fi

    if [[ "${V_CA}" == "${AG_CA}" ]]; then
      ok "Vault.ca matches AccessGrant.status.ca"
    else
      fail "Vault.ca does NOT match AccessGrant.status.ca"
    fi
  else
    fail "Could not read ${VAULT_PATH} from Vault (check VAULT_ADDR/VAULT_TOKEN)"
  fi
else
  fail "VAULT_ADDR/VAULT_TOKEN not set; skipping Vault content comparison"
fi

echo
ok "Sanity check script completed"
