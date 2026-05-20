#!/usr/bin/env python3
"""Build a portable single-file HTML from a modular spec HTML.

Replaces <link rel="stylesheet" href="..."> with inline <style> blocks
and embeds local woff2 fonts as base64 data: URIs.

External fonts referenced via @import url('https://...') stay external
on purpose — Fraunces is fetched from Google Fonts at view time. If the
recipient is offline, the CSS falls back to the configured serif stack
(Iowan Old Style, Palatino, Georgia).

Usage:
  python3 tools/build-singlefile.py specs/<file>.html
  python3 tools/build-singlefile.py specs/*.html

Output is written next to the input as <name>.standalone.html.
"""

from __future__ import annotations

import base64
import re
import sys
from pathlib import Path

LINK_RE = re.compile(
    r'<link[^>]*rel=["\']stylesheet["\'][^>]*href=["\']([^"\']+)["\'][^>]*/?>',
    re.IGNORECASE,
)
FONT_URL_RE = re.compile(
    r"url\(['\"]?([^'\"\)]+\.woff2)['\"]?\)\s*format\(['\"]?(woff2[^'\"]*)['\"]?\)",
    re.IGNORECASE,
)


def embed_fonts(css_text: str, css_path: Path) -> str:
    def replace(match: re.Match) -> str:
        rel = match.group(1)
        fmt = match.group(2)
        if rel.startswith(("http://", "https://", "data:")):
            return match.group(0)
        font_path = (css_path.parent / rel).resolve()
        if not font_path.exists():
            print(f"  warn: font not found {font_path}", file=sys.stderr)
            return match.group(0)
        data = base64.b64encode(font_path.read_bytes()).decode("ascii")
        return f"url(data:font/woff2;base64,{data}) format('{fmt}')"

    return FONT_URL_RE.sub(replace, css_text)


def inline_css(html_text: str, html_path: Path) -> str:
    def replace(match: re.Match) -> str:
        href = match.group(1)
        if href.startswith(("http://", "https://", "data:")):
            return match.group(0)
        css_path = (html_path.parent / href).resolve()
        if not css_path.exists():
            print(f"  warn: css not found {css_path}", file=sys.stderr)
            return match.group(0)
        css_text = css_path.read_text(encoding="utf-8")
        css_text = embed_fonts(css_text, css_path)
        return f"<style>\n/* inlined from {href} */\n{css_text}\n</style>"

    return LINK_RE.sub(replace, html_text)


def build_one(src: Path) -> Path:
    if src.name.endswith(".standalone.html"):
        raise SystemExit(f"refuse to re-process standalone file: {src}")
    out = src.with_name(src.stem + ".standalone.html")
    html = src.read_text(encoding="utf-8")
    html = inline_css(html, src)
    out.write_text(html, encoding="utf-8")
    return out


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: build-singlefile.py <input.html> [more.html …]", file=sys.stderr)
        return 1
    rc = 0
    for arg in argv[1:]:
        src = Path(arg).resolve()
        if not src.exists():
            print(f"not found: {src}", file=sys.stderr)
            rc = 1
            continue
        out = build_one(src)
        size_kb = out.stat().st_size / 1024
        print(f"built: {out.name}  ({size_kb:.1f} KB)")
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
