# roles

> **Onboarding note:** This document is written as a reference guide for the next ChirpLabs cohort. It covers Ansible role structure, common modules, and patterns used throughout this repo. If you already know Ansible, skip to the role directories themselves.

This directory contains Ansible roles. A role is a self-contained unit of configuration for a specific service or VM — it holds all the tasks, config file templates, static files, and handlers needed to fully set up that service. Playbooks call roles; roles do the actual work.

---

## Directory Structure

```
roles/
├── common/                     ← runs on every VM before any service role
│   └── tasks/
│       └── main.yml
├── grafana/
│   ├── tasks/
│   │   └── main.yml
│   ├── templates/
│   │   └── grafana.ini.j2
│   ├── handlers/
│   │   └── main.yml
│   └── files/
│       └── some-static-file
└── nagios/
    ├── tasks/
    │   └── main.yml
    ├── templates/
    │   └── nagios.cfg.j2
    ├── handlers/
    │   └── main.yml
    └── files/
        └── nagios-exporter.deb
```

Ansible looks for these subdirectory names automatically — `tasks/`, `templates/`, `handlers/`, and `files/` are conventions Ansible understands, not arbitrary folders. You only need to create the ones you actually use.

---

## `tasks/main.yml`

This is the entry point for a role and the only required file. It contains the ordered list of things Ansible does on the target host. Tasks run sequentially — if one fails, execution stops.

### Basic Task Structure

Every task follows the same structure:

```yaml
- name: A clear human-readable description of what this does
  module.name:           # the Ansible module to use
    option: value        # module-specific options
    another_option: value
```

The `name` field is technically optional but should always be included — it's what you see in the output when the playbook runs, so make it descriptive.

---

### Common Modules

These are the modules you'll use most often:

**`ansible.builtin.apt`** — install/remove packages:

```yaml
- name: Install nginx
  ansible.builtin.apt:
    name: nginx           # package name, or a list of packages
    state: present        # present = install, absent = remove, latest = upgrade
    update_cache: true    # equivalent of apt update before installing
```

```yaml
# Installing multiple packages at once
- name: Install base packages
  ansible.builtin.apt:
    name:
      - curl
      - git
      - vim
    state: present
    update_cache: true
```

---

**`ansible.builtin.template`** — deploy a Jinja2 template as a file:

```yaml
- name: Deploy config file
  ansible.builtin.template:
    src: myservice.conf.j2    # filename in roles/myservice/templates/
    dest: /etc/myservice/myservice.conf
    owner: myservice          # file owner
    group: myservice          # file group
    mode: '0644'              # file permissions (always quote these)
```

---

**`ansible.builtin.copy`** — copy a static file:

```yaml
- name: Copy exporter binary
  ansible.builtin.copy:
    src: exporter.deb         # filename in roles/myservice/files/
    dest: /tmp/exporter.deb
    mode: '0644'
```

---

**`ansible.builtin.file`** — create directories, set permissions, manage symlinks:

```yaml
- name: Create data directory
  ansible.builtin.file:
    path: /opt/myservice
    state: directory          # directory = create dir, absent = delete, touch = create file
    owner: myservice
    group: myservice
    mode: '0755'
```

---

**`ansible.posix.mount`** — mount a disk:

```yaml
- name: Mount data disk
  ansible.posix.mount:
    path: "{{ myservice_data_path }}"
    src: "UUID={{ myservice_disk_uuid }}"
    fstype: ext4
    state: mounted            # mounted = mount now and add to fstab
```

---

**`ansible.builtin.systemd`** — manage services:

```yaml
- name: Enable and start myservice
  ansible.builtin.systemd:
    name: myservice
    enabled: true             # start on boot
    state: started            # started, stopped, restarted, reloaded
    daemon_reload: true       # run systemctl daemon-reload first (needed after writing unit files)
```

---

**`ansible.builtin.shell`** / **`ansible.builtin.command`** — run a shell command:

```yaml
# command is preferred — doesn't invoke a shell, safer for simple commands
- name: Run a command
  ansible.builtin.command: myprogram --flag value

# shell is needed when you use pipes, redirects, or shell built-ins
- name: Run a shell command
  ansible.builtin.shell: cat /proc/version | grep -i ubuntu
```

---

**`ansible.builtin.user`** — create/manage users:

```yaml
- name: Create service user
  ansible.builtin.user:
    name: myservice
    system: true              # creates a system account (no home dir, no login)
    shell: /sbin/nologin
```

---

### Conditionals — `when:`

`when:` makes a task only run if a condition is true. It goes at the task level, not inside the module options.

```yaml
- name: Install thing only on Ubuntu
  ansible.builtin.apt:
    name: thing
    state: present
  when: ansible_distribution == "Ubuntu"   # ansible_distribution is a fact Ansible collects automatically

- name: Only run if a variable is set
  ansible.builtin.shell: do-something
  when: myservice_enable_feature is defined and myservice_enable_feature == true

- name: Skip if a file already exists
  ansible.builtin.command: setup-program
  when: not setup_done.stat.exists          # using a registered variable (see below)
```

---

### Registering Output — `register:`

`register:` captures the output of a task into a variable so a later task can use it.

```yaml
- name: Check if config file exists
  ansible.builtin.stat:
    path: /etc/myservice/myservice.conf
  register: config_file                     # saves the result into config_file

- name: Run setup only if config is missing
  ansible.builtin.command: myservice --init
  when: not config_file.stat.exists         # reference the registered variable
```

The registered variable holds different fields depending on the module. `stat` gives you `.stat.exists`, `.stat.size`, etc. `shell`/`command` gives you `.stdout`, `.stderr`, `.rc` (return code).

```yaml
- name: Get disk UUID
  ansible.builtin.command: blkid -s UUID -o value /dev/sdb
  register: disk_uuid

- name: Print the UUID
  ansible.builtin.debug:
    msg: "Disk UUID is {{ disk_uuid.stdout }}"
```

---

### Loops — `loop:`

`loop:` runs the same task multiple times over a list of items. The current item is referenced as `{{ item }}`.

```yaml
- name: Create multiple directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    mode: '0755'
  loop:
    - /opt/myservice/data
    - /opt/myservice/logs
    - /opt/myservice/config
```

You can also loop over a list of dictionaries when you need multiple values per item:

```yaml
- name: Create users
  ansible.builtin.user:
    name: "{{ item.name }}"
    shell: "{{ item.shell }}"
  loop:
    - { name: nagios, shell: /sbin/nologin }
    - { name: nagcmd, shell: /sbin/nologin }
```

---

### Notifying Handlers — `notify:`

`notify:` triggers a handler when a task makes a change. The handler name must match exactly.

```yaml
- name: Deploy config file
  ansible.builtin.template:
    src: myservice.conf.j2
    dest: /etc/myservice/myservice.conf
  notify: Restart myservice    # only fires if the file actually changed
```

See the **Handlers** section below for how to write the handler itself.

---

## `templates/`

Templates are config files that contain placeholders Ansible fills in before copying them to the host. The `.j2` extension marks them as Jinja2 templates. Any variable in scope — from `group_vars`, injected secrets, or registered variables — can be used inside a template.

### Basic Variable Substitution

Wrap any variable name in `{{ }}` and Ansible replaces it with the actual value at deploy time:

```jinja2
# roles/myservice/templates/myservice.conf.j2

[server]
data_dir = {{ myservice_data_path }}
admin_user = {{ myservice_admin_user }}
admin_password = {{ myservice_admin_password }}
listen_port = 3000
```

---

### Conditionals in Templates

Use `{% if %}` to include or exclude blocks of config based on a variable:

```jinja2
[database]
host = localhost

{% if myservice_enable_ssl is defined and myservice_enable_ssl %}
ssl = true
ssl_cert = /etc/myservice/cert.pem
ssl_key = /etc/myservice/key.pem
{% else %}
ssl = false
{% endif %}
```

---

### Loops in Templates

Use `{% for %}` to generate repeated blocks from a list variable:

```jinja2
# Generates an entry for each item in the allowed_hosts list
[access]
{% for host in myservice_allowed_hosts %}
allow = {{ host }}
{% endfor %}
```

The `myservice_allowed_hosts` variable would be defined in `group_vars/myservice.yml` as a YAML list:

```yaml
myservice_allowed_hosts:
  - 172.27.80.10
  - 172.27.80.11
```

---

### Filters

Filters transform a variable's value. They're appended with a pipe `|`:

```jinja2
{{ myservice_name | upper }}          # converts to uppercase
{{ myservice_name | lower }}          # converts to lowercase
{{ myservice_path | default('/opt') }} # uses /opt if variable is not defined
{{ myservice_timeout | int }}         # converts string to integer
{{ myservice_admin_password | quote }} # safely quotes a value for use in shell commands
```

---

### Deploying a Template

The task that deploys a template only needs the filename — Ansible looks in `roles/<rolename>/templates/` automatically:

```yaml
- name: Deploy myservice config
  ansible.builtin.template:
    src: myservice.conf.j2
    dest: /etc/myservice/myservice.conf
    owner: myservice
    group: myservice
    mode: '0644'
  notify: Restart myservice
```

---

## `files/`

Static files that are copied to the host exactly as-is — no variable substitution happens. Use this for pre-built binaries, `.deb` packages, certificates, or any config that is identical on every deployment.

```yaml
- name: Copy nagios exporter package
  ansible.builtin.copy:
    src: nagios-exporter.deb      # lives in roles/nagios/files/
    dest: /tmp/nagios-exporter.deb
    mode: '0644'

- name: Install nagios exporter
  ansible.builtin.apt:
    deb: /tmp/nagios-exporter.deb
```

Ansible looks in `roles/<rolename>/files/` automatically — just use the filename, no path needed.

**`files/` vs `templates/`** — if the file contains `{{ }}` placeholders that need filling in, it's a template. If the file is identical every time it's deployed, it belongs in `files/`.

---

## `handlers/main.yml`

Handlers are tasks that only run when explicitly triggered by another task via `notify:`. The most common use is restarting a service after its config changes — no point restarting if nothing actually changed.

### Writing a Handler

Handlers look identical to tasks, but live in `handlers/main.yml`:

```yaml
# roles/myservice/handlers/main.yml
---
- name: Restart myservice
  ansible.builtin.systemd:
    name: myservice
    state: restarted

- name: Reload nginx
  ansible.builtin.systemd:
    name: nginx
    state: reloaded        # reloaded = graceful config reload, restarted = full restart
```

### Triggering a Handler

Any task can trigger a handler with `notify:`. The string must match the handler `name` exactly — capitalization included.

```yaml
# in tasks/main.yml
- name: Deploy nginx config
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
  notify: Reload nginx          # matches handler name exactly

- name: Deploy app config
  ansible.builtin.template:
    src: myservice.conf.j2
    dest: /etc/myservice/myservice.conf
  notify: Restart myservice     # matches handler name exactly
```

### Key Behaviors

**Handlers only run if the task made a change.** If the config file was already correct and Ansible didn't need to change it, the handler is skipped entirely.

**Handlers run once at the end of the play, not immediately.** If ten tasks all notify the same handler, the service still only restarts once — after all tasks finish.

**Multiple tasks can notify the same handler:**

```yaml
- name: Deploy main config
  ansible.builtin.template:
    src: myservice.conf.j2
    dest: /etc/myservice/myservice.conf
  notify: Restart myservice

- name: Deploy secondary config
  ansible.builtin.template:
    src: myservice-extra.conf.j2
    dest: /etc/myservice/extra.conf
  notify: Restart myservice     # same handler — still only restarts once
```

**Force handlers to run immediately with `flush_handlers`** — useful when a later task depends on the service being restarted before it runs:

```yaml
- name: Deploy config
  ansible.builtin.template:
    src: myservice.conf.j2
    dest: /etc/myservice/myservice.conf
  notify: Restart myservice

- name: Force handlers to run now
  ansible.builtin.meta: flush_handlers    # restart happens here instead of end of play

- name: Wait for service to be ready
  ansible.builtin.wait_for:
    port: 3000
    timeout: 30
```

---

## Adding a New Role

1. Create the directory structure (only include what you need):

```
roles/myservice/
├── tasks/
│   └── main.yml      ← required
├── templates/         ← if you have config files with variables
├── handlers/          ← if you need conditional restarts
└── files/             ← if you have static files to copy
```

2. Write `tasks/main.yml`. A minimal starting point:

```yaml
---
- name: Install myservice
  ansible.builtin.apt:
    name: myservice
    state: present
    update_cache: true

- name: Deploy config
  ansible.builtin.template:
    src: myservice.conf.j2
    dest: /etc/myservice/myservice.conf
    owner: myservice
    group: myservice
    mode: '0644'
  notify: Restart myservice

- name: Enable and start myservice
  ansible.builtin.systemd:
    name: myservice
    enabled: true
    state: started
```

3. Create a playbook in `../playbooks/myservice.yml`:

```yaml
---
- name: Configure myservice
  hosts: myservice
  become: true

  roles:
    - common
    - myservice
```

4. Create `../group_vars/myservice.yml` with any variables the role needs.

5. Add it to `../playbooks/site.yml`:

```yaml
- import_playbook: myservice.yml
```