"""Build every external-golden XSIM fixture from tracked ``repro/`` inputs."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from xsim_fixture_lib import (
    SOURCE_FILES,
    emit_conv0_crop,
    emit_conv3_with_unpooled_golden,
    emit_standard_layer,
    sha256_file,
    source_fingerprint,
)


SCHEMA_VERSION = 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate portable external-golden XSIM .mem fixtures from repro/."
    )
    parser.add_argument("--check-only", action="store_true", help="validate an existing fixture set")
    parser.add_argument("--force", action="store_true", help="regenerate even when the manifest matches")
    return parser.parse_args()


def required_sources(repo_root: Path) -> list[Path]:
    layer_names = (
        "00_conv0_pool",
        "01_conv1_pool",
        "02_conv2_pool",
        "03_conv3_pool",
        "04_conv4_pool",
        "05_conv5_pool_like_tiny",
        "06_head_conv6_3x3",
        "07_head_conv7_1x1",
        "08_head_conv8_3x3",
        "09_head_detect_conv9_1x1",
    )
    paths = [
        Path(__file__).resolve(),
        Path(__file__).with_name("xsim_fixture_lib.py").resolve(),
        Path(__file__).with_name("requirements-xsim-fixtures.txt").resolve(),
    ]
    for layer_name in layer_names:
        layer_dir = repo_root / "repro" / "model" / layer_name
        paths.extend(layer_dir / name for name in SOURCE_FILES)
    return paths


def expected_outputs(out_root: Path) -> list[Path]:
    standard = (
        "00_conv0_pool",
        "01_conv1_pool",
        "02_conv2_pool",
        "04_conv4_pool",
        "04_conv4_pool_cout16",
        "05_conv5_pool_like_tiny",
        "05_conv5_pool_like_tiny_cout16",
        "06_head_conv6_3x3_cout16",
        "06_head_conv6_3x3",
        "07_head_conv7_1x1",
        "08_head_conv8_3x3_cout16",
        "08_head_conv8_3x3",
        "09_head_detect_conv9_1x1",
    )
    outputs: list[Path] = []
    for name in standard:
        outputs.extend(
            out_root / name / filename
            for filename in (
                "ifm_u8_hwc.mem",
                "weight_kco_s8.mem",
                "bias_i32.mem",
                "activation_lut_u8.mem",
                "golden_ofm_u8_hwc.mem",
            )
        )
    outputs.extend(
        out_root / "03_conv3_pool" / filename
        for filename in (
            "ifm_u8_hwc.mem",
            "weight_kco_s8.mem",
            "bias_i32.mem",
            "activation_lut_u8.mem",
            "golden_ofm_u8_hwc.mem",
            "golden_pool2x2s2_u8_hwc.mem",
        )
    )
    outputs.extend(
        out_root / "conv0_crop16x8_pool" / filename
        for filename in (
            "ifm_u8_hwc.mem",
            "weight_kco_s8.mem",
            "bias_i32.mem",
            "activation_lut_u8.mem",
            "golden_pool2x2s2_u8_hwc.mem",
        )
    )
    return outputs


def validate_manifest(
    manifest_path: Path, repo_root: Path, sources: list[Path], outputs: list[Path]
) -> tuple[bool, str]:
    if not manifest_path.is_file():
        return False, f"missing {manifest_path}"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return False, f"invalid fixture manifest: {exc}"
    if manifest.get("schema_version") != SCHEMA_VERSION:
        return False, "fixture manifest schema changed"
    if manifest.get("sources") != source_fingerprint(sources, repo_root):
        return False, "fixture source fingerprint changed"

    output_entries = manifest.get("outputs", [])
    recorded = {entry["path"]: entry for entry in output_entries}
    expected_paths = {output.relative_to(repo_root).as_posix() for output in outputs}
    if len(recorded) != len(output_entries) or set(recorded) != expected_paths:
        return False, "fixture manifest output set changed"
    for output in outputs:
        relative = output.relative_to(repo_root).as_posix()
        entry = recorded.get(relative)
        if entry is None or not output.is_file():
            return False, f"missing generated fixture {relative}"
        if output.stat().st_size != int(entry["bytes"]):
            return False, f"fixture size mismatch for {relative}"
        if sha256_file(output) != entry["sha256"]:
            return False, f"fixture hash mismatch for {relative}"
    return True, "fixture manifest and hashes match"


def generate(repo_root: Path, out_root: Path) -> list[Path]:
    model_root = repo_root / "repro" / "model"
    generated: list[Path] = []
    generated += emit_standard_layer(
        model_root / "00_conv0_pool", out_root / "00_conv0_pool", repo_root / "repro"
    )
    generated += emit_conv0_crop(
        model_root / "00_conv0_pool", out_root / "conv0_crop16x8_pool", repo_root / "repro"
    )
    generated += emit_conv3_with_unpooled_golden(
        model_root / "03_conv3_pool", out_root / "03_conv3_pool", repo_root / "repro"
    )
    for layer_name, fixture_name, cout_limit in (
        ("01_conv1_pool", "01_conv1_pool", None),
        ("02_conv2_pool", "02_conv2_pool", None),
        ("04_conv4_pool", "04_conv4_pool", None),
        ("04_conv4_pool", "04_conv4_pool_cout16", 16),
        ("05_conv5_pool_like_tiny", "05_conv5_pool_like_tiny", None),
        ("05_conv5_pool_like_tiny", "05_conv5_pool_like_tiny_cout16", 16),
        ("06_head_conv6_3x3", "06_head_conv6_3x3_cout16", 16),
        ("06_head_conv6_3x3", "06_head_conv6_3x3", None),
        ("07_head_conv7_1x1", "07_head_conv7_1x1", None),
        ("08_head_conv8_3x3", "08_head_conv8_3x3_cout16", 16),
        ("08_head_conv8_3x3", "08_head_conv8_3x3", None),
        ("09_head_detect_conv9_1x1", "09_head_detect_conv9_1x1", None),
    ):
        generated += emit_standard_layer(
            model_root / layer_name,
            out_root / fixture_name,
            repo_root / "repro",
            cout_limit=cout_limit,
        )
    return generated


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    out_root = repo_root / "build_xsim" / "fixtures"
    manifest_path = out_root / "fixture_manifest.json"
    sources = required_sources(repo_root)
    outputs = expected_outputs(out_root)

    valid, reason = validate_manifest(manifest_path, repo_root, sources, outputs)
    if args.check_only:
        if not valid:
            print(f"XSIM fixture preflight failed: {reason}", file=sys.stderr)
            return 1
        print(f"XSIM fixture preflight passed: {reason}")
        return 0
    if valid and not args.force:
        print(f"XSIM fixtures are current: {reason}")
        return 0

    print(f"Generating XSIM fixtures ({reason})")
    # Never recursively remove the fixture root: another XSIM process may be
    # reading an already generated file.  Emitters atomically replace only the
    # explicitly enumerated products, and the exact generated-set check below
    # prevents a new emitter from silently adding or omitting a fixture.
    out_root.mkdir(parents=True, exist_ok=True)
    generated = generate(repo_root, out_root)
    expected = {path.resolve() for path in outputs}
    actual = {path.resolve() for path in generated}
    if actual != expected:
        missing = sorted(str(path) for path in expected - actual)
        extra = sorted(str(path) for path in actual - expected)
        raise RuntimeError(f"fixture output set mismatch; missing={missing}, extra={extra}")

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "source_root": "repro",
        "sources": source_fingerprint(sources, repo_root),
        "outputs": [
            {
                "path": path.relative_to(repo_root).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
            for path in sorted(outputs)
        ],
    }
    manifest_tmp = manifest_path.with_name(f".{manifest_path.name}.tmp")
    manifest_tmp.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    manifest_tmp.replace(manifest_path)
    valid, reason = validate_manifest(manifest_path, repo_root, sources, outputs)
    if not valid:
        raise RuntimeError(f"generated fixture validation failed: {reason}")
    print(f"Generated {len(outputs)} XSIM fixture files under {out_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
