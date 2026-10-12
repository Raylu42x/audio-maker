# Audio Maker

Drop in a PDF (or EPUB, Word doc, text, Markdown, HTML, RTF), and Audio Maker pulls out the text,
turns it into an audiobook with a voice of your choice, and keeps everything in a library you can
come back to — with resume-where-you-left-off, speed control and downloads.

Everything runs locally on your Mac. Nothing is uploaded anywhere.

## Run it

```bash
uv run audio-maker
```

Your browser opens at http://127.0.0.1:8765. Drop a file onto the page, pick a voice, click **Make audio**.

Requirements: macOS, [uv](https://docs.astral.sh/uv/), and `ffmpeg` (`brew install ffmpeg`).

## Voices

**Apple voices** (default) — the voices built into macOS, driven through the `say` command. Fast
(a whole book in minutes). The best ones are the *Premium* and *Enhanced* versions: download them in
**System Settings → Accessibility → Spoken Content → System Voice → Manage Voices…** (try Ava, Zoe,
Evan or Nathan Premium). They show up in Audio Maker automatically. Siri voices and Personal Voice
aren't available to third-party apps.

**Chatterbox** — Resemble AI's open-source neural TTS, running on your Mac's GPU (MPS). More natural
and can clone a voice from a 10–20 second clip, but much slower (roughly real-time or slower on Apple
Silicon). It runs in its own Python 3.11 environment that `uv` creates on first use, which downloads
PyTorch and the model (a few GB) — the first job will sit on "Starting Chatterbox" for a while.
If a Chatterbox job is interrupted, re-running picks up where it left off.

## Easy on your Mac

- The app itself is a tiny local web server: ~0% CPU when idle, and the page stops polling once nothing is generating.
- Only one document is made at a time; everything else waits in line.
- `say`, `ffmpeg` and Chatterbox run at low CPU priority (`nice`), so whatever you're doing wins.
- Chatterbox is capped at 4 CPU threads (change with `AUDIO_MAKER_THREADS`) and only loads while a
  Chatterbox job is running; it exits when the job is done. Apple voices never touch it.
- Chatterbox's Python env + model take a few GB of disk in `~/.cache/uv` and `~/.cache/huggingface`
  (only if you ever use it). To reclaim it: `uv cache clean` and delete `~/.cache/huggingface/hub/models--ResembleAI--chatterbox`.

## Library

Stored in `~/Music/Audio Maker/` (override with `AUDIO_MAKER_HOME`):

```
library.db            SQLite: titles, voice, status, playback position
items/<id>/text.txt   extracted text
items/<id>/audio.m4a  the audiobook (AAC, plays anywhere — drag into Apple Books/Music if you like)
voices/               reference clips for Chatterbox voice cloning
```

Other settings: `AUDIO_MAKER_PORT` (default 8765), `AUDIO_MAKER_NO_BROWSER=1`.

## How it works

- `audio_maker/extract.py` — text extraction per format. PDF lines are re-flowed into paragraphs
  (de-hyphenated, page numbers dropped). Scanned PDFs with no text layer aren't supported yet.
- `audio_maker/tts.py` — splits text into sentence-aligned chunks (≈4000 chars for `say`, ≈280 for
  Chatterbox, which degrades on long inputs), synthesizes each, then stitches them into one `.m4a`
  with ffmpeg.
- `audio_maker/chatterbox_worker.py` — the Chatterbox process, launched with
  `uv run --python 3.11 --with chatterbox-tts` so torch stays out of the app's own environment.
- `audio_maker/server.py` — FastAPI app + a single background worker thread that processes the queue.
  Jobs interrupted by quitting are re-queued on next start.
- `audio_maker/static/index.html` — the whole UI (vanilla JS, no build step).
