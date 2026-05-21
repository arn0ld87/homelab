# Homelab — Host- und Container-Inventar

Single Source of Truth für Pfade, Ports, IPs, Container-Namen.
Bei Änderung diese Datei zuerst aktualisieren, dann committen.

Stand: 2026-05-21

## Hosts

| Host | Rolle | Tailscale-IP | SSH-Alias | OS | Home |
|---|---|---|---|---|---|
| Contabo VPS | Adblock-Primary, Alerting, Backup-Source | `100.92.62.9` | `tail` | Ubuntu 24.04 | `/home/admin` |
| CachyOS Desktop | Monitoring-Stack, Adblock-Replica, Backup-Server | `100.95.132.54` | `cachyos` | CachyOS (Arch) | `/home/alex` |
| Mac M-Series | Arbeitsstation | `100.121.130.100` | — | macOS | — |

SSH-User: `admin` auf VPS, `alex` auf CachyOS. Beide in `sudo` und `docker`.

## Container — tail (VPS, `/home/admin/`)

| Name | Image | Compose-Dir | Network | Wichtige Mounts |
|---|---|---|---|---|
| `agh-primary` | `adguard/adguardhome:latest` | `agh/` (vermutlich) | bridge | `/home/admin/agh/work` → `/opt/adguardhome/work`, `…/conf` → `…/conf` |
| `agh-sync` | `ghcr.io/bakito/adguardhome-sync:latest` | s. o. | bridge | — |
| `alertmanager` | `prom/alertmanager:latest` | `monitoring/alertmanager/` | host | `alertmanager.yml` → `/etc/alertmanager/` |
| `alertmanager-ntfy` | `xenrox/ntfy-alertmanager:v1.0.0` | `monitoring/alertmanager-ntfy/` | host | `config.scfg` → `/etc/ntfy-alertmanager/config` |
| `promtail` | `grafana/promtail:latest` | `monitoring/promtail/` | host | `promtail-config.yml` → `/etc/promtail/config.yml` |
| `node-exporter` | `prom/node-exporter:latest` | `monitoring/node-exporter/` | host | — |
| `backrest` | `garethgeorge/backrest:latest` | `monitoring/backup/` | bridge | `/home/admin/.config/rclone` → `/root/.config/rclone` (rw!) |

Ports auf tail (Host-Bind):
- `9093` Alertmanager UI/API
- `9094` Alertmanager Cluster
- `9095` alertmanager-ntfy Bridge (lokal, von außen unsichtbar)
- `8080` Weaviate (achtung — kollidiert mit Default-Ports vieler Tools)
- `9100` node-exporter

AGH-Querylog: `/home/admin/agh/work/data/querylog.json`

## Container — cachyos (`/home/alex/`)

| Name | Image | Compose-Dir | Network | Wichtige Mounts |
|---|---|---|---|---|
| `adguardhome` | `adguard/adguardhome` | — (`docker run`, NICHT Compose) | bridge | `/home/alex/adguard/conf` → `/opt/adguardhome/conf`, `…/work` → `…/work` |
| `loki` | `grafana/loki:latest` | `monitoring/loki/` | bridge | — |
| `grafana` | `grafana/grafana:latest` | `monitoring/loki/` (vermutlich) | bridge | — |
| `prometheus` | `prom/prometheus:latest` | `monitoring/loki/` (vermutlich) | bridge | — |
| `promtail` | `grafana/promtail:latest` | `monitoring/loki/` | bridge | `/home/alex/monitoring/loki/promtail-config.yml` → `/etc/promtail/config.yml`, `/var/log/journal`, docker.sock |
| `node-exporter` | `prom/node-exporter:latest` | `monitoring/loki/` | host | — |
| `backrest` | `garethgeorge/backrest:latest` | (eigener Stack) | bridge | `/home/alex/.config/rclone` (rw) |
| `sad_mendeleev` | `grafana/grafana:latest` | — (verwaist) | — | TODO: prüfen ob droppen |

Ports auf cachyos (Host-Bind):
- `3000` Grafana UI
- `3100` Loki (Tailscale-Interface, von tail-Promtail reachable)
- `9090` Prometheus
- `9100` node-exporter

AGH-Querylog: `/home/alex/adguard/work/data/querylog.json`

## Datenflüsse

```
                       ┌────────────────────────────┐
                       │ CachyOS (100.95.132.54)    │
                       │                            │
Prometheus ◄── scrape ─┤ prometheus → grafana       │
                       │                            │
                       │ loki :3100 ◄──┐            │
                       │               │            │
                       │ promtail ─────┤ journald,  │
                       │               │ docker.sock│
                       │ adguardhome   │            │
                       │ (Replica)     │            │
                       └───────────────│────────────┘
                                       │
                                       │ Tailscale
                                       │
                       ┌───────────────│────────────┐
                       │ VPS (100.92.62.9)          │
                       │               │            │
                       │ promtail ─────┘ journald,  │
                       │                 docker.sock│
                       │                            │
                       │ alertmanager :9093 ─┐      │
                       │                     │      │
                       │ alertmanager-ntfy ──┤      │
                       │   :9095             │      │
                       │                     ▼      │
                       │       ntfy.sh + Telegram   │
                       │                            │
                       │ agh-primary (DNS, queries) │
                       └────────────────────────────┘
```

## Repo ↔ VPS-Mapping

| Repo (Mac, `/Volumes/T7/Projekte/homelab/`) | tail | cachyos |
|---|---|---|
| `configs/monitoring/alertmanager/` | `/home/admin/monitoring/alertmanager/` | — |
| `configs/monitoring/alertmanager-ntfy/` | `/home/admin/monitoring/alertmanager-ntfy/` | — |
| `configs/monitoring/promtail/` | `/home/admin/monitoring/promtail/` | — |
| `configs/monitoring/loki/` | — | `/home/alex/monitoring/loki/` |

## Secrets-Pfade

| Datei | Inhalt | Berechtigung |
|---|---|---|
| `tail:/home/admin/monitoring/alertmanager/.secrets.env` | `NTFY_TOPIC`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | `600 admin:admin` |
| NordPass | Alle Restic-Passphrasen, OAuth-Tokens, Backrest-Multihost-Secrets | — |

## Pending / TODO

- Adguardhome auf cachyos ist `docker run`, nicht Compose → Migration nach `/home/alex/adguard/docker-compose.yml`
- `sad_mendeleev`-Container auf cachyos prüfen (verwaister Grafana?)
- DoT-Timeouts (Quad9/Cloudflare) auf cachyos-AGH diagnostizieren
- AGH-Querylog auf beiden Hosts in Loki einspeisen (zweiter Promtail-Job)
