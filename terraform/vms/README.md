# terraform/vms

Root Terraform module for the ChirpLabs VM fleet. This is where all VMs are defined and where the pipeline is wired together — provider config, remote state, module calls, and persistent disk lifecycle all live here.

To add or change a VM, **only `vm-definitions.tf` needs to change.**

---

## Directory structure

| File | Purpose |
|---|---|
| `vm-definitions.tf` | **The day-to-day edit target.** Defines the `vms` map — one entry per VM. Add, remove, or resize VMs here. |
| `persistent-disk.tf` | Attach/detach pre-existing persistent data disks via the Proxmox API. Driven automatically by `data_disk` entries in the `vms` map. |
| `backend.tf` | Provider config (`bpg/proxmox`) and MinIO S3 remote state backend. Rarely needs changing. |
| `forgejo-vars.tf` | Declares variables injected by Forgejo at runtime via `TF_VAR_` env vars. Rarely needs changing. |

---

## Adding a VM

Add an entry to the `vms` map in `vm-definitions.tf`:

```hcl
"my-new-vm" = {
  role      = "webserver"        # Ansible inventory group
  node_name = "Amy"              # Proxmox node: "Amy" or "Farnsworth"
  vm_id     = 260                # Unique cluster-wide VM ID
  cores     = 2
  sockets   = 1
  memory    = 4096               # MB
  disk      = 8                  # GB — keep small, data goes on the persistent disk
  datastore = "data"             # Proxmox storage pool for the boot disk
  ip        = "172.27.85.10"
  vlan      = 85
  gateway   = "172.27.85.1"
  network_bridge = "vmbr0"

  # Optional — omit entirely if this VM doesn't need a persistent disk
  data_disk = "data:vm-260-MyNewVM-DATA"
}
```

The `template_vm_id` is resolved automatically from the `nodes` map using `node_name` — you don't set it per VM.

---

## Persistent disks

VMs with a `data_disk` field get a pre-existing disk attached to `scsi1` automatically by `persistent-disk.tf`. The disk must already exist on the Proxmox host before `terraform apply` — Terraform does not create it.

**Lifecycle:**
- `apply` → attaches the disk to the VM via a `PUT` to the Proxmox config API
- `destroy` → unlinks the disk (moves to `unusedX`) — **does not delete it**

**Before running `terraform destroy`**, verify the unlink provisioner will fire correctly. If a destroy has to be forced, manually detach the disk first:
```bash
qm set <VMID> --delete scsi1
```

**Disk naming convention** (required by Proxmox):
```
<storage_pool>:vm-<VMID>-<Label>-DATA
# e.g. data:vm-999-Grafana-DATA
```

> The disk name in Proxmox must follow the `vm-<VMID>-disk-N` or `vm-<VMID>-<Label>` convention for the storage pool reference to be accepted by `qm`.

---

## Remote state

State is stored in MinIO (configured in `backend.tf`), bucket `terraformstate-test`, key `vms/terraform.tfstate`.

This state file is scoped to this root module only. Other root modules (e.g. a future `opnsense/`) use a separate key so a destroy in one cannot affect resources in another.

> MinIO is currently running without TLS (`insecure = true` in `backend.tf`). This is an on-prem environment — TLS is on the roadmap.

---

## Runtime variables

These are injected by the Forgejo Actions pipeline at runtime and must be set as Forgejo secrets/variables before the workflow runs:

| Forgejo secret/variable | `TF_VAR_` name | Description |
|---|---|---|
| `PROXMOX_API_TOKEN` (secret) | `proxmox_api_token` | Full API token string: `forgejo@pam!forgejo=<uuid>` |

The `persistent-disk.tf` provisioners also read the token from `/tmp/proxmox_token` on the runner — the pipeline writes this file before Terraform runs.

---

## How this fits in the pipeline

```
Forgejo Actions
    │
    ├─ Packer workflow     →  builds Ubuntu template on Amy + Farnsworth
    │
    ├─ Terraform workflow  →  runs in this directory
    │       │
    │       ├─ terraform init   (pulls state from MinIO)
    │       ├─ terraform apply
    │       │       ├─ modules/ubuntu  (one instance per VM in local.ubuntu_vms)
    │       │       └─ null_resource   (attaches persistent disks)
    │       └─ outputs vm_info.json    →  uploaded to MinIO
    │
    └─ Ansible workflow    →  reads vm_info.json from MinIO, provisions VMs
```

The 60-second wait job between Terraform and Ansible gives cloud-init time to complete before Ansible tries to connect.