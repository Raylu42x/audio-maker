"""Runs in its own Python 3.11 env (via `uv run --with chatterbox-tts`) so torch never touches the main app.

Usage: python chatterbox_worker.py job.json
Prints `STATUS <msg>` and `PROGRESS <done>/<total>` lines on stdout.
"""

import json
import os
import sys
from pathlib import Path


def say(msg: str) -> None:
    print(msg, flush=True)


def main() -> None:
    job = json.loads(Path(sys.argv[1]).read_text())
    outdir = Path(job["outdir"])
    chunks = job["chunks"]

    say("STATUS Loading Chatterbox model")
    import soundfile as sf
    import torch
    from chatterbox.tts import ChatterboxTTS

    torch.set_num_threads(int(os.environ.get("AUDIO_MAKER_THREADS", "4")))
    device = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
    # Checkpoints were saved on CUDA; remap them onto whatever device we have.
    _load = torch.load
    torch.load = lambda *a, **k: _load(*a, **{"map_location": torch.device(device), **k})

    model = ChatterboxTTS.from_pretrained(device=device)
    if job.get("voice_clip"):
        model.prepare_conditionals(job["voice_clip"], exaggeration=job["exaggeration"])

    total = len(chunks)
    torch.set_grad_enabled(False)
    for i, text in enumerate(chunks):
        out = outdir / f"{i:05d}.wav"
        if not out.exists():  # resume support if a previous run died part way
            wav = model.generate(text, exaggeration=job["exaggeration"], cfg_weight=job["cfg_weight"])
            sf.write(out.with_suffix(".tmp.wav"), wav.squeeze(0).cpu().numpy(), model.sr)
            out.with_suffix(".tmp.wav").rename(out)
        say(f"PROGRESS {i + 1}/{total}")
        if device == "mps" and i % 20 == 19:
            torch.mps.empty_cache()  # stop GPU memory creeping up over long books


if __name__ == "__main__":
    main()
