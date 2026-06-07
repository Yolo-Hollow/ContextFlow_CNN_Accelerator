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


def pack_weight_kco(weight_oihw, cin, cout, kernel, emulate_1x1_as_3x3=False):
    if emulate_1x1_as_3x3 and kernel != 1:
        raise RuntimeError("--emulate-1x1-as-3x3 requires a native 1x1 layer")

    hw_kernel = 3 if emulate_1x1_as_3x3 else kernel
    weight_kco = []
    for ch in range(cin):
        for ky in range(hw_kernel):
            for kx in range(hw_kernel):
                for co in range(cout):
                    if emulate_1x1_as_3x3 and (ky != 1 or kx != 1):
                        weight_kco.append(0)
                    else:
                        src_ky = 0 if emulate_1x1_as_3x3 else ky
                        src_kx = 0 if emulate_1x1_as_3x3 else kx
                        src = ((co * cin + ch) * kernel + src_ky) * kernel + src_kx
                        weight_kco.append(int8_value(weight_oihw[src]))
    return weight_kco, hw_kernel


def pack_weight_stream(weight_kco, k_total, cout, rows=18, cout_tile=16):
    k_passes = (k_total + rows - 1) // rows
    cout_blocks = (cout + cout_tile - 1) // cout_tile
    packed = []
    for block in range(cout_blocks):
        cout_base = block * cout_tile
        for kpass in range(k_passes):
            k_base = kpass * rows
            for kk in range(rows):
                for lane in range(cout_tile):
                    gk = k_base + kk
                    co = cout_base + lane
                    packed.append(
                        weight_kco[gk * cout + co]
                        if gk < k_total and co < cout
                        else 0
                    )
    return packed


def main():
    parser = argparse.ArgumentParser(description="Generate a Vitis C header for one single-scale RTL golden layer.")
    parser.add_argument("layer_dir", help="Layer directory produced by export_rtl_single_scale_golden.py")
    parser.add_argument("output_header")
    parser.add_argument("--prefix", required=True, help="C symbol prefix, e.g. conv4_pool")
    parser.add_argument("--omit-ifm", action="store_true",
                        help="Do not embed the IFM array when it comes from a previous hardware layer.")
    parser.add_argument(
        "--emulate-1x1-as-3x3",
        action="store_true",
        help="Expand native 1x1 weights to center-only 3x3 weights for the existing 3x3 RTL datapath.",
    )
    parser.add_argument(
        "--prepack-weight-stream",
        action="store_true",
        help="Emit weights directly in COUT-block/K-pass AXI packet order.",
    )
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

    ifm = None
    if not args.omit_ifm:
        ifm = read_exact(layer_dir / "ifm_u8_hwc.bin", ifm_h * ifm_w * cin)
    weight_oihw = read_exact(layer_dir / "weight_raw_oihw_s8.bin", cout * cin * kernel * kernel)
    bias_raw = read_exact(layer_dir / "bias_i32.bin", cout * 4)
    lut = read_exact(layer_dir / "activation_lut_u8.bin", 256)
    golden = read_exact(layer_dir / "golden_ofm_u8_hwc.bin", final_h * final_w * cout)

    weight_kco, hw_kernel = pack_weight_kco(
        weight_oihw,
        cin,
        cout,
        kernel,
        emulate_1x1_as_3x3=args.emulate_1x1_as_3x3,
    )
    hw_pad = 1 if args.emulate_1x1_as_3x3 else int(meta["conv"]["pad"])
    hw_k_total = cin * hw_kernel * hw_kernel
    if hw_k_total >= (1 << 14):
        raise RuntimeError(f"Hardware K_TOTAL {hw_k_total} does not fit the 14-bit K path")

    bias = list(struct.unpack("<" + "i" * cout, bias_raw))
    emitted_weight = (
        pack_weight_stream(weight_kco, hw_k_total, cout)
        if args.prepack_weight_stream
        else weight_kco
    )
    guard = f"{args.prefix.upper()}_DATA_H"

    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="ascii", newline="\n") as f:
        f.write(f"#ifndef {guard}\n")
        f.write(f"#define {guard}\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write(f"/* Generated from {layer_dir.as_posix()}. */\n")
        weight_layout = (
            f"prepacked stream {len(emitted_weight)} bytes"
            if args.prepack_weight_stream
            else f"KCO {hw_k_total}x{cout}"
        )
        f.write(
            f"/* IFM {ifm_h}x{ifm_w}x{cin}, weight {weight_layout}, "
            f"golden {final_h}x{final_w}x{cout}. */\n\n"
        )
        f.write(f"#define {args.prefix.upper()}_NATIVE_KERNEL {kernel}U\n")
        f.write(f"#define {args.prefix.upper()}_HW_KERNEL {hw_kernel}U\n")
        f.write(f"#define {args.prefix.upper()}_HW_PAD {hw_pad}U\n")
        f.write(f"#define {args.prefix.upper()}_HW_K_TOTAL {hw_k_total}U\n")
        f.write(
            f"#define {args.prefix.upper()}_EMULATE_1X1_AS_3X3 "
            f"{1 if args.emulate_1x1_as_3x3 else 0}U\n\n"
        )
        f.write(
            f"#define {args.prefix.upper()}_WEIGHT_PREPACKED "
            f"{1 if args.prepack_weight_stream else 0}U\n"
        )
        f.write(
            f"#define {args.prefix.upper()}_WEIGHT_STREAM_BYTES "
            f"{len(emitted_weight)}U\n\n"
        )
        if ifm is not None:
            emit_array(f, "uint8_t", f"{args.prefix}_ifm_u8", list(ifm))
        emit_array(f, "int8_t", f"{args.prefix}_weight_s8", emitted_weight)
        emit_array(f, "int32_t", f"{args.prefix}_bias_i32", bias, per_line=8)
        emit_array(f, "uint8_t", f"{args.prefix}_activation_lut_u8", list(lut))
        emit_array(f, "uint8_t", f"{args.prefix}_golden_ofm_u8", list(golden))
        f.write("#endif\n")

    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
