# ============================================================
# WHAT IS THIS FILE?
# Declares the variables that Forgejo injects into Terraform at
# runtime via TF_VAR_ environment variables. Without these
# declarations Terraform won't accept them.
#
# You should rarely need to touch this file after initial setup.
# To add a new VM or change VM config, edit vm-definitions.tf.
#
# How each variable gets its value:
#   proxmox_url            → TF_VAR_proxmox_url        from Forgejo variable PROXMOX_URL
#   proxmox_api_token      → TF_VAR_proxmox_api_token   from Forgejo secret  PROXMOX_API_TOKEN
#   template_vm_id         → TF_VAR_template_vm_id      from Forgejo variable TEMPLATE_VM_ID
# ============================================================

variable "proxmox_api_token" {
  description = "Full Proxmox API token in the format tokenid=secret."
  type        = string
  sensitive   = true
  # e.g. "forgejo@pam!forgejo=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}

