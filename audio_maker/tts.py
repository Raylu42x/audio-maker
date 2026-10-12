"""Speech engines: Apple's built-in voices (via `say`) and Chatterbox (local neural TTS)."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable

import wave

from .extract import group_text, plan, speech_weight

Progress = Callable[[float, str], None]

# Novelty / legacy voices that aren't pleasant for long-form listening.
NOVELTY = {
    "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Fred", "Good News", "Jester",
    "Junior", "Kathy", "Organ", "Ralph", "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox",
}

# Max characters per TTS call. `say` has ~0.7s startup per call, so it gets bigger chunks;
# Chatterbox degrades on long inputs. Sentence timings inside a chunk are estimated by length.
CHUNK_CHARS = {"apple": 1000, "chatterbox": 280}

CHATTERBOX_WORKER = Path(__file__).parent / "chatterbox_worker.py"
CHATTERBOX_PYTHON = "3.11"
# Keep the Mac responsive: generation runs at low CPU priority, and Chatterbox gets a capped thread count.
NICE = ["nice", "-n", "10"]
CHATTERBOX_THREADS = os.environ.get("AUDIO_MAKER_THREADS", "4")
# resemble-perth (Chatterbox's watermarker) still imports pkg_resources, which setuptools 81 removed.
CHATTERBOX_DEPS = ["--with", "chatterbox-tts", "--with", "soundfile", "--with", "setuptools<81"]


def apple_voices() -> list[dict]:
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, check=True).stdout
    voices = []
    for line in out.splitlines():
        m = re.match(r"^(.+?)\s+([a-z]{2,3}_[A-Z0-9]{2,3})\s+#", line)
        if not m:
            continue
        name, lang = m.group(1).strip(), m.group(2)
        base = re.sub(r"\s*\(.*\)$", "", name)
        if base in NOVELTY:
            continue
        quality = 2 if "(Premium)" in name else 1 if "(Enhanced)" in name else 0
        voices.append({"id": name, "name": name, "lang": lang, "quality": quality})
    voices = list({v["id"]: v for v in voices}.values())
    # US English first, then other English, then by best quality.
    voices.sort(key=lambda v: (not v["lang"].startswith("en"), v["lang"] != "en_US", v["lang"], -v["quality"], v["name"]))
    return voices


def default_apple_voice() -> str:
    voices = [v for v in apple_voices() if v["lang"] == "en_US"]
    return voices[0]["id"] if voices else "Samantha"


def synth_apple(chunks: list[str], voice: str, rate: int | None, workdir: Path, progress: Progress) -> list[Path]:
    files = []
    for i, c in enumerate(chunks):
        txt = workdir / f"{i:05d}.txt"
        out = workdir / f"{i:05d}.wav"
        txt.write_text(c)
        cmd = [*NICE, "say", "-v", voice, "-f", str(txt), "-o", str(out),
               "--file-format=WAVE", "--data-format=LEI16@22050"]
        if rate:
            cmd += ["-r", str(rate)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"say failed: {r.stderr.strip() or r.stdout.strip()}")
        files.append(out)
        progress((i + 1) / len(chunks), f"Speaking part {i + 1} of {len(chunks)}")
    return files


def synth_chatterbox(chunks: list[str], options: dict, workdir: Path, progress: Progress) -> list[Path]:
    job = {
        "chunks": chunks,
        "outdir": str(workdir),
        "voice_clip": options.get("voice_clip"),
        "exaggeration": float(options.get("exaggeration", 0.5)),
        "cfg_weight": float(options.get("cfg_weight", 0.5)),
    }
    job_file = workdir / "job.json"
    job_file.write_text(json.dumps(job))
    progress(0, "Starting Chatterbox (first run downloads the model — this can take several minutes)")
    cmd = [
        "nice", "-n", "15", "uv", "run", "--no-project", "--python", CHATTERBOX_PYTHON,
        *CHATTERBOX_DEPS,
        "python", str(CHATTERBOX_WORKER), str(job_file),
    ]
    log_path = workdir / "chatterbox.log"  # stderr goes to a file: tqdm output would fill a pipe and deadlock
    log = log_path.open("w")
    env = {**os.environ, "OMP_NUM_THREADS": CHATTERBOX_THREADS, "AUDIO_MAKER_THREADS": CHATTERBOX_THREADS}
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1, env=env)
    for line in proc.stdout:
        line = line.strip()
        if line.startswith("PROGRESS "):
            done, total = map(int, line.split()[1].split("/"))
            progress(done / total, f"Chatterbox: part {done} of {total}")
        elif line.startswith("STATUS "):
            progress(0, line[7:])
    code = proc.wait()
    log.close()
    if code != 0:
        tail = "\n".join(log_path.read_text(errors="replace").strip().splitlines()[-5:])
        raise RuntimeError(f"Chatterbox failed:\n{tail}")
    return [workdir / f"{i:05d}.wav" for i in range(len(chunks))]


def synthesize(text: str, engine: str, voice: str, options: dict, workdir: Path, progress: Progress):
    """Speak `text`. Returns (wav parts, sync map) where the sync map places every sentence on the timeline."""
    sents, groups = plan(text, CHUNK_CHARS[engine])
    chunks = [group_text(sents, g) for g in groups]
    if engine == "chatterbox":
        files = synth_chatterbox(chunks, options, workdir, progress)
    else:
        files = synth_apple(chunks, voice, options.get("rate"), workdir, progress)
    t = 0.0
    for g, f in zip(groups, files):
        with wave.open(str(f)) as w:
            dur = w.getnframes() / w.getframerate()
        weights = [speech_weight(sents[i]["t"]) for i in g]
        total = sum(weights)
        for i, wt in zip(g, weights):
            sents[i]["s"] = round(t, 2)
            t += dur * wt / total
            sents[i]["e"] = round(t, 2)
    return files, {"version": 1, "sentences": sents}


def combine(files: list[Path], out: Path) -> float:
    """Concatenate audio parts into one AAC .m4a and return its duration in seconds."""
    listing = out.parent / "parts.txt"
    listing.write_text("".join(f"file '{f.as_posix()}'\n" for f in files))
    subprocess.run(
        [*NICE, "ffmpeg", "-y", "-threads", "2", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
         "-ac", "1", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", str(out)],
        check=True,
    )
    listing.unlink()
    dur = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(out)],
        capture_output=True, text=True, check=True,
    ).stdout
    return float(dur.strip())


def preview_apple(voice: str, rate: int | None, out: Path) -> None:
    cmd = ["say", "-v", voice, "-o", str(out), "--data-format=aac",
           "Hi! This is how I'll sound reading your documents."]
    if rate:
        cmd += ["-r", str(rate)]
    subprocess.run(cmd, check=True, capture_output=True)


if __name__ == "__main__":
    json.dump(apple_voices(), sys.stdout, indent=1)
