# tools/

## build-singlefile.py

Generiert eine portable Single-File-HTML-Variante einer Spec — CSS und
Geist-Fonts werden inline gepackt, sodass die `.standalone.html`-Datei
einzeln per Mail, Chat oder USB weitergegeben werden kann und das
Design behält.

### Aufruf

```bash
# eine einzelne Spec
python3 tools/build-singlefile.py specs/2026-05-20-tailnet-adblock-design.html

# alle Specs auf einen Streich
python3 tools/build-singlefile.py specs/*.html
```

Output landet als `<name>.standalone.html` neben dem Original.

### Was inline ist, was nicht

| Asset                                | Inline | Anmerkung                                                                   |
|--------------------------------------|--------|-----------------------------------------------------------------------------|
| `colors_and_type.css`, `doc.css`     | ja     | Komplett im `<style>`-Block.                                                 |
| `GeistSans-Variable.woff2`           | ja     | base64-eingebettet als `data:font/woff2;base64,…`                            |
| `GeistMono-Variable.woff2`           | ja     | gleich                                                                       |
| Fraunces (Google Fonts via `@import`)| nein   | bleibt online. Offline-Fallback: Iowan Old Style → Palatino → Georgia.       |

### Größen-Erwartung

- Eingebettete Geist-Fonts: ~93 KB + ~96 KB (base64-overhead 33 %)
- Standalone-HTML pro Spec: typisch 280–320 KB
- Mail-Anhang-tauglich (Outlook 25 MB, Gmail 25 MB — alles drin)

### Wenn du Fraunces auch offline-fest haben willst

Lade die `.woff2` von Google Fonts herunter, leg sie unter
`assets/fonts/Fraunces-Variable.woff2` ab, ergänze in
`colors_and_type.css` einen `@font-face`-Block analog zu Geist, entferne
den `@import`-Block von Google Fonts. Dann zieht das Script Fraunces
beim nächsten Build auch ein.

### Abhängigkeiten

Keine. Reine Python-Standardbibliothek (`base64`, `re`, `pathlib`).
Getestet mit Python 3.12.
