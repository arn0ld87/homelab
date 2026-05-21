# alertmanager-ntfy — Bridge

Übersetzt Alertmanager-Webhooks in saubere ntfy-Pushes mit Title, Tags
und Priority aus den Alert-Labels.

## Warum nicht direkt?

Alertmanagers `webhook_configs` schickt zwangsweise einen JSON-Body.
ntfy steuert Title/Tags/Priority aber über HTTP-Header oder
Query-Params. Direkt verdrahtet kommt nur rohes JSON im Notification-Body
an — unbrauchbar auf dem Handy.

## Files

| File | Zweck |
|---|---|
| `docker-compose.yml` | Container-Definition, `network_mode: host` |
| `config.scfg.tpl` | Bridge-Config (scfg-Format), wird via envsubst gerendert |

## Deploy (VPS)

```bash
# 1. Files auf den VPS schieben
rsync -av /Volumes/T7/Projekte/homelab/configs/monitoring/alertmanager-ntfy/ \
  tail:/home/admin/monitoring/alertmanager-ntfy/

# 2. Auf dem VPS: envsubst mit NTFY_TOPIC aus alertmanager-Secrets
ssh tail
cd /home/admin/monitoring/alertmanager-ntfy
set -a; source /home/admin/monitoring/alertmanager/.secrets.env; set +a
envsubst < config.scfg.tpl > config.scfg
chmod 600 config.scfg

# 3. Bridge starten
docker compose up -d

# 4. Alertmanager-Config neu rendern und neu laden
cd /home/admin/monitoring/alertmanager
envsubst < alertmanager.yml.tpl > /tmp/alertmanager.yml
docker compose restart alertmanager
```

## Verifikation

```bash
# Bridge hört auf localhost:9095?
ss -tlnp | grep 9095

# Logs sauber?
docker logs -f alertmanager-ntfy

# Test-Alert über amtool (auf VPS)
amtool alert add \
  alertname=TestAlert host=vps severity=warning \
  --annotation=summary='Bridge-Smoke-Test' \
  --annotation=description='Wenn dieser Push hübsch ankommt, ist die Bridge live.' \
  --alertmanager.url=http://localhost:9093
```

Erwartet auf dem Handy: ntfy-Notification mit Title
`FIRING — TestAlert @ vps`, Tag `warning`, Priority `default`.

## Pfade auf dem VPS

| Komponente | Pfad |
|---|---|
| alertmanager Compose | `/home/admin/monitoring/alertmanager/` |
| alertmanager-ntfy Compose | `/home/admin/monitoring/alertmanager-ntfy/` |
| ntfy.sh-Topic | `ha-hpXCeqyiWiQaqUdbfarq8JIOxXLzzjTg` |
