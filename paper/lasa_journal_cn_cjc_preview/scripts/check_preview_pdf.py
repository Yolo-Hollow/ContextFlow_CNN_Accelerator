#!/usr/bin/env python3
"""Fail-closed checks for the neutral CjC-layout LASA preview."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


FORBIDDEN = (
    "计算机学报",
    "CHINESE JOURNAL OF COMPUTERS",
    "收稿日期",
    "最终修改稿收到日期",
    "第1作者手机号码",
    "投稿时不提供DOI号",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("pdf", type=Path)
    args = parser.parse_args()

    pdf = args.pdf.resolve()
    if not pdf.is_file() or pdf.stat().st_size < 100_000:
        raise SystemExit(f"missing or implausibly small PDF: {pdf}")

    info = subprocess.run(
        ["pdfinfo", str(pdf)], check=True, capture_output=True, text=True,
        encoding="utf-8", errors="replace"
    ).stdout
    match = re.search(r"^Pages:\s+(\d+)\s*$", info, flags=re.MULTILINE)
    if not match:
        raise SystemExit("pdfinfo did not report a page count")
    pages = int(match.group(1))
    text = subprocess.run(
        ["pdftotext", "-enc", "UTF-8", str(pdf), "-"],
        check=True, capture_output=True, text=True, encoding="utf-8",
        errors="replace"
    ).stdout
    errors: list[str] = []
    for phrase in FORBIDDEN:
        if phrase.casefold() in text.casefold():
            errors.append(f"forbidden publication identity remains: {phrase}")
    for required in ("LASA", "层自适应", "YOLOv3-tiny", "165.6", "71.9"):
        if required not in text:
            errors.append(f"required manuscript content missing: {required}")
    if pages < 20:
        errors.append(f"unexpectedly short manuscript: {pages} pages")

    result = {
        "status": "FAIL" if errors else "PASS",
        "pdf": str(pdf),
        "pages": pages,
        "bytes": pdf.stat().st_size,
        "sha256": sha256(pdf),
        "forbidden_identity_terms": list(FORBIDDEN),
        "errors": errors,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
