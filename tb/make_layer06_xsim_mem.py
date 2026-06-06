from pathlib import Path

import numpy as np


SRC_DIR = Path(r"D:\MPSoC\python_prj\rtl_golden\facemask_layer06_rtl")
OUT_DIR = SRC_DIR / "xsim_mem"

H = 52
W = 52
CIN = 64
COUT = 128


def maxpool2x2s2_hwc(values, h, w, c):
    src = values.reshape(h, w, c)
    pooled = np.empty((h // 2, w // 2, c), dtype=np.uint8)
    for y in range(h // 2):
        for x in range(w // 2):
            pooled[y, x, :] = src[y * 2 : y * 2 + 2, x * 2 : x * 2 + 2, :].max(axis=(0, 1))
    return pooled.reshape(-1)


def write_hex(path, values, width):
    path.parent.mkdir(parents=True, exist_ok=True)
    mask = (1 << (width * 4)) - 1
    with path.open("w", encoding="ascii") as f:
        for value in values:
            f.write(f"{int(value) & mask:0{width}x}\n")


def main():
    ifm = np.fromfile(SRC_DIR / "ifm_u8_hwc.bin", dtype=np.uint8)
    weight = np.fromfile(SRC_DIR / "weight_raw_oihw_s8.bin", dtype=np.int8).reshape(COUT, CIN, 3, 3)
    bias = np.fromfile(SRC_DIR / "bias_i32.bin", dtype=np.int32)
    lut = np.fromfile(SRC_DIR / "activation_lut_u8.bin", dtype=np.uint8)
    golden = np.fromfile(SRC_DIR / "golden_ofm_u8_hwc.bin", dtype=np.uint8)

    if ifm.size != H * W * CIN:
        raise RuntimeError(f"IFM size mismatch: {ifm.size}")
    if bias.size != COUT:
        raise RuntimeError(f"Bias size mismatch: {bias.size}")
    if lut.size != 256:
        raise RuntimeError(f"LUT size mismatch: {lut.size}")
    if golden.size != H * W * COUT:
        raise RuntimeError(f"Golden size mismatch: {golden.size}")

    # RTL weight[k][co], k = ch*9 + ky*3 + kx.
    weight_kco = np.empty((CIN * 9, COUT), dtype=np.uint8)
    for ch in range(CIN):
        for ky in range(3):
            for kx in range(3):
                k = ch * 9 + ky * 3 + kx
                weight_kco[k, :] = weight[:, ch, ky, kx].view(np.uint8)

    write_hex(OUT_DIR / "ifm_u8_hwc.mem", ifm, 2)
    write_hex(OUT_DIR / "weight_kco_s8.mem", weight_kco.reshape(-1), 2)
    write_hex(OUT_DIR / "bias_i32.mem", bias.view(np.uint32), 8)
    write_hex(OUT_DIR / "activation_lut_u8.mem", lut, 2)
    write_hex(OUT_DIR / "golden_ofm_u8_hwc.mem", golden, 2)
    pooled = maxpool2x2s2_hwc(golden, H, W, COUT)
    pooled.tofile(SRC_DIR / "golden_pool2x2s2_u8_hwc.bin")
    write_hex(OUT_DIR / "golden_pool2x2s2_u8_hwc.mem", pooled, 2)

    print(f"Wrote xsim mem files to {OUT_DIR}")


if __name__ == "__main__":
    main()
