"""Fail-closed COCO80 run archives, accuracy gates, and hash closure."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
from typing import Any, Mapping, Sequence
import zlib

from .assets import sha256_file, write_json_atomic
from .sd_pack import validate_pipeline_chain


COPY_CHUNK_BYTES = 1024 * 1024
RUN_SCHEMA = "coco80.run-archive.v1"
ACCURACY_SCHEMA = "coco80.five-level-accuracy.v1"
ACCURACY_LEVELS = (
    "official640",
    "fp32_416",
    "ptq_416",
    "rtl_416",
    "board_416",
)
REQUIRED_BINDINGS = (
    "bit",
    "xsa",
    "elf",
    "model_manifest",
    "quant_manifest",
    "calibration_manifest",
    "dataset_manifest",
)
PIPELINE_ROLES = (
    "input_package",
    "parameter_package",
    "raw_head_package",
    "detection_package",
    "result_package",
)
_SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")


class ResultArchiveError(RuntimeError):
    """Raised when a result, metric gate, or archive hash cannot be trusted."""


@dataclass(frozen=True)
class AccuracyGate:
    """Absolute and predecessor-delta limits for one accuracy level.

    mAP values are fractions in [0, 1].  Delta limits are explicitly expressed
    in percentage points, avoiding the common 0.01-versus-1.0 ambiguity.
    """

    min_map50_95: float = 0.0
    min_map50: float = 0.0
    max_drop_map50_95_points: float | None = None
    max_drop_map50_points: float | None = None

    def __post_init__(self) -> None:
        for name in ("min_map50_95", "min_map50"):
            value = getattr(self, name)
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ResultArchiveError(f"{name} must be numeric")
            if not math.isfinite(float(value)) or not 0.0 <= float(value) <= 1.0:
                raise ResultArchiveError(f"{name} must be in [0, 1]")
        for name in ("max_drop_map50_95_points", "max_drop_map50_points"):
            value = getattr(self, name)
            if value is not None and (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(float(value))
                or float(value) < 0.0
            ):
                raise ResultArchiveError(f"{name} must be a non-negative finite number")

    @classmethod
    def from_value(cls, value: Any) -> "AccuracyGate":
        if isinstance(value, cls):
            return value
        if not isinstance(value, Mapping):
            raise ResultArchiveError("each accuracy gate must be an object")
        allowed = {
            "min_map50_95",
            "min_map50",
            "max_drop_map50_95_points",
            "max_drop_map50_points",
        }
        unknown = set(value) - allowed
        if unknown:
            raise ResultArchiveError(f"unknown accuracy gate fields: {sorted(unknown)}")
        return cls(**value)

    def to_dict(self) -> dict[str, float | None]:
        return {
            "min_map50_95": float(self.min_map50_95),
            "min_map50": float(self.min_map50),
            "max_drop_map50_95_points": (
                None
                if self.max_drop_map50_95_points is None
                else float(self.max_drop_map50_95_points)
            ),
            "max_drop_map50_points": (
                None
                if self.max_drop_map50_points is None
                else float(self.max_drop_map50_points)
            ),
        }


def _safe_component(value: Any, label: str) -> str:
    if not isinstance(value, str) or not _SAFE_COMPONENT.fullmatch(value):
        raise ResultArchiveError(
            f"{label} must match {_SAFE_COMPONENT.pattern!r}, got {value!r}"
        )
    return value


def normalize_run_id(run_id: int | str) -> str:
    if isinstance(run_id, bool):
        raise ResultArchiveError("run_id must be a positive uint64 or safe string")
    if isinstance(run_id, int):
        if not 0 < run_id <= (1 << 64) - 1:
            raise ResultArchiveError("integer run_id must be in [1, 2^64-1]")
        return f"{run_id:016x}"
    return _safe_component(run_id, "run_id")


def create_run_directory(root: str | Path, run_id: int | str) -> Path:
    """Create the fixed run-id directory structure without reusing old state."""

    destination = Path(root) / normalize_run_id(run_id)
    destination.mkdir(parents=True, exist_ok=False)
    for relative in (
        "bindings",
        "artifacts",
        "metrics/sources",
        "manifest",
        "seal",
        "logs",
    ):
        (destination / relative).mkdir(parents=True, exist_ok=False)
    return destination.resolve()


def _regular(path: str | Path, label: str) -> Path:
    target = Path(path)
    if target.is_symlink():
        raise ResultArchiveError(f"{label} must not be a symlink: {target}")
    if not target.is_file():
        raise ResultArchiveError(f"{label} is not a regular file: {target}")
    return target


def _within(root: Path, candidate: Path) -> bool:
    try:
        candidate.relative_to(root)
        return True
    except ValueError:
        return False


def _archive_member(root: Path, relative: str) -> Path:
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts or "." in pure.parts or "\\" in relative:
        raise ResultArchiveError(f"unsafe archive member path {relative!r}")
    candidate = root.joinpath(*pure.parts)
    if not _within(root, candidate.resolve(strict=False)):
        raise ResultArchiveError(f"archive member escapes run directory: {relative}")
    return candidate


def _atomic_copy(source: Path, destination: Path) -> dict[str, Any]:
    source = _regular(source, "archive source")
    before = source.stat()
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise ResultArchiveError(f"refusing to overwrite archive member {destination}")
    temporary: Path | None = None
    digest = hashlib.sha256()
    crc = 0
    copied = 0
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{destination.name}.",
            suffix=".tmp",
            dir=destination.parent,
            delete=False,
        ) as target, source.open("rb") as stream:
            temporary = Path(target.name)
            while True:
                chunk = stream.read(COPY_CHUNK_BYTES)
                if not chunk:
                    break
                target.write(chunk)
                copied += len(chunk)
                digest.update(chunk)
                crc = zlib.crc32(chunk, crc)
            target.flush()
            os.fsync(target.fileno())
        after = source.stat()
        if (
            before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
            or copied != before.st_size
        ):
            raise ResultArchiveError(f"archive source changed while copying: {source}")
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return {
        "path": destination.as_posix(),
        "bytes": copied,
        "crc32": crc & 0xFFFFFFFF,
        "sha256": digest.hexdigest(),
    }


def _finite_metric(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ResultArchiveError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result) or not 0.0 <= result <= 1.0:
        raise ResultArchiveError(f"{label} must be finite and in [0, 1]")
    return result


def _metric_source(value: str | Path | Mapping[str, Any], level: str) -> tuple[Mapping[str, Any], str | None]:
    if isinstance(value, Mapping):
        payload = value
        source_sha = None
    else:
        path = _regular(value, f"{level} summary")
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise ResultArchiveError(f"cannot parse {level} summary: {exc}") from exc
        if not isinstance(payload, Mapping):
            raise ResultArchiveError(f"{level} summary must be a JSON object")
        source_sha = sha256_file(path)
    coco = payload.get("coco")
    if isinstance(coco, Mapping) and isinstance(coco.get("metrics"), Mapping):
        metrics = coco["metrics"]
    elif isinstance(payload.get("metrics"), Mapping):
        metrics = payload["metrics"]
    else:
        metrics = payload
    if not isinstance(metrics, Mapping):
        raise ResultArchiveError(f"{level} contains no metrics object")
    return metrics, source_sha


def _pick_metric(metrics: Mapping[str, Any], names: Sequence[str], label: str) -> float:
    present = [name for name in names if name in metrics]
    if not present:
        raise ResultArchiveError(f"{label} is absent (accepted keys: {list(names)})")
    values = [_finite_metric(metrics[name], f"{label}/{name}") for name in present]
    if any(abs(value - values[0]) > 1e-12 for value in values[1:]):
        raise ResultArchiveError(f"conflicting aliases for {label}")
    return values[0]


def compare_accuracy_levels(
    levels: Mapping[str, str | Path | Mapping[str, Any]],
    gates: Mapping[str, AccuracyGate | Mapping[str, Any]],
    *,
    level_order: Sequence[str] = ACCURACY_LEVELS,
) -> dict[str, Any]:
    """Compare exactly five mAP levels and evaluate absolute/Delta gates."""

    order = tuple(level_order)
    if len(order) != 5 or len(set(order)) != 5:
        raise ResultArchiveError("level_order must contain exactly five unique names")
    if set(levels) != set(order):
        raise ResultArchiveError(
            f"accuracy levels must be exactly {list(order)}; "
            f"missing={sorted(set(order) - set(levels))}, extra={sorted(set(levels) - set(order))}"
        )
    if set(gates) != set(order):
        raise ResultArchiveError("accuracy gates must define every one of the five levels")
    normalized_gates = {name: AccuracyGate.from_value(gates[name]) for name in order}
    rows: list[dict[str, Any]] = []
    failures: list[str] = []
    previous: dict[str, float] | None = None
    for name in order:
        metrics, source_sha = _metric_source(levels[name], name)
        current = {
            "map50_95": _pick_metric(
                metrics, ("AP50_95", "mAP50_95", "AP"), f"{name}.mAP50:95"
            ),
            "map50": _pick_metric(metrics, ("AP50", "mAP50"), f"{name}.mAP50"),
        }
        gate = normalized_gates[name]
        level_failures: list[str] = []
        if current["map50_95"] < gate.min_map50_95:
            level_failures.append(
                f"mAP50:95 {current['map50_95']:.6f} < {gate.min_map50_95:.6f}"
            )
        if current["map50"] < gate.min_map50:
            level_failures.append(f"mAP50 {current['map50']:.6f} < {gate.min_map50:.6f}")
        delta: dict[str, float] | None = None
        if previous is not None:
            delta = {
                "map50_95_points": (current["map50_95"] - previous["map50_95"]) * 100.0,
                "map50_points": (current["map50"] - previous["map50"]) * 100.0,
            }
            drop_ap = max(0.0, -delta["map50_95_points"])
            drop_ap50 = max(0.0, -delta["map50_points"])
            if (
                gate.max_drop_map50_95_points is not None
                and drop_ap > gate.max_drop_map50_95_points + 1e-12
            ):
                level_failures.append(
                    f"mAP50:95 drop {drop_ap:.6f} points > "
                    f"{gate.max_drop_map50_95_points:.6f}"
                )
            if (
                gate.max_drop_map50_points is not None
                and drop_ap50 > gate.max_drop_map50_points + 1e-12
            ):
                level_failures.append(
                    f"mAP50 drop {drop_ap50:.6f} points > "
                    f"{gate.max_drop_map50_points:.6f}"
                )
        failures.extend(f"{name}: {failure}" for failure in level_failures)
        rows.append(
            {
                "name": name,
                "map50_95": current["map50_95"],
                "map50": current["map50"],
                "delta_from_previous": delta,
                "gate": gate.to_dict(),
                "passed": not level_failures,
                "failures": level_failures,
                "source_sha256": source_sha,
            }
        )
        previous = current
    return {
        "schema": ACCURACY_SCHEMA,
        "level_order": list(order),
        "passed": not failures,
        "failures": failures,
        "levels": rows,
    }


def enforce_accuracy_gates(
    levels: Mapping[str, str | Path | Mapping[str, Any]],
    gates: Mapping[str, AccuracyGate | Mapping[str, Any]],
    *,
    level_order: Sequence[str] = ACCURACY_LEVELS,
) -> dict[str, Any]:
    report = compare_accuracy_levels(levels, gates, level_order=level_order)
    if not report["passed"]:
        raise ResultArchiveError("accuracy gate failed: " + "; ".join(report["failures"]))
    return report


def _relative_entry(run: Path, source: Path, group: str, role: str) -> tuple[str, Path]:
    role = _safe_component(role, "artifact role")
    filename = source.name
    if not _SAFE_COMPONENT.fullmatch(filename):
        # Preserve the suffix where possible while making the archive path stable.
        suffix = source.suffix if re.fullmatch(r"\.[A-Za-z0-9]{1,16}", source.suffix) else ".bin"
        filename = f"payload{suffix}"
    relative = PurePosixPath(group, role, filename).as_posix()
    return relative, run.joinpath(*PurePosixPath(relative).parts)


def _write_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="ascii",
            newline="\n",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def seal_run(
    run_directory: str | Path,
    *,
    bindings: Mapping[str, str | Path],
    artifacts: Mapping[str, str | Path] | None = None,
    accuracy_levels: Mapping[str, str | Path | Mapping[str, Any]] | None = None,
    accuracy_gates: Mapping[str, AccuracyGate | Mapping[str, Any]] | None = None,
    metadata: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Copy, gate, manifest, and seal one run with a closed SHA256 inventory."""

    run = Path(run_directory).resolve(strict=True)
    if not run.is_dir():
        raise ResultArchiveError("run_directory is not a directory")
    if set(bindings) != set(REQUIRED_BINDINGS):
        raise ResultArchiveError(
            f"bindings must be exactly {list(REQUIRED_BINDINGS)}; "
            f"missing={sorted(set(REQUIRED_BINDINGS) - set(bindings))}, "
            f"extra={sorted(set(bindings) - set(REQUIRED_BINDINGS))}"
        )
    manifest_path = run / "manifest" / "run.json"
    seal_path = run / "seal" / "run.sha256"
    if manifest_path.exists() or seal_path.exists():
        raise ResultArchiveError("run is already sealed or partially sealed")
    existing_files = [path for path in run.rglob("*") if path.is_file() or path.is_symlink()]
    if existing_files:
        raise ResultArchiveError(
            f"unsealed run directory already contains files: {existing_files[0]}"
        )
    if (accuracy_levels is None) != (accuracy_gates is None):
        raise ResultArchiveError("accuracy_levels and accuracy_gates must be supplied together")
    accuracy_report: dict[str, Any] | None = None
    if accuracy_levels is not None and accuracy_gates is not None:
        accuracy_report = enforce_accuracy_gates(accuracy_levels, accuracy_gates)
    copied_bindings: dict[str, dict[str, Any]] = {}
    copied_artifacts: dict[str, dict[str, Any]] = {}
    role_paths: dict[str, Path] = {}
    for role in REQUIRED_BINDINGS:
        source = _regular(bindings[role], f"binding {role}")
        if source.stat().st_size == 0:
            raise ResultArchiveError(f"binding {role} must not be empty")
        if _within(run, source.resolve()):
            raise ResultArchiveError(f"binding {role} source must be outside the run directory")
        relative, destination = _relative_entry(run, source, "bindings", role)
        entry = _atomic_copy(source, destination)
        entry["path"] = relative
        copied_bindings[role] = entry
        role_paths[role] = destination
    for role, value in sorted((artifacts or {}).items()):
        if role in copied_bindings:
            raise ResultArchiveError(f"artifact role collides with binding role {role}")
        if accuracy_report is not None and (
            role == "accuracy_gate" or role.startswith("accuracy_source_")
        ):
            raise ResultArchiveError(f"artifact role {role} is reserved by the accuracy seal")
        source = _regular(value, f"artifact {role}")
        if _within(run, source.resolve()):
            raise ResultArchiveError(f"artifact {role} source must be outside the run directory")
        relative, destination = _relative_entry(run, source, "artifacts", role)
        entry = _atomic_copy(source, destination)
        entry["path"] = relative
        copied_artifacts[role] = entry
        role_paths[role] = destination
    if accuracy_report is not None and accuracy_levels is not None:
        for level in ACCURACY_LEVELS:
            value = accuracy_levels[level]
            if isinstance(value, Mapping):
                continue
            source = _regular(value, f"accuracy summary {level}")
            if _within(run, source.resolve()):
                raise ResultArchiveError(
                    f"accuracy summary {level} source must be outside the run directory"
                )
            relative = PurePosixPath("metrics", "sources", f"{level}.json").as_posix()
            entry = _atomic_copy(source, run.joinpath(*PurePosixPath(relative).parts))
            entry["path"] = relative
            copied_artifacts[f"accuracy_source_{level}"] = entry
        accuracy_path = run / "metrics" / "accuracy_gate.json"
        write_json_atomic(accuracy_path, accuracy_report)
        copied_artifacts["accuracy_gate"] = {
            "path": "metrics/accuracy_gate.json",
            "bytes": accuracy_path.stat().st_size,
            "crc32": _crc32(accuracy_path),
            "sha256": sha256_file(accuracy_path),
        }
    pipeline: dict[str, Any] | None = None
    if set(PIPELINE_ROLES).issubset(role_paths):
        pipeline = validate_pipeline_chain(*(role_paths[role] for role in PIPELINE_ROLES))
    archive_metadata = dict(metadata or {})
    try:
        json.dumps(archive_metadata, allow_nan=False)
    except (TypeError, ValueError) as exc:
        raise ResultArchiveError(f"metadata is not finite JSON: {exc}") from exc
    payload: dict[str, Any] = {
        "schema": RUN_SCHEMA,
        "run_id": run.name,
        "sealed_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "required_bindings": list(REQUIRED_BINDINGS),
        "bindings": copied_bindings,
        "artifacts": copied_artifacts,
        "accuracy": (
            None
            if accuracy_report is None
            else {
                "passed": accuracy_report["passed"],
                "report_sha256": copied_artifacts["accuracy_gate"]["sha256"],
            }
        ),
        "pipeline": pipeline,
        "metadata": archive_metadata,
    }
    write_json_atomic(manifest_path, payload)
    manifest_sha = sha256_file(manifest_path)
    _write_text_atomic(seal_path, manifest_sha + "\n")
    return {
        "status": "sealed",
        "run_id": run.name,
        "run_directory": str(run),
        "manifest": str(manifest_path),
        "manifest_sha256": manifest_sha,
        "seal": str(seal_path),
        "accuracy_passed": accuracy_report is None or accuracy_report["passed"],
        "pipeline_validated": pipeline is not None,
    }


def _crc32(path: Path) -> int:
    crc = 0
    with _regular(path, "archive member").open("rb") as stream:
        while True:
            chunk = stream.read(COPY_CHUNK_BYTES)
            if not chunk:
                break
            crc = zlib.crc32(chunk, crc)
    return crc & 0xFFFFFFFF


def verify_run_archive(run_directory: str | Path) -> dict[str, Any]:
    """Verify the seal and reject missing, changed, symlinked, or undeclared files."""

    run = Path(run_directory).resolve(strict=True)
    if not run.is_dir():
        raise ResultArchiveError("run_directory is not a directory")
    manifest_path = _regular(run / "manifest" / "run.json", "run manifest")
    seal_path = _regular(run / "seal" / "run.sha256", "run seal")
    try:
        raw = manifest_path.read_bytes()
        manifest = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ResultArchiveError(f"cannot parse run manifest: {exc}") from exc
    if not isinstance(manifest, Mapping) or manifest.get("schema") != RUN_SCHEMA:
        raise ResultArchiveError("unsupported run manifest schema")
    canonical = (
        json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"
    ).encode("utf-8")
    if raw != canonical:
        raise ResultArchiveError("run manifest is not canonical JSON")
    actual_manifest_sha = sha256_file(manifest_path)
    try:
        sealed_sha = seal_path.read_text(encoding="ascii")
    except (OSError, UnicodeError) as exc:
        raise ResultArchiveError(f"cannot read run seal: {exc}") from exc
    if sealed_sha != actual_manifest_sha + "\n":
        raise ResultArchiveError("run manifest SHA256 seal mismatch")
    bindings = manifest.get("bindings")
    artifacts = manifest.get("artifacts")
    if not isinstance(bindings, Mapping) or set(bindings) != set(REQUIRED_BINDINGS):
        raise ResultArchiveError("run manifest required bindings are incomplete")
    if manifest.get("required_bindings") != list(REQUIRED_BINDINGS):
        raise ResultArchiveError("run manifest binding contract changed")
    if not isinstance(artifacts, Mapping):
        raise ResultArchiveError("run manifest artifacts must be an object")
    declared: set[str] = set()
    role_paths: dict[str, Path] = {}
    for group_name, group in (("bindings", bindings), ("artifacts", artifacts)):
        for role, raw_entry in group.items():
            _safe_component(role, f"{group_name} role")
            if not isinstance(raw_entry, Mapping):
                raise ResultArchiveError(f"{group_name}.{role} entry is not an object")
            if set(raw_entry) != {"path", "bytes", "crc32", "sha256"}:
                raise ResultArchiveError(f"{group_name}.{role} fields are invalid")
            relative = raw_entry.get("path")
            if not isinstance(relative, str) or relative in declared:
                raise ResultArchiveError(f"invalid or duplicate archive path for {role}")
            declared.add(relative)
            member = _archive_member(run, relative)
            member = _regular(member, f"archive member {relative}")
            if member.stat().st_size != raw_entry.get("bytes"):
                raise ResultArchiveError(f"archive member size mismatch: {relative}")
            if _crc32(member) != raw_entry.get("crc32"):
                raise ResultArchiveError(f"archive member CRC32 mismatch: {relative}")
            if sha256_file(member) != raw_entry.get("sha256"):
                raise ResultArchiveError(f"archive member SHA256 mismatch: {relative}")
            role_paths[role] = member
    actual: set[str] = set()
    for candidate in run.rglob("*"):
        if candidate.is_symlink():
            raise ResultArchiveError(f"run archive contains symlink: {candidate}")
        if candidate.is_file():
            relative = candidate.relative_to(run).as_posix()
            if relative not in {"manifest/run.json", "seal/run.sha256"}:
                actual.add(relative)
    if actual != declared:
        raise ResultArchiveError(
            f"archive hash closure failed: missing={sorted(declared - actual)}, "
            f"undeclared={sorted(actual - declared)}"
        )
    accuracy = manifest.get("accuracy")
    if accuracy is not None:
        if (
            not isinstance(accuracy, Mapping)
            or accuracy.get("passed") is not True
            or "accuracy_gate" not in artifacts
            or accuracy.get("report_sha256") != artifacts["accuracy_gate"]["sha256"]
        ):
            raise ResultArchiveError("sealed accuracy gate binding is invalid")
    pipeline = manifest.get("pipeline")
    if pipeline is not None:
        if not set(PIPELINE_ROLES).issubset(role_paths):
            raise ResultArchiveError("pipeline report exists without all five package roles")
        revalidated = validate_pipeline_chain(*(role_paths[role] for role in PIPELINE_ROLES))
        if revalidated != pipeline:
            raise ResultArchiveError("pipeline chain report changed on revalidation")
    return {
        "status": "ok",
        "run_id": manifest.get("run_id"),
        "manifest_sha256": actual_manifest_sha,
        "binding_count": len(bindings),
        "artifact_count": len(artifacts),
        "pipeline_validated": pipeline is not None,
        "accuracy_validated": accuracy is not None,
    }


@dataclass(frozen=True)
class RunArchive:
    path: Path

    @classmethod
    def create(cls, root: str | Path, run_id: int | str) -> "RunArchive":
        return cls(create_run_directory(root, run_id))

    @classmethod
    def open(cls, path: str | Path) -> "RunArchive":
        target = Path(path).resolve(strict=True)
        if not target.is_dir():
            raise ResultArchiveError("run archive path is not a directory")
        return cls(target)

    def seal(self, **kwargs: Any) -> dict[str, Any]:
        return seal_run(self.path, **kwargs)

    def verify(self) -> dict[str, Any]:
        return verify_run_archive(self.path)


# Short aliases used by automation scripts.
compare_five_levels = compare_accuracy_levels
verify_hash_closure = verify_run_archive
archive_results = seal_run


def _role_arguments(values: Sequence[str], label: str) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        role, separator, path = value.partition("=")
        if not separator or not path:
            raise ResultArchiveError(f"{label} must use role=path syntax: {value!r}")
        role = _safe_component(role, f"{label} role")
        if role in result:
            raise ResultArchiveError(f"duplicate {label} role {role}")
        result[role] = Path(path)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Create, seal, and verify COCO80 run archives")
    sub = parser.add_subparsers(dest="command", required=True)
    create_parser = sub.add_parser("create")
    create_parser.add_argument("--root", required=True, type=Path)
    create_parser.add_argument("--run-id", required=True)
    compare_parser = sub.add_parser("compare")
    for level in ACCURACY_LEVELS:
        compare_parser.add_argument(f"--{level.replace('_', '-')}", required=True, type=Path)
    compare_parser.add_argument("--gates", required=True, type=Path)
    compare_parser.add_argument("--output", type=Path)
    seal_parser = sub.add_parser("seal")
    seal_parser.add_argument("--run-directory", required=True, type=Path)
    for role in REQUIRED_BINDINGS:
        seal_parser.add_argument(f"--{role.replace('_', '-')}", required=True, type=Path)
    seal_parser.add_argument("--artifact", action="append", default=[])
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument("run_directory", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "create":
            result = {"run_directory": str(create_run_directory(args.root, args.run_id))}
        elif args.command == "compare":
            levels = {
                level: getattr(args, level)
                for level in ACCURACY_LEVELS
            }
            try:
                gate_data = json.loads(args.gates.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError) as exc:
                raise ResultArchiveError(f"cannot parse gate JSON: {exc}") from exc
            result = compare_accuracy_levels(levels, gate_data)
            if args.output:
                write_json_atomic(args.output, result)
        elif args.command == "seal":
            bindings = {role: getattr(args, role) for role in REQUIRED_BINDINGS}
            result = seal_run(
                args.run_directory,
                bindings=bindings,
                artifacts=_role_arguments(args.artifact, "artifact"),
            )
        else:
            result = verify_run_archive(args.run_directory)
        print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))
        return 0
    except (OSError, ValueError, TypeError, ResultArchiveError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
