output "vm_id" {
  description = "ID de la VM créée (si applicable)"
  value       = try(proxmox_virtual_environment_vm.k3s_control[0].vm_id, null)
}

output "lxc_id" {
  description = "ID du LXC créé (si applicable)"
  value       = try(proxmox_virtual_environment_container.k3s_lxc[0].vm_id, null)
}

output "node_ip" {
  description = "IP de l'hôte créé"
  value       = var.vm_ip
}
