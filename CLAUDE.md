# homelab — Agent-Instructions

Repo enthält **Infrastruktur-Specs + Runbooks** (Markdown = Source of Truth, HTML
parallel im alexle135.de-Editorial-Stil). Implementations-Logs in `journals/`.
Öffentliches Repo — **keine echten IPs, Hostnames oder Secrets** in Files, nur
Platzhalter (`${...}`).

## Tool-Pflicht (NICHT übergehen)

Diese Reihenfolge ist bindend. Erst die strukturierten Tools, danach Bash/Grep.

| Zweck | Pflicht-Tool |
|---|---|
| Code-/Config-Exploration, Impact, Review | `code-review-graph` MCP (vor Grep/Glob/Read) |
| Shell-Output > 20 Zeilen | `mcp__plugin_context-mode_context-mode__ctx_execute` (shell) |
| Mehrere Befehle bündeln + Search | `mcp__plugin_context-mode_context-mode__ctx_batch_execute` |
| Library/Tool-Docs (Prometheus, Loki, Grafana, restic, rclone, Tailscale, AGH, Traefik) | `context7` — `resolve-library-id` → `query-docs` |
| Mehrstufiges Debugging / ambige Specs | `sequential-thinking` MCP |
| Datei editieren | `Read` → `Edit`/`Write` (NIE `cat`/`sed`/`echo`/`tee`) |
| `git`, `mkdir`, `mv`, `rm`, Navigation | `Bash` |
| Webseite fetchen | `ctx_fetch_and_index` (NIE `curl`/`wget` — Hook blockt) |

Parallele unabhängige Calls in **einer** Message bündeln.

## Wann welches MCP-Tool

- **code-review-graph zuerst** bei: "wie wirkt sich X aus", "wer ruft Y", "wo ist Z konfiguriert" — der Graph kennt die Compose-Files, YAMLs und Markdown-Strukturen strukturell.
- **context7** zuerst bei: PromQL/LogQL-Syntax, restic-Flags, rclone-Optionen, Grafana-Datasource-Format, Tailscale-ACLs, AdGuard-Home-API. Trainingsdaten sind oft veraltet.
- **sequential-thinking** wenn ein Problem zwei oder mehr Hypothesen hat (z. B. "Backup bricht ab — rclone-Quota? Mount-RO? Pack-Size?" → strukturiert durchgehen, nicht raten).

## Hosts & Topologie

```
┌─────────────────────────────────────────────────────────────────────┐
│ Tailnet (100.x.x.x)                                                 │
│                                                                     │
│  ┌──────────────────────────┐      ┌──────────────────────────┐    │
│  │ CachyOS Desktop          │      │ Contabo VPS              │    │
│  │ alias: asus / cachyos    │◀────▶│ alias: tail              │    │
│  │ Tailnet: 100.95.132.54   │      │ Tailnet: 100.92.62.9     │    │
│  │                          │      │                          │    │
│  │ Monitoring-Server:       │      │ Monitoring-Agent +       │    │
│  │  - Prometheus :9090      │      │ Alerting:                │    │
│  │  - Grafana    :3000      │      │  - Alertmanager :9093    │    │
│  │  - Loki       :3100      │      │  - node_exporter :9100   │    │
│  │  - Promtail              │      │  - Promtail (push→Loki)  │    │
│  │  - ntopng     :3001      │      │                          │    │
│  │  - node_exporter :9100   │      │ Backup-Client:           │    │
│  │                          │      │  - Backrest 1.13.0 :9898 │    │
│  │ Backup-Server:           │      │    (Multihost-Client)    │    │
│  │  - Backrest 1.13.0 :9898 │      │                          │    │
│  │    → rclone → gdrive     │      │ Public Services:         │    │
│  │                          │      │  - Traefik (geplant)     │    │
│  │ DNS / Adblock:           │      │                          │    │
│  │  - AdGuard Home          │      │                          │    │
│  └──────────────────────────┘      └──────────────────────────┘    │
│         ▲                                                           │
│         │ DNS / DHCP                                                │
│  ┌──────┴───────────────────┐                                       │
│  │ FritzBox 7520            │                                       │
│  │ - LAN-Gateway            │                                       │
│  │ - kein SPAN, kein NetFlow│                                       │
│  └──────────────────────────┘                                       │
└─────────────────────────────────────────────────────────────────────┘
```

**SSH-Zugänge** (aus User-Sicht, nicht aus Repo):
- `ssh cachyos` → CachyOS Desktop
- `ssh tail` → Contabo VPS

**Was wo läuft — Schnellüberblick:**

| Dienst | Host | Port | Rolle |
|---|---|---|---|
| Prometheus | CachyOS | 9090 | scrapen CachyOS + VPS node_exporter |
| Grafana | CachyOS | 3000 | UI für Prometheus + Loki |
| Loki | CachyOS | 3100 | Log-Aggregation (Push) |
| Promtail | CachyOS + VPS | — | Journal + Docker-Logs → Loki |
| ntopng | CachyOS | 3001 | NetFlow / Top-Talker (nur lokaler Traffic) |
| node_exporter | beide | 9100 | Host-Metriken |
| Alertmanager | VPS | 9093 | ntfy + Telegram Routing |
| Backrest | beide | 9898 | restic-UI, CachyOS=Server, VPS=Client |
| restic→rclone→gdrive | CachyOS | — | eigenes OAuth-Projekt `${GCP_PROJECT_ID}` |
| AdGuard Home | CachyOS | 53/3000 | Tailnet-DNS + Adblock |

## Repo-Struktur

```
homelab/
├── README.md                  Projekt-Übersicht
├── CLAUDE.md                  Diese Datei
├── AGENTS.md                  Vendor-neutrale Variante (Codex/Gemini/…)
├── index.html                 Spec-Übersicht (Editorial, Fraunces+Geist)
├── devops.html                DevOps Console (blackbox-Look, Inter+JetBrains Mono)
├── LICENSE                    CC BY 4.0 für Docs
├── assets/                    Design-Tokens, CSS, Fraunces+Geist, Logo
├── specs/                     Markdown + HTML pro Plan (Source of Truth = MD)
│   └── YYYY-MM-DD-<slug>-design.{md,html}
├── docs/                      Lebende Doku (nicht Plan, nicht Log)
│   ├── SETUP.{md,html}        IST-Stand: Hosts, Dienste, Volumes, Versionen
│   └── runbooks/              Operative Anleitungen
│       └── homelab-recovery.{md,html}  Wiederherstellung nach Total-Verlust
├── journals/                  Implementations-Logs (Soll/Ist/Lernpunkt)
│   └── YYYY-MM-DD-<slug>.md
├── configs/                   Tatsächlich deployte Compose-/YAML-Files
│   ├── monitoring/            prometheus, grafana, loki, alertmanager, ntopng, node_exporter, vps-agents
│   ├── backrest/              Backrest Compose + Forget-Policy
│   ├── backup/                rclone→gdrive (CachyOS), VPS-Script (deaktiviert)
│   ├── agh-sync/              AdGuard-Home Replikation
│   └── agh-cachyos/           AdGuard-Home Container auf CachyOS (Migration aus Bare-Metal)
└── tools/                     Hilfs-Skripte (Single-File-HTML-Build)
```

## Zwei Top-Level-HTML-Seiten, bewusst getrennt

| File          | Look                                  | Zweck                                                   |
|---------------|---------------------------------------|---------------------------------------------------------|
| `index.html`  | Editorial dark · Fraunces · `#ff6a00` | Spec-Übersicht, lebende Plan-Liste                      |
| `devops.html` | Operator-Konsole · Inter+JetBrains Mono · `#060606` | Tailnet-Endpoint-Index mit Live-Heartbeat-Pings         |

Beide werden parallel gepflegt. **Nicht zusammenführen, nicht restylen** — die Stilbruch
ist Designer-Intent (editorial Spec-Repo vs. operator dashboard). Wer eine dritte
Top-Level-Seite anlegt, dokumentiert ihren Stil in dieser Tabelle.

## Konventionen

- **MD ist Source of Truth.** HTML spiegelt MD 1:1. Bei Spec-Änderungen beide aktualisieren.
- **Datei-Schema Specs:** `YYYY-MM-DD-<slug>-design.md` mit Frontmatter (`title`, `slug`, `version`, `status`, `date`, `author`, `scope`, `reading_time`).
- **Datei-Schema docs/SETUP.md:** lebende IST-Doku, semver-versioniert (`1.x.y`), Update bei jedem nicht-trivialen Change am Stack.
- **Datei-Schema docs/runbooks/<slug>.md:** operative Schritt-Anleitung, semver-versioniert, Trockenlauf-Häufigkeit explizit nennen.
- **Datei-Schema Journals:** `YYYY-MM-DD-<slug>.md`, Schritte als **Soll → Ist → Lernpunkt**.
- **Trennung Spec vs. Doku vs. Runbook vs. Journal:** Spec = Plan vorher · Doku = Was-ist-jetzt · Runbook = Wie-mach-ich-X · Journal = Was-ist-passiert. Keine Vermischung — wer das Falsche editiert, soll erstmal nach der richtigen Schublade fragen.
- **Tutor-Modus** in einigen Specs (`modus: tutor`): Claude erklärt, liefert Vorlagen auf Nachfrage, führt **keine** Befehle aus, installiert nichts auf den Hosts.
- **Keine echten Secrets, IPs außerhalb Tailnet, oder Hostnames im Klartext** committen — Platzhalter `${...}` nutzen. Tailnet-IPs (100.x.x.x) sind ok, weil das CGNAT-Bereich ist.
- `*.standalone.html` ist in `.gitignore` — nicht committen.
- **`devops.html`-Action-Buttons** dürfen nur gegen Endpoints aus der harten `ALLOWED_DAEMONS`-Liste rufen (siehe Daemon-Spec, Frontend-Anbindung). Kein `target_host`-Param aus URL/localStorage.

## Workflow-Regeln

- **Minimale Changes.** Kein ungefragtes Refactoring, keine Stil-Vereinheitlichung quer durchs Repo.
- **Spec vor Implementation.** Erst MD im Repo, dann erst auf den Maschinen ausführen.
- **Journal nach Implementation.** Jede umgesetzte Phase bekommt einen Journal-Eintrag im selben Soll/Ist/Lernpunkt-Schema.
- **Commits:** prefix nach Bereich (`feat(monitoring):`, `feat(backrest):`, `docs:`). Co-Author-Trailer behalten.
- **NIE** `--no-verify`, `--force-push`, `--no-gpg-sign` ohne explizite Anweisung.

## Sprache & Stil

- Deutsch. Knapp. Ein Satz schlägt einen Absatz. 2–4 Sätze Default-Report.
- Technische Bezeichner (Befehle, Pfade, Flags) im Original.
- Datei-Referenzen als Markdown-Link: `[file.yml:42](configs/monitoring/prometheus/prometheus.yml:42)`.
- Keine Emojis (außer explizit angefragt), keine Apologien, keine Meta-Kommentare ("Ich werde jetzt…").

## Offene Loose Ends (Stand 2026-05-21)

Aus `journals/2026-05-21-backrest-impl.md` — Kontext für Folge-Sessions:

- CachyOS-AGH DoT-Timeouts (Quad9/Cloudflare in Loki sichtbar)
- Alertmanager-ntfy-Bridge für lesbare Titel
- Doppelte Prometheus-Datasource in Grafana — eine entfernen
- AGH-Query-Log noch nicht in Loki — zweiter Promtail-Job fehlt
- ~~CachyOS-AGH-Container nicht via Compose~~ — Compose-Migration in [`configs/agh-cachyos/`](configs/agh-cachyos/) (Image gepinnt auf `v0.107.52`, siehe diesen PR). Cutover auf den Host steht noch aus.
- OAuth-App auf "In Production" oder Service-Account (sonst stirbt Backup nach 7d Token-Validity)
