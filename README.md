# Highlight

Highlight PDFs two ways: a **website** that runs in any browser, and a native **Mac app** (in `mac/`). Both save standard PDF highlight annotations.

## Website

A website for highlighting PDFs in your browser. Open a PDF, select text, pick a color, and download the PDF with your highlights saved into it. The highlights are standard PDF highlight annotations, so they show up in Preview, Acrobat, and other PDF readers.

Your files stay on your computer. The PDF is opened and saved entirely in the browser and is never uploaded.

### Use it on iPhone and iPad

The website works in Safari on iOS:

- **Highlight:** long-press to select text and drag the handles, then tap a color in the bar under the selection.
- **Zoom:** pinch with two fingers to zoom the document.
- **Change or remove:** tap a highlight to recolor or remove it.
- **Highlights list:** tap the list button to see your highlights and saved passages.
- **Save:** **Download** opens the share sheet: Save to Files, Mail, AirDrop.
- **Color:** the color dot in the bottom toolbar sets the color for new highlights.
- **Area highlight:** tap the dashed-box button, drag over the area, and you're back to scrolling.
- **Home Screen app:** when the site is hosted (for example on GitHub Pages), open it in Safari, tap **Share → Add to Home Screen**, and it opens full screen like an app, with its own icon.

### Use it

- **Hosted:** open `index.html` from GitHub Pages (Settings → Pages → deploy from the `main` branch, root folder), or
- **Locally:** download `index.html` and double-click it. It loads PDF.js and pdf-lib from cdnjs, so it needs an internet connection.

| Action | How |
|---|---|
| Open a PDF | **Open PDF**, or drag a PDF onto the page |
| Highlight | Select text, then click a color in the popup (or press **H**) |
| Highlight an area | Turn on **Area** (or press **B**), then drag a box over anything: signature blocks, blank fill-in lines, form fields, or scanned text |
| Auto-highlight | Toggle **Auto-highlight**: every selection is highlighted when you let go |
| Choose a color | Toolbar swatches, or keys **1–5** |
| Recolor or remove | Click a highlight, then pick a color or **Remove** (or press Delete) |
| Jump to a highlight | Click it in the Highlights list, or **]** / **[** (also ⌥↓ / ⌥↑) for the next and previous |
| Show one color | Tap a color chip above the Highlights list |
| Find | ⌘F, then Enter / ⇧Enter for next and previous, or **Highlight all matches** |
| Copy highlighted text | **Copy all text** at the bottom of the list |
| Export | **Export…** at the bottom of the list: the highlighted pages as a PDF, or the highlighted text as Markdown |
| Highlight a list of phrases | Saved tab → **⋯** → **Highlight Phrases…**, paste one phrase per line |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Save | **Download PDF** (⌘S) |

Highlights already in a PDF, including ones made in Preview or by this site earlier, are loaded as editable highlights. Highlights are saved as plain highlights, with no comment or note text attached.

**Saved passages.** Every passage you highlight is saved. When you open another PDF, such as a new copy of the same form, Highlight looks for the same wording (ignoring case and line breaks) and offers to highlight it in the same color. In the sidebar's **Saved** tab you can choose what happens when a PDF opens (**Ask**, **Highlight** automatically, or **Off**), remove passages you no longer want matched, or highlight saved passages in the open PDF on demand. Inside Claude the list is stored privately for your account, so it follows you across devices. Opened as a plain web page, it stays in that browser. Matching is on exact wording, so a reworded section won't match.

**Form templates.** Highlight a form once (text and area boxes over blank lines or fields), then Saved tab → **⋯** → **Save Highlights as Form Template…**. When you open another copy of the same form (same page count, page size and opening text), Highlight offers to highlight the same places.

**Batches.** Saved tab → **⋯** → **Highlight a Batch of PDFs…** applies your saved passages and form templates to many PDFs at once. One file comes back as a PDF and several come back as a zip. The originals aren't changed.

**Move your library between devices and the Mac app.** **⋯** → **Export Library** saves your passages and templates as a `.json` file, and **Import Library…** reads one back, from the website or the Mac app.

**Picks up where you left off.** The site reopens the last PDF you had open, with any highlights you hadn't downloaded yet. Click or tap the file name at the top for your recent files. Recent files and unsaved highlights are kept only in this browser.

Large PDFs open on page 1 right away while the rest load in the background. Pages far off screen are released from memory. A page indicator shows where you are while scrolling.

### Limitations

- Password-protected PDFs can't be opened, and encrypted PDFs can be viewed but not saved.
- Scanned PDFs without a text layer have nothing to select. Area highlighting works on them; for text matching, use the Mac app (which reads scanned pages) or run OCR first.
- On pages that already had highlights, other annotation types (notes, stamps, drawings) aren't drawn on screen. They are still kept in the downloaded file.

### Development

`site/app.html` is the source. It is the body of the page, the form Claude artifacts publish. `./scripts/build-site.sh` wraps it in a full HTML document at `index.html`. Run that script after editing, and commit both files.

Libraries: [PDF.js](https://mozilla.github.io/pdf.js/) 3.11.174 renders pages and the selectable text layer, [pdf-lib](https://pdf-lib.js.org/) 1.17.1 writes the highlight annotations, and [JSZip](https://stuk.github.io/jszip/) 3.10.1 packs batches. Only PDF.js loads at startup: pdf-lib is fetched in the background once a PDF is open, and JSZip only when a batch needs it. The sample document is embedded (2 KB). The highlights list is built in chunks as you scroll, so documents with thousands of highlights stay responsive.

## Chrome extension

The same app as the website, built into Chrome, so you can highlight the PDF you're looking at in one click. It works offline: PDF.js, pdf-lib and JSZip ship inside the extension.

### Install

1. [**Download Highlight for Chrome**](https://cerulean-pegasus-4af782.netlify.app/downloads/Highlight-chrome.zip) (also the **Chrome** button on the website) and unzip it: on Windows, right-click it in your Downloads folder → **Extract All**. Keep the folder somewhere permanent, because Chrome loads it from there.
2. Open `chrome://extensions`, turn on **Developer mode** (top right), click **Load unpacked**, and choose the unzipped folder.
3. Pin it: click the puzzle-piece icon in the toolbar, then the pin next to Highlight.

When it's installed, a Highlight tab opens by itself. If it doesn't:

- **No Highlight tab and no card in `chrome://extensions`:** it wasn't loaded. Make sure **Developer mode** is on, and that the folder you pick in **Load unpacked** is the unzipped one with `manifest.json` directly inside it (not the `.zip` file, and not a folder above it).
- **A card with a red Errors button:** click it and send me what it says.
- **The card is there but there's no button in the toolbar:** Chrome hides new extensions behind the puzzle-piece icon. Click it, then the pin next to Highlight.
- **"Developer mode" can't be turned on:** a work or school computer may block it; installing through the Chrome Web Store is the only option there.

To update, download the new zip, replace the folder's contents, and click the reload arrow on Highlight's card in `chrome://extensions`. (It isn't on the Chrome Web Store, which is why it installs this way.)

### Use it

| Action | How |
|---|---|
| Highlight the PDF you're viewing | Click the Highlight button in the toolbar, or press **Alt+Shift+H** |
| Highlight a PDF link without opening it | Right-click the link → **Open PDF in Highlight** |
| Open Highlight on its own | Click the toolbar button on any page that isn't a PDF |

The first time you open a PDF from a website, Highlight asks to read PDFs from that site. That's once per site. For PDFs on your computer (`file://` links), turn on **Allow access to file URLs** on Highlight's card in `chrome://extensions`. PDFs are read straight into the Highlight tab and never uploaded. Everything else works like the website, and your saved passages and form templates move between the extension, the website and the Mac app with **Export Library** / **Import Library**.

Build it yourself with `./scripts/build-extension.sh` (needs Node and npm): it writes `build/chrome`, which you can load unpacked, and `build/Highlight-chrome.zip`. The extension page is `site/app.html` with its script moved into `app.js` and the libraries bundled, since Chrome extensions can't load code from a CDN. The extension's own files are in `extension/`.

## Mac app

A native macOS app (SwiftUI + PDFKit, macOS 13 or newer, Apple Silicon and Intel). The highlights list stays pinned on the left.

### Download

[**Download Highlight for Mac**](https://github.com/Blakew316/Highlight-/releases/latest/download/Highlight-mac.zip). It's built automatically each time the app changes on `main`.

1. Unzip it and drag **Highlight.app** into Applications.
2. Open it. macOS will say it can't verify the app, because it isn't notarized with an Apple Developer ID.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Highlight. You only need to do this once.

### Build it yourself

This needs Xcode or the Xcode Command Line Tools.

```bash
cd mac
./scripts/build-app.sh
cp -R build/Highlight.app /Applications/
```

The app icon comes from `mac/Resources/AppIcon.png`, drawn by `scripts/make-icon.py` (which also draws the website's Home Screen icon). The build script turns it into `AppIcon.icns`.

Then open **Highlight** from Applications, or right-click a PDF in Finder → **Open With → Highlight**. For a quick run without installing, use `swift run` inside `mac/`.

| Action | How |
|---|---|
| Open | ⌘O, File → Open Recent, or drag a PDF into the window. The last PDF reopens when the app starts. |
| Highlight selection | ⇧⌘H, the toolbar button, or right-click → Highlight |
| Highlighter mode | ⌘E: every selection is highlighted right away |
| Highlight an area | **Highlight Area** in the toolbar (⇧⌘B), then drag a box over anything: signature blocks, blank lines, form fields, scanned text |
| Color | Toolbar swatches or ⌘1–⌘5 |
| Remove / recolor | Right-click a highlight, or select text and press ⌘⌫ to remove |
| Find | Search field in the toolbar, then ⌘G / ⇧⌘G, or **Highlight All** |
| Export highlighted text | File → Export Highlights as Markdown… (⇧⌘E) |
| Export highlighted pages | File → Export Highlighted Pages as PDF… (⌥⌘E) |
| Next / previous highlight | ⌥⌘↓ / ⌥⌘↑, or the arrows under the list. Color chips above the list show one color |
| Highlight a list of phrases | Highlight → Highlight Phrases… (⌥⌘L) |
| Form templates | Highlight → Save Highlights as Form Template…, then Apply Form Template, or let it be offered when the same form opens |
| Batch | File → Highlight a Batch of PDFs… (⌥⌘B): pick PDFs and an output folder |
| Library | File → Export Library… / Import Library… (the same file the website uses) |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Save / Save As | ⌘S / ⇧⌘S (saves in place, writing to a temp file first) |
| Zoom | ⌘+, ⌘−, ⌘0 actual size, ⌘9 fit |

Saved passages work the same way as on the website: every passage you highlight is saved, and opening a PDF finds the same wording and offers to highlight it (sidebar → **Saved** tab for Ask / Highlight / Off, and Highlight → Highlight Saved Passages, ⌥⌘H, to run it on demand). The list is kept in the app's settings on your Mac.

**Scanned PDFs.** Pages with no text layer are read in the background with macOS's built-in text recognition ("Reading scanned pages…" in the toolbar). After that, Find, saved passages, phrase lists and templates work on them, and highlights there show their text in the list. You still highlight on a scanned page with **Highlight Area**, because recognized text isn't selectable.

A highlight that spans several lines appears as one entry in the list and is removed or recolored as one. The app asks before quitting or opening another file with unsaved highlights. It refuses PDFs that need a password, because saving would remove the password. `swift test` (needs full Xcode) runs the tests, and CI builds and tests the app on macOS for every change under `mac/`.
