import AppKit
import ServiceManagement
import SwiftUI

enum SidebarSelection: Hashable {
    case item(String)
    case bookmarks
}

/// Shared app state: the library, the audio generator, the player and what's on screen.
@MainActor
final class AppModel: ObservableObject {
    let library = Library()
    lazy var generator = Generator(library: library)
    lazy var player = Player(library: library)

    @Published var selection: SidebarSelection?
    @Published var showingNew = false
    @Published var pendingFile: URL?
    @Published var showingBookmarks = true

    init() {
        if let first = library.items.first { selection = .item(first.id) }
    }

    func start() {
        // Start at login by default (replaces the old web version's LaunchAgent); toggle in Settings.
        if !UserDefaults.standard.bool(forKey: "didSetUpLoginItem") {
            UserDefaults.standard.set(true, forKey: "didSetUpLoginItem")
            try? SMAppService.mainApp.register()
        }
        generator.kick()
    }

    func open(_ url: URL) {
        pendingFile = url
        showingNew = true
    }

    var selectedItemID: String? {
        if case .item(let id) = selection { id } else { nil }
    }

    func delete(_ id: String) {
        generator.cancel(id)
        if player.itemID == id { player.stop() }
        library.delete(id)
        if selectedItemID == id { selection = library.items.first.map { .item($0.id) } }
    }

    func remake(_ id: String, voice: VoiceChoice) {
        generator.cancel(id)
        if player.itemID == id { player.stop() }
        library.remake(id, voice: voice)
        generator.kick()
    }

    func bookmarkNow() {
        if let id = player.itemID {
            library.addBookmark(id, at: player.time)
            showingBookmarks = true
        } else if let id = selectedItemID, let it = library.item(id), it.status == .done {
            library.addBookmark(id, at: it.position)
            showingBookmarks = true
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var keyMonitor: Any?

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { Task { @MainActor in model?.open(url) } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Space / arrows / B control playback unless you're typing in a text field.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let model = self?.model else { return e }
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable { return e }
            if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return e }
            return MainActor.assumeIsolated {
                switch e.keyCode {
                case 49: model.player.toggle(selected: model.selectedItemID); return nil        // space
                case 123: model.player.skip(-15); return nil                                     // ←
                case 124: model.player.skip(30); return nil                                      // →
                case 11: model.bookmarkNow(); return nil                                         // B
                default: return e
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.player.savePosition() }
    }
}

@main
struct AudioMakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Audio Maker", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.library)
                .environmentObject(model.player)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear {
                    delegate.model = model
                    model.start()
                }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Audio…") { model.showingNew = true }.keyboardShortcut("n")
            }
            CommandMenu("Playback") {
                Button(model.player.isPlaying ? "Pause" : "Play") { model.player.toggle(selected: model.selectedItemID) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Back 15 Seconds") { model.player.skip(-15) }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Forward 30 Seconds") { model.player.skip(30) }.keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button("Add Bookmark") { model.bookmarkNow() }.keyboardShortcut("b")
            }
        }

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage("chatterboxThreads") private var threads = 4

    var body: some View {
        Form {
            Toggle("Open Audio Maker when I log in", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }
            Stepper("Chatterbox CPU threads: \(threads)", value: $threads, in: 1...12)
            Text("Lower = gentler on your Mac, slower Chatterbox audio. Apple voices aren't affected.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Library") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Library.home]) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
