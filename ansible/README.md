# ChirpLabs / Ansible

> **Onboarding note:** This document is written for the next ChirpLabs cohort. It explains what Ansible is, how it fits into the ChirpLabs pipeline, and how the directory structure is organized — written assuming no prior Ansible experience.

## What Is Ansible?

Ansible is a configuration management tool. Its job is to take a freshly created virtual machine — one that has an operating system but nothing else — and turn it into a fully configured, running service.

In the ChirpLabs pipeline, Ansible is the **third and final stage**:

```
Packer → Terraform → Ansible
```

- **Packer** builds a reusable VM template (Ubuntu with some base configuration baked in)
- **Terraform** uses that template to create and provision the actual VMs
- **Ansible** connects to those VMs and configures them — installing software, setting up users, mounting disks, starting services, and injecting secrets

The key thing to understand about Ansible is that it is **agentless**. It does not require any special software running on the machines it manages. It connects over plain SSH, does its work, and disconnects. The target machines don't need to know Ansible exists — they just need to be reachable over SSH.

Everything Ansible does is defined as code in this directory. That means any VM can be completely wiped and rebuilt to an identical state just by running Ansible again. This is the foundation of the "infrastructure is disposable" philosophy that ChirpLabs is built around.

---

## How It Fits Into the Pipeline

When Terraform finishes creating a VM, that VM boots up and runs **cloud-init** — a lightweight first-boot configuration tool that does things like set the hostname and install the SSH key. The pipeline waits 60 seconds for this to complete, then hands off to Ansible.

Ansible reads an **inventory** to know which machines exist and how to reach them, then runs a **playbook** against those machines, which applies a set of **roles** that do the actual configuration work.

---

## Directory Structure

```
ansible/
├── group_vars/       # Shared variables used across all hosts
├── inventory/        # Defines what machines Ansible knows about
├── playbooks/        # Entry points — one per VM or service
├── roles/            # Modular configuration units (the real work happens here)
├── ansible.cfg       # Global settings for how Ansible behaves
├── requirements.yml  # External roles to download from Ansible Galaxy
└── download/         # Where downloaded external roles are saved at runtime
```

---

## group_vars/

Variables that are shared across all hosts live here. Instead of hardcoding values like usernames, file paths, or software versions directly inside tasks, you define them here and reference them by name. This makes it easy to change a value in one place rather than hunting through dozens of files.

`all.yml` is the main file — it applies to every host in the inventory.

> **Note:** Sensitive values like passwords, API keys, and tokens are **not** stored here. They are injected at runtime from Forgejo secrets so they never get committed to the repository.

---

## inventory/

The inventory tells Ansible what machines exist and how to connect to them. It contains information like IP addresses, SSH usernames, and how machines are grouped together (e.g. "all monitoring VMs").

In ChirpLabs, the inventory file (`hosts.ini`) is **generated automatically** at pipeline runtime from the output of Terraform, which is stored in MinIO. This means the inventory always reflects what Terraform actually deployed — you never have to update it manually when an IP address changes.

Because `hosts.ini` is generated automatically, it is gitignored and never committed to the repo. Only the script that generates it lives here.

---

## playbooks/

Playbooks are the entry point — they're what you actually run when you want to configure a machine. Each playbook targets one or more hosts from the inventory and lists which roles should be applied to them, and in what order.

For example, a `grafana.yml` playbook might say:

> "On the host called `grafana`, apply the `common` role, then apply the `grafana` role."

Playbooks are intentionally thin and don't contain much logic themselves. Their job is just to connect hosts to roles. One playbook per VM keeps things clean and makes it easy to reprovision a single machine without touching anything else.

---

## roles/

Roles are where the actual configuration work happens. A role is a self-contained, reusable unit that handles one specific concern. For example:

- The `common` role runs on every VM — it installs base packages and creates the shared `ctadmin` admin user
- The `grafana` role handles everything specific to Grafana — mounting the persistent data disk, restoring configs, and starting the service
- The `nagios` role installs build dependencies, compiles Nagios from source, creates system users, configures Apache, and installs the Prometheus exporter

Breaking things into roles instead of writing one big script keeps configuration modular. Roles can be reused across multiple playbooks, and you can reprovision a single service without touching others.

A typical role looks like this:

```
roles/
└── my-role/
    ├── tasks/        # The steps Ansible actually executes, in order
    ├── templates/    # Config files with placeholders filled in at runtime (Jinja2 format)
    ├── handlers/     # Actions that run when something changes (e.g. "restart nginx")
    └── defaults/     # Default variable values specific to this role
```

The `tasks/` directory is the most important — it's the list of things Ansible will do on the target machine. Templates let you write config files that have variables in them (like `{{ admin_password }}`), which Ansible fills in before copying them to the VM.

---

## ansible.cfg

The global configuration file for Ansible itself. It controls how Ansible behaves when you run it, so you don't have to pass a bunch of flags on the command line every time. Common settings include:

- Where to find the inventory file
- What SSH user to connect as
- Whether to check SSH host keys (disabled in ChirpLabs because VMs are frequently destroyed and rebuilt — their SSH fingerprints change each time, which would otherwise cause Ansible to refuse to connect)
- Where role directories are located

---

## requirements.yml

A list of external roles to pull from **Ansible Galaxy** — Ansible's public community registry, similar to npm or PyPI. If a well-maintained community role already exists for a task, it can be declared here instead of written from scratch.

Before running playbooks, external roles are installed with:

```bash
ansible-galaxy install -r requirements.yml
```

---

## download/

The directory where roles installed from `requirements.yml` are saved. This is generated content — it gets populated at pipeline runtime and is not committed to the repo. Think of it like a `node_modules/` folder.

---

## Persistent Disks

One important pattern to understand in ChirpLabs is how persistent data is handled. VMs are designed to be completely disposable — they can be destroyed and recreated from scratch at any time. But the **data** those VMs hold (database files, application state, config backups) must survive across rebuilds.

To handle this, persistent data lives on **separate disks** that exist outside of Terraform's control. These disks are created manually in Proxmox and attached to VMs. Ansible mounts them directly at the application's data directory (e.g. `/var/lib/grafana` or `/usr/local/nagios/`) so the application sees its data right where it expects it.

Ansible identifies these disks by their **UUID** rather than their device name (`/dev/sda`, `/dev/sdb`, etc.), because device names can change depending on boot order and disk attachment sequence. UUIDs are stable.

---

## Languages & Formats

If you open files in this directory and aren't sure what you're looking at, here's a quick reference:

**YAML** (`.yml`) — Used almost everywhere in Ansible: playbooks, role tasks, group_vars, handlers, and requirements. YAML is a human-readable data format that uses indentation to show structure. A two-space indent means "this belongs to the thing above it." If something isn't working and the error mentions a parse error, misaligned indentation is usually the culprit — YAML is strict about it.

**Jinja2** (`.j2`) — The templating language used inside template files. You'll recognize it by double curly braces like `{{ variable_name }}` and block tags like `{% if condition %}`. Ansible fills in the real values before copying the file to the target machine. So a template for a config file might have `password = {{ db_password }}` which becomes `password = hunter2` at runtime.

**INI format** (`.ini`) — What the generated inventory file (`hosts.ini`) looks like. It's a simple format using square brackets for group names and plain text for hostnames or IPs underneath them. It looks very different from YAML, which can be jarring if you're expecting consistency.

**Bash** — Some Ansible tasks run shell commands directly on the target machine using Ansible's `shell` or `command` modules. You'll see inline bash scattered throughout task files, usually for things that don't have a dedicated Ansible module.

---

## Secrets

Sensitive credentials are never stored in this repository. They live in Forgejo as encrypted secrets and are injected into the Ansible run at pipeline time — written to a temporary file that gets passed to Ansible via `--extra-vars` and deleted afterward.