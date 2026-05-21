---
title: Implementation-Journal — Heim-Monitoring-Stack
slug: monitoring-impl
date: 2026-05-21
status: in progress
spec: ../specs/2026-05-20-monitoring-stack-design.md
host: CachyOS Desktop (asus)
author: Alexander Schneider
---

# Implementation-Journal — Heim-Monitoring-Stack

Was tatsächlich passiert, mit Befehlen, Outputs, Fehlern, Korrekturen
und kurzen Erklärungen pro Schritt. Ergänzung zur Spec
(`../specs/2026-05-20-monitoring-stack-design.md`).

Schreibrichtung chronologisch, je Schritt: **Soll** — **Ist** —
**Lernpunkt**.

---

## 1. Vorbereitungs-Check auf CachyOS

### Soll

Vier Voraussetzungen prüfen:

- Docker installiert
- Ports 9090 (Prometheus), 9100 (node_exporter), 3001 (Grafana, statt
  Default 3000 wegen AGH-Kollision) frei
- User in `docker`-Gruppe
- Genug Disk-Platz für Retention

### Ist

```bash
sudo ss -lntp 'sport = 9090 or sport = 9100 or sport = 3001'
# → leer, alle drei Ports frei  ✅

mkdir -p /home/alex/monitoring/{prometheus,grafana,node_exporter}
ls -la /home/alex/monitoring/
# → drei leere Unterverzeichnisse  ✅

groups | grep -w docker
# → docker enthalten  ✅  (kein sudo für docker-Befehle nötig)

df -h /home/alex
# → ausreichend Platz
```

### Lernpunkt

- **Port 3000 ist belegt** durch CachyOS-AGH (Web-UI). Grafana, das
  per Default ebenfalls 3000 nutzt, mappen wir per Host-Port-Mapping
  auf **3001**. Container-intern bleibt es 3000 — Konfig ändert sich
  nicht, nur die Außenansicht. Saubere Trennung über Docker-Layer.
- **`network_mode: host` für node_exporter** ist Pflicht, nicht Stil.
  Im Bridge-Modus würde der Container nur Container-eigene Interfaces,
  PIDs und `/proc` sehen — also die Metriken der Bridge-Brücke statt
  des Host-Systems. Exakt das Gegenteil von dem, was man messen will.

---

## 2. node_exporter — standalone starten

### Soll

Ersten Container des Stacks isoliert hochfahren. Browser auf
`http://localhost:9100/metrics` zeigt Tausende Zeilen Klartext-Metriken
— das Roh-Format, das Prometheus später parst.

### Ist

*— wird ergänzt, sobald Container läuft*

### Ist

```bash
nano /home/alex/monitoring/node_exporter/docker-compose.yml
cd /home/alex/monitoring/node_exporter
docker compose up -d
docker compose ps
# → node-exporter   Up

curl -s http://localhost:9100/metrics | head -20
# → Klartext-Metriken im Prometheus-Format (go_gc_duration_seconds, …)
```

### Lernpunkt

- **`pid: host`** macht alle Prozess-IDs des Hosts im Container
  sichtbar. Ohne den Flag sähe `node_exporter` nur sich selbst als
  PID 1.
- **`/proc`, `/sys`, `/` als ro-Mounts:** Pseudo-Dateisysteme des
  Linux-Kernels sind die Datenquelle für fast alle Host-Metriken.
  CPU-Last, Speicher, Disk-I/O — alles in `/proc/stat`,
  `/proc/meminfo`, `/proc/diskstats`. node_exporter liest die nur,
  schreibt nie (deshalb `:ro`).
- **`--collector.filesystem.mount-points-exclude`** filtert
  Pseudo-Filesysteme aus den Disk-Metriken raus. Sonst würde jeder
  Container-Overlay-Mount als eigene „Festplatte" auftauchen.

---

## 3. Prometheus — TSDB + Scraper

### Soll

Bridge-Container, Port 9090 ans Host gemappt, scrape von node_exporter
alle 15 s. Web-UI auf `http://localhost:9090`.

### Ist

Zwei Bind-Mount-Stolpersteine in Folge:

### Stolperstein 11a — Bind-Mount-Ordner statt Datei

Im ersten Versuch lag `prometheus.yml` noch nicht auf dem Host, als
`docker compose up` lief. Docker hat den Bind-Source automatisch als
**Verzeichnis** angelegt:

```
mount src=/home/alex/monitoring/prometheus/prometheus.yml,
      dst=/etc/prometheus/prometheus.yml: not a directory
```

Lösung: Container down, leeren Ordner löschen, yaml-Datei via `scp`
korrekt hinterlegen, dann erneut `up`.

### Stolperstein 11b — Bridge → Host Networking blockt

Prometheus im Bridge-Mode mit `extra_hosts: host.docker.internal:
host-gateway` konnte den Host-Port 9100 nicht erreichen:

```
Get "http://host.docker.internal:9100/metrics": context deadline exceeded
```

Diagnose vom Container aus:

```bash
docker exec prometheus wget --timeout=3 http://host.docker.internal:9100/metrics
# → download timed out
```

Auf dem Host direkt war node_exporter aber erreichbar. Auf CachyOS gibt
es eine Firewall-Regel (vermutlich nftables-Standard), die
Container-Bridge → Host-Network blockiert.

Lösung: Prometheus auch in **`network_mode: host`**. Dann reden beide
Container über `localhost`, kein Bridge-Routing nötig.

Spec-Diff: Ursprünglicher Plan war Bridge mit `extra_hosts`. In dieser
Umgebung nicht funktional, also Workaround. Konsequenz: Port 9090 ist
nun ohne Docker-Port-Mapping-Schicht direkt am Host. Für Heim-LAN
akzeptabel, im Tailnet ohnehin gewollt.

### Verifikation

```bash
curl http://localhost:9090/api/v1/targets
# → localhost:9100 (node_exporter) -> up
#   localhost:9090 (prometheus self-scrape) -> up
```

### Lernpunkt

- **Bind-Mount-Pattern:** Source muss vor `docker compose up` existieren
  und den richtigen Typ haben (Datei vs. Ordner). Sonst legt Docker
  einen falschen Typ an.
- **Named Volumes vs. Bind-Mounts:** Prometheus läuft als UID 65534
  (nobody). Bind-Mount auf User-Verzeichnis braucht `sudo chown
  65534:65534`. Named Volume erledigt das automatisch. Für TSDB-Binary-
  Dateien sowieso kein Editier-Bedarf — Named Volume ist hier sauber.
- **`network_mode: host` als Notnagel:** Wenn Bridge-Host-Networking
  blockiert ist (CachyOS-Default-Firewall), spart `host` viel
  Konfig-Aufwand. Trade-off: Container-Isolation auf Netzebene weg,
  aber für rein Tailnet-erreichbare Services akzeptabel.
- **Self-Scrape:** Prometheus scraped sich selbst — nützlich für
  Meta-Monitoring (Heartbeat, Scrape-Dauer, eigene Speichernutzung).

---

## 4. Grafana — Web-UI + Datasource + Dashboard

### Soll

Grafana auf Port 3001 (3000 ist von AGH belegt), Prometheus als
Datasource, drei Panels: CPU %, RAM verfügbar GB, Disk Write MB/s.

### Ist

Compose mit `network_mode: host` + `GF_SERVER_HTTP_PORT=3001` —
beides nötig:

- `host`-Mode, damit Grafana den Prometheus auf `localhost:9090`
  erreicht (gleiches Bridge-Problem wie bei Prometheus selbst)
- `GF_SERVER_HTTP_PORT=3001`, weil Grafanas Default 3000 schon AGH
  belegt hält

Container hochgefahren, Plugins installiert (`exploretraces`,
`metricsdrilldown` — Grafana-Default seit v11), nach ~10 s antwortet
`http://localhost:3001` mit HTTP 200.

### Stolperstein 12 — Token im Chat-Log geleakt

Beim ersten Setup-Versuch wurde der Grafana-Service-Account-Token
versehentlich in Klartext in den Assistant-Chat gepostet. Das macht
ihn de-facto kompromittiert — Chat-Logs und LLM-Memory sind keine
sicheren Kanäle.

Auflösung:

1. Geleaktes Token in Grafana revoken (*Administration → Service
   accounts → Tokens*)
2. Neues Token erzeugen, **direkt** in
   `~/.grafana-token` mit `chmod 600` ablegen
3. Token niemals im Chat zitieren — ich greife via
   `ssh cachyos cat ~/.grafana-token` darauf zu

Action für die Zukunft: Secrets nie inline schicken. Token-Werte über
Datei mit restriktiven Permissions, oder Passwortmanager-Reference.

### Datasource via API

```bash
TOKEN=$(cat ~/.grafana-token)
curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     http://localhost:3001/api/datasources \
     -d '{"name":"Prometheus","type":"prometheus",
          "url":"http://localhost:9090","access":"proxy",
          "isDefault":true}'
```

Response: `datasource.uid = cfmoy44jnnv28b` ✅

### Dashboard via API

JSON-Template in `configs/monitoring/grafana/dashboards/cachyos-host.json`
versioniert, dann via POST hochgeladen:

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     http://localhost:3001/api/dashboards/db \
     -d @cachyos-host.json
```

Response:

```json
{"uid":"cachyos-host","url":"/d/cachyos-host/cachyos-host","version":1}
```

Drei Panels live, refresh alle 30 s, Zeitfenster „last 1h".

### Lernpunkt

- **Service Accounts > Personal Access Tokens** für Automation:
  Service Accounts sind unabhängig von menschlichen Logins, können
  granular berechtigt werden, und ihre Tokens haben Ablaufdaten.
- **Grafana-Provisioning via API ist idempotent:** Dashboard mit
  fester `uid` + `"overwrite": true` lässt sich immer wieder posten,
  ohne Duplikate zu erzeugen. Für CI/CD-Pipelines wichtig.
- **`GF_*`-ENV-Variablen** übersteuern jede Setting in der
  `grafana.ini`. Damit ist Grafana komplett deklarativ konfigurierbar
  ohne in den Container reinzugreifen.

### Status

Drei Container laufen, Daten fließen, Dashboard zeigt Live-Werte.
**Phase 1 abgeschlossen.**

---

## Offen

- Phase 2: Loki + Promtail (Log-Aggregation, AGH-Container-Logs als
  erste Quelle)
- Phase 3: ntopng (NetFlow auf Desktop-Traffic)
- Dashboard-JSON ins Repo committen für Versionierung
- Compose-Files committen

## Changelog

| Datum       | Änderung                                                          |
|-------------|-------------------------------------------------------------------|
| 2026-05-21  | Initial — Vorbereitungs-Check + node_exporter                     |
| 2026-05-21  | Schritte 3+4 — Prometheus + Grafana + Dashboard, Stolperstein 11+12, Phase 1 durch |
