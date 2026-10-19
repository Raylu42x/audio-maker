import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: Library
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(search: search)
                .searchable(text: $search, placement: .sidebar, prompt: "Search library")
                .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        } detail: {
            switch model.selection {
            case .item(let id) where library.item(id) != nil:
                ItemDetailView(itemID: id).id(id)
            case .bookmarks:
                AllBookmarksView()
            default:
                EmptyLibraryView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.showingNew = true } label: { Label("New Audio", systemImage: "plus") }
                    .help("Make audio from a document (⌘N)")
            }
        }
        .sheet(isPresented: $model.showingNew) { NewItemView() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
        .onChange(of: library.items.map(\.status)) { _, _ in model.generator.kick() }
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ContentUnavailableView {
            Label("Drop a document here", systemImage: "doc.text.below.ecg")
        } description: {
            Text("PDF, EPUB, Word, RTF, HTML, Markdown or text. It becomes audio you can listen to and follow along with.")
        } actions: {
            Button("Choose a Document…") { model.showingNew = true }.buttonStyle(.borderedProminent)
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: Library
    let search: String

    private var shown: [Item] {
        guard !search.isEmpty else { return library.items }
        return library.items.filter { $0.title.localizedCaseInsensitiveContains(search) || ($0.sourceName ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(selection: $model.selection) {
            Label("Bookmarks", systemImage: "bookmark").tag(SidebarSelection.bookmarks)
            Section("Library") {
                ForEach(shown) { item in
                    LibraryRow(item: item)
                        .tag(SidebarSelection.item(item.id))
                        .contextMenu { RowMenu(item: item) }
                }
            }
        }
    }
}

struct RowMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: Library
    let item: Item
    var body: some View {
        Button(item.finished ? "Mark as Unfinished" : "Mark as Finished") {
            library.update(item.id) { $0.finished.toggle(); if $0.finished { $0.position = 0 } }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Library.dir(item.id)]) }
        Divider()
        Button("Delete", role: .destructive) { model.delete(item.id) }
    }
}

struct LibraryRow: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).fontWeight(.medium).lineLimit(1)
            HStack(spacing: 6) {
                Text(meta)
                if !item.bookmarks.isEmpty { Label("\(item.bookmarks.count)", systemImage: "bookmark.fill").labelStyle(.titleAndIcon) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let pct, pct > 0, !item.finished {
                ProgressView(value: pct).progressViewStyle(.linear).controlSize(.mini).tint(.accentColor)
            }
        }
        .padding(.vertical, 3)
    }

    private var meta: String {
        switch item.status {
        case .done:
            if item.finished { return "✓ Finished" }
            if item.position > 5, let d = item.duration { return "\(formatTime(d - item.position)) left" }
            return formatTime(item.duration)
        case .error: return "⚠︎ Failed"
        case .queued: return "Waiting…"
        case .working: return "Making audio · \(Int(item.progress * 100))%"
        }
    }

    private var pct: Double? {
        switch item.status {
        case .done: item.duration.map { min(1, item.position / max($0, 1)) }
        case .working: item.progress
        default: nil
        }
    }
}
