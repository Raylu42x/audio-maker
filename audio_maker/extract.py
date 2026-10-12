"""Pull readable text out of documents."""

import re
from pathlib import Path

SUPPORTED = {".pdf", ".txt", ".md", ".markdown", ".docx", ".epub", ".html", ".htm", ".rtf"}


def extract(path: Path) -> str:
    ext = path.suffix.lower()
    if ext == ".pdf":
        text = _pdf(path)
    elif ext == ".docx":
        text = _docx(path)
    elif ext == ".epub":
        text = _epub(path)
    elif ext in (".html", ".htm"):
        text = _html(path.read_bytes())
    elif ext == ".rtf":
        text = _rtf(path)
    elif ext in (".txt", ".md", ".markdown"):
        text = path.read_text(errors="replace")
        if ext != ".txt":
            text = _strip_markdown(text)
    else:
        raise ValueError(f"Unsupported file type: {ext}")
    text = clean(text)
    if not text.strip():
        raise ValueError("No readable text found (scanned PDFs without a text layer aren't supported yet).")
    return text


def _pdf(path: Path) -> str:
    from pypdf import PdfReader

    reader = PdfReader(path)
    pages = []
    for page in reader.pages:
        pages.append(_reflow(page.extract_text() or ""))
    return "\n\n".join(pages)


def _reflow(page: str) -> str:
    """PDFs break lines mid-sentence; stitch them back into paragraphs."""
    lines = [ln.strip() for ln in page.splitlines()]
    # Drop bare page numbers.
    lines = [ln for ln in lines if not re.fullmatch(r"(page\s*)?\d{1,4}", ln, re.I)]
    lengths = sorted(len(ln) for ln in lines if ln)
    full = lengths[int(len(lengths) * 0.75)] if lengths else 80  # a typical full-width line
    out: list[str] = []
    prev_raw = ""
    for ln in lines:
        if not ln:
            if out and out[-1] != "":
                out.append("")
            continue
        if out and out[-1]:
            joined = out[-1]
            short = len(prev_raw) < full * 0.8  # line ended early: paragraph end or heading
            if joined.endswith("-") and ln[:1].islower():
                out[-1] = joined[:-1] + ln
                prev_raw = ln
                continue
            if ln[:1].islower() or not short:
                out[-1] = joined + " " + ln
                prev_raw = ln
                continue
        out.append(ln)
        prev_raw = ln
    return "\n\n".join(p for p in out if p)


def _docx(path: Path) -> str:
    import docx

    d = docx.Document(str(path))
    return "\n\n".join(p.text for p in d.paragraphs if p.text.strip())


def _epub(path: Path) -> str:
    import ebooklib
    from ebooklib import epub

    book = epub.read_epub(str(path), options={"ignore_ncx": True})
    parts = []
    for item_id, _ in book.spine:
        item = book.get_item_with_id(item_id)
        if item is not None and item.get_type() == ebooklib.ITEM_DOCUMENT:
            parts.append(_html(item.get_content()))
    return "\n\n".join(p for p in parts if p.strip())


def _html(data: bytes) -> str:
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(data, "html.parser")
    for tag in soup(["script", "style", "nav", "header", "footer"]):
        tag.decompose()
    blocks = [el.get_text(" ", strip=True) for el in soup.find_all(["p", "h1", "h2", "h3", "h4", "li", "blockquote"])]
    blocks = [b for b in blocks if b]
    return "\n\n".join(blocks) if blocks else soup.get_text("\n")


def _rtf(path: Path) -> str:
    import subprocess

    return subprocess.run(
        ["textutil", "-convert", "txt", "-stdout", str(path)], capture_output=True, text=True, check=True
    ).stdout


def _strip_markdown(text: str) -> str:
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"^#{1,6}\s*", "", text, flags=re.M)
    text = re.sub(r"[*_`]{1,3}", "", text)
    return text


def clean(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("­", "").replace("\x00", "")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def paragraphs(text: str) -> list[str]:
    return [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]


def chunk(text: str, max_chars: int) -> list[str]:
    """Group text into chunks of whole sentences no longer than max_chars."""
    sentences: list[str] = []
    for para in paragraphs(text):
        para = " ".join(para.split())
        for s in re.split(r"(?<=[.!?…])\s+", para):
            while len(s) > max_chars:  # very long run-on: split on spaces
                cut = s.rfind(" ", 0, max_chars)
                cut = cut if cut > 0 else max_chars
                sentences.append(s[:cut])
                s = s[cut:].strip()
            if s:
                sentences.append(s)
        sentences.append("")  # paragraph boundary marker
    chunks: list[str] = []
    cur = ""
    for s in sentences:
        if s == "":
            if cur and len(cur) > max_chars * 0.6:
                chunks.append(cur)
                cur = ""
            elif cur:
                cur += "\n\n"
            continue
        if cur and len(cur) + len(s) + 1 > max_chars:
            chunks.append(cur.strip())
            cur = ""
        cur = (cur + " " + s) if cur and not cur.endswith("\n") else cur + s
    if cur.strip():
        chunks.append(cur.strip())
    return chunks
