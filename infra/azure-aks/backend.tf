# Remote state in an Azure Storage blob container, authenticated with Entra ID
# (no storage account keys). Location is supplied at init time:
#   terraform init -backend-config=backend.hcl
# See backend.hcl.example and docs/github-secrets.md.
terraform {
  backend "azurerm" {}
}
