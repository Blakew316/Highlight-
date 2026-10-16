#!/usr/bin/env bash
# Wraps site/app.html (the page body, as published to Claude) in a full HTML
# document at index.html, so the site also works on GitHub Pages or opened
# locally, and can be added to an iPhone Home Screen as a full-screen app.
set -euo pipefail
cd "$(dirname "$0")/.."
cp site/apple-touch-icon.png apple-touch-icon.png
{
  cat <<'HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Highlight">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="theme-color" content="#f9f9f9" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#1d1d1f" media="(prefers-color-scheme: dark)">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<style>
/* Same base as the Claude artifact frame: keep content clear of the notch and home indicator. */
:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px);box-sizing:border-box}
body{margin:0;-webkit-text-size-adjust:100%}
img{max-width:100%}
</style>
</head>
<body>
HEAD
  cat site/app.html
  printf '\n</body>\n</html>\n'
} > index.html
echo "Wrote index.html"
