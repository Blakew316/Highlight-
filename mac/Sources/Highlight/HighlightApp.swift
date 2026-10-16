import AppKit
import SwiftUI

@main
@MainActor
struct HighlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DocumentModel.shared

    var body: some Scene {
        Window("Highlight", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 700, minHeight: 500)
        }
        .commands { HighlightCommands(model: model, library: model.library) }
    }
}

/// Handles Finder "Open With", the quit prompt for unsaved highlights, and
/// makes the app a regular foreground app when launched via `swift run`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // After any file Finder asked us to open, reopen the last PDF if nothing is open.
        DispatchQueue.main.async { DocumentModel.shared.reopenLastDocument() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return }
        DocumentModel.shared.open(url)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DocumentModel.shared.confirmDiscardChanges() ? .terminateNow : .terminateCancel
    }
}

/// Menu bar: File (open/save), Edit (undo/redo), Highlight, View (zoom).
struct HighlightCommands: Commands {
    @ObservedObject var model: DocumentModel
    /// Observed too, so Apply Form Template lists templates as they're saved.
    @ObservedObject var library: PassageLibrary

    private var hasDocument: Bool { model.document != nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.availableRecentFiles, id: \.self) { url in
                    Button(url.lastPathComponent) { model.open(url) }
                }
                Divider()
                Button("Clear Menu") { model.clearRecentFiles() }
                    .disabled(model.recentFiles.isEmpty)
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }
                .keyboardShortcut("s")
                .disabled(!hasDocument)
            Button("Save As…") { model.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!hasDocument)
            Divider()
            Button("Export Highlights as Markdown…") { model.presentExportPanel() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.highlights.isEmpty)
            Button("Export Highlighted Pages as PDF…") { model.presentExportPagesPanel() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.highlights.isEmpty)
            Divider()
            Button("Highlight a Batch of PDFs…") { model.presentBatchPanel() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model.batchProgress != nil)
            Divider()
            Button("Export Library…") { model.presentLibraryExportPanel() }
            Button("Import Library…") { model.presentLibraryImportPanel() }
        }

        CommandGroup(replacing: .undoRedo) {
            Button(model.undoManager.undoMenuItemTitle) { model.undoManager.undo() }
                .keyboardShortcut("z")
                .disabled(!model.undoManager.canUndo)
            Button(model.undoManager.redoMenuItemTitle) { model.undoManager.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.undoManager.canRedo)
        }

        CommandMenu("Highlight") {
            Button("Highlight Selection") { model.highlightCurrentSelection() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!hasDocument)
            Button("Remove Highlights in Selection") { model.removeHighlightsInCurrentSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasDocument)
            Divider()
            Toggle("Highlighter Mode", isOn: $model.highlighterMode)
                .keyboardShortcut("e")
                .disabled(!hasDocument)
            Toggle("Area Highlight Mode", isOn: $model.areaMode)
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!hasDocument)
            Divider()
            ForEach(HighlightColor.allCases) { option in
                Toggle(option.name, isOn: Binding(
                    get: { model.color == option },
                    set: { if $0 { model.color = option } }
                ))
                .keyboardShortcut(KeyEquivalent(Character(String(option.number))))
            }
            Divider()
            Button("Find Next") { model.findNext() }
                .keyboardShortcut("g")
                .disabled(model.findResults.isEmpty)
            Button("Find Previous") { model.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.findResults.isEmpty)
            Button("Highlight All Matches") { model.highlightAllMatches() }
                .disabled(model.findResults.isEmpty)
            Divider()
            Button("Highlight Saved Passages") { model.highlightSavedPassagesNow() }
                .keyboardShortcut("h", modifiers: [.command, .option])
                .disabled(!hasDocument)
            Button("Highlight Phrases…") { model.showingPhraseSheet = true }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!hasDocument)
            Divider()
            Button("Save Highlights as Form Template…") { model.presentSaveTemplatePrompt() }
                .disabled(model.highlights.isEmpty)
            Menu("Apply Form Template") {
                ForEach(library.templates) { template in
                    Button(template.name) { model.applyTemplate(template) }
                }
            }
            .disabled(!hasDocument || library.templates.isEmpty)
            Divider()
            Button("Next Highlight") { model.selectNextHighlight() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model.highlights.isEmpty)
            Button("Previous Highlight") { model.selectPreviousHighlight() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(model.highlights.isEmpty)
            Divider()
            Button("Copy All Highlights") { model.copyAllHighlights() }
                .disabled(model.highlights.isEmpty)
        }

        // The highlights sidebar is always shown, so drop View > Hide Sidebar.
        CommandGroup(replacing: .sidebar) {}

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+")
                .disabled(!hasDocument)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!hasDocument)
            Button("Actual Size") { model.actualSize() }
                .keyboardShortcut("0")
                .disabled(!hasDocument)
            Button("Zoom to Fit") { model.zoomToFit() }
                .keyboardShortcut("9")
                .disabled(!hasDocument)
            Divider()
        }
    }
}
