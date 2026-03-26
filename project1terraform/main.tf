# main.tf
#
# PURPOSE: Defines every Azure resource to be created.
# ORDER DOES NOT MATTER — Terraform reads references between
# resources and figures out the correct build order automatically.
# (e.g., VNet must exist before Subnet — Terraform knows this because
#  Subnet references VNet by name)

# ═══════════════════════════════════════════════════════════
# BLOCK 1: DATA SOURCES (Read existing resources — not created by us)
# ═══════════════════════════════════════════════════════════

# DATA SOURCE: Reads the pre-existing Pluralsight resource group.
# "data" blocks READ existing Azure resources.
# "resource" blocks CREATE new Azure resources.
# We use data here because the RG was pre-created by Pluralsight.
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

# DATA SOURCE: Reads the identity of whoever ran "az login"
# We need this to:
#   1. Get tenant_id for Key Vault configuration
#   2. Get object_id to give ourselves Key Vault admin access
data "azurerm_client_config" "current" {}


# ═══════════════════════════════════════════════════════════
# BLOCK 2: VIRTUAL NETWORK
# The private network container — all resources live inside this.
# Think of it as the walls of your building.
# ═══════════════════════════════════════════════════════════

resource "azurerm_virtual_network" "main" {
  name                = "vnet-3tier-eastus"
  address_space       = ["10.0.0.0/16"]
  # 10.0.0.0/16 means IP addresses from 10.0.0.0 to 10.0.255.255
  # = 65,536 possible IP addresses in this VNet
  # We carve this into smaller /24 subnets (256 IPs each) below.

  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  # Note: We reference data.azurerm_resource_group.main
  # NOT azurerm_resource_group.main (which would mean we created it)
  # This is the sandbox adjustment.

  tags = var.tags
}


# ═══════════════════════════════════════════════════════════
# BLOCK 3: SUBNETS — 3 isolated network segments (the 3 floors)
# ═══════════════════════════════════════════════════════════

# Web Subnet — Front-end VMs live here. Faces the internet.
resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
  # 10.0.1.0/24 = addresses 10.0.1.0 to 10.0.1.255 (256 IPs)
}

# App Subnet — Application server VMs live here. No internet access.
resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
  # 10.0.2.0/24 = addresses 10.0.2.0 to 10.0.2.255 (256 IPs)
}

# DB Subnet — Database lives here. Most isolated — only app tier can reach it.
resource "azurerm_subnet" "db" {
  name                 = "snet-db"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.3.0/24"]
  # 10.0.3.0/24 = addresses 10.0.3.0 to 10.0.3.255 (256 IPs)
}


# ═══════════════════════════════════════════════════════════
# BLOCK 4: NETWORK SECURITY GROUPS
# One NSG per subnet. Each is a stateful firewall (bouncer)
# that controls what traffic can enter and leave that subnet.
# ═══════════════════════════════════════════════════════════

# ── NSG for Web Subnet ──────────────────────────────────────
# ALLOWS: HTTPS (443) and HTTP (80) from internet
# ALLOWS: Outbound to App subnet on port 8080
# DENIES: Everything else (Azure's implicit deny at priority 65500)
resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  tags                = var.tags

  # RULE: Allow HTTPS traffic in from anywhere on the internet
  # Priority 100 = checked first. Lower number = higher priority.
  security_rule {
    name                       = "Allow-HTTPS-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"        # Source port is random (client side) — always *
    destination_port_range     = "443"      # HTTPS port
    source_address_prefix      = "Internet" # Azure service tag: means "all public internet IPs"
    destination_address_prefix = "*"        # Any IP in this subnet
  }

  # RULE: Allow HTTP (port 80) — needed so browsers redirected to HTTPS work
  security_rule {
    name                       = "Allow-HTTP-Inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # RULE: Allow web VMs to send requests OUT to the app tier
  # Web server receives user request → forwards to App server for processing
  security_rule {
    name                       = "Allow-Outbound-To-App"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"          # App server listens on 8080
    source_address_prefix      = "10.0.1.0/24"  # From: Web subnet
    destination_address_prefix = "10.0.2.0/24"  # To: App subnet only
  }
}

# ── NSG for App Subnet ──────────────────────────────────────
# ALLOWS: Inbound from Web subnet only (port 8080)
# DENIES: Direct inbound from internet
# ALLOWS: Outbound to DB subnet (port 1433 = SQL Server)
resource "azurerm_network_security_group" "app" {
  name                = "nsg-app"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  tags                = var.tags

  # RULE: Only the web subnet can initiate connections to the app tier
  # This means: even if a hacker breaks into the internet, they
  # CANNOT talk to the app server directly — must go through web tier
  security_rule {
    name                       = "Allow-Inbound-From-Web"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "10.0.1.0/24"  # ONLY from Web subnet
    destination_address_prefix = "*"
  }

  # RULE: Explicitly block any direct internet access to app tier
  # Even though Azure has an implicit deny, making this explicit
  # documents the intent clearly and covers edge cases
  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # RULE: App server sends SQL queries to the database
  # Port 1433 is the default Microsoft SQL Server port
  security_rule {
    name                       = "Allow-Outbound-To-DB"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "10.0.2.0/24"  # From: App subnet
    destination_address_prefix = "10.0.3.0/24"  # To: DB subnet only
  }
}

# ── NSG for DB Subnet ──────────────────────────────────────
# Most restrictive NSG. Database talks to NOBODY except the app tier.
# ALLOWS: Inbound from App subnet only (port 1433)
# DENIES: Everything else in AND out
resource "azurerm_network_security_group" "db" {
  name                = "nsg-db"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  tags                = var.tags

  # RULE: Only app tier VMs can query the database
  security_rule {
    name                       = "Allow-Inbound-From-App"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "10.0.2.0/24"  # ONLY from App subnet
    destination_address_prefix = "*"
  }

  # RULE: Block everything else trying to reach the database
  security_rule {
    name                       = "Deny-All-Other-Inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # RULE: Database server must NEVER initiate outbound internet connections
  # Databases should only RESPOND to app tier — never call out
  security_rule {
    name                       = "Deny-Internet-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}


# ── Attach NSGs to their Subnets ────────────────────────────
# CRITICAL: Creating an NSG does not automatically protect a subnet.
# You must explicitly associate it. Without this, the NSG rules do nothing.

resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.db.id
}


# ═══════════════════════════════════════════════════════════
# BLOCK 5: PUBLIC IP ADDRESS
# A fixed, public-facing IP. This is what users connect to.
# The Load Balancer will sit behind this IP.
# ═══════════════════════════════════════════════════════════

resource "azurerm_public_ip" "lb" {
  name                = "pip-lb-web"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  allocation_method   = "Static"    # IP is permanently reserved — never changes
                                    # Dynamic = IP changes when LB is stopped — bad for DNS
  sku                 = "Standard"  # Must match Load Balancer SKU (both must be Standard)
  tags                = var.tags
}


# ═══════════════════════════════════════════════════════════
# BLOCK 6: LOAD BALANCER
# Distributes traffic across web VMs. Has 4 parts:
#   1. LB resource itself (with Frontend IP)
#   2. Backend Pool (which VMs receive traffic)
#   3. Health Probe (checks if each VM is alive)
#   4. Load Balancing Rule (ties everything together)
# ═══════════════════════════════════════════════════════════

# The Load Balancer resource + its public frontend IP
resource "azurerm_lb" "web" {
  name                = "lb-web-frontend"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  sku                 = "Standard"   # Standard SKU: needed for Availability Zones,
                                     # HTTPS health probes, and production SLA
  tags                = var.tags

  # Frontend IP: what users see and connect to
  # The LB listens on this IP and distributes incoming connections
  frontend_ip_configuration {
    name                 = "frontend-ip"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

# Backend Pool: the named group of VMs that receive traffic
# VMs are added to this pool via NIC associations below
resource "azurerm_lb_backend_address_pool" "web" {
  loadbalancer_id = azurerm_lb.web.id
  name            = "backend-web-pool"
}

# Health Probe: checks every 15 seconds if each VM is alive
# HOW IT WORKS: LB tries to open TCP connection to each VM on port 443
#   - Connection succeeds = VM is HEALTHY → keep sending traffic
#   - Connection fails 2 times in a row = VM is UNHEALTHY → stop sending traffic
#   - VM recovers, 2 consecutive successes = HEALTHY again → resume traffic
resource "azurerm_lb_probe" "web_https" {
  loadbalancer_id     = azurerm_lb.web.id
  name                = "probe-https"
  protocol            = "Tcp"   # TCP: tries to open connection (simpler than HTTP)
  port                = 443     # The port it tries to connect to on each VM
  interval_in_seconds = 15      # Probe every 15 seconds
  number_of_probes    = 2       # 2 consecutive failures = mark as unhealthy
}

# Load Balancing Rule: the instruction connecting all parts
# "When traffic arrives on port 443 at the frontend IP,
#  send it to backend pool, use the health probe to pick only healthy VMs"
resource "azurerm_lb_rule" "web_https" {
  loadbalancer_id                = azurerm_lb.web.id
  name                           = "rule-https"
  protocol                       = "Tcp"
  frontend_port                  = 443           # Traffic arrives on this port (public)
  backend_port                   = 443           # Forwarded to this port on the VM
  frontend_ip_configuration_name = "frontend-ip" # Must match name in azurerm_lb above
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.web.id]
  probe_id                       = azurerm_lb_probe.web_https.id
}


# ═══════════════════════════════════════════════════════════
# BLOCK 7: WEB TIER VMs (2 VMs for High Availability)
# Two identical VMs — both sit behind the Load Balancer.
# If one crashes, the other handles all traffic automatically.
# Each VM has:
#   - NIC (network interface — the VM's network port)
#   - NIC associated to LB backend pool (puts it "behind" the LB)
#   - System-Assigned Managed Identity
# ═══════════════════════════════════════════════════════════

# NIC for Web VM 1 — connects VM to the web subnet
# NIC = Network Interface Card. Virtual equivalent of an ethernet port.
resource "azurerm_network_interface" "web_vm1" {
  name                = "nic-web-vm1"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.web.id  # Connects to Web subnet
    private_ip_address_allocation = "Dynamic"
    # Dynamic: Azure picks a free IP from 10.0.1.0/24 automatically
    # Static alternative: you specify the exact IP (e.g., "10.0.1.4")
  }
}

resource "azurerm_network_interface" "web_vm2" {
  name                = "nic-web-vm2"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.web.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Put NIC 1 into the LB backend pool
# This is what makes the Load Balancer aware of web VM 1
resource "azurerm_network_interface_backend_address_pool_association" "web_vm1" {
  network_interface_id    = azurerm_network_interface.web_vm1.id
  ip_configuration_name   = "internal"                             # Must match ip_configuration name above
  backend_address_pool_id = azurerm_lb_backend_address_pool.web.id
}

resource "azurerm_network_interface_backend_address_pool_association" "web_vm2" {
  network_interface_id    = azurerm_network_interface.web_vm2.id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.web.id
}

# Web VM 1
resource "azurerm_linux_virtual_machine" "web_vm1" {
  name                            = "vm-web-01"
  resource_group_name             = data.azurerm_resource_group.main.name
  location                        = data.azurerm_resource_group.main.location
  size                            = "Standard_B1s"  # Smallest/cheapest: 1 vCPU, 1GB RAM
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false  # Allow password login (no SSH key needed for demo)

  network_interface_ids = [azurerm_network_interface.web_vm1.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"  # Standard HDD — cheapest, fine for demo
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
    # Ubuntu 20.04 LTS — free OS, well supported, widely used
  }

  # MANAGED IDENTITY — the key security feature
  # type = "SystemAssigned" tells Azure:
  #   "Create a Service Principal in Azure AD, tie it to this VM's lifecycle,
  #    give this VM a built-in identity it can use to authenticate"
  # Azure manages the private key internally — you never see it
  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# Web VM 2 — identical to VM 1
resource "azurerm_linux_virtual_machine" "web_vm2" {
  name                            = "vm-web-02"
  resource_group_name             = data.azurerm_resource_group.main.name
  location                        = data.azurerm_resource_group.main.location
  size                            = "Standard_B1s"
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false

  network_interface_ids = [azurerm_network_interface.web_vm2.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}


# ═══════════════════════════════════════════════════════════
# BLOCK 8: APP TIER VM
# Lives in app subnet. No public IP. Never reachable from internet.
# Has Managed Identity to authenticate to Key Vault.
# ═══════════════════════════════════════════════════════════

resource "azurerm_network_interface" "app_vm1" {
  name                = "nic-app-vm1"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id  # App subnet — not web subnet
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "app_vm1" {
  name                            = "vm-app-01"
  resource_group_name             = data.azurerm_resource_group.main.name
  location                        = data.azurerm_resource_group.main.location
  size                            = "Standard_B1s"
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false

  network_interface_ids = [azurerm_network_interface.app_vm1.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
    # This VM's identity will be granted Key Vault access below.
    # After VM is created, Terraform reads:
    # azurerm_linux_virtual_machine.app_vm1.identity[0].principal_id
    # That principal_id is the Object ID of the auto-created Service Principal.
  }

  tags = var.tags
}


# ═══════════════════════════════════════════════════════════
# BLOCK 9: KEY VAULT + ACCESS POLICIES
#
# SANDBOX ADJUSTMENT: Pluralsight Starkiller role cannot write
# Azure AD RBAC role assignments (azurerm_role_assignment).
# SOLUTION: Use Key Vault Access Policies instead of RBAC model.
# Access Policies are resource-level settings — no AAD write needed.
#
# TWO ACCESS POLICIES:
#   1. Current sandbox user — full access (to create secrets via Terraform)
#   2. App VM managed identity — read-only (to read secrets at runtime)
# ═══════════════════════════════════════════════════════════

resource "azurerm_key_vault" "main" {
  name                = var.key_vault_name  # ← YOU MUST CHANGE THIS (see variables.tf)
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"  # standard vs premium (premium adds HSM — not needed for demo)

  soft_delete_retention_days = 7      # Minimum allowed — keep short for sandbox cleanup
  purge_protection_enabled   = false  # MUST be false for sandbox. If true, you cannot
                                      # force-delete KV during terraform destroy.
  tags = var.tags
}

# ACCESS POLICY 1: Grant the sandbox user (you) full secret management
# WHY: Terraform runs as YOU. When it tries to create the secret below,
# it needs permission to write to Key Vault first.
# data.azurerm_client_config.current.object_id = YOUR Azure AD Object ID
resource "azurerm_key_vault_access_policy" "admin" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id  # Your identity

  secret_permissions = [
    "Get",    # Read a specific secret
    "List",   # List all secret names
    "Set",    # Create/update secrets
    "Delete", # Delete secrets
    "Purge"   # Permanently delete (needed for clean terraform destroy)
  ]
}

# ACCESS POLICY 2: Grant App VM's Managed Identity READ-ONLY access
# WHY: At runtime, the app reads its DB connection string from Key Vault.
# It only needs to GET secrets — not create or delete them.
# principal_id = the Object ID of the Service Principal Azure created
#                when we set identity { type = "SystemAssigned" } on the VM
resource "azurerm_key_vault_access_policy" "app_vm" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_virtual_machine.app_vm1.identity[0].principal_id

  secret_permissions = [
    "Get",   # Read a specific secret by name
    "List"   # List available secret names
    # Deliberately NO Set/Delete/Purge — least privilege principle
  ]
}

# Sample secret stored in Key Vault
# In a real project: DB connection string, API keys, certificates
# depends_on ensures admin access policy exists BEFORE Terraform tries to create the secret
resource "azurerm_key_vault_secret" "db_connection" {
  name         = "db-connection-string"
  value        = "Server=sql-3tier.database.windows.net;Database=appdb;Authentication=Active Directory Managed Identity;"
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_key_vault_access_policy.admin]
  # depends_on = explicit dependency. Terraform normally figures out order from references.
  # Here, the secret doesn't reference the policy directly, but NEEDS it to exist first.
  # Without this, Terraform might create the secret before the policy — causing a 403 Forbidden error.
}