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
            ToolbarItem(placement: .status) {
                if let progress = model.ocrProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading scanned pages… \(progress.done) of \(progress.total)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .help("Recognizing text on pages with no text layer, so Find, saved passages and phrase lists work there")
                } else if model.pageCount > 0 {
                    Text("Page \(max(model.currentPageNumber, 1)) of \(model.pageCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Page \(max(model.currentPageNumber, 1)) of \(model.pageCount)")
                }
            }
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
                Toggle(isOn: $model.areaMode) {
                    Label("Highlight Area", systemImage: "rectangle.dashed")
                }
                .help("Area highlight: drag a box over anything, such as signature lines, form fields or scanned text (⇧⌘B)")
                .disabled(model.document == nil)

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
        .sheet(isPresented: $model.showingPhraseSheet) {
            PhraseListSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.batchProgress != nil }, set: { _ in })) {
            BatchProgressSheet(model: model)
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
            Image(systemName: model.pendingTemplateName == nil ? "highlighter" : "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let name = model.pendingTemplateName {
                    Text("This looks like your “\(name)” form")
                        .fontWeight(.semibold)
                    Text("Highlight the same \(count) place\(count == 1 ? "" : "s") as last time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Found \(count) passage\(count == 1 ? "" : "s") you’ve highlighted before")
                        .fontWeight(.semibold)
                    Text("They match passages you highlighted in other PDFs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
                Text("Saved (\(library.passages.count + library.templates.count))").tag(Tab.saved)
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
                if !library.templates.isEmpty {
                    Section("Form templates") {
                        ForEach(library.templates) { template in
                            TemplateRow(model: model, library: library, template: template)
                        }
                    }
                }
                Section {
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
                } header: {
                    if !library.templates.isEmpty { Text("Passages") }
                }
            }
            Divider()
            HStack {
                Button("Highlight in This PDF") { model.highlightSavedPassagesNow() }
                    .disabled(model.document == nil || library.passages.isEmpty)
                Spacer()
                Menu {
                    Button("Highlight Phrases…") { model.showingPhraseSheet = true }
                        .disabled(model.document == nil)
                    Button("Save Highlights as Form Template…") { model.presentSaveTemplatePrompt() }
                        .disabled(model.highlights.isEmpty)
                    Button("Highlight a Batch of PDFs…") { model.presentBatchPanel() }
                    Divider()
                    Button("Export Library…") { model.presentLibraryExportPanel() }
                    Button("Import Library…") { model.presentLibraryImportPanel() }
                    Divider()
                    Button("Clear All Passages…") { confirmClear = true }
                        .disabled(library.passages.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More: phrase lists, form templates, batches, and moving your library between the Mac app and the website")
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

    var body: some View {
        let items = model.visibleHighlights
        List(selection: $model.selectedHighlightID) {
            if model.highlights.isEmpty {
                Text(model.document == nil
                     ? "No document open."
                     : "No highlights yet. Select text and press ⇧⌘H, or turn on the highlighter (⌘E).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
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
        .safeAreaInset(edge: .top, spacing: 0) {
            ColorFilterBar(model: model)
        }
        .safeAreaInset(edge: .bottom) {
            if !model.highlights.isEmpty {
                HStack {
                    Button("Copy All") { model.copyAllHighlights() }
                        .help("Copy the text of every highlight to the clipboard")
                    Spacer()
                    Button { model.selectPreviousHighlight() } label: { Image(systemName: "chevron.up") }
                        .help("Previous highlight (⌥⌘↑)")
                    Button { model.selectNextHighlight() } label: { Image(systemName: "chevron.down") }
                        .help("Next highlight (⌥⌘↓)")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        }
    }
}

/// Filters the highlights list by color; shown once highlights use more than one color.
struct ColorFilterBar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        let counts = Dictionary(grouping: model.highlights, by: \.paletteColor).mapValues(\.count)
        if counts.count > 1 || model.colorFilter != nil {
            HStack(spacing: 6) {
                filterButton(nil, label: Text("All"), count: model.highlights.count)
                ForEach(HighlightColor.allCases.filter { counts[$0] != nil }) { option in
                    filterButton(option, label: Circle().fill(option.swatch).frame(width: 10, height: 10), count: counts[option] ?? 0)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private func filterButton(_ option: HighlightColor?, label: some View, count: Int) -> some View {
        let isOn = model.colorFilter == option
        return Button {
            model.colorFilter = option
        } label: {
            HStack(spacing: 4) {
                label
                Text("\(count)").monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(option.map { "Show only \($0.name.lowercased()) highlights" } ?? "Show all highlights")
        .accessibilityLabel(option.map { "\($0.name), \(count)" } ?? "All, \(count)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A saved form template in the Saved tab.
struct TemplateRow: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var library: PassageLibrary
    let template: FormTemplate

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(template.name).lineLimit(1)
                Text("\(template.highlights.count) highlight\(template.highlights.count == 1 ? "" : "s") · \(template.pageCount) page\(template.pageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Apply") { model.applyTemplate(template) }
                .disabled(model.document == nil)
                .help("Highlight the same places in this PDF")
            Button {
                library.removeTemplate(template)
            } label: {
                Image(systemName: "xmark")
            }
            .help("Delete this template")
            .accessibilityLabel("Delete template")
        }
        .buttonStyle(.borderless)
        .contextMenu {
            Button("Apply to This PDF") { model.applyTemplate(template) }
                .disabled(model.document == nil)
            Button("Delete Template") { library.removeTemplate(template) }
        }
    }
}

/// Paste a list of phrases to highlight every occurrence of each.
struct PhraseListSheet: View {
    @ObservedObject var model: DocumentModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("phraseList.text") private var text = ""
    @AppStorage("phraseList.save") private var save = true
    @State private var result: String?

    var body: some View {
        let phrases = DocumentModel.phrases(from: text)
        VStack(alignment: .leading, spacing: 10) {
            Text("Highlight Phrases").font(.headline)
            Text("Paste words or phrases, one per line. Every place each one appears is highlighted in \(model.color.name.lowercased()).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            Toggle("Also save them for PDFs I open later", isOn: $save)
            if let result {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                ColorPalette(selection: $model.color)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Highlight \(phrases.count == 1 ? "1 Phrase" : "\(phrases.count) Phrases")") {
                    let outcome = model.highlightPhrases(phrases, save: save)
                    if outcome.missing.isEmpty {
                        dismiss()
                    } else {
                        let found = phrases.count - outcome.missing.count
                        result = "Highlighted \(found) of \(phrases.count). Not in this PDF: " + outcome.missing.prefix(6).joined(separator: ", ") + (outcome.missing.count > 6 ? "…" : "")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(phrases.isEmpty || model.document == nil)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onChange(of: text) { _ in result = nil }
    }
}

/// Progress while a batch of PDFs is highlighted.
struct BatchProgressSheet: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        let progress = model.batchProgress ?? JobProgress(done: 0, total: 0)
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlighting PDFs…").font(.headline)
            ProgressView(value: progress.fraction)
            HStack {
                Text("\(progress.done) of \(progress.total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { model.cancelBatch() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 340)
        .interactiveDismissDisabled()
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
                Text(item.text.isEmpty ? "Highlighted area" : item.text)
                    .foregroundStyle(item.text.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                Text("Page \(item.pageNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
