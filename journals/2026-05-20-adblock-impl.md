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

### Nachtrag — Facebook-Tracker-Tiefe

Zweite Stichprobe nach Stolperstein 4:

```bash
dig @100.92.62.9 connect.facebook.net +short
# → scontent.xx.fbcdn.net.
#   57.144.254.128         ❌  NICHT geblockt

dig @100.92.62.9 pixel.facebook.com +short
# → 0.0.0.0  ✅
```

`connect.facebook.net` ist eigentlich der bekannteste Facebook-Tracker
(Pixel SDK auf Drittseiten). Dass Hagezi PRO ihn durchlässt, ist
designt — er bricht zu viele Share-Buttons und Logins.

Würde-Korrekturen blockieren:

- Hagezi **Pro++** statt PRO
- AGH Custom Rule: `||connect.facebook.net^`

Entscheidung: **lassen.** Im AGH-Query-Log sichtbar, gezielt
nachschärfbar wenn nötig. Lieber wenig False-Positives als aggressives
Blocking, das Drittseiten kaputt macht.

### Status

VPS-AGH ist **komplett**. DNS-Auflösung läuft, Block-Listen aktiv,
Konservative Listen-Wahl bewusst — Tracker im Query-Log sichtbar,
Korrekturen pro Domain möglich.

---

---

## 6. CachyOS-AGH — bestehender Container

### Soll

Zweiten AGH als passive Replica auf CachyOS, gebunden an LAN-IP +
Tailscale-IP + Loopback. `network_mode: host`, weil mehrere
Bind-Adressen.

### Ist

Vorbereitungs-Check auf dem Desktop:

```
Docker            29.5.0
LAN-IP            192.168.178.74  (wlan0, FritzBox-Range)
Tailscale-IP      100.95.132.54
Port 53 belegt    docker-proxy auf 0.0.0.0:53 (tcp+udp)
```

### Stolperstein 5 — Port 53 schon belegt

Erwartet hätte ich `systemd-resolved` auf `127.0.0.53`. Tatsächlich:
ein bestehender `adguardhome`-Container hält Port 53 schon, gebunden
auf `0.0.0.0`.

`docker ps | grep 53` zeigt:

```
adguardhome   80/tcp, 67-68/udp, 443/tcp, 443/udp,
              0.0.0.0:53->53/tcp, [::]:53->53/tcp,
              853/udp, 853/tcp, 3000/udp, 5443/tcp,
              0.0.0.0:3000->3000/tcp, 0.0.0.0:53->53/udp,
              [::]:3000->3000/tcp, [::]:53->53/udp,
              5443/udp, 6060/tcp
```

Vor Phase 2 nicht erwartet, also offene Frage: alten Container nutzen
oder löschen?

### Inspektion des bestehenden Containers

```
Image             adguard/adguardhome (latest implied)
Mounts            /home/alex/adguard/conf -> /opt/adguardhome/conf
                  /home/alex/adguard/work -> /opt/adguardhome/work
Compose-Projekt   leer  →  Container via `docker run`, kein Compose
DHCP              enabled: false   (kein FritzBox-Konflikt)
Bind-Hosts        0.0.0.0          (funktional ok, nicht spec-konform)
Filterlisten      4  (AdGuard DNS filter, AdAway, OISD Big, HaGeZi Pro)
Upstream          Quad9 DoH:  https://dns10.quad9.net/dns-query
Bootstrap         9.9.9.10  (Quad9 Secured)
```

### Stolperstein 6 — Listen-/Upstream-Diff zum VPS

Vergleich mit der VPS-Config aus Schritt 5:

| Punkt              | VPS                                | CachyOS                              |
|--------------------|------------------------------------|--------------------------------------|
| Listen             | AdGuard, OISD, Hagezi PRO, **Steven Black** | AdGuard, **AdAway**, OISD, Hagezi PRO |
| Upstream-Protokoll | DoT (`tls://dns.quad9.net`)        | DoH (`dns10.quad9.net/dns-query`)    |
| Fallback-Upstream  | Cloudflare DoT                     | keiner                               |
| Bootstrap          | 9.9.9.9, 1.1.1.1                   | 9.9.9.10                             |

Ohne Eingriff würde der spätere Sync vom VPS die CachyOS-Listen
überschreiben. AdAway wäre weg.

### Entscheidung

**Variante: AdAway vorher auf VPS ergänzen.** Dann hat der Sync nichts
zu überschreiben, alle Listen bleiben.

Vor Sync:

1. Auf VPS-AGH-UI: AdAway-Liste hinzufügen
   (`https://adaway.org/hosts.txt`).
2. VPS hat dann 5 Listen, CachyOS auch 4. Beim Sync wird CachyOS auf
   5 hochgezogen.

### Lernpunkt

- **`docker-proxy` als Indicator:** Wenn `lsof -i :53` einen Prozess
  namens `docker-proxy` zeigt, ist es nicht systemd, sondern ein
  Docker-Container, der den Port hält. Deshalb immer mit
  `docker ps | grep ':53->'` gegenchecken.
- **`docker inspect --format '{{...}}'`** ist die strukturierte
  Inspect-Variante. Spart Parsen vom JSON-Output. Beispiel:
  `--format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'`
  rendert eine zweispaltige Liste der Volume-Mounts.
- **AGH-Config-Pfad:** Liegt auf dem Host am Bind-Mount-Pfad
  (`/home/alex/adguard/conf/AdGuardHome.yaml`). Direktes Editieren
  möglich, aber: nach Edit muss `docker restart adguardhome` her,
  sonst greift es nicht.
- **DoT (Port 853) vs. DoH (Port 443):** Beides verschlüsselt.
  DoT ist transparenter (eigener Port, erkennbar), DoH versteckt sich
  im normalen HTTPS-Traffic. Funktional gleichwertig.
- **Migration auf Compose offen:** Aktueller Container ist nicht
  versioniert. Nach Sync-Aufbau kommt eine Compose-Migration —
  Bind-Hosts spec-konform machen, Restart-Policy setzen,
  Volume-Pfade in `docker-compose.yml` versionieren.

### Status

CachyOS-AGH läuft, ist als Replica geeignet. Vor Sync-Aufbau: AdAway
auf VPS ergänzen.

### Nachtrag — AdAway auf VPS-AGH ergänzt

`https://adaway.org/hosts.txt` als fünfte Liste auf VPS-AGH
hinzugefügt. Verifikations-Dig:

```bash
dig @100.92.62.9 b.scorecardresearch.com +short
# → 0.0.0.0  ✅
```

`scorecardresearch.com` ist Comscore-Tracking — typischer AdAway-Treffer.

---

## 7. Passwort-Reset + Port-Fix auf CachyOS-AGH

### Auslöser

Passwort für das CachyOS-AGH-Login war nicht mehr bekannt. Damit der
Sync später daran kommt, musste es zurückgesetzt werden.

### Vorgehen (yaml-basierter Reset)

AGH speichert das Passwort als bcrypt-Hash in
`AdGuardHome.yaml` — nicht rückrechenbar, aber überschreibbar.

```bash
# Username herausfinden
sudo grep -A3 '^users:' /home/alex/adguard/conf/AdGuardHome.yaml

# Container stoppen
docker stop adguardhome

# Neuen bcrypt-Hash erzeugen (ohne lokale htpasswd-Installation)
docker run --rm -ti httpd:alpine htpasswd -B -n -C 10 <USERNAME>
# liefert  <USERNAME>:$2y$10$...

# yaml editieren, password:-Wert im users:-Block ersetzen
sudo nano /home/alex/adguard/conf/AdGuardHome.yaml

# Container starten
docker start adguardhome
```

### Stolperstein 8 — Port-Mismatch nach Restart

Nach dem Restart: Web-UI auf `http://100.95.132.54:3000` → `Connection
refused`. Port 53 (DNS) ging weiter, Port 3000 nicht.

Diagnose vom Mac aus:

```bash
nc -zv 100.95.132.54 53     # open
nc -zv 100.95.132.54 3000   # refused
```

`refused` (nicht `timeout`) heißt: TCP-Handshake kommt durch, niemand
lauscht. Auf CachyOS in den AGH-Logs:

```
starting plain server server=plain addr=0.0.0.0:80
```

**AGH lauschte intern auf Port 80, nicht 3000.** Das Docker-Port-Mapping
ist aber `0.0.0.0:3000 -> 3000/tcp`. Mismatch:

- Host 3000 → Container 3000
- AGH bindet 80

Wer auf `host:3000` zugreift, landet bei Container-Port 3000 — niemand
hört dort zu.

### Fix

```bash
docker stop adguardhome
sudo nano /home/alex/adguard/conf/AdGuardHome.yaml
# Im http:-Block:  address: 0.0.0.0:80  →  address: 0.0.0.0:3000
docker start adguardhome
docker logs adguardhome --tail 5
# erwartet: starting plain server server=plain addr=0.0.0.0:3000
```

Verifikation vom Mac:

```bash
nc -zv 100.95.132.54 3000
# → open  ✅
```

Login mit neuem Passwort funktioniert.

### Lernpunkt

- **bcrypt** ist Einweg-Hash mit Salt + Cost-Parameter. `-C 10` = 2^10
  Iterationen. Hash überschreiben geht, zurückrechnen nicht. Genau
  dafür designt.
- **Docker-Port-Mapping ist Übersetzung, nicht Magie.** `host:3000 →
  container:3000`. Wenn das Programm im Container auf einer anderen
  Portnummer lauscht, kommt nichts an. Always-check: was sagt das
  **Programm** in den Logs (hier: `starting plain server addr=...`)
  und was sagt das **Docker-Mapping** (`docker ps | grep adguard`)?
- **`refused` vs. `timeout` als Diagnostik-Signal:**
  - `refused` = Host antwortet, aber Port hat keinen Listener
  - `timeout` = Paket geht verloren / Firewall / Host down
  Erste Hinweise auf die Schicht, in der das Problem liegt.
- **AGH-Wizard-Default ist Port 80** für die Web-UI. VPS hatten wir
  bewusst auf 3000 gestellt (Stolperstein 2). Beim CachyOS-Alt-Container
  war das nie nachgezogen — daher der späte Bumper.
- **Nebenbei in den Logs gefunden:**
  `dhcpd: warning: creating dhcpv4 server err="dhcpv4: invalid IP …"`
  AGH startet das DHCP-Subsystem trotz `enabled: false` partiell und
  meckert über eine fehlende IP. Niedrige Priorität, später beim
  yaml-Cleanup die DHCP-Sektion sauber entfernen.

### Status

CachyOS-AGH erreichbar auf `http://100.95.132.54:3000`. Bereit für
Sync-Aufbau.

---

## 8. adguardhome-sync auf VPS

### Soll

`ghcr.io/bakito/adguardhome-sync` als Container auf VPS, Master = VPS-AGH,
Replica1 = CachyOS-AGH, Cron alle 5 min.

### Ist

`/home/admin/agh-sync/` existierte mit `.env`, aber **ohne**
`docker-compose.yml`. Deshalb fiel `docker compose up -d` ins Leere
(kein Service-File gefunden).

Lösung: Compose-File in der homelab-Spec versioniert (Pfad
`homelab/configs/agh-sync/docker-compose.yml`, plus `.env.example`),
via `scp` auf VPS übertragen:

```bash
scp configs/agh-sync/docker-compose.yml tail:/home/admin/agh-sync/
```

Dann auf VPS:

```bash
cd /home/admin/agh-sync
docker compose up -d
docker compose logs --tail 40 agh-sync
```

### Log-Auszug (Sync-Lauf)

```
Connected to origin       version=v0.107.75   from=100.92.62.9:3000
Connected to replica      version=v0.107.73   to=100.95.132.54:3000
Set dns config list       upstream-dns=[tls://dns.quad9.net, tls://1.1.1.1]
Delete filter             url=https://big.oisd.nl
Add filter                url=https://big.oisd.nl/
Add filter                url=.../StevenBlack/hosts/master/hosts
Add filter                url=https://adaway.org/hosts.txt
Update filter             url=.../hagezi/dns-blocklists/main/adblock/pro.txt
Refresh filter
Set user rules            rules=0
Sync done
```

### Verifikation gegen CachyOS-Replica

```bash
# Default-Block (AdGuard DNS filter)
dig @100.95.132.54 doubleclick.net +short
# → 0.0.0.0  ✅

# AdAway-Treffer (Comscore)
dig @100.95.132.54 b.scorecardresearch.com +short
# → 0.0.0.0  ✅

# Steven-Black-Treffer
dig @100.95.132.54 telemetry.microsoft.com +short
# → 0.0.0.0  ✅
```

Drei aus drei — Replica blockt identisch zum Master.

### Beobachtungen / loose ends

- **Versions-Drift** in den Sync-Logs:
  `originVersion=v0.107.75, replicaVersion=v0.107.73`. Funktional
  unkritisch, aber CachyOS-AGH sollte später per
  `docker pull adguard/adguardhome:latest && docker compose up -d`
  (nach Compose-Migration) aktualisiert werden.
- **OISD-URL-Detail:** Im Sync-Log zwei Zeilen für OISD —
  `Delete url=https://big.oisd.nl` gefolgt von
  `Add url=https://big.oisd.nl/`. Trailing-Slash war der einzige
  Unterschied; AGH-Sync sieht das als zwei verschiedene Einträge.
- **Warnung** `disabling replica 'Use private reverse DNS resolvers' as
  no 'Private reverse DNS servers' are configured on origin` — Setting
  wurde abgeschaltet, weil im VPS nicht konfiguriert. Irrelevant für
  unser Setup.

### Lernpunkt

- **`scp` für versionierte Configs:** Compose-File liegt im Repo
  (`configs/agh-sync/`), `.env` mit Secrets nicht. Auf den VPS kopiert
  via `scp`. Bei künftigen Updates des Compose: lokal editieren,
  pushen, `docker compose up -d` auf VPS.
- **Sync-Container braucht kein Port-Mapping:** Reiner Egress —
  redet via HTTP über Tailnet. Daher im Compose kein `ports:`-Block.
  `8080/tcp` in `docker ps` ist die interne Health-API,
  nicht exponiert.
- **FEATURES-Flags trennen Inhalt von Konfig:**
  - `FILTERS=true`, `CLIENTS=true`, `DNS_SERVER_CONFIG=true`,
    `DNS_REWRITES=true` → das sind die inhaltlichen Sachen, die
    Master und Replica gemeinsam haben sollen
  - `GENERAL_SETTINGS=false`, `QUERY_LOG_CONFIG=false`,
    `STATS_CONFIG=false`, `SERVICES=false` → bleibt pro Knoten
    lokal (UI-Theme, Retention, etc.)

### Status

Sync läuft alle 5 Minuten, beide Knoten haben identische Filter,
Upstreams und Clients. **Phase 3 abgeschlossen.**

---

## 9. FritzBox-DHCP auf CachyOS-AGH

### Soll

Im FritzBox-Webinterface das Feld „Lokaler DNS-Server" auf
`192.168.178.74` (CachyOS-LAN-IP). Lease-Zeit-Verkürzung auf 5 Minuten,
Reboot der Clients (oder FritzBox-Neustart), zurücksetzen auf 24 h.

### Ist

Eingetragen über *Heimnetz → Netzwerk → Netzwerkeinstellungen →
IP-Adressen → IPv4-Konfiguration → DHCP*:

```
DHCP-Server vergibt IPv4-Adressen
  von   192.168.178.20
  bis   192.168.178.200
  Gültigkeit  10 Tage    (für IoT-Stabilität so gelassen)

Lokaler DNS-Server  192.168.178.74
```

Statt Lease-Verkürzung: **FritzBox-Neustart**. Wirkt gleich (alle
Clients holen sich beim Wieder-Anmelden eine neue Lease).

### Stolperstein 9 — Tailscale übersteuert lokalen DHCP-DNS

Verifikation am Mac:

```bash
scutil --dns | grep "nameserver\[0\]" | head -3
# → nameserver[0] : 100.100.100.100   (Tailscale MagicDNS-Resolver)
#   nameserver[0] : 100.92.62.9       (VPS-AGH via Tailscale)
#   nameserver[0] : 100.100.100.100
```

**Kein `192.168.178.74` zu sehen.** Erste Reaktion: „FritzBox-DNS
greift nicht." Tatsächlich:

- Tailscale läuft auf dem Mac und schiebt seinen eigenen Resolver
  (`100.100.100.100`) vor den DHCP-DNS
- Sobald Tailscale aktiv ist, gewinnt es — das ist gewollt für den
  „mobil unterwegs"-Use-Case
- IoT-Geräte ohne Tailscale sehen den FritzBox-DHCP-DNS unverändert

Echter LAN-Test mit `dig` direkt gegen die LAN-IP, das umgeht
Tailscale:

```bash
dig @192.168.178.74 doubleclick.net +short
# → 0.0.0.0  ✅

dig @192.168.178.74 b.scorecardresearch.com +short
# → 0.0.0.0  ✅
```

CachyOS-AGH antwortet auf `192.168.178.74:53`, Blocking greift.

### Lernpunkt

- **DNS-Priorität auf macOS:** Tailscale-Daemon kann den OS-Resolver
  per VPN-Profil übersteuern. `scutil --dns` zeigt die Reihenfolge —
  die `nameserver[0]`-Liste oben gewinnt.
- **DHCP-DNS-Zielgruppe sind die LAN-only-Geräte:** Smart-TV, Drucker,
  IoT, Konsolen — alles, was kein Tailscale spricht. Für die wirkt
  der FritzBox-Eintrag wie geplant.
- **`dig @IP host`** ist der schärfere Test: er geht direkt an die
  angegebene IP, ignoriert OS-Resolver-Konfiguration. Bei
  DNS-Debugging fast immer der erste Reflex.
- **FritzBox-Neustart als Lease-Refresh-Hack:** Schneller als
  Lease-Verkürzung und manuelle Lease-Renew-Trigger an jedem Client.
  Funktioniert weil alle Clients beim Reconnect eine frische
  DHCP-Anfrage stellen.

### Status

Heim-LAN-DNS-Pfad steht. **Phase 4 abgeschlossen.**

---

## 10. Tailscale MagicDNS — globaler Resolver

### Soll

`100.92.62.9` als globaler Nameserver in Tailscale Admin Console,
„Override local DNS" aktiv, MagicDNS bleibt an. Damit blockt jedes
Tailscale-Gerät überall.

### Ist

Tailscale Admin Console → DNS → *Add nameserver → Custom*:

- *Nameserver*: `100.92.62.9`
- *Restrict to domain (Split DNS)*: aus
- *Use with exit node*: aus

Save. Anschließend im Haupt-Dialog **„Override local DNS"** auf AN.

### Stolperstein 10 — Tot-Link für Verifikation

Geplanter Test-URL war `d3ward.github.io/toolz/adblock.html`. Die Seite
ist seit kurzem **archiviert** und nicht mehr verfügbar. Ersatz:

```
https://adblock-tester.com/
```

Repo-Specs nachträglich auf den neuen Link umgestellt.

### Verifikation am Handy

iPhone, Tailscale-App an, **Mobilfunk** (WLAN explizit aus), Browser
auf `https://adblock-tester.com/`:

```
Score: 78 / 100
```

Bedeutung:

- 78 ist im erwarteten Bereich für DNS-Adblock mit konservativen Listen
- Fehlende ~22 Punkte sind YouTube-First-Party-Werbung,
  CName-Cloaking und Acceptable-Ads-Tricks — DNS allein kann das nicht
- Aggressivere Listen (Hagezi Pro++) würden auf ~85 bringen, dafür
  steigt das False-Positive-Risiko

### Lernpunkt

- **Tailscale-Override:** Mit „Override local DNS = AN" gewinnt der
  Tailscale-DNS gegen jeden lokalen DHCP-DNS. Heißt: im Café, Hotel,
  fremdem WLAN — überall greift dein AGH. Genau der Grund, warum wir
  Tailscale für die Mobil-Coverage genommen haben statt am Router
  fremder Netze zu schrauben.
- **Adblock-Tester-Score als Diagnose, nicht als Ziel:** 78/100 mit
  DNS-only ist ein normaler Wert. Sichtbare Real-World-Wirkung
  (`bild.de`, `t-online.de`, Wetter-Apps) ist drastisch — DNS-Blocking
  greift dort, wo Werbung weh tut, auch wenn ein Test nur 78 anzeigt.
- **CName-Cloaking** ist die nächste Eskalationsstufe: Tracker setzen
  CNAMEs vom Hauptdomain auf ihre Server. AGH unterstützt
  CName-Uncloaking als Filter-Option, müsste aber gezielt aktiviert
  werden. Für später.

### Status

**Phase 5 abgeschlossen.** Alle fünf Phasen durch.

---

## Schluss-Status

| Phase | Inhalt | Status |
|-------|--------|--------|
| 1 | VPS-AGH (Master) | ✅ |
| 2 | CachyOS-AGH (Replica, bestehender Container) | ✅ |
| 3 | adguardhome-sync auf VPS | ✅ |
| 4 | FritzBox-DHCP-DNS auf CachyOS-LAN-IP | ✅ |
| 5 | Tailscale MagicDNS global | ✅ |

Funktional steht der Stack:

- **Heim-LAN-Clients** (IoT, Apple TV, Drucker): FritzBox-DHCP → CachyOS-AGH (192.168.178.74) → Quad9 DoT
- **Tailscale-Clients** (Mac, Handy, überall): Tailscale-MagicDNS → VPS-AGH (100.92.62.9) → Quad9 DoT
- **Sync**: VPS pusht Filter, Clients, Upstreams alle 5 min an CachyOS-Replica

## Loose ends für später (separat anpacken)

- CachyOS-AGH-Container auf `docker compose` migrieren, Bind-Hosts
  spec-konform setzen, AGH-Version auf VPS-Stand bringen, DHCP-Sektion
  aus yaml entfernen
- Adblock-Tester-Score über 85 bringen: Hagezi PRO → Pro++ wechseln,
  evtl. CName-Uncloaking aktivieren
- Monitoring-Stack (Phase 6+ aus der zweiten Spec) — Prometheus,
  Grafana, Loki — beobachtet ab dann das ganze Setup

---

## Offen

- Schritt 9: CachyOS-AGH-Migration auf Compose, Bind-Hosts spec-konform,
  Version-Drift schließen, DHCP-Sektion aus yaml entfernen
- Schritt 10: FritzBox-DHCP auf CachyOS-LAN-IP (192.168.178.74)
- Schritt 11: Tailscale MagicDNS global (Global Nameserver = 100.92.62.9)

---


## Changelog

| Datum       | Änderung                                                          |
|-------------|-------------------------------------------------------------------|
| 2026-05-20  | Initial — Schritte 1 bis 4 dokumentiert, 5 begonnen               |
| 2026-05-20  | Schritt 5 fertig — Filterlisten, Stolperstein 4 (Facebook-API)    |
| 2026-05-20  | Schritt 6 — CachyOS-AGH inspiziert, Stolperstein 5+6, AdAway-Merge|
| 2026-05-20  | Schritt 7 — Passwort-Reset, Stolperstein 8 (Port-Mismatch 80→3000)|
| 2026-05-20  | Schritt 8 — Sync läuft, Replica spiegelt Master, Phase 3 durch    |
| 2026-05-20  | Schritt 9 — FritzBox-DHCP-DNS, Stolperstein 9 (Tailscale-Override)|
| 2026-05-20  | Schritt 10 — Tailscale MagicDNS, Stolperstein 10 (d3ward archiviert), alle Phasen durch |
