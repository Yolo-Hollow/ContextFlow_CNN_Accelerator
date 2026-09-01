"""Host-side COCO80 baseline utilities for the accelerator project.

Command modules are imported lazily so ``python -m tools.coco80.assets`` (and
the other CLIs) do not encounter runpy's already-imported-module warning.
"""

from importlib import import_module
from typing import Any

from .common import (
    COCO80_CLASS_NAMES,
    COCO80_TO_COCO91,
    COCO91_TO_COCO80,
    coco80_to_coco91,
    coco80_to_coco91_class,
    coco91_to_coco80,
    coco_class_name,
)
from .schemas import (
    ACCURACY_DECODE_CONFIG,
    DEMO_DECODE_CONFIG,
    AssetFile,
    AssetManifest,
    CocoEvalSummary,
    DecodeConfig,
    LetterboxMetadata,
    SchemaError,
    decode_config_for_profile,
)


_LAZY_EXPORTS = {
    "AssetValidationError": (".assets", "AssetValidationError"),
    "build_manifest": (".assets", "build_manifest"),
    "load_manifest": (".assets", "load_manifest"),
    "sha256_file": (".assets", "sha256_file"),
    "validate_assets": (".assets", "validate_assets"),
    "verify_manifest": (".assets", "verify_manifest"),
    "write_manifest_atomic": (".assets", "write_manifest_atomic"),
    "CocoEvalDependencyError": (".coco_eval", "CocoEvalDependencyError"),
    "CocoEvaluationError": (".coco_eval", "CocoEvaluationError"),
    "coco_result_from_xyxy": (".coco_eval", "coco_result_from_xyxy"),
    "evaluate_coco": (".coco_eval", "evaluate_coco"),
    "FILL_VALUE": (".preprocess", "FILL_VALUE"),
    "MODEL_SIZE": (".preprocess", "MODEL_SIZE"),
    "inverse_letterbox_xyxy": (".preprocess", "inverse_letterbox_xyxy"),
    "letterbox_416": (".preprocess", "letterbox_416"),
    "letterbox_file": (".preprocess", "letterbox_file"),
}


def __getattr__(name: str) -> Any:
    try:
        module_name, attribute = _LAZY_EXPORTS[name]
    except KeyError as exc:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}") from exc
    value = getattr(import_module(module_name, __name__), attribute)
    globals()[name] = value
    return value

__all__ = [
    "ACCURACY_DECODE_CONFIG",
    "DEMO_DECODE_CONFIG",
    "AssetFile",
    "AssetManifest",
    "AssetValidationError",
    "COCO80_CLASS_NAMES",
    "COCO80_TO_COCO91",
    "COCO91_TO_COCO80",
    "CocoEvalDependencyError",
    "CocoEvalSummary",
    "CocoEvaluationError",
    "DecodeConfig",
    "FILL_VALUE",
    "LetterboxMetadata",
    "MODEL_SIZE",
    "SchemaError",
    "build_manifest",
    "coco80_to_coco91",
    "coco80_to_coco91_class",
    "coco91_to_coco80",
    "coco_class_name",
    "coco_result_from_xyxy",
    "decode_config_for_profile",
    "evaluate_coco",
    "inverse_letterbox_xyxy",
    "letterbox_416",
    "letterbox_file",
    "load_manifest",
    "sha256_file",
    "validate_assets",
    "verify_manifest",
    "write_manifest_atomic",
]
