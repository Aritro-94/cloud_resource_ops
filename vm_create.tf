terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.114" }
  }
}

# stop the creation of nsg, vnet

provider "azurerm" {
  features {}
  subscription_id = "f2f6c3fc-fdc2-4664-949c-2d214bd0c83e"
}

locals {
  location   = "eastus"
  rg_name    = "LLM_Hosting"
  vm_name    = "llm-host"
  admin_user = "auser"

  vnet_name   = "llm-host-vnet"
  subnet_name = "llm-host-subnet"
  nsg_name    = "llm-host-nsg"
  pip_name    = "llm-host-pip"
  nic_name    = "llm-host773"
}

variable "ssh_public_key" { # Defined in the environment
  type        = string
  description = "Your SSH public key"
}

# resource "azurerm_resource_group" "rg" {
#   name     = local.rg_name
#   location = local.location
# }

resource "azurerm_network_security_group" "nsg" {
  name                = local.nsg_name
  location            = local.location
  resource_group_name = local.rg_name

  security_rule {
    name                       = "allow_ssh"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow_http"
    priority                   = 1010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

    security_rule {
    name                       = "allow_https"
    priority                   = 1020
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_virtual_network" "vnet" {
  name                = local.vnet_name
  address_space       = ["10.10.0.0/16"]
  location            = local.location
  resource_group_name = local.rg_name
}

resource "azurerm_subnet" "subnet" {
  name                 = local.subnet_name
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.1.0/24"]
}

resource "azurerm_subnet_network_security_group_association" "subnet_nsg" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_public_ip" "pip" {
  name                = local.pip_name
  location            = local.location
  resource_group_name = local.rg_name
  allocation_method   = "Static" #"Dynamic"
  sku                 = "Standard"
  
  lifecycle {
    prevent_destroy = false
  }
}

resource "azurerm_network_interface" "nic" {
  name                = local.nic_name
  location            = local.location
  resource_group_name = local.rg_name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
  
  lifecycle {
    prevent_destroy = false
  }
}

# Ubuntu 24.04 LTS (Noble) official image
data "azurerm_platform_image" "ubuntu2404" {
  location  = local.location
  publisher = "Canonical"
  offer     = "ubuntu-24_04-lts-daily"
  sku       = "server"
  # version   = "latest"
  # offer =  "ubuntu-24_04-lts"
  # publisher = "Canonical"
  # sku = "server"
  # version = "latest"
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = local.vm_name
  location            = local.location
  resource_group_name = local.rg_name
  size                = "Standard_D2s_v3"
  admin_username      = local.admin_user
  network_interface_ids = [azurerm_network_interface.nic.id]

  admin_ssh_key {
    username   = local.admin_user
    public_key = var.ssh_public_key
  }
  # admin_ssh_key { # You can add multiple SSH keys
  #   username   = local.admin_user
  #   public_key = var.ssh_public_key
  # }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    # The disk gets deleted by default upon VM deletion
  }


  source_image_reference {
    publisher = data.azurerm_platform_image.ubuntu2404.publisher
    offer     = data.azurerm_platform_image.ubuntu2404.offer
    sku       = data.azurerm_platform_image.ubuntu2404.sku
    version   = "latest"
  }

  disable_password_authentication = true

  boot_diagnostics {
    storage_account_uri = null
  }

  # Match your JSON’s behavior (no hibernation, VM agent on by default)
}

# Create a managed data disk
resource "azurerm_managed_disk" "data_disk" {
  name                 = "myDataDisk1"
  location             = local.location
  resource_group_name  = local.rg_name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 128
}

# Attach it to the VM
resource "azurerm_virtual_machine_data_disk_attachment" "data_attach" {
  managed_disk_id    = azurerm_managed_disk.data_disk.id
  virtual_machine_id = azurerm_linux_virtual_machine.vm.id
  lun                = 0   # must be unique per disk
  caching            = "ReadWrite"
}


# Health extension - probes http://<vm>:80/
resource "azurerm_virtual_machine_extension" "health" {
  name                 = "HealthExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.vm.id
  publisher            = "Microsoft.ManagedServices"
  type                 = "ApplicationHealthLinux"
  type_handler_version = "1.0"
  auto_upgrade_minor_version = false

  settings = jsonencode({
    protocol   = "http"
    port       = 80
    requestPath = "/"
  })
}

output "public_ip" {
  value = azurerm_public_ip.pip.ip_address
}
