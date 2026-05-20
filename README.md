<div align="center">

<a href="https://alexle135.de"><img src="./assets/logo.jpg" alt="alexle135.de — homelab" width="480"/></a>

# homelab

**Infrastruktur-Specs und Runbooks für das eigene Setup — Tailnet, VPS, CachyOS-Desktop, FritzBox.**

Markdown ist Source of Truth, HTML wird parallel im alexle135.de-Editorial-Stil gepflegt. Versionierung über git, Auslieferung per Single-File-HTML an Kollegen und Dozenten.

[![Repository](https://img.shields.io/badge/GitHub-arn0ld87%2Fhomelab-111?style=flat-square&logo=github)](https://github.com/arn0ld87/homelab)
[![License: CC BY 4.0](https://img.shields.io/badge/Docs-CC%20BY%204.0-orange?style=flat-square)](./LICENSE)
[![Tools: MIT](https://img.shields.io/badge/Tools-MIT-green?style=flat-square)](./tools/LICENSE)
[![AdGuard Home](https://img.shields.io/badge/AdGuard%20Home-68bc71?style=flat-square&logo=adguard&logoColor=white)](https://adguard.com/de/adguard-home/overview.html)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=flat-square&logo=prometheus&logoColor=white)](https://prometheus.io/)
[![Tailscale](https://img.shields.io/badge/Tailscale-242424?style=flat-square&logo=tailscale&logoColor=white)](https://tailscale.com/)
[![Status](https://img.shields.io/badge/Status-Entwurf-ff6a00?style=flat-square)](#aktuelle-specs)

[Specs](#aktuelle-specs) · [Konvention](#konvention) · [Lokal anzeigen](#lokal-anzeigen) · [Spec weitergeben](#spec-an-kollegen-weitergeben-single-file-html) · [Design-System](#design-system) · [Lizenz](#lizenz)

</div>

---

> **Status:** Entwurf. Aktuell zwei Specs in `v0.1.1` — Implementation steht aus.
> Repo ist öffentlich, deshalb keine echten IPs, Hostnames oder Secrets in den
> Specs — nur Platzhalter (`${...}`). Wer auf `/ueber-mich` neugierig ist:
> [alexle135.de/ueber-mich](https://alexle135.de/ueber-mich).

## Was hier liegt

Jeder Infrastruktur-Plan kommt zuerst als Markdown-Spec ins Repo, bevor
auf den Maschinen etwas passiert. Die HTML-Version daneben rendert
denselben Inhalt im editorial Dark-Theme von alexle135.de — zum
Mitlesen im Browser oder als Single-File-HTML zum Verschicken.

## Struktur

```
homelab/
├── index.html              Übersicht (HTML-Build der Specs)
├── assets/                 Design-Tokens, CSS, Fonts, Logo
│   ├── colors_and_type.css
│   ├── doc.css
│   ├── logo.jpg
│   └── fonts/
├── specs/                  Markdown + HTML pro Plan
│   └── YYYY-MM-DD-<slug>-design.{md,html}
└── tools/                  Hilfs-Skripte (z. B. Single-File-Build)
```

## Konvention

- Markdown ist Source of Truth. HTML spiegelt den MD-Stand 1:1.
- Datei-Schema: `YYYY-MM-DD-<slug>-design.md`
- Frontmatter im MD: `title`, `slug`, `version`, `status`, `date`,
  `author`, `scope`, `reading_time`
- HTML referenziert `../assets/colors_and_type.css` und
  `../assets/doc.css` aus `specs/`

## Lokal anzeigen

Statischer Ordner — kein Build, kein Server-Pflicht:

```bash
open index.html              # macOS
```

Für saubere Anker-Links über lokalen HTTP-Server:

```bash
python3 -m http.server 8000  # dann http://localhost:8000
```

## Spec an Kollegen weitergeben (Single-File-HTML)

Eine Datei, alles inline — für E-Mail-Anhang, Slack-Upload oder USB:

```bash
python3 tools/build-singlefile.py specs/2026-05-20-tailnet-adblock-design.html
# → specs/2026-05-20-tailnet-adblock-design.standalone.html  (~450 KB)
```

CSS und Geist-Fonts werden base64-eingebettet. Fraunces (Display-Serif)
bleibt über Google-Fonts-CDN bezogen — offline fällt es auf den
Fallback-Stack (Iowan, Palatino, Georgia) zurück. Details in
`tools/README.md`.

Die generierten `*.standalone.html` sind in `.gitignore` und werden
nicht ins Repo committed. Auslieferungs-Stände lieber in einen Ordner
außerhalb des Repos kopieren und mit Datum benennen.

## Aktuelle Specs

| Datum       | Titel                  | Version | Status                 |
|-------------|------------------------|---------|------------------------|
| 2026-05-20  | Tailnet-Werbeblocker   | 0.1.1   | Entwurf                |
| 2026-05-20  | Heim-Monitoring-Stack  | 0.1.1   | Entwurf · Tutor-Modus  |

## Design-System

Stil und Tokens stammen aus der alexle135.de-Designsprache: dark-first
editorial, Fraunces als Display-Serif, Geist Sans und Geist Mono für
Text und Tags, Neon-Orange-Akzent (`#ff6a00`). Theme-Toggle (dark/light)
im HTML-Header jeder Spec.

## Lizenz

- **Doku, HTML, CSS, Diagramme**: [CC BY 4.0](LICENSE) — frei verwendbar
  mit Quellenangabe (Alexander Schneider, https://alexle135.de).
- **Code unter `tools/`**: [MIT](tools/LICENSE).

Wer das Layout oder die Specs übernimmt: kurzer Hinweis auf alexle135.de
reicht.

---

<sub>Alexander Schneider · <a href="https://alexle135.de">alexle135.de</a> · <a href="mailto:schneider@alexle135.de">schneider@alexle135.de</a></sub>
