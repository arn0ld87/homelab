# homelab

Specs und Runbooks für das eigene Setup: Tailnet, VPS, CachyOS-Desktop,
FritzBox. Markdown ist Source of Truth, HTML wird parallel gepflegt.
Versionierung über git.

## Struktur

```
homelab/
├── index.html              Übersichts-Seite (HTML-Build der Pläne)
├── assets/                 Design-Tokens, CSS, Fonts (Anthropic-Vorlage)
│   ├── colors_and_type.css
│   ├── doc.css
│   └── fonts/
└── specs/                  Markdown + HTML pro Plan
    └── YYYY-MM-DD-<slug>-design.{md,html}
```

## Konvention

- **Source of Truth ist das Markdown.** HTML wird parallel gepflegt und
  spiegelt 1:1 den MD-Stand. Bei Änderungen beide Dateien anfassen.
- Datei-Schema: `YYYY-MM-DD-<slug>-design.md`
- Frontmatter im MD enthält: `title`, `slug`, `version`, `status`,
  `date`, `author`, `scope`, `reading_time`
- HTML referenziert `../assets/colors_and_type.css` und
  `../assets/doc.css` aus `specs/`

## Lokal anzeigen

Statischer Ordner — kein Build, kein Server-Pflicht. Reicht ein Browser:

```bash
open index.html              # macOS
```

Wer einen lokalen HTTP-Server möchte (z. B. damit Anker links sauber
funktionieren):

```bash
python3 -m http.server 8000  # dann http://localhost:8000
```

## Spec an Kollegen weitergeben (Single-File-HTML)

Für E-Mail-Anhang, Slack-Upload oder USB. Eine Datei, alles inline:

```bash
python3 tools/build-singlefile.py specs/2026-05-20-tailnet-adblock-design.html
# → specs/2026-05-20-tailnet-adblock-design.standalone.html  (~450 KB)
```

CSS und die Geist-Fonts sind base64-eingebettet. Fraunces (Display-Serif)
bleibt über Google-Fonts-CDN bezogen — offline fällt es auf den
Fallback-Stack (Iowan, Palatino, Georgia) zurück. Details in
`tools/README.md`.

Die generierten `*.standalone.html` sind in `.gitignore` und werden
**nicht** ins Repo committed (regenerierbar). Wenn du einen
Auslieferungs-Stand archivieren willst, in einen Ordner außerhalb des
Repos kopieren und mit Datum benennen.

## Aktuelle Specs

| Datum       | Titel                  | Version | Status                 |
|-------------|------------------------|---------|------------------------|
| 2026-05-20  | Tailnet-Werbeblocker   | 0.1.1   | Entwurf                |
| 2026-05-20  | Heim-Monitoring-Stack  | 0.1.1   | Entwurf · Tutor-Modus  |

## Design-System

Stil und Tokens stammen aus der Anthropic-Design-Vorlage
"Dokumentations-HTML-Vorlage" — dark-first editorial, Fraunces +
Geist + Geist Mono, Neon-Orange-Akzent. Theme-Toggle (dark/light) im
HTML-Header.

## Lizenz

- **Doku, HTML, CSS, Diagramme**: [CC BY 4.0](LICENSE) — frei verwendbar
  mit Quellenangabe (Alexander Schneider, https://alexle135.de).
- **Code unter `tools/`**: [MIT](tools/LICENSE).

Wer das Layout oder die Specs übernimmt: kurzer Hinweis auf alexle135.de
reicht.
