---
title: Heim-Monitoring-Stack
slug: monitoring-stack
version: 0.1.0
status: draft
date: 2026-05-20
author: Alexander Schneider
scope: CachyOS Desktop, Heim-LAN, FISI-Lernprojekt
reading_time: 25 min
modus: tutor
---

# Heim-Monitoring-Stack

## Kicker

> **№ 02 — LERN-PLAN · STAND 20. MAI 2026**
> Lokales Monitoring auf dem CachyOS-Desktop. Drei Phasen, drei Sichten:
> Host-Metriken, Logs, Netzwerk-Flows. Aufgebaut nach Tutor-Prinzip —
> der Plan erklärt das *Warum*, du implementierst selbst.

## Lernziele

Nach Abschluss dieser Spec hast du:

- Einen funktionierenden Prometheus-Grafana-Loki-Stack auf CachyOS
- Verstanden, was **Pull-basiertes Monitoring** von Push-basiertem unterscheidet
- Ein Gefühl dafür, wann **Metriken** und wann **Logs** das richtige Werkzeug sind
- Drei eigene **PromQL**-Abfragen geschrieben und in einem Dashboard verbaut
- NetFlow/IPFIX einmal mit echten Daten gesehen statt nur im Lehrbuch
- Den Reflex, vor jedem neuen Tool zu fragen: „Was kostet das an RAM/Disk?"

### FISI-Lehrplan-Bezüge

- **Lernfeld 7** — IT-Systeme bereitstellen und administrieren (Logging, Monitoring)
- **Lernfeld 9** — Netzwerkbasierte IT-Lösungen umsetzen (NetFlow, Traffic-Analyse)
- **Lernfeld 11** — Daten systemübergreifend bereitstellen (Time-Series-DBs)

Diese Spec eignet sich als **Eigenprojekt** im Berichtsheft. Halte die
einzelnen Schritte mit Screenshots fest — das wird im Praktikum
und in der AP2 relevant.

## Was du vorher verstehen musst

Wenn du diese Begriffe nicht klar trennen kannst, lies sie kurz nach,
bevor du anfängst. Sie tauchen in jedem Job-Interview im
Ops/SRE/DevOps-Umfeld auf.

| Begriff             | Kurzdefinition                                                                                          |
|---------------------|---------------------------------------------------------------------------------------------------------|
| **Metrik**          | Eine Zahl über die Zeit. Beispiel: CPU-Last alle 15 s. Wenig Speicher pro Datenpunkt.                   |
| **Log**             | Eine textuelle Zeile zu einem konkreten Ereignis. Beispiel: "User X hat sich eingeloggt". Größer pro Eintrag. |
| **Trace**           | Pfad einer Anfrage durch mehrere Systeme. Nicht in dieser Spec — kommt später, wenn relevant.            |
| **Pull**            | Der Server fragt aktiv ab. Prometheus zieht alle 15 s von node_exporter. Vorteil: zentrale Kontrolle.    |
| **Push**            | Der Client schickt Daten von sich aus. Loki/Promtail funktioniert so. Vorteil: kurzlebige Jobs.          |
| **Time-Series-DB**  | Spezial-Datenbank für Zahlen-über-Zeit. Prometheus ist eine. Optimiert für Append-only und Aggregation.  |
| **Exporter**        | Kleines Programm, das Metriken eines Systems im Prometheus-Format ausgibt. `node_exporter` für den Host. |
| **PromQL**          | Abfragesprache von Prometheus. SQL-artig, aber für Zeitreihen.                                          |
| **Label**           | Schlüssel-Wert-Tag an einer Metrik. `cpu_seconds_total{mode="user", instance="cachyos"}`. Filter-Achse.  |
| **NetFlow / IPFIX** | Protokoll, mit dem Router/Switches Verbindungs-Metadaten exportieren. Wer redet mit wem, wie viel.       |
| **Cardinality**     | Anzahl unique Label-Kombinationen. Hohe Cardinality = explodierender Speicherbedarf. Klassische Falle.   |

> **Lern-Tipp:** Erkläre die Tabelle einmal laut, ohne auf den Text zu
> schauen. Wenn du bei einem Begriff stockst, schlag nach. Das ist die
> Vor-Pflicht für Phase 1.

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
│   │  ntopng       │  eigene UI :3001 — eigenständig, nicht in    │
│   │  :3001        │  Grafana eingebettet (Phase 2)               │
│   └───────────────┘                                              │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Drei wichtige Pfeile, die du erklären können solltest:**

1. **node_exporter ← Prometheus** — Prometheus *zieht*. Wer ist Master? Prometheus.
2. **Promtail → Loki** — Promtail *pusht*. Wer entscheidet wann? Promtail (an Logzeilen-Eingang gekoppelt).
3. **Grafana ← Prometheus & Loki** — Grafana ist nur Anzeige, kein Datenspeicher.

## Phase 1: Prometheus + Grafana + node_exporter

**Lernziel:** Du verstehst, wie eine Metrik vom Linux-Kernel über
`node_exporter` zu Prometheus kommt, dort gespeichert wird, und in
Grafana ein Diagramm wird. Du schreibst deine erste PromQL-Abfrage.

### Was du installieren wirst

| Komponente      | Image                         | RAM-Schätzung |
|-----------------|-------------------------------|---------------|
| Prometheus      | `prom/prometheus:latest`      | ~250 MB       |
| Grafana         | `grafana/grafana:latest`      | ~120 MB       |
| node_exporter   | `prom/node-exporter:latest`   | ~20 MB        |

Speicherort der Spec-Daten: `~/homelab/monitoring/` auf CachyOS.
Compose-Projekt-Name: `monitoring`.

### Schritte (in der Reihenfolge)

1. **node_exporter zuerst.** Standalone testen. Browser auf
   `http://localhost:9100/metrics` — du sollst Tausende Zeilen Text
   sehen. Das ist das Roh-Format, das Prometheus später parsen wird.
   *Aha-Moment:* Es ist Klartext, keine Zauberei.

2. **Prometheus daneben.** Compose-File mit beiden Services. In
   `prometheus.yml` einen `scrape_config` für node_exporter eintragen.
   Service starten, Browser auf `http://localhost:9090/targets` —
   node_exporter muss als „UP" erscheinen. Wenn nicht: Docker-Netzwerk
   prüfen (sehen sich die Container?).

3. **Erste PromQL-Abfrage** in der Prometheus-UI selbst, nicht in
   Grafana:

   ```promql
   rate(node_cpu_seconds_total{mode="user"}[5m])
   ```

   Verstehe **jeden Teil** dieser Zeile, bevor du weitergehst:
   - `node_cpu_seconds_total` ist ein **Counter** (steigt nur).
   - `{mode="user"}` filtert auf User-Space-CPU (nicht Kernel/IO).
   - `rate(...)[5m]` rechnet die Steigung pro Sekunde über 5 Minuten.
   - Ergebnis: CPU-Last im Bereich 0.0–1.0 pro Kern.

4. **Grafana dazu.** Container starten, Browser auf
   `http://localhost:3000` (admin/admin beim ersten Login). Prometheus
   als Data Source eintragen (`http://prometheus:9090` — der
   Docker-DNS-Name, nicht localhost).

5. **Dein erstes Dashboard.** Eine Reihe mit drei Panels:
   - CPU-Last pro Kern (PromQL aus Schritt 3)
   - RAM-Belegung (`node_memory_MemAvailable_bytes` invertiert)
   - Disk-I/O (`rate(node_disk_read_bytes_total[5m])`)

   Bau es **selbst** auf, nicht via Dashboard-Import. Der Lernwert ist
   im Bauen, nicht im Anschauen.

### Häufige Stolperfallen

- **`localhost` vs. Service-Name in Compose.** Grafana muss
  `prometheus:9090` heißen, nicht `localhost:9090`, weil sie in
  getrennten Container-Namespaces leben.
- **Zeit-Bereich in Grafana zu klein.** Beim ersten Klick stehen oft
  „Last 5 minutes" — der Counter braucht Datenpunkte, also auf
  „Last 1 hour" stellen und etwas warten.
- **Retention zu hoch gesetzt.** Default ist 15 Tage. Reicht. Wenn du
  später auf 90 Tage gehst: Disk-Plan erst nachrechnen.

### Verständnis-Check Phase 1

Wenn du diese Fragen selbst beantworten kannst, ist Phase 1 sauber
verstanden — nicht nur abgehakt:

1. *Warum kann `node_exporter` keine Disk-Schreibvorgänge im Mount
   `/host/proc` sehen, wenn du es ohne Bind-Mounts startest?*
2. *Was ist der Unterschied zwischen `rate()` und `increase()`?*
3. *Wieso ist ein Label wie `user_email="…"` eine **schlechte** Idee?*

## Phase 2: Loki + Promtail

**Lernziel:** Du verstehst, warum man Logs **nicht** in Prometheus
packt, und wie ein Label-basiertes Log-System funktioniert. Du suchst
einen konkreten Eintrag in den Docker-Logs deiner AGH-Instanz.

### Was du installieren wirst

| Komponente | Image                         | RAM-Schätzung |
|------------|-------------------------------|---------------|
| Loki       | `grafana/loki:latest`         | ~150 MB       |
| Promtail   | `grafana/promtail:latest`     | ~30 MB        |

### Schritte

1. **Konzept zuerst, Befehle danach.** Lies das Loki-Konzept-Doku-Kapitel
   („Labels, Streams, Chunks"). Das ist 10 Minuten und erspart dir
   später Cardinality-Probleme.

2. **Loki + Promtail im Compose** ergänzen. Promtail muss
   Lese-Zugriff auf `/var/log/journal/` und auf den Docker-Socket
   bekommen — beides als Bind-Mount.

3. **In Grafana Loki als Data Source eintragen.** Explore-Tab öffnen,
   Loki-Quelle wählen, Abfrage:

   ```logql
   {container="agh-replica"} |= "blocked"
   ```

   Du siehst Live-Logs des AGH-Containers, gefiltert auf Zeilen mit
   „blocked". *Aha-Moment:* Logs und Metriken sind jetzt in derselben
   UI — der Wert von Grafana wird sichtbar.

4. **Korrelations-Übung.** Geh in dein CPU-Dashboard. Wähle einen
   Zeitpunkt mit hohem CPU-Wert aus, klicke auf einen Datenpunkt,
   springe via „View in Explore" → Loki-Quelle. Was hat das System in
   genau diesem Moment geloggt? Wenn nichts → war das ein normaler
   Lastpeak oder ein Hintergrund-Job?

### Verständnis-Check Phase 2

1. *Warum sollte man die Container-ID **nicht** als Loki-Label nehmen?*
2. *Wie lange hält Loki Logs per Default? Wie würdest du das ändern?*
3. *Was passiert, wenn Promtail die Datei nicht hinterherliest
   (Backpressure)?*

## Phase 3: ntopng — Netzwerk-Sicht

**Lernziel:** Du verstehst NetFlow/IPFIX als Konzept, siehst Top-Talker
in deinem Heim-Netz und kannst sagen, welches Gerät welchen Anteil am
Traffic hat.

### Was du installieren wirst

| Komponente | Image                  | RAM-Schätzung |
|------------|------------------------|---------------|
| ntopng     | `ntop/ntopng:stable`   | ~200 MB       |

ntopng braucht **Promiscuous Mode** auf einem Netz-Interface. Das geht
auf dem CachyOS-Desktop nur, wenn er den Traffic auch *sieht* — also:

- Entweder ein **SPAN-Port** an einem Switch (FritzBox kann das nicht
  → kommt für später ins Auge, wenn du einen kleinen Managed-Switch
  dazwischen stellst, z. B. Mikrotik CRS112)
- Oder du wirst dich auf den **Traffic des Desktops selbst** beschränken
  (was er sendet/empfängt), nicht das ganze LAN
- Oder du nutzt **ntopng auf der FritzBox-Seite** über deren
  Export-Funktion — die FritzBox 7520 unterstützt aber **kein**
  NetFlow/IPFIX nativ. Workaround unsicher.

### Realistische Empfehlung

Für Phase 3 reicht es, **ntopng auf dem Desktop** zu betreiben und
seinen eigenen Traffic zu sehen. Das ist immer noch lehrreich (du
siehst, was deine Programme im Hintergrund ins Netz pumpen). Für
„LAN-weite Sicht" brauchst du ergänzend einen Managed-Switch — das ist
ein eigenes Hardware-Projekt, kein Container.

### Verständnis-Check Phase 3

1. *Was ist der Unterschied zwischen NetFlow v5, NetFlow v9 und IPFIX?*
2. *Warum siehst du auf einem normalen Switch nicht den Traffic der
   anderen Ports? Wie heißt das Feature, das es ermöglicht?*
3. *Welchen Layer (OSI) bewegt sich ntopng? Welchen Wireshark?*

## Ad-hoc: Wireshark + tcpdump

Diese beiden gehören in jeden FISI-Werkzeugkasten, sind aber **kein
Monitoring** — sie laufen nicht 24/7.

- **tcpdump** auf CachyOS installiert lassen (`pacman -S tcpdump` über
  CachyOS-Repos oder so wie bei dir üblich). Für schnelle Live-Sicht
  am Terminal.
- **Wireshark** GUI installieren. Capture-File-Format
  (`.pcap`/`.pcapng`) verstehen — du kannst tcpdump-Captures in
  Wireshark öffnen. Das ist ein Workflow, den du im Praktikum brauchen
  wirst.

### Übung (10 Minuten)

1. `sudo tcpdump -i <interface> -w /tmp/capture.pcap port 53` für
   30 Sekunden laufen lassen, während du im Browser ein paar Seiten
   öffnest.
2. Capture in Wireshark öffnen.
3. Filter: `dns.qry.name contains "doubleclick"` — siehst du die DNS-Anfragen,
   die dein AGH (aus dem Adblock-Plan) blockt?

Das ist Forensik-Praxis. Genau diese Art von Live-Capture-Auswertung
wirst du in einer SOC- oder Helpdesk-Rolle wieder sehen.

## PromQL — drei Anfänger-Abfragen zum Selber-Tippen

Tippe sie **selbst**, kein Copy-Paste. Das Tipp-Gedächtnis hilft beim
Lernen.

```promql
# 1. CPU-Auslastung über alle Kerne, in Prozent
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

Verstehe: Warum `1 - idle` und nicht `user + system`? Wegen
`iowait`/`steal`/`softirq` — die zählen sonst nicht mit.

```promql
# 2. Verfügbarer RAM in MB
node_memory_MemAvailable_bytes / 1024 / 1024
```

Verstehe: Warum `MemAvailable` und nicht `MemFree`? Free vs. Available
ist der Klassiker — Linux Page-Cache wäre als „free" missverstanden.

```promql
# 3. Festplatten-Schreibrate, MB pro Sekunde
rate(node_disk_written_bytes_total[1m]) / 1024 / 1024
```

Verstehe: Warum `rate(...)[1m]` und nicht `[1h]`? Window-Größe ≠
Anzeige-Bereich. Größeres Window = glatterer Graph, aber träger.

## Lerncheck zum Schluss

Beantworte schriftlich (Berichtsheft-tauglich):

1. *Du musst in einem Incident-Call binnen 30 s sagen, ob ein Server
   ein CPU- oder ein I/O-Problem hat. Welche zwei PromQL-Abfragen
   ziehst du auf?*
2. *Loki vs. Elasticsearch — nenne je einen Punkt, in dem das
   jeweilige System dem anderen überlegen ist.*
3. *Wieso bauen wir das Monitoring lokal auf CachyOS und nicht auf dem
   VPS? Begründe mit zwei technischen Argumenten.*
4. *Was würde passieren, wenn du `cardinality` für ein Label hast, das
   pro User unique ist (z. B. Session-ID als Label)?*
5. *Beschreibe den Datenfluss „Browser ruft Webseite auf" durch dein
   Setup: an welchen Stellen siehst du das in deinen Monitoring-Tools?*

## Out of Scope (für diese Spec)

- **Suricata / Zeek** (IDS) — eigene Spec, sobald Grundlagen sitzen
- **Wazuh / OSSEC** (SIEM/EDR) — Projektarbeit-Material
- **OpenTelemetry / Traces** — für Web-Services interessant, hier nicht
- **Alerting** (Alertmanager, Slack/Telegram-Push) — Phase 4
- **Externes Monitoring vom VPS aus** — eigene Spec, wenn das Heim-Setup
  steht
- **Blackbox-Probes** (Tests von außen) — Phase 4

## Was ich (dein Tutor) für dich tun werde

- Diesen Plan aktuell halten, wenn du Zwischenstände meldest
- Auf Nachfrage einzelne Befehle/Configs als **Vorlage** liefern, die du
  abtippen oder anpassen kannst
- Verständnis-Fragen beantworten und mit dir Lerncheck-Antworten
  durchgehen
- **Nicht** für dich installieren, **nicht** für dich Configs schreiben,
  **nicht** Befehle in deiner Shell ausführen. Das ist dein Job.

Wenn du an einer Stelle steckenbleibst: melde dich mit
„Phase X, Schritt Y, ich sehe Z, erwartet hatte ich W". Dann debuggen
wir gemeinsam.

## Changelog

| Datum       | Version | Änderung                                            |
|-------------|---------|-----------------------------------------------------|
| 2026-05-20  | 0.1.0   | Erstentwurf. Drei Phasen + Ad-hoc-Werkzeuge + Lerncheck. Tutor-Modus. |
