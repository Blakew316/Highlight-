import PDFKit
import SwiftUI

/// Main window: highlights sidebar plus the PDF (or an empty state).
struct ContentView: View {
    @ObservedObject var model: DocumentModel
    /// The highlights sidebar is pinned open: any attempt to collapse it is undone.
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            HighlightsSidebar(model: model)
                .modifier(HideSidebarToggle())
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            if model.document != nil {
                PDFKitView(pdfView: model.pdfView)
            } else {
                EmptyStateView(model: model)
            }
        }
        .onChange(of: columns) { visibility in
            if visibility != .all { columns = .all }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.isDirty ? "Edited" : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
                        Button("Remove Highlight") { model.removeHighlights([item.placed]) }
                        Menu("Change Color") {
                            ForEach(HighlightColor.allCases) { option in
                                Button(option.name) { model.recolor([item.placed], to: option) }
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
