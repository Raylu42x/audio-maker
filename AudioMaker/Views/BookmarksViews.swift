import SwiftUI

struct BookmarkCard: View {
    let item: Item
    let bookmark: Bookmark
    var showTitle = false
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    player.play(item.id, at: bookmark.position)
                    if showTitle { model.selection = .item(item.id) }
                } label: {
                    Text(formatTime(bookmark.position)).monospacedDigit().fontWeight(.semibold).foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Jump here")
                if showTitle {
                    Button(item.title) { model.selection = .item(item.id) }.buttonStyle(.plain).fontWeight(.medium).lineLimit(1)
                }
                Spacer()
                Button { library.deleteBookmark(item.id, bookmark.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete bookmark")
            }
            if !bookmark.snippet.isEmpty {
                Text(bookmark.snippet).font(.callout).italic().foregroundStyle(.secondary).lineLimit(3)
            }
            TextField("Add a note…", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { focused = false }
                .onChange(of: note) { _, v in if v != bookmark.note { library.setNote(item.id, bookmark.id, v) } }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { note = bookmark.note }
    }
}

struct BookmarksPanel: View {
    let itemID: String
    @EnvironmentObject private var library: Library

    var body: some View {
        if let item = library.item(itemID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bookmarks").font(.headline)
                    if item.bookmarks.isEmpty {
                        Text("Press B (or ⌘B) while listening to bookmark the spot, then add a note.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(item.bookmarks) { BookmarkCard(item: item, bookmark: $0) }
                }
                .padding(14)
            }
        }
    }
}

struct AllBookmarksView: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        let all = library.allBookmarks
        Group {
            if all.isEmpty {
                ContentUnavailableView("No bookmarks yet", systemImage: "bookmark",
                                       description: Text("Press B while listening to bookmark a spot."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(all, id: \.bookmark.id) { BookmarkCard(item: $0.item, bookmark: $0.bookmark, showTitle: true) }
                    }
                    .padding(24)
                    .frame(maxWidth: 760)
                }
            }
        }
        .navigationTitle("Bookmarks")
    }
}
