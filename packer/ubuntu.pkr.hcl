# ============================================================
# WHAT IS THIS FILE?
# This is the main Packer config. It tells Packer:
#   1. What kind of VM to build (hardware specs, OS, etc.)
#   2. What to do INSIDE the VM after it boots (install software)
#   3. How to clean it up and convert it to a reusable template
#
# The output is a Proxmox VM template that Terraform will clone
# every time it needs to spin up a new server.
#
# Storage split:
#   iso_storage_pool  — NFS pool where the Ubuntu ISO lives.
#                       Shared across all nodes, read at build time only.
#   disk_storage_pool — Local storage on the target node for the template
#                       disk and cloud-init drive. Kept local for high I/O.
#                       Each node (Amy = 299, Farnsworth = 300) gets its own
#                       independent template on its own local storage.
#                       Terraform clones locally on each node — no cross-node
#                       transfer, no shared storage dependency for VM disks.
# ============================================================

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# ── Variables ────────────────────────────────────────────────────────────────

variable "proxmox_url" {
  type = string
  # Injected by the workflow matrix per node.
  # Format: "https://<node-ip>:8006/api2/json"
}

variable "proxmox_node" {
  type = string
  # Injected by the workflow matrix — "amy" or "farnsworth".
}

variable "proxmox_token_id" {
  type      = string
  sensitive = true
  # Injected by the workflow from Forgejo secret PROXMOX_TOKEN_ID.
}

variable "proxmox_token_secret" {
  type      = string
  sensitive = true
  # Injected by the workflow from Forgejo secret PROXMOX_TOKEN_SECRET.
}

variable "vm_id" {
  type = number
  # Injected by the workflow matrix per node.
  # Amy = 299, Farnsworth = 300.
}

variable "ansible_ssh_public_key" {
  type        = string
  description = "Ansible runner's public key — baked into the template so Ansible can SSH into every cloned VM."
  # Injected by the workflow from Forgejo variable ANSIBLE_SSH_PUBLIC_KEY.
  # This is the Ansible/runner key only. The packer build key (packer_rsa) is separate:
  # it is injected via user-data late-commands, used only during this build, then removed.
}

variable "build_vm_ip" {
  type = string
  # Injected by the workflow from Forgejo variable PACKER_VM_IP.
  # Must match the address in packer/http/user-data (set by the sed injection step in the workflow).
  # The same build VM IP is reused for both node builds since they run sequentially.
}

variable "iso_storage_pool" {
  type = string
  # Injected by the workflow from Forgejo variable TEMPLATE_STORAGE_POOL.
  # The NFS pool where the Ubuntu ISO lives — e.g. "ChirpNAS_ISO_Templates".
  # Used only to locate the boot ISO. No data is written here by this build.
}

variable "disk_storage_pool" {
  type = string
  # Injected by the workflow matrix per node.
  # Local storage on the target node for the template disk and cloud-init drive.
  # e.g. "data" or "local-lvm". Must exist on the node being built.
}

variable "disk_format" {
  type = string
  # Injected by the workflow matrix per node.
  # "raw"   — use for LVM-thin local storage (most common for Proxmox "data" datastores)
  # "qcow2" — use for directory-based local storage
  # Check in Proxmox UI: Datacenter → Storage → <pool> → Type column.
}

variable "iso_file" {
  type = string
  # Injected by the workflow from Forgejo variable PACKER_ISO_FILE.
  # Format: "<pool>:iso/<filename>" e.g. "ChirpNAS_ISO_Templates:iso/ubuntu-24.04.4-live-server-amd64.iso"
}

variable "iso_checksum" {
  type = string
  # Injected by the workflow from Forgejo variable PACKER_ISO_CHECKSUM.
  # Format: "<type>:<hash>" e.g. "sha256:45f873de9f8cb637345d6e66a583762730bbea30277ef7b32c9c3bd6700a32b2"
  # Find the official checksum at: https://releases.ubuntu.com/24.04/SHA256SUMS
}

variable "build_bridge" {
  type    = string
  default = "vmbr0"
  # Network bridge for the build VM.
  # Injected by the workflow matrix per node.
  # Amy uses vmbr0, Farnsworth may use a different bridge.
}
variable "build_vlan_tag" {
  type    = string
  default = ""
  # Empty string means no VLAN tag (used for OVS bridges that handle VLANs natively)
  # Set to a number string like "81" for standard linux bridges that need explicit tagging
}

# ── Source block ─────────────────────────────────────────────────────────────

source "proxmox-iso" "ubuntu-docker" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = true

  node    = var.proxmox_node
  vm_id   = var.vm_id
  vm_name = "chirplabs-infrastructure-ubuntu"
  tags    = "template"

  # Boot ISO is read from the NFS pool — no upload, just a path reference.
  # unmount_iso removes it from the template config before conversion.
  iso_file         = var.iso_file
  iso_checksum     = var.iso_checksum
  iso_storage_pool = var.iso_storage_pool
  unmount_iso      = true

  cores  = 2
  memory = 2048

  disks {
    disk_size    = "8G"
    storage_pool = var.disk_storage_pool  # Local storage — high I/O, node-specific
    type         = "scsi"
    format       = var.disk_format        # raw for LVM-thin, qcow2 for directory
  }

  network_adapters {
    model    = "virtio"
    bridge   = var.build_bridge
    vlan_tag = var.build_vlan_tag != "" ? tonumber(var.build_vlan_tag) : null
  }

  # Cidata is a temporary ISO Packer generates from user-data/meta-data.
  # Stays on local — NFS rejects this upload. The cidata drive is removed
  # from the template after build by the workflow's "Remove cidata drive" step.
  additional_iso_files {
    cd_label         = "cidata"
    cd_files         = ["http/user-data", "http/meta-data"]
    iso_storage_pool = "local"
    device           = "ide3"
  }

  # Cloud-init drive goes on local storage alongside the template disk.
  cloud_init              = true
  cloud_init_storage_pool = var.disk_storage_pool

  communicator           = "ssh"
  ssh_username           = "ubuntu"
  ssh_private_key_file   = "~/.ssh/packer_rsa"
  ssh_host               = var.build_vm_ip
  ssh_timeout            = "80m"
  ssh_handshake_attempts = 300
  ssh_pty                = true

  boot_command = [
    "<esc><wait2>",
    "e<wait2>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud",
    "<f10><wait>"
  ]

  boot_wait = "15s"
}

# ── Build block ──────────────────────────────────────────────────────────────

# the actual building of the template
build {
  sources = ["source.proxmox-iso.ubuntu-docker"]  # defines what to build and what to do after VM is up -> the source up above

  error-cleanup-provisioner "shell" {   # in case the build fails
    inline = ["echo 'Build failed — Proxmox will clean up the VM.'"]
  }
  
  #==========================================================================
  # SHELL COMMANDS INSIDE THE VM OVER SSH
  #==========================================================================

  # ── Step 1: Bootstrap DNS and base packages ──────────────────────────────
  provisioner "shell" { # tells it to run in the shell
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"] # makes the command become noninteractive and doesn't require inputs
    timeout          = "15m"  # in case it never goes through it had a timeout
    # the actual shell command
    inline = [
      "echo 'nameserver 172.27.10.5' | sudo tee /etc/resolv.conf",
      "echo 'nameserver 172.27.10.6' | sudo tee -a /etc/resolv.conf",
      "echo 'nameserver 8.8.8.8'    | sudo tee -a /etc/resolv.conf",
      "sudo apt-get update",
      "sudo apt-get install -y curl git qemu-guest-agent",
      "sudo systemctl enable qemu-guest-agent"
    ]
  }

  # ── Step 2: Install Docker ────────────────────────────────────────────────
  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    timeout          = "15m"
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y ca-certificates curl gnupg",
      "sudo install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "sudo chmod a+r /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
      "sudo apt-get update",
      "sudo systemctl mask docker containerd",
      "sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",
      "sudo systemctl unmask docker containerd",
      "sudo systemctl enable docker"
    ]
  }

  # ── Step 3: Bake the Ansible SSH key into the template ───────────────────
  # Passed via environment variable rather than direct HCL interpolation to
  # avoid shell escaping issues with the key string.
  # The packer build key (packer_rsa) was injected by user-data late-commands
  # and will be removed in the cleanup step below.
  provisioner "shell" {
    environment_vars = ["ANSIBLE_SSH_PUBLIC_KEY=${var.ansible_ssh_public_key}"]
    timeout          = "5m"
    inline = [
      "mkdir -p /home/ubuntu/.ssh",
      "echo \"$ANSIBLE_SSH_PUBLIC_KEY\" >> /home/ubuntu/.ssh/authorized_keys",
      "chmod 700 /home/ubuntu/.ssh",
      "chmod 600 /home/ubuntu/.ssh/authorized_keys"
    ]
  }

  # ── Step 4: Install Prometheus node exporter ─────────────────────────────
  # I used it for testing and it's probably not needed, but I'm scared to take it off
  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    timeout          = "15m"
    inline = [
      "sudo systemctl mask prometheus-node-exporter",
      "sudo apt-get install -y prometheus-node-exporter",
      "sudo systemctl unmask prometheus-node-exporter",
      "sudo systemctl enable prometheus-node-exporter"
    ]
  }
  # ── Step 5: Disable unattended-upgrades ──────────────────────────────────
  # Prevents Ubuntu from running automatic updates on first boot.
  # Without this, cloud-init triggers apt on every fresh VM which conflicts
  # with Ansible trying to install packages at the same time.
  # Ansible is responsible for package management — not Ubuntu's auto-updater.
  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline = [
      "sudo systemctl disable unattended-upgrades",
      "sudo systemctl mask unattended-upgrades",
      "sudo apt-get remove -y unattended-upgrades"
    ]
  }

  # ── Step 6: Remove packer build key and clean up for templating ──────────
  # Removes the packer_rsa public key that was injected by user-data so Packer
  # could SSH in during this build. Cloned VMs should only accept the Ansible
  # key — the build key must not persist into production.
  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    timeout          = "5m"
    inline = [
      "sed -i '/key pair for packer/d' /home/ubuntu/.ssh/authorized_keys",
      "sudo cloud-init clean",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo sync"
    ]
  }
}
