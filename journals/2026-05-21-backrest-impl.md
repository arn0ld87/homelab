---
title: Implementation-Journal — Backrest auf CachyOS + Multihost-Pairing
slug: backrest-impl
date: 2026-05-21
status: backup-läuft
host: CachyOS Desktop (asus) + Contabo VPS (tail)
author: Alexander Schneider
---

# Implementation-Journal — Backrest auf CachyOS + Multihost

Fortsetzung des Backup-Setups aus dem Resume-Handoff
(`RESUME-HOMELAB-SPRINT.md`). Ziel: CachyOS-Backrest-Initial-Backup
durchbringen, Multihost-Sync zwischen CachyOS (Server) und VPS (Client)
einrichten, Klartext-Passphrasen vom Disk entfernen.

Struktur je Schritt: **Soll** — **Ist** — **Lernpunkt**.

---

## 1. CachyOS-Backrest — Forget-Policy fertig konfigurieren

### Soll

Forget-Policy im Repo `cachyos` aktivieren mit Time-Bucketed-Retention
(7 Daily, 4 Weekly, 6 Monthly, 1 Yearly, 3 KeepLastN), Schedule
`0 4 * * *`. Danach erster Backup via UI „Backup Now".

### Ist

Über UI gesetzt, in `config.json` persistiert als:

```json
"forgetPolicy": {
  "schedule": { "cron": "0 4 * * *", "clock": "CLOCK_LAST_RUN_TIME" },
  "retention": { "policyTimeBucketed": {
    "daily": 7, "weekly": 4, "monthly": 6, "yearly": 1, "keepLastN": 3
  }}
}
```

Erster Backup-Versuch lief auf 0.41% / 229 MiB von 55.43 GiB und brach
ab mit:

```
rclone: ERROR : Failed to save config after 10 tries:
  open /root/.config/rclone/rclone.conf...: read-only file system
rclone: Error 403: Quota exceeded for quota metric 'Queries' ...
```

### Lernpunkt

Forget-Policy-Felder werden in Backrest case-sensitive in der Config
abgelegt (`policyTimeBucketed`, nicht `policy_time_bucketed`). UI ist
sauber, aber wenn man später per JSON-Edit dran will, muss man die
camelCase-Form treffen.

---

## 2. rclone-Mount `:ro` — der eigentliche Backup-Bug

### Soll

Backrest-Container muss `rclone.conf` lesen UND schreiben können, weil
rclone bei jedem OAuth-Token-Refresh die Datei zurückschreibt.

### Ist

Aus `compose.yaml` extrahiert (CachyOS, Mount-Zeile):

```yaml
- /home/alex/.config/rclone:/root/.config/rclone:ro
```

`docker inspect backrest --format '{{range .Mounts}}{{.Source}} ->
{{.Destination}} (RW={{.RW}}){{println}}{{end}}'` bestätigte:

```
/home/alex/.config/rclone -> /root/.config/rclone (RW=false, Mode=ro)
```

Fix:

```yaml
# MUSS rw sein — rclone schreibt Token-Refresh in rclone.conf zurück
- /home/alex/.config/rclone:/root/.config/rclone
```

Nach `docker compose up -d`:

```
rclone-mount RW=true
```

### Lernpunkt

Backrest-Doku-Beispiele lassen `:ro` oft so, weil statische rclone-
Configs (Service-Account-JSON, kein OAuth-Refresh) read-only sein
können. Bei OAuth-Drive (was wir nutzen) refresht rclone den
Access-Token alle ~60 min und schreibt das zurück — `:ro` killt jeden
Backup nach Token-Ablauf.

---

## 3. Restic-Pack-Size + rclone-Drosseln gegen Drive-API-Limit

### Soll

Initial-Backup von 55 GB läuft gegen Google Drives
`defaultPerMinutePerProject`-Limit (geteiltes rclone-OAuth-Projekt).
Hebel: weniger API-Calls pro GB Daten.

### Ist (erster Versuch — falsch)

Über UI versucht, restic-Flags zu setzen:

```
-o
rclone.args=--transfers=2 --tpslimit=8 --tpslimit-burst=10
```

UI hatte keine Env-Var-Felder, also Direkt-Patch der `config.json`:

```json
"env": ["RESTIC_PACK_SIZE=128"],
"flags": ["-o", "rclone.args=--transfers=2 --tpslimit=8 --tpslimit-burst=10"]
```

Nächster Backup-Run starb sofort mit:

```
unknown flag: --tpslimit
```

Restic kennt `--tpslimit` nicht — das ist ein rclone-Flag, kein
restic-Flag. Backrest hat den ganzen String an restic durchgereicht,
nicht an rclone weitergeleitet.

### Ist (zweiter Versuch — richtig)

rclone-Tuning per Env-Vars statt CLI-Flags, weil rclone alle Flags
automatisch via `RCLONE_<FLAG>` als Env-Var akzeptiert (Bindestrich →
Unterstrich, alles groß):

```json
"env": [
  "RESTIC_PACK_SIZE=128",
  "RCLONE_TRANSFERS=2",
  "RCLONE_TPSLIMIT=8",
  "RCLONE_TPSLIMIT_BURST=10"
],
```

Backrest neugestartet, Config valid, Backup-Run startete sauber.

### Lernpunkt

- Restic's `-o rclone.args=...` reicht NICHT mehrere Argumente als
  einen String durch — die werden weiter gesplittet.
- rclone-Tuning gehört in `RCLONE_*`-Env-Vars, nicht in restic-Flags.
- Default-Pack-Size in restic ist 16 MiB, Maximum 128 MiB. Bei 55 GB
  bedeutet 128 MiB ~430 Pack-Files statt ~3500 — Faktor 8 weniger
  API-Calls.

---

## 4. VPS-Backrest-Version-Lücke — Multihost erst ab 1.13

### Soll

Pairing-Token von CachyOS-Backrest in VPS-Backrest einlösen.

### Ist

VPS lief auf `garethgeorge/backrest:1.12.1` — kein Multihost-Feature.
CachyOS war auf `1.13.0`.

```bash
ssh tail 'cd /home/admin/backrest && \
  sudo cp config/config.json config/config.json.bak.pre-multihost-upgrade && \
  docker compose pull && docker compose up -d'
```

Pull holte 1.13.0, Container recreate, Web-UI auf
`http://100.92.62.9:9898` wieder erreichbar (HTTP 200 via Tailnet),
existierende Repos und Backups erhalten.

### Lernpunkt

`image: garethgeorge/backrest:latest` im Compose-File heißt **nicht**,
dass beim Container-Restart automatisch die neueste Version gezogen
wird. `docker compose pull` ist ein expliziter Schritt. Wenn der Host
seit Wochen läuft, kann der Container mehrere Versionen hinterherhinken.

---

## 5. Multihost-Pairing — CachyOS = Server, VPS = Client

### Soll

CachyOS generiert Pairing-Token via UI, VPS löst ihn ein, verschlüsselter
Sync-Stream zwischen beiden steht.

### Ist

CachyOS-UI → Einstellungen → Multihost → Pairing-Token mit Label
`vps-pairing`, TTL 1h, Max Uses 1, Permissions Read-* erzeugt.

Token im Format `<keyid>:<secret>#<instanceid>`. Auf VPS-UI →
Known Hosts → Add → Token eingefügt, Instance URL
`http://100.95.132.54:9898`.

Logs beider Seiten zeigten:

```
[VPS]    sync connection established with peer "CachyOS"
[VPS]    cleared pairing secret for peer "CachyOS" after successful connection
[CachyOS] successfully paired client "alexle135"
[CachyOS] accepted a connection from client instance ID "alexle135"
```

### Lernpunkt

- Auth-disabled (`auth.disabled: true`) ist KEINE Voraussetzung für
  Pairing. Tokens binden an Instance-ID, nicht User. Im 1-User-
  Tailnet ist Auth-aus vertretbar.
- Pairing-State landet NICHT in `config.json` (`multihost.knownHosts`
  blieb leer auf beiden Seiten), sondern in Backrests interner
  Sync-DB unter `data/`. Direkt-JSON-Patches für Pairing scheitern
  daher zwangsläufig.

---

## 6. Eigenes Google-OAuth-Projekt — Drive-Quota dauerhaft lösen

### Soll

Shared rclone-OAuth-Projekt (`consumer: projects/202264815644`) ist mit
Tausenden anderen rclone-Nutzern geteilt — Per-Project-Limit reicht
nicht für 55 GB Initial-Backup, selbst mit Drosseln. Eigener OAuth-Client
im eigenen Cloud-Projekt hat eigenes Quota.

### Ist

OAuth-Client-Credentials aus Cloud-Projekt `temporal-state-497009-n0`
(Web Application Type) in `rclone.conf` eingetragen:

```ini
[gdrive]
type = drive
scope = drive
client_id = 261620747521-...apps.googleusercontent.com
client_secret = GOCSPX-...
team_drive =
```

Backrest gestoppt (sonst überschreibt der Container die Datei),
ownership zurück auf `alex:alex` (Container schrieb sie vorher als
root), dann auf CachyOS-Host als alex:

```bash
rclone config reconnect gdrive:
```

Drei Hindernisse in Folge:

1. **`redirect_uri_mismatch`** — Web-OAuth-Client braucht
   `http://127.0.0.1:53682/` in den autorisierten Redirect-URIs.
2. **`access_denied: rclone_oauth has not completed Google
   verification`** — App im Testing-Mode, Account `Aschn.privat@gmail.com`
   musste als Test-User im OAuth Consent Screen eingetragen werden.
3. **`Google Drive API has not been used in project 261620747521`** —
   Drive-API im Cloud-Projekt nicht aktiviert. Über Console aktiviert.

Danach OAuth-Flow durch, neuer Refresh-Token in `rclone.conf`. Backrest
gestartet, Backup-Run lief sauber an: `count: 0` für Plan-Snapshots,
keine 403er.

### Lernpunkt

- Token von Apps im Testing-Mode haben **7-Tage-Refresh-Validity**.
  Für Dauerbetrieb muss die App entweder auf „In Production" gestellt
  werden (kann Verification-Prozess auslösen für Drive-Scope), oder
  Service-Account-Setup wird gemacht.
- Web-OAuth-Client braucht expliziten Redirect-URI-Eintrag — Desktop-
  Clients hätten den eingebauten OOB-Flow nicht gebraucht. Beim
  nächsten Setup besser direkt einen Desktop-Client anlegen.
- Beim Cloud-Projekt-Wechsel ist die Drive-API **manuell zu
  aktivieren** — passiert nicht automatisch beim OAuth-Client-Erstellen.

---

## 7. Passphrase-Audit — Klartext-Files entsorgt

### Soll

Beide Repo-Passphrasen aus den Klartextdateien
(`/home/admin/restic-vps-passphrase.txt`,
`/home/alex/restic-cachyos-passphrase.txt`) in NordPass übertragen,
dann Files sicher löschen.

### Ist

`shred -uz` auf beiden Hosts:

```bash
ssh tail   'sudo shred -uz /home/admin/restic-vps-passphrase.txt'
ssh cachyos 'sudo shred -uz /home/alex/restic-cachyos-passphrase.txt'
```

Beide Files weg, `ls` bestätigt.

**Wichtiger Mismatch-Befund:** Die CachyOS-Klartextdatei enthielt
einen 32-char-Wert, in `config.json` (Backrest-Repo `cachyos`) steht
ein 31-char-Wert (letztes `F` fehlt). Welcher der echte ist:
Backrest-Config-Wert, weil Backrest mit diesem Wert die `restic
snapshots`-Query durchgekriegt hat. Hätte die Klartextdatei in
NordPass gelandet, wäre der Recovery-Pfad bei Total-Verlust gebrochen
gewesen.

### Lernpunkt

**Bei jedem Passphrase-Setup vor dem Löschen der Klartextdatei
verifizieren, dass NordPass-Eintrag und die tatsächlich von der
Anwendung genutzte Passphrase identisch sind.** Lieber einmal mit
`restic snapshots -r ...` testen als sich auf „hab ich aus dem File
kopiert" verlassen.

---

## Status am Tagesende

| Komponente | Stand |
|---|---|
| CachyOS-Backrest 1.13.0 | läuft |
| rclone-Mount RW + Tuning + eigener OAuth | ✓ |
| Initial-Backup CachyOS 55 GB (eigenes Cloud-Projekt) | läuft |
| Forget Policy `cachyos`-Repo | ✓ |
| VPS-Backrest 1.13.0 | ✓ (von 1.12.1 hochgezogen) |
| Multihost-Pairing CachyOS ↔ VPS | ✓ |
| Klartext-Passphrasen vom Disk | gelöscht (`shred -uz`) |

## Offene Loose Ends (aus Handoff übernommen)

- CachyOS-AGH DoT-Timeouts (Quad9/Cloudflare in Loki)
- ~~Alertmanager-ntfy-Bridge für hübschere Titel~~ → siehe §8
- ~~Doppelte Prometheus-Datasource in Grafana — eine löschen~~ (erledigt)
- ~~AGH-Query-Log noch nicht in Loki — zweiter Promtail-Job~~ → siehe §9
- CachyOS-AGH-Container nicht via Compose — Migration steht aus
- App auf „In Production" oder Service-Account, sonst stirbt das
  CachyOS-Backup nach 7 Tagen still (Token-Validity-Limit)

---

## 8. Alertmanager-ntfy-Bridge — Pushes mit Titel, Tags, Priority

### Soll

`alertmanager` schickt Webhook-Payloads als JSON-Body. ntfy steuert
Title/Tags/Priority aber per HTTP-Header. Direkt verdrahtet kam nur ein
JSON-Dump im Notification-Body an. Eine Bridge dazwischen, die aus
Alertmanager-Labels echte ntfy-Header macht.

### Ist

`xenrox/ntfy-alertmanager:latest` als zweiter Compose-Stack neben
Alertmanager:

```
/home/admin/monitoring/
├── alertmanager/                # bestehend
└── alertmanager-ntfy/           # neu
    ├── docker-compose.yml
    ├── config.scfg.tpl          # gerendert via envsubst
    └── README.md
```

Architektur:

```
Prometheus → Alertmanager (9093) → Bridge (127.0.0.1:9095) → ntfy.sh/${NTFY_TOPIC}
                                 ↘ Telegram (bleibt unverändert)
```

Drei Stolperer auf dem Weg:

1. **Image-Name** — Docker-Hub-Repo heißt `xenrox/ntfy-alertmanager`,
   nicht `alertmanager-ntfy` (mein erster Versuch lieferte `pull access
   denied`). Korrekter Codeberg-Source:
   <https://codeberg.org/xenrox/ntfy-alertmanager>.
2. **Config-Format** — `.scfg`, nicht YAML. Mein erster YAML-Entwurf
   wäre stumm ignoriert worden. Beispiel-Config aus dem Repo
   übernommen, auf unsere Labels reduziert.
3. **Port-Konflikt** — 8080 ist der Default der Bridge, aber auf dem
   VPS belegt durch Weaviate (`*:8080`). Auf 9095 ausgewichen
   (9094 = Alertmanager-Cluster).

Receiver-Patch in `alertmanager.yml.tpl`:

```yaml
webhook_configs:
  - url: 'http://127.0.0.1:9095/hook'
    send_resolved: true
```

Severity-Routing in `config.scfg.tpl`:

```
labels {
    order "severity"
    severity "critical" { priority 5; tags "rotating_light,red_circle" }
    severity "warning"  { priority 3; tags "warning,yellow_circle"     }
}
resolved {
    update-notification true
    tags "white_check_mark"
    priority 2
}
```

Smoke-Test via Alertmanager-API:

```bash
docker exec -i alertmanager wget -qO- \
  --header='Content-Type: application/json' \
  --post-data='[{"labels":{"alertname":"BridgeSmokeTest",...},"annotations":{...}}]' \
  http://127.0.0.1:9093/api/v2/alerts
```

Verifikation (ntfy.sh Topic-Poll):

```json
{
  "title":"[FIRING:1] BridgeSmokeTest vps",
  "priority":3,
  "tags":["warning","yellow_circle"],
  "message":"### Firing\n\n**Labels:**\n- alertname = BridgeSmokeTest\n..."
}
```

Push auf Handy (ntfy-App) und Telegram angekommen.

### Lernpunkt

- Bei Bridge-Auswahl **immer Codeberg/Upstream-README lesen**, nicht
  vom Docker-Hub-Suchergebnis ableiten. Image-Namen sind oft umgedreht
  (`<name>-alertmanager` vs `alertmanager-<name>`).
- `scfg` ist ein anderes Format-Universum als YAML/TOML — Reihenfolge
  matters, geschweifte Klammern statt Einrückung, kein YAML-Anker.
- Host-Network-Ports vor Deploy mit `ss -tlnp` checken. Default-Ports
  kollidieren oft mit Weaviate (8080), Grafana (3000), Prometheus
  (9090).
- AM-Notify-Logs erscheinen auf INFO-Level **nicht bei Erfolg** —
  beim Debuggen lieber direkt am ntfy-Topic pollen statt nur in
  AM-Logs suchen.

### Status

| Komponente | Stand |
|---|---|
| Bridge-Container `alertmanager-ntfy` v1.0.0 | läuft |
| Webhook AM → Bridge → ntfy.sh | ✓ |
| Telegram-Receiver | unverändert ✓ |
| Severity-Routing (critical/warning/resolved) | ✓ |

---

## 9. AGH-Querylog in Loki — beide Hosts

### Soll

AGH-DNS-Queries (Domain, Client, Type, Upstream, Filter-Reason) in
Loki sichtbar machen, sodass man in Grafana per LogQL über beide
Hosts hinweg filtern kann. Promtail muss zusätzlich zu journald
und Docker auch `querylog.json` einlesen.

### Ist

**Schema-Verifikation aus dem laufenden Container** (Host-User darf
nicht in `/.../work/data/`):

```bash
docker exec agh-primary head -1 /opt/adguardhome/work/data/querylog.json
```

Echtes Schema (Stand AGH 2026):

```json
{
  "T": "2026-05-20T16:26:40.406723159Z",
  "QH": "example.com",
  "QT": "A",
  "QC": "IN",
  "CP": "",
  "Upstream": "tls://1.1.1.1:853",
  "Answer": "<base64>",
  "IP": "100.121.130.100",
  "Result": {},
  "Elapsed": 46546819,
  "AD": true
}
```

**Label-Strategie:** nur niedrig-kardinale Felder als Loki-Label.
Domain (`QH`) hat zu viele Werte → bleibt im Body.

| Feld | Cardinality | Label? |
|---|---|---|
| `host` | 2 (vps/cachyos) | ja |
| `job` | 1 (`adguard`) | ja |
| `QT` (qtype) | ~10 (A/AAAA/HTTPS/PTR/...) | ja → `qtype` |
| `Upstream` | 3–5 | ja → `upstream` |
| `QH` (domain) | tausende | nein, Body |
| `IP` (client) | dutzende | nein, Body |

**Promtail-Patch** (beide Hosts identisch bis auf `host`-Label):

```yaml
- job_name: adguard
  static_configs:
    - targets: [localhost]
      labels:
        job: adguard
        host: vps                # bzw. cachyos
        __path__: /var/agh-log/querylog.json*
  pipeline_stages:
    - json:
        expressions:
          ts: T
          qtype: QT
          upstream: Upstream
    - labels:
        qtype:
        upstream:
    - timestamp:
        source: ts
        format: RFC3339Nano
```

**Compose-Patch** (Bind-Mount des AGH-Work-Verzeichnisses):

```yaml
volumes:
  # AGH-Querylog (root:root 600, Promtail liest als root im Container).
  - /home/admin/agh/work/data:/var/agh-log:ro          # vps
  - /home/alex/adguard/work/data:/var/agh-log:ro       # cachyos
```

Glob `querylog.json*` deckt Rotation ab, falls AGH irgendwann einen
`querylog.json.1`-Rotate macht.

### Verifikation

```bash
ssh cachyos
curl -sG \
  --data-urlencode "query=sum by (host,qtype) (count_over_time({job=\"adguard\"}[1h]))" \
  "http://localhost:3100/loki/api/v1/query" | jq .data.result
```

Ergebnis nach 30 Min:

| host | qtype | count |
|---|---|---|
| vps | A | 2891 |
| vps | AAAA | 2844 |
| vps | HTTPS | 702 |
| vps | PTR | 189 |
| cachyos | A | 449 |
| cachyos | AAAA | 443 |
| cachyos | HTTPS | 204 |

### Lernpunkt

- AGH-Querylog hat `600 root:root`. Sample über `docker exec` ist
  der saubere Weg, nicht `sudo cat` (Permission-Pollution vermeiden).
- Pipeline-Stage `json` ohne `output` lässt die original-Zeile als
  Log-Body durch. Grafana-Filtering via `{job="adguard"} | json` —
  Cardinality-Explosion vermieden.
- Promtail-Container läuft per default als UID 0 (root) — damit
  liest er `600 root:root` ohne extra-Rechte.
- Mount auf das Verzeichnis (`/var/agh-log`), nicht direkt auf die
  Datei, damit Rotation transparent klappt.

### Status

| Komponente | Stand |
|---|---|
| Promtail tail — Job `adguard` | ✓ |
| Promtail cachyos — Job `adguard` | ✓ |
| Loki Streams (`host=vps`, `host=cachyos`) | ✓ |
| LogQL-Filter via `{job="adguard"} \| json` | ✓ |
