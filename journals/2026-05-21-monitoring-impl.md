---
title: Implementation-Journal — Heim-Monitoring-Stack
slug: monitoring-impl
date: 2026-05-21
status: complete
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

---

## 5. Loki + Promtail — Log-Aggregation

### Soll

Loki als Log-DB auf `:3100`, Promtail liest systemd-journald und
Docker-Container-Logs, pusht an Loki. Grafana bekommt Loki als zweite
Datasource für Explore-Queries.

### Ist

Compose mit beiden Services in `host`-Mode (gleicher Networking-Grund
wie Prometheus/Grafana). Promtail-Bind-Mounts:

- `/var/log/journal:/var/log/journal:ro`
- `/run/log/journal:/run/log/journal:ro`
- `/etc/machine-id:/etc/machine-id:ro`
- `/var/run/docker.sock:/var/run/docker.sock:ro`

Loki-Config: single-binary, TSDB-Storage auf Filesystem (Named Volume
`loki-data`), Retention 168 h.

### Stolperstein 13 — `entry has timestamp too old`

Beim ersten Start lehnte Loki sämtliche Container-Logs ab:

```
status=400  error="entry for stream {container=\"adguardhome\"}
   has timestamp too old: 2026-04-08T04:34:44Z,
   oldest acceptable timestamp is: 2026-05-14T03:07:18Z"
```

Promtail liest beim Start die **vollständige** Docker-Container-Log-
Datei mit. Bei lang laufenden Containern (AGH läuft seit April) sind
das Logs, die älter sind als Lokis Default-Akzeptanzfenster (`168h`).

Fix in `loki-config.yml`:

```yaml
limits_config:
  reject_old_samples: false
  retention_period: 168h
```

Retention bleibt bei 7 Tagen, alte Samples werden aber nicht mehr
verworfen — sie altern einfach aus.

Loki-Restart, 20 s warten, Labels-Check:

```bash
curl http://localhost:3100/loki/api/v1/labels
# → ["container", "service_name", "stream"]

curl http://localhost:3100/loki/api/v1/label/container/values
# → ["adguardhome", "agora", "agora-neo4j", "agora-redis",
#    "grafana", "loki", "node-exporter", "portainer",
#    "prometheus", "promtail"]
```

10 Container im Index, Pipeline läuft.

### Grafana-Datasource Loki via API

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     http://localhost:3001/api/datasources \
     -d '{"name":"Loki","type":"loki",
          "url":"http://localhost:3100","access":"proxy"}'
```

### Stichproben-Query

```
{container="adguardhome"}
```

Liefert AGH-stdout-Logs. Erwartet wären Block-Events — die loggt AGH
aber **nicht** auf stdout, sondern in den separaten Query-Log
(`/opt/adguardhome/work/data/querylog.json`). Wenn das später relevant
wird: Promtail einen zusätzlichen `static_configs` mit dem Pfad geben.

### Loose Ends gefunden (für später)

- **DNS-Upstream-Timeouts** auf CachyOS-AGH: wiederholt
  `tls://dns.quad9.net:853` und `tls://1.1.1.1:853` Timeouts. AGH auf
  CachyOS kommt nicht zuverlässig zu den DoT-Servern durch.
  Mögliche Ursachen: IPv6-Routing, MTU, oder Bootstrap-Henne-Ei.
  Sichtbar erst durch Loki-Logs. Eigene Diagnose-Session.
- **Doppelte Prometheus-Datasource** in Grafana (`Prometheus` +
  `prometheus`): Grafana-Default-Provisioning hat einen Auto-Eintrag
  gemacht. Cosmetic, beim nächsten Aufräumen einen löschen.

### Lernpunkt

- **Loki rejects old logs** als Anti-Backfill-Mechanismus. In Prod
  sinnvoll (verhindert versehentliches Wieder-Hochladen alter Daten),
  im Heim-Setup beim Onboarding lang laufender Container nervig.
  `reject_old_samples: false` schaltet das ab.
- **Promtail-Quellen sind getrennt:**
  - `journal:` liest aus journald (systemd-Units, kernel, etc.)
  - `docker_sd_configs:` Service-Discovery via Docker-Socket
  - `static_configs:` für klassische Log-Dateien per Glob-Pattern
  Mehrere `scrape_configs`-Blocks parallel möglich.
- **LogQL ist nicht PromQL.** Ähnlich aufgebaut, aber Filter-Operatoren
  sind anders: `|=` für „enthält", `|~` für Regex, `!=` für „enthält
  nicht". JSON-Parse via `| json`.

### Status

Loki + Promtail laufen, 10 Container indiziert, Grafana-Datasource
gesetzt. **Phase 2 abgeschlossen.**

---

---

## 6. ntopng — Network-Traffic auf wlan0

### Soll

ntopng als Container, hört am Host-Interface `wlan0`, Web-UI auf :3002
(3000/3001/9090 sind belegt von AGH/Grafana/Prometheus).

### Ist

Erster Pull-Versuch scheiterte:

```
docker.io/ntop/ntopng:stable: not found
```

Stolperstein 14 — der von der Spec referenzierte `:stable`-Tag
existiert nicht (mehr). Korrekter Tag laut `docker search`:
`ntop/ntopng:latest`.

Compose-File mit `network_mode: host`, `cap_add: NET_ADMIN, NET_RAW`
(statt `--privileged`), Command-Args:

```
--community  --http-port=3002  --interface=wlan0
```

Hochgefahren, Logs zeigen Threat-Intelligence-Listen geladen
(IPsum, NoCoin, Stratosphere Lab, ThreatFox, dshield) — `~110k Rules`.
Dann `Started polling on interface 'wlan0'`.

Verifikation vom Mac via Tailscale:

```bash
nc -zv 100.95.132.54 3002
# → open  ✅
```

### Erwartung vs. Realität

WLAN-Treiber zeigen oft nur eigenen Traffic in Promiscuous Mode, nicht
das ganze LAN. ntopng auf dem Desktop sieht damit den
Desktop-Eigentraffic — Lerneffekt für das NetFlow-Konzept, aber kein
LAN-weites Monitoring.

Für echte LAN-weite Sicht: Managed Switch mit Port-Mirror (z. B.
Mikrotik CRS112) zwischen FritzBox und Endgeräten. Eigenes
Hardware-Projekt.

### Lernpunkt

- **`cap_add` statt `--privileged`** — minimale Capability-Vergabe
  statt komplette Root-Eskalation. NET_ADMIN für Promiscuous-Mode-
  Setup auf Interfaces, NET_RAW für Raw-Sockets (Packet-Capture).
- **Threat-Intelligence-Feeds** kommen bei ntopng „gratis" mit:
  IPsum, ThreatFox, Stratosphere etc. werden automatisch geladen und
  matched gegen jeden Flow. Sehr nützlich für Erkennung von
  Verbindungen zu bekannten C2-Servern oder Malware-IPs.
- **`:stable` vs. `:latest` vs. fixe Version** — Tags sind Vereinbarung
  zwischen Image-Maintainer und Nutzer. Wenn ein Tag fehlt:
  `docker search` oder Image-Repo-URL checken statt blind aus
  alten Specs kopieren.

### Status

ntopng läuft, sniffed wlan0. **Phase 3 abgeschlossen.**

---

## Schluss-Status Monitoring

| Phase | Inhalt | Status |
|-------|--------|--------|
| 1 | node_exporter + Prometheus + Grafana + Dashboard | ✅ |
| 2 | Loki + Promtail + Grafana-Datasource | ✅ |
| 3 | ntopng | ✅ |

Vier Container im Monitoring-Stack:

| Service | Port | Web-UI |
|---------|------|--------|
| node_exporter | :9100 | nur `/metrics` |
| Prometheus | :9090 | http://100.95.132.54:9090 |
| Grafana | :3001 | http://100.95.132.54:3001 |
| Loki | :3100 | API nur |
| Promtail | — | nur Egress |
| ntopng | :3002 | http://100.95.132.54:3002 |

## Offen / Loose Ends (für später)

- CachyOS-AGH DNS-Upstream-Timeouts debuggen (sichtbar in Loki-Logs)
- Doppelte Prometheus-Datasource in Grafana aufräumen
- Promtail um AGH-Query-Log-Datei erweitern (für Block-Stats)
- Managed Switch für LAN-weite ntopng-Sicht (Hardware-Projekt)
- CachyOS-AGH-Container auf `docker compose` migrieren (loose end aus Adblock-Phase)

## Changelog

| Datum       | Änderung                                                          |
|-------------|-------------------------------------------------------------------|
| 2026-05-21  | Initial — Vorbereitungs-Check + node_exporter                     |
| 2026-05-21  | Schritte 3+4 — Prometheus + Grafana + Dashboard, Stolperstein 11+12, Phase 1 durch |
| 2026-05-21  | Schritt 5 — Loki + Promtail, Stolperstein 13 (timestamps too old), Phase 2 durch |
| 2026-05-21  | Schritt 6 — ntopng, Stolperstein 14 (`:stable`-Tag fehlt), Phase 3 durch, Monitoring komplett |
