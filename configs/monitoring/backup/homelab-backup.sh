#!/usr/bin/env bash
# Homelab-Backup → Google Drive via rclone.
#
# Sichert:
#   - Docker-Volumes (Prometheus-TSDB, Loki-Chunks, Grafana-DB)
#   - AGH-Bind-Mount-Daten (conf + work)
#   - Compose-Files (ohne flüchtige work/data-Pfade)
#
# Ziel:        gdrive:homelab-backups/cachyos/YYYY-MM-DD_HHMM/
# Retention:   30 Tage in der Cloud, lokal nichts (tmp wird aufgeräumt)
# Aufruf:      manuell via systemctl --user start homelab-backup.service
#              automatisch via Timer um 03:00 (siehe .timer-Unit)

set -euo pipefail

LOG_PREFIX="[homelab-backup]"
echo "${LOG_PREFIX} starting at $(date -Iseconds)"

DATE=$(date +%Y-%m-%d_%H%M)
TMP=$(mktemp -d -t homelab-backup-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ─── 1) Docker-Volumes als tar.gz ───────────────────────────────────
for vol in prometheus_tsdb loki_loki-data grafana_grafana-data; do
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

# ─── 2) AGH-Configs (via Container, weil chmod-600 root-owned) ──────
# Reasoning: AGH läuft im Container als root, schreibt root-owned Files
# in den Bind-Mount. alex kann sie nicht lesen. Workaround: tar im
# alpine-Container, der als root läuft.
if [ -d /home/alex/adguard/conf ]; then
  echo "${LOG_PREFIX} dumping adguard configs"
  docker run --rm \
    -v /home/alex/adguard:/data:ro \
    -v "${TMP}:/backup" \
    alpine:latest \
    tar -C /data -czf "/backup/adguard-conf.tar.gz" \
        --exclude='*.backup-*' \
        conf work 2>/dev/null || \
  docker run --rm \
    -v /home/alex/adguard:/data:ro \
    -v "${TMP}:/backup" \
    alpine:latest \
    tar -C /data -czf "/backup/adguard-conf.tar.gz" conf
fi

# ─── 3) Compose-Files snapshotten (ohne flüchtige Pfade) ────────────
if [ -d /home/alex/monitoring ]; then
  echo "${LOG_PREFIX} dumping monitoring composes"
  tar -czf "${TMP}/monitoring-composes.tar.gz" \
    --exclude='*/work/*' \
    --exclude='*/data/*' \
    --exclude='*/.git/*' \
    -C /home/alex monitoring
fi

# ─── 4) Manifest schreiben ─────────────────────────────────────────
{
  echo "Homelab Backup ${DATE}"
  echo "Host: $(hostname)"
  echo "Generated: $(date -Iseconds)"
  echo "Files:"
  ls -la "${TMP}/" | grep -v '^total' | awk '{print "  "$NF" ("$5" bytes)"}'
} > "${TMP}/MANIFEST.txt"

# ─── 5) Upload zu Google Drive ─────────────────────────────────────
echo "${LOG_PREFIX} uploading to gdrive:homelab-backups/cachyos/${DATE}/"
rclone copy "${TMP}" "gdrive:homelab-backups/cachyos/${DATE}/" \
  --transfers 4 \
  --stats=0

# ─── 6) Alte Backups (> 30 Tage) löschen ────────────────────────────
echo "${LOG_PREFIX} pruning backups older than 30 days"
rclone delete --min-age 30d "gdrive:homelab-backups/cachyos/" 2>/dev/null || true
rclone rmdirs --leave-root "gdrive:homelab-backups/cachyos/" 2>/dev/null || true

echo "${LOG_PREFIX} done at $(date -Iseconds)"
