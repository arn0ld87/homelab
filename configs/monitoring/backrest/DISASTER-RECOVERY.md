# Disaster Recovery — Restic-Backup-Restore ohne Backrest

Backrest ist nur eine Web-UI um Restic. Das Backup selbst ist ein
verschlüsseltes Restic-Repo im Google Drive. Du brauchst Backrest
**nicht**, um zu restoren — Restic ist Single-Binary für jedes OS.

## Was du NICHT im Backup haben darfst

Die drei Dinge müssen unabhängig vom zu sichernden System verfügbar
sein, sonst Henne-Ei-Problem.

1. **Restic-Repo-Passphrase pro Repo**
   → Bitwarden / Passwortmanager mit Eintrag pro Host
2. **Google-Konto-Login** für rclone-OAuth-Neu-Auth
   → Passwortmanager
3. **Diese Doku selbst**
   → liegt in github.com/arn0ld87/homelab (nicht in VPS/CachyOS)

## Repos im Drive

| Host    | Repo-Pfad                                            |
|---------|-------------------------------------------------------|
| VPS     | `gdrive:homelab-backups-restic/<...>` (in Backrest)   |
| CachyOS | `gdrive:homelab-backups-restic/cachyos` (geplant)     |

## Restore von Null

Frische Ubuntu-VM, Internet, kein Backrest, kein altes System.

### 1. Tools installieren

```bash
sudo apt update && sudo apt install -y restic rclone
```

### 2. rclone für Google Drive konfigurieren

```bash
rclone config
# n → name "gdrive" → drive → leere client_id → scope 1
# Auto-Config: y → Browser-OAuth → Token kommt zurück
# Shared Drive: n → y (confirm) → q (quit)
rclone lsd gdrive:    # Sanity-Check
```

### 3. Restic-Repo öffnen

```bash
export RESTIC_REPOSITORY="rclone:gdrive:homelab-backups-restic/cachyos"
export RESTIC_PASSWORD_FILE=~/restic-passphrase.txt   # aus Bitwarden
# oder direkt:
export RESTIC_PASSWORD="<passphrase>"

restic snapshots
# Liste der Backup-Zeitpunkte mit ID, Datum, Pfaden
```

### 4. Restore

```bash
# Letzten Snapshot komplett zurück
restic restore latest --target /tmp/restore

# Nur bestimmter Pfad
restic restore latest --target /tmp/restore \
  --include /home/alex/monitoring

# Spezifischer Snapshot per ID
restic restore <snap-id> --target /tmp/restore
```

### 5. Container wiederherstellen

```bash
# Compose-Files zurückspielen
cp -a /tmp/restore/home/alex/monitoring /home/alex/

# Docker-Volumes neu anlegen aus Restored Daten
# (Volumes liegen unter /var/lib/docker/volumes/)
sudo cp -a /tmp/restore/var/lib/docker/volumes/* /var/lib/docker/volumes/

# Stacks hochfahren
cd /home/alex/monitoring/prometheus && docker compose up -d
cd /home/alex/monitoring/grafana    && docker compose up -d
cd /home/alex/monitoring/loki       && docker compose up -d
# usw.
```

## Verifikation nach Restore

```bash
# Container laufen?
docker ps

# Endpoints erreichbar?
curl -s http://localhost:9090/-/healthy   # Prometheus
curl -s http://localhost:3001/login        # Grafana
curl -s http://localhost:3100/ready        # Loki

# Letzte Daten im Grafana sichtbar?
# → Browser auf :3001, Dashboard "CachyOS Host"
```

## Wenn Backrest selbst weg ist, aber das Restic-Repo noch existiert

Du brauchst Backrest gar nicht. Restic-Binary reicht für 100 % des
Funktionsumfangs außer der schönen UI. Restore wie oben — Backrest
neu aufsetzen kannst du danach in Ruhe.

## Wenn das Restic-Repo selbst im Drive korrupt ist

Selten, aber möglich. Restic hat eingebaute Verify:

```bash
restic check
# prüft Index + Datenintegrität
```

Wenn `restic check` Fehler findet, ist Daten-Recovery aus Restic-Repos
ein eigenes Kapitel. Vor diesem Punkt: zweite Backup-Kopie woanders
(zweites Cloud-Provider oder Offline-Festplatte) — bei wichtigen
Daten Standard.
