# 2026-05-21 — Grafana-Dashboards-Ausbau

Phase 1 der Monitoring-Spec hat ein Lern-Dashboard ergeben
(`cachyos-host.json`, 3 Panels, CachyOS-only). Ab heute fünf Zusatz-
Dashboards, die das Setup im Alltag tatsächlich nutzbar machen — inklusive
VPS-Daten via Tailnet-Scrape, wie in `prometheus.yml` schon angelegt.

## Soll → Ist → Lernpunkt

### Schritt 1 — Bestand analysieren

- **Soll**: Wissen, was schon da ist, bevor neue Dashboards entstehen.
- **Ist**: `configs/monitoring/grafana/dashboards/` enthielt genau eine
  Datei: `cachyos-host.json`. Drei Panels (CPU, RAM, Disk-Write), Daten-
  source hardgecodet auf UID `cfmoy44jnnv28b`, keine Templating-Variablen,
  kein Host-Filter. Prometheus scrapt aber bereits beide Hosts und labelt
  sie mit `host=cachyos|vps` — das hat das Dashboard nicht genutzt.
- **Lernpunkt**: Single-Host-Dashboard mit hardgecodeter Datasource-UID
  ist nicht falsch, aber unflexibel. Sobald ein zweiter Host dazukommt,
  rentiert sich Templating (Datasource + Host).

### Schritt 2 — Fünf Dashboards bauen

Alle neuen Dashboards nutzen denselben Pattern:

- `DS_PROMETHEUS` / `DS_LOKI` als Datasource-Variable
- `$host` als Multi-Select-Filter mit `includeAll`
- Schema-Version 39, Zeitfenster 3 h–6 h, Refresh 30 s–1 min

| Datei | Panels | Hauptzweck |
|---|---|---|
| `multi-host-overview.json` | 9 | CachyOS + VPS Side-by-side: CPU, RAM%, Load, FS%, Net RX/TX, Uptime |
| `network-traffic.json` | 8 | Per-Interface RX/TX Mbit/s, Errors/Drops, TCP-Conn, Conntrack |
| `disk-storage.json` | 7 | FS-Füllstand pro Mount (Bargauge), IOPS, I/O-Util, Inodes |
| `logs-overview.json` | 8 | Loki: Volume + Error-Rate pro Host, Top-Quellen, Live-Errors |
| `alerts-health.json` | 10 | Firing/Pending Alerts, `up`-Status, Scrape-Dauer, TSDB-Series |

JSON-Validität: alle sechs Dateien per `python3 -c json.load` geprüft → ok.

### Schritt 3 — Doku

- `configs/monitoring/grafana/dashboards/README.md`: Tabelle mit allen
  Dashboards, Datasource-Konvention, Host-Templating-Regel, wiederkehrende
  PromQL-Bausteine.
- `specs/2026-05-20-monitoring-stack-design.md`: neue Section „Dashboards
  (Zusatz, 2026-05-21)" vor dem Changelog, Frontmatter-Version 0.1.1 →
  0.2.0, Changelog-Eintrag ergänzt.

### Schritt 4 — Was offen bleibt

- **HTML-Spec nicht synchronisiert.** `tools/build-singlefile.py` ist
  HTML→Standalone-HTML, nicht MD→HTML. Der MD→HTML-Schritt ist in den
  Tools nicht abgebildet (vermutlich Pandoc oder ein externer Editor).
  Bei nächster Spec-Pflege manuell nachziehen — Source of Truth = MD.
- **Loki-Datasource-UID** nicht aus Provisioning bekannt — keine
  Datasource-Provisioning-YAML im Repo, User hat die in der UI angelegt.
  Templating-Variable-Pattern umgeht das.
- **Backrest-Metriken-Dashboard** fehlt. Backrest hat `/metrics` auf
  :9898, aber Prometheus scrapt es noch nicht. Eigene Spec-Erweiterung
  würde Sinn ergeben (Phase: Backup-Observability).
- **Dashboard-Provisioning** (Auto-Import beim Grafana-Start) noch
  manuell. Trivial nachzurüsten: ein `dashboards.yml` unter
  `/etc/grafana/provisioning/dashboards/` + Volume-Mount auf
  `configs/monitoring/grafana/dashboards/`.

### Schritt 5 — Provisioning nachgezogen (gleicher Tag)

Manueller Import via UI lief beim User nicht durch — vermutlich am
Datasource-Variable-Pattern hängengeblieben. Daher Umstieg auf
vollständiges Provisioning:

- **Neu**: `configs/monitoring/grafana/provisioning/datasources/datasources.yml`
  legt Prometheus (UID `prometheus`, Default) und Loki (UID `loki`) an —
  beide gegen `localhost:9090` / `localhost:3100`, weil Grafana host-mode.
- **Neu**: `configs/monitoring/grafana/provisioning/dashboards/dashboards.yml`
  registriert einen File-Provider, der `/var/lib/grafana/dashboards`
  alle 30 s scannt und in den Folder „Homelab" sync't.
- **Geändert**: Alle sechs Dashboard-JSONs auf feste Datasource-UIDs
  (`prometheus`/`loki`) umgestellt. Templating-Variablen für die
  Datasource sind raus, `$host` bleibt erhalten.
- **Geändert**: `docker-compose.yml` mountet `./provisioning` und
  `./dashboards` read-only in den Container.

Migrations-Hinweis im README: Falls aus der Lern-Phase noch eine
manuelle Prometheus-Datasource mit UID `cfmoy44jnnv28b` existiert,
einmalig in der UI löschen — die provisionierte übernimmt.

Validität: alle JSON + YAML per `json.load` / `yaml.safe_load` geprüft.

**Lernpunkt**: Provisioning > manueller Import, sobald mehr als ein
Dashboard im Spiel ist. Datasource-Variable ist nur dann der richtige
Pfad, wenn das Dashboard ohne Repo-Hoheit verteilt wird (Community,
externe Empfänger). Im eigenen Repo: feste UIDs, zentral provisioniert.

### Schritt 6 — Deploy auf CachyOS + zwei harte Stolpersteine

Manueller UI-Import lief beim User nicht durch. Vollständiges
Provisioning rüber auf den Live-Host und in zwei Iterationen gefixt.

**Lessons learned (teuer bezahlt):**

1. **Dashboard-JSON-Format unterscheidet sich pro Pfad.** Für den
   File-Provider muss das Dashboard-Objekt **im Root** liegen — also
   `{"title": "...", "panels": [...]}`. Der Wrapper
   `{"dashboard": {...}, "overwrite": true, "message": "..."}` ist nur
   für den HTTP-API-Endpunkt `/api/dashboards/db`. Im falschen Format
   wirft Grafana `failed to load dashboard ... error="Dashboard title
   cannot be empty"` — irreführend, weil der Title in `dashboard.title`
   ja sehr wohl da ist, nur eine Ebene tiefer.
   Fix: Wrapper aus allen sechs JSONs entfernt (Python-One-Liner).

2. **Manuelle Datasources kollidieren mit Provisioning bei Name-Match.**
   Hatte aus der Lern-Phase eine händische Prometheus-Datasource in
   der UI angelegt (UID `cfmoy44jnnv28b`). Beim Provisioning mit
   `name: Prometheus` (UID `prometheus`) ging Grafana in Crash-Loop:
   `Datasource provisioning error: data source not found`. Misleading
   Errormessage — das eigentliche Problem ist der Namens-Konflikt,
   nicht eine fehlende Source.
   Fix: `deleteDatasources`-Block in `datasources.yml` räumt vor dem
   Anlegen alle mit gleichem Namen weg.

**Deploy-Pfad**: rsync vom Repo (`/Volumes/T7/Projekte/homelab/...`)
nach CachyOS (`/home/alex/monitoring/grafana/`), dann
`docker compose down && docker compose up -d`. Repo bleibt Source of
Truth — der Live-Host ist Spiegel.

**Verifikation**: HTTP 302 auf `/d/multi-host-overview` (statt 404)
plus „provisioning.dashboard ... finished" ohne Errors in den Logs.
Visuell bestätigt vom User.

## Lernpunkt-Sammlung

1. **Datasource-Variable schlägt UID-Hardcode**, sobald ein Dashboard
   exportiert/importiert/geteilt wird. Grafana fragt einmal beim Import,
   danach ist Ruhe.
2. **`host`-Label in `prometheus.yml`** ist der Anker für Multi-Host-
   Dashboards. Ohne diese Konvention müsste man `instance` parsen oder
   pro Host ein eigenes Dashboard pflegen.
3. **Phase-1-Dashboard bewusst stehen lassen.** Es ist Lerndokumentation,
   kein produktives Dashboard. Refactor wäre falsche Effizienz.
