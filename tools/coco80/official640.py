"""Run the hash-pinned Ultralytics v9.5.0 COCO val2017 FP32 sanity gate."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

from .assets import sha256_file, write_json_atomic
from .model import OFFICIAL_WEIGHT_SHA256, UPSTREAM_COMMIT, verify_upstream


EXPECTED_MAP50_95 = 0.176
EXPECTED_MAP50 = 0.348
TOLERANCE = 0.001


def upstream_options(output: Path, *, device: str, batch_size: int) -> SimpleNamespace:
    """Return the complete v9.5.0 ``test.py`` option surface.

    The callable ``test()`` still reads the module-global ``opt`` from its
    dataloader path.  Keeping every upstream CLI field here prevents a silent
    dependency on whichever defaults happened to exist in the caller.
    """

    return SimpleNamespace(
        weights=[],
        data="",
        batch_size=batch_size,
        img_size=640,
        conf_thres=0.001,
        iou_thres=0.65,
        task="val",
        device=device,
        single_cls=False,
        augment=False,
        verbose=False,
        save_txt=False,
        save_hybrid=False,
        save_conf=False,
        save_json=True,
        project=str(output),
        name="run",
        exist_ok=True,
    )


def install_upstream_numpy_compat() -> dict[str, object]:
    """Provide the one removed NumPy alias used by the frozen v9.5.0 tag."""

    import numpy as np

    installed = "int" not in np.__dict__
    if installed:
        np.int = int  # type: ignore[attr-defined]
    return {
        "numpy_version": np.__version__,
        "numpy_int_alias_installed": installed,
        "semantic_target": "builtin int",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--coco-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--device", default="0")
    parser.add_argument("--batch-size", type=int, default=32)
    args = parser.parse_args()
    identity = verify_upstream(args.upstream, args.weights)
    if not args.data.name.endswith("coco.yaml"):
        raise RuntimeError("official sanity data path basename must end in coco.yaml")
    coco_root = args.coco_root.resolve()
    annotation = coco_root / "annotations" / "instances_val2017.json"
    val_list = coco_root / "val2017.txt"
    if not annotation.is_file() or not val_list.is_file():
        raise RuntimeError(f"incomplete COCO val2017 tree: {coco_root}")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    root = str(args.upstream.resolve())
    if root not in sys.path:
        sys.path.insert(0, root)
    numpy_compat = install_upstream_numpy_compat()
    # v9.5.0 test.py and data/coco.yaml both contain the historical relative
    # path ``../coco``.  Importing from the pinned checkout is sufficient; the
    # process CWD must instead be a disposable direct child of coco_root.parent
    # so those unmodified upstream paths resolve to the explicitly supplied
    # dataset.  This preserves the upstream source hash while avoiding a
    # machine-specific junction or a silent evaluation against another tree.
    with tempfile.TemporaryDirectory(prefix="coco80_official640_", dir=coco_root.parent) as temporary:
        previous = Path.cwd()
        os.chdir(temporary)
        try:
            if not (Path("..") / "coco").resolve().samefile(coco_root):
                raise RuntimeError("controlled upstream ../coco path does not resolve to --coco-root")
            import test as upstream_test

            upstream_test.opt = upstream_options(
                output, device=args.device, batch_size=args.batch_size
            )
            capture = io.StringIO()
            with contextlib.redirect_stdout(capture):
                result, per_class, timing = upstream_test.test(
                    str(args.data.resolve()),
                    str(args.weights.resolve()),
                    args.batch_size,
                    640,
                    0.001,
                    0.65,
                    True,
                    False,
                    False,
                    True,
                    plots=False,
                    half_precision=False,
                    is_coco=True,
                )
            console = capture.getvalue()
            print(console, end="")
            (output / "official_stdout.txt").write_text(console, encoding="utf-8")
        finally:
            os.chdir(previous)
    map50 = float(result[2])
    map50_95 = float(result[3])
    passed = abs(map50 - EXPECTED_MAP50) <= TOLERANCE and abs(map50_95 - EXPECTED_MAP50_95) <= TOLERANCE
    summary = {
        "format":"kv260-coco80-official640-sanity",
        "version":1,
        "status":"PASS" if passed else "FAIL",
        "upstream":identity,
        "configuration":{
            "input":640,"batch_size":args.batch_size,"precision":"FP32",
            "confidence":0.001,"nms_iou":0.65,"multi_label":True,
        },
        "compatibility":numpy_compat,
        "metrics":{"mAP50_95":map50_95,"mAP50":map50},
        "expected":{"mAP50_95":EXPECTED_MAP50_95,"mAP50":EXPECTED_MAP50,"absolute_tolerance":TOLERANCE},
        "per_class_AP50_95":[float(x) for x in per_class],
        "timing_ms_per_image":{"inference":float(timing[0]),"nms":float(timing[1]),"total":float(timing[2])},
        "artifacts":{
            "data_yaml":str(args.data.resolve()),
            "data_yaml_sha256":sha256_file(args.data.resolve()),
            "coco_root":str(coco_root),
            "annotations_sha256":sha256_file(annotation),
            "stdout_sha256":sha256_file(output / "official_stdout.txt"),
        },
    }
    write_json_atomic(output / "summary.json", summary)
    if not passed:
        raise SystemExit(
            f"official640 sanity failed: mAP50:95={map50_95:.6f}, mAP50={map50:.6f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
