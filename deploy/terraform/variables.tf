variable "deployment_type" {
  description = "Type de déploiement (vm ou lxc)"
  type        = string
  default     = "vm"
}

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

variable "lxc_id" {
  description = "ID du conteneur LXC"
  type        = number
  default     = 300
}

variable "vm_ip" {
  description = "IP statique de la VM ou du LXC (ex: 192.168.1.100/24)"
  type        = string
}

variable "vm_gateway" {
  description = "Passerelle réseau"
  type        = string
  default     = "192.168.1.1"
}

variable "vm_console_password" {
  description = "Mot de passe pour accès console (urgence)"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Clé SSH publique pour accéder à la VM ou au LXC"
  type        = string
}

variable "network_vlan" {
  description = "Tag VLAN pour l'interface réseau"
  type        = number
  default     = 0
}

# --- Media Center ---

variable "deploy_media" {
  description = "Déployer le LXC Media Center (Kodi + RetroArch)"
  type        = bool
  default     = false
}

variable "media_lxc_id" {
  description = "ID du conteneur LXC Media Center"
  type        = number
  default     = 301
}

variable "media_lxc_ip" {
  description = "IP statique du LXC Media Center (ex: 192.168.1.101/24)"
  type        = string
  default     = "192.168.1.101/24"
}

