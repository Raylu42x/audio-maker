"""SQLite-backed library of documents and their generated audio."""

import json
import os
import sqlite3
import threading
import time
import uuid
from pathlib import Path

HOME = Path(os.environ.get("AUDIO_MAKER_HOME", Path.home() / "Music" / "Audio Maker")).expanduser()
ITEMS = HOME / "items"
VOICES = HOME / "voices"  # reference clips for Chatterbox voice cloning

_lock = threading.Lock()

SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    source_name TEXT,
    created REAL NOT NULL,
    engine TEXT NOT NULL,
    voice TEXT,
    options TEXT NOT NULL DEFAULT '{}',
    status TEXT NOT NULL,          -- queued | working | done | error
    progress REAL NOT NULL DEFAULT 0,
    message TEXT,
    chars INTEGER NOT NULL DEFAULT 0,
    duration REAL,
    position REAL NOT NULL DEFAULT 0,
    finished INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    position REAL NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    snippet TEXT NOT NULL DEFAULT '',
    created REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS bookmarks_item ON bookmarks(item_id, position);
"""


def _db() -> sqlite3.Connection:
    HOME.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(HOME / "library.db")
    conn.row_factory = sqlite3.Row
    return conn


def init() -> None:
    ITEMS.mkdir(parents=True, exist_ok=True)
    VOICES.mkdir(parents=True, exist_ok=True)
    with _lock, _db() as c:
        c.executescript(SCHEMA)
        # Anything mid-generation when the server stopped gets re-queued.
        c.execute("UPDATE items SET status='queued', progress=0 WHERE status='working'")


def item_dir(item_id: str) -> Path:
    return ITEMS / item_id


def create(title: str, source_name: str, text: str, engine: str, voice: str, options: dict) -> dict:
    item_id = uuid.uuid4().hex[:12]
    d = item_dir(item_id)
    d.mkdir(parents=True)
    (d / "text.txt").write_text(text)
    with _lock, _db() as c:
        c.execute(
            "INSERT INTO items (id,title,source_name,created,engine,voice,options,status,chars) VALUES (?,?,?,?,?,?,?,?,?)",
            (item_id, title, source_name, time.time(), engine, voice, json.dumps(options), "queued", len(text)),
        )
    return get(item_id)


def get(item_id: str) -> dict | None:
    with _db() as c:
        row = c.execute("SELECT * FROM items WHERE id=?", (item_id,)).fetchone()
    return _row(row) if row else None


def all_items() -> list[dict]:
    with _db() as c:
        rows = c.execute(
            "SELECT items.*, (SELECT COUNT(*) FROM bookmarks b WHERE b.item_id = items.id) AS bookmark_count "
            "FROM items ORDER BY created DESC"
        ).fetchall()
    return [_row(r) for r in rows]


def queued_ids() -> list[str]:
    with _db() as c:
        return [r[0] for r in c.execute("SELECT id FROM items WHERE status='queued' ORDER BY created")]


ALLOWED = {"title", "status", "progress", "message", "duration", "position", "finished", "engine", "voice", "options"}


def update(item_id: str, **fields) -> None:
    fields = {k: v for k, v in fields.items() if k in ALLOWED}
    if "options" in fields:
        fields["options"] = json.dumps(fields["options"])
    if not fields:
        return
    cols = ", ".join(f"{k}=?" for k in fields)
    with _lock, _db() as c:
        c.execute(f"UPDATE items SET {cols} WHERE id=?", (*fields.values(), item_id))


def delete(item_id: str) -> None:
    import shutil

    with _lock, _db() as c:
        c.execute("DELETE FROM bookmarks WHERE item_id=?", (item_id,))
        c.execute("DELETE FROM items WHERE id=?", (item_id,))
    shutil.rmtree(item_dir(item_id), ignore_errors=True)


def bookmarks(item_id: str | None = None) -> list[dict]:
    q = "SELECT b.*, i.title FROM bookmarks b JOIN items i ON i.id = b.item_id"
    with _db() as c:
        if item_id:
            rows = c.execute(q + " WHERE b.item_id=? ORDER BY b.position", (item_id,)).fetchall()
        else:
            rows = c.execute(q + " ORDER BY b.created DESC").fetchall()
    return [dict(r) for r in rows]


def add_bookmark(item_id: str, position: float, note: str, snippet: str) -> dict:
    with _lock, _db() as c:
        cur = c.execute(
            "INSERT INTO bookmarks (item_id, position, note, snippet, created) VALUES (?,?,?,?,?)",
            (item_id, position, note, snippet, time.time()),
        )
        bm_id = cur.lastrowid
    return get_bookmark(bm_id)


def get_bookmark(bm_id: int) -> dict | None:
    with _db() as c:
        row = c.execute("SELECT b.*, i.title FROM bookmarks b JOIN items i ON i.id = b.item_id WHERE b.id=?", (bm_id,)).fetchone()
    return dict(row) if row else None


def update_bookmark(bm_id: int, note: str) -> dict | None:
    with _lock, _db() as c:
        c.execute("UPDATE bookmarks SET note=? WHERE id=?", (note, bm_id))
    return get_bookmark(bm_id)


def delete_bookmark(bm_id: int) -> None:
    with _lock, _db() as c:
        c.execute("DELETE FROM bookmarks WHERE id=?", (bm_id,))


def _row(row: sqlite3.Row) -> dict:
    d = dict(row)
    d["options"] = json.loads(d["options"] or "{}")
    d["finished"] = bool(d["finished"])
    d["has_audio"] = (item_dir(d["id"]) / "audio.m4a").exists()
    d["has_sync"] = (item_dir(d["id"]) / "sync.json").exists()
    return d
