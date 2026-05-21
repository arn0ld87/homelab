# Grafana-Dashboards

JSON-Definitionen für alle Dashboards in diesem Homelab. **Source of Truth =
diese Files**, nicht die UI. Wer in Grafana etwas baut, exportiert es hierher
und committet.

## Inhalt

| Datei | UID | Zweck | Datasource(s) |
|---|---|---|---|
| `cachyos-host.json` | `cachyos-host` | Erstes Lern-Dashboard, nur CachyOS (CPU/RAM/Disk-Write) | Prometheus |
| `multi-host-overview.json` | `multi-host-overview` | CPU/RAM/Disk/Net/Load/Uptime für **cachyos + vps** nebeneinander, Host-Filter | Prometheus |
| `network-traffic.json` | `network-traffic` | Per-Interface RX/TX in Mbit/s, Errors, Drops, TCP-Conn, Conntrack | Prometheus |
| `disk-storage.json` | `disk-storage` | Filesystem % full, freie GB, IOPS, I/O-Saturation, Inodes (multi-host) | Prometheus |
| `logs-overview.json` | `logs-overview` | Loki: Log-Volume + Error-Rate pro Host, Top-Quellen, Live-Errors | Loki |
| `alerts-health.json` | `alerts-health` | Aktive Alerts, `up`-Status aller Targets, Scrape-Health, TSDB-Series | Prometheus |

## Auto-Provisioning

Dashboards und Datasources werden beim Grafana-Start **automatisch geladen**.
Kein manueller Import nötig. Ablauf:

1. `docker compose up -d` im `configs/monitoring/grafana/`-Ordner
2. Grafana liest beim Start:
   - `provisioning/datasources/datasources.yml` → legt Prometheus + Loki an
   - `provisioning/dashboards/dashboards.yml` → registriert den File-Provider
3. File-Provider scannt alle 30 s `dashboards/*.json` und sync't sie in den
   Folder „Homelab".

Datasource-UIDs sind **fest** (`prometheus`, `loki`) und in
`provisioning/datasources/datasources.yml` zentral definiert. Alle
Dashboards verweisen direkt darauf — keine Datasource-Variable mehr nötig.

## Aufruf

Nach `docker compose up -d` direkt:

| Dashboard | URL |
|---|---|
| Multi-Host Overview | http://localhost:3001/d/multi-host-overview |
| Network Traffic | http://localhost:3001/d/network-traffic |
| Disk & Storage | http://localhost:3001/d/disk-storage |
| Logs Overview | http://localhost:3001/d/logs-overview |
| Alerts & Health | http://localhost:3001/d/alerts-health |
| CachyOS Host (Lern-Dashboard) | http://localhost:3001/d/cachyos-host |

Im Tailnet: `100.95.132.54` statt `localhost`.

## Wenn eine alte manuelle Datasource existiert

Falls in Grafana noch eine händisch angelegte Prometheus-Datasource liegt
(z. B. UID `cfmoy44jnnv28b` aus der Lern-Phase): Connections → Data Sources
in der UI öffnen, die manuelle löschen. Die provisionierte (UID `prometheus`,
markiert als „provisioned") übernimmt automatisch.

## Host-Templating

Die Dashboards filtern über das **Prometheus-Label `host`**, das in
`prometheus.yml` pro `static_configs`-Block gesetzt wird:

```yaml
- targets: ['localhost:9100']
  labels:
    host: 'cachyos'
- targets: ['100.92.62.9:9100']
  labels:
    host: 'vps'
```

Loki-Dashboards filtern über das **Loki-Label `host`**, das in der
Promtail-Job-Config pro Host gesetzt ist (`host=cachyos` bzw. `host=vps`).

## Änderungen committen

1. JSON im Repo anpassen (oder neu in Grafana bauen → **Share → Export → Save
   to file** → in den `dashboards/`-Ordner kopieren).
2. Innerhalb 30 s übernimmt der File-Provider den Stand.
3. UI-Edits, die nicht im JSON landen, gehen beim nächsten Sync verloren.

## PromQL-Bausteine, die hier wiederkehren

- **CPU %**: `100 - (avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)`
- **RAM used %**: `(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100`
- **FS used %**: `(1 - (node_filesystem_avail_bytes{...} / node_filesystem_size_bytes{...})) * 100`
- **Net RX MB/s**: `rate(node_network_receive_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[5m]) / 1024 / 1024`
- **Up-Status**: `up{job="node_exporter"}`
- **Firing Alerts**: `ALERTS{alertstate="firing"}`
