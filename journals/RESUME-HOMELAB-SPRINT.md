# Resume-Prompt — Homelab-Sprint Fortsetzung

Stand: 2026-05-21, ~02:00 Uhr. Token-Budget der vorherigen Session ist
fast erschöpft. Diese Datei ist Handoff für die nächste Claude-Code-
Session.

## Kontext für die neue Instanz

**Wer:** Alexander Schneider, FISI-Umschüler bei BFW Leipzig, baut
homelab als Lern- und Bewerbungs-Showcase.

**Repo:** `/Volumes/T7/Projekte/homelab/` (cwd setzen)
**GitHub:** `github.com/arn0ld87/homelab` (public, alle Commits gepusht)

**Aktive Skills (vorherige Session, sollten reaktiviert werden):**
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
| Contabo VPS (Ubuntu 24.04) | AGH-Primary, Alertmanager, Backrest (existing) | `100.92.62.9` | `tail` |
| CachyOS Desktop | AGH-Replica, Monitoring-Stack, Backrest (gerade Setup) | `100.95.132.54` | `cachyos` |
| Mac (Apple Silicon) | Arbeitsstation | `100.121.130.100` | — |

Beide SSH-Aliase funktionieren vom Mac aus, key-based, kein Passwort.

## Stand der Stacks

| Stack | Status | Notiz |
|---|---|---|
| Adblock (5 Phasen) | ✅ komplett | VPS-AGH + CachyOS-AGH + Sync + FritzBox + Tailscale-MagicDNS |
| Monitoring (3 Phasen) | ✅ komplett | Prometheus + Grafana + Loki + Promtail + ntopng, Multi-Host (VPS scraped) |
| Alerting | ✅ läuft | Alertmanager auf VPS, ntfy + Telegram, Test-Alerts kamen durch |
| Backup VPS | ✅ läuft seit Wochen | Backrest, Repo `alex` → `gdrive:alexle135-backrest-backup` |
| Backup CachyOS | 🔄 **80 % in Setup** | siehe unten |

## Wo wir stecken geblieben sind

CachyOS-Backrest:

- Container läuft auf `100.95.132.54:9898`, Admin-User in NordPass
- Repo `cachyos` mit URI `rclone:gdrive:homelab-backups-restic/cachyos`
  ist angelegt, Passphrase in NordPass „Restic Repo — CachyOS"
- Plan `Main` ist angelegt (Pfade: `/mnt/host/etc`,
  `/mnt/host/home/alex`, `/mnt/host/var/lib/docker/volumes`,
  Schedule `0 3 * * *`)
- **Aktuell**: User ist im Repo-Edit-Dialog, Sektion „Forget-Richtlinie"
  ist noch nicht aktiviert. Toggle anschalten, dann Werte:

  ```
  Schedule:  0 4 * * *
  Policy:    Time Bucketed
  Hourly:    0
  Daily:     7
  Weekly:    4
  Monthly:   6
  Yearly:    1
  KeepLastN: 3
  ```

- Danach: **„Backup Now"** auf Plan `Main` → erster Snapshot

## Was direkt danach kommt — Multihost-Sync

Architektur entschieden: **CachyOS = Server**, **VPS = Client**.

1. **VPS-Auth aktivieren** (gerade `auth.disabled: true`) —
   Settings → Auth → User anlegen, **vor** Pairing
2. **CachyOS** (Server):
   - Settings → General → Instance ID `cachyos-asus`
   - Settings → Multihost → Pairing Tokens → Generate
     (Label `vps-pairing`, TTL 1 h, Max Uses 1,
      Permissions: Read Operations `*`, Read Config `*`)
   - Token in NordPass `Backrest Pairing — VPS` zwischenspeichern
3. **VPS** (Client):
   - Settings → General → Instance ID `vps-alexle135de`
   - Settings → Multihost → Known Hosts → Add
   - Token einfügen, Instance URL `http://100.95.132.54:9898`
4. Verifikation: im CachyOS-UI sollten VPS-Operations sichtbar werden

## Loose Ends (im Repo dokumentiert, später anpacken)

- **CachyOS-AGH DoT-Timeouts** — wiederholte Timeouts zu Quad9 und
  Cloudflare in Loki sichtbar. Vermutlich IPv6-Routing oder MTU.
  Diagnose-Befehle stehen im Adblock-Journal.
- **Alertmanager-ntfy-Bridge** — aktuell roher JSON-Push,
  `alertmanager-webhook-ntfy` o. Ä. dazwischen für hübsche Titel
- **Doppelte Prometheus-Datasource** in Grafana — eine löschen
- **AGH-Query-Log nicht in Loki** — zweiter Promtail-Job auf
  `/opt/adguardhome/work/data/querylog.json`
- **CachyOS-AGH-Container nicht via Compose** — Migration auf
  `docker-compose.yml` unter `/home/alex/adguard/`
- **VPS-Backrest-Repo-Passphrase-Backup** — Datei
  `/home/admin/restic-vps-passphrase.txt` muss noch nach NordPass
  übertragen und gelöscht werden (falls noch nicht passiert)
- **CachyOS-restic-passphrase.txt** — gleiche Übung,
  `/home/alex/restic-cachyos-passphrase.txt`

## Konventionen für die nächste Session

- **Geheimnisse nie im Chat** — Tokens, Passphrasen, Chat-IDs in
  Dateien (chmod 600) oder NordPass. Audit zeigte einmal Telegram-Token
  geleakt → revoked und neu, jetzt sauber.
- **Tutor-Modus** — Schreibarbeit auf Files mache ich (lokal in
  `/Volumes/T7/Projekte/homelab/configs/` + via scp zu Hosts), 
  Klick-Arbeit in UIs macht User
- **Journal mitschreiben** — bei jedem Schritt ergänzen
  (`journals/2026-05-21-monitoring-impl.md` und
  `journals/2026-05-20-adblock-impl.md` sind die laufenden Logs).
  Stolpersteine mit Auflösung dokumentieren.
- **Bash-Hooks beachten** — kein curl/wget, kein cat/head/tail/sed
  für File-Ops. Native Write/Edit oder ctx_execute_file für Analyse.
- **`config-mode`-MCP** für Outputs > 20 Zeilen, sonst flutet das
  Context-Window

## Prompt für die neue Session

Folgendes in das frische Claude-Code-Fenster pasten:

```
cd /Volumes/T7/Projekte/homelab und lies
journals/RESUME-HOMELAB-SPRINT.md — das ist der Handoff von der
vorherigen Session. Aktiviere danach die humanizer- und
alex-writing-identity-Skills, und übernimm im Tutor-Modus weiter.
Wir stecken bei der CachyOS-Backrest-Forget-Richtlinie, danach
kommt Multihost-Sync (CachyOS = Server, VPS = Client). Stand siehe
Handoff-Datei. Bitte direkt mit knappem „verstanden + nächster
Schritt"-Update einsteigen, ohne lange Wiederholung.
```
