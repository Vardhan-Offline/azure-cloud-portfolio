# variables.tf
#
# PURPOSE: Declares all "inputs" to your Terraform configuration.
#   Think of variables like function parameters in programming.
#   You declare them here. You give them values in terraform.tfvars.
#
# WHY SEPARATE FILE?
#   Keeps your main.tf clean. Anyone reading variables.tf immediately
#   knows what inputs this configuration expects.

variable "location" {
  description = "Azure region. LOCKED to eastus for Pluralsight sandbox — do not change."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Pre-existing RG created by Pluralsight. DO NOT CHANGE — this is not created by Terraform."
  type        = string
  default     = "1-27cc5856-playground-sandbox"
  # WHY data source not resource: Pluralsight created this RG before you logged in.
  # If Terraform tries to CREATE it, you get: "Error: RG already exists"
  # Instead we READ it using a data block in main.tf
}

variable "admin_username" {
  description = "Admin username for all VMs"
  type        = string
  default     = "azureadmin"
  # This is the username you will use if you ever SSH into a VM
}

variable "admin_password" {
  description = "Admin password for all VMs. Set in terraform.tfvars — never hardcode here."
  type        = string
  sensitive   = true
  # sensitive = true means Terraform will NEVER print this value in:
  #   - terraform plan output
  #   - terraform apply output
  #   - log files
  # It will always show as "(sensitive value)"
  # Azure password requirements: min 12 chars, uppercase, lowercase, number, special char
}

variable "key_vault_name" {
  description = "MUST BE GLOBALLY UNIQUE across all Azure customers worldwide. Change lv to your own initials."
  type        = string
  default     = "kv-3tier-lv-001"
  # KEY VAULT NAMING RULES:
  #   - 3 to 24 characters
  #   - Alphanumerics and hyphens only
  #   - Must start with a letter
  #   - Must end with letter or digit
  #   - No consecutive hyphens
  # WHY globally unique: Key Vault DNS names are public (yourname.vault.azure.net)
  # If someone else already used "kv-3tier-lkv-001", yours will fail.
}

variable "tags" {
  description = "Tags applied to every resource. Useful for filtering in Azure Portal and cost tracking."
  type        = map(string)
  default = {
    Project     = "3tier-secure"
    Environment = "sandbox"
    ManagedBy   = "Terraform"
    Owner       = "Vardhan"   # CHANGE THIS to your name
  }
}