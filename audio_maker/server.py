"""Local web app: drop in a document, get an audiobook, keep a library."""

import json
import os
import queue
import re
import shutil
import tempfile
import threading
import traceback
import webbrowser
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel

from . import library, tts
from .extract import SUPPORTED, clean, extract

STATIC = Path(__file__).parent / "static"
app = FastAPI(title="Audio Maker")
jobs: "queue.Queue[str]" = queue.Queue()


# ---------- background generation ----------

def worker() -> None:
    while True:
        item_id = jobs.get()
        try:
            generate(item_id)
        except Exception as e:  # keep the worker alive no matter what
            traceback.print_exc()
            library.update(item_id, status="error", message=str(e))


def generate(item_id: str) -> None:
    item = library.get(item_id)
    if not item or item["status"] != "queued":
        return
    d = library.item_dir(item_id)
    text = (d / "text.txt").read_text()
    work = d / "parts"
    if item["engine"] == "apple":  # chatterbox parts are resumable; apple ones are quick to redo
        shutil.rmtree(work, ignore_errors=True)
    work.mkdir(exist_ok=True)
    library.update(item_id, status="working", progress=0, message="Starting")

    def progress(frac: float, msg: str) -> None:
        library.update(item_id, progress=round(frac * 0.97, 4), message=msg)

    files, sync = tts.synthesize(text, item["engine"], item["voice"], item["options"], work, progress)

    library.update(item_id, message="Stitching audio together")
    duration = tts.combine(files, d / "audio.m4a")
    (d / "sync.json").write_text(json.dumps(sync))
    shutil.rmtree(work, ignore_errors=True)
    library.update(item_id, status="done", progress=1, message=None, duration=duration)


# ---------- API ----------

@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return (STATIC / "index.html").read_text()


@app.get("/api/voices")
def voices() -> dict:
    clips = sorted(p.name for p in library.VOICES.iterdir() if p.is_file())
    return {"apple": tts.apple_voices(), "default_apple": tts.default_apple_voice(), "chatterbox_clips": clips}


@app.get("/api/items")
def items() -> list[dict]:
    return library.all_items()


@app.get("/api/items/{item_id}")
def item(item_id: str) -> dict:
    it = library.get(item_id) or _404()
    d = library.item_dir(item_id)
    it["text"] = (d / "text.txt").read_text()
    sync = d / "sync.json"
    it["sentences"] = json.loads(sync.read_text())["sentences"] if sync.exists() else None
    it["bookmarks"] = library.bookmarks(item_id)
    return it


@app.post("/api/items")
async def add_item(
    file: UploadFile | None = File(None),
    text: str = Form(""),
    title: str = Form(""),
    engine: str = Form("apple"),
    voice: str = Form(""),
    rate: int = Form(0),
    voice_clip: str = Form(""),
    exaggeration: float = Form(0.5),
    cfg_weight: float = Form(0.5),
) -> dict:
    if engine not in ("apple", "chatterbox"):
        raise HTTPException(400, "Unknown engine")
    source_name = ""
    if file is not None and file.filename:
        source_name = file.filename
        ext = Path(file.filename).suffix.lower()
        if ext not in SUPPORTED:
            raise HTTPException(400, f"Can't read {ext} files. Supported: {', '.join(sorted(SUPPORTED))}")
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / f"upload{ext}"
            p.write_bytes(await file.read())
            try:
                text = extract(p)
            except Exception as e:
                raise HTTPException(400, f"Couldn't extract text: {e}")
        title = title or Path(file.filename).stem.replace("_", " ")
    else:
        text = clean(text)
        if not text:
            raise HTTPException(400, "Add a file or paste some text")
        title = title or _title_from_text(text)

    options: dict = {}
    if engine == "apple":
        voice = voice or tts.default_apple_voice()
        if rate:
            options["rate"] = rate
    else:
        voice = voice_clip or "Default"
        options.update(exaggeration=exaggeration, cfg_weight=cfg_weight)
        if voice_clip:
            clip = library.VOICES / Path(voice_clip).name
            if not clip.exists():
                raise HTTPException(400, "Voice clip not found")
            options["voice_clip"] = str(clip)

    it = library.create(title, source_name, text, engine, voice, options)
    jobs.put(it["id"])
    return it


class Patch(BaseModel):
    title: str | None = None
    position: float | None = None
    finished: bool | None = None


@app.patch("/api/items/{item_id}")
def patch_item(item_id: str, body: Patch) -> dict:
    library.get(item_id) or _404()
    library.update(item_id, **body.model_dump(exclude_none=True))
    return library.get(item_id)


class Regen(BaseModel):
    engine: str
    voice: str = ""
    rate: int = 0
    voice_clip: str = ""
    exaggeration: float = 0.5
    cfg_weight: float = 0.5


@app.post("/api/items/{item_id}/regenerate")
def regenerate(item_id: str, body: Regen) -> dict:
    library.get(item_id) or _404()
    options: dict = {}
    voice = body.voice
    if body.engine == "apple":
        voice = voice or tts.default_apple_voice()
        if body.rate:
            options["rate"] = body.rate
    else:
        voice = body.voice_clip or "Default"
        options.update(exaggeration=body.exaggeration, cfg_weight=body.cfg_weight)
        if body.voice_clip:
            options["voice_clip"] = str(library.VOICES / Path(body.voice_clip).name)
    d = library.item_dir(item_id)
    shutil.rmtree(d / "parts", ignore_errors=True)
    (d / "audio.m4a").unlink(missing_ok=True)
    (d / "sync.json").unlink(missing_ok=True)
    library.update(item_id, engine=body.engine, voice=voice, options=options, status="queued",
                   progress=0, message=None, duration=None, position=0, finished=False)
    jobs.put(item_id)
    return library.get(item_id)


@app.delete("/api/items/{item_id}")
def delete_item(item_id: str) -> dict:
    library.delete(item_id)
    return {"ok": True}


@app.get("/api/items/{item_id}/audio")
def audio(item_id: str, download: bool = False):
    it = library.get(item_id) or _404()
    f = library.item_dir(item_id) / "audio.m4a"
    if not f.exists():
        _404()
    name = re.sub(r'[\\/:*?"<>|]', "", it["title"])[:120] + ".m4a"
    return FileResponse(f, media_type="audio/mp4", filename=name if download else None)


class NewBookmark(BaseModel):
    position: float
    note: str = ""


class BookmarkPatch(BaseModel):
    note: str


@app.get("/api/bookmarks")
def all_bookmarks() -> list[dict]:
    return library.bookmarks()


@app.post("/api/items/{item_id}/bookmarks")
def add_bookmark(item_id: str, body: NewBookmark) -> dict:
    library.get(item_id) or _404()
    return library.add_bookmark(item_id, body.position, body.note, _sentence_at(item_id, body.position))


@app.patch("/api/bookmarks/{bm_id}")
def edit_bookmark(bm_id: int, body: BookmarkPatch) -> dict:
    return library.update_bookmark(bm_id, body.note) or _404()


@app.delete("/api/bookmarks/{bm_id}")
def remove_bookmark(bm_id: int) -> dict:
    library.delete_bookmark(bm_id)
    return {"ok": True}


def _sentence_at(item_id: str, t: float) -> str:
    """The sentence being read at time t, saved with a bookmark so the list shows context."""
    sync = library.item_dir(item_id) / "sync.json"
    if not sync.exists():
        return ""
    sents = json.loads(sync.read_text())["sentences"]
    hit = next((s for s in sents if s.get("e", 0) > t), sents[-1] if sents else None)
    return hit["t"] if hit else ""


@app.get("/api/preview")
def preview(voice: str, rate: int = 0):
    out = Path(tempfile.gettempdir()) / "audio-maker-preview.m4a"
    tts.preview_apple(voice, rate or None, out)
    return FileResponse(out, media_type="audio/mp4", headers={"Cache-Control": "no-store"})


@app.post("/api/voice-clips")
async def upload_clip(file: UploadFile = File(...)) -> dict:
    name = Path(file.filename or "clip.wav").name
    if Path(name).suffix.lower() not in (".wav", ".mp3", ".m4a", ".flac", ".aiff"):
        raise HTTPException(400, "Voice clip must be audio (wav/mp3/m4a/flac/aiff)")
    (library.VOICES / name).write_bytes(await file.read())
    return {"name": name}


def _title_from_text(text: str) -> str:
    first = text.strip().splitlines()[0]
    return (first[:60] + "…") if len(first) > 60 else first


def _404():
    raise HTTPException(404, "Not found")


def main() -> None:
    import uvicorn

    library.init()
    for item_id in library.queued_ids():
        jobs.put(item_id)
    threading.Thread(target=worker, daemon=True).start()
    port = int(os.environ.get("AUDIO_MAKER_PORT", 8765))
    url = f"http://127.0.0.1:{port}"
    print(f"Audio Maker running at {url}  (library: {library.HOME})")
    if not os.environ.get("AUDIO_MAKER_NO_BROWSER"):
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    main()
