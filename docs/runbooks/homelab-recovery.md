---
title: Homelab Recovery — Wiederherstellung nach Total-Verlust
slug: homelab-recovery
version: 1.0.0
status: Entwurf
date: 2026-05-21
author: Alexander Schneider
scope: Schritt-für-Schritt-Wiederherstellung von cachyos + server-ops nach Hardware-Ausfall oder Provider-Wechsel
reading_time: ~30 min
---

# Homelab Recovery — Wiederherstellung nach Total-Verlust

## 1. Was hier drin steht / was nicht

Dieses Dokument ist die operative Schritt-Anleitung für den Tag, an dem
entweder die `cachyos`-Festplatte stirbt oder der Contabo-VPS hinter
`server-ops` verloren geht. Der IST-Stand der Maschinen wird (separat)
in `docs/SETUP.md` gepflegt; der geplante Soll-Stack steht in
[`specs/2026-05-20-monitoring-stack-design.md`](../../specs/2026-05-20-monitoring-stack-design.md)
und [`specs/2026-05-20-tailnet-adblock-design.md`](../../specs/2026-05-20-tailnet-adblock-design.md).
Audience: Alex selbst, um drei Uhr nachts, mit einer frischen Maschine
und ohne Geduld für Pädagogik.

Wenn ein Schritt hier mit `TBD` markiert ist, ist die Lücke nicht aus
dem Repo belegbar — bitte vor dem ersten Trockenlauf füllen.

## 2. Voraussetzungen

Bevor irgendein Recovery-Schritt anfängt: diese sechs Dinge müssen
**außerhalb** der kaputten Maschine erreichbar sein. Sonst Henne-Ei.

| # | Ressource | Quelle / Pfad | Anmerkung |
|---|---|---|---|
| 1 | Restic-Repo (Restic) | `gdrive:homelab-backups-restic/<host>` über `rclone` | Pro Host eigener Pfad — siehe [`configs/monitoring/backrest/DISASTER-RECOVERY.md`](../../configs/monitoring/backrest/DISASTER-RECOVERY.md) |
| 2 | Restic-Passphrase | Bitwarden-Eintrag „Homelab · restic · `<host>`" | Pro Host separat. Niemals im Repo, niemals im Chat |
| 3 | rclone-OAuth / Google-Login | Bitwarden-Eintrag „Google · `<gdrive-account>`" + OAuth-App `temporal-state-497009-n0` | Token läuft nach 7 Tagen — Falle, siehe §9 |
| 4 | Tailscale-Auth-Key | Tailscale Admin Console → Settings → Keys (reusable, pre-approved, tagged `tag:home`) | `${TAILSCALE_AUTHKEY}` einsetzen, wird unten in Befehlen referenziert |
| 5 | Aktuelles Repo-Clone | `git clone git@github.com:arn0ld87/homelab.git` auf einem Drittgerät | Nicht auf der kaputten Maschine versuchen zu klonen |
| 6 | VPS-Provisioning-Zugang | Contabo-Account-Login | Bitwarden-Eintrag „Contabo · root" |

`.env`-Files mit AGH-/Alertmanager-/Sync-Secrets liegen ebenfalls in
Bitwarden (Eintrag pro Stack). Sie sind **nicht** im Restic-Backup —
darum hier explizit aufgelistet.

## 3. Szenario A — cachyos-Desktop neu aufsetzen

Häufiger Fall. cachyos hält Prometheus, Grafana, Loki, ntopng,
node_exporter, AdGuard-Home-Replica, Backrest-Server und das
Restic-Repo gegen Google Drive. Recovery-Zeit realistisch 90–120 min,
wenn die Voraussetzungen aus §2 alle da sind.

1. **CachyOS-Installation.** ISO booten, Installation per
   `cachyos-installer`. Filesystem-Layout, Disk-Encryption (LUKS),
   Bootloader-Wahl: `TBD` — bitte aus früherem Setup-Doku ergänzen.
2. **Basis-Pakete.** Nach erstem Login:
   ```bash
   sudo pacman -Syu --noconfirm
   sudo pacman -S --noconfirm restic rclone docker docker-compose git curl
   sudo systemctl enable --now docker
   sudo usermod -aG docker $USER  # neu einloggen danach
   ```
3. **Tailscale installieren + joinen.** Hostname `cachyos`,
   Subnet-Router-Rolle (sofern Subnet-Routing genutzt wird, sonst weglassen):
   ```bash
   sudo pacman -S --noconfirm tailscale
   sudo systemctl enable --now tailscaled
   sudo tailscale up \
     --hostname=cachyos \
     --authkey=${TAILSCALE_AUTHKEY} \
     --accept-dns=false
   tailscale ip -4   # erwartet 100.95.132.54 (oder neu zugewiesene IP)
   ```
   `--accept-dns=false`, damit cachyos seinen lokalen AGH-Resolver
   weiter selbst betreiben kann — Tailscale-MagicDNS würde sonst
   konkurrieren.
4. **Repo-Clone nach `/home/alex/monitoring`.** Pfad entspricht dem,
   was alle Compose-Files erwarten (siehe
   [`configs/monitoring/backrest/compose.yaml`](../../configs/monitoring/backrest/compose.yaml)
   und [`configs/monitoring/backup/homelab-backup.sh`](../../configs/monitoring/backup/homelab-backup.sh)):
   ```bash
   git clone git@github.com:arn0ld87/homelab.git ~/homelab
   mkdir -p ~/monitoring
   # Compose-Files aus dem Repo in den Live-Pfad spiegeln:
   cp -a ~/homelab/configs/monitoring/* ~/monitoring/
   cp -a ~/homelab/configs/agh-cachyos    ~/monitoring/agh
   ```
5. **rclone-Remote `gdrive` einrichten.** Pflicht bevor Restic an die
   Snapshots kommt:
   ```bash
   rclone config
   # n → name "gdrive" → drive → leere client_id → scope 1
   # Auto-Config: y → Browser-OAuth → Token kommt zurück
   # Shared Drive: n → y (confirm) → q (quit)
   rclone lsd gdrive:   # sanity check, Liste der Drive-Ordner
   ```
   Wenn das Headless läuft (z. B. Recovery über SSH): `rclone authorize "drive"`
   auf einer Maschine mit Browser ausführen und Token-Blob auf cachyos
   einspielen.
6. **Restic-Repo öffnen + Snapshots prüfen.** Vorher Passphrase aus
   Bitwarden in eine Datei mit `chmod 600` ablegen:
   ```bash
   echo -n "${RESTIC_PASSWORD}" > ~/restic-passphrase.txt
   chmod 600 ~/restic-passphrase.txt
   export RESTIC_REPOSITORY="rclone:gdrive:homelab-backups-restic/cachyos"
   export RESTIC_PASSWORD_FILE=~/restic-passphrase.txt
   restic snapshots --last 5
   ```
   Erwartet: chronologische Liste mit IDs und Pfaden. Bei
   `Fatal: wrong password` → Bitwarden-Eintrag prüfen, kein Zeilenumbruch
   am Datei-Ende. Bei `repository is already locked` → §7.
7. **Trockenlauf-Restore.** Vor dem echten Restore einmal ohne Schreiben
   prüfen, was zurückkäme:
   ```bash
   restic restore latest --target /tmp/restore-dryrun --dry-run \
     --include /home/alex/monitoring \
     --include /home/alex/adguard \
     --include /etc
   ```
8. **Echter Restore.** Wenn der Trockenlauf passt:
   ```bash
   restic restore latest --target /tmp/restore \
     --include /home/alex/monitoring \
     --include /home/alex/adguard \
     --include /etc \
     --include /var/lib/docker/volumes
   sudo cp -a /tmp/restore/home/alex/monitoring/. ~/monitoring/
   sudo cp -a /tmp/restore/home/alex/adguard      /home/alex/adguard
   sudo cp -a /tmp/restore/var/lib/docker/volumes/. /var/lib/docker/volumes/
   ```
   Volumes-Restore nur, wenn Prometheus-TSDB / Loki-Chunks /
   Grafana-DB wirklich gebraucht werden. Wer mit leerem TSDB starten
   will (sauberer Cut), lässt den `volumes`-Include weg.
9. **`.env`-Files aus Bitwarden zurückspielen.** Eine pro Stack:
   - `~/monitoring/agh-sync/.env` — falls hier mitlaufend
   - `~/monitoring/alertmanager/.secrets.env` (siehe Template
     [`alertmanager.yml.tpl`](../../configs/monitoring/alertmanager/alertmanager.yml.tpl):
     `NTFY_TOPIC`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`)
   - `~/.grafana-token` (`chmod 600`) — wird in Journal
     [`2026-05-21-monitoring-impl.md`](../../journals/2026-05-21-monitoring-impl.md) erwähnt
10. **AdGuard-Home-Container hochfahren.** Konfig liegt jetzt in
    `/home/alex/adguard/{conf,work}` (aus Restore) und das Compose ist
    [`configs/agh-cachyos/docker-compose.yml`](../../configs/agh-cachyos/docker-compose.yml):
    ```bash
    cd ~/monitoring/agh
    docker compose up -d
    docker compose logs --tail 20 adguardhome
    dig @127.0.0.1 doubleclick.net +short   # erwartet 0.0.0.0
    ```
11. **Monitoring-Stack hochziehen.** Einer nach dem anderen, damit
    Fehler einzeln gesehen werden:
    ```bash
    cd ~/monitoring/node_exporter && docker compose up -d
    cd ~/monitoring/prometheus    && docker compose up -d
    cd ~/monitoring/loki          && docker compose up -d   # bringt Promtail mit
    cd ~/monitoring/grafana       && docker compose up -d
    cd ~/monitoring/ntopng        && docker compose up -d
    docker ps   # erwartet 6+ container running
    ```
12. **Backrest-Server-Container starten.** Compose:
    [`configs/monitoring/backrest/compose.yaml`](../../configs/monitoring/backrest/compose.yaml).
    Repo-Pfad wird in der Backrest-UI manuell wieder eingehängt
    (`gdrive:homelab-backups-restic/cachyos`, Passphrase aus
    `~/restic-passphrase.txt`). Wichtig: **nicht** gleichzeitig auf
    server-ops einen Backrest-Server für dasselbe Repo laufen lassen —
    siehe §9 letzter Eintrag.
    ```bash
    cd ~/monitoring/backrest && docker compose -f compose.yaml up -d
    # Web-UI: http://100.95.132.54:9898 (Tailnet only)
    ```
13. **Verify.** Siehe §8.

## 4. Szenario B — server-ops-VPS neu aufsetzen

server-ops trägt den AGH-Primary, node_exporter + Promtail (Push gegen
cachyos:3100), Alertmanager, agh-sync-Container und den
Backrest-Client. Recovery-Zeit realistisch 45–60 min.

1. **VPS provisionieren.** Contabo Web-UI → neuer VPS, Debian 12 (LTS),
   IPv4 + IPv6, SSH-Key Upload. Hostname `server-ops` setzen
   (`hostnamectl set-hostname server-ops`).
2. **Initial-Hardening.** Erste fünf Minuten nach root-Login:
   ```bash
   apt update && apt -y full-upgrade
   apt install -y nala ufw unattended-upgrades fail2ban
   # SSH-Key only:
   sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
   systemctl reload ssh
   # Firewall:
   ufw default deny incoming
   ufw default allow outgoing
   ufw allow 22/tcp
   ufw --force enable
   dpkg-reconfigure -plow unattended-upgrades
   ```
   Detail-Hardening (User `admin` statt root, ssh-Port, etc.): `TBD` —
   bitte aus existierender Praxis ergänzen.
3. **Tailscale.** Hostname `server-ops` (gleicher Tag wie cachyos,
   damit ACLs greifen):
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   # --accept-dns=false aus dem gleichen Grund wie auf cachyos (Schritt 3):
   # der Host soll seinen eigenen AGH-Resolver (Primary) selbst betreiben
   # und nicht via MagicDNS überschrieben werden.
   tailscale up --hostname=server-ops --authkey=${TAILSCALE_AUTHKEY} --accept-dns=false
   tailscale ip -4   # erwartet 100.92.62.9 oder neue IP
   ```
4. **Docker + Compose.**
   ```bash
   nala install -y docker.io docker-compose-plugin git
   systemctl enable --now docker
   usermod -aG docker admin
   ```
5. **Repo-Clone nach `/home/admin/`.** Pfade entsprechen
   [Journal Schritt 8](../../journals/2026-05-20-adblock-impl.md):
   ```bash
   sudo -u admin -i
   git clone git@github.com:arn0ld87/homelab.git ~/homelab
   mkdir -p ~/agh ~/agh-sync ~/monitoring
   cp ~/homelab/configs/agh-sync/docker-compose.yml ~/agh-sync/
   cp -a ~/homelab/configs/monitoring/vps-agents/. ~/monitoring/
   cp -a ~/homelab/configs/monitoring/alertmanager ~/monitoring/alertmanager
   ```
   Eigene Compose-Datei für den VPS-AGH (`agh-primary`): aus Journal
   2026-05-20 nachbauen (`/home/admin/agh/docker-compose.yml`,
   Bind auf `${TAILSCALE_IP_VPS}`), oder `TBD` einlesen, sobald die in
   `configs/` versioniert ist.
6. **`.env`-Files zurückspielen.** Aus Bitwarden:
   - `~/agh/.env` mit `TAILSCALE_IP_VPS=100.92.62.9` (neue IP einsetzen,
     falls Tailnet sie geändert hat)
   - `~/agh-sync/.env` mit `ORIGIN_*` (VPS-AGH-Admin) und `REPLICA1_*`
     (CachyOS-AGH-Admin) — Template steht oben im Compose-File
     [`configs/agh-sync/docker-compose.yml`](../../configs/agh-sync/docker-compose.yml)
   - `~/monitoring/alertmanager/.secrets.env` (`NTFY_TOPIC`,
     `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`)
   - `chmod 600 ~/agh/.env ~/agh-sync/.env ~/monitoring/alertmanager/.secrets.env`
7. **node_exporter + Promtail starten.** Beide pushen / liefern an
   cachyos:
   ```bash
   cd ~/monitoring/node_exporter && docker compose up -d
   cd ~/monitoring/promtail      && docker compose up -d
   curl -s http://localhost:9100/metrics | head -5
   ```
   Verify auf cachyos: in Prometheus-UI `Status → Targets` muss
   `server-ops:9100` als `up` auftauchen.
8. **Alertmanager starten.**
   ```bash
   cd ~/monitoring/alertmanager && docker compose up -d
   curl -s http://localhost:9093/-/healthy
   ```
   Bridge `alertmanager-ntfy` für lesbare Titel: `TBD` (steht im
   Journal als loose end vom 2026-05-21).
9. **Backrest-Client starten.** Auf server-ops ist Backrest
   **Multihost-Client** (siehe CLAUDE.md, Hosts-Tabelle), die
   Server-Rolle liegt auf cachyos. Compose-Datei für den Client-Mode:
   `TBD` — aktuell nur die Server-Variante
   [`compose.yaml`](../../configs/monitoring/backrest/compose.yaml) im
   Repo. Pragmatisch: gleichen Compose nehmen, aber im UI gegen das
   bestehende `gdrive:homelab-backups-restic/vps`-Repo verbinden und
   keinen Server-Endpoint exponieren.
10. **AGH-Fallback starten (Primary auf VPS).** Compose aus
    `~/agh/docker-compose.yml` (Schritt 5 oben). AGH-yaml-Restore
    optional aus Restic-Snapshot:
    ```bash
    # Passphrase aus Bitwarden-Eintrag "Homelab · restic · server-ops"
    # in lokale Datei mit chmod 600. Niemals committen.
    echo -n "${RESTIC_PASSWORD}" > ~/restic-passphrase.txt
    chmod 600 ~/restic-passphrase.txt
    export RESTIC_REPOSITORY="rclone:gdrive:homelab-backups-restic/vps"
    export RESTIC_PASSWORD_FILE=~/restic-passphrase.txt
    restic restore latest --target /tmp/restore --include /home/admin/agh
    sudo cp -a /tmp/restore/home/admin/agh/. /home/admin/agh/
    cd /home/admin/agh && docker compose up -d
    ```
    Wenn kein Snapshot greifbar: Wizard wie in Journal 2026-05-20
    Schritt 3 neu durchgehen, dann sync übernimmt CachyOS-Filter
    binnen 5 Minuten.
11. **Verify.** Siehe §8.

## 5. Szenario C — Nur ein Service stirbt

Kein Total-Restore, nur Container re-create. Reihenfolge egal, Repo-
Zustand reicht.

| Service | Host | Recovery-Befehl |
|---|---|---|
| Prometheus | cachyos | `cd ~/monitoring/prometheus && docker compose -f docker-compose.yml up -d --force-recreate` |
| Grafana | cachyos | `cd ~/monitoring/grafana && docker compose up -d --force-recreate` |
| Loki + Promtail | cachyos | `cd ~/monitoring/loki && docker compose up -d --force-recreate` |
| ntopng | cachyos | `cd ~/monitoring/ntopng && docker compose up -d --force-recreate` |
| node_exporter | beide | `cd ~/monitoring/node_exporter && docker compose up -d --force-recreate` |
| AdGuard Home (Replica) | cachyos | `cd ~/monitoring/agh && docker compose up -d --force-recreate` |
| AdGuard Home (Primary) | server-ops | `cd ~/agh && docker compose up -d --force-recreate` |
| adguardhome-sync | server-ops | `cd ~/agh-sync && docker compose up -d --force-recreate` |
| Alertmanager | server-ops | `cd ~/monitoring/alertmanager && docker compose up -d --force-recreate` |
| Backrest (Server) | cachyos | `cd ~/monitoring/backrest && docker compose -f compose.yaml up -d --force-recreate` |

Wenn `--force-recreate` einen Volume-Konflikt wirft: `docker compose down`
zuerst, dann `up -d`. **Niemals** `down --volumes` für Prometheus, Loki,
Grafana, AGH — das nuked die Daten.

## 6. Restic-Restore-Detail

Diese Befehle sind die Single-Source-of-Truth-Variante aus
[`configs/monitoring/backrest/DISASTER-RECOVERY.md`](../../configs/monitoring/backrest/DISASTER-RECOVERY.md).
Funktioniert auf jedem System mit Restic-Binary, ohne Backrest-UI.

```bash
# Repo öffnen
export RESTIC_REPOSITORY="rclone:gdrive:homelab-backups-restic/<host>"
export RESTIC_PASSWORD_FILE=~/restic-passphrase.txt

# Liste der Snapshots
restic snapshots --last 10

# Trockenlauf
restic restore latest --target /tmp/restore-dryrun --dry-run

# Restore eines bestimmten Pfads
restic restore latest --target /tmp/restore \
  --include /home/alex/monitoring

# Spezifischer Snapshot per ID
restic restore <snap-id> --target /tmp/restore

# Integrität prüfen, wenn etwas komisch aussieht
restic check
```

Typische Fehlermodi:

- `Fatal: wrong password or no key found` → Passphrase falsch. Bitwarden-
  Eintrag „Homelab · restic · `<host>`" prüfen. Kein Trailing-Newline.
- `unable to open config file: ... repository is already locked by ...`
  → Vorheriger Restic-/Backrest-Prozess hängt im Lock-State.
  Vorsichtig:
  ```bash
  restic unlock                   # bei eigenem stale lock
  restic unlock --remove-all      # nur wenn sicher keine andere
                                  # Instanz parallel zugreift
  ```
- `failed to download <pack>` mit gdrive-Quota-Error → `rclone config
  reconnect gdrive:` um OAuth-Token neu zu holen. Falls
  `App not verified`: §9 erster Punkt.

## 7. Wiederherstellung der Tailscale-ACLs

Wenn die ACL-Config in der Tailscale Admin Console selbst verloren ist:

1. Login auf https://login.tailscale.com → Admin Console → Access Controls.
2. Wenn ein ACL-JSON-Backup vorliegt (Bitwarden-Eintrag „Tailscale · ACL"):
   einfügen, Save, Test.
3. Wenn kein Backup: minimal-Set, das den Recovery freischaltet:
   ```json
   {
     "tagOwners": {
       "tag:home": ["autogroup:admin"]
     },
     "acls": [
       { "action": "accept", "src": ["tag:home"], "dst": ["tag:home:*"] }
     ],
     "ssh": [
       { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:home"], "users": ["root", "alex", "admin"] }
     ]
   }
   ```
   Danach beide Hosts mit `--advertise-tags=tag:home` neu joinen (oder
   `tailscale set --advertise-tags=tag:home`).

ACLs feiner schneiden (Subnet-Routes, exit-Nodes, Magic-DNS-Split):
`TBD` — bitte die aktuell genutzten Tags + Routes hier eintragen,
sobald die ACL-Datei einmal im Bitwarden archiviert wurde.

## 8. Selbst-Test nach Recovery

Erst grün abhaken, dann ist Recovery „done".

- [ ] `tailscale status` zeigt beide Hosts mit korrekten Tailnet-IPs
- [ ] `dig @100.95.132.54 doubleclick.net +short` → `0.0.0.0` (CachyOS-AGH)
- [ ] `dig @100.92.62.9 doubleclick.net +short` → `0.0.0.0` (VPS-AGH)
- [ ] `curl -fsS http://100.95.132.54:9090/-/healthy` → `Prometheus Server is Healthy.`
- [ ] `curl -fsS http://100.95.132.54:3001/api/health` → `{"database":"ok","version":...}`
- [ ] `curl -fsS http://100.95.132.54:3100/ready` → `ready`
- [ ] `curl -fsS http://100.92.62.9:9093/-/healthy` → 200
- [ ] Prometheus-UI `Status → Targets` zeigt cachyos:9100 und server-ops:9100 als `up`
- [ ] Grafana-Dashboard „CachyOS Host" zeigt Werte der letzten 5 min
- [ ] Grafana-Dashboard „multi-host-overview" zeigt beide Hosts
- [ ] `devops.html` (lokal im Browser) — alle 12 Heartbeat-Badges grün
- [ ] `restic snapshots --last 5` auf beiden Hosts zeigt frische Snapshots
- [ ] AGH-Stats (`http://100.92.62.9:3000`) zeigen Queries der letzten Stunde
- [ ] Test-Alert: `amtool alert add testalert severity=critical` auf
      server-ops → ntfy-Push empfangen, Telegram-Nachricht erhalten

## 9. Bekannte Fallstricke

Aus den Journals 2026-05-20 + 2026-05-21 zusammengezogen — Punkte, die
einen Recovery sonst nachts um drei verlängern.

- **gdrive-OAuth-Token 7-Tage-Falle.** Wenn die OAuth-App
  (`temporal-state-497009-n0`) im Google-Console-Status „Testing" steht,
  läuft jedes Refresh-Token nach 7 Tagen ab und Backups + Restore
  sterben mit `oauth2: token expired`. Fix: OAuth-App auf **„In
  Production"** schieben, oder Service-Account-JSON statt OAuth nutzen.
  Loose end aus CLAUDE.md.
- **CachyOS-AGH DoT-Timeouts.** `tls://dns.quad9.net:853` und
  `tls://1.1.1.1:853` zeigen periodische Timeouts in Loki-Logs. Wenn
  Recovery direkt nach Reboot fehlschlägt: kurz warten, Bootstrap-DNS
  (9.9.9.9 / 1.1.1.1) prüfen, IPv6-Routing checken (`ping6 -c 1
  dns.quad9.net`).
- **Doppelte Prometheus-Datasource in Grafana.** Bei provisioniertem
  Setup kommt manchmal ein zweiter Auto-Eintrag dazu (`Prometheus` +
  `prometheus`). Nach Restore: im Grafana-UI eine löschen, sonst
  zeigen Dashboards leere Panels (falsche UID).
- **AGH-Query-Log → Loki.** Promtail liest aktuell nur stdout. Der
  Query-Log liegt in `/home/alex/adguard/work/data/querylog.json` und
  kommt erst mit dem zusätzlichen `static_configs`-Job rein (PR #4).
  Wenn `{container="adguardhome"}` in Grafana keine Block-Events zeigt:
  das ist erwartet, kein Bug.
- **Backrest-Multihost-Topologie.** cachyos = Server, server-ops =
  Client. **Nicht beide gleichzeitig** Backrest-Server gegen dasselbe
  Restic-Repo laufen lassen — Repo-Lock-Konflikte und korrupte
  Snapshot-Indizes. Wenn ein Recovery die Rollen tauscht, vorher den
  alten Container hart stoppen (`docker stop backrest`).
- **AGH-Port-Default 80.** Frischer AGH-Container nach Restore lauscht
  intern wieder auf `0.0.0.0:80`, das Docker-Port-Mapping in Compose
  erwartet aber 3000. Nach Restore von `AdGuardHome.yaml` prüfen,
  dass `http.address: 0.0.0.0:3000` (Stolperstein 8 aus
  [Journal 2026-05-20](../../journals/2026-05-20-adblock-impl.md)).
- **Prometheus läuft als UID 65534.** Named Volume statt Bind-Mount
  benutzen — bei Bind-Mount-Restore unter falschem Owner crasht der
  Container.
- **Loki rejects old samples.** Nach Restore mit alten Logs kommt
  `entry has timestamp too old`. `reject_old_samples: false` in
  `loki-config.yml` ist dafür da, sollte aus Restic-Restore mitkommen
  — falls nicht: manuell setzen, Loki neu starten.
- **Tailscale-Override auf macOS überstimmt DHCP-DNS.** Wer von
  einem Mac aus testen will, ob CachyOS-AGH auf LAN-IP funktioniert:
  `dig @192.168.178.74` direkt — `scutil --dns` zeigt sonst nur den
  Tailscale-Resolver.

## 10. Häufigkeit

Trockenlauf einmal pro Quartal — wegwerfbare VM (libvirt /
VirtualBox / Multipass), eine der Szenarien §3 oder §4 von Schritt 1
bis Verify. Erkenntnisse als Journal-Eintrag mit Slug
`YYYY-MM-DD-recovery-dryrun-<host>.md` ablegen, Soll/Ist/Lernpunkt-Schema
wie alle anderen Journals.

Bei jeder strukturellen Änderung am Stack (neuer Service, neuer Host,
neuer Backup-Pfad): dieses Runbook im **selben PR** mitaktualisieren,
sonst läuft es stillschweigend tot.

## 11. Changelog

| Datum | Version | Änderung |
|---|---|---|
| 2026-05-21 | 1.0.0 | Initial-Entwurf — Szenarien A/B/C, Restic-Detail, Selbst-Test, Fallstricke aus Journals und DISASTER-RECOVERY.md. |
