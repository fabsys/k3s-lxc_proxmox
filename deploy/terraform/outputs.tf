output "vm_id" {
  description = "ID de la VM créée (si applicable)"
  value       = try(proxmox_virtual_environment_vm.k3s_control[0].vm_id, null)
}

output "lxc_id" {
  description = "ID du LXC k3s créé (si applicable)"
  value       = try(proxmox_virtual_environment_container.k3s_lxc[0].vm_id, null)
}

output "node_ip" {
  description = "IP de l'hôte k3s créé"
  value       = var.vm_ip
}

output "media_lxc_id" {
  description = "ID du LXC Media Center créé (si applicable)"
  value       = try(proxmox_virtual_environment_container.media_lxc[0].vm_id, null)
}

output "media_lxc_ip" {
  description = "IP du LXC Media Center"
  value       = var.deploy_media ? var.media_lxc_ip : null
}
