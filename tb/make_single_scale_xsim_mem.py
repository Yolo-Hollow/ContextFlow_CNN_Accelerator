import argparse
import json
from pathlib import Path

import numpy as np


def write_mem(path, values, fmt):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as f:
        for v in values:
            f.write(fmt.format(int(v) & ((1 << (4 * (len(fmt.format(0))))) - 1)))
            f.write("\n")


def main():
    parser = argparse.ArgumentParser(description="Convert one single-scale RTL golden layer to xsim .mem files.")
    parser.add_argument("layer_dir", help="Layer directory produced by export_rtl_single_scale_golden.py")
    parser.add_argument("--out-dir", default=None, help="Output directory. Defaults to <layer_dir>/xsim_mem.")
    args = parser.parse_args()

    layer_dir = Path(args.layer_dir).resolve()
    out_dir = Path(args.out_dir).resolve() if args.out_dir else layer_dir / "xsim_mem"
    meta = json.loads((layer_dir / "manifest.json").read_text(encoding="utf-8"))

    ifm_h, ifm_w, cin = meta["shape"]["ifm_hwc"]
    _, _, cout = meta["shape"]["conv_ofm_hwc"]
    kernel = int(meta["conv"]["kernel"])
    if kernel != 3:
        raise RuntimeError(f"xsim RTL testbench currently assumes 3x3 K layout, got kernel={kernel}")

    ifm = np.fromfile(layer_dir / "ifm_u8_hwc.bin", dtype=np.uint8)
    weight_oihw = np.fromfile(layer_dir / "weight_raw_oihw_s8.bin", dtype=np.int8).reshape(cout, cin, kernel, kernel)
    bias = np.fromfile(layer_dir / "bias_i32.bin", dtype=np.int32)
    lut = np.fromfile(layer_dir / "activation_lut_u8.bin", dtype=np.uint8)
    golden = np.fromfile(layer_dir / "golden_ofm_u8_hwc.bin", dtype=np.uint8)

    if ifm.size != ifm_h * ifm_w * cin:
        raise RuntimeError(f"IFM size mismatch: got {ifm.size}")
    if bias.size != cout:
        raise RuntimeError(f"Bias size mismatch: got {bias.size}, expected {cout}")
    if lut.size != 256:
        raise RuntimeError(f"LUT size mismatch: got {lut.size}")

    weight_kco = []
    for ch in range(cin):
        for ky in range(kernel):
            for kx in range(kernel):
                for co in range(cout):
                    weight_kco.append(weight_oihw[co, ch, ky, kx])

    write_mem(out_dir / "ifm_u8_hwc.mem", ifm, "{:02x}")
    write_mem(out_dir / "weight_kco_s8.mem", np.array(weight_kco, dtype=np.int8).view(np.uint8), "{:02x}")
    write_mem(out_dir / "bias_i32.mem", bias.view(np.uint32), "{:08x}")
    write_mem(out_dir / "activation_lut_u8.mem", lut, "{:02x}")
    write_mem(out_dir / "golden_ofm_u8_hwc.mem", golden, "{:02x}")

    print(f"Wrote xsim mem files to {out_dir}")


if __name__ == "__main__":
    main()
