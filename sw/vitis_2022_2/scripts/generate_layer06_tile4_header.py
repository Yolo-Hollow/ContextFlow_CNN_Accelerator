import struct
import sys
from pathlib import Path


SRC_DIR = Path(r"D:\MPSoC\python_prj\rtl_golden\facemask_layer06_rtl")

H = 52
W = 52
CIN = 64
COUT = 128
KH = 3
KW = 3


def maxpool2x2s2_hwc(values, h, w, c):
    pooled = []
    for y in range(h // 2):
        for x in range(w // 2):
            for co in range(c):
                base0 = ((y * 2) * w + x * 2) * c + co
                base1 = base0 + c
                base2 = base0 + w * c
                base3 = base2 + c
                pooled.append(max(values[base0], values[base1], values[base2], values[base3]))
    return pooled


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
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate_layer06_tile4_header.py <output-header>")
    out = Path(sys.argv[1]).resolve()

    ifm = read_exact(SRC_DIR / "ifm_u8_hwc.bin", H * W * CIN)
    weight_oihw = read_exact(SRC_DIR / "weight_raw_oihw_s8.bin", COUT * CIN * KH * KW)
    bias_raw = read_exact(SRC_DIR / "bias_i32.bin", COUT * 4)
    lut = read_exact(SRC_DIR / "activation_lut_u8.bin", 256)
    golden = read_exact(SRC_DIR / "golden_ofm_u8_hwc.bin", H * W * COUT)
    golden_pool = maxpool2x2s2_hwc(golden, H, W, COUT)

    weight_kco = []
    for ch in range(CIN):
        for ky in range(KH):
            for kx in range(KW):
                for co in range(COUT):
                    src = ((co * CIN + ch) * KH + ky) * KW + kx
                    weight_kco.append(int8_value(weight_oihw[src]))

    bias = list(struct.unpack("<" + "i" * COUT, bias_raw))

    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="ascii", newline="\n") as f:
        f.write("#ifndef LAYER06_TILE4_DATA_H\n")
        f.write("#define LAYER06_TILE4_DATA_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("/* Generated at manual-build time from D:/MPSoC/python_prj/rtl_golden/facemask_layer06_rtl. */\n")
        f.write("/* Shape: IFM 52x52x64, weight KCO 576x128, full golden 52x52x128. */\n\n")
        emit_array(f, "uint8_t", "layer06_tile4_ifm_u8", list(ifm))
        emit_array(f, "int8_t", "layer06_tile4_weight_s8", weight_kco)
        emit_array(f, "int32_t", "layer06_tile4_bias_i32", bias, per_line=8)
        emit_array(f, "uint8_t", "layer06_tile4_activation_lut_u8", list(lut))
        emit_array(f, "uint8_t", "layer06_tile4_golden_ofm_u8", list(golden))
        emit_array(f, "uint8_t", "layer06_pool_golden_ofm_u8", golden_pool)
        f.write("#endif\n")

    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
