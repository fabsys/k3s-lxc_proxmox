output "vm_id" {
  value = proxmox_virtual_environment_vm.k3s_control.vm_id
}

output "vm_ip" {
  value = var.vm_ip
}
