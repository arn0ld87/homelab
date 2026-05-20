---
title: Implementation-Journal — Tailnet-Werbeblocker, VPS-AGH
slug: adblock-impl
date: 2026-05-20
status: in progress
spec: ../specs/2026-05-20-tailnet-adblock-design.md
host: Contabo VPS (alexle135de)
author: Alexander Schneider
---

# Implementation-Journal — Tailnet-Werbeblocker

Was tatsächlich passiert ist, mit Befehlen, Outputs, Fehlern,
Korrekturen und kurzen Erklärungen pro Schritt. Ergänzung zur Spec
(`../specs/2026-05-20-tailnet-adblock-design.md`) — die beschreibt den
Sollzustand, dieses Journal den Verlauf.

Schreibrichtung chronologisch, je Schritt:

- **Soll** — was die Spec verlangt
- **Ist** — was passiert ist
- **Lernpunkt** — warum dieser Befehl/Flag/Schritt so aussieht

---

## 1. Vorbereitungs-Check auf dem VPS

### Soll

Drei Voraussetzungen prüfen, bevor irgendein Container startet:

- Docker installiert und ≥ Version 24
- Tailscale läuft und liefert die VPS-Tailscale-IP
- `/home/admin/` ist schreibbar

### Ist

SSH zum VPS via Alias `tail`, drei Befehle:

```bash
docker version --format '{{.Server.Version}}'
# → 29.5.1

tailscale ip -4
# → 100.92.62.9

ls -la /home/admin/ | head -5
# → admin admin (Owner), 103 Einträge, schreibbar
```

### Lernpunkt

- `docker version --format '{{.Server.Version}}'` — Go-Template, gibt
  nur die Server-Version aus statt des ganzen Client+Server-Blocks.
  Vereinfacht das Parsen in Skripten.
- `tailscale ip -4` — `-4` zwingt IPv4. Ohne Flag würden auch IPv6-IPs
  kommen, die für unser Setup nicht gebraucht werden.
- Beobachtung am Rand: `.DS_Store` im Home-Verzeichnis des VPS. Vom
  macOS-Finder via SSH-Mount reingerutscht. Nicht relevant für die
  Aufgabe, aber im nächsten Cleanup-Lauf mit
  `find /home/admin -name '.DS_Store' -delete` weg.

---

## 2. Verzeichnis-Layout, .env, docker-compose.yml

### Soll

- Verzeichnis: `/home/admin/agh/{conf,work}`
- `.env` mit `TAILSCALE_IP_VPS=100.92.62.9`, `chmod 600`
- `docker-compose.yml` mit Bind auf die Tailscale-IP (NICHT auf
  `0.0.0.0`), Ports 53/udp, 53/tcp, 3000/tcp

### Ist

```bash
mkdir -p /home/admin/agh/{conf,work}
cd /home/admin/agh
echo 'TAILSCALE_IP_VPS=100.92.62.9' > .env
chmod 600 .env
nano docker-compose.yml   # Inhalt aus Spec Sektion 3.1
```

Inhalt von `docker-compose.yml`:

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

Verifikation ohne Container-Start:

```bash
docker compose config | grep -A1 ports
# → host_ip: 100.92.62.9 für alle drei Ports ✅
```

### Lernpunkt

- `${TAILSCALE_IP_VPS}:53:53/udp` — das Format ist
  `host_ip:host_port:container_port/protocol`. Wenn `host_ip` fehlt
  (`53:53/udp`), bindet Docker an `0.0.0.0`, also alle Interfaces inkl.
  öffentlichem `eth0`. **Das wäre der Hardening-Bruch, den wir
  vermeiden.** Genau deshalb steht die IP explizit davor.
- `chmod 600 .env` — nur der Besitzer darf lesen/schreiben. Andere
  User auf dem System sehen den Inhalt nicht. Reflex, auch wenn die IP
  selbst kein Geheimwert ist — das `.env`-Pattern wird später auch
  Passwörter halten.
- `docker compose config` rendert die Compose-Datei mit aufgelösten
  Variablen, **ohne** etwas zu starten. Damit prüfst du vor dem ersten
  `up`, ob die Variablen-Substitution funktioniert. Sehr nützlich, wenn
  man von `.env`-Files abhängt.
- `network_mode: bridge` ist Docker-Default — extra hingeschrieben für
  Lesbarkeit. Die Alternative wäre `host`, dabei würde der Container
  alle Host-Interfaces direkt nutzen. Klingt verlockend, ist aber
  riskant: ein `host`-Container ohne `0.0.0.0` umgeht das
  Docker-Port-Mapping komplett und exponiert je nach Programm wieder
  alles. Bridge + explizites `host_ip` ist sicherer.

---

## 3. Container starten + Setup-Wizard

### Soll

Container hochfahren, im Browser auf `http://100.92.62.9:3000` den
AGH-Setup-Wizard durchlaufen, Listen-Interface und DNS-Port korrekt
setzen.

### Ist

```bash
cd /home/admin/agh
docker compose up -d
docker compose ps
# → agh-primary, Status: Up

docker compose logs --tail 20
# → Startup-Meldungen, kein "bind: address already in use"
```

Im Browser `http://100.92.62.9:3000` geöffnet, Setup-Wizard angezeigt.

### Stolperstein 1 — Listen-Interface im Wizard

Im Wizard zeigt das Dropdown drei Optionen:

- `Alle Schnittstellen`
- `eth0 - 10.0.0.5`
- `lo - 127.0.0.1`

**Keine Tailscale-IP sichtbar.** Erste Reaktion: „Welches der beiden
echten Interfaces nehme ich, eth0 oder lo?"

**Auflösung:** Beide falsch. Richtig ist `Alle Schnittstellen`.

Grund: Der Container läuft im Bridge-Modus. Was AGH im Wizard sieht,
sind die Interfaces **innerhalb** des Containers:

- `Alle Schnittstellen` = `0.0.0.0` aus Container-Sicht
- `eth0 - 10.0.0.5` = Docker-Bridge-IP des Containers (kurzlebig,
  ändert sich nach `docker compose down/up`)
- `lo - 127.0.0.1` = Container-Loopback (nur intern)

Die Tailscale-IP `100.92.62.9` ist eine **Host-Adresse** und für den
Container per Design unsichtbar. Der Tailnet-Bind passiert **außerhalb**
des Containers durch Docker — das haben wir in Schritt 2 mit dem
`host_ip:port:port`-Mapping schon erledigt.

Heißt: AGH darf intern auf „alle Interfaces" lauschen — Docker lässt
sowieso nur Pakete von `100.92.62.9` an den Container durch.

### Stolperstein 2 — Port-Default 80 vs. unser Mapping 3000

Der Wizard schlug **Port 80** für die Web-UI vor. Falsch für uns.

Im Compose-File ist `100.92.62.9:3000:3000/tcp` gemapped — heißt:
Host-Port 3000 wird auf Container-Port 3000 weitergeleitet. AGH muss
intern also auch auf Port 3000 lauschen, nicht auf 80.

Korrektur: Port-Feld im Wizard auf `3000` geändert.

### Wizard-Eingaben final

**Admin-Weboberfläche:** `Alle Schnittstellen` · Port `3000`
**DNS-Server:** `Alle Schnittstellen` · Port `53`
**Admin-User:** eigener Username (nicht `admin`), 16+ Zeichen Passwort
in Passwortmanager abgelegt — wird später für `adguardhome-sync`
gebraucht.

Wizard fertig, Login auf `http://100.92.62.9:3000` klappt.

### Lernpunkt

- **Container-NIC ≠ Host-NIC.** Programme im Container kennen nur die
  Interfaces, die Docker ihnen gibt. Tailscale läuft auf dem Host und
  ist für den Container unsichtbar — es sei denn, man würde
  `network_mode: host` nutzen (was wir aus Hardening-Gründen nicht
  tun).
- **Port-Mapping ist eine Übersetzung.** `100.92.62.9:3000:3000`
  bedeutet: „Pakete, die an die Host-IP 100.92.62.9 Port 3000 kommen,
  reicht durch zum Container-Port 3000." Beide Seiten müssen
  zusammenpassen — wenn AGH intern auf 80 lauscht, geht nichts durch.
- `docker compose logs --tail 20` — limitiert auf die letzten 20
  Zeilen. Bei vielen 50 Containern auf dem Host würde `docker logs`
  ohne `--tail` riesige Outputs liefern. `--tail` ist Pflicht-Reflex.

---

## 4. DNS-Settings: Quad9 DoT als Upstream

### Soll

Spec Sektion 3.2: Quad9 + Cloudflare als Upstream (DoT), Bootstrap auf
Klartext-DNS, Cache, kein Rate-Limit.

### Ist

**Settings → DNS settings** im AGH-Dashboard:

**Upstream DNS servers:**

```
tls://dns.quad9.net
tls://1.1.1.1
```

- Upstream-Modus: `Parallel requests` (anstatt Lastverteilung)
- Fastest IP address: an

**Bootstrap DNS servers:**

```
9.9.9.9
1.1.1.1
```

**Fallback DNS servers:** leer.

**DNS cache:**

- Cache size: `8388608` (8 MiB)
- Minimum TTL override: `600`
- Optimistic cache: an

**Ratelimit:** `0`

Save.

### Stolperstein 3 — Fallback-Feld

Im Dashboard taucht ein zusätzliches Feld auf, das in der Spec nicht
explizit benannt war: **Fallback-DNS-Server**.

Entscheidung: **leer lassen.**

Gründe:

- Upstream ist schon redundant (zwei Anbieter parallel).
- Wenn beide gleichzeitig down sind, hilft ein dritter Anbieter oft
  auch nicht (Routing-Probleme treffen häufig mehrere gleichzeitig).
- Jeder zusätzliche Resolver ist ein weiterer Akteur, dem DNS-Anfragen
  offenliegen.

Wenn in den AGH-Stats später Upstream-Timeouts auffallen, kann man
`tls://dns0.eu` (EU-Anbieter) nachziehen.

### Lernpunkt

- **DoT (DNS over TLS)** verschlüsselt die DNS-Antworten zwischen AGH
  und Upstream. Klartext-DNS wäre lesbar für jeden Hop dazwischen
  (ISP, Hoster).
- **Bootstrap-DNS** ist nötig, weil AGH den Hostnamen `dns.quad9.net`
  erst zu einer IP auflösen muss, bevor es die DoT-Verbindung aufbauen
  kann. Henne-Ei-Problem: DoT braucht ein TLS-Zertifikat, das gegen
  einen Hostnamen geprüft wird, also muss der Name erst aufgelöst
  werden — über einen separaten Klartext-Bootstrap-Resolver.
- **Parallel requests** statt Lastverteilung: AGH fragt **alle**
  Upstreams gleichzeitig und nimmt die schnellste Antwort. Mehr
  Traffic, aber spürbar schneller bei einzelnen langsamen Anbietern.
  Lohnt sich, wenn man wenige sehr schnelle Upstreams hat.
- **Optimistic Cache** liefert auch nach Cache-TTL-Ablauf weiter aus
  und refresht im Hintergrund. Subjektiv viel schneller; der Preis
  sind manchmal leicht veraltete Antworten.
- **Ratelimit auf 0** ist hier vertretbar, weil der Resolver
  ausschließlich übers Tailnet erreichbar ist — keine fremden Clients
  können ihn missbrauchen.

### Verifikation

Vom Mac aus, Tailscale aktiv:

```bash
dig @100.92.62.9 example.com +short
# → 104.20.23.154, 172.66.147.243 (Cloudflare-Range — example.com
#   läuft aktuell wohl über CF; Hauptsache, eine Antwort kommt)

dig @100.92.62.9 example.com | grep "SERVER:"
# → SERVER: 100.92.62.9#53(100.92.62.9)
#   Bestätigt: Antwort kam vom AGH auf dem VPS.

dig @100.92.62.9 doubleclick.net +short
# → 0.0.0.0
#   Default-AdGuard-DNS-Filter blockt.
```

Alle drei Checks grün. Pipeline: Tailnet → AGH → Quad9 DoT → Internet,
Block-Liste aktiv.

---

## 5. Filterlisten

### Soll

Drei Listen ergänzend zur Default-Liste:

- **OISD Big** — `https://big.oisd.nl/`
- **Hagezi Multi PRO** —
  `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt`
- **Steven Black Hosts** —
  `https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts`

### Ist

Drei Listen über *Filters → DNS-Blocklisten → Eigene Liste hinzufügen*
ergänzt. Download lief in wenigen Sekunden durch.

Verifikation per `dig` vom Mac aus:

```bash
dig @100.92.62.9 ads.youtube.com +short
# → 0.0.0.0  ✅

dig @100.92.62.9 graph.facebook.com +short
# → star.c10r.facebook.com.
#   57.144.248.141        ❌  NICHT geblockt

dig @100.92.62.9 telemetry.microsoft.com +short
# → 0.0.0.0  ✅
```

### Stolperstein 4 — `graph.facebook.com` wird nicht geblockt

Erwartung war: alle drei Test-Domains werden geblockt. Tatsächlich
zwei von drei.

**Auflösung:** Kein Fehler in der Konfig, sondern absichtliches
Verhalten der Listen.

- Hagezi PRO und OISD halten `graph.facebook.com` bewusst frei. Das
  ist die Graph-API. „Mit Facebook anmelden" und Facebook-Embeds
  brauchen sie — wer das blockiert, bekommt kaputte Seiten an
  unerwarteter Stelle.
- Was diese Listen blockieren, sind die **echten** Tracker-Subdomains:
  `connect.facebook.net` (Tracking-Pixel),
  `pixel.facebook.com`. Diese ergeben `0.0.0.0`.

Entscheidung: lassen wie es ist. Tracker sind abgedeckt, API bleibt
funktional. Wer aggressiver will, hat drei Optionen:

- Hagezi **Pro++** statt PRO:
  `.../main/adblock/pro.plus.txt`
- Hagezi **Ultimate**: deutlich aggressiver, höhere False-Positive-Rate.
  Für ein Heim-LAN mit IoT-Geräten ungeeignet.
- AGH Custom Rule: `||graph.facebook.com^` (eigene Regel, überstimmt
  alle Listen).

### Lernpunkt

- **DNS-Blocklisten** sind Textdateien mit Domain-Mustern. AGH lädt
  sie herunter, parst sie, matched eingehende Anfragen dagegen.
  Trifft eine Anfrage einen Eintrag, antwortet AGH mit `0.0.0.0` oder
  `NXDOMAIN`, je nach Block-Mode.
- **Mehr Listen ≠ besseres Blocking.** Ab einem gewissen Punkt
  überlappen sie sich stark, und der Speicher-/CPU-Aufwand pro Lookup
  wächst. Vier Listen reichen für die meisten Setups.
- **`raw.githubusercontent.com`** ist die direkte Datei-URL für
  GitHub-Repos. Die `github.com/.../blob/...`-URL würde das HTML-UI
  ausliefern, AGH erwartet aber Plaintext.
- **CNAME-Auflösung im `dig`-Output:** Ein Block-Test, der eine Zeile
  mit einem Punkt am Ende (`star.c10r.facebook.com.`) gefolgt von
  einer IP zeigt, ist eine CNAME-Kette. AGH konnte die Domain auflösen
  → also nicht geblockt. Geblockt wäre eine einzelne `0.0.0.0`-Zeile
  ohne CNAME.
- **Konservative vs. aggressive Listen** sind eine Designentscheidung
  der Maintainer. Hagezi dokumentiert die Stufen explizit
  (`Light/Normal/Pro/Pro++/Ultimate`). Lieber die richtige Stufe
  wählen, als nachträglich Whitelists pflegen.

### Status

VPS-AGH ist **komplett**. DNS-Auflösung läuft, Block-Listen aktiv,
Default-Tracker werden blockiert, Facebook-API absichtlich nicht.

---

## Offen

- Schritt 6: CachyOS-AGH als Replica
- Schritt 7: `adguardhome-sync` auf dem VPS
- Schritt 8: FritzBox-DHCP auf CachyOS-LAN-IP
- Schritt 9: Tailscale MagicDNS global

## Changelog

| Datum       | Änderung                                                          |
|-------------|-------------------------------------------------------------------|
| 2026-05-20  | Initial — Schritte 1 bis 4 dokumentiert, 5 begonnen               |
| 2026-05-20  | Schritt 5 fertig — Filterlisten, Stolperstein 4 (Facebook-API)    |
