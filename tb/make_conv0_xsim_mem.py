"""Generate the full Conv0 fixture from tracked repro data."""

from __future__ import annotations

import argparse
from pathlib import Path

from xsim_fixture_lib import emit_standard_layer


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", default=None)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    layer_dir = repo_root / "repro" / "model" / "00_conv0_pool"
    out_dir = (
        Path(args.out_dir).resolve()
        if args.out_dir
        else repo_root / "build_xsim" / "fixtures" / "00_conv0_pool"
    )
    outputs = emit_standard_layer(layer_dir, out_dir, repo_root / "repro")
    print(f"Wrote {len(outputs)} Conv0 fixture files to {out_dir}")


if __name__ == "__main__":
    main()
