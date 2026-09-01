#!/usr/bin/env python3
"""Bind and verify the fail-closed ABI-v2 candidate artifact set.

The manifest has two states.  ``inputs_bound`` is sufficient to create/build
the Vitis candidate workspace.  ``complete`` additionally binds the uniquely
named candidate ELF and is required before a board download.  No artifact is
copied by this tool; every recorded file is hashed in place and re-hashed on
each verification.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any, Mapping


FORMAT = "kv260-accelerator-abi-v2-candidate"
MANIFEST_VERSION = 1
CANDIDATE_PROFILE = "abi_v2_candidate"
HARDWARE_PROFILE = "abi_v2_release"
HARDWARE_CLOCK_HZ = {
    "abi_v2_release": 100_000_000,
    "abi_v2_frequency_sweep_125": 125_000_000,
    "abi_v2_release_200": 200_000_000,
}
RELEASE_HARDWARE_PROFILES = frozenset(
    {"abi_v2_release", "abi_v2_release_200"}
)
DEVELOPMENT_FREQUENCY_SWEEP_PROFILES = frozenset(
    {"abi_v2_frequency_sweep_125"}
)
ABI_VERSION = 2
ROWS = 18
COLS = 16
COUT_TILE = 32
VIVADO_VERSION = "2022.2"
VITIS_VERSION = "2022.2"
RUNTIME_READY = 0
ALLOWED_STREAM_CFG = (0x2B, 0x3B, 0x3F, 0xBF)
CANDIDATE_ELF_NAME = "conv_accel_abi_v2_candidate.elf"
PARAMETER_FORMAT = "kv260-accelerator-abi-v2-parameters"
PARAMETER_VERSION = 1
BIAS_PAYLOAD_BYTES = 61_824
WEIGHT_PAYLOAD_BYTES = 16_849_728
ALIGNMENT = 64
BIAS_PACKET_BYTES = COUT_TILE * 4
WEIGHT_PACKET_BYTES = ROWS * COUT_TILE
EXPECTED_LAYER_NAMES = (
    "conv0_pool",
    "conv1_pool",
    "conv2_pool",
    "conv3_pool",
    "conv4_pool",
    "conv5_pool_like_tiny",
    "head_conv6_3x3",
    "head_conv7_1x1",
    "head_conv8_3x3",
    "head_detect_conv9_1x1",
)
EXPECTED_IFM_SHAPES = (
    (416, 416, 3),
    (208, 208, 16),
    (104, 104, 32),
    (52, 52, 64),
    (26, 26, 128),
    (13, 13, 256),
    (13, 13, 512),
    (13, 13, 1024),
    (13, 13, 256),
    (13, 13, 512),
)
EXPECTED_CONV_OFM_SHAPES = (
    (416, 416, 16),
    (208, 208, 32),
    (104, 104, 64),
    (52, 52, 128),
    (26, 26, 256),
    (13, 13, 512),
    (13, 13, 1024),
    (13, 13, 256),
    (13, 13, 512),
    (13, 13, 24),
)
EXPECTED_KERNELS = (3, 3, 3, 3, 3, 3, 3, 1, 3, 1)
EXPECTED_TILE_H_MAX = (2, 4, 8, 8, 8, 8, 8, 13, 8, 13)
EXPECTED_CONTEXTS = (416, 416, 416, 896, 2048, 4096, 16384, 456, 4096, 29)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")


class CandidateArtifactError(RuntimeError):
    """Raised when a candidate artifact set is incomplete or mismatched."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_file_slice(path: Path, offset: int, size: int) -> str:
    digest = hashlib.sha256()
    remaining = size
    with path.open("rb") as stream:
        stream.seek(offset)
        while remaining:
            block = stream.read(min(1024 * 1024, remaining))
            if not block:
                raise CandidateArtifactError(
                    f"short parameter section at offset {offset}, size {size}: {path}"
                )
            digest.update(block)
            remaining -= len(block)
    return digest.hexdigest()


def require_file(path: Path, label: str) -> Path:
    resolved = path.expanduser().resolve()
    if not resolved.is_file():
        raise CandidateArtifactError(f"{label} is not a file: {resolved}")
    return resolved


def require_candidate_workspace(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    if "abi_v2_candidate" not in resolved.name.lower():
        raise CandidateArtifactError(
            "candidate workspace basename must contain 'abi_v2_candidate': "
            f"{resolved}"
        )
    if resolved.name.lower() == "build_vitis_2022_2":
        raise CandidateArtifactError(
            f"legacy ABI-v1 workspace is forbidden for ABI v2: {resolved}"
        )
    return resolved


def parse_key_value_metadata(path: Path) -> dict[str, str]:
    metadata: dict[str, str] = {}
    for line in require_file(path, "hardware metadata").read_text(
        encoding="utf-8"
    ).splitlines():
        key, separator, value = line.partition("=")
        if separator and key:
            metadata[key] = value
    return metadata


def hardware_release_eligible(profile: str) -> bool:
    if profile not in HARDWARE_CLOCK_HZ:
        raise CandidateArtifactError(f"unknown hardware profile: {profile!r}")
    return profile in RELEASE_HARDWARE_PROFILES


def validate_hardware_metadata(metadata: Mapping[str, str]) -> tuple[str, int]:
    profile = metadata.get("profile", "")
    expected = {
        "vivado_version": VIVADO_VERSION,
        "rows": str(ROWS),
        "cols": str(COLS),
        "cout_tile": str(COUT_TILE),
        "enable_packed_hwc_ofm": "1",
        "enable_layer_tile_sequencer": "1",
        "enable_layer_long_hwc_ifm": "1",
        "enable_tagged_context": "1",
        "enable_column_psum": "0",
        "git_dirty": "0",
    }
    mismatches = [
        f"{key}={metadata.get(key)!r}, expected {value!r}"
        for key, value in expected.items()
        if metadata.get(key) != value
    ]
    if profile not in HARDWARE_CLOCK_HZ:
        mismatches.append(
            f"profile={profile!r}, expected one of {tuple(HARDWARE_CLOCK_HZ)!r}"
        )
        expected_clock_hz = 0
    else:
        expected_clock_hz = HARDWARE_CLOCK_HZ[profile]
    raw_clock_hz = metadata.get("clock_hz")
    raw_pl_clock_mhz = metadata.get("pl_clock_mhz")
    # Pre-clock-contract 100 MHz metadata remains readable.  Every 200 MHz
    # candidate, and every newly generated metadata file, is explicit.
    if raw_clock_hz is None and profile == HARDWARE_PROFILE:
        clock_hz = expected_clock_hz
    else:
        try:
            clock_hz = int(str(raw_clock_hz))
        except (TypeError, ValueError):
            clock_hz = 0
            mismatches.append(f"clock_hz={raw_clock_hz!r}, expected an integer")
    if clock_hz != expected_clock_hz:
        mismatches.append(
            f"clock_hz={clock_hz!r}, expected {expected_clock_hz!r}"
        )
    if raw_pl_clock_mhz is not None:
        try:
            pl_clock_hz = int(str(raw_pl_clock_mhz)) * 1_000_000
        except (TypeError, ValueError):
            pl_clock_hz = 0
        if pl_clock_hz != expected_clock_hz:
            mismatches.append(
                f"pl_clock_mhz={raw_pl_clock_mhz!r}, expected "
                f"{expected_clock_hz // 1_000_000!r}"
            )
    elif profile != HARDWARE_PROFILE:
        mismatches.append("pl_clock_mhz is required for non-legacy metadata")
    raw_weight_burst = metadata.get("weight_dma_mm2s_burst")
    if raw_weight_burst is not None and raw_weight_burst != "64":
        mismatches.append(
            f"weight_dma_mm2s_burst={raw_weight_burst!r}, expected '64'"
        )
    elif raw_weight_burst is None and profile != HARDWARE_PROFILE:
        mismatches.append(
            "weight_dma_mm2s_burst is required for explicit clock metadata"
        )
    if profile in DEVELOPMENT_FREQUENCY_SWEEP_PROFILES:
        development_expected = {
            "source_profile": "abi_v2_release_200",
            "development_frequency_sweep": "1",
            "place_min_wns": "0.08",
            "min_wns": "0.0",
        }
        mismatches.extend(
            f"{key}={metadata.get(key)!r}, expected {value!r}"
            for key, value in development_expected.items()
            if metadata.get(key) != value
        )
    git_sha = metadata.get("git_sha", "")
    if not GIT_SHA_RE.fullmatch(git_sha):
        mismatches.append(f"git_sha={git_sha!r}, expected a full 40-hex SHA")
    if mismatches:
        raise CandidateArtifactError(
            "hardware metadata is not a clean abi_v2_release build: "
            + "; ".join(mismatches)
        )
    return profile, clock_hz


def validate_hardware_sha_manifest(
    path: Path, xsa: Path, bitstream: Path
) -> None:
    entries: dict[str, str] = {}
    for line in require_file(path, "hardware SHA256 manifest").read_text(
        encoding="utf-8"
    ).splitlines():
        fields = line.split()
        if len(fields) != 2 or not SHA256_RE.fullmatch(fields[0].lower()):
            raise CandidateArtifactError(
                f"invalid hardware SHA256 manifest line: {line!r}"
            )
        if fields[1] in entries:
            raise CandidateArtifactError(
                f"duplicate hardware SHA256 entry: {fields[1]}"
            )
        entries[fields[1]] = fields[0].lower()
    for label, artifact in (("XSA", xsa), ("bitstream", bitstream)):
        expected = entries.get(artifact.name)
        if expected is None:
            raise CandidateArtifactError(
                f"hardware SHA256 manifest does not bind {label} {artifact.name}"
            )
        actual = sha256_file(artifact)
        if actual != expected:
            raise CandidateArtifactError(
                f"{label} does not match hardware publication SHA256: "
                f"{actual}, expected {expected}"
            )


def manifest_clock_hz(value: Mapping[str, Any]) -> int:
    hardware = value.get("hardware")
    runtime = value.get("runtime")
    if not isinstance(hardware, Mapping) or not isinstance(runtime, Mapping):
        raise CandidateArtifactError("candidate manifest has no clock identity")
    profile = hardware.get("profile")
    if profile not in HARDWARE_CLOCK_HZ:
        raise CandidateArtifactError(f"unknown hardware profile: {profile!r}")
    expected = HARDWARE_CLOCK_HZ[str(profile)]
    runtime_clock = runtime.get("clock_hz")
    hardware_clock = hardware.get("clock_hz")
    if runtime_clock is None and hardware_clock is None and profile == HARDWARE_PROFILE:
        return expected
    if runtime_clock != expected or hardware_clock != expected:
        raise CandidateArtifactError(
            "candidate manifest clock mismatch: "
            f"runtime={runtime_clock!r} hardware={hardware_clock!r} "
            f"expected={expected}"
        )
    return expected


def manifest_release_eligible(value: Mapping[str, Any]) -> bool:
    hardware = value.get("hardware")
    if not isinstance(hardware, Mapping):
        raise CandidateArtifactError("candidate manifest has no hardware identity")
    profile = hardware.get("profile")
    if not isinstance(profile, str):
        raise CandidateArtifactError("candidate manifest has no hardware profile")
    expected = hardware_release_eligible(profile)
    recorded = value.get("release_eligible")
    hardware_recorded = hardware.get("release_eligible")
    # Version-1 release manifests created before this field existed remain
    # readable.  Development profiles never receive this compatibility path.
    if recorded is None and hardware_recorded is None and expected:
        return True
    if recorded is not expected or hardware_recorded is not expected:
        raise CandidateArtifactError(
            "candidate manifest release eligibility mismatch: "
            f"top={recorded!r} hardware={hardware_recorded!r} "
            f"expected={expected!r} for profile={profile!r}"
        )
    return expected


def file_entry(path: Path, manifest_path: Path) -> dict[str, Any]:
    resolved = require_file(path, "artifact")
    try:
        stored_path = os.path.relpath(resolved, manifest_path.parent.resolve())
    except ValueError:
        stored_path = str(resolved)
    return {
        "path": Path(stored_path).as_posix(),
        "size_bytes": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }


def resolve_entry(manifest_path: Path, entry: Mapping[str, Any]) -> Path:
    raw = Path(str(entry.get("path", "")))
    return (raw if raw.is_absolute() else manifest_path.parent / raw).resolve()


def verify_file_entry(
    manifest_path: Path,
    entry: Mapping[str, Any],
    label: str,
) -> Path:
    path = require_file(resolve_entry(manifest_path, entry), label)
    expected_size = entry.get("size_bytes")
    expected_hash = str(entry.get("sha256", "")).lower()
    if not isinstance(expected_size, int) or expected_size < 0:
        raise CandidateArtifactError(f"{label} has invalid size metadata")
    if not SHA256_RE.fullmatch(expected_hash):
        raise CandidateArtifactError(f"{label} has invalid SHA256 metadata")
    actual_size = path.stat().st_size
    if actual_size != expected_size:
        raise CandidateArtifactError(
            f"{label} size mismatch: {actual_size}, expected {expected_size}"
        )
    actual_hash = sha256_file(path)
    if actual_hash != expected_hash:
        raise CandidateArtifactError(
            f"{label} SHA256 mismatch: {actual_hash}, expected {expected_hash}"
        )
    return path


def load_json(path: Path, label: str) -> dict[str, Any]:
    resolved = require_file(path, label)
    try:
        value = json.loads(resolved.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise CandidateArtifactError(f"invalid {label}: {error}") from error
    if not isinstance(value, dict):
        raise CandidateArtifactError(f"{label} root must be an object")
    return value


def validate_parameter_manifest(path: Path) -> dict[str, Any]:
    resolved = require_file(path, "parameter manifest")
    manifest = load_json(resolved, "parameter manifest")
    if manifest.get("format") != PARAMETER_FORMAT:
        raise CandidateArtifactError(
            f"wrong parameter format: {manifest.get('format')!r}"
        )
    if manifest.get("version") != PARAMETER_VERSION:
        raise CandidateArtifactError(
            f"wrong parameter manifest version: {manifest.get('version')!r}"
        )
    if manifest.get("array") != {
        "rows": ROWS,
        "cols": COLS,
        "cout_tile": COUT_TILE,
    }:
        raise CandidateArtifactError(
            f"wrong parameter array identity: {manifest.get('array')!r}"
        )
    if manifest.get("alignment_bytes") != ALIGNMENT:
        raise CandidateArtifactError(
            f"wrong parameter alignment: {manifest.get('alignment_bytes')!r}"
        )
    if manifest.get("packet_bytes") != {
        "bias": BIAS_PACKET_BYTES,
        "weight": WEIGHT_PACKET_BYTES,
    }:
        raise CandidateArtifactError(
            f"wrong parameter packet sizes: {manifest.get('packet_bytes')!r}"
        )
    files = manifest.get("files")
    if not isinstance(files, dict):
        raise CandidateArtifactError("parameter manifest has no files object")
    expected_payloads = {
        "bias": BIAS_PAYLOAD_BYTES,
        "weight": WEIGHT_PAYLOAD_BYTES,
    }
    verified: dict[str, Any] = {}
    for kind, expected_payload in expected_payloads.items():
        entry = files.get(kind)
        if not isinstance(entry, dict):
            raise CandidateArtifactError(
                f"parameter manifest has no {kind} file entry"
            )
        if entry.get("payload_bytes") != expected_payload:
            raise CandidateArtifactError(
                f"{kind} payload total {entry.get('payload_bytes')!r}, "
                f"expected {expected_payload}"
            )
        expected_name = f"abi_v2_{kind}_cout32.bin"
        if entry.get("path") != expected_name:
            raise CandidateArtifactError(
                f"{kind} package path {entry.get('path')!r}, "
                f"expected {expected_name!r}"
            )
        raw_path = Path(str(entry.get("path", "")))
        payload_path = (
            raw_path if raw_path.is_absolute() else resolved.parent / raw_path
        ).resolve()
        payload_path = require_file(payload_path, f"{kind} parameter package")
        expected_size = entry.get("file_bytes")
        if expected_size != expected_payload:
            raise CandidateArtifactError(
                f"{kind} package file size {expected_size!r}, "
                f"expected {expected_payload}"
            )
        if payload_path.stat().st_size != expected_size:
            raise CandidateArtifactError(
                f"{kind} package size mismatch: {payload_path.stat().st_size}, "
                f"expected {expected_size!r}"
            )
        expected_hash = str(entry.get("sha256", "")).lower()
        if not SHA256_RE.fullmatch(expected_hash):
            raise CandidateArtifactError(
                f"{kind} package has invalid SHA256 metadata"
            )
        actual_hash = sha256_file(payload_path)
        if actual_hash != expected_hash:
            raise CandidateArtifactError(
                f"{kind} package SHA256 mismatch: {actual_hash}, "
                f"expected {expected_hash}"
            )
        verified[kind] = payload_path
    layers = manifest.get("layers")
    if not isinstance(layers, list) or len(layers) != 10:
        raise CandidateArtifactError("parameter manifest must contain 10 layers")
    next_offset = {"bias": 0, "weight": 0}
    payload_totals = {"bias": 0, "weight": 0}
    header_rows: list[tuple[int, int, int, int, int, int]] = []
    for index, layer in enumerate(layers):
        if not isinstance(layer, dict):
            raise CandidateArtifactError(f"parameter layer {index} is not an object")
        if layer.get("index") != index or layer.get("name") != EXPECTED_LAYER_NAMES[index]:
            raise CandidateArtifactError(
                f"parameter layer {index} identity mismatch: "
                f"index={layer.get('index')!r} name={layer.get('name')!r}"
            )
        ifm_h, ifm_w, cin = EXPECTED_IFM_SHAPES[index]
        conv_h, conv_w, cout = EXPECTED_CONV_OFM_SHAPES[index]
        kernel = EXPECTED_KERNELS[index]
        k_total = cin * kernel * kernel
        k_passes = (k_total + ROWS - 1) // ROWS
        cout_blocks = (cout + COUT_TILE - 1) // COUT_TILE
        tile_h_max = EXPECTED_TILE_H_MAX[index]
        tile_count = (conv_h + tile_h_max - 1) // tile_h_max
        expected_shape = {
            "ifm_hwc": [ifm_h, ifm_w, cin],
            "conv_ofm_hwc": [conv_h, conv_w, cout],
            "kernel": kernel,
            "k_total": k_total,
            "k_passes": k_passes,
            "cout_blocks": cout_blocks,
            "tile_h_max": tile_h_max,
            "tile_count": tile_count,
        }
        if layer.get("shape") != expected_shape:
            raise CandidateArtifactError(
                f"parameter layer {index} shape mismatch: {layer.get('shape')!r}"
            )
        expected_packets = {
            "bias": tile_count * cout_blocks,
            "weight": EXPECTED_CONTEXTS[index],
        }
        if expected_packets["weight"] != expected_packets["bias"] * k_passes:
            raise CandidateArtifactError(
                f"internal context expectation mismatch for layer {index}"
            )
        for kind, packet_bytes in (
            ("bias", BIAS_PACKET_BYTES),
            ("weight", WEIGHT_PACKET_BYTES),
        ):
            section = layer.get(kind)
            if not isinstance(section, dict):
                raise CandidateArtifactError(
                    f"parameter layer {index} has no {kind} section"
                )
            offset = section.get("offset")
            size = section.get("bytes")
            packets = section.get("packets")
            section_hash = str(section.get("sha256", "")).lower()
            if not all(isinstance(value, int) for value in (offset, size, packets)):
                raise CandidateArtifactError(
                    f"parameter layer {index} {kind} section has non-integer metadata"
                )
            expected_offset = (
                (next_offset[kind] + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT
            )
            if offset != expected_offset or offset % ALIGNMENT != 0:
                raise CandidateArtifactError(
                    f"parameter layer {index} {kind} offset {offset}, "
                    f"expected {expected_offset}"
                )
            if packets != expected_packets[kind] or size != packets * packet_bytes:
                raise CandidateArtifactError(
                    f"parameter layer {index} {kind} size/packet mismatch: "
                    f"bytes={size} packets={packets}"
                )
            if not SHA256_RE.fullmatch(section_hash):
                raise CandidateArtifactError(
                    f"parameter layer {index} {kind} has invalid SHA256"
                )
            actual_section_hash = sha256_file_slice(
                verified[kind], offset, size
            )
            if actual_section_hash != section_hash:
                raise CandidateArtifactError(
                    f"parameter layer {index} {kind} SHA256 mismatch: "
                    f"{actual_section_hash}, expected {section_hash}"
                )
            next_offset[kind] = offset + size
            payload_totals[kind] += size
        # Header order is bias offset/bytes, weight offset/bytes, then packets.
        header_rows.append(
            (
                layer["bias"]["offset"],
                layer["bias"]["bytes"],
                layer["weight"]["offset"],
                layer["weight"]["bytes"],
                layer["bias"]["packets"],
                layer["weight"]["packets"],
            )
        )
    if payload_totals != expected_payloads:
        raise CandidateArtifactError(
            f"parameter layer payload totals {payload_totals!r}, "
            f"expected {expected_payloads!r}"
        )
    binding_header = require_file(
        resolved.parent / "accel_v2_parameter_package.h",
        "generated parameter binding header",
    )
    binding_text = binding_header.read_text(encoding="ascii")
    required_macros = (
        f"ACCEL_V2_PARAMETER_PACKAGE_VERSION {PARAMETER_VERSION}U",
        f"ACCEL_V2_PARAMETER_PACKAGE_ALIGNMENT {ALIGNMENT}U",
        f"ACCEL_V2_BIAS_PACKAGE_BYTES {files['bias']['file_bytes']}U",
        f"ACCEL_V2_WEIGHT_PACKAGE_BYTES {files['weight']['file_bytes']}U",
    )
    for macro in required_macros:
        if f"#define {macro}" not in binding_text:
            raise CandidateArtifactError(
                f"generated parameter binding header does not bind {macro}"
            )
    for kind in ("bias", "weight"):
        expected_hash = str(files[kind]["sha256"]).lower()
        macro = f'ACCEL_V2_{kind.upper()}_PACKAGE_SHA256 "{expected_hash}"'
        if macro not in binding_text:
            raise CandidateArtifactError(
                f"generated parameter binding header does not bind {kind} SHA256"
            )
    initializer_rows = [
        tuple(int(value) for value in match)
        for match in re.findall(
            r"^\s*\{(\d+)U,\s*(\d+)U,\s*(\d+)U,\s*(\d+)U,\s*"
            r"(\d+)U,\s*(\d+)U\},\s*$",
            binding_text,
            flags=re.MULTILINE,
        )
    ]
    if initializer_rows != header_rows:
        raise CandidateArtifactError(
            "generated parameter binding header layer table does not match manifest"
        )
    return {
        "manifest": resolved,
        "binding_header": binding_header,
        **verified,
    }


def current_git_provenance(root: Path) -> dict[str, Any]:
    try:
        sha = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        status = subprocess.run(
            ["git", "-C", str(root), "status", "--porcelain=v1"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise CandidateArtifactError(f"cannot read software Git provenance: {error}")
    if not GIT_SHA_RE.fullmatch(sha):
        raise CandidateArtifactError(f"invalid software Git SHA: {sha!r}")
    return {"git_sha": sha.lower(), "git_dirty": int(bool(status))}


def validate_clean_git_provenance(
    provenance: Mapping[str, Any], label: str
) -> str:
    git_sha = provenance.get("git_sha")
    git_dirty = provenance.get("git_dirty")
    if not isinstance(git_sha, str) or not GIT_SHA_RE.fullmatch(git_sha):
        raise CandidateArtifactError(
            f"{label} has invalid Git SHA {git_sha!r}; expected a full 40-hex SHA"
        )
    if git_dirty not in {0, False}:
        raise CandidateArtifactError(f"{label} was built from a dirty worktree")
    return git_sha.lower()


def bind_inputs(
    manifest_path: Path,
    workspace: Path,
    xsa: Path,
    bitstream: Path,
    hardware_metadata_path: Path,
    hardware_sha_manifest_path: Path,
    parameter_manifest_path: Path,
) -> dict[str, Any]:
    manifest_path = manifest_path.expanduser().resolve()
    workspace = require_candidate_workspace(workspace)
    if manifest_path.parent != workspace:
        raise CandidateArtifactError(
            "candidate manifest must reside directly in its bound workspace: "
            f"{manifest_path}"
        )
    xsa = require_file(xsa, "XSA")
    bitstream = require_file(bitstream, "bitstream")
    if xsa.suffix.lower() != ".xsa":
        raise CandidateArtifactError(f"XSA must use .xsa suffix: {xsa}")
    if bitstream.suffix.lower() != ".bit":
        raise CandidateArtifactError(f"bitstream must use .bit suffix: {bitstream}")
    hardware_metadata_path = require_file(
        hardware_metadata_path, "hardware metadata"
    )
    hardware_metadata = parse_key_value_metadata(hardware_metadata_path)
    hardware_profile, clock_hz = validate_hardware_metadata(hardware_metadata)
    release_eligible = hardware_release_eligible(hardware_profile)
    hardware_sha_manifest_path = require_file(
        hardware_sha_manifest_path, "hardware SHA256 manifest"
    )
    validate_hardware_sha_manifest(hardware_sha_manifest_path, xsa, bitstream)
    parameters = validate_parameter_manifest(parameter_manifest_path)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    value: dict[str, Any] = {
        "format": FORMAT,
        "manifest_version": MANIFEST_VERSION,
        "state": "inputs_bound",
        "candidate_profile": CANDIDATE_PROFILE,
        "release_eligible": release_eligible,
        "runtime": {
            "abi_version": ABI_VERSION,
            "rows": ROWS,
            "cols": COLS,
            "cout_tile": COUT_TILE,
            "long_stream_runtime_ready": RUNTIME_READY,
            "clock_hz": clock_hz,
        },
        "toolchain": {
            "vivado": VIVADO_VERSION,
            "vitis": VITIS_VERSION,
        },
        "workspace": str(workspace),
        "hardware": {
            "profile": hardware_profile,
            "clock_hz": clock_hz,
            "release_eligible": release_eligible,
            "git_sha": hardware_metadata["git_sha"].lower(),
            "git_dirty": 0,
            "xsa": file_entry(xsa, manifest_path),
            "bitstream": file_entry(bitstream, manifest_path),
            "metadata": file_entry(hardware_metadata_path, manifest_path),
            "sha256_manifest": file_entry(
                hardware_sha_manifest_path, manifest_path
            ),
        },
        "parameters": {
            "manifest": file_entry(parameters["manifest"], manifest_path),
            "binding_header": file_entry(
                parameters["binding_header"], manifest_path
            ),
            "bias": file_entry(parameters["bias"], manifest_path),
            "weight": file_entry(parameters["weight"], manifest_path),
        },
        "software": {
            "elf": None,
            "git_sha": None,
            "git_dirty": None,
            "clock_hz": None,
            "run_mode": None,
            "soak_seconds": None,
            "soak_temp_limit_millic": None,
        },
    }
    manifest_path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return value


def validate_manifest_identity(value: Mapping[str, Any]) -> None:
    expected_scalars = {
        "format": FORMAT,
        "manifest_version": MANIFEST_VERSION,
        "candidate_profile": CANDIDATE_PROFILE,
    }
    mismatches = [
        f"{key}={value.get(key)!r}, expected {expected!r}"
        for key, expected in expected_scalars.items()
        if value.get(key) != expected
    ]
    runtime = value.get("runtime")
    expected_runtime = {
        "abi_version": ABI_VERSION,
        "rows": ROWS,
        "cols": COLS,
        "cout_tile": COUT_TILE,
        "long_stream_runtime_ready": RUNTIME_READY,
    }
    if not isinstance(runtime, Mapping) or any(
        runtime.get(key) != expected for key, expected in expected_runtime.items()
    ):
        mismatches.append(f"runtime identity is {runtime!r}")
    toolchain = value.get("toolchain")
    if toolchain != {"vivado": VIVADO_VERSION, "vitis": VITIS_VERSION}:
        mismatches.append(f"toolchain identity is {toolchain!r}")
    hardware = value.get("hardware")
    if (
        not isinstance(hardware, dict)
        or hardware.get("profile") not in HARDWARE_CLOCK_HZ
    ):
        mismatches.append("hardware profile is not a supported ABI-v2 profile")
    if isinstance(hardware, dict) and hardware.get("git_dirty") != 0:
        mismatches.append("hardware candidate was built from a dirty worktree")
    try:
        manifest_clock_hz(value)
    except CandidateArtifactError as error:
        mismatches.append(str(error))
    try:
        manifest_release_eligible(value)
    except CandidateArtifactError as error:
        mismatches.append(str(error))
    if mismatches:
        raise CandidateArtifactError(
            "candidate manifest identity mismatch: " + "; ".join(mismatches)
        )


def verify_manifest(
    manifest_path: Path,
    phase: str,
    expected_workspace: Path | None = None,
    expected_xsa: Path | None = None,
    expected_bitstream: Path | None = None,
    expected_elf: Path | None = None,
    expected_parameter_manifest: Path | None = None,
    expected_bias: Path | None = None,
    expected_weight: Path | None = None,
    expected_software_provenance: Mapping[str, Any] | None = None,
    expected_clock_hz: int | None = None,
) -> dict[str, Any]:
    manifest_path = require_file(manifest_path, "candidate manifest")
    value = load_json(manifest_path, "candidate manifest")
    validate_manifest_identity(value)
    clock_hz = manifest_clock_hz(value)
    release_eligible = manifest_release_eligible(value)
    if expected_clock_hz is not None and clock_hz != expected_clock_hz:
        raise CandidateArtifactError(
            f"clock selection mismatch: {clock_hz}, expected {expected_clock_hz}"
        )
    if phase not in {"build", "run"}:
        raise CandidateArtifactError(f"unknown verification phase: {phase}")
    state = value.get("state")
    if phase == "build" and state not in {"inputs_bound", "complete"}:
        raise CandidateArtifactError(f"invalid build manifest state: {state!r}")
    if phase == "run" and state != "complete":
        raise CandidateArtifactError(
            f"board run requires complete manifest, found {state!r}"
        )
    workspace = require_candidate_workspace(Path(str(value.get("workspace", ""))))
    if manifest_path.parent != workspace:
        raise CandidateArtifactError(
            "candidate manifest is outside its bound workspace: "
            f"{manifest_path}"
        )
    if expected_workspace is not None and workspace != require_candidate_workspace(
        expected_workspace
    ):
        raise CandidateArtifactError(
            f"workspace mismatch: {workspace}, expected {expected_workspace.resolve()}"
        )
    hardware = value["hardware"]
    xsa = verify_file_entry(manifest_path, hardware["xsa"], "XSA")
    bitstream = verify_file_entry(
        manifest_path, hardware["bitstream"], "bitstream"
    )
    metadata_path = verify_file_entry(
        manifest_path, hardware["metadata"], "hardware metadata"
    )
    metadata = parse_key_value_metadata(metadata_path)
    metadata_profile, metadata_clock_hz = validate_hardware_metadata(metadata)
    if metadata_profile != hardware.get("profile"):
        raise CandidateArtifactError("hardware metadata profile changed")
    if metadata_clock_hz != clock_hz:
        raise CandidateArtifactError("hardware metadata clock changed")
    hardware_sha_manifest_path = verify_file_entry(
        manifest_path,
        hardware["sha256_manifest"],
        "hardware SHA256 manifest",
    )
    validate_hardware_sha_manifest(hardware_sha_manifest_path, xsa, bitstream)
    if metadata["git_sha"].lower() != hardware.get("git_sha"):
        raise CandidateArtifactError("hardware metadata Git SHA changed")
    if expected_xsa is not None and xsa != expected_xsa.expanduser().resolve():
        raise CandidateArtifactError(
            f"XSA selection mismatch: {xsa}, expected {expected_xsa.resolve()}"
        )
    if expected_bitstream is not None and bitstream != expected_bitstream.expanduser().resolve():
        raise CandidateArtifactError(
            "bitstream selection mismatch: "
            f"{bitstream}, expected {expected_bitstream.resolve()}"
        )
    parameters = value.get("parameters")
    if not isinstance(parameters, dict):
        raise CandidateArtifactError("candidate manifest has no parameters")
    parameter_manifest = verify_file_entry(
        manifest_path, parameters["manifest"], "parameter manifest"
    )
    if (
        expected_parameter_manifest is not None
        and parameter_manifest != expected_parameter_manifest.expanduser().resolve()
    ):
        raise CandidateArtifactError(
            "parameter-package selection mismatch: "
            f"{parameter_manifest}, expected "
            f"{expected_parameter_manifest.expanduser().resolve()}"
        )
    verified_parameters = validate_parameter_manifest(parameter_manifest)
    binding_header = verify_file_entry(
        manifest_path,
        parameters["binding_header"],
        "generated parameter binding header",
    )
    if binding_header != verified_parameters["binding_header"]:
        raise CandidateArtifactError(
            "bound parameter header is not adjacent to the parameter manifest"
        )
    expected_parameter_files = {
        "bias": expected_bias,
        "weight": expected_weight,
    }
    for kind in ("bias", "weight"):
        bound_path = verify_file_entry(
            manifest_path, parameters[kind], f"{kind} parameter package"
        )
        if bound_path != verified_parameters[kind]:
            raise CandidateArtifactError(
                f"bound {kind} package is not the file named by parameter manifest"
            )
        expected_path = expected_parameter_files[kind]
        if (
            expected_path is not None
            and bound_path != expected_path.expanduser().resolve()
        ):
            raise CandidateArtifactError(
                f"{kind} package selection mismatch: {bound_path}, expected "
                f"{expected_path.expanduser().resolve()}"
            )
    if phase == "run":
        software = value.get("software")
        if not isinstance(software, dict) or not isinstance(
            software.get("elf"), dict
        ):
            raise CandidateArtifactError("complete candidate has no ELF binding")
        software_git_sha = validate_clean_git_provenance(
            software, "candidate ELF software provenance"
        )
        if expected_software_provenance is not None:
            expected_git_sha = validate_clean_git_provenance(
                expected_software_provenance,
                "expected candidate ELF software provenance",
            )
            if software_git_sha != expected_git_sha:
                raise CandidateArtifactError(
                    "candidate ELF software Git provenance mismatch: "
                    f"{software_git_sha}, expected {expected_git_sha}"
                )
        if software.get("long_stream_runtime_enabled") != 1:
            raise CandidateArtifactError(
                "candidate ELF did not explicitly enable the layer-long runtime"
            )
        stream_cfg = software.get("stream_cfg")
        performance_mode = software.get("performance_mode")
        benchmark_runs = software.get("benchmark_runs")
        soak_seconds = software.get("soak_seconds", 0)
        soak_temp_limit_millic = software.get(
            "soak_temp_limit_millic", 0
        )
        run_mode = software.get("run_mode")
        if stream_cfg not in ALLOWED_STREAM_CFG or (stream_cfg & 0x40) != 0:
            raise CandidateArtifactError(
                f"candidate ELF has invalid STREAM_CFG: {stream_cfg!r}"
            )
        if not isinstance(performance_mode, bool):
            raise CandidateArtifactError(
                "candidate ELF has no boolean performance-mode identity"
            )
        if performance_mode and stream_cfg != 0xBF:
            raise CandidateArtifactError(
                "performance candidate must use STREAM_CFG=0xBF"
            )
        if benchmark_runs not in {0, 30, 100}:
            raise CandidateArtifactError(
                f"candidate ELF has invalid benchmark run count: {benchmark_runs!r}"
            )
        if not isinstance(soak_seconds, int) or soak_seconds < 0:
            raise CandidateArtifactError(
                f"candidate ELF has invalid soak duration: {soak_seconds!r}"
            )
        if not isinstance(soak_temp_limit_millic, int) or \
                soak_temp_limit_millic < 0:
            raise CandidateArtifactError(
                "candidate ELF has invalid soak temperature limit: "
                f"{soak_temp_limit_millic!r}"
            )
        is_soak = soak_seconds != 0
        inferred_mode = (
            "soak" if is_soak else
            "benchmark" if benchmark_runs in {30, 100} else
            "functional"
        )
        # Older complete manifests predate the explicit run-mode field.
        if run_mode is None:
            run_mode = inferred_mode
        if run_mode != inferred_mode:
            raise CandidateArtifactError(
                f"candidate ELF run mode {run_mode!r} conflicts with its controls"
            )
        if is_soak:
            if soak_seconds < 600 or soak_temp_limit_millic != 85_000:
                raise CandidateArtifactError(
                    "soak candidate must bind at least 600 seconds and a "
                    "strict 85000 mC temperature limit"
                )
            if benchmark_runs != 0 or not performance_mode or stream_cfg != 0xBF:
                raise CandidateArtifactError(
                    "soak candidate requires performance STREAM_CFG=0xBF "
                    "with zero finite benchmark runs"
                )
        elif soak_temp_limit_millic != 0:
            raise CandidateArtifactError(
                "non-soak candidate has a nonzero soak temperature limit"
            )
        elif performance_mode != (benchmark_runs in {30, 100}):
            raise CandidateArtifactError(
                "performance candidate must contain one warm-up plus 30 or 100 runs"
            )
        if not release_eligible and (
            hardware.get("profile") not in DEVELOPMENT_FREQUENCY_SWEEP_PROFILES
            or soak_seconds != 0
            or soak_temp_limit_millic != 0
            or stream_cfg != 0xBF
            or run_mode not in {"functional", "benchmark"}
            or benchmark_runs not in {0, 30}
        ):
            raise CandidateArtifactError(
                "development frequency-sweep candidates allow only one "
                "functional run or one warm-up plus 30 performance runs, "
                "always with STREAM_CFG=0xBF and no soak"
            )
        software_clock_hz = software.get("clock_hz")
        if software_clock_hz is None and hardware.get("profile") == HARDWARE_PROFILE:
            software_clock_hz = 100_000_000
        if software_clock_hz != clock_hz:
            raise CandidateArtifactError(
                "candidate ELF clock identity mismatch: "
                f"{software_clock_hz!r}, expected {clock_hz}"
            )
        elf = verify_file_entry(manifest_path, software["elf"], "candidate ELF")
        if elf.name != CANDIDATE_ELF_NAME:
            raise CandidateArtifactError(
                f"wrong candidate ELF name: {elf.name}, expected {CANDIDATE_ELF_NAME}"
            )
        if expected_elf is not None and elf != expected_elf.expanduser().resolve():
            raise CandidateArtifactError(
                f"ELF selection mismatch: {elf}, expected {expected_elf.resolve()}"
            )
    return value


def finalize_manifest(
    manifest_path: Path,
    elf: Path,
    software_provenance: Mapping[str, Any] | None = None,
    stream_cfg: int = 0xBF,
    performance_mode: bool = False,
    benchmark_runs: int = 0,
    clock_hz: int | None = None,
    soak_seconds: int = 0,
    soak_temp_limit_millic: int = 0,
) -> dict[str, Any]:
    manifest_path = require_file(manifest_path, "candidate manifest")
    value = verify_manifest(manifest_path, "build")
    manifest_expected_clock_hz = manifest_clock_hz(value)
    release_eligible = manifest_release_eligible(value)
    if clock_hz is None:
        clock_hz = manifest_expected_clock_hz
    if clock_hz != manifest_expected_clock_hz:
        raise CandidateArtifactError(
            f"ELF clock {clock_hz} does not match manifest clock "
            f"{manifest_expected_clock_hz}"
        )
    elf = require_file(elf, "candidate ELF")
    if elf.name != CANDIDATE_ELF_NAME:
        raise CandidateArtifactError(
            f"candidate ELF must be named {CANDIDATE_ELF_NAME}: {elf}"
        )
    if elf.parent.parent.resolve() != require_candidate_workspace(
        Path(str(value["workspace"]))
    ) / "conv_accel_abi_v2_candidate":
        raise CandidateArtifactError(
            "candidate ELF must reside under the bound candidate app workspace: "
            f"{elf}"
        )
    if software_provenance is None:
        script_root = Path(__file__).resolve().parents[3]
        software_provenance = current_git_provenance(script_root)
    git_sha = validate_clean_git_provenance(
        software_provenance, "candidate ELF finalization provenance"
    )
    if stream_cfg not in ALLOWED_STREAM_CFG or (stream_cfg & 0x40) != 0:
        raise CandidateArtifactError(
            f"invalid ABI v2 candidate STREAM_CFG: 0x{stream_cfg:02x}"
        )
    if performance_mode and stream_cfg != 0xBF:
        raise CandidateArtifactError(
            "performance candidate must use STREAM_CFG=0xBF"
        )
    if benchmark_runs not in {0, 30, 100}:
        raise CandidateArtifactError(
            f"candidate ELF has invalid benchmark run count: {benchmark_runs!r}"
        )
    is_soak = soak_seconds != 0
    if is_soak:
        if soak_seconds < 600 or soak_temp_limit_millic != 85_000:
            raise CandidateArtifactError(
                "soak candidate must bind at least 600 seconds and a strict "
                "85000 mC temperature limit"
            )
        if benchmark_runs != 0 or not performance_mode or stream_cfg != 0xBF:
            raise CandidateArtifactError(
                "soak candidate requires performance STREAM_CFG=0xBF with "
                "zero finite benchmark runs"
            )
    elif soak_temp_limit_millic != 0:
        raise CandidateArtifactError(
            "non-soak candidate has a nonzero soak temperature limit"
        )
    elif performance_mode != (benchmark_runs in {30, 100}):
        raise CandidateArtifactError(
            "performance candidate must contain one warm-up plus 30 or 100 runs"
        )
    if not release_eligible and (
        value["hardware"].get("profile")
        not in DEVELOPMENT_FREQUENCY_SWEEP_PROFILES
        or soak_seconds != 0
        or soak_temp_limit_millic != 0
        or stream_cfg != 0xBF
        or benchmark_runs not in {0, 30}
    ):
        raise CandidateArtifactError(
            "development frequency-sweep candidates allow only one functional "
            "run or one warm-up plus 30 performance runs, always with "
            "STREAM_CFG=0xBF and no soak"
        )
    value["state"] = "complete"
    value["software"] = {
        "elf": file_entry(elf, manifest_path),
        "git_sha": git_sha,
        "git_dirty": 0,
        "long_stream_runtime_enabled": 1,
        "stream_cfg": stream_cfg,
        "performance_mode": bool(performance_mode),
        "benchmark_runs": benchmark_runs,
        "clock_hz": clock_hz,
        "run_mode": (
            "soak" if is_soak else
            "benchmark" if benchmark_runs in {30, 100} else
            "functional"
        ),
        "soak_seconds": soak_seconds,
        "soak_temp_limit_millic": soak_temp_limit_millic,
    }
    manifest_path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    verify_manifest(
        manifest_path,
        "run",
        expected_software_provenance={"git_sha": git_sha, "git_dirty": 0},
    )
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    bind = subparsers.add_parser("bind", help="bind verified build inputs")
    bind.add_argument("--manifest", type=Path, required=True)
    bind.add_argument("--workspace", type=Path, required=True)
    bind.add_argument("--xsa", type=Path, required=True)
    bind.add_argument("--bit", dest="bitstream", type=Path, required=True)
    bind.add_argument("--hardware-metadata", type=Path, required=True)
    bind.add_argument("--hardware-sha-manifest", type=Path, required=True)
    bind.add_argument("--parameter-manifest", type=Path, required=True)

    finalize = subparsers.add_parser("finalize", help="bind the candidate ELF")
    finalize.add_argument("--manifest", type=Path, required=True)
    finalize.add_argument("--elf", type=Path, required=True)
    finalize.add_argument(
        "--stream-cfg",
        type=lambda value: int(value, 0),
        choices=ALLOWED_STREAM_CFG,
        default=0xBF,
    )
    finalize.add_argument("--performance", action="store_true")
    finalize.add_argument(
        "--benchmark-runs", type=int, choices=(0, 30, 100), default=0
    )
    finalize.add_argument(
        "--clock-hz",
        type=int,
        choices=(100_000_000, 125_000_000, 200_000_000),
    )
    finalize.add_argument("--soak-seconds", type=int, default=0)
    finalize.add_argument("--soak-temp-limit-millic", type=int, default=0)

    verify = subparsers.add_parser("verify", help="verify every bound hash")
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--phase", choices=("build", "run"), required=True)
    verify.add_argument("--expect-workspace", type=Path)
    verify.add_argument("--expect-xsa", type=Path)
    verify.add_argument("--expect-bit", dest="expected_bitstream", type=Path)
    verify.add_argument("--expect-elf", type=Path)
    verify.add_argument("--expect-parameter-manifest", type=Path)
    verify.add_argument("--expect-bias", type=Path)
    verify.add_argument("--expect-weight", type=Path)
    verify.add_argument("--expect-software-git-sha")
    verify.add_argument("--expect-clock-hz", type=int)
    fingerprint = subparsers.add_parser(
        "fingerprint", help="print the SHA256 of one required file"
    )
    fingerprint.add_argument("--file", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "fingerprint":
            print(sha256_file(require_file(args.file, "fingerprint input")))
            return 0
        if args.command == "bind":
            bind_inputs(
                args.manifest,
                args.workspace,
                args.xsa,
                args.bitstream,
                args.hardware_metadata,
                args.hardware_sha_manifest,
                args.parameter_manifest,
            )
            phase = "build"
        elif args.command == "finalize":
            finalize_manifest(
                args.manifest,
                args.elf,
                stream_cfg=args.stream_cfg,
                performance_mode=args.performance,
                benchmark_runs=args.benchmark_runs,
                clock_hz=args.clock_hz,
                soak_seconds=args.soak_seconds,
                soak_temp_limit_millic=args.soak_temp_limit_millic,
            )
            phase = "run"
        else:
            expected_software_provenance = (
                {
                    "git_sha": args.expect_software_git_sha,
                    "git_dirty": 0,
                }
                if args.expect_software_git_sha is not None
                else None
            )
            verify_manifest(
                args.manifest,
                args.phase,
                args.expect_workspace,
                args.expect_xsa,
                args.expected_bitstream,
                args.expect_elf,
                args.expect_parameter_manifest,
                args.expect_bias,
                args.expect_weight,
                expected_software_provenance,
                args.expect_clock_hz,
            )
            phase = args.phase
    except (CandidateArtifactError, KeyError, TypeError) as error:
        print(f"FAIL: ABI v2 candidate artifact verification: {error}")
        return 1
    print(f"PASS: ABI v2 candidate artifact verification ({phase})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
