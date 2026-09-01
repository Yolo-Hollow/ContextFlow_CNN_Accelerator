#!/usr/bin/env python3
"""Audit the LASA manuscript evidence chain and publication-freeze gates.

Draft mode verifies integrity and composition while permitting explicitly
declared PENDING experiments. Strict mode fails closed until every gate is
PASS, so an internal evidence draft cannot be mistaken for a submission.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--paper-root", type=Path, required=True)
    parser.add_argument(
        "--draft", action="store_true",
        help="permit declared PENDING experiments while checking all other gates",
    )
    args = parser.parse_args()
    paper = args.paper_root.resolve()
    repo = paper.parents[1]
    generated = paper / "generated"
    manifest_path = generated / "evidence_manifest.json"
    errors: list[str] = []

    if not manifest_path.is_file():
        errors.append(f"missing evidence manifest: {manifest_path}")
        manifest: dict[str, Any] = {}
    else:
        manifest = load_json(manifest_path)

    for name, record in manifest.get("generated_files", {}).items():
        path = generated / name
        if not path.is_file():
            errors.append(f"missing generated file: {name}")
            continue
        if path.stat().st_size != int(record["bytes"]):
            errors.append(f"generated size mismatch: {name}")
        if sha256(path) != record["sha256"]:
            errors.append(f"generated hash mismatch: {name}")

    for name, record in manifest.get("sources", {}).items():
        path = Path(record["path"])
        if not path.is_absolute():
            path = repo / path
        if not path.is_file():
            errors.append(f"missing evidence source {name}: {path}")
            continue
        if sha256(path) != record["sha256"]:
            errors.append(f"evidence source drift: {name}")

    bib = (paper / "references.bib").read_text(encoding="utf-8")
    reference_count = len(re.findall(r"(?m)^@\w+\s*\{", bib))
    if not 45 <= reference_count <= 60:
        errors.append(f"reference count {reference_count} outside [45, 60]")

    figure_count = sum(
        path.read_text(encoding="utf-8").count(r"\label{fig:")
        for path in (paper / "figures").glob("*.tex")
    )
    if figure_count != 9:
        errors.append(f"expected 9 core figures, found {figure_count}")

    section_paths = sorted((paper / "sections").glob("*.tex"))
    manuscript_text = main_text = (paper / "main.tex").read_text(encoding="utf-8")
    manuscript_text += "\n" + "\n".join(
        path.read_text(encoding="utf-8") for path in section_paths
    )
    cjk_count = len(re.findall(r"[\u3400-\u4dbf\u4e00-\u9fff]", manuscript_text))
    latin_word_count = len(re.findall(r"\b[A-Za-z][A-Za-z0-9_-]*\b", manuscript_text))
    word_equivalent = cjk_count + latin_word_count
    if not 18_000 <= word_equivalent <= 22_000:
        errors.append(f"manuscript word-equivalent {word_equivalent} outside [18000, 22000]")

    manual_tables = sum(
        text.count(r"\begin{table")
        for text in (path.read_text(encoding="utf-8") for path in section_paths)
    )
    if manual_tables:
        errors.append(f"found {manual_tables} hand-authored section tables; use generated tables")

    abstract_match = re.search(
        r"\\begin\{abstract\}(.*?)\\end\{abstract\}", main_text, re.DOTALL
    )
    abstract = abstract_match.group(1) if abstract_match else ""
    for token in ("100 MHz", "18x8", "288 ms", "24 通道", "无精度损失", "模型发布通过"):
        if token in abstract:
            errors.append(f"forbidden legacy/release claim in abstract: {token}")

    gates = manifest.get("publication_gates", {})
    pending = sorted(name for name, state in gates.items() if state != "PASS")
    if pending and not args.draft:
        errors.append("submission gates not PASS: " + ", ".join(pending))

    result = {
        "status": "PASS" if not errors else "FAIL",
        "mode": "draft" if args.draft else "submission-freeze",
        "reference_count": reference_count,
        "figure_count": figure_count,
        "cjk_characters": cjk_count,
        "latin_words": latin_word_count,
        "word_equivalent": word_equivalent,
        "manual_section_tables": manual_tables,
        "pending_gates": pending,
        "errors": errors,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if not errors else 2


if __name__ == "__main__":
    raise SystemExit(main())
