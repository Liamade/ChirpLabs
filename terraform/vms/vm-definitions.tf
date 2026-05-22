# THIS IS THE FILE YOU EDIT DAY-TO-DAY.
# Add, remove, or change VMs by editing the ubuntu_vms map in locals.
# Everything else (provider, state, variables) lives in other files
# and rarely needs touching.
#
# Each entry in ubuntu_vms calls the proxmox-vm module once,
# creating one VM on Proxmox cloned from the Packer-built template.

locals {
  dns_servers = ["<dns-server-1>", "<dns-server-2>"]

  # Maps node names to their template IDs and IPs.
  # template_id is resolved automatically from this map — you don't set it per VM.
  nodes = {
    Amy = {
      template_id = 299
      ip          = "<proxmox-node-1-ip>"
    }
    Farnsworth = {
      template_id = 298
      ip          = "<proxmox-node-2-ip>"
    }
  }

  ubuntu_vms = {
    # ── Format ──────────────────────────────────────────────────────────────
    # "vm-name" = {
    #   role           → Ansible inventory group (e.g. "grafana", "nagios")
    #   node_name      → Proxmox node to create the VM on (Amy / Farnsworth)
    #   vm_id          → Unique cluster-wide VM ID
    #   cores          → vCPU count
    #   sockets        → CPU socket count
    #   memory         → RAM in MB
    #   disk           → Boot disk size in GB
    #   datastore      → Proxmox storage pool for the boot disk
    #   ip             → Static IP (injected via cloud-init on first boot)
    #   vlan           → VLAN tag on the network bridge
    #   gateway        → Default gateway for this VM's subnet
    #   network_bridge → Proxmox bridge to attach the NIC to
    #   data_disk      → (optional) name of pre-existing persistent disk to attach
    # }
    # ────────────────────────────────────────────────────────────────────────

    "grafana-test" = {
      role           = "grafana"
      node_name      = "Amy"
      vm_id          = 251
      cores          = 2
      sockets        = 2
      memory         = 4096
      disk           = 8         # small boot disk — data lives on the persistent disk
      datastore      = "data"
      ip             = "<grafana-ip>"
      vlan           = 85
      gateway        = "<vlan85-gateway>"
      data_disk      = "data:vm-999-Grafana-DATA"
      network_bridge = "vmbr0"
    }

    "nagios-test" = {
      role           = "nagios"
      node_name      = "Amy"
      vm_id          = 252
      cores          = 2
      sockets        = 1
      memory         = 8192
      disk           = 8         # small boot disk — data lives on the persistent disk
      datastore      = "data"
      ip             = "<nagios-ip>"
      vlan           = 85
      gateway        = "<vlan85-gateway>"
      data_disk      = "data:vm-999-Nagios-DATA"
      network_bridge = "vmbr0"
    }

    "SecMonDock-test" = {
      role           = "secmondock"
      node_name      = "Amy"
      vm_id          = 253
      cores          = 3
      sockets        = 3
      memory         = 72608
      disk           = 10        # small boot disk — data lives on the persistent disk
      datastore      = "data"
      ip             = "<secmondock-ip>"
      vlan           = 84
      gateway        = "<vlan84-gateway>"
      data_disk      = "data:vm-999-SecMonDock-DATA"
      network_bridge = "vmbr0"
    }

  }
}

module "ubuntu_vms" {
  source   = "../modules/ubuntu"
  for_each = local.ubuntu_vms

  name           = each.key
  vm_id          = each.value.vm_id
  node_name      = each.value.node_name
  template_vm_id = local.nodes[each.value.node_name].template_id
  template_node  = each.value.node_name
  cores          = each.value.cores
  sockets        = each.value.sockets
  memory         = each.value.memory
  disk           = each.value.disk
  datastore      = each.value.datastore
  ip             = each.value.ip
  gateway        = each.value.gateway
  vlan           = each.value.vlan
  tags           = [each.value.role]
  dns_servers    = local.dns_servers
}