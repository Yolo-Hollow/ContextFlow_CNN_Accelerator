"""Freeze upstream, dataset archives, r5 hardware, and host environment hashes."""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
from pathlib import Path

from .assets import sha256_file, write_json_atomic
from .model import verify_upstream


def file_entry(path: Path) -> dict[str, object]:
    if not path.is_file():
        raise RuntimeError(f"missing required asset: {path}")
    return {"path":str(path.resolve()),"bytes":path.stat().st_size,"sha256":sha256_file(path)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--local-weights", type=Path, required=True)
    parser.add_argument("--download-dir", type=Path, required=True)
    parser.add_argument("--coco-root", type=Path, required=True)
    parser.add_argument("--bit", type=Path, required=True)
    parser.add_argument("--xsa", type=Path, required=True)
    parser.add_argument("--hardware-metadata", type=Path, required=True)
    parser.add_argument("--hardware-sha-manifest", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    upstream = verify_upstream(args.upstream, args.weights)
    official = file_entry(args.weights)
    local = file_entry(args.local_weights)
    if official["sha256"] != local["sha256"]:
        raise RuntimeError("local checkpoint differs from the official v9.5.0 release asset")
    archives = {}
    for name in ("train2017.zip","val2017.zip","annotations_trainval2017.zip","coco2017labels.zip"):
        archives[name] = file_entry(args.download_dir / name)
    annotations = {
        name:file_entry(args.coco_root / "annotations" / name)
        for name in ("instances_train2017.json","instances_val2017.json")
    }
    image_lists = {
        name:file_entry(args.coco_root / name)
        for name in ("train2017.txt", "val2017.txt")
    }
    source_root = args.source_root.resolve()
    source_commit = subprocess.check_output(
        ["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True
    ).strip()
    source_status = subprocess.check_output(
        ["git", "-C", str(source_root), "status", "--porcelain"], text=True
    ).strip()
    if source_status:
        raise RuntimeError("COCO80 asset manifest requires a clean implementation worktree")
    manifest = {
        "format":"kv260-coco80-frozen-assets",
        "version":1,
        "upstream":upstream,
        "weights":{"official":official,"local":local,"byte_exact_match":True},
        "dataset":{
            "source":"COCO 2017 official images/annotations plus Ultralytics v1.0 YOLO labels",
            "archives":archives,
            "annotations":annotations,
            "image_lists":image_lists,
            "image_counts":{
                "train2017":len(list((args.coco_root / "images/train2017").glob("*.jpg"))),
                "val2017":len(list((args.coco_root / "images/val2017").glob("*.jpg"))),
            },
        },
        "hardware":{
            "profile":"abi_v2_release_200","clock_hz":200000000,
            "bit":file_entry(args.bit),"xsa":file_entry(args.xsa),
            "metadata":file_entry(args.hardware_metadata),
            "sha_manifest":file_entry(args.hardware_sha_manifest),
        },
        "software":{"git_root":str(source_root),"git_sha":source_commit,"git_dirty":False},
        "host":{
            "python":platform.python_version(),"platform":platform.platform(),
            "pip_freeze":subprocess.check_output(
                [sys.executable, "-m", "pip", "freeze"], text=True
            ).splitlines(),
        },
    }
    if manifest["dataset"]["image_counts"] != {"train2017":118287,"val2017":5000}:
        raise RuntimeError(f"COCO image count gate failed: {manifest['dataset']['image_counts']}")
    write_json_atomic(args.output, manifest)
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
