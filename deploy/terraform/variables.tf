variable "proxmox_endpoint" {
  description = "URL de l'API Proxmox (ex: https://192.168.1.10:8006)"
  type        = string
}

variable "proxmox_username" {
  description = "Utilisateur Proxmox (ex: root@pam)"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Mot de passe Proxmox"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Nom du nœud Proxmox"
  type        = string
  default     = "pve"
}

variable "vm_id" {
  description = "ID de la VM"
  type        = number
  default     = 200
}

variable "vm_ip" {
  description = "IP statique de la VM (ex: 192.168.1.100/24)"
  type        = string
}

variable "vm_gateway" {
  description = "Passerelle réseau"
  type        = string
  default     = "192.168.1.1"
}

variable "ssh_public_key" {
  description = "Clé SSH publique pour accéder à la VM"
  type        = string
}

variable "debian_image_id" {
  description = "ID de l'image cloud Debian 13 dans Proxmox (ex: local:iso/debian-13-genericcloud-amd64.img)"
  type        = string
  default     = "local:iso/debian-13-genericcloud-amd64.img"
}
