# ============================================================
# WHAT IS THIS FILE?
# The reusable VM blueprint. Defines one Proxmox VM resource
# using variables supplied by the caller (vms/vm-definitions.tf).
#
# This module handles Ubuntu-style VMs: single NIC, cloud-init,
# qemu-guest-agent. OPNsense or other appliances that need
# multiple NICs or different boot behaviour get their own module.
# ============================================================
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73.0"
    }
  }
}
resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name
  vm_id     = var.vm_id
  tags      = var.tags

  timeout_clone    = 1800  # 30 minutes — full clones from NFS can take time
  timeout_start_vm = 600   # 10 minutes

  # Clone from the Packer-built template.
  # node_name here tells Proxmox where the template CONFIG lives —
  # this is separate from where the new VM will be created (node_name above).
  # Because the template disk is on shared NFS, Proxmox can clone it from
  # any node without transferring data between hosts.
  clone {
    vm_id        = var.template_vm_id
    node_name    = var.template_node
    full         = true        # Full clone — independent disk, no link to template
    datastore_id = var.datastore
  }

  cpu {
    cores = var.cores
    sockets = var.sockets
    type  = "host"  # Pass through host CPU flags
  }

  memory {
    dedicated = var.memory
  }

  # qemu-guest-agent is pre-installed in the Packer template.
  # Terraform waits for the agent to report ready before marking the VM provisioned.
  agent {
    enabled = true
  }

  disk {
    datastore_id = var.datastore
    interface    = "scsi0"
    size         = var.disk
  }

  network_device {
    model   = "virtio"
    bridge  = var.network_bridge
    vlan_id = var.vlan
  }

  # Cloud-init injects the static IP and DNS on first boot.
  # The cloud-init drive was baked into the template by Packer.
  initialization {
    ip_config {
      ipv4 {
        address = "${var.ip}/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }
}
