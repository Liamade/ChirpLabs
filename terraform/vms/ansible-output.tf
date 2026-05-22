# Exposes VM info after apply so the workflow can write vm_info.json
# to MinIO for Ansible to consume.
#
# Output shape:
# {
#   "grafana-test":   { "ip": "<vm-ip>", "role": "grafana",    "node": "Amy" },
#   "nagios-test":    { "ip": "<vm-ip>", "role": "nagios",     "node": "Amy" },
#   "SecMonDock-test":{ "ip": "<vm-ip>", "role": "secmondock", "node": "Amy" }
# }

output "vm_ips" {
  description = "Map of VM name to IP, role, and node — consumed by Ansible inventory generation."

  value = {
    for name, vm in module.ubuntu_vms : name => {
      ip   = vm.ip
      role = local.ubuntu_vms[name].role
      node = vm.node
    }
  }
}