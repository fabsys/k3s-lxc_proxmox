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
  insecure = true # Accepte le certificat auto-signé Proxmox
}

resource "proxmox_virtual_environment_download_file" "debian13" {
  content_type        = "iso"
  datastore_id        = "local"
  node_name           = var.proxmox_node
  url                 = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  file_name           = "debian-13-genericcloud-amd64.img"
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_vm" "k3s_control" {
  name        = "k3s-control"
  node_name   = var.proxmox_node
  vm_id       = var.vm_id
  description = "K3s control node — GitOps homelab"

  on_boot = true
  started = true

  machine = "pc"
  bios    = "seabios"

  # QEMU Guest Agent — désactivé au boot initial (pas préinstallé dans l'image cloud)
  # Ansible installe qemu-guest-agent, puis Proxmox le détecte automatiquement
  agent {
    enabled = false
  }

  timeout_create = "5m"

  # CPU
  cpu {
    cores   = 3
    sockets = 1
    units   = 1024
    type    = "host" # Expose les instructions CPU du host (utile pour le transcoding)
  }

  # RAM fixe — pas de balloon pour éviter les OOM k3s
  memory {
    dedicated = 13312
    floating  = 0
  }

  # Disque OS (~30GB) — cloné depuis l'image cloud Debian 13
  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.debian13.id
    interface    = "scsi0"
    size         = 30
    cache        = "writeback"
    discard      = "on"
    ssd          = true
  }

  # Disque données (~100GB) — PVCs k3s local-path
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi1"
    size         = 100
    cache        = "writeback"
    discard      = "on"
    ssd          = true
  }

  # Contrôleur SCSI
  scsi_hardware = "virtio-scsi-single"

  # Réseau — on garde le même MAC pour conserver l'IP DHCP
  network_device {
    model   = "virtio"
    bridge  = "vmbr0"
    mac_address = "BC:24:11:80:91:08"
    queues  = 2
  }

  # Port série (requis pour la console Proxmox)
  serial_device {}

  # PCI passthrough — Intel GPU (VAAPI pour Jellyfin)
  hostpci {
    device  = "hostpci0"
    id      = "0000:00:02"
    rombar  = true
  }

  # Virtiofs — partages du host Proxmox
  virtiofs {
    mapping = "movies"
  }

  virtiofs {
    mapping = "paperless"
  }

  # Cloud-init
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

    dns {
      servers = ["1.1.1.1", "8.8.8.8"]
    }
  }

  # Boot sur le disque OS
  boot_order = ["scsi0"]
}
