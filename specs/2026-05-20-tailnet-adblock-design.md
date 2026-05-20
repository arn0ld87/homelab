---
title: Tailnet-Werbeblocker
slug: tailnet-adblock
version: 0.1.0
status: draft
date: 2026-05-20
author: Alexander Schneider
scope: Heim-LAN + alle Tailscale-Geräte (CachyOS, VPS, Mobil, IoT, Apple TV)
reading_time: 12 min
---

# Tailnet-Werbeblocker

## Kicker

> **№ 01 — INFRASTRUKTUR-PLAN · STAND 20. MAI 2026**
> Netzwerkweites Werbe- und Tracker-Blocking für alle Geräte über zwei
> AdGuard-Home-Instanzen im Tailnet — VPS primär, CachyOS sekundär,
> synchronisiert.

## Übersicht

Ein DNS-Sinkhole (AdGuard Home) auf zwei Knoten im Tailnet:
**Contabo VPS in Frankreich** als Primary, **CachyOS Desktop** als
Replica. Konfigurations- und Filterlisten-Stand wird über
`adguardhome-sync` aktiv gehalten. Mobilgeräte erreichen den Resolver
über die Tailscale-App + MagicDNS, das Heim-LAN über die FritzBox 7520.

**Was hier nicht steht:** YouTube-spezifische Hacks (Premium, SmartTube,
Magic Lasso). Der User hat sich bewusst für die Sparvariante entschieden
— YouTube-Pre-Rolls bleiben sichtbar. Das ist akzeptiert, kein Bug.

### Ziel

Alle Geräte — IoT, Smartphone, Computer, Apple TV — bekommen
automatisch DNS-basiertes Werbe- und Tracker-Blocking. Zu Hause via
DHCP, unterwegs via Tailscale.

### Constraints (nicht verhandelbar)

- **VPS-Hardening intakt:** Keine neuen Public-Ports auf `eth0`. AGH
  bindet exklusiv an die Tailscale-IP. Web-UI ebenfalls Tailnet-only.
- **Single Source of Truth:** Configs/Listen leben auf VPS-AGH.
  CachyOS-AGH ist Read-Only-Replica.
- **Audit-fähig:** AGH-Query-Logs sind pro Client lesbar.
- **Kein US-Cloud-Lock-in:** Keine NextDNS-as-a-Service, keine
  Cloudflare-Family-Falle.

### Out of Scope (YAGNI)

- Öffentlicher DoH-/DoT-Endpoint (nicht nötig, weil Tailscale reicht).
- Tailscale-Subnet-Routes ins Heim-LAN (CachyOS-AGH lokal reicht).
- Eigener rekursiver Resolver (Unbound) — Quad9-DoT als Forwarder ist
  gut genug, weniger Wartungs-Aufwand.
- YouTube-spezifische Maßnahmen.
- Per-Client-Familien-Filter (kann später nachgezogen werden).

## Architektur

### Topologie

```
┌──────────────────────────────────────────────────────────────┐
│  TAILNET (Wireguard, 100.x.y.z/24, MagicDNS)                 │
│                                                              │
│   ┌───────────────────┐         ┌────────────────────────┐   │
│   │  Contabo VPS (FR) │◀───────▶│  CachyOS Desktop (DE)  │   │
│   │  AGH (master)     │  sync   │  AGH (replica)         │   │
│   │  bind: tailscale0 │  HTTPS  │  bind: tailscale0+LAN  │   │
│   └────────┬──────────┘         └─────────┬──────────────┘   │
│            │                              │                  │
└────────────┼──────────────────────────────┼──────────────────┘
             │ DNS via Tailnet              │ DNS via LAN
             ▼                              ▼
   Handy/Laptop unterwegs        FritzBox 7520 (DHCP)
   (Tailscale-App)                       │
                                         ▼
                              IoT, Apple TV, Drucker, …
```

### Datenflüsse

1. **Heim-LAN/IoT:** FritzBox-DHCP → CachyOS-AGH (LAN-IP) → Quad9 DoT
2. **Mobil unterwegs:** Tailscale-App → VPS-AGH (Tailscale-IP) → Quad9 DoT
3. **CachyOS lokal (Tailscale-Always-On):** identisch zu (2), aber direkt
   ohne FritzBox-Hop
4. **Sync:** `adguardhome-sync` läuft als Container auf VPS, pollt
   VPS-AGH-API alle 5 min, pusht Diff per HTTPS+API-Token an CachyOS-AGH

## Komponenten

### VPS-AGH (Primary)

Docker-Container `adguard/adguardhome:latest`. Compose-File wird in den
existierenden VPS-Stack eingehängt (separater Compose-File neben
Traefik).

**Bind-Strategie:**

- `0.0.0.0` ist verboten. Ports werden nur auf `<TAILSCALE_IP_VPS>:53`
  und `<TAILSCALE_IP_VPS>:3000` (Web-UI) gebunden.
- `eth0` bleibt geschlossen wie heute. Keine UFW/nftables-Anpassung.
- Healthcheck via `dig @<TAILSCALE_IP_VPS> doubleclick.net` — muss
  `0.0.0.0` zurückgeben (Block).

**Upstream:**

- Primär: `tls://dns.quad9.net` (Quad9 DoT, malware-blocking)
- Fallback: `tls://1.1.1.1` (Cloudflare DoT)
- `--no-fallback` für unbekannte Upstreams. Kein UDP-Fallback auf
  ungesichertes DNS.

### CachyOS-AGH (Replica)

Docker-Container im docker-Daemon des CachyOS-Desktops. Wird über einen
systemd-User-Service oder den eingebauten Docker-Autostart hochgefahren.

**Bind-Strategie:**

- Bind auf `<CACHYOS_LAN_IP>:53` (für FritzBox-Clients) **und**
  `<TAILSCALE_IP_CACHYOS>:53` (für Tailnet-Geräte zu Hause).
- Loopback `127.0.0.1:53` zusätzlich — verhindert, dass systemd-resolved
  oder andere lokale Tools auf den Public-Resolver durchfallen.
- Web-UI nur auf `<TAILSCALE_IP_CACHYOS>:3000`.

**Replica-Modus:**

- Web-UI ist Read-Only-Schaufenster. Bedienung läuft IMMER über VPS-UI.
- `adguardhome-sync` schreibt die Konfiguration direkt in die
  AGH-API; lokale Änderungen werden beim nächsten Sync überschrieben.

### adguardhome-sync

`ghcr.io/bakito/adguardhome-sync:latest` als Docker-Container auf dem
VPS. Konfiguration via ENV-Variablen:

```yaml
ORIGIN_URL: http://<TAILSCALE_IP_VPS>:3000
ORIGIN_USERNAME: admin
ORIGIN_PASSWORD: <secret>
REPLICA1_URL: http://<TAILSCALE_IP_CACHYOS>:3000
REPLICA1_USERNAME: admin
REPLICA1_PASSWORD: <secret>
CRON: "*/5 * * * *"
RUN_ON_START: true
FEATURES_GENERAL_SETTINGS: true
FEATURES_QUERY_LOG_CONFIG: true
FEATURES_STATS_CONFIG: true
FEATURES_DNS_SERVER_CONFIG: true
FEATURES_DNS_REWRITES: true
FEATURES_FILTERS: true
FEATURES_CLIENTS: true
FEATURES_SERVICES: true
```

Passwörter kommen aus `~/.config/agh-sync/.env`, nicht ins
docker-compose-File.

### FritzBox 7520 — Heimnetz-DNS

**Pfad:** *Heimnetz → Netzwerk → Netzwerkeinstellungen → IP-Adressen →
IPv4-Konfiguration → Heimnetz*

Feld **„Lokaler DNS-Server"** auf `<CACHYOS_LAN_IP>` setzen. Die
FritzBox verteilt diesen Wert anschließend per DHCP an alle Clients im
Heim-Netz, inklusive IoT-Geräte, Apple TV und Drucker.

**Limitierung:** Das Gäste-Netz ignoriert diesen Wert — die FritzBox
setzt sich dort immer selbst als DNS. Für unseren Use-Case egal.

**Wirksamkeit:** Clients ziehen den neuen DNS erst beim nächsten
DHCP-Renew. Schnellster Pfad: DHCP-Lease-Zeit in der FritzBox kurzfristig
auf 5 min senken, alle Geräte neu verbinden lassen, dann auf 24 h
zurück.

### Tailscale MagicDNS

**Pfad:** Tailscale Admin Console → DNS

- **Nameserver:** `<TAILSCALE_IP_VPS>` als „Global Nameserver"
  eintragen. „Override local DNS" aktivieren.
- **MagicDNS:** an.
- **Search Domain:** unverändert (Tailscale-Default).

Effekt: Jedes Gerät mit aktiver Tailscale-App nutzt den VPS-AGH als
DNS-Resolver, egal wo es sich befindet. Mobiltelefone, Reise-Laptop,
ein Mac im Café — alle blocken Werbung wie zu Hause.

**Caveat:** Wenn das Mobilgerät zu Hause WLAN-verbunden ist **und**
Tailscale aktiv, dann gibt es zwei DNS-Pfade: FritzBox-DHCP (→ CachyOS)
**und** Tailscale (→ VPS). Tailscale gewinnt mit „Override local DNS".
Das ist gewollt — Mobil-Konfig bleibt überall identisch.

## Filterlisten

### Aktiv

| Liste                      | Quelle                                            | Zweck                       |
|----------------------------|---------------------------------------------------|-----------------------------|
| AdGuard DNS Default        | `https://adguardteam.github.io/AdGuardSDNSFilter` | Werbung + Tracker (Default) |
| OISD Big                   | `https://big.oisd.nl/`                            | Werbung breit, low FP       |
| Hagezi Multi PRO           | `https://github.com/hagezi/dns-blocklists`        | Werbung + Telemetrie        |
| Steven Black Hosts         | `https://stevenblack.github.io/hosts/`            | Klassische hosts-Konsolidierung |

### Erwartungen

- **Klassische Web-Werbung:** ~95 % geblockt.
- **App-Telemetrie auf iOS/Android:** ~60–80 % geblockt, je nach App.
- **YouTube-Pre-Rolls:** **NICHT** geblockt (vom Video-CDN nicht
  trennbar). Bewusst akzeptiert.
- **YouTube-Tracking-Endpoints:** teilweise geblockt — beeinflusst
  Empfehlungs-Statistik bei Google, nicht den Ad-Auslieferer.
- **Smart-TV-Telemetrie:** stark geblockt durch Hagezi.

## Rollback & Notfall

### Wenn DNS bricht (Web nicht mehr lädt)

1. FritzBox-Pfad: *Heimnetz → Netzwerk → … → Lokaler DNS-Server*
   leeren → speichern. FritzBox fällt auf ISP-DNS zurück. Heim-LAN
   sofort wieder online.
2. Tailscale-Pfad: Admin Console → DNS → „Override local DNS" abschalten
   und globalen Nameserver entfernen. Mobilgeräte fallen auf
   OS-Default-DNS.
3. Container-Pfad: `docker compose -f agh.yml stop` auf der betroffenen
   Maschine. Geräte fallen via Resolver-Timeout auf den
   FritzBox/ISP-Pfad zurück (kann 5–10 s dauern pro Anfrage —
   unangenehm, aber überlebbar).

### Wenn Sync amok läuft

`adguardhome-sync` zuerst stoppen (`docker stop agh-sync`), bevor
manuelle UI-Reparaturen an VPS oder CachyOS gemacht werden. Sonst
überschreibt der nächste Sync-Lauf alles.

## Verifikation

Nach dem Setup, in dieser Reihenfolge:

```bash
# 1) VPS-AGH antwortet im Tailnet
dig @<TAILSCALE_IP_VPS> example.com +short
# erwartet: gültige IP

# 2) Block greift auf VPS-AGH
dig @<TAILSCALE_IP_VPS> doubleclick.net +short
# erwartet: 0.0.0.0 (oder NXDOMAIN, je nach AGH-Config)

# 3) CachyOS-AGH ist synchron
dig @<CACHYOS_LAN_IP> doubleclick.net +short
# erwartet: 0.0.0.0

# 4) eth0 ist DICHT (vom Internet aus)
dig @<VPS_PUBLIC_IP> example.com +short
# erwartet: timeout — NICHT eine IP

# 5) FritzBox verteilt korrekten DNS
# auf einem Heim-Gerät:
scutil --dns | grep "nameserver\[0\]"
# erwartet: <CACHYOS_LAN_IP>

# 6) Mobil unterwegs: Handy mit Tailscale ON, Mobilfunk
nslookup doubleclick.net
# erwartet: 0.0.0.0 (Tailscale-Resolver liefert)
```

Browser-Test: <https://d3ward.github.io/toolz/adblock.html> sollte ≥
85 % Block-Rate zeigen, ohne dass installierte Browser-Extensions
mitwirken (Inkognito-Test).

## Changelog

| Datum       | Version | Änderung                              |
|-------------|---------|---------------------------------------|
| 2026-05-20  | 0.1.0   | Erstentwurf, Top-Level-Architektur abgenickt. Detail-Sektionen sind Best-Entwurf, noch nicht implementiert. |
