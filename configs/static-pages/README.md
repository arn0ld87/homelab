# static-pages — Tailnet-only statisches Hosting

Caddy-Container auf server-ops (`100.92.62.9`), der die DevOps-Konsole
(`devops.html` aus dem Repo-Root) und ggf. weitere statische Seiten
ausschließlich im Tailnet ausliefert.

## Erreichbarkeit

| URL                                 | Wer kann |
|-------------------------------------|----------|
| `http://100.92.62.9:8081/`          | jedes Tailnet-Device |
| `http://server-ops.tailnet:8081/`   | dito, via MagicDNS |
| `http://<wan-ip>:8081/`             | **blockiert** (Port-Mapping bindet nur an Tailscale-IP) |

Port-Wahl: 8080 ist auf server-ops von Weaviate belegt, daher 8081.
Andere belegte Ports im Tailnet: 3000 (AGH-UI), 3100 (Loki), 9090
(Prometheus), 9093/9094 (Alertmanager), 9095 (ntfy-bridge), 9100
(node_exporter), 9898 (Backrest).

Kein TLS, weil tailnet-internal. Wer TLS will, nutzt `tailscale serve`
oder einen Tailscale-Cert-Renewal.

## Deploy (Erstinstallation)

```bash
# ── lokal: devops.html in www/index.html spiegeln ────────────────
cp /Volumes/T7/Projekte/homelab/devops.html \
   /Volumes/T7/Projekte/homelab/configs/static-pages/www/index.html

# ── auf VPS: Zielverzeichnis anlegen ────────────────────────────
ssh tail "mkdir -p /home/admin/monitoring/homelab-static"

# ── lokal: alles auf VPS rsyncen ────────────────────────────────
rsync -av --delete \
  /Volumes/T7/Projekte/homelab/configs/static-pages/ \
  tail:/home/admin/monitoring/homelab-static/

# ── auf VPS: starten ────────────────────────────────────────────
ssh tail "cd /home/admin/monitoring/homelab-static && docker compose up -d"

# ── verifizieren ────────────────────────────────────────────────
ssh tail "docker compose -f /home/admin/monitoring/homelab-static/docker-compose.yml ps"
curl -fsS http://100.92.62.9:8080/ | head -5
```

## Update (nur Inhalt geändert)

```bash
cp /Volumes/T7/Projekte/homelab/devops.html \
   /Volumes/T7/Projekte/homelab/configs/static-pages/www/index.html

rsync -av /Volumes/T7/Projekte/homelab/configs/static-pages/www/ \
  tail:/home/admin/monitoring/homelab-static/www/
# Caddy serviert die neue Datei sofort — kein Restart nötig.
```

## Mehr Seiten ausliefern

Wenn du später auch `index.html` (Spec-Übersicht), `docs/` und `specs/`
mitservieren willst, statt nur `devops.html`:

```bash
rsync -av --delete \
  --exclude='.git' --exclude='configs' --exclude='journals' \
  --exclude='*.zip' --exclude='.code-review-graph' \
  /Volumes/T7/Projekte/homelab/ \
  tail:/home/admin/monitoring/homelab-static/www/
```

Dann ist `http://100.92.62.9:8080/devops.html` die Konsole,
`http://100.92.62.9:8080/` die Spec-Übersicht.

## Tailnet-Binding verifizieren

```bash
ssh tail "ss -tlnp | grep 8080"
# Erwartet: 100.92.62.9:8080  (NICHT 0.0.0.0:8080)

# Negativ-Check vom externen Internet aus (sollte timeout/refused geben):
# curl --max-time 5 http://<wan-ip>:8080/
```

## Verbote

- **Niemals** `ports: "8080:8080"` oder `0.0.0.0:8080` — das öffnet die
  Seite ins WAN.
- Tailscale-IP von server-ops ist hartkodiert. Bei Tailnet-Change Wert
  in `docker-compose.yml` anpassen.
- Wer cachyos statt server-ops nutzen will: gleiche Files, aber
  `100.95.132.54:8080:8080` im Port-Mapping.
