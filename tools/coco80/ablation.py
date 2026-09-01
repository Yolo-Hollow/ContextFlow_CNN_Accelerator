"""Fail-closed LASA ablation manifests, samples, statistics, and paper tables."""

from __future__ import annotations

import argparse
import csv
from dataclasses import asdict, replace
import hashlib
import json
import math
from pathlib import Path
import random
import re
import statistics
from typing import Any, Iterable, Sequence

from .assets import sha256_file, write_json_atomic
from .hardware_plan import get_schedule, schedule_layer
from .net_protocol import EXTENDED_TIMING_BYTES, ExtendedTiming


FORMAT_MANIFEST = "kv260-lasa-ablation-manifest"
FORMAT_SUMMARY = "kv260-lasa-ablation-summary"
VERSION = 1
SEED = 20260814
LAYER_NAMES = (
    "m0", "m2", "m4", "m6", "m8", "m10", "m13", "m14", "m15",
    "m16", "m19", "p4_detect", "p5_detect",
)
REPRESENTATIVE_LAYERS = ("m0", "m13", "m19", "p4_detect")
STREAM_CONFIGS = (0x29, 0x2B, 0x3B, 0x3F, 0xBF)
VARIANTS = {
    "a0": ("abi_v2_ablation_200_a0", 0, 1, 0, 0),
    "a1": ("abi_v2_ablation_200_a1", 1, 1, 0, 0),
    "a2": ("abi_v2_ablation_200_a2", 1, 1, 1, 0),
    "a3": ("abi_v2_release_200", 1, 1, 1, 1),
}
SAMPLE_FIELDS = (
    "version", "variant", "experiment", "case_label", "session", "sample_index",
    "image_id", "warmup", "stream_config", "layer", "resident_ticks",
    "pl_ticks", "layer_ticks", "tick_hz", "output_crc32",
    "ifm_dma_bytes", "bias_dma_bytes", "weight_dma_bytes", "ofm_dma_bytes",
    "expected_contexts", "context_alloc", "context_input_issued",
    "context_array_retired", "context_collector_done", "context_gap_cycles",
    "ifm_owner_stall_cycles", "weight_owner_stall_cycles",
    "psum_credit_stall_cycles", "stage_weight_cycles",
    "stage_feeder_cycles", "stage_compute_cycles", "stage_drain_cycles",
    "compute_fire", "compute_idle_cycles", "raw_load_active_cycles",
    "raw_replay_active_cycles", "raw_replay_wait_cycles", "prefetch_hit",
    "prefetch_miss", "prefetch_stall_cycles", "psum_overlap_hit",
    "psum_overlap_wait_cycles", "psum_overlap_underflow",
    "drain_ready_stall_cycles", "drain_internal_full_cycles",
    "collector_full_stall_cycles", "collector_empty_wait_cycles",
)


class AblationError(RuntimeError):
    pass


def _json(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise AblationError(f"{label} is not a regular file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise AblationError(f"cannot parse {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise AblationError(f"{label} must contain one JSON object")
    return value


def _metadata(path: Path) -> dict[str, str]:
    if path.is_symlink() or not path.is_file():
        raise AblationError(f"hardware metadata is missing: {path}")
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if "=" not in line:
            raise AblationError("hardware metadata contains a malformed line")
        key, value = line.split("=", 1)
        if not key or key in result:
            raise AblationError("hardware metadata has a duplicate/empty key")
        result[key] = value
    return result


def _sha_manifest(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2 or len(parts[0]) != 64:
            raise AblationError("hardware SHA manifest is malformed")
        result[Path(parts[1].strip()).name] = parts[0].lower()
    if len(result) != 2:
        raise AblationError("hardware SHA manifest must bind exactly BIT and XSA")
    return result


def _asset(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise AblationError(f"asset is missing or symbolic: {path}")
    return {"path": str(path.resolve()), "bytes": path.stat().st_size,
            "sha256": sha256_file(path)}


def _verify_bound_asset(raw: object, label: str) -> Path:
    if not isinstance(raw, dict) or set(raw) != {"path", "bytes", "sha256"}:
        raise AblationError(f"{label} binding is malformed")
    path = Path(str(raw["path"])).resolve()
    if path.is_symlink() or not path.is_file():
        raise AblationError(f"{label} bound file is missing")
    if path.stat().st_size != int(raw["bytes"]) or sha256_file(path) != raw["sha256"]:
        raise AblationError(f"{label} bound file size/hash mismatch")
    return path


def _hardware_failure(path: Path) -> dict[str, Any]:
    value = _json(path, "ablation hardware failure")
    if (
        value.get("format") != "kv260-lasa-ablation-hardware"
        or value.get("version") != 1 or value.get("status") != "FAIL"
        or value.get("variant") not in {"a0", "a1", "a2"}
        or value.get("profile") != f"abi_v2_ablation_200_{value.get('variant')}"
        or value.get("release_eligible") is not False
        or value.get("bit_xsa_published") is not False
    ):
        raise AblationError("ablation hardware failure identity is invalid")
    gate_path = _verify_bound_asset(value.get("gate"), "failure gate")
    profile_path = _verify_bound_asset(
        value.get("build_profile"), "failure build profile")
    _verify_bound_asset(value.get("log"), "failure log")
    _verify_bound_asset(value.get("journal"), "failure journal")
    gate: dict[str, Any] = {}
    violations: list[str] = []
    for line in gate_path.read_text(encoding="utf-8-sig").splitlines():
        if "=" not in line:
            raise AblationError("failure gate contains a malformed line")
        key, text = line.split("=", 1)
        if key == "violation":
            violations.append(text)
        elif not key or key in gate:
            raise AblationError("failure gate contains a duplicate/empty key")
        else:
            gate[key] = text
    gate["violations"] = violations
    profile = _metadata(profile_path)
    if gate.get("status") != "FAIL" or gate.get("gate") not in {
        "SYSTEM_SYNTH", "SYSTEM_PLACE", "SYSTEM_IMPL"
    }:
        raise AblationError("bound hardware failure gate is not a formal FAIL")
    if (
        profile.get("profile") != value["profile"]
        or profile.get("clock_hz") != "200000000"
        or profile.get("git_sha") != value.get("git_sha")
        or profile.get("git_dirty") != "0"
    ):
        raise AblationError("hardware failure provenance/profile mismatch")
    return {
        "variant": value["variant"], "hardware_profile": value["profile"],
        "status": "FAIL", "failed_gate": gate["gate"],
        "gate_metrics": gate, "failure_artifact": _asset(path),
    }


def _post_route_power(report_path: Path, assumptions_path: Path) -> dict[str, Any]:
    """Load one comparable, vectorless post-route Vivado power estimate."""
    assumptions = _metadata(assumptions_path)
    expected = {
        "format": "lasa-post-route-power-assumptions",
        "version": "1",
        "vivado_version": "2022.2",
        "operating_process": "typical",
        "ambient_temp_c": "25",
        "default_toggle_rate_percent": "12.5",
        "default_static_probability": "0.5",
        "resets": "deasserted",
        "activity_source": "vectorless",
        "saif": "none",
        "measurement": "post_route_estimated",
    }
    mismatch = {
        key: (assumptions.get(key), value)
        for key, value in expected.items() if assumptions.get(key) != value
    }
    if mismatch:
        raise AblationError(f"post-route power assumptions mismatch: {mismatch}")
    if report_path.is_symlink() or not report_path.is_file():
        raise AblationError(f"post-route power report is missing: {report_path}")
    text = report_path.read_text(encoding="utf-8-sig", errors="strict")
    numeric_patterns = {
        "total_on_chip_w": r"\|\s*Total On-Chip Power \(W\)\s*\|\s*([0-9.]+)\s*\|",
        "dynamic_w": r"\|\s*Dynamic \(W\)\s*\|\s*([0-9.]+)\s*\|",
        "device_static_w": r"\|\s*Device Static \(W\)\s*\|\s*([0-9.]+)\s*\|",
        "junction_temperature_c": r"\|\s*Junction Temperature \(C\)\s*\|\s*([0-9.]+)\s*\|",
    }
    metrics: dict[str, Any] = {}
    for key, pattern in numeric_patterns.items():
        match = re.search(pattern, text)
        if not match:
            raise AblationError(f"post-route power report is missing {key}")
        metrics[key] = float(match.group(1))
    confidence = re.search(
        r"\|\s*Confidence Level\s*\|\s*([A-Za-z]+)\s*\|", text)
    if not confidence:
        raise AblationError("post-route power report is missing its confidence level")
    metrics["confidence_level"] = confidence.group(1)
    if not math.isclose(
            metrics["total_on_chip_w"],
            metrics["dynamic_w"] + metrics["device_static_w"],
            abs_tol=0.002):
        raise AblationError("post-route power components do not sum to total power")
    return {
        "measurement": "post_route_estimated",
        "metrics": metrics,
        "report": _asset(report_path),
        "assumptions": _asset(assumptions_path),
        "assumption_values": assumptions,
    }


def _model_traffic(model_spec: Path) -> dict[str, dict[str, int]]:
    spec = _json(model_spec, "model spec")
    if spec.get("format") != "kv260-coco80-yolov3-tiny-dag":
        raise AblationError("unexpected model spec identity")
    result: dict[str, dict[str, int]] = {}
    for layer in spec.get("conv_layers", []):
        name = layer["name"]
        h, w, cin = (int(value) for value in layer["ifm_hwc"])
        _, _, cout = (int(value) for value in layer["ofm_hwc"])
        kernel = int(layer["kernel"])
        tile_h = int(layer["tile_h"])
        p = math.ceil(cin * kernel * kernel / 18)
        q = math.ceil(cout / 32)
        tile_count = math.ceil(h / tile_h)
        tile_pixels = min(tile_h, h) * w
        raw_tile = min(tile_h, h) * w * cin
        materialized = tile_pixels * p * 18
        raw_tensor = h * w * cin
        # The theoretical im2col baseline reads Q copies of the materialized
        # vectors.  The implemented A0 baseline is slightly different: its
        # legacy 3x3 feeder reads two useful channel bytes in each 64-bit line
        # word (including tile halo rows), while native 1x1 reads three 64-bit
        # beats per 18-lane pixel vector.  Record both instead of conflating
        # conceptual window traffic with the actual DMA contract.
        im2col = sum(
            min(tile_h, h - tile * tile_h) * w * p * 18 * q
            for tile in range(tile_count)
        )
        if kernel == 1:
            legacy_prepacked = sum(
                min(tile_h, h - tile * tile_h) * w * p * q * 24
                for tile in range(tile_count)
            )
        else:
            legacy_prepacked = 0
            for tile in range(tile_count):
                base = tile * tile_h
                active_h = min(tile_h, h - base)
                first_row = max(0, base - int(layer["pad"]))
                last_row = min(h - 1, base + active_h - 1 + int(layer["pad"]))
                legacy_prepacked += (last_row - first_row + 1) * w * p * q * 8
        result[name] = {
            "height": h, "width": w, "cin": cin, "cout": cout,
            "kernel": kernel, "tile_h": tile_h,
            "p": p, "q": q, "tile_count": tile_count,
            "raw_tile_bytes": raw_tile,
            "materialized_tile_bytes": materialized,
            "serial_raw_upper_bound_bytes": p * q * raw_tensor,
            "serial_prepacked_ifm_bytes": legacy_prepacked,
            "im2col_external_ifm_bytes": im2col,
            "lasa_external_ifm_bytes": raw_tensor,
            "onchip_materialize_write_bytes": sum(
                min(tile_h, h - tile * tile_h) * w * p * 18
                for tile in range(tile_count)
            ),
            "onchip_replay_read_bytes": im2col,
        }
    if tuple(result) != LAYER_NAMES:
        raise AblationError("model spec does not contain the canonical 13 layers")
    return result


def _dma_contract(
    parameter_manifest: Path, traffic: dict[str, dict[str, int]],
    experiment: str, case_label: str,
) -> dict[str, dict[str, int]]:
    package = _json(parameter_manifest, "parameter manifest")
    entries = package.get("layers", [])
    by_name = {entry.get("layer_id"): entry for entry in entries if isinstance(entry, dict)}
    if tuple(name for name in LAYER_NAMES if name in by_name) != LAYER_NAMES:
        raise AblationError("parameter manifest does not contain the canonical 13 layers")
    result: dict[str, dict[str, int]] = {}
    for name in LAYER_NAMES:
        base = traffic[name]
        entry = by_name[name]
        release = get_schedule(name)
        layer = release.layer
        if experiment == "native1x1" and case_label == "sparse3x3" and name in {
            "m14", "m16", "p4_detect", "p5_detect"
        }:
            layer = replace(
                layer, kernel=3, pad=1,
                tile_h={"m14": 4, "m16": 13,
                        "p4_detect": 8, "p5_detect": 8}[name])
        elif experiment == "tile" and case_label in {"tile_h4", "tile_h3"}:
            if name == "m13" and case_label == "tile_h4":
                layer = replace(layer, tile_h=4)
            elif name == "m19" and case_label == "tile_h3":
                layer = replace(layer, tile_h=3)
        schedule = schedule_layer(layer)
        custom = schedule != release
        if not custom:
            packaged_bias = int(entry.get("bias", {}).get("bytes", -1))
            packaged_weight = int(entry.get("weight", {}).get("bytes", -1))
            if packaged_bias != schedule.bias_bytes or packaged_weight != schedule.weight_bytes:
                raise AblationError(f"parameter package DMA contract drift for {name}")
        result[name] = {
            "kernel": layer.kernel, "tile_h": layer.tile_h,
            "k_passes": schedule.k_passes,
            "cout_blocks": schedule.cout_blocks,
            "tile_count": schedule.tile_count,
            "ifm_dma_bytes": base["lasa_external_ifm_bytes"],
            "bias_dma_bytes": schedule.bias_bytes,
            "weight_dma_bytes": schedule.weight_bytes,
            "ofm_dma_bytes": schedule.ofm_bytes,
            "nonzero_mac": base["height"] * base["width"] * base["cin"] *
                base["cout"] * base["kernel"] * base["kernel"],
            "scheduled_lane_mac": base["height"] * base["width"] *
                schedule.k_passes * 18 * schedule.cout_blocks * 32,
        }
        if min(result[name].values()) < 0 or result[name]["ofm_dma_bytes"] <= 0:
            raise AblationError(f"invalid DMA/schedule contract for {name}")
    return result


def build_manifest(args: argparse.Namespace) -> dict[str, Any]:
    if args.variant not in VARIANTS or args.stream_config not in STREAM_CONFIGS:
        raise AblationError("unknown variant or unsafe STREAM_CFG")
    profile, long_ifm, tagged, preload, handoff = VARIANTS[args.variant]
    if args.variant == "a0" and args.experiment != "representative":
        raise AblationError("A0 is valid only for the prepacked representative-layer experiment")
    if args.variant == "a0" and args.stream_config != 0x29:
        raise AblationError("A0 representative layers require the legacy prepacked STREAM_CFG=0x29")
    if args.variant != "a0" and args.stream_config == 0x29:
        raise AblationError("STREAM_CFG=0x29 is exclusive to the A0 prepacked baseline")
    if args.experiment in {"native1x1", "tile"} and args.variant != "a3":
        raise AblationError("secondary ablations must reuse the A3 bitstream")
    if not re.fullmatch(r"[a-z0-9_]+", args.case_label):
        raise AblationError("ablation case label is invalid")
    if args.experiment == "full" and args.variant in {"a1", "a2"} and args.stream_config != 0x2B:
        raise AblationError("A1/A2 full-network experiments are fixed to STREAM_CFG=0x2B")
    metadata = _metadata(args.hardware_metadata)
    expected = {
        "profile": profile, "clock_hz": "200000000", "rows": "18",
        "cols": "16", "cout_tile": "32", "enable_layer_long_hwc_ifm": str(long_ifm),
        "enable_tagged_context": str(tagged), "enable_weight_preload": str(preload),
        "enable_fast_context_handoff": str(handoff), "enforce_gates": "1",
        "git_dirty": "0", "git_dirty_end": "0", "provenance_stable": "1",
    }
    mismatch = {key: (metadata.get(key), value) for key, value in expected.items()
                if metadata.get(key) != value}
    if mismatch:
        raise AblationError(f"hardware metadata/profile mismatch: {mismatch}")
    if args.variant != "a3" and (
        metadata.get("release_eligible") != "0" or metadata.get("ablation_profile") != "1"
    ):
        raise AblationError("dedicated ablation hardware is not marked non-release")
    gate = args.hardware_metadata.parent / "system_impl_gate.txt"
    if not gate.is_file() or "status=PASS" not in gate.read_text(encoding="utf-8-sig"):
        raise AblationError("SYSTEM_IMPL PASS evidence is missing")
    gate_metrics = _metadata(gate)
    power = _post_route_power(args.power_report, args.power_assumptions)
    sha_entries = _sha_manifest(args.hardware_sha_manifest)
    bit = _asset(args.bit)
    xsa = _asset(args.xsa)
    if sha_entries.get(args.bit.name) != bit["sha256"] or sha_entries.get(args.xsa.name) != xsa["sha256"]:
        raise AblationError("hardware manifest does not bind selected BIT/XSA")
    layers = tuple(args.layers or (LAYER_NAMES if args.experiment == "full" else REPRESENTATIVE_LAYERS))
    if not layers or any(name not in LAYER_NAMES for name in layers):
        raise AblationError("experiment layer selection is invalid")
    traffic = _model_traffic(args.model_spec)
    dma_contract = _dma_contract(
        args.parameter_manifest, traffic, args.experiment, args.case_label)
    result: dict[str, Any] = {
        "format": FORMAT_MANIFEST, "version": VERSION, "status": "READY",
        "variant": args.variant, "hardware_profile": profile,
        "publication_eligible": False, "stream_config": f"0x{args.stream_config:02X}",
        "experiment": args.experiment, "layers": list(layers),
        "case_label": args.case_label,
        "features": {"materialize": bool(long_ifm), "tagged_context": bool(tagged),
                     "weight_preload": bool(preload), "fast_handoff": bool(handoff)},
        "clock_hz": 200_000_000, "array": {"rows": 18, "cols": 16, "cout_tile": 32},
        "run_protocol": {"sessions": args.sessions, "warmup_per_session": args.warmup,
                         "timed_per_session": args.timed, "input_order_sha256": sha256_file(args.input_index)},
        "hardware": {"metadata": _asset(args.hardware_metadata),
                     "sha_manifest": _asset(args.hardware_sha_manifest),
                     "system_impl_gate": _asset(gate),
                     "implementation_gate_metrics": gate_metrics,
                     "post_route_power": power,
                     "bit": bit, "xsa": xsa},
        "workload": {"model_spec": _asset(args.model_spec),
                     "parameter_manifest": _asset(args.parameter_manifest),
                     "input_index": _asset(args.input_index), "traffic_model": traffic,
                     "dma_contract": dma_contract},
    }
    write_json_atomic(args.output, result)
    return result


def timing_to_samples(args: argparse.Namespace) -> int:
    manifest = _json(args.manifest, "ablation manifest")
    if manifest.get("format") != FORMAT_MANIFEST or manifest.get("status") != "READY":
        raise AblationError("ablation manifest is not READY")
    if len(args.timing) != len(args.session):
        raise AblationError("--timing and --session must be supplied in pairs")
    if len(args.timing) != int(manifest["run_protocol"]["sessions"]):
        raise AblationError("timing file count differs from the manifest session count")
    if len(set(args.session)) != len(args.session):
        raise AblationError("session identifiers must be unique")
    expected = int(manifest["run_protocol"]["warmup_per_session"]) + int(
        manifest["run_protocol"]["timed_per_session"])
    record_sets: list[tuple[int, list[ExtendedTiming]]] = []
    for session, timing_path in zip(args.session, args.timing):
        raw = timing_path.read_bytes()
        if not raw or len(raw) % EXTENDED_TIMING_BYTES:
            raise AblationError("extended timing file length is invalid")
        records = [ExtendedTiming.unpack(raw[offset:offset + EXTENDED_TIMING_BYTES])
                   for offset in range(0, len(raw), EXTENDED_TIMING_BYTES)]
        if len(records) != expected:
            raise AblationError(
                f"session {session} timing count={len(records)}, expected={expected}")
        record_sets.append((session, records))
    expected_stream = int(str(manifest["stream_config"]), 16)
    layers = set(manifest["layers"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=SAMPLE_FIELDS)
        writer.writeheader()
        for session, records in record_sets:
            for sample_index, timing in enumerate(records):
                if timing.stream_config != expected_stream:
                    raise AblationError("timing STREAM_CFG differs from manifest")
                for layer_index, layer_name in enumerate(LAYER_NAMES):
                    if layer_name not in layers:
                        continue
                    row = {
                        "version": VERSION, "variant": manifest["variant"],
                        "experiment": manifest["experiment"], "session": session,
                        "case_label": manifest["case_label"],
                        "sample_index": sample_index, "image_id": timing.image_id,
                        "warmup": int(sample_index < manifest["run_protocol"]["warmup_per_session"]),
                        "stream_config": manifest["stream_config"], "layer": layer_name,
                        "resident_ticks": timing.total_ticks, "pl_ticks": timing.pl_ticks,
                        "layer_ticks": timing.pl_layer_ticks[layer_index], "tick_hz": timing.tick_hz,
                        "output_crc32": timing.output_crc32,
                        **asdict(timing.layer_telemetry[layer_index]),
                    }
                    writer.writerow(row)
    return sum(len(records) for _, records in record_sets)


def _percentile(values: Sequence[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower, upper = math.floor(position), math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def _bootstrap_mean_ci(values: Sequence[float], seed: int) -> tuple[float, float]:
    rng = random.Random(seed)
    count = len(values)
    samples = [statistics.fmean(values[rng.randrange(count)] for _ in range(count))
               for _ in range(2_000)]
    return _percentile(samples, 0.025), _percentile(samples, 0.975)


def _stats(values: Sequence[float], seed: int, bootstrap: bool = True) -> dict[str, float]:
    if not values:
        raise AblationError("cannot summarize an empty sample series")
    mean = statistics.fmean(values)
    low, high = _bootstrap_mean_ci(values, seed) if bootstrap else (mean, mean)
    return {"min": min(values), "mean": statistics.fmean(values),
            "p50": _percentile(values, 0.50), "p95": _percentile(values, 0.95),
            "max": max(values), "mean_ci95_low": low, "mean_ci95_high": high}


def _read_samples(path: Path, manifest: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if tuple(reader.fieldnames or ()) != SAMPLE_FIELDS:
            raise AblationError(f"sample CSV schema mismatch: {path}")
        for raw in reader:
            if raw["variant"] != manifest["variant"] or raw["experiment"] != manifest["experiment"]:
                raise AblationError("sample identity differs from manifest")
            row: dict[str, Any] = {key: raw[key] for key in SAMPLE_FIELDS}
            for key in SAMPLE_FIELDS:
                if key not in {"variant", "experiment", "case_label", "stream_config", "layer"}:
                    row[key] = int(raw[key])
            if row["warmup"] == 0:
                expected = row["expected_contexts"]
                if (row["context_alloc"], row["context_input_issued"],
                    row["context_array_retired"], row["context_collector_done"]) != (expected,) * 4:
                    raise AblationError("sample lifecycle counters mismatch")
                if row["psum_overlap_underflow"] != 0:
                    raise AblationError("sample reports PSUM underflow")
                traffic = manifest["workload"]["traffic_model"][row["layer"]]
                expected_ifm = (
                    traffic["serial_prepacked_ifm_bytes"]
                    if manifest["variant"] == "a0"
                    else traffic["lasa_external_ifm_bytes"]
                )
                if row["ifm_dma_bytes"] != expected_ifm:
                    raise AblationError(
                        f"{row['layer']} actual IFM DMA bytes={row['ifm_dma_bytes']}, "
                        f"expected={expected_ifm}")
                contract = manifest["workload"]["dma_contract"][row["layer"]]
                for field in ("bias_dma_bytes", "weight_dma_bytes", "ofm_dma_bytes"):
                    if row[field] != contract[field]:
                        raise AblationError(
                            f"{row['layer']} actual {field}={row[field]}, "
                            f"expected={contract[field]}")
                rows.append(row)
    return rows


def summarize(args: argparse.Namespace) -> dict[str, Any]:
    if len(args.manifest) != len(args.samples) or not args.manifest:
        raise AblationError("manifest/sample arguments must be nonempty pairs")
    cases: list[dict[str, Any]] = []
    raw_cases: list[list[dict[str, Any]]] = []
    for case_index, (manifest_path, sample_path) in enumerate(zip(args.manifest, args.samples)):
        manifest = _json(manifest_path, "ablation manifest")
        rows = _read_samples(sample_path, manifest)
        protocol = manifest["run_protocol"]
        expected = int(protocol["sessions"]) * int(protocol["timed_per_session"]) * len(manifest["layers"])
        if len(rows) != expected:
            raise AblationError(f"{manifest['variant']} has {len(rows)} timed layer rows, expected {expected}")
        tick_hz_values = {row["tick_hz"] for row in rows}
        if len(tick_hz_values) != 1:
            raise AblationError("sample CSV contains multiple timer frequencies")
        tick_hz = next(iter(tick_hz_values))
        layer_summary: dict[str, Any] = {}
        for layer_index, name in enumerate(manifest["layers"]):
            selected = [row for row in rows if row["layer"] == name]
            metrics = {}
            for field in SAMPLE_FIELDS[SAMPLE_FIELDS.index("pl_ticks"):]:
                if field in {"tick_hz", "output_crc32"}:
                    continue
                metrics[field] = _stats(
                    [float(row[field]) for row in selected],
                    SEED + case_index + layer_index,
                    bootstrap=field == "layer_ticks",
                )
            metrics["compute_fire_per_stage_cycle"] = _stats([
                row["compute_fire"] / row["stage_compute_cycles"]
                if row["stage_compute_cycles"] else 0.0 for row in selected
            ], SEED + 100 + layer_index, bootstrap=False)
            metrics["latency_us"] = _stats([
                row["layer_ticks"] * 1_000_000.0 / tick_hz for row in selected
            ], SEED + 200 + layer_index)
            layer_summary[name] = metrics
        image_rows = [row for row in rows if row["layer"] == manifest["layers"][0]]
        resident_us = [row["resident_ticks"] * 1_000_000.0 / tick_hz for row in image_rows]
        pl_us = [row["pl_ticks"] * 1_000_000.0 / tick_hz for row in image_rows]
        cases.append({
            "variant": manifest["variant"], "hardware_profile": manifest["hardware_profile"],
            "stream_config": manifest["stream_config"], "experiment": manifest["experiment"],
            "case_label": manifest["case_label"],
            "layers_selected": manifest["layers"], "tick_hz": tick_hz,
            "timed_images": len(image_rows), "samples_sha256": sha256_file(sample_path),
            "resident_ticks": _stats([float(row["resident_ticks"]) for row in image_rows], SEED + case_index),
            "pl_ticks": _stats([float(row["pl_ticks"]) for row in image_rows], SEED + 10 + case_index),
            "resident_us": _stats(resident_us, SEED + 20 + case_index),
            "pl_us": _stats(pl_us, SEED + 30 + case_index),
            "resident_fps_from_mean": 1_000_000.0 / statistics.fmean(resident_us),
            "hardware_metrics": manifest["hardware"]["implementation_gate_metrics"],
            "post_route_power": manifest["hardware"]["post_route_power"],
            "dma_contract": {
                name: manifest["workload"]["dma_contract"][name]
                for name in manifest["layers"]
            },
            "layers": layer_summary,
        })
        raw_cases.append(rows)
    comparisons = []
    for index in range(1, len(cases)):
        before, after = raw_cases[index - 1], raw_cases[index]
        if (cases[index - 1]["experiment"] != cases[index]["experiment"] or
                cases[index - 1]["layers_selected"] != cases[index]["layers_selected"]):
            continue
        key = lambda row: (row["session"], row["sample_index"], row["image_id"], row["layer"])
        left, right = {key(row): row for row in before}, {key(row): row for row in after}
        if left.keys() != right.keys():
            raise AblationError("adjacent cases do not contain paired samples")
        for item in left:
            if left[item]["output_crc32"] != right[item]["output_crc32"]:
                raise AblationError("adjacent variants produced different output CRCs")
        ratios = [left[item]["layer_ticks"] / right[item]["layer_ticks"]
                  for item in sorted(left) if right[item]["layer_ticks"] > 0]
        first_layer = cases[index]["layers_selected"][0]
        image_keys = sorted(item for item in left if item[3] == first_layer)
        resident_ratios = [
            left[item]["resident_ticks"] / right[item]["resident_ticks"]
            for item in image_keys if right[item]["resident_ticks"] > 0
        ]
        comparisons.append({
            "from": cases[index - 1]["variant"], "to": cases[index]["variant"],
            "from_case_label": cases[index - 1]["case_label"],
            "to_case_label": cases[index]["case_label"],
            "from_stream_config": cases[index - 1]["stream_config"],
            "to_stream_config": cases[index]["stream_config"],
            "experiment": cases[index]["experiment"],
            "paired_rows": len(ratios), "layer_speedup": _stats(ratios, SEED + 1000 + index),
            "paired_images": len(resident_ratios),
            "resident_speedup": _stats(resident_ratios, SEED + 2000 + index),
        })
    failed_hardware = [
        _hardware_failure(path)
        for path in (getattr(args, "hardware_failure", None) or [])
    ]
    failed_variants = [item["variant"] for item in failed_hardware]
    if len(failed_variants) != len(set(failed_variants)):
        raise AblationError("duplicate hardware failure variant")
    result = {"format": FORMAT_SUMMARY, "version": VERSION, "status": "PASS",
              "cases": cases, "failed_hardware": failed_hardware,
              "paired_comparisons": comparisons}
    write_json_atomic(args.output, result)
    return result


def write_paper_tables(args: argparse.Namespace) -> None:
    summary = _json(args.summary, "ablation summary")
    if summary.get("format") != FORMAT_SUMMARY or summary.get("status") != "PASS":
        raise AblationError("summary is not publication-ready")
    payload = {"format": "kv260-lasa-paper-ablation-tables", "version": 1,
               "source_summary_sha256": sha256_file(args.summary),
               "cases": summary["cases"],
               "failed_hardware": summary.get("failed_hardware", []),
               "paired_comparisons": summary["paired_comparisons"]}
    write_json_atomic(args.output_json, payload)
    lines = ["% Generated from ablation_summary.json; do not edit."]
    implementations: list[dict[str, Any]] = []
    seen_profiles: set[str] = set()
    for case in summary["cases"]:
        if case["hardware_profile"] not in seen_profiles:
            implementations.append(case)
            seen_profiles.add(case["hardware_profile"])
    if implementations or summary.get("failed_hardware"):
        lines.extend([
            "\\begin{table*}[t]", "\\centering", "\\small",
            "\\caption{消融硬件版本的实现代价。功耗为相同活动率假设下的 post-route 估算值。}",
            "\\label{tab:lasa-ablation-implementation}",
            "\\begin{tabular}{lrrrrrrrr}",
            "版本 & LUT & FF & CLB/\\% & BRAM & URAM & DSP & WNS/ns & 功耗/W \\\\",
            "\\hline",
        ])
        for case in implementations:
            metrics = case["hardware_metrics"]
            power = case["post_route_power"]["metrics"]
            lines.append(
                f"{case['variant'].upper()} & {metrics['metric.lut']} & "
                f"{metrics.get('metric.ff', '--')} & {float(metrics['metric.clb_percent']):.2f} & "
                f"{metrics['metric.bram']} & {metrics['metric.uram']} & {metrics['metric.dsp']} & "
                f"{float(metrics['metric.wns']):.3f} & {power['total_on_chip_w']:.3f} \\\\")
        for failure in summary.get("failed_hardware", []):
            metrics = failure["gate_metrics"]
            lines.append(
                f"{failure['variant'].upper()} & {metrics.get('metric.lut', '--')} & "
                f"{metrics.get('metric.ff', '--')} & "
                f"{float(metrics['metric.clb_percent']):.2f} & "
                f"{metrics.get('metric.bram', '--')} & {metrics.get('metric.uram', '--')} & "
                f"{metrics.get('metric.dsp', '--')} & "
                f"{float(metrics['metric.wns']):.3f} & -- \\\\")
        lines.extend(["\\end{tabular}", "\\end{table*}", ""])
    representative = [
        case for case in summary["cases"]
        if case["experiment"] == "representative"
    ]
    if representative:
        lines.extend([
            "\\begin{table*}[t]", "\\centering", "\\small",
            "\\caption{代表层架构消融。输入字节均为实际 DMA 计数。}",
            "\\label{tab:lasa-ablation-representative}",
            "\\begin{tabular}{llrrrr}",
            "配置 & 层 & 平均时延/$\\mu$s & IFM字节 & 计算有效比 & 上下文空泡 \\\\",
            "\\hline",
        ])
        for case in representative:
            label = f"{case['variant'].upper()} / {case['case_label']}"
            for layer_name in case["layers_selected"]:
                layer = case["layers"][layer_name]
                lines.append(
                    f"{label} & {layer_name} & {layer['latency_us']['mean']:.3f} & "
                    f"{layer['ifm_dma_bytes']['mean']:.0f} & "
                    f"{layer['compute_fire_per_stage_cycle']['mean']:.4f} & "
                    f"{layer['context_gap_cycles']['mean']:.1f} \\\\")
        lines.extend(["\\end{tabular}", "\\end{table*}", ""])
    full = [case for case in summary["cases"] if case["experiment"] == "full"]
    if full:
        lines.extend([
            "\\begin{table*}[t]", "\\centering", "\\small",
            "\\caption{完整网络上下文调度与运行时流水消融。}",
            "\\label{tab:lasa-ablation-full}",
            "\\begin{tabular}{lrrrr}",
            "配置 & 时延/ms & FPS & PL/ms & P95/ms \\\\", "\\hline",
        ])
        for case in full:
            label = f"{case['variant'].upper()} / {case['case_label']}"
            lines.append(
                f"{label} & {case['resident_us']['mean'] / 1000.0:.3f} & "
                f"{case['resident_fps_from_mean']:.3f} & "
                f"{case['pl_us']['mean'] / 1000.0:.3f} & "
                f"{case['resident_us']['p95'] / 1000.0:.3f} \\\\")
        lines.extend(["\\end{tabular}", "\\end{table*}", ""])
    secondary = [
        case for case in summary["cases"]
        if case["experiment"] in {"native1x1", "tile"}
    ]
    if secondary:
        lines.extend([
            "\\begin{table*}[t]", "\\centering", "\\small",
            "\\caption{原生1$\\times$1与层自适应 tile 次级消融。}",
            "\\label{tab:lasa-ablation-secondary}",
            "\\begin{tabular}{lllrrrrrrr}",
            "实验 & 配置 & 层 & tile数 & Pass数 & IFM字节 & 权重字节 & "
            "非零MAC & 调度MAC & 时延/$\\mu$s \\\\", "\\hline",
        ])
        for case in secondary:
            for layer_name in case["layers_selected"]:
                contract = case["dma_contract"][layer_name]
                lines.append(
                    f"{case['experiment']} & {case['case_label']} & {layer_name} & "
                    f"{contract['tile_count']} & {contract['k_passes']} & "
                    f"{contract['ifm_dma_bytes']} & {contract['weight_dma_bytes']} & "
                    f"{contract['nonzero_mac']} & {contract['scheduled_lane_mac']} & "
                    f"{case['layers'][layer_name]['latency_us']['mean']:.3f} \\\\")
        lines.extend(["\\end{tabular}", "\\end{table*}", ""])
    args.output_tex.parent.mkdir(parents=True, exist_ok=True)
    args.output_tex.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    manifest = sub.add_parser("manifest")
    manifest.add_argument("--variant", choices=tuple(VARIANTS), required=True)
    manifest.add_argument("--stream-config", type=lambda x: int(x, 0), required=True)
    manifest.add_argument("--experiment", choices=("full", "representative", "native1x1", "tile"), required=True)
    manifest.add_argument("--case-label", default="default")
    manifest.add_argument("--layers", nargs="*")
    manifest.add_argument("--sessions", type=int, default=3)
    manifest.add_argument("--warmup", type=int, default=20)
    manifest.add_argument("--timed", type=int, required=True)
    manifest.add_argument("--hardware-metadata", type=Path, required=True)
    manifest.add_argument("--hardware-sha-manifest", type=Path, required=True)
    manifest.add_argument("--power-report", type=Path, required=True)
    manifest.add_argument("--power-assumptions", type=Path, required=True)
    manifest.add_argument("--bit", type=Path, required=True)
    manifest.add_argument("--xsa", type=Path, required=True)
    manifest.add_argument("--model-spec", type=Path, required=True)
    manifest.add_argument("--parameter-manifest", type=Path, required=True)
    manifest.add_argument("--input-index", type=Path, required=True)
    manifest.add_argument("--output", type=Path, required=True)
    extract = sub.add_parser("samples")
    extract.add_argument("--manifest", type=Path, required=True)
    extract.add_argument("--timing", action="append", type=Path, required=True)
    extract.add_argument("--session", action="append", type=int, required=True)
    extract.add_argument("--output", type=Path, required=True)
    aggregate = sub.add_parser("summarize")
    aggregate.add_argument("--manifest", action="append", type=Path, required=True)
    aggregate.add_argument("--samples", action="append", type=Path, required=True)
    aggregate.add_argument("--hardware-failure", action="append", type=Path)
    aggregate.add_argument("--output", type=Path, required=True)
    paper = sub.add_parser("paper")
    paper.add_argument("--summary", type=Path, required=True)
    paper.add_argument("--output-json", type=Path, required=True)
    paper.add_argument("--output-tex", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "manifest":
            result = build_manifest(args)
            print(json.dumps({"status": result["status"], "variant": result["variant"]}))
        elif args.command == "samples":
            print(json.dumps({"status": "PASS", "records": timing_to_samples(args)}))
        elif args.command == "summarize":
            result = summarize(args)
            print(json.dumps({"status": result["status"], "cases": len(result["cases"])}))
        else:
            write_paper_tables(args)
            print(json.dumps({"status": "PASS", "paper_tables": str(args.output_json)}))
    except (AblationError, OSError, ValueError, KeyError) as exc:
        print(f"FAIL: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
