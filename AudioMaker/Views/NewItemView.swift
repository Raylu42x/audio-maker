import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Voice settings shared by "New Audio" and "Re-make Audio". Remembers your last choice.
struct VoiceSettings: View {
    @Binding var choice: VoiceChoice
    @State private var voices = AppleVoices.all()
    @State private var allLanguages = false
    @State private var clips = Chatterbox.clips()
    @State private var personalStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    @State private var pickingClip = false

    private var lang: String { Locale.current.language.languageCode?.identifier ?? "en" }
    private var shownVoices: [AVSpeechSynthesisVoice] {
        allLanguages ? voices : voices.filter { $0.language.hasPrefix(lang) || $0.voiceTraits.contains(.isPersonalVoice) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Engine", selection: $choice.engine) {
                Text("Apple voices").tag(Engine.apple)
                Text("Chatterbox (AI)").tag(Engine.chatterbox)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            if choice.engine == .apple {
                HStack {
                    Picker("Voice", selection: Binding(get: { choice.appleVoiceID }, set: { id in
                        choice.appleVoiceID = id
                        choice.appleVoiceName = voices.first { $0.identifier == id }.map(AppleVoices.label) ?? id
                    })) {
                        ForEach(shownVoices, id: \.identifier) { v in
                            Text(allLanguages ? "\(AppleVoices.label(v)) — \(v.language)" : AppleVoices.label(v)).tag(v.identifier)
                        }
                    }
                    .frame(maxWidth: 340)
                    Button { if let v = voices.first(where: { $0.identifier == choice.appleVoiceID }) { VoicePreview.play(v) } } label: {
                        Label("Preview", systemImage: "speaker.wave.2")
                    }
                }
                Toggle("Show all languages", isOn: $allLanguages).controlSize(.small)
                HStack(spacing: 10) {
                    if personalStatus == .notDetermined {
                        Button("Use my Personal Voice…") {
                            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                                Task { @MainActor in personalStatus = status; voices = AppleVoices.all() }
                            }
                        }
                    }
                    Button("Get better voices…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
                    }
                }
                .controlSize(.small)
                Text("Premium and Enhanced voices sound best. Download them in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices. Personal Voice is set up under Accessibility → Personal Voice.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                if !Chatterbox.isAvailable {
                    Text("Chatterbox needs uv. Install it with `brew install uv`, then reopen this window.")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Picker("Voice", selection: $choice.clip) {
                        Text("Built-in voice").tag("")
                        ForEach(clips, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 300)
                    Button("Clone a Voice…") { pickingClip = true }
                }
                HStack {
                    Text("Expressiveness")
                    Slider(value: $choice.exaggeration, in: 0.25...1.5).frame(width: 200)
                }
                Text("Chatterbox runs a neural voice model on your Mac. It sounds more natural but is much slower than Apple voices, and its first run downloads a few GB. To clone a voice, add a clean 10–20 second recording.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(isPresented: $pickingClip, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dest = Library.voicesDir.appending(path: url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
            clips = Chatterbox.clips()
            choice.clip = url.lastPathComponent
        }
        .onAppear {
            if AppleVoices.find(choice.appleVoiceID) == nil {
                let v = AppleVoices.best()
                choice.appleVoiceID = v.identifier
                choice.appleVoiceName = AppleVoices.label(v)
            }
        }
    }
}

/// Last-used voice settings, persisted in UserDefaults.
enum VoiceStore {
    static func load() -> VoiceChoice {
        let d = UserDefaults.standard
        return VoiceChoice(engine: Engine(rawValue: d.string(forKey: "engine") ?? "") ?? .apple,
                           appleVoiceID: d.string(forKey: "appleVoiceID") ?? "",
                           appleVoiceName: d.string(forKey: "appleVoiceName") ?? "",
                           clip: d.string(forKey: "clip") ?? "",
                           exaggeration: d.object(forKey: "exaggeration") as? Double ?? 0.5)
    }

    static func save(_ c: VoiceChoice) {
        let d = UserDefaults.standard
        d.set(c.engine.rawValue, forKey: "engine")
        d.set(c.appleVoiceID, forKey: "appleVoiceID")
        d.set(c.appleVoiceName, forKey: "appleVoiceName")
        d.set(c.clip, forKey: "clip")
        d.set(c.exaggeration, forKey: "exaggeration")
    }
}

struct NewItemView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var pasted = ""
    @State private var title = ""
    @State private var choice = VoiceStore.load()
    @State private var picking = false
    @State private var dropTargeted = false
    @State private var working: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Audio").font(.title2.weight(.semibold))

            VStack(spacing: 8) {
                Image(systemName: file == nil ? "doc.badge.plus" : "doc.text.fill").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(file?.lastPathComponent ?? "Drop a document here").fontWeight(.medium)
                Text("PDF, EPUB, Word, RTF, HTML, Markdown or text").font(.caption).foregroundStyle(.secondary)
                Button(file == nil ? "Choose File…" : "Choose a Different File…") { picking = true }
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in file = url } }
                }
                return true
            }

            if file == nil {
                Text("…or paste text").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $pasted)
                    .font(.body)
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            TextField("Title (optional — uses the file name)", text: $title).textFieldStyle(.roundedBorder)

            VoiceSettings(choice: $choice)

            if let error { Text(error).foregroundStyle(.red).font(.callout) }

            HStack {
                if let working { ProgressView().controlSize(.small); Text(working).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make Audio") { Task { await make() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working != nil || (file == nil && pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                              || (choice.engine == .chatterbox && !Chatterbox.isAvailable))
            }
        }
        .padding(24)
        .frame(width: 560)
        .fileImporter(isPresented: $picking, allowedContentTypes: Extractor.contentTypes) { result in
            if case .success(let url) = result { file = url }
        }
        .onAppear {
            if let f = model.pendingFile { file = f; model.pendingFile = nil }
        }
    }

    private func make() async {
        error = nil
        working = file == nil ? "Saving…" : "Reading document…"
        defer { working = nil }
        do {
            let text: String
            var sourceName: String?
            var name = title.trimmingCharacters(in: .whitespaces)
            if let file {
                let access = file.startAccessingSecurityScopedResource()
                defer { if access { file.stopAccessingSecurityScopedResource() } }
                text = try await Extractor.extract(file) { msg in Task { @MainActor in working = msg } }
                sourceName = file.lastPathComponent
                if name.isEmpty { name = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ") }
            } else {
                text = Extractor.clean(pasted)
                if name.isEmpty {
                    let first = text.split(separator: "\n").first.map(String.init) ?? "Untitled"
                    name = first.count > 60 ? String(first.prefix(60)) + "…" : first
                }
            }
            VoiceStore.save(choice)
            let item = try library.add(title: name, sourceName: sourceName, text: text, voice: choice)
            model.selection = .item(item.id)
            model.generator.kick()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RemakeSheet: View {
    var onRemake: (VoiceChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choice = VoiceStore.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Re-make Audio").font(.title2.weight(.semibold))
            Text("Replaces this item's audio using a different voice. Bookmarks are kept.").foregroundStyle(.secondary)
            VoiceSettings(choice: $choice)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Re-make") { VoiceStore.save(choice); onRemake(choice); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(choice.engine == .chatterbox && !Chatterbox.isAvailable)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}
