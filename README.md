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
- **Save:** **Download PDF** saves to the Files app (or opens the share sheet in the Claude app).
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
| Jump to a highlight | Click it in the Highlights list |
| Find | ⌘F, then Enter / ⇧Enter for next and previous, or **Highlight all matches** |
| Copy highlighted text | **Copy all text** at the bottom of the list |
| Export highlighted text | **Export Markdown** at the bottom of the list |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Save | **Download PDF** (⌘S) |

Highlights already in a PDF, including ones made in Preview or by this site earlier, are loaded as editable highlights. Highlights are saved as plain highlights, with no comment or note text attached.

**Saved passages.** Every passage you highlight is saved. When you open another PDF, such as a new copy of the same form, Highlight looks for the same wording (ignoring case and line breaks) and offers to highlight it in the same color. In the sidebar's **Saved** tab you can choose what happens when a PDF opens (**Ask**, **Highlight** automatically, or **Off**), remove passages you no longer want matched, or highlight saved passages in the open PDF on demand. Inside Claude the list is stored privately for your account, so it follows you across devices. Opened as a plain web page, it stays in that browser. Matching is on exact wording, so a reworded section won't match.

Large PDFs open on page 1 right away while the rest load in the background. Pages far off screen are released from memory. Until you download, your highlights are auto-saved in this browser, and reopening the same file offers to restore them.

### Limitations

- Password-protected PDFs can't be opened, and encrypted PDFs can be viewed but not saved.
- Scanned PDFs without a text layer have nothing to select. Run OCR on them first.
- On pages that already had highlights, other annotation types (notes, stamps, drawings) aren't drawn on screen. They are still kept in the downloaded file.

### Development

`site/app.html` is the source. It is the body of the page, the form Claude artifacts publish. `./scripts/build-site.sh` wraps it in a full HTML document at `index.html`. Run that script after editing, and commit both files.

Libraries: [PDF.js](https://mozilla.github.io/pdf.js/) 3.11.174 renders pages and the selectable text layer, and [pdf-lib](https://pdf-lib.js.org/) 1.17.1 writes the highlight annotations.

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
| Open | ⌘O, or drag a PDF into the window |
| Highlight selection | ⇧⌘H, the toolbar button, or right-click → Highlight |
| Highlighter mode | ⌘E: every selection is highlighted right away |
| Highlight an area | **Highlight Area** in the toolbar (⇧⌘B), then drag a box over anything: signature blocks, blank lines, form fields, scanned text |
| Color | Toolbar swatches or ⌘1–⌘5 |
| Remove / recolor | Right-click a highlight, or select text and press ⌘⌫ to remove |
| Find | Search field in the toolbar, then ⌘G / ⇧⌘G, or **Highlight All** |
| Export highlighted text | File → Export Highlights as Markdown… (⇧⌘E) |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Save / Save As | ⌘S / ⇧⌘S (saves in place, writing to a temp file first) |
| Zoom | ⌘+, ⌘−, ⌘0 actual size, ⌘9 fit |

Saved passages work the same way as on the website: every passage you highlight is saved, and opening a PDF finds the same wording and offers to highlight it (sidebar → **Saved** tab for Ask / Highlight / Off, and Highlight → Highlight Saved Passages, ⌥⌘H, to run it on demand). The list is kept in the app's settings on your Mac.

A highlight that spans several lines appears as one entry in the list and is removed or recolored as one. The app asks before quitting or opening another file with unsaved highlights. It refuses PDFs that need a password, because saving would remove the password. `swift test` (needs full Xcode) runs the tests, and CI builds and tests the app on macOS for every change under `mac/`.
