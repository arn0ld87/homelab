# Resume-Prompt — Homelab-Sprint Fortsetzung

Stand: 2026-05-21, ~12:30 Uhr. Handoff für die nächste
Claude-Code-Session.

## Kontext für die neue Instanz

**Wer:** Alexander Schneider, FISI-Umschüler bei BFW Leipzig, baut
homelab als Lern- und Bewerbungs-Showcase.

**Repo:** `/Volumes/T7/Projekte/homelab/` (cwd setzen)
**GitHub:** `github.com/arn0ld87/homelab` (public, alle Commits gepusht)

**Aktive Skills (sollten reaktiviert werden):**
- `humanizer` — AI-Floskeln raus, deutsche Sachlichkeit
- `anthropic-skills:alex-writing-identity` — Modus „dokumentation/tutor"
- Tutor-Prinzip: ich erkläre und übernehme Schreibarbeit, User klickt
  und tippt selbst auf seinen Hosts

**User-Traits (aus Honcho):**
- Quality-Gate Collaborator — explizit Pushback erwünscht
- Audit-focused — nachvollziehbare Schritte > Quick-Fixes
- Tone-Disziplin: keine Buzzwords, keine Marketing-Floskeln,
  keine inflationären Em-Dashes

## Infrastruktur-Übersicht

| Host | Rolle | Tailscale-IP | SSH-Alias |
|---|---|---|---|
| Contabo VPS (Ubuntu 24.04) | AGH-Primary, Alertmanager, Backrest 1.13.0 | `100.92.62.9` | `tail` |
| CachyOS Desktop | AGH-Replica, Monitoring-Stack, Backrest 1.13.0 | `100.95.132.54` | `cachyos` |
| Mac (Apple Silicon) | Arbeitsstation | `100.121.130.100` | — |

## Stand der Stacks

| Stack | Status | Notiz |
|---|---|---|
| Adblock (5 Phasen) | ✅ komplett | VPS-AGH + CachyOS-AGH + Sync + FritzBox + Tailscale-MagicDNS |
| Monitoring (3 Phasen) | ✅ komplett | Prometheus + Grafana + Loki + Promtail + ntopng |
| Alerting | ✅ läuft | Alertmanager auf VPS, ntfy + Telegram |
| Backup VPS | ✅ Wochen produktiv | Repo `alex` → `gdrive:alexle135-backrest-backup` |
| Backup CachyOS | ✅ Initial-Backup durch | Repo `cachyos` → `gdrive:homelab-backups-restic/cachyos` |
| Multihost-Pairing | ✅ aktiv | CachyOS = Server, VPS = Client, beide Hosts in einer UI |

Sprint-Details: [`2026-05-21-backrest-impl.md`](2026-05-21-backrest-impl.md)

## Was heute am 21.05. abgeschlossen wurde

- CachyOS-Backrest-Initial-Backup (55 GB) durchgelaufen
- rclone-Mount auf RW gesetzt (`:ro` killte Token-Refresh)
- Restic-Pack-Size + rclone-Drosseln per `RCLONE_*`-Env-Vars
- VPS-Backrest von 1.12.1 auf 1.13.0 (Multihost-Voraussetzung)
- Multihost-Pairing CachyOS ↔ VPS via Pairing-Token
- Eigenes Google-Cloud-OAuth-Projekt für Drive
  (`temporal-state-497009-n0`), eigener Quota
- OAuth-App auf „In Production" — kein 7-Tage-Token-Tod mehr
- Beide Klartext-Passphrasen-Files mit `shred -uz` entsorgt,
  NordPass ist Single Source of Truth
- Forget-Policies auf `cachyos`- und `alex`-Repo definiert

## Offener Diskussionspunkt

**Grafana-Datasource-Diskrepanz:**

DB-Stand nach Cleanup (verifiziert via SQLite):

| id | name | uid | default |
|---|---|---|---|
| 2 | `Prometheus` | `cfmoy44jnnv28b` | ja |
| 3 | `Loki` | `efmoz6gihqwhsd` | nein |

Alex meldete dennoch „immer noch 2 Prometheus" in der UI. Hard-Reload
(Cmd+Shift+R) und ggf. Screenshot anfordern. Wenn Bild nach Hard-Reload
bleibt: prüfen, ob die zweite Erwähnung in einer anderen Stelle steht
(Dashboard-Variable, Alerting-Picker, Service-Account-Permissions).

## Loose Ends in priorisierter Reihenfolge

1. **Alertmanager-ntfy-Bridge** — aktuell roher JSON-Push,
   `alertmanager-webhook-ntfy` o. Ä. dazwischen für hübsche Titel
2. **AGH-Query-Log in Loki** — zweiter Promtail-Job auf
   `/opt/adguardhome/work/data/querylog.json` (VPS + CachyOS)
3. **CachyOS-AGH-Container in Compose migrieren** — aktuell
   händisch via `docker run`, Migration auf
   `/home/alex/adguard/docker-compose.yml`
4. **CachyOS-AGH DoT-Timeouts** — wiederholte Timeouts zu Quad9 und
   Cloudflare in Loki sichtbar. Vermutlich IPv6-Routing oder MTU.
   Diagnose-Befehle stehen im Adblock-Journal.

## Konventionen für die nächste Session

- **Geheimnisse nie im Chat** — Tokens, Passphrasen, Chat-IDs in
  Dateien (chmod 600) oder NordPass
- **Tutor-Modus** — Schreibarbeit auf Files mache ich (lokal in
  `/Volumes/T7/Projekte/homelab/configs/` + via scp zu Hosts),
  Klick-Arbeit in UIs macht User
- **Journal mitschreiben** — bei jedem Schritt ergänzen
  (`journals/2026-05-21-backrest-impl.md` ist das letzte Tageslog).
  Stolpersteine mit Auflösung dokumentieren
- **Bash-Hooks beachten** — kein curl/wget, kein cat/head/tail/sed
  für File-Ops. Native Write/Edit oder ctx_execute_file für Analyse
- **`context-mode`-MCP** für Outputs > 20 Zeilen, sonst flutet das
  Context-Window

## Prompt für die neue Session

Folgendes in das frische Claude-Code-Fenster pasten:

```
cd /Volumes/T7/Projekte/homelab und lies
journals/2026-05-21-backrest-impl.md — das ist das Tageslog vom
21.05.2026, in dem CachyOS-Backrest, Multihost-Pairing,
Drive-OAuth-Eigenprojekt und Passphrase-Cleanup abgearbeitet
wurden. Aktiviere danach die humanizer- und
alex-writing-identity-Skills, übernimm im Tutor-Modus.

Stand:
- CachyOS-Backup durch, eigener OAuth-Client auf Production,
  Token-Tod-Risiko gebannt.
- VPS-Backrest 1.13.0, Multihost mit CachyOS gepairt.
- Klartext-Passphrasen entsorgt (shred -uz), NordPass ist Single
  Source of Truth.
- Grafana: DB hat nur EINE Prometheus-Datasource (id=2,
  uid cfmoy44jnnv28b), aber die UI zeigt laut Alex immer noch
  zwei. Selbst-Check auf Cache durch Hard-Reload (Cmd+Shift+R)
  steht aus — wenn das Bild bleibt: Screenshot anfordern und
  prüfen, ob es die Connections-Liste ist oder eine andere
  Stelle (Dashboard-Variable, Alerting-Picker, Service-Account-
  Permissions).

Offene Loose Ends aus dem Handoff:
- Alertmanager-ntfy-Bridge (alertmanager-webhook-ntfy o. Ä.)
- AGH-Query-Log noch nicht in Loki — zweiter Promtail-Job auf
  /opt/adguardhome/work/data/querylog.json (VPS) und Pendant
  auf CachyOS
- CachyOS-AGH-Container nicht via Compose — Migration auf
  /home/alex/adguard/docker-compose.yml
- CachyOS-AGH DoT-Timeouts zu Quad9/Cloudflare diagnostizieren

Erst Grafana-Discrepancy klären, dann Loose Ends in der
gelisteten Reihenfolge anpacken (ntfy zuerst, Querylog danach).
Bitte direkt mit knappem "verstanden + nächster Schritt"-
Update einsteigen, ohne lange Wiederholung.
```
