# Policy used by ESO on site-b to read the Skupper link token from Vault
path "rhsi/data/site-b/link-token" {
  capabilities = ["read"]
}
