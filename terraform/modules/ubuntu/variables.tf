# ============================================================
# WHAT IS THIS FILE?
# Input variables for the proxmox-vm module.
# Every VM that calls this module must supply these values.
# They map 1:1 to the resource arguments in resource.tf.
# ============================================================

variable "name" {
  description = "VM name (used as the Proxmox display name and hostname via cloud-init)."
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID. Must be unique across the entire cluster."
  type        = string
}

variable "node_name" {
  description = "Proxmox node to create the VM on (e.g. 'amy', 'farnsworth')."
  type        = string
}

variable "template_vm_id" {
  description = "VM ID of the Packer-built template to clone from."
  type        = string
}

variable "template_node" {
  description = "Proxmox node where the template config lives. The clone block always needs this, even if the disk is on shared NFS."
  type        = string
}

variable "cores" {
  description = "Number of vCPUs."
  type        = number
}

variable "sockets" {
  description = "Number of CPU sockets"
  type        = number
  default     = 1
}

variable "memory" {
  description = "RAM in MB."
  type        = number
}

variable "disk" {
  description = "Boot disk size in GB."
  type        = number
}

variable "datastore" {
  description = "Proxmox datastore ID for both the cloned disk and the new VM's disk (e.g. 'data', 'local-lvm')."
  type        = string
}

variable "ip" {
  description = "Static IPv4 address to assign via cloud-init (without prefix length, e.g. '172.27.81.60')."
  type        = string
}

variable "gateway" {
  description = "Default gateway for this VM's subnet."
  type        = string
}

variable "vlan" {
  description = "VLAN tag to apply to the VM's network interface."
  type        = number
}

variable "tags" {
  description = "List of Proxmox tags to apply (used for Ansible inventory grouping)."
  type        = list(string)
}

variable "dns_servers" {
  description = "List of DNS server IPs to inject via cloud-init."
  type        = list(string)
}
variable "network_bridge" {
  type    = string
  default = "vmbr0"
}
