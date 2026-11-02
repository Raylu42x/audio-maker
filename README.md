# Audio Maker

A native Mac app that turns documents into audiobooks you can follow along with.

Drop in a PDF (or EPUB, Word, RTF, HTML, Markdown, text — or paste text), pick a voice, and Audio Maker
extracts the text, speaks it to an `.m4a`, and keeps it in a library with resume-where-you-left-off,
speed control, highlighted follow-along text and bookmarks with notes. Everything runs on your Mac.

## Features

- **Any document**: PDF (with on-device OCR for scanned pages via Vision), EPUB, DOCX/DOC/ODT, RTF, HTML,
  Markdown, plain text, or pasted text. Drag files onto the window or the Dock icon, or use ⌘N.
- **Apple voices**: every voice on your Mac, including downloaded Premium/Enhanced voices and your
  **Personal Voice** (the app asks for permission). Fast: roughly 15–20× real time.
- **Chatterbox (optional)**: Resemble AI's open-source neural TTS, with voice cloning from a 10–20s clip.
  More natural, much slower. Needs [uv](https://docs.astral.sh/uv/) (`brew install uv`); the first run
  downloads PyTorch and the model (a few GB).
- **Follow along**: the sentence being read is highlighted and kept centered. Scroll away and auto-follow
  pauses until you hit "Back to where it's reading". Click any sentence to jump there.
- **Bookmarks with notes**: press **B** (or ⌘B) while listening. Each bookmark keeps the sentence being
  read; type a note under it. Bookmarked sentences are underlined; the sidebar's Bookmarks view lists
  them across the whole library.
- **Player**: speed 0.8–2.5×, −15s / +30s, media keys / Control Center, remembers your position per item.
- **Starts at login** (on by default, toggle in Settings ⌘,).

Keyboard: Space play/pause · ← back 15s · → forward 30s · B bookmark · ⌘N new.

## Build & install

Requires macOS 15+ and Xcode 16+.

```bash
open AudioMaker.xcodeproj          # then Run, or:
xcodebuild -project AudioMaker.xcodeproj -scheme AudioMaker -configuration Release -derivedDataPath build build
cp -R "build/Build/Products/Release/Audio Maker.app" /Applications/
```

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`xcodegen generate` after adding/removing files). Builds are ad-hoc signed by default; to sign with your
own certificate, create `Config/Local.xcconfig` (git-ignored):

```
CODE_SIGN_IDENTITY = Apple Development: you@example.com (XXXXXXXXXX)
DEVELOPMENT_TEAM = YOURTEAMID
```

## Library

Stored in `~/Music/Audio Maker/` (override with the `AUDIO_MAKER_HOME` environment variable):

```
items/<id>/item.json   title, voice, status, playback position, bookmarks + notes
items/<id>/text.txt    extracted text
items/<id>/sync.json   every sentence with its start/end time, for follow-along
items/<id>/audio.m4a   the audiobook (AAC, plays anywhere)
voices/                Chatterbox voice-cloning clips
```

## How it works

| File | Role |
|---|---|
| `Engine/Extractor.swift` | Text extraction per format. PDF lines are re-flowed into paragraphs (de-hyphenated, page numbers dropped); pages with no text layer are OCR'd with Vision. |
| `Engine/TextPlanner.swift` | Paragraph/sentence splitting (abbreviation-aware) and Chatterbox chunking. |
| `Engine/AppleSpeech.swift` | `AVSpeechSynthesizer.write` renders **one utterance per sentence** to PCM, so every sentence's timing is exact. |
| `Engine/Chatterbox.swift` + `Resources/chatterbox_worker.py` | Runs Chatterbox in its own `uv run --python 3.11 --with chatterbox-tts` process (PyTorch never loads into the app). Chunks of ≈280 chars; sentence times inside a chunk are estimated by speaking weight. |
| `Engine/AudioWriter.swift` | Converts any PCM format and appends it to one mono 24 kHz AAC `.m4a`, tracking exact frame time. |
| `Engine/Generator.swift` | One-at-a-time queue at utility priority; Chatterbox runs under `nice` with a capped thread count (Settings). Interrupted jobs restart on next launch. |
| `Playback/Player.swift` | AVPlayer, per-item resume, Now Playing / media keys. |
| `Views/ReaderView.swift` | Follow-along text: a TextKit 1 `NSTextView` (fast with whole books) using temporary attributes for the highlight and bookmark underlines. |

## History / decisions

- **v1 was a local web app** (Python/FastAPI + browser UI, run by a LaunchAgent). It was replaced by this
  native app so there's nothing extra running in the background and no browser tab. The old code is in
  git history (branches `agent/app-doc-reader`, `agent/app-follow-along-bookmarks`). On first launch the
  app imports the web version's `library.db` (items, positions, bookmarks) and renames it
  `library.db.imported`; the item folders are reused as-is.
- **Per-sentence Apple rendering** instead of the web version's 1000-character `say` chunks: in-process
  `AVSpeechSynthesizer` has no per-call startup cost (`say` had ~0.7s), so exact timing is free.
- **Chatterbox stays out-of-process** because it needs PyTorch; bundling a Python runtime would add GBs
  for an optional engine. `setuptools<81` is pinned because `resemble-perth` imports `pkg_resources`.
- **Not sandboxed**, so it can run `uv` for Chatterbox and use `~/Music/Audio Maker` directly.
