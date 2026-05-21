---
title: DevOps Control Daemon
slug: devops-control-daemon
version: 0.1.1
status: Entwurf
date: 2026-05-21
author: Alexander Schneider
scope: Tailnet-only Mini-Daemon mit Allowlist für Routine-Operations
reading_time: ~14 min
---

# DevOps Control Daemon

## Motivation

Routine-Operations wie `nala update`, `restic snapshots` oder `systemctl status loki.service`
laufen heute über zwei SSH-Sessions in zwei Terminals. Das ist zuverlässig, aber langsam
und schlecht aus dem Browser bedienbar. Eine SaaS-Lösung (Portainer Business, Cockpit auf
extern, Ansible Tower) lohnt nicht — der Betrieb von Auth-Backend, OIDC, TLS-Reverse-Proxy
und Audit-Pipeline frisst mehr Zeit als die Operations selbst. Stattdessen: ein kleiner
Daemon pro Host, der nur eine geschlossene Liste von Befehlen ausführt, und die
Vertrauensbasis ist das Tailnet. Wer im Tailnet ist, ist authentifiziert — Tailscale
liefert Identity über `tailscaled localapi/v0/whois`, der Daemon hört nur auf
`100.x.x.x` und schaltet `0.0.0.0` aus. Kein Shared-Secret, kein OAuth-Provider, kein
Token in `localStorage`. Wenn das Tailnet kompromittiert ist, sind ohnehin größere
Probleme vorne.

## Ziele und Nicht-Ziele

**Ziele**

- Idempotente Allowlist-Commands: jedes Kommando hat eine feste `argv`-Liste, keine Shell.
- Tailscale-Identity als Auth-Anchor — User wird per `whois` aufgelöst, Allowlist matcht
  gegen `alex@github` und Co.
- Audit-Log als append-only JSONL, lesbar und maschinenparsbar.
- Ein Binary pro Host, statisch gelinkt (Go), keine libc-Abhängigkeit, kein Runtime.
- systemd-Hardening (`NoNewPrivileges`, `ProtectSystem=strict`, dedicated User).

**Nicht-Ziele**

- Kein freies Shell-Eval, keine User-Argumente außer aus geschlossener Enum.
- Keine Container-Orchestration — kein Ersatz für Compose, Portainer, Komodo.
- Kein Multi-User-RBAC mit Rollen/Policies — Allowlist ist flach, eine User-Liste pro Host.
- Kein Push-Modell — der Daemon ruft nichts selbst auf, hat keine Outbound-Verbindungen.
- Kein Web-UI im Daemon — die `devops.html`-Console im homelab-Frontend ist der einzige Client.

## Architektur

```
[Browser im Tailnet]
     ↓ HTTP (Tailscale TLS via tailscale cert)
[Daemon :7777 auf jedem Host]
     ↓ identity-Lookup
[Local tailscaled /localapi/v0/whois]
     ↓ Allowlist-Filter
[Subprocess mit fester argv-Liste, no shell]
```

Der Daemon läuft pro Host, lauscht ausschließlich auf der Tailscale-IPv4 (`tailscale ip -4`)
und niemals auf `0.0.0.0`. Beim Start liest er sein Listen-Interface aus dem
`tailscaled localapi/v0/status` heraus — wenn Tailscale nicht läuft, fährt der Daemon nicht
hoch. Sprache: Go, statisch kompiliert, einzelnes Binary unter `/usr/local/bin/devopsd`.
Keine Plugins, keine dynamischen Libs.

Host-Topologie:

```
┌────────────────────────────────────────────────────────────────┐
│  TAILNET                                                       │
│                                                                │
│   ┌───────────────────────┐         ┌────────────────────────┐ │
│   │  cachyos (Desktop DE) │         │  server-ops (VPS DE)   │ │
│   │  devopsd :7777        │         │  devopsd :7777         │ │
│   │  bind: 100.95.132.54  │         │  bind: 100.92.62.9     │ │
│   └───────────┬───────────┘         └───────────┬────────────┘ │
│               │                                  │             │
│               └─────────────┬────────────────────┘             │
│                             ▼                                  │
│              ┌──────────────────────────────┐                  │
│              │  Browser-Client              │                  │
│              │  devops.html im Tailnet      │                  │
│              │  identity: alex@github       │                  │
│              └──────────────────────────────┘                  │
└────────────────────────────────────────────────────────────────┘
```

## Authentifizierung — Tailscale Identity

Bei jedem Request schaut der Daemon die Quelle-IP an (typisch `100.x.x.x`) und ruft lokal
gegen den `tailscaled`-Socket:

```
GET /localapi/v0/whois?addr=<peer-ip>:<peer-port>
```

Das Response liefert `UserProfile.LoginName` — z. B. `alex@github`. Diese Login-ID wird
gegen die User-Allowlist in `/etc/devopsd/config.toml` (`allowed_users`) gematcht. Trifft
sie nicht, antwortet der Daemon `403 Forbidden` mit JSON-Body `{"error":"not_allowed"}`,
ohne den User-Namen zu echoen.

Kein Shared-Secret, kein API-Token, kein Bearer-Header. Die Vertrauenskette ist:

1. Tailscale-Node ist im Tailnet → Quelle-IP ist garantiert `100.x.x.x` aus diesem Tailnet.
2. `tailscaled` weiß, welcher User welchen Node besitzt → `whois` ist autoritativ lokal.
3. Allowlist in der Config entscheidet, ob der User Commands ausführen darf.

**Sicherheits-Hinweis**: Der Daemon vertraut der Quelle-IP, weil sie vom
Tailscale-Userspace-Routing kommt, nicht vom Kernel-Netzwerkstack auf einem öffentlichen
Interface. Spoofing der `100.x.x.x`-IP ist nur über einen kompromittierten Tailscale-Node
möglich — und in dem Fall liefert `whois` ohnehin die Identity des kompromittierten Users.
Die Allowlist begrenzt dann den Blast-Radius (siehe Threat-Model).

## Command-Allowlist (MVP)

| id | host-scope | argv (no shell) | side-effect | dauer | docs |
|---|---|---|---|---|---|
| `pkg.update` | cachyos | `nala update` | aktualisiert apt-Cache | ~30 s | nala(8) |
| `pkg.upgrade-dry` | cachyos | `nala upgrade --simulate` | listet Upgrades | <10 s | nala(8) |
| `restic.snapshots` | server-ops | `backrest snapshots --json` | read-only | <5 s | backrest(1) |
| `docker.ps` | beide | `docker ps --format json` | read-only | <2 s | docker(1) |
| `systemd.status` | beide | `systemctl status --no-pager -- $UNIT` | read-only | <2 s | systemd(1) |
| `tailscale.status` | beide | `tailscale status --json` | read-only | <1 s | tailscale(1) |

**Wichtig**: `$UNIT` wird gegen `^[a-zA-Z0-9@._-]+\.(service|timer|socket)$` validiert.
Keine Pipes, keine Shell-Substitution, keine freien Args von der Wire. Kein `pkg.upgrade`
ohne `--simulate` im MVP — das Apply-Kommando kommt erst nach erfolgreicher Audit-Phase
(siehe Slice-Plan V0.5).

Das explizite `--` vor `$UNIT` ist Pflicht — ohne wird ein Name wie `-H remote.service`
als systemctl-Option gelesen und kann auf entfernte Hosts hosten.

Zusätzlich zur Argv-Regex MUSS jede Host-Config in `/etc/devopsd/config.toml` eine flache
Unit-Allowlist deklarieren (`allowed_units = ["loki.service", "promtail.service",
"backrest.service", …]`). Das ist im MVP nicht optional — eine sensitive Unit wie
`sshd.service` darf nicht implizit erlaubt sein.

Jedes Kommando hat ein Hardtimeout (Spalte „dauer" mal 3). Läuft es länger, schickt der
Daemon `SIGTERM`, nach weiteren 5 s `SIGKILL`. Concurrency ist auf 1 begrenzt — kein
zweites `nala update` startet, solange das erste läuft.

## REST-API

```
GET  /v1/commands          → JSON-Liste der Allowlist mit id/scope/dauer
POST /v1/exec/{id}         → execute (body: {"args":{"unit":"loki.service"}})
                             Response: {"exit":0,"stdout":"…","stderr":"","duration_ms":1842,"correlation_id":"…"}
GET  /v1/audit?since=…     → Audit-Log (nur eigene Calls)
GET  /healthz              → 200 ok ohne Auth
```

`/healthz` ist der einzige Endpoint ohne Identity-Check — er ist read-only, ohne
Side-Effect, und nützlich für Uptime-Probes aus dem Monitoring-Stack. Alle anderen
Endpoints lösen vor dem Routing den Peer auf und matchen die Allowlist.

Response-Schema für `POST /v1/exec/{id}`:

```json
{
  "command_id": "systemd.status",
  "exit": 0,
  "stdout": "● loki.service - Loki Logging Backend\n   Active: active (running)\n   …",
  "stderr": "",
  "duration_ms": 1842,
  "correlation_id": "01J2Q7Y6XK3M0V5R9P8D4B1T2N",
  "ts_start": "2026-05-21T10:14:22.103Z",
  "ts_end":   "2026-05-21T10:14:23.945Z"
}
```

`stdout` und `stderr` werden auf 64 KiB gekappt — wer mehr braucht, soll Logs direkt
über Loki abrufen.

## Audit-Log

Append-only JSONL unter `/var/log/devopsd/audit.jsonl`, ein Eintrag pro Exec:

```json
{"ts":"2026-05-21T10:14:22.103Z","peer":"alex@github","peer_node":"macbook-alex","command_id":"systemd.status","argv":["systemctl","status","--no-pager","--","loki.service"],"exit":0,"duration_ms":1842,"correlation_id":"01J2Q7Y6XK3M0V5R9P8D4B1T2N","stdout_bytes":1842,"stderr_bytes":0,"prev_hash":"3f5c…","entry_hash":"a91e…"}
```

Felder pro Eintrag: `ts`, `peer`, `peer_node`, `command_id`, `argv`, `exit`,
`duration_ms`, `correlation_id`, `stdout_bytes`, `stderr_bytes`, `prev_hash`,
`entry_hash`. Kein `stdout` selbst ins Log — das landet nur im Response. Der Audit-Log
dokumentiert, **was** wann passiert ist, nicht **was rauskam**.

**Tamper-Evidence.** `O_APPEND` schützt nicht gegen einen kompromittierten `devopsd`
selbst. Jeder Eintrag bekommt deshalb `prev_hash` (SHA-256 des kanonischen JSON des
vorherigen Eintrags) und `entry_hash = HMAC-SHA256(k, canonical(entry_ohne_entry_hash))`.
Der HMAC-Schlüssel `k` wird **nicht** im `devopsd`-Prozess gehalten, sondern liegt unter
`/etc/devopsd-sealing/key` mode `0400 root:root` und wird beim Start in einen separaten
Hilfsprozess `devopsd-seal` (privilegienarm, drop-priv) gemmapped. Der Daemon sendet
Einträge per Unix-Domain-Socket an `devopsd-seal`, bekommt nur das resultierende
`entry_hash` zurück. Bei jedem Daemon-Start verifiziert eine Wachthund-Routine die
letzten 1024 Einträge gegen die Chain — bricht der Hash, schreibt der Daemon einen
**TAMPER**-Marker und alarmiert über `journalctl --priority=err`.

Zusätzlich wird der Audit-Log **gleichzeitig** lokal geschrieben und live an Loki via
Promtail geshippt — kompromittierte lokale Files lassen sich am Loki-Index ablesen.

Rotation über `/etc/logrotate.d/devopsd`: täglich rotieren, 7 Tage roh, 30 Tage gzipped,
1 Jahr Archive. Die Rotation ist out-of-process, der Daemon selbst hält nur den offenen
Schreib-Handle und reagiert auf `SIGHUP` mit Reopen.

## Deploy-Plan

- **systemd-Unit** `devopsd.service`:
  - User `devopsd`, Group `devopsd`, ohne Login-Shell (`/usr/sbin/nologin`).
  - `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`.
  - `ReadWritePaths=/var/log/devopsd`, sonst nichts schreibbar.
  - `RestrictAddressFamilies=AF_INET AF_UNIX` (kein IPv6, kein Raw-Socket).
  - `CapabilityBoundingSet=` (leer) — keine Caps, keine `CAP_NET_BIND_SERVICE` nötig
    bei Port 7777.
- **Binary** unter `/usr/local/bin/devopsd`, root-owned, mode `0755`.
- **Config** unter `/etc/devopsd/config.toml`, mode `0640`, owner `root:devopsd`.
  Inhalt: User-Allowlist, optional Host-spezifische Command-Overrides, Listen-Port.
- **TLS** via `tailscale cert <host>.<tailnet>` — Cert landet in
  `/var/lib/devopsd/tls/`. Renewal über `tailscale cert` läuft als Timer-Unit
  `devopsd-cert.timer`, weekly.
- **Alternative** zu eigenem TLS-Handling: `tailscale serve --bg --https=7777 http://127.0.0.1:7777`.
  Tailscale terminiert TLS, der Daemon spricht plain HTTP gegen Loopback. Spart die
  Cert-Renewal-Logik, kostet das Direkt-Binding an die Tailscale-IP.

## Threat-Model

- **Tailnet-Device kompromittiert.** Der Daemon executet im Namen des kompromittierten
  Users. Die Allowlist begrenzt blast radius auf read-only Commands plus `nala update`
  und `nala upgrade --simulate`. Kein `pkg.upgrade --yes`, kein `restic forget`, kein
  `docker rm`. Worst case im MVP: ein aktualisierter apt-Cache und eine Liste, was
  upgradebar wäre — kein State-Change am laufenden System.
- **Daemon-User erreicht Shell-Escape.** systemd-Hardening greift: kein Schreibzugriff
  außer auf `/var/log/devopsd`, kein neuer Capability-Erwerb, keine Privilege Escalation
  via SUID. Der `devopsd`-User hat keine Login-Shell, kein Home, keine sudo-Rechte.
- **Allowlist falsch konfiguriert.** Default-deny. Unbekannte `command_id` → `404 Not Found`.
  Unbekannter User in `whois` → `403 Forbidden`. Beim Daemon-Start wird die Config
  validiert (Schema-Check, Argv-Existenz auf dem `$PATH`) — bei Fehler kein Listen-Start,
  systemd schlägt Alarm.
- **Argument-Injection.** Es gibt keine User-Argumente außer aus geschlossener Enum.
  `$UNIT` ist die einzige variable Stelle, regex-validiert vor `exec`. Kein
  `os/exec` mit `sh -c`, immer direkt mit `argv []string`. Speziell `systemd.status`:
  das `--` vor `$UNIT` blockt Option-Injection (z. B. `-H remote.host.service`); ohne
  `--` wäre Remote-Hosting möglich.
- **DoS.** Rate-Limit pro Peer 30 req/min, Exec-Concurrency global 1, jedes Kommando mit
  Hardtimeout. Ein flutender Client bekommt `429 Too Many Requests`, parallele Calls
  warten oder werden mit `409 Conflict` abgelehnt.
- **Log-Tampering.** Audit-Log ist append-only über `O_APPEND`, mode `0640`, owner
  `devopsd:adm`. Wer den Log manipuliert, hat Root — und damit den Daemon-User
  überstimmt. Realer Schutz wäre Append-only-Fs oder Remote-Shipping nach Loki — Slice V0.6.
- **Manipulierte Releases / Supply-Chain.** Der Daemon wird über GitHub-Release-Tarball
  plus `install.sh` verteilt. Vor V1: Cosign-Signatur des Tarballs, SHA-256 im
  Release-Body, Reproducible-Build über Goreleaser. `install.sh` verifiziert die Signatur
  vor jedem Replace — kein blindes `curl | sh`. Ohne diese Pipeline kein
  Production-Deploy. SBOM (CycloneDX) liegt jedem Release bei.
- **Symlink-Races / TOCTOU.** Der Daemon öffnet jede Datei in `/var/log/devopsd`,
  `/var/lib/devopsd/tls/` und `/etc/devopsd` mit `O_NOFOLLOW` + `O_CLOEXEC`.
  Verzeichnis-Ownership ist `root:devopsd`, mode `0750`, keine `o+w`. Rotation und Reopen
  passieren atomar: neue Datei nach Tempname schreiben, `fsync`, `rename` — kein
  zwischenzeitliches Truncate.
- **SSRF / Client-seitige Endpoint-Redirection.** Die `devops.html`-Console hält eine
  harte Liste erlaubter Daemon-Endpoints (`100.95.132.54:7777`, `100.92.62.9:7777`).
  Jeder `fetch(target)` wird gegen diese Liste validiert; ein manipulierter
  `target_host`-Param aus URL/localStorage führt zu Klick-Refuse mit Toast, nicht zu
  einem unbeabsichtigten Request gegen einen anderen Tailnet-Host.

## Offene Fragen

- Brauchen wir `pkg.upgrade --apply` (also `nala upgrade -y`) im V1, oder erst nach
  30 Tagen Audit-Log-Auswertung mit echten Nutzungsmustern?
- Wie verteilen wir Daemon-Updates auf cachyos und server-ops — apt-Repo unter
  `apt.alexle135.de`, GitHub-Release-Tarball mit `install.sh`, oder ein Ansible-Playbook
  im homelab-Repo?
- Audit-Log nach Loki shippen über Promtail, oder reicht das lokale JSONL für die
  ersten 90 Tage?
- Wie unterscheiden wir Commands mit `host-scope: beide` zwischen den Hosts — Frontend
  schickt explizit `target_host`, oder der User wählt im UI vorher den Host und die
  Console hält den Endpoint?
- Wie verteilen wir den Sealing-Key auf neue Hosts — manuell ssh-copy + Tag im
  Setup-Runbook, oder via Ansible-Vault?

## Implementation-Slices

- **V0.2** — Build + systemd-Unit auf cachyos, nur read-only Commands (`docker.ps`,
  `systemd.status`, `tailscale.status`). Plain HTTP gegen die Tailscale-IP, kein TLS.
- **V0.3** — Audit-Log JSONL **mit Hash-Chain via `devopsd-seal` Hilfsprozess** +
  logrotate.d-Hookup + TLS via `tailscale cert` oder `tailscale serve --https=7777`.
- **V0.4** — Loki-Shipping (vorgezogen) + server-ops-Deploy + `pkg.update` und
  `pkg.upgrade-dry` auf cachyos + `restic.snapshots` auf server-ops.
- **V0.5** — Apply-Commands (`pkg.upgrade --yes`, `restic forget --prune`) nach
  abgeschlossener Audit-Phase, gegated nicht nur über `requires_confirm`, sondern
  zusätzlich über `last_tamper_check < 24h`.
- **V0.6** — Reproducible-Build-Pipeline + Cosign-Signatur + SBOM (CycloneDX) für jeden
  Release-Tarball; Dashboard für DevOps-Aktivität im Grafana-Stack aus der
  Monitoring-Spec.

## Frontend-Anbindung

Die Console hält eine fest verdrahtete Liste erlaubter Daemon-Endpoints
(`const ALLOWED_DAEMONS = ['http://100.95.132.54:7777', 'http://100.92.62.9:7777']`).
Jeder Klick auf einen Action-Button validiert das Ziel gegen diese Liste, bevor der
`fetch` losgeht — kein offener `target_host`-Parameter aus URL oder localStorage.

Die `devops.html`-Console im homelab-Frontend lädt beim Start `GET /v1/commands` und
rendert daraus die Button-Liste pro Host. Klick auf einen Button löst einen direkten
`fetch('/devopsd/v1/exec/pkg.update', {method: 'POST'})` aus, das Response landet in
einem Toast plus Detail-Panel (Exit-Code, Dauer, gekapptes stdout). Bei `403` wird
der Toast rot mit Hinweis auf die Allowlist; bei `429` mit Hinweis auf den Rate-Limit.

Die Console ist reines HTML/JS ohne Build-Step — `fetch` gegen die Tailscale-IP der
beiden Hosts, kein CORS-Stress, weil die Console selbst über das Tailnet ausgeliefert
wird. Die konkrete UI ist nicht Teil dieser Spec — hier nur die Anbindungs-Skizze:
welche Endpoints aufgerufen werden, welche Responses erwartet werden, wo die
Fehlerklassen `403`/`404`/`409`/`429` auflaufen.

## Changelog

| Datum       | Version | Änderung    |
|-------------|---------|-------------|
| 2026-05-21  | 0.1.0   | Erstentwurf |
| 2026-05-21  | 0.1.1   | Codex-Review-Findings eingearbeitet: -- vor $UNIT, Hash-Chain im Audit-Log, SSRF-/Supply-Chain-/TOCTOU-Bedrohungen, Unit-Whitelist als MVP-Pflicht |
