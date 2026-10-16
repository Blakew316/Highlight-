import PDFKit
import SwiftUI

/// Main window: highlights sidebar plus the PDF (or an empty state).
struct ContentView: View {
    @ObservedObject var model: DocumentModel
    /// The highlights sidebar is pinned open: any attempt to collapse it is undone.
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var findQuery = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model, library: model.library)
                .modifier(HideSidebarToggle())
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            if model.document != nil {
                PDFKitView(pdfView: model.pdfView)
                    .safeAreaInset(edge: .top) {
                        if model.pendingSavedCount > 0 {
                            SavedMatchesBanner(model: model)
                        }
                    }
            } else {
                EmptyStateView(model: model)
            }
        }
        .onChange(of: columns) { visibility in
            if visibility != .all { columns = .all }
        }
        .searchable(text: $findQuery, placement: .toolbar, prompt: "Find in PDF")
        .onSubmit(of: .search) { model.find(findQuery) }
        .onChange(of: findQuery) { query in
            if query.trimmingCharacters(in: .whitespaces).count < 2 { model.clearFind() }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.isDirty ? "Edited" : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.findResults.isEmpty {
                    Text("\(model.findIndex + 1) of \(model.findResults.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button { model.findPrevious() } label: { Label("Previous Match", systemImage: "chevron.up") }
                        .help("Previous match (⇧⌘G)")
                    Button { model.findNext() } label: { Label("Next Match", systemImage: "chevron.down") }
                        .help("Next match (⌘G)")
                    Button("Highlight All") { model.highlightAllMatches() }
                        .help("Highlight every match in the current color")
                }
                Toggle(isOn: $model.highlighterMode) {
                    Label("Highlighter", systemImage: "highlighter")
                }
                .help("Highlighter mode: anything you select is highlighted automatically (⌘E)")
                .disabled(model.document == nil)

                ColorPalette(selection: $model.color)

                Button {
                    model.highlightCurrentSelection()
                } label: {
                    Label("Highlight Selection", systemImage: "text.badge.plus")
                }
                .help("Highlight the selected text (⇧⌘H)")
                .disabled(model.document == nil)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            model.open(url)
            return true
        }
    }
}

/// Removes the toolbar button that would hide the sidebar (macOS 14+; on 13
/// the button stays but `ContentView` reopens the sidebar immediately).
private struct HideSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

/// Hosts the model's PDFView. The view is owned by the model so commands and
/// menus can reach its selection.
struct PDFKitView: NSViewRepresentable {
    let pdfView: HighlightPDFView

    func makeNSView(context: Context) -> HighlightPDFView { pdfView }
    func updateNSView(_ nsView: HighlightPDFView, context: Context) {}
}

/// Row of color swatches shown in the toolbar.
struct ColorPalette: View {
    @Binding var selection: HighlightColor

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HighlightColor.allCases) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Circle()
                        .fill(option.swatch)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.85 : 0.2),
                                                  lineWidth: isSelected ? 2 : 1)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("\(option.name) (⌘\(option.number))")
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Shown when no PDF is open.
struct EmptyStateView: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "highlighter")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Open a PDF to start highlighting")
                .font(.title2)
            Button("Open PDF…") { model.presentOpenPanel() }
                .keyboardShortcut(.defaultAction)
            Text("or drag a PDF into this window")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Offers to highlight passages the user has highlighted in other PDFs.
struct SavedMatchesBanner: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        let count = model.pendingSavedCount
        HStack(spacing: 12) {
            Image(systemName: "highlighter")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Found \(count) passage\(count == 1 ? "" : "s") you’ve highlighted before")
                    .fontWeight(.semibold)
                Text("They match passages you highlighted in other PDFs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Not Now") { model.dismissPendingSavedMatches() }
            Button("Highlight Them") { model.applyPendingSavedMatches() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Sidebar with two tabs: this document's highlights, and saved passages.
struct SidebarView: View {
    enum Tab: Hashable { case document, saved }

    @ObservedObject var model: DocumentModel
    @ObservedObject var library: PassageLibrary
    @State private var tab: Tab = .document

    var body: some View {
        Group {
            switch tab {
            case .document: HighlightsSidebar(model: model)
            case .saved: SavedPassagesView(model: model, library: library)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Sidebar", selection: $tab) {
                Text("This PDF").tag(Tab.document)
                Text("Saved (\(library.passages.count))").tag(Tab.saved)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

/// Saved passages, the setting for what happens when a PDF is opened, and
/// controls to apply or forget them.
struct SavedPassagesView: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var library: PassageLibrary
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("When you open a PDF")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("When you open a PDF", selection: $library.mode) {
                    ForEach(AutoHighlightMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Every passage you highlight is saved here. Opening another PDF looks for the same wording and highlights it in the same color.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            Divider()
            List {
                if library.passages.isEmpty {
                    Text("Nothing saved yet. Passages you highlight show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(library.passages) { passage in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(passage.color.swatch)
                            .frame(width: 4)
                        Text(passage.text)
                            .lineLimit(3)
                        Spacer(minLength: 4)
                        Button {
                            library.remove(passage)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop matching this passage (highlights already made stay)")
                        .accessibilityLabel("Stop matching this passage")
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Stop Matching This Passage") { library.remove(passage) }
                    }
                }
            }
            Divider()
            HStack {
                Button("Highlight in This PDF") { model.highlightSavedPassagesNow() }
                    .disabled(model.document == nil || library.passages.isEmpty)
                Spacer()
                Button("Clear All…") { confirmClear = true }
                    .disabled(library.passages.isEmpty)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .confirmationDialog("Clear all saved passages?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { library.removeAll() }
        } message: {
            Text("Highlights already in your PDFs aren’t affected.")
        }
    }
}

/// Lists every highlight in the document; clicking one scrolls to it.
struct HighlightsSidebar: View {
    @ObservedObject var model: DocumentModel
    @State private var selection: HighlightItem.ID?

    var body: some View {
        List(selection: $selection) {
            if model.highlights.isEmpty {
                Text(model.document == nil
                     ? "No document open."
                     : "No highlights yet. Select text and press ⇧⌘H, or turn on the highlighter (⌘E).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.highlights) { item in
                HighlightRow(item: item)
                    .tag(item.id)
                    .contextMenu {
                        Button("Remove Highlight") { model.removeHighlights(item.members) }
                        Menu("Change Color") {
                            ForEach(HighlightColor.allCases) { option in
                                Button(option.name) { model.recolor(item.members, to: option) }
                            }
                        }
                    }
            }
        }
        .onChange(of: selection) { id in
            guard let id, let item = model.highlights.first(where: { $0.id == id }) else { return }
            model.reveal(item)
        }
        .safeAreaInset(edge: .bottom) {
            if !model.highlights.isEmpty {
                Button("Copy All Highlights") { model.copyAllHighlights() }
                    .buttonStyle(.borderless)
                    .padding(8)
                    .help("Copy the text of every highlight to the clipboard")
            }
        }
    }
}

struct HighlightRow: View {
    let item: HighlightItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: item.color.withAlphaComponent(1)))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text.isEmpty ? "(no text)" : item.text)
                    .lineLimit(3)
                Text("Page \(item.pageNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
