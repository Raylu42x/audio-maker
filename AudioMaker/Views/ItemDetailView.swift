import SwiftUI

struct ItemDetailView: View {
    let itemID: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @State private var sync: SyncMap?
    @State private var text = ""
    @State private var follow = true
    @State private var showingRemake = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false

    private var item: Item? { library.item(itemID) }
    private var isCurrent: Bool { player.itemID == itemID }

    private var currentSentence: Int? {
        guard isCurrent, let ss = sync?.sentences, !ss.isEmpty else { return nil }
        return Self.sentence(at: player.time, in: ss)
    }

    private var bookmarkedSentences: Set<Int> {
        guard let ss = sync?.sentences, !ss.isEmpty, let item else { return [] }
        return Set(item.bookmarks.map { Self.sentence(at: $0.position, in: ss) })
    }

    static func sentence(at t: Double, in ss: [Sentence]) -> Int {
        var lo = 0, hi = ss.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if (ss[mid].s ?? 0) <= t + 0.05 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                header(item)
                Divider()
                ReaderView(docID: itemID, sentences: sync?.sentences, plainText: text, current: currentSentence,
                           bookmarked: bookmarkedSentences, follow: $follow) { index in
                    guard item.status == .done, let s = sync?.sentences[index].s else { return }
                    follow = true
                    player.play(itemID, at: s)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !follow && isCurrent && sync != nil {
                        Button { follow = true } label: { Label("Back to where it's reading", systemImage: "arrow.down.to.line") }
                            .buttonStyle(.borderedProminent)
                            .padding(20)
                    }
                }
            }
            .inspector(isPresented: $model.showingBookmarks) {
                BookmarksPanel(itemID: itemID).inspectorColumnWidth(min: 240, ideal: 300, max: 420)
            }
            .toolbar {
                ToolbarItem {
                    Button { model.showingBookmarks.toggle() } label: { Label("Bookmarks", systemImage: "sidebar.right") }
                        .help("Show bookmarks")
                }
            }
            .navigationTitle(item.title)
            .task(id: item.status) {
                text = library.text(itemID)
                sync = library.sync(itemID)
            }
            .sheet(isPresented: $showingRemake) {
                RemakeSheet { choice in model.remake(itemID, voice: choice) }
            }
            .alert("Rename", isPresented: $renaming) {
                TextField("Title", text: $newTitle)
                Button("Rename") { let t = newTitle; if !t.isEmpty { library.update(itemID) { $0.title = t } } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(item.title)” and its audio?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.delete(itemID) }
            }
        }
    }

    @ViewBuilder
    private func header(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.title.weight(.semibold)).lineLimit(2)
            Text(metaLine(item)).font(.callout).foregroundStyle(.secondary)
            switch item.status {
            case .queued, .working:
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.status == .queued ? "Waiting in line…" : (item.message ?? "Working…")).font(.callout)
                    ProgressView(value: item.progress).progressViewStyle(.linear)
                }
                .frame(maxWidth: 520)
            case .error:
                Text("Audio generation failed: \(item.message ?? "")").foregroundStyle(.red).font(.callout).textSelection(.enabled)
            case .done:
                EmptyView()
            }
            HStack(spacing: 8) {
                Button {
                    isCurrent ? player.toggle() : player.play(itemID)
                } label: {
                    Label(playLabel(item), systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.status != .done)
                Button { model.bookmarkNow() } label: { Label("Bookmark", systemImage: "bookmark") }
                    .disabled(item.status != .done)
                Button { showingRemake = true } label: { Label("Re-make Audio…", systemImage: "waveform") }
                Menu {
                    Button("Rename…") { newTitle = item.title; renaming = true }
                    Button(item.finished ? "Mark as Unfinished" : "Mark as Finished") {
                        library.update(itemID) { $0.finished.toggle(); if $0.finished { $0.position = 0 } }
                    }
                    Button("Export Audio…") { export(item) }.disabled(item.status != .done)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Library.dir(itemID)]) }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if item.status == .done && sync == nil {
                Text("Made before follow-along existed — use Re-make Audio to get highlighted, clickable text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playLabel(_ item: Item) -> String {
        if isCurrent && player.isPlaying { return "Pause" }
        if item.position > 5 && !item.finished { return "Resume at \(formatTime(isCurrent ? player.time : item.position))" }
        return "Play"
    }

    private func metaLine(_ item: Item) -> String {
        var parts: [String] = []
        if let s = item.sourceName { parts.append(s) }
        if let d = item.duration { parts.append(formatTime(d)) }
        parts.append(item.engineLabel)
        parts.append("added \(item.created.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }

    private func export(_ item: Item) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title.replacingOccurrences(of: "/", with: "-") + ".m4a"
        panel.allowedContentTypes = [.mpeg4Audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: Library.audioURL(itemID), to: url)
    }
}
