# group_vars

This directory contains variable files that Ansible automatically loads based on which inventory group a host belongs to. Variables defined here are available to every role and task that runs against the matching hosts — no manual importing required.

---

## File Structure

```
group_vars/
├── README.md           ← you are here
├── all.yml             ← loaded for every host in the inventory
├── grafana.yml         ← loaded only for hosts in the [grafana] group
├── nagios.yml          ← loaded only for hosts in the [nagios] group
└── secmondock.yml      ← loaded only for hosts in the [secmondock] group
```

---

## How Ansible Loads These Files

Ansible matches the filename (minus `.yml`) to a group name in `inventory/hosts.ini`. If a host belongs to that group, the file is loaded automatically before any tasks run.

```ini
# inventory/hosts.ini
[grafana]
<vm-ip>        # → group_vars/grafana.yml is loaded for this host

[nagios]
<vm-ip>        # → group_vars/nagios.yml is loaded for this host

[secmondock]
<vm-ip>        # → group_vars/secmondock.yml is loaded for this host
```

`all.yml` is the exception — it loads for **every** host regardless of group.

---

## `all.yml` — Global Variables

Variables that apply to every VM in the inventory. Currently holds SSH connection settings and the base credential placeholder used by the `common` role.

```yaml
# Connection settings used by every playbook
ansible_user: ubuntu
ansible_ssh_private_key_file: ~/.ssh/ansible_ed25519
ansible_ssh_common_args: '-o StrictHostKeyChecking=no'

# Injected at runtime via -e from Forgejo secrets
ctadmin_user_password: ""
```

`StrictHostKeyChecking=no` is required because the runner container has never seen a freshly provisioned VM before and can't answer host key prompts interactively.

---

## Per-Group Files

### `grafana.yml`

Variables for hosts in the `[grafana]` inventory group. Defines where the persistent data disk is mounted and the admin credentials for the Grafana service.

```yaml
grafana_disk_uuid: "d75c48b0-..."   # UUID of vm-999-Grafana-DATA on Amy
grafana_data_path: /var/lib/grafana # mount point — Grafana's main data directory
grafana_config_path: /etc/grafana   # where Grafana config files live

grafana_admin_user: "ctadmin"
grafana_admin_password: ""          # injected at runtime via -e from Forgejo secrets
```

---

### `nagios.yml`

Variables for hosts in the `[nagios]` inventory group. Nagios is compiled from source and lives entirely under `/usr/local/nagios/`, so the data disk mounts directly there.

```yaml
nagios_disk_uuid: "b95f1230-..."              # UUID of vm-999-Nagios-DATA on Amy
nagios_data_path: /usr/local/nagios           # mount point — the full Nagios install root
nagios_config_backup_path: /usr/local/nagios/disk-backups  # external configs backed up here
```

---

### `secmondock.yml`

Variables for hosts in the `[secmondock]` inventory group. Holds paths and empty secret placeholders for the Wazuh, Graylog, and Shuffle services running on that VM.

```yaml
secmondock_disk_uuid: "11f39fcc-..."          # UUID of vm-999-SecMonDock-DATA on Amy
secmondock_data_path: /mnt/data               # where the data disk is mounted
secmondock_services_path: /opt/services/secmondock  # where compose files and role assets are deployed

# All secrets below are empty defaults — always overridden by -e at runtime
wazuh_api_password: ""
wazuh_indexer_password: ""
wazuh_dashboard_password: ""
graylog_password_secret: ""
graylog_root_password_sha2: ""
shuffle_opensearch_password: ""
```

---

## Secret Handling Pattern

Secrets are **never hardcoded** in these files. The pattern used across all group_vars files is:

1. Declare the variable with an empty string default so roles can reference it safely.
2. The real value is stored as a Forgejo Actions secret.
3. The pipeline injects it at runtime with `-e "var_name=${{ secrets.VAR_NAME }}"`.

This means if a playbook runs outside the pipeline (e.g. manually), it will use empty strings for secrets — which will fail loudly rather than silently use a wrong value.

---

## Adding Variables for a New VM

1. Add the VM to `inventory/hosts.ini` under a new group:

```ini
[myservice]
<vm-ip>
```

2. Create `group_vars/myservice.yml` with its variables:

```yaml
# UUID of the persistent disk for this VM
myservice_disk_uuid: ""

# Mount point for the data disk
myservice_data_path: /opt/myservice

# Secrets — empty defaults, injected at runtime
myservice_secret: ""
```

3. Reference these variables by name inside the role (`roles/myservice/tasks/main.yml`) — Ansible makes them available automatically.