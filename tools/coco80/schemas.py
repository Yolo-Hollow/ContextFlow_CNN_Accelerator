"""Strict, JSON-serializable schemas for the COCO80 host baseline."""

from __future__ import annotations

from dataclasses import dataclass, field
import math
from pathlib import PurePosixPath
import re
from typing import Any, Mapping


DECODE_CONFIG_SCHEMA = "coco80.decode-config.v1"
LETTERBOX_SCHEMA = "coco80.letterbox.v1"
ASSET_MANIFEST_SCHEMA = "coco80.assets.v1"
COCO_EVAL_SUMMARY_SCHEMA = "coco80.coco-eval.v1"
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class SchemaError(ValueError):
    """Raised when serialized data does not match a supported schema."""


def _strict_keys(data: Mapping[str, Any], expected: set[str], label: str) -> None:
    actual = set(data)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        details = []
        if missing:
            details.append(f"missing={missing}")
        if unknown:
            details.append(f"unknown={unknown}")
        raise SchemaError(f"invalid {label} fields: {', '.join(details)}")


def _finite_number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SchemaError(f"{label} must be a finite number, got {value!r}")
    result = float(value)
    if not math.isfinite(result):
        raise SchemaError(f"{label} must be finite, got {value!r}")
    return result


def _integer(value: Any, label: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise SchemaError(f"{label} must be an integer >= {minimum}, got {value!r}")
    return value


def _json_value(value: Any, label: str = "metadata") -> Any:
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise SchemaError(f"{label} contains a non-finite float")
        return value
    if isinstance(value, list):
        return [_json_value(item, label) for item in value]
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise SchemaError(f"{label} object keys must be strings")
        return {key: _json_value(item, label) for key, item in value.items()}
    raise SchemaError(f"{label} is not JSON serializable: {type(value).__name__}")


@dataclass(frozen=True)
class DecodeConfig:
    """Post-processing contract shared by accuracy and interactive runs."""

    profile: str
    confidence_threshold: float
    iou_threshold: float
    max_detections: int
    multi_label: bool
    class_agnostic: bool
    input_size: int = 416
    class_count: int = 80

    def __post_init__(self) -> None:
        if not isinstance(self.profile, str) or self.profile not in {"accuracy", "demo"}:
            raise SchemaError(
                f"decode profile must be 'accuracy' or 'demo', got {self.profile!r}"
            )
        confidence = _finite_number(
            self.confidence_threshold, "confidence_threshold"
        )
        iou = _finite_number(self.iou_threshold, "iou_threshold")
        if not 0.0 <= confidence <= 1.0:
            raise SchemaError("confidence_threshold must be in [0, 1]")
        if not 0.0 <= iou <= 1.0:
            raise SchemaError("iou_threshold must be in [0, 1]")
        _integer(self.max_detections, "max_detections", 1)
        if type(self.multi_label) is not bool or type(self.class_agnostic) is not bool:
            raise SchemaError("multi_label and class_agnostic must be booleans")
        if self.input_size != 416:
            raise SchemaError("the hardware baseline requires input_size=416")
        if self.class_count != 80:
            raise SchemaError("the COCO80 baseline requires class_count=80")

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": DECODE_CONFIG_SCHEMA,
            "profile": self.profile,
            "input_size": self.input_size,
            "class_count": self.class_count,
            "confidence_threshold": float(self.confidence_threshold),
            "iou_threshold": float(self.iou_threshold),
            "max_detections": self.max_detections,
            "multi_label": self.multi_label,
            "class_agnostic": self.class_agnostic,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "DecodeConfig":
        if not isinstance(data, Mapping):
            raise SchemaError("decode config must be a JSON object")
        expected = {
            "schema", "profile", "input_size", "class_count",
            "confidence_threshold", "iou_threshold", "max_detections",
            "multi_label", "class_agnostic",
        }
        _strict_keys(data, expected, "decode config")
        if data["schema"] != DECODE_CONFIG_SCHEMA:
            raise SchemaError(f"unsupported decode schema {data['schema']!r}")
        return cls(
            profile=data["profile"],
            input_size=_integer(data["input_size"], "input_size", 1),
            class_count=_integer(data["class_count"], "class_count", 1),
            confidence_threshold=_finite_number(
                data["confidence_threshold"], "confidence_threshold"
            ),
            iou_threshold=_finite_number(data["iou_threshold"], "iou_threshold"),
            max_detections=_integer(
                data["max_detections"], "max_detections", 1
            ),
            multi_label=data["multi_label"],
            class_agnostic=data["class_agnostic"],
        )


ACCURACY_DECODE_CONFIG = DecodeConfig(
    profile="accuracy",
    confidence_threshold=0.001,
    iou_threshold=0.65,
    max_detections=300,
    multi_label=True,
    class_agnostic=False,
)

DEMO_DECODE_CONFIG = DecodeConfig(
    profile="demo",
    confidence_threshold=0.25,
    iou_threshold=0.45,
    max_detections=300,
    multi_label=False,
    class_agnostic=False,
)


def decode_config_for_profile(profile: str) -> DecodeConfig:
    if profile == "accuracy":
        return ACCURACY_DECODE_CONFIG
    if profile == "demo":
        return DEMO_DECODE_CONFIG
    raise SchemaError(f"unknown decode profile {profile!r}")


@dataclass(frozen=True)
class LetterboxMetadata:
    source_width: int
    source_height: int
    resized_width: int
    resized_height: int
    scale: float
    pad_left: int
    pad_top: int
    pad_right: int
    pad_bottom: int
    model_width: int = 416
    model_height: int = 416
    fill: int = 114
    pixel_format: str = "RGB"
    resample: str = "PIL.BILINEAR"

    def __post_init__(self) -> None:
        for name in (
            "source_width", "source_height", "resized_width", "resized_height"
        ):
            _integer(getattr(self, name), name, 1)
        for name in ("pad_left", "pad_top", "pad_right", "pad_bottom"):
            _integer(getattr(self, name), name, 0)
        scale = _finite_number(self.scale, "scale")
        if scale <= 0.0:
            raise SchemaError("scale must be positive")
        if self.model_width != 416 or self.model_height != 416:
            raise SchemaError("the hardware letterbox is fixed at 416x416")
        if self.fill != 114 or self.pixel_format != "RGB":
            raise SchemaError("the hardware letterbox requires RGB fill=114")
        if self.resample != "PIL.BILINEAR":
            raise SchemaError("the hardware letterbox requires PIL bilinear resize")
        if self.pad_left + self.resized_width + self.pad_right != self.model_width:
            raise SchemaError("horizontal letterbox geometry is inconsistent")
        if self.pad_top + self.resized_height + self.pad_bottom != self.model_height:
            raise SchemaError("vertical letterbox geometry is inconsistent")
        if abs(self.pad_left - self.pad_right) > 1 or abs(self.pad_top - self.pad_bottom) > 1:
            raise SchemaError("letterbox padding is not centered")

    @property
    def pad_x(self) -> int:
        return self.pad_left

    @property
    def pad_y(self) -> int:
        return self.pad_top

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": LETTERBOX_SCHEMA,
            "source_width": self.source_width,
            "source_height": self.source_height,
            "model_width": self.model_width,
            "model_height": self.model_height,
            "resized_width": self.resized_width,
            "resized_height": self.resized_height,
            "scale": float(self.scale),
            "pad_left": self.pad_left,
            "pad_top": self.pad_top,
            "pad_right": self.pad_right,
            "pad_bottom": self.pad_bottom,
            "fill": self.fill,
            "pixel_format": self.pixel_format,
            "resample": self.resample,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "LetterboxMetadata":
        if not isinstance(data, Mapping):
            raise SchemaError("letterbox metadata must be a JSON object")
        expected = {
            "schema", "source_width", "source_height", "model_width",
            "model_height", "resized_width", "resized_height", "scale",
            "pad_left", "pad_top", "pad_right", "pad_bottom", "fill",
            "pixel_format", "resample",
        }
        _strict_keys(data, expected, "letterbox metadata")
        if data["schema"] != LETTERBOX_SCHEMA:
            raise SchemaError(f"unsupported letterbox schema {data['schema']!r}")
        integer_fields = {
            name: _integer(data[name], name, 0)
            for name in expected
            if name not in {"schema", "scale", "pixel_format", "resample"}
        }
        return cls(
            **integer_fields,
            scale=_finite_number(data["scale"], "scale"),
            pixel_format=data["pixel_format"],
            resample=data["resample"],
        )


@dataclass(frozen=True, order=True)
class AssetFile:
    path: str
    size_bytes: int
    sha256: str

    def __post_init__(self) -> None:
        if not isinstance(self.path, str) or not self.path:
            raise SchemaError("asset path must be a non-empty string")
        pure = PurePosixPath(self.path)
        if pure.is_absolute() or ".." in pure.parts or "." in pure.parts:
            raise SchemaError(f"asset path must be normalized and relative: {self.path!r}")
        if pure.parts and pure.parts[0].endswith(":"):
            raise SchemaError(f"asset path must not contain a drive prefix: {self.path!r}")
        if "\\" in self.path or pure.as_posix() != self.path:
            raise SchemaError(f"asset path must use normalized POSIX separators: {self.path!r}")
        _integer(self.size_bytes, "size_bytes", 0)
        if not isinstance(self.sha256, str) or not _SHA256_RE.fullmatch(self.sha256):
            raise SchemaError("asset sha256 must be 64 lowercase hexadecimal characters")

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "size_bytes": self.size_bytes,
            "sha256": self.sha256,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "AssetFile":
        if not isinstance(data, Mapping):
            raise SchemaError("asset entry must be a JSON object")
        _strict_keys(data, {"path", "size_bytes", "sha256"}, "asset entry")
        return cls(
            path=data["path"],
            size_bytes=_integer(data["size_bytes"], "size_bytes", 0),
            sha256=data["sha256"],
        )


@dataclass(frozen=True)
class AssetManifest:
    files: tuple[AssetFile, ...]
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.files:
            raise SchemaError("asset manifest must declare at least one file")
        paths = [entry.path for entry in self.files]
        if len(set(paths)) != len(paths):
            raise SchemaError("asset manifest contains duplicate paths")
        if tuple(sorted(self.files, key=lambda entry: entry.path)) != self.files:
            raise SchemaError("asset manifest entries must be sorted by path")
        if not isinstance(self.metadata, Mapping):
            raise SchemaError("asset manifest metadata must be a JSON object")
        _json_value(dict(self.metadata))

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": ASSET_MANIFEST_SCHEMA,
            "files": [entry.to_dict() for entry in self.files],
            "metadata": _json_value(dict(self.metadata)),
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "AssetManifest":
        if not isinstance(data, Mapping):
            raise SchemaError("asset manifest must be a JSON object")
        _strict_keys(data, {"schema", "files", "metadata"}, "asset manifest")
        if data["schema"] != ASSET_MANIFEST_SCHEMA:
            raise SchemaError(f"unsupported asset schema {data['schema']!r}")
        files = data["files"]
        if not isinstance(files, list):
            raise SchemaError("asset manifest files must be an array")
        return cls(
            files=tuple(AssetFile.from_dict(entry) for entry in files),
            metadata=_json_value(data["metadata"]),
        )


@dataclass(frozen=True)
class CocoEvalSummary:
    annotation_file: str
    prediction_count: int
    image_count: int
    image_ids: tuple[int, ...]
    max_detections: tuple[int, int, int]
    metrics: Mapping[str, float]

    def __post_init__(self) -> None:
        if not isinstance(self.annotation_file, str) or not self.annotation_file:
            raise SchemaError("annotation_file must be a non-empty string")
        _integer(self.prediction_count, "prediction_count", 0)
        _integer(self.image_count, "image_count", 0)
        if len(self.max_detections) != 3:
            raise SchemaError("max_detections must contain exactly three limits")
        previous = 0
        for value in self.max_detections:
            value = _integer(value, "max_detections entry", 1)
            if value <= previous:
                raise SchemaError("max_detections must be strictly increasing")
            previous = value
        if any(isinstance(value, bool) or not isinstance(value, int) for value in self.image_ids):
            raise SchemaError("image_ids must contain integers")
        for name, value in self.metrics.items():
            if not isinstance(name, str):
                raise SchemaError("metric names must be strings")
            _finite_number(value, f"metric {name}")

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": COCO_EVAL_SUMMARY_SCHEMA,
            "annotation_file": self.annotation_file,
            "prediction_count": self.prediction_count,
            "image_count": self.image_count,
            "image_ids": list(self.image_ids),
            "max_detections": list(self.max_detections),
            "metrics": {
                name: float(value) for name, value in self.metrics.items()
            },
        }
