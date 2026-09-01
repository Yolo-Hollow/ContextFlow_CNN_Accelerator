"""Safe, hash-bound deployment of the COCO80 evaluation set to an SD card.

The card is an external target, so this tool never formats it and never
replaces a different existing file.  A destination file is copied only when
absent or byte-identical; a hash mismatch is a hard error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
import struct
import tempfile
from pathlib import Path
from typing import Any, Iterable


CARD_FORMAT = "kv260-coco80-sd-card"
CARD_VERSION = 1
MIN_FREE_BYTES = 4 * 1024 * 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _regular(path: Path, label: str) -> Path:
    path = path.resolve()
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f"{label} is not a regular file: {path}")
    return path


def _copy_if_same_or_absent(source: Path, destination: Path, label: str) -> dict[str, Any]:
    source = _regular(source, label)
    digest = sha256_file(source)
    if destination.exists():
        if not destination.is_file() or destination.is_symlink():
            raise RuntimeError(f"refusing to overwrite non-regular {label}: {destination}")
        if destination.stat().st_size != source.stat().st_size or sha256_file(destination) != digest:
            raise RuntimeError(f"refusing to overwrite different {label}: {destination}")
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="wb", dir=destination.parent, prefix=destination.name + ".", delete=False
            ) as stream:
                temporary = Path(stream.name)
                with source.open("rb") as reader:
                    shutil.copyfileobj(reader, stream, length=8 * 1024 * 1024)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, destination)
            temporary = None
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return {"path": str(destination), "bytes": source.stat().st_size, "sha256": digest}


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=path.name + ".", delete=False
        ) as stream:
            temporary = Path(stream.name)
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def prepare_card(card: Path, *, bit: Path, xsa: Path, source_root: Path) -> dict[str, Any]:
    card = card.resolve()
    card.mkdir(parents=True, exist_ok=True)
    usage = shutil.disk_usage(card)
    if usage.free < MIN_FREE_BYTES:
        raise RuntimeError(f"SD card has only {usage.free} free bytes; minimum is {MIN_FREE_BYTES}")
    directories = [
        "ARTIFACT", "PARAM", "INPUT", "OUTPUT/ACCURACY", "OUTPUT/PRODUCT",
        "OUTPUT/PERF", "OUTPUT/CONFORM", "MANIFEST",
    ]
    for relative in directories:
        (card / relative).mkdir(parents=True, exist_ok=True)
    artifacts = {
        "bit": _copy_if_same_or_absent(bit, card / "ARTIFACT" / "r5.bit", "BIT"),
        "xsa": _copy_if_same_or_absent(xsa, card / "ARTIFACT" / "r5.xsa", "XSA"),
    }
    manifest = {
        "format": CARD_FORMAT,
        "version": CARD_VERSION,
        "card_root": str(card),
        "artifacts": artifacts,
        "directories": directories,
        "free_bytes_after_prepare": shutil.disk_usage(card).free,
        "source_root": str(source_root.resolve()),
        "status": "ARTIFACTS_READY",
    }
    _write_json(card / "MANIFEST" / "card_manifest.json", manifest)
    return manifest


def _canonical_input_qparams(path: Path) -> dict[str, Any]:
    path = _regular(path, "quantization manifest")
    data = json.loads(path.read_text(encoding="utf-8"))
    layers = data.get("layers")
    if (
        data.get("format") != "kv260-coco80-rtl-quantization"
        or data.get("version") != 1
        or not isinstance(layers, list)
        or len(layers) != 13
        or not isinstance(layers[0], dict)
        or layers[0].get("name") != "m0"
    ):
        raise RuntimeError("unsupported canonical COCO80 quantization manifest")
    quant = layers[0].get("quant")
    input_q = quant.get("input") if isinstance(quant, dict) else None
    if not isinstance(input_q, dict):
        raise RuntimeError("m0 input quantization is missing")
    scale = input_q.get("scale")
    zero_point = input_q.get("zero_point")
    if (
        isinstance(scale, bool)
        or not isinstance(scale, (int, float))
        or not math.isfinite(float(scale))
        or float(scale) <= 0.0
        or isinstance(zero_point, bool)
        or not isinstance(zero_point, int)
        or input_q.get("qmin") != 0
        or input_q.get("qmax") != 127
        or not 0 <= zero_point <= 127
    ):
        raise RuntimeError("m0 input quantization is not the required uint8 reduced range")
    provenance = data.get("provenance")
    checkpoint = provenance.get("source_weights_sha256") if isinstance(provenance, dict) else None
    if not isinstance(checkpoint, str) or len(checkpoint) != 64:
        raise RuntimeError("quantization manifest has no checkpoint SHA256")
    scale_bits = struct.unpack("<I", struct.pack("<f", float(scale)))[0]
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "input_scale": float(scale),
        "input_scale_f32_bits": scale_bits,
        "input_zero_point": zero_point,
        "checkpoint_sha256": checkpoint.lower(),
    }


def install(
    card: Path,
    *,
    parameter_package: Path,
    quantization_manifest: Path,
) -> dict[str, Any]:
    card = card.resolve()
    manifest_path = card / "MANIFEST" / "card_manifest.json"
    if not manifest_path.is_file():
        raise RuntimeError("run prepare-card before install")
    package_dst = card / "PARAM" / "coco80_parameters.c8pa"
    parameter_package = _regular(parameter_package, "parameter package")
    current = json.loads(manifest_path.read_text(encoding="utf-8"))
    input_json = current.get("input_index_json")
    if not isinstance(input_json, dict) or not isinstance(input_json.get("path"), str):
        raise RuntimeError("register the final input shard set before installing parameters")
    current = register_inputs(
        card,
        input_manifest=Path(input_json["path"]),
        quantization_manifest=quantization_manifest,
    )
    from .sd_pack import parse_parameter_package

    parsed = parse_parameter_package(parameter_package)
    binding = parsed["sections"]["quantization"]
    with parameter_package.open("rb") as stream:
        stream.seek(int(binding["offset"]))
        first_layer = stream.read(15 * 4)
    if len(first_layer) != 15 * 4:
        raise RuntimeError("SD parameter binding section is truncated")
    words = struct.unpack("<15I", first_layer)
    qparams = _canonical_input_qparams(quantization_manifest)
    if words[6] != qparams["input_scale_f32_bits"] or words[7] != qparams["input_zero_point"]:
        raise RuntimeError("SD parameter m0 input binding differs from the quantization manifest")
    if parsed.get("model_sha256") != qparams["checkpoint_sha256"]:
        raise RuntimeError("SD parameter package is bound to a different checkpoint")
    package = _copy_if_same_or_absent(
        parameter_package, package_dst, "parameter package"
    )
    current.update({
        "parameter_package": package,
        "free_bytes_after_install": shutil.disk_usage(card).free,
        "status": "DATA_READY",
    })
    _write_json(manifest_path, current)
    return current


def register_inputs(
    card: Path,
    *,
    input_manifest: Path,
    quantization_manifest: Path | None = None,
) -> dict[str, Any]:
    """Bind an already-created shard set on the card without a parameter package.

    This supports the intentional two-phase workflow: the immutable 5000-image
    evaluation corpus can be prepared first, while the quantized parameter
    package remains fail-closed until calibration and export have completed.
    """

    from .sd_pack import validate_input_shard_set

    card = card.resolve()
    card_manifest_path = card / "MANIFEST" / "card_manifest.json"
    if not card_manifest_path.is_file():
        raise RuntimeError("run prepare-card before register-inputs")
    input_manifest = _regular(input_manifest, "input shard manifest")
    input_root = input_manifest.parent.resolve()
    expected_root = (card / "INPUT").resolve()
    if input_root != expected_root:
        raise RuntimeError(
            f"input shard set must already be under {expected_root}, got {input_root}"
        )
    verified = validate_input_shard_set(input_manifest)
    data = json.loads(input_manifest.read_text(encoding="utf-8"))
    input_scale = data.get("input_scale")
    input_zero_point = data.get("input_zero_point")
    if (
        isinstance(input_scale, bool)
        or not isinstance(input_scale, (int, float))
        or not math.isfinite(float(input_scale))
        or float(input_scale) <= 0.0
        or isinstance(input_zero_point, bool)
        or not isinstance(input_zero_point, int)
    ):
        raise RuntimeError("input shard manifest has invalid quantization fields")
    quantization_binding = None
    if quantization_manifest is not None:
        quantization_binding = _canonical_input_qparams(quantization_manifest)
        input_scale_bits = struct.unpack("<I", struct.pack("<f", float(input_scale)))[0]
        if (
            input_scale_bits != quantization_binding["input_scale_f32_bits"]
            or input_zero_point != quantization_binding["input_zero_point"]
        ):
            raise RuntimeError("input shard quantization differs from canonical m0 input")
    binary = _regular(input_root / str(data["binary_index"]["path"]), "binary input index")
    shards: list[dict[str, Any]] = []
    for raw in data.get("shards", []):
        if not isinstance(raw, dict) or not isinstance(raw.get("path"), str):
            raise RuntimeError("input shard manifest contains an invalid shard entry")
        path = _regular(input_root / raw["path"], "input shard")
        shards.append({"path": str(path), "bytes": path.stat().st_size, "sha256": sha256_file(path)})
    if len(shards) != int(verified["shard_count"]):
        raise RuntimeError("validated input shard count changed during registration")
    current = json.loads(card_manifest_path.read_text(encoding="utf-8"))
    current.update(
        {
            "input_index": {
                "path": str(binary),
                "bytes": binary.stat().st_size,
                "sha256": sha256_file(binary),
            },
            "input_index_json": {
                "path": str(input_manifest),
                "bytes": input_manifest.stat().st_size,
                "sha256": sha256_file(input_manifest),
            },
            "input_shards": shards,
            "input_validation": verified,
            "free_bytes_after_inputs": shutil.disk_usage(card).free,
            "status": "INPUTS_READY" if quantization_binding is not None else "INPUTS_PROVISIONAL",
        }
    )
    if quantization_binding is None:
        current.pop("quantization_binding", None)
    else:
        current["quantization_binding"] = quantization_binding
    _write_json(card_manifest_path, current)
    return current


def register_conformance(
    card: Path,
    *,
    selection_manifest: Path,
    selection_index: Path,
) -> dict[str, Any]:
    """Install the frozen, input-index-bound 128-image conformance order."""

    from .conformance import parse_conformance_binary

    card = card.resolve()
    card_manifest_path = card / "MANIFEST" / "card_manifest.json"
    if not card_manifest_path.is_file():
        raise RuntimeError("prepare and register inputs before conformance selection")
    current = json.loads(card_manifest_path.read_text(encoding="utf-8"))
    input_binding = current.get("input_index")
    if not isinstance(input_binding, dict) or not isinstance(input_binding.get("path"), str):
        raise RuntimeError("register the final input shard set before conformance selection")
    card_input_index = _regular(Path(input_binding["path"]), "card input index")
    selection_manifest = _regular(selection_manifest, "conformance selection manifest")
    selection_index = _regular(selection_index, "conformance selection index")
    verified = parse_conformance_binary(selection_index, card_input_index)
    manifest_sha = sha256_file(selection_manifest)
    if verified["selection_manifest_sha256"] != manifest_sha:
        raise RuntimeError("conformance index is bound to a different selection manifest")
    installed_manifest = _copy_if_same_or_absent(
        selection_manifest,
        card / "INPUT" / "conformance_selection.json",
        "conformance selection manifest",
    )
    installed_index = _copy_if_same_or_absent(
        selection_index,
        card / "INPUT" / "conformance_index.bin",
        "conformance selection index",
    )
    current["conformance_selection"] = {
        "manifest": installed_manifest,
        "index": installed_index,
        "count": verified["count"],
        "input_index_crc32": verified["input_index_crc32"],
        "selection_manifest_sha256": manifest_sha,
    }
    current["free_bytes_after_conformance"] = shutil.disk_usage(card).free
    _write_json(card_manifest_path, current)
    return current


def verify_card(card: Path) -> dict[str, Any]:
    card = card.resolve()
    manifest_path = card / "MANIFEST" / "card_manifest.json"
    if not manifest_path.is_file():
        raise RuntimeError(f"missing card manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("format") != CARD_FORMAT or manifest.get("version") != CARD_VERSION:
        raise RuntimeError("unsupported SD card manifest")
    checked = 0
    for section in ("artifacts", "parameter_package", "input_index", "input_index_json"):
        entries = manifest.get(section, {})
        if section == "artifacts":
            entries = entries.values()
        else:
            entries = [entries] if entries else []
        for entry in entries:
            path = _regular(Path(entry["path"]), section)
            if path.stat().st_size != int(entry["bytes"]) or sha256_file(path) != entry["sha256"]:
                raise RuntimeError(f"card hash mismatch: {path}")
            checked += 1
    conformance = manifest.get("conformance_selection")
    if conformance is not None:
        if not isinstance(conformance, dict):
            raise RuntimeError("card conformance selection binding is invalid")
        for key in ("manifest", "index"):
            entry = conformance.get(key)
            if not isinstance(entry, dict):
                raise RuntimeError("card conformance selection file binding is invalid")
            path = _regular(Path(entry["path"]), f"conformance {key}")
            if path.stat().st_size != int(entry["bytes"]) or sha256_file(path) != entry["sha256"]:
                raise RuntimeError(f"card conformance hash mismatch: {path}")
            checked += 1
    for entry in manifest.get("input_shards", []):
        path = _regular(Path(entry["path"]), "input shard")
        if path.stat().st_size != int(entry["bytes"]) or sha256_file(path) != entry["sha256"]:
            raise RuntimeError(f"card shard hash mismatch: {path}")
        checked += 1
    return {
        "format": CARD_FORMAT,
        "version": CARD_VERSION,
        "status": "PASS",
        "checked_files": checked,
        "free_bytes": shutil.disk_usage(card).free,
        "card_status": manifest.get("status"),
        "runnable": manifest.get("status") == "DATA_READY",
    }


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prepare = sub.add_parser("prepare-card")
    prepare.add_argument("--card", type=Path, required=True)
    prepare.add_argument("--bit", type=Path, required=True)
    prepare.add_argument("--xsa", type=Path, required=True)
    prepare.add_argument("--source-root", type=Path, required=True)
    install_cmd = sub.add_parser("install")
    install_cmd.add_argument("--card", type=Path, required=True)
    install_cmd.add_argument("--parameter-package", type=Path, required=True)
    install_cmd.add_argument("--quantization-manifest", type=Path, required=True)
    register = sub.add_parser("register-inputs")
    register.add_argument("--card", type=Path, required=True)
    register.add_argument("--input-manifest", type=Path, required=True)
    register.add_argument("--quantization-manifest", type=Path)
    conformance = sub.add_parser("register-conformance")
    conformance.add_argument("--card", type=Path, required=True)
    conformance.add_argument("--selection-manifest", type=Path, required=True)
    conformance.add_argument("--selection-index", type=Path, required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--card", type=Path, required=True)
    args = parser.parse_args(list(argv) if argv is not None else None)
    if args.command == "prepare-card":
        result = prepare_card(args.card, bit=args.bit, xsa=args.xsa, source_root=args.source_root)
    elif args.command == "install":
        result = install(
            args.card,
            parameter_package=args.parameter_package,
            quantization_manifest=args.quantization_manifest,
        )
    elif args.command == "register-inputs":
        result = register_inputs(
            args.card,
            input_manifest=args.input_manifest,
            quantization_manifest=args.quantization_manifest,
        )
    elif args.command == "register-conformance":
        result = register_conformance(
            args.card,
            selection_manifest=args.selection_manifest,
            selection_index=args.selection_index,
        )
    else:
        result = verify_card(args.card)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
