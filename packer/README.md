# Packer — Ubuntu Template

This directory contains everything needed to build the base Ubuntu VM template that Terraform clones when provisioning new servers.

The output is a Proxmox VM template — a frozen, generalized disk image with Docker, qemu-guest-agent, and the Ansible SSH key pre-baked in. Terraform clones it; Ansible configures it the rest of the way.

---

## Directory Structure

```
packer/
├── ubuntu.pkr.hcl      # Main Packer config — hardware, boot, provisioners
└── http/
    ├── user-data       # Ubuntu autoinstall config (cloud-init)
    └── meta-data       # Required companion file for cloud-init
```

---

## How It Works

Packer boots a temporary VM from the Ubuntu live server ISO and drives a fully automated OS install. The sequence is:

```
Packer starts VM
    └── Boots Ubuntu ISO
        └── Reads http/user-data + http/meta-data via cidata CD-ROM
            └── Ubuntu autoinstall runs (partitioning, user, SSH key)
                └── Packer SSH connects
                    └── Provisioners run (DNS, Docker, Ansible key, cleanup)
                        └── VM is converted to a Proxmox template
```

The cidata CD-ROM (generated from `http/`) is how autoinstall receives its configuration without a network-reachable HTTP server. After the build, the workflow removes the cidata drive from the template so cloned VMs don't see it.

---

## The `http/` Directory

### `user-data`

The Ubuntu autoinstall configuration. This file drives the entire OS installation before Packer's SSH provisioners ever connect.

**Important:** This file contains `__PLACEHOLDER__` tokens that are substituted by the workflow's *"Inject variables into user-data"* step before Packer runs. The file committed to the repo should never contain real IPs or keys.

| Placeholder | Source | Purpose |
|---|---|---|
| `__BUILD_VM_IP__` | Forgejo variable `PACKER_VM_IP` | Static IP for the build VM so Packer can SSH to it |
| `__GATEWAY__` | Forgejo variable `PACKER_GATEWAY` | Default route for the build VM |
| `__PACKER_SSH_PUBLIC_KEY__` | Forgejo variable `PACKER_SSH_PUBLIC_KEY` | Temporary build key so Packer can SSH in — **removed by Step 6 before templating** |

> **Key rotation:** If you regenerate `packer_rsa`, update `PACKER_SSH_PUBLIC_KEY` in Forgejo variables. The comment `packer-build` at the end of the key line must be preserved — the cleanup provisioner uses it to find and remove the entry via `sed`.

### `meta-data`

A required companion file for cloud-init. Cloud-init expects both files to exist — if `meta-data` is missing, the Ubuntu installer will hang waiting for it. For local Packer builds it only needs a valid `instance-id`; it carries no meaningful configuration.

---

## Variables

All variables are injected at build time via `PKR_VAR_` environment variables set by the Forgejo Actions workflow. Nothing is hardcoded.

| Variable | Source | Notes |
|---|---|---|
| `proxmox_url` | Workflow matrix | `https://<node-ip>:8006/api2/json` |
| `proxmox_node` | Workflow matrix | `amy` or `farnsworth` |
| `proxmox_token_id` | Forgejo secret | API token ID |
| `proxmox_token_secret` | Forgejo secret | API token secret |
| `vm_id` | Workflow matrix | `299` (Amy) or `300` (Farnsworth) |
| `build_vm_ip` | Forgejo variable | Must match the IP injected into `user-data` |
| `ansible_ssh_public_key` | Forgejo variable | Baked into template; used by every cloned VM |
| `iso_file` | Forgejo variable | `<pool>:iso/<filename>` |
| `iso_checksum` | Forgejo variable | `sha256:<hash>` — see [Ubuntu releases](https://releases.ubuntu.com/24.04/SHA256SUMS) |
| `iso_storage_pool` | Forgejo variable | NFS pool where the ISO lives |
| `disk_storage_pool` | Workflow matrix | Local storage on the target node |
| `disk_format` | Workflow matrix | `raw` for LVM-thin, `qcow2` for directory-based storage |
| `build_bridge` | Workflow matrix | `vmbr0` (Amy) or node-specific bridge |
| `build_vlan_tag` | Workflow matrix | VLAN tag number, or empty string for OVS bridges |

---

## Build Steps

The build block runs six provisioner steps in order after autoinstall completes:

1. **Bootstrap DNS and base packages** — Writes DNS resolvers to `/etc/resolv.conf`, then installs `curl`, `git`, and `qemu-guest-agent`. The DNS step runs first because the build VM's network may not have DNS configured yet from autoinstall alone.

2. **Install Docker** — Adds the official Docker apt repository and installs the Docker Engine + Compose plugin. Docker is masked during install to prevent it from starting mid-provisioner, then unmasked and enabled for future boots.

3. **Bake the Ansible SSH key** — Appends the Ansible runner's public key to `authorized_keys`. This key persists into every cloned VM so Ansible can connect without any per-VM key setup. Passed via environment variable rather than direct interpolation to avoid shell escaping issues.

4. **Install Prometheus node exporter** — Installs `prometheus-node-exporter` via apt and enables it. Same mask/unmask pattern as Docker.

5. **Disable unattended-upgrades** — Removes Ubuntu's automatic background updater. Without this, a fresh VM's first boot can trigger an apt lock at the same time Ansible tries to install packages, causing Ansible to fail. Ansible owns all package management post-boot.

6. **Cleanup for templating** — Removes the Packer build key (injected by `user-data` for this build only, must not persist to production), runs `cloud-init clean` so clones start fresh, and truncates `/etc/machine-id` so each cloned VM generates its own unique ID on first boot.

---

## Storage Layout

Two storage pools are used, intentionally kept separate:

- **`iso_storage_pool` (NFS/shared)** — Where the Ubuntu ISO lives. Read at build time only; nothing is written here by Packer.
- **`disk_storage_pool` (local, per-node)** — Where the template's boot disk and cloud-init drive are stored. Local storage is used for high I/O and to avoid cross-node NFS dependency during VM cloning.

Each node (Amy and Farnsworth) gets its own independent template on its own local storage. Terraform clones locally on each node — no cross-node disk transfers during provisioning.

---

## Per-Node Differences

The workflow runs the Packer build as a matrix — once targeting Amy, once targeting Farnsworth. The variables that differ per node are:

| | Amy | Farnsworth |
|---|---|---|
| `vm_id` | `299` | `300` |
| `proxmox_node` | `amy` | `farnsworth` |
| `disk_storage_pool` | `data` | `data` |
| `build_bridge` | `vmbr0` | `vlan81` |
| `build_vlan_tag` | *(empty)* | *(empty — OVS handles VLAN)* |

Both templates are built sequentially. The same `build_vm_ip` is reused across both builds since they don't run concurrently.

---

## Triggering a Rebuild

The Packer workflow is triggered manually (or as the first stage of `deploy-all.yml`). A rebuild is needed when:

- The Ubuntu ISO version changes
- A new package needs to be pre-baked into every VM (e.g., a new monitoring agent)
- The Ansible SSH key is rotated
- Any `user-data` or `ubuntu.pkr.hcl` change is made

Rebuilding is safe — Terraform will clone the new template on the next `deploy-all` run. Existing running VMs are unaffected until they are destroyed and rebuilt.