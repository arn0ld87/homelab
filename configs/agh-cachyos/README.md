# AGH-CachyOS

AdGuard Home Replica auf CachyOS Desktop.

## Rolle

- DNS-Resolver für LAN-Clients und Tailscale-Geräte (`100.95.132.54`)
- Replica zu `agh-primary` auf VPS via `agh-sync`
- Quelle für Querylog → Promtail → Loki (siehe
  `configs/monitoring/loki/promtail-config.yml`, Job `adguard`)

## Deploy auf CachyOS

Ziel-Pfad: `/home/alex/adguard/`

```bash
# 1. Compose-File auf Host bringen
rsync -av configs/agh-cachyos/docker-compose.yml cachyos:/home/alex/adguard/

# 2. Auf CachyOS — alten Container ablösen
ssh cachyos
cd /home/alex/adguard

# Sanity: laufender Container vor Stop nochmal sichern
docker inspect adguardhome > /tmp/adguardhome-pre-migration.json

# Stop + Remove alter `docker run`-Container
docker stop adguardhome
docker rm adguardhome

# Compose-Up — gleiches Image, gleiche Args, gleiche Volumes
docker compose up -d

# 3. Verify
docker ps | grep adguardhome
docker logs --tail 30 adguardhome
dig @100.95.132.54 example.com +short
```

Erwartet: AGH läuft als Compose-Service, DNS antwortet, Web-UI auf
`http://100.95.132.54:3000` erreichbar, Querylog landet weiterhin in
Loki (Promtail-Mount unverändert).

## Downtime

5–10 s zwischen `docker rm` und `docker compose up -d`. LAN-Clients mit
DNS-Cache (Standard) merken nichts. Geräte ohne Cache fallen während
der Lücke auf ihren Fallback-Resolver zurück (sollte konfiguriert sein).

## Mount-Layout

| Host | Container | Zweck |
|---|---|---|
| `/home/alex/adguard/conf/` | `/opt/adguardhome/conf/` | `AdGuardHome.yaml`, Filterlisten |
| `/home/alex/adguard/work/` | `/opt/adguardhome/work/` | Querylog, Stats-DB, Filter-Cache |

## Rollback

Falls Compose-Variante Ärger macht:

```bash
docker compose down
docker run -d --name adguardhome \
  --restart unless-stopped \
  -p 53:53/tcp -p 53:53/udp -p 3000:3000/tcp \
  -v /home/alex/adguard/conf:/opt/adguardhome/conf \
  -v /home/alex/adguard/work:/opt/adguardhome/work \
  adguard/adguardhome:latest \
  --no-check-update \
  -c /opt/adguardhome/conf/AdGuardHome.yaml \
  -w /opt/adguardhome/work
```
