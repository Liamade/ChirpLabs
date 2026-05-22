# terraform/modules/ubuntu

Reusable Terraform module for provisioning a single Ubuntu VM on Proxmox via the `bpg/proxmox` provider.

This module is the core building block of the ChirpLabs IaC pipeline. It clones a Packer-built template, configures static networking via cloud-init, and emits connection metadata consumed by Ansible downstream.

**Infrastructure is disposable — data is not.** Persistent data disks are pre-existing and managed separately in `persistent-disk.tf` — they survive a full `terraform destroy` + re-apply cycle untouched.

---

## Usage

This module is not called directly — it is driven by the `for_each` loop in `vms/vm-definitions.tf`:

```hcl
module "ubuntu_vms" {
  source   = "../modules/ubuntu"
  for_each = local.ubuntu_vms   # one module instance per VM defined in the locals map

  name           = each.key
  vm_id          = each.value.vm_id
  node_name      = each.value.node_name
  template_vm_id = local.nodes[each.value.node_name].template_id  # resolved from the nodes map
  template_node  = each.value.node_name
  ...
}
```

To add a new VM, edit the `vms` map in `vms/vm-definitions.tf` — you do not touch this module.

---

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | — | VM display name in Proxmox and hostname set via cloud-init. |
| `vm_id` | `string` | — | Proxmox VM ID. Must be unique across the entire cluster. |
| `node_name` | `string` | — | Proxmox node to create the VM on (e.g. `Amy`, `Farnsworth`). |
| `template_vm_id` | `string` | — | VM ID of the Packer-built Ubuntu template to clone from. Each node has its own local template; the correct ID is resolved from the `nodes` map in `vm-definitions.tf`. |
| `template_node` | `string` | — | Node where the template config lives. Matches `node_name` — Packer builds a template on each node separately. |
| `cores` | `number` | — | Number of vCPU cores. |
| `sockets` | `number` | `1` | Number of CPU sockets. |
| `memory` | `number` | — | RAM in MB. |
| `disk` | `number` | — | Boot disk size in GB. Keep this small — application data lives on the persistent disk. |
| `datastore` | `string` | — | Proxmox storage pool for the cloned boot disk (e.g. `data`). |
| `ip` | `string` | — | Static IPv4 address injected via cloud-init, without prefix (e.g. `172.27.85.4`). The module appends `/24`. |
| `gateway` | `string` | — | Default gateway for this VM's subnet. |
| `vlan` | `number` | — | VLAN tag applied to the VM's network interface. |
| `dns_servers` | `list(string)` | — | DNS server IPs injected via cloud-init. Shared across all VMs via `local.dns_servers`. |
| `tags` | `list(string)` | — | Proxmox tags applied to the VM. Populated from the VM's `role` field; used for Ansible inventory grouping. |
| `network_bridge` | `string` | `"vmbr0"` | Proxmox bridge to attach the NIC to. Override to `vlan81` for Farnsworth/OVS. |

---

## Outputs

Exposed back to the `vms/` root module. Collected into `vm_info.json`, uploaded to MinIO, and consumed by Ansible to build `hosts.ini` at runtime.

| Name | Description |
|---|---|
| `vm_id` | Proxmox VM ID. |
| `ip` | Static IP address assigned via cloud-init. |
| `name` | VM name. |
| `node` | Proxmox node the VM was created on. |

---

## Persistent disks

VMs that need a persistent data disk define a `data_disk` field in `vm-definitions.tf`:

```hcl
data_disk = "data:vm-999-Grafana-DATA"
```

This is **not** a module input. It is handled entirely by `persistent-disk.tf` in the `vms/` root module using a `null_resource` with `local-exec` curl calls to the Proxmox API:

- **On apply:** attaches the pre-existing disk to `scsi1` via a `PUT` to the Proxmox config endpoint.
- **On destroy:** unlinks the disk from the VM (moves it to `unusedX`) — does **not** delete it.

VMs without a `data_disk` key are ignored by this resource entirely.

> **Disk naming:** Proxmox requires the format `<pool>:vm-<VMID>-<label>-DATA`. Disk numbers inside the VM (`/dev/sda`, `/dev/sdb`) are not stable — Ansible detects the persistent disk by UUID via `blkid`.

---

## How it fits in the pipeline

```
Packer  ──►  builds Ubuntu template on each node (SSH key baked in, no cloud-init key injection)
                │
                ▼
Terraform  ──►  clones template per VM, injects static IP via cloud-init
            ──►  attaches pre-existing persistent disks via Proxmox API (null_resource)
            ──►  emits vm_info.json  ──►  MinIO
                │
                ▼
Ansible  ──►  reads vm_info.json from MinIO, builds hosts.ini
         ──►  provisions software, mounts persistent disk by UUID
```

---

## Notes

- **SSH keys are not injected here.** They are baked into the Packer template. Ansible connects as the `ubuntu` user using that key.
- **Each Proxmox node has its own template.** Packer builds separately on Amy (ID 299) and Farnsworth (ID 298). `template_node` always matches `node_name`.
- **`network_bridge` defaults to `vmbr0`** (standard Linux bridge on Amy). VMs on Farnsworth need `vmbr0` too currently, but this may need to change to `vlan81` depending on OVS config — set it explicitly per VM to be safe.
- **`vm_id` is typed as `string`** because Forgejo injects all pipeline variables as strings. `tonumber()` is used internally where Proxmox needs a number.
- **The Proxmox API token** used by `persistent-disk.tf` is read from `/tmp/proxmox_token` on the runner, written there by the pipeline before Terraform runs.