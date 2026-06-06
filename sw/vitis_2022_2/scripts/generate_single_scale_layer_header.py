import argparse
import json
import struct
from pathlib import Path


def read_exact(path, expected_size):
    data = path.read_bytes()
    if len(data) != expected_size:
        raise RuntimeError(f"{path} has {len(data)} bytes, expected {expected_size}")
    return data


def int8_value(byte):
    return byte - 256 if byte >= 128 else byte


def emit_array(f, c_type, name, values, per_line=16):
    f.write(f"static const {c_type} {name}[{len(values)}] = {{\n")
    for i in range(0, len(values), per_line):
        chunk = values[i : i + per_line]
        f.write("    ")
        f.write(", ".join(str(v) for v in chunk))
        if i + per_line < len(values):
            f.write(",")
        f.write("\n")
    f.write("};\n\n")


def main():
    parser = argparse.ArgumentParser(description="Generate a Vitis C header for one single-scale RTL golden layer.")
    parser.add_argument("layer_dir", help="Layer directory produced by export_rtl_single_scale_golden.py")
    parser.add_argument("output_header")
    parser.add_argument("--prefix", required=True, help="C symbol prefix, e.g. conv4_pool")
    args = parser.parse_args()

    layer_dir = Path(args.layer_dir).resolve()
    out = Path(args.output_header).resolve()
    meta = json.loads((layer_dir / "manifest.json").read_text(encoding="utf-8"))

    ifm_h, ifm_w, cin = meta["shape"]["ifm_hwc"]
    _, _, cout = meta["shape"]["conv_ofm_hwc"]
    kernel = int(meta["conv"]["kernel"])
    final_h, final_w, final_c = meta["shape"]["final_ofm_hwc"]
    if final_c != cout:
        raise RuntimeError(f"Final C {final_c} does not match conv C {cout}")

    ifm = read_exact(layer_dir / "ifm_u8_hwc.bin", ifm_h * ifm_w * cin)
    weight_oihw = read_exact(layer_dir / "weight_raw_oihw_s8.bin", cout * cin * kernel * kernel)
    bias_raw = read_exact(layer_dir / "bias_i32.bin", cout * 4)
    lut = read_exact(layer_dir / "activation_lut_u8.bin", 256)
    golden = read_exact(layer_dir / "golden_ofm_u8_hwc.bin", final_h * final_w * cout)

    weight_kco = []
    for ch in range(cin):
        for ky in range(kernel):
            for kx in range(kernel):
                for co in range(cout):
                    src = ((co * cin + ch) * kernel + ky) * kernel + kx
                    weight_kco.append(int8_value(weight_oihw[src]))

    bias = list(struct.unpack("<" + "i" * cout, bias_raw))
    guard = f"{args.prefix.upper()}_DATA_H"

    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="ascii", newline="\n") as f:
        f.write(f"#ifndef {guard}\n")
        f.write(f"#define {guard}\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write(f"/* Generated from {layer_dir.as_posix()}. */\n")
        f.write(
            f"/* IFM {ifm_h}x{ifm_w}x{cin}, weight KCO {cin * kernel * kernel}x{cout}, "
            f"golden {final_h}x{final_w}x{cout}. */\n\n"
        )
        emit_array(f, "uint8_t", f"{args.prefix}_ifm_u8", list(ifm))
        emit_array(f, "int8_t", f"{args.prefix}_weight_s8", weight_kco)
        emit_array(f, "int32_t", f"{args.prefix}_bias_i32", bias, per_line=8)
        emit_array(f, "uint8_t", f"{args.prefix}_activation_lut_u8", list(lut))
        emit_array(f, "uint8_t", f"{args.prefix}_golden_ofm_u8", list(golden))
        f.write("#endif\n")

    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
