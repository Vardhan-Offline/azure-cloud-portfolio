# outputs.tf
#
# PURPOSE: Values printed to your terminal after "terraform apply" completes.
# WHY USEFUL:
#   - Quickly see the public IP without logging into the portal
#   - Get the Key Vault URI to paste into application code
#   - Confirm Managed Identity principal_id for verification

output "load_balancer_public_ip" {
  description = "Public IP address — what users type in their browser"
  value       = azurerm_public_ip.lb.ip_address
}

output "web_vm1_private_ip" {
  description = "Private IP of Web VM 1 inside the VNet"
  value       = azurerm_network_interface.web_vm1.private_ip_address
}

output "web_vm2_private_ip" {
  description = "Private IP of Web VM 2 inside the VNet"
  value       = azurerm_network_interface.web_vm2.private_ip_address
}

output "app_vm1_private_ip" {
  description = "Private IP of App VM 1 inside the VNet"
  value       = azurerm_network_interface.app_vm1.private_ip_address
}

output "app_vm_managed_identity_principal_id" {
  description = "Object ID of App VM's Managed Identity — proof it was created"
  value       = azurerm_linux_virtual_machine.app_vm1.identity[0].principal_id
}

output "key_vault_uri" {
  description = "URI used by application code to connect to Key Vault"
  value       = azurerm_key_vault.main.vault_uri
}

output "resource_group_name" {
  description = "Resource group all resources were deployed into"
  value       = data.azurerm_resource_group.main.name
}