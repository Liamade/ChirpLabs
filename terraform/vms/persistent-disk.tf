# ============================================================
# WHAT IS THIS FILE?
# Handles persistent data disk lifecycle for VMs that define
# a data_disk field in vm-definitions.tf.
#
# On create: attaches the pre-existing disk to the VM via the
#            Proxmox API (no SSH needed — reuses PROXMOX_API_TOKEN)
# On destroy: unlinks the disk from the VM before it's deleted
#             (unlink moves it to unusedX — does NOT delete it)
#
# VMs without a data_disk key are ignored entirely.
# ============================================================

locals {
  vms_with_disk = {
    for k, v in local.ubuntu_vms : k => v
    if try(v.data_disk, null) != null
  }
}

resource "null_resource" "data_disk_lifecycle" {
  for_each = local.vms_with_disk

  triggers = {
    vm_id = module.ubuntu_vms[each.key].vm_id
    disk_vol     = each.value.data_disk
    node_name    = each.value.node_name   # removed lower() — Proxmox API needs "Amy" not "amy"
    proxmox_host = local.nodes[each.value.node_name].ip
    force_rerun  = "2"                    # bump to force re-run
  }

  depends_on = [module.ubuntu_vms]

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(cat /tmp/proxmox_token)
      echo "Token length: $${#TOKEN}"
      echo "Token prefix: $${TOKEN:0:25}..."
      result=$(curl -k -X PUT \
        -H "Authorization: PVEAPIToken=$TOKEN" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -w "\nHTTP_STATUS:%%{http_code}" \
        "https://${self.triggers.proxmox_host}:8006/api2/json/nodes/${self.triggers.node_name}/qemu/${self.triggers.vm_id}/config" \
        -d "scsi1=${self.triggers.disk_vol}")
      echo "Full response: $result"
      echo "$result" | grep -q '"errors"' && echo "ERROR: Disk attach failed" && exit 1
      exit 0
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      TOKEN=$(cat /tmp/proxmox_token)
      result=$(curl -k -X PUT \
        -H "Authorization: PVEAPIToken=$TOKEN" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        "https://${self.triggers.proxmox_host}:8006/api2/json/nodes/${self.triggers.node_name}/qemu/${self.triggers.vm_id}/unlink" \
        -d "idlist=scsi1")
      echo "Proxmox response: $result"
      echo "$result" | grep -q '"errors"' && echo "ERROR: Disk unlink failed" && exit 1
      exit 0
    EOT
  }
}