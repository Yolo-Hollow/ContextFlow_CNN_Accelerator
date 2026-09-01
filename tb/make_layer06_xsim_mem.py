"""Generate the legacy 'layer06' (single-scale Conv3) XSIM fixture.

Historical test names call the 52x52x64 -> 128 stage layer06.  In the current
ten-layer single-scale manifest this is ``03_conv3_pool``.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from xsim_fixture_lib import emit_conv3_with_unpooled_golden


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", default=None)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    layer_dir = repo_root / "repro" / "model" / "03_conv3_pool"
    out_dir = (
        Path(args.out_dir).resolve()
        if args.out_dir
        else repo_root / "build_xsim" / "fixtures" / "03_conv3_pool"
    )
    outputs = emit_conv3_with_unpooled_golden(layer_dir, out_dir, repo_root / "repro")
    print(f"Wrote {len(outputs)} legacy layer06 fixture files to {out_dir}")


if __name__ == "__main__":
    main()
