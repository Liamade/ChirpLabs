# modules

> **Onboarding note:** This document is written as a reference guide for the next ChirpLabs cohort. It covers how Terraform modules work, how variables and outputs are structured, and how the `ubuntu` module is used by the VM fleet. If you already know Terraform, skip to [ubuntu/](ubuntu/) directly.

This directory contains reusable Terraform modules. A module is a self-contained unit that defines how to build a specific type of resource — in this case, a VM. Rather than writing the same VM configuration repeatedly for every machine, you define it once here and call it from `../vms/` with different inputs each time.

---

## Structure

```
modules/
├── README.md
└── ubuntu/                 ← the only module right now; defines how to provision an Ubuntu VM
    ├── variables.tf        ← what inputs the module accepts
    ├── main.tf             ← the actual resources being created
    └── ansible-outputs.tf  ← what values the module exposes back to its caller
```

The `../vms/` directory is the caller. It references this module, passes in the required variables, and collects the outputs to build `vm_info.json` for Ansible.

---

## How Modules Work

A module is just a folder of `.tf` files. Terraform treats it as a black box — you pass inputs in via `variables.tf`, it creates resources defined in `main.tf`, and it hands values back out via outputs. The caller never needs to know the internals.

```
vms/main.tf                     modules/ubuntu/
┌─────────────────┐             ┌──────────────────────┐
│ module "web" {  │  variables  │ variables.tf         │
│   source = ...  │ ──────────► │ (ip, name, node etc) │
│   ip     = ...  │             ├──────────────────────┤
│   name   = ...  │             │ main.tf              │
│ }               │             │ (proxmox VM resource)│
│                 │  outputs    ├──────────────────────┤
│ module.web.ip   │ ◄────────── │ ansible-outputs.tf   │
└─────────────────┘             │ (vm_id, ip, name...) │
                                └──────────────────────┘
```

---

## `variables.tf` — Module Inputs

This file declares every input the module accepts. Think of these as the function parameters — the caller must supply values for anything without a `default`.

### Basic Structure

```hcl
variable "name" {
  description = "A clear explanation of what this variable is for."
  type        = string         # string, number, bool, list, map, object
}

variable "memory" {
  description = "RAM allocated to the VM in megabytes."
  type        = number
  default     = 2048           # optional — makes the variable optional for the caller
}
```

### Common Types

```hcl
# Simple values
variable "vm_name"   { type = string }
variable "vm_cores"  { type = number }
variable "vm_start"  { type = bool   }

# A list of strings
variable "dns_servers" {
  type    = list(string)
  default = ["1.1.1.1", "8.8.8.8"]
}

# A map of key/value pairs
variable "tags" {
  type    = map(string)
  default = {}
}
```

### Inside the Module

Variables are referenced with `var.<name>` anywhere in the module's `.tf` files:

```hcl
# in main.tf
resource "proxmox_virtual_environment_vm" "this" {
  name    = var.name        # pulled from variables.tf
  node_name = var.node_name
  vm_id   = var.vm_id
}
```

---

## `main.tf` — The Resources

This is where the actual infrastructure gets defined. For the `ubuntu` module this is the Proxmox VM resource — disk size, CPU, memory, cloud-init config, network, etc.

### Basic Resource Structure

```hcl
resource "provider_resourcetype" "label" {
  # resource-specific arguments
}
```

The label (e.g. `"this"`) is just an internal name used to reference the resource elsewhere in the same module. By convention, `"this"` is used when there's only one resource of that type in the module.

```hcl
resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name
  vm_id     = var.vm_id

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory
  }

  # Nested blocks group related settings
  network_device {
    bridge  = var.network_bridge
    vlan_id = var.vlan_id
  }
}
```

### Referencing Other Resources

Within the same module, you reference a resource's attributes with `resourcetype.label.attribute`:

```hcl
output "vm_id" {
  value = proxmox_virtual_environment_vm.this.vm_id   # reading back the assigned VM ID
}
```

---

## `ansible-outputs.tf` — Module Outputs

This file defines what values the module hands back to its caller (`vms/main.tf`). The caller uses these to build `vm_info.json`, which Ansible reads to generate its inventory.

### Basic Structure

```hcl
output "name" {
  description = "A clear explanation of what this value is."
  value       = var.name                                      # can reference variables or resource attributes
}

output "vm_id" {
  description = "The Proxmox VM ID assigned to this VM."
  value       = proxmox_virtual_environment_vm.this.vm_id    # reading from the resource
}
```

### Current Outputs

The `ubuntu` module exposes four values back to `vms/`:

```hcl
output "vm_id"  { value = proxmox_virtual_environment_vm.this.vm_id }
output "ip"     { value = var.ip }
output "name"   { value = var.name }
output "node"   { value = var.node_name }
```

`vms/` collects these across every module call and writes them into `vm_info.json` for Ansible to consume.

---

## How `vms/` Calls This Module

The caller in `vms/main.tf` references the module with a `source` path and passes values for every required variable:

```hcl
module "grafana" {
  source = "../modules/ubuntu"    # path to the module directory

  # These map to variables.tf in the module
  name        = "grafana-01"
  node_name   = "amy"
  vm_id       = 201
  ip          = "172.27.80.51"
  cpu_cores   = 2
  memory      = 2048
}

module "nagios" {
  source = "../modules/ubuntu"    # same module, different inputs

  name        = "nagios-01"
  node_name   = "amy"
  vm_id       = 202
  ip          = "172.27.80.52"
  cpu_cores   = 2
  memory      = 2048
}
```

The caller reads outputs back with `module.<label>.<output_name>`:

```hcl
# in vms/outputs.tf
output "grafana_ip" {
  value = module.grafana.ip       # reads the ip output from the grafana module call
}
```

---

## Adding a New Module

Only add a new module if the VM type is genuinely different — different OS, different provisioning method, different resource structure. If it's just another Ubuntu VM with different specs, add another `module` block in `vms/main.tf` pointing at the existing `ubuntu` module.

If you do need a new module (e.g. OPNsense):

1. Create the directory:

```
modules/
└── opnsense/
    ├── variables.tf
    ├── main.tf
    └── ansible-outputs.tf
```

2. Define inputs in `variables.tf` — anything the resource needs that will differ between VMs.

3. Write the resource in `main.tf`.

4. Expose the values Ansible needs in `ansible-outputs.tf` — at minimum `vm_id`, `ip`, `name`, and `node` to stay consistent with the ubuntu module.

5. Call it from `vms/main.tf` the same way as the ubuntu module.