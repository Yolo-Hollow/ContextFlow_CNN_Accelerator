"""Generate the compact Conv0 Conv+Pool fixture from tracked repro data."""

from __future__ import annotations

import argparse
from pathlib import Path

from xsim_fixture_lib import emit_conv0_crop


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--crop-x", type=int, default=96)
    parser.add_argument("--crop-y", type=int, default=96)
    parser.add_argument("--crop-w", type=int, default=16)
    parser.add_argument("--crop-h", type=int, default=8)
    parser.add_argument("--out-dir", default=None)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    layer_dir = repo_root / "repro" / "model" / "00_conv0_pool"
    out_dir = (
        Path(args.out_dir).resolve()
        if args.out_dir
        else repo_root / "build_xsim" / "fixtures" / "conv0_crop16x8_pool"
    )
    outputs = emit_conv0_crop(
        layer_dir,
        out_dir,
        repo_root / "repro",
        crop_x=args.crop_x,
        crop_y=args.crop_y,
        crop_w=args.crop_w,
        crop_h=args.crop_h,
    )
    print(f"Wrote {len(outputs)} Conv0 crop fixture files to {out_dir}")


if __name__ == "__main__":
    main()
