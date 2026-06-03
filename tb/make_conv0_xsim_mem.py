from pathlib import Path

import numpy as np


SRC_DIR = Path(r"D:\MPSoC\python_prj\rtl_golden\facemask_conv0")
OUT_DIR = SRC_DIR / "xsim_mem"

H = 416
W = 416
CIN = 3
COUT = 16
POOL_H = H // 2
POOL_W = W // 2


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
    golden = np.fromfile(SRC_DIR / "golden_pool2x2s2_u8_hwc.bin", dtype=np.uint8)

    if ifm.size != H * W * CIN:
        raise RuntimeError(f"IFM size mismatch: {ifm.size}")
    if bias.size != COUT:
        raise RuntimeError(f"Bias size mismatch: {bias.size}")
    if lut.size != 256:
        raise RuntimeError(f"LUT size mismatch: {lut.size}")
    if golden.size != POOL_H * POOL_W * COUT:
        raise RuntimeError(f"Golden pool size mismatch: {golden.size}")

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
    write_hex(OUT_DIR / "golden_pool2x2s2_u8_hwc.mem", golden, 2)

    print(f"Wrote Conv0 xsim mem files to {OUT_DIR}")


if __name__ == "__main__":
    main()
