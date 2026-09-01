"""Generate one portable XSIM layer fixture from tracked repro data."""

from __future__ import annotations

import argparse
from pathlib import Path

from xsim_fixture_lib import emit_standard_layer


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert one repro/model layer to XSIM .mem files."
    )
    parser.add_argument("layer_dir", help="Layer directory below repository repro/.")
    parser.add_argument(
        "--out-dir",
        default=None,
        help="Output directory (default: build_xsim/fixtures/manual/<layer-name>).",
    )
    parser.add_argument(
        "--cout-limit",
        type=int,
        default=0,
        help="Optionally emit only the first N output channels.",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    repro_root = repo_root / "repro"
    layer_dir = Path(args.layer_dir).resolve()
    out_dir = (
        Path(args.out_dir).resolve()
        if args.out_dir
        else repo_root / "build_xsim" / "fixtures" / "manual" / layer_dir.name
    )
    outputs = emit_standard_layer(
        layer_dir,
        out_dir,
        repro_root,
        cout_limit=(args.cout_limit or None),
    )
    print(f"Wrote {len(outputs)} XSIM fixture files to {out_dir}")


if __name__ == "__main__":
    main()
