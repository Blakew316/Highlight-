#!/usr/bin/env bash
# Wraps site/app.html (the page body, as published to Claude) in a full HTML
# document at index.html, so the site also works on GitHub Pages or opened locally.
set -euo pipefail
cd "$(dirname "$0")/.."
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
  printf '<style>body{margin:0}img{max-width:100%%}</style>\n</head>\n<body>\n'
  cat site/app.html
  printf '\n</body>\n</html>\n'
} > index.html
echo "Wrote index.html"
