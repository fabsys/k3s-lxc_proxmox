terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = true
}

# --- TEMPLATES ---

resource "proxmox_virtual_environment_download_file" "debian13_vm" {
  count               = var.deployment_type == "vm" ? 1 : 0
  content_type        = "iso"
  datastore_id        = "local"
  node_name           = var.proxmox_node
  url                 = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  file_name           = "debian-13-genericcloud-amd64.img"
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_download_file" "debian12_lxc" {
  count               = var.deployment_type == "lxc" ? 1 : 0
  content_type        = "vztmpl"
  datastore_id        = "local"
  node_name           = var.proxmox_node
  url                 = "http://download.proxmox.com/images/system/debian-13-standard_13.1-2_amd64.tar.zst"
  file_name           = "debian-13-standard_13.1-2_amd64.tar.zst"
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_download_file" "ubuntu2404_lxc" {
  count               = var.deploy_media ? 1 : 0
  content_type        = "vztmpl"
  datastore_id        = "local"
  node_name           = var.proxmox_node
  url                 = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  file_name           = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  overwrite_unmanaged = true
}

# --- MODE VM + CILIUM ---

resource "proxmox_virtual_environment_vm" "k3s_control" {
  count       = var.deployment_type == "vm" ? 1 : 0
  name        = "k3s-control"
  node_name   = var.proxmox_node
  vm_id       = var.vm_id
  description = "K3s control node (VM) — GitOps homelab"

  on_boot = true
  started = true
  machine = "pc"
  bios    = "seabios"

  agent { enabled = false }

  cpu {
    cores = 3
    type  = "host"
  }

  memory {
    dedicated = 13312
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.debian13_vm[0].id
    interface    = "scsi0"
    size         = 30
  }

  network_device {
    model    = "virtio"
    bridge   = "vmbr0"
    vlan_id  = var.network_vlan > 0 ? var.network_vlan : null
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.vm_ip
        gateway = var.vm_gateway
      }
    }
    user_account {
      username = "ansible"
      keys     = [var.ssh_public_key]
      password = var.vm_console_password
    }
  }
}

# --- MODE LXC + CALICO ---

resource "proxmox_virtual_environment_container" "k3s_lxc" {
  count       = var.deployment_type == "lxc" ? 1 : 0
  node_name   = var.proxmox_node
  vm_id       = var.lxc_id
  description = "K3s control node (LXC) — GitOps homelab"
  unprivileged = false
  started      = true

  initialization {
    hostname = "k3s-lxc"
    ip_config {
      ipv4 {
        address = var.vm_ip
        gateway = var.vm_gateway
      }
    }
    user_account {
      keys     = [var.ssh_public_key]
      password = var.vm_console_password
    }
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.debian12_lxc[0].id
    type             = "debian"
  }

  features {
    nesting = true
    keyctl  = true
  }

  network_interface {
    name    = "eth0"
    bridge   = "vmbr0"
    vlan_id = var.network_vlan > 0 ? var.network_vlan : null
  }

  # --- Note: Le passthrough GPU (/dev/dri) et /dev/kmsg pour LXC 
  # doit être fait via la configuration brute (lxc_config) 
  # ou manuellement sur l'hôte Proxmox (fichier /etc/pve/lxc/ID.conf)
  # exemple: lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file

  memory {
    dedicated = 8192
  }

  cpu {
    cores = 4
  }

  disk {
    datastore_id = "local-lvm"
    size         = 30
  }
}

# --- MODE LXC MEDIA CENTER ---

resource "proxmox_virtual_environment_container" "media_lxc" {
  count        = var.deploy_media ? 1 : 0
  node_name    = var.proxmox_node
  vm_id        = var.media_lxc_id
  description  = "Media Center LXC — Kodi + RetroArch + Retrogaming"
  unprivileged = false
  started      = true

  initialization {
    hostname = "media-lxc"
    ip_config {
      ipv4 {
        address = var.media_lxc_ip
        gateway = var.vm_gateway
      }
    }
    user_account {
      keys     = [var.ssh_public_key]
      password = var.vm_console_password
    }
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.ubuntu2404_lxc[0].id
    type             = "ubuntu"
  }

  features {
    nesting = true
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = var.network_vlan > 0 ? var.network_vlan : null
  }

  memory {
    dedicated = 8192
  }

  cpu {
    cores = 12
  }

  disk {
    datastore_id = "local-lvm"
    size         = 30
  }
}
