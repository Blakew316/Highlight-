# Highlight

A small native macOS app for highlighting PDFs. It uses Apple's PDFKit (the same engine as Preview), so highlights are saved as standard PDF highlight annotations that show up in Preview, Acrobat, and other PDF readers.

## Requirements

- macOS 13 (Ventura) or newer
- Xcode 15+ (or the Xcode Command Line Tools, Swift 5.9+). Running the tests requires full Xcode.

## Install

```bash
git clone https://github.com/Blakew316/Highlight-.git
cd Highlight-
./scripts/build-app.sh
cp -R build/Highlight.app /Applications/
```

Then open **Highlight** from Applications, or right-click any PDF in Finder → **Open With → Highlight**.

For a quick run without installing: `swift run`.

## Using it

| Action | How |
|---|---|
| Open a PDF | ⌘O, or drag a PDF into the window |
| Highlight selected text | Select text, then ⇧⌘H (or the toolbar button, or right-click → Highlight) |
| Highlighter mode | ⌘E or the highlighter toolbar button: everything you select is highlighted right away |
| Choose a color | Click a toolbar swatch, or ⌘1–⌘5 (yellow, green, blue, pink, orange) |
| Remove a highlight | Right-click it → Remove Highlight, or select text and press ⌘⌫ |
| Recolor a highlight | Right-click it → Change Color |
| Jump to a highlight | Click it in the sidebar |
| Copy all highlighted text | Sidebar → Copy All Highlights (or the Highlight menu) |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Save / Save As | ⌘S / ⇧⌘S |
| Zoom | ⌘+, ⌘−, ⌘0 (actual size), ⌘9 (fit) |

Highlight asks before quitting or opening another file if you have unsaved highlights. Saves are written to a temporary file first and then swapped in, so a failed save never damages the original.

## Limitations

- PDFs that need a password to open aren't supported. Saving an unlocked copy would remove the password.
- Scanned PDFs without a text layer can't be highlighted, because there's no text to select. Run OCR on them first (for example in Preview or Acrobat).
- Highlights are stored one per line of text, so a three-line highlight appears as three entries in the sidebar.

## Development

```bash
swift build     # compile
swift test      # run the tests (needs Xcode)
open Package.swift   # work on it in Xcode
```

Code layout (`Sources/Highlight`):

- `HighlightApp.swift`: app entry point, menus, quit and Open With handling
- `DocumentModel.swift`: the open document, highlight add/remove/recolor with undo, open and save
- `Highlighter.swift`: creates and finds highlight annotations (PDFKit only, no UI)
- `HighlightPDFView.swift`: PDFView subclass for highlighter mode and the right-click menu
- `ContentView.swift`: SwiftUI window, toolbar, and sidebar
