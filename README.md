# Highlight

A website for highlighting PDFs in your browser. Open a PDF, select text, pick a color, and download the PDF with your highlights saved into it. The highlights are standard PDF highlight annotations, so they show up in Preview, Acrobat, and other PDF readers.

Your files stay on your computer. The PDF is opened and saved entirely in the browser and is never uploaded.

## Use it

- **Hosted:** open `index.html` from GitHub Pages (Settings → Pages → deploy from the `main` branch, root folder), or
- **Locally:** download `index.html` and double-click it. It loads PDF.js and pdf-lib from cdnjs, so it needs an internet connection.

| Action | How |
|---|---|
| Open a PDF | **Open PDF**, or drag a PDF onto the page |
| Highlight | Select text, then click a color in the popup (or press **H**) |
| Auto-highlight | Toggle **Auto-highlight**: every selection is highlighted when you let go |
| Choose a color | Toolbar swatches, or keys **1–5** |
| Recolor or remove | Click a highlight, then pick a color or **Remove** (or press Delete) |
| Jump to a highlight | Click it in the Highlights list |
| Copy highlighted text | **Copy all text** at the bottom of the list |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Save | **Download PDF** (⌘S) |

Highlights already in a PDF, including ones made in Preview or by this site earlier, are loaded as editable highlights.

## Limitations

- Password-protected PDFs can't be opened, and encrypted PDFs can be viewed but not saved.
- Scanned PDFs without a text layer have nothing to select. Run OCR on them first.
- On pages that already had highlights, other annotation types (notes, stamps, drawings) aren't drawn on screen. They are still kept in the downloaded file.

## Development

`site/app.html` is the source. It is the body of the page, the form Claude artifacts publish. `./scripts/build-site.sh` wraps it in a full HTML document at `index.html`. Run that script after editing, and commit both files.

Libraries: [PDF.js](https://mozilla.github.io/pdf.js/) 3.11.174 renders pages and the selectable text layer, and [pdf-lib](https://pdf-lib.js.org/) 1.17.1 writes the highlight annotations.
