# ============================================================
# WHAT IS THIS FILE?
# Values this module exposes back to its caller (vms/main.tf).
# The outputs.tf in vms/ references these to build vm_info.json
# for Ansible consumption.
# ============================================================

output "vm_id" {
  description = "The Proxmox VM ID assigned to this VM."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "ip" {
  description = "The static IP address assigned to this VM via cloud-init."
  value       = var.ip
}

output "name" {
  description = "The VM name."
  value       = var.name
}

output "node" {
  description = "The Proxmox node this VM was created on."
  value       = var.node_name
}
