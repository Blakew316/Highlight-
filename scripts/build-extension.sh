#!/usr/bin/env bash
# Builds the Chrome extension into build/chrome (load it unpacked from there) and
# zips it to build/Highlight-chrome.zip.
#
# The extension page is the website (site/app.html) with two changes Chrome
# requires: its inline script moves to app.js, and the libraries it loads from
# cdnjs ship inside the extension (extensions may not run remote code).
#
#   VERSION=1.0.7 ./scripts/build-extension.sh      # set the manifest version
#   VENDOR_FROM=/path ./scripts/build-extension.sh  # use an existing node_modules parent instead of npm install
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/chrome
rm -rf "$OUT" build/Highlight-chrome.zip
mkdir -p "$OUT/vendor" "$OUT/icons"

if [ -z "${VENDOR_FROM:-}" ]; then
  VENDOR_FROM=$(mktemp -d)
  trap 'rm -rf "$VENDOR_FROM"' EXIT
  (cd "$VENDOR_FROM" && npm init -y >/dev/null &&
   npm install --no-audit --no-fund --silent pdfjs-dist@3.11.174 pdf-lib@1.17.1 jszip@3.10.1)
fi
NM="$VENDOR_FROM/node_modules"
cp "$NM/pdfjs-dist/build/pdf.min.js" "$NM/pdfjs-dist/build/pdf.worker.min.js" "$OUT/vendor/"
cp "$NM/pdf-lib/dist/pdf-lib.min.js" "$OUT/vendor/"
cp "$NM/jszip/dist/jszip.min.js" "$OUT/vendor/"
cp "$NM/pdfjs-dist/LICENSE" "$OUT/vendor/LICENSE-pdfjs.txt"
cp "$NM/pdf-lib/LICENSE.md" "$OUT/vendor/LICENSE-pdf-lib.txt"
cp "$NM/jszip/LICENSE.markdown" "$OUT/vendor/LICENSE-jszip.txt"

cp extension/background.js "$OUT/"
cp extension/icons/*.png "$OUT/icons/"

python3 - "$OUT" "${VERSION:-}" <<'PY'
import json, re, sys
out, version = sys.argv[1], sys.argv[2]
src = open("site/app.html", encoding="utf-8").read()
CDN = "https://cdnjs.cloudflare.com/ajax/libs/"
LOCAL = {
    CDN + "pdf.js/3.11.174/pdf.min.js": "vendor/pdf.min.js",
    CDN + "pdf.js/3.11.174/pdf.worker.min.js": "vendor/pdf.worker.min.js",
    CDN + "pdf-lib/1.17.1/pdf-lib.min.js": "vendor/pdf-lib.min.js",
    CDN + "jszip/3.10.1/jszip.min.js": "vendor/jszip.min.js",
}
# Resource hints for the CDN mean nothing here.
src = re.sub(r'<link rel="(preconnect|preload)"[^>]*>\n', "", src)
# The one inline script becomes app.js.
m = re.search(r"<script>\n(.*?)</script>", src, re.S)
assert m, "inline script not found"
js = m.group(1)
src = src[:m.start()] + '<script src="app.js"></script>' + src[m.end():]
for remote, local in LOCAL.items():
    src = src.replace(remote, local)
    js = js.replace(remote, local)
assert CDN not in src and CDN not in js, "a CDN reference is left"
assert not re.search(r"<script>(?!</script>)", src), "an inline script is left"
html = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
        '<link rel="icon" href="icons/32.png">\n</head>\n<body>\n' + src + "\n</body>\n</html>\n")
open(f"{out}/app.html", "w", encoding="utf-8").write(html)
open(f"{out}/app.js", "w", encoding="utf-8").write(js)
manifest = json.load(open("extension/manifest.json"))
if version:
    manifest["version"] = version
json.dump(manifest, open(f"{out}/manifest.json", "w"), indent=2)
PY

(cd "$OUT" && zip -qr ../Highlight-chrome.zip .)
echo "Built $OUT (load it unpacked in chrome://extensions) and build/Highlight-chrome.zip"
