# terraform/

Infrastructure-as-code for the ChirpLabs VM fleet. All Proxmox VMs are defined, provisioned, and lifecycle-managed here using Terraform with the `bpg/proxmox` provider.

---

## Structure

```
terraform/
├── modules/
│   └── ubuntu/        # Reusable blueprint for a single Ubuntu VM
│       ├── main.tf
│       ├── variables.tf
│       └── ansible-outputs.tf
│
└── vms/               # Root module — defines the actual VM fleet
    ├── vm-definitions.tf   ← THIS IS WHERE YOU ADD/CHANGE VMs
    ├── persistent-disk.tf
    ├── backend.tf
    └── forgejo-vars.tf
```

**`modules/`** is organised by OS / appliance type — one subdirectory per distinct build target. Each module encapsulates everything specific to that platform: boot mechanism, cloud-init behaviour, NIC count, etc. This keeps the root module clean and means a new VM type never requires hacking an existing module to fit.

Currently there is one module:

| Module | Used for |
|---|---|
| `ubuntu/` | All standard Ubuntu VMs (Grafana, Nagios, Forgejo, etc.) — single NIC, cloud-init, qemu-guest-agent |

Appliances that don't fit the Ubuntu model get their own module rather than being forced into this one. For example, OPNsense (FreeBSD-based, no cloud-init, multiple NICs, configured via Packer rather than Ansible) would live in a future `modules/opnsense/`.

**`vms/`** is the root module. It's where the actual fleet is defined — each entry in the `vms` map in `vm-definitions.tf` becomes one VM on Proxmox. This is the only directory Terraform is ever run against directly.

See each directory's own README for full details.

---

## Core design principles

**Infrastructure is disposable — data is not.**
VM boot disks are created and destroyed freely by Terraform. Persistent data disks are pre-created manually, attached via the Proxmox API, and always survive a `terraform destroy`. Application data never touches Terraform state.

**One map entry = one VM.**
Adding a VM means adding one block to `local.ubuntu_vms` in `vm-definitions.tf`. The module, provider, state backend, and disk lifecycle are all handled automatically.

**State is remote and scoped.**
Terraform state lives in MinIO (`http://172.27.80.15:9000`), not on any local machine or runner. The `vms/` state file is intentionally isolated — future root modules (e.g. `opnsense/`) get their own state key so a destroy in one cannot affect another.

---

## Where this fits in the full pipeline

```
Packer   →  builds Ubuntu VM templates on each Proxmox node
    ↓
Terraform  →  clones templates, configures networking, attaches persistent disks
    ↓         outputs vm_info.json  →  MinIO
Ansible  →  reads vm_info.json, provisions software on each VM
```

The pipeline is orchestrated by Forgejo Actions. Terraform is never run manually in production — always via the workflow.

---

## Quick reference

| I want to...                        | Go to...                                  |
|-------------------------------------|-------------------------------------------|
| Add or change a VM                  | `vms/vm-definitions.tf`                   |
| Understand the VM resource itself   | `modules/ubuntu/`                         |
| Change provider or state config     | `vms/backend.tf`                          |
| Understand persistent disk handling | `vms/persistent-disk.tf`                  |
| Add a pipeline secret/variable      | `vms/forgejo-vars.tf` + Forgejo settings  |