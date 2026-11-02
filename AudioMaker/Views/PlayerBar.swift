import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @State private var scrub: Double?

    private let speeds: [Float] = [0.8, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5]

    var body: some View {
        let item = player.itemID.flatMap { library.item($0) }
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.title ?? "Nothing playing").fontWeight(.semibold).lineLimit(1)
                Text(item?.engineLabel ?? "Pick something from your library").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 230, alignment: .leading)
            .onTapGesture { if let item { model.selection = .item(item.id) } }

            VStack(spacing: 4) {
                HStack(spacing: 18) {
                    Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }.help("Back 15s (←)")
                    Button { player.toggle(selected: model.selectedItemID) } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
                    }
                    .help("Play/Pause (space)")
                    Button { player.skip(30) } label: { Image(systemName: "goforward.30") }.help("Forward 30s (→)")
                    Button { model.bookmarkNow() } label: { Image(systemName: "bookmark") }.help("Bookmark this spot (B)")
                }
                .buttonStyle(.plain)
                .font(.system(size: 17))
                .disabled(item == nil && model.selectedItemID == nil)

                HStack(spacing: 8) {
                    Text(formatTime(scrub ?? player.time)).monospacedDigit()
                    Slider(value: Binding(get: { scrub ?? player.time }, set: { scrub = $0 }),
                           in: 0...max(player.duration, 1)) { editing in
                        if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                    }
                    .controlSize(.small)
                    Text(formatTime(player.duration)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                .disabled(item == nil)
            }
            .frame(maxWidth: 620)

            Picker("Speed", selection: $player.rate) {
                ForEach(speeds, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
            }
            .frame(width: 130)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
