#!/usr/bin/env bash
# Homelab-Backup für VPS → Google Drive via rclone.
#
# Sichert:
#   - Docker-Volumes (alertmanager-data)
#   - AGH-Primary configs (/home/admin/agh)
#   - agh-sync incl. .env (Token!)
#   - monitoring incl. alertmanager/.secrets.env (Token!)
#
# Hinweis: Backup enthält Geheimnisse (.env, .secrets.env). Wenn dir
# das nicht passt: rclone-crypt-Remote dazwischenschalten. Für jetzt
# liegt's nur in deinem eigenen Google Drive, das ist der gleiche
# Vertrauenslevel wie dein Google-Konto-Login.
#
# Ziel:        gdrive:homelab-backups/vps/YYYY-MM-DD_HHMM/
# Retention:   30 Tage in der Cloud

set -euo pipefail

LOG_PREFIX="[homelab-backup-vps]"
echo "${LOG_PREFIX} starting at $(date -Iseconds)"

DATE=$(date +%Y-%m-%d_%H%M)
TMP=$(mktemp -d -t homelab-backup-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ─── 1) Docker-Volumes als tar.gz ───────────────────────────────────
for vol in alertmanager_alertmanager-data; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "${LOG_PREFIX} dumping volume ${vol}"
    docker run --rm \
      -v "${vol}:/data:ro" \
      -v "${TMP}:/backup" \
      alpine:latest \
      tar -C /data -czf "/backup/${vol}.tar.gz" .
  else
    echo "${LOG_PREFIX} volume ${vol} not found, skipping"
  fi
done

# ─── 2) Bind-Mount-Pfade via Container-Tar (weil chmod 600 / root-owned) ─
for path in agh agh-sync monitoring; do
  src="/home/admin/${path}"
  if [ -d "$src" ]; then
    echo "${LOG_PREFIX} dumping ${src}"
    docker run --rm \
      -v "${src}:/data:ro" \
      -v "${TMP}:/backup" \
      alpine:latest \
      tar -C /data -czf "/backup/host-${path}.tar.gz" \
          --exclude='*.backup-*' \
          --exclude='./work/*' \
          --exclude='./alertmanager-data/*' \
          .
  fi
done

# ─── 3) Manifest ────────────────────────────────────────────────────
{
  echo "Homelab Backup VPS ${DATE}"
  echo "Host: $(hostname)"
  echo "Generated: $(date -Iseconds)"
  echo "Files:"
  ls -la "${TMP}/" | grep -v '^total' | awk '{print "  "$NF" ("$5" bytes)"}'
} > "${TMP}/MANIFEST.txt"

# ─── 4) Upload ──────────────────────────────────────────────────────
echo "${LOG_PREFIX} uploading to gdrive:homelab-backups/vps/${DATE}/"
rclone copy "${TMP}" "gdrive:homelab-backups/vps/${DATE}/" \
  --transfers 4 \
  --stats=0

# ─── 5) Retention ───────────────────────────────────────────────────
echo "${LOG_PREFIX} pruning backups older than 30 days"
rclone delete --min-age 30d "gdrive:homelab-backups/vps/" 2>/dev/null || true
rclone rmdirs --leave-root "gdrive:homelab-backups/vps/" 2>/dev/null || true

echo "${LOG_PREFIX} done at $(date -Iseconds)"
