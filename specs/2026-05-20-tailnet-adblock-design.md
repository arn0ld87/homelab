---
title: Tailnet-Werbeblocker
slug: tailnet-adblock
version: 0.1.2
status: draft
date: 2026-05-20
author: Alexander Schneider
scope: Heim-LAN + alle Tailscale-Geräte (CachyOS, VPS, Mobil, IoT, Apple TV)
reading_time: 10 min
---

# Tailnet-Werbeblocker

## Ziel

DNS-basiertes Blocking von Werbung und Trackern für alle Geräte im
Heim-LAN und alle Tailscale-Clients unterwegs. Zwei AdGuard-Home-Instanzen:
VPS in Frankreich als Primary, CachyOS-Desktop als Replica, synchronisiert
über `adguardhome-sync`. Heim-Clients bekommen den DNS über die FritzBox,
Mobilgeräte über Tailscale-MagicDNS.

YouTube-Pre-Rolls sind nicht im Scope. Werbung kommt vom selben
`googlevideo.com`-CDN wie das Video, DNS kann das nicht trennen.

## Constraints

- VPS-Hardening bleibt unverändert. AGH bindet nur an die Tailscale-IP,
  kein Port auf `eth0`.
- VPS-AGH ist die einzige Bedienoberfläche. CachyOS-AGH ist Read-Only-Spiegel.
- AGH-Query-Logs sind pro Client lesbar.
- Kein NextDNS, kein Cloudflare-for-Families.

## Out of Scope

- Öffentlicher DoH-/DoT-Endpoint
- Tailscale-Subnet-Routes ins Heim-LAN
- Eigener rekursiver Resolver (Unbound) — Quad9 DoT als Forwarder reicht
- YouTube-spezifische Maßnahmen
- Per-Client-Familienfilter

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

1. Heim-LAN/IoT: FritzBox-DHCP → CachyOS-AGH (LAN-IP) → Quad9 DoT
2. Mobil unterwegs: Tailscale-App → VPS-AGH (Tailscale-IP) → Quad9 DoT
3. Mobil zu Hause mit Tailscale on: Tailscale-Override greift, geht ebenfalls
   zum VPS-AGH
4. Sync: `adguardhome-sync` läuft als Container auf dem VPS, pollt
   VPS-AGH-API alle 5 Minuten und pusht Diffs an CachyOS-AGH

## VPS-AGH (Primary)

Docker-Container `adguard/adguardhome:latest`. Separates Compose-File
neben dem bestehenden VPS-Stack.

### Bind

Port 53 und Web-UI nur auf der Tailscale-IP, nie auf `0.0.0.0`. UFW/nftables
bleiben unangetastet.

```yaml
services:
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: agh-primary
    restart: unless-stopped
    ports:
      - "${TAILSCALE_IP_VPS}:53:53/udp"
      - "${TAILSCALE_IP_VPS}:53:53/tcp"
      - "${TAILSCALE_IP_VPS}:3000:3000/tcp"
    volumes:
      - ./work:/opt/adguardhome/work
      - ./conf:/opt/adguardhome/conf
    network_mode: bridge
```

Wenn jemand auf `network_mode: host` umstellt, ist Port 53 wieder auf
allen Interfaces offen. Dann braucht es eine explizite UFW-Regel
`deny 53/udp on eth0`.

### Upstream

```yaml
dns:
  upstream_dns:
    - tls://dns.quad9.net
    - tls://1.1.1.1
  upstream_mode: parallel
  fastest_addr: true
  cache_size: 8388608
  cache_ttl_min: 600
  ratelimit: 0
  bootstrap_dns:
    - 9.9.9.9
    - 1.1.1.1
```

## CachyOS-AGH (Replica)

Zweiter AGH-Container, bedient sich nicht selbst, sondern wird vom
Sync-Container aktualisiert.

### Bind

Drei Adressen: LAN für IoT, Tailscale für Mobil im Heimnetz, Loopback
gegen lokale Tools, die sonst Public-Resolver verwenden würden.

```yaml
services:
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: agh-replica
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./work:/opt/adguardhome/work
      - ./conf:/opt/adguardhome/conf
```

```yaml
dns:
  bind_hosts:
    - ${CACHYOS_LAN_IP}
    - ${TAILSCALE_IP_CACHYOS}
    - 127.0.0.1
  port: 53
```

Wenn `systemd-resolved` Port 53 belegt: `DNSStubListener=no` in
`/etc/systemd/resolved.conf`, dann `systemctl restart systemd-resolved`.

## Sync

`ghcr.io/bakito/adguardhome-sync:latest` als Container auf dem VPS.
Bedienung läuft ausschließlich über das VPS-Web-UI. Manuelle Änderungen
in der CachyOS-UI werden beim nächsten Sync-Lauf überschrieben.

```yaml
services:
  agh-sync:
    image: ghcr.io/bakito/adguardhome-sync:latest
    container_name: agh-sync
    restart: unless-stopped
    env_file: ./.env
    command: run
```

```ini
ORIGIN_URL=http://${TAILSCALE_IP_VPS}:3000
ORIGIN_USERNAME=admin
ORIGIN_PASSWORD=<secret>
REPLICA1_URL=http://${TAILSCALE_IP_CACHYOS}:3000
REPLICA1_USERNAME=admin
REPLICA1_PASSWORD=<secret>
CRON=*/5 * * * *
RUN_ON_START=true
FEATURES_FILTERS=true
FEATURES_CLIENTS=true
FEATURES_DNS_SERVER_CONFIG=true
FEATURES_DNS_REWRITES=true
```

Vor jeder Reparatur an der CachyOS-Instanz erst `agh-sync` stoppen. Sonst
überschreibt der nächste Lauf alles wieder.

## FritzBox 7520

*Heimnetz → Netzwerk → Netzwerkeinstellungen → IP-Adressen →
IPv4-Konfiguration → Heimnetz*. Feld „Lokaler DNS-Server" auf
`${CACHYOS_LAN_IP}` setzen.

Clients ziehen den neuen DNS erst beim nächsten DHCP-Renew. Schneller geht
es so: DHCP-Lease-Zeit auf 5 Minuten, Geräte aus und wieder ins WLAN,
Lease-Zeit zurück auf 24 h.

Das Gäste-WLAN ignoriert den Eintrag. Die FritzBox setzt sich dort selbst
als DNS. Für Besucher meist egal.

## Tailscale MagicDNS

Tailscale Admin Console → DNS:

- Global Nameserver: `${TAILSCALE_IP_VPS}`
- Override local DNS: an
- MagicDNS: bleibt an

Effekt: Tailscale-Clients bekommen den VPS-AGH als einzigen DNS, egal in
welchem Netz sie hängen. Im Heim-WLAN überschreibt das den
FritzBox-Eintrag. Beabsichtigt.

## Filterlisten

| Liste              | Quelle                                            | Zweck                  |
|--------------------|---------------------------------------------------|------------------------|
| AdGuard DNS Default| adguardteam.github.io/AdGuardSDNSFilter           | Default-Liste          |
| OISD Big           | big.oisd.nl                                       | Breit, wenig FP        |
| Hagezi Multi PRO   | github.com/hagezi/dns-blocklists                  | Werbung + Telemetrie   |
| Steven Black Hosts | stevenblack.github.io/hosts                       | Hosts-Konsolidierung   |

### Was tatsächlich greift

- Web-Werbung: ~95 % geblockt
- App-Telemetrie iOS/Android: ~60–80 %, abhängig von der App
- YouTube-Pre-Rolls: nicht geblockt (gleicher Host wie das Video)
- YouTube-Tracking-Endpoints: teilweise, betrifft Google-Empfehlungen,
  nicht den Ad-Auslieferer
- Smart-TV-Telemetrie: gut abgedeckt durch Hagezi

Wenn YouTube später doch stört: SmartTube auf Android TV, ReVanced auf
Android, uBlock Origin im Browser. Apple TV braucht YouTube Premium oder
Magic Lasso Adblock for tvOS. Alle drei sind clientseitig und unabhängig
vom AGH.

## Rollback

DNS bricht, Webseiten laden nicht. Drei Hebel:

1. FritzBox: Feld „Lokaler DNS-Server" leeren, speichern. Heim-LAN läuft
   beim nächsten DHCP-Renew wieder über ISP-DNS.
2. Tailscale: Admin → DNS → „Override local DNS" abschalten und globalen
   Nameserver entfernen. Mobilgeräte fallen auf OS-Default-DNS.
3. Container: `docker compose stop` auf dem betroffenen Host.
   Resolver-Timeout fängt das ab, kostet 5–10 s pro erstem Lookup.

## Verifikation

```bash
# 1) VPS-AGH antwortet im Tailnet
dig @${TAILSCALE_IP_VPS} example.com +short
# erwartet: gültige IP

# 2) Block greift
dig @${TAILSCALE_IP_VPS} doubleclick.net +short
# erwartet: 0.0.0.0

# 3) CachyOS-AGH ist synchron
dig @${CACHYOS_LAN_IP} doubleclick.net +short
# erwartet: 0.0.0.0

# 4) eth0 ist nicht offen
dig @${VPS_PUBLIC_IP} example.com +short
# erwartet: timeout

# 5) FritzBox verteilt korrekten DNS (am Client)
scutil --dns | grep "nameserver\[0\]"
# erwartet: ${CACHYOS_LAN_IP}

# 6) Mobil unterwegs (Tailscale on)
nslookup doubleclick.net
# erwartet: 0.0.0.0
```

Browser-Test: <https://adblock-tester.com/> im
Inkognito-Mode. Erwartet: ≥ 85 % Blockrate.

## Changelog

| Datum       | Version | Änderung                                                 |
|-------------|---------|----------------------------------------------------------|
| 2026-05-20  | 0.1.0   | Erstentwurf                                              |
| 2026-05-20  | 0.1.1   | Sprache entkitscht, Floskeln und Marketing-Ton entfernt  |
| 2026-05-20  | 0.1.2   | Toten d3ward-Link durch adblock-tester.com ersetzt        |
