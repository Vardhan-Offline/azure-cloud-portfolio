# providers.tf
#
# PURPOSE: Tells Terraform two things:
#   1. What version of Terraform CLI this code needs
#   2. Which plugin (provider) to download to talk to Azure
#
# WHAT IS A PROVIDER?
#   Terraform doesn't speak Azure natively. The "azurerm" provider
#   is a plugin that translates your .tf code into Azure REST API calls.
#   Think of it as an interpreter between Terraform and Azure.

terraform {
  # Minimum Terraform CLI version required to run this code
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"   # Download from HashiCorp's public registry
      version = "~> 3.90.0"           # Use 3.90.x — ~> means allow 3.90.1, 3.90.2
                                      # but NOT 3.91 or 4.x (prevents breaking changes)
    }
  }
}

provider "azurerm" {
  # No subscription_id needed here — Terraform automatically reads
  # the active subscription from your "az login" session.

  features {
    # KEY VAULT SPECIFIC SETTINGS
    # These are critical for sandbox use. Without these,
    # "terraform destroy" will soft-delete the Key Vault but NOT purge it.
    # Next time you run "terraform apply" it fails:
    # "Error: Key Vault already exists in deleted state"
    key_vault {
      purge_soft_delete_on_destroy    = true   # Permanently delete KV on destroy
      recover_soft_deleted_key_vaults = false  # Don't try to recover old deleted KVs
    }
  }
}