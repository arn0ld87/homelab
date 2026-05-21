---
title: Heim-Monitoring-Stack
slug: monitoring-stack
version: 0.2.1
status: draft
date: 2026-05-20
author: Alexander Schneider
scope: CachyOS Desktop, Heim-LAN, FISI-Lernprojekt
reading_time: 18 min
modus: tutor
---

# Heim-Monitoring-Stack

## Ziel

Drei Phasen, drei Sichten:

- Phase 1: Host-Metriken — Prometheus + node_exporter + Grafana
- Phase 2: Logs — Loki + Promtail
- Phase 3: Netzwerk-Flows — ntopng

Alles in Docker auf dem CachyOS-Desktop. Wireshark und tcpdump bleiben
als Ad-hoc-Werkzeuge daneben, laufen nicht als Daemon.

Plan ist Tutor-Modus: ich liefere Aufbau und Erklärung, du installierst,
konfigurierst und debuggst selbst.

## FISI-Bezug

| Lernfeld | Inhalt                                       | Abgedeckt durch                       |
|----------|----------------------------------------------|---------------------------------------|
| LF 7     | IT-Systeme bereitstellen und administrieren  | Logging, Monitoring, Container-Betrieb|
| LF 9     | Netzwerkbasierte IT-Lösungen umsetzen        | NetFlow, Traffic-Analyse              |
| LF 11    | Daten systemübergreifend bereitstellen       | Time-Series-DB, Label-Konzept         |

Eignet sich als Eigenprojekt fürs Berichtsheft. Screenshots und
Konfig-Diffs pro Schritt mitschneiden — das ist später AP2-Stoff.

## Begriffe

Wenn einer davon nicht sitzt, vorher nachlesen. Sie kommen in jedem
Ops/SRE/DevOps-Interview vor.

| Begriff             | Bedeutung                                                              |
|---------------------|------------------------------------------------------------------------|
| Metrik              | Zahl über die Zeit. CPU-Last alle 15 s. Klein pro Datenpunkt.          |
| Log                 | Textuelle Zeile zu einem Ereignis. Größer, schwerer zu aggregieren.    |
| Trace               | Pfad einer Anfrage durch mehrere Systeme. Nicht in dieser Spec.        |
| Pull                | Server fragt aktiv ab. Prometheus zieht von node_exporter.             |
| Push                | Client schickt von sich aus. Loki/Promtail.                            |
| Time-Series-DB      | Datenbank für Zahlen-über-Zeit. Prometheus ist eine.                   |
| Exporter            | Programm, das Metriken im Prometheus-Format ausgibt.                   |
| PromQL              | Abfragesprache von Prometheus. SQL-artig für Zeitreihen.               |
| Label               | Schlüssel-Wert-Tag an einer Metrik. Filter-Achse.                      |
| NetFlow / IPFIX     | Protokoll, mit dem Router/Switches Verbindungs-Metadaten exportieren.  |
| Cardinality         | Anzahl unique Label-Kombinationen. Hohe Cardinality frisst Speicher.   |

## Architektur

```
┌──────────────────────────────────────────────────────────────────┐
│  CachyOS Desktop — alles in Docker, eigenes Compose-Projekt      │
│                                                                  │
│   ┌───────────────┐    ┌───────────────┐    ┌────────────────┐   │
│   │ node_exporter │───▶│  Prometheus   │◀───│   Grafana      │   │
│   │  :9100        │    │  :9090        │    │  :3000  (UI)   │   │
│   └───────────────┘    │  Pull /15s    │    └───────┬────────┘   │
│                        └───────┬───────┘            │            │
│                                │                    │            │
│   ┌───────────────┐    ┌───────▼───────┐            │            │
│   │  Promtail     │───▶│  Loki         │◀───────────┘            │
│   │  liest journal│    │  :3100        │    Datenquelle          │
│   │  + Docker-Logs│    │  Push         │                         │
│   └───────────────┘    └───────────────┘                         │
│                                                                  │
│   ┌───────────────┐                                              │
│   │  ntopng       │  eigene UI :3001, nicht in Grafana           │
│   │  :3001        │  eingebettet                                 │
│   └───────────────┘                                              │
└──────────────────────────────────────────────────────────────────┘
```

Drei Pfeile, die du erklären können solltest:

1. node_exporter ← Prometheus. Prometheus zieht. Master ist Prometheus.
2. Promtail → Loki. Promtail pusht.
3. Grafana ← Prometheus + Loki. Grafana ist nur Anzeige, kein Speicher.

### RAM-Budget

| Komponente    | RAM   | Phase |
|---------------|-------|-------|
| Prometheus    | ~250 MB | 1   |
| Grafana       | ~120 MB | 1   |
| node_exporter | ~20 MB  | 1   |
| Loki+Promtail | ~180 MB | 2   |
| ntopng        | ~200 MB | 3   |
| Summe         | ~770 MB | —   |

Disk: 5–10 GB für 30 Tage Retention mit Defaults.

## Phase 1 — Prometheus + node_exporter + Grafana

Ziel: Verstehen, wie eine Metrik vom Linux-Kernel über `node_exporter`
zu Prometheus kommt und in Grafana als Diagramm landet. Eine erste
PromQL-Abfrage selbst schreiben.

### Reihenfolge

1. `node_exporter` einzeln starten. Browser auf
   `http://localhost:9100/metrics`. Erwartet: tausende Zeilen Klartext.
2. Prometheus daneben. In `prometheus.yml` einen `scrape_config` für
   `node_exporter` eintragen. Browser auf
   `http://localhost:9090/targets`. Erwartet: `UP`. Wenn nicht: Docker-Netzwerk
   prüfen (sehen sich die Container?).
3. Erste PromQL-Abfrage in der Prometheus-UI:

   ```promql
   rate(node_cpu_seconds_total{mode="user"}[5m])
   ```

   - `node_cpu_seconds_total` ist ein Counter (steigt nur).
   - `{mode="user"}` filtert auf User-Space-CPU.
   - `rate(...)[5m]` rechnet Steigung pro Sekunde über 5 min.
   - Ergebnis: 0.0–1.0 pro Kern.
4. Grafana dazu. Browser auf `http://localhost:3000` (admin/admin).
   Prometheus als Data Source mit URL `http://prometheus:9090`. Achtung:
   Docker-DNS-Name, nicht `localhost`.
5. Eigenes Dashboard, drei Panels:
   - CPU-Last pro Kern (PromQL aus Schritt 3)
   - RAM-Belegung (`node_memory_MemAvailable_bytes`)
   - Disk-I/O (`rate(node_disk_read_bytes_total[5m])`)

   Selbst bauen, nicht importieren. Der Lerneffekt liegt im Bauen.

### Typische Fehler

- `localhost:9090` in Grafana statt `prometheus:9090`. Container haben
  getrennte Namespaces.
- Zeitbereich „Last 5 minutes" beim ersten Klick. Counter braucht
  Datenpunkte. Auf „Last 1 hour" stellen, kurz warten.
- Retention auf 90 Tage drehen ohne Disk-Rechnung. Default 15 Tage reicht.

### Verständnis-Check Phase 1

1. Warum sieht `node_exporter` keine Host-Disk-Schreibvorgänge, wenn er
   ohne Bind-Mount auf `/host/proc` startet?
2. Unterschied zwischen `rate()` und `increase()`?
3. Warum ist `user_email="…"` als Label eine schlechte Idee?

## Phase 2 — Loki + Promtail

Ziel: Verstehen, warum Logs nicht in Prometheus gehören, und wie ein
Label-basiertes Log-System funktioniert. Einen konkreten Eintrag in den
AGH-Container-Logs (aus dem Adblock-Plan) suchen.

### Reihenfolge

1. Loki-Konzept-Kapitel „Labels, Streams, Chunks" lesen. 10 Minuten,
   erspart Cardinality-Probleme später.
2. Loki + Promtail im Compose ergänzen. Promtail braucht Bind-Mounts auf
   `/var/log/journal/` und den Docker-Socket.
3. In Grafana Loki als Data Source eintragen. Explore-Tab:

   ```logql
   {container="agh-replica"} |= "blocked"
   ```

   Live-Logs des AGH-Containers, gefiltert auf Zeilen mit „blocked".
4. Korrelations-Übung: Im CPU-Dashboard einen Lastpeak suchen, per
   „View in Explore" auf Loki springen, gleichen Zeitraum prüfen. Was
   hat das System in dem Moment geloggt?

### Verständnis-Check Phase 2

1. Warum sollte die Container-ID kein Loki-Label sein?
2. Default-Retention von Loki, und wie änderst du sie?
3. Was passiert, wenn Promtail dem Log-Strom nicht hinterherkommt?

## Phase 3 — ntopng

Ziel: NetFlow/IPFIX einmal mit echten Daten gesehen haben. Top-Talker
im sichtbaren Traffic identifizieren.

### Hardware-Realität

ntopng braucht Promiscuous Mode auf einem Netz-Interface. Es sieht nur,
was es auch bekommt:

- FritzBox 7520 kann keinen SPAN-Port und exportiert kein NetFlow/IPFIX
  nativ. Damit sind die anderen LAN-Geräte für ntopng erstmal
  unsichtbar.
- Realistisch: ntopng läuft auf dem Desktop und sieht den Traffic des
  Desktops. Reicht, um das Konzept zu lernen.
- LAN-weite Sicht braucht einen kleinen Managed-Switch mit Port-Mirror
  (z. B. Mikrotik CRS112). Eigene Hardware-Anschaffung, kein
  Container-Thema.

### Verständnis-Check Phase 3

1. Unterschied NetFlow v5, NetFlow v9, IPFIX?
2. Wie heißt das Switch-Feature, das den Traffic eines Ports auf einen
   anderen kopiert? Warum brauchst du das für ntopng?
3. Auf welchem OSI-Layer arbeitet ntopng, auf welchem Wireshark?

## Ad-hoc — Wireshark und tcpdump

Beide gehören in den Werkzeugkasten, laufen aber nicht als Daemon.

- `tcpdump` über das Paketmanagement installiert. Schnelle Live-Sicht
  am Terminal.
- Wireshark GUI installiert. `.pcap`/`.pcapng` aus `tcpdump` lassen sich
  damit öffnen.

### Übung, 10 Minuten

```bash
sudo tcpdump -i <interface> -w /tmp/capture.pcap port 53
# 30 Sekunden laufen lassen, Browser benutzen, dann Strg-C
```

In Wireshark öffnen, Filter `dns.qry.name contains "doubleclick"`. Die
DNS-Anfragen, die der AGH blockt, sind sichtbar.

## PromQL — drei Abfragen zum Selber-Tippen

Selbst tippen, kein Copy-Paste. Das Tippen prägt sich ein.

```promql
# 1. CPU-Auslastung in Prozent
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

Warum `1 - idle` und nicht `user + system`? Wegen `iowait`, `steal`
und `softirq` — die zählen sonst nicht mit.

```promql
# 2. Verfügbarer RAM in MB
node_memory_MemAvailable_bytes / 1024 / 1024
```

Warum `MemAvailable` und nicht `MemFree`? Linux nutzt Page-Cache, der
als „frei" verfügbar wäre, in `MemFree` aber als belegt steht.

```promql
# 3. Disk-Schreibrate, MB/s
rate(node_disk_written_bytes_total[1m]) / 1024 / 1024
```

Warum `[1m]` und nicht `[1h]`? Größeres Window glättet, reagiert
träger auf Spitzen.

## Lerncheck

Schriftlich beantworten, fürs Berichtsheft.

1. Incident-Call, 30 Sekunden Zeit: CPU- oder I/O-Problem? Welche zwei
   PromQL-Abfragen ziehst du auf?
2. Loki vs. Elasticsearch — je ein Punkt, in dem das eine dem anderen
   überlegen ist.
3. Warum läuft das Monitoring auf CachyOS und nicht auf dem VPS? Zwei
   technische Argumente.
4. Was passiert mit einem Label, das pro User unique ist (z. B.
   Session-ID)?
5. Datenfluss „Browser ruft Webseite auf" durch das Setup — an welchen
   Stellen siehst du das in den Monitoring-Tools?

## Out of Scope

| Thema                          | Wann sinnvoll                          |
|--------------------------------|----------------------------------------|
| Suricata / Zeek (IDS)          | Eigene Spec, sobald die Basis steht    |
| Wazuh / OSSEC (SIEM/EDR)       | AP2-Projektarbeit                       |
| OpenTelemetry / Traces         | Für Web-Services, hier nicht           |
| Alertmanager                   | Phase 4                                 |
| Blackbox-Probes vom VPS aus    | Eigene Spec, wenn Heim-Setup läuft     |

## Tutor-Rollen

Was ich tue:

- Plan aktuell halten, wenn du Zwischenstände meldest
- Auf Nachfrage einzelne Befehle/Configs als Vorlage liefern
- Verständnis-Fragen beantworten, Lerncheck-Antworten gegenlesen
- Beim Debuggen helfen, wenn du beschreibst: „Phase X, Schritt Y, ich
  sehe Z, erwartet hatte ich W"

Was ich nicht tue:

- Für dich installieren oder Container starten
- Komplette fertige Configs auf einen Schlag liefern
- Befehle in deiner Shell ausführen
- Lerncheck-Antworten vorbeten

## Dashboards (Zusatz, 2026-05-21)

Phase 1 hat genau **ein** Lern-Dashboard hervorgebracht (`cachyos-host.json`,
drei Panels, nur CachyOS). Damit das Setup im Alltag tatsächlich brauchbar
wird, liegen seit 2026-05-21 fünf ergänzende Dashboards in
`configs/monitoring/grafana/dashboards/`:

| Dashboard | Zweck |
|---|---|
| `multi-host-overview` | CachyOS und VPS nebeneinander — CPU, RAM, Load, Root-FS, Net RX/TX, Uptime |
| `network-traffic` | Per-Interface RX/TX in Mbit/s, Errors, Drops, TCP/Conntrack |
| `disk-storage` | Filesystem-Füllstand pro Mount, freie GB, IOPS, I/O-Saturation, Inodes |
| `logs-overview` | Loki: Volume + Error-Rate pro Host, Top-Quellen, Live-Errors |
| `alerts-health` | Aktive Alerts, `up`-Status aller Targets, Scrape-Dauer, TSDB-Series |

Konvention: Datasource-UIDs sind **fest** (`prometheus`, `loki`) und in
`configs/monitoring/grafana/provisioning/datasources/datasources.yml`
zentral definiert. Host-Filter via Variable `$host`. Beim Container-Start
liest Grafana das Provisioning-Verzeichnis und legt Datasources +
Dashboards automatisch an — kein manueller Import. Der File-Provider
scannt alle 30 s, Änderungen an einer JSON-Datei sind innerhalb einer
halben Minute live. Details in
`configs/monitoring/grafana/dashboards/README.md`.

Warum erst jetzt: Phase 1 hat „selber bauen, nicht importieren" als Lern-
Ziel — das gilt für das erste Dashboard. Ab dem zweiten geht es nicht mehr
um den Lerneffekt, sondern darum, dass im Störfall der Blick auf die
richtige Kachel reicht.

## Changelog

| Datum       | Version | Änderung                                                |
|-------------|---------|---------------------------------------------------------|
| 2026-05-20  | 0.1.0   | Erstentwurf                                             |
| 2026-05-20  | 0.1.1   | Sprache entkitscht, Pullquote und Aha-Momente raus      |
| 2026-05-21  | 0.2.0   | Zusatz-Dashboards (multi-host, network, disk, logs, alerts) |
| 2026-05-21  | 0.2.1   | Datasource- und Dashboard-Provisioning komplett verkabelt    |
