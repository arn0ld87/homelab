---
title: Homelab Setup — IST-Stand
slug: homelab-setup-ist
version: 1.0.0
status: lebend
date: 2026-05-21
author: Alexander Schneider
scope: Beschreibung des laufenden Setups (Hosts, Dienste, Volumes, Versionen, Konfiguration)
reading_time: ~25 min
---

# Homelab Setup — IST-Stand

## 1. Was steht hier

Das ist die **lebende Beschreibung** des laufenden Homelab-Setups — was wo läuft, welche Datei zu welchem Container gehört, welche Pfade auf welchem Host liegen. Kein Wieder-Aufbau-Plan (siehe `docs/runbooks/homelab-recovery.md`), kein Roadmap-Dokument (siehe `specs/`).

**Update-Zyklus:** bei jedem nicht-trivialen Change (neuer Dienst, Pfadwechsel, Image-Pin, Retention-Anpassung). Source of Truth = diese MD, HTML ist 1:1-Spiegel.

## 2. Hosts

### cachyos — Monitoring-Server, AGH-Primary, Backrest-Server

| Feld | Wert |
|---|---|
| Rolle | Monitoring-Stack, AdGuard-Home DNS-Primary, Backrest-Server, ntopng-Sniffer |
| Hardware | Desktop (ASUS) |
| OS | CachyOS (Arch-basiert) |
| Kernel | TBD |
| Tailnet-IP | `100.95.132.54` |
| Tailnet-Alias | `cachyos` / `asus` |
| LAN-IP-Hinweis | private FritzBox-Range (Klartext nicht im Repo) |
| CPU / RAM / Disk | TBD |
| SSH-Alias | `cachyos` |

### server-ops — Alertmanager, AGH-Fallback, Backrest-Client

| Feld | Wert |
|---|---|
| Rolle | Alertmanager, AdGuard-Home Fallback, Backrest-Multihost-Client, agh-sync-Origin |
| Hardware | Contabo VPS (DE) |
| OS | Debian-LTS (Ubuntu 24.04 lt. Resume-Journal — TBD verifizieren) |
| Kernel | TBD |
| Tailnet-IP | `100.92.62.9` |
| Tailnet-Alias | `tail` |
| LAN-IP-Hinweis | nur Tailnet + öffentliches eth0 (WAN-IP nicht im Repo) |
| CPU / RAM / Disk | TBD |
| SSH-Alias | `tail` |

### FritzBox 7520 — LAN-Gateway

| Feld | Wert |
|---|---|
| Rolle | LAN-Gateway, DHCP, Modem |
| Hardware | AVM FritzBox 7520 |
| DHCP-DNS-Override | zeigt auf cachyos-LAN-IP (siehe Adblock-Journal Schritt 9) |
| SPAN / NetFlow | nicht vorhanden — ntopng sieht keinen LAN-internen Cross-Talk |

## 3. Tailnet-Topologie

```
┌─────────────────────────────────────────────────────────────────────┐
│ Tailnet (100.64.0.0/10)                                             │
│                                                                     │
│  ┌──────────────────────────┐      ┌──────────────────────────┐    │
│  │ cachyos                  │      │ server-ops               │    │
│  │ 100.95.132.54            │◀────▶│ 100.92.62.9              │    │
│  │                          │      │                          │    │
│  │ Monitoring-Server:       │      │ Alerting + Fallback:     │    │
│  │  Prometheus  :9090       │      │  Alertmanager  :9093     │    │
│  │  Grafana     :3001       │      │  node_exporter :9100     │    │
│  │  Loki        :3100       │      │  Promtail (push→Loki)    │    │
│  │  Promtail                │      │                          │    │
│  │  ntopng      :3002       │      │ Backrest 1.13.0 :9898    │    │
│  │  node_exporter :9100     │      │   (Multihost-Client)     │    │
│  │                          │      │                          │    │
│  │ Backup-Server:           │      │ DNS-Fallback:            │    │
│  │  Backrest 1.13.0 :9898   │      │  AdGuard Home :3000      │    │
│  │   → rclone → gdrive      │      │   (Standby)              │    │
│  │                          │      │                          │    │
│  │ DNS-Primary:             │      │ agh-sync (Origin → Replica) │
│  │  AdGuard Home :53/:3000  │      │                          │    │
│  └──────────────────────────┘      └──────────────────────────┘    │
│         ▲                                                           │
│         │ DHCP-DNS-Override (LAN)                                   │
│  ┌──────┴───────────────────┐                                       │
│  │ FritzBox 7520            │                                       │
│  │ - LAN-Gateway            │                                       │
│  │ - kein SPAN, kein NetFlow│                                       │
│  └──────────────────────────┘                                       │
└─────────────────────────────────────────────────────────────────────┘
```

- **MagicDNS:** aktiv. Global Nameserver = `100.95.132.54` (cachyos-AGH) lt. Adblock-Journal Schritt 10.
- **Exit-Node:** TBD (nicht aus Repo belegt).
- **Subnet-Routes:** TBD (nicht aus Repo belegt).

### Service-Map (Wo läuft was auf welchem Port)

| Dienst | Host | Port | Rolle | Quelle |
|---|---|---|---|---|
| Prometheus | cachyos | 9090 | TSDB + Scraper | [docker-compose.yml](configs/monitoring/prometheus/docker-compose.yml) |
| Grafana | cachyos | 3001 | UI (Default 3000 belegt durch AGH) | [docker-compose.yml](configs/monitoring/grafana/docker-compose.yml) |
| Loki | cachyos | 3100 | Log-Aggregation | [docker-compose.yml](configs/monitoring/loki/docker-compose.yml) |
| Promtail | cachyos + server-ops | 9080 (interne HTTP) | Journal + Docker-Logs → Loki | [cachyos](configs/monitoring/loki/promtail-config.yml), [server-ops](configs/monitoring/vps-agents/promtail/promtail-config.yml) |
| ntopng | cachyos | 3002 | Flow-Analyse `wlan0` | [docker-compose.yml](configs/monitoring/ntopng/docker-compose.yml) |
| node_exporter | beide | 9100 | Host-Metriken | [docker-compose.yml](configs/monitoring/node_exporter/docker-compose.yml) |
| Alertmanager | server-ops | 9093 | ntfy + Telegram | [docker-compose.yml](configs/monitoring/alertmanager/docker-compose.yml) |
| Backrest | beide | 9898 | restic-UI (cachyos=Server, server-ops=Client) | [compose.yaml](configs/monitoring/backrest/compose.yaml) |
| AdGuard Home | cachyos (Primary) | 53/3000 | DNS + Adblock | [docker-compose.yml](configs/agh-cachyos/docker-compose.yml) |
| AdGuard Home | server-ops (Fallback) | 53/3000 | DNS-Fallback + Sync-Origin | nicht im Repo (bare-metal) |
| agh-sync | server-ops | — | Push Origin → Replica alle 5 min | [docker-compose.yml](configs/agh-sync/docker-compose.yml) |

## 4. Dienste im Detail

### 4.1 Monitoring-Stack

#### Prometheus

- **Compose:** [configs/monitoring/prometheus/docker-compose.yml](configs/monitoring/prometheus/docker-compose.yml)
- **Image:** `prom/prometheus:latest` (kein Pin)
- **Network:** `network_mode: host` — bindet an Host-Interfaces auf `:9090`
- **Volumes:**
  - `./prometheus.yml` → `/etc/prometheus/prometheus.yml:ro`
  - `./alert-rules.yml` → `/etc/prometheus/alert-rules.yml:ro`
  - Named Volume `tsdb` → `/prometheus` (TSDB-Daten, UID 65534)
- **Retention:** `--storage.tsdb.retention.time=15d`, `--storage.tsdb.retention.size=2GB`
- **Scrape-Config:** [prometheus.yml](configs/monitoring/prometheus/prometheus.yml) — Jobs `node_exporter` (cachyos+vps) und `prometheus` (self).
- **Alert-Rules:** [alert-rules.yml](configs/monitoring/prometheus/alert-rules.yml) — `TargetDown`, `HighCpuUsage`, `LowMemory`, `DiskFillingUp`.
- **Alertmanager-Ziel:** `100.92.62.9:9093` (server-ops via Tailnet).

#### Grafana

- **Compose:** [configs/monitoring/grafana/docker-compose.yml](configs/monitoring/grafana/docker-compose.yml)
- **Image:** `grafana/grafana:latest`
- **Network:** `network_mode: host`, gebunden via `GF_SERVER_HTTP_PORT=3001`
- **Volumes:**
  - Named Volume `grafana-data` → `/var/lib/grafana`
  - `./provisioning` → `/etc/grafana/provisioning:ro`
  - `./dashboards` → `/var/lib/grafana/dashboards:ro`
- **Default-Login:** `admin/admin` — Pflicht-Wechsel beim ersten Aufruf (jetzt erledigt, neues Passwort liegt in NordPass — nicht im Repo).
- **Provisioning:**
  - Datasources: [datasources.yml](configs/monitoring/grafana/provisioning/datasources/datasources.yml)
    - `Prometheus` (UID `prometheus`, default, `http://localhost:9090`)
    - `Loki` (UID `loki`, `http://localhost:3100`)
    - `deleteDatasources` räumt Lern-Phase-Reste (`cfmoy44jnnv28b` etc.) weg.
  - Dashboards: [dashboards.yml](configs/monitoring/grafana/provisioning/dashboards/dashboards.yml) — File-Provider, Folder `Homelab`, Reload alle 30 s.
- **Dashboards** (alle in [configs/monitoring/grafana/dashboards/](configs/monitoring/grafana/dashboards/)):

| Datei | UID | Direkt-Link |
|---|---|---|
| `cachyos-host.json` | `cachyos-host` | `/d/cachyos-host` |
| `multi-host-overview.json` | `multi-host-overview` | `/d/multi-host-overview` |
| `network-traffic.json` | `network-traffic` | `/d/network-traffic` |
| `disk-storage.json` | `disk-storage` | `/d/disk-storage` |
| `logs-overview.json` | `logs-overview` | `/d/logs-overview` |
| `alerts-health.json` | `alerts-health` | `/d/alerts-health` |

#### Loki + Promtail

- **Compose:** [configs/monitoring/loki/docker-compose.yml](configs/monitoring/loki/docker-compose.yml)
- **Image:** `grafana/loki:latest`, `grafana/promtail:latest`
- **Network:** beide `network_mode: host`
- **Loki-Config:** [loki-config.yml](configs/monitoring/loki/loki-config.yml)
  - Single-binary, Filesystem-Storage (Named Volume `loki-data` → `/loki`)
  - Schema v13, `tsdb`-Index, 24 h Index-Periode
  - `retention_period: 168h` (7 Tage)
  - `ingestion_rate_mb: 16`, `max_global_streams_per_user: 5000`
- **Promtail-Config (cachyos):** [promtail-config.yml](configs/monitoring/loki/promtail-config.yml)
  - Job `journal` — `/var/log/journal`, labels `job=systemd-journal host=cachyos`
  - Job `docker` — Docker-Socket-Discovery, label `container=<name>`
- **Promtail-Config (server-ops):** [vps-agents/promtail/promtail-config.yml](configs/monitoring/vps-agents/promtail/promtail-config.yml)
  - Push-Ziel `http://100.95.132.54:3100/loki/api/v1/push`
  - Job `journal`, `host=vps`
  - Job `docker` mit Force-Label `host=vps`

#### Alertmanager

- **Compose:** [configs/monitoring/alertmanager/docker-compose.yml](configs/monitoring/alertmanager/docker-compose.yml) (auf server-ops)
- **Image:** `prom/alertmanager:latest`
- **Network:** `network_mode: host`, `:9093`, `user: "0:0"` (chmod-600-Config lesen)
- **Config-Template:** [alertmanager.yml.tpl](configs/monitoring/alertmanager/alertmanager.yml.tpl) — wird beim Container-Start via `envsubst` aus `.secrets.env` zu `/tmp/alertmanager.yml` gerendert.
- **Volumes:** Named Volume `alertmanager-data` → `/alertmanager`
- **Route:** single `receiver: all-channels`, `group_by: [alertname, host]`, `repeat_interval: 4h`, Inhibit `critical → warning` (gleiche `alertname`+`host`).
- **Receiver-Channels:**
  - **ntfy:** `https://ntfy.sh/${NTFY_TOPIC}`, `send_resolved: true` — **roher JSON-Push** (Loose End: hübsche Titel via `alertmanager-webhook-ntfy` o. Ä. offen).
  - **Telegram:** Bot via `${TELEGRAM_BOT_TOKEN}` + `${TELEGRAM_CHAT_ID}`, HTML-Template mit Status/Host/Severity/Summary.
- **Priority-Routing (geplant, NICHT in Repo):** das im Prompt erwähnte Mapping `critical → high+rotating_light`, `warning → default`, `resolved → low+check_mark` ist Teil der offenen ntfy-Bridge-Arbeit — aktuell nur `send_resolved` ohne explizite Priorities.

#### node_exporter

- **Compose (cachyos + server-ops identisch):** [docker-compose.yml](configs/monitoring/node_exporter/docker-compose.yml)
- **Image:** `prom/node-exporter:latest`
- **Network:** `network_mode: host`, `pid: host`
- **Mounts:** `/proc`, `/sys`, `/` jeweils read-only nach `/host/...`
- **Filesystem-Filter:** schließt `/sys`, `/proc`, `/dev`, `/host`, `/etc` aus.

#### ntopng

- **Compose:** [configs/monitoring/ntopng/docker-compose.yml](configs/monitoring/ntopng/docker-compose.yml)
- **Image:** `ntop/ntopng:latest`, `--community`
- **Network:** `network_mode: host`, Caps `NET_ADMIN` + `NET_RAW` (Promiscuous Mode)
- **Sniffer-Interface:** `--interface=wlan0`
- **Was es NICHT sieht:** FritzBox-internen LAN-Traffic (kein SPAN/Port-Mirror). Sieht im WLAN-Treiber-Modus oft nur eigenen Traffic.
- **Web-UI:** `:3002`, Default-Login `admin/admin` → Pflicht-Wechsel.
- **Volumes:** Named Volume `ntopng-data` → `/var/lib/ntopng`.

### 4.2 Backup-Stack

#### Backrest (restic-UI)

- **Compose:** [configs/monitoring/backrest/compose.yaml](configs/monitoring/backrest/compose.yaml)
- **Image:** `garethgeorge/backrest:latest` (Stand 2026-05-21: **Version 1.13.0** auf beiden Hosts — Multihost-Voraussetzung)
- **Port:** `100.95.132.54:9898:9898` — **explizit auf Tailnet-IP gebunden**, nicht `0.0.0.0`
- **Multihost-Pairing:** cachyos = Server, server-ops = Client (Pairing-Token zwischen beiden, beide Repos in einer UI).
- **Restic-Repos:**

| Repo-Name | Host | Drive-Pfad |
|---|---|---|
| `alex` | server-ops (VPS) | `gdrive:alexle135-backrest-backup` |
| `cachyos` | cachyos | `gdrive:homelab-backups-restic/cachyos` |

- **Schedule:** TBD — Backrest hält Schedule in seiner internen Config-DB unter `./config/config.json` (Bind-Mount), nicht in YAML im Repo. Aus dem Resume-Journal nur: Forget-Policies für beide Repos sind definiert, konkrete Cron-Expression nicht repo-belegt.
- **Retention / Forget-Policy:** TBD (Forget-Policies sind aktiv, Werte liegen in der Backrest-DB).
- **Bind-Mounts (cachyos):**
  - `./data` → `/data` (Backrest-State)
  - `./config` → `/config` (Backrest-DB inkl. Schedule + Forget-Policy)
  - `./cache`, `./restic-cache`
  - `/home/alex/.config/rclone` → `/root/.config/rclone:ro` (rclone-OAuth gemeinsam mit Host)
  - Backup-Quellen read-only: `/etc`, `/home/alex`, `/var/lib/docker/volumes` → `/mnt/host/...`
- **gdrive-OAuth:**
  - Eigenes Google-Cloud-Projekt `temporal-state-497009-n0`, OAuth-App auf **„In Production"** seit 2026-05-21.
  - **Token-Falle vermieden:** Solange die OAuth-App im „Testing"-Status ist, läuft der Refresh-Token nach **7 Tagen** ab → Backup stirbt stumm. Seit Production-Status kein 7-Tage-Tod mehr (siehe RESUME-HOMELAB-SPRINT.md Zeile 56).
  - **Restore-Henne-Ei:** Repo-Passphrasen + Google-Konto-Login liegen in NordPass, nicht im Backup. Klartext-Passphrasen-Files mit `shred -uz` entsorgt.

#### Legacy: rclone → gdrive (systemd-Timer)

Parallel zum Backrest existieren **systemd-Units** für ein eigenes rclone-basiertes Backup. Im Hintergrund deaktiviert/abgelöst durch Backrest:

- **CachyOS:** [homelab-backup.sh](configs/monitoring/backup/homelab-backup.sh), [.service](configs/monitoring/backup/homelab-backup.service), [.timer](configs/monitoring/backup/homelab-backup.timer)
  - Ziel: `gdrive:homelab-backups/cachyos/<DATE>/`
  - Schedule: `OnCalendar=*-*-* 03:00:00`, `RandomizedDelaySec=30min`
  - Retention: 30 Tage in Drive, lokal nichts (`mktemp`)
  - Sichert: Docker-Volumes (`prometheus_tsdb`, `loki_loki-data`, `grafana_grafana-data`), AGH-Configs, Compose-Files
- **VPS:** [homelab-backup-vps.sh](configs/monitoring/backup/homelab-backup-vps.sh), [.service](configs/monitoring/backup/homelab-backup-vps.service), [.timer](configs/monitoring/backup/homelab-backup-vps.timer)
  - Ziel: `gdrive:homelab-backups/vps/<DATE>/`
  - Schedule: `OnCalendar=*-*-* 03:30:00` (versetzt zu CachyOS)
  - Sichert: `alertmanager_alertmanager-data`-Volume + Bind-Mounts `agh`, `agh-sync`, `monitoring`
- **Status:** Backrest ist Primary, der rclone-Timer ist Backup-of-Backup-Mechanik bzw. historisch. TBD: ob die Timer aktuell auf den Hosts aktiv sind (`systemctl list-timers` auf Hosts prüfen).

### 4.3 DNS / AdGuard

#### Primary: cachyos-AGH

- **Compose:** [configs/agh-cachyos/docker-compose.yml](configs/agh-cachyos/docker-compose.yml)
- **Image:** `adguard/adguardhome:latest`
- **Network:** `bridge` (Default), Ports `53:53/tcp`, `53:53/udp`, `3000:3000/tcp` explizit gemappt
- **Bind-Mounts (Host-Pfade auf cachyos):**

| Host | Container | Zweck |
|---|---|---|
| `/home/alex/adguard/conf/` | `/opt/adguardhome/conf/` | `AdGuardHome.yaml`, Filterlisten |
| `/home/alex/adguard/work/` | `/opt/adguardhome/work/` | Querylog, Stats-DB, Filter-Cache |

- **Migrationsstatus:** Compose-File ist 1:1-Spiegel des bisherigen `docker run`. Migration ausstehend → Loose End.
- **Filterlisten** (aus Adblock-Journal):
  - AdGuard DNS filter
  - AdAway (`https://adaway.org/hosts.txt`)
  - OISD Big
  - HaGeZi Pro
  - Steven Black (aus VPS-Sync)
- **Custom-Rules:** TBD (liegen in `AdGuardHome.yaml`, nicht im Repo).
- **Upstreams:** Quad9 DoH (`https://dns10.quad9.net/dns-query`), Bootstrap `9.9.9.10`.
- **Encrypted DNS Serving:** DoT/DoH/DoQ-Ports sind im Compose als Kommentar vorbereitet, aber **nicht aktiv** — AGH dient lokal nur Plain DNS auf `:53`.
- **DoT-Outbound-Lernpunkt:** wiederholte Timeouts zu Quad9/Cloudflare in Loki sichtbar — Diagnose offen (Loose End, vermutlich IPv6-Routing oder MTU).

#### Fallback: server-ops-AGH

- **Compose:** **nicht im Repo** — läuft bare-metal/`docker run` auf server-ops. Bind-Mounts unter `/home/admin/agh/{conf,work}` (lt. Adblock-Journal Schritt 2).
- **Rolle:** Sync-**Origin** (Master), nicht Replica. agh-sync läuft auf demselben Host und pusht Origin → cachyos.
- **Upstream:** Quad9 DoT (`tls://dns.quad9.net`) + Cloudflare DoT als Fallback, Bootstrap `9.9.9.9, 1.1.1.1` (laut Diff im Adblock-Journal Schritt 6).

#### agh-sync

- **Compose:** [configs/agh-sync/docker-compose.yml](configs/agh-sync/docker-compose.yml) — läuft auf server-ops
- **Image:** `ghcr.io/bakito/adguardhome-sync:latest`
- **Quelle für Tokens:** [.env.example](configs/agh-sync/.env.example) — echte `.env` ist `chmod 600`, **gitignored**
- **Schedule:** `CRON=*/5 * * * *` (alle 5 Minuten)
- **Synchronisiert:** Filter, Clients, DNS-Server-Config, DNS-Rewrites
- **Bleibt pro Knoten lokal:** General-Settings, Query-Log-Config, Stats-Config, Services

#### Querylog → Loki

- **Status:** **NICHT verdrahtet**. Loose End. Aktuell kein zweiter Promtail-Job für `/opt/adguardhome/work/data/querylog.json`. Geplant für VPS- und CachyOS-AGH.

### 4.4 Netzwerk-Flow / ntopng

- **Sniffer-Interface:** `wlan0` (cachyos)
- **Sichtbar:** eigener WLAN-Verkehr von cachyos, evtl. Multicast/Broadcast im WLAN-Segment
- **NICHT sichtbar:**
  - LAN-internen Cross-Talk (z. B. IoT ↔ Apple TV ↔ Drucker) — FritzBox 7520 hat keinen Port-Mirror/SPAN.
  - Verkehr anderer WLAN-Clients (WLAN-Treiber zeigt im Promiscuous-Mode oft nur eigenen Traffic).
- **Workaround für LAN-Sicht:** Managed Switch mit Port-Mirror (z. B. Mikrotik CRS112) — nicht angeschafft.

## 5. Verzeichnis-Layout auf den Hosts

### cachyos

| Pfad | Inhalt |
|---|---|
| `/home/alex/monitoring/prometheus/` | Compose + `prometheus.yml` + `alert-rules.yml` |
| `/home/alex/monitoring/grafana/` | Compose + `provisioning/` + `dashboards/` |
| `/home/alex/monitoring/loki/` | Compose + `loki-config.yml` + `promtail-config.yml` |
| `/home/alex/monitoring/node_exporter/` | Compose |
| `/home/alex/monitoring/ntopng/` | Compose |
| `/home/alex/adguard/conf/` | AGH-Config (`AdGuardHome.yaml`) |
| `/home/alex/adguard/work/` | AGH-Querylog, Stats-DB, Filter-Cache |
| `/var/lib/docker/volumes/prometheus_tsdb/_data/` | Prometheus-TSDB (UID 65534) |
| `/var/lib/docker/volumes/loki_loki-data/_data/` | Loki-Chunks |
| `/var/lib/docker/volumes/grafana_grafana-data/_data/` | Grafana-DB (SQLite) |
| `/var/lib/docker/volumes/ntopng-data/_data/` | ntopng-State |
| `/home/alex/.config/rclone/` | rclone-OAuth (Drive-Token), gemeinsam mit Backrest |
| Backrest-Bind-Mount-Pfad cachyos | TBD (vermutlich `/home/alex/backrest/{data,config,cache,restic-cache}`, nicht hart belegbar) |

### server-ops

| Pfad | Inhalt |
|---|---|
| `/home/admin/agh/conf/` | VPS-AGH-Config (Primary) |
| `/home/admin/agh/work/` | VPS-AGH-Querylog |
| `/home/admin/agh-sync/` | agh-sync Compose + `.env` (`chmod 600`) |
| `/home/admin/monitoring/alertmanager/` | Compose + `.secrets.env` (`chmod 600`) + Template |
| `/home/admin/monitoring/node_exporter/` | Compose |
| `/home/admin/monitoring/promtail/` | Compose + `promtail-config.yml` |
| `/var/lib/docker/volumes/alertmanager_alertmanager-data/_data/` | Alertmanager-State |
| Backrest-Bind-Mount-Pfad server-ops | TBD (vermutlich `/home/admin/backrest/...`, nicht hart belegbar) |

## 6. Secrets-Strategie

- **`.env`-Files:** chmod 600, gitignored via `.gitignore` (Pattern `.env`, `.env.*`, Ausnahme `.env.example`).
- **Templates im Repo:** [agh-sync/.env.example](configs/agh-sync/.env.example), Alertmanager-Template `alertmanager.yml.tpl` (Platzhalter `${NTFY_TOPIC}`, `${TELEGRAM_BOT_TOKEN}`, `${TELEGRAM_CHAT_ID}`).
- **Restic-Passphrasen:** **NordPass** ist Single Source of Truth — pro Repo ein Eintrag. Klartext-Files mit `shred -uz` entsorgt (RESUME-HOMELAB-SPRINT, 2026-05-21).
- **Google-Konto-Login (rclone-OAuth):** NordPass.
- **Grafana-Admin-Passwort:** beim ersten Login geändert, neuer Wert in NordPass — `GF_SECURITY_ADMIN_PASSWORD=admin` im Compose ist nur Default für Erst-Bootstrap und sollte nach Login nicht mehr gelten.
- **AGH-Web-UI-Passwörter:** beide AGH-Instanzen haben eigene Login, in NordPass.
- **Token-Validity-Falle:** gdrive-OAuth-App auf „In Production" — kein 7-Tage-Token-Tod mehr.

## 7. Update-Pfade

Allgemein: `docker compose pull && docker compose up -d` im jeweiligen Compose-Ordner. Bei `:latest`-Tags kann jeder `pull` Breaking-Changes ziehen.

| Komponente | Update-Befehl | Owner | Downtime erwartet |
|---|---|---|---|
| Prometheus | `cd /home/alex/monitoring/prometheus && docker compose pull && docker compose up -d` | Alex | ~5 s (Scrape-Lücke) |
| Grafana | `cd /home/alex/monitoring/grafana && docker compose pull && docker compose up -d` | Alex | ~10 s (UI offline) |
| Loki + Promtail | `cd /home/alex/monitoring/loki && docker compose pull && docker compose up -d` | Alex | ~5 s (Log-Lücke OK, reject_old_samples=false) |
| Alertmanager (server-ops) | `cd /home/admin/monitoring/alertmanager && docker compose pull && docker compose up -d` | Alex | ~5 s |
| node_exporter | `cd .../node_exporter && docker compose pull && docker compose up -d` | Alex | ~5 s (Scrape-Lücke) |
| ntopng | `cd /home/alex/monitoring/ntopng && docker compose pull && docker compose up -d` | Alex | ~5 s |
| Backrest (cachyos + server-ops) | `docker compose pull && docker compose up -d` | Alex | ~10 s, **vor Update Pairing-Status sichern** (Multihost-Auth) |
| AGH cachyos | `cd /home/alex/adguard && docker compose pull && docker compose up -d` | Alex | 5–10 s DNS-Lücke — LAN-Clients fallen auf Fallback (server-ops-AGH) |
| AGH server-ops | bare-metal `docker pull && docker run` (Compose-Migration ausstehend) | Alex | ~10 s |
| agh-sync | `cd /home/admin/agh-sync && docker compose pull && docker compose up -d` | Alex | nein (Push-Job, kein Path-of-Use) |

**Grafana-Dashboards:** kein Container-Restart nötig — File-Provider scannt alle 30 s neu, JSON-Änderung greift automatisch.

**Alert-Rules:** Prometheus per `curl -X POST http://localhost:9090/-/reload` neu laden (Lifecycle ist enabled).

## 8. Monitoring-Selfcheck

Wie merkt man, dass das Monitoring selbst lebt:

| Check | Wo | Erwartung |
|---|---|---|
| Prometheus-Targets | `http://100.95.132.54:9090/targets` | alle UP, beide `host=cachyos` und `host=vps` grün |
| Loki-Ready | `curl http://100.95.132.54:3100/ready` | `ready` |
| Loki-Ingest läuft | Grafana `/d/logs-overview` Live-Errors-Panel | Logs der letzten 5 min sichtbar |
| Promtail-Push (server-ops) | Grafana Explore, LogQL `{host="vps"}` | letzte Minuten gefüllt |
| Alertmanager | `http://100.92.62.9:9093/#/status` | grün, Cluster-Status `ready` |
| ntfy-Bridge | Test-Alert via Prometheus-Rule + `amtool` | Notification kommt auf ntfy-Topic + Telegram |
| Backrest | `http://100.95.132.54:9898/` | beide Repos sichtbar (Multihost), letzter Snapshot < 24 h alt |
| Grafana-Dashboards live | `/d/multi-host-overview` | beide Hosts haben aktuelle Daten |

**Heartbeat-Alert:** TBD — kein bewusster „Watchdog"-Alert (`absent()` o. Ä.), der das Monitoring-System selbst überwacht. Loose End / nice-to-have.

## 9. Loose Ends (Stand 2026-05-21)

Aus [RESUME-HOMELAB-SPRINT.md](journals/RESUME-HOMELAB-SPRINT.md) und [CLAUDE.md](CLAUDE.md):

1. **Alertmanager-ntfy-Bridge** — aktuell roher JSON-Push, hübsche Titel + Priority-Mapping (`critical → high+rotating_light`, `warning → default`, `resolved → low+check_mark`) via `alertmanager-webhook-ntfy` o. Ä. fehlt.
2. **AGH-Query-Log → Loki** — zweiter Promtail-Job auf `/opt/adguardhome/work/data/querylog.json` (VPS + cachyos). Stand: in flight via PR #4 (lt. Prompt-Hinweis — Repo-Stand: PR-Branch noch nicht gemerged, kein zweiter Job in den Configs).
3. **CachyOS-AGH-Container Compose-Migration** — Compose-File liegt im Repo unter `configs/agh-cachyos/`, aber **Deploy** auf Host steht aus (aktueller Container ist noch `docker run`).
4. **CachyOS-AGH DoT-Timeouts** — Quad9/Cloudflare-Timeouts in Loki sichtbar, Diagnose offen (vermutlich IPv6-Routing oder MTU).
5. **Grafana-Datasource-Diskrepanz** — DB-Cleanup ist durch (id=2 `Prometheus` + id=3 `Loki`), aber User meldete „immer noch 2 Prometheus" in UI; Hard-Reload-Check + ggf. Screenshot ausstehend.
6. **Doppelte Prometheus-Datasource** (aus CLAUDE.md) — siehe oben, überschneidet sich mit Punkt 5.
7. **OAuth-App auf „In Production"** — **erledigt** (2026-05-21, RESUME-HOMELAB-SPRINT Zeile 56). Kein 7-Tage-Token-Tod mehr.
8. **MD→HTML-Pipeline** — `tools/build-singlefile.py` ist HTML→Standalone-HTML, nicht MD→HTML. Spec-Pflege erfordert manuelles HTML-Nachziehen.
9. **Backrest-Metriken-Dashboard** — Backrest exposed `/metrics` auf `:9898`, Prometheus scrapt es noch nicht.
10. **Heartbeat-Watchdog** — kein Selbst-Überwachungs-Alert für das Monitoring-System (siehe Section 8).

## 10. Was als Nächstes

Offene Specs unter [specs/](specs/):

| Spec | Status | Inhalt |
|---|---|---|
| [2026-05-20-tailnet-adblock-design.md](specs/2026-05-20-tailnet-adblock-design.md) | v0.1.1 Entwurf, alle 5 Phasen umgesetzt | Tailnet-Werbeblocker — Implementation-Loop in [Journal](journals/2026-05-20-adblock-impl.md) |
| [2026-05-20-monitoring-stack-design.md](specs/2026-05-20-monitoring-stack-design.md) | v0.1.1 Entwurf · Tutor-Modus, Phase 1–3 + Dashboards umgesetzt | Heim-Monitoring-Stack — siehe [Journal](journals/2026-05-21-monitoring-impl.md) |
| [2026-05-21-devops-control-daemon-design.md](specs/2026-05-21-devops-control-daemon-design.md) | v0.1.1 Entwurf | DevOps Control Daemon — REST-API auf Tailnet, Tailscale-Identity-Auth, Allowlist für `restart`/`pull`/`logs`. Implementation steht aus. |

Empfehlung (lt. RESUME): erst Grafana-Discrepancy klären, dann Loose Ends in Reihenfolge anpacken — ntfy zuerst, Query-Log danach, AGH-Compose-Migration und DoT-Diagnose parallel.

## 11. Changelog

| Datum | Version | Änderung |
|---|---|---|
| 2026-05-21 | 1.0.0 | Erstaufnahme des IST-Stands. |
