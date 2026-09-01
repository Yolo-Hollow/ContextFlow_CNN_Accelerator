"""Fail-closed host pipeline for r5 COCO80 calibration, evaluation and export."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Sequence

import torch

from .assets import sha256_file, write_json_atomic
from .calibration import DEFAULT_SEED, build_split_manifest
from .conformance import build_conformance_manifest
from .dataset import tensors_from_split_manifest
from .model import load_official_model, verify_upstream
from .parameter_package import generate_package, verify_package
from .quantization import build_quant_plan, calibrate, save_quant_checkpoint
from .sd_pack import pack_parameter_package_from_manifest, parse_parameter_package
from .vitis_headers import generate_vitis_header


FORMAT = "kv260-coco80-r5-pipeline-config"
VERSION = 1
BIT_SHA256 = "1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e"
XSA_SHA256 = "42d761b1cc77f1a7988d40dd71f0a1c7e1987a057bc457c7d5b55613637e3030"


def _resolve(root: Path, value: object, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise RuntimeError(f"configuration field {label} must be a path string")
    path = Path(value)
    return (root / path).resolve() if not path.is_absolute() else path.resolve()


def load_config(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("format") != FORMAT or data.get("version") != VERSION:
        raise RuntimeError("unsupported COCO80 pipeline configuration")
    required = {
        "upstream", "weights", "local_weights", "download_dir", "coco_root",
        "bit", "xsa", "hardware_metadata", "hardware_sha_manifest",
    }
    if set(data.get("paths", {})) != required:
        raise RuntimeError("pipeline paths must contain the exact required key set")
    root = path.resolve().parent
    data["resolved"] = {
        key: _resolve(root, value, f"paths.{key}")
        for key, value in data["paths"].items()
    }
    for key, value in data["resolved"].items():
        if key == "download_dir" or key == "coco_root":
            if not value.is_dir():
                raise RuntimeError(f"missing configured directory {key}: {value}")
        elif not value.is_file() and key != "upstream":
            raise RuntimeError(f"missing configured file {key}: {value}")
    verify_upstream(data["resolved"]["upstream"], data["resolved"]["weights"])
    if sha256_file(data["resolved"]["bit"]) != BIT_SHA256:
        raise RuntimeError("configured BIT is not the signed-off r5 image")
    if sha256_file(data["resolved"]["xsa"]) != XSA_SHA256:
        raise RuntimeError("configured XSA is not the signed-off r5 platform")
    return data


def _run_module(module: str, arguments: list[str]) -> None:
    command = [sys.executable, "-m", module, *arguments]
    print("RUN", subprocess.list2cmdline(command), flush=True)
    subprocess.run(command, check=True)


def _write_stage(run_dir: Path, name: str, artifacts: dict[str, Path]) -> None:
    stage_dir = run_dir / "stages"
    stage_dir.mkdir(parents=True, exist_ok=True)
    marker = stage_dir / f"{name}.json"
    if marker.exists():
        raise RuntimeError(f"stage marker already exists: {marker}")
    payload = {
        "format": "kv260-coco80-pipeline-stage",
        "version": 1,
        "stage": name,
        "artifacts": {
            label: {
                "path": str(path.resolve()),
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
            for label, path in artifacts.items()
        },
    }
    write_json_atomic(marker, payload)


def stage_assets(config: dict[str, Any], run_dir: Path) -> None:
    path = run_dir / "asset_manifest.json"
    paths = config["resolved"]
    _run_module(
        "tools.coco80.make_asset_manifest",
        [
            "--upstream", str(paths["upstream"]), "--weights", str(paths["weights"]),
            "--local-weights", str(paths["local_weights"]),
            "--download-dir", str(paths["download_dir"]), "--coco-root", str(paths["coco_root"]),
            "--bit", str(paths["bit"]), "--xsa", str(paths["xsa"]), "--output", str(path),
            "--hardware-metadata", str(paths["hardware_metadata"]),
            "--hardware-sha-manifest", str(paths["hardware_sha_manifest"]),
            "--source-root", str(Path(__file__).resolve().parents[2]),
        ],
    )
    _write_stage(run_dir, "assets", {"manifest": path})


def stage_split(config: dict[str, Any], run_dir: Path) -> None:
    coco = config["resolved"]["coco_root"]
    output = run_dir / "calibration_split.json"
    build_split_manifest(
        coco / "annotations" / "instances_train2017.json",
        coco / "images" / "train2017",
        output,
        calibration_count=1024,
        holdout_count=512,
        seed=DEFAULT_SEED,
        hash_images=True,
    )
    _write_stage(run_dir, "split", {"manifest": output})


def stage_conformance(config: dict[str, Any], run_dir: Path) -> None:
    coco = config["resolved"]["coco_root"]
    output = run_dir / "conformance_selection.json"
    build_conformance_manifest(
        coco / "annotations" / "instances_val2017.json",
        coco / "images" / "val2017",
        output,
        seed=DEFAULT_SEED,
    )
    _write_stage(run_dir, "conformance", {"manifest": output})


def stage_ptq(config: dict[str, Any], run_dir: Path, device: str, batch_size: int) -> None:
    split = run_dir / "calibration_split.json"
    if not split.is_file():
        raise RuntimeError("PTQ requires the completed calibration split stage")
    output = run_dir / "ptq"
    model = load_official_model(
        config["resolved"]["upstream"], config["resolved"]["weights"], device, fuse=True
    )
    tensors = tensors_from_split_manifest(split, "calibration", batch_size=batch_size)
    outputs, preacts, count = calibrate(model, tensors, device=device, expected_count=1024)
    if count != 1024:
        raise RuntimeError("calibration count gate failed")
    plan, weights, luts = build_quant_plan(model, outputs, preacts)
    save_quant_checkpoint(
        output,
        plan,
        weights,
        luts,
        source_weights=config["resolved"]["weights"],
        calibration_manifest=split,
    )
    _write_stage(run_dir, "ptq", {"manifest": output / "quantization_manifest.json"})


def stage_official640(config: dict[str, Any], run_dir: Path, device: str) -> None:
    output = run_dir / "official640"
    paths = config["resolved"]
    _run_module(
        "tools.coco80.official640",
        [
            "--upstream", str(paths["upstream"]), "--weights", str(paths["weights"]),
            "--data", str(paths["upstream"] / "data" / "coco.yaml"),
            "--coco-root", str(paths["coco_root"]), "--output-dir", str(output),
            "--device", device, "--batch-size", "32",
        ],
    )
    _write_stage(run_dir, "official640", {"summary": output / "summary.json"})


def stage_evaluation(
    config: dict[str, Any],
    run_dir: Path,
    *,
    mode: str,
    device: str,
    batch_size: int,
    quant_dir: Path | None = None,
    name: str | None = None,
) -> None:
    paths = config["resolved"]
    stage_name = name or ("fp32_deploy416" if mode == "fp32" else "int8_pytorch")
    output = run_dir / stage_name
    arguments = [
        "--mode", mode,
        "--annotations", str(paths["coco_root"] / "annotations" / "instances_val2017.json"),
        "--image-root", str(paths["coco_root"] / "images" / "val2017"),
        "--upstream", str(paths["upstream"]), "--weights", str(paths["weights"]),
        "--output-dir", str(output), "--device", device,
        "--batch-size", str(batch_size), "--workers", "2",
    ]
    if quant_dir is not None:
        arguments += ["--quant-dir", str(quant_dir)]
    _run_module("tools.coco80.evaluate", arguments)
    _write_stage(run_dir, stage_name, {
        "summary": output / "summary.json", "predictions": output / "predictions.json"
    })


def stage_precision_gate(run_dir: Path, candidate_name: str) -> dict[str, Any]:
    fp32_path = run_dir / "fp32_deploy416" / "summary.json"
    candidate_path = run_dir / candidate_name / "summary.json"
    fp32 = json.loads(fp32_path.read_text(encoding="utf-8"))
    candidate = json.loads(candidate_path.read_text(encoding="utf-8"))
    fp = fp32["coco"]["metrics"]
    quant = candidate["coco"]["metrics"]
    delta = {
        "AP50_95": float(fp["AP50_95"] - quant["AP50_95"]),
        "AP50": float(fp["AP50"] - quant["AP50"]),
    }
    passed = delta["AP50_95"] <= 0.010 and delta["AP50"] <= 0.020
    comparison = {
        "format": "kv260-coco80-precision-gate",
        "version": 1,
        "status": "PASS" if passed else "QAT_REQUIRED",
        "candidate": candidate_name,
        "delta_absolute": delta,
        "limits_absolute": {"AP50_95": 0.010, "AP50": 0.020},
        "fp32_summary_sha256": sha256_file(fp32_path),
        "candidate_summary_sha256": sha256_file(candidate_path),
    }
    path = run_dir / f"{candidate_name}_precision_gate.json"
    write_json_atomic(path, comparison)
    _write_stage(run_dir, f"{candidate_name}_precision_gate", {"comparison": path})
    return comparison


def stage_qat(config: dict[str, Any], run_dir: Path, device: str) -> None:
    paths = config["resolved"]
    output = run_dir / "qat"
    _run_module(
        "tools.coco80.qat",
        [
            "--upstream", str(paths["upstream"]),
            "--weights", str(paths["weights"]),
            "--quant-manifest", str(run_dir / "ptq" / "quantization_manifest.json"),
            "--fp32-summary", str(run_dir / "fp32_deploy416" / "summary.json"),
            "--ptq-summary", str(run_dir / "int8_pytorch" / "summary.json"),
            "--split-manifest", str(run_dir / "calibration_split.json"),
            "--train-annotations", str(paths["coco_root"] / "annotations" / "instances_train2017.json"),
            "--train-image-root", str(paths["coco_root"] / "images" / "train2017"),
            "--hyp", str(paths["upstream"] / "data" / "hyp.scratch.yaml"),
            "--output-dir", str(output),
            "--device", device,
            "--max-epochs", "20",
        ],
    )
    summary = json.loads((output / "summary.json").read_text(encoding="utf-8"))
    if summary.get("status") != "PASS":
        raise RuntimeError("QAT holdout selection did not pass its precision budget")
    _write_stage(
        run_dir,
        "qat",
        {
            "summary": output / "summary.json",
            "checkpoint": output / "qat_best_conv_state.pt",
            "quant_manifest": output / "quant" / "quantization_manifest.json",
        },
    )


def stage_package(run_dir: Path, quant_dir: Path) -> None:
    output = run_dir / "parameter_package"
    manifest = generate_package(quant_dir, output)
    manifest_path = output / "coco80_parameter_manifest.json"
    verify_package(manifest_path)
    if manifest["files"]["bias"]["file_bytes"] != 64256:
        raise RuntimeError("bias package byte contract changed")
    if manifest["files"]["weight"]["file_bytes"] != 18614016:
        raise RuntimeError("weight package byte contract changed")
    sd_package = output / "coco80_parameters.c8pa"
    pack_parameter_package_from_manifest(
        manifest_path,
        sd_package,
        quantization_root=quant_dir,
    )
    parsed_sd = parse_parameter_package(sd_package)
    if parsed_sd["sections"]["weights"]["bytes"] != 18614016:
        raise RuntimeError("SD weight section byte contract changed")
    if parsed_sd["sections"]["biases"]["bytes"] != 64256:
        raise RuntimeError("SD bias section byte contract changed")
    if sd_package.stat().st_size != 18682508:
        raise RuntimeError("SD parameter package byte contract changed")
    _write_stage(
        run_dir,
        "parameter_package",
        {
            "manifest": manifest_path,
            "bias": output / manifest["files"]["bias"]["path"],
            "weight": output / manifest["files"]["weight"]["path"],
            "sd_package": sd_package,
        },
    )


def stage_header(run_dir: Path, quant_dir: Path) -> None:
    parameter_manifest = run_dir / "parameter_package" / "coco80_parameter_manifest.json"
    quant_manifest = quant_dir / "quantization_manifest.json"
    output = run_dir / "vitis" / "coco80_generated_config.h"
    artifact = generate_vitis_header(
        parameter_manifest,
        quant_manifest,
        output,
        bit_sha256=BIT_SHA256,
        xsa_sha256=XSA_SHA256,
        sd_parameter_package=run_dir / "parameter_package" / "coco80_parameters.c8pa",
    )
    if artifact.bytes <= 0 or sha256_file(output) != artifact.sha256:
        raise RuntimeError("generated Vitis header hash closure failed")
    _write_stage(run_dir, "vitis_header", {"header": output})


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument(
        "stage",
        choices=(
            "assets", "split", "conformance", "official640", "fp32", "ptq", "ptq-eval",
            "gate", "qat", "qat-eval", "package", "header", "host-all",
        ),
    )
    parser.add_argument("--device", default="cuda:0" if torch.cuda.is_available() else "cpu")
    parser.add_argument("--batch-size", type=int, default=4)
    args = parser.parse_args(argv)
    config = load_config(args.config)
    run_dir = args.run_dir.resolve()
    run_dir.mkdir(parents=True, exist_ok=True)

    def execute(stage: str) -> None:
        if stage == "assets":
            stage_assets(config, run_dir)
        elif stage == "split":
            stage_split(config, run_dir)
        elif stage == "conformance":
            stage_conformance(config, run_dir)
        elif stage == "official640":
            stage_official640(config, run_dir, args.device)
        elif stage == "fp32":
            stage_evaluation(config, run_dir, mode="fp32", device=args.device, batch_size=args.batch_size)
        elif stage == "ptq":
            stage_ptq(config, run_dir, args.device, args.batch_size)
        elif stage == "ptq-eval":
            stage_evaluation(
                config, run_dir, mode="ptq", device=args.device, batch_size=args.batch_size,
                quant_dir=run_dir / "ptq", name="int8_pytorch",
            )
        elif stage == "gate":
            gate = stage_precision_gate(run_dir, "int8_pytorch")
            if gate["status"] != "PASS":
                raise SystemExit("PTQ accuracy budget missed; run tools.coco80.qat")
        elif stage == "qat":
            stage_qat(config, run_dir, args.device)
        elif stage == "qat-eval":
            stage_evaluation(
                config, run_dir, mode="ptq", device=args.device, batch_size=args.batch_size,
                quant_dir=run_dir / "qat" / "quant", name="int8_qat",
            )
        elif stage == "package":
            selected = run_dir / "qat" / "quant" if (run_dir / "qat" / "quant").is_dir() else run_dir / "ptq"
            stage_package(run_dir, selected)
        elif stage == "header":
            selected = run_dir / "qat" / "quant" if (run_dir / "qat" / "quant").is_dir() else run_dir / "ptq"
            stage_header(run_dir, selected)
        else:
            raise AssertionError(stage)

    if args.stage == "host-all":
        for stage in ("assets", "split", "conformance", "official640", "fp32", "ptq", "ptq-eval"):
            execute(stage)
        gate = stage_precision_gate(run_dir, "int8_pytorch")
        selected = run_dir / "ptq"
        if gate["status"] != "PASS":
            stage_qat(config, run_dir, args.device)
            stage_evaluation(
                config, run_dir, mode="ptq", device=args.device,
                batch_size=args.batch_size, quant_dir=run_dir / "qat" / "quant",
                name="int8_qat",
            )
            qat_gate = stage_precision_gate(run_dir, "int8_qat")
            if qat_gate["status"] != "PASS":
                raise SystemExit("QAT full-val precision budget failed; release is blocked")
            selected = run_dir / "qat" / "quant"
        stage_package(run_dir, selected)
        stage_header(run_dir, selected)
    else:
        execute(args.stage)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
