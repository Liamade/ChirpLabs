# security-core

This directory contains Ansible templates for the combined Graylog + Wazuh stack.
These two services are grouped together because Wazuh joins Graylog's Docker network
(`graylog`) at startup — Graylog must exist before Wazuh can connect to it.

## Files

| File | Deployed to | Purpose |
|---|---|---|
| `docker-compose.yml.j2` | `/opt/services/secmondock/security-core/` | Defines all Graylog and Wazuh containers |
| `.env.j2` | `/opt/services/secmondock/security-core/` | Graylog secrets (password secret + root password SHA2) |
| `filebeat.yml.j2` | `/opt/services/secmondock/security-core/` | Filebeat config — ships Wazuh alerts to Graylog Beats input |
| `opensearch.yml.j2` | `/mnt/data/wazuh/indexer/config/` | Wazuh indexer (OpenSearch) node configuration |
| `internal_users.yml.j2` | `/mnt/data/wazuh/indexer/config/` | Wazuh indexer built-in user definitions and password hashes |
| `opensearch_dashboards.yml.j2` | `/mnt/data/wazuh/dashboard/config-files/` | Wazuh dashboard server config (SSL, OpenSearch connection) |
| `wazuh.yml.j2` | `/mnt/data/wazuh/dashboard/config-files/` | Wazuh dashboard API connection config |
| `wazuh-ossec.conf.j2` | `/mnt/data/wazuh/manager/ossec/` | Wazuh manager main config (rules, integrations, agent settings) |
| `custom-misp.py.j2` | `/mnt/data/wazuh/integration-scripts/scripts/` | Wazuh-to-MISP integration script (placeholder — implement as needed) |

## Important notes

### SSL certificates
Wazuh requires SSL certificates for communication between its components
(manager, indexer, dashboard). These are generated automatically on first
deploy using the `wazuh/wazuh-certs-generator` container and stored on
the persistent disk at `/mnt/data/wazuh/indexer/ssl-certs/`.

Cert generation is skipped on subsequent runs if the certs already exist.
If you need to regenerate certs, delete the ssl-certs directory contents
and rerun Ansible.

### Graylog SSL certificates
Graylog requires TLS certs that are **not** auto-generated — they must be
copied manually before running Ansible for the first time. Ansible will
fail with a clear error message if they are missing.

Required files at `/mnt/data/graylog/certs/`:
- `rootCA.crt`
- `server.crt`
- `server.key`
- `server_pkcs8.key`
- `truststore.jks`

These came from the original Graylog instance. If setting up from scratch,
generate a self-signed CA and server cert using OpenSSL and import the CA
into a Java truststore.

### Persistent vs ephemeral data
- `/opt/services/secmondock/security-core/` — **ephemeral**, written fresh on every Ansible run
- `/mnt/data/wazuh/` — **persistent**, survives VM destroy/recreate
- `/mnt/data/graylog/` — **persistent**, survives VM destroy/recreate

### What persists automatically (no extra config needed)
- Graylog streams, inputs, dashboards, alerts → stored in MongoDB at `/mnt/data/graylog/mongodb/`
- Wazuh agent registrations, rules, alert history → stored in indexer at `/mnt/data/wazuh/indexer/data/`
- Wazuh agent configs → stored in manager volumes at `/mnt/data/wazuh/manager/`

### What requires template updates to change
- Wazuh manager behavior (rootcheck, syscheck, integrations) → `wazuh-ossec.conf.j2`
- Wazuh dashboard connection settings → `wazuh.yml.j2` and `opensearch_dashboards.yml.j2`
- Filebeat shipping destination → `filebeat.yml.j2`
- Shuffle webhook URL → `wazuh-ossec.conf.j2` (the `<integration>` block at the bottom)
- MISP integration logic → `custom-misp.py.j2` (currently a placeholder)

### Secrets
All secrets are injected at runtime from Forgejo secrets via `-e` flags.
Never hardcode credentials in these templates.

| Variable | Forgejo Secret | Used in |
|---|---|---|
| `graylog_password_secret` | `GRAYLOG_PASSWORD_SECRET` | `.env.j2` |
| `graylog_root_password_sha2` | `GRAYLOG_ROOT_PASSWORD_SHA2` | `.env.j2` |
| `wazuh_api_password` | `WAZUH_API_PASSWORD` | `docker-compose.yml.j2`, `wazuh.yml.j2` |
| `wazuh_indexer_password` | `WAZUH_INDEXER_PASSWORD` | `docker-compose.yml.j2` |
| `wazuh_dashboard_password` | `WAZUH_DASHBOARD_PASSWORD` | `docker-compose.yml.j2` |

### Changing the Shuffle webhook
The Wazuh-to-Shuffle integration URL is in `wazuh-ossec.conf.j2`:
```xml
<integration>
  <name>shuffle</name>
  <hook_url>http://{{ inventory_hostname }}:3001/api/v1/hooks/webhook_2a43dcae-...</hook_url>
  <level>3</level>
  <alert_format>json</alert_format>
</integration>
```
The IP is injected automatically. If the webhook ID changes, update it here and rerun Ansible.

### MISP integration script
`custom-misp.py.j2` is currently a placeholder that allows Wazuh manager to start
without errors. The actual integration logic needs to be implemented by whoever
manages the Wazuh/MISP side of the stack. Once implemented, update the template
and rerun Ansible — it will be deployed automatically on the next run.