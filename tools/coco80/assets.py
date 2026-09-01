"""Fail-closed hashing, manifest creation, and asset verification."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path, PurePosixPath
import sys
import tempfile
from typing import Any, Iterable, Mapping, Sequence

from .schemas import AssetFile, AssetManifest, SchemaError


HASH_CHUNK_BYTES = 1024 * 1024


class AssetValidationError(RuntimeError):
    """Raised whenever an asset cannot be proven to match its manifest."""


def sha256_file(path: str | Path, chunk_bytes: int = HASH_CHUNK_BYTES) -> str:
    """Hash a regular, non-symlink file without loading it into memory."""

    target = Path(path)
    if isinstance(chunk_bytes, bool) or not isinstance(chunk_bytes, int) or chunk_bytes <= 0:
        raise ValueError("chunk_bytes must be a positive integer")
    if target.is_symlink():
        raise AssetValidationError(f"refusing to hash symlink asset: {target}")
    if not target.is_file():
        raise AssetValidationError(f"asset is not a regular file: {target}")
    digest = hashlib.sha256()
    with target.open("rb") as stream:
        while True:
            chunk = stream.read(chunk_bytes)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_json_bytes(payload: Mapping[str, Any]) -> bytes:
    try:
        text = json.dumps(
            payload,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
            allow_nan=False,
        ) + "\n"
    except (TypeError, ValueError) as exc:
        raise AssetValidationError(f"manifest is not canonical JSON: {exc}") from exc
    return text.encode("utf-8")


def write_json_atomic(path: str | Path, payload: Mapping[str, Any]) -> None:
    """Atomically replace a JSON file using a temporary in its destination dir."""

    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    data = _canonical_json_bytes(payload)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{destination.name}.",
            suffix=".tmp",
            dir=destination.parent,
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _within_root(root: Path, candidate: Path) -> bool:
    try:
        candidate.relative_to(root)
        return True
    except ValueError:
        return False


def _contains_symlink(root: Path, candidate: Path) -> bool:
    """Check the complete relative path, not only its final component."""

    try:
        parts = candidate.relative_to(root).parts
    except ValueError:
        return True
    current = root
    for part in parts:
        current = current / part
        if current.is_symlink():
            return True
    return False


def _asset_path(root: Path, value: str | Path) -> tuple[Path, str]:
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    if _contains_symlink(root, candidate):
        raise AssetValidationError(f"symlink assets are not accepted: {candidate}")
    try:
        resolved = candidate.resolve(strict=True)
    except FileNotFoundError as exc:
        raise AssetValidationError(f"asset does not exist: {candidate}") from exc
    if not _within_root(root, resolved):
        raise AssetValidationError(f"asset escapes root {root}: {candidate}")
    if not resolved.is_file():
        raise AssetValidationError(f"asset is not a regular file: {resolved}")
    relative = resolved.relative_to(root).as_posix()
    # Run through the strict schema before returning the name.
    PurePosixPath(relative)
    return resolved, relative


def build_manifest(
    root: str | Path,
    files: Iterable[str | Path],
    *,
    metadata: Mapping[str, Any] | None = None,
) -> AssetManifest:
    """Build a deterministic manifest for explicitly selected files."""

    root_path = Path(root).resolve(strict=True)
    if not root_path.is_dir():
        raise AssetValidationError(f"asset root is not a directory: {root_path}")
    records: list[AssetFile] = []
    seen: set[str] = set()
    for value in files:
        resolved, relative = _asset_path(root_path, value)
        if relative in seen:
            raise AssetValidationError(f"duplicate asset path: {relative}")
        seen.add(relative)
        records.append(
            AssetFile(
                path=relative,
                size_bytes=resolved.stat().st_size,
                sha256=sha256_file(resolved),
            )
        )
    records.sort(key=lambda entry: entry.path)
    try:
        return AssetManifest(tuple(records), dict(metadata or {}))
    except SchemaError as exc:
        raise AssetValidationError(str(exc)) from exc


def write_manifest_atomic(path: str | Path, manifest: AssetManifest) -> None:
    if not isinstance(manifest, AssetManifest):
        raise TypeError("manifest must be an AssetManifest")
    write_json_atomic(path, manifest.to_dict())


def load_manifest(path: str | Path) -> AssetManifest:
    source = Path(path)
    if source.is_symlink():
        raise AssetValidationError(f"manifest must not be a symlink: {source}")
    if not source.is_file():
        raise AssetValidationError(f"manifest does not exist: {source}")
    try:
        payload = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise AssetValidationError(f"cannot read manifest {source}: {exc}") from exc
    try:
        return AssetManifest.from_dict(payload)
    except SchemaError as exc:
        raise AssetValidationError(f"invalid manifest {source}: {exc}") from exc


def _normalize_required(path: str | Path) -> str:
    text = Path(path).as_posix()
    try:
        placeholder = AssetFile(path=text, size_bytes=0, sha256="0" * 64)
    except SchemaError as exc:
        raise AssetValidationError(f"invalid required asset path {path!r}: {exc}") from exc
    return placeholder.path


def verify_manifest(
    manifest: str | Path | AssetManifest,
    *,
    root: str | Path | None = None,
    required_paths: Iterable[str | Path] = (),
) -> tuple[Path, ...]:
    """Verify every declared file and return resolved paths in manifest order.

    Verification is fail-closed: malformed schemas, symlinks, missing required
    entries, size changes, and digest changes all raise ``AssetValidationError``.
    """

    manifest_path: Path | None = None
    if isinstance(manifest, AssetManifest):
        parsed = manifest
    else:
        manifest_path = Path(manifest).resolve(strict=False)
        parsed = load_manifest(manifest_path)
    if root is None:
        if manifest_path is None:
            raise AssetValidationError(
                "root is required when verifying an in-memory manifest"
            )
        root_path = manifest_path.parent.resolve(strict=True)
    else:
        root_path = Path(root).resolve(strict=True)
    if not root_path.is_dir():
        raise AssetValidationError(f"asset root is not a directory: {root_path}")

    declared = {entry.path for entry in parsed.files}
    required = {_normalize_required(path) for path in required_paths}
    missing_required = sorted(required - declared)
    if missing_required:
        raise AssetValidationError(
            f"required assets are absent from manifest: {missing_required}"
        )

    verified: list[Path] = []
    for entry in parsed.files:
        candidate = root_path.joinpath(*PurePosixPath(entry.path).parts)
        if _contains_symlink(root_path, candidate):
            raise AssetValidationError(f"asset became a symlink: {entry.path}")
        try:
            resolved = candidate.resolve(strict=True)
        except FileNotFoundError as exc:
            raise AssetValidationError(f"asset is missing: {entry.path}") from exc
        if not _within_root(root_path, resolved) or not resolved.is_file():
            raise AssetValidationError(f"asset is outside root or not regular: {entry.path}")
        actual_size = resolved.stat().st_size
        if actual_size != entry.size_bytes:
            raise AssetValidationError(
                f"asset size mismatch for {entry.path}: "
                f"expected {entry.size_bytes}, got {actual_size}"
            )
        actual_hash = sha256_file(resolved)
        if not hmac.compare_digest(actual_hash, entry.sha256):
            raise AssetValidationError(
                f"asset SHA256 mismatch for {entry.path}: "
                f"expected {entry.sha256}, got {actual_hash}"
            )
        verified.append(resolved)
    return tuple(verified)


# Descriptive alias for callers that treat the manifest as an asset gate.
validate_assets = verify_manifest


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Create or verify COCO80 asset manifests")
    subparsers = parser.add_subparsers(dest="command", required=True)

    hash_parser = subparsers.add_parser("sha256", help="hash one regular file")
    hash_parser.add_argument("file", type=Path)

    build_parser = subparsers.add_parser("build", help="atomically write a manifest")
    build_parser.add_argument("--root", required=True, type=Path)
    build_parser.add_argument("--output", required=True, type=Path)
    build_parser.add_argument("files", nargs="+", type=Path)

    verify_parser = subparsers.add_parser("verify", help="fail-closed manifest check")
    verify_parser.add_argument("manifest", type=Path)
    verify_parser.add_argument("--root", type=Path)
    verify_parser.add_argument("--require", action="append", default=[])

    args = parser.parse_args(argv)
    try:
        if args.command == "sha256":
            print(sha256_file(args.file))
        elif args.command == "build":
            built = build_manifest(args.root, args.files)
            write_manifest_atomic(args.output, built)
            print(json.dumps(built.to_dict(), indent=2, sort_keys=True))
        else:
            verified = verify_manifest(
                args.manifest,
                root=args.root,
                required_paths=args.require,
            )
            print(json.dumps({"status": "ok", "files": [str(p) for p in verified]}, indent=2))
        return 0
    except (OSError, ValueError, AssetValidationError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover - exercised through CLI
    raise SystemExit(main())
