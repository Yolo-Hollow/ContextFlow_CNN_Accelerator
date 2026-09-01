#!/usr/bin/env python3
"""Checks the public-facing LASA narrative manuscript and rendered PDF."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


PDF_FORBIDDEN = (
    "计算机学报",
    "CHINESE JOURNAL OF COMPUTERS",
    "PENDING",
    "TODO",
    "内部证据稿",
    "冻结门禁",
    "SHA256",
    "Git commit",
    "本文不会",
    "本文不声称",
    "尚未完成",
    "不等价于",
)

PDF_REQUIRED = (
    "片上物化重放",
    "上下文调度",
    "28.618",
    "165.6",
    "71.9",
    "34.943",
    "1,625.9",
    "46.5",
    "2,816",
    "14.304",
    "30.212",
    "12.61",
    "7.28",
    "1.42",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--paper-root", required=True, type=Path)
    parser.add_argument("--pdf", required=True, type=Path)
    args = parser.parse_args()

    root = args.paper_root.resolve()
    pdf = args.pdf.resolve()
    errors: list[str] = []
    if not pdf.is_file() or pdf.stat().st_size < 100_000:
        errors.append(f"missing or implausibly small PDF: {pdf}")

    source_files = [root / "main.tex", *sorted((root / "sections").glob("*.tex"))]
    source_text = "\n".join(path.read_text(encoding="utf-8") for path in source_files)
    for token in (r"\todo", r"\nocite{*}", "PENDING", "内部证据稿"):
        if token in source_text:
            errors.append(f"publication source contains forbidden token: {token}")

    info = subprocess.run(
        ["pdfinfo", str(pdf)], check=True, capture_output=True, text=True,
        encoding="utf-8", errors="replace"
    ).stdout
    match = re.search(r"^Pages:\s+(\d+)\s*$", info, flags=re.MULTILINE)
    pages = int(match.group(1)) if match else 0
    if not 16 <= pages <= 18:
        errors.append(f"page target is 16-18, got {pages}")

    text = subprocess.run(
        ["pdftotext", "-enc", "UTF-8", str(pdf), "-"], check=True,
        capture_output=True, text=True, encoding="utf-8", errors="replace"
    ).stdout
    for phrase in PDF_FORBIDDEN:
        if phrase.casefold() in text.casefold():
            errors.append(f"forbidden public-manuscript phrase remains: {phrase}")
    for phrase in PDF_REQUIRED:
        if phrase not in text:
            errors.append(f"required narrative/result is missing: {phrase}")

    compact_text = re.sub(r"\s+", "", text)
    if "本文的主要贡献概括为以下两点" not in compact_text:
        errors.append("two-contribution introduction block not found")

    result = {
        "status": "FAIL" if errors else "PASS",
        "pdf": str(pdf),
        "pages": pages,
        "bytes": pdf.stat().st_size if pdf.is_file() else 0,
        "sha256": sha256(pdf) if pdf.is_file() else None,
        "errors": errors,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
