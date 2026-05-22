# group_vars

This directory contains variable files that Ansible loads automatically based on inventory group membership. Each file defines variables that are available to every role and task running against hosts in the matching group — no importing required.

---

## How It Works

Ansible does a simple name match. When a playbook runs against a host, Ansible checks which groups that host belongs to in `hosts.ini`, then looks for a file in `group_vars/` with the same name. If it finds one, it loads it automatically before any tasks run.

```
hosts.ini group name  →  group_vars/<groupname>.yml  →  variables in scope for that host
```

`all.yml` is the only special case — it loads for every host regardless of group.

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

## Writing a Group Vars File

### 1. Name it after the group

The filename must exactly match the group name in `inventory/hosts.ini`:

```ini
# inventory/hosts.ini
[myservice]
172.27.80.XX
```

```
group_vars/myservice.yml   ✓ matches [myservice]
group_vars/MyService.yml   ✗ won't load — case sensitive
group_vars/my_service.yml  ✗ won't load — must be exact
```

---

### 2. Define your variables

Variables are plain YAML key-value pairs. Name them clearly and consistently, using the group name as a prefix so it's obvious where they come from when referenced inside a role.

```yaml
# group_vars/myservice.yml

# Persistent disk UUID — use `blkid` on the VM to find this
myservice_disk_uuid: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Where the data disk gets mounted on the VM
myservice_data_path: /opt/myservice

# Where the role deploys compose files and config assets
myservice_services_path: /opt/services/myservice
```

---

### 3. Handle secrets correctly

Secrets (passwords, API keys, tokens) should **never be hardcoded** in these files. The pattern used throughout this repo is to declare the variable with an empty string default, then have the real value injected at runtime by the Forgejo Actions pipeline via `-e`.

```yaml
# Declare with empty default — the real value comes from Forgejo secrets at runtime
myservice_admin_password: ""
myservice_api_key: ""
```

In the workflow, the pipeline injects them like this:

```yaml
- name: Run myservice playbook
  run: |
    ansible-playbook -i inventory/hosts.ini playbooks/myservice.yml \
      -e "myservice_admin_password=${{ secrets.MYSERVICE_ADMIN_PASSWORD }}" \
      -e "myservice_api_key=${{ secrets.MYSERVICE_API_KEY }}"
```

The empty default means if the playbook accidentally runs without injection, the variable still exists but is obviously wrong — it fails loudly rather than silently using a bad value.

---

### 4. Reference variables in your role

Once defined in `group_vars/`, variables are available by name anywhere in the role without any extra imports. Ansible has already loaded them by the time the role runs.

```yaml
# roles/myservice/tasks/main.yml

- name: Mount data disk
  ansible.posix.mount:
    path: "{{ myservice_data_path }}"       # comes from group_vars/myservice.yml
    src: "UUID={{ myservice_disk_uuid }}"   # comes from group_vars/myservice.yml
    fstype: ext4
    state: mounted
```

---

## Full Example

```yaml
# group_vars/myservice.yml
# =============================================================================
# PURPOSE: Variables for all hosts in the [myservice] inventory group.
#
# SECRETS (injected at runtime via -e from Forgejo secrets):
#   myservice_admin_password  — admin password for the service
# =============================================================================

# -----------------------------------------------------------------------------
# DISK
# -----------------------------------------------------------------------------
myservice_disk_uuid: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # UUID of vm-999-MyService-DATA on Amy
myservice_data_path: /opt/myservice                          # where the disk gets mounted on the VM

# -----------------------------------------------------------------------------
# SERVICE
# -----------------------------------------------------------------------------
myservice_services_path: /opt/services/myservice  # where compose files and assets are deployed

# -----------------------------------------------------------------------------
# SECRETS — empty defaults, always overridden by -e at runtime
# -----------------------------------------------------------------------------
myservice_admin_password: ""
```

---

## What Goes in `all.yml` vs a Group File

| Put it in `all.yml` | Put it in a group file |
|---|---|
| SSH connection settings | Disk UUIDs and mount paths |
| Ansible interpreter path | Service-specific config values |
| Variables every role needs | Secrets scoped to one service |
| Base user credentials | Anything only one group uses |