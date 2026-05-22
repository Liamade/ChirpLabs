# ChirpLabs CI/CD Workflows

This directory contains the Forgejo Actions workflows that implement ChirpLabs' Infrastructure-as-Code pipeline. The pipeline automates the full lifecycle of VM provisioning: building golden images, cloning them into running VMs, and configuring those VMs with Ansible.

**Core philosophy: infrastructure is disposable, data is not.** VMs can be torn down and rebuilt entirely from code. Persistent data lives on separately managed disks that survive destroy-rebuild cycles.

---

## Workflow Overview

```
deploy-all.yml          ← master orchestrator (manual trigger)
   │
   ├── packer.yml       ← builds golden VM templates on Amy & Farnsworth
   ├── terraform.yml    ← clones templates into running VMs, exports inventory
   └── ansible.yml      ← configures VMs using inventory from MinIO
```

Each workflow can also be triggered **independently** — they don't have to run together. Push a change to `ansible/` and only Ansible runs; push to `packer/` and only Packer runs.

---

## Workflows

### `deploy-all.yml` — Master Orchestrator

Chains all three stages in order. If any stage fails, subsequent stages are skipped.

**Trigger:** Manual only (`workflow_dispatch`). This is an intentional gate — a full rebuild is a destructive operation.

**Inputs:**

| Input | Description | Default |
|---|---|---|
| `force_rebuild_packer` | Rebuild Packer templates even if they already exist | `false` |
| `destroy_first` | Destroy existing VMs before recreating (full Terraform reset) | `false` |
| `destroy_all` | Destroy everything and do **not** recreate (tear-down only) | `false` |

There is a 60-second wait job between Terraform and Ansible to allow cloud-init to complete before Ansible tries to connect.

---

### `packer.yml` — Build Golden Image

Builds an Ubuntu VM template on each Proxmox node using Packer. The template is the base image that Terraform clones for every VM.

**Triggers:**
- Push to `main` with changes in `packer/`
- Called by `deploy-all.yml`
- Manual (`workflow_dispatch`)

**How it works:**

Builds run **sequentially** (`max-parallel: 1`) against a matrix of both nodes — Amy first, then Farnsworth. Each node gets its own independent template on its local storage so Terraform can clone locally without cross-node transfer.

Before running Packer, a `sed` step injects runtime values (build VM IP, gateway, SSH public keys) into `packer/http/user-data`, since that file is uploaded as a static cidata ISO and isn't processed by Packer itself.

The workflow checks whether the template already exists on each node before building. If it does and `force_rebuild` is false, the build step is skipped for that node.

**Node configuration (hardcoded in matrix):**

| | Amy | Farnsworth |
|---|---|---|
| Host | `<node-1-ip>:8006` | `<node-2-ip>:8006` |
| Template VM ID | `299` | `298` |
| Disk storage | `data` | `data` |
| Bridge | `vmbr0` | `vlan81` |

**SSH keypair separation:**

Two distinct keypairs are used to limit key exposure:

- `packer_ed25519` — injected into the build VM during the Packer run so Packer can SSH in and run provisioners. Removed from the template in the cleanup step. Never reaches production.
- `ansible_ed25519` — baked into the template so the runner can SSH into every deployed VM for Ansible. This key persists into production.

**Required secrets:**

| Secret | Description |
|---|---|
| `PROXMOX_TOKEN_ID` | Proxmox API token ID (e.g. `forgejo@pam!forgejo`) |
| `PROXMOX_TOKEN_SECRET` | Proxmox API token secret UUID |
| `PACKER_SSH_PRIVATE_KEY` | Private half of `packer_ed25519` |

**Required variables:**

| Variable | Description |
|---|---|
| `PACKER_VM_IP_AMY` | Static IP for Amy's temporary build VM |
| `PACKER_VM_IP_FARNSWORTH` | Static IP for Farnsworth's temporary build VM |
| `PACKER_GATEWAY` | Gateway for the temporary build VM |
| `PACKER_SSH_PUBLIC_KEY` | Public half of `packer_ed25519` |
| `ANSIBLE_SSH_PUBLIC_KEY` | Public half of `ansible_ed25519` |
| `TEMPLATE_STORAGE_POOL` | NFS pool name where the Ubuntu ISO lives |
| `PACKER_ISO_FILE` | Full ISO path (e.g. `ChirpNAS_ISO_Templates:iso/ubuntu-24.04.4-live-server-amd64.iso`) |
| `PACKER_ISO_CHECKSUM` | ISO checksum (e.g. `sha256:abc123...`) |
| `PACKER_VLAN_ID` | VLAN tag for the build VM NIC |

---

### `terraform.yml` — Provision VMs

Clones the golden templates into running VMs, then uploads a `vm_info.json` inventory to MinIO for Ansible to consume.

**Triggers:**
- Push to `main` with changes in `terraform/vms/` or `terraform/modules/`
- Called by `deploy-all.yml`
- Manual (`workflow_dispatch`)

**Inputs:**

| Input | Description | Default |
|---|---|---|
| `destroy_first` | Destroy existing VMs before applying (full reset) | `false` |
| `destroy_all` | Destroy everything and skip apply | `false` |

**How it works:**

Runs the standard `init → validate → plan → apply` sequence. After a successful apply, `terraform output -json vm_ips` is written to `vm_info.json` and uploaded to MinIO. This file is the handoff point between Terraform and Ansible — it contains each VM's IP and role, and is never committed to the repo.

If the job fails, a `force-unlock` step attempts to release any stuck Terraform state lock automatically.

**Required secrets:**

| Secret | Description |
|---|---|
| `PROXMOX_API_TOKEN` | Combined Proxmox token string (`tokenid=secret`) |
| `MINIO_ACCESS_KEY` | MinIO access key |
| `MINIO_SECRET_KEY` | MinIO secret key |

**Required variables:**

| Variable | Description |
|---|---|
| `PROXMOX_URL` | Proxmox API endpoint (e.g. `https://<proxmox-host>:8006/`) |
| `MINIO_ENDPOINT` | MinIO endpoint (e.g. `http://<minio-host>:9000`) |
| `MINIO_BUCKET` | MinIO bucket name |

---

### `ansible.yml` — Configure VMs

Runs Ansible playbooks against all provisioned VMs. Reads `vm_info.json` from MinIO to generate a dynamic `hosts.ini` at runtime — the inventory is never committed to the repo.

**Triggers:**
- Push to `main` with changes in `ansible/`
- Called by `deploy-all.yml`
- Manual (`workflow_dispatch`)

**How it works:**

After fetching `vm_info.json`, a Python snippet groups VMs by their `role` field and writes `ansible/hosts.ini`. SSH host key checking is disabled (`UserKnownHostsFile=/dev/null`) to prevent stale `known_hosts` entries from blocking connections after a VM is rebuilt.

Playbooks run in sequence:

1. `common.yml` — runs against all VMs; installs base packages, creates the `ctadmin` user, and starts qemu-guest-agent
2. `monitoring.yml` — configures Grafana and Nagios
3. `secmondock.yml` — configures the SecMonDock VM (Wazuh, Graylog, Shuffle)

Sensitive credentials (passwords, API keys) are passed as `-e` extra vars from Forgejo secrets and never touch the repo.

**Required secrets:**

| Secret | Description |
|---|---|
| `ANSIBLE_SSH_PRIVATE_KEY` | Private half of `ansible_ed25519` |
| `MINIO_ACCESS_KEY` | MinIO access key |
| `MINIO_SECRET_KEY` | MinIO secret key |
| `CTADMIN_USER_PASSWORD` | Password for the `ctadmin` user |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password |
| `WAZUH_API_PASSWORD` | Wazuh API password |
| `WAZUH_INDEXER_PASSWORD` | Wazuh indexer password |
| `WAZUH_DASHBOARD_PASSWORD` | Wazuh dashboard password |
| `GRAYLOG_PASSWORD_SECRET` | Graylog password secret |
| `GRAYLOG_ROOT_PASSWORD_SHA2` | Graylog root password (SHA-256) |
| `SHUFFLE_OPENSEARCH_PASSWORD` | Shuffle OpenSearch password |

**Required variables:**

| Variable | Description |
|---|---|
| `MINIO_ENDPOINT` | MinIO endpoint |
| `MINIO_BUCKET` | MinIO bucket name |

---

## Infrastructure Reference

| Component | Details |
|---|---|
| Proxmox nodes | Amy, Farnsworth (configure IPs in workflow matrix) |
| MinIO (S3 backend) | Self-hosted on TrueNAS (configure endpoint in `backend.tf`) |
| Forgejo | Self-hosted (configure URL in repo settings) |
| Runner | Dockerized `gitea/act_runner:latest` (Alpine), tagged `chirplabs` |
| Terraform provider | `bpg/proxmox` ~> 0.73 |
| State backend | MinIO S3-compatible (`use_path_style = true`) |