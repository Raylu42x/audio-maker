# Audio Maker docs

Start with [../README.md](../README.md) for features and install steps.

## Layout

| Path | Job |
|---|---|
| `AudioMaker/Engine/Extractor.swift` | Pulls text from documents, with OCR for scanned PDF pages |
| `AudioMaker/Engine/TextPlanner.swift` | Prepares text for speech |
| `AudioMaker/Engine/AppleSpeech.swift`, `Chatterbox.swift` | The two speech engines |
| `AudioMaker/Engine/Generator.swift`, `AudioWriter.swift` | Generation and audio output |
| `AudioMaker/Model/` | Library and data models |
| `AudioMaker/Playback/Player.swift` | Playback |
| `AudioMaker/Views/` | SwiftUI interface |
| `AudioMaker/Resources/chatterbox_worker.py` | Python worker for Chatterbox |

`project.yml` is the project spec. `Config/Signing.xcconfig` is committed, and `Config/Local.xcconfig`
holds local signing settings and stays out of git.

## Status

This branch is the app installed in `/Applications`. Until PR #1 merges, `main` contains only `STATUS.md`.
