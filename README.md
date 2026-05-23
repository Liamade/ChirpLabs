# ChirpLabs Infrastructure

> **Infrastructure is disposable. Data is not.**

ChirpLabs is a student hosting service at Ball State University. This repository is the complete infrastructure-as-code stack for the environment — everything needed to go from bare Proxmox nodes to a fully running security lab, from scratch, with one pipeline trigger.

---

## What's Deployed

The lab runs a full defensive security stack, all containerized on a dedicated VM:

| Service | Purpose |
|---------|---------|
| [Wazuh](https://wazuh.com/) | SIEM — endpoint detection and log analysis |
| [Graylog](https://graylog.org/) | Log aggregation and search |
| [MISP](https://www.misp-project.org/) | Threat intelligence sharing |
| [Shuffle](https://shuffler.io/) | Security automation (SOAR) |
| [Prometheus](https://prometheus.io/) + [Grafana](https://grafana.com/) | Infrastructure metrics and dashboards |
| [Nagios](https://www.nagios.org/) | Network host and service alerting |

---

## The Pipeline

Three tools, three stages — each independently triggerable or chained end-to-end:

```
Packer  ──►  Terraform  ──►  Ansible
(build template)  (provision VMs)  (configure services)
```

1. **Packer** builds a hardened Ubuntu base template on Proxmox from a live server ISO. Docker, qemu-guest-agent, and the Ansible SSH key are pre-baked so every cloned VM is immediately ready for configuration.
2. **Terraform** clones that template into running VMs, configures networking, and attaches pre-existing persistent data disks via the Proxmox API.
3. **Ansible** connects over SSH and finishes the job — installs services, mounts disks, templates config files, and brings up all containers in the correct startup order.

CI/CD is handled by self-hosted Forgejo Actions. Terraform state lives in MinIO on TrueNAS. Secrets are injected at pipeline runtime via Forgejo secrets — nothing sensitive lives in this repo.

---

## Persistent Data

VMs are designed to be freely destroyed and rebuilt. The data they hold is not. Each stateful service has a dedicated data disk that exists entirely outside of Terraform state — Terraform attaches it, not creates it, and explicitly unlinks it before any destroy operation.

| VM | Data Disk | Mount Point |
|----|-----------|-------------|
| Grafana | `vm-999-Grafana-DATA` | `/var/lib/grafana` |
| Nagios | `vm-999-Nagios-DATA` | `/usr/local/nagios/` |
| SecMonDock | `vm-999-SecMonDock-DATA` | `/mnt/data` |

A full `terraform destroy` detaches every data disk before the VMs are deleted. A full rebuild reattaches them. The data never moves.

---

## Repository Layout

```
.forgejo/workflows/     # CI/CD pipeline (Packer, Terraform, Ansible, deploy-all)
ansible/                # Roles and playbooks for VM configuration
packer/                 # Base image build template and cloud-init config
terraform/
  modules/ubuntu/       # Reusable VM blueprint for the bpg/proxmox provider
  vms/                  # VM fleet definitions, remote state, and disk lifecycle
```

Each directory has its own README with full details.

---

## Infrastructure

| Component | Detail |
|-----------|--------|
| Hypervisor | Proxmox cluster (3 nodes) |
| IaC Provider | `bpg/proxmox` |
| State Backend | MinIO (S3-compatible, self-hosted on TrueNAS) |
| VCS / CI | Self-hosted Forgejo + Forgejo Actions runner |
| Base OS | Ubuntu 24.04 LTS |

---

## Running the Pipeline

Trigger end-to-end from the Forgejo Actions UI via `deploy-all.yml`, or run any stage on its own:

```
deploy-all.yml
  └─ packer.yml          # Build base template (skips if template already exists)
  └─ [60s wait]          # Let cloud-init finish on fresh VMs
  └─ terraform.yml       # Provision the VM fleet
  └─ ansible.yml         # Configure all services
```

Each workflow accepts inputs (`force_rebuild_packer`, `destroy_first`, `destroy_all`) for targeted operations without running the full chain.

---

## Key Design Decisions

- **VMs are cattle, not pets.** If a service can't be reprovisioned from this repo, it doesn't belong here.
- **Secrets never touch the repo.** All credentials live in Forgejo secrets and are injected at runtime.
- **State is isolated.** Each Terraform root module gets its own state key in MinIO — a destroy in one can't affect another.
- **Data survives everything.** Persistent disks are managed outside Terraform state intentionally, so no Terraform bug or `terraform destroy` can touch application data.