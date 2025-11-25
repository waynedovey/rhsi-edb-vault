#!/usr/bin/env bash
#
# Sanity check for Skupper link created via Vault on site-b (standby) to site-a (primary).
#
# Defaults are tuned for this lab:
#   SITE_A_CTX=site-a
#   SITE_B_CTX=site-b
#   NAMESPACE=rhsi
#   GRANT_NAME=rhsi-standby-grant
#   ACCESS_TOKEN_NAME=standby-from-vault
#   SECRETSTORE_NAME=vault-rhsi
#   EXTERNALSECRET_NAME=rhsi-link-token
#   VAULT_PATH_SITE_B=rhsi/site-b/link-token
#
# Override via environment variables if needed.

set -u -o pipefail

SITE_A_CTX="${SITE_A_CTX:-site-a}"
SITE_B_CTX="${SITE_B_CTX:-site-b}"
NAMESPACE="${NAMESPACE:-rhsi}"
GRANT_NAME="${GRANT_NAME:-rhsi-standby-grant}"
ACCESS_TOKEN_NAME="${ACCESS_TOKEN_NAME:-standby-from-vault}"
SECRETSTORE_NAME="${SECRETSTORE_NAME:-vault-rhsi}"
EXTERNALSECRET_NAME="${EXTERNALSECRET_NAME:-rhsi-link-token}"
VAULT_PATH_SITE_B="${VAULT_PATH_SITE_B:-rhsi/site-b/link-token}"

# Simple colour helpers (fallback to plain if tput not available)
if command -v tput >/dev/null 2>&1; then
  GREEN="$(tput setaf 2)"; RED="$(tput setaf 1)"; YELLOW="$(tput setaf 3)"; BOLD="$(tput bold)"; RESET="$(tput sgr0)"
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

info()  { echo "${BOLD}[*]${RESET} $*"; }
ok()    { echo "${GREEN}[OK]${RESET} $*"; }
warn()  { echo "${YELLOW}[WARN]${RESET} $*"; }
fail()  { echo "${RED}[FAIL]${RESET} $*"; }

# base64 decode helper that works on Linux and macOS
b64dec() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0")

Environment variables:
  SITE_A_CTX          kube context for primary site (default: site-a)
  SITE_B_CTX          kube context for standby site (default: site-b)
  NAMESPACE           namespace for rhsi objects (default: rhsi)
  GRANT_NAME          name of AccessGrant on site-a (default: rhsi-standby-grant)
  ACCESS_TOKEN_NAME   name of AccessToken on site-b (default: standby-from-vault)
  SECRETSTORE_NAME    name of SecretStore on site-b (default: vault-rhsi)
  EXTERNALSECRET_NAME name of ExternalSecret on site-b (default: rhsi-link-token)
  VAULT_PATH_SITE_B   Vault KV v2 path for site-b grant (default: rhsi/site-b/link-token)

Example:
  SITE_A_CTX=site-a SITE_B_CTX=site-b NAMESPACE=rhsi \\
    $(basename "$0")
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

FAIL=0

###############################################################################
# 1. Check Skupper link on site-b
###############################################################################
info "Checking Skupper link status on site-b (${SITE_B_CTX}, ns=${NAMESPACE})..."

if ! command -v skupper >/dev/null 2>&1; then
  fail "skupper CLI not found in PATH"
  FAIL=1
else
  LINK_LINE="$(skupper --context "${SITE_B_CTX}" --namespace "${NAMESPACE}" link status 2>/dev/null | awk -v n="${ACCESS_TOKEN_NAME}" 'NR>1 && $1==n {print $0}')"
  if [[ -z "${LINK_LINE}" ]]; then
    warn "No link row found for '${ACCESS_TOKEN_NAME}'. Full link status:"
    skupper --context "${SITE_B_CTX}" --namespace "${NAMESPACE}" link status || true
    FAIL=1
  else
    LINK_STATUS="$(echo "${LINK_LINE}" | awk '{print $2}')"
    if [[ "${LINK_STATUS}" == "Ready" ]]; then
      ok "Skupper link '${ACCESS_TOKEN_NAME}' is Ready on site-b"
    else
      fail "Skupper link '${ACCESS_TOKEN_NAME}' is present but not Ready (status=${LINK_STATUS})"
      echo "  -> ${LINK_LINE}"
      FAIL=1
    fi
  fi
fi

###############################################################################
# 2. Check AccessToken on site-b
###############################################################################
info "Checking AccessToken '${ACCESS_TOKEN_NAME}' on site-b..."

if ! oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get accesstoken "${ACCESS_TOKEN_NAME}" >/dev/null 2>&1; then
  fail "AccessToken ${ACCESS_TOKEN_NAME} not found in ${NAMESPACE} on ${SITE_B_CTX}"
  FAIL=1
else
  AT_STATUS="$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" \
    get accesstoken "${ACCESS_TOKEN_NAME}" -o jsonpath='{.status.status}' 2>/dev/null || echo "")"
  AT_MSG="$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" \
    get accesstoken "${ACCESS_TOKEN_NAME}" -o jsonpath='{.status.message}' 2>/dev/null || echo "")"

  if [[ "${AT_STATUS}" == "Ready" ]]; then
    ok "AccessToken ${ACCESS_TOKEN_NAME} status is Ready (message='${AT_MSG}')"
  else
    fail "AccessToken ${ACCESS_TOKEN_NAME} status is not Ready (status='${AT_STATUS}', message='${AT_MSG}')"
    FAIL=1
  fi
fi

###############################################################################
# 3. Check SecretStore & ExternalSecret on site-b
###############################################################################
info "Checking SecretStore '${SECRETSTORE_NAME}' and ExternalSecret '${EXTERNALSECRET_NAME}' on site-b..."

SS_LINE="$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secretstore "${SECRETSTORE_NAME}" 2>/dev/null | awk 'NR==2')"
if [[ -z "${SS_LINE}" ]]; then
  fail "SecretStore ${SECRETSTORE_NAME} not found in ${NAMESPACE} on ${SITE_B_CTX}"
  FAIL=1
else
  # Columns: NAME AGE STATUS CAPABILITIES READY
  SS_READY="$(echo "${SS_LINE}" | awk '{print $5}')"
  if [[ "${SS_READY}" == "True" ]]; then
    ok "SecretStore ${SECRETSTORE_NAME} is Ready"
  else
    fail "SecretStore ${SECRETSTORE_NAME} is not Ready (line: ${SS_LINE})"
    FAIL=1
  fi
fi

ES_LINE="$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get externalsecret "${EXTERNALSECRET_NAME}" 2>/dev/null | awk 'NR==2')"
if [[ -z "${ES_LINE}" ]]; then
  fail "ExternalSecret ${EXTERNALSECRET_NAME} not found in ${NAMESPACE} on ${SITE_B_CTX}"
  FAIL=1
else
  # last column is READY
  ES_READY="$(echo "${ES_LINE}" | awk '{print $NF}')"
  if [[ "${ES_READY}" == "True" ]]; then
    ok "ExternalSecret ${EXTERNALSECRET_NAME} is Ready (SecretSynced)"
  else
    fail "ExternalSecret ${EXTERNALSECRET_NAME} is not Ready (line: ${ES_LINE})"
    FAIL=1
  fi
fi

###############################################################################
# 4. Compare Secret (site-b) vs AccessGrant (site-a)
###############################################################################
info "Comparing rhsi-link-token Secret on site-b with AccessGrant '${GRANT_NAME}' on site-a..."

if ! oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secret "${EXTERNALSECRET_NAME}" >/dev/null 2>&1; then
  fail "Secret ${EXTERNALSECRET_NAME} not found in ${NAMESPACE} on ${SITE_B_CTX}"
  FAIL=1
else
  URL_B="$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secret "${EXTERNALSECRET_NAME}" -o jsonpath='{.data.url}' | b64dec || true)"
  CODE_B="$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secret "${EXTERNALSECRET_NAME}" -o jsonpath='{.data.code}' | b64dec || true)"
  CA_B="$(oc --context "${SITE_B_CTX}" -n "${NAMESPACE}" get secret "${EXTERNALSECRET_NAME}" -o jsonpath='{.data.ca}' | b64dec || true)"
fi

if ! oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" >/dev/null 2>&1; then
  fail "AccessGrant ${GRANT_NAME} not found in ${NAMESPACE} on ${SITE_A_CTX}"
  FAIL=1
else
  URL_A="$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.url}' || true)"
  CODE_A="$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.code}' || true)"
  CA_A="$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.ca}' || true)"
  RA_A="$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.spec.redemptionsAllowed}' || echo 0)"
  R_A="$(oc --context "${SITE_A_CTX}" -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.redemptions}' || echo 0)"
fi

if [[ -n "${URL_A:-}" && "${URL_A}" == "${URL_B:-}" ]]; then
  ok "AccessGrant.status.url matches Secret.url"
else
  fail "AccessGrant.status.url (${URL_A}) does NOT match Secret.url (${URL_B})"
  FAIL=1
fi

if [[ -n "${CODE_A:-}" && "${CODE_A}" == "${CODE_B:-}" ]]; then
  ok "AccessGrant.status.code matches Secret.code"
else
  fail "AccessGrant.status.code (${CODE_A}) does NOT match Secret.code (${CODE_B})"
  FAIL=1
fi

if [[ -n "${CA_A:-}" && "${CA_A}" == "${CA_B:-}" ]]; then
  ok "AccessGrant.status.ca matches Secret.ca"
else
  fail "AccessGrant.status.ca does NOT match Secret.ca"
  FAIL=1
fi

# redemptions sanity
if [[ "${RA_A}" -ge 1 && "${R_A}" -ge 1 ]]; then
  ok "AccessGrant redemptions: allowed=${RA_A}, made=${R_A} (grant has been redeemed)"
else
  warn "AccessGrant redemptions look odd: allowed=${RA_A}, made=${R_A}"
fi

###############################################################################
# 5. Optional: Vault sanity (if vault + jq available)
###############################################################################
if command -v vault >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  info "Checking Vault contents at ${VAULT_PATH_SITE_B}..."
  if VAULT_JSON="$(vault kv get -format=json "${VAULT_PATH_SITE_B}" 2>/dev/null)"; then
    URL_V="$(echo "${VAULT_JSON}" | jq -r '.data.data.url')"
    CODE_V="$(echo "${VAULT_JSON}" | jq -r '.data.data.code')"
    CA_V="$(echo "${VAULT_JSON}" | jq -r '.data.data.ca')"

    [[ "${URL_V}"  == "${URL_A}" ]] && ok "Vault.url matches AccessGrant.status.url" || { fail "Vault.url (${URL_V}) != AccessGrant.url (${URL_A})"; FAIL=1; }
    [[ "${CODE_V}" == "${CODE_A}" ]] && ok "Vault.code matches AccessGrant.status.code" || { fail "Vault.code (${CODE_V}) != AccessGrant.code (${CODE_A})"; FAIL=1; }
    [[ "${CA_V}"   == "${CA_A}"   ]] && ok "Vault.ca matches AccessGrant.status.ca"   || { fail "Vault.ca != AccessGrant.ca"; FAIL=1; }
  else
    warn "Vault kv get ${VAULT_PATH_SITE_B} failed; skipping Vault comparison"
  fi
else
  warn "Skipping Vault sanity: vault and/or jq not found in PATH"
fi

###############################################################################
# Result
###############################################################################
echo
if [[ "${FAIL}" -eq 0 ]]; then
  echo "${GREEN}${BOLD}Sanity check PASSED${RESET}"
  exit 0
else
  echo "${RED}${BOLD}Sanity check FAILED (see messages above)${RESET}"
  exit 1
fi
